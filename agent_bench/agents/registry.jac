"""Builder adapters, by name."""

import from agent_bench.agents.base { Agent, BuilderSpec, Endpoint }
import from agent_bench.agents.claude_code { ClaudeCode }
import from agent_bench.agents.codex { Codex }
import from agent_bench.agents.command { Command }
import from agent_bench.agents.opencode { OpenCode }
import from agent_bench.agents.openhands { OpenHands }

glob ADAPTERS: list[str] = ["claude-code", "opencode", "openhands", "codex", "command"];

def make(spec: BuilderSpec, endpoint: Endpoint | None = None) -> Agent {
    a = spec.agent;
    if a == "claude-code" {
        return ClaudeCode(spec=spec, endpoint=endpoint);
    }
    if a == "opencode" {
        return OpenCode(spec=spec, endpoint=endpoint);
    }
    if a == "openhands" {
        return OpenHands(spec=spec, endpoint=endpoint);
    }
    if a == "codex" {
        return Codex(spec=spec, endpoint=endpoint);
    }
    if a == "command" {
        return Command(spec=spec, endpoint=endpoint);
    }
    raise KeyError(f"no adapter {a!r}; known: {', '.join(ADAPTERS)}");
}
