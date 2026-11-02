"""Builder adapters, by name."""

from __future__ import annotations

import importlib

from .base import Agent, BuilderSpec, Endpoint, Turn, TurnRequest  # noqa: F401

ADAPTERS = {
    "claude-code": "agent_bench.agents.claude_code:ClaudeCode",
    "opencode": "agent_bench.agents.opencode:OpenCode",
    "openhands": "agent_bench.agents.openhands:OpenHands",
    "codex": "agent_bench.agents.codex:Codex",
    "command": "agent_bench.agents.command:Command",
}


def adapter_class(name: str) -> type[Agent]:
    if name not in ADAPTERS:
        raise KeyError(f"no adapter {name!r}; known: {', '.join(ADAPTERS)}")
    mod, cls = ADAPTERS[name].split(":")
    return getattr(importlib.import_module(mod), cls)


def make(spec: BuilderSpec, endpoint: Endpoint | None = None) -> Agent:
    return adapter_class(spec.agent)(spec, endpoint)
