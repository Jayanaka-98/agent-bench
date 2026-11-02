"""The build workspace: the task alone, in a fresh git repository.

The builder sees only the task's files, with every other arm removed (shared
files kept) and no history to dig one out of. Each round is a commit, so the
arm's evolution and its final diff are on record.
"""

import shutil;
import subprocess;
import from pathlib { Path }
import from agent_bench.config { Task }
import from agent_bench.template { render }

glob EXCLUDE: list[str] = [
    "__pycache__/", "*.pyc", ".jac/", ".pytest_cache/", "node_modules/", "*.egg-info/", ".venv/", ".agent-home/"
];

"""The user's git config must not reach build commits: no signing, no hooks."""
glob GIT: list[str] = [
    "git", "-c", "user.name=build", "-c", "user.email=build@local", "-c", "commit.gpgsign=false",
    "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null"
];

def sh(cmd: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess {
    p = subprocess.run(cmd, text=True, capture_output=True, cwd=cwd);
    if p.returncode {
        raise RuntimeError(f"{' '.join(cmd)} exited {p.returncode}: {p.stderr.strip()[-1000:]}");
    }
    return p;
}

def _git(ws: Path, *args: str) -> str {
    return str(sh([*GIT, *args], cwd=ws).stdout).strip();
}

def _ignored(directory: str, names: list[str]) -> set[str] {
    skipped = {"__pycache__", ".jac", ".pytest_cache", "node_modules", ".venv", ".git"};
    return {n for n in names if n in skipped or n.endswith(".pyc")};
}

def export(task: Task, ws: Path, ctx: dict[str, any]) {
    w = task.workspace;
    ws.mkdir(parents=True, exist_ok=True);
    kind = str(w.get("kind", "dir" if "path" in w else "empty"));
    if kind == "dir" {
        src = (task.dir / render(str(w["path"]), ctx)).resolve();
        shutil.copytree(src, ws, ignore=_ignored, dirs_exist_ok=True, symlinks=True);
    } elif kind == "git" {
        repo = Path(render(str(w["repo"]), ctx)).expanduser();
        repo = repo if repo.is_absolute() else (task.dir / repo).resolve();
        git_dir = repo if (repo / "HEAD").exists() and not (repo / ".git").exists() else repo / ".git";
        paths = [render(str(p), ctx) for p in w.get("paths", [])];
        archive = subprocess.run(["git", f"--git-dir={git_dir}", "archive", render(str(w["ref"]), ctx), *paths],
                                 check=True, capture_output=True);
        subprocess.run(["tar", "-x", "-C", str(ws)], input=archive.stdout, check=True);
    } elif kind != "empty" {
        raise ValueError(f"{task.id}: unknown workspace kind {kind!r}");
    }
}

"""Remove `remove`, except the paths in `keep`, which are moved aside and back."""
def strip(ws: Path, remove: list[str], keep: list[str]) {
    kept = ws.parent / ".kept";
    for rel in keep {
        src = ws / rel;
        if src.exists() or src.is_symlink() {
            dst = kept / rel;
            dst.parent.mkdir(parents=True, exist_ok=True);
            shutil.move(str(src), str(dst));
        }
    }
    for rel in remove {
        targets = list(ws.glob(rel)) if any([c in rel for c in "*?["]) else [ws / rel];
        for target in targets {
            if target.is_symlink() or target.is_file() {
                target.unlink();
            } elif target.exists() {
                shutil.rmtree(target);
            }
        }
    }
    for rel in keep {
        src = kept / rel;
        if src.exists() or src.is_symlink() {
            (ws / rel).parent.mkdir(parents=True, exist_ok=True);
            shutil.move(str(src), str(ws / rel));
        }
    }
    shutil.rmtree(kept, ignore_errors=True);
}

"""Build the workspace and commit it as the base. Returns the base commit."""
def prepare(task: Task, ws: Path, slot: str, ctx: dict[str, any]) -> str {
    export(task, ws, ctx);
    w = task.workspace;
    strip(ws, [render(str(p), ctx) for p in w.get("strip", [])], [render(str(p), ctx) for p in w.get("keep", [])]);
    for d in list(ws.rglob(".jac")) {  # stale runtime state some arms track
        if d.is_dir() {
            shutil.rmtree(d, ignore_errors=True);
        }
    }
    (ws / slot).mkdir(parents=True, exist_ok=True);
    sh(["git", "init", "-q", "-b", "main"], cwd=ws);
    (ws / ".git/info/exclude").write_text("\n".join(EXCLUDE) + "\n");
    _git(ws, "add", "-A");
    _git(ws, "commit", "-q", "--allow-empty", "-m", f"base: {task.id}");
    return _git(ws, "rev-parse", "HEAD");
}

def snapshot(ws: Path, message: str) -> str {
    _git(ws, "add", "-A");
    _git(ws, "commit", "-q", "--allow-empty", "-m", message);
    return _git(ws, "rev-parse", "HEAD");
}

def diff(ws: Path, base: str, final: str) -> str {
    return str(sh(["git", "diff", base, final], cwd=ws).stdout);
}

def loc(ws: Path, base: str, rel: str) -> dict[str, int] {
    out = str(sh(["git", "diff", "--numstat", base, "HEAD", "--", rel], cwd=ws).stdout);
    added = 0;
    deleted = 0;
    files = 0;
    for line in out.splitlines() {
        (a, d, _) = line.split("\t", 2);
        if a != "-" {
            added += int(a);
            deleted += int(d);
        }
        files += 1;
    }
    return {"files_changed": files, "lines_added": added, "lines_deleted": deleted};
}

"""Virtual environments are re-creatable and dominate disk use."""
def drop_venvs(ws: Path) {
    for pat in (".jac/venv", ".venv", "node_modules") {
        for d in ws.rglob(pat) {
            shutil.rmtree(d, ignore_errors=True);
        }
    }
}
