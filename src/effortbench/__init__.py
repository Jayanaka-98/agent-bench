"""effortbench: run coding agents on build tasks and measure the effort they spend.

The pieces, each replaceable on its own:

- **Task** (task.py): a workspace to build in, the spec, and an acceptance check.
- **Arm** (arm.py): the condition under test: framework section, skills, notes.
- **Agent** (agents/): the builder CLI. Claude Code, OpenCode, OpenHands, Codex,
  or any command line. Each adapter turns its agent's log into one trace format.
- **Protocol** (protocols.py): one-shot, or reviewed by a Claude Code driver.
- **Proxy** (proxy.py): every builder model call goes through one metering proxy,
  so tokens are counted the same way whatever the agent.
- **Runner** (runner.py): the experiment matrix, lanes, ports, resume, reports.
"""

__version__ = "0.1.0"
