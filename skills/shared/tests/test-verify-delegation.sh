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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-old)
echo 'review' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
echo 'Looks fine to me, no issues.' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

# === Test 7: REAL — ext-claude delegated, agentic review ===
echo "=== Test 7: ext-claude REAL (num_turns 46) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/kimi" 2026-07-28-11-00-00-1000-real)
echo '### Strengths
- connection.py singleton cold-start race is properly guarded.' > "$rd/output.txt"
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
echo 'I reviewed the diff; here are the findings...' > "$rd/output.txt"
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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-noresult)
echo 'partial output' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
rd=$(mk_run "$TDIR/runs/ext-claude/ollama/deepseek" 2026-07-28-11-00-00-1000-multibroken)
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
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-noturns)
echo 'partial output' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
echo 'Frontend reviewed. Critical findings: ...' > "$rd/output.txt"
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
echo 'Prompt is too long' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
echo 'Looks fine to me.' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
echo 'some text' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
echo 'review' > "$retry/output.txt"; ln -s attempt-1 "$retry/final"
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
echo 'partial' > "$rd/output.txt"
printf '{"type":"thread.started"}\n{"type":"command_execution"}\n' > "$rd/raw.jsonl"
run codex - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test: a real codex run still passes ===
echo "=== Test: codex with a terminal event and tool calls → REAL ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/codex" 2026-07-28-11-00-00-1000-task)
echo 'findings' > "$rd/output.txt"
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
echo 'findings' > "$rd/output.txt"
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
echo 'review' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
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
echo 'findings' > "$rd/output.txt"
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
echo 'findings' > "$rd/output.txt"
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
echo 'plausible findings' > "$rd/output.txt"
run gemini - 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
