"""Reports over a run, or over several runs together.

- `summary.csv` / `summary.md`: one row per build.
- `aggregate()`: per (task, arm, builder) group: builds, how many work, and
  builder tokens (median, mean), model calls, cost, wall time.
- `status()`: every build of a run, finished or not, with the tokens a
  running build has used so far (from the proxy ledger).
"""

import csv;
import json;
import statistics;
import threading;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.proxy { ledger_usage }

glob _lock: threading.Lock = threading.Lock();

def summaries(run_dirs: list[Path]) -> list[Json] {
    out: list[Json] = [];
    for rd in run_dirs {
        for s in sorted(Path(rd).glob("*/summary.json")) {
            d = json.loads(s.read_text()) as Json;
            if d.get("status") != "dry-run" {
                out.append(d);
            }
        }
    }
    return out;
}

def row(d: Json) -> Json {
    tokens: Json = d["tokens"];
    b: Json = tokens["builder"];
    dr: Json = tokens["driver"];
    an: Json = d.get("analysis") or {};
    acc: Json = d.get("acceptance") or {};
    selfu: Json = b.get("self_reported") or {};
    use: Json = b.get("metered") or selfu;
    builder: Json = d["builder"];
    tc: Json = an.get("tool_counts", {});
    sr: Json = an.get("source_reads", {});
    su: Json = an.get("skills_used", {});
    skills: Json = su.get("builder") or {};
    return {
        "run_id": d.get("run_id"), "task": d["task"], "arm": d["arm"], "builder": builder["name"],
        "agent": builder["agent"], "model": builder["model"], "rep": d["rep"],
        "status": d["status"], "accepted": ("pass" if acc.get("passed") else "FAIL") if acc else "-",
        "rounds": d["rounds"], "wall_min": round(float(d["wall_s"]) / 60, 1),
        "builder_tokens": b["total"], "builder_source": b["source"], "builder_calls": b["calls"],
        "builder_input": use.get("input", 0), "builder_cache_read": use.get("cache_read", 0),
        "builder_cache_write": use.get("cache_write", 0), "builder_output": use.get("output", 0),
        "builder_self_tokens": selfu.get("total", ""), "builder_self_usd": b.get("self_cost_usd") or "",
        "driver_tokens": dr["total"],
        "tool_calls": (tc.get("builder") or {}).get("total", 0),
        "source_reads": (sr.get("builder") or {}).get("source_reads", 0),
        "skills_opened": sum([int(v) for v in skills.values()]),
        "outside_paths": len(an.get("outside_paths") or []),
        "arm_lines_added": d["arm_loc"]["lines_added"], "resent": d.get("resent_without_resume", 0)
    };
}

def md_table(rows: list[Json], cols: list[str]) -> str {
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)];
    for r in rows {
        cells: list[str] = [];
        for c in cols {
            v = r.get(c, "");
            cells.append(f"{v:,}" if isinstance(v, int) and not isinstance(v, bool) else str(v));
        }
        lines.append("| " + " | ".join(cells) + " |");
    }
    return "\n".join(lines) + "\n";
}

def write_report(run_dir: Path) {
    with _lock {
        rows = [row(d) for d in summaries([run_dir])];
        if not rows {
            return;
        }
        with (run_dir / "summary.csv").open("w", newline="") as f {
            w = csv.DictWriter(f, fieldnames=list(rows[0]));
            w.writeheader();
            w.writerows(rows);
        }
        cols = ["task", "arm", "builder", "rep", "status", "accepted", "rounds", "wall_min", "builder_tokens",
                "builder_source", "builder_calls", "builder_self_tokens", "driver_tokens", "tool_calls",
                "source_reads", "skills_opened", "outside_paths", "arm_lines_added"];
        (run_dir / "summary.md").write_text(md_table(rows, cols));
    }
}

def aggregate(run_dirs: list[Path], group_by: tuple[str, ...] = ("task", "arm", "builder")) -> list[Json] {
    groups: dict[tuple[any, ...], list[Json]] = {};
    for d in summaries(run_dirs) {
        r = row(d);
        groups.setdefault(tuple([r[k] for k in group_by]), []).append(r);
    }
    out: list[Json] = [];
    for (key, rs) in sorted(groups.items()) {
        toks = [int(r["builder_tokens"]) for r in rs];
        usd = [float(r["builder_self_usd"]) for r in rs if r["builder_self_usd"] != ""];
        agg: Json = {k: v for (k, v) in zip(group_by, key)};
        agg.update({
            "builds": len(rs), "works": len([r for r in rs if r["status"] in ("works", "done")]),
            "tokens_median": int(statistics.median(toks)), "tokens_mean": int(statistics.fmean(toks)),
            "calls_mean": round(statistics.fmean([float(r["builder_calls"]) for r in rs]), 1),
            "self_usd_mean": round(statistics.fmean(usd), 3) if usd else "",
            "wall_min_mean": round(statistics.fmean([float(r["wall_min"]) for r in rs]), 1)
        });
        out.append(agg);
    }
    return out;
}

def status(run_dir: Path) -> list[Json] {
    manifest: Json = json.loads((run_dir / "manifest.json").read_text()) if (run_dir / "manifest.json").exists() else {};
    ledger = run_dir / "proxy" / "ledger.jsonl";
    cfg: Json = manifest.get("config") or {};
    pcfg: Json = cfg.get("proxy") or {};
    if pcfg.get("ledger") {
        ledger = Path(str(pcfg["ledger"])).expanduser();
    }
    live = ledger_usage(ledger) if ledger.exists() else {};
    out: list[Json] = [];
    for bdir in sorted([p for p in run_dir.iterdir() if p.is_dir() and (p / "transcripts").exists()]) {
        s = bdir / "summary.json";
        if s.exists() {
            d = json.loads(s.read_text()) as Json;
            b: Json = d["tokens"]["builder"];
            out.append({"build": bdir.name, "state": "finished", "status": d["status"],
                        "builder_tokens": b["total"], "calls": b["calls"],
                        "wall_min": round(float(d["wall_s"]) / 60, 1)});
            continue;
        }
        inv = bdir / "invocations.jsonl";
        n_rows = len(inv.read_text().splitlines()) if inv.exists() else 0;
        mine = [u for (t, u) in live.items() if t.startswith(bdir.name + "~")];
        current = sorted((bdir / "transcripts").glob("*.jsonl"), key=lambda (p: Path) -> float { return p.stat().st_mtime; });
        acc = bdir / "acceptance.jsonl";
        out.append({
            "build": bdir.name, "state": "running" if current else "prepared", "turns_done": n_rows,
            "current": current[-1].name if current else "",
            "metered_tokens_so_far": sum([u.total for u in mine]), "calls_so_far": sum([u.calls for u in mine]),
            "acceptance_runs": len(acc.read_text().splitlines()) if acc.exists() else 0
        });
    }
    return out;
}
