"""One build: its live trace, metered calls, summary, prompt and acceptance."""

import from "react" { useEffect }
import from ..api { build_info, build_trace, build_calls, build_file }
import from .common { Status, dur, fmt_tokens, event_text }

def:pub BuildView(run: str, build: str) -> JsxElement {
    has info: dict[str, any] = {},
        events: list[dict[str, any]] = [],
        offset: int = 0,
        calls: list[dict[str, any]] = [],
        tab: str = "trace",
        text: str = "",
        filter: str = "",
        error: str = "";

    async def refresh {
        try {
            info = await build_info(run, build);
            t = await build_trace(run, build, offset, 5000);
            got: list[dict[str, any]] = t["events"] or [];
            if len(got) > 0 {
                events = events + got;
                offset = int(t["next"]);
            }
            error = "";
        } except Exception as e {
            error = str(e);
        }
    }

    async def show(name: str) {
        tab = name;
        if name == "calls" {
            calls = await build_calls(run, build);
        } elif name != "trace" {
            text = await build_file(run, build, name);
        }
    }

    useEffect(lambda {
        events = [];
        offset = 0;
        info = {};
        refresh();
        timer = setInterval(lambda { refresh(); }, 2000);
        return lambda { clearInterval(timer); };
    }, [run, build]);

    s = info["summary"];
    meta = info["meta"] or {};
    who = meta["builder"] or {};
    live = info["live"];
    shown = [e for e in events if not filter or filter.lower() in (str(e["kind"]) + " " + str(e["role"]) + " " + event_text(e)).lower()];

    return <div className="page">
        {error and <div className="err-box">{error}</div>}
        <div className="panel">
            <h2 style={{"textTransform": "none"}}>{build.replace("__", " / ")}</h2>
            <div className="row-actions">
                <Status value={str(s["status"]) if s else str(info["state"] or "")} />
                <span>{str(who["agent"] or "") + " " + str(who["model"] or "")}</span>
                {s and <span>{f"builder {fmt_tokens(float(s['tokens']['builder']['total']))} tokens ({s['tokens']['builder']['source']}, {s['tokens']['builder']['calls']} calls)"}</span>}
                {s and <span className="dim">{f"driver {fmt_tokens(float(s['tokens']['driver']['total']))}  ·  {s['rounds']} rounds  ·  {dur(float(s['wall_s']))}  ·  {s['acceptance_runs']} acceptance runs"}</span>}
                {(not s) and live and <span className="s-running">{str(live["phase"])}</span>}
                {(not s) and <span>{f"metered so far {fmt_tokens(float(info['metered_tokens'] or 0))} in {info['calls'] or 0} calls"}</span>}
            </div>
        </div>
        <div className="panel">
            <div className="tabs">
                {for name in ["trace", "calls", "summary.json", "prompt-builder.md", "acceptance", "final.patch"] {
                    <button key={name} className={"on" if tab == name else ""} onClick={lambda { show(name); }}>{name}</button>
                }}
                {tab == "trace" and <input placeholder="filter: kind, role or text" value={filter}
                    onChange={lambda (e: ChangeEvent) { filter = e.target.value; }} />}
            </div>
            {tab == "trace" and <div className="trace">
                {for (i, e) in enumerate(shown) {
                    <div key={str(i)} className={"tline" + (" result" if e["type"] == "tool_result" else "")
                        + (" err" if e["is_error"] else "") + " k-" + str(e["kind"] or "")}>
                        <span className="dim">{f"{e['seq'] or 0:02d} {str(e['role'] or '')[:7]} "}</span>{event_text(e)[:4000]}
                    </div>
                }}
                {len(shown) == 0 and <div className="note">no events yet</div>}
            </div>}
            {tab == "calls" and <table>
                <thead><tr><th>role</th><th>model</th><th className="num">input</th><th className="num">cache read</th>
                    <th className="num">cache write</th><th className="num">output</th><th className="num">total</th>
                    <th className="num">ms</th></tr></thead>
                <tbody>
                    {for (i, c) in enumerate(calls) {
                        <tr key={str(i)}>
                            <td>{str(c["role"])}</td><td className="dim">{str(c["model"] or "")}</td>
                            <td className="num">{str((c["usage"] or {})["input"] or "")}</td>
                            <td className="num">{str((c["usage"] or {})["cache_read"] or "")}</td>
                            <td className="num">{str((c["usage"] or {})["cache_write"] or "")}</td>
                            <td className="num">{str((c["usage"] or {})["output"] or "")}</td>
                            <td className="num">{str((c["usage"] or {})["total"] or "")}</td>
                            <td className="num dim">{str(c["ms"] or "")}</td>
                        </tr>
                    }}
                </tbody>
            </table>}
            {tab != "trace" and tab != "calls" and <pre className="file">{text or "(empty)"}</pre>}
        </div>
    </div>;
}
