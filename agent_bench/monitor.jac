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

import json;
import os;
import re;
import shutil;
import tempfile;
import time;
import from collections { deque }
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.trace { Event }
import from agent_bench.agents.base { Agent, BuilderSpec }
import from agent_bench.agents.registry { make }

glob TAIL_BYTES: int = 256 * 1024;
glob FEED_MAX: int = 2000;
glob RATE_WINDOW: int = 60 * 60;
glob STALE_RUN: int = 24 * 3600;

def runner_alive(run_dir: Path) -> bool {
    pid = run_dir / "runner.pid";
    if not pid.exists() {
        return False;
    }
    try {
        os.kill(int(pid.read_text().strip()), 0);
        return True;
    } except (ValueError, ProcessLookupError) {
        return False;
    } except PermissionError {  # alive, another user's
        return True;
    }
}

"""A proxy ledger, read from where the last poll stopped."""
obj LedgerTail {
    has path: Path,
        offset: int = 0,
        per_build: dict[str, Json] = {},        # proxy tag (build~nonce) -> total, calls, last
        recent: deque = deque();

    def poll {
        if not self.path.exists() {
            return;
        }
        size = self.path.stat().st_size;
        if size < self.offset {  # rotated or rewritten
            self.offset = 0;
            self.per_build = {};
        }
        if size == self.offset {
            return;
        }
        with self.path.open("rb") as f {
            f.seek(self.offset);
            chunk = f.read();
        }
        end = chunk.rfind(b"\n") + 1;
        self.offset += end;
        for line in chunk[:end].splitlines() {
            try {
                r = json.loads(line);
            } except ValueError {
                continue;
            }
            if not isinstance(r, dict) {
                continue;
            }
            rd = r as Json;
            u: Json | None = rd.get("usage");
            if not u {
                continue;
            }
            key = str(rd.get("tag", "")).rsplit(".", 1)[0];
            b = self.per_build.setdefault(key, {"total": 0, "calls": 0, "last": 0.0});
            b["total"] = int(b["total"]) + int(u.get("total", 0));
            b["calls"] = int(b["calls"]) + 1;
            b["last"] = max(float(b["last"]), float(rd.get("ts", 0)));
            self.recent.append((float(rd.get("ts", 0)), int(u.get("total", 0))));
        }
        cutoff = time.time() - RATE_WINDOW;
        while self.recent and self.recent[0][0] < cutoff {
            self.recent.popleft();
        }
    }
}

obj Running {
    has run: str,
        build: str,
        dir: Path,
        agent: str,
        model: str,
        phase: str,
        phase_s: float,
        tokens: int,
        calls: int,
        quiet_s: float,
        action: str,
        state: str;          # running | stopped
}

obj Snapshot {
    has runs: list[Json] = [],
        running: list[Running] = [],
        recent: list[Json] = [],
        feed: list[tuple[str, Event]] = [],   # new since the last scan
        rate: list[int] = [],                 # tokens per minute, oldest first
        counts: dict[str, int] = {},
        disk_free_gb: float = 0.0;
}

"""task__arm__builder__rK -> task/arm/builder/rK, for narrow columns."""
def short_name(build: str) -> str {
    return build.replace("__", "/");
}

def action_text(e: Event) -> str {
    if e.`type == "tool_call" {
        arg = e.input.get("command") or e.input.get("file_path") or e.input.get("path")
            or e.input.get("pattern") or e.input.get("skill") or json.dumps(e.input);
        return f"{e.tool}: {str(arg).strip()}";
    }
    if e.`type == "message" {
        return "“" + (e.text or "").strip() + "”";
    }
    if e.`type == "final" {
        return "■ " + (e.text or "").strip();
    }
    return "";
}

def _event_key(e: Event) -> tuple[int, str, str, str, str] {
    return (e.seq, e.role, e.`type, e.call_id or (e.text or "")[:120], json.dumps(e.input)[:200]);
}

obj Monitor {
    has runs_dirs: list[Path],
        ledgers: dict[str, LedgerTail] = {},
        summaries: dict[str, tuple[float, Json]] = {},
        seen: dict[str, set[tuple[int, str, str, str, str]]] = {},
        primed: set[str] = set(),
        adapters: dict[str, Agent] = {},
        tmp: Path postinit;

    def postinit {
        self.tmp = Path(tempfile.mkdtemp(prefix="agent-bench-monitor-"));
    }

    # ---- pieces -----------------------------------------------------------------

    def ledger(rd: Path, manifest: Json) -> LedgerTail {
        cfg: Json = manifest.get("config") or {};
        pcfg: Json = cfg.get("proxy") or {};
        path = Path(str(pcfg["ledger"])).expanduser() if pcfg.get("ledger") else rd / "proxy" / "ledger.jsonl";
        k = str(path);
        if k not in self.ledgers {
            self.ledgers[k] = LedgerTail(path=path);
        }
        t = self.ledgers[k];
        t.poll();
        return t;
    }

    def summary(p: Path) -> Json {
        m = p.stat().st_mtime;
        k = str(p);
        if k not in self.summaries or self.summaries[k][0] != m {
            try {
                self.summaries[k] = (m, json.loads(p.read_text()) as Json);
            } except ValueError {
                return {};
            }
        }
        return self.summaries[k][1];
    }

    def adapter(name: str) -> Agent {
        if name not in self.adapters {
            self.adapters[name] = make(BuilderSpec(name=name, agent=name));
        }
        return self.adapters[name];
    }

    """Events from the end of the newest transcript."""
    def tail_events(bdir: Path, agent: str) -> tuple[Path | None, list[Event]] {
        ts = sorted((bdir / "transcripts").glob("*.jsonl"), key=lambda (p: Path) -> float { return p.stat().st_mtime; });
        if not ts {
            return (None, []);
        }
        t = ts[-1];
        m = re.match(r"(\d+)-(builder|driver)", t.name);
        seq = int(m.group(1)) if m else 0;
        role = str(m.group(2)) if m else "builder";
        size = t.stat().st_size;
        with t.open("rb") as f {
            f.seek(max(0, size - TAIL_BYTES));
            chunk = f.read();
        }
        if size > TAIL_BYTES {
            chunk = chunk[chunk.find(b"\n") + 1:];
        }
        tmp = self.tmp / f"{abs(hash(str(t)))}.jsonl";
        tmp.write_bytes(chunk);
        try {
            ad = self.adapter(agent if role == "builder" else "claude-code");
            evs = [e for e in ad.events(tmp, role, seq) if e.`type in ("tool_call", "message", "final")];
            return (t, evs);
        } except Exception {  # a transcript mid-write
            return (t, []);
        }
    }

    # ---- the scan ---------------------------------------------------------------

    def scan -> Snapshot {
        snap = Snapshot();
        now = time.time();
        totals: dict[str, int] = {"active_runs": 0, "running": 0, "queued": 0, "finished": 0, "works": 0, "stopped": 0};
        recent: list[Json] = [];
        for runs_dir in self.runs_dirs {
            if not runs_dir.exists() {
                continue;
            }
            for rd in sorted([p for p in runs_dir.iterdir() if (p / "manifest.json").exists()]) {
                alive = runner_alive(rd);
                bdirs = [p for p in rd.iterdir() if p.is_dir() and (p / "transcripts").exists()];
                lives = [b for b in bdirs if (b / "live.json").exists() and not (b / "summary.json").exists()];
                fresh = any([now - (b / "live.json").stat().st_mtime < STALE_RUN for b in lives]);
                if not alive and not fresh {
                    continue;  # a finished or long-dead run
                }
                manifest = json.loads((rd / "manifest.json").read_text()) as Json;
                plan: list[Json] = json.loads((rd / "plan.json").read_text()) if (rd / "plan.json").exists() else [];
                ledger = self.ledger(rd, manifest);
                done_dirs = [b for b in bdirs if (b / "summary.json").exists()];
                done = [self.summary(b / "summary.json") for b in done_dirs];
                works = len([d for d in done if d.get("status") == "works"]);
                queued = max(len(plan) - len(bdirs), 0) if alive else 0;
                totals["active_runs"] += 1;
                totals["finished"] += len(done);
                totals["works"] += works;
                totals["queued"] += queued;
                snap.runs.append({"run": rd.name, "dir": rd, "alive": alive, "planned": len(plan),
                                  "finished": len(done), "works": works, "running": len(lives) if alive else 0,
                                  "queued": queued});
                for (b, d) in zip(done_dirs, done) {
                    tok: Json = d.get("tokens") or {};
                    bt: Json = tok.get("builder") or {};
                    recent.append({"run": rd.name, "build": b.name, "dir": b, "status": d.get("status", "?"),
                                   "tokens": bt.get("total", 0), "min": round(float(d.get("wall_s", 0)) / 60, 1),
                                   "at": (b / "summary.json").stat().st_mtime});
                }
                for b in lives {
                    snap.running.append(self.running(rd, b, alive, ledger, now, snap));
                }
            }
        }
        for r in snap.running {
            totals["running" if r.state == "running" else "stopped"] += 1;
        }
        snap.recent = sorted(recent, key=lambda (x: Json) -> float { return float(x["at"]); }, reverse=True)[:15];
        snap.counts = totals;
        snap.rate = self.rate(now);
        base = self.runs_dirs[0] if self.runs_dirs and self.runs_dirs[0].exists() else Path.home();
        snap.disk_free_gb = round(shutil.disk_usage(base).free / 2 ** 30, 1);
        return snap;
    }

    def running(rd: Path, b: Path, alive: bool, ledger: LedgerTail, now: float, snap: Snapshot) -> Running {
        meta: Json = json.loads((b / "build.json").read_text()) if (b / "build.json").exists() else {};
        live = json.loads((b / "live.json").read_text()) as Json;
        who: Json = meta.get("builder", {});
        use: Json = ledger.per_build.get(str(meta.get("proxy_tag", "")), {"total": 0, "calls": 0, "last": 0.0});
        (t, evs) = self.tail_events(b, str(who.get("agent", "claude-code")));
        last = max(float(use["last"]), t.stat().st_mtime if t is not None else 0.0, float(live.get("since", 0)));
        k = str(b);
        seen = self.seen.setdefault(k, set());
        new: list[Event] = [];
        for e in evs {
            key = _event_key(e);
            if key not in seen {
                seen.add(key);
                new.append(e);
            }
        }
        if len(seen) > FEED_MAX {
            self.seen[k] = {_event_key(e) for e in evs};
        }
        # The first sight of a build shows only its last few events, not its whole tail.
        first = k not in self.primed;
        self.primed.add(k);
        for e in (new[-3:] if first else new) {
            snap.feed.append((short_name(b.name), e));
        }
        return Running(
            run=rd.name, build=b.name, dir=b, agent=str(who.get("agent", "?")), model=str(who.get("model", "")),
            phase=str(live.get("phase", "?")), phase_s=now - float(live.get("since", now)),
            tokens=int(use["total"]), calls=int(use["calls"]), quiet_s=now - last if last else 0.0,
            action=action_text(evs[-1]) if evs else "", state="running" if alive else "stopped"
        );
    }

    def rate(now: float) -> list[int] {
        buckets = [0] * 60;
        for t in self.ledgers.values() {
            for (ts, total) in t.recent {
                i = int((now - ts) // 60);
                if 0 <= i and i < 60 {
                    buckets[59 - i] += total;
                }
            }
        }
        return buckets;
    }
}
