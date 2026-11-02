"""OpenHands as a builder: the `openhands` CLI in headless mode.

Facts this relies on (OpenHands-CLI 1.16 / agent SDK 1.59 source, checked
2026-11-01; the old `python -m openhands.core.main` is gone):
- `openhands --headless --json --override-with-envs -f task.md` runs one task
  and auto-approves. The model comes only from LLM_MODEL / LLM_API_KEY /
  LLM_BASE_URL, and only with `--override-with-envs`. Models are LiteLLM
  names: `anthropic/<m>` for the Messages API, `openai/<m>` for
  OpenAI-compatible endpoints.
- Each JSON line is an event, discriminated by `kind` (ActionEvent,
  ObservationEvent, MessageEvent, ...). The run prints
  `Conversation ID: <hex>` at the end; `--resume <id>` continues it (the CLI
  passes both; not yet checked at run time, so `resume` is off by default).
- Per-call usage is not in the stream; it is in the conversation state
  (`base_state.json`: stats.usage_to_metrics.*.token_usages[]) under
  OPENHANDS_CONVERSATIONS_DIR. The proxy's count is the measure either way.
- Skills are read from `.agents/skills`; user dirs use `~`, so HOME is the
  build's own home.

Options: bin, resume (default false), extra_args.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Iterator

from ..trace import Event, text_of, tool_kind
from ..usage import Usage
from .base import Agent, Parsed, TurnRequest, copy_skills, jsonl

CONV_ID = re.compile(r"Conversation ID:\s*([0-9a-fA-F-]{8,})")


class OpenHands(Agent):
    name = "openhands"

    @property
    def supports_resume(self) -> bool:  # type: ignore[override]
        return bool(self.spec.options.get("resume", False))

    def binary(self) -> str:
        return self.spec.options.get("bin", "openhands")

    def install(self, ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict, str]:
        self.home = home
        (home / ".openhands" / "conversations").mkdir(parents=True, exist_ok=True)
        if not skills:
            return {}, ""
        names = copy_skills(skills, ws / ".agents" / "skills")
        return {}, f"<!-- skills installed natively in .agents/skills: {', '.join(names)} -->"

    def litellm_model(self) -> str:
        m = self.spec.model
        if "/" in m.split(":")[0] and m.split("/", 1)[0] in ("anthropic", "openai", "openrouter", "ollama"):
            return m
        return f"{'anthropic' if self.endpoint and self.endpoint.api == 'anthropic' else 'openai'}/{m}"

    def env(self, base: dict) -> dict:
        env = dict(base)
        if self.home:
            env["HOME"] = str(self.home)
            env["OPENHANDS_PERSISTENCE_DIR"] = str(self.home / ".openhands")
            env["OPENHANDS_CONVERSATIONS_DIR"] = str(self.home / ".openhands" / "conversations")
        env["LLM_MODEL"] = self.litellm_model()
        if self.endpoint:
            env["LLM_API_KEY"] = self.endpoint.key
            # LiteLLM appends /v1/messages for Anthropic; OpenAI-compatible bases include /v1.
            env["LLM_BASE_URL"] = self.endpoint.base_url + ("" if self.endpoint.api == "anthropic" else "/v1")
        return env

    def command(self, req: TurnRequest) -> tuple[list[str], str | None]:
        task = req.bdir / "transcripts" / f"{req.seq:02d}-{req.role}.task.md"
        task.write_text(req.message)
        cmd = [self.binary(), "--headless", "--json", "--override-with-envs"]
        if req.resume and req.session:
            cmd += ["--resume", req.session]
        cmd += ["-f", str(task), *self.spec.options.get("extra_args", [])]
        return cmd, None

    def _state_usage(self, conv: str) -> Usage | None:
        if not self.home or not conv:
            return None
        for state in (self.home / ".openhands" / "conversations").glob(f"{conv}*/base_state.json"):
            try:
                d = json.loads(state.read_text())
            except ValueError:
                continue
            u = Usage()
            for m in ((d.get("stats") or {}).get("usage_to_metrics") or {}).values():
                for t in m.get("token_usages") or []:
                    read, write = int(t.get("cache_read_tokens") or 0), int(t.get("cache_write_tokens") or 0)
                    u = u + Usage(input=max(int(t.get("prompt_tokens") or 0) - read - write, 0), cache_read=read,
                                  cache_write=write, output=int(t.get("completion_tokens") or 0),
                                  reasoning=int(t.get("reasoning_tokens") or 0), calls=1)
            return u
        return None

    def parse(self, transcript: Path, stderr: str) -> Parsed:
        raw = transcript.read_text(errors="replace") if transcript.exists() else ""
        m = CONV_ID.findall(raw + "\n" + stderr)
        conv = m[-1] if m else ""
        text, finished, errors = "", False, []
        for ev in jsonl(transcript):
            k = ev.get("kind", "")
            act = ev.get("action") or {}
            if k == "ActionEvent" and "Finish" in str(act.get("kind", "")):
                text, finished = act.get("message", "") or text, True
            elif k == "MessageEvent" and ev.get("source") == "agent":
                text = text_of((ev.get("llm_message") or {}).get("content")) or text
            elif "Error" in k:
                errors.append(ev)
        return Parsed(text=text or stderr[-2000:], session=conv, usage=self._state_usage(conv),
                      is_error=not (finished or text) or (bool(errors) and not finished),
                      detail={"finished": finished, **({"errors": errors[-3:]} if errors else {})})

    def events(self, transcript: Path, role: str, seq: int) -> Iterator[Event]:
        text = ""
        for ev in jsonl(transcript):
            k = ev.get("kind", "")
            if k == "ActionEvent":
                act = ev.get("action") or {}
                name = ev.get("tool_name") or act.get("kind", "")
                if "Finish" in str(act.get("kind", "")):
                    text = act.get("message", "") or text
                    continue
                inp = {k2: v for k2, v in act.items() if k2 != "kind"}
                yield Event("tool_call", role, seq, tool=name, kind=self._kind(name, act),
                            call_id=ev.get("tool_call_id") or ev.get("id", ""), input=inp)
            elif k == "ObservationEvent":
                obs = ev.get("observation") or {}
                yield Event("tool_result", role, seq, call_id=ev.get("tool_call_id") or ev.get("action_id", ""),
                            output=text_of(obs.get("content", obs.get("output", ""))),
                            is_error=bool(obs.get("is_error") or obs.get("error")))
            elif k == "MessageEvent" and ev.get("source") == "agent":
                t = text_of((ev.get("llm_message") or {}).get("content"))
                if t:
                    text = t
                    yield Event("message", role, seq, text=t)
        yield Event("final", role, seq, text=text)

    @staticmethod
    def _kind(name: str, act: dict) -> str:
        n = name.lower()
        if any(s in n for s in ("terminal", "bash", "cmd", "execute")):
            return "bash"
        if any(s in n for s in ("file_editor", "fileeditor", "str_replace", "edit")):
            return tool_kind("str_replace_editor", act)
        if "task" in n or "think" in n:
            return "plan"
        if "browser" in n or "fetch" in n:
            return "web"
        return tool_kind(name, act)
