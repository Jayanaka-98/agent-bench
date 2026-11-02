"""Runs, a run's builds, its aggregate report, and the experiments to launch."""

import from "react" { useEffect }
import from ..api { list_runs, run_builds, aggregate, stop_run, list_experiments, launch, runner_log }
import from .common { Status, fmt_tokens, short }

def:pub RunsView(open_run: Callable[[str], None]) -> JsxElement {
    has runs: list[dict[str, any]] = [],
        error: str = "";

    async def refresh {
        try {
            runs = await list_runs();
            error = "";
        } except Exception as e {
            error = str(e);
        }
    }

    useEffect(lambda {
        refresh();
        timer = setInterval(lambda { refresh(); }, 3000);
        return lambda { clearInterval(timer); };
    }, []);

    return <div className="page">
        {error and <div className="err-box">{error}</div>}
        <div className="panel">
            <h2>Runs</h2>
            <table>
                <thead><tr><th>run</th><th className="num">finished</th><th className="num">work</th>
                    <th className="num">running</th><th>runner</th><th>started</th></tr></thead>
                <tbody>
                    {for r in runs {
                        <tr className="row" key={str(r["run"])} onClick={lambda { open_run(str(r["run"])); }}>
                            <td>{str(r["run"])}</td>
                            <td className="num">{f"{r['finished']}/{r['planned']}"}</td>
                            <td className="num ok">{str(r["works"])}</td>
                            <td className="num">{str(r["running"])}</td>
                            <td className={"ok" if r["alive"] else "dim"}>{"alive" if r["alive"] else "-"}</td>
                            <td className="dim">{str(r["started"])}</td>
                        </tr>
                    }}
                </tbody>
            </table>
            {len(runs) == 0 and <div className="note">no runs yet</div>}
        </div>
    </div>;
}

def:pub RunView(run: str, open_build: Callable[[str, str], None]) -> JsxElement {
    has builds: list[dict[str, any]] = [],
        agg: list[dict[str, any]] = [],
        group: str = "task,arm,builder",
        log: str = "",
        show_log: bool = False,
        error: str = "";

    async def refresh {
        try {
            builds = await run_builds(run);
            agg = await aggregate([run], group);
            error = "";
        } except Exception as e {
            error = str(e);
        }
    }

    async def stop {
        r = await stop_run(run);
        error = "" if r["stopped"] else str(r["reason"]);
    }

    async def toggle_log {
        show_log = not show_log;
        if show_log {
            log = await runner_log(run);
        }
    }

    useEffect(lambda {
        refresh();
        timer = setInterval(lambda { refresh(); }, 2000);
        return lambda { clearInterval(timer); };
    }, [run, group]);

    cols: list[str] = list(agg[0].keys()) if len(agg) > 0 else [];

    return <div className="page">
        {error and <div className="err-box">{error}</div>}
        <div className="panel">
            <div className="row-actions">
                <h2 style={{"margin": "0"}}>{run}</h2>
                <button className="act danger" onClick={stop}>Stop runner</button>
                <button className="act" onClick={toggle_log}>{"Hide log" if show_log else "Runner log"}</button>
            </div>
            {show_log and <pre className="file">{log or "(no runner.log: this run was not launched from a UI)"}</pre>}
        </div>
        <div className="panel">
            <h2>Builds</h2>
            <table>
                <thead><tr><th>build</th><th>state</th><th>status</th><th className="num">tokens</th>
                    <th className="num">calls</th><th className="num">min</th></tr></thead>
                <tbody>
                    {for b in builds {
                        <tr className="row" key={str(b["build"])} onClick={lambda { open_build(run, str(b["build"])); }}>
                            <td>{short(str(b["build"]))}</td>
                            <td><Status value={str(b["state"])} /></td>
                            <td>{b["status"] and <Status value={str(b["status"])} />}</td>
                            <td className="num">{fmt_tokens(float(b["builder_tokens"] or b["metered_tokens_so_far"] or 0))}</td>
                            <td className="num">{str(b["calls"] or b["calls_so_far"] or 0)}</td>
                            <td className="num">{str(b["wall_min"] or "")}</td>
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
        <div className="panel">
            <div className="row-actions">
                <h2 style={{"margin": "0"}}>Report</h2>
                <span className="note">group by</span>
                <input value={group} onChange={lambda (e: ChangeEvent) { group = e.target.value; }} />
            </div>
            <table>
                <thead><tr>{for c in cols { <th key={c}>{c}</th> }}</tr></thead>
                <tbody>
                    {for (i, r) in enumerate(agg) {
                        <tr key={str(i)}>
                            {for c in cols {
                                <td key={c} className={"num" if c.startswith("tokens") or c in ("builds", "works") else ""}>
                                    {fmt_tokens(float(r[c])) if c.startswith("tokens") else str(r[c])}
                                </td>
                            }}
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
    </div>;
}

def:pub ExperimentsView(open_run: Callable[[str], None]) -> JsxElement {
    has exps: list[dict[str, any]] = [],
        chosen: str = "",
        run_id: str = "",
        only: str = "",
        error: str = "";

    async can with entry {
        exps = await list_experiments();
        if len(exps) > 0 {
            chosen = str(exps[0]["path"]);
            run_id = str(exps[0]["run_id"]);
        }
    }

    def pick(path: str) {
        chosen = path;
        for e in exps {
            if str(e["path"]) == path {
                run_id = str(e["run_id"]);
            }
        }
    }

    async def go {
        try {
            filters = [w for w in only.split(" ") if w];
            r = await launch(chosen, run_id, filters);
            open_run(str(r["run"]));
        } except Exception as e {
            error = str(e);
        }
    }

    return <div className="page">
        {error and <div className="err-box">{error}</div>}
        <div className="panel">
            <h2>Launch an experiment</h2>
            <div className="row-actions">
                <select value={chosen} onChange={lambda (e: ChangeEvent) { pick(e.target.value); }}>
                    {for e in exps { <option key={str(e["path"])} value={str(e["path"])}>{str(e["name"])}</option> }}
                </select>
                <input placeholder="run id" value={run_id} onChange={lambda (e: ChangeEvent) { run_id = e.target.value; }} />
                <input placeholder="only (task, arm, builder…)" value={only}
                       onChange={lambda (e: ChangeEvent) { only = e.target.value; }} />
                <button className="act" onClick={go}>Launch</button>
            </div>
            <p className="note">The run starts as its own process: closing this page never stops it.
                Relaunching the same run id resumes it.</p>
        </div>
        <div className="panel">
            <h2>Experiments</h2>
            <table>
                <thead><tr><th>name</th><th>run id</th><th>path</th></tr></thead>
                <tbody>
                    {for e in exps {
                        <tr className="row" key={str(e["path"])} onClick={lambda { pick(str(e["path"])); }}>
                            <td>{str(e["name"])}</td><td>{str(e["run_id"])}</td><td className="dim">{str(e["path"])}</td>
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
    </div>;
}
