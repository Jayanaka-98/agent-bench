"""Whole builds, with scripted agents against a fake model API: workspace,
prompt, proxy metering, protocol, acceptance, trace, analysis and summary."""

import json
import sys
from pathlib import Path

import pytest

from agent_bench.config import Experiment
from agent_bench.report import aggregate, status
from agent_bench.runner import run

from fakes import Served, fake_api, free_port

ROOT = Path(__file__).resolve().parent.parent
FIX = Path(__file__).resolve().parent / "fixtures"


@pytest.fixture()
def api():
    s = Served()
    url = s.serve(fake_api(), free_port())
    yield url
    s.close()


def experiment(tmp_path: Path, api: str, protocol: str, extra_args: list[str] = (), driver: bool = False) -> Path:
    py = sys.executable
    argv = [py, str(FIX / "fake_builder.py"), "${message_file}", "${ws}", "${base_url}", *extra_args]
    text = f"""
run_id = "t1"
runs_dir = "{tmp_path / 'runs'}"
tasks = ["{ROOT / 'examples/tasks/wordfreq'}"]
arms = ["{ROOT / 'examples/arms/stdlib-skill.toml'}"]
protocol = "{protocol}"
max_rounds = 3
lanes = 1
min_free_gb = 0
port_base = {free_port()}

[[builders]]
name = "fake"
agent = "command"
model = "fake"
endpoint = "anthropic"
[builders.options]
argv = {json.dumps(argv)}

[proxy]
port = {free_port()}
[proxy.upstreams.anthropic]
url = "{api}"
api = "anthropic"
"""
    if driver:
        text += f"""
[driver]
model = "fake"
endpoint = "anthropic"
[driver.options]
bin = "{FIX / 'fake_claude.py'}"
"""
    f = tmp_path / "exp.toml"
    f.write_text(text)
    (FIX / "fake_claude.py").chmod(0o755)
    return f


def only_summary(tmp_path) -> dict:
    [s] = list((tmp_path / "runs" / "t1").glob("*/summary.json"))
    return json.loads(s.read_text())


def test_accept_loop_resends_and_meters(tmp_path, api):
    run(Experiment.load(experiment(tmp_path, api, "accept-loop")))
    s = only_summary(tmp_path)
    assert s["status"] == "works"
    assert s["acceptance_runs"] == 2 and s["resent_without_resume"] == 1
    assert s["rounds"] == 2  # an accept-loop round is a builder turn, then a check
    b = s["tokens"]["builder"]
    # 2 turns x 2 calls; plain call 11+900+40+5, streamed 11+900+40+25
    assert b["source"] == "metered" and b["calls"] == 4 and b["total"] == 2 * (956 + 976)
    bdir = tmp_path / "runs" / "t1" / s["build"]
    prompt = (bdir / "prompt-builder.md").read_text()
    assert "# Build: wordfreq" in prompt and "Success criterion" in prompt and "`wordfreq/`" in prompt
    assert (bdir / "ws" / ".agent-skills" / "text-processing" / "SKILL.md").exists()
    assert len((bdir / "calls.jsonl").read_text().splitlines()) == 4
    assert "+def top_words" in (bdir / "final.patch").read_text()
    assert s["arm_loc"]["lines_added"] > 10
    agg = aggregate([tmp_path / "runs" / "t1"])
    assert agg[0]["works"] == 1 and agg[0]["tokens_median"] == b["total"]
    assert status(tmp_path / "runs" / "t1")[0]["state"] == "finished"


def test_one_shot_failure_is_recorded(tmp_path, api):
    run(Experiment.load(experiment(tmp_path, api, "one-shot")))
    s = only_summary(tmp_path)
    assert s["status"] == "done-not-working" and s["rounds"] == 1 and s["acceptance_runs"] == 1
    assert s["acceptance"]["metrics"]["passed_cases"] < s["acceptance"]["metrics"]["cases"]


def test_reviewed_with_claude_code_driver(tmp_path, api):
    run(Experiment.load(experiment(tmp_path, api, "reviewed", ["--solve"], driver=True)))
    s = only_summary(tmp_path)
    assert s["status"] == "works" and s["verdicts"] == ["DONE"] and s["rounds"] == 1
    d = s["tokens"]["driver"]
    assert d["source"] == "metered" and d["calls"] == 1
    assert d["self_reported"]["total"] == 240 and d["self_cost_usd"] == 0.01
    an = s["analysis"]
    assert an["tool_counts"]["driver"]["bash"] == 1
    # the driver's tool call reads /etc/hosts, which is allowed (under /etc)
    assert an["outside_paths"] == []


def test_rerun_skips_finished_builds(tmp_path, api):
    f = experiment(tmp_path, api, "one-shot", ["--solve"])
    run(Experiment.load(f))
    first = only_summary(tmp_path)["finished"]
    run(Experiment.load(f))
    assert only_summary(tmp_path)["finished"] == first
