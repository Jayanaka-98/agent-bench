"""Shared type names and helpers."""

import os;
import shutil;
import sys;
import from pathlib { Path }

"""A JSON object as decoded: string keys, values of any JSON type."""
type Json = dict[str, any];

"""The jac binary to run agent-bench's own processes (the server, a launched
run) with: AGENT_BENCH_JAC, else `jac` on PATH, else the running jac (under
the jac runtime `sys.executable` is the jac binary). JAC_BIN is not read:
other environments (the jac-paper env.sh) set it to a directory."""
def jac_bin -> str {
    return os.environ.get("AGENT_BENCH_JAC") or shutil.which("jac") or sys.executable;
}

"""agent-bench's own directory: AGENT_BENCH_HOME, else ~/.agent-bench. Agents
it installs go in `tools/` there; per-machine pins in `agents.toml`."""
def bench_home -> Path {
    return Path(os.environ.get("AGENT_BENCH_HOME") or os.path.expanduser("~/.agent-bench"));
}

"""Where `agents ensure` installs, without sudo: npm agents under `npm/`,
uv tools under `uv/`, a downloaded Node under `node/`."""
def tools_dir -> Path {
    return bench_home() / "tools";
}

"""The bin directories of the user-space installs, in the order they win."""
def tool_bin_dirs -> list[Path] {
    t = tools_dir();
    return [t / "npm" / "bin", t / "uv" / "bin", t / "node" / "bin"];
}

"""`env` with the user-space install bin dirs in front of PATH, so an agent
(and the Node an npm agent's launcher needs) is found there first."""
def with_tools(env: dict[str, str]) -> dict[str, str] {
    out = dict(env);
    have = [p for p in str(out.get("PATH", os.defpath)).split(os.pathsep) if p];
    front = [str(d) for d in tool_bin_dirs()];
    out["PATH"] = os.pathsep.join(front + [p for p in have if p not in front]);
    return out;
}
