"""The one trace format every builder's log is converted to.

Each adapter reads its agent's native log and yields `Event`s. The analyzers
(analyze.py), the reports and the supervising Claude session all read
`trace.jsonl`, so none of them needs to know which agent ran.

An event is one of:

    message      assistant text (`text`)
    tool_call    a tool use: `tool` (native name), `kind` (normalized), `input`, `call_id`
    tool_result  its result: `call_id`, `output`, `is_error`
    usage        one model call's tokens, as the agent itself reported them
    final        the turn's last message (`text`), its session id and error state
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable, Iterator

KINDS = ("bash", "read", "write", "edit", "search", "skill", "web", "subagent", "plan", "other")

#: Native tool names → kind, across the agents with adapters. Lower-cased.
TOOL_KINDS = {
    # Claude Code
    "bash": "bash", "read": "read", "write": "write", "edit": "edit", "multiedit": "edit",
    "notebookedit": "edit", "glob": "search", "grep": "search", "ls": "search",
    "skill": "skill", "webfetch": "web", "websearch": "web", "task": "subagent",
    "agent": "subagent", "todowrite": "plan",
    # OpenCode
    "list": "search", "patch": "edit", "todoread": "plan",
    # OpenHands
    "execute_bash": "bash", "terminal": "bash", "cmd_run": "bash", "execute_ipython_cell": "bash",
    "browser": "web", "fetch": "web", "think": "plan", "task_tracker": "plan",
    # Codex
    "shell": "bash", "local_shell": "bash", "apply_patch": "edit", "command_execution": "bash",
    "file_change": "edit", "web_search": "web",
}


def tool_kind(name: str, inp: dict | None = None) -> str:
    n = (name or "").lower()
    # OpenHands' file editor is one tool with a `command` argument.
    if n in ("str_replace_editor", "file_editor", "edit_file"):
        cmd = (inp or {}).get("command", "")
        return {"view": "read", "create": "write"}.get(cmd, "edit")
    if n.startswith("mcp__"):
        return "other"
    return TOOL_KINDS.get(n, "other")


@dataclass
class Event:
    type: str
    role: str = ""
    seq: int = 0
    text: str = ""
    tool: str = ""
    kind: str = ""
    call_id: str = ""
    input: dict = field(default_factory=dict)
    output: str = ""
    is_error: bool = False
    model: str = ""
    usage: dict | None = None
    session: str = ""
    ts: str = ""

    def to_json(self) -> str:
        d = {k: v for k, v in asdict(self).items() if v not in ("", None, {}, False) or k == "type"}
        return json.dumps(d, ensure_ascii=False)


def write(path: Path, events: Iterable[Event], append: bool = True) -> int:
    n = 0
    with path.open("a" if append else "w") as f:
        for ev in events:
            f.write(ev.to_json() + "\n")
            n += 1
    return n


def read(path: Path) -> Iterator[Event]:
    if not path.exists():
        return
    names = set(Event.__dataclass_fields__)
    for line in path.read_text(errors="replace").splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        yield Event(**{k: v for k, v in d.items() if k in names})


def text_of(content) -> str:
    """A tool result's content as text, whatever shape the agent used."""
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(text_of(c.get("text", c.get("content")) if isinstance(c, dict) else c)
                         for c in content)
    if isinstance(content, dict):
        return text_of(content.get("text", content.get("output", content.get("content"))))
    return str(content)
