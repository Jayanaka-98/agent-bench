"""The token meter: one reverse proxy in front of every model API a builder uses.

Agents count their own tokens differently (cache semantics, side calls for
titles or summaries, sub-agents), so their self-reports are not comparable.
Every builder is instead pointed at this proxy, which records each call's usage
from the API's own response, in one normalized form (usage.jac).

A builder's base URL names the upstream and the build, so one proxy serves many
builds at once with no shared marker to race on:

    http://127.0.0.1:<port>/<upstream>/<tag>/<the API path as the client sends it>

e.g. `ANTHROPIC_BASE_URL=http://127.0.0.1:8790/anthropic/meeting__jac__cc__r1.builder`.
Claude Code appends `/v1/messages`; that path goes to the `anthropic` upstream.

Upstreams are `{name: {"url": ..., "key_env": ..., "auth": ...}}`:

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
  <ledger>.bodies.jsonl  (with bodies on) the request and the response, every chunk of a stream

    jac run agent_bench/proxy.jac --port 8790 --upstreams up.json --ledger runs/x/ledger.jsonl
"""

import argparse;
import asyncio;
import json;
import os;
import threading;
import time;
import uuid;
import from pathlib { Path }
import from urllib.parse { unquote }
import from aiohttp { ClientSession, ClientTimeout, web }
import from agent_bench.common { Json }
import from agent_bench.usage { Usage, detect, merge_anthropic_stream }

glob HOP_BY_HOP: set[str] = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
    "trailers", "transfer-encoding", "upgrade", "host", "content-length",
    # aiohttp hands over the decompressed body, so the upstream's encoding
    # header must not reach the client.
    "content-encoding"
};
glob AUTH_HEADERS: set[str] = {"authorization", "x-api-key"};
# The client hung up or was killed: aiohttp raises ClientConnectionResetError (a
# ConnectionResetError) or a RuntimeError on writing to the closed transport.
glob CLIENT_GONE: tuple[type[Exception], type[Exception]] = (ConnectionError, RuntimeError);
glob _write_lock: threading.Lock = threading.Lock();

def append_jsonl(path: Path, row: Json) {
    with _write_lock {
        with path.open("a") as f {
            f.write(json.dumps(row, ensure_ascii=False) + "\n");
        }
    }
}

"""Usage scanned out of SSE payloads, for either API family."""
obj StreamUsage {
    has anthropic_start: Json = {},
        anthropic_delta: Json = {},
        raw: Json | None = None,
        model: str = "";

    def feed(p: Json) {
        t = str(p.get("type", ""));
        if t == "message_start" {
            msg: Json = p.get("message") or {};
            self.model = str(msg.get("model", self.model));
            self.anthropic_start = msg.get("usage") or {};
        } elif t == "message_delta" and p.get("usage") {
            self.anthropic_delta = p["usage"];
        } elif t in ("response.completed", "response.incomplete", "response.failed") {
            r: Json = p.get("response") or {};
            self.model = str(r.get("model", self.model));
            self.raw = r.get("usage") or self.raw;
        } elif isinstance(p.get("usage"), dict) {
            self.model = str(p.get("model", self.model));
            self.raw = p["usage"];
        } elif p.get("model") {
            self.model = str(p["model"]);
        }
    }

    def result -> tuple[Usage | None, Json | None] {
        if self.anthropic_start or self.anthropic_delta {
            raw: Json = dict(self.anthropic_start);
            for (k, v) in self.anthropic_delta.items() {
                if v is not None {
                    raw[k] = v;
                }
            }
            return (merge_anthropic_stream(self.anthropic_start, self.anthropic_delta), raw);
        }
        if self.raw {
            return (detect(self.raw), self.raw);
        }
        return (None, None);
    }
}

obj Meter {
    has upstreams: dict[str, Json],
        ledger: Path,
        bodies: Path | None = None,
        totals: dict[str, Usage] = {};

    def postinit {
        self.ledger.parent.mkdir(parents=True, exist_ok=True);
    }

    def record(row: Json, usage: Usage | None) {
        row["usage"] = usage.to_dict() if usage else None;
        row["has_usage"] = usage is not None;
        append_jsonl(self.ledger, row);
        if usage {
            tag = str(row["tag"]);
            self.totals[tag] = self.totals.get(tag, Usage()) + usage;
        }
    }

    def body(row: Json, request: bytes, response: any) {
        if self.bodies is None {
            return;
        }
        append_jsonl(self.bodies, {
            "call_id": row["call_id"], "tag": row["tag"], "ts": row["ts"], "path": row["path"],
            "status": row["status"], "request": _json_or_text(request), "response": response
        });
    }
}

"""A JSON response. (Written out: referencing aiohttp's `web.json_response`
makes this jac version's code generation fail silently.)"""
def json_reply(data: any, status: int = 200) -> web.Response {
    return web.Response(text=json.dumps(data), status=status, content_type="application/json");
}

def _json_or_text(raw: bytes) -> any {
    try {
        return json.loads(raw);
    } except (ValueError, UnicodeDecodeError) {
        return raw.decode(errors="replace");
    }
}

def _maybe_inject(path: str, body: bytes, up: Json) -> tuple[bytes, bool] {
    if not up.get("inject_stream_usage", True) or not path.endswith("/chat/completions") {
        return (body, False);
    }
    try {
        req = json.loads(body);
    } except ValueError {
        return (body, False);
    }
    if not isinstance(req, dict) {
        return (body, False);
    }
    rq = req as Json;
    if not rq.get("stream") {
        return (body, False);
    }
    opts: Json = rq.get("stream_options") or {};
    if opts.get("include_usage") {
        return (body, False);
    }
    rq["stream_options"] = {**opts, "include_usage": True};
    return (json.dumps(rq).encode(), True);
}

def _request_model(body: bytes) -> str {
    if not body {
        return "";
    }
    try {
        d = json.loads(body);
    } except (ValueError, UnicodeDecodeError) {
        return "";
    }
    return str((d as Json).get("model", "")) if isinstance(d, dict) else "";
}

"""Whether the client asked for a stream (`"stream": true` in a JSON body)."""
def _request_stream(body: bytes) -> bool {
    if not body {
        return False;
    }
    try {
        d = json.loads(body);
    } except (ValueError, UnicodeDecodeError) {
        return False;
    }
    return isinstance(d, dict) and (d as Json).get("stream") is True;
}

"""Usage from a whole SSE body, for an upstream that streams without saying
so in its Content-Type (the ChatGPT Codex backend)."""
def _sse_usage(raw: bytes) -> tuple[StreamUsage, list[Json]] | None {
    head = raw.lstrip()[:16];
    if not (head.startswith(b"event:") or head.startswith(b"data:")) {
        return None;
    }
    su = StreamUsage();
    chunks: list[Json] = [];
    for line in raw.split(b"\n") {
        line = line.strip();
        if not line.startswith(b"data:") {
            continue;
        }
        data = line[5:].strip();
        if not data or data == b"[DONE]" {
            continue;
        }
        try {
            payload = json.loads(data);
        } except ValueError {
            continue;
        }
        if isinstance(payload, dict) {
            chunks.append(payload as Json);
            su.feed(payload as Json);
        }
    }
    return (su, chunks);
}

async def handle(request: any) -> any {
    meter = request.app["meter"] as Meter;
    name = str(request.match_info["upstream"]);
    tag = unquote(str(request.match_info["tag"]));
    up = meter.upstreams.get(name);
    if up is None {
        return json_reply({"error": f"unknown upstream {name!r}"}, status=404);
    }
    rest = "/" + str(request.match_info["rest"]);
    qs = str(request.query_string);
    url = str(up["url"]).rstrip("/") + rest + (f"?{qs}" if qs else "");
    headers: dict[str, str] = {};
    for (k, v) in request.headers.items() {
        if str(k).lower() not in HOP_BY_HOP {
            headers[str(k)] = str(v);
        }
    }
    if up.get("key_env") {
        key = os.environ.get(str(up["key_env"]), "");
        headers = {k: v for (k, v) in headers.items() if k.lower() not in AUTH_HEADERS};
        if up.get("auth", "bearer") == "x-api-key" {
            headers["x-api-key"] = key;
        } else {
            headers["Authorization"] = f"Bearer {key}";
        }
    }
    raw_body = (await request.read()) as bytes;
    (body, injected) = _maybe_inject(rest, raw_body, up);
    started = time.time();
    row: Json = {
        "ts": started, "call_id": uuid.uuid4().hex[:16], "tag": tag, "upstream": name,
        "method": str(request.method), "path": rest, "request_model": _request_model(body),
        "injected_stream_usage": injected
    };
    session = request.app["client"] as ClientSession;
    async with session.request(str(request.method), url, headers=headers, data=body) as resp {
        # aiohttp's `headers` is a reified property the checker reads as a method.
        resp_headers = resp.headers as dict[str, str];
        ctype = str(resp_headers.get("Content-Type", ""));
        out_headers: dict[str, str] = {};
        for (k, v) in resp_headers.items() {
            if str(k).lower() not in HOP_BY_HOP {
                out_headers[str(k)] = str(v);
            }
        }
        row["status"] = resp.status;
        # Some upstreams stream SSE under another Content-Type; a request that
        # asked for a stream with a 2xx answer is treated as one.
        if "text/event-stream" in ctype or (_request_stream(body) and 200 <= resp.status < 300) {
            out = web.StreamResponse(status=resp.status, headers=out_headers);
            su = StreamUsage();
            buf = b"";
            chunks: list[Json] = [];
            client_open = True;
            # Clients may hang up as soon as they read the end marker, or be
            # killed mid-call (the budget stop): keep reading upstream and
            # always log, so a call the API answered is counted, and say
            # nothing about the client being gone.
            try {
                try {
                    await out.prepare(request);
                } except CLIENT_GONE {
                    client_open = False;
                }
                async for chunk in resp.content.iter_any() {
                    piece = chunk as bytes;
                    buf += piece;
                    while b"\n" in buf {
                        (line, buf) = buf.split(b"\n", 1);
                        line = line.strip();
                        if not line.startswith(b"data:") {
                            continue;
                        }
                        data = line[5:].strip();
                        if not data or data == b"[DONE]" {
                            continue;
                        }
                        try {
                            payload = json.loads(data);
                        } except ValueError {
                            continue;
                        }
                        if isinstance(payload, dict) {
                            chunks.append(payload as Json);
                            su.feed(payload as Json);
                        }
                    }
                    if client_open {
                        try {
                            await out.write(piece);
                        } except CLIENT_GONE {
                            client_open = False;
                        }
                    }
                }
                if client_open {
                    try {
                        await out.write_eof();
                    } except CLIENT_GONE {}
                }
            } finally {
                (usage, raw) = su.result();
                row.update({"stream": True, "model": su.model, "ms": int((time.time() - started) * 1000),
                            "raw_usage": raw});
                meter.record(row, usage);
                meter.body(row, body, {"stream": chunks});
            }
            return out;
        }
        resp_raw = (await resp.read()) as bytes;
        usage: Usage | None = None;
        raw_usage: any = None;
        model = "";
        sse = _sse_usage(resp_raw);
        if sse is not None {
            (su2, chunks2) = sse;
            (usage, raw_usage) = su2.result();
            row.update({"stream": True, "model": su2.model, "ms": int((time.time() - started) * 1000),
                        "raw_usage": raw_usage});
            meter.record(row, usage);
            meter.body(row, body, {"stream": chunks2});
            return web.Response(status=resp.status, headers=out_headers, body=resp_raw);
        }
        try {
            payload = json.loads(resp_raw);
            if isinstance(payload, dict) {
                pd = payload as Json;
                model = str(pd.get("model", ""));
                raw_usage = pd.get("usage");
                usage = detect(raw_usage) if raw_usage else None;
            }
        } except (ValueError, UnicodeDecodeError) {}
        row.update({"stream": False, "model": model, "ms": int((time.time() - started) * 1000),
                    "raw_usage": raw_usage});
        meter.record(row, usage);
        meter.body(row, body, _json_or_text(resp_raw));
        return web.Response(status=resp.status, headers=out_headers, body=resp_raw);
    }
}

async def health(request: any) -> any {
    meter = request.app["meter"] as Meter;
    return json_reply({"ok": True, "upstreams": sorted(meter.upstreams), "ledger": str(meter.ledger)});
}

"""Live usage per tag, optionally only tags starting with ?prefix=."""
async def totals(request: any) -> any {
    meter = request.app["meter"] as Meter;
    prefix = str(request.query.get("prefix", ""));
    return json_reply({t: u.to_dict() for (t, u) in meter.totals.items() if t.startswith(prefix)});
}

async def _start_client(app: any) {
    app["client"] = ClientSession(timeout=ClientTimeout(total=1800), auto_decompress=True);
}

async def _stop_client(app: any) {
    await (app["client"] as ClientSession).close();
}

def make_app(upstreams: dict[str, Json], ledger: Path, bodies: Path | None) -> web.Application {
    app = web.Application(client_max_size=256 * 1024 * 1024);
    app["meter"] = Meter(upstreams=upstreams, ledger=ledger, bodies=bodies);
    app.on_startup.append(_start_client as any);
    app.on_cleanup.append(_stop_client as any);
    app.router.add_get("/__health", health as any);
    app.router.add_get("/__usage", totals as any);
    app.router.add_route("*", "/{upstream}/{tag}/{rest:.*}", handle as any);
    return app;
}

"""Usage per tag, read back from a ledger file."""
def ledger_usage(ledger: Path, tag_prefix: str = "") -> dict[str, Usage] {
    out: dict[str, Usage] = {};
    if not ledger.exists() {
        return out;
    }
    for line in ledger.read_text(errors="replace").splitlines() {
        try {
            r = json.loads(line);
        } except ValueError {
            continue;
        }
        if not isinstance(r, dict) {
            continue;
        }
        rd = r as Json;
        tag = str(rd.get("tag", ""));
        if not tag.startswith(tag_prefix) or not rd.get("usage") {
            continue;
        }
        out[tag] = out.get(tag, Usage()) + Usage.from_dict(rd["usage"]);
    }
    return out;
}

"""The proxy on a background thread with its own event loop: how the runner
hosts it, so a run needs no second process."""
obj ThreadedProxy {
    has upstreams: dict[str, Json],
        ledger: Path,
        host: str = "127.0.0.1",
        port: int = 8790,
        bodies: bool = True,
        loop: any = None,
        runner: any = None,
        thread: threading.Thread | None = None;

    def start {
        ready = threading.Event();
        errors: list[str] = [];
        self.loop = asyncio.new_event_loop();
        app = make_app(self.upstreams, self.ledger, self.ledger.with_suffix(".bodies.jsonl") if self.bodies else None);

        async def boot {
            self.runner = web.AppRunner(app);
            await self.runner.setup();
            await web.TCPSite(self.runner, self.host, self.port).start();
        }

        def serve {
            asyncio.set_event_loop(self.loop);
            try {
                self.loop.run_until_complete(boot());
            } except OSError as e {
                errors.append(str(e));
                ready.set();
                return;
            }
            ready.set();
            self.loop.run_forever();
        }

        self.thread = threading.Thread(target=serve, daemon=True, name="agent-bench-proxy");
        self.thread.start();
        ready.wait(30);
        if errors {
            raise RuntimeError(f"proxy could not start on {self.host}:{self.port}: {errors[0]}");
        }
    }

    def stop {
        if self.loop is None {
            return;
        }
        if self.runner is not None {
            asyncio.run_coroutine_threadsafe(self.runner.cleanup(), self.loop).result(15);
        }
        self.loop.call_soon_threadsafe(self.loop.stop);
        if self.thread is not None {
            self.thread.join(15);
        }
    }
}

def main(argv: list[str] | None = None) -> int {
    ap = argparse.ArgumentParser(description="agent-bench metering proxy");
    ap.add_argument("--host", `default="127.0.0.1");
    ap.add_argument("--port", type=int, `default=8790);
    ap.add_argument("--upstreams", required=True, help="JSON file: {name: {url, key_env?, auth?}}");
    ap.add_argument("--ledger", required=True);
    ap.add_argument("--bodies", action="store_true", help="also log every request and response in full");
    a = ap.parse_args(argv);
    ledger = Path(a.ledger);
    upstreams = json.loads(Path(a.upstreams).read_text()) as dict[str, Json];
    bodies = ledger.with_suffix(".bodies.jsonl") if a.bodies else None;
    print(f"agent-bench proxy on {a.host}:{a.port}: {', '.join(sorted(upstreams))} -> {ledger}", flush=True);
    web.run_app(make_app(upstreams, ledger, bodies), host=a.host, port=a.port, print=None);
    return 0;
}

with entry:__main__ {
    import sys;
    raise SystemExit(main(sys.argv[1:]));
}
