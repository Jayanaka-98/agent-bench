"""What a build's trace says about how the builder worked, for any agent.

All of these read trace.jsonl (trace.jac), never an agent's native log:

- tool_counts      tool calls per role and kind
- outside_paths    tool calls that touch an absolute path outside the workspace
                   and the allowed toolchain: the record of any peeking
- skills_used      skills each role opened: skill-tool calls, plus reads of a
                   file in an installed skills directory
- source_reads     tool calls that read the framework's installed source
                   (the arm's `source_patterns`): how far the builder had to dig
                   past the docs
- command_checks   per named command pattern (e.g. `jac check`), how many runs
                   and how many came back with an error: syntax and API mistakes
"""

import json;
import re;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.trace { Event, read }

glob SKILL_DIRS: re.Pattern = re.compile(
    r"(?:\.claude/skills|\.agent-skills|\.opencode/skills?|\.openhands/(?:skills|microagents)|\.codex/skills|\.agents/skills)/([A-Za-z0-9][A-Za-z0-9_.-]*)"
);
# Not inside another path: /opt/homebrew/bin is not /homebrew/bin.
glob ABS_PATH: re.Pattern = re.compile(
    r"(?<![\w./~-])(?:~|/home|/Users|/root|/Volumes|/mnt)(?=[/\s'\"`;|&)\\]|$)[^\s'\"`;|&)\\]*"
);
glob ERROR: re.Pattern = re.compile(r"Error|error:|Traceback|\bE\d{4}\b");
glob DEFAULT_ALLOWED: list[str] = ["/tmp", "/private/tmp", "/var/folders", "/dev/null", "/proc", "/usr", "/etc", "/opt"];

def tool_counts(events: list[Event]) -> dict[str, dict[str, int]] {
    out: dict[str, dict[str, int]] = {};
    for e in events {
        if e.`type == "tool_call" {
            c = out.setdefault(e.role, {"total": 0});
            k = e.kind or "other";
            c[k] = c.get(k, 0) + 1;
            c["total"] += 1;
        }
    }
    return out;
}

def outside_paths(events: list[Event], ws: Path, allowed: list[str] = [], home: str = "") -> list[Json] {
    ok = tuple(DEFAULT_ALLOWED + list(allowed));
    hits: list[Json] = [];
    for e in events {
        if e.`type != "tool_call" {
            continue;
        }
        for found in ABS_PATH.findall(json.dumps(e.input)) {
            p = str(found);
            if p.startswith("~") and home {
                p = home + p[1:];
            }
            if p.startswith(str(ws)) or p.startswith(ok) or (home and p.startswith(f"{home}/.cache")) {
                continue;
            }
            hits.append({"role": e.role, "seq": e.seq, "tool": e.tool, "path": p});
        }
    }
    return hits;
}

def skills_used(events: list[Event]) -> dict[str, dict[str, int]] {
    used: dict[str, dict[str, int]] = {};
    for e in events {
        if e.`type != "tool_call" {
            continue;
        }
        names: list[str] = [];
        if e.kind == "skill" {
            names = [str(e.input.get("skill") or e.input.get("name") or e.input.get("command") or e.tool)];
        } else {
            names = sorted({str(n) for n in SKILL_DIRS.findall(json.dumps(e.input))});
        }
        for n in names {
            c = used.setdefault(e.role, {});
            c[n] = c.get(n, 0) + 1;
        }
    }
    return used;
}

def source_reads(events: list[Event], patterns: list[str]) -> dict[str, dict[str, int]] {
    pat = re.compile("|".join([f"(?:{p})" for p in patterns])) if patterns else None;
    out: dict[str, dict[str, int]] = {};
    for e in events {
        if e.`type != "tool_call" {
            continue;
        }
        c = out.setdefault(e.role, {"source_reads": 0, "tool_calls": 0});
        c["tool_calls"] += 1;
        s = json.dumps(e.input);
        if pat is not None and pat.search(s) and not SKILL_DIRS.search(s) {
            c["source_reads"] += 1;
        }
    }
    return out;
}

def command_checks(events: list[Event], checks: dict[str, str], role: str = "builder") -> dict[str, dict[str, int]] {
    res: dict[str, dict[str, int]] = {};
    for (name, rx) in checks.items() {
        pat = re.compile(rx);
        pending: set[str] = set();
        calls = 0;
        failed = 0;
        for e in events {
            if e.role != role {
                continue;
            }
            if e.`type == "tool_call" and e.kind == "bash" {
                cmd = str(e.input.get("command", e.input.get("cmd", "")));
                if pat.search(cmd) {
                    calls += 1;
                    pending.add(e.call_id);
                }
            } elif e.`type == "tool_result" and e.call_id in pending {
                pending.discard(e.call_id);
                if e.is_error or ERROR.search(e.output or "") {
                    failed += 1;
                }
            }
        }
        res[name] = {"calls": calls, "with_errors": failed};
    }
    return res;
}

"""Model calls the agent itself reported, per role."""
def model_calls(events: list[Event]) -> dict[str, int] {
    c: dict[str, int] = {};
    for e in events {
        if e.`type == "usage" {
            c[e.role] = c.get(e.role, 0) + 1;
        }
    }
    return c;
}

def analyze(trace_path: Path, ws: Path, allowed: list[str] = [], source_patterns: list[str] = [],
            checks: dict[str, str] | None = None, home: str = "") -> Json {
    events = read(trace_path);
    return {
        "tool_counts": tool_counts(events),
        "model_calls_self_reported": model_calls(events),
        "skills_used": skills_used(events),
        "source_reads": source_reads(events, list(source_patterns)),
        "command_checks": command_checks(events, checks or {}),
        "outside_paths": outside_paths(events, ws, list(allowed), home)
    };
}
