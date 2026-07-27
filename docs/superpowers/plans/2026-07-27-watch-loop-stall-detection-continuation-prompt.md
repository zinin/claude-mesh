## TASK

Continue work on watch-loop stall detection in claude-mesh. Iteration 1 of the design review
is finished; **no fixes have been applied yet**. The chosen path (variant B) is: settle three
architectural decisions FIRST, then rewrite the design and plan against them, then apply the
accumulated auto-fixes to the final text — so that nothing is written twice.

Branch: `fix/watch-loop-stall-detection` (already checked out, 3 commits ahead of master).

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

- Design: `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md`
- Plan: `docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md`
- **Merged review (8 reviewers):** `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-review-merged-iter-1.md`
- **First-hand findings from running the design live:** `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-dogfood-findings.md`

Read all four. The merged review is the largest and the most important — the design and plan
are both known to be partly wrong, and the review says where.

## PROGRESS

**Done:**
- [x] Brainstorming — root cause established and verified against 212 archived runs
- [x] Design document written and committed (`9636195`)
- [x] Implementation plan written and committed (`f70101c`); its shell code was dry-run
      outside the repo before committing
- [x] Design review iteration 1 — 8 reviewers dispatched, all 8 reported, output merged
      and committed (`631cffc`)
- [x] Step 9 classification: 18 auto-fixes, 13 disputed, 16 dismissed, 0 repeats

**Remaining:**
- [ ] Settle the three architectural decisions below
- [ ] Rewrite the design document against those decisions
- [ ] Rewrite the affected plan tasks
- [ ] Apply the 18 auto-fixes to the rewritten text
- [ ] Commit; optionally run design review iteration 2
- [ ] Then execute the plan (Tasks 1–5, none started)

## THE THREE DECISIONS (this is the immediate work)

The 13 disputed findings collapse into three questions. Everything else depends on them.

### Decision 1 — what handle does the watcher hold?

Today `watch-runs.sh` takes a fixed list of run directories captured at dispatch. That is
disproven: an executor that dies and self-retries creates a **new** directory, the abandoned
one crosses `stall_sec`, and a live executor is reported dead. Observed 4× in one run, and one
retry directory even carried a different suffix (`…-iter-1-retry`), defeating glob
rediscovery.

Compounding this, `DISPATCH_EPOCH` and `$WATCH` do not survive between Bash-tool calls, so the
snippet's `DEADLINE=$(( DISPATCH_EPOCH + … ))` collapses to `3900` and the watcher reports the
budget expired on its first evaluation — silently, because bash reads the dangling `+` as
unary plus and `is_pos_int 3900` passes.

Candidates: keep directories and require a literal epoch substituted into every call; or take
`engine[/provider/model]` plus `--since EPOCH` and re-resolve the newest match each tick (the
way `verify-delegation.sh` already does); or a `--state-file` written once at dispatch holding
the deadline and the roster. The second and third also remove most of the prose rules.

### Decision 2 — what does `DONE` mean, and is there a `FAILED`?

`DONE` currently conflates "stopped changing" with "produced a usable result". Three
independent confirmations: a torn run left a 47429-byte `output.txt` containing only the
model's narration and was classified `DONE`; `watchdog.sh` `bail()` creates `final` and writes
`cleanup` even when every attempt failed; and at `rc=0` `output.txt` can still be empty.
`/mesh-review` is protected downstream by `verify-delegation.sh`; design-review has no
analogue, so the new script widens that asymmetry.

Candidates: state plainly that `DONE` means finalized-not-successful and mandate
`verify-delegation.sh` before accepting a report; or add a `FAILED` status read from
`watchdog.exit` (`reason: all_attempts_failed|global_timeout`) — roughly five lines; or both.
Also settle the naming collision: `verify-delegation.sh` already emits `STALLED` with a
different meaning inside the same command (`opus` K6 suggests `SILENT` for the watcher).

### Decision 3 — does Component B earn its cost after Component A?

`claude:opus` measured: `cleanup` is present in **282 of 282 completed** supervised runs and
`stall_detected` in **0 of 284**. After Component A every orchestrated run is supervised and
`watchdog.log` heartbeats every 60s regardless of stream activity, so `quiet` can barely
exceed `stall_sec` while the watchdog lives. **Component A alone would have closed the
incident**, because `cleanup` increments the finished counter the improvised watcher woke on.

So Component B is insurance against an executor not honouring `SUPERVISED_MODE`, not a
liveness sensor — and it costs ~130 lines, 36 asserts and two mirrored prompt rewrites. The
counter-argument, which this run supports: non-compliance is real and non-deterministic —
today all six executors started unsupervised, and four only became supervised because they
improvised it themselves after dying.

Candidates: keep B as designed; keep a reduced B; drop B and ship A alone. **Note the user
already chose "watchdog + net" during brainstorming — reopening this needs their explicit
agreement, not an inference.**

## THE 18 AUTO-FIXES (apply AFTER the rewrite, to the final text)

Verified by hand in the previous session, marked ✔:

1. ✔ Test baseline is **246**, not 180 — wrong in four places (plan Global Constraints,
   Task 1 Step 5, Task 5 Step 2, design Testing). Assert `0 failed` with no hardcoded count.
   Full measured baseline is in the merged review.
2. ✔ Task 5 Step 2 omits `skills/shared/tests/test-check-context-size.sh` (6 suites exist).
3. ✔ Task 3 Step 7 expects `grep -c 'SUPERVISED_MODE: shell'` = 2; the real answer is **3**,
   because Step 5's explanatory paragraph contains the same literal.
4. ✔ Task 4 breaks `skills/shared/tests/test-loader-resolution.sh` — a deliberate canary
   asserting 5 / 5 / 3. A fourth resolver copy makes it 6 / 6 / 4. Bump the numbers, use all
   **three** canonical lines (the plan's copy drops the `[ -f "$LOADER" ] || …` error check),
   and add the test file to Task 4's modified list.
5. `${CLAUDE_PLUGIN_ROOT}` is forbidden inside Bash blocks by `mesh-design-review/SKILL.md`'s
   own "Locating plugin files" section — use `SKILL_BASE/../shared/watch-runs.sh` plus an
   explicit `[ -x "$WATCH" ]` check. The `find` fallback would select the installed 0.5.0
   cache, where the script does not exist.
6. Remove the false "retry already exists at two layers / Step 6.0's `max_redispatch`" claim
   from the text inserted into `skills/mesh-design-review/SKILL.md` — neither exists there
   (0 occurrences vs 7 in `commands/mesh-review.md`).
7. `new_statuses` must compare per-position transitions, not status sets. Corrected code is in
   the dogfooding findings document, already verified.
8. Assert the exec bit reached the index (`git ls-files -s` → `100755`) for both new files;
   the prompts invoke `"$WATCH"` directly and the first live launch died `Permission denied`.
9. Replace `date -d` with the bash builtin `printf '%(%H:%M:%S)T'` and add a GNU-coreutils
   precondition; `config-loader.sh` has a Darwin preflight precisely for this class.
10. `agents/gemini-executor.md` Output section still promises `log.jsonl`, which supervised
    mode does not write; `codex-executor.md:44` already carries the caveat — mirror it.
11. `agents/ext-claude-executor.md:29` documents `SUPERVISED_MODE=…` with `=` while the new
    templates use `: ` — one file would carry two contradictory syntaxes.
12. `--stall-sec` with an invalid value silently becomes 600 while `--poll-sec` / `--deadline`
    exit 64. Make it symmetric. Concrete breaking input: `--stall-sec --once <dir>` eats
    `--once` as the value and the script blocks forever.
13. Warn on stderr when `stall_sec` falls back to the default.
14. Widen Test 15's timing margin; Test 14 is scheduler-sensitive — wait on a marker file the
    watcher writes after its first iteration instead of a bare `sleep`.
15. Missing tests: mixed baseline (`DONE` + `RUN`→`DONE` must say `CHANGED done`; `DONE` +
    `RUN`→`STALLED` must name `stalled`); the *values* of `quiet` and `last`; the threshold
    boundary (`-gt`, so `quiet == stall_sec` is RUN); `log.jsonl` as a freshness source;
    `CHANGED missing` mid-watch; `--once` never yielding `CHANGED`; a path containing a space.
16. The term `idle_notification` appears nowhere in the repo — define it or use existing
    vocabulary. Also: the rule says `--once <that run dir>` but never says how to derive the
    run dir from a notification.
17. CHANGELOG: "exits on any status change" overclaims (`STALLED → RUN` is deliberately not
    signalled); add an explicit "Configuration: no new keys" line.
18. In Task 4 the fenced block and table sit at column zero inside a numbered list item,
    breaking the list.

## SESSION CONTEXT

**The root-cause analysis is sound and was confirmed live — do not relitigate it.**
`/mesh-design-review` never passes `SUPERVISED_MODE`, so `watchdog.sh` runs only by chance
(38 of 212 archived runs). During this very review, **4 of the 5 ext-claude executors died
mid-stream in the default unsupervised mode**; all four recovered on the first attempt after
self-retrying under the watchdog. The 2026-07-26 incident had the same 4/5 ratio with no
recovery. Component A is not in question.

**Two claims from the original task document turned out to be wrong.** It said the retry that
saved `zai/glm` came from some mechanism — there is none; the default-mode block exits 4 and
the executor agent improvises. And it said the test baseline was "180 passed" — it is 246. The
document warned that it was written by a participant in the incident; that warning was
correct, and the test-count line was taken on faith. Verify numbers before propagating them.

**`stall_detected` has never fired in 284 watchdog logs, and should not have.** A torn stream
kills the CLI, which the `kill -0` check catches. But `ollama/minimax` (Critical 1) argues the
inference is unproven and proposes tabulating `bail.reason` across the archive to settle it.
That check has not been run.

**Reviewers reason plausibly and are sometimes wrong.** Three of them called the `,state`
fallback in `new_statuses` unreachable; it fired live and was reproduced by executing the
plan's own code. `ollama/minimax` self-retracted 5 of its own findings after checking. One
reviewer said nobody writes `.watchdog_rc` while another said 3 exist on disk — both are true
in part (no writer in `skills/`; the files predate). Adjudicate by running things, not by
weighing authority.

**`.watchdog_rc` is dead code** — `verify-delegation.sh:89` reads it, nothing writes it. Real,
pre-existing, and out of scope because that file must not be touched. Recorded, not fixed.

**Sharpest architectural critique, from codex:** Decision 3's justification ("prose gets
re-improvised") cuts against the design itself. The script only *reports*; the orchestrator
still *acts*, and points 3–5 of the new prompt block — drop dead runs, answer notifications
with `--once`, routing — remain prose carrying all the behaviour. The defects compound: skip
point 5 and a repeat `STALLED` enters the new baseline and never resurfaces.

**Confirmed live during the run:** a background Bash task exiting 2 is surfaced by the harness
as "failed with exit code 2". An LLM orchestrator will read a normal terminal verdict as an
error.

**Working prototype is gone.** A corrected `watch-runs.sh` lived in the previous session's
scratchpad (36/36 asserts, correct reason lines on the live run), but scratchpad directories
are session-scoped. The corrected `new_statuses` is preserved in the dogfooding findings
document; the rest is in the plan.

**Process constraints (from `~/.claude/CLAUDE.md`):** design and plan documents must not be
committed to master, and must be `git rm`'d from the branch before opening a PR — they stay
in branch history. The branch was created with `git switch -c` at the user's choice.

**Scope boundaries the user set:** `skills/shared/verify-delegation.sh` must not be touched;
the `SUPERVISED_MODE` default in the `*-exec` skills stays `none` (flipping it would strip
live progress from direct `/claude-mesh:*-exec` calls); and reconciling the point-4 routing
divergence between the two prompt files is explicitly out of scope.

## PLAN QUALITY WARNING

The plan was written for a large task and **is known to contain errors** — iteration 1 found
nine Critical ones. Beyond those, it may contain:
- Further inaccuracies in implementation details
- Oversights about edge cases or dependencies
- Assumptions that don't match the actual codebase
- Missing steps or incomplete instructions

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the four documents listed above
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
