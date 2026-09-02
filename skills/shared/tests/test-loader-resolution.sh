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

assert_match_snippet() {   # desc, pattern, text — pins that the guard survived extraction
    local desc="$1" pat="$2" txt="$3"
    if printf '%s' "$txt" | tail -1 | grep -q -- "$pat"; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (last line: $(printf '%s' "$txt" | tail -1))"; fi
}
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

PRIMARY='LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"'
# The two roots are searched in PRIORITY order, never in one find over both: `sort -V`
# compares whole paths and `.claude` < `.grok`, so a single find picked the .grok copy
# whatever its version — the same class of silent mis-resolution as the original `head -1`.
FALLBACK='[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '"'"'*claude-mesh*/skills/shared/config-loader.sh'"'"' 2>/dev/null | sort -V | tail -1)" || true'
FALLBACK2='[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.grok/plugins -path '"'"'*claude-mesh*/skills/shared/config-loader.sh'"'"' 2>/dev/null | sort -V | tail -1)" || true'
# installed-plugins is searched only inside a Grok session (GROK_SESSION_ID set) — see Test 6.
FALLBACK_INST='[ -f "$LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || LOADER="$(find "$HOME"/.grok/installed-plugins -path '"'"'*claude-mesh*/skills/shared/config-loader.sh'"'"' 2>/dev/null | sort -V | tail -1)" || true'

# === Test 1: every command site uses the same resolver ===
# The counts are a deliberate canary, not incidental. A new command that resolves the loader
# SHOULD break this test — bump the numbers once you have checked the new site uses the same
# two lines. Deleting the assertion instead is how the six copies silently drift apart.
#
# mesh-review.md went 2 -> 3 with the multi-model claude reviewers: Step 2.4 (the Claude-model
# selection page) re-resolves the loader because Q1's AskUserQuestion sits between it and
# Step 1, so its Bash call runs in a fresh shell where $LOADER no longer exists.
# mesh-review.md went 3 -> 4 with the watch-runs.sh call site: the Step 5a watch block needs
# $WATCH, and it runs in a Bash call of its own where $LOADER from any earlier block is gone.
# That site's fence is indented (it sits in a numbered list), which is why the counts below
# strip leading whitespace — deliberate, not sloppy.
# mesh-review.md went 4 -> 5 with the grok engine: Step 2.45 (the grok-model selection page)
# reads defaults.code_review.grok_models for its recommended set, and Step 2.1's
# AskUserQuestion sits between it and Step 1 — same fresh-shell reason as Step 2.4's site.
# Checked: the new site uses these same two lines, byte for byte.
echo "=== Test 1: resolver present and in sync across command files ==="
# Leading whitespace is stripped first: the Step 5a site sits inside a numbered list
# item, so its fence is indented. This canary is about content drift, not indentation.
n_primary=$(sed 's/^[[:space:]]*//' "$CMD_DIR"/*.md | grep -Fxc "$PRIMARY")
n_fallback=$(sed 's/^[[:space:]]*//' "$CMD_DIR"/*.md | grep -Fxc "$FALLBACK")
n_fallback2=$(sed 's/^[[:space:]]*//' "$CMD_DIR"/*.md | grep -Fxc "$FALLBACK2")
n_fallback_inst=$(sed 's/^[[:space:]]*//' "$CMD_DIR"/*.md | grep -Fxc "$FALLBACK_INST")
assert_eq "7 primary lines across commands/" "7" "$n_primary"
assert_eq "7 .claude fallback lines across commands/" "7" "$n_fallback"
assert_eq "7 .grok fallback lines across commands/" "7" "$n_fallback2"
assert_eq "7 installed-plugins fallback lines across commands/" "7" "$n_fallback_inst"
# Neither root may be searched together with the other in one find.
assert_eq "0 cross-root finds remain" "0" \
    "$(grep -c '.claude/plugins "$HOME"/.grok/plugins' "$CMD_DIR"/*.md | awk -F: '{s+=$2} END {print s+0}')"
assert_eq "mesh-review.md carries 5" "5" \
    "$(sed 's/^[[:space:]]*//' "$CMD_DIR/mesh-review.md" | grep -Fxc "$PRIMARY")"
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
# Five lines: the substituted primary, installed-plugins find, .claude find, .grok find,
# then the guard. The window must cover the guard — extracting too few lines silently
# dropped it and Test 5 then passed a snippet that could not fail.
SNIPPET="$(grep -Fx -A4 -h "$PRIMARY" "$CMD_DIR/mesh-review.md" | grep -v '^--$' | head -5)"
echo "=== extraction ==="
assert_eq "snippet extracted (5 lines)" "5" "$(printf '%s' "$SNIPPET" | grep -c '')"
assert_match_snippet "…and the last line is the not-found guard" '\[ -f "$LOADER" \] || {' "$SNIPPET"

# Run the extracted snippet under a controlled HOME / plugin root. rc is asserted too:
# an empty $GOT must mean "resolver found nothing", never "the snippet failed to run".
run_snippet() {   # $1 = HOME, $2 = CLAUDE_PLUGIN_ROOT, $3 = GROK_SESSION_ID (empty = not a Grok session)
    GOT=$(HOME="$1" CLAUDE_PLUGIN_ROOT="$2" GROK_SESSION_ID="${3:-}" bash -c "$SNIPPET"$'\n''printf %s "$LOADER"' 2>/dev/null); RC=$?
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

# === Test 6: installed-plugins is a Grok-session root ===
# The unpublished snapshot outranks the Claude cache only when GROK_SESSION_ID is set — bash
# inside Grok Build has it, Claude Code does not (measured 2026-09-01). A Claude Code session on
# a machine that also runs Grok smokes must not execute that snapshot: it falls behind the tree
# the moment a commit lands (decided 2026-09-02).
echo "=== Test 6: installed-plugins wins only inside a Grok session ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.12.0/skills/shared" \
         "$TDIR/home/.grok/installed-plugins/claude-mesh-aabbccdd/skills/shared"
: > "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.12.0/skills/shared/config-loader.sh"
: > "$TDIR/home/.grok/installed-plugins/claude-mesh-aabbccdd/skills/shared/config-loader.sh"
run_snippet "$TDIR/home" "" "grok-session-1"
assert_eq "snippet ran cleanly (Grok session)" "0" "$RC"
assert_eq "Grok session: the snapshot wins" "$TDIR/home/.grok/installed-plugins/claude-mesh-aabbccdd/skills/shared/config-loader.sh" "$GOT"
run_snippet "$TDIR/home" ""
assert_eq "snippet ran cleanly (no Grok session)" "0" "$RC"
assert_eq "no Grok session: the Claude cache wins" "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.12.0/skills/shared/config-loader.sh" "$GOT"
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

# === Test 7: missing installed-plugins must not abort under set -euo pipefail ===
# Marketplace Grok: GROK_SESSION_ID is set, ~/.grok/installed-plugins does not exist,
# the Claude cache does. `find` on a missing dir is rc=1; with pipefail that used to
# kill the last `||` arm under `set -e` before the .claude fallback (measured 2026-09-02).
# Command fences themselves are `set -u` only; skill launch fences are `set -euo pipefail`.
# Run the live command snippet under -e so a missing `|| true` cannot hide here.
echo "=== Test 7: missing installed-plugins does not abort under set -euo pipefail ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.12.0/skills/shared"
: > "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.12.0/skills/shared/config-loader.sh"
GOT=$(HOME="$TDIR/home" CLAUDE_PLUGIN_ROOT="" GROK_SESSION_ID="grok-session-1" \
    bash -c 'set -euo pipefail
'"$SNIPPET"'
printf %s "$LOADER"'); RC=$?
assert_eq "strict snippet ran cleanly" "0" "$RC"
assert_eq "falls through to the Claude cache" \
    "$TDIR/home/.claude/plugins/cache/zinin/claude-mesh/0.12.0/skills/shared/config-loader.sh" "$GOT"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
