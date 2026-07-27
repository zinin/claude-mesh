# Watch-loop stall detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `/mesh-review` and `/mesh-design-review` orchestrators notice a dead executor within `stall_sec` instead of sitting silent until the hour-long global budget expires.

**Architecture:** Two moves. First, turn on the watchdog that `/mesh-design-review` never enabled — it already does stall detection, auto-retry and writes the `cleanup` event that the watch loop's third finalization predicate looks for. Second, replace the prose "poll the disk" instruction in both prompts with a tested shared script, `skills/shared/watch-runs.sh`, that classifies every run dir as DONE / RUN / STALLED / MISSING and exits on any status change — so the orchestrator cannot re-improvise it into a counter check, as it did on 2026-07-26.

**Tech Stack:** bash 4+, GNU coreutils (`stat -c`, `date -d`), `jq` (optional — only to read the config default), markdown prompts.

## Global Constraints

- The stall threshold is `runtime.timeouts.stall_sec`, default 600. No new config key.
- `--deadline` is an **absolute** unix epoch, never a duration. The watcher restarts after every change; a relative budget would reset each time and never expire.
- Detection marks a run FAILED and continues. **No new retry layer** — retry already exists in `watchdog.sh` (`MAX_RETRIES=2`) and in `/mesh-review` Step 6.0 (`max_redispatch`).
- `skills/shared/verify-delegation.sh` is not touched.
- The `SUPERVISED_MODE` default in the `*-exec` skills stays `none`. Flipping it would strip live `progress-monitor.sh` progress from direct `/claude-mesh:*-exec` invocations.
- New shell code follows `verify-delegation.sh` conventions: `set -u` (not `-e`), a bash 4+ guard, meaningful exit codes, verdict on stdout.
- Test files follow `skills/shared/tests/test-verify-delegation.sh`: `assert_eq`, `PASS`/`FAIL` counters, `mktemp -d` fixtures, and a closing `=== Summary: $PASS passed, $FAIL failed ===` with `[ "$FAIL" = "0" ]`.
- `bash skills/shared/tests/test-config-loader.sh` must stay at **180 passed, 0 failed** throughout.
- CHANGELOG entries go under `## [Unreleased]`; the version bump is a separate release chore and is out of scope.

---

### Task 1: `watch-runs.sh` — status classification and single evaluation

**Files:**
- Create: `skills/shared/watch-runs.sh`
- Test: `skills/shared/tests/test-watch-runs.sh`

**Interfaces:**
- Consumes: `skills/shared/config-loader.sh get-runtime` (JSON with `.timeouts.stall_sec`), resolved as a sibling of the script.
- Produces: executable `watch-runs.sh` accepting `[--stall-sec N] [--deadline EPOCH] [--poll-sec N] [--once] <run-dir>...`. Prints a reason line, then one row per dir. Reasons and exit codes established here: `ALL_DONE`=2, `SETTLED`=2, `DEADLINE`=3, `SNAPSHOT`=0, usage error=64. Task 2 adds `CHANGED`=0 and the polling loop, reusing the shell functions `classify`, `evaluate`, `has_status`, `emit`, `shorten`, `newest_mtime` defined here.

- [ ] **Step 1: Write the failing test file**

Create `skills/shared/tests/test-watch-runs.sh`:

```bash
#!/usr/bin/env bash
# Regression tests for watch-runs.sh
#
# watch-runs.sh answers one question the orchestrators could not answer on their own:
# is each external run finished, still working, or dead? A dead executor and a slow one
# leave the same disk — nothing changes — so the classification below is the whole point.
#
# Reasons (stdout line 1) + exit codes:
#   CHANGED <statuses>=0   SNAPSHOT=0   ALL_DONE=2   SETTLED=2   DEADLINE=3   usage=64
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../watch-runs.sh"

FAIL=0
PASS=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$pattern' in '$actual')" ;;
    esac
}

# run the script, capture full output, reason line and rc
run() { OUT="$(bash "$SCRIPT" "$@" 2>/dev/null)"; RC=$?; REASON="$(printf '%s\n' "$OUT" | head -1)"; }
# the rendered row for a run dir, matched by its shortened path
row() { printf '%s\n' "$OUT" | grep -F "$1" | head -1; }

mk_run() { mkdir -p "$1"; printf '%s' "$1"; }

# === Test 1: every run finalized → ALL_DONE ===
echo "=== Test 1: every run finalized → ALL_DONE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); echo 'review' > "$a/output.txt"
b=$(mk_run "$TDIR/runs/ext-claude/zai/glm/run-b"); echo 'review' > "$b/output.txt"
run --once --stall-sec 600 "$a" "$b"
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 2: fresh stream → SNAPSHOT + RUN ===
echo "=== Test 2: fresh stream → SNAPSHOT + RUN ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/ext-claude/zai/glm/run-a"); : > "$a/raw.jsonl"
run --once --stall-sec 600 "$a"
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "row is RUN" "RUN" "$(row 'zai/glm/run-a')"
assert_match "row carries quiet" "quiet=" "$(row 'zai/glm/run-a')"
rm -rf "$TDIR"

# === Test 3: stale stream → STALLED with quiet and last ===
echo "=== Test 3: stale stream → STALLED with quiet and last ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi/run-a")
: > "$a/raw.jsonl"; touch -d '20 minutes ago' "$a/raw.jsonl" "$a"
run --once --stall-sec 600 "$a"
assert_eq "reason SETTLED" "SETTLED" "$REASON"
assert_eq "exit 2" "2" "$RC"
assert_match "row is STALLED" "STALLED" "$(row 'ollama/kimi/run-a')"
assert_match "row carries last=" "last=" "$(row 'ollama/kimi/run-a')"
rm -rf "$TDIR"

# === Test 4: REGRESSION — a watchdog heartbeat keeps a retrying run alive ===
# This is the case that makes SUPERVISED_MODE=shell safe to enable. Under supervision the
# CLI writes attempt-N/raw.jsonl and root raw.jsonl only appears at the end, so between
# watchdog retries the root stream looks long dead. The `alive` heartbeat is the proof of
# life; without folding watchdog.log into the freshness set, every supervised retry would
# be reported as a death.
echo "=== Test 4: REGRESSION — watchdog heartbeat keeps a retrying run alive ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/ext-claude/deepseek/v4-pro/run-a")
: > "$a/raw.jsonl"; touch -d '20 minutes ago' "$a/raw.jsonl"
printf '{"ts":"x","event":"alive","attempt":2,"details":{"event_count":7,"age_sec":3}}\n' > "$a/watchdog.log"
run --once --stall-sec 600 "$a"
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN, not STALLED" "RUN" "$(row 'deepseek/v4-pro/run-a')"
rm -rf "$TDIR"

# === Test 5: supervised layout — attempt-1/raw.jsonl is the live stream ===
echo "=== Test 5: supervised layout — attempt-1/raw.jsonl is the live stream ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); mkdir -p "$a/attempt-1"; : > "$a/attempt-1/raw.jsonl"
touch -d '20 minutes ago' "$a"
run --once --stall-sec 600 "$a"
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row 'codex/run-a')"
rm -rf "$TDIR"

# === Test 6: gemini's pre-created zero-byte output.txt is NOT finalization ===
echo "=== Test 6: zero-byte output.txt is NOT finalization ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/gemini/run-a"); : > "$a/output.txt"; : > "$a/raw.jsonl"
run --once --stall-sec 600 "$a"
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row 'gemini/run-a')"
rm -rf "$TDIR"

# === Test 7: final symlink counts as finalized ===
echo "=== Test 7: final symlink counts as finalized ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); mkdir -p "$a/attempt-1"; ln -s attempt-1 "$a/final"
run --once --stall-sec 600 "$a"
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 8: a cleanup event counts as finalized ===
echo "=== Test 8: a cleanup event counts as finalized ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a")
printf '{"ts":"x","event":"cleanup","attempt":2,"details":{"exit_code":143}}\n' > "$a/watchdog.log"
run --once --stall-sec 600 "$a"
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
rm -rf "$TDIR"

# === Test 9: absent run dir → MISSING ===
echo "=== Test 9: absent run dir → MISSING ==="
TDIR=$(mktemp -d)
run --once --stall-sec 600 "$TDIR/runs/codex/never-created"
assert_eq "reason SETTLED" "SETTLED" "$REASON"
assert_match "row is MISSING" "MISSING" "$(row 'codex/never-created')"
rm -rf "$TDIR"

# === Test 10: nothing left running but not all finalized → SETTLED ===
echo "=== Test 10: nothing running, not all finalized → SETTLED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); echo 'review' > "$a/output.txt"
b=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi/run-b"); : > "$b/raw.jsonl"
touch -d '20 minutes ago' "$b/raw.jsonl" "$b"
run --once --stall-sec 600 "$a" "$b"
assert_eq "reason SETTLED" "SETTLED" "$REASON"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 11: expired deadline wins over everything ===
echo "=== Test 11: expired deadline wins over everything ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); : > "$a/raw.jsonl"
run --once --stall-sec 600 --deadline 1000000000 "$a"
assert_eq "reason DEADLINE" "DEADLINE" "$REASON"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test 12: no run dirs → usage error ===
echo "=== Test 12: no run dirs → usage error ==="
run --once --stall-sec 600
assert_eq "exit 64" "64" "$RC"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash skills/shared/tests/test-watch-runs.sh`
Expected: FAIL — every case reports an unexpected value because `watch-runs.sh` does not exist yet (bash prints "No such file or directory" to the suppressed stderr and returns 127).

- [ ] **Step 3: Write `skills/shared/watch-runs.sh`**

```bash
#!/usr/bin/env bash
# watch-runs.sh — is each external run finished, still working, or dead?
#
# The /mesh-review (Step 5a) and /mesh-design-review (Step 6) orchestrators disk-watch
# their executors' run dirs. Finalization is easy to see; DEATH is not — a dead executor
# and a slow one leave exactly the same disk: nothing changes. Both orchestrators used to
# hand-roll the poll loop from prose, and both arrived at "exit when the finished count
# grows", which death never does. On 2026-07-26 four executors died mid-stream and the
# orchestrator stayed silent for 38 minutes. This script is that loop, written once.
#
# Usage:
#   watch-runs.sh [--stall-sec N] [--deadline EPOCH] [--poll-sec N] [--once] <run-dir>...
#
# Status per run dir:
#   DONE     output.txt non-empty, or `final` present, or watchdog.log has "event":"cleanup"
#   STALLED  not DONE and quiet > stall-sec
#   RUN      not DONE and not STALLED
#   MISSING  the directory does not exist
#
# quiet = now - newest mtime among raw.jsonl, log.jsonl, watchdog.log, attempt-*/raw.jsonl.
# Under SUPERVISED_MODE=shell the CLI writes attempt-N/raw.jsonl (root raw.jsonl appears
# only at the end) and watchdog.log gets an `alive` heartbeat every 60s, so the gap between
# watchdog retries never reads as STALLED. Unsupervised, the rule degrades to plain CLI
# stream freshness. Erring toward "do not declare a live run dead" is deliberate; --deadline
# is the backstop.
#
# stdout: reason line, then one row per dir. Exit codes:
#   0   SNAPSHOT           — --once, and at least one dir is RUN
#   2   ALL_DONE           — every dir DONE
#   2   SETTLED            — nothing RUN any more, but not all DONE
#   3   DEADLINE           — --deadline passed
#   64  usage error
#
# --deadline is an ABSOLUTE epoch: the watcher is restarted after every change, so a
# relative budget would reset each time and never expire.
set -u

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
    echo "watch-runs: bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
    exit 64
}

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SELF_DIR/config-loader.sh"

STALL_SEC=""
DEADLINE=""
POLL_SEC=30
ONCE=0
DIRS=()

is_pos_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }

usage() {
    echo "usage: watch-runs.sh [--stall-sec N] [--deadline EPOCH] [--poll-sec N] [--once] <run-dir>..." >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --stall-sec) STALL_SEC="${2:-}"; shift 2 || usage ;;
        --deadline)  DEADLINE="${2:-}";  shift 2 || usage ;;
        --poll-sec)  POLL_SEC="${2:-}";  shift 2 || usage ;;
        --once)      ONCE=1; shift ;;
        --)          shift; while [ $# -gt 0 ]; do DIRS+=("$1"); shift; done ;;
        -*)          echo "watch-runs: unknown option '$1'" >&2; usage ;;
        *)           DIRS+=("$1"); shift ;;
    esac
done

# A caller with nothing left to watch should not invoke the watcher at all.
[ "${#DIRS[@]}" -gt 0 ] || usage
is_pos_int "$POLL_SEC" || { echo "watch-runs: --poll-sec must be a positive integer" >&2; exit 64; }
[ -z "$DEADLINE" ] || is_pos_int "$DEADLINE" || { echo "watch-runs: --deadline must be a unix epoch" >&2; exit 64; }

# Threshold: the caller's flag, else runtime.timeouts.stall_sec, else 600. jq is optional —
# without it the substitution yields nothing and the fallback takes over.
if [ -z "$STALL_SEC" ]; then
    STALL_SEC="$("$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.stall_sec // empty' 2>/dev/null)"
fi
is_pos_int "$STALL_SEC" || STALL_SEC=600

NOW=0
VECTOR=""
ROWS=""
STATUS=""
QUIET=""
LAST=""

# Rows print relative to the runs root so the reason line and rows fit a terminal.
shorten() {
    case "$1" in
        */runs/*) printf '%s' "${1#*/runs/}" ;;
        *)        printf '%s' "$1" ;;
    esac
}

newest_mtime() {
    local d="$1" newest=0 m f
    for f in "$d/raw.jsonl" "$d/log.jsonl" "$d/watchdog.log" "$d"/attempt-*/raw.jsonl; do
        [ -f "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null)" || continue
        [ -n "$m" ] || continue
        [ "$m" -gt "$newest" ] && newest="$m"
    done
    printf '%s' "$newest"
}

classify() {
    local d="$1" newest
    if [ ! -d "$d" ]; then STATUS=MISSING; QUIET=""; LAST=""; return; fi
    # -L before -e so a dangling `final` symlink still counts as finalized.
    # The cleanup probe matches a literal key/value pair: watchdog.log lines come from
    # `jq -nc` with a fixed key order, so the substring is exact, not a loose match.
    if [ -s "$d/output.txt" ] || [ -L "$d/final" ] || [ -e "$d/final" ] \
       || grep -q '"event":"cleanup"' "$d/watchdog.log" 2>/dev/null; then
        STATUS=DONE; QUIET=""; LAST=""; return
    fi
    newest="$(newest_mtime "$d")"
    # Nothing streamed yet: fall back to the run dir's own mtime, so a just-created dir
    # reads as RUN rather than as dead since the epoch.
    [ "$newest" != "0" ] || newest="$(stat -c %Y "$d" 2>/dev/null || printf '%s' "$NOW")"
    QUIET=$(( NOW - newest ))
    LAST="$(date -d "@$newest" +%H:%M:%S 2>/dev/null || printf '?')"
    if [ "$QUIET" -gt "$STALL_SEC" ]; then STATUS=STALLED; else STATUS=RUN; fi
}

evaluate() {
    local d row
    NOW="$(date +%s)"
    VECTOR=""
    ROWS=""
    for d in "${DIRS[@]}"; do
        classify "$d"
        VECTOR="$VECTOR $STATUS"
        row="$(printf '%-8s %s' "$STATUS" "$(shorten "$d")")"
        case "$STATUS" in
            STALLED) row="$row   quiet=${QUIET}s last=$LAST" ;;
            RUN)     row="$row   quiet=${QUIET}s" ;;
        esac
        ROWS="$ROWS$row"$'\n'
    done
}

has_status() { case "$VECTOR " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

emit() { printf '%s\n' "$1"; printf '%s' "$ROWS"; exit "$2"; }

# Checked in this order on every evaluation: deadline, then settle, then change.
evaluate
[ -z "$DEADLINE" ] || [ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE" 3
has_status STALLED || has_status MISSING || has_status RUN || emit "ALL_DONE" 2
has_status RUN || emit "SETTLED" 2
emit "SNAPSHOT" 0
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x skills/shared/watch-runs.sh
bash skills/shared/tests/test-watch-runs.sh
```
Expected: `=== Summary: 26 passed, 0 failed ===` and exit 0.

- [ ] **Step 5: Confirm the existing suite is untouched**

Run: `bash skills/shared/tests/test-config-loader.sh | tail -3`
Expected: `180 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
chmod +x skills/shared/tests/test-watch-runs.sh
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git commit -m "feat(shared): classify external runs as done, running, stalled or missing

watch-runs.sh answers the question neither orchestrator could: is this
executor working or dead? Freshness is the newest mtime across raw.jsonl,
log.jsonl, watchdog.log and attempt-*/raw.jsonl, so a supervised run
between watchdog retries reads as RUN on its heartbeat rather than as a
death.

Claude-Session: https://claude.ai/code/session_017ZE13nvHvUC2KWcEfhSHiL"
```

---

### Task 2: `watch-runs.sh` — the polling loop and change detection

**Files:**
- Modify: `skills/shared/watch-runs.sh` (replace the trailing evaluation block from Task 1 Step 3, and add `new_statuses`)
- Test: `skills/shared/tests/test-watch-runs.sh` (append)

**Interfaces:**
- Consumes: `classify`, `evaluate`, `has_status`, `emit`, `VECTOR`, `NOW`, `POLL_SEC`, `ONCE`, `DEADLINE` from Task 1.
- Produces: blocking behaviour. Without `--once` the script sleeps `--poll-sec` between evaluations and exits on the first status change with `CHANGED <statuses>` (exit 0), where `<statuses>` are the statuses present now but absent from the baseline, comma-separated in the fixed order `done,stalled,missing,run`. Tasks 3–4 rely on exactly these reason strings.

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-watch-runs.sh`, **before** the closing summary block:

```bash
# === Test 13: a run finishing while another works → CHANGED done ===
echo "=== Test 13: a run finishing while another works → CHANGED done ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); : > "$a/raw.jsonl"
b=$(mk_run "$TDIR/runs/ext-claude/zai/glm/run-b"); : > "$b/raw.jsonl"
timeout 20 bash "$SCRIPT" --stall-sec 600 --poll-sec 1 "$a" "$b" > "$TDIR/out" 2>/dev/null &
WPID=$!
sleep 3
echo 'review' > "$a/output.txt"
wait "$WPID"; RC=$?
OUT="$(cat "$TDIR/out")"; REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason CHANGED done" "CHANGED done" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "codex row is DONE" "DONE" "$(row 'codex/run-a')"
rm -rf "$TDIR"

# === Test 14: a run going quiet → CHANGED stalled ===
# The 2026-07-26 blind spot: nothing finishes, so a count-based watcher never wakes.
echo "=== Test 14: a run going quiet → CHANGED stalled ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); : > "$a/raw.jsonl"
b=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi/run-b"); : > "$b/raw.jsonl"
timeout 20 bash "$SCRIPT" --stall-sec 60 --poll-sec 1 "$a" "$b" > "$TDIR/out" 2>/dev/null &
WPID=$!
sleep 3
touch -d '10 minutes ago' "$b/raw.jsonl"
wait "$WPID"; RC=$?
OUT="$(cat "$TDIR/out")"; REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason CHANGED stalled" "CHANGED stalled" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "kimi row is STALLED" "STALLED" "$(row 'ollama/kimi/run-b')"
assert_match "codex row still RUN" "RUN" "$(row 'codex/run-a')"
rm -rf "$TDIR"

# === Test 15: the watcher blocks while everything is still running ===
echo "=== Test 15: the watcher blocks while everything is still running ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR/runs/codex/run-a"); : > "$a/raw.jsonl"
START=$(date +%s)
timeout 20 bash "$SCRIPT" --stall-sec 600 --poll-sec 1 --deadline "$(( START + 3 ))" "$a" > "$TDIR/out" 2>/dev/null
RC=$?
ELAPSED=$(( $(date +%s) - START ))
REASON="$(head -1 "$TDIR/out")"
assert_eq "reason DEADLINE" "DEADLINE" "$REASON"
assert_eq "exit 3" "3" "$RC"
if [ "$ELAPSED" -ge 3 ]; then
    PASS=$((PASS+1)); echo "  PASS: blocked for >=3s (was ${ELAPSED}s)"
else
    FAIL=$((FAIL+1)); echo "  FAIL: returned after ${ELAPSED}s without blocking"
fi
rm -rf "$TDIR"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash skills/shared/tests/test-watch-runs.sh 2>&1 | tail -20`
Expected: Tests 13–15 FAIL. Task 1's script evaluates once and exits `SNAPSHOT` immediately, so the reason is `SNAPSHOT` instead of `CHANGED done` / `CHANGED stalled`, and Test 15 returns in under a second.

- [ ] **Step 3: Add `new_statuses` to `watch-runs.sh`**

Insert immediately after the `has_status` definition:

```bash
# Statuses present now but absent from the baseline, in a fixed order so the reason line
# is stable across runs.
new_statuses() {
    local base="$1 " cur="$2 " out="" s
    for s in DONE STALLED MISSING RUN; do
        case "$cur" in
            *" $s "*)
                case "$base" in
                    *" $s "*) ;;
                    *) out="$out,$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" ;;
                esac
                ;;
        esac
    done
    [ -n "$out" ] || out=",state"
    printf '%s' "${out#,}"
}
```

- [ ] **Step 4: Replace the trailing evaluation block with the loop**

Replace these lines at the end of `watch-runs.sh`:

```bash
# Checked in this order on every evaluation: deadline, then settle, then change.
evaluate
[ -z "$DEADLINE" ] || [ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE" 3
has_status STALLED || has_status MISSING || has_status RUN || emit "ALL_DONE" 2
has_status RUN || emit "SETTLED" 2
emit "SNAPSHOT" 0
```

with:

```bash
# The first evaluation establishes the baseline, so CHANGED cannot fire on it. Every
# evaluation is checked in the same order: deadline, then settle, then change.
BASELINE=""
FIRST=1
while :; do
    evaluate
    [ -z "$DEADLINE" ] || [ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE" 3
    has_status STALLED || has_status MISSING || has_status RUN || emit "ALL_DONE" 2
    has_status RUN || emit "SETTLED" 2
    if [ "$FIRST" = 1 ]; then
        BASELINE="$VECTOR"
        FIRST=0
    elif [ "$VECTOR" != "$BASELINE" ]; then
        emit "CHANGED $(new_statuses "$BASELINE" "$VECTOR")" 0
    fi
    [ "$ONCE" = 0 ] || emit "SNAPSHOT" 0
    sleep "$POLL_SEC"
done
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash skills/shared/tests/test-watch-runs.sh`
Expected: `=== Summary: 36 passed, 0 failed ===` and exit 0. The suite takes roughly 10 seconds — Tests 13–15 wait on real sleeps.

- [ ] **Step 6: Commit**

```bash
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git commit -m "feat(shared): exit the watch loop on any status change, not on a count

The improvised watcher exited when the finished count grew. Death does not
grow a count, so RUN -> STALLED went unnoticed. The loop now compares the
whole status vector against its baseline and names what changed.

Claude-Session: https://claude.ai/code/session_017ZE13nvHvUC2KWcEfhSHiL"
```

---

### Task 3: Enable supervised mode for design-review executors

**Files:**
- Modify: `agents/codex-executor.md` (Optional parameters list)
- Modify: `agents/gemini-executor.md` (Optional parameters list)
- Modify: `agents/ext-claude-executor.md` (new Optional Parameters section)
- Modify: `skills/mesh-design-review/SKILL.md:396-421` (Step 6 dispatch templates)
- Modify: `config.example.yaml` (the `stall_sec` comment)

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces: design-review executor runs now carry `SUPERVISED_MODE: shell`, which makes `shared/watchdog.sh` run — so those run dirs gain `watchdog.log`, `attempt-N/` and a `final` symlink. Task 4's watch-loop text depends on `watchdog.log` existing for design-review runs.

These are prompt files, not code. There is no unit test; verification is by `grep` and by reading.

- [ ] **Step 1: Document `SUPERVISED_MODE` in `agents/codex-executor.md`**

After the `REASONING_LEVEL` bullet in the "Optional parameters" list, add:

```markdown
- **SUPERVISED_MODE** — `none` (default) or `shell`. Forward it to the skill as a named parameter; it is NOT part of `PROMPT`. `shell` wraps the codex run in `shared/watchdog.sh`, which restarts the CLI on a stall or a torn stream and writes a `watchdog.log` the caller can watch for liveness. Orchestrated runs (`/mesh-design-review`) pass `shell`; a one-off interactive run leaves it unset, which keeps the live `progress-monitor.sh` output.
```

- [ ] **Step 2: Document `SUPERVISED_MODE` in `agents/gemini-executor.md`**

After the `APPROVAL_MODE` bullet in the "Optional parameters" list, add:

```markdown
- **SUPERVISED_MODE** — `none` (default) or `shell`. Forward it to the skill as a named parameter; it is NOT part of `PROMPT`. `shell` wraps the gemini run in `shared/watchdog.sh`, which restarts the CLI on a stall or a torn stream and writes a `watchdog.log` the caller can watch for liveness. Orchestrated runs (`/mesh-design-review`) pass `shell`; a one-off interactive run leaves it unset, which keeps the live `progress-monitor.sh` output.
```

- [ ] **Step 3: Add an Optional Parameters section to `agents/ext-claude-executor.md`**

Insert between the "CRITICAL: You MUST Use the Skill Tool" section and the "PROHIBITIONS" section:

```markdown
## Optional Parameters

Recognise these on their own lines and pass each to the skill as a named parameter.
They are NOT part of `PROMPT`.

- **TASK_NAME** — short identifier for log files (default: "task")
- **SUPERVISED_MODE** — `none` (default) or `shell`. `shell` wraps the `claude -p` run in `shared/watchdog.sh`, which restarts the CLI on a stall or a torn stream and writes a `watchdog.log` the caller can watch for liveness. Orchestrated runs (`/mesh-design-review`) pass `shell`; a one-off interactive run leaves it unset, which keeps the live `progress-monitor.sh` output.
```

- [ ] **Step 4: Add `SUPERVISED_MODE: shell` to the Step 6 dispatch templates**

In `skills/mesh-design-review/SKILL.md`, change the codex / gemini template intro and body from:

```
**codex / gemini executors** parse `PROMPT` / `MODEL` / `REASONING_LEVEL` as named params (any line), so use the wrapped form:
```
```
Task tool:
  subagent_type: [claude-mesh:<executor>]
  description: "Design review via [agent-name] (iter N)"
  prompt: "Execute this prompt via [tool]:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    [agent-specific params]"
```

to:

```
**codex / gemini executors** parse `PROMPT` / `MODEL` / `REASONING_LEVEL` / `SUPERVISED_MODE` as named params (any line), so use the wrapped form:
```
```
Task tool:
  subagent_type: [claude-mesh:<executor>]
  description: "Design review via [agent-name] (iter N)"
  prompt: "Execute this prompt via [tool]:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell
    [agent-specific params]"
```

And in the ext-claude template, change:

```
  prompt: "MODEL=<id>
    Execute this prompt via ext-claude-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N"
```

to:

```
  prompt: "MODEL=<id>
    Execute this prompt via ext-claude-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell"
```

- [ ] **Step 5: Explain why, right at the dispatch site**

Immediately after the "Agent-specific parameters" bullet list (after the `ext-claude-executor` bullet, before the "Collect output paths" paragraph), insert:

```markdown
**Every executor template carries `SUPERVISED_MODE: shell` — never drop it.** Without it the `*-exec` skills default to `none`, which means no `shared/watchdog.sh`: no stall detection, no restart when a provider tears the stream mid-response, and no `watchdog.log` — the file that carries the `cleanup` event the watch loop below treats as finalization, and the `alive` heartbeat it treats as proof of life. Design review never set this until 2026-07-27, so supervision was a coin flip: 38 of 212 archived runs got a watchdog. On 2026-07-26 none of six did, four executors died mid-stream, and nothing noticed for 38 minutes.
```

- [ ] **Step 6: Update the `stall_sec` comment in `config.example.yaml`**

Change:

```yaml
    stall_sec: 600                             # supervised mode: no output for this long → kill + retry. default 600
```

to:

```yaml
    stall_sec: 600                             # no output for this long → supervised mode kills and retries;
                                               #   the /mesh-review and /mesh-design-review watcher
                                               #   (shared/watch-runs.sh) reports the run STALLED. default 600
```

- [ ] **Step 7: Verify mechanically**

```bash
grep -c 'SUPERVISED_MODE: shell' skills/mesh-design-review/SKILL.md
grep -l 'SUPERVISED_MODE' agents/codex-executor.md agents/gemini-executor.md agents/ext-claude-executor.md
grep -n 'watch-runs.sh' config.example.yaml
```
Expected: `2` for the first (one per template); all three agent files listed by the second; one hit for the third.

- [ ] **Step 8: Commit**

```bash
git add agents/codex-executor.md agents/gemini-executor.md agents/ext-claude-executor.md \
        skills/mesh-design-review/SKILL.md config.example.yaml
git commit -m "fix(mesh-design-review): supervise executor runs instead of leaving it to chance

Step 6 asserted that each executor launches a watchdog, but never passed
SUPERVISED_MODE, so the *-exec skills defaulted to none. Whether a run got
stall detection, auto-retry and a watchdog.log was luck: 38 of 212 archived
design-review runs had one. codex-executor and gemini-executor did not
document the parameter at all, so the dispatch line would have leaked into
PROMPT — they document it now.

Claude-Session: https://claude.ai/code/session_017ZE13nvHvUC2KWcEfhSHiL"
```

---

### Task 4: Route both orchestrators through `watch-runs.sh`

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md:428-430` (Step 6 watch block, points 2 and 4)
- Modify: `commands/mesh-review.md:247-249` (Step 5a watch block, points 2 and 4)

**Interfaces:**
- Consumes: `watch-runs.sh` and its reason strings from Tasks 1–2; the `watchdog.log` that Task 3 makes design-review runs produce.
- Produces: nothing later tasks depend on.

Both files are prompts. Verification is by `grep` and by reading the two blocks side by side.

- [ ] **Step 1: Replace point 2 of the watch block in `skills/mesh-design-review/SKILL.md`**

Replace this line:

```
2. Poll the disk via Bash — as a background Bash task (a background watcher that exits on each state change re-invokes the orchestrator per event; a foreground poll loop would block the session). ~30–60 s cadence; bound the whole watch by `runtime.timeouts.global_sec` (read it via `"$LOADER" get-runtime | jq -r '.timeouts.global_sec'`, default 3600) plus a margin. A run is finalized when: root `output.txt` is present and non-empty (gemini-exec pre-creates a zero-byte `output.txt` at launch — an empty file is NOT finalization), or a `final` symlink exists, or the run's `watchdog.log` has a `cleanup` event.
```

with:

````
2. Watch the disk with `skills/shared/watch-runs.sh`, launched as a **background** Bash task — a foreground poll loop would block the session, and a background watcher that exits on each state change re-invokes you per event. **Do NOT hand-roll a poller.** The one that was improvised here exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

```bash
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
WATCH="$(dirname "$LOADER")/watch-runs.sh"
DEADLINE=$(( DISPATCH_EPOCH + $("$LOADER" get-runtime | jq -r '.timeouts.global_sec // 3600') + 300 ))
"$WATCH" --deadline "$DEADLINE" <run dir per executor>
```

   `DEADLINE` is an absolute epoch computed **once** from `DISPATCH_EPOCH` and reused verbatim on every re-invocation — the watcher restarts after each change, so a duration would reset every time and never expire. The stall threshold comes from `runtime.timeouts.stall_sec` (default 600); pass `--stall-sec` only to override it.

   The script prints a reason line, then one row per run dir:

   | Status | Meaning |
   |---|---|
   | `DONE` | finalized — `output.txt` non-empty (gemini-exec pre-creates a zero-byte one at launch; empty is NOT finalization), or a `final` symlink, or a `cleanup` event in `watchdog.log` |
   | `RUN` | still producing |
   | `STALLED` | nothing written to `raw.jsonl` / `log.jsonl` / `watchdog.log` / `attempt-*/raw.jsonl` for longer than the threshold |
   | `MISSING` | the run dir is gone |

   It exits on the first status change — `RUN → STALLED` included — with `CHANGED <statuses>`; with `ALL_DONE` or `SETTLED` when nothing is left running; with `DEADLINE` when the budget expires.
````

- [ ] **Step 2: Replace point 4 of the same block in `skills/mesh-design-review/SKILL.md`**

Replace this line:

```
4. Repeat until every dispatched executor has reported or the watch budget expires; treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings". This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it.
```

with:

```
4. **A `STALLED` or `MISSING` run is dead — treat it as a failed executor** per Error Handling ("One agent fails, others succeed"): note the failure in the merged file, omit its section, continue with the rest. Do **not** re-dispatch it. Retry already exists at two layers — `watchdog.sh` restarts the CLI up to twice inside the run, and Step 6.0's `max_redispatch` covers the wrapper — so a third would spend another budget on the same failure. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact an executor died, and the two call for different actions.
5. Drop dead runs from the list you pass to the next `"$WATCH"` invocation, and stop watching once that list is empty.
6. Repeat until every dispatched executor has reported, is dead, or the watch budget expires — never interpret silence as "no findings". This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it.

**An `idle_notification` from an executor is a free liveness check, not something to acknowledge.** Answer it with one `"$WATCH" --once <that run dir>` call and act on the row. On 2026-07-26 six notifications arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command.

> Sync note: points 1–6 are mirrored in `commands/mesh-review.md` (Step 5a). The watch mechanics are identical; only the routing of a dead executor differs (there it lands in Step 6.0, which classifies it mechanically). When editing the mechanics, mirror the edit.
```

- [ ] **Step 3: Replace point 2 of the watch block in `commands/mesh-review.md`**

Replace this line:

```
2. **Poll the disk via Bash — as a background Bash task**, so "Do NOT block" above stays true (a background watcher that exits on each state change re-invokes the orchestrator per event; a foreground poll loop would hold the session hostage). ~30–60 s cadence; bound the whole watch by `runtime.timeouts.global_sec` (read it via `"$LOADER" get-runtime | jq -r '.timeouts.global_sec'`, default 3600) plus a margin. A run is finalized when: root `output.txt` is present **and non-empty** (gemini-exec pre-creates a zero-byte `output.txt` at launch — an empty file is NOT finalization), or a `final` symlink exists, or the run's `watchdog.log` has a `cleanup` event.
```

with:

````
2. **Watch the disk with `skills/shared/watch-runs.sh`, launched as a background Bash task**, so "Do NOT block" above stays true — a foreground poll loop would hold the session hostage, and a background watcher that exits on each state change re-invokes you per event. **Do NOT hand-roll a poller.** The improvised one exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

```bash
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
WATCH="$(dirname "$LOADER")/watch-runs.sh"
DEADLINE=$(( DISPATCH_EPOCH + $("$LOADER" get-runtime | jq -r '.timeouts.global_sec // 3600') + 300 ))
"$WATCH" --deadline "$DEADLINE" <run dir per wrapper>
```

   `DEADLINE` is an absolute epoch computed **once** from `DISPATCH_EPOCH` and reused verbatim on every re-invocation — the watcher restarts after each change, so a duration would reset every time and never expire. The stall threshold comes from `runtime.timeouts.stall_sec` (default 600); pass `--stall-sec` only to override it.

   The script prints a reason line, then one row per run dir:

   | Status | Meaning |
   |---|---|
   | `DONE` | finalized — `output.txt` non-empty (gemini-exec pre-creates a zero-byte one at launch; empty is NOT finalization), or a `final` symlink, or a `cleanup` event in `watchdog.log` |
   | `RUN` | still producing |
   | `STALLED` | nothing written to `raw.jsonl` / `log.jsonl` / `watchdog.log` / `attempt-*/raw.jsonl` for longer than the threshold |
   | `MISSING` | the run dir is gone |

   It exits on the first status change — `RUN → STALLED` included — with `CHANGED <statuses>`; with `ALL_DONE` or `SETTLED` when nothing is left running; with `DEADLINE` when the budget expires.
````

- [ ] **Step 4: Replace point 4 of the same block in `commands/mesh-review.md`**

Replace this line:

```
4. **Repeat** until every dispatched wrapper has reported or the watch budget expires; whatever is still silent lands in Step 6.0, which classifies it mechanically. Never interpret wrapper silence as "no findings".
```

with:

```
4. **A `STALLED` or `MISSING` run is dead — send it to Step 6.0**, which classifies it mechanically, rather than waiting out the budget over a run that will never change. Do **not** re-dispatch it here: `watchdog.sh` already restarts the CLI up to twice inside the run, and Step 6.0 owns the wrapper-level retry via `max_redispatch`. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact an executor died, and the two call for different actions.
5. Drop dead runs from the list you pass to the next `"$WATCH"` invocation, and stop watching once that list is empty.
6. **Repeat** until every dispatched wrapper has reported, is dead, or the watch budget expires; whatever is still silent lands in Step 6.0. Never interpret wrapper silence as "no findings".

**An `idle_notification` from a wrapper is a free liveness check, not something to acknowledge.** Answer it with one `"$WATCH" --once <that run dir>` call and act on the row. On 2026-07-26 six notifications arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command.

> Sync note: points 1–6 are mirrored in `skills/mesh-design-review/SKILL.md` (Step 6). The watch mechanics are identical; only the routing of a dead wrapper differs (there it goes to Error Handling). When editing the mechanics, mirror the edit.
```

- [ ] **Step 5: Verify mechanically**

```bash
grep -c 'watch-runs.sh' skills/mesh-design-review/SKILL.md commands/mesh-review.md
grep -c 'WATCH_TIMEOUT' skills/mesh-design-review/SKILL.md commands/mesh-review.md
grep -n 'Sync note: points 1–6' skills/mesh-design-review/SKILL.md commands/mesh-review.md
```
Expected: at least 2 hits for `watch-runs.sh` in each file; `1` for `WATCH_TIMEOUT` in each (only the new prohibition); one sync note per file.

- [ ] **Step 6: Read both blocks side by side and confirm they agree**

Run: `sed -n '/CRITICAL — an executor.s report does NOT arrive/,/^### Step 7/p' skills/mesh-design-review/SKILL.md` and `sed -n '/CRITICAL — a wrapper.s report does NOT arrive/,/^## Step 5b/p' commands/mesh-review.md`

Confirm by reading: identical status table, identical `DEADLINE` derivation, identical `--once` rule, and that the only intended difference is where a dead run is routed (Error Handling vs Step 6.0).

- [ ] **Step 7: Commit**

```bash
git add skills/mesh-design-review/SKILL.md commands/mesh-review.md
git commit -m "fix(mesh-review,mesh-design-review): detect dead executors, do not just wait

Both watch loops defined only finalization predicates, so a dead executor
and a slow one were indistinguishable and the only backstop was an hour of
global_sec. They now call shared/watch-runs.sh, which exits on any status
change including RUN -> STALLED, and they report the death instead of
WATCH_TIMEOUT. An idle notification is now spent on a --once liveness check
rather than on acknowledging inaction.

Claude-Session: https://claude.ai/code/session_017ZE13nvHvUC2KWcEfhSHiL"
```

---

### Task 5: CHANGELOG and full verification

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the completed work of Tasks 1–4.
- Produces: nothing.

- [ ] **Step 1: Add an Unreleased section to `CHANGELOG.md`**

Insert directly after the `All notable changes to claude-mesh will be documented here.` line and the blank line following it, before `## [0.5.0] - 2026-07-27`:

```markdown
## [Unreleased]

### Fixed
- The `/mesh-review` and `/mesh-design-review` watch loops could not tell a slow
  executor from a dead one — both leave the same disk, and every finalization predicate
  was about a result *appearing*. The only backstop was `runtime.timeouts.global_sec`,
  an hour of blindness by default, and when it fired it reported `WATCH_TIMEOUT` rather
  than naming the death. A new `skills/shared/watch-runs.sh` classifies each run dir as
  `DONE` / `RUN` / `STALLED` / `MISSING` and exits on **any** status change, so a death
  now wakes the orchestrator within `runtime.timeouts.stall_sec` (default 600). Freshness
  is the newest mtime across `raw.jsonl`, `log.jsonl`, `watchdog.log` and
  `attempt-*/raw.jsonl`, so a supervised run between watchdog retries reads as `RUN` on
  its heartbeat instead of as a false death. Both prompts now call the script instead of
  describing a poll loop in prose — the improvised implementation exited only when the
  finished count grew, which death never does. An executor `idle_notification` is now
  answered with a `--once` liveness check rather than an acknowledgement.
- `/mesh-design-review` never passed `SUPERVISED_MODE`, so its executors ran unsupervised
  by default: no `shared/watchdog.sh`, no stall detection, no restart on a torn provider
  stream, and no `watchdog.log` — which is one of the three finalization predicates the
  watch loop depends on. Whether a run got a watchdog was luck (38 of 212 archived runs
  did). Step 6 now dispatches every executor with `SUPERVISED_MODE: shell`, and
  `codex-executor` / `gemini-executor` / `ext-claude-executor` document the parameter so
  it is forwarded to the skill instead of leaking into the prompt.
```

- [ ] **Step 2: Run the whole test suite**

```bash
bash skills/shared/tests/test-watch-runs.sh | tail -3
bash skills/shared/tests/test-config-loader.sh | tail -3
bash skills/shared/tests/test-verify-delegation.sh | tail -3
bash skills/shared/tests/test-loader-resolution.sh | tail -3
bash skills/shared/tests/test-extract-result.sh | tail -3
bash skills/shared/tests/test-render-template.sh | tail -3
```
Expected: every suite ends `N passed, 0 failed`. `test-config-loader.sh` must read `180 passed, 0 failed`.

- [ ] **Step 3: Confirm nothing out of scope was touched**

```bash
git diff --stat master...HEAD -- skills/shared/verify-delegation.sh
git diff --name-only master...HEAD
```
Expected: the first command prints nothing. The second lists exactly: `CHANGELOG.md`, `agents/codex-executor.md`, `agents/ext-claude-executor.md`, `agents/gemini-executor.md`, `commands/mesh-review.md`, `config.example.yaml`, `skills/mesh-design-review/SKILL.md`, `skills/shared/tests/test-watch-runs.sh`, `skills/shared/watch-runs.sh`, plus the two `docs/superpowers/` files.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): record watch-loop stall detection

Claude-Session: https://claude.ai/code/session_017ZE13nvHvUC2KWcEfhSHiL"
```

---

## Before opening a PR

Per the repository convention (`git log 326942d`), the plan and design documents must not
appear in the PR diff:

```bash
git rm docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md
git commit -m "docs: drop the plan and design documents before the PR"
```

They stay reachable in this branch's history.
