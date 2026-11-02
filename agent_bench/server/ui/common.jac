"""Formatting and small pieces shared by the web UI's views."""

def fmt_tokens(n: float) -> str {
    if n >= 1000000 {
        return f"{n / 1000000:.2f}M";
    }
    if n >= 1000 {
        return f"{n / 1000:.0f}K";
    }
    return f"{n:.0f}";
}

def dur(s: float) -> str {
    t = int(max(s, 0));
    if t >= 3600 {
        return f"{t // 3600}h{(t % 3600) // 60:02d}m";
    }
    return f"{t // 60}m{t % 60:02d}s";
}

"""task__arm__builder__rK as task/arm/builder/rK."""
def short(build: str) -> str {
    return build.replace("__", "/");
}

def status_class(status: str) -> str {
    if status.startswith("limit") {
        return "s-limit";
    }
    if status.startswith("acceptance") {
        return "s-acceptance";
    }
    if status.startswith("driver") {
        return "s-driver";
    }
    return "s-" + status;
}

def quiet_class(s: float) -> str {
    if s > 900 {
        return "bad";
    }
    return "warn" if s > 300 else "dim";
}

"""One trace event as a single line of text."""
def event_text(e: dict[str, any]) -> str {
    kind = str(e["type"]);
    if kind == "tool_call" {
        inp = e["input"] or {};
        arg = inp["command"] or inp["file_path"] or inp["path"] or inp["pattern"] or inp["skill"] or "";
        return str(e["tool"]) + " " + str(arg);
    }
    if kind == "tool_result" {
        return "↳ " + str(e["output"] or "");
    }
    if kind == "final" {
        return "■ " + str(e["text"] or "");
    }
    if kind == "usage" {
        return "· model call";
    }
    return str(e["text"] or "");
}

def:pub Status(value: str) -> JsxElement {
    return <span className={"badge " + status_class(value)}>{value}</span>;
}

"""Tokens per minute over the last hour, as bars."""
def:pub Spark(values: list[float]) -> JsxElement {
    top = max(values) if len(values) > 0 else 0;
    return <div className="spark" title="tokens per minute, last hour">
        {for v in values {
            <i style={{"height": f"{(v / top * 100) if top > 0 else 0:.0f}%"}} />
        }}
    </div>;
}

def:pub Stat(label: str, value: str, cls: str = "") -> JsxElement {
    return <div className="stat"><b className={cls}>{value}</b><span>{label}</span></div>;
}
