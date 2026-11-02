"""Any CLI as a builder, configured rather than coded.

For an agent without a dedicated adapter. It is metered like any other (its
model calls go through the proxy), but its trace holds only the final message,
so the tool-call analyzers see nothing.

    [[builders]]
    name = "aider-sonnet"
    agent = "command"
    model = "anthropic/claude-sonnet-5-5"
    endpoint = "anthropic"
    [builders.options]
    argv = ["aider", "--yes-always", "--no-git", "--model", "${model}", "--message-file", "${message_file}"]
    env = { ANTHROPIC_BASE_URL = "${base_url}", ANTHROPIC_API_KEY = "${key}" }
    session_re = ''      # optional: a regex whose group 1 is a session id in stdout
    resume_argv = []     # optional: argv for a follow-up in the same session
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterator

from ..config import render
from ..trace import Event
from .base import Agent, Parsed, TurnRequest


class Command(Agent):
    name = "command"

    @property
    def supports_resume(self) -> bool:  # type: ignore[override]
        return bool(self.spec.options.get("resume_argv"))

    def _ctx(self, req: TurnRequest, msg_file: Path) -> dict:
        ep = self.endpoint
        return {"model": self.spec.model, "message_file": str(msg_file), "message": req.message,
                "session": req.session, "ws": str(req.ws), "home": str(self.home or ""),
                "base_url": ep.base_url if ep else "", "key": ep.key if ep else ""}

    def command(self, req: TurnRequest) -> tuple[list[str], str | None]:
        msg_file = req.bdir / "transcripts" / f"{req.seq:02d}-{req.role}.message.md"
        msg_file.write_text(req.message)
        self._last_ctx = self._ctx(req, msg_file)
        o = self.spec.options
        argv = o.get("resume_argv") if req.resume and req.session and o.get("resume_argv") else o["argv"]
        return [render(a, self._last_ctx) for a in argv], (req.message if o.get("stdin") else None)

    def env(self, base: dict) -> dict:
        env = dict(base)
        for k, v in self.spec.options.get("env", {}).items():
            env[k] = render(v, getattr(self, "_last_ctx", {}))
        return env

    def parse(self, transcript: Path, stderr: str) -> Parsed:
        out = transcript.read_text(errors="replace") if transcript.exists() else ""
        session = ""
        if self.spec.options.get("session_re"):
            m = re.search(self.spec.options["session_re"], out)
            session = m.group(1) if m else ""
        return Parsed(text=out[-8000:], session=session, is_error=not out.strip())

    def events(self, transcript: Path, role: str, seq: int) -> Iterator[Event]:
        p = self.parse(transcript, "")
        yield Event("final", role, seq, text=p.text, session=p.session, is_error=p.is_error)
