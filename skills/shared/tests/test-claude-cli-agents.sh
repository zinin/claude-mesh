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
assert_eq "reviewer does not STOP when MODEL is omitted" "0" \
    "$(grep -c 'ERROR: MODEL parameter is required on first line' "$REPO/agents/claude-code-reviewer.md")"
assert_eq "executor does not STOP when MODEL is omitted" "0" \
    "$(grep -c 'ERROR: MODEL parameter is required on first line' "$REPO/agents/claude-executor.md")"
assert_ge "reviewer still invokes skill when MODEL omitted" "1" \
    "$(grep -c 'If the first line is not `MODEL=`, still invoke the skill' "$REPO/agents/claude-code-reviewer.md")"
assert_ge "executor still invokes skill when MODEL omitted" "1" \
    "$(grep -c 'If the first line is not `MODEL=`, still invoke the skill' "$REPO/agents/claude-executor.md")"
assert_ge "reviewer names HOST_CLAUDE" "1" \
    "$(grep -c 'HOST_CLAUDE=1' "$REPO/skills/claude-code-review/SKILL.md")"
assert_eq "review skill has no tooling-constraint section" "0" \
    "$(grep -c '## Tooling constraint' "$REPO/skills/claude-code-review/SKILL.md")"

echo ""
echo "=== Test: wrapper dual-path invoke + Grok wait ==="
AGENTS="$REPO/agents"
# 8 pre-existing wrappers; claude-* already have the paragraph from Task 5.
WRAPPERS="codex-code-reviewer.md codex-executor.md gemini-code-reviewer.md gemini-executor.md grok-code-reviewer.md grok-executor.md ext-claude-code-reviewer.md ext-claude-executor.md claude-code-reviewer.md claude-executor.md"
forbid=0
for f in $WRAPPERS; do
    grep -q 'Do NOT read SKILL.md' "$AGENTS/$f" && forbid=$((forbid+1))
done
assert_eq "no wrapper still forbids reading SKILL.md" "0" "$forbid"
missing=0
for f in $WRAPPERS; do
    grep -q 'If this host has no Skill tool' "$AGENTS/$f" || missing=$((missing+1))
    grep -q 'do not end the turn while the CLI is alive' "$AGENTS/$f" || missing=$((missing+1))
done
assert_eq "every wrapper has dual invoke + Grok wait" "0" "$missing"

echo ""
echo "=== Test: empty-SKILL_BASE else-branch is in the fence ==="
# Prose telling the LLM to rewrite is not enough: the executable fence must
# contain the find fallback. Every resolve-plugin-root.sh call via $SKILL_BASE
# must sit in `if [ -n "$SKILL_BASE" ]`.
SKILLS_WITH_RESOLVER="claude-code-review ext-claude-exec ext-claude-code-review codex-exec codex-code-review gemini-exec gemini-code-review grok-exec grok-code-review mesh-design-review"
mismatch=0
for s in $SKILLS_WITH_RESOLVER; do
    f="$REPO/skills/$s/SKILL.md"
    n_resolve="$(grep -c 'bash "$SKILL_BASE/../shared/resolve-plugin-root.sh"' "$f" || true)"
    n_if="$(grep -c 'if \[ -n "\$SKILL_BASE" \]; then' "$f" || true)"
    n_find="$(grep -c 'claude-mesh\*/skills/shared/config-loader.sh' "$f" || true)"
    if [ "$n_resolve" != "$n_if" ] || [ "$n_find" -lt "$n_if" ]; then
        mismatch=$((mismatch+1))
        echo "    mismatch $s: resolve=$n_resolve if=$n_if find=$n_find"
    fi
done
assert_eq "every resolver fence has empty-SKILL_BASE else-branch" "0" "$mismatch"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
