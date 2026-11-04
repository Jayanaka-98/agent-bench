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

import importlib.util;
import json;
import subprocess;
import time;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.config { Task }
import from agent_bench.template { render }

def _hook(task: Task, ctx: dict[str, any], env: dict[str, str], out_dir: Path) -> Json {
    (file, fn) = str(task.accept["hook"]).split(":", 1);
    spec = importlib.util.spec_from_file_location(f"accept_hook_{task.id}", task.dir / file);
    if spec is None or spec.loader is None {
        return {"passed": False, "reasons": [f"cannot load acceptance hook {file}"]};
    }
    mod = importlib.util.module_from_spec(spec);
    spec.loader.exec_module(mod);
    try {
        v = getattr(mod, fn)(ws=Path(str(ctx["ws"])), ctx=ctx, env=env, out_dir=out_dir) as Json;
    } except Exception as e {  # a crashing checker is a failed check, on record
        return {"passed": False, "metrics": {}, "reasons": [f"acceptance hook crashed: {type(e).__name__}: {e}"]};
    }
    out: Json = {"passed": bool(v.get("passed")), "metrics": v.get("metrics", {}), "reasons": v.get("reasons", [])};
    for (k, val) in v.items() {
        if k not in out {
            out[k] = val;
        }
    }
    return out;
}

def _command(task: Task, ctx: dict[str, any], env: dict[str, str], out_dir: Path, verdict_path: Path,
             log_path: Path) -> Json {
    a = task.accept;
    cmd = render(str(a["command"]), {**ctx, "verdict": str(verdict_path), "out_dir": str(out_dir)});
    cwd = render(str(a.get("cwd", "${ws}")), ctx);
    timed_out = False;
    out = "";
    code = 0;
    with log_path.open("w") as log {
        log.write(f"$ {cmd}\n");
        log.flush();
        try {
            p = subprocess.run(cmd, shell=True, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, timeout=int(a.get("timeout", 1800)));
            out = str(p.stdout or "");
            code = p.returncode;
        } except subprocess.TimeoutExpired as e {
            raw = e.stdout;
            out = raw.decode(errors="replace") if isinstance(raw, bytes) else str(raw or "");
            code = -1;
            timed_out = True;
        }
        log.write(out);
    }
    v: Json | None = None;
    if verdict_path.exists() {
        try {
            v = json.loads(verdict_path.read_text()) as Json;
        } except ValueError {
            v = None;
        }
    }
    if v is None {
        for line in reversed(out.strip().splitlines()) {
            line = line.strip();
            if line.startswith("{") and '"passed"' in line {
                try {
                    v = json.loads(line) as Json;
                    break;
                } except ValueError {
                    continue;
                }
            }
        }
    }
    if v is None {
        v = {"passed": code == 0, "metrics": {}, "reasons": [] if code == 0 else [f"acceptance command exited {code}"]};
    }
    if timed_out {
        v["passed"] = False;
        reasons: list[str] = v.get("reasons") or [];
        v["reasons"] = reasons + ["acceptance timed out"];
    }
    v["exit"] = code;
    return v;
}

def run(task: Task, ctx: dict[str, any], env: dict[str, str], out_dir: Path, k: int) -> Json {
    a = task.accept;
    out_dir.mkdir(parents=True, exist_ok=True);
    verdict_path = out_dir / f"verdict-{k}.json";
    log_path = out_dir / f"accept-{k}.log";
    started = time.time();
    v: Json = {};
    if a.get("hook") {
        v = _hook(task, ctx, env, out_dir);
    } elif a.get("command") {
        v = _command(task, ctx, env, out_dir, verdict_path, log_path);
    } else {
        return {"passed": True, "metrics": {}, "reasons": [], "skipped": "task has no acceptance"};
    }
    v["wall_s"] = round(time.time() - started, 1);
    v["log"] = str(log_path) if log_path.exists() else None;
    with (out_dir.parent / "acceptance.jsonl").open("a") as f {
        f.write(json.dumps(v) + "\n");
    }
    return v;
}

"""The success criterion as a note for the builder, if the task gives one:
`describe`, and `self_check` if set, in the task's own `criterion` wording if
it has one (a template with `${describe}` and `${self_check}`)."""
def criterion(task: Task, ctx: dict[str, any]) -> str {
    a = task.accept;
    if not a.get("describe") {
        return "";
    }
    describe = render(str(a["describe"]), ctx);
    check = render(str(a["self_check"]), ctx) if a.get("self_check") else "";
    if a.get("criterion") {
        return render(str(a["criterion"]), {**ctx, "describe": describe, "self_check": check});
    }
    text = f"- **Success criterion.** The build succeeds only if it works: {describe}";
    if check {
        text += f" To run the same check yourself: `{check}`.";
    }
    return text;
}

"""What the builder hears when its work fails acceptance."""
def feedback(v: Json) -> str {
    tail = "";
    log = v.get("log");
    if log and Path(str(log)).exists() {
        tail = "\n".join(Path(str(log)).read_text(errors="replace").splitlines()[-60:]);
    }
    reasons: list[str] = [str(r) for r in (v.get("reasons") or ["(no reason given)"])];
    text = "Your work was checked and it fails the success criterion.\n\nWhy it fails:\n";
    text += "\n".join([f"- {r}" for r in reasons]);
    text += f"\n\nMeasured: `{json.dumps(v.get('metrics', {}))}`\n\n";
    if tail {
        text += f"The last lines of the check's log:\n```\n{tail}\n```\n\n";
    }
    return text + "Fix it so it passes, re-run the relevant check yourself, then report what changed.";
}
