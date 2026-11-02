"""The build workspace: the task alone, in a fresh git repository.

The builder sees only the task's files, with every other arm removed (shared
files kept) and no history to dig one out of. Each round is a commit, so the
arm's evolution and its final diff are on record.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from .config import Task, render

EXCLUDE = ["__pycache__/", "*.pyc", ".jac/", ".pytest_cache/", "node_modules/",
           "*.egg-info/", ".venv/", ".agent-home/"]
IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", ".jac", ".pytest_cache", "node_modules",
                                ".venv", ".git")


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    p = subprocess.run(cmd, text=True, capture_output=True, **kw)
    if p.returncode:
        raise RuntimeError(f"{' '.join(cmd)} exited {p.returncode}: {p.stderr.strip()[-1000:]}")
    return p


#: The user's git config must not reach build commits: no signing, no hooks.
GIT = ["git", "-c", "user.name=build", "-c", "user.email=build@local", "-c", "commit.gpgsign=false",
       "-c", "tag.gpgsign=false", "-c", "core.hooksPath=/dev/null"]


def _git(ws: Path, *args: str) -> str:
    return sh([*GIT, *args], cwd=ws).stdout.strip()


def export(task: Task, ws: Path, ctx: dict) -> None:
    w = task.workspace
    ws.mkdir(parents=True, exist_ok=True)
    kind = w.get("kind", "dir" if "path" in w else "empty")
    if kind == "dir":
        src = (task.dir / render(w["path"], ctx)).resolve()
        shutil.copytree(src, ws, ignore=IGNORE, dirs_exist_ok=True, symlinks=True)
    elif kind == "git":
        repo = Path(render(w["repo"], ctx)).expanduser()
        repo = repo if repo.is_absolute() else (task.dir / repo).resolve()
        git_dir = repo if (repo / "HEAD").exists() and not (repo / ".git").exists() else repo / ".git"
        archive = subprocess.run(["git", f"--git-dir={git_dir}", "archive", render(w["ref"], ctx),
                                  *[render(p, ctx) for p in w.get("paths", [])]],
                                 check=True, capture_output=True)
        subprocess.run(["tar", "-x", "-C", str(ws)], input=archive.stdout, check=True)
    elif kind != "empty":
        raise ValueError(f"{task.id}: unknown workspace kind {kind!r}")


def strip(ws: Path, remove: list[str], keep: list[str]) -> None:
    """Remove `remove`, except the paths in `keep`, which are moved aside and back."""
    kept = ws.parent / ".kept"
    for rel in keep:
        src = ws / rel
        if src.exists() or src.is_symlink():
            dst = kept / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))
    for rel in remove:
        for target in ws.glob(rel) if any(c in rel for c in "*?[") else [ws / rel]:
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.exists():
                shutil.rmtree(target)
    for rel in keep:
        src = kept / rel
        if src.exists() or src.is_symlink():
            (ws / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(ws / rel))
    shutil.rmtree(kept, ignore_errors=True)


def prepare(task: Task, ws: Path, slot: str, ctx: dict) -> str:
    """Build the workspace and commit it as the base. Returns the base commit."""
    export(task, ws, ctx)
    w = task.workspace
    strip(ws, [render(p, ctx) for p in w.get("strip", [])], [render(p, ctx) for p in w.get("keep", [])])
    for d in list(ws.rglob(".jac")):  # stale runtime state some arms track
        if d.is_dir():
            shutil.rmtree(d, ignore_errors=True)
    (ws / slot).mkdir(parents=True, exist_ok=True)
    sh(["git", "init", "-q", "-b", "main"], cwd=ws)
    (ws / ".git/info/exclude").write_text("\n".join(EXCLUDE) + "\n")
    _git(ws, "add", "-A")
    _git(ws, "commit", "-q", "--allow-empty", "-m", f"base: {task.id}")
    return _git(ws, "rev-parse", "HEAD")


def snapshot(ws: Path, message: str) -> str:
    _git(ws, "add", "-A")
    _git(ws, "commit", "-q", "--allow-empty", "-m", message)
    return _git(ws, "rev-parse", "HEAD")


def diff(ws: Path, base: str, final: str) -> str:
    return sh(["git", "diff", base, final], cwd=ws).stdout


def loc(ws: Path, base: str, rel: str) -> dict:
    out = sh(["git", "diff", "--numstat", base, "HEAD", "--", rel], cwd=ws).stdout
    added = deleted = files = 0
    for line in out.splitlines():
        a, d, _ = line.split("\t", 2)
        if a != "-":
            added += int(a)
            deleted += int(d)
        files += 1
    return {"files_changed": files, "lines_added": added, "lines_deleted": deleted}


def drop_venvs(ws: Path) -> None:
    """Virtual environments are re-creatable and dominate disk use."""
    for pat in (".jac/venv", ".venv", "node_modules"):
        for d in ws.rglob(pat):
            shutil.rmtree(d, ignore_errors=True)
