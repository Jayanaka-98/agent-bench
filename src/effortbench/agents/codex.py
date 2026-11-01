"""OpenAI Codex CLI as a builder: `codex exec --json`.

Facts this relies on (Codex 0.166 source, checked 2026-11-01):
- `codex exec ... -` reads the prompt from stdin; exec never asks for
  approval, and `--dangerously-bypass-approvals-and-sandbox` lifts the sandbox.
- JSON events: thread.started{thread_id}, turn.completed{usage},
  item.completed{item}, turn.failed, error. Items: agent_message, reasoning,
  command_execution, file_change, mcp_tool_call, web_search, todo_list.
- `turn.completed.usage` is the thread's running total, so a resumed thread
  counts once, at its last turn: {input_tokens (incl. cached),
  cached_input_tokens, cache_write_input_tokens, output_tokens,
  reasoning_output_tokens}.
- `codex exec resume <thread_id>` continues a thread.
- The only wire API is Responses: the endpoint's upstream must serve
  `/v1/responses`. There is no Anthropic Messages support.
- `CODEX_HOME` isolates config, auth and session logs; skills are read from
  `.agents/skills`.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator

from ..trace import Event, tool_kind
from ..usage import Usage
from .base import Agent, Parsed, TurnRequest, copy_skills, jsonl


class Codex(Agent):
    name = "codex"
    self_usage_cumulative = True

    def binary(self) -> str:
        return self.spec.options.get("bin", "codex")

    def install(self, ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict, str]:
        self.home = home
        (home / "codex").mkdir(parents=True, exist_ok=True)
        if self.endpoint and self.endpoint.api == "anthropic":
            raise ValueError("codex speaks only the Responses API; give it an OpenAI-compatible endpoint")
        if not skills:
            return {}, ""
        names = copy_skills(skills, ws / ".agents" / "skills")
        return {}, f"<!-- skills installed natively in .agents/skills: {', '.join(names)} -->"

    def env(self, base: dict) -> dict:
        env = dict(base)
        if self.home:
            env["CODEX_HOME"] = str(self.home / "codex")
        if self.endpoint:
            env["EFFORTBENCH_KEY"] = self.endpoint.key
        return env

    def command(self, req: TurnRequest) -> tuple[list[str], str | None]:
        cmd = [self.binary(), "exec"]
        if req.resume and req.session:
            cmd += ["resume", req.session]
        cmd += ["--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check",
                *(["-m", self.spec.model] if self.spec.model else [])]
        if not (req.resume and req.session):
            cmd += ["-C", str(req.ws)]
        if self.endpoint:
            cmd += ["-c", "model_provider=metered", "-c",
                    'model_providers.metered={name="metered",base_url="%s/v1",env_key="EFFORTBENCH_KEY",'
                    'wire_api="responses"}' % self.endpoint.base_url]
        cmd += list(self.spec.options.get("extra_args", [])) + ["-"]
        return cmd, req.message

    def parse(self, transcript: Path, stderr: str) -> Parsed:
        session, text, usage, turns, failed = "", "", None, 0, []
        for ev in jsonl(transcript):
            t = ev.get("type")
            if t == "thread.started":
                session = ev.get("thread_id", session)
            elif t == "turn.completed":
                turns += 1
                u = ev.get("usage") or {}
                cached, write = int(u.get("cached_input_tokens") or 0), int(u.get("cache_write_input_tokens") or 0)
                usage = Usage(input=max(int(u.get("input_tokens") or 0) - cached - write, 0), cache_read=cached,
                              cache_write=write, output=int(u.get("output_tokens") or 0),
                              reasoning=int(u.get("reasoning_output_tokens") or 0))
            elif t in ("turn.failed", "error"):
                failed.append(ev)
            elif t == "item.completed" and (ev.get("item") or {}).get("type") == "agent_message":
                text = ev["item"].get("text", "")
        return Parsed(text=text or (json.dumps(failed[-1]) if failed else stderr[-2000:]), session=session,
                      usage=usage, num_turns=turns, is_error=bool(failed) or not turns,
                      detail={"self_usage_cumulative": True, **({"errors": failed[-3:]} if failed else {})})

    def events(self, transcript: Path, role: str, seq: int) -> Iterator[Event]:
        text, session = "", ""
        for ev in jsonl(transcript):
            t = ev.get("type")
            if t == "thread.started":
                session = ev.get("thread_id", "")
            elif t == "turn.completed":
                yield Event("usage", role, seq, usage=ev.get("usage") or {})
            elif t == "item.completed":
                it = ev.get("item") or {}
                kind, iid = it.get("type", ""), it.get("id", "")
                if kind == "agent_message":
                    text = it.get("text", "")
                    yield Event("message", role, seq, text=text)
                elif kind == "command_execution":
                    yield Event("tool_call", role, seq, tool="command_execution", kind="bash", call_id=iid,
                                input={"command": it.get("command", "")})
                    yield Event("tool_result", role, seq, call_id=iid, output=it.get("aggregated_output", ""),
                                is_error=(it.get("exit_code") not in (0, None)) or it.get("status") == "failed")
                elif kind == "file_change":
                    for ch in it.get("changes") or []:
                        yield Event("tool_call", role, seq, tool="file_change",
                                    kind="write" if ch.get("kind") == "add" else "edit", call_id=iid, input=ch)
                elif kind in ("web_search", "mcp_tool_call", "todo_list"):
                    inp = {k: v for k, v in it.items() if k not in ("id", "type")}
                    yield Event("tool_call", role, seq, tool=kind, kind=tool_kind(kind), call_id=iid, input=inp)
        yield Event("final", role, seq, text=text, session=session)
