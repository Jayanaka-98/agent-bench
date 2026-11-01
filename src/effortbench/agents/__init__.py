"""Builder adapters, by name."""

from __future__ import annotations

import importlib

from .base import Agent, BuilderSpec, Endpoint, Turn, TurnRequest  # noqa: F401

ADAPTERS = {
    "claude-code": "effortbench.agents.claude_code:ClaudeCode",
    "opencode": "effortbench.agents.opencode:OpenCode",
    "openhands": "effortbench.agents.openhands:OpenHands",
    "codex": "effortbench.agents.codex:Codex",
    "command": "effortbench.agents.command:Command",
}


def adapter_class(name: str) -> type[Agent]:
    if name not in ADAPTERS:
        raise KeyError(f"no adapter {name!r}; known: {', '.join(ADAPTERS)}")
    mod, cls = ADAPTERS[name].split(":")
    return getattr(importlib.import_module(mod), cls)


def make(spec: BuilderSpec, endpoint: Endpoint | None = None) -> Agent:
    return adapter_class(spec.agent)(spec, endpoint)
