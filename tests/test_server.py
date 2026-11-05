"""The served API, end to end: `agent-bench serve` (jac run) on a real port;
a run launched over HTTP, followed to the end over HTTP; and the TUI reading
the same server."""

import asyncio
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest
from textual.widgets import DataTable

from agent_bench.tui import AgentBench, BuildScreen, HttpApi, RunScreen

from fakes import free_port
from test_end_to_end import ROOT, api as fake_api_url, experiment  # noqa: F401 - fixture

JAC = os.environ.get("AGENT_BENCH_JAC") or shutil.which("jac")


@pytest.fixture()
def server(tmp_path, fake_api_url):  # noqa: F811
    exp = experiment(tmp_path, fake_api_url, "one-shot", ["--solve"])
    port = free_port()
    log = (tmp_path / "serve.log").open("w")
    p = subprocess.Popen([str(ROOT / "bin/agent-bench"), "serve", "--no-client", "--port", str(port),
                          "--runs", str(tmp_path / "runs"), "--experiments", str(tmp_path)],
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                         env={**os.environ, "AGENT_BENCH_JAC": JAC})
    client = HttpApi(base=f"http://127.0.0.1:{port}")
    for _ in range(240):
        try:
            client.call("info")
            break
        except OSError:
            time.sleep(0.5)
    else:
        p.kill()
        raise AssertionError((tmp_path / "serve.log").read_text()[-3000:])
    yield client, exp, tmp_path
    os.killpg(p.pid, 15)
    p.wait(20)


def test_launch_and_follow_over_http(server):
    client, exp, tmp_path = server
    [e] = client.call("list_experiments")
    launched = client.call("launch", {"experiment": e["path"]})
    assert launched["run"] == "t1"
    for _ in range(240):
        runs = client.call("list_runs")
        if runs and runs[0]["finished"] == 1 and not runs[0]["alive"]:
            break
        time.sleep(0.5)
    else:
        raise AssertionError((tmp_path / "runs/t1/runner.log").read_text()[-3000:])
    [b] = client.call("run_builds", {"run": "t1"})
    assert b["status"] == "works"
    assert client.call("build_info", {"run": "t1", "build": b["build"]})["summary"]["tokens"]["builder"]["calls"] == 2
    assert "launched" in client.call("runner_log", {"run": "t1"})

    async def tui():
        app = AgentBench(tmp_path / "unused", [], server=client.base)
        async with app.run_test(size=(160, 50)) as pilot:
            await pilot.pause()
            runs = app.screen.query_one("#runs", DataTable)
            assert runs.row_count == 1
            runs.focus()
            await pilot.press("enter")
            await pilot.pause()
            assert isinstance(app.screen, RunScreen)
            await pilot.press("enter")
            await pilot.pause()
            assert isinstance(app.screen, BuildScreen)
            assert app.screen.query_one("#calls", DataTable).row_count == 2
            await pilot.press("escape", "escape", "q")

    asyncio.run(tui())
