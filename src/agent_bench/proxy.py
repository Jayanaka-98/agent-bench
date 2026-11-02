"""The token meter: one reverse proxy in front of every model API a builder uses.

Agents count their own tokens differently (cache semantics, side calls for
titles or summaries, sub-agents), so their self-reports are not comparable.
Every builder is instead pointed at this proxy, which records each call's usage
from the API's own response, in one normalized form (usage.py).

A builder's base URL names the upstream and the build, so one proxy serves many
builds at once with no shared marker to race on:

    http://127.0.0.1:<port>/<upstream>/<tag>/<the API path as the client sends it>

e.g. `ANTHROPIC_BASE_URL=http://127.0.0.1:8790/anthropic/meeting__jac__cc__r1.builder`.
Claude Code appends `/v1/messages`; that path goes to the `anthropic` upstream.

Upstreams come from a JSON file, `{name: {"url": ..., "key_env": ..., "auth": ...}}`:

- `url`: the upstream origin (plus any path prefix, e.g. `https://openrouter.ai/api`).
- `key_env` (optional): the proxy injects this environment variable's key, so the
  builder can run with a dummy key and never sees the real one. `auth` is
  `x-api-key` (Anthropic) or `bearer` (OpenAI-compatible, the default).
  Without `key_env` the client's own auth headers pass through, which is how
  Claude Code's subscription login is metered.
- `inject_stream_usage` (default true): a streamed Chat Completions request
  without `stream_options.include_usage` reports no usage at all, so the proxy
  adds it; the ledger row says when it did.

Recorded, one JSON line per call:
  <ledger>               tag, upstream, path, status, model, ms, normalized usage, raw usage
  <ledger>.bodies.jsonl  (with --bodies) the request and the response, every chunk of a stream

    python -m agent_bench.proxy --port 8790 --upstreams up.json --ledger runs/x/ledger.jsonl
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import unquote

from aiohttp import ClientSession, ClientTimeout, web

from .usage import Usage, detect, merge_anthropic_stream

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
    "trailers", "transfer-encoding", "upgrade", "host", "content-length",
    # aiohttp hands over the decompressed body, so the upstream's encoding
    # header must not reach the client.
    "content-encoding",
}
AUTH_HEADERS = {"authorization", "x-api-key"}

_write_lock = threading.Lock()


def append_jsonl(path: Path, row: dict) -> None:
    with _write_lock, path.open("a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


class StreamUsage:
    """Usage scanned out of SSE payloads, for either API family."""

    def __init__(self) -> None:
        self.anthropic_start: dict = {}
        self.anthropic_delta: dict = {}
        self.raw: dict | None = None
        self.model = ""

    def feed(self, p: dict) -> None:
        t = p.get("type", "")
        if t == "message_start":
            msg = p.get("message") or {}
            self.model = msg.get("model", self.model)
            self.anthropic_start = msg.get("usage") or {}
        elif t == "message_delta" and p.get("usage"):
            self.anthropic_delta = p["usage"]
        elif t in ("response.completed", "response.incomplete", "response.failed"):
            r = p.get("response") or {}
            self.model = r.get("model", self.model)
            self.raw = r.get("usage") or self.raw
        elif isinstance(p.get("usage"), dict):
            self.model = p.get("model", self.model)
            self.raw = p["usage"]
        elif p.get("model"):
            self.model = p["model"]

    def result(self) -> tuple[Usage | None, dict | None]:
        if self.anthropic_start or self.anthropic_delta:
            raw = {**self.anthropic_start, **{k: v for k, v in self.anthropic_delta.items() if v is not None}}
            return merge_anthropic_stream(self.anthropic_start, self.anthropic_delta), raw
        if self.raw:
            return detect(self.raw), self.raw
        return None, None


class Meter:
    def __init__(self, upstreams: dict, ledger: Path, bodies: Path | None) -> None:
        self.upstreams = upstreams
        self.ledger = ledger
        self.bodies = bodies
        self.totals: dict[str, Usage] = {}
        ledger.parent.mkdir(parents=True, exist_ok=True)

    def record(self, row: dict, usage: Usage | None) -> None:
        row["usage"] = usage.to_dict() if usage else None
        row["has_usage"] = usage is not None
        append_jsonl(self.ledger, row)
        if usage:
            self.totals[row["tag"]] = self.totals.get(row["tag"], Usage()) + usage

    def body(self, row: dict, request: bytes, response) -> None:
        if self.bodies is None:
            return
        append_jsonl(self.bodies, {"call_id": row["call_id"], "tag": row["tag"], "ts": row["ts"],
                                   "path": row["path"], "status": row["status"],
                                   "request": _json_or_text(request), "response": response})


def _json_or_text(raw: bytes):
    try:
        return json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return raw.decode(errors="replace")


def _maybe_inject(path: str, body: bytes, up: dict) -> tuple[bytes, bool]:
    if not up.get("inject_stream_usage", True) or not path.endswith("/chat/completions"):
        return body, False
    try:
        req = json.loads(body)
    except ValueError:
        return body, False
    if not isinstance(req, dict) or not req.get("stream"):
        return body, False
    opts = req.get("stream_options") or {}
    if opts.get("include_usage"):
        return body, False
    req["stream_options"] = {**opts, "include_usage": True}
    return json.dumps(req).encode(), True


async def handle(request: web.Request) -> web.StreamResponse:
    meter: Meter = request.app["meter"]
    name, tag = request.match_info["upstream"], unquote(request.match_info["tag"])
    up = meter.upstreams.get(name)
    if up is None:
        return web.json_response({"error": f"unknown upstream {name!r}"}, status=404)
    rest = "/" + request.match_info["rest"]
    url = up["url"].rstrip("/") + rest + (f"?{request.query_string}" if request.query_string else "")
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}
    if up.get("key_env"):
        key = os.environ.get(up["key_env"], "")
        headers = {k: v for k, v in headers.items() if k.lower() not in AUTH_HEADERS}
        if up.get("auth", "bearer") == "x-api-key":
            headers["x-api-key"] = key
        else:
            headers["Authorization"] = f"Bearer {key}"
    body = await request.read()
    body, injected = _maybe_inject(rest, body, up)
    req_model = ""
    with contextlib.suppress(ValueError, AttributeError):
        req_model = json.loads(body).get("model", "") if body else ""
    started = time.time()
    row = {"ts": started, "call_id": uuid.uuid4().hex[:16], "tag": tag, "upstream": name,
           "method": request.method, "path": rest, "request_model": req_model,
           "injected_stream_usage": injected}

    session: ClientSession = request.app["client"]
    async with session.request(request.method, url, headers=headers, data=body) as resp:
        ctype = resp.headers.get("Content-Type", "")
        out_headers = {k: v for k, v in resp.headers.items() if k.lower() not in HOP_BY_HOP}
        row["status"] = resp.status
        if "text/event-stream" in ctype:
            out = web.StreamResponse(status=resp.status, headers=out_headers)
            await out.prepare(request)
            su, buf, chunks, client_open = StreamUsage(), b"", [], True
            # Clients may hang up as soon as they read the end marker; keep
            # reading upstream and always log, so a delivered call is counted.
            try:
                async for chunk in resp.content.iter_any():
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        line = line.strip()
                        if not line.startswith(b"data:"):
                            continue
                        data = line[5:].strip()
                        if not data or data == b"[DONE]":
                            continue
                        try:
                            payload = json.loads(data)
                        except ValueError:
                            continue
                        if isinstance(payload, dict):
                            chunks.append(payload)
                            su.feed(payload)
                    if client_open:
                        try:
                            await out.write(chunk)
                        except (ConnectionResetError, RuntimeError):
                            client_open = False
                if client_open:
                    with contextlib.suppress(ConnectionResetError, RuntimeError):
                        await out.write_eof()
            finally:
                usage, raw = su.result()
                row.update(stream=True, model=su.model, ms=int((time.time() - started) * 1000),
                           raw_usage=raw)
                meter.record(row, usage)
                meter.body(row, body, {"stream": chunks})
            return out
        raw = await resp.read()
        usage, raw_usage, model = None, None, ""
        with contextlib.suppress(ValueError, AttributeError, UnicodeDecodeError):
            payload = json.loads(raw)
            model = payload.get("model", "")
            raw_usage = payload.get("usage")
            usage = detect(raw_usage) if raw_usage else None
        row.update(stream=False, model=model, ms=int((time.time() - started) * 1000),
                   raw_usage=raw_usage)
        meter.record(row, usage)
        meter.body(row, body, _json_or_text(raw))
        return web.Response(status=resp.status, headers=out_headers, body=raw)


async def health(request: web.Request) -> web.Response:
    meter: Meter = request.app["meter"]
    return web.json_response({"ok": True, "upstreams": sorted(meter.upstreams),
                              "ledger": str(meter.ledger)})


async def totals(request: web.Request) -> web.Response:
    """Live usage per tag, optionally only tags starting with ?prefix=."""
    meter: Meter = request.app["meter"]
    prefix = request.query.get("prefix", "")
    return web.json_response({t: u.to_dict() for t, u in meter.totals.items() if t.startswith(prefix)})


def make_app(upstreams: dict, ledger: Path, bodies: Path | None) -> web.Application:
    app = web.Application(client_max_size=256 * 1024 * 1024)
    app["meter"] = Meter(upstreams, ledger, bodies)

    async def start(app):
        app["client"] = ClientSession(timeout=ClientTimeout(total=1800), auto_decompress=True)

    async def stop(app):
        await app["client"].close()

    app.on_startup.append(start)
    app.on_cleanup.append(stop)
    app.router.add_get("/__health", health)
    app.router.add_get("/__usage", totals)
    app.router.add_route("*", "/{upstream}/{tag}/{rest:.*}", handle)
    return app


def ledger_usage(ledger: Path, tag_prefix: str = "") -> dict[str, Usage]:
    """Usage per tag, read back from a ledger file."""
    out: dict[str, Usage] = {}
    if not ledger.exists():
        return out
    for line in ledger.read_text(errors="replace").splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not r.get("tag", "").startswith(tag_prefix) or not r.get("usage"):
            continue
        out[r["tag"]] = out.get(r["tag"], Usage()) + Usage.from_dict(r["usage"])
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="agent-bench metering proxy")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8790)
    ap.add_argument("--upstreams", required=True, help="JSON file: {name: {url, key_env?, auth?}}")
    ap.add_argument("--ledger", required=True)
    ap.add_argument("--bodies", action="store_true", help="also log every request and response in full")
    args = ap.parse_args(argv)
    ledger = Path(args.ledger)
    upstreams = json.loads(Path(args.upstreams).read_text())
    bodies = ledger.with_suffix(".bodies.jsonl") if args.bodies else None
    print(f"agent-bench proxy on {args.host}:{args.port}: {', '.join(sorted(upstreams))} -> {ledger}",
          flush=True)
    web.run_app(make_app(upstreams, ledger, bodies), host=args.host, port=args.port, print=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
