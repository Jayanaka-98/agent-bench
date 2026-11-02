"""The agent-bench server: the API (api.jac) at /function/<name>, and the web
UI at /. Run with `agent-bench serve` (127.0.0.1:8770 by default)."""

import from agent_bench.server.api {
    info, list_runs, run_builds, monitor, build_info, build_trace, build_calls, build_file,
    aggregate, list_experiments, launch, stop_run, runner_log
}

import "./ui/app.css";
import from .ui.Shell { Shell }

def:pub app -> JsxElement {
    return <Shell />;
}
