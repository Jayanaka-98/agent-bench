"""agent-bench command line: what the supervising Claude session (or a person) uses.

    agent-bench run EXPERIMENT.toml [--run-id ID] [--only ...] [--dry-run]
    agent-bench serve [--runs DIR ...] [--experiments DIR ...] [--port 8770]   # API + web UI
    agent-bench tui [--runs RUNS] [--experiments DIR] [--server URL]          # the terminal UI
    agent-bench monitor [RUNS_DIR ...] [--server URL]                         # live view of everything running
    agent-bench status RUN_DIR [--json]
    agent-bench report RUN_DIR [RUN_DIR ...] [--by task,arm,builder] [--json]
    agent-bench trace BUILD_DIR [--role builder] [--kind bash] [--grep RE] [--full]
    agent-bench retrace BUILD_DIR             # rebuild trace.jsonl from transcripts
    agent-bench proxy --upstreams up.json --ledger L [--port 8790]
    agent-bench agents                        # adapters and installed versions
    agent-bench legacy-check OLD_BUILD_DIR    # jac-paper run_builds dirs: same tokens?
    agent-bench dash init|join|publish|link|snapshot   # the shared encrypted dashboard
"""

import argparse;
import json;
import os;
import re;
import subprocess;
import sys;
import from pathlib { Path }
import from agent_bench.common { Json, jac_bin }
import from agent_bench.usage { Usage }
import from agent_bench.trace { read, write }
import from agent_bench.agents.base { BuilderSpec }
import from agent_bench.agents.claude_code { ClaudeCode }
import from agent_bench.agents.registry { ADAPTERS, make }
import agent_bench.report as reports;

glob SERVER_MAIN: Path = Path(__file__).resolve().parent / "server" / "main.jac";

def _print_table(rows: list[Json]) {
    if not rows {
        print("(nothing)");
        return;
    }
    cols: list[str] = [];
    for r in rows {
        for k in r {
            if k not in cols {
                cols.append(k);
            }
        }
    }
    print(reports.md_table([{c: r.get(c, "") for c in cols} for r in rows], cols), end="");
}

def cmd_run(a: any) -> int {
    import from agent_bench.config { Experiment }
    import from agent_bench.runner { run }
    exp = Experiment.load(Path(a.experiment), a.run_id);
    run(exp, a.only, a.dry_run);
    return 0;
}

def cmd_status(a: any) -> int {
    rows = reports.status(Path(a.run_dir));
    if a.json {
        print(json.dumps(rows, indent=1));
    } else {
        _print_table(rows);
    }
    return 0;
}

def cmd_report(a: any) -> int {
    rows = reports.aggregate([Path(p) for p in a.run_dirs], tuple(str(a.by).split(",")));
    if a.json {
        print(json.dumps(rows, indent=1));
    } else {
        _print_table(rows);
    }
    return 0;
}

def cmd_trace(a: any) -> int {
    pat = re.compile(a.grep) if a.grep else None;
    for e in read(Path(a.build_dir) / "trace.jsonl") {
        if (a.role and e.role != a.role) or (a.kind and e.kind != a.kind and e.`type != a.kind) {
            continue;
        }
        body = "";
        if e.`type == "tool_call" {
            body = f"{e.tool}[{e.kind}] {json.dumps(e.input)}";
        } elif e.`type == "tool_result" {
            body = ("ERROR " if e.is_error else "") + (e.output or "").replace("\n", "⏎ ");
        } elif e.`type == "usage" {
            body = json.dumps(e.usage);
        } else {
            body = (e.text or "").replace("\n", "⏎ ");
        }
        line = f"{e.seq:02d} {e.role:<7} {e.`type:<11} {body}";
        if pat is not None and not pat.search(line) {
            continue;
        }
        print(line if a.full else line[:160]);
    }
    return 0;
}

def cmd_retrace(a: any) -> int {
    bdir = Path(a.build_dir);
    s: Json = json.loads((bdir / "summary.json").read_text()) if (bdir / "summary.json").exists() else {};
    b: Json = s.get("builder") or {};
    name = a.agent or b.get("agent");
    if not name {
        print("which agent built this? pass --agent", file=sys.stderr);
        return 2;
    }
    builder = make(BuilderSpec(name=str(name), agent=str(name)));
    driver = make(BuilderSpec(name="driver", agent="claude-code"));
    out = bdir / "trace.jsonl";
    out.write_text("");
    n = 0;
    for t in sorted((bdir / "transcripts").glob("*.jsonl")) {
        m = re.match(r"(\d+)-(builder|driver)", t.name);
        if not m {
            continue;
        }
        seq = int(m.group(1));
        role = str(m.group(2));
        n += write(out, (builder if role == "builder" else driver).events(t, role, seq));
    }
    print(f"{out}: {n} events");
    return 0;
}

def cmd_agents(a: any) -> int {
    rows: list[Json] = [];
    for name in ADAPTERS {
        v = "";
        try {
            v = make(BuilderSpec(name=name, agent=name)).version() if name != "command" else "(configured per builder)";
        } except Exception as e {
            v = f"error: {e}";
        }
        rows.append({"adapter": name, "version": v or "not installed"});
    }
    _print_table(rows);
    return 0;
}

"""Re-total a jac-paper run_builds.py build through this package's Claude Code
adapter and accounting, and compare with the summary it wrote."""
def cmd_legacy_check(a: any) -> int {
    import from agent_bench.build { role_tokens }
    bad = 0;
    for bdir in [Path(p) for p in a.build_dirs] {
        if not (bdir / "summary.json").exists() or not (bdir / "invocations.jsonl").exists() {
            print(f"SKIP {bdir.name:<34} unfinished: no summary.json to compare with");
            continue;
        }
        old = json.loads((bdir / "summary.json").read_text()) as Json;
        cc = ClaudeCode(spec=BuilderSpec(name="cc", agent="claude-code"));
        rows: list[Json] = [];
        for line in (bdir / "invocations.jsonl").read_text().splitlines() {
            r = json.loads(line) as Json;
            u: Usage | None = None;
            mus: Json = r.get("modelUsage") or {};
            if mus {
                u = Usage();
                for mu in mus.values() {
                    m = mu as Json;
                    u = u + Usage(input=int(m.get("inputTokens", 0)), output=int(m.get("outputTokens", 0)),
                                  cache_read=int(m.get("cacheReadInputTokens", 0)),
                                  cache_write=int(m.get("cacheCreationInputTokens", 0)));
                }
            }
            rows.append({**r, "self_usage": u.to_dict() if u is not None else None, "cost_usd": r.get("total_cost_usd")});
        }
        ev_calls: dict[str, int] = {};
        for t in sorted((bdir / "transcripts").glob("*.jsonl")) {
            role = "driver" if "-driver" in t.name else "builder";
            ev_calls[role] = ev_calls.get(role, 0) + len([e for e in cc.events(t, role, 0) if e.`type == "usage"]);
        }
        for role in ("builder", "driver") {
            new = role_tokens(rows, role, None, cumulative=True);
            o: Json = old[role];
            want = int(o["total_tokens"]);
            ok = int(new["total"]) == want and abs(float(new["self_cost_usd"] or 0) - float(o["cost_usd"])) < 1e-3;
            bad += 0 if ok else 1;
            print(f"{'OK ' if ok else 'BAD'} {bdir.name:<34} {role:<7} old {want:>11,}  new {int(new['total']):>11,}  "
                  + f"usd {float(o['cost_usd']):.4f}/{float(new['self_cost_usd'] or 0):.4f}  "
                  + f"model calls in trace {ev_calls.get(role, 0)}");
        }
    }
    return 1 if bad else 0;
}

"""The API and web UI, served by `jac run` on this machine only by default:
launching a run executes the experiment's commands."""
def cmd_serve(a: any) -> int {
    env = dict(os.environ);
    env["AGENT_BENCH_RUNS"] = os.pathsep.join([str(Path(p).resolve()) for p in a.runs]);
    env["AGENT_BENCH_EXPERIMENTS"] = os.pathsep.join([str(Path(p).resolve()) for p in (a.experiments or ["."])]);
    cmd = [jac_bin(), "run", "--serve", "--host", a.host, "--port", str(a.port), str(SERVER_MAIN)];
    if a.no_client {
        cmd.insert(3, "--no-client");
    }
    print(f"agent-bench serving runs {env['AGENT_BENCH_RUNS']} on http://{a.host}:{a.port}", flush=True);
    return subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL).returncode;
}

def cmd_tui(a: any) -> int {
    import from agent_bench.tui { main as tui_main }
    return tui_main(a.runs, a.experiments, a.run, None, a.server or "");
}

def cmd_monitor(a: any) -> int {
    import from agent_bench.tui { main as tui_main }
    dirs: list[str] = a.runs_dirs or ["runs"];
    return tui_main(dirs[0], [], None, dirs, a.server or "");
}

"""The shared, encrypted dashboard (agent_bench/dash.jac)."""
def cmd_dash(a: any) -> int {
    import from agent_bench.dash {
        dash_home, make_token, join, load_config, view_link, publish_loop, snapshot
    }
    if a.dash_cmd == "init" {
        key = os.urandom(32);
        tok = make_token(a.repo, key, Path(a.ssh_key).expanduser().read_text());
        out = Path(a.out).expanduser() if a.out else dash_home() / "join-token";
        out.parent.mkdir(parents=True, exist_ok=True);
        fd = os.open(str(out), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
        with os.fdopen(fd, "w") as f {
            f.write(tok + "\n");
        }
        print(f"join token written to {out} (mode 0600): pass it to `agent-bench dash join @{out}` on each machine");
        return 0;
    }
    if a.dash_cmd == "join" {
        cfg = join(a.token, a.machine, a.roots, a.since, a.exclude);
        print(f"joined as {cfg['machine']}, publishing runs started since {cfg['since']} under:");
        for r in cfg["roots"] {
            print(f"  {r}");
        }
        print(f"view: {view_link(cfg)}");
        return 0;
    }
    if a.dash_cmd == "link" {
        print(view_link(load_config()));
        return 0;
    }
    if a.dash_cmd == "snapshot" {
        print(json.dumps(snapshot(load_config()), indent=1));
        return 0;
    }
    return publish_loop(a.every, a.once);
}

def cmd_proxy(a: any) -> int {
    import from agent_bench.proxy { main as proxy_main }
    return proxy_main(a.rest);
}

def main(argv: list[str] | None = None) -> int {
    ap = argparse.ArgumentParser(prog="agent-bench", description="Run coding agents as builders and meter their effort.");
    sub = ap.add_subparsers(dest="cmd", required=True);
    r = sub.add_parser("run", help="run an experiment");
    r.add_argument("experiment");
    r.add_argument("--run-id");
    r.add_argument("--only", nargs="*", `default=[], help="task, arm, builder, rK, or part of a build id");
    r.add_argument("--dry-run", action="store_true", help="prepare workspaces and prompts only");
    r.set_defaults(fn=cmd_run);
    sv = sub.add_parser("serve", help="the API and web UI (jac run), on 127.0.0.1 by default");
    sv.add_argument("--runs", nargs="*", `default=["runs"]);
    sv.add_argument("--experiments", nargs="*", `default=[]);
    sv.add_argument("--host", `default="127.0.0.1");
    sv.add_argument("--port", type=int, `default=8770);
    sv.add_argument("--no-client", action="store_true", help="the API only, no web UI");
    sv.set_defaults(fn=cmd_serve);
    ui = sub.add_parser("tui", help="the terminal UI: launch experiments, watch builds live");
    ui.add_argument("--runs", `default="runs");
    ui.add_argument("--experiments", nargs="*", `default=[]);
    ui.add_argument("--run", help="open this run directly");
    ui.add_argument("--server", help="an agent-bench serve URL to read through instead of local files");
    ui.set_defaults(fn=cmd_tui);
    mo = sub.add_parser("monitor", help="the TUI's live view of everything running, across runs");
    mo.add_argument("runs_dirs", nargs="*", `default=["runs"]);
    mo.add_argument("--server", help="an agent-bench serve URL to read through instead of local files");
    mo.set_defaults(fn=cmd_monitor);
    s = sub.add_parser("status", help="every build of a run, finished or running");
    s.add_argument("run_dir");
    s.add_argument("--json", action="store_true");
    s.set_defaults(fn=cmd_status);
    p = sub.add_parser("report", help="aggregate over one or more runs");
    p.add_argument("run_dirs", nargs="+");
    p.add_argument("--by", `default="task,arm,builder");
    p.add_argument("--json", action="store_true");
    p.set_defaults(fn=cmd_report);
    t = sub.add_parser("trace", help="read a build's normalized trace");
    t.add_argument("build_dir");
    t.add_argument("--role");
    t.add_argument("--kind", help="a tool kind (bash, read, edit, ...) or an event type");
    t.add_argument("--grep");
    t.add_argument("--full", action="store_true");
    t.set_defaults(fn=cmd_trace);
    rt = sub.add_parser("retrace", help="rebuild trace.jsonl from a build's transcripts");
    rt.add_argument("build_dir");
    rt.add_argument("--agent");
    rt.set_defaults(fn=cmd_retrace);
    ag = sub.add_parser("agents", help="adapters and the installed version of each agent");
    ag.set_defaults(fn=cmd_agents);
    lc = sub.add_parser("legacy-check", help="re-total jac-paper run_builds.py builds and compare");
    lc.add_argument("build_dirs", nargs="+");
    lc.set_defaults(fn=cmd_legacy_check);
    ds = sub.add_parser("dash", help="the shared encrypted dashboard: init, join, publish, link, snapshot");
    dsub = ds.add_subparsers(dest="dash_cmd", required=True);
    di = dsub.add_parser("init", help="make a join token: a new data key plus a deploy key for the data repo");
    di.add_argument("--repo", required=True, help="OWNER/NAME of the data repo");
    di.add_argument("--ssh-key", required=True, help="private key of a deploy key with write access to it");
    di.add_argument("--out", help="where to write the token (default ~/.agent-bench/dash/join-token)");
    dj = dsub.add_parser("join", help="join this machine with a token (or @file)");
    dj.add_argument("token");
    dj.add_argument("--machine", required=True, help="this machine's name on the dashboard");
    dj.add_argument("--roots", nargs="+", required=True, help="runs directories to publish");
    dj.add_argument("--since", help="publish runs started at or after this ISO time (default: now)");
    dj.add_argument("--exclude", nargs="*", `default=[], help="run ids never to publish (void runs)");
    dp = dsub.add_parser("publish", help="publish this machine's runs, then keep publishing");
    dp.add_argument("--every", type=int, `default=60, help="seconds between publishes while a run is active");
    dp.add_argument("--once", action="store_true");
    dsub.add_parser("link", help="print the dashboard link (includes the data key)");
    dsub.add_parser("snapshot", help="print what this machine would publish");
    ds.set_defaults(fn=cmd_dash);
    px = sub.add_parser("proxy", help="run the metering proxy in the foreground");
    px.add_argument("rest", nargs=argparse.REMAINDER);
    px.set_defaults(fn=cmd_proxy);
    a = ap.parse_args(argv);
    return int(a.fn(a));
}

with entry:__main__ {
    raise SystemExit(main(sys.argv[1:]));
}
