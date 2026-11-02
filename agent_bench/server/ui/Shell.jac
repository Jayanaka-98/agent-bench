"""The web UI's frame: navigation between the monitor, runs, a run, a build,
and the experiments."""

import from .Monitor { MonitorView }
import from .Runs { RunsView, RunView, ExperimentsView }
import from .Build { BuildView }

def:pub Shell -> JsxElement {
    has view: str = "monitor",
        run: str = "",
        build: str = "";

    def open_run(r: str) {
        run = r;
        build = "";
        view = "run";
    }

    def open_build(r: str, b: str) {
        run = r;
        build = b;
        view = "build";
    }

    return <div className="shell">
        <div className="nav">
            <span className="brand">agent-bench</span>
            <button className={"on" if view == "monitor" else ""} onClick={lambda { view = "monitor"; }}>Monitor</button>
            <button className={"on" if view in ("runs", "run", "build") else ""} onClick={lambda { view = "runs"; }}>Runs</button>
            <button className={"on" if view == "experiments" else ""} onClick={lambda { view = "experiments"; }}>Experiments</button>
            {view in ("run", "build") and <span className="crumbs">
                <span className="link" onClick={lambda { open_run(run); }}>{run}</span>
                {view == "build" and <span>{" / " + build.replace("__", "/")}</span>}
            </span>}
        </div>
        {view == "monitor" and <MonitorView open_build={open_build} />}
        {view == "runs" and <RunsView open_run={open_run} />}
        {view == "run" and <RunView run={run} open_build={open_build} />}
        {view == "build" and <BuildView run={run} build={build} />}
        {view == "experiments" and <ExperimentsView open_run={open_run} />}
    </div>;
}
