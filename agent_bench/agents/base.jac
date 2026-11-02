"""What every builder adapter shares: the process loop, retries, limit waits,
the live token budget, and the invocation record.

An adapter says only what is particular to its agent:

- `install(ws, home, skills, notes)`: put skills and instructions where this
  agent reads them, and give it an isolated config; returns env additions and
  a note on how the skills were delivered (recorded, since delivery differs).
- `command(req)`: the argv (and stdin) for one headless turn.
- `parse(transcript, stderr)`: the turn's final text, session id, self-reported
  usage, error and rate-limit state.
- `events(transcript)`: the native log as trace.Event objects.
"""

import json;
import os;
import re;
import shutil;
import signal;
import subprocess;
import time;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.trace { Event }
import from agent_bench.usage { Usage }

glob LIMIT_RE: re.Pattern = re.compile(
    r"rate.?limit|usage.?limit|session limit|\b429\b|overloaded|limit reached|quota exceeded|insufficient_quota",
    re.I
);

"""One builder in an experiment: which agent, which model, which endpoint."""
obj BuilderSpec {
    has name: str,               # short label used in build ids, e.g. "cc-opus"
        agent: str,              # adapter name
        model: str = "",
        endpoint: str = "",      # proxy upstream; "" = unmetered, the agent's own endpoint
        options: Json = {};
}

"""Where this build's model calls go."""
obj Endpoint {
    has upstream: str,           # proxy upstream name
        api: str,                # "anthropic" | "openai"
        base_url: str,           # proxy URL carrying this build's tag, no API path
        key: str = "metered";    # what the agent presents; the proxy may replace it
}

obj TurnRequest {
    has role: str,
        seq: int,
        ws: Path,
        bdir: Path,
        env: dict[str, str],
        message: str,
        session: str = "",       # "" = start a new session
        resume: bool = False,
        timeout: int = 3 * 3600,
        over_budget: Callable[[], bool] | None = None,
        tools_denied: list[str] = [],
        on_phase: Callable[[str], None] | None = None;   # tells monitors about waits and retries

    def again(message: str, resume: bool, session: str) -> TurnRequest {
        return TurnRequest(
            role=self.role, seq=self.seq, ws=self.ws, bdir=self.bdir, env=self.env, message=message,
            session=session, resume=resume, timeout=self.timeout, over_budget=self.over_budget,
            tools_denied=self.tools_denied, on_phase=self.on_phase
        );
    }
}

obj Parsed {
    has text: str = "",
        session: str = "",
        usage: Usage | None = None,
        cost_usd: float | None = None,
        num_turns: int | None = None,
        is_error: bool = True,
        limited: bool = False,
        detail: Json = {};
}

obj Turn {
    has role: str,
        seq: int,
        attempt: int,
        agent: str,
        model: str,
        session: str,
        resume: bool,
        started: str,
        wall_s: float,
        timed_out: bool,
        over_budget: bool,
        is_error: bool,
        limited: bool,
        num_turns: int | None,
        cost_usd: float | None,
        self_usage: Json | None,
        text: str,
        transcript: str,
        detail: Json = {};

    def row -> Json {
        return {
            "role": self.role, "seq": self.seq, "attempt": self.attempt, "agent": self.agent,
            "model": self.model, "session": self.session, "resume": self.resume, "started": self.started,
            "wall_s": self.wall_s, "timed_out": self.timed_out, "over_budget": self.over_budget,
            "is_error": self.is_error, "limited": self.limited, "num_turns": self.num_turns,
            "cost_usd": self.cost_usd, "self_usage": self.self_usage, "text": self.text,
            "transcript": self.transcript, "detail": self.detail
        };
    }
}

obj Agent {
    has spec: BuilderSpec,
        endpoint: Endpoint | None = None,
        home: Path | None = None,
        has_skills: bool = False;

    static has name: str = "base",
        rate_limit_sleep: int = 15 * 60,
        max_limit_waits: int = 24,
        max_retries: int = 2,
        # A self-report that covers the whole session so far, so a resumed
        # session counts once, at its last turn.
        self_usage_cumulative: bool = False;

    # ---- what adapters implement -------------------------------------------------

    """Whether a follow-up can continue the same conversation. When not, the
    protocol re-sends the task with the feedback, and records that."""
    def can_resume -> bool {
        return True;
    }

    def binary -> str {
        return str(self.spec.options.get("bin") or self.name);
    }

    def version -> str {
        try {
            out = subprocess.run([self.binary(), "--version"], capture_output=True, text=True, timeout=60);
        } except (OSError, subprocess.TimeoutExpired) {
            return "";
        }
        text = (out.stdout or out.stderr or "").strip();
        return text.splitlines()[0] if text else "";
    }

    """Default: skills copied to `.agent-skills/`, named in the prompt."""
    def install(ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict[str, str], str] {
        self.home = home;
        if not skills {
            return ({}, "");
        }
        names = copy_skills(skills, ws / ".agent-skills");
        listed = ", ".join([f"`{n}`" for n in names]);
        return ({}, f"- **Skills.** These skills are in `.agent-skills/`; read a skill's `SKILL.md` when it applies: {listed}.");
    }

    def command(req: TurnRequest) -> tuple[list[str], str | None] {
        raise NotImplementedError(self.name);
    }

    def parse(transcript: Path, stderr: str) -> Parsed {
        raise NotImplementedError(self.name);
    }

    def events(transcript: Path, role: str, seq: int) -> Iterator[Event] {
        return iter([]);
    }

    """Environment for the agent process: the endpoint, and nothing that would
    point it elsewhere."""
    def env(base: dict[str, str]) -> dict[str, str] {
        return dict(base);
    }

    """Directories of the agent's own session files, copied into the build."""
    def native_logs(ws: Path) -> list[Path] {
        return [self.home] if self.home is not None and self.home.exists() else [];
    }

    # ---- the shared loop ---------------------------------------------------------

    """One turn, retried on crashes and waited out on rate limits. Every attempt
    is a row in invocations.jsonl and a transcript file."""
    def run_turn(req: TurnRequest, log: Callable[[str], None] = print) -> Turn {
        attempt = 0;
        tag_n = 0;
        limit_waits = 0;
        message = req.message;
        resume = req.resume;
        session = req.session;
        (req.bdir / "transcripts").mkdir(parents=True, exist_ok=True);
        while True {
            attempt += 1;
            tag_n += 1;
            tag = f"{req.seq:02d}-{req.role}" + (f"-retry{tag_n - 1}" if tag_n > 1 else "");
            out = req.bdir / "transcripts" / f"{tag}.jsonl";
            r = req.again(message, resume, session);
            (argv, stdin) = self.command(r);
            session = r.session or session;  # an adapter may assign the id up front
            started = time.time();
            timed_out = False;
            over = False;
            with out.open("w") as fo {
                with out.with_suffix(".err").open("w") as fe {
                    p = subprocess.Popen(
                        argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                        stdout=fo, stderr=fe, cwd=req.ws, env=self.env(req.env), text=True,
                        start_new_session=True
                    );
                    if stdin is not None and p.stdin is not None {
                        p.stdin.write(stdin);
                        p.stdin.close();
                    }
                    while p.poll() is None {
                        time.sleep(3);
                        if req.over_budget is not None and req.over_budget() {
                            over = True;
                            break;
                        }
                        if time.time() - started > req.timeout {
                            timed_out = True;
                            break;
                        }
                    }
                    if p.poll() is None {
                        kill_tree(p);
                    }
                    p.wait();
                }
            }
            stderr = out.with_suffix(".err").read_text(errors="replace");
            parsed = self.parse(out, stderr);
            if parsed.session {
                session = parsed.session;
            }
            turn = Turn(
                role=req.role, seq=req.seq, attempt=attempt, agent=self.name, model=self.spec.model,
                session=session, resume=resume,
                started=datetime.fromtimestamp(started, timezone.utc).isoformat(),
                wall_s=round(time.time() - started, 1), timed_out=timed_out, over_budget=over,
                is_error=parsed.is_error or timed_out, limited=parsed.limited,
                num_turns=parsed.num_turns, cost_usd=parsed.cost_usd,
                self_usage=parsed.usage.to_dict() if parsed.usage else None,
                text=parsed.text, transcript=str(out.relative_to(req.bdir)), detail=parsed.detail
            );
            with (req.bdir / "invocations.jsonl").open("a") as f {
                f.write(json.dumps(turn.row()) + "\n");
            }
            if over or not turn.is_error {
                return turn;
            }
            if parsed.limited or LIMIT_RE.search(parsed.text + stderr[-2000:]) {
                # Waiting out a limit is not a failed attempt: a window can last hours.
                limit_waits += 1;
                attempt -= 1;
                if limit_waits > self.max_limit_waits {
                    return turn;
                }
                log(f"{req.bdir.name}: {req.role} hit a limit; sleeping {self.rate_limit_sleep // 60} min");
                if req.on_phase is not None {
                    until = datetime.fromtimestamp(time.time() + self.rate_limit_sleep);
                    req.on_phase(f"limit wait until {until:%H:%M} ({limit_waits}/{self.max_limit_waits})");
                }
                time.sleep(self.rate_limit_sleep);
            } elif attempt > self.max_retries or timed_out {
                return turn;
            }
            if req.on_phase is not None {
                req.on_phase(f"{req.role} turn {req.seq} retry {tag_n}");
            }
            if self.can_resume() and session {
                message = "Continue where you left off.";
                resume = True;
            }
        }
    }
}

"""Agents start servers and sub-processes; take the whole group down."""
def kill_tree(p: subprocess.Popen) {
    for sig in (signal.SIGTERM, signal.SIGKILL) {
        try {
            os.killpg(p.pid, sig);
        } except (ProcessLookupError, PermissionError) {
            return;
        }
        try {
            p.wait(timeout=10);
            return;
        } except subprocess.TimeoutExpired {
            continue;
        }
    }
}

"""Copy skill sets into `dest`. Each source is either one skill (has a SKILL.md)
or a directory of skills. Returns the skill names."""
def copy_skills(skills: list[Path], dest: Path) -> list[str] {
    dest.mkdir(parents=True, exist_ok=True);
    names: list[str] = [];
    for src in skills {
        items = [src] if (src / "SKILL.md").exists() else sorted([p for p in src.iterdir() if p.is_dir()]);
        for item in items {
            shutil.copytree(item, dest / item.name, dirs_exist_ok=True);
            names.append(item.name);
        }
    }
    return names;
}

def jsonl(path: Path) -> list[Json] {
    out: list[Json] = [];
    if not path.exists() {
        return out;
    }
    for line in path.read_text(errors="replace").splitlines() {
        line = line.strip();
        if not line.startswith("{") {
            continue;
        }
        try {
            d = json.loads(line);
        } except ValueError {
            continue;
        }
        if isinstance(d, dict) {
            out.append(d as Json);
        }
    }
    return out;
}
