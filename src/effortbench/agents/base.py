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

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterator

from ..trace import Event
from ..usage import Usage

LIMIT_RE = re.compile(r"rate.?limit|usage.?limit|session limit|\b429\b|overloaded|limit reached|"
                      r"quota exceeded|insufficient_quota", re.I)


@dataclass
class BuilderSpec:
    """One builder in an experiment: which agent, which model, which endpoint."""
    name: str                 # short label used in build ids, e.g. "cc-opus"
    agent: str                # adapter name
    model: str = ""
    endpoint: str = ""        # proxy upstream; "" = unmetered, the agent's own endpoint
    options: dict = field(default_factory=dict)


@dataclass
class Endpoint:
    """Where this build's model calls go."""
    upstream: str             # proxy upstream name
    api: str                  # "anthropic" | "openai"
    base_url: str             # proxy URL carrying this build's tag, no API path
    key: str = "metered"      # what the agent presents; the proxy may replace it


@dataclass
class TurnRequest:
    role: str
    seq: int
    ws: Path
    bdir: Path
    env: dict
    message: str
    session: str = ""         # "" = start a new session
    resume: bool = False
    timeout: int = 3 * 3600
    over_budget: Callable[[], bool] | None = None
    tools_denied: list[str] = field(default_factory=list)
    on_phase: Callable[[str], None] | None = None   # tells monitors about waits and retries


@dataclass
class Parsed:
    text: str = ""
    session: str = ""
    usage: Usage | None = None
    cost_usd: float | None = None
    num_turns: int | None = None
    is_error: bool = True
    limited: bool = False
    detail: dict = field(default_factory=dict)


@dataclass
class Turn:
    role: str
    seq: int
    attempt: int
    agent: str
    model: str
    session: str
    resume: bool
    started: str
    wall_s: float
    timed_out: bool
    over_budget: bool
    is_error: bool
    limited: bool
    num_turns: int | None
    cost_usd: float | None
    self_usage: dict | None
    text: str
    transcript: str
    detail: dict = field(default_factory=dict)

    def row(self) -> dict:
        return asdict(self)


class Agent:
    name = "base"
    #: Whether a follow-up can continue the same conversation. When not, the
    #: protocol re-sends the task with the feedback, and records that.
    supports_resume = True
    rate_limit_sleep = 15 * 60
    max_limit_waits = 24
    max_retries = 2

    def __init__(self, spec: BuilderSpec, endpoint: Endpoint | None = None) -> None:
        self.spec = spec
        self.endpoint = endpoint
        self.home: Path | None = None

    # ---- what adapters implement -------------------------------------------------

    def binary(self) -> str:
        return self.spec.options.get("bin") or self.name

    def version(self) -> str:
        try:
            out = subprocess.run([self.binary(), "--version"], capture_output=True, text=True, timeout=60)
            return (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr) else ""
        except (OSError, subprocess.TimeoutExpired, IndexError):
            return ""

    def install(self, ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict, str]:
        """Default: skills copied to `.agent-skills/`, named in the prompt."""
        self.home = home
        if not skills:
            return {}, ""
        dest = ws / ".agent-skills"
        names = copy_skills(skills, dest)
        return {}, ("- **Skills.** These skills are in `.agent-skills/`; read a skill's "
                    "`SKILL.md` when it applies: " + ", ".join(f"`{n}`" for n in names) + ".")

    def command(self, req: TurnRequest) -> tuple[list[str], str | None]:
        raise NotImplementedError

    def parse(self, transcript: Path, stderr: str) -> Parsed:
        raise NotImplementedError

    def events(self, transcript: Path, role: str, seq: int) -> Iterator[Event]:
        return iter(())

    def env(self, base: dict) -> dict:
        """Environment for the agent process: the endpoint, and nothing that
        would point it elsewhere."""
        return dict(base)

    def native_logs(self, ws: Path) -> list[Path]:
        """Directories of the agent's own session files, copied into the build."""
        return [self.home] if self.home and self.home.exists() else []

    # ---- the shared loop ---------------------------------------------------------

    def run_turn(self, req: TurnRequest, log: Callable[[str], None] = print) -> Turn:
        """One turn, retried on crashes and waited out on rate limits. Every
        attempt is a row in invocations.jsonl and a transcript file."""
        attempt = tag_n = limit_waits = 0
        message, resume, session = req.message, req.resume, req.session
        (req.bdir / "transcripts").mkdir(parents=True, exist_ok=True)
        while True:
            attempt += 1
            tag_n += 1
            tag = f"{req.seq:02d}-{req.role}" + (f"-retry{tag_n - 1}" if tag_n > 1 else "")
            out = req.bdir / "transcripts" / f"{tag}.jsonl"
            r = TurnRequest(**{**req.__dict__, "message": message, "resume": resume, "session": session})
            argv, stdin = self.command(r)
            session = r.session or session  # an adapter may assign the id up front
            started = time.time()
            timed_out = over = False
            with out.open("w") as fo, out.with_suffix(".err").open("w") as fe:
                p = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                     stdout=fo, stderr=fe, cwd=req.ws, env=self.env(req.env), text=True,
                                     start_new_session=True)
                if stdin is not None:
                    p.stdin.write(stdin)
                    p.stdin.close()
                while p.poll() is None:
                    time.sleep(3)
                    if req.over_budget and req.over_budget():
                        over = True
                        break
                    if time.time() - started > req.timeout:
                        timed_out = True
                        break
                if p.poll() is None:
                    kill_tree(p)
                p.wait()
            stderr = out.with_suffix(".err").read_text(errors="replace")
            parsed = self.parse(out, stderr)
            if parsed.session:
                session = parsed.session
            turn = Turn(
                role=req.role, seq=req.seq, attempt=attempt, agent=self.name, model=self.spec.model,
                session=session, resume=resume,
                started=datetime.fromtimestamp(started, timezone.utc).isoformat(),
                wall_s=round(time.time() - started, 1), timed_out=timed_out, over_budget=over,
                is_error=parsed.is_error or timed_out, limited=parsed.limited,
                num_turns=parsed.num_turns, cost_usd=parsed.cost_usd,
                self_usage=parsed.usage.to_dict() if parsed.usage else None,
                text=parsed.text, transcript=str(out.relative_to(req.bdir)), detail=parsed.detail)
            with (req.bdir / "invocations.jsonl").open("a") as f:
                f.write(json.dumps(turn.row()) + "\n")
            if over or not turn.is_error:
                return turn
            if parsed.limited or LIMIT_RE.search(parsed.text + stderr[-2000:]):
                # Waiting out a limit is not a failed attempt: a window can last hours.
                limit_waits += 1
                attempt -= 1
                if limit_waits > self.max_limit_waits:
                    return turn
                log(f"{req.bdir.name}: {req.role} hit a limit; sleeping {self.rate_limit_sleep // 60} min")
                if req.on_phase:
                    until = datetime.fromtimestamp(time.time() + self.rate_limit_sleep)
                    req.on_phase(f"limit wait until {until:%H:%M} ({limit_waits}/{self.max_limit_waits})")
                time.sleep(self.rate_limit_sleep)
            elif attempt > self.max_retries or timed_out:
                return turn
            if req.on_phase:
                req.on_phase(f"{req.role} turn {req.seq} retry {tag_n}")
            if self.supports_resume and session:
                message, resume = "Continue where you left off.", True


def kill_tree(p: subprocess.Popen) -> None:
    """Agents start servers and sub-processes; take the whole group down."""
    import signal
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            p.wait(timeout=10)
            return
        except subprocess.TimeoutExpired:
            continue


def copy_skills(skills: list[Path], dest: Path) -> list[str]:
    """Copy skill sets into `dest`. Each source is either one skill (has a
    SKILL.md) or a directory of skills. Returns the skill names."""
    dest.mkdir(parents=True, exist_ok=True)
    names = []
    for src in skills:
        src = Path(src)
        items = [src] if (src / "SKILL.md").exists() else sorted(p for p in src.iterdir() if p.is_dir())
        for item in items:
            shutil.copytree(item, dest / item.name, dirs_exist_ok=True)
            names.append(item.name)
    return names


def jsonl(path: Path) -> Iterator[dict]:
    if not path.exists():
        return
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue
