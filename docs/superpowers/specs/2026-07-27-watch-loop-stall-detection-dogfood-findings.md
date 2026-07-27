# Findings against the watch-loop stall-detection design, found by running it live

Source: dogfooding `watch-runs.sh` on the iter-1 design review of its own design doc
(2026-07-27, 8 reviewers, 6 executors). These are MY findings, not a reviewer's — they
must be classified in Step 9 alongside the reviewers' issues.

## D1 (Critical) — a fixed run-dir list is the wrong handle; retries create new dirs

`watch-runs.sh` takes a list of run dirs captured at dispatch. An executor that dies and
self-retries creates a **new** run dir. The abandoned first dir stops being written to,
crosses `stall_sec`, and is reported `STALLED` — so the orchestrator marks a **live**
executor dead and, per Decision 2, continues without it. A false FAILED, which is worse
than the blindness being fixed.

Observed live: `ollama/kimi` and `deepseek/v4-pro` both died unsupervised at ~13:09 and
self-retried into fresh dirs. `alibaba/qwen` did the same at 13:12.

Aggravator: qwen's retry dir is named `…-iter-1-retry`, a different suffix — so even a
glob-based rediscovery keyed on the task name can miss it.

Fix direction: the watcher should take `engine[/provider/model]` plus `--since EPOCH` and
re-resolve the newest matching dir on **every tick**, the way `verify-delegation.sh`
already does (`find … -newermt "@$SINCE" | sort -rn | head -1`). Directory identity is
not executor identity.

## D2 (Critical) — `new_statuses` used set difference, so the reason line went blank

Original implementation reported statuses "present now, absent from baseline". Once ANY
dir is `DONE`, a later dir reaching `DONE` adds nothing new to the set, so `$out` came out
empty and the reason degraded to the `,state` sentinel.

Observed live: `CHANGED state` when `alibaba/qwen` finished while `ollama/minimax` was
already `DONE`.

Correct rule: compare **per position**, collecting the status each dir transitioned INTO.
Fixed in the scratchpad copy; the plan still carries the broken version.

Note: reviewer `ollama/minimax` raised this same branch as C1 and argued it is
*unreachable*. It is reachable, and it fired. Plausible reasoning, refuted by observation.

## D3 (Major) — settle-check runs before change-check, so the last death reads as `SETTLED`

Order is deadline → settle → change. When the last `RUN` dir dies, `has_status RUN` goes
false and the loop emits a bare `SETTLED` — "nothing left running" — instead of naming the
death. The rows do show `STALLED`, so the information is not lost, but the reason line was
supposed to be what makes a death nameable, and this is exactly the incident's end state
(some done, rest dead, nothing running).

Verified live with a two-dir fixture: `a`=DONE, `b`=RUN→STALLED yields `SETTLED`.

Fix direction: always compute transitions and append them to whichever terminal reason
fires — `SETTLED stalled`, `ALL_DONE`, `CHANGED done,stalled`, `DEADLINE`.

## D4 (Critical) — `DONE` conflates "stopped changing" with "produced a usable result"

`[ -s output.txt ]` is not sufficient. A torn unsupervised run can leave a large non-empty
`output.txt` holding the model's narration instead of its review.

Observed live: `alibaba/qwen`'s torn attempt left a 47429-byte `output.txt` beginning
"Проведу ревью документов… Начну с чтения" and containing no `Critical Issues` /
`Concerns` / `Suggestions` / `Questions` section. `watch-runs.sh` classified it `DONE`.
Only the executor's own honesty prevented a narration draft from being merged as a review.

Related: `watchdog.sh` writes `cleanup` on *every* exit including `bail`, so the third
DONE predicate has the same problem (reviewer `ollama/minimax` Q5).

Fix direction: `DONE` must mean "finalized, not necessarily REAL", stated explicitly, and
both prompts must run `verify-delegation.sh` on a `DONE` run before accepting its report.
That is the boundary `ollama/minimax` C7 asked to document — it is load-bearing, not
cosmetic.

## D5 (Minor) — the plan never verifies the exec bit reached the index

Both prompts invoke the script as `"$WATCH" …`, not `bash "$WATCH"`. All three existing
`skills/shared/*.sh` are mode `100755`. The plan does `chmod +x` before `git add`, but
never asserts the blob landed as `100755`.

Observed live: the first watcher launch died with `Permission denied`, silently, inside a
background task — the worst place for it.

Fix direction: add `git ls-files -s skills/shared/watch-runs.sh` expecting `100755` to
Task 1 Step 6, and the same for the test file.

## D6 (Major) — the test suite passes 36/36 both before and after the D2 bug

No test has a **mixed** baseline (some dir already `DONE` while another transitions), so
D2 and D3 both sail through. The suite validates each status in isolation and never the
vector semantics that the whole design rests on.

Fix direction: add mixed-baseline cases — `DONE` + `RUN`→`DONE` must yield `CHANGED done`;
`DONE` + `RUN`→`STALLED` must name `stalled` in the reason.

## D7 (Major) — the harness reports exit 2 as a failed task

The watcher exited `ALL_DONE` (exit 2) and the harness surfaced it as
`Background command … failed with exit code 2`. Live confirmation of `opus` K4 and `codex`'s
concern: an LLM orchestrator reading that will treat a normal terminal verdict as an error.
Either use exit 0 for every non-error verdict, or say so explicitly in both prompts.

## Verified fix for D2, for reuse after the interface is settled

This replacement was applied to the prototype and the suite stayed at 36/36; it also produced
correct `CHANGED done` / `CHANGED stalled` reason lines on the live run. It is the
per-position rule, not a set difference:

```bash
new_statuses() {
    # Per-POSITION transitions, not set difference. Set difference reports nothing when
    # the status entered is already held by some other dir — so once ANY run is DONE,
    # every later change degrades to "state" and the reason line stops naming the death.
    local -a b c
    read -ra b <<< "$1"
    read -ra c <<< "$2"
    local moved=" " out="" i s
    for i in "${!c[@]}"; do
        [ "${c[$i]}" = "${b[$i]:-}" ] || moved="$moved${c[$i]} "
    done
    for s in DONE STALLED MISSING RUN; do
        case "$moved" in *" $s "*) out="$out,$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" ;; esac
    done
    [ -n "$out" ] || out=",state"
    printf '%s' "${out#,}"
}
```

Note this fix does NOT address D3 (the settle-check still precedes the change-check, so the
last executor's death still reports as a bare `SETTLED`), and it is moot if the interface
moves to per-run reason lines as `opus` S3 suggests.

## Measured test baseline (this branch, 2026-07-27)

`test-check-context-size.sh` 11 · `test-config-loader.sh` **246** · `test-extract-result.sh` 28
· `test-loader-resolution.sh` 12 · `test-render-template.sh` 44 · `test-verify-delegation.sh` 42
— all `0 failed`. The plan's "180 passed" is wrong in all four places it appears; it came from
the input task document and was propagated without checking.
