#!/usr/bin/env bash
# What grok-code-review's pre-flight does with the values the CALLER supplies.
#
# MODEL and BASE_BRANCH are substituted into the skill's fences as text, so the substitution is
# an executable context and a hostile value is a code path, not a string. The file already binds
# DESC, PLAN_REF and WORK_DIR through quoted heredocs for exactly that reason, and grok-exec
# binds MODEL the same way — these two lines had been left in double-quoted assignments, with
# the catalog check sitting a line BELOW the assignment that would already have run the value.
#
# Like test-grok-effort-resolution.sh, this EXTRACTS the fences from SKILL.md and EXECUTES them:
# a grep for `heredoc` would pass on a file that merely mentions one.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$TESTS_DIR/../../grok-code-review/SKILL.md"

FAIL=0
PASS=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

[ -f "$SKILL" ] || { echo "FAIL: grok-code-review/SKILL.md not found at $SKILL"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CANARY="$T/executed"

# The value a hostile caller would send. If the binding is an executable context, the `touch`
# runs; if it is a quoted heredoc, the whole thing stays one opaque string.
HOSTILE='x"; touch '"$CANARY"'; y="'

echo "=== grok-code-review caller-value bindings ==="

# --- MODEL -------------------------------------------------------------------------------
# Take the binding and the two guards that follow it, with a catalog that does NOT list the
# hostile value, so a correct fence STOPs on the membership check.
awk '/^MODEL=/ {found=1} found {print} found && /grep -Fxq/ {exit}' "$SKILL" > "$T/model-raw.sh"
if [ ! -s "$T/model-raw.sh" ]; then
    bad "the MODEL binding could not be located in SKILL.md"
else
    ok "the MODEL binding and its guards were located"
    {   printf 'GROK_CAT=$(printf %%s "grok-4.6")\n'
        sed "s|<the MODEL argument this skill was called with>|$HOSTILE|" "$T/model-raw.sh"
    } > "$T/model.sh"
    OUT=$(bash "$T/model.sh" 2>&1); RC=$?
    if [ -e "$CANARY" ]; then
        bad "a hostile MODEL EXECUTED — the binding is a code path, not a string"
        rm -f "$CANARY"
    else
        ok "a hostile MODEL does not execute"
    fi
    case "$RC:$OUT" in
        1:*"is not in the grok.models catalog"*) ok "…and is rejected by the catalog check" ;;
        *) bad "expected the catalog check to STOP with rc=1; got rc=$RC out='$OUT'" ;;
    esac
    # The honest half: a LEGAL id must still pass, or the fence is merely broken rather than safe.
    {   printf 'GROK_CAT=$(printf %%s "grok-4.6")\n'
        sed "s|<the MODEL argument this skill was called with>|grok-4.6|" "$T/model-raw.sh"
        printf 'printf "MODEL=%%s\\n" "$MODEL"\n'
    } > "$T/model-ok.sh"
    OUT=$(bash "$T/model-ok.sh" 2>&1); RC=$?
    case "$RC:$OUT" in
        0:*"MODEL=grok-4.6"*) ok "a catalog id still passes through unchanged" ;;
        *) bad "a legal MODEL should pass; got rc=$RC out='$OUT'" ;;
    esac
fi

# --- BASE_BRANCH -------------------------------------------------------------------------
# Only the binding itself: the git commands after it need a repository and are not what this
# suite is about.
awk '/^BASE_BRANCH=/ {found=1} found {print} found && /^BASE_REF=/ {exit}' "$SKILL" > "$T/base-raw.sh"
if [ ! -s "$T/base-raw.sh" ]; then
    bad "the BASE_BRANCH binding could not be located in SKILL.md"
else
    ok "the BASE_BRANCH binding was located"
    {   sed "s|<the BASE_BRANCH argument, or leave empty to auto-detect>|$HOSTILE|" "$T/base-raw.sh" \
            | sed '/^BASE_REF=/d'
        printf 'printf "BASE_BRANCH=[%%s]\\n" "$BASE_BRANCH"\n'
    } > "$T/base.sh"
    OUT=$(bash "$T/base.sh" 2>&1)
    if [ -e "$CANARY" ]; then
        bad "a hostile BASE_BRANCH EXECUTED — the binding is a code path, not a string"
        rm -f "$CANARY"
    else
        ok "a hostile BASE_BRANCH does not execute"
    fi
    case "$OUT" in
        *"BASE_BRANCH=[$HOSTILE]"*) ok "…and arrives whole, for the caller to be told it is wrong" ;;
        *) bad "the value did not arrive intact: '$OUT'" ;;
    esac
    # Empty means auto-detect, which is the documented default and must keep working.
    {   sed "s|<the BASE_BRANCH argument, or leave empty to auto-detect>||" "$T/base-raw.sh" \
            | sed '/^BASE_REF=/d'
        printf 'printf "BASE_BRANCH=[%%s]\\n" "$BASE_BRANCH"\n'
    } > "$T/base-empty.sh"
    OUT=$(bash "$T/base-empty.sh" 2>&1)
    case "$OUT" in
        *"BASE_BRANCH=[]"*) ok "an empty value still means auto-detect" ;;
        *) bad "an empty BASE_BRANCH should stay empty: '$OUT'" ;;
    esac
fi

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
