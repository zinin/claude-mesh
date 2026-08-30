#!/usr/bin/env bash
# Regression tests for extract-result.py
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$TESTS_DIR/../extract-result.py"

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

# === Test 1: PRIMARY wins (type==result beats assistant text) ===
echo "=== Test 1: result event wins over assistant text ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"IGNORED"}]}}' \
    '{"type":"result","result":"RESULT_WINS"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt == RESULT_WINS" "RESULT_WINS" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 2: FALLBACK concatenates assistant text blocks ===
echo "=== Test 2: fallback joins two text blocks ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}]}}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt == 'hello world'" "hello world" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 3: empty result string falls through to fallback ===
echo "=== Test 3: empty result string -> fallback assistant text ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"fb"}]}}' \
    '{"type":"result","result":""}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt == fb" "fb" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 4: missing raw.jsonl -> empty output, raw.json == [] ===
echo "=== Test 4: missing raw.jsonl ==="
TDIR=$(mktemp -d)
# deliberately do NOT create raw.jsonl
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
if [ -f "$TDIR/output.txt" ]; then PASS=$((PASS+1)); echo "  PASS: output.txt exists"; else FAIL=$((FAIL+1)); echo "  FAIL: output.txt missing"; fi
assert_eq "output.txt is empty (0 bytes)" "0" "$(stat -c %s "$TDIR/output.txt")"
assert_eq "raw.json == []" "[]" "$(cat "$TDIR/raw.json")"
rm -rf "$TDIR"

# === Test 5: all-unparseable non-empty file -> exit 3 ===
echo "=== Test 5: all-unparseable non-empty -> exit 3 ==="
TDIR=$(mktemp -d)
printf '%s\n' 'not json' '{bad' > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

# === Test 6: REGRESSION (FIX 1A) non-dict lines mixed with valid event ===
echo "=== Test 6: non-dict JSON lines are skipped, dict event processed ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '42' \
    '[1,2,3]' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0 (no crash)" "0" "$RC"
assert_eq "output.txt == ok" "ok" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 7: REGRESSION (FIX 1B) non-dict message does not crash ===
echo "=== Test 7: non-dict message is skipped, no crash ==="
TDIR=$(mktemp -d)
printf '%s\n' '{"type":"assistant","message":"oops"}' > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0 (no crash)" "0" "$RC"
assert_eq "output.txt is empty" "0" "$(stat -c %s "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 8: usage error (no work_dir arg) -> exit 2 ===
echo "=== Test 8: no work_dir arg -> exit 2 ==="
python3 "$EXTRACT" 2>/dev/null; RC=$?
assert_eq "exit 2" "2" "$RC"

# === Test 9: REGRESSION (F3) error event -> "API Error: <msg>" ===
echo "=== Test 9: error event surfaces API Error ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"error","error":{"message":"rate limit exceeded"}}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt == 'API Error: rate limit exceeded'" "API Error: rate limit exceeded" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 10: REGRESSION (F3) non-dict error value -> str(err) ===
echo "=== Test 10: non-dict error value falls back to str ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"error","error":"boom"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt == 'API Error: boom'" "API Error: boom" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 11: REGRESSION (F3) result event wins over error event ===
echo "=== Test 11: result beats error ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"error","error":{"message":"ignored"}}' \
    '{"type":"result","result":"OK"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt == OK" "OK" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 12: REGRESSION (E) result branch ends with newline (parity w/ progress-monitor.sh) ===
echo "=== Test 12: result output has trailing newline (size 6) ==="
TDIR=$(mktemp -d)
printf '%s\n' '{"type":"result","result":"HELLO"}' > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt size == 6 (HELLO + newline)" "6" "$(stat -c %s "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 13: GUARD (E) assistant-fallback output has NO trailing newline ===
echo "=== Test 13: fallback output has no trailing newline (size 2) ==="
TDIR=$(mktemp -d)
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"HI"}]}}' > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "fallback output.txt size == 2 (HI, no newline)" "2" "$(stat -c %s "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 14: thinking-only stream -> EMPTY output (thinking-fallback reverted, b42161f) ===
# A reasoning model that emits only a `thinking` block (no text/result) must now yield an
# EMPTY output.txt. The thinking fallback was removed so engine-broken runs surface honestly;
# mesh-review Step 6.0 classifies them BROKEN via the result event's num_turns<=1, not via
# output.txt junk. This test guards against the fallback being silently reintroduced.
echo "=== Test 14: thinking-only -> empty output (no fallback) ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"the answer is 42"}]}}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt is empty (0 bytes)" "0" "$(stat -c %s "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 15: REGRESSION (grok) error message — BOTH shapes, nested arm first ===
# grok emits the error text TOP-LEVEL (`.message`); claude/codex/gemini nest it under
# `.error.message`. The extractor tries nested first, then top-level, then str(err), so
# all three pre-grok engines stay byte-identical while a grok error-only stream — the
# shape a typo in `-m` produces — stops rendering as the literal "API Error: {}".
echo "=== Test 15: error message read from nested AND top-level shapes ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"error","error":{"message":"nested msg"}}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "nested shape: exit 0" "0" "$RC"
assert_eq "nested shape: output.txt == 'API Error: nested msg'" "API Error: nested msg" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"error","message":"Couldn'"'"'t set model to bogus-model"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "top-level shape: exit 0" "0" "$RC"
assert_eq "top-level shape: message survives (was 'API Error: {}')" "API Error: Couldn't set model to bogus-model" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# Precedence: when BOTH are present the nested arm wins, which is what keeps the three
# pre-grok engines byte-identical. Pins the order of the two arms, not just their presence.
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"error","message":"top-level","error":{"message":"nested"}}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "both shapes: exit 0" "0" "$RC"
assert_eq "both shapes: nested wins" "API Error: nested" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 16: a RESULT event carrying errors[] is not silence ===
# The shape a grok argument-parse failure produces — no `type:"error"` event at all, just a
# terminal result with is_error and the reason in `errors[]`. Every existing arm misses it:
# `.result` is absent, there are no assistant messages, and the type is `result`, not `error`.
# So the extractor exited 0 over a ZERO-BYTE output.txt and the reason survived only in
# stderr.txt, where nothing downstream reads it: verify-delegation.sh sees an empty review and
# scores the run STALLED — "killed mid-flight" — for a run that died deterministically in 15s.
# Observed live on 2026-08-30, not constructed: `--effort max` against grok-4.6.
echo "=== Test 16: result event with errors[] surfaces the reason ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"system","subtype":"init","model":"grok-4.6"}' \
    '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"errors":["unknown effort level max"]}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "output.txt names the reason" "API Error: unknown effort level max" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# Several errors are all reported: a run can fail for more than one reason, and picking the
# first would hide the rest behind a message that looks complete.
echo "=== Test 17: every entry of errors[] is reported ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["first reason","second reason"]}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR" >/dev/null 2>&1
assert_eq "the first reason is there" "1" "$(grep -c 'first reason' "$TDIR/output.txt")"
assert_eq "…and so is the second" "1" "$(grep -c 'second reason' "$TDIR/output.txt")"
rm -rf "$TDIR"

# A HEALTHY result must not be touched by the new arm — is_error false, errors absent, and a
# real answer present. This is the assertion that keeps the arm from firing on ordinary runs.
echo "=== Test 18: a healthy result event is unaffected ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"result":"THE REVIEW"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR" >/dev/null 2>&1
assert_eq "output.txt is the review, not an error" "THE REVIEW" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 20: a DICT entry in errors[] reports its message, not a Python repr ===
# Every grok failure measured so far puts strings in errors[]. If xAI ever puts objects there,
# the naive `str(e)` renders `{'message': '...'}` as the whole user-facing diagnosis — the same
# class of loss Test 16 exists for, one layer in. Strings must keep their exact old rendering.
echo "=== Test 20: a dict in errors[] is not rendered as a Python repr ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"errors":[{"message":"unknown effort level max"}]}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR" >/dev/null 2>&1
assert_eq "dict entry: message extracted" "API Error: unknown effort level max" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["plain string",{"message":"from a dict"}]}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR" >/dev/null 2>&1
assert_eq "mixed entries: both rendered, order kept" "API Error: plain string; from a dict" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 21: a SPLIT stream extracts the review, not the wake-up tail ===
# progress-monitor.sh appends every segment of a resumed run to one raw.jsonl, so a run that
# dispatches a background subagent ends with a short wake-up turn. Taking the LAST result event
# discarded the review in 36 of the 59 multi-result streams on this machine — up to 16817 of
# 17882 characters, this repository's own 2026-08-29 review included. Ties go to the LAST, so
# single-result streams keep byte-parity with progress-monitor.sh; Tests 1-20 above are that
# parity and must stay green.
echo "=== Test 21: the longest result wins on a split stream ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":20,"result":"THE_REAL_REVIEW_IS_LONG"}' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"origin":{"kind":"task-notification"},"result":"woke up"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "split stream: exit 0" "0" "$RC"
assert_eq "split stream: the review wins, not the tail" "THE_REAL_REVIEW_IS_LONG" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# The REFUTED alternative, pinned so nobody re-derives it: skipping task-notification events
# reads like the semantic fix and breaks 64 archived streams — the marker records how a turn
# STARTED, not what it carries, and it sits on 22 of the 23 tails that ARE the answer. Here the
# task-notification event is the longest, and it must win.
echo "=== Test 22: a task-notification event still wins when it is the longest ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"result":"short interim"}' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"origin":{"kind":"task-notification"},"result":"THE_ANSWER_ARRIVED_ON_THE_WAKE_UP_TURN"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "wake-up turn carrying the answer: exit 0" "0" "$RC"
assert_eq "…is not skipped for its origin" "THE_ANSWER_ARRIVED_ON_THE_WAKE_UP_TURN" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# Ties go to the LAST — the rule that keeps every single-result stream byte-identical.
echo "=== Test 23: equal lengths keep the LAST, preserving parity ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"result":"AAAA"}' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"ZZZZ"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "tie: exit 0" "0" "$RC"
assert_eq "tie goes to the last" "ZZZZ" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 24: a FAILED segment never shadows a genuine review ===
# The candidate loop read length alone, so an is_error:true result longer than the review
# would win — while verify-delegation.sh judges the LAST result event and scores such a
# run REAL: the orchestrator would merge the failure text as the review.
# The failed shape is real — five historical run dirs hold {"subtype":"success",
# "is_error":true,"result":"Prompt is too long"} (subtype lies; is_error is the signal).
# Latent, not observed: across 1095 archived ext-claude+grok streams an error candidate and
# a success candidate never co-occur (swept 2026-08-30). Closed for the LAST_NT reason:
# real mechanism, cheap to exclude.
echo "=== Test 24: a longer failed segment loses to the successful review ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":true,"num_turns":95,"result":"Prompt is too long — A_VERY_LONG_FAILED_SEGMENT_THAT_MUST_NOT_WIN"}' \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":20,"result":"THE_REVIEW"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "failed+success: exit 0" "0" "$RC"
assert_eq "the success wins whatever its length" "THE_REVIEW" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 25: an error-ONLY stream still surfaces the CLI's own message ===
# 56 archived streams hold nothing but is_error:true results ("API Error: 402 Insufficient
# Balance", 429 texts, "Prompt is too long"). Excluding errors outright would extract those
# to EMPTY — the exact silence Test 16 exists to prevent. The error pool is a fallback, not
# discarded, and it keeps the result branch's trailing newline (byte-parity with the old
# behaviour on all 56).
echo "=== Test 25: error-only stream keeps the error text, with the result newline ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"result":"API Error: 402 Insufficient Balance"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "error-only: exit 0" "0" "$RC"
assert_eq "error-only: the message survives" "API Error: 402 Insufficient Balance" "$(cat "$TDIR/output.txt")"
assert_eq "error-only: result-branch newline kept (35 + 1)" "36" "$(stat -c %s "$TDIR/output.txt")"
rm -rf "$TDIR"

# === Test 26: among errors only, the LONGEST still wins ===
# The fallback pool follows the same longest-ties-last rule as the primary one; a "last
# error" or "first error" shortcut would flip which text the 56 archived error-only
# streams extract. First-longer-wins pins the rule against both shortcuts.
echo "=== Test 26: multiple errors, no success -> longest error wins ==="
TDIR=$(mktemp -d)
printf '%s\n' \
    '{"type":"result","subtype":"success","is_error":true,"num_turns":2,"result":"API Error: the long first failure text"}' \
    '{"type":"result","subtype":"success","is_error":true,"num_turns":3,"result":"API Error"}' \
    > "$TDIR/raw.jsonl"
python3 "$EXTRACT" "$TDIR"; RC=$?
assert_eq "errors-only: exit 0" "0" "$RC"
assert_eq "errors-only: the longest error is kept" "API Error: the long first failure text" "$(cat "$TDIR/output.txt")"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
