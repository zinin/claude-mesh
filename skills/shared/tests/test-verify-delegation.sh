#!/usr/bin/env bash
# Regression tests for verify-delegation.sh
#
# verify-delegation.sh classifies whether a wrapper reviewer (ext-claude / codex /
# gemini) actually DELEGATED to its external engine and produced a REAL review, vs
# self-reviewed on the session model (FLIP), was killed mid-flight (STALLED), or got an
# engine-broken empty/thinking-only result (BROKEN).
#
# Verdicts (stdout) + exit codes:
#   REAL=0  FLIP=3  STALLED=2  BROKEN=4
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

# run the script and capture verdict + rc
run() { VERDICT=$(bash "$SCRIPT" "$@" 2>/dev/null); RC=$?; }

# --- helpers to build run dirs ---
# $1 base dir (e.g. $TDIR/runs/ext-claude/zai/glm), $2 run name
mk_run() { mkdir -p "$1/$2/attempt-1"; echo "$1/$2"; }

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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-old)
echo 'review' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
run ext-claude zai/glm 9999999999 "$TDIR"   # since far in the future
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test 3: STALLED — killed mid-flight (no final, no root output.txt) ===
echo "=== Test 3: ext-claude STALLED (killed, no final/output) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-kill)
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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-empty)
: > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 5: BROKEN — DSML thinking-fallback garbage (num_turns==1) ===
echo "=== Test 5: ext-claude BROKEN (DSML + num_turns 1) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/deepseek" run-broken)
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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-1turn)
echo 'Looks fine to me, no issues.' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 7: REAL — ext-claude delegated, agentic review ===
echo "=== Test 7: ext-claude REAL (num_turns 46) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi" run-real)
echo '### Strengths
- connection.py singleton cold-start race is properly guarded.' > "$rd/output.txt"
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":46}' > "$rd/raw.jsonl"
run ext-claude ollama/kimi 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 8: REAL — codex delegated (watchdog_rc=0, no num_turns) ===
echo "=== Test 8: codex REAL (.watchdog_rc=0) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" run-codex-ok)
echo 'I reviewed the diff; here are the findings...' > "$rd/output.txt"
ln -s attempt-1 "$rd/final"; echo 0 > "$rd/.watchdog_rc"
run codex - 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 9: STALLED — codex run-dir, non-empty output, but watchdog_rc != 0 ===
# (non-empty output so this exercises the codex rc-branch, not the empty-output branch)
echo "=== Test 9: codex STALLED (.watchdog_rc=124) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" run-codex-kill)
echo 'partial findings before kill...' > "$rd/output.txt"; echo 124 > "$rd/.watchdog_rc"
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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-noresult)
echo 'partial output' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 12: STALLED — ext-claude agentic (num_turns>1) but output.txt empty ===
echo "=== Test 12: ext-claude STALLED (num_turns 5, empty output) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-agentic-empty)
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
rd=$(mk_run "$TDIR/runs/ext-claude/deepseek/v4-pro" run-multiresult)
echo '## Code Review
- Critical: connection leak in pool.py:42' > "$rd/output.txt"
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
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/deepseek" run-multibroken)
echo 'Looks fine to me, no issues.' > "$rd/output.txt"
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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" run-noturns)
echo 'partial output' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"error_during_execution","is_error":true}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 16: REAL — a truncated result line must not abort the scan ===
# raw.jsonl is appended live, so a killed stream can leave its last line cut mid-string
# (observed in real run dirs). Scanning every line means a bare `jq` would abort ON that
# line and drop the values after it; `fromjson?` skips it instead. Truncated line FIRST,
# so the fixture fails if the tolerant parse is ever dropped.
echo "=== Test 16: ext-claude REAL (truncated line before a valid result) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/alibaba/qwen" run-truncated)
echo 'Frontend reviewed. Critical findings: ...' > "$rd/output.txt"
ln -s attempt-1 "$rd/final"
{
  echo '{"type":"result","subtype":"success","is_error":false,"result":"cut off mid-str'
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12}'
} > "$rd/raw.jsonl"
run ext-claude alibaba/qwen 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
