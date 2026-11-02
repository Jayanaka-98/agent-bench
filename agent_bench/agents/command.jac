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

import re;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.template { render }
import from agent_bench.trace { Event }
import from agent_bench.agents.base { Agent, Parsed, TurnRequest }

obj Command(Agent) {
    has last_ctx: dict[str, str] = {};

    static has name: str = "command";

    def can_resume -> bool {
        return bool(self.spec.options.get("resume_argv"));
    }

    def command(req: TurnRequest) -> tuple[list[str], str | None] {
        msg_file = req.bdir / "transcripts" / f"{req.seq:02d}-{req.role}.message.md";
        msg_file.write_text(req.message);
        ep = self.endpoint;
        self.last_ctx = {
            "model": self.spec.model, "message_file": str(msg_file), "message": req.message,
            "session": req.session, "ws": str(req.ws), "home": str(self.home or ""),
            "base_url": ep.base_url if ep is not None else "", "key": ep.key if ep is not None else ""
        };
        o = self.spec.options;
        use_resume = req.resume and bool(req.session) and bool(o.get("resume_argv"));
        argv: list[str] = [str(a) for a in (o.get("resume_argv") if use_resume else o["argv"]) or []];
        return ([render(str(a), self.last_ctx) for a in argv], req.message if o.get("stdin") else None);
    }

    def env(base: dict[str, str]) -> dict[str, str] {
        env = dict(base);
        extra: Json = self.spec.options.get("env", {});
        for (k, v) in extra.items() {
            env[k] = render(str(v), self.last_ctx);
        }
        return env;
    }

    def parse(transcript: Path, stderr: str) -> Parsed {
        out = transcript.read_text(errors="replace") if transcript.exists() else "";
        session = "";
        rx = str(self.spec.options.get("session_re", ""));
        if rx {
            m = re.search(rx, out);
            session = m.group(1) if m else "";
        }
        return Parsed(text=out[-8000:], session=session, is_error=not out.strip());
    }

    def events(transcript: Path, role: str, seq: int) -> Iterator[Event] {
        p = self.parse(transcript, "");
        yield Event(`type="final", role=role, seq=seq, text=p.text, session=p.session, is_error=p.is_error);
    }
}
