"""What is running right now, across every run: the data behind the monitor screen.

Read incrementally, so a refresh every couple of seconds stays cheap with many
parallel builds and multi-megabyte transcripts:

- proxy ledgers are tailed from a saved byte offset (`LedgerTail`);
- a running build's current activity comes from the last ~256 KB of its
  newest transcript, read through its own adapter;
- finished summaries are read once and cached by mtime.

A build's state comes from files the harness writes as it goes: `build.json`
(who is building), `live.json` (its phase: a turn, acceptance, a limit wait),
`summary.json` (done), and the run's `plan.json` and `runner.pid`.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from . import agents
from . import trace as tr
from .agents.base import BuilderSpec

TAIL_BYTES = 256 * 1024
FEED_MAX = 2000
RATE_WINDOW = 60 * 60
STALE_RUN = 24 * 3600


def runner_alive(run_dir: Path) -> bool:
    pid = run_dir / "runner.pid"
    if not pid.exists():
        return False
    try:
        os.kill(int(pid.read_text().strip()), 0)
        return True
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:  # alive, another user's
        return True


class LedgerTail:
    """A proxy ledger, read from where the last poll stopped."""

    def __init__(self, path: Path) -> None:
        self.path, self.offset = path, 0
        self.per_build: dict[str, dict] = {}       # proxy tag (build~nonce) → total, calls, last
        self.recent: deque[tuple[float, int]] = deque()

    def poll(self) -> None:
        if not self.path.exists():
            return
        size = self.path.stat().st_size
        if size < self.offset:  # rotated or rewritten
            self.offset, self.per_build = 0, {}
        if size == self.offset:
            return
        with self.path.open("rb") as f:
            f.seek(self.offset)
            chunk = f.read()
        end = chunk.rfind(b"\n") + 1
        self.offset += end
        for line in chunk[:end].splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            u = r.get("usage")
            if not u:
                continue
            key = r.get("tag", "").rsplit(".", 1)[0]
            b = self.per_build.setdefault(key, {"total": 0, "calls": 0, "last": 0.0})
            b["total"] += u.get("total", 0)
            b["calls"] += 1
            b["last"] = max(b["last"], r.get("ts", 0))
            self.recent.append((r.get("ts", 0), u.get("total", 0)))
        cutoff = time.time() - RATE_WINDOW
        while self.recent and self.recent[0][0] < cutoff:
            self.recent.popleft()


@dataclass
class Running:
    run: str
    build: str
    dir: Path
    agent: str
    model: str
    phase: str
    phase_s: float
    tokens: int
    calls: int
    quiet_s: float
    action: str
    state: str          # running | stopped


@dataclass
class Snapshot:
    runs: list[dict] = field(default_factory=list)
    running: list[Running] = field(default_factory=list)
    recent: list[dict] = field(default_factory=list)
    feed: list[tuple[str, tr.Event]] = field(default_factory=list)   # new since the last scan
    rate: list[int] = field(default_factory=list)                    # tokens per minute, oldest first
    counts: dict = field(default_factory=dict)
    disk_free_gb: float = 0.0


def _short(build: str) -> str:
    """task__arm__builder__rK → task/arm/builder/rK, for narrow columns."""
    return build.replace("__", "/")


def action_text(e: tr.Event) -> str:
    if e.type == "tool_call":
        arg = (e.input.get("command") or e.input.get("file_path") or e.input.get("path")
               or e.input.get("pattern") or e.input.get("skill") or json.dumps(e.input))
        return f"{e.tool}: {str(arg).strip()}"
    if e.type == "message":
        return "“" + (e.text or "").strip() + "”"
    if e.type == "final":
        return "■ " + (e.text or "").strip()
    return ""


class Monitor:
    def __init__(self, runs_dirs: list[Path]) -> None:
        self.runs_dirs = runs_dirs
        self.ledgers: dict[Path, LedgerTail] = {}
        self.summaries: dict[Path, tuple[float, dict]] = {}
        self.seen: dict[Path, set] = {}
        self.primed: set[Path] = set()
        self.adapters: dict[str, agents.Agent] = {}
        self._tmp = Path(tempfile.mkdtemp(prefix="agent-bench-monitor-"))

    # ---- pieces -----------------------------------------------------------------

    def ledger(self, rd: Path, manifest: dict) -> LedgerTail:
        ext = ((manifest.get("config") or {}).get("proxy") or {}).get("ledger")
        path = Path(ext).expanduser() if ext else rd / "proxy" / "ledger.jsonl"
        if path not in self.ledgers:
            self.ledgers[path] = LedgerTail(path)
        t = self.ledgers[path]
        t.poll()
        return t

    def summary(self, p: Path) -> dict:
        m = p.stat().st_mtime
        if p not in self.summaries or self.summaries[p][0] != m:
            try:
                self.summaries[p] = (m, json.loads(p.read_text()))
            except ValueError:
                return {}
        return self.summaries[p][1]

    def adapter(self, name: str) -> agents.Agent:
        if name not in self.adapters:
            self.adapters[name] = agents.make(BuilderSpec(name=name, agent=name))
        return self.adapters[name]

    def tail_events(self, bdir: Path, agent: str) -> tuple[Path | None, list[tr.Event]]:
        """Events from the end of the newest transcript."""
        ts = sorted((bdir / "transcripts").glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
        if not ts:
            return None, []
        t = ts[-1]
        m = re.match(r"(\d+)-(builder|driver)", t.name)
        seq, role = (int(m.group(1)), m.group(2)) if m else (0, "builder")
        size = t.stat().st_size
        with t.open("rb") as f:
            f.seek(max(0, size - TAIL_BYTES))
            chunk = f.read()
        if size > TAIL_BYTES:
            chunk = chunk[chunk.find(b"\n") + 1:]
        tmp = self._tmp / f"{abs(hash(str(t)))}.jsonl"
        tmp.write_bytes(chunk)
        try:
            ad = self.adapter(agent if role == "builder" else "claude-code")
            return t, [e for e in ad.events(tmp, role, seq) if e.type in ("tool_call", "message", "final")]
        except Exception:  # noqa: BLE001 - a transcript mid-write
            return t, []

    # ---- the scan ---------------------------------------------------------------

    def scan(self) -> Snapshot:
        snap = Snapshot()
        now = time.time()
        totals = {"active_runs": 0, "running": 0, "queued": 0, "finished": 0, "works": 0, "stopped": 0}
        recent = []
        for runs_dir in self.runs_dirs:
            if not runs_dir.exists():
                continue
            for rd in sorted(p for p in runs_dir.iterdir() if (p / "manifest.json").exists()):
                alive = runner_alive(rd)
                bdirs = [p for p in rd.iterdir() if p.is_dir() and (p / "transcripts").exists()]
                lives = [b for b in bdirs if (b / "live.json").exists() and not (b / "summary.json").exists()]
                fresh = any(now - (b / "live.json").stat().st_mtime < STALE_RUN for b in lives)
                if not alive and not fresh:
                    continue  # a finished or long-dead run
                manifest = json.loads((rd / "manifest.json").read_text())
                plan = json.loads((rd / "plan.json").read_text()) if (rd / "plan.json").exists() else []
                ledger = self.ledger(rd, manifest)
                done = [self.summary(b / "summary.json") for b in bdirs if (b / "summary.json").exists()]
                works = sum(d.get("status") == "works" for d in done)
                queued = max(len(plan) - len(bdirs), 0) if alive else 0
                totals["active_runs"] += 1
                totals["finished"] += len(done)
                totals["works"] += works
                totals["queued"] += queued
                snap.runs.append({"run": rd.name, "dir": rd, "alive": alive, "planned": len(plan),
                                  "finished": len(done), "works": works, "running": len(lives) if alive else 0,
                                  "queued": queued})
                for b, d in zip([b for b in bdirs if (b / "summary.json").exists()], done):
                    recent.append({"run": rd.name, "build": b.name, "dir": b, "status": d.get("status", "?"),
                                   "tokens": (d.get("tokens") or {}).get("builder", {}).get("total", 0),
                                   "min": round(d.get("wall_s", 0) / 60, 1),
                                   "at": (b / "summary.json").stat().st_mtime})
                for b in lives:
                    snap.running.append(self.running(rd, b, alive, ledger, now, snap))
        for r in snap.running:
            totals["running" if r.state == "running" else "stopped"] += 1
        snap.recent = sorted(recent, key=lambda x: x["at"], reverse=True)[:15]
        snap.counts = totals
        snap.rate = self.rate(now)
        snap.disk_free_gb = round(shutil.disk_usage(self.runs_dirs[0] if self.runs_dirs[0].exists()
                                                    else Path.home()).free / 2**30, 1)
        return snap

    def running(self, rd: Path, b: Path, alive: bool, ledger: LedgerTail, now: float, snap: Snapshot) -> Running:
        meta = json.loads((b / "build.json").read_text()) if (b / "build.json").exists() else {}
        live = json.loads((b / "live.json").read_text())
        who = meta.get("builder", {})
        use = ledger.per_build.get(meta.get("proxy_tag", ""), {"total": 0, "calls": 0, "last": 0.0})
        t, evs = self.tail_events(b, who.get("agent", "claude-code"))
        last = max(use["last"], t.stat().st_mtime if t else 0, live.get("since", 0))
        seen = self.seen.setdefault(b, set())
        new = []
        for e in evs:
            key = (e.seq, e.role, e.type, e.call_id or (e.text or "")[:120], json.dumps(e.input)[:200])
            if key not in seen:
                seen.add(key)
                new.append(e)
        if len(seen) > FEED_MAX:
            seen.clear()
            seen.update((e.seq, e.role, e.type, e.call_id or (e.text or "")[:120], json.dumps(e.input)[:200])
                        for e in evs)
        # The first sight of a build shows only its last few events, not its whole tail.
        first = b not in self.primed
        self.primed.add(b)
        snap.feed += [(_short(b.name), e) for e in (new[-3:] if first else new)]
        return Running(run=rd.name, build=b.name, dir=b, agent=who.get("agent", "?"), model=who.get("model", ""),
                       phase=live.get("phase", "?"), phase_s=now - live.get("since", now),
                       tokens=use["total"], calls=use["calls"], quiet_s=now - last if last else 0,
                       action=action_text(evs[-1]) if evs else "",
                       state="running" if alive else "stopped")

    def rate(self, now: float) -> list[int]:
        buckets = [0] * 60
        for t in self.ledgers.values():
            for ts, total in t.recent:
                i = int((now - ts) // 60)
                if 0 <= i < 60:
                    buckets[59 - i] += total
        return buckets
