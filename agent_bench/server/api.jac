"""The agent-bench API: one set of functions every interface uses.

Served by `jac run` as `POST /function/<name>` (`agent-bench serve`), called
from the web UI as typed RPC, and called by the TUI either over HTTP or
in-process (tui.jac's `Api`). Everything here reads the files the harness
writes (runs/<run>/<build>/...), so a run started from the CLI, the TUI or the
web UI looks the same in all three.

Where to look comes from `configure()` or, at import, from the environment:
AGENT_BENCH_RUNS (runs directories, os.pathsep-separated; default ./runs) and
AGENT_BENCH_EXPERIMENTS (experiment files or directories; default .).

Launching a run executes the experiment's commands, so `launch` only accepts
an experiment this server lists, and `agent-bench serve` binds 127.0.0.1.
"""

import json;
import os;
import re;
import shutil;
import signal;
import subprocess;
import sys;
import threading;
import time;
import from datetime { datetime }
import from pathlib { Path }
import from agent_bench.common { Json, jac_bin }
import from agent_bench.trace { Event, read }
import from agent_bench.monitor { Monitor, runner_alive }
import from agent_bench.agents.base { BuilderSpec }
import from agent_bench.agents.registry { make }
import agent_bench.report as reports;

glob ROOT: Path = Path(__file__).resolve().parent.parent.parent;
glob CLI: Path = Path(__file__).resolve().parent.parent / "cli.jac";
glob FEED_KEEP: int = 3000;
glob MONITOR_MIN_INTERVAL: float = 1.0;
glob BUILD_FILES: list[str] = ["prompt-builder.md", "prompt-driver.md", "summary.json", "final.patch",
                              "acceptance.jsonl", "build.json"];

"""Configuration and the shared monitor, behind one lock: the server may serve
several clients (a browser and a TUI) at once."""
obj State {
    has runs_dirs: list[Path] = [],
        exp_dirs: list[Path] = [],
        monitor: Monitor | None = None,
        feed: list[Json] = [],
        feed_seq: int = 0,
        last_scan: float = 0.0,
        snapshot: Json = {},
        events_cache: dict[str, tuple[tuple[float, int], list[Json]]] = {},
        lock: threading.Lock = threading.Lock();
}

glob STATE: State = State();

def _env_paths(name: str, fallback: str) -> list[Path] {
    raw = os.environ.get(name, "");
    parts = [p for p in raw.split(os.pathsep) if p] if raw else [fallback];
    return [Path(p).expanduser().resolve() for p in parts];
}

"""Point the API at runs and experiments (the CLI and TUI call this)."""
def configure(runs_dirs: list[Path] | None = None, exp_dirs: list[Path] | None = None) {
    with STATE.lock {
        STATE.runs_dirs = [Path(p).resolve() for p in runs_dirs] if runs_dirs else _env_paths("AGENT_BENCH_RUNS", "runs");
        STATE.exp_dirs = [Path(p).resolve() for p in exp_dirs] if exp_dirs else _env_paths("AGENT_BENCH_EXPERIMENTS", ".");
        STATE.monitor = Monitor(runs_dirs=STATE.runs_dirs);
        STATE.feed = [];
        STATE.feed_seq = 0;
        STATE.last_scan = 0.0;
        STATE.snapshot = {};
    }
}

def _ensure {
    if STATE.monitor is None {
        configure();
    }
}

def _name_ok(name: str) -> bool {
    return bool(name) and "/" not in name and "\\" not in name and name not in (".", "..");
}

def _run_dir(run: str) -> Path {
    _ensure();
    if not _name_ok(run) {
        raise ValueError(f"bad run name {run!r}");
    }
    for d in STATE.runs_dirs {
        if (d / run / "manifest.json").exists() {
            return d / run;
        }
    }
    raise FileNotFoundError(f"no run {run!r}");
}

def _build_dir(run: str, build: str) -> Path {
    rd = _run_dir(run);
    if not _name_ok(build) or not (rd / build / "transcripts").exists() {
        raise FileNotFoundError(f"no build {build!r} in {run!r}");
    }
    return rd / build;
}

def _read_json(p: Path) -> Json | None {
    if not p.exists() {
        return None;
    }
    try {
        return json.loads(p.read_text()) as Json;
    } except ValueError {
        return None;
    }
}

def _jsonable(v: any) -> any {
    if isinstance(v, Path) {
        return str(v);
    }
    if isinstance(v, dict) {
        return {str(k): _jsonable(x) for (k, x) in (v as Json).items()};
    }
    if isinstance(v, (list, tuple)) {
        return [_jsonable(x) for x in v];
    }
    return v;
}

"""A build's trace: trace.jsonl, plus, while it runs, the transcripts not yet
folded into it, read through the build's own adapter."""
def _events(bdir: Path) -> list[Json] {
    events = [e.to_dict() for e in read(bdir / "trace.jsonl")];
    if (bdir / "summary.json").exists() {
        return events;
    }
    meta = _read_json(bdir / "build.json");
    if meta is None {
        return events;
    }
    b: Json = meta["builder"];
    done = {(str(e["role"]), int(e["seq"])) for e in events};
    for t in sorted((bdir / "transcripts").glob("*.jsonl")) {
        m = re.match(r"(\d+)-(builder|driver)", t.name);
        if not m or (str(m.group(2)), int(m.group(1))) in done {
            continue;
        }
        st = t.stat();
        key = str(t);
        stamp = (st.st_mtime, st.st_size);
        cached = STATE.events_cache.get(key);
        if cached is None or cached[0] != stamp {
            role = str(m.group(2));
            spec = BuilderSpec(name=str(b["name"]), agent=str(b["agent"]), model=str(b.get("model", "")))
                if role == "builder" else BuilderSpec(name="driver", agent="claude-code");
            try {
                # Usage events come at a turn's end; in a half-written transcript
                # they would sit before events still to come. Leaving them out
                # keeps the live part a prefix of the trace the turn will write,
                # so clients reading by offset never see a line twice.
                evs = [e.to_dict() for e in make(spec).events(t, role, int(m.group(1))) if e.`type != "usage"];
            } except Exception {  # a half-written transcript
                evs = [];
            }
            STATE.events_cache[key] = (stamp, evs);
            cached = STATE.events_cache[key];
        }
        events += cached[1];
    }
    return events;
}

def _ledger_rows(bdir: Path) -> list[Json] {
    calls = bdir / "calls.jsonl";
    if calls.exists() {
        return [json.loads(l) as Json for l in calls.read_text().splitlines() if l.strip()];
    }
    meta = _read_json(bdir / "build.json");
    ledger = bdir.parent / "proxy" / "ledger.jsonl";
    if meta is None or not ledger.exists() {
        return [];
    }
    marker = f'"tag": "{meta["proxy_tag"]}.';
    return [json.loads(l) as Json for l in ledger.read_text(errors="replace").splitlines() if marker in l];
}

"""A served endpoint can receive an omitted defaulted parameter as text (an
omitted `only: list[str] = []` arrives as "[]"), so list and number parameters
are coerced here."""
def _as_list(v: any) -> list[str] {
    if isinstance(v, (list, tuple)) {
        return [str(x) for x in v];
    }
    if isinstance(v, str) {
        t = v.strip();
        if t.startswith("[") {
            try {
                parsed = json.loads(t);
                return [str(x) for x in parsed] if isinstance(parsed, list) else [];
            } except ValueError {
                return [];
            }
        }
        return t.split();
    }
    return [];
}

def _as_int(v: any, fallback: int) -> int {
    try {
        return int(v);
    } except (TypeError, ValueError) {
        return fallback;
    }
}

# ---------------------------------------------------------------------------
# The API
# ---------------------------------------------------------------------------

"""Where this server looks, and its version."""
def:pub info -> Json {
    _ensure();
    return {"runs_dirs": [str(p) for p in STATE.runs_dirs], "experiment_dirs": [str(p) for p in STATE.exp_dirs],
            "version": "0.2.0", "now": time.time()};
}

"""Every run, newest first, with how far along it is."""
def:pub list_runs -> list[Json] {
    _ensure();
    out: list[Json] = [];
    found: list[Path] = [];
    for d in STATE.runs_dirs {
        if d.exists() {
            found += [p for p in d.iterdir() if (p / "manifest.json").exists()];
        }
    }
    for rd in sorted(found, key=lambda (p: Path) -> float { return p.stat().st_mtime; }, reverse=True) {
        m = _read_json(rd / "manifest.json") or {};
        st = reports.status(rd);
        done = [s for s in st if s["state"] == "finished"];
        plan = _read_json(rd / "plan.json");
        out.append({
            "run": rd.name, "builds": len(st), "planned": len(plan) if isinstance(plan, list) else len(st),
            "finished": len(done), "works": len([s for s in done if s.get("status") == "works"]),
            "running": len([s for s in st if s["state"] == "running"]), "alive": runner_alive(rd),
            "started": str(m.get("started", ""))[:16].replace("T", " ")
        });
    }
    return out;
}

"""Every build of a run, finished or running (report.status)."""
def:pub run_builds(run: str) -> list[Json] {
    return reports.status(_run_dir(run));
}

"""Everything running now, across runs. `since` is the cursor from the last
call: the feed holds only the activity after it, so any number of clients can
poll the one monitor without taking events from each other."""
def:pub monitor(since: int = 0) -> Json {
    _ensure();
    with STATE.lock {
        if time.time() - STATE.last_scan >= MONITOR_MIN_INTERVAL or not STATE.snapshot {
            mon = STATE.monitor;
            if mon is None {
                return {};
            }
            s = mon.scan();
            for (who, e) in s.feed {
                STATE.feed_seq += 1;
                STATE.feed.append({"seq": STATE.feed_seq, "build": who, "at": time.time(), "event": e.to_dict()});
            }
            STATE.feed = STATE.feed[-FEED_KEEP:];
            STATE.snapshot = _jsonable({
                "runs": s.runs, "recent": s.recent, "rate": s.rate, "counts": s.counts,
                "disk_free_gb": s.disk_free_gb,
                "running": [{
                    "run": r.run, "build": r.build, "dir": str(r.dir), "agent": r.agent, "model": r.model,
                    "phase": r.phase, "phase_s": r.phase_s, "tokens": r.tokens, "calls": r.calls,
                    "quiet_s": r.quiet_s, "action": r.action, "state": r.state
                } for r in s.running]
            });
            STATE.last_scan = time.time();
        }
        after = _as_int(since, 0);
        feed = [f for f in STATE.feed if int(f["seq"]) > after];
        return {**STATE.snapshot, "feed": feed, "cursor": STATE.feed_seq};
    }
}

"""Who is building, its phase, and its summary once it has one."""
def:pub build_info(run: str, build: str) -> Json {
    bdir = _build_dir(run, build);
    calls = _ledger_rows(bdir);
    return {
        "run": run, "build": build, "meta": _read_json(bdir / "build.json"),
        "live": _read_json(bdir / "live.json"), "summary": _read_json(bdir / "summary.json"),
        "state": "finished" if (bdir / "summary.json").exists() else ("running" if (bdir / "live.json").exists() else "stopped"),
        "metered_tokens": sum([int((c.get("usage") or {}).get("total", 0)) for c in calls]),
        "calls": len([c for c in calls if c.get("usage")])
    };
}

"""A build's trace from event `offset` on, live while it runs."""
def:pub build_trace(run: str, build: str, offset: int = 0, limit: int = 5000) -> Json {
    bdir = _build_dir(run, build);
    with STATE.lock {
        evs = _events(bdir);
    }
    start = _as_int(offset, 0);
    end = start + _as_int(limit, 5000);
    return {"events": evs[start:end], "next": min(len(evs), end), "total": len(evs)};
}

"""Every metered model call the build made."""
def:pub build_calls(run: str, build: str) -> list[Json] {
    rows = _ledger_rows(_build_dir(run, build));
    return [{
        "ts": r.get("ts"), "role": str(r.get("tag", "")).rsplit(".", 1)[-1],
        "model": r.get("model") or r.get("request_model", ""), "usage": r.get("usage"),
        "ms": r.get("ms"), "stream": r.get("stream"), "status": r.get("status")
    } for r in rows];
}

"""One of a build's text files: its prompts, summary, patch, or acceptance logs."""
def:pub build_file(run: str, build: str, name: str) -> str {
    bdir = _build_dir(run, build);
    if name == "acceptance" {
        parts: list[str] = [];
        adir = bdir / "acceptance";
        for f in sorted(adir.glob("accept-*.log")) if adir.exists() else [] {
            parts.append(f"── {f.name} ──\n" + f.read_text(errors="replace")[-20000:]);
        }
        if (bdir / "acceptance.jsonl").exists() {
            parts.append("── verdicts ──\n" + (bdir / "acceptance.jsonl").read_text());
        }
        return "\n".join(parts);
    }
    if name not in BUILD_FILES {
        raise ValueError(f"not a build file: {name!r}");
    }
    p = bdir / name;
    return p.read_text(errors="replace") if p.exists() else "";
}

"""Aggregate over runs, grouped by a comma list of task, arm, builder, agent, model."""
def:pub aggregate(runs: list[str], group_by: str = "task,arm,builder") -> list[Json] {
    keys = [g.strip() for g in str(group_by or "task,arm,builder").split(",") if g.strip()];
    return reports.aggregate([_run_dir(r) for r in _as_list(runs)], tuple(keys));
}

"""The experiment files this server can launch."""
def:pub list_experiments -> list[Json] {
    _ensure();
    out: list[Json] = [];
    for d in STATE.exp_dirs {
        files = sorted(d.rglob("*.toml")) if d.is_dir() else [d];
        for f in files {
            if any([rd in f.parents for rd in STATE.runs_dirs]) {
                continue;  # a run's own copy of its experiment
            }
            try {
                txt = f.read_text();
            } except OSError {
                continue;
            }
            if "[[builders]]" not in txt or "tasks" not in txt {
                continue;
            }
            m = re.search(r'^run_id\s*=\s*"([^"]+)"', txt, re.M);
            out.append({"path": str(f), "name": f.stem, "dir": str(f.parent), "run_id": m.group(1) if m else ""});
        }
    }
    return out;
}

"""Start `agent-bench run` detached; the run lives on if every client leaves."""
def:pub launch(experiment: str, run_id: str = "", only: list[str] = []) -> Json {
    allowed = {str(e["path"]) for e in list_experiments()};
    if experiment not in allowed {
        raise ValueError(f"not an experiment this server lists: {experiment}");
    }
    import from agent_bench.config { Experiment }
    exp = Experiment.load(Path(experiment), run_id or None);
    rd = exp.runs_dir / exp.run_id;
    rd.mkdir(parents=True, exist_ok=True);
    cmd = [jac_bin(), "run", str(CLI), "--", "run", experiment, "--run-id", exp.run_id];
    filters = _as_list(only);
    if filters {
        cmd += ["--only", *filters];
    }
    with (rd / "runner.log").open("a") as logf {
        logf.write(f"\n[{datetime.now():%H:%M:%S}] launched: {' '.join(cmd)}\n");
        logf.flush();
        p = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             start_new_session=True, cwd=str(Path(experiment).parent));
    }
    (rd / "runner.pid").write_text(str(p.pid));
    return {"run": exp.run_id, "dir": str(rd), "pid": p.pid};
}

"""Stop a run's runner (its running builds are killed; relaunching resumes)."""
def:pub stop_run(run: str) -> Json {
    rd = _run_dir(run);
    if not runner_alive(rd) {
        return {"stopped": False, "reason": "no live runner"};
    }
    pid = int((rd / "runner.pid").read_text().strip());
    try {
        os.killpg(pid, signal.SIGTERM);
    } except (ProcessLookupError, PermissionError) {
        os.kill(pid, signal.SIGTERM);
    }
    return {"stopped": True, "pid": pid};
}

"""The tail of a run's runner.log (runs launched from the TUI or web UI)."""
def:pub runner_log(run: str) -> str {
    f = _run_dir(run) / "runner.log";
    return f.read_text(errors="replace")[-100000:] if f.exists() else "";
}
