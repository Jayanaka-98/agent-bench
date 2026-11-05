"""A fake model API (Anthropic Messages, OpenAI Chat and Responses, streamed or
not) and helpers to run aiohttp apps in a background thread."""

from __future__ import annotations

import asyncio
import json
import socket
import threading

from aiohttp import web


def _seen(request: web.Request, body: dict) -> dict:
    # Header names lower-cased: clients differ in how they capitalize them.
    return {"path": request.path, "headers": {k.lower(): v for k, v in request.headers.items()}, "body": body}


ANTHROPIC_USAGE = {"input_tokens": 11, "cache_read_input_tokens": 900, "cache_creation_input_tokens": 40,
                   "output_tokens": 1}


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def sse(*payloads) -> bytes:
    return b"".join(b"data: " + json.dumps(p).encode() + b"\n\n" for p in payloads)


async def messages(request: web.Request) -> web.StreamResponse:
    body = await request.json()
    request.app["seen"].append(_seen(request, body))
    if not body.get("stream"):
        return web.json_response({"id": "m1", "model": body["model"], "type": "message",
                                  "content": [{"type": "text", "text": "hi"}],
                                  "usage": {**ANTHROPIC_USAGE, "output_tokens": 5}})
    if body.get("delay"):  # upstream slow to answer: the client may be gone by then
        await asyncio.sleep(float(body["delay"]))
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await resp.prepare(request)
    await resp.write(sse({"type": "message_start", "message": {"model": body["model"], "usage": ANTHROPIC_USAGE}},
                         {"type": "content_block_delta", "delta": {"text": "hi"}},
                         {"type": "message_delta", "usage": {"output_tokens": 25}},
                         {"type": "message_stop"}))
    await resp.write_eof()
    return resp


async def chat(request: web.Request) -> web.StreamResponse:
    body = await request.json()
    request.app["seen"].append(_seen(request, body))
    usage = {"prompt_tokens": 300, "completion_tokens": 20, "prompt_tokens_details": {"cached_tokens": 256}}
    if not body.get("stream"):
        return web.json_response({"model": body["model"], "choices": [{"message": {"content": "ok"}}], "usage": usage})
    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await resp.prepare(request)
    chunks = [{"model": body["model"], "choices": [{"delta": {"content": "ok"}}]}]
    if (body.get("stream_options") or {}).get("include_usage"):
        chunks.append({"model": body["model"], "choices": [], "usage": usage})
    await resp.write(sse(*chunks) + b"data: [DONE]\n\n")
    await resp.write_eof()
    return resp


async def responses(request: web.Request) -> web.StreamResponse:
    body = await request.json()
    request.app["seen"].append(_seen(request, body))
    # `ctype`: an upstream that streams SSE under another Content-Type.
    resp = web.StreamResponse(headers={"Content-Type": body.get("ctype", "text/event-stream")})
    await resp.prepare(request)
    await resp.write(sse({"type": "response.created", "response": {"model": body["model"]}},
                         {"type": "response.completed", "response": {
                             "model": body["model"], "usage": {"input_tokens": 70, "output_tokens": 8,
                                                               "input_tokens_details": {"cached_tokens": 64}}}}))
    await resp.write_eof()
    return resp


def fake_api() -> web.Application:
    app = web.Application()
    app["seen"] = []
    app.router.add_post("/v1/messages", messages)
    app.router.add_post("/v1/chat/completions", chat)
    app.router.add_post("/v1/responses", responses)
    return app


class Served:
    """Run aiohttp apps on a background event loop."""

    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.runners = []

    def serve(self, app: web.Application, port: int) -> str:
        async def go():
            runner = web.AppRunner(app)
            await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", port).start()
            self.runners.append(runner)
        asyncio.run_coroutine_threadsafe(go(), self.loop).result(10)
        return f"http://127.0.0.1:{port}"

    def close(self) -> None:
        async def stop():
            for r in self.runners:
                await r.cleanup()
        asyncio.run_coroutine_threadsafe(stop(), self.loop).result(10)
        self.loop.call_soon_threadsafe(self.loop.stop)
