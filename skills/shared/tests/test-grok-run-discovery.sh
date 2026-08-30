#!/usr/bin/env bash
# Which run does grok's error-recovery path pick?
#
# verify-delegation.sh answers that question by filtering on `.session_id`; the two recovery
# paths — grok-exec's Step 3 and the reviewer agent's verification block — used to answer it
# with "the newest directory under runs/grok", across every model and every session. Two runs
# of one model a minute apart is not hypothetical: it happened on this branch on 2026-08-30,
# and reading the older of the two produced the report "this reviewer is dead" about a reviewer
# that was at that moment writing its review.
#
# The fence is EXTRACTED from SKILL.md and EXECUTED, like the sibling suites: a grep for
# `.session_id` would pass on a file that only mentions it in a comment.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$TESTS_DIR/../../grok-exec/SKILL.md"

FAIL=0
PASS=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }

[ -f "$SKILL" ] || { echo "FAIL: grok-exec/SKILL.md not found at $SKILL"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R="$T/runs/grok"
MINE="session-aaaa"
THEIRS="session-bbbb"

mk() { # <model> <name> <session-id or - for none> <mtime offset seconds ago>
    local d="$R/$1/$2"; mkdir -p "$d"
    [ "$3" = "-" ] || printf '%s\n' "$3" > "$d/.session_id"
    touch -d "@$(( $(date +%s) - $4 ))" "$d"
}
# The newest directory belongs to ANOTHER session, on another model. The one this session
# actually produced is older — which is exactly the shape that misleads a plain `ls -t`.
mk grok-4.6      2026-08-30-16-32-35-1-review 	"$MINE"   300
mk glm-5-3-flash 2026-08-30-16-40-00-2-review 	"$THEIRS"  60

# Pull the selection out of Step 3: from the RUNS_DIR assignment to the empty-result guard.
awk '/^RUNS_DIR=/ {f=1} f {print} f && /No grok runs under/ {exit}' "$SKILL" > "$T/pick-raw.sh"
[ -s "$T/pick-raw.sh" ] || { echo "FAIL: could not locate Step 3's selection in SKILL.md"; exit 1; }

echo "=== grok error-recovery run discovery ==="
ok "Step 3's selection was located"

pick() { # $1 = WORK_DIR placeholder value ("" = unknown)
    {   printf 'CLAUDE_CODE_SESSION_ID=%q\n' "$MINE"
        # RUNS_DIR is computed from the loader in the real fence; substitute the fixture.
        sed -e "s|^RUNS_DIR=.*|RUNS_DIR=$(printf '%q' "$R")|" \
            -e "s|<the WORK_DIR this skill returned, or leave empty to search>|$1|" "$T/pick-raw.sh"
        printf 'printf "PICKED=%%s\\n" "${LATEST_DIR%%/}"\n'
    } > "$T/pick.sh"
    bash "$T/pick.sh" 2>&1 | sed -n 's/^PICKED=//p'
}

# 1. WORK_DIR known: it wins outright, whatever is newest on disk.
eq "a known WORK_DIR is used as given" \
   "$R/grok-4.6/2026-08-30-16-32-35-1-review" \
   "$(pick "$R/grok-4.6/2026-08-30-16-32-35-1-review")"

# 2. WORK_DIR unknown: the fallback must not cross into another session's run, even though
#    that run is the newest thing on disk.
eq "the fallback skips another session's newer run" \
   "$R/grok-4.6/2026-08-30-16-32-35-1-review" \
   "$(pick "")"

# 3. An UNSTAMPED run stays eligible — the semantics verify-delegation.sh already fixed on
#    itself: runs left by an older plugin version carry no id, and reporting a live one as
#    somebody else's would be worse than the collision it avoids.
mk grok-4.5 2026-08-30-16-45-00-3-review - 10
eq "a run with no session stamp is still eligible" \
   "$R/grok-4.5/2026-08-30-16-45-00-3-review" \
   "$(pick "")"

# 4. Nothing of ours at all: the fence still reports rather than picking a stranger's run.
rm -rf "$R"; mkdir -p "$R"
mk glm-5-3-flash 2026-08-30-16-50-00-4-review "$THEIRS" 10
OUT=$(bash <(
    printf 'CLAUDE_CODE_SESSION_ID=%q\n' "$MINE"
    sed -e "s|^RUNS_DIR=.*|RUNS_DIR=$(printf '%q' "$R")|" \
        -e "s|<the WORK_DIR this skill returned, or leave empty to search>||" "$T/pick-raw.sh"
) 2>&1)
case "$OUT" in
    *"No grok runs"*) ok "with only a stranger's run, it reports none rather than picking it" ;;
    *) bad "expected the no-runs message; got '$OUT'" ;;
esac

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
