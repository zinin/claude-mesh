# Watch-loop stall detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `/mesh-review` and `/mesh-design-review` orchestrators notice a dead executor within the stall threshold instead of sitting silent until the hour-long global budget expires.

**Architecture:** Four moves. **A** — turn on the watchdog that `/mesh-design-review` never enabled. **B** — replace the prose "poll the disk" instruction with a tested shared script, `skills/shared/watch-runs.sh`, that takes a *roster* of `engine[/provider/model]` entries plus `--since EPOCH`, re-resolves each executor's newest run directory every tick, and classifies it `DONE` / `FAILED` / `RUN` / `SILENT` / `MISSING`. **C** — route both prompts through it. **D** — make design-review run the existing `verify-delegation.sh` content gate that `/mesh-review` has always run.

**Tech Stack:** bash 4.2+ (the `printf '%(fmt)T'` builtin replaces every `date` call), GNU `stat -c`, `jq` (only to read two config values), markdown prompts.

## Global Constraints

- The stall threshold is `runtime.timeouts.stall_sec`, **floored at 600**. `codex-exec` and `gemini-exec` hardcode `HARD_ZERO_TIMEOUT=600` and ignore the config key, so a lower threshold would let the watcher call a live run silent before its own watchdog acts. No new config key.
- `--since` is an absolute unix epoch and the **only** volatile value the prompts substitute. The deadline is computed inside the script as `since + global_sec + 300`. Never write arithmetic over a shell variable into a prompt: shell state does not survive between Bash-tool calls, and an unset name in a prompt raises nothing at all.
- **Every verdict exits 0.** The harness surfaces a non-zero background exit as "failed with exit code N", which an LLM orchestrator reads as an error. A non-zero exit (64) means the script itself is broken.
- Detection marks a run failed and continues. **No new retry layer.** In `/mesh-review` retry already exists twice (`watchdog.sh` `MAX_RETRIES=2`, and Step 6.0's `max_redispatch`). In `/mesh-design-review` there is exactly **one** — the watchdog, which Task 3 turns on. Do not write "two layers" into the design-review prompt; `max_redispatch` and `Step 6.0` do not exist in that file.
- `skills/shared/verify-delegation.sh` and `skills/shared/watchdog.sh` are **called, never modified**.
- The `SUPERVISED_MODE` default in the `*-exec` skills stays `none`. Flipping it would strip live `progress-monitor.sh` progress from direct `/claude-mesh:*-exec` invocations.
- New shell code follows `verify-delegation.sh` conventions: `set -u` (not `-e`), a bash version guard, a verdict on stdout, diagnostics on stderr.
- Test files follow `skills/shared/tests/test-verify-delegation.sh`: `assert_eq`, `PASS`/`FAIL` counters, `mktemp -d` fixtures, and a closing `=== Summary: $PASS passed, $FAIL failed ===` with `[ "$FAIL" = "0" ]`.
- **Assert `0 failed`, never a hardcoded pass count.** The previous draft of this plan asserted "180 passed" for `test-config-loader.sh`; the real number on this branch is 246. A count inherited without measuring becomes a false gate.
- CHANGELOG entries go under `## [Unreleased]`; the version bump is a separate release chore and is out of scope.

## File Structure

| File | Responsibility |
|---|---|
| `skills/shared/watch-runs.sh` (new) | The whole watch loop: roster → run dir → status → verdict. Reads existence, size and mtime; never content. |
| `skills/shared/tests/test-watch-runs.sh` (new) | Fixtures under a temporary `--data-dir`; one assert per documented behaviour. |
| `skills/mesh-design-review/SKILL.md` | Step 6: dispatch templates gain `SUPERVISED_MODE: shell`; the watch block calls the script; the collection step gains the content gate. |
| `commands/mesh-review.md` | Step 5a watch block calls the script. |
| `agents/{codex,gemini,ext-claude}-executor.md` | Document `SUPERVISED_MODE` so the dispatch line is forwarded as a parameter instead of leaking into `PROMPT`. |
| `skills/shared/tests/test-loader-resolution.sh` | Canary counts, bumped for the new resolver site in `commands/`. |
| `config.example.yaml` | `stall_sec` comment gains the second consumer and the floor. |

---

### Task 1: `watch-runs.sh` — roster resolution, classification, one evaluation
✅ Done — see commit(s): `6a26aa2`

---

### Task 2: `watch-runs.sh` — the polling loop
✅ Done — see commit(s): `ba43249`, `d151a15` (the second hardens two tests per a human ruling: Test 25's timing bound 1→2, Test 26 wrapped in `timeout 15`)

---

### Task 3: Enable supervised mode for design-review executors
✅ Done — see commit(s): `6e91eef`

---

### Task 4: Route both orchestrators through `watch-runs.sh`
✅ Done — see commit(s): `539b732`, `fe56027` (the second re-resolves `$WATCH` before the `--once` check, replaces the orphaned term "finalized", adds `SNAPSHOT` to the verdict vocabulary, and updates the canary comment)

Two human rulings changed this task's mechanics against the plan's literal text: the loader canary now strips leading whitespace before its exact match (the new call site is indented inside a numbered list item), and the corrected verification expectation for the design-review file is `max_redispatch` = 0 with `Step 6.0` = 1, the sync note's cross-reference.

---

### Task 5: Verify content before accepting a design-review report
✅ Done — see commit(s): `de4c999`, `d251fb7` (the second documents `verify-delegation.sh`'s exit-code contract and guards the `FLIP` verdict, which after a `DONE` means the two tools disagree about where the run lives, not that the executor died)

---

### Task 6: CHANGELOG and full verification
✅ Done — see commit(s): `032cffd`, `658bb7d`, `92007a0`, `815e689`

Beyond the plan's four steps, two human-ruled additions landed here: the stale sync note in both prompt files was rewritten to name all four axes that must NOT be mirrored, and the CHANGELOG's false claim that recovery is signalled (`SILENT → RUN`) was replaced — the watcher's baseline is virtual, so a recovered run produces no event at all.

---

## Before opening a PR

Per the repository convention (`git log 326942d`), the plan and design documents must not
appear in the PR diff:

```bash
git rm docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md \
       docs/superpowers/plans/2026-07-27-watch-loop-stall-detection-continuation-prompt.md \
       docs/superpowers/plans/2026-07-28-watch-loop-stall-detection-continuation-prompt.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-review-merged-iter-1.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-dogfood-findings.md
git commit -m "docs: drop the design and review documents before the PR"
```

They stay reachable in this branch's history.
