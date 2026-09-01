#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$TESTS_DIR/../../ext-claude-exec/host-claude-env.sh"
FAIL=0
PASS=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"; fi
}
# Simulate a leftover parent-shell leak from a previous ext-claude export.
export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
export ANTHROPIC_AUTH_TOKEN="tkn-zai"
export ANTHROPIC_API_KEY="should-go"
export ANTHROPIC_MODEL="glm-5.1"
export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.1"
export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.1"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5.1"
export CLAUDE_CODE_SUBAGENT_MODEL="glm-5.1"
export CLAUDE_CODE_USE_BEDROCK="1"
export CLAUDE_CODE_USE_VERTEX="1"
export CLAUDE_CODE_ATTRIBUTION_HEADER="1"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="200000"
# shellcheck source=/dev/null
. "$HELPER"
assert_eq "BASE_URL unset" "" "${ANTHROPIC_BASE_URL:-}"
assert_eq "AUTH_TOKEN unset" "" "${ANTHROPIC_AUTH_TOKEN:-}"
assert_eq "API_KEY unset" "" "${ANTHROPIC_API_KEY:-}"
assert_eq "MODEL unset" "" "${ANTHROPIC_MODEL:-}"
assert_eq "OPUS unset" "" "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
assert_eq "SONNET unset" "" "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
assert_eq "HAIKU unset" "" "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
assert_eq "SUBAGENT unset" "" "${CLAUDE_CODE_SUBAGENT_MODEL:-}"
assert_eq "BEDROCK unset" "" "${CLAUDE_CODE_USE_BEDROCK:-}"
assert_eq "VERTEX unset" "" "${CLAUDE_CODE_USE_VERTEX:-}"
assert_eq "ATTRIBUTION unset" "" "${CLAUDE_CODE_ATTRIBUTION_HEADER:-}"
assert_eq "COMPACT unset" "" "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
