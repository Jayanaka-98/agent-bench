"""Reports over a run, or over several runs together.

- `summary.csv` / `summary.md`: one row per build.
- `aggregate()`: per (task, arm, builder) group: builds, how many work, and
  builder tokens (median, mean), model calls, cost, wall time.
- `status()`: every build of a run, finished or not, with the tokens a
  running build has used so far (from the proxy ledger).
"""

from __future__ import annotations

import csv
import json
import statistics
import threading
from pathlib import Path

from .proxy import ledger_usage

_lock = threading.Lock()


def summaries(run_dirs: list[Path]) -> list[dict]:
    out = []
    for rd in run_dirs:
        for s in sorted(Path(rd).glob("*/summary.json")):
            d = json.loads(s.read_text())
            if d.get("status") != "dry-run":
                out.append(d)
    return out


def row(d: dict) -> dict:
    b, dr = d["tokens"]["builder"], d["tokens"]["driver"]
    an = d.get("analysis") or {}
    acc = d.get("acceptance") or {}
    selfu = b.get("self_reported") or {}
    return {
        "run_id": d.get("run_id"), "task": d["task"], "arm": d["arm"], "builder": d["builder"]["name"],
        "agent": d["builder"]["agent"], "model": d["builder"]["model"], "rep": d["rep"],
        "status": d["status"], "accepted": ("pass" if acc.get("passed") else "FAIL") if acc else "-",
        "rounds": d["rounds"], "wall_min": round(d["wall_s"] / 60, 1),
        "builder_tokens": b["total"], "builder_source": b["source"], "builder_calls": b["calls"],
        "builder_input": (b.get("metered") or selfu).get("input", 0),
        "builder_cache_read": (b.get("metered") or selfu).get("cache_read", 0),
        "builder_cache_write": (b.get("metered") or selfu).get("cache_write", 0),
        "builder_output": (b.get("metered") or selfu).get("output", 0),
        "builder_self_tokens": selfu.get("total", ""), "builder_self_usd": b.get("self_cost_usd") or "",
        "driver_tokens": dr["total"],
        "tool_calls": (an.get("tool_counts", {}).get("builder") or {}).get("total", 0),
        "source_reads": (an.get("source_reads", {}).get("builder") or {}).get("source_reads", 0),
        "skills_opened": sum((an.get("skills_used", {}).get("builder") or {}).values()),
        "outside_paths": len(an.get("outside_paths") or []),
        "arm_lines_added": d["arm_loc"]["lines_added"], "resent": d.get("resent_without_resume", 0),
    }


def write_report(run_dir: Path) -> None:
    with _lock:
        rows = [row(d) for d in summaries([run_dir])]
        if not rows:
            return
        with (run_dir / "summary.csv").open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
        cols = ["task", "arm", "builder", "rep", "status", "accepted", "rounds", "wall_min", "builder_tokens",
                "builder_source", "builder_calls", "builder_self_tokens", "driver_tokens", "tool_calls",
                "source_reads", "skills_opened", "outside_paths", "arm_lines_added"]
        (run_dir / "summary.md").write_text(md_table(rows, cols))


def md_table(rows: list[dict], cols: list[str]) -> str:
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        lines.append("| " + " | ".join(f"{r[c]:,}" if isinstance(r[c], int) and not isinstance(r[c], bool)
                                        else str(r[c]) for c in cols) + " |")
    return "\n".join(lines) + "\n"


def aggregate(run_dirs: list[Path], by: tuple[str, ...] = ("task", "arm", "builder")) -> list[dict]:
    groups: dict[tuple, list[dict]] = {}
    for d in summaries(run_dirs):
        r = row(d)
        groups.setdefault(tuple(r[k] for k in by), []).append(r)
    out = []
    for key, rs in sorted(groups.items()):
        toks = [r["builder_tokens"] for r in rs]
        usd = [r["builder_self_usd"] for r in rs if r["builder_self_usd"] != ""]
        out.append({**dict(zip(by, key)), "builds": len(rs),
                    "works": sum(r["status"] in ("works", "done") for r in rs),
                    "tokens_median": int(statistics.median(toks)), "tokens_mean": int(statistics.fmean(toks)),
                    "calls_mean": round(statistics.fmean(r["builder_calls"] for r in rs), 1),
                    "self_usd_mean": round(statistics.fmean(usd), 3) if usd else "",
                    "wall_min_mean": round(statistics.fmean(r["wall_min"] for r in rs), 1)})
    return out


def status(run_dir: Path) -> list[dict]:
    manifest = json.loads((run_dir / "manifest.json").read_text()) if (run_dir / "manifest.json").exists() else {}
    ledger = run_dir / "proxy" / "ledger.jsonl"
    ext = ((manifest.get("config") or {}).get("proxy") or {}).get("ledger")
    if ext:
        ledger = Path(ext).expanduser()
    live = ledger_usage(ledger) if ledger.exists() else {}
    out = []
    for bdir in sorted(p for p in run_dir.iterdir() if p.is_dir() and (p / "transcripts").exists()):
        s = bdir / "summary.json"
        if s.exists():
            d = json.loads(s.read_text())
            out.append({"build": bdir.name, "state": "finished", "status": d["status"],
                        "builder_tokens": d["tokens"]["builder"]["total"],
                        "calls": d["tokens"]["builder"]["calls"], "wall_min": round(d["wall_s"] / 60, 1)})
            continue
        inv = bdir / "invocations.jsonl"
        rows = [json.loads(l) for l in inv.read_text().splitlines()] if inv.exists() else []
        tokens = sum(u.total for t, u in live.items() if t.startswith(bdir.name + "~"))
        calls = sum(u.calls for t, u in live.items() if t.startswith(bdir.name + "~"))
        current = sorted((bdir / "transcripts").glob("*.jsonl"), key=lambda p: p.stat().st_mtime)
        out.append({"build": bdir.name, "state": "running" if current else "prepared",
                    "turns_done": len(rows), "current": current[-1].name if current else "",
                    "metered_tokens_so_far": tokens, "calls_so_far": calls,
                    "acceptance_runs": len((bdir / "acceptance.jsonl").read_text().splitlines())
                    if (bdir / "acceptance.jsonl").exists() else 0})
    return out
