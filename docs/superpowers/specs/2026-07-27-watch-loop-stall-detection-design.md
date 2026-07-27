# Stall detection in the mesh review watch loop — design

Date: 2026-07-27
Branch: `fix/watch-loop-stall-detection`
Status: approved for planning

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

## Root cause

Two layers, verified against the repository and against 212 archived design-review runs.

### 1. `/mesh-design-review` never enables supervised mode

`skills/shared/watchdog.sh` already implements the stall detection this task is about:

- stream freshness by mtime (`HARD_ZERO_TIMEOUT`, default 600s, fed by
  `runtime.timeouts.stall_sec`);
- process liveness via `kill -0`;
- auto-retry, `MAX_RETRIES=2`;
- a machine-readable `watchdog.log` (JSONL) with `alive{age_sec,event_count}` every 60s,
  plus `stall_detected`, `stream_lost`, `attempt_failed`, `bail`, `cleanup`.

It runs only under `SUPERVISED_MODE=shell`. The two command paths differ:

| Command | Path | `SUPERVISED_MODE` | Supervised runs on disk |
|---|---|---|---|
| `/mesh-review` | `*-code-reviewer` → `*-code-review` | hardcoded `shell` | 139 / 151 |
| `/mesh-design-review` | `*-executor` → `*-exec` | default `none` | 38 / 212 |

`grep SUPERVISED skills/mesh-design-review/SKILL.md` returns nothing. The skill never
specifies the mode, so whether a run gets a watchdog is left to chance — 38 of 212 got
one. On 2026-07-26 none of the six did.

Consequences:

- The watch loop's third finalization predicate — "the run's `watchdog.log` has a
  `cleanup` event" — is a working death signal that simply never fires, because no
  watchdog runs. Verified against a failed supervised run: `cleanup` is written even on
  `exit_code:143`.
- No auto-retry. `SKILL.md` Step 6 asserts "Each executor launches its external engine
  (**watchdog** + CLI)"; for the default path that is false.

### 2. The watch loop has no liveness predicate and leaves implementation to improvisation

`skills/mesh-design-review/SKILL.md:425-430` and `commands/mesh-review.md:244-249` define
three finalization predicates, all about a result *appearing*. Nothing is about progress
*disappearing*. The only backstop is `runtime.timeouts.global_sec` — an hour of blindness
by default, and its message says "time ran out" rather than naming the death.

Point 2 says the watcher "exits on each state change". The orchestrator implemented that
as "exit when the DONE count exceeds the baseline". Death does not increase the count, so
the watcher never woke.

### Two secondary findings

**`stall_detected` has never fired across 282 watchdog logs, and should not have.** A torn
provider stream *kills* the CLI rather than hanging it; that is caught by the `kill -0`
liveness check, which routes to `attempt_failed` → retry. The mtime threshold covers a
different, rarer failure: a process that is alive but producing nothing.

**The `zai/glm` retry was not a mechanism.** The default-mode block in `ext-claude-exec`
exits 4 on exactly the incident signature (`output.txt` empty, `raw.jsonl` has data). The
executor agent saw a failed Bash call and re-ran on its own initiative — non-deterministic,
which is why glm retried and deepseek/kimi did not. `runtime.max_redispatch` is a
`/mesh-review` Step 6.0 mechanism that runs far later than 14:47; it was not involved.

## Decisions

1. **Scope**: enable the existing watchdog in design-review *and* add a liveness net to the
   watch loop. The watchdog is the primary fix at the right layer; the net covers a dead
   watchdog and any unsupervised run.
2. **On detecting death**: mark FAILED, report precisely, continue. No new retry — retry
   already exists at two layers (watchdog ×2, `max_redispatch`), and a third would be the
   duplication this task was told to avoid.
3. **Where the watch logic lives**: a new shared script, not prose and not a snippet
   duplicated into two prompts. Prose is what got re-improvised into a counter check; two
   snippets would drift, and drift between these files is itself a known bug. This follows
   the existing `verify-delegation.sh` precedent — a mechanical on-disk guard invoked from
   the prompt, covered by unit tests.
4. **Threshold**: reuse `runtime.timeouts.stall_sec` (600). The key exists and already
   means exactly this. No new configuration.

## Component A — enable supervised mode in design-review

Add `SUPERVISED_MODE: shell` to the executor dispatch templates in
`skills/mesh-design-review/SKILL.md` Step 6 — two blocks covering three executors: one
shared by codex and gemini, one for ext-claude. The punctuation matches the neighbouring
`TASK_NAME:` line in each template.

The parameter must also be documented in the executor agent contracts. Today only
`agents/ext-claude-executor.md` mentions it, and only in passing; `agents/codex-executor.md`
and `agents/gemini-executor.md` do not list it at all, so a dispatch template carrying it
would leak the line into `PROMPT` instead of forwarding it. Add `SUPERVISED_MODE` to the
Input Parameters section of all three.

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
watch-runs.sh [--stall-sec N] [--deadline EPOCH] [--poll-sec N] [--once] <run-dir>...
```

| Option | Default |
|---|---|
| `--stall-sec` | `runtime.timeouts.stall_sec` via `config-loader.sh get-runtime`, fallback 600 |
| `--deadline` | none (watch indefinitely) |
| `--poll-sec` | 30 |
| `--once` | evaluate once, print, exit — do not block |

At least one run directory is required; an empty list is a usage error, because a caller
with nothing left to watch should not invoke the watcher at all.

**`--deadline` takes an absolute epoch, not a duration.** The watcher is restarted after
every status change, so a relative budget would reset on each restart and never expire.
The orchestrator computes `DL=$((DISPATCH_EPOCH + global_sec + margin))` once, before
dispatch, and passes the same value to every invocation.

### Status per run directory

| Status | Condition |
|---|---|
| `DONE` | `output.txt` exists and is non-empty, **or** `final` exists (`-L` or `-e`, so a dangling symlink still counts), **or** `watchdog.log` contains `"event":"cleanup"` |
| `STALLED` | not `DONE` and `quiet > stall_sec` |
| `RUN` | not `DONE` and not `STALLED` |
| `MISSING` | the directory does not exist |

`quiet = now − max(mtime)` over whichever of these exist: `raw.jsonl`, `log.jsonl`,
`watchdog.log`, `attempt-*/raw.jsonl`.

Why the maximum over that set:

- Under supervision the CLI writes `attempt-N/raw.jsonl` and root `raw.jsonl` appears only
  at the end — but `watchdog.log` receives an `alive` heartbeat every 60s, so the gap
  between watchdog retries produces no false `STALLED`.
- Without supervision the rule degrades to plain CLI stream freshness.
- If the watchdog dies while its CLI keeps running, `attempt-*/raw.jsonl` keeps the run
  `RUN` rather than falsely `STALLED`. Erring toward "do not declare a live run dead" is
  the safe direction; `--deadline` remains the backstop.

A zero-byte `output.txt` is not finalization — `gemini-exec` pre-creates one at launch.

The `cleanup` probe matches the literal `"event":"cleanup"`; `watchdog.log` lines are
generated by `jq -nc` with a fixed key order, so the substring is exact rather than a
loose match.

### Loop and exit

The first evaluation establishes the baseline snapshot. Every evaluation — the first one
included — is checked in this order: deadline, then settle, then change.

```
exit 3   DEADLINE             --deadline passed
exit 2   ALL_DONE             every directory is DONE
exit 2   SETTLED              nothing is RUN any more, but not everything is DONE
exit 0   CHANGED <statuses>   status vector differs from the baseline — look, then re-invoke
exit 0   SNAPSHOT             --once only: none of the above, so at least one directory is RUN
exit 64  (usage error)        matches the watchdog.sh convention
```

`CHANGED` cannot fire on the first evaluation, since the baseline is established there.
`SNAPSHOT` is reachable only under `--once`; without it the watcher sleeps `--poll-sec` and
evaluates again.

`SETTLED` prevents the loop from spinning to the deadline when the only non-`DONE`
directories are `STALLED` or `MISSING` and the orchestrator has not yet dropped them.

`<statuses>` lists the statuses present now but absent from the baseline, comma-separated
in the fixed order `done,stalled,missing,run`, e.g. `CHANGED done,stalled`.

### Output

The reason line, then one line per directory. Paths are printed relative to the data
directory's `runs/` root; a path outside it is printed in full.

```
CHANGED stalled
DONE     codex/2026-07-26-14-35-38-282583-design-review-multi-model-claude-reviewers-iter-1
DONE     ext-claude/alibaba/qwen/2026-07-26-14-36-53-285067-design-review-…-iter-1
STALLED  ext-claude/ollama/kimi/2026-07-26-14-37-31-290029-design-review-…-iter-1   quiet=612s last=14:40:43
RUN      ext-claude/zai/glm/2026-07-26-14-47-01-398584-design-review-…-iter-1       quiet=8s
```

`DONE` and `MISSING` rows carry no `quiet` field. `STALLED` rows carry `quiet` and `last`;
`RUN` rows carry `quiet` only.

## Component C — watch loop text in both prompts

Mirrored edits in `skills/mesh-design-review/SKILL.md` (point 2 onward of the Step 6 watch
block) and `commands/mesh-review.md` (point 2 onward of the Step 5a watch block):

1. **Point 2** — invoke `watch-runs.sh` as a background Bash task instead of hand-rolling a
   poll loop. State the status table. State explicitly that a watcher exiting only when the
   `DONE` count grows is the bug this replaces, and that writing a bespoke poller is
   forbidden.
2. **New point** — a `STALLED` or `MISSING` run is marked FAILED and routed into the
   existing failure path, and the orchestrator's message names the observation: "kimi is
   silent for 612s, last write 14:40:43" — never `WATCH_TIMEOUT` for a death. The routing
   target legitimately differs between the files (`/mesh-review` → Step 6.0;
   `mesh-design-review` → Error Handling), and stays as it is; only the watch mechanics are
   shared.
3. **New rule** — a `STALLED` run is dropped from the directory list passed to the next
   watcher invocation.
4. **New rule** — an `idle_notification` from an executor is answered with a single
   `watch-runs.sh --once` call, not with "expected, still waiting". A notification is a free
   opportunity to check liveness; in the incident six of them were spent confirming
   inaction.
5. **Sync note** between the two blocks, in the style of the existing one on the Iron Rules.

`config.example.yaml`: the `stall_sec` comment currently says "supervised mode"; it is now
read by the orchestrator's watcher too.

## Testing

New `skills/shared/tests/test-watch-runs.sh`, following `test-verify-delegation.sh`.
Fixtures are temporary directories with mtimes set via `touch -d`.

Cases:

- all directories `DONE` → `ALL_DONE`, exit 2
- `--once` with a fresh stream → `SNAPSHOT` + `RUN`, exit 0
- not finalized, stale stream → `STALLED` with correct `quiet` and `last`
- **regression, the load-bearing case**: `raw.jsonl` stale beyond the threshold but
  `watchdog.log` fresh → `RUN`, no false `STALLED` (this is what makes watchdog retries
  safe)
- `attempt-1/raw.jsonl` fresh, root `raw.jsonl` absent → `RUN`
- zero-byte `output.txt` → not `DONE`
- `final` symlink present → `DONE`
- `watchdog.log` containing `"event":"cleanup"` → `DONE`
- absent directory → `MISSING`
- mix of `DONE` and `STALLED`, nothing `RUN` → `SETTLED`, exit 2
- deadline in the past → `DEADLINE`, exit 3
- status transition between ticks → `CHANGED` naming the new status
- no directory arguments → exit 64

`bash skills/shared/tests/test-config-loader.sh` must stay at 180 passed, 0 failed.

Both prompt files are prompts, not code. They are verified by reading: internal
consistency, and agreement between the two mirrored blocks.

## Files

New:
- `skills/shared/watch-runs.sh`
- `skills/shared/tests/test-watch-runs.sh`

Modified:
- `skills/mesh-design-review/SKILL.md` — Step 6 dispatch templates + watch block
- `commands/mesh-review.md` — Step 5a watch block
- `agents/codex-executor.md`, `agents/gemini-executor.md`, `agents/ext-claude-executor.md`
- `config.example.yaml` — `stall_sec` comment

Untouched:
- `skills/shared/verify-delegation.sh`
- the `SUPERVISED_MODE` default in the `*-exec` skills

## Out of scope

- Reconciling the point-4 divergence between the two files (`/mesh-review` routes silent
  executors to Step 6.0, `mesh-design-review` to Error Handling). The routing differs
  because the downstream steps differ; only the watch mechanics are unified here.
- Any change to `verify-delegation.sh` or to the `max_redispatch` flow.
- Branch `feature/multi-model-claude-reviewers` and its work.
