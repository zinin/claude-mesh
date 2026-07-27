## TASK

Continue work on watch-loop stall detection in claude-mesh. The design and the implementation
plan have both been rewritten against four settled architectural decisions and committed.
**No task in the plan has been executed** — all 38 steps are unchecked.

Branch: `fix/watch-loop-stall-detection` (already checked out, 5 commits ahead of master).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents)
- Assume what task to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md` (commit `3c2deb7`)
- Plan: `docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md` (commit `c9556f0`)

Read both. They are self-contained and current.

Two further documents exist and are **not required reading** — everything actionable in them
has been absorbed into the two above. Consult them only for provenance:
- `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-review-merged-iter-1.md`
- `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-dogfood-findings.md`

## PROGRESS

**Done:**
- [x] Brainstorming; root cause established and verified against the run archive
- [x] Design review iteration 1 — 8 reviewers, merged and committed (`631cffc`)
- [x] Four architectural decisions settled with the user (below)
- [x] Design document rewritten against them (`3c2deb7`)
- [x] Implementation plan rewritten (`c9556f0`), and its shell code executed rather than read
- [x] All 18 verified auto-fixes from iteration 1 applied to the final text

**Remaining — none of these has been started:**
- [ ] Task 1: `watch-runs.sh` — roster resolution, classification, one evaluation
- [ ] Task 2: `watch-runs.sh` — the polling loop
- [ ] Task 3: Component A — `SUPERVISED_MODE: shell` in design-review + three agent contracts
- [ ] Task 4: Component C — both prompts through `watch-runs.sh` + canary bump
- [ ] Task 5: Component D — `verify-delegation.sh` content gate in design-review
- [ ] Task 6: CHANGELOG and full verification

**The user has not yet chosen how to proceed.** The three options put to them were:
subagent-driven execution, inline execution, or a second design-review iteration over the
rewritten documents first. Do not assume — ask.

## THE FOUR DECISIONS (settled; do not reopen without the user)

1. **The watcher holds a roster, not directories.** `engine[/provider/model]` entries plus
   `--since EPOCH`, re-resolving the newest run dir every tick. A fixed list is disproven: a
   self-retrying executor creates a *new* directory and the old one goes quiet, so a live
   executor gets reported dead. The deadline is computed inside the script from `--since`, so
   exactly one volatile value crosses the Bash-call boundary and the script validates it.
2. **`DONE` splits into `DONE` and `FAILED`**, on the `cleanup` exit code, and `DONE`
   additionally requires a non-empty `output.txt`. Content is judged by *calling*
   `verify-delegation.sh` (Task 5), never by duplicating its rules. The watcher's silence
   status is `SILENT`, freeing `STALLED` for the meaning `verify-delegation.sh` already gives it.
3. **Component B stays in full**, with an honest justification: after Component A the stall
   sensor is the least of its five jobs, and the cost being argued about is the watch loop
   itself, not the threshold. The threshold is floored at `max(stall_sec, 600)`.
4. **Every verdict exits 0.** A non-zero exit means the script is broken, never that an
   executor died.

## SESSION CONTEXT

**The plan's code was executed, not dry-run.** Both bash blocks were extracted from the plan
file, Task 2 was applied verbatim to Task 1's output, and the suite was run: **52 passed,
0 failed** at the Task 1 boundary and **61 passed, 0 failed** at the Task 2 boundary, in about
19 seconds. The script was then run against the real 2026-07-27 run directories and returned
`ALL_DONE` with **all four self-retries followed** into their new directories, including the
one carrying a `-retry` suffix. Reproduce by writing the two blocks to a scratch
`shared/watch-runs.sh` and `shared/tests/test-watch-runs.sh`, symlinking the real
`config-loader.sh` alongside, and running the suite. **Do this again if you change the plan's
code** — the previous session's "dry-run outside the repo" still shipped nine Critical defects.

**Three defects were found only by running it**, and are already fixed in the committed plan:
the test suite's `row()` helper matched the reason line (printed first, and it names entries
too), so several row assertions were passing against the wrong line; Test 27 built a deadline
from a `NOW` stamped when the suite started, which the suite outlives; and with the deadline
checked first, a roster that finished while the orchestrator was busy reported `DEADLINE` over
six rows reading `DONE`. The check order is now all-done → settle → deadline → change.

**Numbers were re-measured, not inherited.** design-review 42/223 supervised, code-review
242/255. Across 286 `watchdog.log` files: `cleanup` 286, `complete` 246, `attempt_failed` 13,
`bail` 2 (both `global_timeout`, zero `all_attempts_failed`), `stall_detected` 0,
`stream_lost` 0. 40 runs carry `cleanup` without `complete` — 38 with `exit_code:143`, 2 with
`exit_code:2` — and 36 of those have neither `final` nor `output.txt`. The `bail.reason`
tabulation is the falsifiable check reviewer `ollama/minimax` asked for; it confirms the
design's inference rather than refuting it. **Verify any number before propagating it**: the
previous plan's "180 passed" baseline came from the input document and was wrong (246).

**The content gate was validated on the real artifact.** `verify-delegation.sh` classifies the
torn `alibaba/qwen` attempt — 47429 bytes of the model's narration — as `STALLED` ("no usable
result event in raw.jsonl"), and its supervised retry as `REAL` (`num_turns=26`). Task 5 exists
because that verdict is available and design-review never asks for it.

**Two auto-fixes from iteration 1 were deliberately inverted** by the new interface: the
per-position `new_statuses` fix is moot (per-entry transitions removed set arithmetic and the
`,state` fallback entirely), and the requested test asserting "`--once` never yields `CHANGED`"
is now the opposite — with a virtual baseline, a one-shot check must name an already-dead
executor.

**Anomaly that is not one:** a supervised run *does* always write `watchdog.log`. An earlier
`ls | head` in this session truncated the listing and briefly suggested otherwise.

**`--since` is rejected if older than 24 hours**, so the 2026-07-26 incident directories can no
longer be used for a live smoke check. Use the 2026-07-27 13:0x runs instead.

**Scope boundaries the user set:** `skills/shared/verify-delegation.sh` and
`skills/shared/watchdog.sh` are called, never modified; the `SUPERVISED_MODE` default in the
`*-exec` skills stays `none`; the point-4 routing divergence between the two prompt files is
out of scope; plumbing `stall_sec` into `codex-exec`/`gemini-exec` is out of scope (the 600
floor covers it).

**Process constraints (`~/.claude/CLAUDE.md`):** design and plan documents must not be
committed to master, and must be `git rm`'d from the branch before opening a PR — they stay in
branch history. The branch was created with `git switch -c` at the user's choice.

**Do not relitigate the root cause.** It is sound and was confirmed live: during iteration 1's
own review, four of five ext-claude executors died mid-stream in the default unsupervised mode
and only recovered because the executor agents improvised their own retries.

## PLAN QUALITY WARNING

This plan is in better shape than its predecessor — its shell code was executed end to end and
its assertions were measured. But **the prompt-file edits in Tasks 3, 4 and 5 are verified only
by reading**, and Task 4 in particular replaces long blocks in two files that must stay
mirrored. The plan may still contain:
- Inaccuracies in the quoted "replace this line" anchors, if those files changed
- Oversights about edge cases or dependencies
- Assumptions that no longer match the codebase

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the two documents listed above
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
