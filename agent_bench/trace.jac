"""The one trace format every builder's log is converted to.

Each adapter reads its agent's native log and yields `Event`s. The analyzers
(analyze.jac), the reports and the supervising Claude session all read
`trace.jsonl`, so none of them needs to know which agent ran.

An event is one of:

    message      assistant text (`text`)
    tool_call    a tool use: `tool` (native name), `kind` (normalized), `input`, `call_id`
    tool_result  its result: `call_id`, `output`, `is_error`
    usage        one model call's tokens, as the agent itself reported them
    final        the turn's last message (`text`), its session id and error state
"""

import json;
import from pathlib { Path }
import from agent_bench.common { Json }

glob KINDS: list[str] = ["bash", "read", "write", "edit", "search", "skill", "web", "subagent", "plan", "other"];

"""Native tool names to kind, across the agents with adapters. Lower-cased."""
glob TOOL_KINDS: dict[str, str] = {
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
    "file_change": "edit", "web_search": "web"
};

glob EVENT_FIELDS: list[str] = [
    "type", "role", "seq", "text", "tool", "kind", "call_id", "input", "output", "is_error",
    "model", "usage", "session", "ts"
];

def tool_kind(name: str, inp: Json | None = None) -> str {
    n = (name or "").lower();
    # OpenHands' file editor is one tool with a `command` argument.
    if n in ("str_replace_editor", "file_editor", "edit_file") {
        cmd = str((inp or {}).get("command", ""));
        if cmd == "view" {
            return "read";
        }
        return "write" if cmd == "create" else "edit";
    }
    if n.startswith("mcp__") {
        return "other";
    }
    return TOOL_KINDS.get(n, "other");
}

obj Event {
    has `type: str,
        role: str = "",
        seq: int = 0,
        text: str = "",
        tool: str = "",
        kind: str = "",
        call_id: str = "",
        input: Json = {},
        output: str = "",
        is_error: bool = False,
        model: str = "",
        usage: Json | None = None,
        session: str = "",
        ts: str = "";

    def to_dict -> Json {
        return {
            "type": self.`type, "role": self.role, "seq": self.seq, "text": self.text,
            "tool": self.tool, "kind": self.kind, "call_id": self.call_id, "input": self.input,
            "output": self.output, "is_error": self.is_error, "model": self.model,
            "usage": self.usage, "session": self.session, "ts": self.ts
        };
    }

    def to_json -> str {
        d = {k: v for (k, v) in self.to_dict().items() if k == "type" or v not in ("", None, {}, False)};
        return json.dumps(d, ensure_ascii=False);
    }

    static def from_dict(d: Json) -> Event {
        return Event(**{k: v for (k, v) in d.items() if k in EVENT_FIELDS});
    }
}

def write(path: Path, events: Iterable[Event], append: bool = True) -> int {
    n = 0;
    with path.open("a" if append else "w") as f {
        for ev in events {
            f.write(ev.to_json() + "\n");
            n += 1;
        }
    }
    return n;
}

def read(path: Path) -> list[Event] {
    out: list[Event] = [];
    if not path.exists() {
        return out;
    }
    for line in path.read_text(errors="replace").splitlines() {
        try {
            d = json.loads(line);
        } except ValueError {
            continue;
        }
        if isinstance(d, dict) {
            out.append(Event.from_dict(d as Json));
        }
    }
    return out;
}

"""A tool result's content as text, whatever shape the agent used."""
def text_of(content: any) -> str {
    if content is None {
        return "";
    }
    if isinstance(content, str) {
        return content;
    }
    if isinstance(content, list) {
        parts: list[str] = [];
        for c in content {
            if isinstance(c, dict) {
                cd = c as Json;
                parts.append(text_of(cd.get("text", cd.get("content"))));
            } else {
                parts.append(text_of(c));
            }
        }
        return "\n".join(parts);
    }
    if isinstance(content, dict) {
        cd = content as Json;
        return text_of(cd.get("text", cd.get("output", cd.get("content"))));
    }
    return str(content);
}
