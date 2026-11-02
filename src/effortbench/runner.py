"""An experiment: every (task, arm, builder, rep), in parallel lanes.

- **Proxy.** With `[proxy]` in the experiment, the runner starts the metering
  proxy for the run (or reuses one already serving this run's ledger, or uses
  an external one given by `url` + `ledger`) and stops what it started.
- **Lanes.** `lane_by` groups builds that run one after another: "builder"
  (each builder works in parallel), "task", "arm", or "none" (every build its
  own lane). `lanes` is how many lanes run at once.
- **Ports.** Each build gets its own port, `port_base` + its index, as
  `${port}` and `BUILD_PORT`, so servers in parallel builds never collide.
- **Resume.** A build with a summary.json is skipped; a half-finished one is
  started again from scratch.
- **Gates.** Before each build: free disk (`min_free_gb`), then each `gates`
  shell command (e.g. a credit check); a failing gate is retried every 10
  minutes, up to `gate_waits` times, and the build is then skipped.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

from . import __version__, agents
from .build import Build
from .config import Experiment
from .report import write_report

_print_lock = threading.Lock()


def log(msg: str) -> None:
    with _print_lock:
        print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def _health(url: str) -> dict | None:
    try:
        with urllib.request.urlopen(f"{url}/__health", timeout=3) as r:
            return json.loads(r.read())
    except (OSError, ValueError):
        return None


class Proxy:
    def __init__(self, exp: Experiment) -> None:
        self.exp, self.proc = exp, None
        p = exp.proxy
        self.url, self.ledger = "", None
        if not p:
            return
        if p.get("url"):
            self.url = p["url"].rstrip("/")
            self.ledger = Path(p["ledger"]).expanduser() if p.get("ledger") else None
            return
        host, port = p.get("host", "127.0.0.1"), p.get("port", 8790)
        self.url = f"http://{host}:{port}"
        self.ledger = exp.runs_dir / exp.run_id / "proxy" / "ledger.jsonl"

    def start(self) -> None:
        if not self.url or self.exp.proxy.get("url"):
            return
        h = _health(self.url)
        if h:
            if Path(h.get("ledger", "")) != self.ledger:
                raise RuntimeError(f"a proxy for another ledger ({h.get('ledger')}) holds {self.url}; "
                                   "give this experiment another proxy port")
            log(f"reusing the proxy at {self.url}")
            return
        pdir = self.ledger.parent
        pdir.mkdir(parents=True, exist_ok=True)
        (pdir / "upstreams.json").write_text(json.dumps(self.exp.proxy.get("upstreams", {}), indent=2))
        port = self.url.rsplit(":", 1)[1]
        cmd = [sys.executable, "-m", "effortbench.proxy", "--port", port, "--host", self.url.split("//")[1].split(":")[0],
               "--upstreams", str(pdir / "upstreams.json"), "--ledger", str(self.ledger)]
        if self.exp.proxy.get("bodies", True):
            cmd.append("--bodies")
        self.proc = subprocess.Popen(cmd, stdout=(pdir / "proxy.log").open("a"), stderr=subprocess.STDOUT,
                                     start_new_session=True)
        for _ in range(60):
            if _health(self.url):
                log(f"proxy up at {self.url}, ledger {self.ledger}")
                return
            if self.proc.poll() is not None:
                break
            time.sleep(0.5)
        raise RuntimeError(f"proxy did not start; see {pdir / 'proxy.log'}")

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def builds(exp: Experiment, proxy: Proxy, only: list[str] = ()) -> list[Build]:
    out, port = [], exp.port_base
    for rep in range(1, exp.reps + 1):
        for task in exp.tasks:
            for arm in exp.arms:
                if exp.pairs is not None and (task.id, arm.id) not in exp.pairs:
                    continue
                for b in exp.builders:
                    build = Build(exp, task, arm, b, rep, port, proxy.url, proxy.ledger, log)
                    port += 1
                    if only and not any(o in (task.id, arm.id, b.name, f"r{rep}") or o in build.id for o in only):
                        continue
                    out.append(build)
    return out


def lanes(exp: Experiment, bs: list[Build]) -> list[list[Build]]:
    key = {"builder": lambda b: b.spec.name, "task": lambda b: b.task.id, "arm": lambda b: b.arm.id,
           "none": lambda b: b.id}[exp.lane_by]
    groups: dict[str, list[Build]] = {}
    for b in bs:
        groups.setdefault(key(b), []).append(b)
    return list(groups.values())


def wait_gates(exp: Experiment, b: Build) -> bool:
    while shutil.disk_usage(exp.runs_dir).free < exp.min_free_gb * 2**30:
        log(f"less than {exp.min_free_gb} GB free; waiting")
        time.sleep(300)
    for gate in exp.gates:
        for attempt in range(exp.raw.get("gate_waits", 36) + 1):
            if subprocess.run(gate, shell=True, cwd=exp.file.parent).returncode == 0:
                break
            log(f"{b.id}: gate `{gate}` failed; waiting 10 min")
            time.sleep(600)
        else:
            log(f"{b.id}: gate `{gate}` still failing; skipped")
            return False
    return True


def run(exp: Experiment, only: list[str] = (), dry_run: bool = False) -> Path:
    run_dir = exp.runs_dir / exp.run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    proxy = Proxy(exp)
    versions = {}
    for b in exp.builders:
        try:
            versions[b.name] = agents.make(b).version()
        except Exception as e:  # noqa: BLE001
            versions[b.name] = f"unavailable: {e}"
    (run_dir / "manifest.json").write_text(json.dumps({
        "run_id": exp.run_id, "experiment": str(exp.file), "effortbench": __version__,
        "started": datetime.now(timezone.utc).isoformat(), "only": list(only),
        "agent_versions": versions, "config": exp.raw}, indent=2, default=str))
    shutil.copy(exp.file, run_dir / "experiment.toml")
    all_builds = builds(exp, proxy, only)
    log(f"run {exp.run_id}: {len(all_builds)} builds in {exp.lanes} lane(s) by {exp.lane_by}")
    # For monitors: what this run will build, and which process is building it.
    (run_dir / "plan.json").write_text(json.dumps(
        [{"build": b.id, "task": b.task.id, "arm": b.arm.id, "builder": b.spec.name, "rep": b.rep}
         for b in all_builds], indent=1))
    if not dry_run:
        (run_dir / "runner.pid").write_text(str(os.getpid()))
        proxy.start()

    def run_lane(lane: list[Build]) -> None:
        for b in lane:
            try:
                if not dry_run and not (b.dir / "summary.json").exists() and not wait_gates(exp, b):
                    continue
                b.run(dry_run=dry_run)
            except Exception as e:  # noqa: BLE001 - one broken build, not the run
                log(f"{b.id}: FAILED {type(e).__name__}: {e}")
            write_report(run_dir)

    try:
        with ThreadPoolExecutor(max_workers=max(exp.lanes, 1)) as pool:
            list(pool.map(run_lane, lanes(exp, all_builds)))
    finally:
        proxy.stop()
        pid = run_dir / "runner.pid"
        if pid.exists() and pid.read_text().strip() == str(os.getpid()):
            pid.unlink()
    write_report(run_dir)
    log(f"run {exp.run_id} finished: {run_dir / 'summary.md'}")
    return run_dir
