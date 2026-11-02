"""Everything running now, across runs: the web UI's monitor view."""

import from "react" { useEffect }
import from ..api { monitor }
import from .common { Spark, Stat, Status, dur, fmt_tokens, quiet_class, short, event_text }

def:pub MonitorView(open_build: Callable[[str, str], None]) -> JsxElement {
    has snap: dict[str, any] = {},
        feed: list[dict[str, any]] = [],
        cursor: int = 0,
        error: str = "";

    async def refresh {
        try {
            s = await monitor(cursor);
            got: list[dict[str, any]] = s["feed"] or [];
            merged = feed + got;
            feed = merged[len(merged) - 400:] if len(merged) > 400 else merged;
            cursor = int(s["cursor"] or 0);
            snap = s;
            error = "";
        } except Exception as e {
            error = str(e);
        }
    }

    useEffect(lambda {
        refresh();
        timer = setInterval(lambda { refresh(); }, 2000);
        return lambda { clearInterval(timer); };
    }, []);

    counts: dict[str, any] = snap["counts"] or {};
    running: list[dict[str, any]] = snap["running"] or [];
    recent: list[dict[str, any]] = snap["recent"] or [];
    runs: list[dict[str, any]] = snap["runs"] or [];
    rate: list[float] = snap["rate"] or [];
    last10 = sum(rate[len(rate) - 10:]) if len(rate) >= 10 else sum(rate);
    disk = float(snap["disk_free_gb"] or 0);

    return <div className="page">
        {error and <div className="err-box">{error}</div>}
        <div className="panel">
            <div className="stats">
                <Stat label="active runs" value={str(counts["active_runs"] or 0)} />
                <Stat label="running" value={str(counts["running"] or 0)} cls="s-running" />
                <Stat label="queued" value={str(counts["queued"] or 0)} />
                <Stat label="stopped" value={str(counts["stopped"] or 0)} cls={"bad" if counts["stopped"] else "dim"} />
                <Stat label="finished" value={str(counts["finished"] or 0)} />
                <Stat label="work" value={str(counts["works"] or 0)} cls="ok" />
                <Stat label="tokens, last 10 min" value={fmt_tokens(last10)} />
                <Stat label="disk free" value={f"{disk:.1f} GB"} cls={"bad" if disk < 5 else ""} />
            </div>
            <div style={{"marginTop": "10px"}}><Spark values={rate} /></div>
            {for r in runs {
                <div className="note" key={str(r["run"])}>
                    <b>{str(r["run"])}</b>{" "}
                    <span className={"ok" if r["alive"] else "bad"}>{"runner alive" if r["alive"] else "runner dead"}</span>
                    {f"   {r['finished']}/{r['planned'] or '?'} finished, {r['works']} work, {r['running']} running, {r['queued']} queued"}
                </div>
            }}
            {len(runs) == 0 and <div className="note">nothing running</div>}
        </div>
        <div className="panel">
            <h2>Running now</h2>
            <table>
                <thead><tr><th>build</th><th>agent</th><th>phase</th><th>in phase</th><th className="num">tokens</th>
                    <th className="num">calls</th><th>quiet</th><th>doing now</th></tr></thead>
                <tbody>
                    {for r in running {
                        <tr className="row" key={str(r["dir"])}
                            onClick={lambda { open_build(str(r["run"]), str(r["build"])); }}>
                            <td>{short(str(r["build"]))}</td>
                            <td className="dim">{str(r["agent"]) + " " + str(r["model"])}</td>
                            <td><Status value={"stopped" if r["state"] == "stopped" else str(r["phase"])} /></td>
                            <td className="num">{dur(float(r["phase_s"]))}</td>
                            <td className="num">{fmt_tokens(float(r["tokens"]))}</td>
                            <td className="num">{str(r["calls"])}</td>
                            <td className={quiet_class(float(r["quiet_s"]))}>{dur(float(r["quiet_s"]))}</td>
                            <td className="dim">{str(r["action"])[:140]}</td>
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
        <div className="panel">
            <h2>Activity</h2>
            <div className="feed">
                {for f in feed {
                    <div className="ev" key={str(f["seq"])}>
                        <span className="dim">{str(f["seq"])}</span>
                        <span className="who">{str(f["build"])}</span>
                        <span className={"what k-" + str(f["event"]["kind"] or "")}>{event_text(f["event"])}</span>
                    </div>
                }}
            </div>
        </div>
        <div className="panel">
            <h2>Recently finished</h2>
            <table>
                <thead><tr><th>build</th><th>status</th><th className="num">tokens</th><th className="num">min</th></tr></thead>
                <tbody>
                    {for r in recent {
                        <tr className="row" key={str(r["dir"])}
                            onClick={lambda { open_build(str(r["run"]), str(r["build"])); }}>
                            <td>{short(str(r["build"]))}</td>
                            <td><Status value={str(r["status"])} /></td>
                            <td className="num">{fmt_tokens(float(r["tokens"]))}</td>
                            <td className="num">{str(r["min"])}</td>
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
    </div>;
}
