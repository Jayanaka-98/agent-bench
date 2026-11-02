"""Claude Code as a builder (and as the driver): `claude -p --output-format stream-json`.

This is the jac-paper harness's `run_claude`, behind the adapter interface:
the same flags, sessions and limit handling.

Options (builder `options` in the experiment):
  bin          the CLI (default `claude`)
  safe_mode    pass --safe-mode (default: on unless skills are installed, which it hides)
  auth         "inherit" (default), "subscription" (drop ANTHROPIC_API_KEY so the
               login pays; through the proxy, its auth passes through) or "api-key"
  extra_args   more CLI arguments
"""

from __future__ import annotations

import os
import re
import uuid
from pathlib import Path
from typing import Iterator

from ..trace import Event, text_of, tool_kind
from ..usage import Usage
from .base import Agent, Parsed, TurnRequest, copy_skills, jsonl


class ClaudeCode(Agent):
    name = "claude-code"
    #: `result.modelUsage` and `total_cost_usd` cover the whole session so far,
    #: so a resumed session counts once, at its last turn.
    self_usage_cumulative = True

    def binary(self) -> str:
        return self.spec.options.get("bin", "claude")

    def install(self, ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict, str]:
        self.home = home
        self.has_skills = bool(skills)
        if not skills:
            return {}, ""
        names = copy_skills(skills, ws / ".claude" / "skills")
        return {}, f"<!-- skills installed natively in .claude/skills: {', '.join(names)} -->"

    def env(self, base: dict) -> dict:
        env = dict(base)
        for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"):
            env.pop(k, None)
        auth = self.spec.options.get("auth", "inherit")
        if auth == "subscription":
            env.pop("ANTHROPIC_API_KEY", None)
        if self.endpoint:
            env["ANTHROPIC_BASE_URL"] = self.endpoint.base_url
            if auth == "api-key":
                env["ANTHROPIC_API_KEY"] = self.endpoint.key
        return env

    def command(self, req: TurnRequest) -> tuple[list[str], str | None]:
        o = self.spec.options
        safe = o.get("safe_mode", not getattr(self, "has_skills", False))
        cmd = [self.binary(), "-p", "--output-format", "stream-json", "--verbose",
               *(["--model", self.spec.model] if self.spec.model else []),
               *(["--safe-mode"] if safe else []),
               "--setting-sources", o.get("setting_sources", "project"), "--strict-mcp-config",
               "--dangerously-skip-permissions"]
        if req.resume and req.session:
            cmd += ["--resume", req.session]
        else:
            req.session = req.session or str(uuid.uuid4())
            cmd += ["--session-id", req.session]
        if req.tools_denied:
            cmd += ["--disallowedTools", *req.tools_denied]
        cmd += list(o.get("extra_args", []))
        return cmd, req.message

    def parse(self, transcript: Path, stderr: str) -> Parsed:
        res, session = None, ""
        for ev in jsonl(transcript):
            session = ev.get("session_id") or session
            if ev.get("type") == "result":
                res = ev
        if not res:
            return Parsed(session=session, text=stderr[-2000:], is_error=True)
        usage = None
        if res.get("modelUsage"):
            usage = Usage()
            for mu in res["modelUsage"].values():
                usage = usage + Usage(input=mu.get("inputTokens", 0), output=mu.get("outputTokens", 0),
                                      cache_read=mu.get("cacheReadInputTokens", 0),
                                      cache_write=mu.get("cacheCreationInputTokens", 0),
                                      reasoning=mu.get("thinkingTokens", 0))
        return Parsed(text=res.get("result", "") or "", session=res.get("session_id", session),
                      usage=usage, cost_usd=res.get("total_cost_usd"), num_turns=res.get("num_turns"),
                      is_error=bool(res.get("is_error", True)),
                      limited=res.get("api_error_status") == 429,
                      detail={"subtype": res.get("subtype"), "duration_api_ms": res.get("duration_api_ms"),
                              "modelUsage": res.get("modelUsage"), "usage": res.get("usage"),
                              "self_usage_cumulative": True})

    def events(self, transcript: Path, role: str, seq: int) -> Iterator[Event]:
        # stream-json repeats an assistant message once per content block, each
        # with the message's usage so far: keep the last usage per message id.
        usage_by_msg: dict[str, tuple[dict, str]] = {}
        order: list[str] = []
        for ev in jsonl(transcript):
            t = ev.get("type")
            msg = ev.get("message") or {}
            if t == "assistant":
                mid = msg.get("id", "")
                if msg.get("usage"):
                    if mid not in usage_by_msg:
                        order.append(mid)
                    usage_by_msg[mid] = (msg["usage"], msg.get("model", ""))
                for b in msg.get("content") or []:
                    if b.get("type") == "text" and b.get("text"):
                        yield Event("message", role, seq, text=b["text"], model=msg.get("model", ""))
                    elif b.get("type") == "tool_use":
                        inp = b.get("input") or {}
                        yield Event("tool_call", role, seq, tool=b.get("name", ""),
                                    kind=tool_kind(b.get("name", ""), inp), call_id=b.get("id", ""),
                                    input=inp)
            elif t == "user":
                for b in msg.get("content") or [] if isinstance(msg.get("content"), list) else []:
                    if b.get("type") == "tool_result":
                        yield Event("tool_result", role, seq, call_id=b.get("tool_use_id", ""),
                                    output=text_of(b.get("content")), is_error=bool(b.get("is_error")))
            elif t == "result":
                for mid in order:
                    u, model = usage_by_msg[mid]
                    yield Event("usage", role, seq, model=model, usage=u)
                order.clear()
                yield Event("final", role, seq, text=ev.get("result", "") or "",
                            session=ev.get("session_id", ""), is_error=bool(ev.get("is_error")))
        for mid in order:  # a turn cut off before its result event
            u, model = usage_by_msg[mid]
            yield Event("usage", role, seq, model=model, usage=u)

    def native_logs(self, ws: Path) -> list[Path]:
        d = Path(os.path.expanduser("~/.claude/projects")) / re.sub(r"[^A-Za-z0-9]", "-", str(ws))
        return [d] if d.exists() else []
