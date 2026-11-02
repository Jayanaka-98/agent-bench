"""The monitor sees a build while it runs: its phase, its metered tokens, what
it is doing; and the monitor screen shows it."""

import asyncio
import json
import threading
import time
from pathlib import Path

from textual.widgets import DataTable, RichLog

from effortbench.config import Experiment
from effortbench.monitor import Monitor
from effortbench.runner import run
from effortbench.tui import EffortBench, MonitorScreen

from fakes import free_port
from test_end_to_end import ROOT, FIX, api  # noqa: F401 - fixture


def slow_claude_experiment(tmp_path: Path, api: str) -> Path:
    f = tmp_path / "exp.toml"
    f.write_text(f"""
run_id = "live"
runs_dir = "{tmp_path / 'runs'}"
tasks = ["{ROOT / 'examples/tasks/wordfreq'}"]
arms = ["{ROOT / 'examples/arms/stdlib.toml'}"]
protocol = "one-shot"
min_free_gb = 0
port_base = {free_port()}
[env]
FAKE_SLEEP = "6"
[[builders]]
name = "slow"
agent = "claude-code"
model = "fake"
endpoint = "anthropic"
options = {{ bin = "{FIX / 'fake_claude.py'}" }}
[proxy]
port = {free_port()}
[proxy.upstreams.anthropic]
url = "{api}"
api = "anthropic"
""")
    (FIX / "fake_claude.py").chmod(0o755)
    return f


def wait_for(cond, timeout=20.0):
    end = time.time() + timeout
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(0.3)
    raise AssertionError("timed out")


def test_monitor_sees_a_running_build(tmp_path, api):  # noqa: F811
    exp = Experiment.load(slow_claude_experiment(tmp_path, api))
    th = threading.Thread(target=run, args=(exp,), daemon=True)
    th.start()
    mon = Monitor([tmp_path / "runs"])

    def mid_turn():
        s = mon.scan()
        r = s.running[0] if s.running else None
        return s if r and r.phase == "builder turn 0" and r.tokens > 0 and r.action.startswith("Bash:") else None

    s = wait_for(mid_turn)
    r = s.running[0]
    assert r.agent == "claude-code" and r.calls == 1 and r.state == "running"
    assert s.counts["active_runs"] == 1 and s.counts["running"] == 1
    assert any(e.type == "tool_call" for _, e in s.feed)
    assert json.loads((tmp_path / "runs/live/plan.json").read_text())[0]["builder"] == "slow"

    async def ui():
        app = EffortBench(tmp_path / "runs", [tmp_path], monitor=[tmp_path / "runs"])
        async with app.run_test(size=(180, 50)) as pilot:
            await pilot.pause()
            assert isinstance(app.screen, MonitorScreen)
            assert app.screen.query_one("#running", DataTable).row_count == 1
            assert app.screen.query_one("#feed", RichLog).lines
            await pilot.press("q")

    asyncio.run(ui())
    th.join(60)
    s = mon.scan()
    assert s.running == [] and not (tmp_path / "runs/live/runner.pid").exists()
    [d] = [json.loads(p.read_text()) for p in (tmp_path / "runs/live").glob("*/summary.json")]
    assert not (tmp_path / "runs/live" / d["build"] / "live.json").exists()
