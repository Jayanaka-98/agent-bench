# effortbench

Measure how much effort a coding agent spends to build something, and compare
that effort across programming abstractions, builders and models.

A **builder** (Claude Code, OpenCode, OpenHands, Codex, or any CLI) gets a
task spec plus an **arm** (the condition under test: a framework section,
skills, notes) in an isolated workspace. A **protocol** decides how its turns,
an optional Claude Code review and the acceptance checks fit together. Every
model call the builder makes goes through one **metering proxy**, so effort
is counted the same way whatever the agent. A supervising Claude session (or
you, in the TUI) launches runs, watches them and reads the results.

```
experiment.toml ─► runner ─┬─ Task      workspace, spec, acceptance check
                           ├─ Arm       framework section, skills, notes
                           ├─ Builder   adapter: claude-code | opencode | openhands | codex | command
                           ├─ Protocol  one-shot | accept-loop | reviewed (Claude Code driver)
                           └─ Proxy     every builder call metered, per build and role
                                 │
               runs/<run>/<task>__<arm>__<builder>__r<k>/
                 summary.json  trace.jsonl  calls.jsonl  transcripts/  ws/  final.patch
```

## Install

```bash
uv venv --python 3.13 && uv pip install -e '.[tui,test]'
```

Python 3.11+. Runtime dependency: aiohttp (the proxy); Textual for the TUI.
The agents themselves are installed separately; `effortbench agents` lists
the ones found.

## Use

```bash
effortbench tui --runs runs --experiments examples/experiments   # launch and watch
effortbench run examples/experiments/smoke.toml --only cc-haiku   # or headless
effortbench status runs/smoke
effortbench trace runs/smoke/<build> --kind bash
effortbench report runs/smoke --by arm,builder
```

**TUI.** Home lists runs and experiment files; `n` launches the highlighted
experiment as a detached process (quitting the TUI never stops it). A run
shows every build live (state, status, metered tokens so far, calls) with the
highlighted build's trace streaming below; `enter` opens a build (trace with
filters, every metered call, summary, prompt, acceptance logs), `a` the
aggregate report, `s` stops the runner.

**Supervised by Claude.** `skills/effortbench/SKILL.md` tells a Claude Code
session how to launch, watch, diagnose and report through the CLI. Install it
in the supervising session's `.claude/skills/`.

## The measure

`tokens.builder.total` = uncached input + cache reads + cache writes + output,
summed over every model call the builder made, as the API itself reported it
to the proxy (`source: "metered"`). Each agent's own count is kept beside it
(`self_reported`) as a cross-check, never as the measure: agents differ in
what they count (side calls, sub-agents, cache semantics).

- Anthropic `input_tokens` is uncached; OpenAI `prompt_tokens` includes cached
  tokens. Both are normalized to the same four parts (`usage.py`).
- A streamed Chat Completions request without `stream_options.include_usage`
  reports no usage; the proxy adds it and marks the call.
- The proxy can hold the real key (`key_env`) so builders only see a dummy.
  Without it, the client's own auth passes through (Claude Code's login).
- Self-reports that are cumulative per session (Claude Code, Codex) count each
  session once, at its last turn.

## Configuration

- **task.toml**: workspace (a directory copy, or a `git archive` of a repo
  ref with arms stripped and shared files kept), prompt parts, machine notes,
  env, acceptance (a shell command writing a JSON verdict, or a Python hook),
  analysis patterns. See `config.py` and `examples/tasks/wordfreq`.
- **arm.toml**: framework, prompt parts, skills, notes, the framework's
  source paths (to count source reads). See `examples/arms`.
- **experiment.toml**: tasks, arms, builders, reps, protocol, lanes, ports,
  budget, driver, proxy upstreams, gates. See `examples/experiments`.

Text fields are templates: `${ws}`, `${arm_dir}`, `${port}`, `${python}`,
`${run_id}`, `${build}`, ... Unknown `${...}` are left alone, so code in a spec
is never mangled.

## Builders

| Adapter | Run | Session resume | Self-reported usage | Skills go to | Checked |
|---|---|---|---|---|---|
| claude-code | `claude -p --output-format stream-json` | `--resume` | `result.modelUsage` (cumulative) | `.claude/skills` | live, and against 187 archived jac-paper builds |
| opencode | `opencode run --format json --auto` | `-s <sessionID>` | `step_finish.part.tokens` per call | `.agents/skills` | from source; not yet run |
| openhands | `openhands --headless --json --override-with-envs -f` | off by default (unverified) | `base_state.json` metrics | `.agents/skills` | from source; not yet run |
| codex | `codex exec --json` (Responses API only) | `exec resume <id>` | `turn.completed.usage` (cumulative) | `.agents/skills` | from source; not yet run |
| command | any argv template | optional `resume_argv` | none (metered only) | `.agent-skills/` + a prompt note | tests |

Each adapter gives its agent an isolated config (its own HOME / XDG / CODEX_HOME
under the build directory) so user settings do not leak into builds, and
records how skills were delivered, since delivery differs between agents.

## Layout of a build

| File | What |
|---|---|
| `build.json` | who is building (written at the start; the TUI reads it) |
| `prompt-builder.md`, `prompt-driver.md` | exactly what each was given |
| `transcripts/NN-<role>[-retryK].jsonl` | each invocation, in the agent's native output |
| `invocations.jsonl` | one row per invocation: session, self-reported usage, time, errors |
| `trace.jsonl` | every invocation normalized: messages, tool calls (kind), results, usage |
| `calls.jsonl` | this build's proxy ledger rows: one per model call |
| `acceptance/` | each acceptance run's log and verdict |
| `ws/` | the workspace, one commit per round; `final.patch` against the base |
| `summary.json` | status, tokens per role (metered and self), analysis, LOC |

## Tests

`pytest` runs the proxy against a fake Anthropic/OpenAI API, whole builds with
scripted builders and a fake Claude Code driver, and the TUI headless.
`effortbench legacy-check <jac-paper build dirs>` re-totals builds from the
jac-paper `run_builds.py` harness through this package's accounting.
