#!/usr/bin/env bash
# Runs both shell suites once per yq flavor installed on this machine.
#
# The suites resolve bare `yq` from PATH, so pointing PATH at one flavor at a time is the whole
# mechanism — no new test machinery, only time (about 156 s per pass). What this cannot do is
# invent a flavor the machine does not have: when only one is installed it says so instead of
# reporting a pass it did not earn.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/skills/shared/tests/lib-yq-doubles.sh"
command -v find_real_go_yq >/dev/null \
    || { echo "lib-yq-doubles.sh did not provide find_real_go_yq — cannot tell a missing flavor from a missing library" >&2; exit 2; }

run_pass() {            # run_pass <label> <dir-holding-that-yq>
    local label="$1" dir="$2" rc=0
    echo "########## $label ($dir/yq: $("$dir/yq" --version 2>&1 | head -1)) ##########"
    for suite in test-config-loader.sh test-preflight-env.sh; do
        echo "--- $suite ---"
        # Keep every SKIP, not just the summary: a skipped scenario is a coverage gap, and
        # truncating it away leaves a green summary standing over an unstated one. `^PASS: ` is
        # anchored so it catches test-preflight-env.sh's differently-shaped final line without
        # also matching the indented per-assertion `  PASS:` lines in either suite.
        #
        # PIPESTATUS, not `|| rc=1`: after a pipe the shell reports the last command's status,
        # which here is grep's — 0 when it matched something, 1 when it matched nothing, and in
        # neither case the suite's. A failing suite would otherwise be recorded as a pass by the
        # very artifact whose job is to prove it passed.
        PATH="$dir:$PATH" bash "$ROOT/skills/shared/tests/$suite" \
            | grep -E '^[[:space:]]*SKIP:|^=== Summary:|^PASS: '
        [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
    done
    return $rc
}

FAILED=0
PY_YQ="$(command -v yq)"
# The banner of whatever pass 1 actually ran. The skip text below is derived from it rather
# than naming mikefarah outright: on a machine whose only yq IS a Go-yq, pass 1 is the Go
# one, and calling mikefarah the uncovered flavor would be exactly backwards.
PASS1_BANNER="$("$PY_YQ" --version 2>&1 | head -1)"
run_pass "pass 1: yq as PATH resolves it" "$(dirname "$PY_YQ")" || FAILED=1

# NOT YET EXERCISED ANYWHERE: no machine this branch was developed on had two flavors at
# once, so pass 2 has never actually run. Expect it to go red for a reason that is not
# config-loader.sh's fault: lib-yq-doubles.sh resolves YQ_REAL at SOURCE time, inside the
# suite process, whose PATH this runner has already pointed at the Go-yq. The doubles are
# then built on mikefarah — mkyq_go's -o=json branch runs a bare `.`, which prints YAML
# there, and its default branch passes -y, which Go-yq v4 does not accept. The durable fix
# is an overridable YQ_REAL in that library so this runner can pin the doubles to a kislyuk
# binary while PATH points at the Go one; deliberately not done here, because it could not
# be tested on the machine that would have made the change.
#
# -ef compares device and inode, NOT the path string, and that is the whole point: on a
# merged-/usr host `command -v yq` says /usr/bin/yq while find_real_go_yq's own iteration
# reaches /bin/yq first — one file, two spellings. A string comparison there runs pass 2
# against the binary pass 1 already used, labels it "real Go-yq", prints no skip line, and
# spends 156 s proving one flavor twice. Measured on the machine this was written on.
if GO_YQ="$(find_real_go_yq)" && ! [ "$GO_YQ" -ef "$PY_YQ" ]; then
    run_pass "pass 2: real Go-yq" "$(dirname "$GO_YQ")" || FAILED=1
else
    echo "########## SKIPPED: no second flavor on this machine ##########"
    echo "Only one yq is installed here: $PASS1_BANNER"
    echo "The other flavor's path was exercised only against the doubles in lib-yq-doubles.sh."
fi

echo "########## FAILED=$FAILED ##########"
exit "$FAILED"
