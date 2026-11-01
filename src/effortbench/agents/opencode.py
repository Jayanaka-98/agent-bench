"""OpenCode as a builder: `opencode run --format json --auto`.

Facts this relies on (OpenCode 2.x source, checked 2026-11-01):
- `--auto` approves every permission request; without it a non-interactive
  run rejects them all. Piped stdin is merged into the message.
- JSON lines are `{type, timestamp, sessionID, part}`, `type` one of
  step_start, text, reasoning, tool_use, step_finish, error. Per model call,
  `step_finish.part.tokens = {input, output, reasoning, cache: {read, write}}`
  with `input` excluding cached tokens and `output` excluding reasoning.
- `-s <sessionID>` continues a session.
- Config comes from `OPENCODE_CONFIG_CONTENT` (inline JSON); XDG dirs point
  at the build's own home, and `OPENCODE_DISABLE_CLAUDE_CODE` keeps it from
  reading the user's ~/.claude.
- Skills are discovered in `.opencode/`, `.claude/` and `.agents/`; they are
  installed in `.agents/skills/`.

Options: bin, provider (override the provider id in the model name),
isolate_home (default true), config (extra JSON merged into the config).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator

from ..trace import Event, text_of, tool_kind
from ..usage import Usage
from .base import Agent, Parsed, TurnRequest, copy_skills, jsonl


def deep_merge(a: dict, b: dict) -> dict:
    out = dict(a)
    for k, v in b.items():
        out[k] = deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


class OpenCode(Agent):
    name = "opencode"

    def binary(self) -> str:
        return self.spec.options.get("bin", "opencode")

    def install(self, ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict, str]:
        self.home = home
        for d in ("config", "data", "cache", "state"):
            (home / d).mkdir(parents=True, exist_ok=True)
        if not skills:
            return {}, ""
        names = copy_skills(skills, ws / ".agents" / "skills")
        return {}, f"<!-- skills installed natively in .agents/skills: {', '.join(names)} -->"

    def model_id(self) -> str:
        m = self.spec.model
        ep = self.endpoint
        if "/" in m and not ep:
            return m
        provider = self.spec.options.get("provider") or (
            "anthropic" if ep and ep.api == "anthropic" else "metered")
        return f"{provider}/{m.split('/', 1)[1] if '/' in m and m.split('/', 1)[0] == provider else m}"

    def config(self) -> dict:
        cfg: dict = {"$schema": "https://opencode.ai/config.json", "autoupdate": False, "share": "disabled"}
        ep = self.endpoint
        if ep:
            model = self.model_id().split("/", 1)[1]
            if ep.api == "anthropic":
                cfg["provider"] = {"anthropic": {"options": {"baseURL": ep.base_url + "/v1", "apiKey": ep.key}}}
            else:
                cfg["provider"] = {self.model_id().split("/", 1)[0]: {
                    "npm": "@ai-sdk/openai-compatible", "name": "metered",
                    "options": {"baseURL": ep.base_url + "/v1", "apiKey": ep.key},
                    "models": {model: {"name": model}}}}
        return deep_merge(cfg, self.spec.options.get("config", {}))

    def env(self, base: dict) -> dict:
        env = dict(base)
        h = self.home
        if h:
            env.update({"XDG_CONFIG_HOME": str(h / "config"), "XDG_DATA_HOME": str(h / "data"),
                        "XDG_CACHE_HOME": env.get("XDG_CACHE_HOME", str(h / "cache")),
                        "XDG_STATE_HOME": str(h / "state")})
            if self.spec.options.get("isolate_home", True):
                env["HOME"] = str(h)
        env["OPENCODE_CONFIG_CONTENT"] = json.dumps(self.config())
        env["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
        env["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        if self.endpoint and self.endpoint.api == "anthropic":
            env["ANTHROPIC_API_KEY"] = self.endpoint.key
        return env

    def command(self, req: TurnRequest) -> tuple[list[str], str | None]:
        cmd = [self.binary(), "run", "-m", self.model_id(), "--format", "json", "--auto"]
        if req.resume and req.session:
            cmd += ["-s", req.session]
        cmd += list(self.spec.options.get("extra_args", []))
        # The message goes on stdin: a spec can exceed one argument's size limit.
        return cmd, req.message

    @staticmethod
    def _usage(tokens: dict) -> Usage:
        cache = tokens.get("cache") or {}
        reasoning = int(tokens.get("reasoning") or 0)
        return Usage(input=int(tokens.get("input") or 0), cache_read=int(cache.get("read") or 0),
                     cache_write=int(cache.get("write") or 0),
                     output=int(tokens.get("output") or 0) + reasoning, reasoning=reasoning, calls=1)

    def parse(self, transcript: Path, stderr: str) -> Parsed:
        usage, cost, text, session, errors, steps = Usage(), 0.0, "", "", [], 0
        for ev in jsonl(transcript):
            session = ev.get("sessionID") or session
            part = ev.get("part") or {}
            t = ev.get("type")
            if t == "text" and part.get("text"):
                text = part["text"]
            elif t == "step_finish":
                steps += 1
                usage = usage + self._usage(part.get("tokens") or {})
                cost += float(part.get("cost") or 0)
            elif t == "error":
                errors.append(ev.get("error") or part or ev)
        is_error = bool(errors) or not (text or steps)
        return Parsed(text=text or (json.dumps(errors[-1]) if errors else stderr[-2000:]), session=session,
                      usage=usage if steps else None, cost_usd=round(cost, 6) if steps else None,
                      num_turns=steps, is_error=is_error,
                      detail={"errors": errors[-3:]} if errors else {})

    def events(self, transcript: Path, role: str, seq: int) -> Iterator[Event]:
        text, session = "", ""
        for ev in jsonl(transcript):
            session = ev.get("sessionID") or session
            part = ev.get("part") or {}
            t = ev.get("type")
            if t == "text" and part.get("text"):
                text = part["text"]
                yield Event("message", role, seq, text=part["text"])
            elif t == "tool_use":
                st = part.get("state") or {}
                name = part.get("tool", "")
                inp = st.get("input") or part.get("input") or {}
                cid = part.get("callID") or part.get("id", "")
                yield Event("tool_call", role, seq, tool=name, kind=tool_kind(name, inp), call_id=cid, input=inp)
                if st.get("status") in ("completed", "error") or "output" in st:
                    yield Event("tool_result", role, seq, call_id=cid,
                                output=text_of(st.get("output", st.get("error", ""))),
                                is_error=st.get("status") == "error")
            elif t == "step_finish":
                yield Event("usage", role, seq, usage=part.get("tokens") or {}, model=part.get("modelID", ""))
        yield Event("final", role, seq, text=text, session=session)
