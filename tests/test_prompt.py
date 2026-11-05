"""What a build is given and how it is read back, without running an agent:
the builder prompt (slot line, criterion wording and placement, per-framework
task values, no skills comment for Claude Code), the allowed outside paths,
and which jac the launcher runs."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from agent_bench.analyze import outside_paths
from agent_bench.build import Build
from agent_bench.common import jac_bin
from agent_bench.config import Experiment, Task
from agent_bench.runner import run
from agent_bench.trace import Event

ROOT = Path(__file__).resolve().parent.parent
WORDFREQ = ROOT / "examples/tasks/wordfreq"

# The jac-paper harness's wording (run_builds.py compose_prompt).
PARITY = '''
[workspace.vars]
impl = { python = "Stdlib", default = "${framework}" }

[prompt]
parts = ["spec.md"]
notes = "notes.md"
slot_line = "- **Your arm directory** is `${arm_dir}/`."
criterion_at = "after-slot"

[accept]
command = "true"
describe = "the hidden test cases pass"
self_check = "python bench/run.py --impl ${impl}"
criterion = "- **Success criterion.** The build succeeds only if the agent works. After the review, the benchmark's own harness runs your arm: ${describe}. To run the same check yourself: `${self_check}`."
'''


def task_dir(tmp_path: Path, extra: str) -> Path:
    d = tmp_path / "task"
    shutil.copytree(WORDFREQ, d)
    head = (d / "task.toml").read_text().split("[prompt]")[0]  # id, [workspace]
    (d / "task.toml").write_text(head + extra)
    return d


def experiment(tmp_path: Path, task: Path, agent: str = "claude-code") -> Experiment:
    f = tmp_path / "exp.toml"
    f.write_text(f'''
run_id = "p1"
runs_dir = "{tmp_path / 'runs'}"
tasks = ["{task}"]
arms = ["{ROOT / 'examples/arms/stdlib-skill.toml'}"]
min_free_gb = 0
[[builders]]
name = "b"
agent = "{agent}"
model = "m"
[builders.options]
bin = "/bin/false"
argv = ["/bin/false"]
''')
    return Experiment.load(f)


def prompt_of(tmp_path: Path, exp: Experiment) -> tuple[str, Path]:
    run(exp, dry_run=True)
    [bdir] = list((tmp_path / "runs" / "p1").glob("*__*"))
    return (bdir / "prompt-builder.md").read_text(), bdir


def test_prompt_matches_run_builds_wording(tmp_path):
    text, bdir = prompt_of(tmp_path, experiment(tmp_path, task_dir(tmp_path, PARITY)))
    lines = text.splitlines()
    slot = lines.index("- **Your arm directory** is `wordfreq/`.")
    # the criterion right after the slot line, before the arm's note, with the
    # framework's own `impl` value in the self-check
    assert lines[slot + 1] == (
        "- **Success criterion.** The build succeeds only if the agent works. After the review, the "
        "benchmark's own harness runs your arm: the hidden test cases pass. To run the same check "
        "yourself: `python bench/run.py --impl Stdlib`.")
    assert lines[slot + 2].startswith("- **Skill.**")
    assert "Your work goes in" not in text
    # Claude Code finds its skills itself: installed, and not named in a comment
    assert "<!--" not in text
    assert (bdir / "ws" / ".claude" / "skills" / "text-processing" / "SKILL.md").exists()


def test_prompt_defaults_unchanged(tmp_path):
    exp = experiment(tmp_path, WORDFREQ, agent="command")
    text, _ = prompt_of(tmp_path, exp)
    lines = text.splitlines()
    slot = lines.index("- **Your work goes in** `wordfreq/`.")
    assert lines[slot + 1].startswith("- **Skill.**")
    assert lines[slot + 2].startswith("- **Skills.** These skills are in `.agent-skills/`")
    assert lines[slot + 3].startswith("- **Success criterion.** The build succeeds only if it works: the hidden")


def test_workspace_vars_per_framework(tmp_path):
    t = Task.load(task_dir(tmp_path, PARITY))
    exp = experiment(tmp_path, t.dir)
    arm = exp.arms[0]
    assert t.vars(arm) == {"impl": "Stdlib"}
    arm.framework = "langgraph"
    assert t.vars(arm) == {"impl": "langgraph"}  # the default, rendered
    b = Build(exp=exp, task=t, arm=exp.arms[0], spec=exp.builders[0], rep=1, port=1)
    ctx = b.context()
    assert ctx["impl"] == "langgraph" and ctx["arm_dir"] == "wordfreq"


def test_skills_dir_follows_the_adapter(tmp_path):
    exp = experiment(tmp_path, WORDFREQ)
    spec = exp.builders[0]
    for agent, where in (("claude-code", ".claude/skills"), ("codex", ".agents/skills"),
                         ("command", ".agent-skills")):
        spec.agent = agent
        b = Build(exp=exp, task=exp.tasks[0], arm=exp.arms[0], spec=spec, rep=1, port=1)
        assert b.context()["skills_dir"] == where


def test_bad_criterion_placement_is_refused(tmp_path):
    with pytest.raises(ValueError, match="criterion_at"):
        Task.load(task_dir(tmp_path, PARITY.replace('"after-slot"', '"first"')))


def test_driver_scratch_is_not_outside(tmp_path):
    exp = experiment(tmp_path, WORDFREQ)
    b = Build(exp=exp, task=exp.tasks[0], arm=exp.arms[0], spec=exp.builders[0], rep=1, port=1)
    # as on a build machine: the build directory under /home
    bdir = Path("/home/u/runs/p1/x__r1")
    b.dir, b.ws = bdir, bdir / "ws"
    allowed = b.allowed_outside()
    ev = [Event(type="tool_call", role="driver", seq=1, tool="Write",
                input={"file_path": f"{bdir}/driver-scratch/notes.md"}),
          Event(type="tool_call", role="driver", seq=1, tool="Read",
                input={"file_path": "/home/u/runs/p1/other__r1/ws/x.py"})]
    hits = outside_paths(ev, b.ws, allowed)
    assert [h["path"] for h in hits] == ["/home/u/runs/p1/other__r1/ws/x.py"]


def test_jac_bin_ignores_jac_bin(monkeypatch, tmp_path):
    monkeypatch.setenv("JAC_BIN", str(tmp_path))  # a directory, as the jac-paper env.sh sets it
    monkeypatch.delenv("AGENT_BENCH_JAC", raising=False)
    assert jac_bin() != str(tmp_path)
    monkeypatch.setenv("AGENT_BENCH_JAC", "/opt/jac-0.37/jac")
    assert jac_bin() == "/opt/jac-0.37/jac"


def test_launcher_uses_agent_bench_jac(tmp_path):
    fake = tmp_path / "fakejac"
    fake.write_text('#!/bin/sh\necho "fakejac $*"\n')
    fake.chmod(0o755)
    env = {**os.environ, "JAC_BIN": str(tmp_path), "AGENT_BENCH_JAC": str(fake)}
    out = subprocess.run([str(ROOT / "bin/agent-bench"), "agents"], env=env, capture_output=True, text=True)
    assert out.returncode == 0 and out.stdout.startswith("fakejac run ") and out.stdout.rstrip().endswith("-- agents")
    # JAC_BIN a directory and no AGENT_BENCH_JAC: `jac` on PATH, which works
    env.pop("AGENT_BENCH_JAC")
    out = subprocess.run([str(ROOT / "bin/agent-bench"), "--help"], env=env, capture_output=True, text=True,
                         timeout=300)
    assert out.returncode == 0, out.stderr
    assert "Is a directory" not in out.stderr
