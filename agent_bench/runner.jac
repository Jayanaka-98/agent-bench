"""An experiment: every (task, arm, builder, rep), in parallel lanes.

- **Proxy.** With `[proxy]` in the experiment, the runner hosts the metering
  proxy for the run on a background thread (or reuses one already serving this
  run's ledger, or uses an external one given by `url` + `ledger`).
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
- **Monitors.** The run writes `plan.json` (every build it will run) and
  `runner.pid` (this process, removed at the end).
"""

import json;
import os;
import shutil;
import subprocess;
import threading;
import time;
import urllib.request;
import from concurrent.futures { ThreadPoolExecutor }
import from datetime { datetime, timezone }
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.config { Experiment }
import from agent_bench.build { Build }
import from agent_bench.report { write_report }
import from agent_bench.proxy { ThreadedProxy }
import from agent_bench.agents.base { BuilderSpec }
import from agent_bench.agents.registry { make }
import from agent_bench.agents.setup { preflight }

glob VERSION: str = "0.2.0";
glob _print_lock: threading.Lock = threading.Lock();

def log(msg: str) {
    with _print_lock {
        print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True);
    }
}

def _health(url: str) -> Json | None {
    try {
        with urllib.request.urlopen(f"{url}/__health", timeout=3) as r {
            return json.loads(r.read()) as Json;
        }
    } except (OSError, ValueError) {
        return None;
    }
}

obj Proxy {
    has exp: Experiment,
        url: str = "",
        ledger: Path | None = None,
        served: ThreadedProxy | None = None;

    def postinit {
        p = self.exp.proxy;
        if not p {
            return;
        }
        if p.get("url") {
            self.url = str(p["url"]).rstrip("/");
            self.ledger = Path(str(p["ledger"])).expanduser() if p.get("ledger") else None;
            return;
        }
        host = str(p.get("host", "127.0.0.1"));
        port = int(p.get("port", 8790));
        self.url = f"http://{host}:{port}";
        self.ledger = self.exp.runs_dir / self.exp.run_id / "proxy" / "ledger.jsonl";
    }

    def start {
        if not self.url or self.exp.proxy.get("url") or self.ledger is None {
            return;
        }
        h = _health(self.url);
        if h is not None {
            if Path(str(h.get("ledger", ""))) != self.ledger {
                raise RuntimeError(f"a proxy for another ledger ({h.get('ledger')}) holds {self.url}; "
                                   + "give this experiment another proxy port");
            }
            log(f"reusing the proxy at {self.url}");
            return;
        }
        pdir = self.ledger.parent;
        pdir.mkdir(parents=True, exist_ok=True);
        ups: dict[str, Json] = self.exp.proxy.get("upstreams", {});
        (pdir / "upstreams.json").write_text(json.dumps(ups, indent=2));
        p = self.exp.proxy;
        self.served = ThreadedProxy(upstreams=ups, ledger=self.ledger, host=str(p.get("host", "127.0.0.1")),
                                    port=int(p.get("port", 8790)), bodies=bool(p.get("bodies", True)));
        self.served.start();
        log(f"proxy up at {self.url}, ledger {self.ledger}");
    }

    def stop {
        if self.served is not None {
            self.served.stop();
        }
    }
}

def builds(exp: Experiment, proxy: Proxy, only: list[str] = []) -> list[Build] {
    out: list[Build] = [];
    port = exp.port_base;
    for rep in range(1, exp.reps + 1) {
        for task in exp.tasks {
            for arm in exp.arms {
                if exp.pairs is not None and (task.id, arm.id) not in exp.pairs {
                    continue;
                }
                for b in exp.builders {
                    build = Build(exp=exp, task=task, arm=arm, spec=b, rep=rep, port=port,
                                  proxy_url=proxy.url, ledger=proxy.ledger, log_fn=log);
                    port += 1;
                    if only and not any([o in (task.id, arm.id, b.name, f"r{rep}") or o in build.id for o in only]) {
                        continue;
                    }
                    out.append(build);
                }
            }
        }
    }
    return out;
}

def lane_key(exp: Experiment, b: Build) -> str {
    if exp.lane_by == "builder" {
        return b.spec.name;
    }
    if exp.lane_by == "task" {
        return b.task.id;
    }
    if exp.lane_by == "arm" {
        return b.arm.id;
    }
    return b.id;
}

def lanes(exp: Experiment, bs: list[Build]) -> list[list[Build]] {
    groups: dict[str, list[Build]] = {};
    for b in bs {
        groups.setdefault(lane_key(exp, b), []).append(b);
    }
    return list(groups.values());
}

def wait_gates(exp: Experiment, b: Build) -> bool {
    while shutil.disk_usage(exp.runs_dir).free < exp.min_free_gb * 2 ** 30 {
        log(f"less than {exp.min_free_gb} GB free; waiting");
        time.sleep(300);
    }
    for gate in exp.gates {
        passed = False;
        for _ in range(int(exp.raw.get("gate_waits", 36)) + 1) {
            if subprocess.run(gate, shell=True, cwd=exp.file.parent).returncode == 0 {
                passed = True;
                break;
            }
            log(f"{b.id}: gate `{gate}` failed; waiting 10 min");
            time.sleep(600);
        }
        if not passed {
            log(f"{b.id}: gate `{gate}` still failing; skipped");
            return False;
        }
    }
    return True;
}

"""The builders a run will start, and its driver (reviewed protocol): what
preflight makes ready. Builds already finished need nothing."""
def to_prepare(exp: Experiment, bs: list[Build]) -> list[BuilderSpec] {
    out: list[BuilderSpec] = [];
    todo = [b for b in bs if not (b.dir / "summary.json").exists()];
    for b in todo {
        if b.spec not in out {
            out.append(b.spec);
        }
    }
    if todo and exp.protocol == "reviewed" {
        d = exp.driver;
        out.append(BuilderSpec(name="driver", agent="claude-code", model=str(d.get("model", "")),
                               endpoint=str(d.get("endpoint", "")), options=d.get("options", {})));
    }
    return out;
}

"""Before the first build: each builder's agent installed at its pin and, if
it pays with a login, signed in (waiting for the human). A dry run only
reports what is missing."""
def run_preflight(exp: Experiment, bs: list[Build], dry_run: bool, login_timeout: float) {
    env: dict[str, str] = dict(os.environ);
    for (k, v) in exp.env.items() {
        env[str(k)] = str(v);
    }
    problems = preflight(to_prepare(exp, bs), env, dry_run=dry_run, log=log, login_timeout=login_timeout);
    if dry_run {
        if problems {
            log("preflight (dry run): not ready:\n" + "\n".join([f"  - {p}" for p in problems]));
        } else {
            log("preflight (dry run): every agent installed and signed in");
        }
    }
}

def run(exp: Experiment, only: list[str] = [], dry_run: bool = False, check_agents: bool = True,
        login_timeout: float = 1800.0) -> Path {
    run_dir = exp.runs_dir / exp.run_id;
    run_dir.mkdir(parents=True, exist_ok=True);
    proxy = Proxy(exp=exp);
    all_builds = builds(exp, proxy, only);
    if check_agents {
        run_preflight(exp, all_builds, dry_run, login_timeout);
    }
    versions: dict[str, str] = {};
    for b in exp.builders {
        try {
            versions[b.name] = make(b).version();
        } except Exception as e {
            versions[b.name] = f"unavailable: {e}";
        }
    }
    (run_dir / "manifest.json").write_text(json.dumps({
        "run_id": exp.run_id, "experiment": str(exp.file), "agent_bench": VERSION,
        "started": datetime.now(timezone.utc).isoformat(), "only": list(only),
        "agent_versions": versions, "config": exp.raw
    }, indent=2, `default=str));
    shutil.copy(exp.file, run_dir / "experiment.toml");
    log(f"run {exp.run_id}: {len(all_builds)} builds in {exp.lanes} lane(s) by {exp.lane_by}");
    # For monitors: what this run will build, and which process is building it.
    (run_dir / "plan.json").write_text(json.dumps(
        [{"build": b.id, "task": b.task.id, "arm": b.arm.id, "builder": b.spec.name, "rep": b.rep}
         for b in all_builds], indent=1));
    if not dry_run {
        (run_dir / "runner.pid").write_text(str(os.getpid()));
        proxy.start();
    }

    def run_lane(lane: list[Build]) {
        for b in lane {
            try {
                if not dry_run and not (b.dir / "summary.json").exists() and not wait_gates(exp, b) {
                    continue;
                }
                b.run(dry_run=dry_run);
            } except Exception as e {  # one broken build, not the run
                log(f"{b.id}: FAILED {type(e).__name__}: {e}");
            }
            write_report(run_dir);
        }
    }

    try {
        with ThreadPoolExecutor(max_workers=max(exp.lanes, 1)) as pool {
            list(pool.map(run_lane, lanes(exp, all_builds)));
        }
    } finally {
        proxy.stop();
        pid = run_dir / "runner.pid";
        if pid.exists() and pid.read_text().strip() == str(os.getpid()) {
            pid.unlink();
        }
    }
    write_report(run_dir);
    log(f"run {exp.run_id} finished: {run_dir / 'summary.md'}");
    return run_dir;
}
