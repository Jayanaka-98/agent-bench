"""One build: a task, an arm, a builder and a repetition.

Recorded under <runs>/<run-id>/<task>__<arm>__<builder>__r<k>/:

    prompt-builder.md       exactly what the builder was given
    prompt-driver.md        the driver's brief (reviewed protocol)
    transcripts/            every agent invocation, in the agent's native output format
    invocations.jsonl       one row per invocation: agent, session, self-reported usage, time
    trace.jsonl             every invocation, normalized (trace.py)
    calls.jsonl             this build's rows of the proxy ledger: one per model call
    native/                 the agents' own session files
    acceptance/             each acceptance run's log and verdict
    ws/                     the workspace; one commit per round
    final.patch             the work, as a diff against the prepared base
    summary.json            status, tokens (metered and self-reported) per role, analysis
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import time
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from . import accept, agents, analyze, workspace
from . import trace as tr
from .agents.base import BuilderSpec, Endpoint, Turn, TurnRequest
from .config import Arm, Experiment, Task, render
from .protocols import PROTOCOLS
from .proxy import ledger_usage
from .usage import Usage

DATA = Path(__file__).resolve().parent / "data"
DRIVER_DENIED = ["Edit", "Write", "NotebookEdit"]


def safe(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.+-]", "-", s)


class Build:
    def __init__(self, exp: Experiment, task: Task, arm: Arm, builder: BuilderSpec, rep: int, port: int,
                 proxy_url: str = "", ledger: Path | None = None, log: Callable[[str], None] = print) -> None:
        self.exp, self.task, self.arm, self.spec, self.rep, self.port = exp, task, arm, builder, rep, port
        self.id = safe(f"{task.id}__{arm.id}__{builder.name}__r{rep}")
        self.dir = exp.runs_dir / exp.run_id / self.id
        self.ws = self.dir / "ws"
        self.proxy_url, self.ledger = proxy_url.rstrip("/"), ledger
        self._log = log
        self.slot = task.slot(arm)

    def log(self, msg: str) -> None:
        self._log(f"{self.id}: {msg}")

    # ---- context ----------------------------------------------------------------

    def context(self) -> dict:
        return {"ws": str(self.ws), "bdir": str(self.dir), "task": self.task.id, "task_dir": str(self.task.dir),
                "arm": self.arm.id, "arm_dir": self.slot, "framework": self.arm.framework,
                "builder": self.spec.name, "agent": self.spec.agent, "model": self.spec.model,
                "port": self.port, "run_id": self.exp.run_id, "build": self.id, "rep": self.rep,
                "python": self.exp.env.get("PYTHON", sys.executable),
                "python_bin": str(Path(self.exp.env.get("PYTHON", sys.executable)).parent),
                "home": os.path.expanduser("~")}

    def environment(self, ctx: dict) -> dict:
        env = {**os.environ}
        for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"):
            env.pop(k, None)
        for layer in (self.exp.env, self.task.env, self.arm.env):
            env.update({k: render(str(v), {**ctx, **env}) for k, v in layer.items()})
        env["BUILD_PORT"] = str(self.port)
        return env

    def endpoint(self, upstream: str, role: str) -> Endpoint | None:
        if not upstream or not self.proxy_url:
            return None
        up = self.exp.proxy.get("upstreams", {}).get(upstream)
        if up is None:
            raise KeyError(f"builder endpoint {upstream!r} is not a proxy upstream")
        return Endpoint(upstream=upstream, api=up.get("api", "openai"),
                        base_url=f"{self.proxy_url}/{upstream}/{self.tag}.{role}",
                        key="metered" if up.get("key_env") else os.environ.get(up.get("client_key_env", ""), ""))

    # ---- tokens -----------------------------------------------------------------

    def metered(self) -> dict[str, Usage]:
        """Usage per role, from the proxy: live over HTTP, or from the ledger."""
        prefix = f"{self.tag}."
        per_tag: dict[str, Usage] = {}
        if self.ledger and self.ledger.exists():
            per_tag = ledger_usage(self.ledger, prefix)
        elif self.proxy_url:
            try:
                with urllib.request.urlopen(f"{self.proxy_url}/__usage?prefix={prefix}", timeout=10) as r:
                    per_tag = {t: Usage.from_dict(u) for t, u in json.loads(r.read()).items()}
            except OSError:
                per_tag = {}
        out: dict[str, Usage] = {}
        for t, u in per_tag.items():
            role = t[len(prefix):]
            out[role] = out.get(role, Usage()) + u
        return out

    def over_budget(self) -> bool:
        cap = self.budget()
        if cap is None:
            return False
        roles = self.exp.budget.get("counts", ["builder", "driver"])
        m = self.metered()
        return sum(m.get(r, Usage()).total for r in roles) >= cap

    def budget(self) -> float | None:
        b = self.exp.budget
        return b.get("tasks", {}).get(self.task.id, b.get("tokens")) if b else None

    # ---- the build --------------------------------------------------------------

    def run(self, dry_run: bool = False) -> dict:
        if (self.dir / "summary.json").exists():
            return json.loads((self.dir / "summary.json").read_text())
        if self.dir.exists():
            shutil.rmtree(self.dir)  # a half-finished build restarts cleanly
        (self.dir / "transcripts").mkdir(parents=True)
        # A fresh tag per attempt, so an aborted attempt's calls never count.
        self.tag = f"{self.id}~{uuid.uuid4().hex[:6]}"
        # Who is building, for anything that reads the build while it runs (the TUI).
        (self.dir / "build.json").write_text(json.dumps({
            "build": self.id, "task": self.task.id, "arm": self.arm.id, "rep": self.rep,
            "builder": {"name": self.spec.name, "agent": self.spec.agent, "model": self.spec.model,
                        "endpoint": self.spec.endpoint},
            "protocol": self.exp.protocol, "proxy_tag": self.tag,
            "started": datetime.now(timezone.utc).isoformat()}, indent=2))
        ctx = self.context()
        base = workspace.prepare(self.task, self.ws, self.slot, ctx)
        env = self.environment(ctx)
        home = self.dir / "home"
        home.mkdir()
        builder = agents.make(self.spec, self.endpoint(self.spec.endpoint, "builder"))
        env_add, install_note = builder.install(self.ws, home, self.arm.skill_dirs(), self.arm.notes)
        env.update(env_add)
        if self.arm.skills:
            base = workspace.snapshot(self.ws, "install skills")
        prompt = self.compose(ctx, install_note)
        (self.dir / "prompt-builder.md").write_text(prompt)
        driver_intro = ""
        if self.exp.protocol == "reviewed":
            scratch = self.dir / "driver-scratch"
            scratch.mkdir()
            tmpl = Path(self.exp.driver["prompt"]) if self.exp.driver.get("prompt") else DATA / "driver.md"
            if not tmpl.is_absolute():
                tmpl = self.exp.file.parent / tmpl
            driver_intro = render(tmpl.read_text(), {**ctx, "spec": prompt, "scratch": str(scratch),
                                                     "max_rounds": self.exp.max_rounds})
            (self.dir / "prompt-driver.md").write_text(driver_intro)
        if dry_run:
            self.log(f"prepared {self.ws} (dry run)")
            return {"build": self.id, "status": "dry-run"}

        d = self.exp.driver
        driver = agents.make(BuilderSpec(name="driver", agent="claude-code",
                                         model=d.get("model", "claude-opus-5-5"),
                                         endpoint=d.get("endpoint", ""), options=d.get("options", {})),
                             self.endpoint(d.get("endpoint", ""), "driver"))
        driver.install(self.ws, home, [], "")
        driver.has_skills = bool(self.arm.skills)  # its --safe-mode would hide them too
        session = Session(self, builder, driver, env, prompt, driver_intro, ctx)
        t0 = time.time()
        meta = {"agent_version": builder.version(), "driver_version": driver.version()}
        try:
            outcome = PROTOCOLS[self.exp.protocol](session)
        except Exception as e:  # noqa: BLE001 - recorded, not raised: one build, not the run
            from .protocols import Outcome
            self.log(f"protocol crashed: {type(e).__name__}: {e}")
            outcome = Outcome(status="error")
            meta["error"] = f"{type(e).__name__}: {e}"
        return self.finish(outcome, base, t0, builder, driver, session, meta)

    def compose(self, ctx: dict, install_note: str) -> str:
        extras = [f"- **Your work goes in** `{self.slot}/`."]
        if self.arm.notes:
            extras.append(render(self.arm.notes.rstrip(), ctx))
        if install_note:
            extras.append(install_note)
        crit = accept.criterion(self.task, ctx)
        if crit:
            extras.append(crit)
        ctx2 = {**ctx, "extras": "\n".join(extras)}
        parts = [render(self.task.text(), ctx), render(self.arm.text(), ctx)]
        notes = render(self.task.notes, ctx2) if self.task.notes else ""
        if "${extras}" not in self.task.notes:
            notes = (notes.rstrip() + "\n\n" if notes else "") + ctx2["extras"]
        return "\n".join(p.rstrip() for p in parts + [notes] if p.strip()) + "\n"

    def finish(self, outcome, base: str, t0: float, builder, driver, session: "Session", meta: dict) -> dict:
        time.sleep(1)  # the proxy logs a streamed call just after the agent has read it
        final = workspace.snapshot(self.ws, "final")
        (self.dir / "final.patch").write_text(workspace.diff(self.ws, base, final))
        for src in builder.native_logs(self.ws) + driver.native_logs(self.ws):
            if src.resolve() != (self.dir / "home").resolve():
                shutil.copytree(src, self.dir / "native" / src.name, dirs_exist_ok=True)
        rows = [json.loads(l) for l in (self.dir / "invocations.jsonl").read_text().splitlines()] \
            if (self.dir / "invocations.jsonl").exists() else []
        if self.ledger and self.ledger.exists():
            with (self.dir / "calls.jsonl").open("w") as f:
                for line in self.ledger.read_text(errors="replace").splitlines():
                    if f'"tag": "{self.tag}.' in line:
                        f.write(line + "\n")
        metered = self.metered()
        tokens = {role: role_tokens(rows, role, metered.get(role),
                                    getattr(builder if role == "builder" else driver, "self_usage_cumulative", False))
                  for role in ("builder", "driver")}
        analysis = analyze.analyze(self.dir / "trace.jsonl", self.ws,
                                   allowed=self.task.analyze.get("allowed_outside", []),
                                   source_patterns=self.arm.source_patterns,
                                   checks=self.task.analyze.get("command_checks", {}),
                                   home=os.path.expanduser("~"))
        last = outcome.accepts[-1] if outcome.accepts else None
        summary = {
            "build": self.id, "run_id": self.exp.run_id, "task": self.task.id, "arm": self.arm.id,
            "framework": self.arm.framework, "rep": self.rep, "protocol": self.exp.protocol,
            "builder": {"name": self.spec.name, "agent": self.spec.agent, "model": self.spec.model,
                        "endpoint": self.spec.endpoint, "version": meta.get("agent_version"),
                        "resumable": builder.supports_resume},
            "driver": ({"model": driver.spec.model, "version": meta.get("driver_version")}
                       if self.exp.protocol == "reviewed" else None),
            "status": outcome.status, "rounds": len(outcome.verdicts), "verdicts": outcome.verdicts,
            "tokens": tokens,
            "total_tokens": tokens["builder"]["total"],
            "total_tokens_source": tokens["builder"]["source"],
            "acceptance": last, "acceptance_runs": len(outcome.accepts),
            "budget": {"tokens": self.budget(), "counts": self.exp.budget.get("counts", ["builder", "driver"])}
            if self.budget() else None,
            "wall_s": round(time.time() - t0, 1), "base": base, "final": final, "commits": outcome.commits,
            "arm_loc": workspace.loc(self.ws, base, self.slot), "resent_without_resume": session.resends,
            "analysis": analysis, "errors": [r["transcript"] for r in rows if r.get("is_error")],
            "proxy_tag": self.tag, "finished": datetime.now(timezone.utc).isoformat(),
            **({"error": meta["error"]} if meta.get("error") else {}),
        }
        (self.dir / "summary.json").write_text(json.dumps(summary, indent=2))
        workspace.drop_venvs(self.ws)
        b = tokens["builder"]
        self.log(f"{outcome.status}; builder {b['total']:,} tok ({b['source']}), "
                 f"{b['calls']} calls; {round(time.time() - t0)} s")
        return summary


def role_tokens(rows: list[dict], role: str, metered: Usage | None, cumulative: bool) -> dict:
    """A role's tokens: metered by the proxy (the measure) and self-reported by
    the agent (a cross-check). A self-report that is cumulative per session
    counts each session once, at its last turn that reported usage; summing
    turns would count every round after the first again."""
    mine = [r for r in rows if r["role"] == role]
    self_u, cost = Usage(), 0.0
    if cumulative:
        last: dict[str, dict] = {}
        for r in mine:
            if r.get("self_usage"):
                last[r["session"]] = r
        picked = list(last.values())
    else:
        picked = [r for r in mine if r.get("self_usage")]
    for r in picked:
        self_u = self_u + Usage.from_dict(r["self_usage"])
        cost += r.get("cost_usd") or 0.0
    has_metered = metered is not None and metered.calls > 0
    head = metered if has_metered else self_u
    return {"source": "metered" if has_metered else ("self" if picked else "none"),
            "total": head.total, "calls": head.calls,
            "metered": metered.to_dict() if metered else None,
            "self_reported": self_u.to_dict() if picked else None,
            "self_cost_usd": round(cost, 4) if picked else None,
            "invocations": len(mine), "num_turns": sum(r.get("num_turns") or 0 for r in mine),
            "wall_s": round(sum(r.get("wall_s") or 0 for r in mine), 1)}


class Session:
    """What a protocol may do in a build."""

    def __init__(self, b: Build, builder, driver, env: dict, prompt: str, driver_intro: str, ctx: dict) -> None:
        self.b, self.builder_agent, self.driver_agent = b, builder, driver
        self.env, self.prompt, self.driver_intro, self.ctx = env, prompt, driver_intro, ctx
        self.max_rounds = b.exp.max_rounds
        self.has_accept = bool(b.task.accept.get("command") or b.task.accept.get("hook"))
        self.seq = -1
        self.sessions = {"builder": "", "driver": ""}
        self.resends = 0
        self.timeouts = {"builder": b.exp.raw.get("builder_timeout", 3 * 3600),
                         "driver": b.exp.raw.get("driver_timeout", 2 * 3600)}

    def log(self, msg: str) -> None:
        self.b.log(msg)

    def over_budget(self) -> bool:
        return self.b.over_budget()

    def snapshot(self, msg: str) -> str:
        return workspace.snapshot(self.b.ws, msg)

    def accept(self, k: int) -> dict:
        return accept.run(self.b.task, self.ctx, self.env, self.b.dir / "acceptance", k)

    def _turn(self, role: str, agent, message: str, first: bool, denied: list[str]) -> Turn:
        self.seq += 1
        resume = not first and agent.supports_resume and bool(self.sessions[role])
        if not first and not resume and role == "builder":
            # No way to continue the conversation: the task again, with the follow-up.
            self.resends += 1
            message = (self.prompt + "\n\n---\n\n## Follow-up\n\nYour earlier session has ended; "
                       "your work so far is in the workspace.\n\n" + message)
        self.log(f"{role} turn {self.seq} ({agent.name})")
        req = TurnRequest(role=role, seq=self.seq, ws=self.b.ws, bdir=self.b.dir, env=self.env,
                          message=message, session=self.sessions[role] if resume else "",
                          resume=resume, timeout=self.timeouts[role],
                          over_budget=self.b.over_budget if self.b.budget() else None,
                          tools_denied=denied)
        t = agent.run_turn(req, log=self.b._log)
        self.sessions[role] = t.session or self.sessions[role]
        tr.write(self.b.dir / "trace.jsonl", self._events(agent, role))
        return t

    def _events(self, agent, role: str):
        """Every transcript of this seq (retries included), normalized."""
        for path in sorted((self.b.dir / "transcripts").glob(f"{self.seq:02d}-{role}*.jsonl")):
            yield from agent.events(path, role, self.seq)

    def builder(self, message: str, first: bool) -> Turn:
        return self._turn("builder", self.builder_agent, message, first, [])

    def driver(self, message: str, first: bool) -> Turn:
        return self._turn("driver", self.driver_agent, message, first, DRIVER_DENIED)
