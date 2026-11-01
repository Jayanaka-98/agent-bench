"""Tasks, arms and experiments, loaded from TOML.

Paths inside a file are relative to that file. Text fields are templates:
`${name}` is replaced from the build's context (see `Build.context` in
runner.py: ws, arm_dir, framework, port, python, run_id, build, ...), and an
unknown `${name}` is left as it is, so code in a spec is never mangled.

**task.toml**

    id = "meeting-assistant"
    [workspace]
    kind = "git"                 # or "dir" (copy `path`)
    repo = "/path/to/repo.git"   # git: repo + ref + paths to export
    ref = "parity/apples-to-apples"
    paths = ["meeting-assistant", "bench"]
    strip = ["meeting-assistant/byLLM", "meeting-assistant/langgraph"]   # arms removed
    keep = []                    # paths under `strip` that stay (shared files)
    slot = "meeting-assistant/${slot}"     # the directory the builder writes
    slots = { byllm = "byLLM", default = "${framework}" }
    [prompt]
    parts = ["spec.md"]          # the task's text, first in the prompt
    notes = "notes.md"           # machine notes, last; `${extras}` gets the extras
    [env]                        # extra environment for the builder and acceptance
    [accept]
    command = "python ${task_dir}/accept.py ${ws} --out ${verdict}"
    describe = "all 10 cases complete"   # told to the builder
    timeout = 1800
    [analyze]
    command_checks = { jac = '\\bjac (check|run)\\b' }
    allowed_outside = ["/opt/jac"]

**arm.toml**

    id = "jac-v10"
    framework = "byllm"
    prompt_parts = ["suffixes/byllm-0.37.md"]
    skills = ["skills/byllm-v10"]
    notes = "- **Skill.** ..."
    source_patterns = ['\\.cache/jac', 'site-packages/byllm']
"""

from __future__ import annotations

import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from .agents.base import BuilderSpec

_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def render(text: str, ctx: dict) -> str:
    return _VAR.sub(lambda m: str(ctx[m.group(1)]) if m.group(1) in ctx else m.group(0), text)


def _load(path: Path) -> dict:
    return tomllib.loads(path.read_text())


def _read_part(base: Path, p: str) -> str:
    return (base / p).read_text()


@dataclass
class Task:
    id: str
    dir: Path
    workspace: dict
    prompt_parts: list[str]
    notes: str
    env: dict
    accept: dict
    analyze: dict
    description: str = ""

    @classmethod
    def load(cls, path: Path) -> "Task":
        path = Path(path).resolve()
        f = path / "task.toml" if path.is_dir() else path
        d = _load(f)
        p = d.get("prompt", {})
        notes = p.get("notes", "")
        if notes and (f.parent / notes).is_file():
            notes = (f.parent / notes).read_text()
        return cls(id=d["id"], dir=f.parent, workspace=d.get("workspace", {}),
                   prompt_parts=p.get("parts", []), notes=notes, env=d.get("env", {}),
                   accept=d.get("accept", {}), analyze=d.get("analyze", {}),
                   description=d.get("description", ""))

    def slot(self, arm: "Arm") -> str:
        """The directory the builder writes, relative to the workspace."""
        slots = self.workspace.get("slots", {})
        name = slots.get(arm.framework, slots.get("default", arm.framework))
        name = render(name, {"framework": arm.framework, "arm": arm.id})
        return render(self.workspace.get("slot", "${slot}"), {"slot": name, "framework": arm.framework})

    def text(self) -> str:
        return "\n".join(_read_part(self.dir, p).rstrip() for p in self.prompt_parts)


@dataclass
class Arm:
    id: str
    framework: str
    dir: Path
    prompt_parts: list[str] = field(default_factory=list)
    skills: list[str] = field(default_factory=list)
    notes: str = ""
    source_patterns: list[str] = field(default_factory=list)
    env: dict = field(default_factory=dict)
    description: str = ""

    @classmethod
    def load(cls, spec, base: Path) -> "Arm":
        if isinstance(spec, dict):
            d, adir = spec, base
        else:
            f = (base / spec).resolve()
            d, adir = _load(f), f.parent
        return cls(id=d["id"], framework=d.get("framework", d["id"]), dir=adir,
                   prompt_parts=d.get("prompt_parts", []), skills=d.get("skills", []),
                   notes=d.get("notes", ""), source_patterns=d.get("source_patterns", []),
                   env=d.get("env", {}), description=d.get("description", ""))

    def text(self) -> str:
        return "\n".join(_read_part(self.dir, p).rstrip() for p in self.prompt_parts)

    def skill_dirs(self) -> list[Path]:
        return [(self.dir / s).resolve() for s in self.skills]


@dataclass
class Experiment:
    run_id: str
    file: Path
    runs_dir: Path
    tasks: list[Task]
    arms: list[Arm]
    builders: list[BuilderSpec]
    pairs: list[tuple[str, str]] | None  # (task, arm) pairs to build; None = all
    reps: int = 1
    lanes: int = 1
    lane_by: str = "builder"
    protocol: str = "one-shot"
    max_rounds: int = 5
    budget: dict = field(default_factory=dict)
    port_base: int = 8650
    driver: dict = field(default_factory=dict)
    proxy: dict = field(default_factory=dict)
    gates: list[str] = field(default_factory=list)
    min_free_gb: float = 3.0
    env: dict = field(default_factory=dict)
    raw: dict = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path, run_id: str | None = None) -> "Experiment":
        f = Path(path).resolve()
        d, base = _load(f), f.parent
        tasks = [Task.load(base / t) for t in d["tasks"]]
        arms = [Arm.load(a, base) for a in d["arms"]]
        builders = [BuilderSpec(name=b["name"], agent=b["agent"], model=b.get("model", ""),
                                endpoint=b.get("endpoint", ""), options=b.get("options", {}))
                    for b in d["builders"]]
        pairs = [tuple(p.split(":", 1)) for p in d["pairs"]] if "pairs" in d else None
        return cls(run_id=run_id or d["run_id"], file=f,
                   runs_dir=(base / d.get("runs_dir", "runs")).resolve(),
                   tasks=tasks, arms=arms, builders=builders, pairs=pairs,
                   reps=d.get("reps", 1), lanes=d.get("lanes", 1),
                   lane_by=d.get("lane_by", "builder"), protocol=d.get("protocol", "one-shot"),
                   max_rounds=d.get("max_rounds", 5), budget=d.get("budget", {}),
                   port_base=d.get("port_base", 8650), driver=d.get("driver", {}),
                   proxy=d.get("proxy", {}), gates=d.get("gates", []),
                   min_free_gb=d.get("min_free_gb", 3.0), env=d.get("env", {}), raw=d)
