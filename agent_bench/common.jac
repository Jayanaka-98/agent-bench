"""Shared type names and helpers."""

import os;
import shutil;
import sys;

"""A JSON object as decoded: string keys, values of any JSON type."""
type Json = dict[str, any];

"""The jac binary to run agent-bench's own processes (the server, a launched
run) with: AGENT_BENCH_JAC, else `jac` on PATH, else the running jac (under
the jac runtime `sys.executable` is the jac binary). JAC_BIN is not read:
other environments (the jac-paper env.sh) set it to a directory."""
def jac_bin -> str {
    return os.environ.get("AGENT_BENCH_JAC") or shutil.which("jac") or sys.executable;
}
