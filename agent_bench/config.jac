"""Tasks, arms and experiments, loaded from TOML.

Paths inside a file are relative to that file. Text fields are templates
(template.jac): `${name}` is replaced from the build's context (ws, arm_dir,
framework, port, python, run_id, build, ...), and an unknown `${name}` is left
as it is, so code in a spec is never mangled.

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
    [workspace.vars]             # per-framework template values, like `slots`
    impl = { byllm = "byLLM", langgraph = "LangGraph", default = "${framework}" }
    [prompt]
    parts = ["spec.md"]          # the task's text, first in the prompt
    notes = "notes.md"           # machine notes, last; `${extras}` gets the extras
    slot_line = "- **Your arm directory** is `${arm_dir}/`."   # first extra ("" drops it)
    criterion_at = "after-slot"  # or "after-notes" (default): where the criterion goes
    [env]                        # extra environment for the builder and acceptance
    [accept]
    command = "python ${task_dir}/accept.py ${ws} --out ${verdict}"
    describe = "all 10 cases complete"   # told to the builder
    self_check = "python bench/run.py --impl ${impl}"   # the check the builder can run
    criterion = "- **Success criterion.** ...: ${describe}. ... `${self_check}`."   # its wording
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

The builder prompt is the task's parts, the arm's parts, then the task's notes
with the extras: the slot line, the arm's notes, the adapter's skills note (none
for Claude Code, which lists `.claude/skills` itself) and the success criterion, which by default comes last; `criterion_at = "after-slot"`
puts it right after the slot line, as the jac-paper harness did. The defaults:

    slot_line = "- **Your work goes in** `${arm_dir}/`."
    criterion = "- **Success criterion.** The build succeeds only if it works: ${describe}"
                + " To run the same check yourself: `${self_check}`."  (if self_check is set)

`[workspace.vars]`: each `name = {framework = value, ..., default = value}` (or a
plain string, the same for every framework) is `${name}` in every template of
the build, rendered with `framework`, `arm` and `arm_dir`. A framework with no entry
and no `default` gets an empty string. Built-in names (`ws`, `arm_dir`, ...) win
over a var of the same name.
"""

import tomllib;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.template { render }
import from agent_bench.agents.base { BuilderSpec }

def _load(path: Path) -> Json {
    return tomllib.loads(path.read_text());
}

def _read_part(base: Path, p: str) -> str {
    return (base / p).read_text();
}

obj Task {
    has id: str,
        dir: Path,
        workspace: Json,
        prompt_parts: list[str],
        notes: str,
        env: Json,
        accept: Json,
        analyze: Json,
        prompt: Json = {},
        description: str = "";

    static def load(path: Path) -> Task {
        p0 = Path(path).resolve();
        f = p0 / "task.toml" if p0.is_dir() else p0;
        d = _load(f);
        p: Json = d.get("prompt", {});
        at = str(p.get("criterion_at", "after-notes"));
        if at not in ("after-slot", "after-notes") {
            raise ValueError(f"{f}: [prompt] criterion_at is after-slot or after-notes, not {at!r}");
        }
        notes = str(p.get("notes", ""));
        if notes and (f.parent / notes).is_file() {
            notes = (f.parent / notes).read_text();
        }
        return Task(
            id=str(d["id"]), dir=f.parent, workspace=d.get("workspace", {}),
            prompt_parts=[str(x) for x in p.get("parts", [])], notes=notes, env=d.get("env", {}),
            accept=d.get("accept", {}), analyze=d.get("analyze", {}), prompt=p,
            description=str(d.get("description", ""))
        );
    }

    """The directory the builder writes, relative to the workspace."""
    def slot(arm: Arm) -> str {
        slots: Json = self.workspace.get("slots", {});
        name = str(slots.get(arm.framework, slots.get("default", arm.framework)));
        name = render(name, {"framework": arm.framework, "arm": arm.id});
        return render(str(self.workspace.get("slot", "${slot}")), {"slot": name, "framework": arm.framework});
    }

    """Per-framework template values (`[workspace.vars]`) for this arm."""
    def vars(arm: Arm) -> dict[str, str] {
        table: Json = self.workspace.get("vars", {});
        ctx: dict[str, any] = {"framework": arm.framework, "arm": arm.id, "arm_dir": self.slot(arm)};
        out: dict[str, str] = {};
        for (name, spec) in table.items() {
            v: any = spec;
            if isinstance(spec, dict) {
                per = spec as Json;
                v = per.get(arm.framework, per.get("default", ""));
            }
            out[str(name)] = render(str(v), ctx);
        }
        return out;
    }

    def text -> str {
        return "\n".join([_read_part(self.dir, p).rstrip() for p in self.prompt_parts]);
    }
}

obj Arm {
    has id: str,
        framework: str,
        dir: Path,
        prompt_parts: list[str] = [],
        skills: list[str] = [],
        notes: str = "",
        source_patterns: list[str] = [],
        env: Json = {},
        description: str = "";

    static def load(spec: any, base: Path) -> Arm {
        d: Json = {};
        adir = base;
        if isinstance(spec, dict) {
            d = spec as Json;
        } else {
            f = (base / str(spec)).resolve();
            d = _load(f);
            adir = f.parent;
        }
        return Arm(
            id=str(d["id"]), framework=str(d.get("framework", d["id"])), dir=adir,
            prompt_parts=[str(x) for x in d.get("prompt_parts", [])], skills=[str(x) for x in d.get("skills", [])],
            notes=str(d.get("notes", "")), source_patterns=[str(x) for x in d.get("source_patterns", [])],
            env=d.get("env", {}), description=str(d.get("description", ""))
        );
    }

    def text -> str {
        return "\n".join([_read_part(self.dir, p).rstrip() for p in self.prompt_parts]);
    }

    def skill_dirs -> list[Path] {
        return [(self.dir / s).resolve() for s in self.skills];
    }
}

obj Experiment {
    has run_id: str,
        file: Path,
        runs_dir: Path,
        tasks: list[Task],
        arms: list[Arm],
        builders: list[BuilderSpec],
        pairs: list[tuple[str, str]] | None,   # (task, arm) pairs to build; None = all
        reps: int = 1,
        lanes: int = 1,
        lane_by: str = "builder",
        protocol: str = "one-shot",
        max_rounds: int = 5,
        budget: Json = {},
        port_base: int = 8650,
        driver: Json = {},
        proxy: Json = {},
        gates: list[str] = [],
        min_free_gb: float = 3.0,
        env: Json = {},
        raw: Json = {};

    static def load(path: Path, run_id: str | None = None) -> Experiment {
        f = Path(path).resolve();
        d = _load(f);
        base = f.parent;
        tasks = [Task.load(base / str(t)) for t in d["tasks"]];
        arms = [Arm.load(a, base) for a in d["arms"]];
        builders: list[BuilderSpec] = [];
        for b in d["builders"] {
            bd = b as Json;
            builders.append(BuilderSpec(
                name=str(bd["name"]), agent=str(bd["agent"]), model=str(bd.get("model", "")),
                endpoint=str(bd.get("endpoint", "")), options=bd.get("options", {})
            ));
        }
        pairs: list[tuple[str, str]] | None = None;
        if "pairs" in d {
            pairs = [];
            for pr in d["pairs"] {
                (t, a) = str(pr).split(":", 1);
                pairs.append((t, a));
            }
        }
        return Experiment(
            run_id=run_id or str(d["run_id"]), file=f, runs_dir=(base / str(d.get("runs_dir", "runs"))).resolve(),
            tasks=tasks, arms=arms, builders=builders, pairs=pairs,
            reps=int(d.get("reps", 1)), lanes=int(d.get("lanes", 1)), lane_by=str(d.get("lane_by", "builder")),
            protocol=str(d.get("protocol", "one-shot")), max_rounds=int(d.get("max_rounds", 5)),
            budget=d.get("budget", {}), port_base=int(d.get("port_base", 8650)), driver=d.get("driver", {}),
            proxy=d.get("proxy", {}), gates=[str(g) for g in d.get("gates", [])],
            min_free_gb=float(d.get("min_free_gb", 3.0)), env=d.get("env", {}), raw=d
        );
    }
}
