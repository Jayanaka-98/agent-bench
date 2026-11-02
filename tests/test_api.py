"""The server API in-process: what the web UI and the TUI both read."""

import pytest

import agent_bench.server.api as api
from agent_bench.config import Experiment
from agent_bench.runner import run

from test_end_to_end import api as fake_api_url, experiment  # noqa: F401 - fixture


@pytest.fixture()
def finished(tmp_path, fake_api_url):  # noqa: F811
    run(Experiment.load(experiment(tmp_path, fake_api_url, "accept-loop")))
    api.configure([tmp_path / "runs"], [tmp_path])
    return tmp_path


def test_runs_builds_and_files(finished):
    [r] = api.list_runs()
    assert r["run"] == "t1" and r["finished"] == 1 and r["works"] == 1 and not r["alive"]
    [b] = api.run_builds("t1")
    info = api.build_info("t1", b["build"])
    assert info["state"] == "finished" and info["summary"]["status"] == "works" and info["calls"] == 4
    assert "# Build: wordfreq" in api.build_file("t1", b["build"], "prompt-builder.md")
    assert "verdicts" in api.build_file("t1", b["build"], "acceptance")
    assert len(api.build_calls("t1", b["build"])) == 4
    assert api.aggregate(["t1"])[0]["works"] == 1


def test_trace_pages_by_offset(finished):
    b = api.run_builds("t1")[0]["build"]
    whole = api.build_trace("t1", b)
    assert whole["total"] == len(whole["events"]) > 0
    first = api.build_trace("t1", b, offset=0, limit=1)
    rest = api.build_trace("t1", b, offset=first["next"])
    assert first["events"] + rest["events"] == whole["events"]


def test_names_cannot_escape_the_runs_dir(finished):
    with pytest.raises(ValueError):
        api.run_builds("../t1")
    b = api.run_builds("t1")[0]["build"]
    with pytest.raises(ValueError):
        api.build_file("t1", b, "../../experiment.toml")


def test_launch_only_listed_experiments(finished, tmp_path):
    other = tmp_path / "elsewhere.toml"
    other.write_text('run_id = "x"\n')
    with pytest.raises(ValueError):
        api.launch(str(other))
    assert [e["name"] for e in api.list_experiments()] == ["exp"]  # the run's own copy is not listed


def test_monitor_feed_is_shared_by_cursor(finished):
    a = api.monitor(0)
    b = api.monitor(0)
    assert a["cursor"] == b["cursor"] and a["feed"] == b["feed"]  # two clients see the same feed
    assert api.monitor(a["cursor"])["feed"] == []
    assert a["counts"]["active_runs"] == 0  # the run is finished and its runner gone
