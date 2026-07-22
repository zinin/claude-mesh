#!/usr/bin/env bash
# Regression tests for the config-loader resolution snippet that the slash commands
# duplicate (commands/mesh-review.md x2, commands/do-plan.md x2).
#
# The snippet must reach the loader of the ACTIVE plugin copy. It used to fail two ways:
#
#   1. `find "$HOME"/.claude/plugins ... | head -1` returns directory order, not version
#      order, so with several versions cached it silently picked a stale one — observed
#      picking 0.4.0 while 0.4.2 was the installed version.
#   2. It only ever looked under ~/.claude/plugins, so under a `--plugin-dir <repo>` dev
#      load the command TEXT came from the working tree while the scripts it ran came from
#      the installed cache — the copy under test was never the copy executed.
#
# ${CLAUDE_PLUGIN_ROOT} is empty as a shell VARIABLE in Bash-tool calls, but the harness
# substitutes the placeholder into slash-command TEXT — including inside ```bash fences —
# before the call, and it names the active copy incl. a --plugin-dir load (verified on CC
# 2.1.217; documented for skill/command content). So the snippet takes that path first and
# keeps a version-sorted glob as fallback for harnesses that do not substitute.
#
# These tests EXTRACT the live snippet from the markdown and execute it, so the command
# files and the assertions cannot drift apart.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"
CMD_DIR="$REPO/commands"

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

PRIMARY='LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"'
FALLBACK='[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '"'"'*claude-mesh*/skills/shared/config-loader.sh'"'"' 2>/dev/null | sort -V | tail -1)"'

# === Test 1: every command site uses the same resolver ===
# The counts are a deliberate canary, not incidental. A new command that resolves the loader
# SHOULD break this test — bump the numbers once you have checked the new site uses the same
# two lines. Deleting the assertion instead is how the four copies silently drift apart.
echo "=== Test 1: resolver present and in sync across command files ==="
n_primary=$(grep -Fxh "$PRIMARY" "$CMD_DIR"/*.md 2>/dev/null | wc -l)
n_fallback=$(grep -Fxh "$FALLBACK" "$CMD_DIR"/*.md 2>/dev/null | wc -l)
assert_eq "4 primary lines across commands/" "4" "$n_primary"
assert_eq "4 fallback lines across commands/" "4" "$n_fallback"
assert_eq "mesh-review.md carries 2" "2" "$(grep -Fxc "$PRIMARY" "$CMD_DIR/mesh-review.md")"
assert_eq "do-plan.md carries 2" "2" "$(grep -Fxc "$PRIMARY" "$CMD_DIR/do-plan.md")"

# === Test 2: the version-blind glob is gone ===
# `head -1` on the loader glob is the original defect — it must not come back anywhere.
echo "=== Test 2: no version-blind 'head -1' loader glob remains ==="
stale=$(grep -h "claude-mesh\*/skills/shared/config-loader.sh" "$CMD_DIR"/*.md 2>/dev/null | grep -c 'head -1')
assert_eq "0 occurrences of 'head -1' on the loader glob" "0" "$stale"

# --- extract the live snippet for execution ---
# Three lines, not two: the third is the `|| { echo …; exit 1; }` guard, and Test 5 below
# only means anything if it actually runs. `run_snippet` assumes the extracted block is a
# self-contained, well-formed bash fragment — it is concatenated into `bash -c`.
SNIPPET="$(grep -Fx -A2 -h "$PRIMARY" "$CMD_DIR/mesh-review.md" | grep -v '^--$' | head -3)"
echo "=== extraction ==="
assert_eq "snippet extracted (3 lines)" "3" "$(printf '%s' "$SNIPPET" | grep -c '')"

# Run the extracted snippet under a controlled HOME / plugin root. rc is asserted too:
# an empty $GOT must mean "resolver found nothing", never "the snippet failed to run".
run_snippet() {   # $1 = HOME, $2 = CLAUDE_PLUGIN_ROOT
    GOT=$(HOME="$1" CLAUDE_PLUGIN_ROOT="$2" bash -c "$SNIPPET"$'\n''printf %s "$LOADER"' 2>/dev/null); RC=$?
}

# === Test 3: substituted ${CLAUDE_PLUGIN_ROOT} wins over anything installed ===
# This is the --plugin-dir dev-load case: the working tree must beat the cached copy.
echo "=== Test 3: substituted plugin root wins over the installed cache ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/dev/skills/shared" "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/9.9.9/skills/shared"
: > "$TDIR/dev/skills/shared/config-loader.sh"
: > "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/9.9.9/skills/shared/config-loader.sh"
run_snippet "$TDIR/home" "$TDIR/dev"
assert_eq "snippet ran cleanly" "0" "$RC"
assert_eq "resolves to the dev root" "$TDIR/dev/skills/shared/config-loader.sh" "$GOT"
rm -rf "$TDIR"

# === Test 4: without substitution, the newest INSTALLED version wins ===
# 0.10.0 vs 0.9.0 — plain lexicographic sort would pick 0.9.0, so this pins `sort -V`
# and is decided by version order alone, never by the filesystem's directory order.
echo "=== Test 4: fallback picks the highest version (0.10.0 over 0.9.0) ==="
TDIR=$(mktemp -d)
for v in 0.9.0 0.10.0; do
    mkdir -p "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/$v/skills/shared"
    : > "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/$v/skills/shared/config-loader.sh"
done
run_snippet "$TDIR/home" ""
assert_eq "snippet ran cleanly" "0" "$RC"
assert_eq "resolves to 0.10.0" "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.10.0/skills/shared/config-loader.sh" "$GOT"
rm -rf "$TDIR"

# === Test 5: nothing installed and no substitution -> the guard exits 1 ===
# The point is that the call site FAILS LOUDLY rather than carrying an empty $LOADER into
# `"$LOADER" get-flag …`, where the shell would report a confusing "not found".
echo "=== Test 5: nothing to find makes the guard exit 1 ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/home/.claude/plugins"
run_snippet "$TDIR/home" ""
assert_eq "guard exits 1" "1" "$RC"
assert_eq "nothing printed" "" "$GOT"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
