#!/usr/bin/env bash
# Type-check every module, then make sure each one also generates code.
# `jac check` alone is not enough: this jac version can pass a module that then
# fails code generation with no diagnostic (see json_reply in proxy.jac).
set -u
cd "$(dirname "$0")/.."
files=$(find agent_bench -name '*.jac' | sort)
status=0
jac check $files 2>&1 | grep -E "error\[|failed files|ok \[100%\]" || true
jac check $files >/dev/null 2>&1 || status=1
for f in $files; do
  if jac tool ir py "$f" 2>&1 | tail -1 | grep -q "^Compile failed"; then
    echo "codegen failed: $f"
    status=1
  fi
done
exit $status
