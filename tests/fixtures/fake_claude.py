#!/usr/bin/env python3
"""Stands in for `claude -p --output-format stream-json`: one tool call, one
metered model call, and a result line, the way Claude Code writes them."""
import json
import os
import sys
import urllib.request
import uuid

args = sys.argv[1:]
session = args[args.index("--session-id") + 1] if "--session-id" in args else args[args.index("--resume") + 1]
prompt = sys.stdin.read()
base = os.environ.get("ANTHROPIC_BASE_URL")
if base:
    req = urllib.request.Request(f"{base}/v1/messages", data=json.dumps({"model": "fake", "max_tokens": 5}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req).read()
verdict = "VERDICT: DONE\n- checked" if "Review round" in prompt else "Done."
u = {"input_tokens": 3, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 10, "output_tokens": 7}
lines = [
    {"type": "system", "subtype": "init", "session_id": session},
    {"type": "assistant", "session_id": session, "message": {"id": "msg1", "model": "fake", "usage": u, "content": [
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "python wordfreq/wordfreq.py /etc/hosts"}}]}},
    {"type": "user", "session_id": session, "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "ok", "is_error": False}]}},
    {"type": "assistant", "session_id": session, "message": {"id": "msg2", "model": "fake", "usage": u, "content": [
        {"type": "text", "text": verdict}]}},
    {"type": "result", "subtype": "success", "is_error": False, "num_turns": 2, "result": verdict,
     "session_id": session, "total_cost_usd": 0.01,
     "modelUsage": {"fake": {"inputTokens": 6, "outputTokens": 14, "cacheReadInputTokens": 200,
                             "cacheCreationInputTokens": 20}}},
]
import time
for i, l in enumerate(lines):
    print(json.dumps(l), flush=True)
    if i == 1:  # mid-turn, after a tool call: lets a monitor see a running build
        time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
