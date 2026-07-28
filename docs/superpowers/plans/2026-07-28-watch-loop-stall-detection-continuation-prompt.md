## TASK

Finish the watch-loop stall detection branch in claude-mesh. **All six implementation tasks are
complete, reviewed and committed.** What remains is the closing phase: the final whole-branch
review, then `superpowers:finishing-a-development-branch`, then the pre-PR document removal.

Branch: `fix/watch-loop-stall-detection`, at `815e689`, 12 commits ahead of the merge base
`3d5c004`. Tracked tree clean.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start the final review or any subagent
- Make any code changes
- Run any commands (except reading documents)
- Assume what to work on next

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md`
- Plan: `docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md` — **trimmed**: every
  completed task body is replaced by its commit list, so it is now 85 lines. The full text stays in
  git history (`git show c9556f0:docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md`).
- **Ledger: `.superpowers/sdd/2026-07-27-watch-loop-stall-detection/progress.md`** — git-ignored,
  and the most important file for what comes next. It carries every human ruling with its
  rationale, ~15 deferred minor findings, and several observations. The final review must be
  pointed at it so it can triage which minors block merge.

Read all three. The per-task briefs and reports (`task-N-brief.md`, `task-N-report.md`) and the
review packages (`review-<base>..<head>.diff`) live in the same workspace directory if you need
provenance for a specific decision.

## PROGRESS

**Completed — all six tasks, each with a spec+quality review and, where needed, a fix round:**

- [x] Task 1: `watch-runs.sh` — roster resolution, classification, one evaluation (`6a26aa2`)
- [x] Task 2: `watch-runs.sh` — the polling loop (`ba43249`, `d151a15`)
- [x] Task 3: `SUPERVISED_MODE: shell` for design-review executors (`6e91eef`)
- [x] Task 4: both orchestrators routed through `watch-runs.sh` (`539b732`, `fe56027`)
- [x] Task 5: `verify-delegation.sh` content gate in design-review (`de4c999`, `d251fb7`)
- [x] Task 6: CHANGELOG, sync-note rewrite, full verification (`032cffd`, `658bb7d`, `92007a0`,
      `815e689`)

**Remaining — none of these has been started:**

- [ ] Final whole-branch review (`3d5c004..815e689`), on the most capable model, pointed at the
      ledger's deferred-minor list. Per `superpowers:subagent-driven-development`: if it returns
      findings, ONE fix dispatch with the complete list, then exactly one scoped re-review, then
      adjudicate residuals. There is no second fix wave.
- [ ] `superpowers:finishing-a-development-branch`
- [ ] The pre-PR document removal — the plan's own "Before opening a PR" step, whose `git rm` list
      was corrected during trimming to name all six tracked documents (the original named four).

**Verification state at the pause:** seven suites, each `0 failed` — watch-runs 61,
check-context-size 11, config-loader 246, extract-result 28, loader-resolution 12, render-template
44, verify-delegation 42. `skills/shared/watch-runs.sh` and its test are `100755` in the index.
`skills/shared/verify-delegation.sh` and `skills/shared/watchdog.sh` untouched across the branch.

## SESSION CONTEXT

**Execution was `/claude-mesh:do-plan 300k` driving `superpowers:subagent-driven-development`** —
a fresh implementer subagent per task on `opus`, a spec+quality reviewer after each, scoped
re-reviews after every fix round. The session paused at its 300k context threshold with Task 6
closed cleanly.

### The plan was wrong in six places, and each was ruled by the user rather than worked around

Every one of these is a deviation from the plan's literal text. They are settled; do not reopen
them, but do not be surprised when the plan file and the code disagree.

1. **Test 25's timing bound (Task 2).** `assert_between "it waited for the change" 1 20` passed in
   the RED run, when the script still returned instantly — `date +%s` truncates, so a tick across a
   second boundary yields 1. Raised to 2, which is deterministic because the toucher fires at t+2.
2. **Test 26's missing `timeout` (Task 2).** It called the now-blocking script through the `run()`
   helper, so a deadline regression would hang the suite forever instead of failing it. Rewritten
   in the shape of Tests 25/27 under `timeout 15`; the shared helper was left alone because 24
   earlier tests depend on it.
3. **The loader canary (Task 4).** The plan assumed the new call site in `commands/mesh-review.md`
   would be counted by `grep -Fx`, but its fence is indented three spaces to stay inside numbered
   list item 2, while the five pre-existing sites sit at column 0 — so 6/6/4 could not pass. The
   canary now strips leading whitespace before the exact match. Rejected alternatives: de-indenting
   the fence (splits the list, adds a fourth difference between the mirrored blocks) and staying at
   5/5/3 (leaves the sixth copy uncovered).
4. **The `Step 6.0` expectation (Task 4).** The plan expected `grep -c 'max_redispatch\|Step 6\.0'`
   = 0 in the design-review file, but the sync note it itself mandates contains that literal. The
   corrected expectation is `max_redispatch` = 0 and `Step 6.0` = 1. The note was NOT reworded —
   that would desync it from its mirror.
5. **`$WATCH` in the liveness paragraph (Task 4).** The plan's text told the orchestrator to run
   `"$WATCH" … --once`, but `WATCH=` is assigned inside point 2's fence — a different Bash-tool
   call — two lines below the block's own warning that shell state does not survive between calls.
   A literal run yields rc 127, which the orchestrator would read as "the watcher is broken". The
   text now says to re-resolve it first. Landed with three related edits: the orphaned term
   "finalized" (whose only definition this branch deleted) replaced by the watcher's `DONE` status
   in `commands/mesh-review.md`, `SNAPSHOT` added to the verdict vocabulary in both files, and the
   canary comment's "five copies" → "six".
6. **`verify-delegation.sh`'s exit contract and the `FLIP` verdict (Task 5).** The script exits
   non-zero for every verdict but `REAL` (`STALLED`=2, `FLIP`=3, `BROKEN`=4) — its normal answer —
   while the sentence two lines above says a non-zero exit means the watcher is broken. And `FLIP`
   after a `DONE` cannot mean "never delegated": the watcher just saw the run directory, so it
   means the two tools disagree about *where* the run lives — a typo in the hand-substituted
   engine/model arguments, or a different data dir. As written, that would have dropped a finished
   report over a typo. Both are now stated in point 3.
7. **The CHANGELOG's recovery claim (Task 6).** "Recovery is reported too — `SILENT → RUN` is a
   transition like any other" is false: the baseline is virtual, `transitions()` skips every `RUN`
   entry and can only print `RUN→X`, and the loop returns only when something stops being `RUN`.
   Replaced with the honest statement. This was stale text from review iteration 1 (C4) that the
   design rewrite fixed and the CHANGELOG draft did not.

### Things a final reviewer should look at, but that are not defects

- **The sync note was rewritten twice.** Its first rewrite claimed points 1, 2 and 4-6 identical
  while ordering that the dead-run routing not be mirrored — and that routing lives inside point 4.
  The current version claims identity of *substance* for six named elements and enumerates four
  axes that must never be mirrored (points 1-2 path resolution, point 3's content gate, point 4's
  routing plus its retry tail, point 6's tail). Every claim in it was audited individually against
  both files and found true. It is now the longest blockquote in either file, deliberately.
- **`242 of 255` in the CHANGELOG drifts.** The live archive now reads 244/265 — ten runs accrued
  since the scan. Same conclusion (~19% vs ~94%), and `skills/mesh-design-review/SKILL.md:425`
  carries the same figures: update both or neither, and do not treat them as an invariant.
- **A pre-existing inconsistency this branch only points at:** `SKILL.md:443` says an executor that
  dies "self-retries" into a new run dir, while `:466` says the watchdog inside the run is the only
  retry layer — and a watchdog restart writes `attempt-*/` in the *same* dir. The sentence is
  consistent only with the improvised executor retries recorded at `:425`. Out of this branch's
  scope.

### Scope boundaries the user set, still in force

`skills/shared/verify-delegation.sh` and `skills/shared/watchdog.sh` are called, never modified.
The `SUPERVISED_MODE` default in the `*-exec` skills stays `none`. The point-4 routing divergence
between the two prompt files is deliberate. Plumbing `stall_sec` into `codex-exec`/`gemini-exec`
is out of scope — the 600 floor covers it.

**Process constraint (`~/.claude/CLAUDE.md`):** design and plan documents must not appear in the PR
diff; `git rm` them from the branch before opening it. They stay reachable in branch history.

## PLAN QUALITY WARNING

The implementation phase is done, so the plan's remaining risk is concentrated in one place: its
"Before opening a PR" step. That list was already wrong once (four documents named, five tracked)
and has been corrected in the trimmed file to six — verify it against `git ls-files docs/superpowers/`
before running it rather than trusting either version.

More generally, this plan contained a provable error in six separate places, every one caught by a
reviewer or an implementer rather than by reading. If anything else in it looks wrong:

1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the design, the trimmed plan, and the ledger
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
