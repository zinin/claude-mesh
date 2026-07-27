# Merged Design Review — Iteration 1

Design: `docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md`
Plan: `docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md`
Dispatched 2026-07-27 13:01:58 — 8 reviewers (`claude:opus`, `claude:fable`, `codex`,
ext-claude on `zai/glm`, `alibaba/qwen`, `deepseek/v4-pro`, `ollama/kimi`, `ollama/minimax`).

> **Run conditions are themselves evidence.** Four of the five ext-claude executors
> (`qwen`, `deepseek`, `kimi`, `glm`) died mid-stream in the default unsupervised mode and
> self-retried under `watchdog.sh`. Only `minimax` completed first try. The 2026-07-26
> incident had the same 4/5 ratio. This is the failure rate Component A exists to remove,
> reproduced live while reviewing the fix for it.

---

## claude:fable

Verified against the repository before critiquing: `grep SUPERVISED` on
`skills/mesh-design-review/SKILL.md` is empty; `agents/codex-executor.md` and
`agents/gemini-executor.md` do not document `SUPERVISED_MODE` while
`agents/ext-claude-executor.md` mentions it only in passing (line 29); `get-runtime`
really returns `.timeouts.stall_sec: 600`; `heartbeat()` builds lines via `jq -nc` with a
fixed key order, so the `"event":"cleanup"` substring is exact; gemini-exec does `touch
"$OUTPUT_FILE"` at launch; the codex/gemini default modes write `log.jsonl` live, so the
freshness set covers unsupervised runs too; assert counts check out (26 at the Task 1
boundary, 36 at Task 2).

### Critical Issues

**C1. Dangling reference to "Step 6.0" in text inserted into `skills/mesh-design-review/SKILL.md`.**
Task 4 Step 2's new point 4 says retry "already exists at two layers — `watchdog.sh` …
and **Step 6.0's `max_redispatch`** covers the wrapper". That text lands in the
design-review file, which has neither: `grep -n "6\.0\|max_redispatch"
skills/mesh-design-review/SKILL.md` returns nothing, and the design itself states
`max_redispatch` is a `/mesh-review` mechanism. Two problems: (a) the orchestrator will
hunt for a step that does not exist in its own prompt — exactly the imprecise prose the
incident grew from; (b) "retry exists at two layers" is **factually false** for
design-review, where the only retry is watchdog ×2, and only if `SUPERVISED_MODE` actually
reached the skill.

**C2. A STALLED that arises between watcher restarts is absorbed into the baseline and never announced.**
The design states "CHANGED cannot fire on the first evaluation, since the baseline is
established there". Trace: a first evaluation of `STALLED RUN RUN` passes no emit
(not ALL_DONE, not SETTLED because RUN exists, not CHANGED because the baseline is being
set) — nothing is printed and the STALLED enters the baseline. Scenario: the watcher exits
`CHANGED done` for run A; the orchestrator spends minutes reading output, pinging, merging,
replying; run B crosses the threshold in that window; the watcher restarts with B..F and
B's death is never announced until some *other* run changes status, or until
SETTLED/DEADLINE. With long-running peers this reproduces the 38 minutes of blindness for
B — the same bug class the feature must close, and a direct violation of the plan's goal
("notice a dead executor within `stall_sec`"). The `--once`-on-idle_notification hedge is
opportunistic and cannot be relied on. Cheap fix: compare the first evaluation against a
virtual "all RUN" baseline, so an already-dead run yields an immediate `CHANGED stalled`;
plus one test.

**C3. Task 3 Step 7 contradicts Task 3 Step 5: `grep -c 'SUPERVISED_MODE: shell'` = 2 is wrong.**
Step 4 adds the literal to two templates (2 lines), but Step 5 inserts a paragraph
containing the same literal — 3 matches total. The mechanical check fails on correctly
completed work, and the implementing agent will "fix" what is not broken. Expect 3, or
anchor the grep (e.g. `^    SUPERVISED_MODE: shell$`).

### Concerns

1. **`DISPATCH_EPOCH` is silently zero on a literal paste.** Bash state does not persist
   between calls; `DEADLINE=$(( DISPATCH_EPOCH + … + 300 ))` assumes the orchestrator
   substitutes the stamped number. Pasted literally, the unset variable makes DEADLINE≈3901
   (1970) → instant `DEADLINE` exit 3, and the orchestrator concludes the budget expired
   right after dispatch. The mesh-review Step 6.0 precedent carries an explicit "substitute
   the ACTUAL…" remark; this snippet has none. Add a placeholder and/or a sanity check
   (a deadline older than `NOW − 86400` is a usage error).
2. **Delivering `SUPERVISED_MODE: shell` through two LLM layers is non-deterministic, and
   nothing verifies supervision actually happened.** On the mesh-review path `shell` is
   hardcoded in the `*-code-review` skills and it is still 139/151. The design-review path
   relies entirely on template → executor agent → skill. The net catches *detection*, but a
   dropped parameter silently degrades the run to zero retries (see C1). A cheap post-check
   exists: the presence of `watchdog.log` shortly after start is proof of supervision.
   Unexplored alternative: a thin wrapper skill hardcoding `shell` for orchestrated runs.
3. **For an unsupervised run, STALLED means "no stream writes for 600s", not "process dead".**
   The watcher has no PID, so no `kill -0`. A long reasoning turn with no tool calls can
   legitimately be silent past 600s. The watchdog would kill *and restart*; the watcher marks
   FAILED permanently, drops the run, and a later `output.txt` is silently lost. The design
   argues the "never declare a live run dead" asymmetry only for the supervised branch; the
   unsupervised trade-off is unstated. Minimum: tell the orchestrator to pick up a late
   `output.txt` from a run it declared dead.
4. **DONE ≠ success, and DONE can precede the end of a run.** (a) `bail()` creates `final`
   even when every attempt failed → DONE, and the unchanged point 3 then pings the executor
   to "extract findings" from an empty output. (b) Unsupervised gemini appends `output.txt`
   incrementally per assistant message, and ext-claude's progress-monitor *rewrites* it on
   every segment result event — a non-empty `output.txt` mid-run yields a premature DONE.
   Inherited from the old predicate, but the table is being rewritten, so state the limit.
5. **An invalid `--stall-sec` is swallowed silently.** Garbage in `--poll-sec` / `--deadline`
   exits 64; garbage in `--stall-sec` silently falls back to 600. Concrete breaking input:
   `watch-runs.sh --stall-sec --once <dir>` — `--once` is eaten as the flag's value and the
   script **blocks forever** instead of erroring.
6. **`CHANGED state` is an undocumented reason.** STALLED→RUN or MISSING→RUN hits the
   `new_statuses()` fallback, which appears in neither the design's table nor the Task 4
   prompt text — though the plan claims "Tasks 3–4 rely on exactly these reason strings".
7. **The mid-watch hand-off into Step 6.0 (mesh-review) is under-specified.** "STALLED — send
   it to Step 6.0" reads as entering a batch step while other runs are still going: 6.0.a
   re-stamps `DISPATCH_EPOCH`, the re-dispatched run is not added to the watch list, and
   6.0.b's "Wait for completion" is not said to go through `watch-runs.sh`.

### Suggestions

1. Close C2 with one condition — compare the first evaluation against a virtual "all RUN"
   baseline — plus a regression test ("a run already STALLED when the watcher starts, with
   live peers → immediate `CHANGED stalled`").
2. **Exit codes.** ALL_DONE/SETTLED = 2 reaches the orchestrator as "task failed with exit
   code 2", which an LLM reads as an error. Either use 0 for all normal verdicts (the reason
   line already carries the meaning), or say explicitly in both prompts that 2/3 are not
   errors.
3. `--once` on a single dir returns `ALL_DONE` even while five peers are running — "ALL"
   invites a false "everything is finished". Say in the prompt that the reason covers only
   the list passed.
4. Discovery (point 1) is untouched and the dir list is snapshotted when the watcher starts,
   so an executor whose dir appears *after* that (slow agent boot) is never added. Mirror the
   drop rule: "…and add newly discovered run dirs".
5. No loop-mode test for `CHANGED missing` (a dir deleted mid-watch) — the one uncovered
   transition.
6. Tech Stack says "jq (optional)", but the prompt snippet needs jq for `global_sec`.

### Questions

1. In design-review, a STALLED unsupervised run (parameter lost en route) gets **zero retries
   at every level**. Acceptable, or should this file allow a single re-dispatch? The design's
   argument against orchestrator retry — collision with Step 6.0 — does not apply here,
   because design-review has no 6.0 (see C1).
2. What does the orchestrator do if the *watcher itself* dies (exit 64 after a plugin
   upgrade, bash<4, script not found)? There is a net for a dead watchdog but none for a dead
   watch-runs, and watcher silence becomes the new unannounced death.
3. Keep DONE runs in the next invocation's list or drop them? The code tolerates both; the
   prompt only speaks about dead ones.

**Verdict:** the diagnosis and the chosen architecture are correct and well verified against
the code; the plan is executable. C1, C2 and C3 must be fixed before implementation; the rest
are targeted text and validation edits.

---

## ollama/minimax

Read both documents plus `watchdog.sh`, `verify-delegation.sh`, `config-loader.sh`, both
`*-exec` skills, both orchestrator prompts and `config.example.yaml`. **Self-retracted 5 of
its own findings after checking the code** (Critical 4, 6, 7 and C3, C9, Q2, Q4) — dropped
here as noise.

### Critical Issues

**1. The "`stall_detected` never fired in 282 logs → `kill -0` catches torn streams" claim is
not quantitatively established, and Component B rests on it.** A torn provider stream does
not reliably kill the CLI — the provider closes the TLS socket and `claude -p` may hang on
`read()` or exit with a partial `raw.jsonl` lacking `type:result`. Falsifiable check:
tabulate `bail.reason` across the 282 `watchdog.log` files. If `all_attempts_failed` is ~0,
`kill -0` is only catching real SIGTERM/SIGKILL, which would make the mtime threshold the
*primary* net rather than the rarer one — inverting the design's framing.

**2. `CHANGED` is unreachable under `--once`, and the spec does not say so.** `SNAPSHOT`
emits before the change branch is reached. Correct behaviour, but undocumented and untested.

**3. No validation that `DIRS` entries are plausible run dirs.** Any string is accepted; an
orchestrator typo silently classifies everything `MISSING` and burns the full deadline with
no diagnosable message. `verify-delegation.sh` by contrast fails loudly on a missing base.

**4. `test-config-loader.sh` at 180/0 is author-asserted, not machine-anchored in the PR.**
Suggests Task 5 Step 2 add a `git diff` against master for that test file — if it changed,
the baseline number is no longer the right anchor.

### Concerns

- **C8 (called the real UX regression):** when `stall_sec` resolution falls back to 600,
  nothing is printed. A user with `stall_sec: 30` and a broken `config-loader` waits 600s
  silently.
- **C7:** the boundary between `watch-runs.sh` (runtime classifier DONE/RUN/STALLED/MISSING)
  and `verify-delegation.sh` (post-hoc classifier REAL/FLIP/STALLED/BROKEN) is nowhere
  stated. Both read `runs/<engine>/…`; coexistence is correct but opaque.
- **C4:** the CHANGELOG's "exits on **any** status change" is misleading — `STALLED → RUN`
  recovery is deliberately not signalled.
- **C1:** `[ -n "$out" ] || out=",state"` in `new_statuses` is unreachable — a non-empty
  vector diff guarantees non-empty `$out`. *(Contradicted by observation — see the
  dogfooding findings, D2.)*
- **C2 / C10:** watchdog cold-start — for the first 60s of an attempt there is no `alive`
  heartbeat, so freshness depends on the implicit invariant that `attempt_start` does
  `: > "$stream"`. Verified to hold, but wants a test pinning it, since `watch-runs.sh` now
  silently depends on watchdog internals.
- **C6:** "DO NOT hand-roll a poller" blocks the observed regression, but nothing stops a
  future agent from bolting a `SendMessage` hook into the script itself.

### Suggestions

S1 warn on `stall_sec` fallback. S2 optional `--runs-root` for validation and a firmer basis
for `shorten()`. S3 state "Configuration: no new keys" at the top of the CHANGELOG block.
S4 the loader-discovery `find` block is now copied a third time — record as tech debt for a
future `shared/resolve-loader.sh`. S5 add a test asserting `--once` never yields `CHANGED`.
S6 tighten `grep -q '"event":"cleanup"'` to an anchored pattern. S7 assert the sync note
appears exactly twice.

### Questions

- **Q5 (most substantive):** `cleanup` is written on *every* watchdog exit including `bail`,
  so `DONE` means "finalized", not "succeeded". The design does not say the orchestrator must
  then run `verify-delegation.sh` to tell success from bail.
- **Q6:** `--stall-sec` exists in the interface but neither prompt uses it. Document as a
  per-engine escape hatch?
- **Q1:** three places now touch `stall_sec` — DRY violation or correct specialization?
- **Q3:** should the `mesh-review.md` block mention that omitting `--stall-sec` reads config?

**Verdict:** no regressions found in the `watch-runs.sh` code itself; ready to implement after
settling Critical #1 with the `bail.reason` distribution, applying S1/S5/S6/S8, an explicit
out-of-scope note on the `verify-delegation.sh` boundary, and two missing tests.

---

## alibaba/qwen

First attempt died: the provider tore the stream at `raw.jsonl` line 2529, exactly as the
model finished investigating and began writing its answer. Exit 4, no `result` event. The
executor declined to relay the fragment as a review. A supervised retry is in flight.

Notably, the torn attempt left a **47429-byte non-empty `output.txt`** containing only
narration ("Проведу ревью документов… Начну с чтения") with no findings sections — which
`watch-runs.sh` classified `DONE`. See dogfooding finding D4.

From the last complete thinking block before the cut, the model had drafted at least one
finding: that `new_statuses` falls through to its `,state` fallback and emits an unspecified
`CHANGED state` whenever a run reaches `DONE` before the watch baseline is taken — plausible
in a 6-way fan-out. *(Independently confirmed live — see D2.)*

The supervised retry completed rc=0 on attempt 1 and delivered the full review.

**Reviewer verdict: no critical issues; the plan is executable.** Every claim the design makes
about the codebase checked out — `HARD_ZERO_TIMEOUT` / `MAX_RETRIES` / the JSONL events /
`kill -0` are all as described; `SUPERVISED_MODE` really is absent from
`skills/mesh-design-review/SKILL.md`; the three finalization predicates are identical in
`SKILL.md:428` and `mesh-review.md:247`; `cleanup` is written via `trap cleanup EXIT` with a
fixed key order, so the substring match is exact; and **`WATCH_TIMEOUT` does not exist
anywhere in the code** — it was an orchestrator improvisation, which justifies banning it in
the prompts.

Concerns raised: the `,state` fallback; the unguarded `get-runtime` output in `DEADLINE`; GNU
coreutils lock-in; no mechanical way to enforce the `WATCH_TIMEOUT` ban; `SETTLED` semantics
on a first `--once` when everything is already dead. Suggestions: `set -o pipefail` for
consistency with `watchdog.sh`; comments in Tests 3 and 9; a uniqueness check on run dirs.

**The executor then verified two of its own reviewer's judgements and found both understated:**

1. **The `,state` fallback is reachable, not cosmetic.** `VECTOR` is positional
   (`VECTOR="$VECTOR $STATUS"` per dir) while `new_statuses` compares **sets**. Running the
   plan's actual code:
   ```
   baseline=[ DONE RUN RUN] current=[ DONE DONE RUN]
   VECTOR != BASELINE ? YES
   new_statuses -> CHANGED state
   ```
   Same with `STALLED`. Trigger: any run reaches `DONE`/`STALLED` before the first evaluation,
   then a second enters the same status — likely in a 6-way fan-out. The plan claims "Tasks
   3–4 rely on exactly these reason strings", and `CHANGED state` is not in that contract.
2. **A `get-runtime` failure yields a silent 5-minute deadline, not a syntax error.** The
   reviewer had called it a loud failure. Verified:
   ```
   DEADLINE=$(( DISPATCH_EPOCH + $(true) + 300 ))  →  1000300, no syntax error
   printf '' | jq -r '.timeouts.global_sec // 3600'  →  rc=0, empty output
   ```
   Bash parses the dangling `+` as unary plus, and jq exits 0 with empty stdout, so there is no
   failure signal at all. Both copies in the plan (lines 730 and 785) are affected. Judged a
   **blocking** defect rather than a 30-second edit.

Side observation: run 1's failure is a live instance of the very signature the design targets
— default mode, torn stream, no `result` event, exit 4, no deterministic retry — and the
supervised retry passed first try, empirically supporting Decision 1.

---

## claude:opus

Checked the documents against the code *and* against real on-disk data (284 archived runs).

### Critical Issues

**C1. Task 4 breaks `test-loader-resolution.sh`, while Task 5 claims every suite is green.**
`skills/shared/tests/test-loader-resolution.sh:39-56` is a deliberate canary asserting
`5` primary lines, `5` fallback lines across `commands/`, and `3` in `mesh-review.md`
(currently `12 passed, 0 failed`). Task 4 Step 3 adds a **fourth** verbatim resolver copy to
`commands/mesh-review.md` → 6 / 6 / 4 → **two asserts fail**. The test's own comment says to
bump the numbers once the new site is checked. Worse: the new site copies **2 of the
canonical 3 lines**, dropping `[ -f "$LOADER" ] || { echo "config-loader.sh not found…";
exit 1; }` (`commands/mesh-review.md:43`) — precisely the drift the canary exists to catch.

**C2. The Task 4 snippet breaks silently: `DISPATCH_EPOCH` and `$WATCH` do not survive a Bash call.**
Shell state does not persist between Bash-tool calls — the repo knows this, which is why
`commands/mesh-review.md` redefines `LOADER` three times and why `test-loader-resolution.sh`
exists. Demonstrated:

```
$ bash -c 'DEADLINE=$(( DISPATCH_EPOCH + 3600 + 300 )); echo $DEADLINE'
3900
$ watch-runs.sh --stall-sec 600 --deadline 3900 <dir>
DEADLINE   rc=3
```

So the **first** watcher invocation reports the budget expired, every time. There is no
`set -u` in the snippet and `is_pos_int 3900` passes — the failure is completely silent and
worse than the original bug. Same for `"$WATCH" --once <run dir>` in point 4 and `"$WATCH"`
in point 5: those run in *later* Bash calls where the variable is undefined (`rc=127`). Both
prompt files already warn: "An undefined name in a shell script raises an error under
`set -u`; in a prompt it raises nothing at all — the reader improvises" (`SKILL.md:308`,
`mesh-review.md:107`). Options: (a) make the snippet self-contained and require a literal
epoch substituted into every call; (b) better — `--since EPOCH` with the deadline computed
inside the script, or a `--state-file` written once at dispatch. And a loud error on an
already-past deadline at the *first* evaluation (`exit 64`, "deadline already passed — did
DISPATCH_EPOCH expand to nothing?"). Test 11 (`--deadline 1000000000`) currently **enshrines**
the silent behaviour as correct.

**C3. `CHANGED state` is an undocumented reason that fires in the ordinary case.**
Verified on three dirs (one already DONE in the baseline, a second finishing mid-watch):
`CHANGED state`. The design documents only `CHANGED <statuses>` = "present now but absent
from the baseline" and never mentions `state`. With ≥3 executors, **every completion after
the first** produces it, because `DONE` is already in the baseline and the prompt only drops
*dead* runs, not DONE ones. The undocumented string is the most frequent event of a normal
run, and no test covers it.

**C4. `stall_sec` now has two consumers with different blast radius, and they desynchronise.**
Decision 4 ("the key already means exactly this") is only half true:
`skills/ext-claude-exec/SKILL.md:261` uses `HARD_ZERO_TIMEOUT="$STALL"` from config, but
`skills/codex-exec/SKILL.md:332` and `skills/gemini-exec/SKILL.md:313` **hardcode**
`HARD_ZERO_TIMEOUT=600` and ignore the config. With `stall_sec: 300`, `watch-runs.sh`
declares a codex run STALLED at 300s while its watchdog will not restart before 600s;
design-review marks it FAILED and drops it, the watchdog then finishes successfully into a
directory nobody is watching, and the result is discarded. The consequences are asymmetric:
for the watchdog the threshold is **recoverable** (kill + 2 retries), for `watch-runs.sh` it
is **terminal**. Measured headroom on this machine: across 46 successful archived runs the
largest healthy stream gap is **383s**, and three runs exceeded 300s — so 600 is only ~1.6×
the worst healthy gap, and 300 would produce ~6.5% false positives. Neither the design nor
the `config.example.yaml` comment warns about this. Minimum fix: a floor in the script
(`max(stall_sec, 600)`), or plumb the config into codex/gemini-exec. A comment is not enough.

### Concerns

**K1. Component B's expected firing rate is near zero, and the design oversells it.**
Recounted independently: 284 `watchdog.log` files, `stall_detected` in **0**, `cleanup` in
**282**. The two without `cleanup` are this review's own runs, started 13:09 and still live.
So among all *completed* supervised runs, `cleanup` is present in **100%**. The "watchdog
died" case that Decision 1 uses to justify rejecting watchdog-only has never been observed.
Furthermore, after Task 3 every orchestrated run is supervised and `watchdog.log` gets
`alive` every 60s **regardless of stream activity** — so `quiet` can barely exceed
`stall_sec` while the watchdog lives. STALLED remains reachable only via the never-observed
dead watchdog, or via an executor not honouring `SUPERVISED_MODE`. And: **Task 3 alone would
have closed the incident** — `cleanup` increments the finished counter, which is exactly what
the improvised watcher woke on. This is not a reason to drop Component B (determinism and
non-compliance coverage are real), but the design should call it what it is: insurance
against contract non-compliance, not a liveness sensor. The prompt's tone depends on that.

**K2. `DONE` conflates "produced a review" with "gave up", and the most informative on-disk
signal is ignored.** `watchdog.sh` `bail()` (316-344) creates a `final` symlink to a partial
attempt, writes `watchdog.exit` with `{reason: all_attempts_failed|global_timeout, attempts,
elapsed_sec}`, and the EXIT trap writes `cleanup`. Root `output.txt` is not created
(ext-claude rc=2 skips extraction). So a **definite failure is classified `DONE`**, and
`ALL_DONE` can mean "all four gave up". Decision 2 demands "mark FAILED, report precisely",
but the script cannot emit FAILED at all. A `FAILED` status keyed on `watchdog.exit` (2 such
files exist on disk) is ~5 lines and gives the prompt "all_attempts_failed after 3 attempts
in 2841s" instead of a generic phrase. `.watchdog_rc` (3 on disk) is already used by
`verify-delegation.sh:89-91` as the codex/gemini success signal.

**K3. `MISSING` has no grace period, contradicting the design's own principle.** The design
says "err toward not declaring a live run dead", yet an absent directory is an immediate
death sentence on the first evaluation (Test 9). A path captured a moment before the
executor's `mkdir`, a misparsed interim status, or a missed fallback discovery declares a
live executor dead in milliseconds — and design-review has no retry layer to compensate.
Proposal: `MISSING` behaves as `RUN` until `stall_sec` elapses, or a shorter
`--missing-grace`.

**K4. `ALL_DONE` / `SETTLED` return in ~15ms and nothing tells the orchestrator to stop.**
Measured: 5 invocations in 78ms. Rule 5 says "stop watching once that list is empty", but at
`ALL_DONE` the list is **not** empty (DONE dirs are never dropped), while rule 6 says "repeat
until every dispatched executor has reported". An orchestrator with a DONE-but-silent
executor satisfies both and spins in a no-delay respawn loop. The old hand-rolled poller at
least slept. Both prompts must say `ALL_DONE` / `SETTLED` are terminal.

**K5. macOS: a silent no-op.** README supports macOS explicitly and
`config-loader.sh:77-93` carries a deliberate Darwin preflight because "claude-mesh uses
GNU-only utilities: `timeout`, `stdbuf`, `setsid`, `stat -c`, `find`". `watch-runs.sh` uses
`stat -c %Y` and `date -d` with `2>/dev/null`, and the line
`[ "$newest" != "0" ] || newest="$(stat -c %Y "$d" 2>/dev/null || printf '%s' "$NOW")"`
turns every failed probe into `QUIET=0` on BSD. Result: **every run is forever `RUN`** and
the watcher blocks until the deadline — the original bug, now with a "fix" in the repo. Needs
the same Darwin guard (or `stat -f %m` / `date -r`).

**K6. `STALLED` now means two different things inside `/mesh-review`.**
`verify-delegation.sh:26-31` already emits `STALLED` (exit 2) = "killed mid-flight or
delivered nothing usable", which Step 6.0 feeds into `max_redispatch`. `watch-runs.sh`
introduces `STALLED` = "silent longer than the threshold". One word, two semantics, one
command — and Task 4 routes one into a step that consumes the other. Not a routing question
(out of scope) but a naming one: `SILENT` for the watcher, or at minimum a disambiguating
sentence in both prompts.

**K7. `--stall-sec` validation is silently lenient, unlike its neighbours.** `--stall-sec 0`,
`-5`, `abc` all collapse to 600 without a word, while `--poll-sec 0` and `--deadline abc`
exit 64.

### Suggestions

- **S1.** Move watcher state out of prose into a file (`--state-file`, or
  `.watch-<epoch>.json` beside the run dirs). This removes C2 and makes three of the four new
  prose rules unnecessary. The design's own thesis — "prose gets re-improvised" — applies
  here: state kept in a prompt is also prose.
- **S2.** Add `--since EPOCH` and compute the deadline inside the script from `global_sec` +
  margin; the whole "absolute vs relative" paragraph then disappears.
- **S3.** The reason line should name the run and the transition —
  `CHANGED ext-claude/ollama/kimi RUN→STALLED` — because the orchestrator's action is
  per-run. A set of statuses forces it to re-diff the rows itself, which is exactly the
  re-derivation the design wants to eliminate.
- **S4.** No assert checks the *value* of `quiet` or `last`, though the design promises
  "STALLED with correct `quiet` and `last`". Also uncovered: `CHANGED state`; the threshold
  boundary (`quiet == stall_sec` → RUN, `+1` → STALLED, since the comparison is `-gt`);
  `MISSING` appearing mid-watch; a path containing a space.
- **S5.** Task 5 Step 2 omits `skills/shared/tests/test-check-context-size.sh` (today
  `11 passed, 0 failed`) — add it or stop calling it "the whole test suite".
- **S6.** Task 3 edits `agents/gemini-executor.md`'s parameter list but not its Output
  section, which still promises `log.jsonl` — a file supervised mode does not produce.
  `codex-executor.md:44` already carries the caveat; mirror it.
- **S7.** The term `idle_notification` does not exist anywhere in the repo (0 occurrences
  outside the design/plan), yet the new rule 4 uses it as established vocabulary.
- **S8.** Task 3 Step 7's `grep -c 'SUPERVISED_MODE: shell'` expects `2`, but Step 5's
  paragraph contains the same literal → actually `3`. The step fails its own check.
- **S9.** In Task 4 the ```bash block and the table sit at column zero inside numbered list
  item `2.`, breaking the list for human readers.

### Questions

1. Given `cleanup` in 282/282 completed supervised runs and `stall_detected` in 0/284, which
   concrete failure does Component B catch that Component A does not, other than an executor
   not honouring `SUPERVISED_MODE:`? If the honest answer is "only non-compliance", say so in
   the design — it changes how the prompt text should read.
2. Is a `stall_sec` below the watchdog's own restart threshold permissible? If not, where is
   it clamped — in `watch-runs.sh`, in `config-loader.sh` validation, or only in a comment?
3. After Task 3, do design-review executors still send an interim status naming the run dir?
   The whole of watch-loop point 1 rests on it, and supervised mode replaces
   `progress-monitor.sh` output with the watchdog's stderr heartbeats. Was this verified on a
   real supervised design-review dispatch, or inferred from mesh-review?
4. Task 5 Step 3 expects `git diff --name-only master...HEAD` to list "the two
   `docs/superpowers/` files" — does that expectation account for the `git rm` in "Before
   opening a PR"?
5. `output.txt` non-empty counts as finalization via `-s`, whereas `verify-delegation.sh:144`
   requires non-whitespace content for ext-claude and otherwise returns STALLED. Should both
   use one predicate so the two checks cannot disagree about the same directory?

### What checked out

- Ran the plan's code verbatim: **36 passed, 0 failed**, exactly as claimed (26 at the Task 1
  boundary, asserts recounted by hand).
- Ran `watch-runs.sh --once` against the **real 2026-07-26 incident directories**.
  Classification exact: 3× DONE for the survivors, 4× STALLED for the dead, `last=14:40:43`
  for kimi — letter for letter as in the design's example. The root-cause diagnosis is
  correct.
- Archive statistics reproduce independently (221 design-review runs / 40 with watchdog vs the
  claimed 212/38 — the gap is runs added in the last day).
- `log.jsonl` really is required in the freshness set: a codex default-mode run has no
  `raw.jsonl` at all.
- `config.example.yaml:260`, the `CHANGELOG.md` structure, `get-runtime`'s `.timeouts.stall_sec`
  and the Task 3/4 line numbers all match what the plan expects.

## codex

`gpt-5.6-sol`, reasoning `max`, exit 0. Confirmed the session's premise independently:
`mesh-design-review` really does not pass `SUPERVISED_MODE`; 38 historical runs carry a
watchdog; 212 reproduces once the improvised second GLM run is excluded (otherwise 213);
`stall_detected` appears in none of the 282 logs.

### Critical Issues

**1. The first evaluation absorbs a stall that has already happened.** The loop
unconditionally writes the first vector into `BASELINE` and prints nothing. An initial
`STALLED + RUN` is not `SETTLED`, not `ALL_DONE`, and `CHANGED` cannot fire on the first
iteration by definition — so the dead run stays invisible until some other change or the
deadline. **This reproduces the original blindness on every watcher restart** — and a restart
happens after every `CHANGED`, i.e. exactly the incident scenario. A ready `DONE + RUN` is
lost the same way. *(Same defect as claude:fable's C2, found independently.)*

**2. `runtime.timeouts.stall_sec` is not a shared threshold.** Verified:
`skills/codex-exec/SKILL.md:332` and `skills/gemini-exec/SKILL.md:313` contain the literal
`HARD_ZERO_TIMEOUT=600`; only `skills/ext-claude-exec/SKILL.md:261` uses
`HARD_ZERO_TIMEOUT="$STALL"`. The design's claim ("fed by `runtime.timeouts.stall_sec`") holds
for **1 engine of 3**. With `stall_sec: 120`, the codex/gemini watchdog keeps writing `alive`
every 60s, the watcher sees a fresh `watchdog.log` and holds `RUN` until the hard 600s. With
`stall_sec < 60` the race inverts into false `STALLED` between heartbeats.
*(Independently verified by the orchestrator — confirmed.)*

**3. The plan's resolver contradicts the skill's own rule.**
`skills/mesh-design-review/SKILL.md` ("Locating plugin files", ~line 13) explicitly forbids
`${CLAUDE_PLUGIN_ROOT}` inside Bash blocks and requires `SKILL_BASE`. Task 4 Step 1 inserts
the command-file idiom using `${CLAUDE_PLUGIN_ROOT}` plus
`find ~/.claude/plugins … | sort -V | tail -1`. The fallback would select the installed 0.5.0
cache, where `watch-runs.sh` does not exist. Needs `SKILL_BASE/../shared/watch-runs.sh` and an
explicit `[ -x "$WATCH" ]` check.

**4. `DEADLINE` is built from a variable that does not survive dispatch.** Confirmed
experimentally: `unset DISPATCH_EPOCH; echo $((DISPATCH_EPOCH+3600+300))` → `3900`, no error.
Literal execution yields an immediate `DEADLINE`/rc=3 on the very first evaluation — **a
regression worse than the current bug, and silent**.

**5. Task 5 is guaranteed to break the canary test.** `test-loader-resolution.sh` hard-asserts
`5` primary, `5` fallback across `commands/` and `3` in `mesh-review.md`. Task 4 Step 3 adds a
4th resolver → 6/6/4. The test's own comment says a new call site *should* break it and the
numbers must be raised; the plan does neither and promises "every suite ends N passed, 0
failed". The file is not in the modified list.

**6. A second retry layer is claimed for design-review that does not exist.** Verified:
`max_redispatch` / `Step 6.0` occurs 0 times in `skills/mesh-design-review/SKILL.md` and 7
times in `commands/mesh-review.md`. This is not the out-of-scope point-4 divergence — it is a
factually false statement being written into a prompt. Decision 2's "retry already exists at
two layers" is wrong for design-review: there is exactly one.

### Concerns

- `STALLED` means "no writes past the threshold", not proven death. The run is dropped from
  the watch, but the wrapper is not cancelled and a live unsupervised CLI is not killed — it
  may survive and deliver into a loop that has already closed.
- `new_statuses` compares status **sets**, not per-directory transitions: `DONE RUN RUN` →
  `DONE DONE RUN` gives different vectors but identical sets → undocumented `CHANGED state`.
  This is the ordinary case of three reviewers finishing in sequence.
- `MISSING` counts as death immediately — a single not-yet-created run dir yields `SETTLED` on
  the first evaluation. Needs a grace period or two consecutive polls.
- Exit codes 2/3 are nowhere explained in the prompts as expected; to the Bash tool they look
  like failure and invite improvisation again.
- `--stall-sec abc` silently becomes 600 while `--poll-sec` / `--deadline` give usage error 64.

### Suggestions

- An integration test against the real `watchdog.sh` with a cheap fake command (heartbeat
  between attempts, kill, custom `stall_sec`, terminal cleanup) — the current fixtures only
  test mtime arithmetic.
- Machine-readable output (JSONL: `path`, `status`, `quiet_sec`, `last_epoch`,
  `terminal_exit`) instead of parsing aligned text; this also removes `CHANGED state`.
- A "one active watcher per generation" rule: after a `--once` on an idle notification, the
  old background watcher must be cancelled.
- A smoke acceptance: one `/mesh-design-review` per executor must produce `watchdog.log` and
  `attempt-1/` — verifying forwarding, not the presence of a Markdown line.

### Questions

- Does a background Bash exiting 2/3 reliably wake the orchestrator and deliver stdout as a
  normal result rather than a failed task?
- Is `STALLED` terminal while the process is alive, and what mechanism stops the
  process/wrapper?
- Is `stall_sec < 60` permissible? The fixed 60-second heartbeat is incompatible with such a
  contract.

### The executor's own additional checks

1. **Task 3 Step 7 expects the wrong number** — `grep -c` gives **3**, not 2. *(Verified.)*
2. **`bail()` also creates `final` and `cleanup`** (`watchdog.sh:323`, `:130`). A run that
   exhausts every retry and produces no output is therefore classified **`DONE`**, not
   `STALLED`. Before Task 3 this path did not exist in design-review; afterwards it will. The
   orchestrator pings "run finished, read output.txt" and the executor finds nothing — exactly
   the reporting imprecision the design claims to remove.
3. **`agents/gemini-executor.md:44`** lists artifacts as `prompt.md, log.jsonl, output.txt,
   report.md, stderr.txt` with no supervised caveat, while `codex-executor.md:44` has one.
   Task 3 enables supervised mode for gemini but does not fix the artifact list.
4. **Parameter-syntax divergence in ext-claude.** `agents/ext-claude-executor.md:29` documents
   `TASK_NAME=…`, `SUPERVISED_MODE=…` (with `=`), while the template and Task 3 Steps 3/4 use
   `SUPERVISED_MODE: shell` (with `:`). After the edit one file carries two contradictory
   descriptions — risking the line leaking into `PROMPT`, the very problem documenting the
   parameter is meant to prevent.
5. **Task 5 Step 2 does not run the whole suite** — `test-check-context-size.sh` is missing.
6. **The check order puts `DEADLINE` above `ALL_DONE`.** If every run finished but the deadline
   has just passed, the watcher reports `DEADLINE`/rc=3 instead of `ALL_DONE`, and the
   orchestrator risks discarding ready results at the boundary.
7. **Architectural.** Decision 3 justifies moving logic into a script because "prose gets
   re-improvised". But points 3–5 of the new block — drop dead runs from the list, answer
   `idle_notification` with `--once`, routing — remain prose, and they are what carries the
   behaviour. The script only reports; the orchestrator still acts. If point 5 is not
   followed, a repeat `STALLED` enters the new baseline and never resurfaces again (see
   Critical 1) — the two defects compound.

## deepseek/v4-pro

First attempt died in default mode with exit 4 (1547 thinking-token events, 135 chars of
assistant text, no `result` event, nothing salvageable). The executor re-dispatched through
the skill's `SUPERVISED_MODE=shell` path rather than improvising an ad-hoc re-run;
`watchdog.sh` succeeded on attempt 1.

### Critical Issues

None. The design is judged sound and data-driven (212 archived runs, 282 watchdog logs)
rather than speculative.

### Concerns

**1. The `DEADLINE` arithmetic in the orchestrator snippet degrades silently.**

```bash
DEADLINE=$(( DISPATCH_EPOCH + $("$LOADER" get-runtime | jq -r '.timeouts.global_sec // 3600') + 300 ))
```

If `get-runtime` fails (e.g. the `find` fallback does not locate config-loader.sh), jq gets
empty stdin and exits silently. The expression becomes `$(( DISPATCH_EPOCH + + 300 ))` —
the unary plus parses fine — so the deadline is `DISPATCH_EPOCH + 300` instead of
`+ 3600 + 300`. The orchestrator hits `DEADLINE` after 5 minutes instead of 65. Note that
jq's `// 3600` only covers a null key, not absent input. `watch-runs.sh` handles its own
fallback explicitly; the snippet does not. Add `[ -n "$DEADLINE" ]` or an explicit fallback.

**2. `grep -q '"event":"cleanup"'` re-runs every tick for already-DONE dirs.** DONE is
terminal; re-grepping is wasted work on dead directories. Cache it.

**3. Test 14 is scheduler-sensitive.** With `--poll-sec 1`, `sleep 3` racing three poll
cycles is not guaranteed: on a slow machine the `touch -d '10 minutes ago'` can land before
the baseline is established, yielding `SETTLED` instead of `CHANGED stalled`. Replace the
sleep with a wait on a marker file the watcher writes after its first iteration.

**4. No test exercises `log.jsonl` as a freshness source.** `newest_mtime` includes it, but
no fixture creates it. Low risk, real coverage gap.

**5. `SETTLED` invariant with no deadline** — the watcher spins forever by design. The
prompts always set a deadline, so this is fine in practice.

### Suggestions

1. `inotifywait` as an optional accelerator would remove the up-to-30s detection lag. Not
   for this PR; leave a TODO.
2. `[ -n "$out" ] || out=",state"` is an unreachable fallback — delete it or comment it as
   defensive. *(Contradicted by observation — see D2.)*
3. **`DISPATCH_EPOCH` capture consistency** — verify the prompt explicitly requires stamping
   it at dispatch; if an LLM misses it, the snippet breaks.
4. `agents/ext-claude-executor.md` line 29 mentions `SUPERVISED_MODE` but has no Optional
   Parameters section — the plan is right to add one.
5. Message prefixes are inconsistent across `watch-runs:` / `watchdog.sh:` /
   `verify-delegation:`.
6. Check an already-expired deadline before the first `evaluate`, not only inside the loop.

### Questions

1. **Why is the margin 300?** Empirical or arbitrary? A team-mode dispatch of 10+ reviewers
   could exceed it.
2. **What happens to `RUN` dirs at `DEADLINE` (exit 3)?** The plan specifies STALLED and
   MISSING only. RUN dirs are neither done nor dead — just late — and Task 4 does not say how
   to classify them.
3. **`--once` from an `idle_notification` answering `SNAPSHOT`?** The prompt says "act on the
   row", but `SNAPSHOT` means "still working, do nothing". Clarify that only `STALLED` /
   `MISSING` rows demand action.
4. Why not `--deadline-sec` plus an absolute deadline persisted in a state file across
   restarts — was that considered and rejected?

**Verdict:** the design is strong; the main risk is incompleteness of the orchestrator prompts
in handling *all* `watch-runs.sh` outcomes — especially `DEADLINE` with RUN dirs and
`SNAPSHOT` from `--once`. Not a design defect, a specification gap in Task 4.

## ollama/kimi

First attempt (default mode) died with a torn stream at ~2 min — 1003 stream lines,
truncated mid-JSON, no `result` event, zero text emitted (the model was on its 11th `Read`).
The supervised retry logged `attempt_success` on attempt 1.

### Critical Issues

1. **Double classification of a dead run in `/mesh-review`.** The watch loop marks
   `STALLED`/`MISSING` failed and drops it, but the run dir stays on disk. Step 6.0 then runs
   `verify-delegation.sh` on that same dir with the same `DISPATCH_EPOCH`, sees a
   non-finalized directory, returns `STALLED` → `max_redispatch` re-dispatches the wrapper.
   The run is classified dead twice: the watch loop reports the death, Step 6.0 restarts it.
   Needs either an "already handled by the watch loop" marker or an explicit statement that
   double classification is intended.
2. **Nobody creates `.watchdog_rc`.** `verify-delegation.sh:89` checks `$RD/.watchdog_rc` for
   codex/gemini, but neither `watchdog.sh` nor `codex-exec` nor `gemini-exec` writes it — the
   rc check is dead code. *(Verified: no writer anywhere in `skills/`; only
   `test-verify-delegation.sh` fabricates it in fixtures. Pre-existing, out of scope for
   changes, but worth recording.)*
3. **Wrong expected count in Task 3 Step 7** — `grep -c` returns 3, not 2, because Step 5's
   explanatory paragraph contains the same literal. *(Verified: 3.)*
4. **Fragile `cleanup` detection.** `grep -q '"event":"cleanup"'` binds to one generator's key
   order; adding a field or a space breaks DONE detection silently.
5. **`date -d` is not covered by `require_gnu_coreutils`.** `config-loader.sh` checks
   `timeout` / `stdbuf` / `stat` / `setsid` / `find`, but not `date`. On macOS without gnubin
   the `last=` column degrades to `?`.

### Concerns

1. "No new retry layer" is semantically true, but design-review never used the watchdog — for
   that file this *is* a new retry layer, up to two extra attempts per executor.
2. The prompts get longer; an LLM still interprets them and may confuse
   `ALL_DONE`/`SETTLED`/`CHANGED` or ignore "Do NOT hand-roll a poller".
3. No automated verification of the prompts — the "edited one mirrored block, forgot the sync
   note" regression class stays open.
4. `MISSING` semantics are unexplained: in which real scenarios does it arise, and how does it
   differ from "the wrapper died before creating the directory"?
5. The `out=",state"` fallback is unreachable — better `die "internal: no status change"`.
   *(Contradicted by observation and by qwen's execution — it is reachable.)*
6. The `idle_notification` rule says `--once <that run dir>` but never explains how to derive
   the run dir from a notification; there is no agent → run dir map in the design.

### Suggestions

1. An explicit reconciliation rule between the watch loop and Step 6.0 (a
   `.watch_reported_dead` marker), or document double classification as intended.
2. Parse `watchdog.log` with `jq -R 'fromjson? | select(.event == "cleanup")'` and keep the
   substring as a fallback.
3. Fix the expected count to 3; also check `WATCH_TIMEOUT` appears exactly once.
4. Boundary tests: several runs changing status in the same tick (`CHANGED done,stalled`);
   finalization via `cleanup` with no `output.txt` and no `final`; an empty directory reaching
   `stall_sec`.
5. **Replace `date -d` with the bash builtin `printf '%(%H:%M:%S)T' "$newest"`** (bash 4.2+) —
   removes the macOS risk with no new dependency.
6. A smoke test for the prompts: extract the watch block from both files and assert the
   presence of `watch-runs.sh`, the status table, the `DEADLINE` line, the sync note, and
   mirroring.

### Questions

1. Is double classification in Step 6.0 intended? How does it square with "report precisely,
   continue" and "no new retry layer"?
2. Who is supposed to create `$RD/.watchdog_rc`?
3. How does the orchestrator derive the run dir for `--once` from an `idle_notification`?
4. Why do `ALL_DONE` and `SETTLED` use exit code 2, which normally means failure? Risk that an
   LLM reads a successful completion as a fault.
5. Was the plan tested on macOS?

*The executor added its own caveat: `grep -c` counts matching lines, not occurrences, so the
reviewer's arithmetic needed direct checking. It does return 3.*

## zai/glm

First attempt (default mode) hit exit 4 — the exact incident signature: stream torn
mid-generation after ~8 min, 3508 `thinking_tokens` events, last JSON line truncated, no
`result` event, only 916 chars of preamble recovered. The supervised re-run succeeded on
attempt 1 in ~9 min (`attempt_success` → `complete` → `cleanup`, rc=0).

### Critical Issues

**1. `watch-runs.sh` classifies bailed/empty runs as `DONE`, and design-review never checks
content.** Traced chain: on bail `watchdog.sh` still creates the `final` symlink (`:323`) and
writes `cleanup` via the EXIT trap (`:121-138, 286`), but root `output.txt` is never created —
the supervised block copies artefacts up **only** in the `rc=0` branch
(`codex-exec/SKILL.md:347-385`); the `rc=2` branch prints diagnostics and exits. `classify`
marks `DONE` on `[ -L "$d/final" ]` or `cleanup`, so a run where all 3 watchdog attempts
failed is reported `DONE`, and Component C then tells the orchestrator to read a non-existent
`output.txt` — reintroducing the improvisation this task exists to remove. Wider than bail:
even at `rc=0`, `output.txt` can be empty (`codex-exec/SKILL.md:378` "else: leave empty").
This is not covered by the out-of-scope carve-out — that concerns *routing*, this is
*classification in new code*. `/mesh-review` is protected by `verify-delegation.sh`'s
`[ -s output.txt ]` check (`:93`) while design-review has no analogue, so the new script
widens that asymmetry. Fix: a mechanical content check at collection, or have `watch-runs.sh`
read `watchdog.exit` (`reason: all_attempts_failed|global_timeout`) / a non-zero `cleanup`
exit and emit `STALLED`/`FAILED`.

**2. The "180 passed" invariant is stale — independently measured `246 passed, 0 failed`** on
this branch. The number is hardcoded in four places (plan Global Constraints, Task 1 Step 5,
Task 5 Step 2, design Testing section). Since the plan is executed task-by-task with
"Expected: X" gates, an executor hits a false mismatch at the first gate. Assert `0 failed`
without a hardcoded count. *(Verified by the orchestrator: 246. The figure came from the
input task document and was propagated without checking.)*

### Concerns

1. `SETTLED` and `ALL_DONE` share exit code 2 — distinguishable only by parsing the reason.
2. `new_statuses` returns `"state"` and loses information when a second run finishes while the
   first is already `DONE` — degrading the reason in the most common multi-run case.
3. GNU `stat -c %Y` and `date -d` with no precondition check, inconsistent with
   `config-loader.sh:76-101` (`require_gnu_coreutils`) and `watchdog.sh:25-27`.
4. Timing tests 13–15 are potentially flaky; Test 15's margin is tight
   (`deadline=START+3`, assert `ELAPSED >= 3`).
5. The empirical claims (212 runs, 282 logs, 38/212, 139/151, "`stall_detected` never fired")
   are load-bearing but unverifiable from the repo — record a reproduction command.
6. Component A alone would have resolved the incident; B is defence-in-depth costing ~130
   lines + 36 asserts + two mirrored prompt rewrites. The document presents them as near-equal
   — an explicit cost/benefit line would preempt "why B?".

### Suggestions

Drop the hardcoded test count; add a content check or a `FAILED` status (Critical 1); add a
GNU coreutils precondition; widen Test 15's margin to `deadline=START+5` / assert `>=4`; give
`ALL_DONE` and `SETTLED` distinct exit codes so the orchestrator need not parse prose.

### Questions

1. Is it confirmed that **no** design-review step reads `log.jsonl`? Supervised mode does not
   write it — a surviving consumer would break collection silently.
2. Should an all-retries-failed supervised run route as a failure rather than be collected as
   an empty section?
3. Are the 212/282/38/139/151 figures reproducible, or incident-report-only?
4. Is it verified on the current Claude Code build that a background Bash task's exit wakes the
   main session? The whole "watcher exits → re-invoke" model rests on this inherited
   assumption.
5. Should `--deadline` be mandatory for orchestrator invocations? The default is "watch
   indefinitely", so safety depends on the prompt always passing it.

---

## Measured test baseline (orchestrator, 2026-07-27, branch `fix/watch-loop-stall-detection`)

| Suite | Result |
|---|---|
| `test-check-context-size.sh` | 11 passed, 0 failed |
| `test-config-loader.sh` | **246** passed, 0 failed |
| `test-extract-result.sh` | 28 passed, 0 failed |
| `test-loader-resolution.sh` | 12 passed, 0 failed |
| `test-render-template.sh` | 44 passed, 0 failed |
| `test-verify-delegation.sh` | 42 passed, 0 failed |

The plan's "180 passed" is wrong in all four places it appears, and Task 5 Step 2 omits
`test-check-context-size.sh`.

---

## Orchestrator findings from dogfooding the design during this review

Full detail in the scratchpad notes; summarised because they are first-hand observations, not
reviewer claims.

- **D1** A retry creates a **new** run dir; the abandoned first one crosses `stall_sec` and
  reports `STALLED`, so a live executor is declared dead. Observed 4× this run. One retry dir
  even carried a different suffix (`…-iter-1-retry`), defeating glob rediscovery.
- **D2** `new_statuses` set-difference produced a live `CHANGED state` when `qwen` finished
  while `minimax` was already `DONE`. (`minimax` C1 and `kimi` #5 called this branch
  unreachable; it fired.)
- **D3** Settle-check precedes change-check, so the death of the **last** running executor
  reports as a bare `SETTLED`. Reproduced with a two-dir fixture.
- **D4** `qwen`'s torn attempt left a 47429-byte `output.txt` containing only narration; the
  script called it `DONE`. Independently reached by `glm` C1 and `opus` K2 from the `bail()`
  side.
- **D5** The first watcher launch died `Permission denied` — the prompts invoke `"$WATCH"`
  directly and the plan never asserts the blob landed as `100755`.
- **D6** The suite passes 36/36 both before and after the D2 bug: no test has a mixed
  baseline, which is why three reviewers reasoned the branch was unreachable.
- **D7** The harness reported the watcher's exit 2 as **"failed"** — live confirmation of
  `opus` K4 / `codex` "exit codes 2/3 look like failure".
