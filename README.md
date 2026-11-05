# agent-bench

Measure how much effort a coding agent spends to build something, and compare
that effort across programming abstractions, builders and models. Written in
[Jac](https://www.jac-lang.org).

A **builder** (Claude Code, OpenCode, OpenHands, Codex, or any CLI) gets a
task spec plus an **arm** (the condition under test: a framework section,
skills, notes) in an isolated workspace. A **protocol** decides how its turns,
an optional Claude Code review and the acceptance checks fit together. Every
model call the builder makes goes through one **metering proxy**, so effort
is counted the same way whatever the agent. One **server API** serves the web
UI and the TUI, and a supervising Claude session drives it all through the CLI.

```
experiment.toml ─► runner ─┬─ Task      workspace, spec, acceptance check
                           ├─ Arm       framework section, skills, notes
                           ├─ Builder   adapter: claude-code | opencode | openhands | codex | command
                           ├─ Protocol  one-shot | accept-loop | reviewed (Claude Code driver)
                           └─ Proxy     every builder call metered, per build and role
                                 │
               runs/<run>/<task>__<arm>__<builder>__r<k>/
                 summary.json  trace.jsonl  calls.jsonl  live.json  transcripts/  ws/
                                 │
              server/api.jac  (def:pub: runs, monitor, builds, traces, calls, report, launch, stop)
                 ├── web UI   served at /, typed RPC to the API (server/ui/*.jac)
                 └── TUI      Textual, in-process or over HTTP (--server URL)
```

## Install

Needs `jac` 0.37.25 (the version `jac.toml` pins): download the release binary
for your platform from
[jaseci-labs/jaseci v0.37.25](https://github.com/jaseci-labs/jaseci/releases/tag/v0.37.25),
check it against its `.sha256`, and put it on `PATH` as `jac`. Then:

```bash
jac install --dev              # aiohttp, textual, pytest into .jac/venv
export PATH="$PWD/bin:$PATH"   # bin/agent-bench runs agent_bench/cli.jac under jac
```

`bin/agent-bench` (and the processes it starts: `serve`, a launched run) runs
`$AGENT_BENCH_JAC` if set, else `jac` on `PATH`. It does not read `JAC_BIN`,
which other setups (the jac-paper `env.sh`) set to a directory.

The agents themselves are installed separately; `agent-bench agents` lists the
ones it finds.

## Use

```bash
agent-bench run examples/experiments/smoke.toml --only cc-haiku   # an experiment
agent-bench serve                                                # API + web UI on http://127.0.0.1:8770
agent-bench tui                                                  # the terminal UI, on local files
agent-bench tui --server http://127.0.0.1:8770                   # ... or through a server, e.g. over ssh -L
agent-bench monitor                                              # live view of everything running
agent-bench status runs/smoke
agent-bench trace runs/smoke/<build> --kind bash
agent-bench report runs/smoke --by arm,builder
```

**Server and web UI.** `agent-bench serve` runs `jac run` on
`agent_bench/server/main.jac`: every `def:pub` in `server/api.jac` is served at
`POST /function/<name>`, and the web UI (Monitor, Runs, a run's builds and
report, a build's live trace, metered calls, prompt, acceptance, and
Experiments to launch) is served at `/`. It binds 127.0.0.1: launching a run
executes the experiment's commands, so reach it from elsewhere through an ssh
tunnel, not by opening the port. `launch` accepts only an experiment the server
lists.

**TUI.** Home lists runs and experiment files; `n` launches the highlighted
experiment as a detached process (quitting never stops it). A run shows every
build live with the highlighted build's trace below; `enter` opens a build
(trace with filters, every metered call, summary, prompt, acceptance), `a` the
report, `s` stops the runner. `m`, or `agent-bench monitor`, is one live
screen for everything running across runs: counts, token rate over the last
hour, each build's phase (builder or driver turn, acceptance, a rate-limit
wait, a retry), tokens and calls so far, how long it has been quiet, what it is
doing now, an activity feed, and what just finished. Every screen reads through
the server API, in-process by default or over HTTP with `--server`.

**Supervised by Claude.** `skills/agent-bench/SKILL.md` tells a Claude Code
session how to launch, watch, diagnose and report through the CLI.

## The measure

`tokens.builder.total` = uncached input + cache reads + cache writes + output,
summed over every model call the builder made, as the API itself reported it
to the proxy (`source: "metered"`). Each agent's own count is kept beside it
(`self_reported`) as a cross-check, never as the measure: agents differ in
what they count (side calls, sub-agents, cache semantics).

- Anthropic `input_tokens` is uncached; OpenAI `prompt_tokens` includes cached
  tokens. Both are normalized to the same four parts (`usage.jac`).
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
  analysis patterns. See `config.jac` and `examples/tasks/wordfreq`. Optional:
  - `[workspace.vars]`: per-framework template values, shaped like `slots`,
    e.g. `impl = { byllm = "byLLM", langgraph = "LangGraph", default = "${framework}" }`
    makes `${impl}` usable in the spec, notes, env and acceptance
    (`self_check = "python bench/run.py --impl ${impl}"`).
  - `[prompt] slot_line`: the line naming the builder's directory (default
    ``- **Your work goes in** `${arm_dir}/`.``; `""` drops it).
  - `[prompt] criterion_at`: `"after-notes"` (default: the success criterion
    is the last extra) or `"after-slot"` (right after the slot line, before
    the arm's notes).
  - `[accept] criterion`: the criterion's wording, a template with
    `${describe}` and `${self_check}`.

  With ``slot_line = "- **Your arm directory** is `${arm_dir}/`."``,
  `criterion_at = "after-slot"` and the old criterion text, the prompt is
  worded and ordered as `run_builds.py` gave it.
- **arm.toml**: framework, prompt parts, skills, notes, the framework's
  source paths (to count source reads). See `examples/arms`.
- **experiment.toml**: tasks, arms, builders, reps, protocol, lanes, ports,
  budget, driver, proxy upstreams, gates. See `examples/experiments`.

Text fields are templates: `${ws}`, `${arm_dir}`, `${port}`, `${python}`,
`${run_id}`, `${build}`, `${skills_dir}` (where the builder's adapter puts skills, e.g. `.claude/skills` or `.agents/skills`), ..., plus the task's `[workspace.vars]` (a built-in
name wins over a var of the same name). Unknown `${...}` are left alone, so code in a spec
is never mangled. `${python}` (and `python` on a builder's PATH, via
`${python_bin}`) is `AGENT_BENCH_PYTHON`, else this project's `.jac/venv`
Python, else `python3`: under the jac runtime `sys.executable` is the jac binary.

## Builders

| Adapter | Run | Session resume | Self-reported usage | Skills go to | Checked |
|---|---|---|---|---|---|
| claude-code | `claude -p --output-format stream-json` | `--resume` | `result.modelUsage` (cumulative) | `.claude/skills` | live, and against 134 finished archived jac-paper builds |
| opencode | `opencode run --format json --auto` | `-s <sessionID>` | `step_finish.part.tokens` per call | `.agents/skills` | from source; not yet run |
| openhands | `openhands --headless --json --override-with-envs -f` | off by default (unverified) | `base_state.json` metrics | `.agents/skills` | from source; not yet run |
| codex | `codex exec --json` (Responses API only) | `exec resume <id>` | `turn.completed.usage` (cumulative) | `.agents/skills` | from source; not yet run |
| command | any argv template | optional `resume_argv` | none (metered only) | `.agent-skills/` + a prompt note | tests |

Each adapter gives its agent an isolated config (its own HOME / XDG / CODEX_HOME
under the build directory) so user settings do not leak into builds, and
records how skills were delivered (`builder.skills_delivered` in the summary),
since delivery differs between agents. Claude Code's prompt does not name its
skills (it lists `.claude/skills` itself, as in the jac-paper harness); the
`command` adapter's prompt does.

## Layout of a build

| File | What |
|---|---|
| `build.json` | who is building (written at the start; the UIs read it) |
| `live.json` | while it runs: its phase and since when (removed when it finishes) |
| `prompt-builder.md`, `prompt-driver.md` | exactly what each was given |
| `transcripts/NN-<role>[-retryK].jsonl` | each invocation, in the agent's native output |
| `invocations.jsonl` | one row per invocation: session, self-reported usage, time, errors |
| `trace.jsonl` | every invocation normalized: messages, tool calls (kind), results, usage |
| `calls.jsonl` | this build's proxy ledger rows: one per model call |
| `acceptance/` | each acceptance run's log and verdict |
| `ws/` | the workspace, one commit per round; `final.patch` against the base |
| `summary.json` | status, rounds, acceptance runs, tokens per role (metered and self), analysis, LOC, skills delivered |

`rounds` is the protocol's own count: 1 for one-shot, the acceptance runs for
accept-loop (each round is a builder turn, then a check), the driver's
verdicts for reviewed. `acceptance_runs` is the number of acceptance checks in
every protocol.

## Code

```
agent_bench/
  usage.jac trace.jac proxy.jac           the measure: normalized usage, the trace format, the meter
  agents/                                 base (process loop, limits, retries) + one adapter per agent
  config.jac workspace.jac accept.jac     tasks, arms, experiments; workspaces; acceptance
  protocols.jac build.jac runner.jac      episode protocols, one build, the experiment
  analyze.jac report.jac monitor.jac      trace analyzers, reports, the live monitor's data
  server/api.jac server/main.jac          the API (def:pub) and the served app
  server/ui/*.jac                         the web UI (client components)
  tui.jac cli.jac                         the TUI and the CLI
```

## Tests

`scripts/check.sh` type-checks every module and makes sure each one also
generates code (this jac version can pass a module through `jac check` that
then fails code generation silently). `jac x pytest` runs the suite under the
jac runtime, so the Python tests import the Jac modules directly:

- the proxy against a fake Anthropic/OpenAI API;
- whole builds with scripted builders and a fake Claude Code driver;
- the API in-process, and served by `agent-bench serve`: a run launched over
  HTTP, followed to the end over HTTP, and the TUI reading the same server;
- the TUI and the monitor, driven headless.

CI (`.github/workflows/tests.yml`) installs the pinned jac release binary
(checksum-verified) on Linux and macOS and runs both; it needs no model access
or secrets. `agent-bench legacy-check <jac-paper build dirs>` re-totals builds
from the jac-paper `run_builds.py` harness through this package's accounting.
