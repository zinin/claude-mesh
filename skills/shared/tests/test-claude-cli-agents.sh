#!/usr/bin/env bash
# Presence contract for the Grok-host Claude CLI wrappers (spec §4).
#
# claude-code-reviewer / claude-executor dispatch official `claude -p` via
# ext-claude-exec HOST_CLAUDE=1. Catalog aliases (opus, fable), no tooling
# constraint, run dirs under runs/claude/. Task 6 appends dual-path asserts
# for all ten wrappers; this file starts with the three new paths only so
# Test 6 in test-command-sync.sh stays grok-specific.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"

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

assert_ge() {
    local desc="$1" min="$2" actual="$3"
    case "$actual" in
        ''|*[!0-9]*)
            FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected a count >= $min, got '$actual' — did the file move?)"
            return ;;
    esac
    if [ "$actual" -ge "$min" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc ($actual >= $min)"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected >= $min, got $actual)"
    fi
}

echo "=== Test: claude CLI reviewer, executor, review skill ==="
assert_eq "reviewer agent exists" "1" "$([ -f "$REPO/agents/claude-code-reviewer.md" ] && echo 1 || echo 0)"
assert_eq "executor agent exists" "1" "$([ -f "$REPO/agents/claude-executor.md" ] && echo 1 || echo 0)"
assert_eq "review skill exists" "1" "$([ -f "$REPO/skills/claude-code-review/SKILL.md" ] && echo 1 || echo 0)"
assert_ge "reviewer requires MODEL on first line" "1" \
    "$(grep -c 'MODEL is REQUIRED on the first line' "$REPO/agents/claude-code-reviewer.md")"
assert_ge "reviewer names HOST_CLAUDE" "1" \
    "$(grep -c 'HOST_CLAUDE=1' "$REPO/skills/claude-code-review/SKILL.md")"
assert_eq "review skill has no tooling-constraint section" "0" \
    "$(grep -c '## Tooling constraint' "$REPO/skills/claude-code-review/SKILL.md")"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
