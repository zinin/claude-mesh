#!/usr/bin/env bash
# What grok-exec's two execution fences actually DO when they resolve the reasoning effort.
#
# Not a grep over SKILL.md: the construct below is EXTRACTED from the file and EXECUTED against
# a stub loader, so what is pinned is behaviour, not wording. The stub answers per model, which
# is the whole point — a fence that asks the loader the whole-section question gets the
# section's answer back and this suite reddens.
#
# The fence appears TWICE (default and supervised execution) and the two must not drift: an
# edit that reaches only one of them leaves supervised runs — which is every code review — on
# the old behaviour, and that is invisible in an unsupervised smoke test.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$TESTS_DIR/../../grok-exec/SKILL.md"

FAIL=0
PASS=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
eq()  { # desc expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi
}

[ -f "$SKILL" ] || { echo "FAIL: grok-exec/SKILL.md not found at $SKILL"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The stub stands in for config-loader.sh. It answers the per-model question differently from
# the whole-section one, so the two are distinguishable from the outside.
STUB="$T/config-loader.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LOG"
case "${1:-}" in
    get-flag)
        # A loader that cannot answer the flag AT ALL — a broken grok: section. It exits
        # non-zero and says why on stderr, exactly as the real one does.
        if [ "${STUB_FLAG_RC:-0}" != "0" ]; then
            echo "config-loader: grok: must be a mapping with models/reasoning_effort keys (got boolean)" >&2
            exit "${STUB_FLAG_RC}"
        fi
        echo "${STUB_HAS_GROK:-1}"
        ;;
    get-grok)
        [ "${STUB_FAIL:-0}" = "1" ] && { echo "config-loader: the grok section does not validate" >&2; exit 1; }
        case "${2:-}" in
            grok-4.6) echo "xhigh" ;;
            "")       echo "max" ;;
            *)        echo "UNEXPECTED-MODEL:${2}" ;;
        esac
        ;;
    *) echo "UNEXPECTED-SUBCOMMAND:${1:-}" ;;
esac
STUBEOF
chmod +x "$STUB"

# Pull every occurrence of the resolution construct out of the skill: from the `if` that gates
# on an empty EFFORT down to its closing `fi`.
awk '/^if \[ -z "\$EFFORT" \]/ {inblock=1} inblock {print} inblock && /^fi$/ {inblock=0; print "@@SNIPPET-END@@"}' \
    "$SKILL" > "$T/snippets.txt"
COUNT=$(grep -c '^@@SNIPPET-END@@$' "$T/snippets.txt")

echo "=== grok-exec effort resolution ==="
# BOTH fences, pinned by number. A third one appearing, or one of the two being rewritten out
# of this shape, is a change this suite must not sit through quietly. It also guards the
# EXTRACTION itself: the awk anchor above keys on the gate's own text, so rewriting that gate
# reports "found 0" here rather than letting every assertion below pass over an empty snippet.
# Measured, not assumed — a mutation that changed the gate's wording reddened this line first.
eq "SKILL.md carries the resolution fence exactly twice" "2" "$COUNT"

run_snippet() { # $1=index  $2=preset EFFORT  $3=MODEL  -> prints "rc|EFFORT|<stdout>"
    local idx="$1" pre="$2" model="$3"
    : > "$T/one.sh"
    printf 'set -euo pipefail\nEFFORT=%q\nLOADER=%q\nMODEL=%q\n' "$pre" "$STUB" "$model" > "$T/one.sh"
    awk -v want="$idx" '
        /^@@SNIPPET-END@@$/ { n++; next }
        { if (n == want) print }
    ' "$T/snippets.txt" >> "$T/one.sh"
    # shellcheck disable=SC2016  # $EFFORT must land in the GENERATED script, not expand here
    printf 'printf "EFFORT=%%s\\n" "$EFFORT"\n' >> "$T/one.sh"
    # Both stub controls are named explicitly rather than left to bash's function-prefix
    # semantics, so it is visible that they reach the stub, which is a grandchild of this call.
    local out rc
    out=$(STUB_LOG="${STUB_LOG:-}" STUB_FAIL="${STUB_FAIL:-0}" STUB_FLAG_RC="${STUB_FLAG_RC:-0}" STUB_HAS_GROK="${STUB_HAS_GROK:-1}" bash "$T/one.sh" 2>&1); rc=$?
    printf '%s|%s\n' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

for i in 0 1; do
    LABEL=$([ "$i" = "0" ] && echo "default fence" || echo "supervised fence")

    # The model must reach the loader. This is the assertion the whole feature rests on: the
    # CLI validates --effort per model, so a fence that asks the section-wide question hands
    # every model one level and half a real catalog dies at argument parsing.
    R=$(run_snippet "$i" "" "grok-4.6")
    eq "$LABEL passes the model to the loader" "0|EFFORT=xhigh" "$R"

    # An empty MODEL is legitimate — a direct grok-exec call naming none — and must stay the
    # whole-section question rather than becoming a lookup of the empty id.
    R=$(run_snippet "$i" "" "")
    eq "$LABEL asks the section question when no model is named" "0|EFFORT=max" "$R"

    # Precedence: a caller who named a level keeps it, and the loader is never consulted.
    : > "$T/log-$i"
    R=$(STUB_LOG="$T/log-$i" run_snippet "$i" "medium" "grok-4.6")
    eq "$LABEL leaves a caller-supplied effort alone" "0|EFFORT=medium" "$R"
    if [ -s "$T/log-$i" ]; then
        bad "$LABEL consulted the loader despite a caller-supplied effort"
    else
        ok "$LABEL does not consult the loader when the caller named a level"
    fi
    # The discriminating control for the line above. An empty log proves the loader was not
    # consulted only if this same log fills when it IS — otherwise a STUB_LOG that never
    # reached the stub would make that assertion pass whatever the fence did.
    : > "$T/log-$i"
    STUB_LOG="$T/log-$i" run_snippet "$i" "" "grok-4.6" >/dev/null
    if [ -s "$T/log-$i" ]; then
        ok "$LABEL logs the call when the caller named none, so the log discriminates"
    else
        bad "$LABEL wrote nothing even where the loader IS called — the check above is vacuous"
    fi

    # A loader that cannot answer is a STOP, not a silent fall-through to the CLI default: on
    # this machine that default is codex-sol, not a grok model at all.
    R=$(STUB_FAIL=1 run_snippet "$i" "" "grok-4.6")
    case "$R" in
        1\|*STOP*) ok "$LABEL STOPs when the loader fails" ;;
        *) bad "$LABEL should STOP with rc=1 when the loader fails — got '$R'" ;;
    esac

    # The SAME treatment when the loader cannot answer the FLAG. The gate used to read it
    # inside the `if` condition under 2>/dev/null, so a broken grok: section made the whole
    # condition false and the run continued with NO --effort at all — the CLI's own default,
    # which on this machine belongs to a model this plugin never chose. Pre-flight STOPs on
    # exactly that rc, and execution has to agree with it: the two are separate Bash calls, so
    # the config can break between them.
    R=$(STUB_FLAG_RC=1 run_snippet "$i" "" "grok-4.6")
    case "$R" in
        1\|*STOP*) ok "$LABEL STOPs when the flag read itself fails" ;;
        *) bad "$LABEL should STOP with rc=1 when get-flag fails — got '$R'" ;;
    esac

    # rc=2 is "no config.yaml at all", which IS unconfigured: no --effort and no STOP. The two
    # non-zero rcs must not collapse into one.
    R=$(STUB_FLAG_RC=2 run_snippet "$i" "" "grok-4.6")
    eq "$LABEL treats rc=2 as unconfigured and passes no effort" "0|EFFORT=" "$R"

    # A plain flag of 0 — a valid config with no grok: section — stays that same quiet path.
    R=$(STUB_HAS_GROK=0 run_snippet "$i" "" "grok-4.6")
    eq "$LABEL passes no effort when the section is absent" "0|EFFORT=" "$R"
done

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
