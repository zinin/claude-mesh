#!/usr/bin/env bash
# Regression tests for preflight-env.sh
#
# The probe answers one question for a session that did not configure this machine: what can
# actually be used here? Every verdict exits 0 — a non-zero exit means the probe is broken,
# never that the environment is poor. That contract is the first thing asserted below.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../preflight-env.sh"

FAIL=0
PASS=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$pattern' in output)" ;;
    esac
}

assert_no_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) FAIL=$((FAIL+1)); echo "  FAIL: $desc ('$pattern' present in output)" ;;
        *) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
    esac
}

# Status column of a named row ("" when the row is absent).
field() { awk -v n="$1" '$1==n {print $2; exit}' <<<"$2"; }

# Default git shim: answers instantly that there is no 'origin'. Without it every scenario
# below would run a real `git ls-remote` against this repository's remote — up to the git
# budget each, on a network the suite is not testing. Scenarios that DO test git pass their
# own PREFLIGHT_GIT_BIN, which wins because `env` keeps the last assignment.
mkdir -p "$WORK/gitfast"
cat > "$WORK/gitfast/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  rev-parse) echo ".git" ;;
  remote)    exit 1 ;;       # no origin configured — resolves without touching the network
  *)         exit 0 ;;
esac
SH
chmod +x "$WORK/gitfast/git"

# Default curl shim: answers 200 instantly. Without it, the moment Task 2's provider probes
# exist, every Task-1 scenario would send the fixture token to the real https://api.z.ai and
# poke 127.0.0.1:11434 with retries — the suite would silently become network-dependent, slow,
# and leak a fixture token outward on every run. Scenarios that test other codes pass their
# own PREFLIGHT_CURL_BIN/PATH, which win because `env` keeps the last assignment.
mkdir -p "$WORK/curlfast"
cat > "$WORK/curlfast/curl" <<'SH'
#!/usr/bin/env bash
echo "200"
exit 0
SH
chmod +x "$WORK/curlfast/curl"

# Each run gets a private data dir (so the suite never reads the developer's ~/.claude config)
# and a private TMPDIR (so exported env files, which carry tokens, cannot leak into shared /tmp
# and can be counted afterwards).
#
# run_probe assigns OUT / ERR / RC / CFG_DIR as globals and is called as a STANDALONE command —
# never as OUT="$(run_probe …)". A command substitution would strand the assignments in its
# subshell and make the exit-code and leak assertions below unfalsifiable: the probe could
# exit 7 and RC would still read 0. Same idiom as test-verify-delegation.sh:43.
#
# THREE PROPERTIES BELOW ARE LOAD-BEARING — do not "simplify" them away:
#   1. stdout and stderr are captured SEPARATELY, never merged with 2>&1. The probe's progress
#      chatter goes to stderr ("probing <provider>…"), and those lines have NF>=2, so merging
#      would feed that chatter to the FINAL GATES at the bottom of this file: the closed-set
#      gate would read a provider name ("zai…") as a status. Task 4's row-order check will
#      have the same exposure once it exists.
#   2. RC=$? stays on the line IMMEDIATELY after the OUT= assignment. Anything in between
#      overwrites $? and makes every exit-code assertion unfalsifiable.
#   3. errf lives in $WORK, never in $CFG_DIR: $CFG_DIR doubles as the probe's TMPDIR and its
#      leftover files are counted to prove exported env files (which carry tokens) were
#      deleted. A stray stderr file there would corrupt that count.
CFG_DIR=""
RC=0
OUT=""
ERR=""
# Accumulators for the FINAL GATES (bottom of file). Per-scenario assertions can only check
# the scenario their author thought about; these two make the universal contracts — closed
# status set, "every verdict exits 0" — hold over EVERY scenario, including ones Tasks 2-4
# have not written yet.
ALL_OUT=""
ALL_ERR=""
BAD_RC=""
PROBE_N=0
run_probe() {           # run_probe <fixture-basename|none> [VAR=value ...]
    local fixture="$1"; shift
    CFG_DIR="$(mktemp -d "$WORK/data-XXXXXX")"
    # A mistyped fixture name must fail loudly: silently leaving $CFG_DIR empty degrades the
    # scenario into "no config", and Tasks 2-4 add scenarios that legitimately expect
    # MISSING/SKIPPED — there the typo would produce a green run that tests nothing.
    if [ "$fixture" != none ] && ! cp "$TESTS_DIR/fixtures/$fixture" "$CFG_DIR/config.yaml"; then
        FAIL=$((FAIL+1))
        echo "  FAIL: cannot stage fixture '$fixture' (missing from $TESTS_DIR/fixtures?)"
    fi
    local errf
    errf="$(mktemp "$WORK/stderr-XXXXXX")"
    OUT="$(env CLAUDE_PLUGIN_DATA="$CFG_DIR" TMPDIR="$CFG_DIR" \
               PREFLIGHT_GIT_BIN="$WORK/gitfast/git" \
               PREFLIGHT_CURL_BIN="$WORK/curlfast/curl" PATH="$WORK/curlfast:$PATH" \
               "$@" bash "$SCRIPT" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
    rm -f "$errf"
    ALL_OUT="$ALL_OUT$OUT"$'\n'
    ALL_ERR="$ALL_ERR$ERR"$'\n'
    PROBE_N=$((PROBE_N+1))
    [ "$RC" -eq 0 ] || BAD_RC="$BAD_RC #$PROBE_N($fixture rc=$RC)"
}

echo "== Task 1: config detection and static rows =="

run_probe valid-claude-models.yaml
assert_eq   "valid config exits 0"            0    "$RC"
assert_eq   "plugin identity row present"     OK   "$(field plugin "$OUT")"
assert_eq   "valid config -> config OK"       OK   "$(field config "$OUT")"
# Full path, not a bare "/config.yaml" suffix: the detail must name the file the loader
# actually resolved, so an empty `data-dir` cannot satisfy this assertion.
assert_match "config detail names config.yaml" "$CFG_DIR/config.yaml" "$OUT"
assert_eq   "builtin-claude always OK"        OK   "$(field builtin-claude "$OUT")"
assert_eq   "claude catalog -> OK"            OK   "$(field claude-models "$OUT")"
assert_match "catalog lists both aliases"     "opus, fable" "$OUT"

run_probe none
assert_eq   "missing config exits 0"          0        "$RC"
assert_eq   "missing config -> MISSING"       MISSING  "$(field config "$OUT")"
assert_eq   "built-in claude survives no config" OK    "$(field builtin-claude "$OUT")"
assert_eq   "no config -> catalog SKIPPED"    SKIPPED  "$(field claude-models "$OUT")"
# The table is stdout ONLY. This scenario runs no network probe of any kind (no config ⇒ no
# provider to probe), so the probe has nothing legitimate to say on stderr — now or after
# Tasks 2–4 append their sections. Any output here means diagnostics leaked into the stream
# the reading session parses as rows.
assert_eq   "stdout carries no stderr noise in a local-only run" "" "$ERR"

run_probe invalid-no-providers.yaml
assert_eq   "invalid config exits 0"          0        "$RC"
assert_eq   "invalid config -> INVALID"       INVALID  "$(field config "$OUT")"

# config OK must predict "the orchestrator starts": Step 5.0 validates defaults and runtime
# too, so a config whose models parse but whose defaults: section is broken is INVALID here.
run_probe invalid-defaults-runmode.yaml
assert_eq   "broken defaults -> config INVALID" INVALID "$(field config "$OUT")"

# A dead toolchain must not impersonate a rejected config — the loader dies rc=1 either way,
# but the operator's next move differs (pipx install yq vs editing a healthy config).
run_probe valid-claude-models.yaml PREFLIGHT_YQ_BIN="$WORK/no-such-yq"
assert_eq   "missing yq exits 0"              0        "$RC"
assert_eq   "missing yq -> its own row"       MISSING  "$(field yq "$OUT")"
assert_eq   "missing yq -> config UNKNOWN, not INVALID" UNKNOWN "$(field config "$OUT")"

# A broken claude: section is INVALID with the validator's reason — mesh-review refuses to
# start on this same read, so "no catalog" (MISSING) would be a lie.
run_probe invalid-claude-scalar.yaml
assert_eq   "broken claude section -> INVALID" INVALID "$(field claude-models "$OUT")"

run_probe valid-full.yaml
assert_eq   "no claude section -> MISSING"    MISSING  "$(field claude-models "$OUT")"

echo "== Task 2: provider probes =="

# One shim stands in for curl everywhere, and it has to be faithful in two different ways,
# because the two prechecks read curl differently: token-precheck.sh runs curl WITHOUT -f and
# reads the status code off stdout (401 is a normal exit there), while ollama-precheck.sh runs
# `curl -sf` and reads only curl's own exit status. A shim that always exits 0 would make
# ollama unreachable-proof; one that always fails on 4xx would turn a 401 into "unreachable".
SHIM="$WORK/bin"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
code="${SHIM_HTTP_CODE:-200}"
fail_on_http=0
for a in "$@"; do case "$a" in -sf|-f|--fail) fail_on_http=1 ;; esac; done
# SHIM_TAGS_CODE, when set, applies to /api/tags ONLY. That path is the only way to reach
# ollama-precheck.sh's rc=5 ("daemon up, tags errored") without a real daemon: the daemon
# ping and the tags read differ by URL alone.
for a in "$@"; do case "$a" in */api/tags) code="${SHIM_TAGS_CODE:-$code}" ;; esac; done
[ "$code" = "000" ] && exit 7                                    # curl itself failed
[ "$fail_on_http" = 1 ] && [ "$code" -ge 400 ] && exit 22        # what -f does on 4xx/5xx
echo "$code"
exit 0
SH
chmod +x "$SHIM/curl"

# A PATH that genuinely has no curl but still has everything the loader needs (yq, jq, …).
# Built by symlinking every PATH entry into one dir — first occurrence wins, as in a real
# PATH search — and then deleting the curl link. Needed because curl lives in /usr/bin next
# to every other tool here, so no subset of the real PATH can drop curl alone.
mkdir -p "$WORK/nocurl"
IFS=: read -r -a PATH_DIRS <<<"$PATH"
for D in "${PATH_DIRS[@]}"; do
    [ -n "$D" ] && [ -d "$D" ] && ln -s "$D"/* "$WORK/nocurl/" 2>/dev/null
done
rm -f "$WORK/nocurl/curl"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq "reachable provider -> OK"          OK   "$(field provider:zai "$OUT")"
assert_eq "ollama-kind provider probed too"   OK   "$(field provider:ollama "$OUT")"
assert_eq "probing providers still exits 0"   0    "$RC"
assert_match "detail names the endpoint"      "https://api.z.ai" "$OUT"

# Three models, two providers: the probe runs once per provider, not once per model.
assert_eq "one row per provider" 2 "$(grep -c '^provider:' <<<"$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=401
assert_eq "401 -> AUTH-FAILED"                AUTH-FAILED "$(field provider:zai "$OUT")"
assert_match "…and blames the credentials"    "credentials rejected" "$OUT"

# Same status, different kind, different advice: an ollama daemon has no credential to
# reject, so rc=5 there must not send the operator hunting for a token that does not exist.
# Only /api/tags fails here, which is exactly what "daemon up, not signed in" looks like.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=200 SHIM_TAGS_CODE=404
assert_eq "ollama tags failure -> AUTH-FAILED" AUTH-FAILED "$(field provider:ollama "$OUT")"
assert_match "…advises ollama signin"          "ollama signin" "$OUT"
assert_no_match "…and never blames a token"    "credentials rejected" "$OUT"
assert_eq "…while the anthropic-api provider is untouched" OK "$(field provider:zai "$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=000
assert_eq "unreachable -> NO-NETWORK"         NO-NETWORK  "$(field provider:zai "$OUT")"

# SKIP_TOKEN_PRECHECK exists so a caller can skip the check. Inherited, it would turn every
# provider row into a false OK — the probe must neutralise it.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=000 SKIP_TOKEN_PRECHECK=1
assert_eq "SKIP_TOKEN_PRECHECK cannot fake OK" NO-NETWORK "$(field provider:zai "$OUT")"

# A copied-but-unedited config: export refuses to hand out a REPLACE_ME token.
run_probe invalid-token-replace-me.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_match "REPLACE_ME reported as a config gap, not a network verdict" "token not configured" "$OUT"

# runtime: is gated at the config row (config OK = the orchestrator starts), so a broken
# runtime can no longer masquerade as a per-provider token gap. probe_provider keeps its
# UNKNOWN/export-refused branch as defence-in-depth (mktemp failure, races, future loader
# changes) — no fixture can reach it any more, and that is the point.
run_probe invalid-runtime-runmode.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_eq "broken runtime -> config INVALID"  INVALID "$(field config "$OUT")"
assert_no_match "…not blamed on any token"    "token not configured" "$OUT"

# No curl (the probe's own binary): prechecks are not invoked at all — UNKNOWN, not a fake
# network verdict. No PATH surgery needed: the gate is HAVE_CURL, not the prechecks' lookup.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$WORK/no-such-curl"
assert_eq "no curl -> provider UNKNOWN"       UNKNOWN "$(field provider:zai "$OUT")"

# The other half of the same gate, and the one that fabricates a verdict if it is missing:
# PREFLIGHT_CURL_BIN resolves, but the prechecks look `curl` up on PATH and would not find it.
# token-precheck.sh turns that command-not-found into HTTP 000 -> rc 6 -> NO-NETWORK, an
# endpoint verdict invented out of a missing binary. UNKNOWN is the only honest answer.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/nocurl"
assert_eq "curl absent from PATH -> its own row" MISSING "$(field curl "$OUT")"
assert_eq "…and provider UNKNOWN, not NO-NETWORK" UNKNOWN "$(field provider:zai "$OUT")"
assert_match "…naming the PATH gap"           "curl on PATH" "$OUT"

# Missing ext-claude prerequisites: endpoint reachability is irrelevant if the executor
# cannot start — provider rows degrade and name the gap.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200 \
          PREFLIGHT_EXT_DEPS_BINS="bc no-such-ext-tool"
assert_eq "missing ext dep -> its own row"    MISSING "$(field ext-claude-deps "$OUT")"
assert_eq "…and providers degrade"            MISSING "$(field provider:zai "$OUT")"
assert_match "…naming the executor gap"       "ext-claude prerequisites absent" "$OUT"

# Re-runs inside a session: PREFLIGHT_SKIP_NETWORK answers from local facts alone — the
# prechecks are never invoked, so this must hold even with a broken shim on PATH.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=000 PREFLIGHT_SKIP_NETWORK=1
assert_eq "skip-network -> provider UNKNOWN"  UNKNOWN "$(field provider:zai "$OUT")"
assert_match "…and says why"                  "skipped by PREFLIGHT_SKIP_NETWORK" "$OUT"

# Secrets: the token from the fixture must not appear anywhere, and no exported env file
# may survive the run (TMPDIR is private to this run, so a leftover is visible).
# BOTH streams are checked: this section is the first to write to stderr ("probing zai…"),
# so "no secret reaches stdout or stderr" needs an assertion on $ERR too — a precheck that
# stopped discarding its diagnosis would leak the token there while $OUT stayed clean.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_no_match "provider token never printed"        "tkn-zai" "$OUT"
assert_no_match "…and never reaches stderr either"    "tkn-zai" "$ERR"
LEFT="$(find "$CFG_DIR" -name 'claude-mesh-env-*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "exported env files removed" 0 "$LEFT"

# ============================================================================
# FINAL GATES — must stay LAST. Tasks 2-4 append their scenario sections ABOVE
# this banner. Both gates read every scenario's output, not just the last one.
# ============================================================================

# The closed status set is the contract every later task must keep. Read from ALL_OUT, not
# $OUT: over a single scenario this gate only ever sees that author's statuses, and the
# unusual ones (UNKNOWN, SKIPPED, INVALID) live in scenarios nobody would think to point it at.
#
# The awk filter skips the two kinds of legitimate NON-ROW prose the probe prints: Task 4's
# `SUMMARY …` lines and its `hint: cp config.example.yaml …` line (whose $2 is "cp"). Extend
# this filter when a task adds a new non-row line — and do NOT replace it with a "every line
# matches a row shape" regexp: row names legitimately contain a colon (provider:zai, Task 2),
# so a shape check is the same forward-compatibility trap in a new costume.
ROWS="$(awk 'NF>=2 && $1 !~ /^SUMMARY/ && $1 != "hint:" {print $2}' <<<"$ALL_OUT")"
BAD="$(sort -u <<<"$ROWS" | grep -Ev '^(OK|MISSING|NO-NETWORK|AUTH-FAILED|INVALID|SKIPPED|UNKNOWN)$' || true)"
assert_eq   "status column stays in the closed set (every scenario)" "" "$BAD"
# Both gates above and below pass on empty input, so they must prove they looked at something.
# Today: 7 scenarios x 4-5 rows = 29. The floor only gets safer as Tasks 2-4 add scenarios.
assert_eq   "…and the gate actually examined rows" \
            1 "$([ "$(grep -c . <<<"$ROWS")" -ge 10 ] && echo 1 || echo 0)"

# "Every verdict exits 0" is THE contract of this probe, and Tasks 2-4 each append a section
# whose last command silently decides the script's exit status. Asserting RC per scenario
# only covers the scenarios someone remembered; this backstop covers all of them.
assert_eq   "every verdict exits 0" "" "$BAD_RC"

# stdout is the table; stderr is progress chatter and NOTHING else. The real regression this
# guards is a dropped `2>&1` on a precheck invocation: token-precheck.sh prints up to 400
# bytes of raw provider response body (:49) and ollama-precheck.sh prints the URL, so the
# probe would start emitting other people's diagnostics — and, for a provider that echoes the
# request, potentially the token itself. A per-scenario "the token is not in $ERR" assertion
# cannot catch that: neither precheck prints the token today, so it can never fail.
#
# The filter is a PREFIX, deliberately: Task 3's cli_row adds `probing codex (https://…)…`
# and `probing gemini (…)…`. Pinning exact text would break there; `^probing ` covers every
# such line and still rejects `token-precheck: OK (HTTP 200) — token appears valid`.
BAD_ERR="$(grep -v '^probing ' <<<"$ALL_ERR" | grep -c . || true)"
assert_eq   "stderr carries only probe chatter, never precheck diagnostics" 0 "$BAD_ERR"
# Same pairing as the closed-set gate above: a gate that passes on empty input must prove it
# had input. 17 probing lines today, across the 10 scenarios that reach a live probe (3 of
# them in the Task 1 section, whose fixtures also carry providers).
assert_eq   "…and that gate saw the chatter it filters" \
            1 "$([ "$(grep -c '^probing ' <<<"$ALL_ERR")" -ge 5 ] && echo 1 || echo 0)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
