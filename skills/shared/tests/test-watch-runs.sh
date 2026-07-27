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

# run the script; capture stdout, stderr, reason line and rc
run() { OUT="$(bash "$SCRIPT" "$@" 2>"$ERRF")"; RC=$?; REASON="$(printf '%s\n' "$OUT" | head -1)"; ERR="$(cat "$ERRF")"; }
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

# === Test 4: rc 0 but empty output.txt → FAILED ===
# codex-exec/gemini-exec "leave empty" when extraction finds nothing, so rc=0 alone is not proof
# that there is anything to read. DONE must mean the orchestrator's next action can succeed.
echo "=== Test 4: cleanup exit_code 0 but empty output.txt → FAILED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; : > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is FAILED" "FAILED" "$(row codex)"
rm -rf "$TDIR"

# === Test 5: unsupervised finish → DONE ===
echo "=== Test 5: no watchdog.log, non-empty output.txt → DONE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/zai/glm -60); echo 'review' > "$a/output.txt"
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

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
