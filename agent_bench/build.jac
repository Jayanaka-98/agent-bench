"""One build: a task, an arm, a builder and a repetition.

Recorded under <runs>/<run-id>/<task>__<arm>__<builder>__r<k>/:

    build.json              who is building (written first, for monitors)
    live.json               while it runs: its phase and since when
    prompt-builder.md       exactly what the builder was given
    prompt-driver.md        the driver's brief (reviewed protocol)
    transcripts/            every agent invocation, in the agent's native output format
    invocations.jsonl       one row per invocation: agent, session, self-reported usage, time
    trace.jsonl             every invocation, normalized (trace.jac)
    calls.jsonl             this build's rows of the proxy ledger: one per model call
    native/                 the agents' own session files
    acceptance/             each acceptance run's log and verdict
    ws/                     the workspace; one commit per round
    final.patch             the work, as a diff against the prepared base
    summary.json            status, tokens (metered and self-reported) per role, analysis
"""

import json;
import os;
import re;
import shutil;
import sys;
import time;
import urllib.request;
import uuid;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.config { Arm, Experiment, Task }
import from agent_bench.template { render }
import from agent_bench.usage { Usage }
import from agent_bench.proxy { ledger_usage }
import from agent_bench.trace { write }
import from agent_bench.analyze { analyze }
import from agent_bench.protocols { Outcome, run_protocol }
import from agent_bench.agents.base { Agent, BuilderSpec, Endpoint, Turn, TurnRequest }
import from agent_bench.agents.registry { make }
import agent_bench.accept as accept;
import agent_bench.workspace as workspace;

glob DATA: Path = Path(__file__).resolve().parent / "data";
glob ROOT: Path = Path(__file__).resolve().parent.parent;
glob DRIVER_DENIED: list[str] = ["Edit", "Write", "NotebookEdit"];

def safe(s: str) -> str {
    return re.sub(r"[^A-Za-z0-9_.+-]", "-", s);
}

"""The interpreter builders see as `python` and acceptance commands run as
`${python}`: AGENT_BENCH_PYTHON, else the project's own venv, else python3.
(Under the jac runtime `sys.executable` is the jac binary, not a Python.)"""
def default_python -> str {
    if os.environ.get("AGENT_BENCH_PYTHON") {
        return os.environ["AGENT_BENCH_PYTHON"];
    }
    for name in ("python3", "python") {
        p = ROOT / ".jac" / "venv" / "bin" / name;
        if p.exists() {
            return str(p);
        }
    }
    return shutil.which("python3") or sys.executable;
}

"""A role's tokens: metered by the proxy (the measure) and self-reported by the
agent (a cross-check). A self-report that is cumulative per session counts
each session once, at its last turn that reported usage; summing turns would
count every round after the first again."""
def role_tokens(rows: list[Json], role: str, metered: Usage | None, cumulative: bool) -> Json {
    mine = [r for r in rows if r["role"] == role];
    self_u = Usage();
    cost = 0.0;
    picked: list[Json] = [];
    if cumulative {
        last: dict[str, Json] = {};
        for r in mine {
            if r.get("self_usage") {
                last[str(r["session"])] = r;
            }
        }
        picked = list(last.values());
    } else {
        picked = [r for r in mine if r.get("self_usage")];
    }
    for r in picked {
        self_u = self_u + Usage.from_dict(r["self_usage"]);
        cost += float(r.get("cost_usd") or 0.0);
    }
    has_metered = metered is not None and metered.calls > 0;
    head = metered if has_metered and metered is not None else self_u;
    return {
        "source": "metered" if has_metered else ("self" if picked else "none"),
        "total": head.total, "calls": head.calls,
        "metered": metered.to_dict() if metered is not None else None,
        "self_reported": self_u.to_dict() if picked else None,
        "self_cost_usd": round(cost, 4) if picked else None,
        "invocations": len(mine), "num_turns": sum([int(r.get("num_turns") or 0) for r in mine]),
        "wall_s": round(sum([float(r.get("wall_s") or 0) for r in mine]), 1)
    };
}

obj Build {
    has exp: Experiment,
        task: Task,
        arm: Arm,
        spec: BuilderSpec,
        rep: int,
        port: int,
        proxy_url: str = "",
        ledger: Path | None = None,
        log_fn: Callable[[str], None] = print,
        id: str postinit,
        dir: Path postinit,
        ws: Path postinit,
        slot: str postinit,
        tag: str = "";

    def postinit {
        self.id = safe(f"{self.task.id}__{self.arm.id}__{self.spec.name}__r{self.rep}");
        self.dir = self.exp.runs_dir / self.exp.run_id / self.id;
        self.ws = self.dir / "ws";
        self.proxy_url = self.proxy_url.rstrip("/");
        self.slot = self.task.slot(self.arm);
    }

    def log(msg: str) {
        self.log_fn(f"{self.id}: {msg}");
    }

    """What the build is doing now, for monitors: live.json while it runs."""
    def phase(text: str | None) {
        p = self.dir / "live.json";
        if text is None {
            p.unlink(missing_ok=True);
        } else {
            p.write_text(json.dumps({"phase": text, "since": time.time(), "pid": os.getpid()}));
        }
    }

    # ---- context ----------------------------------------------------------------

    def context -> dict[str, any] {
        python = str(self.exp.env.get("PYTHON") or default_python());
        return {
            "ws": str(self.ws), "bdir": str(self.dir), "task": self.task.id, "task_dir": str(self.task.dir),
            "arm": self.arm.id, "arm_dir": self.slot, "framework": self.arm.framework,
            "builder": self.spec.name, "agent": self.spec.agent, "model": self.spec.model,
            "port": self.port, "run_id": self.exp.run_id, "build": self.id, "rep": self.rep,
            "python": python, "python_bin": str(Path(python).parent), "home": os.path.expanduser("~")
        };
    }

    def environment(ctx: dict[str, any]) -> dict[str, str] {
        env: dict[str, str] = dict(os.environ);
        for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT") {
            env.pop(k, None);
        }
        for layer in (self.exp.env, self.task.env, self.arm.env) {
            for (k, v) in layer.items() {
                env[k] = render(str(v), {**ctx, **env});
            }
        }
        env["BUILD_PORT"] = str(self.port);
        return env;
    }

    def endpoint(upstream: str, role: str) -> Endpoint | None {
        if not upstream or not self.proxy_url {
            return None;
        }
        ups: Json = self.exp.proxy.get("upstreams", {});
        up: Json | None = ups.get(upstream);
        if up is None {
            raise KeyError(f"builder endpoint {upstream!r} is not a proxy upstream");
        }
        key = "metered" if up.get("key_env") else os.environ.get(str(up.get("client_key_env", "")), "");
        return Endpoint(upstream=upstream, api=str(up.get("api", "openai")),
                        base_url=f"{self.proxy_url}/{upstream}/{self.tag}.{role}", key=key);
    }

    # ---- tokens -----------------------------------------------------------------

    """Usage per role, from the proxy: from the ledger, or live over HTTP."""
    def metered -> dict[str, Usage] {
        prefix = f"{self.tag}.";
        per_tag: dict[str, Usage] = {};
        if self.ledger is not None and self.ledger.exists() {
            per_tag = ledger_usage(self.ledger, prefix);
        } elif self.proxy_url {
            try {
                with urllib.request.urlopen(f"{self.proxy_url}/__usage?prefix={prefix}", timeout=10) as r {
                    raw = json.loads(r.read()) as Json;
                    per_tag = {t: Usage.from_dict(u) for (t, u) in raw.items()};
                }
            } except OSError {
                per_tag = {};
            }
        }
        out: dict[str, Usage] = {};
        for (t, u) in per_tag.items() {
            role = t[len(prefix):];
            out[role] = out.get(role, Usage()) + u;
        }
        return out;
    }

    def budget -> float | None {
        b = self.exp.budget;
        if not b {
            return None;
        }
        per_task: Json = b.get("tasks", {});
        v = per_task.get(self.task.id, b.get("tokens"));
        return float(v) if v is not None else None;
    }

    def over_budget -> bool {
        cap = self.budget();
        if cap is None {
            return False;
        }
        roles: list[str] = self.exp.budget.get("counts", ["builder", "driver"]);
        m = self.metered();
        return sum([m.get(r, Usage()).total for r in roles]) >= cap;
    }

    # ---- the build --------------------------------------------------------------

    def run(dry_run: bool = False) -> Json {
        if (self.dir / "summary.json").exists() {
            return json.loads((self.dir / "summary.json").read_text()) as Json;
        }
        if self.dir.exists() {
            shutil.rmtree(self.dir);  # a half-finished build restarts cleanly
        }
        (self.dir / "transcripts").mkdir(parents=True);
        # A fresh tag per attempt, so an aborted attempt's calls never count.
        self.tag = f"{self.id}~{uuid.uuid4().hex[:6]}";
        # Who is building, for anything that reads the build while it runs.
        (self.dir / "build.json").write_text(json.dumps({
            "build": self.id, "task": self.task.id, "arm": self.arm.id, "rep": self.rep,
            "builder": {"name": self.spec.name, "agent": self.spec.agent, "model": self.spec.model,
                        "endpoint": self.spec.endpoint},
            "protocol": self.exp.protocol, "proxy_tag": self.tag,
            "started": datetime.now(timezone.utc).isoformat()
        }, indent=2));
        self.phase("preparing");
        ctx = self.context();
        base = workspace.prepare(self.task, self.ws, self.slot, ctx);
        env = self.environment(ctx);
        home = self.dir / "home";
        home.mkdir();
        builder = make(self.spec, self.endpoint(self.spec.endpoint, "builder"));
        (env_add, install_note) = builder.install(self.ws, home, self.arm.skill_dirs(), self.arm.notes);
        env.update(env_add);
        if self.arm.skills {
            base = workspace.snapshot(self.ws, "install skills");
        }
        prompt = self.compose(ctx, install_note);
        (self.dir / "prompt-builder.md").write_text(prompt);
        driver_intro = "";
        if self.exp.protocol == "reviewed" {
            scratch = self.dir / "driver-scratch";
            scratch.mkdir();
            tmpl = Path(str(self.exp.driver["prompt"])) if self.exp.driver.get("prompt") else DATA / "driver.md";
            if not tmpl.is_absolute() {
                tmpl = self.exp.file.parent / tmpl;
            }
            driver_intro = render(tmpl.read_text(), {**ctx, "spec": prompt, "scratch": str(scratch),
                                                     "max_rounds": self.exp.max_rounds});
            (self.dir / "prompt-driver.md").write_text(driver_intro);
        }
        if dry_run {
            self.log(f"prepared {self.ws} (dry run)");
            self.phase(None);
            return {"build": self.id, "status": "dry-run"};
        }
        d = self.exp.driver;
        driver = make(BuilderSpec(name="driver", agent="claude-code", model=str(d.get("model", "claude-opus-5-5")),
                                  endpoint=str(d.get("endpoint", "")), options=d.get("options", {})),
                      self.endpoint(str(d.get("endpoint", "")), "driver"));
        driver.install(self.ws, home, [], "");
        driver.has_skills = bool(self.arm.skills);  # its --safe-mode would hide them too
        session = Session(b=self, builder_agent=builder, driver_agent=driver, env=env, prompt=prompt,
                          driver_intro=driver_intro, ctx=ctx);
        t0 = time.time();
        meta: Json = {"agent_version": builder.version(), "driver_version": driver.version()};
        outcome = Outcome(status="error");
        try {
            outcome = run_protocol(self.exp.protocol, session);
        } except Exception as e {  # recorded, not raised: one build, not the run
            self.log(f"protocol crashed: {type(e).__name__}: {e}");
            meta["error"] = f"{type(e).__name__}: {e}";
        }
        return self.finish(outcome, base, t0, builder, driver, session, meta);
    }

    def compose(ctx: dict[str, any], install_note: str) -> str {
        extras: list[str] = [f"- **Your work goes in** `{self.slot}/`."];
        if self.arm.notes {
            extras.append(render(self.arm.notes.rstrip(), ctx));
        }
        if install_note {
            extras.append(install_note);
        }
        crit = accept.criterion(self.task, ctx);
        if crit {
            extras.append(crit);
        }
        ctx2 = {**ctx, "extras": "\n".join(extras)};
        parts = [render(self.task.text(), ctx), render(self.arm.text(), ctx)];
        notes = render(self.task.notes, ctx2) if self.task.notes else "";
        if "${extras}" not in self.task.notes {
            notes = (notes.rstrip() + "\n\n" if notes else "") + str(ctx2["extras"]);
        }
        return "\n".join([p.rstrip() for p in parts + [notes] if p.strip()]) + "\n";
    }

    def finish(outcome: Outcome, base: str, t0: float, builder: Agent, driver: Agent, session: Session,
               meta: Json) -> Json {
        self.phase("finishing");
        time.sleep(1);  # the proxy logs a streamed call just after the agent has read it
        final = workspace.snapshot(self.ws, "final");
        (self.dir / "final.patch").write_text(workspace.diff(self.ws, base, final));
        for src in builder.native_logs(self.ws) + driver.native_logs(self.ws) {
            if src.resolve() != (self.dir / "home").resolve() {
                shutil.copytree(src, self.dir / "native" / src.name, dirs_exist_ok=True);
            }
        }
        rows: list[Json] = [];
        inv = self.dir / "invocations.jsonl";
        if inv.exists() {
            rows = [json.loads(l) as Json for l in inv.read_text().splitlines()];
        }
        if self.ledger is not None and self.ledger.exists() {
            marker = f'"tag": "{self.tag}.';
            with (self.dir / "calls.jsonl").open("w") as f {
                for line in self.ledger.read_text(errors="replace").splitlines() {
                    if marker in line {
                        f.write(line + "\n");
                    }
                }
            }
        }
        m = self.metered();
        tokens: Json = {
            "builder": role_tokens(rows, "builder", m.get("builder"), builder.self_usage_cumulative),
            "driver": role_tokens(rows, "driver", m.get("driver"), driver.self_usage_cumulative)
        };
        checks: dict[str, str] = self.task.analyze.get("command_checks", {});
        allowed: list[str] = self.task.analyze.get("allowed_outside", []);
        analysis = analyze(self.dir / "trace.jsonl", self.ws, allowed=allowed,
                           source_patterns=self.arm.source_patterns, checks=checks,
                           home=os.path.expanduser("~"));
        last = outcome.accepts[-1] if outcome.accepts else None;
        cap = self.budget();
        b: Json = tokens["builder"];
        summary: Json = {
            "build": self.id, "run_id": self.exp.run_id, "task": self.task.id, "arm": self.arm.id,
            "framework": self.arm.framework, "rep": self.rep, "protocol": self.exp.protocol,
            "builder": {"name": self.spec.name, "agent": self.spec.agent, "model": self.spec.model,
                        "endpoint": self.spec.endpoint, "version": meta.get("agent_version"),
                        "resumable": builder.can_resume()},
            "driver": {"model": driver.spec.model, "version": meta.get("driver_version")}
                if self.exp.protocol == "reviewed" else None,
            "status": outcome.status, "rounds": len(outcome.verdicts), "verdicts": outcome.verdicts,
            "tokens": tokens, "total_tokens": b["total"], "total_tokens_source": b["source"],
            "acceptance": last, "acceptance_runs": len(outcome.accepts),
            "budget": {"tokens": cap, "counts": self.exp.budget.get("counts", ["builder", "driver"])}
                if cap is not None else None,
            "wall_s": round(time.time() - t0, 1), "base": base, "final": final, "commits": outcome.commits,
            "arm_loc": workspace.loc(self.ws, base, self.slot), "resent_without_resume": session.resends,
            "analysis": analysis, "errors": [r["transcript"] for r in rows if r.get("is_error")],
            "proxy_tag": self.tag, "finished": datetime.now(timezone.utc).isoformat()
        };
        if meta.get("error") {
            summary["error"] = meta["error"];
        }
        (self.dir / "summary.json").write_text(json.dumps(summary, indent=2));
        self.phase(None);
        workspace.drop_venvs(self.ws);
        self.log(f"{outcome.status}; builder {b['total']:,} tok ({b['source']}), {b['calls']} calls; "
                 + f"{round(time.time() - t0)} s");
        return summary;
    }
}

"""What a protocol may do in a build."""
obj Session {
    has b: Build,
        builder_agent: Agent,
        driver_agent: Agent,
        env: dict[str, str],
        prompt: str,
        driver_intro: str,
        ctx: dict[str, any],
        max_rounds: int postinit,
        has_accept: bool postinit,
        timeouts: dict[str, int] postinit,
        seq: int = -1,
        sessions: dict[str, str] = {},
        resends: int = 0;

    def postinit {
        self.max_rounds = self.b.exp.max_rounds;
        self.has_accept = bool(self.b.task.accept.get("command") or self.b.task.accept.get("hook"));
        self.timeouts = {"builder": int(self.b.exp.raw.get("builder_timeout", 3 * 3600)),
                         "driver": int(self.b.exp.raw.get("driver_timeout", 2 * 3600))};
        self.sessions = {"builder": "", "driver": ""};
    }

    def log(msg: str) {
        self.b.log(msg);
    }

    def over_budget -> bool {
        return self.b.over_budget();
    }

    def snapshot(msg: str) -> str {
        return workspace.snapshot(self.b.ws, msg);
    }

    def accept(k: int) -> Json {
        self.b.phase(f"acceptance {k}");
        return accept.run(self.b.task, self.ctx, self.env, self.b.dir / "acceptance", k);
    }

    def _turn(role: str, agent: Agent, message: str, first: bool, denied: list[str]) -> Turn {
        self.seq += 1;
        resume = not first and agent.can_resume() and bool(self.sessions[role]);
        if not first and not resume and role == "builder" {
            # No way to continue the conversation: the task again, with the follow-up.
            self.resends += 1;
            message = self.prompt + "\n\n---\n\n## Follow-up\n\nYour earlier session has ended; "
                + "your work so far is in the workspace.\n\n" + message;
        }
        self.log(f"{role} turn {self.seq} ({agent.name})");
        self.b.phase(f"{role} turn {self.seq}");
        req = TurnRequest(
            role=role, seq=self.seq, ws=self.b.ws, bdir=self.b.dir, env=self.env, message=message,
            session=self.sessions[role] if resume else "", resume=resume, timeout=self.timeouts[role],
            over_budget=self.b.over_budget if self.b.budget() is not None else None,
            tools_denied=denied, on_phase=self.b.phase
        );
        t = agent.run_turn(req, log=self.b.log_fn);
        self.sessions[role] = t.session or self.sessions[role];
        seq = self.seq;
        paths = sorted((self.b.dir / "transcripts").glob(f"{seq:02d}-{role}*.jsonl"));
        for path in paths {
            write(self.b.dir / "trace.jsonl", agent.events(path, role, seq));
        }
        return t;
    }

    def builder(message: str, first: bool) -> Turn {
        return self._turn("builder", self.builder_agent, message, first, []);
    }

    def driver(message: str, first: bool) -> Turn {
        return self._turn("driver", self.driver_agent, message, first, DRIVER_DENIED);
    }
}
