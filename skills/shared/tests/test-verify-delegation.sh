#!/usr/bin/env bash
# Regression tests for verify-delegation.sh
#
# verify-delegation.sh classifies whether a wrapper reviewer (ext-claude / codex /
# gemini) actually DELEGATED to its external engine and produced a REAL review, vs
# self-reviewed on the session model (FLIP), died on its own (STALLED), was terminated
# from outside (KILLED), or got an engine-broken empty/thinking-only result (BROKEN).
#
# Verdicts (stdout) + exit codes:
#   REAL=0  FLIP=3  STALLED=2  BROKEN=4  DEGRADED=5  KILLED=6
#
# Criteria are derived from real run-dir fixtures observed on 2026-05-30:
#   REAL    (kimi):     final symlink + result num_turns>1 + non-empty output.txt
#   BROKEN  (deepseek): finalized + num_turns<=1 — model did no agentic work, regardless
#                       of HOW it surfaces (empty output / thinking-only / DSML grammar)
#   STALLED (glm kill): no final / no result event / engine rc!=0 (killed — retry helps)
#   FLIP    (codex):    no run-dir at all under runs/<engine>/...
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../verify-delegation.sh"

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

# The reason line is prose an orchestrator relays verbatim, so a wrong CLAIM in it is a defect
# even when the verdict is right: the SIGINT case must not be told the Bash cap killed it.
assert_no_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) FAIL=$((FAIL+1)); echo "  FAIL: $desc ('$pattern' present in '$actual')" ;;
        *) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
    esac
}

# run the script and capture verdict + rc. REASON is cleared, not left over: without this a
# stale reason from an earlier run_full survives into the next test and an assertion on it
# passes against the previous case's string.
run() { VERDICT=$(bash "$SCRIPT" "$@" 2>/dev/null); RC=$?; REASON=""; }

# same, but also keep the reason line from stderr in $REASON — the DEGRADED tests assert on
# the denial count it carries, which is the whole point of that verdict.
run_full() {
    local errf; errf=$(mktemp)
    VERDICT=$(bash "$SCRIPT" "$@" 2>"$errf"); RC=$?
    REASON=$(cat "$errf" 2>/dev/null); rm -f "$errf"
}

# The denial count $REASON carries, as a bare number ('' when it names none). assert_match is a
# substring glob, so a "1 tool call(s)" pattern also matches "21 tool call(s)" — the count is
# the entire content of a DEGRADED verdict, so pull it out and compare it exactly.
reason_count() { printf '%s' "$REASON" | grep -o '[0-9]\+ tool call(s)' | grep -o '^[0-9]\+'; }

# run the script under an explicit session identity: <sid>, or '-' for no identity at all.
# The assignment prefixes the EXTERNAL command; a prefix on a function call would leak into
# the rest of the suite.
run_as() {
    local sid="$1"; shift
    if [ "$sid" = "-" ]; then
        VERDICT=$(env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" "$@" 2>/dev/null); RC=$?
    else
        VERDICT=$(env "CLAUDE_CODE_SESSION_ID=$sid" bash "$SCRIPT" "$@" 2>/dev/null); RC=$?
    fi
}
# stamp a run dir with a session id
sid_stamp() { printf '%s\n' "$2" > "$1/.session_id"; }

# --- helpers to build run dirs ---
# $1 base dir (e.g. $TDIR/runs/ext-claude/zai/glm), $2 run name
mk_run() { mkdir -p "$1/$2/attempt-1"; echo "$1/$2"; }

# An output.txt that stands for a DELIVERED REVIEW. A bare `echo findings` used to do, because
# REAL asked only that the file be non-blank; it no longer is — a run that delivers a one-line
# notice now scores STALLED (see the review-floor tests at the bottom). So every fixture whose
# subject is a review that ARRIVED has to be long enough to be one, while the fixtures that test
# emptiness, torn streams or leaked tool grammar keep writing exactly what they mean.
# The headline argument keeps each test's output recognisable in a failure message.
mk_output() {   # mk_output <file> [headline]
    { printf '%s\n' "${2:-### Findings}"
      for i in 1 2 3 4 5; do
          printf -- '- storage/RecoveryOrderRepositoryImpl.java:%d — the CAS retry drops the audit stamp when the version check loses a race.\n' "$i"
      done; } > "$1"
}

# === Test 1: FLIP — no run-dir under the engine path ===
echo "=== Test 1: ext-claude FLIP (no run dir) ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/runs/ext-claude/zai/glm"   # base exists but EMPTY (no run dir)
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test 2: FLIP — run-dir exists but older than since-epoch ===
echo "=== Test 2: ext-claude FLIP (run-dir older than since) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-old)
mk_output "$rd/output.txt" 'review'; ln -s attempt-1 "$rd/final"
run ext-claude zai/glm 9999999999 "$TDIR"   # since far in the future
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test 3: STALLED — killed mid-flight (no final, no root output.txt) ===
echo "=== Test 3: ext-claude STALLED (killed, no final/output) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-kill)
# only the in-progress attempt log exists; no final symlink, no root output.txt
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/attempt-1/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 4: BROKEN — finalized, output.txt empty, num_turns<=1 (deepseek-after-revert) ===
# Post thinking-fallback revert, an engine-broken run leaves output.txt EMPTY (no DSML junk
# to grep). num_turns=1 from the result event still proves the model did no agentic work →
# BROKEN (drop, do not retry), NOT STALLED (which would trigger a futile re-dispatch).
echo "=== Test 4: ext-claude BROKEN (finalized, empty output, num_turns 1) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-empty)
: > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 5: BROKEN — DSML thinking-fallback garbage (num_turns==1) ===
echo "=== Test 5: ext-claude BROKEN (DSML + num_turns 1) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/deepseek" 2026-07-28-11-00-00-1000-broken)
printf "I'll start by examining the diff.\n<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"Bash\">\n" > "$rd/output.txt"
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run ext-claude ollama/deepseek 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 6: BROKEN — non-agentic (num_turns==1, no DSML) ===
echo "=== Test 6: ext-claude BROKEN (num_turns 1, plain text) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-1turn)
mk_output "$rd/output.txt" 'Looks fine to me, no issues.'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 7: REAL — ext-claude delegated, agentic review ===
echo "=== Test 7: ext-claude REAL (num_turns 46) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi" 2026-07-28-11-00-00-1000-real)
mk_output "$rd/output.txt" '### Strengths
- connection.py singleton cold-start race is properly guarded.'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":46}' > "$rd/raw.jsonl"
run ext-claude ollama/kimi 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 8: REAL — codex delegated (watchdog_rc=0, agentic stream) ===
echo "=== Test 8: codex REAL (.watchdog_rc=0) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-codex-ok)
mk_output "$rd/output.txt" 'I reviewed the diff; here are the findings...'
ln -s attempt-1 "$rd/final"; echo 0 > "$rd/.watchdog_rc"
printf '{"type":"command_execution"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
run codex - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 9: STALLED — codex run-dir, non-empty output, but watchdog_rc != 0 ===
# (non-empty output so this exercises the codex rc-branch, not the empty-output branch)
echo "=== Test 9: codex STALLED (.watchdog_rc=124) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-codex-kill)
mk_output "$rd/output.txt" 'partial findings before kill...'; echo 124 > "$rd/.watchdog_rc"
run codex - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 10: FLIP — codex no run-dir at all ===
echo "=== Test 10: codex FLIP (no runs/codex) ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/runs"   # no codex/ subdir
run codex - 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test 11: STALLED — ext-claude finalized but raw.jsonl has NO result event (cut off) ===
echo "=== Test 11: ext-claude STALLED (no result event) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-noresult)
mk_output "$rd/output.txt" 'partial output'; ln -s attempt-1 "$rd/final"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 12: STALLED — ext-claude agentic (num_turns>1) but output.txt empty ===
echo "=== Test 12: ext-claude STALLED (num_turns 5, empty output) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-agentic-empty)
: > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":5}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 13: REAL — stream carries TWO result events (background subagent) ===
# When the external model dispatches a background subagent it first answers "started", the
# session then resumes and delivers the real review; progress-monitor.sh appends BOTH
# segments to one raw.jsonl. The LAST result then describes only the short closing segment
# (num_turns:1) while the agentic work sits in the first (num_turns:5). Classify on the
# MAXIMUM across result events — taking the last one drops a genuine review as BROKEN,
# and BROKEN is the one verdict mesh-review never retries.
echo "=== Test 13: ext-claude REAL (two result events, num_turns 5 then 1) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/deepseek/v4-pro" 2026-07-28-11-00-00-1000-multiresult)
mk_output "$rd/output.txt" '## Code Review
- Critical: connection leak in pool.py:42'
ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":5,"result":"Review launched in background via subagent code-reviewer."}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"Review complete. Here are the results..."}'
} > "$rd/raw.jsonl"
run ext-claude deepseek/v4-pro 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 14: BROKEN — two result events, BOTH non-agentic ===
# Guard on the aggregation choice made in Test 13. Every existing single-event fixture
# passes under max AND under sum (n == max(n) == sum(n)), so only a multi-segment stream
# tells them apart: summing 1+1 would fake a REAL out of a run that never read any code.
echo "=== Test 14: ext-claude BROKEN (two result events, num_turns 1 and 1) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/deepseek" 2026-07-28-11-00-00-1000-multibroken)
mk_output "$rd/output.txt" 'Looks fine to me, no issues.'
ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}'
} > "$rd/raw.jsonl"
run ext-claude ollama/deepseek 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 15: STALLED — result events present but none carries num_turns ===
# `sort -n | tail -1` must not turn "no usable num_turns" into a number: an empty scan
# still has to fall through to the no-result-event branch, not be read as 0 (BROKEN).
echo "=== Test 15: ext-claude STALLED (result events without num_turns) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-noturns)
mk_output "$rd/output.txt" 'partial output'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"error_during_execution","is_error":true}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 16: REAL — a truncated result line must not swallow the scan ===
# raw.jsonl is appended live, so a killed stream leaves its LAST line cut mid-string
# (observed in a real run dir). Fixture order matters: the truncated line goes at the END,
# which is where truncation actually happens and which is what discriminates the fix —
# `tail -1 | jq` would land on the cut line and yield nothing (STALLED), while scanning all
# lines finds the 12. Reading each line as a raw string (`jq -R`) is what survives the bad
# line; a bare `jq` parsing the stream as JSON aborts on it. (`fromjson?` is belt-and-braces:
# on jq 1.7 `-R` alone already tolerates it, verdict and exit status unchanged either way.)
echo "=== Test 16: ext-claude REAL (valid result before a truncated line) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/alibaba/qwen" 2026-07-28-11-00-00-1000-truncated)
mk_output "$rd/output.txt" 'Frontend reviewed. Critical findings: ...'
ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12}'
  echo '{"type":"result","subtype":"success","is_error":false,"result":"cut off mid-str'
} > "$rd/raw.jsonl"
run ext-claude alibaba/qwen 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 17: STALLED — the only result event is an engine error ===
# Real shape, found in 5 historical run dirs: {"subtype":"success","is_error":true,
# "num_turns":95,"result":"Prompt is too long"}. subtype says success, is_error says
# otherwise — is_error is the signal. Both `tail -1` and a naive max elect 95 and call the
# string "Prompt is too long" a REAL cross-validation. Errored events must not count.
echo "=== Test 17: ext-claude STALLED (single is_error result, num_turns 95) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi" 2026-07-28-11-00-00-1000-prompt-too-long)
mk_output "$rd/output.txt" 'Prompt is too long'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":true,"num_turns":95,"result":"Prompt is too long"}' > "$rd/raw.jsonl"
run ext-claude ollama/kimi 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 18: BROKEN — a failed segment must not lend its turns to a non-agentic one ===
# error(95) followed by success(1): the max must be taken over SUCCESSFUL events only, so
# the run is judged on its one real segment (1) — not promoted to REAL by the failure's 95.
echo "=== Test 18: ext-claude BROKEN (is_error 95 then success 1) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-err-then-weak)
mk_output "$rd/output.txt" 'Looks fine to me.'; ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":true,"num_turns":95,"result":"Prompt is too long"}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"Looks fine to me."}'
} > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 19: STALLED — agentic first segment, but the FINAL segment errored ===
# progress-monitor.sh:171-175 REWRITES output.txt from every result event, so the delivered
# text is the last segment's. When that segment failed, the review is gone however agentic
# the earlier ones were — and `[ -s ]` alone would pass the lone "\n" it leaves behind.
echo "=== Test 19: ext-claude STALLED (success 12 then is_error, 1-byte output) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-final-error)
printf '\n' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12,"result":"full review"}'
  echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1}'
} > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 20: STALLED — num_turns present but not a usable integer ===
# `[ "$NT" -le 1 ] 2>/dev/null` errors on a non-number, the error is swallowed, the `if`
# reads false and the run falls through to REAL. Nothing may reach that test but an integer.
echo "=== Test 20: ext-claude STALLED (non-integer num_turns only) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-bogus-turns)
mk_output "$rd/output.txt" 'some text'; ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":"bogus"}'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1.5}'
} > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 21: STALLED — agentic, but output.txt holds only whitespace ===
# `[ -s ]` is a size test: a file of one newline passes it and the blank "review" would
# reach dedupe. Require actual content.
echo "=== Test 21: ext-claude STALLED (num_turns 9, whitespace-only output) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-blank-output)
printf '\n  \n' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test: the winner is the newest run dir by NAME, not by mtime ===
# mesh-design-review chains watch-runs.sh and this script on the same run. watch-runs.sh picks
# by name; picking by mtime here made them disagree, because on bail an abandoned dir gains a
# `final` symlink that lifts its mtime above the retry dir that superseded it. The watcher then
# reported DONE on the retry while this script reported STALLED on the corpse, and the caller
# is told to treat STALLED as a dead executor — discarding a finished review.
echo "=== Test: newest by name wins over a later-touched abandoned dir ==="
TDIR=$(mktemp -d)
BASE="$TDIR/runs/ext-claude/zai/glm"
abandoned=$(mk_run "$BASE" 2026-07-28-11-00-00-1000-task)
retry=$(mk_run "$BASE" 2026-07-28-11-05-00-2000-task-retry)
printf '{"type":"result","num_turns":20,"is_error":false}\n' > "$retry/raw.jsonl"
mk_output "$retry/output.txt" 'review'; ln -s attempt-1 "$retry/final"
touch -d '2026-07-28 11:06:00' "$retry"
touch -d '2026-07-28 11:20:00' "$abandoned"     # the corpse is touched LAST
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL (the retry, not the corpse)" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: codex narration-only output is BROKEN, not REAL ===
# This branch used to check `.watchdog_rc` — which nothing under skills/ writes — and then only
# that output.txt was non-empty, so it confirmed what the caller already knew. The 47429-byte
# narration draft that motivated the gate would have passed it for codex and gemini.
echo "=== Test: codex terminal event with no tool call → BROKEN ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-task)
printf 'Проведу ревью документов… Начну с чтения.\n' > "$rd/output.txt"
printf '{"type":"thread.started"}\n{"type":"agent_message"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
run codex - 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test: codex stream without a terminal event is STALLED ===
echo "=== Test: codex stream cut off mid-flight → STALLED ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'partial'
printf '{"type":"thread.started"}\n{"type":"command_execution"}\n' > "$rd/raw.jsonl"
run codex - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test: a real codex run still passes ===
echo "=== Test: codex with a terminal event and tool calls → REAL ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'findings'
printf '{"type":"command_execution"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
run codex - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# --- run-dir shape: only timestamp-named children are candidates --------------------------
# watch-runs.sh:189 filters candidates to the zero-padded timestamp shape; this script picks
# the winner from the same tree and must agree, or the pair disagrees about which run is
# "the run" — the exact class of defect the name-over-mtime fix above removed. In LC_ALL=C
# letters sort above digits, so any non-timestamp name outranks every real run.

# === Test: a stray non-timestamp dir does not shadow the real codex run ===
echo "=== Test: stray runs/codex/tmp beside a finished run → still REAL ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'findings'
printf '{"type":"command_execution"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
mkdir -p "$TDIR/runs/codex/tmp"
run codex - 1 "$TDIR"
assert_eq "verdict REAL (not the stray dir)" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: a truncated model argument yields FLIP, not STALLED ===
# `ext-claude zai` (model half lost) makes $BASE the PROVIDER directory; its children are
# model dirs, not run dirs. Unfiltered, the newest child is inspected as if it were a run —
# no final, no output.txt — and the verdict is STALLED, which the prompts treat as terminal.
# Filtered, there is no candidate at all and the verdict is FLIP, the one verdict the
# prompts explicitly say to re-check against the engine/model arguments.
echo "=== Test: ext-claude with a truncated model argument → FLIP ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'review'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9}' > "$rd/raw.jsonl"
run ext-claude zai 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# --- gemini result status: an errored engine must not pass as REAL ------------------------
# gemini can exit 0 while reporting an API failure as a result event with status!="success";
# gemini-exec's own extraction then writes "API Error: …" into output.txt
# (skills/gemini-exec/SKILL.md:350-357), so every other signal this branch checks looks
# healthy: cleanup exit 0, non-empty output, a terminal event, tool calls before the failure.

# === Test: gemini error-status result → STALLED ===
echo "=== Test: gemini result status:error → STALLED ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/gemini" 2026-07-28-11-00-00-1000-task)
printf 'API Error: 401 unauthorized\n' > "$rd/output.txt"
printf '{"type":"tool_use","name":"read_file"}\n{"type":"result","status":"error"}\n' > "$rd/raw.jsonl"
run gemini - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test: gemini success-status result stays REAL ===
echo "=== Test: gemini result status:success → REAL ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/gemini" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'findings'
printf '{"type":"tool_use","name":"read_file"}\n{"type":"result","status":"success","stats":{"duration_ms":8100}}\n' > "$rd/raw.jsonl"
run gemini - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: a result event with NO status field stays REAL ===
# The documented success shape lists only stats fields — status is not promised. Rejecting
# its absence would turn every such healthy run into a false STALLED, and a false STALLED
# discards a finished review. Only an EXPLICIT non-success status may fail the run.
echo "=== Test: gemini result without a status field → REAL ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/gemini" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'findings'
printf '{"type":"tool_use"}\n{"type":"result","stats":{"total_tokens":512}}\n' > "$rd/raw.jsonl"
run gemini - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: finalized output with no stream file at all → STALLED ===
# Every layout the exec skills produce carries a stream: supervised runs get root raw.jsonl
# copied back, default-mode runs write log.jsonl (0 of 75 archived codex+gemini runs lack
# both). No stream means the layout is not one our tooling wrote — nothing can prove the
# run was agentic, so the gate must fail closed instead of silently skipping its checks.
echo "=== Test: gemini output.txt but no stream file → STALLED ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/gemini" 2026-07-28-11-00-00-1000-task)
mk_output "$rd/output.txt" 'plausible findings'
run gemini - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test: a foreign-stamped newest run is skipped for the older own-stamped one ===
# The gate and watch-runs.sh must agree on which run is "the run". mesh-design-review chains
# them: the watcher reports DONE, the gate then reads content. Disagreement discards a review.
echo "=== Test: run identity — the foreign newest run is not inspected ==="
TDIR=$(mktemp -d)
mine=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-mine)
mk_output "$mine/output.txt" 'real review'; ln -s attempt-1 "$mine/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$mine/raw.jsonl"
sid_stamp "$mine" sid-A
theirs=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-12-00-00-1000-theirs)
sid_stamp "$theirs" sid-B                       # newer by name, killed mid-flight
run_as sid-A ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL (own run inspected)" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: an unstamped run stays eligible ===
echo "=== Test: run identity — an unstamped run is still inspected ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-legacy)
mk_output "$rd/output.txt" 'real review'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$rd/raw.jsonl"
run_as sid-A ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
rm -rf "$TDIR"

# === Test: a reader with no session identity does not filter ===
echo "=== Test: run identity — no reader identity means no filtering ==="
TDIR=$(mktemp -d)
theirs=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-theirs)
mk_output "$theirs/output.txt" 'real review'; ln -s attempt-1 "$theirs/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$theirs/raw.jsonl"
sid_stamp "$theirs" sid-B
run_as - ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
rm -rf "$TDIR"

# === Test: every candidate foreign → FLIP, the same verdict as no run dir at all ===
echo "=== Test: run identity — only foreign runs present → FLIP ==="
TDIR=$(mktemp -d)
theirs=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-theirs)
mk_output "$theirs/output.txt" 'real review'; ln -s attempt-1 "$theirs/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$theirs/raw.jsonl"
sid_stamp "$theirs" sid-B
run_as sid-A ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
assert_match "reason names the session mismatch" "belong to another session" \
    "$(env CLAUDE_CODE_SESSION_ID=sid-A bash "$SCRIPT" ext-claude zai/glm 1 "$TDIR" 2>&1 >/dev/null)"
rm -rf "$TDIR"

# --- the dispatch window is the NAME window, the same one watch-runs.sh uses ---------------
# It used to be `find -newermt` — MODIFICATION time. A run dir created BEFORE the window but
# still being written stayed eligible forever, so /mesh-review Step 6.4a, which stamps a fresh
# epoch precisely "so the guard inspects the NEW run, not the old failed one", still got the
# old one: a wrapper that flipped on re-dispatch was scored REAL off the previous round's
# corpse, while watch-runs.sh — comparing names — reported no run in that window at all.

# === Test: a run named before --since is out of the window however fresh its mtime ===
echo "=== Test: run dir named before the window, mtime inside it → FLIP ==="
TDIR=$(mktemp -d)
NOW_T=$(date +%s)
OLD_NAME="$(date -d "@$(( NOW_T - 900 ))" +%Y-%m-%d-%H-%M-%S)-1000-task"
rd=$(mk_run "$TDIR/runs/codex" "$OLD_NAME")
mk_output "$rd/output.txt" 'findings'                       # written NOW → mtime inside the window
printf '{"type":"command_execution"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
run codex - "$(( NOW_T - 300 ))" "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test: the same run is REAL once --since precedes its name ===
echo "=== Test: the same run with --since before its name → REAL ==="
TDIR=$(mktemp -d)
NOW_T=$(date +%s)
IN_NAME="$(date -d "@$(( NOW_T - 300 ))" +%Y-%m-%d-%H-%M-%S)-1000-task"
rd=$(mk_run "$TDIR/runs/codex" "$IN_NAME")
mk_output "$rd/output.txt" 'findings'
printf '{"type":"command_execution"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
run codex - "$(( NOW_T - 900 ))" "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: a non-numeric since-epoch is a usage error, not a FLIP verdict ===
# An unsubstituted "$DISPATCH_EPOCH" expands to nothing; `find -newermt "@"` used to fail
# silently and the run came back FLIP — "the reviewer never delegated" — for every reviewer.
echo "=== Test: empty since-epoch → usage error (exit 1, no verdict) ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run codex - "" "$TDIR"
assert_eq "no verdict on stdout" "" "$VERDICT"
assert_eq "exit 1" "1" "$RC"
rm -rf "$TDIR"

# === Test: root output.txt empty while final/ holds the review → REAL, as watch-runs sees it ===
# watch-runs.sh picks the root file with -s and falls through to final/output.txt; this script
# used to pick it with -f, so an existing-but-empty root won and the gate answered STALLED on
# the run the watcher had just reported DONE.
echo "=== Test: empty root output.txt, content under final/ → REAL ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-task)
ln -sfn attempt-1 "$rd/final"
: > "$rd/output.txt"
mk_output "$rd/attempt-1/output.txt" 'findings'
printf '{"type":"command_execution"}\n{"type":"turn.completed"}\n' > "$rd/attempt-1/raw.jsonl"
run codex - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === DEGRADED: an agentic review the CLI denied access to ===
#
# Under `-p` nobody can answer a permission prompt, so a run launched without
# `--permission-mode bypassPermissions` is confined to its cwd and every read of a sibling
# repository comes back denied. The run still finalizes with is_error:false and num_turns>1,
# so every liveness signal this script had already checked said REAL: a review written from
# guesswork passed the gate as genuine cross-validation, and the only way to notice was to
# read raw.jsonl by hand.
#
# The signal is `permission_denials` on the result event — an array the CLI fills with one
# entry per refusal, carrying the tool name and the exact input it was refused. Verified on
# CC 2.1.221 (2026-08-04): a Read refusal yields one entry with tool_name "Read", a Bash
# refusal one with "Bash", and a run under --permission-mode bypassPermissions yields `[]`.
# The fixtures below use that field and nothing else. An earlier draft of this gate grepped
# the refusal TEXT out of tool_result bodies instead; that is what these tests are written
# against, because text matching failed in both directions — it missed every wording beyond
# the two that had been sampled, and it fired on any failed tool call whose OUTPUT happened
# to quote one of them (grepping this very repository does it).

echo "=== Test: ext-claude DEGRADED (one denial in an otherwise REAL run) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/deepseek/v4-pro" 2026-08-04-11-00-00-1000-degraded)
mk_output "$rd/output.txt" '### Critical
- The API signature could not be verified against the real source.'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":24,"permission_denials":[{"tool_name":"Read","tool_use_id":"toolu_01","tool_input":{"file_path":"/opt/git/common-backend/pom.xml"}}]}
EOF
run_full ext-claude deepseek/v4-pro 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "exit 5" "5" "$RC"
assert_eq "reason counts exactly 1 denial" "1" "$(reason_count)"
assert_match "reason names the refused tool" "Read" "$REASON"
# The remedy sentence became a `case "$ENGINE"` arm when grok joined this branch, so pin the
# ext-claude one too — otherwise swapping the two arms is only half-detected, by the grok test.
assert_match "keeps the ext-claude remedy" "the ext-claude run needs" "$REASON"
rm -rf "$TDIR"

echo "=== Test: ext-claude DEGRADED counts every denial and names each tool ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi" 2026-08-04-11-00-00-1000-count)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":40,"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/a.java"}},{"tool_name":"Read","tool_input":{"file_path":"/opt/b.java"}},{"tool_name":"Bash","tool_input":{"command":"grep -rn Foo /opt/svc"}}]}
EOF
run_full ext-claude ollama/kimi 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "reason counts exactly 3 denials" "3" "$(reason_count)"
assert_match "reason names both tools" "Bash" "$REASON"
rm -rf "$TDIR"

# The healthy shape: the field is present and empty. This is what every run under
# --permission-mode bypassPermissions produces (measured), so it must not be a DEGRADED.
echo "=== Test: ext-claude REAL — permission_denials present and empty ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-04-11-00-00-1000-empty-denials)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":18,"permission_denials":[]}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# Back-compat: a stream from a build that never wrote the field at all must stay REAL rather
# than becoming an unexplained DEGRADED — absent is not the same as denied.
echo "=== Test: ext-claude REAL — result event with no permission_denials field ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/alibaba/qwen" 2026-08-04-11-00-00-1000-nofield)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":22}
EOF
run ext-claude alibaba/qwen 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# Anti-false-positive 1: an ordinary failed tool call is not a permission denial. Reviewers
# hit these constantly (a path that does not exist, a grep that matched nothing); counting
# them would flag every healthy run as DEGRADED and make the verdict worthless.
echo "=== Test: ext-claude REAL — is_error tool_result that is NOT a denial ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-04-11-00-00-1000-ordinary-err)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Error: File does not exist. Did you mean src/main/java/App.java?","is_error":true}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":18,"permission_denials":[]}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# Anti-false-positive 2 — the one that sank the text-matching draft. A reviewer that greps
# THIS repository and gets a non-zero exit produces an is_error tool_result whose body quotes
# the refusal wordings verbatim, because they are written down here. Reviewing claude-mesh
# with full access must not report itself as denied.
echo "=== Test: ext-claude REAL — failed tool call whose OUTPUT quotes refusal wordings ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-04-11-00-00-1000-quoted)
mk_output "$rd/output.txt" 'a complete review of claude-mesh'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"verify-delegation.sh:313: grep -c 'requested permissions' ...\nSKILL.md:207: allowed working directories\nClaude requested permissions to read from /x, but you haven't granted it yet.","is_error":true}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":31,"permission_denials":[]}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# Anti-false-positive 3: the phrase in the model's own prose is not evidence either. A
# reviewer writing "the handler requested permissions it never checks" is describing code.
echo "=== Test: ext-claude REAL — denial wording in assistant prose ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/alibaba/qwen" 2026-08-04-11-00-00-1000-prose)
mk_output "$rd/output.txt" 'the handler requested permissions it never checks'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The handler requested permissions to read from the vault but you haven't granted it yet — that path is unreachable in prod."}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":22,"permission_denials":[]}
EOF
run ext-claude alibaba/qwen 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# Segments: NT deliberately ignores failed result events (see the script's own comment on the
# background-subagent split), so the denial count must ignore them too. Denials belonging to
# an abandoned segment did not constrain the review that was actually delivered — counting
# them publishes "partial context" about a run that had full access.
echo "=== Test: ext-claude REAL — denials only in the FAILED segment ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/minimax" 2026-08-04-11-00-00-1000-segments)
mk_output "$rd/output.txt" 'findings from the resumed segment'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":true,"num_turns":4,"result":"Prompt is too long","permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/x.java"}},{"tool_name":"Read","tool_input":{"file_path":"/opt/y.java"}}]}
{"type":"result","subtype":"success","is_error":false,"num_turns":30,"permission_denials":[]}
EOF
run ext-claude ollama/minimax 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# ...but denials in a SUCCESSFUL segment of the same split stream do count, and across all of
# them: the resumed segment inherits the earlier one's context, so both constrained the review.
echo "=== Test: ext-claude DEGRADED — denials summed across successful segments ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/minimax" 2026-08-04-11-00-00-1000-segsum)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":1,"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/a.java"}}]}
{"type":"result","subtype":"success","is_error":false,"num_turns":30,"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"ls /opt"}}]}
EOF
run_full ext-claude ollama/minimax 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "reason counts both segments" "2" "$(reason_count)"
rm -rf "$TDIR"

# A segment that omits the field entirely must not swallow the denials of one that carries it
# — the two shapes coexist in a split stream when only one segment hit a refusal.
echo "=== Test: ext-claude DEGRADED — one segment without the field, one with denials ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-04-11-00-00-1000-mixed-shape)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":3}
{"type":"result","subtype":"success","is_error":false,"num_turns":30,"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/a.java"}}]}
EOF
run_full ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "reason counts 1 denial" "1" "$(reason_count)"
rm -rf "$TDIR"

# A truncated final line is the shape a killed, live-appended stream leaves. The denial scan
# must survive it exactly as the NT scan does, rather than aborting and losing the verdict.
echo "=== Test: ext-claude DEGRADED — truncated trailing line does not break the scan ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-04-11-00-00-1000-torn)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":12,"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/a.java"}}]}
{"type":"result","subtype":"succ
EOF
run_full ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "reason counts 1 denial" "1" "$(reason_count)"
rm -rf "$TDIR"

# Precedence: DEGRADED is checked LAST, so a run that is also dead stays dead. BROKEN and
# STALLED route to different actions (drop / re-dispatch) and a denial count does not change
# either of them — whereas DEGRADED means "keep it, but know what it is worth".
echo "=== Test: ext-claude BROKEN wins over DEGRADED (num_turns<=1 + denials) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/minimax" 2026-08-04-11-00-00-1000-broken-deny)
mk_output "$rd/output.txt" 'narration'
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":1,"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/x.java"}}]}
EOF
run ext-claude ollama/minimax 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

echo "=== Test: ext-claude STALLED wins over DEGRADED (blank output + denials) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-04-11-00-00-1000-stalled-deny)
printf '\n' > "$rd/output.txt"
ln -s attempt-1 "$rd/final"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"num_turns":9,"permission_denials":[{"tool_name":"Read","tool_input":{"file_path":"/opt/x.java"}}]}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# codex and gemini are out of scope: they carry a bypass flag of their own since the first
# commit, and their streams carry no result event with this field, so there is nothing to
# read. Keep the branch narrow rather than speculative.
echo "=== Test: codex REAL — denial-shaped payload in the stream is not scanned ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-04-11-00-00-1000-codex-textual)
mk_output "$rd/output.txt" 'findings'
ln -s attempt-1 "$rd/final"; echo 0 > "$rd/.watchdog_rc"
cat > "$rd/raw.jsonl" <<'EOF'
{"type":"command_execution","text":"permission_denials: the reviewer discussed this field","permission_denials":[{"tool_name":"Read"}]}
{"type":"turn.completed"}
EOF
run codex - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# --- KILLED: terminated from outside, not by anything inside the run -------------------
#
# watchdog.sh traps the two signals it can be killed by and records them as its own exit code
# (`trap 'cleanup 143' TERM`, `trap 'cleanup 130' INT`, watchdog.sh:287-288). It writes
# `watchdog.exit` ONLY when it decides to stop by itself — retries exhausted or global timeout.
# So a cleanup of 143/130 with NO watchdog.exit beside it says: nothing inside the run decided
# anything, the signal came from outside.
#
# Measured 2026-08-05 (CC 2.1.222): five ext-claude runs launched as FOREGROUND Bash calls with
# `timeout: 600000` died at 600-605s while writing steadily, each tool result reading
# "Exit code 143 / Command timed out after 10m 0s"; every run launched with
# `run_in_background: true` outlived the cap (812s, 1397s, 2001s, 2028s). A re-dispatch of a
# killed run repeats whatever killed it, so this must not read as STALLED, which mesh-review
# Step 6.0.4 retries.
echo "=== Test: ext-claude KILLED — cleanup 143, no watchdog.exit ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-killed)
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/attempt-1/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:53:45+0300","event":"alive","attempt":1,"details":{"event_count":10422,"age_sec":0}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

echo "=== Test: ext-claude KILLED — SIGINT (130) counts too ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-int)
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":130}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

# The discriminator is watchdog.exit, not the code: when the watchdog bailed on its own it
# writes that file, and the run is a STALLED the orchestrator may usefully retry.
echo "=== Test: ext-claude STALLED — watchdog.exit present means it decided, not was killed ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-bailed)
echo '{"reason":"retries_exhausted","attempts":3,"elapsed_sec":900}' > "$rd/watchdog.exit"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# A run with no watchdog.log at all is the pre-supervised shape: unfinalized says nothing about
# WHO stopped it, so it stays STALLED rather than being guessed into KILLED.
echo "=== Test: ext-claude STALLED — unfinalized with no watchdog.log stays STALLED ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-nolog)
echo '{"type":"assistant"}' > "$rd/attempt-1/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# The signal is only a verdict when it cost the review. A run that finalized with a real
# review before something SIGTERMed its tail is REAL — the findings are on disk.
echo "=== Test: ext-claude REAL — a 143 after a finalized, agentic run is not KILLED ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi" 2026-08-05-09-44-20-1000-late143)
mk_output "$rd/output.txt" '### Findings
- storage/RecoveryOrderMongoRepositoryImpl.java: the CAS retry drops the audit stamp.'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":46}' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:20+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:50:11+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run ext-claude ollama/kimi 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# codex/gemini reach the same conclusion down a different path: their branch reads the watchdog
# cleanup code directly, and used to call every non-zero one STALLED.
echo "=== Test: codex KILLED — finalized output but cleanup 143, no watchdog.exit ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-05-09-45-39-1000-killed)
mk_output "$rd/output.txt" 'partial findings'; ln -s attempt-1 "$rd/final"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:46:10+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:19:58+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run codex - 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

# Any other non-zero watchdog code is the engine failing, not a signal — still STALLED. The
# fixture carries a healthy STREAM on purpose: without one the run is STALLED anyway ("no stream
# file"), so the assertion would hold with the cleanup-code branch deleted and pin nothing. Assert
# the REASON for the same reason — the verdict alone cannot say which branch produced it.
echo "=== Test: codex STALLED — cleanup 2 is the watchdog bailing, not an outside kill ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-05-09-45-39-1000-bail)
mk_output "$rd/output.txt" 'partial'; ln -s attempt-1 "$rd/final"
printf '{"type":"command_execution","call_id":"c1"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:46:10+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:19:58+0300","event":"cleanup","attempt":1,"details":{"exit_code":2}}
EOF
run_full codex - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
assert_match "reason names the cleanup code" "watchdog cleanup exit code 2" "$REASON"
rm -rf "$TDIR"

# --- KILLED is what a signal COST, not the signal itself ---------------------------------
#
# The verdict answers "was the review lost?", and only then "who stopped the run?". A signalled
# run that had already delivered a usable review is REAL — the findings are on disk and dropping
# them buys nothing. This is what CHANGELOG promises for every engine; it used to hold for
# ext-claude only, because the codex/gemini branch emitted KILLED from the watchdog exit code
# before it ever looked at the content.
echo "=== Test: codex REAL — signalled AFTER delivering a complete review ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-05-09-45-39-1000-late143)
mk_output "$rd/output.txt" '### Findings — Critical: the CAS retry drops the audit stamp.'
ln -s attempt-1 "$rd/final"
printf '{"type":"command_execution","call_id":"c1"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:46:10+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:19:58+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run codex - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# ...and the mirror image: a signalled run whose review is NOT usable is KILLED down every path
# that would otherwise have said STALLED. The ext-claude branch never consulted the signal at
# all, so a torn stream on a killed run was reported as "killed mid-flight" and RE-DISPATCHED
# into an identical death — the exact loop this verdict exists to break.
echo "=== Test: ext-claude KILLED — finalized dir, torn stream, cleanup 143 ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-58-40-1000-torn)
ln -s attempt-1 "$rd/final"
mk_output "$rd/output.txt" 'partial review text'
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:58:40+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:08:42+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

# num_turns<=1 on a SIGNALLED ext-claude run is not a broken engine. A run that dispatches a
# background subagent answers "started" (num_turns 1) and delivers the review in a later segment;
# a kill before that segment leaves exactly this shape. BROKEN would be terminal AND would tell
# the user to swap a model that did nothing wrong.
echo "=== Test: ext-claude KILLED — num_turns=1 on a signalled run is not BROKEN ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-58-40-1000-seg1)
ln -s attempt-1 "$rd/final"
mk_output "$rd/output.txt" 'started'
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:58:40+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:08:42+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

# An unsignalled num_turns=1 is still BROKEN — the signal is what moves it, nothing else.
echo "=== Test: ext-claude BROKEN — num_turns=1 with no signal stays BROKEN ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-58-40-1000-nt1)
ln -s attempt-1 "$rd/final"
mk_output "$rd/output.txt" 'thinking only'
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:58:40+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:08:42+0300","event":"cleanup","attempt":1,"details":{"exit_code":0}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# codex/gemini keep BROKEN even when signalled: a terminal turn event with zero tool calls says
# the CLI finished its turn and did nothing, which no signal can explain away. There is no
# subagent-split shape on these engines to confuse it with.
echo "=== Test: codex BROKEN — narration plus a late 143 is still BROKEN ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-05-09-45-39-1000-narration)
mk_output "$rd/output.txt" 'I would review this by first...'; ln -s attempt-1 "$rd/final"
printf '{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:46:10+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:19:58+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run codex - 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# A dead `.watchdog_rc` check used to run BEFORE the signal was consulted, so a fixture (or any
# future writer) putting 143 there masked KILLED behind "engine exit code != 0".
echo "=== Test: codex KILLED — .watchdog_rc 143 does not mask the signal ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-05-09-45-39-1000-rcfile)
mk_output "$rd/output.txt" 'partial'; ln -s attempt-1 "$rd/final"
echo '143' > "$rd/.watchdog_rc"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:46:10+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T10:19:58+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run codex - 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

# The orchestrators are told to report the lifetime ("terminated from outside after Ns") and that
# a cluster of deaths at the same round number is the foreground-cap signature. The number has to
# come from the guard, or the model invents it: 09:44:45 -> 09:54:46 is 601s.
echo "=== Test: KILLED reason carries the run's lifetime ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-life)
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:53:45+0300","event":"alive","attempt":1,"details":{"event_count":10422,"age_sec":0}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run_full ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_match "reason names the lifetime" "after 601s" "$REASON"
assert_match "reason names the cap for a SIGTERM" "BASH_MAX_TIMEOUT_MS" "$REASON"
rm -rf "$TDIR"

# A SIGINT is a user pressing ESC or an orchestrator stopping the wrapper. Naming the Bash cap
# there states a cause that cannot apply — the cap raises TERM, never INT.
echo "=== Test: KILLED reason does not blame the Bash cap for a SIGINT ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-intreason)
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":130}}
EOF
run_full ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_no_match "no cap claim on a SIGINT" "BASH_MAX_TIMEOUT_MS" "$REASON"
assert_match "reason names an interrupt" "interrupt" "$REASON"
rm -rf "$TDIR"

# "I read the evidence and it says nothing happened" and "I could not read the evidence" are
# different states. Swallowing the read error turns the second into the first, and STALLED sends
# the run back into whatever killed it.
echo "=== Test: STALLED — an unreadable watchdog.log is reported, not swallowed ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-unreadable)
echo '{"type":"assistant"}' > "$rd/attempt-1/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
chmod 000 "$rd/watchdog.log"
if [ -r "$rd/watchdog.log" ]; then
    echo "  SKIP: running as root — chmod 000 does not deny reads"
else
    run_full ext-claude zai/glm 1 "$TDIR"
    assert_eq "verdict STALLED" "STALLED" "$VERDICT"
    assert_match "reason names the unreadable log" "unreadable" "$REASON"
fi
chmod 644 "$rd/watchdog.log"
rm -rf "$TDIR"

# --- a delivered notice is not a delivered review ----------------------------------------
#
# Until this check existed, REAL asked only that output.txt be non-blank, so a model that
# delegated the work and reported the delegation passed as a cross-validation. Measured
# 2026-08-05 on the archive that produced these fixtures (336 ext-claude runs with a non-empty
# output, 78 codex): every output under 400 non-space BYTES was a stub, a torn fragment, leaked
# tool grammar or an "I need approval" note; the shortest genuine ext-claude review measured 460
# and the shortest genuine codex one 1746. Bytes rather than characters because the script runs
# under LC_ALL=C — which also means the floor is stricter for Cyrillic (~2 bytes per character)
# than for ASCII, and the archive's Russian-language reviews are what calibrated it.
# The first fixture is a verbatim copy of what deepseek/v4-pro delivered twice that day, while
# `/mesh-review` counted it as one of its cross-validating reviewers.
echo "=== Test: ext-claude STALLED — an agentic run that delivered only a start notice ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/deepseek/v4-pro" 2026-08-05-09-55-27-1000-stub)
ln -s attempt-1 "$rd/final"
printf '%s\n' "Ревью запущено — агент анализирует 82 изменённых файла (6648 строк добавлено, 637 удалено) из двух крупных workstream'ов: слой точечной записи в MongoDB и генерация XML документа." \
    "" "Ожидаю результаты, уведомлю вас по завершении." > "$rd/output.txt"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":7}' > "$rd/raw.jsonl"
run_full ext-claude deepseek/v4-pro 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
assert_match "reason names the delivered length" "non-space bytes" "$REASON"
# Same reason as the DEGRADED remedy above: the sentence that EXPLAINS the floor is a per-engine
# `case` arm now, and ext-claude's is the measured archive number rather than the bare floor.
assert_match "cites the ext-claude archive floor" "archive is 460" "$REASON"
rm -rf "$TDIR"

# A short review is still a review. The floor is deliberately below the shortest genuine one in
# the archive, so "no findings, here is why" survives.
echo "=== Test: ext-claude REAL — a brief but substantive review passes ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-brief)
ln -s attempt-1 "$rd/final"
{ printf '### Critical\n'
  for i in 1 2 3 4 5 6 7 8; do
      printf -- '- storage/RecoveryOrderMongoRepositoryImpl.java:%d — the CAS retry drops the audit stamp on conflict.\n' "$i"
  done; } > "$rd/output.txt"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":7}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# The floor counts CHARACTERS, not bytes, and ignores whitespace — otherwise a page of newlines
# or a UTF-8 text would clear it without saying anything.
echo "=== Test: ext-claude STALLED — padding with whitespace does not clear the floor ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-padded)
ln -s attempt-1 "$rd/final"
{ printf 'Review done.'; for i in $(seq 1 300); do printf '   \n'; done; } > "$rd/output.txt"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":31}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# codex/gemini reach the floor down their own path — theirs only ever checked `-s`.
echo "=== Test: codex STALLED — terminal event and tool calls, but only a notice delivered ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-08-05-09-45-39-1000-notice)
ln -s attempt-1 "$rd/final"
printf 'Review kicked off in the background; I will report once it finishes.\n' > "$rd/output.txt"
printf '{"type":"command_execution","call_id":"c1"}\n{"type":"turn.completed"}\n' > "$rd/raw.jsonl"
run_full codex - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
assert_match "reason names the delivered length" "non-space bytes" "$REASON"
rm -rf "$TDIR"

# Precedence: a signalled run whose output is thin is KILLED, not STALLED. The floor routes
# through `fail` like every other non-REAL outcome, so re-dispatch stays off the table.
echo "=== Test: ext-claude KILLED — a thin output on a signalled run is not retryable ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-05-09-44-24-1000-thinkilled)
ln -s attempt-1 "$rd/final"
printf 'Starting the review now.\n' > "$rd/output.txt"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9}' > "$rd/raw.jsonl"
cat > "$rd/watchdog.log" <<'EOF'
{"ts":"2026-08-05T09:44:45+0300","event":"attempt_start","attempt":1,"details":{"dir":"attempt-1"}}
{"ts":"2026-08-05T09:54:46+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}
EOF
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

# === grok: the engine shares ext-claude's classification, because it shares its stream format ===
# grok --output-format streaming-messages-json emits the Claude Code wire format verbatim, so
# every signal the ext-claude branch reads — is_error, num_turns, permission_denials — is on
# disk here too. These tests exist to keep the two wired together: a future edit that splits
# the branch must keep grok scoring the same way.
echo "=== Test: grok FLIP (no run dir) ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/runs/grok/grok-4.6"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok REAL (num_turns 12, real review) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-review)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12}' > "$rd/raw.jsonl"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok BROKEN (num_turns 1 — answered without reading code) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-lazy)
mk_output "$rd/output.txt" 'Looks fine to me.'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok STALLED (torn stream, no result event) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.5" 2026-08-28-11-00-00-1000-torn)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/raw.jsonl"
run grok grok-4.5 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# Design §5 promises grok coverage for REAL, STALLED, BROKEN, FLIP, DEGRADED **and KILLED**;
# KILLED and the engine-specific STALLED floor note are the two the first draft omitted.
echo "=== Test: grok KILLED (watchdog cleanup 143, no watchdog.exit) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-30-00-1000-killed)
printf '%s\n' '{"ts":"2026-08-28T11:40:00+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}' > "$rd/watchdog.log"
: > "$rd/output.txt"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok STALLED floor note is grok's, not ext-claude's archive number ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-45-00-1000-short)
# Written directly and NOT with mk_output: that helper pads the headline with five filler lines
# — 527 non-space bytes, above MIN_REVIEW_BYTES=400 — so the run would score REAL and the floor
# branch under test would never execute. The suite's other floor tests write theirs the same way.
printf 'ok\n' > "$rd/output.txt"
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":4}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
# "the shortest genuine review in the archive is 460" is a measured ext-claude fact; quoting it
# for grok would cite evidence that does not exist for this engine.
assert_no_match "no ext-claude archive number" "archive" "$REASON"
assert_match "names the floor itself" "400 non-space" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok DEGRADED (denials on an otherwise real review) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-denied)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"permission_denials":[{"tool_name":"Read"},{"tool_name":"Bash"}]}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "exit 5" "5" "$RC"
assert_eq "counts both denials" "2" "$(reason_count)"
# The ext-claude remedy prescribes a flag grok already passes — saying it here would send the
# reader after a setting that is not the cause.
assert_no_match "does not prescribe the ext-claude remedy" "the ext-claude run needs" "$REASON"
# assert_no_match alone would also pass on an EMPTY or generic reason, so pin the grok text too:
# the branch must say something true about grok, not merely avoid saying something false.
assert_match "names the grok remedy" "grok-exec already passes" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok BROKEN — a single turn because the CLI refused the first tool call ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-30-00-1000-denied-first)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"permission_denials":[{"tool_name":"Bash"},{"tool_name":"Read"}]}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
# The VERDICT does not move: one turn is not a review whatever caused it, and BROKEN is
# terminal for the right reason. What must move is the DIAGNOSIS. BROKEN's own text says
# "retry futile" — swap the model — about a model that did nothing wrong, while the DEGRADED
# branch that knows better is 45 lines further down and unreachable from here.
assert_eq "verdict stays BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
assert_match "names the refusal and its count" "refused 2 tool call" "$REASON"
assert_match "…and which tools" "Bash" "$REASON"
assert_no_match "does not send the user off to swap the model" "retry futile" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok requires a model argument ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/grok"
run grok - 1 "$TDIR"
assert_eq "exit 1 (usage error, no verdict)" "1" "$RC"
assert_eq "no verdict printed" "" "$VERDICT"
rm -rf "$TDIR"

echo "=== Test: grok rejects a model that is not a catalog id ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/grok"
# `<provider>/<short>` is ext-claude's spelling, and both orchestrators TEMPLATE this call, so
# it is the copy-paste that actually happens. It used to pass the guard and resolve
# runs/grok/zai/glm — a path nothing ever writes — reported as FLIP, i.e. "this reviewer never
# delegated", about a reviewer that ran and delivered. Usage error, not a verdict.
run grok zai/glm 1 "$TDIR"
assert_eq "slashed model: exit 1 (usage error)" "1" "$RC"
assert_eq "slashed model: no verdict printed" "" "$VERDICT"
# Anchored at the first character, like GROK_IDENT_RE: a leading dot would climb out of the
# runs tree once joined to a path.
run grok .hidden 1 "$TDIR"
assert_eq "leading dot: exit 1 (usage error)" "1" "$RC"
# The positive control that stops the new pattern from rejecting everything: a real catalog id
# reaches a VERDICT. There is no run dir, so that verdict is FLIP (exit 3), not a usage error.
run grok grok-4.6 1 "$TDIR"
assert_eq "a real catalog id still reaches a verdict" "3" "$RC"
assert_eq "…and that verdict is FLIP" "FLIP" "$VERDICT"
rm -rf "$TDIR"

# === A failed run that took ZERO turns is BROKEN, not STALLED ===
# The shape a CLI produces when it refuses its own arguments. Measured 2026-08-30:
# `grok -m grok-4.6 --effort max` exits 1 in 4.7s BEFORE any API call, emitting one
# {"type":"result","is_error":true,"num_turns":0,"errors":[…]} event. watchdog.sh counts that as
# attempt success and extract-result.py's F4 arm makes output.txt non-empty, so the run reaches
# the guard looking finished. Scored STALLED it prescribes a re-dispatch, and the whole
# max_redispatch budget is spent on 4.7-second deaths.
echo "=== Test 66: grok BROKEN (is_error, num_turns 0 — an argument refusal) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-30-16-32-35-2064858-review-feat-grok-engine)
mk_output "$rd/output.txt" 'API Error: unknown effort level'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"errors":["--effort/--reasoning-effort: unknown effort level '"'"'max'"'"'; use one of: xhigh, high, medium, low"]}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict BROKEN, not STALLED" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
assert_match "reason names the zero turn count" "num_turns=0" "$REASON"
assert_match "reason names the per-model effort cause" "PER MODEL" "$REASON"
assert_no_match "reason does not prescribe a retry" "retry helps" "$REASON"
rm -rf "$TDIR"

# The condition is engine-agnostic — a run that took no turn did no work whatever produced it —
# but the grok-specific --effort sentence must not be told to an ext-claude user.
echo "=== Test 67: ext-claude with num_turns 0 is BROKEN too, without grok's remedy ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-08-30-12-00-00-1000-zero-turns)
mk_output "$rd/output.txt" 'API Error'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0}' > "$rd/raw.jsonl"
run_full ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_match "reason names the zero turn count" "num_turns=0" "$REASON"
assert_no_match "no grok effort remedy on ext-claude" "model_efforts" "$REASON"
rm -rf "$TDIR"

# THE REFUTATION, pinned. The first proposal was to treat "is_error:true with a non-empty
# errors[]" as BROKEN. Measured across 1067 archived ext-claude run files: that shape is
# ORDINARY there — num_turns 2 through 62, dozens of runs — while num_turns == 0 appears in
# NONE of them (the archive's minimum is 1). Had errors[] entered the condition, retryable
# ext-claude failures would have become terminal. This test is what stops it coming back.
echo "=== Test 68: ext-claude is_error with errors[] but real turns stays STALLED ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/deepseek/v4-pro" 2026-08-30-12-30-00-1000-mid-flight)
mk_output "$rd/output.txt" 'partial'; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":18,"errors":["Insufficient Balance"]}' > "$rd/raw.jsonl"
run ext-claude deepseek/v4-pro 1 "$TDIR"
assert_eq "a non-empty errors[] alone does NOT make it BROKEN" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
