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

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
