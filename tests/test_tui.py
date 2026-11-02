"""The TUI, driven headless: home lists the run, the run screen lists its
build, the build screen shows the trace and the metered calls."""

import asyncio

from textual.widgets import DataTable, RichLog

from agent_bench.config import Experiment
from agent_bench.runner import run
from agent_bench.tui import BuildScreen, AgentBench, ReportScreen, RunScreen

from test_end_to_end import api, experiment  # noqa: F401 - fixture


def test_tui_walkthrough(tmp_path, api):  # noqa: F811
    exp = experiment(tmp_path, api, "accept-loop")
    run(Experiment.load(exp))

    async def go():
        app = AgentBench(tmp_path / "runs", [tmp_path])
        async with app.run_test(size=(160, 50)) as pilot:
            await pilot.pause()
            home = app.screen
            runs = home.query_one("#runs", DataTable)
            assert runs.row_count == 1
            assert home.query_one("#exps", DataTable).row_count == 1
            runs.focus()
            await pilot.press("enter")
            await pilot.pause()
            assert isinstance(app.screen, RunScreen)
            builds = app.screen.query_one("#builds", DataTable)
            assert builds.row_count == 1
            assert "works" in str(builds.get_row_at(0)[2])
            assert app.screen.query_one("#tail", RichLog).lines  # the trace tail shows
            await pilot.press("a")
            await pilot.pause()
            assert isinstance(app.screen, ReportScreen)
            assert app.screen.query_one(DataTable).row_count == 1
            await pilot.press("escape")
            await pilot.press("enter")
            await pilot.pause()
            assert isinstance(app.screen, BuildScreen)
            assert app.screen.query_one("#calls", DataTable).row_count == 4
            await pilot.press("escape", "escape", "q")

    asyncio.run(go())
