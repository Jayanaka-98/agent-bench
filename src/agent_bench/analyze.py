"""What a build's trace says about how the builder worked, for any agent.

All of these read trace.jsonl (trace.py), never an agent's native log:

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

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from . import trace as tr

SKILL_DIRS = re.compile(r"(?:\.claude/skills|\.agent-skills|\.opencode/skills?|\.openhands/(?:skills|microagents)"
                        r"|\.codex/skills|\.agents/skills)/([A-Za-z0-9][A-Za-z0-9_.-]*)")
# Not inside another path: /opt/homebrew/bin is not /homebrew/bin.
ABS_PATH = re.compile(r"(?<![\w./~-])(?:~|/home|/Users|/root|/Volumes|/mnt)(?=[/\s'\"`;|&)\\]|$)[^\s'\"`;|&)\\]*")
ERROR = re.compile(r"Error|error:|Traceback|\bE\d{4}\b")
DEFAULT_ALLOWED = ("/tmp", "/private/tmp", "/var/folders", "/dev/null", "/proc", "/usr", "/etc", "/opt")


def tool_counts(events: list[tr.Event]) -> dict:
    out: dict[str, Counter] = defaultdict(Counter)
    for e in events:
        if e.type == "tool_call":
            out[e.role][e.kind or "other"] += 1
    return {role: {"total": sum(c.values()), **dict(c)} for role, c in out.items()}


def outside_paths(events: list[tr.Event], ws: Path, allowed: list[str] = (), home: str = "") -> list[dict]:
    ok = tuple(DEFAULT_ALLOWED) + tuple(allowed)
    hits = []
    for e in events:
        if e.type != "tool_call":
            continue
        for p in ABS_PATH.findall(json.dumps(e.input)):
            if p.startswith("~") and home:
                p = home + p[1:]
            if p.startswith(str(ws)) or p.startswith(ok) or (home and p.startswith(f"{home}/.cache")):
                continue
            hits.append({"role": e.role, "seq": e.seq, "tool": e.tool, "path": p})
    return hits


def skills_used(events: list[tr.Event]) -> dict:
    used: dict[str, Counter] = defaultdict(Counter)
    for e in events:
        if e.type != "tool_call":
            continue
        if e.kind == "skill":
            name = e.input.get("skill") or e.input.get("name") or e.input.get("command") or e.tool
            used[e.role][str(name)] += 1
        else:
            for n in set(SKILL_DIRS.findall(json.dumps(e.input))):
                used[e.role][n] += 1
    return {role: dict(c) for role, c in used.items()}


def source_reads(events: list[tr.Event], patterns: list[str]) -> dict:
    pat = re.compile("|".join(f"(?:{p})" for p in patterns)) if patterns else None
    out: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    for e in events:
        if e.type != "tool_call":
            continue
        out[e.role][1] += 1
        s = json.dumps(e.input)
        if pat and pat.search(s) and not SKILL_DIRS.search(s):
            out[e.role][0] += 1
    return {role: {"source_reads": a, "tool_calls": b} for role, (a, b) in out.items()}


def command_checks(events: list[tr.Event], checks: dict[str, str], role: str = "builder") -> dict:
    res = {}
    for name, rx in checks.items():
        pat = re.compile(rx)
        pending, calls, failed = set(), 0, 0
        for e in events:
            if e.role != role:
                continue
            if e.type == "tool_call" and e.kind == "bash":
                cmd = str(e.input.get("command", e.input.get("cmd", "")))
                if pat.search(cmd):
                    calls += 1
                    pending.add(e.call_id)
            elif e.type == "tool_result" and e.call_id in pending:
                pending.discard(e.call_id)
                if e.is_error or ERROR.search(e.output or ""):
                    failed += 1
        res[name] = {"calls": calls, "with_errors": failed}
    return res


def model_calls(events: list[tr.Event]) -> dict:
    """Model calls the agent itself reported, per role."""
    c = Counter(e.role for e in events if e.type == "usage")
    return dict(c)


def analyze(trace_path: Path, ws: Path, *, allowed: list[str] = (), source_patterns: list[str] = (),
            checks: dict | None = None, home: str = "") -> dict:
    events = list(tr.read(trace_path))
    return {
        "tool_counts": tool_counts(events),
        "model_calls_self_reported": model_calls(events),
        "skills_used": skills_used(events),
        "source_reads": source_reads(events, list(source_patterns)),
        "command_checks": command_checks(events, checks or {}),
        "outside_paths": outside_paths(events, ws, list(allowed), home),
    }
