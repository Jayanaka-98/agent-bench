# agent-bench validation on clarity1

2026-11-04. agent-bench `main` at `869e5eb` (after PR #2, the Jac port), on clarity1 with
jac 0.37.25 and Claude Code 2.1.316, logged in as community@jaseci.org (subscription).

## Summary

agent-bench reproduces the jac-paper harness (`run_builds.py`). On the same benchmark,
with the same prompt, workspace and acceptance check, it gives the same outcomes and
token counts within rep-to-rep spread. Its own accounting agrees with the old harness
on all 233 archived clarity1 builds. All three protocols, resume, the budget stop and
role separation work live. Four small bugs and three prompt-parity gaps are listed at the end; all are now fixed (section 5).

| Check | Result |
|---|---|
| Offline suite on Linux (`scripts/check.sh`, `jac x pytest`) | clean, 24 passed |
| `legacy-check` over every archived clarity1 build | 233 of 233 match (builder and driver, tokens and cost); 1 skipped, unfinished |
| Metered (proxy) = self-reported, live | equal on every finished build, builder and driver: 27 builds, plus 5 from a first run of the hidden-requirement task; resumed sessions included |
| Jac-paper parity, meeting-assistant, 2 arms x 3 reps | 6 of 6 pass the old acceptance; tokens within the old spread |
| one-shot, accept-loop, reviewed protocols | all work; the feedback reaches the builder, which fixes the problem in round 2 |
| Budget stop | stops mid-turn, `over-budget` |

## 1. Accounting against the old harness

`agent-bench legacy-check ~/agent-eval/runs/*/*__*` re-totals each archived build's
transcripts through agent-bench's accounting and compares it with that build's
`summary.json`. Runs covered: os1–os3, os1-mockllm, ov4-1, ov41-1..3, jtk5–jtk10, limit-invalid.

- 466 of 466 role rows OK: builder and driver, tokens and USD.
- One build skipped: `os1-mockllm/codeagent__byllm`, which never wrote a summary.
- So no clarity1 build hit the old `totals()` limit-resume undercount, unlike `od1`.

## 2. Parity: the one-shot study's meeting-assistant, rerun

The task pack is `~/agent-bench-val/jacpaper` on clarity1, with a copy in
`~/agent-work/jac-paper/agent-bench-val`. It uses the old harness's own pieces:
- `repo.git` at `base-parity`, with the same arms stripped;
- `prompts/requirements/meeting-assistant.md`;
- the 0.37 suffix;
- `machine.md`;
- the v10 skill and note;
- the environment `build_env` gives;
- acceptance through `acceptance.accept()`, unchanged (`accept_legacy.py`).

Builder: Claude Code, `claude-opus-5-5`, one-shot, as in the study.

**Inputs are identical.**
- The base workspace trees match the old builds blob for blob: 41 files for Jac, 50 for the SDK, skills included.
- The builder prompt differs only in the workspace path and three lines (section 5).

**Results.**

| Arm | Harness | Runs | Accepted | Builder tokens per rep | Mean | Arm lines added |
|---|---|---|---|---|---|---|
| Jac v10 | run_builds | jtk10-1..3 | 3/3 | 357k, 333k, 271k | 320k | 207, 238, 211 |
| Jac v10 | agent-bench | parity-meeting r1..3 | 3/3 | 298k, 325k, 249k | 290k | 213, 195, 202 |
| OpenAI SDK | run_builds | os1..3 | 3/3 | 243k, 206k, 254k | 234k | 207, 215, 204 |
| OpenAI SDK | agent-bench | parity-meeting r1..3 | 3/3 | 223k, 277k, 239k | 246k | 206, 211, 201 |

- Every agent-bench rep lies inside the range set by the old reps, or within one rep's spread of it.
- The Jac-over-SDK ordering holds.
- Source reads stay at zero for Jac.
- Wall time is not comparable. The old acceptance serializes per benchmark (`bench_lock`), so 6 parallel builds of one benchmark queue on it. The jtk runs had one build per benchmark.

## 3. Protocols, resume and budget (toy task)

| Experiment | What it checks | Result |
|---|---|---|
| val-oneshot: wordfreq, 2 arms x Haiku/Sonnet x 3 reps, 6 lanes | metering, skill delivery, parallel lanes | 12/12 pass; metered = self on all; the skill arm opened the skill once (`skills_opened` 1) |
| val-accept: accept-loop | the pass path | 2/2 pass in round 1 |
| val-accept2: accept-loop, `wordfreq-hidden` | resend, resume, per-round metering | 4/4 fail round 1 and pass round 2, on the same resumed session; metered = self (cumulative self-report counted once) |
| val-reviewed: reviewed, Opus driver | driver metered under its own role | 2/2 pass; driver 56k, builder 70k |
| val-reviewed2: reviewed, `wordfreq-hidden` | driver review, then a failing acceptance sent back | fail after review 1, pass after review 2 |
| val-budget: 40k budget | budget stop | `over-budget` at 55.9k metered (one call overshoot); no self-report, since the killed session never wrote one |

- `wordfreq-hidden` adds one acceptance requirement the spec never states (a `--json` flag), so round 1 must fail.
- My first version of its check expected a stopword in the output and failed correct builds. That was my bug; the fixed check passes on those builds' workspaces.
- The proxy ledger has one `HEAD /api/hello` row per Claude Code session. It carries no usage and is correctly ignored.

## 4. Not validated yet

- **The OpenCode, OpenHands and Codex adapters.** None of them is installed on clarity1.
  - OpenRouter has $4.05 left, so the GLM and GPT builders in `smoke.toml` can't run there either.
- **Rate-limit waits and retries.** None occurred.
- **The web UI, the TUI and `monitor`** against live runs on clarity1.
- **The other five benchmarks.** Each needs its own task pack. RagGPT, YTNavigator and CodeAgent need extra environment (Postgres, ports, docker).

## 5. Bugs and gaps found

All six are fixed on `fix/validation-bugs`, each with a test (`tests/test_prompt.py`,
`tests/test_proxy.py`, `tests/test_end_to_end.py`).

1. **`JAC_BIN` collision.** `bin/agent-bench` runs `${JAC_BIN:-jac}`. The jac-paper `env.sh` sets `JAC_BIN` to a *directory* (0.31.1), so the launcher fails with "Is a directory".
   - Fix: read `AGENT_BENCH_JAC` instead.
   - Workaround used: set `JAC_BIN` to the binary for the runner only.
   - **Fixed.** The launcher, `serve` and a run launched from the API all run `$AGENT_BENCH_JAC`, else `jac` on PATH (`common.jac: jac_bin`). `JAC_BIN` is no longer read.
2. **`outside_paths` false positive.** The reviewed protocol flags the driver's own `driver-scratch/` as outside the workspace. It should be allowed.
   - **Fixed.** The build's `driver-scratch/` is always allowed, next to the task's `allowed_outside` (`Build.allowed_outside`).
3. **`rounds` is 0 for the accept-loop.** It counts driver verdicts, so an accept-loop build that needed 2 acceptance runs reports `rounds 0`. The summary should also report the number of acceptance runs.
   - **Fixed.** Each protocol sets `rounds`: one-shot 1, accept-loop its acceptance runs, reviewed its verdicts (unchanged). The summary already had `acceptance_runs` (every protocol); field names are unchanged, so the monitor, TUI, web UI and reports read it as before.
4. **Proxy traceback on a killed client.** When the budget stop kills the builder, aiohttp logs `ClientConnectionResetError` from `proxy.jac:239`. It is harmless and should be caught.
   - **Fixed.** Line 239 was `out.prepare()`, which raised when the client was already gone. It is now caught with the other client-gone errors (`ConnectionError`, `RuntimeError`); the proxy keeps reading the upstream, so the call is still counted.
5. **Prompt parity.** Compared with `run_builds.py`, the builder prompt:
   - says "Your work goes in" instead of "Your arm directory is";
   - words the success criterion slightly differently, and places it after the arm note instead of before;
   - adds an HTML comment naming the installed skills.

   To match exactly, let a task template the slot line and the criterion, and drop the comment for claude-code.
   - **Fixed.** New task fields: `[prompt] slot_line`, `[prompt] criterion_at = "after-slot"` and `[accept] criterion` (a template with `${describe}` and `${self_check}`). Without them the prompt is as before. The claude-code adapter adds no comment; the summary records where skills went (`builder.skills_delivered`).
6. **No per-framework template values in a task.** The acceptance self-check needs each arm's runner key (`--impl byLLM`), but the context has no such value. I used `$(basename ${arm_dir})`. Per-framework values like `slots` (for example `[workspace.vars]`) would fix it.
   - **Fixed.** `[workspace.vars]`: `impl = { byllm = "byLLM", default = "${framework}" }` makes `${impl}` available in every template of the build.

## 6. The fixes, validated on clarity1

Branch `fix/validation-bugs` at `17e1fc2`, same box and versions. The launcher
`~/agent-bench-val/run2.sh` sources the jac-paper `env.sh` and leaves its
`JAC_BIN` (a directory) in place, setting only `AGENT_BENCH_JAC`.

| Check | Result |
|---|---|
| Offline suite on Linux (`jac x pytest`, `scripts/check.sh`) | 32 passed; check clean |
| 1. Launch with `JAC_BIN` set to a directory | every run below started; no workaround |
| 2. `val-reviewed-fix` (the experiment that showed the bug), 2 reps | both drivers wrote into `driver-scratch/`; `outside_paths` is empty for both (it listed those files before) |
| 3. `val-accept2-fix`, Haiku and Sonnet | `rounds` 2, `acceptance_runs` 2 for both (fail, then pass); `val-oneshot-fix`: `rounds` 1 |
| 4. `val-budget-fix` | `over-budget` at 55.8k metered; no traceback in the log |
| 5. Parity pack `meeting-assistant-v2` with `slot_line`, `criterion_at = "after-slot"` and `criterion` | `--dry-run` builder prompt identical to `run_builds.py`'s (jtk10-1), except the workspace path |
| 6. Same pack, self_check through `${impl}` | the live Jac v10 build (`parity-v2`, Opus, one-shot) passes the old acceptance: 10/10 complete and consistent, 9 in range; 284k builder tokens, inside the jtk10 range |
| Metering | metered = self-reported on all 8 finished builds, builder and driver |

The reviewed and accept-loop runs (`val-reviewed2-fix`) behave as before: a
failing acceptance goes back, and round 2 passes.

## Reproduce (clarity1)

```bash
~/agent-bench-val/jacpaper/run.sh parity-meeting.toml        # sources env.sh, sets JAC_BIN (before the fix)
~/agent-bench-val/run2.sh jacpaper/exp parity-v2.toml         # after: env.sh as is, AGENT_BENCH_JAC
cd ~/agent-bench-val/exp && agent-bench run val-accept2.toml   # toy experiments
agent-bench legacy-check ~/agent-eval/runs/*/*__*
```

Runs: `~/agent-bench-val/runs/` (toy; `*-fix` after the fixes), `~/agent-bench-val/jacpaper/runs/parity-meeting/` and `parity-v2/`.
