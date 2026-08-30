#!/usr/bin/env bash
# Regression tests for shared/stream-json-report.sh — the markdown renderer two engines share
# (ext-claude and grok). It had none until the whole-branch review of feat/grok-engine found
# that it read `.message.content[0]` and nothing else: a message whose FIRST block is
# `thinking` — the norm for a reasoning model, which is what grok is — was dropped whole,
# tool call included, and a mixed message lost everything after its first block. Nothing
# decides anything from report.md (every verdict comes from output.txt), but a trace that
# silently omits a tool call reads as "the tool was never called", which is worse than a gap.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
GEN="$TESTS_DIR/../stream-json-report.sh"

FAIL=0
PASS=0

assert_contains() {
    local desc="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$needle' in output)"
    fi
}
assert_lacks() {
    local desc="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        FAIL=$((FAIL+1)); echo "  FAIL: $desc ('$needle' present)"
    else
        PASS=$((PASS+1)); echo "  PASS: $desc"
    fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

# render <jsonl lines...> -> prints the generated markdown
render() {
    local d; d=$(mktemp -d)/2026-08-30-12-00-00-1234-task
    mkdir -p "$d"
    printf '%s\n' "$@" > "$d/raw.jsonl"
    bash "$GEN" "$d/raw.jsonl" "$d/report.md" "test-model" "Test Report" "task" >/dev/null 2>&1
    cat "$d/report.md"
    rm -rf "$(dirname "$d")"
}

# === Test 1: the shapes that already worked must keep working ===
echo "=== Test 1: text, Bash tool_use and a non-Bash tool_use still render ==="
OUT=$(render \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"PLAIN_ANSWER"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo BASH_CMD"}}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/READ_TARGET"}}]}}')
assert_contains "plain text message renders" "PLAIN_ANSWER" "$OUT"
assert_contains "Bash tool renders its command" "echo BASH_CMD" "$OUT"
assert_contains "non-Bash tool renders its input" "READ_TARGET" "$OUT"
assert_contains "…and names the tool" "## Tool: Read" "$OUT"

# === Test 2: a thinking block must not swallow the tool call behind it ===
# This is the defect. `thinking` first, `tool_use` second: the whole message used to vanish.
echo "=== Test 2: thinking + tool_use — the tool call survives ==="
OUT=$(render \
    '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"SECRET_REASONING"},{"type":"tool_use","name":"Bash","input":{"command":"echo AFTER_THINKING"}}]}}')
assert_contains "the tool call is rendered" "echo AFTER_THINKING" "$OUT"
assert_contains "…under its tool heading" "## Tool: Bash" "$OUT"

# === Test 3: text and tool_use in one message — both render, not just the first ===
echo "=== Test 3: text + tool_use — neither block is lost ==="
OUT=$(render \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"NARRATION_HERE"},{"type":"tool_use","name":"Bash","input":{"command":"echo BOTH_BLOCKS"}}]}}')
assert_contains "the text block renders" "NARRATION_HERE" "$OUT"
assert_contains "the tool block renders too" "echo BOTH_BLOCKS" "$OUT"

# === Test 4: two tool calls in one message ===
echo "=== Test 4: two tool_use blocks in one message both render ==="
OUT=$(render \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo FIRST_CALL"}},{"type":"tool_use","name":"Bash","input":{"command":"echo SECOND_CALL"}}]}}')
assert_contains "first call renders" "echo FIRST_CALL" "$OUT"
assert_contains "second call renders" "echo SECOND_CALL" "$OUT"
assert_eq "two tool headings" "2" "$(printf '%s' "$OUT" | grep -c '^## Tool: Bash')"

# === Test 5: tool_result still renders ===
echo "=== Test 5: a user tool_result renders its output ==="
OUT=$(render \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"TOOL_STDOUT_HERE"}]}}')
assert_contains "tool_result output renders" "TOOL_STDOUT_HERE" "$OUT"

# === Test 6: a thinking-only message renders no empty section ===
echo "=== Test 6: a thinking-only message adds no empty section ==="
OUT=$(render \
    '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"JUST_THINKING"}]}}')
assert_lacks "thinking text is not dumped into the report" "JUST_THINKING" "$OUT"
assert_lacks "no empty Response heading" "## Response" "$OUT"

# === Test 7: parallel tool_results in ONE user message all render ===
# The mirror of Test 4, one branch over. A model that issues parallel tool calls gets one
# tool_result per call in a SINGLE user message; the branch read index 0 and dropped the rest,
# so a trace showed one answer where several tools had replied. The assistant branch was
# reworked for exactly this and its `user` twin was left behind.
echo "=== Test 7: two tool_results in one user message both render ==="
OUT=$(render \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":"FIRST_RESULT"},{"type":"tool_result","content":"SECOND_RESULT"}]}}')
assert_contains "the first tool_result renders" "FIRST_RESULT" "$OUT"
assert_contains "…and so does the second" "SECOND_RESULT" "$OUT"
assert_eq "one <details> section per result" "2" "$(printf '%s' "$OUT" | grep -c '<summary>Output')"

# The single top-level shape the other engine emits keeps precedence and is NOT indexed.
echo "=== Test 8: .tool_use_result.stdout still wins and still renders ==="
OUT=$(render \
    '{"type":"user","tool_use_result":{"stdout":"TOP_LEVEL_STDOUT"},"message":{"content":[{"type":"tool_result","content":"BLOCK_CONTENT"}]}}')
assert_contains "top-level stdout renders" "TOP_LEVEL_STDOUT" "$OUT"
assert_lacks "…and the blocks are not also rendered under it" "BLOCK_CONTENT" "$OUT"

# === Test 9: the ext-claude PREFIXED line shape reaches the block loop ===
# Every case above feeds bare JSONL — grok's shape. ext-claude writes `[HH:MM:SS] {json}`, and
# the block loop is new code that nothing drives through the prefix stripper. A regression that
# broke prefixed lines would leave this suite green.
echo "=== Test 9: prefixed [HH:MM:SS] lines render through the block loop ==="
OUT=$(render \
    '[12:34:56] {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"X"},{"type":"tool_use","name":"Bash","input":{"command":"echo PREFIXED_CMD"}}]}}' \
    '[12:34:57] {"type":"user","message":{"content":[{"type":"tool_result","content":"PREFIXED_ONE"},{"type":"tool_result","content":"PREFIXED_TWO"}]}}')
assert_contains "a prefixed assistant message renders its tool call" "echo PREFIXED_CMD" "$OUT"
assert_contains "…under the timestamp the prefix carried" "[12:34:56]" "$OUT"
assert_contains "a prefixed user message renders its first result" "PREFIXED_ONE" "$OUT"
assert_contains "…and its second" "PREFIXED_TWO" "$OUT"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
