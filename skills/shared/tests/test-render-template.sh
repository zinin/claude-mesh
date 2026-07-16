#!/usr/bin/env bash
# Regression tests for render-template.py — literal {PLACEHOLDER} rendering.
# Born from the 2026-07-16 incident: bash 5.2 patsub_replacement expanded '&' in
# ${PROMPT//\{DESCRIPTION\}/$DESC} to the matched pattern, corrupting review prompts
# whenever CONTEXT contained shell commands like `cd x && make test`.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER="$TESTS_DIR/../render-template.py"
REAL_TEMPLATE="$TESTS_DIR/../code-review-prompt.md"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [ "${haystack#*"$needle"}" != "$haystack" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (needle '$needle' not found)"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [ "${haystack#*"$needle"}" = "$haystack" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (needle '$needle' unexpectedly present)"
    fi
}

# === Test 1: basic rendering of all four review placeholders ===
echo "=== Test 1: all placeholders replaced ==="
TDIR=$(mktemp -d)
printf '%s\n' 'range {BASE_SHA}..{HEAD_SHA}' 'desc: {DESCRIPTION}' 'plan: {PLAN_REFERENCE}' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" BASE_SHA=abc1234 HEAD_SHA=def5678 DESCRIPTION='added heartbeat' PLAN_REFERENCE='No formal plan'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "rendered output" "range abc1234..def5678
desc: added heartbeat
plan: No formal plan" "$OUT"
rm -rf "$TDIR"

# === Test 2: incident repro — '&&' in DESCRIPTION stays literal (bash 5.2 patsub_replacement) ===
echo "=== Test 2: && in value stays literal ==="
TDIR=$(mktemp -d)
printf '%s\n' 'Context: {DESCRIPTION} <end>' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION='cd test-server && python3 -m unittest'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "&& preserved verbatim" "Context: cd test-server && python3 -m unittest <end>" "$OUT"
rm -rf "$TDIR"

# === Test 3: backslash/ampersand zoo stays literal ===
echo "=== Test 3: & \\& \\\\ literal ==="
TDIR=$(mktemp -d)
printf '%s\n' 'V: {DESCRIPTION}' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION='lone & then \& then \\ end'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "specials preserved" 'V: lone & then \& then \\ end' "$OUT"
rm -rf "$TDIR"

# === Test 4: multi-line value ===
echo "=== Test 4: multi-line value ==="
TDIR=$(mktemp -d)
printf '%s\n' 'D: {DESCRIPTION} :end' > "$TDIR/t.md"
ML=$'line1 && a\nline2 & b'
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION="$ML"); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "multi-line preserved" "D: line1 && a
line2 & b :end" "$OUT"
rm -rf "$TDIR"

# === Test 5: single-pass — placeholder text inside a value is NOT re-substituted ===
echo "=== Test 5: injected {PLAN_REFERENCE} in value stays literal ==="
TDIR=$(mktemp -d)
printf '%s\n' 'desc: {DESCRIPTION}' 'plan: {PLAN_REFERENCE}' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION='quote: {PLAN_REFERENCE} and {braces} kept' PLAN_REFERENCE='REAL_PLAN'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "value not re-scanned" "desc: quote: {PLAN_REFERENCE} and {braces} kept
plan: REAL_PLAN" "$OUT"
rm -rf "$TDIR"

# === Test 6: unknown placeholder in template left intact ===
echo "=== Test 6: unknown placeholder untouched ==="
TDIR=$(mktemp -d)
printf '%s\n' 'known: {DESCRIPTION} unknown: {UNKNOWN_KEY}' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION=x); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "unknown survives" "known: x unknown: {UNKNOWN_KEY}" "$OUT"
rm -rf "$TDIR"

# === Test 7: key absent from template is a no-op ===
echo "=== Test 7: extra key ignored ==="
TDIR=$(mktemp -d)
printf '%s\n' 'plain text' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION='whatever'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "template unchanged" "plain text" "$OUT"
rm -rf "$TDIR"

# === Test 8: empty value replaces with empty string ===
echo "=== Test 8: empty value ==="
TDIR=$(mktemp -d)
printf '%s\n' 'D:[{DESCRIPTION}]' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION=); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "empty substitution" "D:[]" "$OUT"
rm -rf "$TDIR"

# === Test 9: value containing '=' splits on FIRST '=' only ===
echo "=== Test 9: '=' inside value ==="
TDIR=$(mktemp -d)
printf '%s\n' 'D: {DESCRIPTION}' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" DESCRIPTION='a=b && c=d'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "= preserved in value" "D: a=b && c=d" "$OUT"
rm -rf "$TDIR"

# === Test 10: repeated placeholder replaced everywhere ===
echo "=== Test 10: repeated placeholder ==="
TDIR=$(mktemp -d)
printf '%s\n' '{HEAD_SHA} and again {HEAD_SHA}' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" "$TDIR/t.md" HEAD_SHA=fff000); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_eq "both occurrences" "fff000 and again fff000" "$OUT"
rm -rf "$TDIR"

# === Test 11: usage errors -> exit 2, nothing on stdout ===
echo "=== Test 11: usage errors ==="
TDIR=$(mktemp -d)
printf '%s\n' 'x' > "$TDIR/t.md"
OUT=$(python3 "$RENDER" 2>/dev/null); RC=$?
assert_eq "no args -> exit 2" "2" "$RC"
assert_eq "no args -> empty stdout" "" "$OUT"
OUT=$(python3 "$RENDER" "$TDIR/t.md" NOEQUALSIGN 2>/dev/null); RC=$?
assert_eq "pair without '=' -> exit 2" "2" "$RC"
assert_eq "pair without '=' -> empty stdout" "" "$OUT"
OUT=$(python3 "$RENDER" "$TDIR/t.md" 'BAD-NAME=x' 2>/dev/null); RC=$?
assert_eq "invalid name -> exit 2" "2" "$RC"
OUT=$(python3 "$RENDER" "$TDIR/t.md" '1LEADING=x' 2>/dev/null); RC=$?
assert_eq "digit-leading name -> exit 2" "2" "$RC"
rm -rf "$TDIR"

# === Test 12: unreadable template -> exit 3 ===
echo "=== Test 12: missing template ==="
OUT=$(python3 "$RENDER" /nonexistent/template.md DESCRIPTION=x 2>/dev/null); RC=$?
assert_eq "missing template -> exit 3" "3" "$RC"
assert_eq "missing template -> empty stdout" "" "$OUT"

# === Test 13: acceptance dry-run — real shared template + incident-style CONTEXT ===
echo "=== Test 13: real code-review-prompt.md with hostile CONTEXT ==="
CTX='Adds CDR heartbeat classification. Verify: cd test-server && python3 -m unittest discover -s tests & watch \& logs'
OUT=$(python3 "$RENDER" "$REAL_TEMPLATE" \
    BASE_SHA=1111aaa HEAD_SHA=2222bbb \
    DESCRIPTION="$CTX" \
    PLAN_REFERENCE='No formal plan - review for general quality'); RC=$?
assert_eq "exit 0" "0" "$RC"
assert_contains "CONTEXT verbatim in output" "$CTX" "$OUT"
assert_contains "git range filled" 'git diff 1111aaa..2222bbb' "$OUT"
assert_not_contains "no {DESCRIPTION} left" '{DESCRIPTION}' "$OUT"
assert_not_contains "no {BASE_SHA} left" '{BASE_SHA}' "$OUT"
assert_not_contains "no {HEAD_SHA} left" '{HEAD_SHA}' "$OUT"
assert_not_contains "no {PLAN_REFERENCE} left" '{PLAN_REFERENCE}' "$OUT"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
