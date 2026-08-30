#!/usr/bin/env bash
# Holds the two fresh-session review-prompt generators in sync where they must be identical.
#
# commands/design-review-fresh-session.md and commands/code-review-fresh-session.md each embed
# a prompt template for a FRESH Claude Code session. Six regions of that template are shared
# (the SYNC note at the top of both files enumerates all six); two of them must be identical to
# the byte:
#
#   DO NOT    — the gate that stops a review session from implementing the plan instead. Its
#               exact wording is an EXPERIMENTAL result: a 5-run A/B against a no-gate control
#               held 5/5 while the control failed 3/3 (docs/superpowers/verification/
#               2026-08-02-fresh-session-baseline.md). Line breaks and the em dash are part of
#               what was measured. Reword it in one file and that path silently ships an
#               untested gate — nothing breaks, nothing warns, the session just starts coding.
#   PREFLIGHT — the probe-discovery block plus the rules for reading its verdicts. A drift here
#               sends one of the two paths at a stale probe, or softens a verdict.
#
# Until this suite existed, both were held by a comment alone.
#
# Test 5 guards something else: design decision 1, "the generators never read config.yaml".
# That is the branch's central decision, and every other trace of it disappears before the PR —
# the baseline record and the design both live under docs/superpowers/, and the generated
# prompts that demonstrate it were never tracked. What survives here is its statically
# checkable half.
#
# Assertion 3 compares the shipped DO NOT block against the measured wording in the baseline
# record. That record lives under docs/superpowers/, which is `git rm`'d before any PR — so on
# master the file is absent and assertion 3 SKIPS with a note. It must never fail for absence;
# assertions 1-2 read only commands/*.md and stay hard everywhere.
#
# Test 6 is the odd one out and deliberately so: it reads the two ORCHESTRATORS, not the
# generators, and asserts absolute facts about each rather than equality between them. Its own
# header says why an equality check would be the wrong tool there.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"
CMD_DIR="$REPO/commands"

DESIGN_CMD="$CMD_DIR/design-review-fresh-session.md"
CODE_CMD="$CMD_DIR/code-review-fresh-session.md"
BASELINE="$REPO/docs/superpowers/verification/2026-08-02-fresh-session-baseline.md"
BASELINE_HEADING='## The winning `DO NOT` wording'

FAIL=0
PASS=0
SKIP=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

# Multi-line comparison: on failure print the diff, because "two 17-line blocks differ" is
# not actionable on its own.
assert_identical() {
    local desc="$1" a="$2" b="$3"
    if [ "$a" = "$b" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc"
        diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/        /'
    fi
}

# Numeric floor, for a fact whose exact count is not a contract: a phrase that legitimately
# occurs several times, where zero is the failure and 7-versus-5 is not. A non-numeric actual
# (grep on a file that moved prints nothing) is a FAILURE, not a silent pass.
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

assert_differs() {
    local desc="$1" a="$2" b="$3"
    if [ "$a" != "$b" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (the two are identical — the extractor is not discriminating)"
    fi
}

assert_nonempty() {
    local desc="$1" v="$2"
    if [ -n "$v" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (extracted nothing)"
    fi
}

skip() {
    SKIP=$((SKIP+1)); echo "  SKIP: $1"
}

# --- normalisation -----------------------------------------------------------------------
# The ONLY normalisation in this suite, and it exists for one named reason. The two extractors
# below use different delimiters: extract_section cuts at the NEXT `## ` heading and therefore
# carries the blank line that separates the block from that heading, while extract_fenced cuts
# at a ``` fence and carries no such line. Stripping TRAILING BLANK LINES makes the two
# delimiters comparable — and does nothing else. Leading whitespace, whitespace inside a line,
# case and every character of the wording are left exactly as written, so a real difference
# still fails. Widening this function is how a genuine drift gets absorbed later.
strip_trailing_blanks() {
    awk '{ l[NR] = $0 }
         END { last = NR
               while (last > 0 && l[last] == "") last--
               for (i = 1; i <= last; i++) print l[i] }'
}

# extract_section <file> <heading, matched as an exact line prefix>
# From the heading line through the line before the next `## ` heading.
extract_section() {
    awk -v START="$2" '
        !on && index($0, START) == 1 { on = 1; print; next }
        on && /^## / { exit }
        on { print }
    ' "$1" | strip_trailing_blanks
}

# extract_fenced <file> <heading, matched as an exact line prefix>
# The first ```-fenced block following that heading. Used for the baseline record, where the
# wording is quoted inside a fence rather than living under a heading of its own.
extract_fenced() {
    awk -v START="$2" '
        !h && index($0, START) == 1 { h = 1; next }
        h && !inb && /^```/ { inb = 1; next }
        h && inb && /^```/  { exit }
        h && inb { print }
    ' "$1" | strip_trailing_blanks
}

DESIGN_DONOT="$(extract_section "$DESIGN_CMD" '## DO NOT')"
CODE_DONOT="$(extract_section "$CODE_CMD" '## DO NOT')"
DESIGN_PREFLIGHT="$(extract_section "$DESIGN_CMD" '## PREFLIGHT')"
CODE_PREFLIGHT="$(extract_section "$CODE_CMD" '## PREFLIGHT')"

# === Test 1: the extraction is not vacuous ===
# A checksum over an empty or wrongly-delimited range proves nothing, and this plan's review
# loop has already caught two gates that could not fail. The line counts are deliberate
# canaries: if you legitimately change a block, update the number here on purpose — do not
# delete the assertion.
echo "=== Test 1: extraction is non-vacuous and discriminating ==="
# Emptiness is asserted separately from the line counts on purpose: `printf '%s\n' ""` is ONE
# line, so a count assertion whose expected value ever became 1 would pass on an extraction
# that found nothing. These four make that impossible regardless of what the counts become.
assert_nonempty "design DO NOT extracted"     "$DESIGN_DONOT"
assert_nonempty "code DO NOT extracted"       "$CODE_DONOT"
assert_nonempty "design PREFLIGHT extracted"  "$DESIGN_PREFLIGHT"
assert_nonempty "code PREFLIGHT extracted"    "$CODE_PREFLIGHT"
assert_eq "design DO NOT is 7 lines"      "7"  "$(printf '%s\n' "$DESIGN_DONOT" | grep -c '')"
assert_eq "code DO NOT is 7 lines"        "7"  "$(printf '%s\n' "$CODE_DONOT" | grep -c '')"
assert_eq "design PREFLIGHT is 17 lines"  "17" "$(printf '%s\n' "$DESIGN_PREFLIGHT" | grep -c '')"
assert_eq "code PREFLIGHT is 17 lines"    "17" "$(printf '%s\n' "$CODE_PREFLIGHT" | grep -c '')"
assert_eq "design DO NOT starts at its heading" "## DO NOT" "$(printf '%s\n' "$DESIGN_DONOT" | head -1)"
assert_eq "code DO NOT starts at its heading"   "## DO NOT" "$(printf '%s\n' "$CODE_DONOT" | head -1)"
# The two blocks of the SAME file must come out different, or the extractor is returning
# something other than what it claims and every identity assertion below is meaningless.
assert_differs "DO NOT and PREFLIGHT extract to different text" "$CODE_DONOT" "$CODE_PREFLIGHT"

# === Test 2: the measured DO NOT gate is byte-identical across the pair ===
echo "=== Test 2: DO NOT is byte-identical in both command files ==="
assert_identical "DO NOT: design == code" "$DESIGN_DONOT" "$CODE_DONOT"

# === Test 3: the preflight block is byte-identical across the pair ===
echo "=== Test 3: PREFLIGHT is byte-identical in both command files ==="
assert_identical "PREFLIGHT: design == code" "$DESIGN_PREFLIGHT" "$CODE_PREFLIGHT"

# === Test 4: the shipped gate still matches the wording that was actually measured ===
# Tests 2-3 only prove the two files agree — they would both stay green if someone reworded
# the gate in BOTH. This one pins the pair to the experiment.
echo "=== Test 4: DO NOT matches the measured baseline wording ==="
if [ ! -f "$BASELINE" ]; then
    skip "baseline record absent ($BASELINE) — expected on master, docs/superpowers/ is removed before a PR"
else
    BASELINE_DONOT="$(extract_fenced "$BASELINE" "$BASELINE_HEADING")"
    assert_nonempty "baseline block extracted" "$BASELINE_DONOT"
    assert_eq "baseline block is 7 lines" "7" "$(printf '%s\n' "$BASELINE_DONOT" | grep -c '')"
    assert_identical "DO NOT: shipped == measured" "$BASELINE_DONOT" "$CODE_DONOT"
fi

# === Test 5: neither generator invokes the config loader ===
# Decision 1 in prose is a paragraph in each file telling the generating session not to read
# the local config; nothing checked that the files obey it. They do so today by containing no
# invocation at all, which is a property a grep can hold.
#
# TWO patterns, because either alone is evadable in an obvious way:
#   1. `config-loader.sh <subcommand>` — a direct call, executable or quoted as an example.
#   2. every mention must be the BARE inline-code span the prohibition itself uses. An
#      assignment (`LOADER="$DIR/config-loader.sh"`) followed by `"$LOADER" list-models` slips
#      past pattern 1 entirely, and so does a bare-word call; neither can spell the name as a
#      lone `code span`.
# The prohibition line in each file is prose and is the ONLY permitted mention — pattern 1 does
# not match it (a backtick follows the name, not a subcommand) and pattern 2 is what it is.
#
# LOADER_SUBCMDS is the loader's full vocabulary — the alternation pattern 1 looks for AFTER
# the script name. It does NOT pin what the orchestrators may call; it widens what these two
# GENERATORS are forbidden to invoke. A subcommand missing from it is a hole of exactly that
# width: a generator could write `config-loader.sh get-grok` and pattern 1 would not see it.
# Keep it equal to the case arms at the bottom of config-loader.sh.
echo "=== Test 5: the generators never read the local config ==="
LOADER_SUBCMDS='validate|data-dir|export|get-flag|list-models|list-claude-models|list-grok-models|list-providers|get-defaults|get-runtime|get-codex|get-gemini|get-grok'
for CMD_FILE in "$DESIGN_CMD" "$CODE_CMD"; do
    CMD_NAME="$(basename "$CMD_FILE")"
    assert_eq "$CMD_NAME: no config-loader.sh <subcommand> invocation" "0" \
        "$(grep -cE "config-loader\.sh[[:space:]]+($LOADER_SUBCMDS)" "$CMD_FILE" || true)"
    TOTAL="$(grep -o 'config-loader\.sh' "$CMD_FILE" | grep -c . || true)"
    QUOTED="$(grep -o '`config-loader\.sh`' "$CMD_FILE" | grep -c . || true)"
    assert_eq "$CMD_NAME: every config-loader.sh mention is a bare inline-code span" \
        "$TOTAL" "$QUOTED"
    # Both assertions above pass on a file that never names the loader at all, so this one
    # proves they had something to look at — and that the prohibition paragraph is still there.
    # A deliberate canary, like the line counts in Test 1: if a second prose mention is ever
    # legitimate, raise the number on purpose rather than deleting the assertion.
    assert_eq "$CMD_NAME: …and the prohibition itself is still in the file" "1" "$QUOTED"
done

# === Test 6: the grok orchestrator contract, asserted per file ===
# Tests 1-5 hold the two GENERATORS against EACH OTHER. The two ORCHESTRATORS
# (commands/mesh-review.md and skills/mesh-design-review/SKILL.md) are a different kind of
# pair: they are deliberately not interchangeable, so equality between them would be the wrong
# assertion — and a mistake made identically in both would satisfy it anyway. Every
# orchestrator defect this branch's review surfaced was of that shape: the wrong agent type in
# design review, a missing SELECTED_GROK_MODELS binding, an enumeration left at three engines.
# So this test asserts ABSOLUTE facts, one file at a time.
#
# The positive assertions are PRESENCE checks (>= 1), never exact counts. The design skill
# names grok-executor five times and mesh-review spells `grok:grok-4.6` seven; those are
# illustrative occurrences — the dispatch pair list, the guard spec, the status table, the
# attribution rule — and not a contract, so pinning the number would fail on the next
# legitimate paragraph. The NEGATIVE assertions stay an exact 0: absence IS the contract.
echo "=== Test 6: the grok orchestrator contract ==="
MESH_REVIEW="$CMD_DIR/mesh-review.md"
DESIGN_SKILL="$REPO/skills/mesh-design-review/SKILL.md"

# First, that both files are where this test thinks they are. Without it the `0` assertions
# below would pass on a moved file — grep prints no count and finds no forbidden string, which
# is indistinguishable from the file being correct. This is the vacuity the rest depends on.
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    if [ -f "$f" ]; then
        PASS=$((PASS+1)); echo "  PASS: ${f#"$REPO"/} is where this test reads it"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: ${f#"$REPO"/} not found — every assertion below would read nothing"
    fi
done

# Agent type per orchestrator. /mesh-design-review dispatches EXECUTORS, because it composes
# its own document-review prompt; /mesh-review dispatches the code-reviewer wrappers, which
# build a diff-review prompt of their own. Cross them and grok reviews a git diff during a
# design review — a run that looks entirely healthy while answering the wrong question.
assert_ge "design review dispatches grok-executor" "1" \
    "$(grep -c 'claude-mesh:grok-executor' "$DESIGN_SKILL")"
assert_eq "design review never dispatches grok-code-reviewer" "0" \
    "$(grep -c 'claude-mesh:grok-code-reviewer' "$DESIGN_SKILL")"
assert_ge "mesh-review dispatches grok-code-reviewer" "1" \
    "$(grep -c 'claude-mesh:grok-code-reviewer' "$MESH_REVIEW")"
assert_eq "mesh-review never dispatches grok-executor" "0" \
    "$(grep -c 'claude-mesh:grok-executor' "$MESH_REVIEW")"

# `grok_degraded` is the loader's only signal that a preset asked for grok and got nothing —
# it emits the preset with grok stripped, so the absence is otherwise invisible. Both preset
# branches must read it, or `default` mode silently runs one reviewer short of what was asked.
assert_ge "mesh-review honours grok_degraded" "1" \
    "$(grep -c 'grok_degraded' "$MESH_REVIEW")"
assert_ge "design review honours grok_degraded" "1" \
    "$(grep -c 'grok_degraded' "$DESIGN_SKILL")"
# The two above are floors on a NAME, and a name is satisfied by a passing mention in a
# comment. What the rule actually owes the user is a SENTENCE — the flag is the only signal
# that a reviewer they asked for is not running, so the orchestrator has to say so out loud.
# Pin that sentence: it is user-facing output, which no comment about the field can supply.
assert_eq "mesh-review prints the degraded notice verbatim" "1" \
    "$(grep -c 'каталог grok.models не валидируется' "$MESH_REVIEW")"
assert_eq "design review prints it too" "1" \
    "$(grep -c 'каталог grok.models не валидируется' "$DESIGN_SKILL")"

# The per-model selection list, in BOTH files. 4 is a floor, not a measurement: each
# orchestrator has to default it to empty, fill it from the config or the selection page,
# expand it into one reviewer per entry, and carry it into its own status accounting. A file
# naming it fewer than four times has dropped one of those steps.
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    assert_ge "${f#"$REPO"/} binds SELECTED_GROK_MODELS" "4" \
        "$(grep -c 'SELECTED_GROK_MODELS' "$f")"
done

# Every `ни одной …` sentinel must carry its own drop clause. The sentinel exists because
# AskUserQuestion refuses a one-option page, so each of the three model pages offers its empty
# outcome AS an option — and the instruction 13 lines below is a bare "Collect the selections
# into SELECTED_*". Read literally, that puts the sentinel STRING into the model list: the
# claude page is worst, because a list holding it is non-empty and the documented empty-selection
# fallback never fires, dispatching a reviewer whose `model:` is that sentence.
# This is exactly the defect class Test 6 exists for and Tests 1-5 cannot see: both files carried
# it identically, so comparing them to each other passed. Counted per file, and equal to the
# number of sentinels in that file, so a seventh page added without a clause fails here.
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    assert_eq "${f#"$REPO"/}: every sentinel drops before collecting" \
        "$(grep -c 'ни одной' "$f")" \
        "$(grep -c 'Selecting it IS the empty selection' "$f")"
done

# Two spellings that are never interchangeable: `grok:<model>` names a reviewer and a dispatch
# pair, `grok/<model>` is a watch-runs.sh roster entry (and the shape of the run directory).
# Swap them and the watcher waits on a roster entry no run will ever create, or the attribution
# table names a reviewer the orchestrator never dispatched. Both files use both; both must keep
# both — `grok-4.6` is the worked example each of them carries.
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    # Presence of each spelling, not of a particular line: prose mentioning `grok/grok-4.6`
    # keeps this green with the watcher roster deleted, so the pair pins that BOTH spellings
    # exist and are never swapped — never that the roster itself is there.
    assert_ge "${f#"$REPO"/}: grok/<model> spelling present, never swapped" "1" \
        "$(grep -c 'grok/grok-4\.6' "$f")"
    assert_ge "${f#"$REPO"/}: grok:<model> spelling present, never swapped" "1" \
        "$(grep -c 'grok:grok-4\.6' "$f")"
done

# No enumeration of the dispatchable engines left at three. This is the defect class a sweep
# for `grok` cannot find: a list that names every engine BUT the new one contains no token you
# would grep for. Pinned as the exact phrase because that is what such a list reads like once
# the fourth engine exists and the sentence was not touched.
assert_eq "no stale 'codex / gemini / ext-claude' enumeration" "0" \
    "$(cat "$MESH_REVIEW" "$DESIGN_SKILL" | grep -c 'codex / gemini / ext-claude')"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" = "0" ]
