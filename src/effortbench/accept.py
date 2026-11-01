"""Acceptance: does the built thing work, by the task's own measure?

A task says how in `[accept]`, one of:

- `command`: a shell command, run in the workspace with the build's
  environment. Its verdict is, in order: the JSON file at `${verdict}` if it
  wrote one; else the last stdout line that is a JSON object with `passed`;
  else its exit status. A verdict is `{"passed": bool, "metrics": {...},
  "reasons": [...]}`.
- `hook = "file.py:function"`: a Python function in the task directory, called
  as `function(ws=Path, ctx=dict, env=dict, out_dir=Path)` and returning a
  verdict dict. This is how an existing checker (e.g. the jac-paper
  acceptance.py) is wrapped.

`describe` is the success criterion as told to the builder, and `self_check`
the command it can run itself.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import time
from pathlib import Path

from .config import Task, render


def run(task: Task, ctx: dict, env: dict, out_dir: Path, k: int) -> dict:
    a = task.accept
    out_dir.mkdir(parents=True, exist_ok=True)
    verdict_path = out_dir / f"verdict-{k}.json"
    log_path = out_dir / f"accept-{k}.log"
    started = time.time()
    if a.get("hook"):
        file, fn = a["hook"].split(":", 1)
        spec = importlib.util.spec_from_file_location(f"accept_hook_{task.id}", task.dir / file)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        try:
            v = getattr(mod, fn)(ws=Path(ctx["ws"]), ctx=ctx, env=env, out_dir=out_dir)
        except Exception as e:  # noqa: BLE001 - a crashing checker is a failed check, on record
            v = {"passed": False, "reasons": [f"acceptance hook crashed: {type(e).__name__}: {e}"]}
        v = {"passed": bool(v.get("passed")), "metrics": v.get("metrics", {}),
             "reasons": v.get("reasons", []), **{k2: v[k2] for k2 in v if k2 not in ("passed", "metrics", "reasons")}}
    elif a.get("command"):
        cmd = render(a["command"], {**ctx, "verdict": str(verdict_path), "out_dir": str(out_dir)})
        cwd = render(a.get("cwd", "${ws}"), ctx)
        timed_out = False
        with log_path.open("w") as log:
            log.write(f"$ {cmd}\n")
            log.flush()
            try:
                p = subprocess.run(cmd, shell=True, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=a.get("timeout", 1800))
                out, code = p.stdout, p.returncode
            except subprocess.TimeoutExpired as e:
                out, code, timed_out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) \
                    else (e.stdout or ""), -1, True
            log.write(out)
        v = None
        if verdict_path.exists():
            try:
                v = json.loads(verdict_path.read_text())
            except ValueError:
                v = None
        if v is None:
            for line in reversed(out.strip().splitlines()):
                line = line.strip()
                if line.startswith("{") and '"passed"' in line:
                    try:
                        v = json.loads(line)
                        break
                    except ValueError:
                        continue
        if v is None:
            v = {"passed": code == 0, "metrics": {},
                 "reasons": [] if code == 0 else [f"acceptance command exited {code}"]}
        if timed_out:
            v["passed"] = False
            v.setdefault("reasons", []).append("acceptance timed out")
        v["exit"] = code
    else:
        return {"passed": True, "metrics": {}, "reasons": [], "skipped": "task has no acceptance"}
    v["wall_s"] = round(time.time() - started, 1)
    v["log"] = str(log_path) if log_path.exists() else None
    with (out_dir.parent / "acceptance.jsonl").open("a") as f:
        f.write(json.dumps(v) + "\n")
    return v


def criterion(task: Task, ctx: dict) -> str:
    """The success criterion as a note for the builder, if the task gives one."""
    a = task.accept
    if not a.get("describe"):
        return ""
    text = (f"- **Success criterion.** The build succeeds only if it works: {render(a['describe'], ctx)}")
    if a.get("self_check"):
        text += f" To run the same check yourself: `{render(a['self_check'], ctx)}`."
    return text


def feedback(v: dict) -> str:
    """What the builder hears when its work fails acceptance."""
    tail = ""
    if v.get("log") and Path(v["log"]).exists():
        tail = "\n".join(Path(v["log"]).read_text(errors="replace").splitlines()[-60:])
    return ("Your work was checked and it fails the success criterion.\n\n"
            "Why it fails:\n" + "\n".join(f"- {r}" for r in v.get("reasons") or ["(no reason given)"]) +
            f"\n\nMeasured: `{json.dumps(v.get('metrics', {}))}`\n\n"
            + (f"The last lines of the check's log:\n```\n{tail}\n```\n\n" if tail else "") +
            "Fix it so it passes, re-run the relevant check yourself, then report what changed.")
