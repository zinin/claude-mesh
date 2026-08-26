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

run_pass() {            # run_pass <label> <dir-holding-that-yq>
    local label="$1" dir="$2" rc=0
    echo "########## $label ($dir/yq: $("$dir/yq" --version 2>&1 | head -1)) ##########"
    for suite in test-config-loader.sh test-preflight-env.sh; do
        echo "--- $suite ---"
        # PIPESTATUS, not `|| rc=1`: after a pipe the shell reports `tail`'s status, which is 0
        # almost always, so a failing suite would be recorded as a pass by the very artifact
        # whose job is to prove it passed.
        PATH="$dir:$PATH" bash "$ROOT/skills/shared/tests/$suite" | tail -3
        [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
    done
    return $rc
}

FAILED=0
PY_YQ="$(command -v yq)"
run_pass "pass 1: yq as PATH resolves it" "$(dirname "$PY_YQ")" || FAILED=1

if GO_YQ="$(find_real_go_yq)" && [ "$GO_YQ" != "$PY_YQ" ]; then
    run_pass "pass 2: real Go-yq" "$(dirname "$GO_YQ")" || FAILED=1
else
    echo "########## SKIPPED: no second flavor on this machine ##########"
    echo "The mikefarah path was exercised only against the doubles in lib-yq-doubles.sh."
fi

echo "########## FAILED=$FAILED ##########"
exit "$FAILED"
