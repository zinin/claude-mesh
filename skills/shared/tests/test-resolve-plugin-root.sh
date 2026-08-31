#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../resolve-plugin-root.sh"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"
FAIL=0; PASS=0
assert_eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1"; else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi; }
# From a skill directory, walking up should find the repo's config-loader.
GOT=$(SKILL_BASE="$REPO/skills/ext-claude-exec" "$SCRIPT")
assert_eq "SKILL_BASE=skill dir → plugin root" "$REPO" "$GOT"
GOT=$(CLAUDE_PLUGIN_ROOT="$REPO" SKILL_BASE= "$SCRIPT")
assert_eq "CLAUDE_PLUGIN_ROOT wins when SKILL_BASE empty" "$REPO" "$GOT"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
