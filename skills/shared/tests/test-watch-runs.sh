#!/usr/bin/env bash
# Regression tests for watch-runs.sh
#
# watch-runs.sh answers the question neither orchestrator could answer on its own: is each
# dispatched executor finished, still working, or dead? A dead executor and a slow one leave
# the same disk — nothing changes — so the classification below is the whole point.
#
# The roster is engine[/provider/model], NOT a run dir: an executor that dies and self-retries
# creates a NEW dir, and a watcher holding the old one reports a LIVE executor dead.
#
# Reasons (stdout line 1), all exit 0:
#   CHANGED <entry> RUN→X   SETTLED <entry> RUN→X   ALL_DONE   DEADLINE   SNAPSHOT
# Usage errors exit 64.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../watch-runs.sh"
LOADER="$TESTS_DIR/../config-loader.sh"

FAIL=0
PASS=0
printf -v NOW '%(%s)T' -1
ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT

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

assert_between() {
    local desc="$1" lo="$2" hi="$3" actual="$4"
    if [[ "$actual" =~ ^[0-9]+$ ]] && [ "$actual" -ge "$lo" ] && [ "$actual" -le "$hi" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected $lo..$hi, got '$actual')"
    fi
}

# run the script; capture stdout, stderr, reason line and rc.
# The bound is not about slowness. Every call through this helper passes --once, which cannot
# block; a measured call costs ~260ms, so 10s is ~40x headroom and never fires on a healthy
# suite. It fires when a regression makes the watcher wait forever — deleting the SNAPSHOT emit
# does exactly that — and turns a suite that hangs until someone kills it into one that fails
# with rc=124. For a feature whose whole subject is unbounded silent waiting, that is the
# failure mode its own tests have to have. Keep the bound tight enough that 24 blocked calls
# still finish in minutes. Tests 25-27 bound themselves; they do not go through run().
run() { OUT="$(timeout 10 bash "$SCRIPT" "$@" 2>"$ERRF")"; RC=$?; REASON="$(printf '%s\n' "$OUT" | head -1)"; ERR="$(cat "$ERRF")"; }
# the rendered row for a roster entry. Line 1 is the reason line and it names entries too,
# so it must be skipped — otherwise every row assertion silently matches the reason instead.
row() { printf '%s\n' "$OUT" | tail -n +2 | grep -F " $1 " | head -1; }
# the numeric quiet= value out of a row
quiet_of() { printf '%s\n' "$1" | sed -n 's/.*quiet=\([0-9]*\)s.*/\1/p'; }

# a run dir NAME stamped <offset> seconds from now, with an optional pid suffix
stamp() { printf '%(%Y-%m-%d-%H-%M-%S)T-%s' "$(( NOW + ${1:-0} ))" "${2:-100000}"; }
# mk_run <data-dir> <entry> [name-offset-sec] [pid] [name-suffix] → prints the created dir
mk_run() {
    local d="$1/runs/$2/$(stamp "${3:-0}" "${4:-100000}")${5:-}"
    mkdir -p "$d"; printf '%s' "$d"
}
# a watchdog.log holding one cleanup event with the given exit code
wd_log() { printf '{"ts":"x","event":"cleanup","attempt":1,"details":{"exit_code":%s}}\n' "$2" > "$1/watchdog.log"; }

SINCE_OK=$(( NOW - 300 ))    # inside the MISSING grace when --stall-sec is 600
SINCE_OLD=$(( NOW - 900 ))   # past the grace

# === Test 1: finished with output → DONE, and a single-entry roster → ALL_DONE ===
echo "=== Test 1: finished with output → DONE → ALL_DONE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "row is DONE" "DONE" "$(row codex)"
assert_match "row names the resolved dir" "$(basename "$a")" "$(row codex)"
rm -rf "$TDIR"

# === Test 2: bailed run → FAILED with the watchdog.exit reason ===
# watchdog.sh bail() creates `final` and the EXIT trap writes `cleanup`, so a run where every
# attempt failed looks finalized. Across 286 archived logs cleanup appears in 286 and complete
# in 246 — cleanup alone says "it stopped", never "it worked".
echo "=== Test 2: bailed run → FAILED with reason ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" gemini -60); mkdir -p "$a/attempt-2"; ln -s attempt-2 "$a/final"
wd_log "$a" 2
printf '{\n  "reason": "all_attempts_failed",\n  "attempts": 3\n}\n' > "$a/watchdog.exit"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" gemini
assert_eq "reason names the transition" "SETTLED gemini RUN→FAILED" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "row is FAILED" "FAILED" "$(row gemini)"
assert_match "row carries the bail reason" "all_attempts_failed" "$(row gemini)"
rm -rf "$TDIR"

# === Test 3: killed watchdog, nothing on disk → FAILED ===
echo "=== Test 3: cleanup exit_code 143, no output → FAILED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 143
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is FAILED" "FAILED" "$(row codex)"
rm -rf "$TDIR"

# === Test 4: rc 0 with nothing to read — the extraction window vs a real failure ===
# watchdog.sh never writes output.txt: the *-exec skill extracts it from raw.jsonl AFTER the
# watchdog returns, 0-33s later across 249 archived successful runs. The fixture that used to
# live here asserted FAILED on exactly that window, so it blessed a false FAILED — and design
# review's failure path never re-dispatches, which makes such a loss permanent. rc=0 alone is
# still not proof there is anything to read, so the FAILED verdict survives; it just waits.
echo "=== Test 4a: cleanup exit_code 0, output.txt not extracted yet → RUN ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; : > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

echo "=== Test 4b: cleanup exit_code 0, still no output.txt past the settle window → FAILED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -600); wd_log "$a" 0; : > "$a/output.txt"
touch -d '10 minutes ago' "$a/watchdog.log" "$a/output.txt" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is FAILED" "FAILED" "$(row codex)"
assert_match "row says why" "no output.txt" "$(row codex)"
rm -rf "$TDIR"

# === Test 5: unsupervised finish → DONE ===
echo "=== Test 5: no watchdog.log, non-empty output.txt → DONE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/zai/glm -60); echo 'review' > "$a/output.txt"; echo '# report' > "$a/report.md"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" ext-claude/zai/glm
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_match "row is DONE" "DONE" "$(row ext-claude/zai/glm)"
rm -rf "$TDIR"

# === Test 6: gemini's pre-created zero-byte output.txt is NOT finalization ===
echo "=== Test 6: zero-byte output.txt → RUN ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" gemini -60); : > "$a/output.txt"; : > "$a/log.jsonl"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" gemini
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row gemini)"
rm -rf "$TDIR"

# === Test 7: REGRESSION — a watchdog heartbeat keeps a retrying run alive ===
# This is what makes SUPERVISED_MODE=shell safe to enable. Under supervision the CLI writes
# attempt-N/raw.jsonl and root raw.jsonl appears only at the end, so between watchdog retries
# the root stream looks long dead. The `alive` heartbeat is the proof of life; without folding
# watchdog.log into the freshness set, every supervised retry would be reported as a death.
echo "=== Test 7: REGRESSION — watchdog heartbeat keeps a retrying run alive ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/deepseek/v4-pro -60)
: > "$a/raw.jsonl"; touch -d '30 minutes ago' "$a/raw.jsonl"
printf '{"ts":"x","event":"alive","attempt":2,"details":{"event_count":7,"age_sec":3}}\n' > "$a/watchdog.log"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" ext-claude/deepseek/v4-pro
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN, not SILENT" "RUN" "$(row ext-claude/deepseek/v4-pro)"
rm -rf "$TDIR"

# === Test 8: supervised layout — attempt-1/raw.jsonl is the live stream ===
echo "=== Test 8: attempt-1/raw.jsonl is the live stream ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); mkdir -p "$a/attempt-1"; : > "$a/attempt-1/raw.jsonl"
touch -d '30 minutes ago' "$a"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

# === Test 9: log.jsonl alone is a valid freshness source ===
# A codex default-mode run has no raw.jsonl at all.
echo "=== Test 9: log.jsonl as the only freshness source ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/log.jsonl"; touch -d '30 minutes ago' "$a"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

# === Test 10: stale stream → SILENT with a correct quiet value and a last stamp ===
echo "=== Test 10: stale stream → SILENT with quiet and last ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/ollama/kimi -700)
: > "$a/raw.jsonl"; touch -d '660 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/ollama/kimi
assert_eq "reason names the transition" "SETTLED ext-claude/ollama/kimi RUN→SILENT" "$REASON"
assert_match "row is SILENT" "SILENT" "$(row ext-claude/ollama/kimi)"
assert_between "quiet is ~660s" 655 675 "$(quiet_of "$(row ext-claude/ollama/kimi)")"
assert_match "row carries last=" "last=" "$(row ext-claude/ollama/kimi)"
rm -rf "$TDIR"

# === Test 11: threshold neighbourhood ===
# The exact `quiet == stall_sec` boundary is not asserted: a one-second clock tick between
# `touch` and the script's own `now` would flip it, and the difference is immaterial. What is
# asserted is that 600 is a threshold at all — just below stays RUN, just above turns SILENT.
echo "=== Test 11: threshold neighbourhood ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -700); : > "$a/raw.jsonl"; touch -d '590 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "590s quiet is still RUN" "RUN" "$(row codex)"
touch -d '615 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "615s quiet is SILENT" "SILENT" "$(row codex)"
rm -rf "$TDIR"

# === Test 12: an executor that has not created its dir yet is RUN, not dead ===
echo "=== Test 12: no run dir inside the grace → RUN ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

# === Test 13: past the grace, a missing dir is MISSING ===
echo "=== Test 13: no run dir past the grace → MISSING ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason names the transition" "SETTLED codex RUN→MISSING" "$REASON"
assert_match "row is MISSING" "MISSING" "$(row codex)"
rm -rf "$TDIR"

# === Test 14: a roster typo is diagnosable, not a silent permanent MISSING ===
echo "=== Test 14: unknown roster entry warns on stderr ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/zia/glm
assert_match "row is MISSING" "MISSING" "$(row ext-claude/zia/glm)"
assert_match "stderr names the missing base" "ext-claude/zia/glm" "$ERR"
rm -rf "$TDIR"

# === Test 15: RETRY — a self-retry into a new dir is followed, the abandoned one ignored ===
# Observed four times on 2026-07-27: executors died unsupervised and re-ran into fresh dirs.
# A watcher holding the first dir would have reported four LIVE executors dead.
echo "=== Test 15: RETRY — the newer dir is watched, including a different suffix ==="
TDIR=$(mktemp -d)
old=$(mk_run "$TDIR" ext-claude/alibaba/qwen -600 2060029)
: > "$old/raw.jsonl"; touch -d '660 seconds ago' "$old/raw.jsonl" "$old"
new=$(mk_run "$TDIR" ext-claude/alibaba/qwen -60 2135662 '-retry')
: > "$new/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/alibaba/qwen
assert_match "row is RUN, not SILENT" "RUN" "$(row ext-claude/alibaba/qwen)"
assert_match "row names the retry dir" "$(basename "$new")" "$(row ext-claude/alibaba/qwen)"
rm -rf "$TDIR"

# === Test 16: a dir created before --since is not selected ===
echo "=== Test 16: a pre-window dir is not selected ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -5000); : > "$a/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is MISSING" "MISSING" "$(row codex)"
rm -rf "$TDIR"

# === Test 17: selection is by name, not by mtime ===
# On bail the abandoned dir gets a `final` symlink, which bumps its mtime above the retry dir's.
# Selecting by mtime would then follow the corpse.
echo "=== Test 17: a late write to the abandoned dir does not outrank the retry ==="
TDIR=$(mktemp -d)
old=$(mk_run "$TDIR" gemini -600 111); : > "$old/raw.jsonl"
new=$(mk_run "$TDIR" gemini -60 222); : > "$new/raw.jsonl"
touch -d '30 minutes ago' "$new"
touch "$old"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" gemini
assert_match "the newer NAME is selected" "$(basename "$new")" "$(row gemini)"
rm -rf "$TDIR"

# === Test 18: a data dir path containing a space ===
echo "=== Test 18: a path with a space ==="
TDIR=$(mktemp -d "${TMPDIR:-/tmp}/watch runs XXXXXX")
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
rm -rf "$TDIR"

# === Test 19: MIXED roster — only what moved is named ===
# The suite that shipped with the previous draft passed 36/36 both before and after a real
# reason-line bug, because no test ever had one entry already terminal while another moved.
echo "=== Test 19: mixed roster names only the entry that moved ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
b=$(mk_run "$TDIR" ext-claude/zai/glm -60); : > "$b/raw.jsonl"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex ext-claude/zai/glm
assert_eq "reason names only codex" "CHANGED codex RUN→DONE" "$REASON"
assert_match "codex row is DONE" "DONE" "$(row codex)"
assert_match "glm row is RUN" "RUN" "$(row ext-claude/zai/glm)"
rm -rf "$TDIR"

# === Test 20: two entries moving at once are both named ===
echo "=== Test 20: two transitions in one evaluation ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
b=$(mk_run "$TDIR" ext-claude/ollama/kimi -700)
: > "$b/raw.jsonl"; touch -d '660 seconds ago' "$b/raw.jsonl" "$b"
c=$(mk_run "$TDIR" ext-claude/zai/glm -60); : > "$c/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex ext-claude/ollama/kimi ext-claude/zai/glm
assert_eq "both transitions named, in roster order" \
    "CHANGED codex RUN→DONE, ext-claude/ollama/kimi RUN→SILENT" "$REASON"
rm -rf "$TDIR"

# === Test 21: --once over an already-silent roster reports CHANGED, not SNAPSHOT ===
# This is what makes a one-shot liveness check worth running when an executor pings: the answer
# names the death instead of handing back a table to diff by eye.
echo "=== Test 21: --once with an already-silent entry → CHANGED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/ollama/kimi -700)
: > "$a/raw.jsonl"; touch -d '660 seconds ago' "$a/raw.jsonl" "$a"
b=$(mk_run "$TDIR" ext-claude/zai/glm -60); : > "$b/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/ollama/kimi ext-claude/zai/glm
assert_eq "reason CHANGED" "CHANGED ext-claude/ollama/kimi RUN→SILENT" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 22: --once with everything running → SNAPSHOT ===
echo "=== Test 22: --once with everything running → SNAPSHOT ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
b=$(mk_run "$TDIR" gemini -60); : > "$b/log.jsonl"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex gemini
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 23: the stall threshold is floored at 600 and says so ===
# codex-exec and gemini-exec hardcode HARD_ZERO_TIMEOUT=600, so a lower watcher threshold would
# call a live run silent 300s before its own watchdog would act on it.
echo "=== Test 23: --stall-sec below 600 is floored, with a warning ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -700); : > "$a/raw.jsonl"; touch -d '300 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 120 --data-dir "$TDIR" codex
assert_match "300s quiet stays RUN under the floor" "RUN" "$(row codex)"
assert_match "stderr announces the floor" "600" "$ERR"
rm -rf "$TDIR"

# === Test 24: usage errors ===
echo "=== Test 24: usage errors exit 64 ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "missing --since → 64" "64" "$RC"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR"
assert_eq "empty roster → 64" "64" "$RC"
run --once --since 3900 --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "a 1970 --since → 64" "64" "$RC"
assert_match "and it names the likely cause" "DISPATCH_EPOCH" "$ERR"
run --once --since "$SINCE_OK" --stall-sec abc --data-dir "$TDIR" codex
assert_eq "non-numeric --stall-sec → 64" "64" "$RC"
run --once --since "$SINCE_OK" --poll-sec 0 --data-dir "$TDIR" codex
assert_eq "--poll-sec 0 → 64" "64" "$RC"
# --stall-sec swallowing the next flag used to make the script block forever
run --since "$SINCE_OK" --data-dir "$TDIR" --stall-sec --once codex
assert_eq "--stall-sec eating --once → 64" "64" "$RC"
rm -rf "$TDIR"

# The deadline is computed inside the script as --since + global_sec + margin, so these tests
# steer it by choosing --since. global_sec comes from the real config; read it the same way.
GS="$(bash "$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.global_sec // empty' 2>/dev/null)"
[[ "$GS" =~ ^[1-9][0-9]*$ ]] || GS=3600
MARGIN=300

if [ "$GS" -gt 80000 ]; then
    FAIL=$((FAIL+1))
    echo "  FAIL: runtime.timeouts.global_sec=$GS leaves no room inside the --since plausibility window; Tests 25-27 cannot run"
else

# === Test 25: the watcher blocks while everything is RUN, and returns when one goes silent ===
# The 2026-07-26 blind spot: nothing finishes, so a count-based watcher never wakes. There is no
# race with the baseline here — the baseline is virtual, so a change landing before the first
# evaluation is reported just the same.
echo "=== Test 25: a run going quiet wakes the watcher ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
b=$(mk_run "$TDIR" ext-claude/ollama/kimi -60); : > "$b/raw.jsonl"
( sleep 2; touch -d '660 seconds ago' "$b/raw.jsonl" "$b" ) &
TOUCHER=$!
START=$(date +%s)
OUT="$(timeout 30 bash "$SCRIPT" --since "$SINCE_OK" --stall-sec 600 --poll-sec 1 \
        --data-dir "$TDIR" codex ext-claude/ollama/kimi 2>"$ERRF")"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
wait "$TOUCHER" 2>/dev/null
REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason names the death" "CHANGED ext-claude/ollama/kimi RUN→SILENT" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "codex row still RUN" "RUN" "$(row codex)"
assert_between "it waited for the change" 2 20 "$ELAPSED"
rm -rf "$TDIR"

# === Test 26: an expired budget reports DEADLINE ===
echo "=== Test 26: an expired budget reports DEADLINE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
OUT="$(timeout 15 bash "$SCRIPT" --since "$(( NOW - GS - MARGIN - 100 ))" --stall-sec 600 \
        --poll-sec 1 --data-dir "$TDIR" codex 2>"$ERRF")"
RC=$?
REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason DEADLINE" "DEADLINE" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 27: the watcher really blocks rather than returning at once ===
echo "=== Test 27: the watcher blocks until its deadline ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
# NOW was stamped when the suite started and the suite takes seconds to get here; a deadline
# eight seconds past a stale NOW is already behind us. Re-read the clock.
printf -v T27_NOW '%(%s)T' -1
START=$(date +%s)
OUT="$(timeout 40 bash "$SCRIPT" --since "$(( T27_NOW - GS - MARGIN + 8 ))" --stall-sec 600 \
        --poll-sec 1 --data-dir "$TDIR" codex 2>"$ERRF")"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason DEADLINE" "DEADLINE" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_between "it blocked for roughly the remaining budget" 4 30 "$ELAPSED"
rm -rf "$TDIR"

fi

# --- roster and run-dir shape -------------------------------------------------------------
# A name that is not a timestamp sorts ABOVE every timestamp, so without a shape filter one
# stray directory shadows its roster entry permanently — every finished run under it reads
# SILENT, forever. That is the silent blindness this whole script exists to remove.

echo ""
echo "Test 28: a non-timestamp directory beside a finished run does not shadow it"
TDIR="$(mktemp -d)"
A="$(mk_run "$TDIR" codex)"
wd_log "$A" 0; printf 'findings\n' > "$A/output.txt"
mkdir -p "$TDIR/runs/codex/tmp"
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" codex
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_match "codex is still DONE" "DONE" "$(row codex)"
rm -rf "$TDIR"

echo ""
echo "Test 29: a bare entry whose base holds only provider dirs is MISSING, not a provider dir"
TDIR="$(mktemp -d)"
mk_run "$TDIR" ext-claude/zai/glm >/dev/null
run --since "$SINCE_OLD" --stall-sec 600 --once --data-dir "$TDIR" ext-claude
assert_eq "reason SETTLED RUN→MISSING" "SETTLED ext-claude RUN→MISSING" "$REASON"
assert_match "ext-claude is MISSING" "MISSING" "$(row ext-claude)"
rm -rf "$TDIR"

echo ""
echo "Test 30: a roster entry containing '..' is a usage error"
TDIR="$(mktemp -d)"; mkdir -p "$TDIR/runs"
run --since "$SINCE_OK" --once --data-dir "$TDIR" 'ext-claude/zai/..'
assert_eq "exit 64" "64" "$RC"
assert_match "stderr names the entry" "invalid roster entry" "$ERR"
rm -rf "$TDIR"

echo ""
echo "Test 31: an empty roster entry is a usage error, not a watch of runs/ itself"
TDIR="$(mktemp -d)"; mkdir -p "$TDIR/runs"
run --since "$SINCE_OK" --once --data-dir "$TDIR" ''
assert_eq "exit 64" "64" "$RC"
assert_match "stderr names the entry" "invalid roster entry" "$ERR"
rm -rf "$TDIR"

# --- the unsupervised branch: a non-empty output.txt is not a finish ----------------------
# gemini-exec appends to output.txt INSIDE its stream-reading loop, so the file goes non-empty
# seconds after launch. Treating "no watchdog.log + non-empty output.txt" as terminal reported
# a live run DONE, and the orchestrator then pinged its executor for a half-written review —
# the one failure mode here that corrupts the merged result instead of losing it.

echo ""
echo "Test 32: an unsupervised run still streaming into output.txt is RUN, not DONE"
TDIR="$(mktemp -d)"
a=$(mk_run "$TDIR" gemini -60)
printf 'partial answer so far' > "$a/output.txt"
: > "$a/log.jsonl"
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" gemini
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row gemini)"
rm -rf "$TDIR"

echo ""
echo "Test 33: report.md is the stop signal — the same run with it present is DONE"
TDIR="$(mktemp -d)"
a=$(mk_run "$TDIR" gemini -60)
printf 'full answer' > "$a/output.txt"; : > "$a/log.jsonl"; printf '# report\n' > "$a/report.md"
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" gemini
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_match "row is DONE" "DONE" "$(row gemini)"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
