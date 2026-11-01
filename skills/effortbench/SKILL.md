---
name: effortbench
description: Run and supervise effortbench experiments, where builder agents (Claude Code, OpenCode, OpenHands, Codex or any CLI) build tasks and their effort is measured in metered tokens. Use when launching a build experiment, checking on running builds, reading a builder's trace, comparing builders or arms, or diagnosing a failed build.
---

# Supervising effortbench

You are the supervisor. Builders are separate agent processes that the harness
launches; you never build the task yourself, and you do not edit a build's
workspace. Your job: launch, watch, diagnose, and report.

## Launch

```bash
effortbench run EXPERIMENT.toml --dry-run          # prepare workspaces + prompts only; read prompt-builder.md
effortbench run EXPERIMENT.toml --only cc-opus     # a subset: task, arm, builder, rK, or part of a build id
```

Launch long runs in the background (`run_in_background`, or `setsid nohup`),
never in the foreground. Re-running the same run id resumes: finished builds
are skipped, half-finished ones restart clean.

## Watch

```bash
effortbench status runs/<run> --json     # every build: state, status, metered tokens so far, calls
effortbench trace runs/<run>/<build> --role builder --kind bash   # what the builder did
effortbench trace runs/<run>/<build> --grep 'Error|Traceback'
```

Check on a run at a cadence that matches it: builds take minutes to hours.
A build stuck on the same transcript with no new calls for a long time is
worth a look (`trace`, then the tail of `transcripts/*.err`).

## Report

```bash
effortbench report runs/<run> [runs/<run2> ...] --by task,arm,builder --json
```

The measure is `tokens.builder.total` with `source: "metered"`: every model
call the builder made, counted at the proxy as uncached input + cache reads +
cache writes + output. `self_reported` is the agent's own count, kept as a
cross-check; never mix the two in one comparison. A build with `source: "self"`
was not metered (no `endpoint`), so it is not comparable with metered builds.

When comparing, say what was held fixed. Comparing arms (abstractions) needs
the same builder and model; comparing builders needs the same arm and model.
Report n, the pass rate (`works`), and the median as well as the mean: one
build that spends its budget on a flaky endpoint moves a mean a lot.

## Diagnose a failed build

1. `summary.json`: `status`, `acceptance.reasons`, `errors`, `analysis`.
2. `acceptance/accept-<k>.log`: what the check saw.
3. `trace`: the last tool calls before the final message.
4. `analysis.outside_paths`: anything the builder read outside its workspace.
5. `resent_without_resume` > 0 means the agent could not continue its session,
   so follow-ups re-sent the task: that build's token count includes the re-send.

Infrastructure failures (rate limits, a dead proxy, a full disk, a bad key)
are not the builder's failures. Name them as such, fix the infrastructure, move
the build directory aside, and re-run it.
