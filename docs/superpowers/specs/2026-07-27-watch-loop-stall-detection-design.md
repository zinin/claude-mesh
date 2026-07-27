# Stall detection in the mesh review watch loop — design

Date: 2026-07-27
Branch: `fix/watch-loop-stall-detection`
Status: approved for planning (rewritten after design-review iteration 1)

## Problem

The `/mesh-review` and `/mesh-design-review` orchestrators watch the disk for executor
results but cannot tell a slow executor from a dead one. Both look the same on disk:
nothing changes.

On 2026-07-26 a `/mesh-design-review default` run dispatched six reviewers. Four external
runs died mid-stream between 14:40 and 14:57. The orchestrator stayed silent until the
user asked "как дела?" at 15:35 — 38 minutes over a state that could never change again,
with the evidence on disk since 14:42. When the watch budget finally expired at 15:39 it
reported `WATCH_TIMEOUT after 3916s` — "time ran out", not "three executors died 50
minutes ago".

The failure reproduced during this design's own review on 2026-07-27: four of five
ext-claude executors died mid-stream in the default unsupervised mode. All four recovered,
because the executor agents improvised a retry — non-deterministically, and into **new**
run directories.

## Root cause

Two layers, verified against the repository and against 488 archived run directories.

### 1. `/mesh-design-review` never enables supervised mode

`skills/shared/watchdog.sh` already implements the stall detection this task is about:

- stream freshness by mtime (`HARD_ZERO_TIMEOUT`, default 600s);
- process liveness via `kill -0`;
- auto-retry, `MAX_RETRIES=2`;
- a machine-readable `watchdog.log` (JSONL) with `alive{age_sec,event_count}` every 60s,
  plus `stall_detected`, `stream_lost`, `attempt_failed`, `bail`, `cleanup`.

It runs only under `SUPERVISED_MODE=shell`. The two command paths differ:

| Command | Path | `SUPERVISED_MODE` | Supervised runs on disk |
|---|---|---|---|
| `/mesh-review` | `*-code-reviewer` → `*-code-review` | hardcoded `shell` | 242 / 255 (95%) |
| `/mesh-design-review` | `*-executor` → `*-exec` | default `none` | 42 / 223 (19%) |

`grep SUPERVISED skills/mesh-design-review/SKILL.md` returns nothing. The skill never
specifies the mode, so whether a run gets a watchdog is left to chance. On 2026-07-26 none
of the six did.

Consequences:

- The watch loop's third finalization predicate — "the run's `watchdog.log` has a
  `cleanup` event" — is a working death signal that simply never fires, because no
  watchdog runs.
- No auto-retry. `SKILL.md` Step 6 asserts "Each executor launches its external engine
  (**watchdog** + CLI)"; for the default path that is false.

### 2. The watch loop has no liveness predicate and leaves implementation to improvisation

`skills/mesh-design-review/SKILL.md:427-430` and `commands/mesh-review.md:246-249` define
three finalization predicates, all about a result *appearing*. Nothing is about progress
*disappearing*. The only backstop is `runtime.timeouts.global_sec` — an hour of blindness
by default, and its message says "time ran out" rather than naming the death.

Point 2 says the watcher "exits on each state change". The orchestrator implemented that
as "exit when the DONE count exceeds the baseline". Death does not increase the count, so
the watcher never woke.

The block carries a second, quieter defect: `commands/mesh-review.md:247` reads
`"$LOADER" get-runtime` while `$LOADER` is never assigned anywhere in Step 5a. Shell state
does not survive between Bash-tool calls, and a prompt does not raise `set -u` — the reader
improvises. Both files already warn about exactly this class
(`SKILL.md:308`, `mesh-review.md:107`); the watch block violates the warning printed a
hundred lines above it.

### What the archive actually says about the watchdog

Three claims in the previous draft were quantitative and load-bearing, so they were
re-measured rather than inherited. Reproduce with:

```bash
D=~/.claude/plugins/data/claude-mesh-*/runs
grep -ho '"event":"[a-z_]*"' $(find $D -name watchdog.log) | sort | uniq -c | sort -rn
```

Across 286 `watchdog.log` files:

| Event | Count |
|---|---|
| `cleanup` | 286 (100%) |
| `complete` | 246 |
| `attempt_failed` | 13 |
| `bail` | 2 — both `global_timeout`, zero `all_attempts_failed` |
| `stall_detected` | 0 |
| `stream_lost` | 0 |

**`stall_detected` has never fired, and should not have.** The `bail.reason` tabulation —
the falsifiable check reviewer `ollama/minimax` asked for — settles it: a torn provider
stream *kills* the CLI rather than hanging it, which surfaces as `attempt_failed` (13
occurrences) via the `wait`/`kill -0` path and routes to a retry. The mtime threshold
covers a different, rarer failure: a process that is alive but producing nothing.

**`cleanup` is not a success signal.** 40 of the 286 runs (14%) have `cleanup` without
`complete`: 38 with `exit_code:143` (killed from outside) and 2 with `exit_code:2` (bail).
Of those 40, **36 have neither `final` nor `output.txt`** — so `cleanup` is the only
predicate that fires, and under the previous design it alone would have made the status
`DONE` for a directory containing nothing to read.

**The `zai/glm` retry was not a mechanism.** The default-mode block in `ext-claude-exec`
exits 4 on exactly the incident signature (`output.txt` empty, `raw.jsonl` has data). The
executor agent saw a failed Bash call and re-ran on its own initiative — which is why glm
retried and deepseek/kimi did not. `runtime.max_redispatch` is a `/mesh-review` Step 6.0
mechanism that runs far later; it was not involved, and it does not exist in
`skills/mesh-design-review/SKILL.md` at all (0 occurrences, versus 7 in
`commands/mesh-review.md`).

## Decisions

### 1. Scope — enable the watchdog *and* give the orchestrator a fleet view

Component A turns on the existing watchdog in design-review. Component B replaces the
improvised poll loop with a tested shared script. Component C rewrites the watch text in
both prompts. Component D closes the gap between "the run finished" and "the run produced a
review", which design-review has never checked.

**What Component B is, stated honestly.** After Component A, `watchdog.log` receives an
`alive` heartbeat every 60s for as long as the CLI process lives
(`watchdog.sh:213-248`, inside `while kill -0 "$pid"`), regardless of stream activity. A
healthy supervised run therefore cannot accumulate enough quiet time to be called silent.
Combined with `stall_detected` at 0/286, the "the watchdog died" scenario the earlier draft
used to justify Component B has never been observed.

So Component B is not primarily a stall sensor. It does five things, and only the last is
stall detection:

1. **Follows retries.** A dead executor that re-runs creates a *new* run directory. The
   watchdog lives inside one directory and cannot know about siblings; this is an
   orchestrator-level concern by construction.
2. **Distinguishes a finished run from a failed one.** The watchdog records its own exit
   code and nothing reads it.
3. **Reports an executor that produced no run directory at all.** No run means no
   `watchdog.log`, so Component A is blind to this case by definition.
4. **Writes the watch loop down once.** This is the actual subject of the incident.
5. **Reports silence.** After Component A this fires only for a run that is not supervised
   — that is, for non-compliance with the dispatch contract, which was observed in four of
   five executors during this design's own review.

The cost argument in review iteration 1 ("~130 lines for a sensor that never fires")
measures the wrong thing: the freshness threshold is roughly 20 of those lines. The rest is
the loop.

**Why not reuse `verify-delegation.sh` as the poller.** It emits `STALLED` for any run
directory without `final` and without `output.txt` (`verify-delegation.sh:77-79`) — which
is every run still in flight. It is a post-hoc classifier and cannot answer a liveness
question.

### 2. What the watcher holds — a roster, not a list of directories

The watcher takes `engine[/provider/model]` entries plus `--since EPOCH`, and re-resolves
the newest matching run directory on **every** evaluation.

A fixed list of directories captured at dispatch is disproven. An executor that dies and
self-retries creates a new directory; the abandoned one stops changing, crosses the
threshold, and a **live** executor is reported dead. Observed four times in one run, and
one retry directory carried a different suffix (`…-iter-1-retry`), so even glob
rediscovery keyed on the task name misses it. Directory identity is not executor identity.

This is not a new discovery rule — it is the fallback already written into both prompts
(`SKILL.md:427`, `mesh-review.md:246`) and already implemented by `verify-delegation.sh`,
applied every tick instead of once.

A roster entry is literally the subpath under `runs/`: `codex`, `gemini`,
`ext-claude/zai/glm`.

**Consequence: the deadline moves inside the script.** Given `--since`, the watcher
computes `deadline = since + runtime.timeouts.global_sec + 300` itself. The orchestrator no
longer performs arithmetic in a prompt, and the "absolute versus relative budget" rule
disappears along with the `jq` call. The margin of 300s is fixed, not configurable; it
covers agent boot and dispatch spread before the executors' own clocks start.

**Consequence: exactly one volatile value crosses the Bash-call boundary** — the `--since`
literal, which both prompts already stamp and keep. And it is validated: a `--since`
outside `[now − 86400, now + 60]` is a usage error naming the likely cause. The previous
draft's `DEADLINE=$(( DISPATCH_EPOCH + … ))` collapsed to `3900` when the variable did not
survive, `is_pos_int 3900` passed, and the watcher reported the budget expired on its first
evaluation — silently, and worse than the bug being fixed.

### 3. What a status means, and where content is judged

`DONE` must not conflate "stopped changing" with "produced something usable".

```
terminal := watchdog.log has a cleanup event (any exit code)
         OR there is no watchdog.log and output.txt is non-empty

DONE     = terminal AND no non-zero cleanup exit code
                    AND non-empty output.txt (root or final/output.txt)
FAILED   = terminal AND NOT DONE
```

Checked against the archive: the 2 bailed runs (`final` present, no `output.txt`) classify
`FAILED`; the 36 killed runs with nothing on disk classify `FAILED`; the 2 killed runs with
a partial `output.txt` classify `FAILED` on their non-zero exit code. `DONE` now carries
the guarantee the orchestrator's next action assumes — that there is something to read.

**Content is judged elsewhere.** The boundary, which review iteration 1 asked to state:

- `watch-runs.sh` answers *terminal state*: running, stopped, how it stopped. It reads file
  existence, size and mtime, never content.
- `verify-delegation.sh` answers *content*: is this a real review.

The worked case is on disk. During this design's review the torn `alibaba/qwen` attempt
left a 47429-byte `output.txt` containing only the model's narration ("Проведу ревью
документов… Начну с чтения") and no findings sections. `watch-runs.sh` calls it `DONE` —
correctly, by its own contract. `verify-delegation.sh` calls it `STALLED` ("no usable
result event in raw.jsonl — killed mid-flight"), and calls the supervised retry `REAL`
(`num_turns=26`). Both verdicts are right; they answer different questions.

`/mesh-review` already runs that gate in Step 6.0. `/mesh-design-review` has no analogue,
so a classifier that says `DONE` for a narration draft would widen an existing asymmetry.
Component D closes it — by *calling* `verify-delegation.sh`, not by duplicating its rules,
because two scripts reading the same files under different rules is a disagreement waiting
to happen.

**Naming.** The watcher's "silent past the threshold" status is `SILENT`, not `STALLED`.
`verify-delegation.sh` already emits `STALLED` with a different meaning, and Step 6.0 feeds
that verdict into `max_redispatch`; one word with two meanings inside one command is a
defect. `SILENT` also describes what the watcher actually observes.

### 4. On detecting death — report precisely, continue

A `SILENT`, `FAILED` or `MISSING` run is routed into the existing failure path and named
for what it is: "ext-claude ollama/kimi silent for 612s, last write 14:40:43" — never
`WATCH_TIMEOUT`, which claims time ran out when an executor died, and the two call for
different actions. (`WATCH_TIMEOUT` appears nowhere in the repository; it was an
orchestrator improvisation.)

**No new retry layer.** In `/mesh-review` retry exists at two layers — `watchdog.sh` ×2
inside the run, and Step 6.0's `max_redispatch` for the wrapper. In
`/mesh-design-review` there is exactly **one**: the watchdog, which Component A is what
turns on. The earlier draft asserted "two layers" for both files; for design-review that
was false, and the false sentence was about to be written into its prompt.

### 5. Threshold — `max(stall_sec, 600)`

`runtime.timeouts.stall_sec` is not the shared threshold the earlier draft assumed.
`skills/ext-claude-exec/SKILL.md:261` passes `HARD_ZERO_TIMEOUT="$STALL"` from config;
`skills/codex-exec/SKILL.md:332` and `skills/gemini-exec/SKILL.md:313` hardcode
`HARD_ZERO_TIMEOUT=600`. The key governs one engine of three.

With `stall_sec: 300` the watcher would call a codex run `SILENT` at 300s while its
watchdog will not act before 600s: the orchestrator marks it failed and drops it, the
watchdog then finishes successfully into a directory nobody is watching, and the result is
discarded. Independently, the largest healthy stream gap measured across 46 successful
archived runs is 383s, so 300 would produce false positives without any desynchronisation
at all.

The watcher therefore floors its threshold at 600 and warns on stderr when the floor or the
default applies. The invariant is one sentence: **the watcher never declares silence
earlier than the slowest watchdog would act.** Plumbing the config into codex-exec and
gemini-exec would be the deeper fix and is out of scope; a comment would not be enough. No
new configuration key.

### 6. Exit codes — 0 for every verdict

Confirmed live during this review: a background Bash task exiting 2 is surfaced by the
harness as "Background command … failed with exit code 2". An LLM orchestrator reads a
normal terminal verdict as an error.

Every verdict therefore exits 0 and is carried by the reason line, which is the contract
anyway and has the only consumer. A non-zero exit means the **watcher itself** is broken —
bad arguments, missing script, bash < 4 — and never that an executor died. That also gives
the orchestrator the answer to "what if the watcher dies": a non-zero exit is a diagnosable
event rather than a second unannounced silence.

### 7. Where the watch logic lives — a shared script

A new `skills/shared/watch-runs.sh`, not prose and not a snippet duplicated into two
prompts. Prose is what got re-improvised into a counter check; two snippets would drift,
and drift between these files is itself a known bug. This follows the existing
`verify-delegation.sh` precedent — a mechanical on-disk guard invoked from the prompt,
covered by unit tests.

Decision 2 shrinks what stays in prose, though it does not eliminate it. The deadline
arithmetic disappears entirely into the script. "Drop dead runs from the list" does not
disappear — it becomes "pass the executors you are still waiting for", which is one
self-evident sentence instead of a rule to remember. And Component D adds a prose step of
its own. The honest claim is that the prompt now carries fewer moving parts, not none:
what the orchestrator must still *do* is act on a verdict and narrow a list.

## Component A — enable supervised mode in design-review

Add `SUPERVISED_MODE: shell` to the executor dispatch templates in
`skills/mesh-design-review/SKILL.md` Step 6 — two blocks covering three executors: one
shared by codex and gemini, one for ext-claude. The punctuation matches the neighbouring
`TASK_NAME:` line in each template.

The parameter must also be documented in the executor agent contracts. Today only
`agents/ext-claude-executor.md` mentions it, and only in passing; `agents/codex-executor.md`
and `agents/gemini-executor.md` do not list it at all, so a dispatch template carrying it
would leak the line into `PROMPT` instead of forwarding it. Add `SUPERVISED_MODE` to the
Input Parameters section of all three, and fix two inconsistencies the change would
otherwise entrench:

- `agents/ext-claude-executor.md:29` documents these parameters with `=`
  (`SUPERVISED_MODE=…`) while the dispatch templates use `: `. One file would carry two
  contradictory syntaxes for the same parameter — the exact confusion that documenting it
  is meant to prevent.
- `agents/gemini-executor.md` still lists `log.jsonl` among the run artifacts. Supervised
  mode does not write it; `agents/codex-executor.md:44` already carries that caveat, and
  gemini must mirror it.

**The `*-exec` skills keep `none` as their default.** Flipping it would change every direct
`/claude-mesh:*-exec` invocation, which would lose the live streaming progress of
`progress-monitor.sh` — supervised mode extracts results after the fact instead. That is a
real interactive regression for a fix aimed at orchestrated runs.

Artifact impact of supervised mode is contained: root `raw.jsonl` / `output.txt` /
`report.md` are still produced for backward compatibility; only `log.jsonl` is absent, and
it has no consumer outside the exec skills' own default-mode blocks.

## Component B — `skills/shared/watch-runs.sh`

### Interface

```
watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR]
              <engine[/provider/model]>...
```

| Option | Default |
|---|---|
| `--since` | **required** — the dispatch epoch, substituted as a literal |
| `--stall-sec` | `runtime.timeouts.stall_sec` via `config-loader.sh get-runtime`, else 600; floored at 600 either way |
| `--poll-sec` | 30 |
| `--once` | evaluate once, print, exit — do not block |
| `--data-dir` | `config-loader.sh data-dir` |

At least one roster entry is required; an empty roster is a usage error, because a caller
with nothing left to watch should not invoke the watcher at all.

Every option validates symmetrically: a non-positive-integer `--stall-sec`, `--poll-sec` or
`--since` is a usage error, not a silent fallback. (The earlier draft let `--stall-sec`
degrade quietly to 600 while its neighbours exited 64 — and `--stall-sec --once <entry>`
consumed `--once` as the value and then blocked forever.) A resolved threshold that comes
from the default or the floor is announced on stderr.

If `<data-dir>/runs/<entry>` does not exist, the entry is reported `MISSING` and a warning
naming the path goes to stderr — a roster typo must be diagnosable rather than silently
producing a permanent `MISSING`.

### Resolving the run directory

For each roster entry, the candidate directories are the immediate subdirectories of
`<data-dir>/runs/<entry>`. Run directory names begin with a fixed-width, zero-padded
`YYYY-MM-DD-HH-MM-SS-<pid>` prefix, so lexicographic order is chronological order by
*creation*. The watcher renders `--since` into the same format with the bash builtin
`printf '%(%Y-%m-%d-%H-%M-%S)T'`, keeps the names that sort at or after it, and selects the
maximum. No `find`, no `date`, no subprocess.

Selecting by name rather than by mtime matters: an abandoned directory that receives a late
structural write (a `final` symlink on bail) must not outrank the retry directory that
superseded it.

This windowing is deliberately stricter than `verify-delegation.sh`'s
`find -newermt "@$SINCE"`, which admits a directory created before the window but modified
inside it. The two scripts run at different times for different purposes and the difference
is safe; it is recorded here so it is not read as drift.

### Status per roster entry

| Status | Condition |
|---|---|
| `DONE` | terminal, no non-zero `cleanup` exit code, and `output.txt` non-empty |
| `FAILED` | terminal, and not `DONE` |
| `MISSING` | no run directory at or after `--since`, and more than `stall_sec` has passed since `--since` |
| `SILENT` | a run directory exists, is not terminal, and `quiet > stall_sec` |
| `RUN` | anything else — including a directory not yet created, inside the grace window |

*Terminal* means: `watchdog.log` contains a `cleanup` event, whatever its exit code, or
there is no `watchdog.log` and `output.txt` is non-empty. A non-zero `cleanup` exit code
lands in `FAILED` — with the reason taken from `watchdog.exit`
(`all_attempts_failed` / `global_timeout`) when that file is present.

A zero-byte `output.txt` is never finalization — `gemini-exec:208` pre-creates one at
launch.

`quiet = now − max(mtime)` over whichever of these exist inside the resolved directory:
`raw.jsonl`, `log.jsonl`, `watchdog.log`, `attempt-*/raw.jsonl`; if none exist, the
directory's own mtime.

Why the maximum over that set:

- Under supervision the CLI writes `attempt-N/raw.jsonl` and root `raw.jsonl` appears only
  at the end — but `watchdog.log` receives an `alive` heartbeat every 60s, so the gap
  between watchdog retries produces no false `SILENT`.
- Without supervision the rule degrades to plain CLI stream freshness. `log.jsonl` is
  required: a codex default-mode run has no `raw.jsonl` at all.
- If the watchdog dies while its CLI keeps running, `attempt-*/raw.jsonl` keeps the run
  `RUN` rather than falsely `SILENT`. Erring toward "do not declare a live run dead" is the
  safe direction; the deadline remains the backstop.

**`MISSING` has a grace period.** An entry with no directory yet is treated as `RUN` until
`now − since > stall_sec`; only after that is it reported `MISSING`. Without this, a roster
entry whose executor is still booting would be declared dead on the first evaluation —
contradicting the asymmetry above. The grace period needs no new option because the script
already knows `--since`.

### Roster semantics and the baseline

**The roster is the set of executors the orchestrator is still waiting for.** That single
sentence replaces two prose rules from the earlier draft.

The baseline is therefore *virtual*: every entry is assumed `RUN`, and any other status is
news on the first evaluation. The earlier draft established the baseline from the first
evaluation itself, which meant a run that was already dead when the watcher started was
absorbed into the baseline and never announced — reproducing the original 38 minutes of
blindness on **every watcher restart**, and a restart happens after every change. Two
reviewers found this independently; it is the one defect that would have re-created the
incident inside the fix.

The corollary is a rule the orchestrator must follow: **narrow the roster before
re-invoking.** An entry already reported and handled must not be passed again, or the
watcher returns immediately with the same reason. The prompts state the self-check
directly: *if the watcher returns twice in a row with the same reason, the roster was not
narrowed.*

### Reason lines and exit codes

The reason line names the transitions, not a set of statuses:

```
CHANGED <entry> FROM→TO[, <entry> FROM→TO …]   something moved off RUN
SETTLED <entry> FROM→TO[, …]                   nothing is RUN any more, not all DONE
ALL_DONE                                       every entry DONE
DEADLINE                                       since + global_sec + 300 has passed
SNAPSHOT                                       --once only: nothing has moved off RUN
```

All of these exit 0. A usage or precondition failure exits 64, matching the `watchdog.sh`
convention.

Naming the per-entry transition rather than a status set removes a defect and a
degenerate case at once. The earlier draft reported "statuses present now but absent from
the baseline", which reports *nothing* once any entry already holds the status being
entered — so with three or more executors, every completion after the first degraded to an
undocumented `CHANGED state` sentinel. That fired live during this review. With per-entry
transitions there is no set arithmetic and no fallback branch.

`SETTLED` carries its transitions for the same reason: when the last running executor dies,
"nothing is left running" is not the useful half of the sentence — "kimi went RUN→SILENT"
is. `ALL_DONE` carries none, since every transition would read `RUN→DONE`.

Checked in this order on every evaluation: all-done, then settle, then deadline, then
change; `SNAPSHOT` is what `--once` prints when none of those fire. Because the baseline is
virtual rather than established by the first iteration, there is no
baseline-establishing pass — the first evaluation and every later one run identical logic,
and the loop needs no "first time" flag.

**Finished work outranks the budget.** Running the script against the real 2026-07-27 run
directories 156 minutes after dispatch produced `DEADLINE` over six rows that all read
`DONE` — "time ran out" about a review that had completed. Review iteration 1 predicted
exactly this and it reproduces trivially, because the orchestrator is often busy when the
last run lands. `ALL_DONE` and `SETTLED` are therefore evaluated first: if nothing is still
running, the budget is irrelevant. The deadline stays ahead of `CHANGED` so that a roster
which never stops running still terminates on the budget rather than on the orchestrator's
diligence.

**`CHANGED` therefore fires under `--once` too, and that is the point.** A one-shot check
answering an executor's message reports `CHANGED ext-claude/ollama/kimi RUN→SILENT`
immediately, instead of a `SNAPSHOT` that the reader has to diff by eye. (The earlier draft
had the opposite property, and review iteration 1 asked for a test pinning it; that
expectation is inverted here deliberately.)

### Output

The reason line, then one row per roster entry: status, entry, resolved directory name,
and timing where it carries information.

A mid-watch wake-up, roster of three still awaited:

```
CHANGED ext-claude/ollama/kimi RUN→SILENT
RUN      codex                   2026-07-27-13-04-32-2059576-design-review-…-iter-1  quiet=12s
RUN      ext-claude/zai/glm      2026-07-27-13-12-28-2136074-design-review-…-iter-1  quiet=8s
SILENT   ext-claude/ollama/kimi  2026-07-27-13-04-41-2060933-design-review-…-iter-1  quiet=612s last=13:14:53
```

The last two, after the roster has been narrowed to what remained:

```
SETTLED ext-claude/alibaba/qwen RUN→DONE, gemini RUN→FAILED
DONE     ext-claude/alibaba/qwen 2026-07-27-13-12-14-2135662-design-review-…-iter-1-retry
FAILED   gemini                  2026-07-27-13-05-02-2061880-design-review-…-iter-1  global_timeout
```

Note that in a narrowed roster every non-`RUN` row is, by construction, something the
orchestrator has not yet handled — which is why the reason line and the rows agree.

`DONE` and `MISSING` rows carry no timing. `FAILED` rows carry the `watchdog.exit` reason
when present. `SILENT` rows carry `quiet` and `last`; `RUN` rows carry `quiet` only.

## Component C — watch loop text in both prompts

Mirrored edits in `skills/mesh-design-review/SKILL.md` (point 2 onward of the Step 6 watch
block) and `commands/mesh-review.md` (point 2 onward of the Step 5a watch block):

1. **Point 2** — invoke `watch-runs.sh` as a background Bash task instead of hand-rolling a
   poll loop. State the status table. State explicitly that a watcher exiting only when the
   `DONE` count grows is the bug this replaces, and that writing a bespoke poller is
   forbidden.
2. **New point** — a `SILENT`, `FAILED` or `MISSING` run is routed into the existing
   failure path, and the orchestrator's message names the observation. The routing target
   legitimately differs between the files (`/mesh-review` → Step 6.0; `mesh-design-review`
   → Error Handling) and stays as it is; only the watch mechanics are shared.
3. **New rule** — pass only the executors still being waited for, plus the self-check on a
   watcher that returns immediately twice.
4. **New rule** — anything an executor says while the watch is running (its interim status,
   a progress note, a question) is answered with a single `watch-runs.sh --once` call over
   the current roster *before* replying, not with "expected, still waiting". Such a message
   is a free opportunity to check liveness; in the incident six of them were spent
   confirming inaction. The rule is phrased on the observable event because
   `idle_notification`, the term the previous draft used, appears nowhere in the repository
   and names nothing the orchestrator can recognise.
5. **Sync note** between the two blocks, in the style of the existing one on the Iron Rules.

**Locating the script differs by file, deliberately.** `skills/mesh-design-review/SKILL.md`
forbids `${CLAUDE_PLUGIN_ROOT}` inside Bash blocks in its own "Locating plugin files"
section — it is empty there on Claude Code 2.1.156 — and requires `SKILL_BASE`, so the
skill resolves `$SKILL_BASE/../shared/watch-runs.sh`. `commands/mesh-review.md` has no
`SKILL_BASE` and uses the command-file idiom: the canonical three loader lines, then
`WATCH="$(dirname "$LOADER")/watch-runs.sh"`. Both add an explicit `[ -x "$WATCH" ]` check,
because the prompts invoke `"$WATCH"` directly and a missing execute bit dies with
`Permission denied` inside a background task — the worst place for it, observed live.

That fourth loader copy in `commands/` is a deliberate canary break:
`skills/shared/tests/test-loader-resolution.sh` asserts 5 primary / 5 fallback lines across
`commands/` and 3 in `mesh-review.md`. The new site makes it 6 / 6 / 4, all three canonical
lines must be used, and the test file is part of the change.

`config.example.yaml`: the `stall_sec` comment currently says "supervised mode"; it is now
read by the orchestrator's watcher too, with the 600 floor.

## Component D — content gate in design-review

When the watcher reports a run `DONE`, and **before** pinging its executor for the report,
`skills/mesh-design-review/SKILL.md` runs the existing guard:

```
verify-delegation.sh <engine> <model|-> <since>
```

`REAL` → accept the report. `STALLED` / `BROKEN` / `FLIP` → treat as a failed executor per
Error Handling: note it in the merged file, omit its section, continue. No re-dispatch —
the watchdog that Component A enables is the retry layer.

The three arguments are exactly the ones the orchestrator already holds for the watcher, so
the call costs nothing new. `verify-delegation.sh` itself is not modified.

This is the asymmetry named in Decision 3: `/mesh-review` has run this gate since Step 6.0
existed; design-review never has.

## Testing

New `skills/shared/tests/test-watch-runs.sh`, following `test-verify-delegation.sh`.
Fixtures are temporary data directories (`--data-dir`) holding
`runs/<engine>[/<provider>/<model>]/<timestamp>-<pid>-<task>/`, with mtimes set via
`touch -d`.

Classification:

- terminal `cleanup` `exit_code:0` + non-empty `output.txt` → `DONE`
- `cleanup` `exit_code:2` with `final` and no `output.txt` → `FAILED`, reason from
  `watchdog.exit`
- `cleanup` `exit_code:143`, nothing else on disk → `FAILED`
- `cleanup` `exit_code:0` but empty `output.txt` → `FAILED`
- no `watchdog.log`, non-empty `output.txt` → `DONE`
- zero-byte `output.txt` → not terminal
- **regression, the load-bearing case**: `raw.jsonl` stale beyond the threshold but
  `watchdog.log` fresh → `RUN` (this is what makes watchdog retries safe)
- `attempt-1/raw.jsonl` fresh, root `raw.jsonl` absent → `RUN`
- `log.jsonl` as the only freshness source → `RUN`
- stale stream, not terminal → `SILENT` with the correct `quiet` **value** and `last`
- threshold boundary: `quiet == stall_sec` → `RUN`, `quiet == stall_sec + 1` → `SILENT`
- no directory, within grace → `RUN`; past grace → `MISSING`

Resolution:

- two directories for one entry, the newer one fresh → the newer is watched, the abandoned
  one is ignored (the retry case, D1)
- a retry directory with a different task suffix is still resolved
- a directory created before `--since` is not selected
- an abandoned directory whose mtime was bumped after the retry started does not outrank it
- a roster entry with no base directory → `MISSING` + a stderr warning
- a path containing a space

Loop and protocol:

- an entry already `SILENT` at watcher start → immediate `CHANGED <entry> RUN→SILENT`
  (the virtual-baseline regression)
- a status change mid-watch → `CHANGED` naming entry and transition
- the last running entry dying → `SETTLED` naming the transition, not a bare verdict
- two entries changing in one tick → both named
- every entry `DONE` → `ALL_DONE`
- deadline passed → `DEADLINE`
- `--once` over a roster with an already-silent entry yields `CHANGED`, not `SNAPSHOT`
- `--once` with everything still running yields `SNAPSHOT`
- every verdict exits 0
- invalid `--since` / `--stall-sec` / `--poll-sec`, and an empty roster → exit 64
- `--since` outside the plausibility window → exit 64 naming the likely cause
- `--stall-sec 120` is floored to 600 and warns

Timing-sensitive cases wait on a marker the watcher writes after its first iteration rather
than on a bare `sleep`, and the deadline case uses a margin wide enough not to race the
scheduler.

Every existing suite must end `0 failed`, with no hardcoded pass count in the assertion —
the six suites are `test-check-context-size.sh`, `test-config-loader.sh`,
`test-extract-result.sh`, `test-loader-resolution.sh`, `test-render-template.sh`,
`test-verify-delegation.sh`. `test-loader-resolution.sh` changes as described in
Component C.

Both prompt files are prompts, not code. They are verified by reading: internal
consistency, and agreement between the two mirrored blocks.

## Files

New:
- `skills/shared/watch-runs.sh`
- `skills/shared/tests/test-watch-runs.sh`

Modified:
- `skills/mesh-design-review/SKILL.md` — Step 6 dispatch templates, watch block, content gate
- `commands/mesh-review.md` — Step 5a watch block
- `agents/codex-executor.md`, `agents/gemini-executor.md`, `agents/ext-claude-executor.md`
- `skills/shared/tests/test-loader-resolution.sh` — canary counts 6 / 6 / 4
- `config.example.yaml` — `stall_sec` comment

Untouched:
- `skills/shared/verify-delegation.sh` (called, not modified)
- `skills/shared/watchdog.sh`
- the `SUPERVISED_MODE` default in the `*-exec` skills

## Out of scope

- Reconciling the point-4 routing divergence between the two files (`/mesh-review` routes
  silent executors to Step 6.0, `mesh-design-review` to Error Handling). The routing differs
  because the downstream steps differ; only the watch mechanics are unified here.
- Plumbing `runtime.timeouts.stall_sec` into `codex-exec` and `gemini-exec`, which hardcode
  `HARD_ZERO_TIMEOUT=600`. The 600 floor makes the watcher safe without it.
- `.watchdog_rc`: `verify-delegation.sh:89` reads it and nothing in `skills/` writes it. Real
  and pre-existing; the file it lives in must not be touched. `cleanup`'s `exit_code` gives
  `watch-runs.sh` the same signal without it.
- Extracting the repeated loader-resolution block into `shared/resolve-loader.sh`. The
  canary test exists precisely because there are now six copies; consolidating them is its
  own change.
- Any change to `verify-delegation.sh` or to the `max_redispatch` flow.
- Branch `feature/multi-model-claude-reviewers` and its work.
