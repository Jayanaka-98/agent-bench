"""agent-bench command line: what the supervising Claude session (or a person) uses.

    agent-bench run EXPERIMENT.toml [--run-id ID] [--only ...] [--dry-run]
    agent-bench status RUN_DIR [--json]
    agent-bench report RUN_DIR [RUN_DIR ...] [--by task,arm,builder] [--json]
    agent-bench trace BUILD_DIR [--role builder] [--kind bash] [--grep RE] [--full]
    agent-bench retrace BUILD_DIR             # rebuild trace.jsonl from transcripts
    agent-bench tui [--runs RUNS] [--experiments DIR]   # the terminal UI
    agent-bench monitor [RUNS_DIR ...]                  # live view of everything running
    agent-bench proxy --upstreams up.json --ledger L [--port 8790]
    agent-bench agents                        # adapters and installed versions
    agent-bench legacy-check OLD_BUILD_DIR    # jac-paper run_builds dirs: same tokens?
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from . import agents, report
from . import trace as tr


def _print_table(rows: list[dict]) -> None:
    if not rows:
        print("(nothing)")
        return
    cols = list(dict.fromkeys(k for r in rows for k in r))
    print(report.md_table([{c: r.get(c, "") for c in cols} for r in rows], cols), end="")


def cmd_run(a) -> int:
    from .config import Experiment
    from .runner import run
    exp = Experiment.load(Path(a.experiment), a.run_id)
    run(exp, a.only, a.dry_run)
    return 0


def cmd_status(a) -> int:
    rows = report.status(Path(a.run_dir))
    print(json.dumps(rows, indent=1)) if a.json else _print_table(rows)
    return 0


def cmd_report(a) -> int:
    rows = report.aggregate([Path(p) for p in a.run_dirs], tuple(a.by.split(",")))
    print(json.dumps(rows, indent=1)) if a.json else _print_table(rows)
    return 0


def cmd_trace(a) -> int:
    pat = re.compile(a.grep) if a.grep else None
    width = None if a.full else 160
    for e in tr.read(Path(a.build_dir) / "trace.jsonl"):
        if (a.role and e.role != a.role) or (a.kind and e.kind != a.kind and e.type != a.kind):
            continue
        if e.type == "tool_call":
            body = f"{e.tool}[{e.kind}] {json.dumps(e.input)}"
        elif e.type == "tool_result":
            body = ("ERROR " if e.is_error else "") + (e.output or "").replace("\n", "⏎ ")
        elif e.type == "usage":
            body = json.dumps(e.usage)
        else:
            body = (e.text or "").replace("\n", "⏎ ")
        line = f"{e.seq:02d} {e.role:<7} {e.type:<11} {body}"
        if pat and not pat.search(line):
            continue
        print(line if width is None else line[:width])
    return 0


def cmd_retrace(a) -> int:
    bdir = Path(a.build_dir)
    s = json.loads((bdir / "summary.json").read_text()) if (bdir / "summary.json").exists() else {}
    name = a.agent or (s.get("builder") or {}).get("agent")
    if not name:
        print("which agent built this? pass --agent", file=sys.stderr)
        return 2
    spec = agents.BuilderSpec(name=name, agent=name)
    b, d = agents.make(spec), agents.make(agents.BuilderSpec(name="driver", agent="claude-code"))
    out = bdir / "trace.jsonl"
    out.write_text("")
    n = 0
    for t in sorted((bdir / "transcripts").glob("*.jsonl")):
        m = re.match(r"(\d+)-(builder|driver)", t.name)
        if not m:
            continue
        seq, role = int(m.group(1)), m.group(2)
        n += tr.write(out, (b if role == "builder" else d).events(t, role, seq))
    print(f"{out}: {n} events")
    return 0


def cmd_agents(a) -> int:
    rows = []
    for name in agents.ADAPTERS:
        try:
            ag = agents.make(agents.BuilderSpec(name=name, agent=name))
            v = ag.version() if name != "command" else "(configured per builder)"
        except Exception as e:  # noqa: BLE001
            v = f"error: {e}"
        rows.append({"adapter": name, "version": v or "not installed"})
    _print_table(rows)
    return 0


def cmd_legacy_check(a) -> int:
    """Re-total a jac-paper run_builds.py build through this package's Claude
    Code adapter and accounting, and compare with the summary it wrote."""
    from .agents.claude_code import ClaudeCode
    from .build import role_tokens
    from .usage import Usage
    bad = 0
    for bdir in [Path(p) for p in a.build_dirs]:
        old = json.loads((bdir / "summary.json").read_text())
        cc = ClaudeCode(agents.BuilderSpec(name="cc", agent="claude-code"))
        rows = []
        for r in (json.loads(l) for l in (bdir / "invocations.jsonl").read_text().splitlines()):
            u = None
            if r.get("modelUsage"):
                u = Usage()
                for mu in r["modelUsage"].values():
                    u = u + Usage(input=mu.get("inputTokens", 0), output=mu.get("outputTokens", 0),
                                  cache_read=mu.get("cacheReadInputTokens", 0),
                                  cache_write=mu.get("cacheCreationInputTokens", 0))
            rows.append({**r, "self_usage": u.to_dict() if u else None, "cost_usd": r.get("total_cost_usd")})
        ev_calls = {}
        for t in sorted((bdir / "transcripts").glob("*.jsonl")):
            role = "driver" if "-driver" in t.name else "builder"
            ev_calls[role] = ev_calls.get(role, 0) + sum(1 for e in cc.events(t, role, 0) if e.type == "usage")
        for role in ("builder", "driver"):
            new = role_tokens(rows, role, None, cumulative=True)
            want = old[role]["total_tokens"]
            ok = new["total"] == want and abs((new["self_cost_usd"] or 0) - old[role]["cost_usd"]) < 1e-3
            bad += not ok
            print(f"{'OK ' if ok else 'BAD'} {bdir.name:<34} {role:<7} old {want:>11,}  new {new['total']:>11,}  "
                  f"usd {old[role]['cost_usd']:.4f}/{new['self_cost_usd'] or 0:.4f}  "
                  f"model calls in trace {ev_calls.get(role, 0)}")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="agent-bench", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="run an experiment")
    r.add_argument("experiment")
    r.add_argument("--run-id")
    r.add_argument("--only", nargs="*", default=[], help="task, arm, builder, rK, or part of a build id")
    r.add_argument("--dry-run", action="store_true", help="prepare workspaces and prompts only")
    r.set_defaults(fn=cmd_run)
    s = sub.add_parser("status", help="every build of a run, finished or running")
    s.add_argument("run_dir")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_status)
    p = sub.add_parser("report", help="aggregate over one or more runs")
    p.add_argument("run_dirs", nargs="+")
    p.add_argument("--by", default="task,arm,builder")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_report)
    t = sub.add_parser("trace", help="read a build's normalized trace")
    t.add_argument("build_dir")
    t.add_argument("--role")
    t.add_argument("--kind", help="a tool kind (bash, read, edit, ...) or an event type")
    t.add_argument("--grep")
    t.add_argument("--full", action="store_true")
    t.set_defaults(fn=cmd_trace)
    rt = sub.add_parser("retrace", help="rebuild trace.jsonl from a build's transcripts")
    rt.add_argument("build_dir")
    rt.add_argument("--agent")
    rt.set_defaults(fn=cmd_retrace)
    ag = sub.add_parser("agents", help="adapters and the installed version of each agent")
    ag.set_defaults(fn=cmd_agents)
    lc = sub.add_parser("legacy-check", help="re-total jac-paper run_builds.py builds and compare")
    lc.add_argument("build_dirs", nargs="+")
    lc.set_defaults(fn=cmd_legacy_check)
    ui = sub.add_parser("tui", help="the terminal UI: launch experiments, watch builds live")
    ui.add_argument("--runs", default="runs", help="the runs directory (default ./runs)")
    ui.add_argument("--experiments", nargs="*", default=[], help="experiment files or dirs (default .)")
    ui.add_argument("--run", help="open this run directory directly")
    ui.set_defaults(fn=lambda a: __import__("agent_bench.tui", fromlist=["main"]).main(a.runs, a.experiments, a.run))
    mo = sub.add_parser("monitor", help="the TUI's live view of everything running, across runs")
    mo.add_argument("runs_dirs", nargs="*", default=["runs"], help="runs directories (default ./runs)")
    mo.set_defaults(fn=lambda a: __import__("agent_bench.tui", fromlist=["main"]).main(
        a.runs_dirs[0], [], None, a.runs_dirs))
    px = sub.add_parser("proxy", help="run the metering proxy in the foreground")
    px.add_argument("rest", nargs=argparse.REMAINDER)
    px.set_defaults(fn=lambda a: __import__("agent_bench.proxy", fromlist=["main"]).main(a.rest))
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    raise SystemExit(main())
