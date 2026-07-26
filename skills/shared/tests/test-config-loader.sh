#!/usr/bin/env bash
# Smoke tests for config-loader.sh
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$TESTS_DIR/../config-loader.sh"
FIXTURES="$TESTS_DIR/fixtures"

FAIL=0
PASS=0

assert_exit() {
    local desc="$1" expected_rc="$2" actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected rc=$expected_rc, got $actual_rc)"
    fi
}

assert_stderr_contains() {
    local desc="$1" needle="$2" stderr_file="$3"
    if grep -q -- "$needle" "$stderr_file"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected stderr to contain: $needle)"
        echo "    stderr was:"; sed 's/^/      /' "$stderr_file"
    fi
}

echo "=== Test 1: missing config file ==="
# iter-2 CONCERN-11: load_or_die exits with rc=2 (distinct from rc=1) when
# config.yaml is missing — so /do-plan (and any future consumer that wants to
# tolerate "no config yet" during fresh setup) can differentiate this case from
# yaml-malformed / validator / env errors. All other commands (validate/export)
# propagate the rc=2 as their own exit code.
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA=/nonexistent "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits with rc=2 (distinct 'config not found')" "2" "$RC"
assert_stderr_contains "mentions missing config.yaml" "config.yaml not found" "$ERR"
rm -f "$ERR"

echo "=== Test 2: valid minimal config ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits zero on valid config" "0" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 3: invalid config (no providers) ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-no-providers.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on missing providers" "1" "$RC"
assert_stderr_contains "names the issue" "providers" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 4: model id without slash ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-no-slash.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "explains the slash requirement" 'must be "<provider>/<short>"' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 5: model id references missing provider ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-missing-provider.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names the missing provider" "missing provider" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 6: model id with empty short ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-empty-short.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "explains empty short" "short name after .*/.* is empty" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7: codex.reasoning_level unknown (warn + pass through) ==="
# Forward-compat: unknown levels are NOT fatal — the loader warns on stderr and
# passes the value through (the codex CLI/API is the authority on valid levels).
TDIR=$(mktemp -d)
cp "$FIXTURES/unknown-codex-reasoning.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits zero (unknown level warns, not dies)" "0" "$RC"
assert_stderr_contains "warns about the unknown level" "reasoning_level: unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7b: export ignores codex-section issues (scoped validation) ==="
# cmd_export validation is scoped to providers/models/runtime — the same
# unknown-level fixture must export cleanly with no reasoning_level noise on stderr.
TDIR=$(mktemp -d)
cp "$FIXTURES/unknown-codex-reasoning.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm >"$OUT" 2>"$ERR"
RC=$?
assert_exit "export exits zero despite unknown codex level" "0" "$RC"
if grep -q -- "reasoning_level" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: export stderr mentions reasoning_level (codex section is out of export scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: export stderr silent on reasoning_level"
fi
# cmd_export prints the path to a mode-600 env file; remove it without reading it.
ENV_FILE=$(cat "$OUT" 2>/dev/null)
[ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"
rm -rf "$TDIR" "$OUT" "$ERR"

echo "=== Test 7c: get-codex unaffected by broken gemini section (scoped validation) ==="
# get-codex validates only the codex: section — a gemini: section without model
# must not block config-driven codex resolution (Codex PR-review finding).
# validate stays the full-config lint and still rejects the same fixture.
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-gemini-valid-codex.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
VAL=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>"$ERR")
RC=$?
assert_exit "get-codex exits zero despite broken gemini section" "0" "$RC"
if [ "$VAL" = "gpt-5.5|xhigh" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex prints model|level"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|xhigh')"
fi
if grep -q -- "gemini" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex stderr mentions gemini (out of scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: get-codex stderr silent on gemini"
fi
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>/dev/null
RC=$?
assert_exit "validate (full lint) still rejects the broken gemini section" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7d: get-gemini unaffected by broken codex section (scoped validation) ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-codex-valid-gemini.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
VAL=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-gemini 2>"$ERR")
RC=$?
assert_exit "get-gemini exits zero despite broken codex section" "0" "$RC"
if [ "$VAL" = "gemini-3.1-pro" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-gemini prints model"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-gemini printed '$VAL' (expected 'gemini-3.1-pro')"
fi
if grep -q -- "codex" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: get-gemini stderr mentions codex (out of scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: get-gemini stderr silent on codex"
fi
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>/dev/null
RC=$?
assert_exit "validate (full lint) still rejects the broken codex section" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7e: all known reasoning levels pass silently ==="
# Mutation guard (external review, fix wave 3): removing a level from the known
# set must turn the suite red — previously no test exercised any known level.
for LVL in none minimal low medium high xhigh ultra; do
    TDIR=$(mktemp -d)
    sed "s/reasoning_level: extreme.*/reasoning_level: $LVL/" \
        "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
    ERR=$(mktemp)
    CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
    RC=$?
    assert_exit "validate exits zero on level '$LVL'" "0" "$RC"
    # Scoped assert (fix wave 5): an unrelated future WARN must not break this test —
    # the mutation guard only needs "no reasoning_level noise" (removing a level from
    # the known set emits 'codex.reasoning_level: unknown value …', still caught).
    if grep -q -- "reasoning_level" "$ERR"; then
        FAIL=$((FAIL+1)); echo "  FAIL: stderr mentions reasoning_level on known level '$LVL'"
        echo "    stderr was:"; sed 's/^/      /' "$ERR"
    else
        PASS=$((PASS+1)); echo "  PASS: stderr silent on known level '$LVL'"
    fi
    # Consumer-path round-trip (fix wave 5): executors read get-codex, not validate —
    # a known level must round-trip verbatim and keep the `<model>|<level>` shape
    # (exactly one pipe; the resolution snippets split on the LAST '|').
    VAL=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>/dev/null)
    if [ "$VAL" = "gpt-5.5|$LVL" ]; then
        PASS=$((PASS+1)); echo "  PASS: get-codex round-trips level '$LVL'"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|$LVL')"
    fi
    rm -rf "$TDIR" "$ERR"
done

echo "=== Test 7f: get-codex passes an unknown level through (the consumer path) ==="
# The executor skills consume get-codex, not validate — lock the passthrough
# contract on the path they actually call.
TDIR=$(mktemp -d)
cp "$FIXTURES/unknown-codex-reasoning.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
VAL=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>"$ERR")
RC=$?
assert_exit "get-codex exits zero on unknown level" "0" "$RC"
if [ "$VAL" = "gpt-5.5|extreme" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex prints model|unknown-level unchanged"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|extreme')"
fi
assert_stderr_contains "warns about the unknown level" "reasoning_level: unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7g: export unaffected by die-class codex section (scoped validation) ==="
# 7b covers the warn-noise case; this locks the die-class case — a codex: section
# without model must not block ext-claude exports either.
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-codex-valid-gemini.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm >"$OUT" 2>"$ERR"
RC=$?
assert_exit "export exits zero despite die-class codex section" "0" "$RC"
if grep -q -- "codex" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: export stderr mentions codex (out of export scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: export stderr silent on codex"
fi
# cmd_export prints the path to a mode-600 env file; remove it without reading it.
ENV_FILE=$(cat "$OUT" 2>/dev/null)
[ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"
rm -rf "$TDIR" "$OUT" "$ERR"

echo "=== Test 7h: get-codex dies on codex section without model ==="
# The executor STOP contract relies on this rc=1 (resolution snippets surface it).
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-codex-valid-gemini.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex >/dev/null 2>"$ERR"
RC=$?
assert_exit "get-codex exits non-zero" "1" "$RC"
assert_stderr_contains "names the missing model" "codex.model: required" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7i: non-string reasoning_level dies with a clear message ==="
# Previously an unquoted numeric level passed validate (warn) and then crashed
# get-codex with a raw jq type error (rc=5) — worse than 0.3.0's clean die.
TDIR=$(mktemp -d)
sed "s/reasoning_level: extreme.*/reasoning_level: 3/" \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "validate exits non-zero on numeric level" "1" "$RC"
assert_stderr_contains "explains the type requirement" "must be a string" "$ERR"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex >/dev/null 2>/dev/null
RC=$?
assert_exit "get-codex dies cleanly too (no raw jq rc=5)" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7j: reasoning_level with unsafe characters dies ==="
# '|' would corrupt the get-codex model|level protocol; quotes/spaces would break
# shell substitution in the executor skills.
TDIR=$(mktemp -d)
sed 's/reasoning_level: extreme.*/reasoning_level: "a|b"/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "validate exits non-zero on 'a|b'" "1" "$RC"
assert_stderr_contains "names reasoning_level charset" "codex.reasoning_level: must start with" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7k: codex.model with unsafe characters dies ==="
TDIR=$(mktemp -d)
sed 's/model: gpt-5.5/model: "gpt 5.5"/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "validate exits non-zero on 'gpt 5.5'" "1" "$RC"
assert_stderr_contains "names codex.model charset" "codex.model: must start with" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 8: defaults references unknown model ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-missing-model.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names unknown model" "unknown model" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 9: defaults.builtin lists gemini without gemini section ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-builtin-gemini-no-section.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "explains the missing section" "but no gemini: section" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 10: runtime.do_plan_default_stop_tokens below 150000 ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-do-plan-tokens.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names do_plan_default_stop_tokens" "do_plan_default_stop_tokens" "$ERR"
assert_stderr_contains "mentions 150000 lower bound" "150000" "$ERR"
rm -rf "$TDIR" "$ERR"

# iter-2 CONCERN-11: load_or_die exits 2 (not 1) when config.yaml is missing.
echo "=== Test 10b: get-flag returns rc=2 when config.yaml missing ==="
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA=/nonexistent "$LOADER" get-flag do_plan_default_stop_tokens 2>"$ERR"
RC=$?
assert_exit "get-flag exits rc=2 on missing config" "2" "$RC"
assert_stderr_contains "names missing config.yaml" "config.yaml not found" "$ERR"
rm -f "$ERR"

# iter-2 CRITICAL-2: cmd_get_flag must run validate_runtime before reading the typed scalar.
echo "=== Test 10c: get-flag do_plan_default_stop_tokens enforces ≥150000 floor ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-do-plan-tokens.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag do_plan_default_stop_tokens 2>"$ERR"
RC=$?
assert_exit "get-flag exits rc=1 on below-floor value" "1" "$RC"
assert_stderr_contains "mentions 150000 lower bound" "150000" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 11: defaults.models as scalar (not a list) is rejected ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-models-scalar.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on scalar models" "1" "$RC"
assert_stderr_contains "explains it must be a list" "must be a list" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 12: export simple model ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-full.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm >"$OUT" 2>/dev/null
RC=$?
assert_exit "export exits zero" "0" "$RC"

ENV_FILE=$(cat "$OUT")
# Secret hygiene (FIX 3): the emitted env file (which holds the token) must be mode 600.
# Stat BEFORE sourcing/removing it.
MODE=$(stat -c %a "$ENV_FILE")
[ "$MODE" = "600" ] && { PASS=$((PASS+1)); echo "  PASS: env file mode 600"; } || { FAIL=$((FAIL+1)); echo "  FAIL: env file mode '$MODE'"; }
# Secret hygiene (FIX 3): the token must NOT appear on stdout (the path is all that goes there).
# $OUT holds the captured export stdout; grep BEFORE $OUT is overwritten/removed.
if grep -q 'tkn-zai' "$OUT"; then FAIL=$((FAIL+1)); echo "  FAIL: token leaked to stdout"; else PASS=$((PASS+1)); echo "  PASS: token absent from stdout"; fi
source "$ENV_FILE"; rm -f "$ENV_FILE"
[ "$ANTHROPIC_BASE_URL" = "https://api.z.ai/api/anthropic" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ANTHROPIC_BASE_URL set"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ANTHROPIC_BASE_URL got '$ANTHROPIC_BASE_URL'"; }
[ "$ANTHROPIC_AUTH_TOKEN" = "tkn-zai" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ANTHROPIC_AUTH_TOKEN set"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ANTHROPIC_AUTH_TOKEN got '$ANTHROPIC_AUTH_TOKEN'"; }
[ "$ANTHROPIC_MODEL" = "glm-5.1" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ANTHROPIC_MODEL set"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ANTHROPIC_MODEL got '$ANTHROPIC_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "glm-5.1" ] \
  && { PASS=$((PASS+1)); echo "  PASS: haiku defaults to model"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: haiku got '$ANTHROPIC_DEFAULT_HAIKU_MODEL'"; }
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
rm -rf "$TDIR" "$OUT"

echo "=== Test 13: export model with haiku_model override and context_window ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-full.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export ollama/deepseek >"$OUT" 2>/dev/null
ENV_FILE=$(cat "$OUT"); source "$ENV_FILE"; rm -f "$ENV_FILE"
[ "$ANTHROPIC_BASE_URL" = "http://127.0.0.1:11434" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ollama base_url"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ollama base_url got '$ANTHROPIC_BASE_URL'"; }
[ "$ANTHROPIC_MODEL" = "deepseek-v4-pro:cloud" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ollama model"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: model got '$ANTHROPIC_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "deepseek-v4-flash:cloud" ] \
  && { PASS=$((PASS+1)); echo "  PASS: haiku override applied"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: haiku got '$ANTHROPIC_DEFAULT_HAIKU_MODEL'"; }
[ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" = "1000000" ] \
  && { PASS=$((PASS+1)); echo "  PASS: context_window exported"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: window got '$CLAUDE_CODE_AUTO_COMPACT_WINDOW'"; }
[ "$CLAUDE_MESH_PROVIDER_KIND" = "ollama-daemon" ] \
  && { PASS=$((PASS+1)); echo "  PASS: provider kind exported for precheck routing"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: kind got '$CLAUDE_MESH_PROVIDER_KIND'"; }
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_MESH_PROVIDER_KIND
rm -rf "$TDIR" "$OUT"

echo "=== Test 14: export nonexistent model ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-full.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/nope 2>"$ERR"
RC=$?
assert_exit "exits non-zero for unknown model" "1" "$RC"
assert_stderr_contains "names the unknown model" "zai/nope" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 15: provider kind invalid value ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-kind.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on invalid kind" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 16: provider base_url empty ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-empty-base-url.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on empty base_url" "1" "$RC"
assert_stderr_contains "names missing base_url" "base_url: missing" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 17: provider base_url not a URL ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-bad-url.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on bad URL" "1" "$RC"
assert_stderr_contains "names invalid URL" "invalid URL" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 18: provider token REPLACE_ME rejected at export ==="
# By design the REPLACE_ME check lives in cmd_export (NOT validate): the shipped
# config.example.yaml has REPLACE_ME everywhere and must still pass `validate`.
# So this fixture is otherwise-valid (passes validate_all, which runs first inside
# export) and we invoke `export` to trigger the token error.
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-token-replace-me.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm 2>"$ERR"
RC=$?
assert_exit "export exits non-zero on REPLACE_ME token" "1" "$RC"
assert_stderr_contains "names the still-REPLACE_ME token" 'still "REPLACE_ME"' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 19: provider duplicate id ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-duplicate-id.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on duplicate provider id" "1" "$RC"
assert_stderr_contains "names duplicate id" "duplicate id" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 20: model id with multiple slashes ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-multi-slash.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on multi-slash id" "1" "$RC"
assert_stderr_contains "explains only one slash allowed" 'only one "/"' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 21: model id short part has uppercase ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-uppercase-short.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on uppercase short" "1" "$RC"
assert_stderr_contains "explains short-name regex" "must match" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 22: model id duplicate ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-duplicate.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on duplicate model id" "1" "$RC"
assert_stderr_contains "names duplicate id" "duplicate id" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 23: model.model empty ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-empty-model.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on empty model field" "1" "$RC"
assert_stderr_contains "names required field" "required field" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 24: defaults.builtin lists codex without codex section ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-builtin-codex-no-section.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on codex without section" "1" "$RC"
assert_stderr_contains "explains the missing codex section" "but no codex: section" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 25: defaults.builtin unknown value ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-builtin-unknown.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on unknown builtin" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 26: defaults.code_review.run_mode invalid ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-runmode.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on invalid run_mode" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 27: runtime.default_run_mode invalid ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-runmode.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on invalid default_run_mode" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 28: runtime.timeouts.* zero ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-timeout-zero.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on zero timeout" "1" "$RC"
assert_stderr_contains "names positive integer rule" "positive integer" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 29: runtime.timeouts.* negative ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-timeout-negative.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on negative timeout" "1" "$RC"
assert_stderr_contains "names positive integer rule" "positive integer" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 30: odd model name round-trips verbatim (jq-injection guard, FIX 1) ==="
# Regression for the jq filter-injection fix: the .model field contains `"` and `$`
# (`a" + .providers[0].token + "z`). With the fallback bound as program text this would
# evaluate as a jq expression and splice the provider token into opus/sonnet/haiku/subagent.
# With --arg binding it must round-trip as a literal string. EXPECTED kept in a variable to
# avoid quoting mistakes.
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-odd-model-name.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/odd >"$OUT" 2>/dev/null
RC=$?
assert_exit "export exits zero on odd model name" "0" "$RC"
ENV_FILE=$(cat "$OUT"); source "$ENV_FILE"; rm -f "$ENV_FILE"
EXPECTED='a" + .providers[0].token + "z'
[ "$ANTHROPIC_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (model)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: model got '$ANTHROPIC_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_OPUS_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (opus)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: opus got '$ANTHROPIC_DEFAULT_OPUS_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_SONNET_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (sonnet)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: sonnet got '$ANTHROPIC_DEFAULT_SONNET_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (haiku)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: haiku got '$ANTHROPIC_DEFAULT_HAIKU_MODEL'"; }
[ "$CLAUDE_CODE_SUBAGENT_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (subagent)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: subagent got '$CLAUDE_CODE_SUBAGENT_MODEL'"; }
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
rm -rf "$TDIR" "$OUT"

echo "=== Test 31: full config.example.yaml validates ==="
PLUGIN_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
# NB: name this TMPD, not TMPDIR — mktemp consumes a set $TMPDIR as its base dir; clobbering it would break staging.
TMPD=$(mktemp -d)
cp "$PLUGIN_ROOT/config.example.yaml" "$TMPD/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TMPD" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "config.example.yaml validates" "0" "$RC"
[ "$RC" != "0" ] && { echo "    stderr:"; sed 's/^/      /' "$ERR"; }
rm -rf "$TMPD" "$ERR"

echo "=== Test 32: export every model in config.example.yaml ==="
TMPD=$(mktemp -d)
# iter-3 CRITICAL-4: stage a REPLACE_ME→fake-token copy so cmd_export's
# REPLACE_ME guard (iter-2 CONCERN-10) doesn't trip on the shipped example.
sed 's/REPLACE_ME/test-token-fake/g' "$PLUGIN_ROOT/config.example.yaml" > "$TMPD/config.yaml"
MODEL_IDS=$(yq -r '.models[].id' "$TMPD/config.yaml")
for mid in $MODEL_IDS; do
    OUT=$(mktemp)
    ERRF=$(mktemp)
    CLAUDE_PLUGIN_DATA="$TMPD" "$LOADER" export "$mid" >"$OUT" 2>"$ERRF"
    RC=$?
    ENV_FILE=$(cat "$OUT" 2>/dev/null)
    # cmd_export now prints the path to a mode-600 tmpfile, not the exports themselves.
    if [ "$RC" = "0" ] && [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] && grep -q '^export ANTHROPIC_BASE_URL=' "$ENV_FILE"; then
        PASS=$((PASS+1)); echo "  PASS: export $mid"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: export $mid (rc=$RC, env_file=$ENV_FILE)"
        sed 's/^/      /' "$ERRF"
    fi
    [ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"
    rm -f "$OUT" "$ERRF"
done
rm -rf "$TMPD"

# === Test 33: get-runtime surfaces runtime.max_redispatch from config ===
# (consumed by /mesh-review Step 6.0 guard as the auto-redispatch round cap)
echo "=== Test 33: get-runtime emits max_redispatch from config ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  max_redispatch: 3\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.max_redispatch')
if [ "$GOT" = "3" ]; then PASS=$((PASS+1)); echo "  PASS: max_redispatch=3"; else FAIL=$((FAIL+1)); echo "  FAIL: max_redispatch (expected 3, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 34: get-runtime defaults max_redispatch to 1 when absent ===
echo "=== Test 34: get-runtime defaults max_redispatch to 1 ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  default_run_mode: team\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.max_redispatch')
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: default 1"; else FAIL=$((FAIL+1)); echo "  FAIL: default (expected 1, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 35: validate_runtime rejects non-positive max_redispatch ===
echo "=== Test 35: get-runtime rejects max_redispatch=0 ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  max_redispatch: 0\n' > "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime 2>"$ERR"; RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names max_redispatch" "max_redispatch" "$ERR"
rm -rf "$TDIR" "$ERR"

# === Test 36: validate enforces the dispatch_model charset ===
# Hardened charset ^[A-Za-z0-9][A-Za-z0-9._:@-]*$ : reject whitespace/punct AND a leading
# dash/dot, but accept a normal alias or full id (internal dashes ok), incl. provider
# ids — Bedrock (…-v2:0, colon) and Vertex (…@date, at-sign).
echo "=== Test 36: dispatch_model charset (reject bad / leading-dash, accept valid id) ==="
TDIR=$(mktemp -d); ERR=$(mktemp)

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "bad model!"\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects whitespace/punct dispatch_model" "1" "$RC"
assert_stderr_contains "names dispatch_model" "dispatch_model" "$ERR"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "-opus"\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects leading-dash dispatch_model" "1" "$RC"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "claude-fable-5"\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a valid alias/id (internal dashes ok)" "0" "$RC"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "us.anthropic.claude-3-5-sonnet-20241022-v2:0"\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a Bedrock full id (colon ok)" "0" "$RC"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "claude-opus-4@20250514"\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a Vertex full id (at-sign ok)" "0" "$RC"

rm -rf "$TDIR" "$ERR"

# === Test 37: get-flag dispatch_model returns the configured value ===
echo "=== Test 37: get-flag dispatch_model returns value ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  dispatch_model: opus\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag dispatch_model)
if [ "$GOT" = "opus" ]; then PASS=$((PASS+1)); echo "  PASS: dispatch_model=opus"; else FAIL=$((FAIL+1)); echo "  FAIL: dispatch_model (expected opus, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 38: get-flag dispatch_model is empty when the key is absent ===
echo "=== Test 38: get-flag dispatch_model empty when absent ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  default_run_mode: background\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag dispatch_model)
if [ -z "$GOT" ]; then PASS=$((PASS+1)); echo "  PASS: empty when absent"; else FAIL=$((FAIL+1)); echo "  FAIL: expected empty, got '$GOT'"; fi
rm -rf "$TDIR"

# === Test 39: get-runtime surfaces dispatch_model (value, and "" when absent) ===
echo "=== Test 39: get-runtime emits dispatch_model ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  dispatch_model: fable\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.dispatch_model')
if [ "$GOT" = "fable" ]; then PASS=$((PASS+1)); echo "  PASS: dispatch_model=fable"; else FAIL=$((FAIL+1)); echo "  FAIL: expected fable, got '$GOT'"; fi
printf 'runtime:\n  default_run_mode: team\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.dispatch_model')
if [ -z "$GOT" ]; then PASS=$((PASS+1)); echo "  PASS: dispatch_model defaults to empty"; else FAIL=$((FAIL+1)); echo "  FAIL: expected empty, got '$GOT'"; fi
rm -rf "$TDIR"

# === Test 40: codex.model accepts provider-qualified ids (slash) ===
# codex CLI accepts provider-qualified model ids (e.g. ollama-style `openai/gpt-oss-20b`);
# the model charset must allow "/" — unlike reasoning_level/dispatch_model, which keep the
# stricter charset. Leading "/" stays rejected (leading-alnum anchor).
echo "=== Test 40: codex.model with '/' validates and round-trips ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
sed 's|model: gpt-5.5|model: openai/gpt-oss-20b|' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on provider-qualified codex.model" "0" "$RC"
VAL=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>/dev/null)
if [ "$VAL" = "openai/gpt-oss-20b|extreme" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex round-trips the slash model"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'openai/gpt-oss-20b|extreme')"
fi
sed 's|model: gpt-5.5|model: "/gpt-oss"|' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "still rejects a leading-slash codex.model" "1" "$RC"
assert_stderr_contains "names codex.model charset" "codex.model: must start with" "$ERR"
rm -rf "$TDIR" "$ERR"

# === Test 41: scalar codex:/gemini: sections die cleanly (not raw jq rc=5) ===
# `jq -e '.codex'` gated on truthiness, so `codex: false` skipped validation and then
# crashed cmd_get_codex with a raw jq "Cannot index boolean" (rc=5). The gate must
# type-dispatch: null → absent, object → validate, anything else → clean die.
echo "=== Test 41: codex:/gemini: as non-mapping scalars die cleanly ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ncodex: false\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on codex: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "codex: must be a mapping" "$ERR"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-codex dies cleanly on codex: false (no raw jq rc=5)" "1" "$RC"
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ngemini: false\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on gemini: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "gemini: must be a mapping" "$ERR"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-gemini >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-gemini dies cleanly on gemini: false (no raw jq rc=5)" "1" "$RC"
# An explicitly EMPTY key (`codex:` → null) keeps the absent semantics: no error.
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ncodex:\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'codex:' key (null = absent)" "0" "$RC"
rm -rf "$TDIR" "$ERR"

# === Test 42: empty config.yaml dies cleanly, without bash arithmetic noise ===
# An empty yaml gives an empty JSON snapshot; jq then emits NOTHING, and the old
# `[ "$count" -gt 0 ]` printed "integer expression expected" before the die message.
echo "=== Test 42: empty config.yaml dies without integer-expression noise ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
: > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on empty config" "1" "$RC"
assert_stderr_contains "names the empty providers section" "providers: section is empty or missing" "$ERR"
if grep -q -- "integer expression" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: bash arithmetic noise leaked to stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: stderr free of integer-expression noise"
fi
rm -rf "$TDIR" "$ERR"

# === Test 43: get-runtime exposes timeouts (watch loops read global_sec via the loader) ===
# The mesh-review/mesh-design-review disk-watch bounds itself by runtime.timeouts.global_sec
# "via the loader" — so get-runtime must actually emit the timeouts block (defaults match
# cmd_export: single_run_sec 1800, stall_sec 600, global_sec 3600, max_retries 2).
echo "=== Test 43: get-runtime emits timeouts with export-parity defaults ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  timeouts:\n    global_sec: 7200\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.timeouts.global_sec')
if [ "$GOT" = "7200" ]; then PASS=$((PASS+1)); echo "  PASS: configured global_sec=7200"; else FAIL=$((FAIL+1)); echo "  FAIL: global_sec (expected 7200, got '$GOT')"; fi
printf 'runtime:\n  default_run_mode: background\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '[.timeouts.single_run_sec, .timeouts.stall_sec, .timeouts.global_sec, .timeouts.max_retries] | join(",")')
if [ "$GOT" = "1800,600,3600,2" ]; then PASS=$((PASS+1)); echo "  PASS: defaults 1800,600,3600,2"; else FAIL=$((FAIL+1)); echo "  FAIL: timeout defaults (got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 44: export still validates its OWN sections (regression guard) ===
# cmd_export's scoping (fix wave 1) must not be read as "export skips validation":
# deleting validate_providers/validate_models/validate_runtime from cmd_export would
# keep the whole suite green without these asserts (final-review + wave-5 finding).
echo "=== Test 44: export fails on broken providers/models/runtime sections ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
cp "$FIXTURES/invalid-provider-bad-url.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm >/dev/null 2>"$ERR"; RC=$?
assert_exit "export exits 1 on invalid provider base_url" "1" "$RC"
assert_stderr_contains "names the invalid URL" "invalid URL" "$ERR"
cp "$FIXTURES/invalid-model-duplicate.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm >/dev/null 2>"$ERR"; RC=$?
assert_exit "export exits 1 on duplicate model id" "1" "$RC"
assert_stderr_contains "names the duplicate id" "duplicate id" "$ERR"
cp "$FIXTURES/invalid-runtime-timeout-zero.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" export zai/glm >/dev/null 2>"$ERR"; RC=$?
assert_exit "export exits 1 on zero runtime timeout" "1" "$RC"
assert_stderr_contains "names the positive-integer rule" "positive integer" "$ERR"
rm -rf "$TDIR" "$ERR"

# === Test 45: unquoted YAML-1.1-style `off` parses as a STRING with kislyuk-yq ===
# Locks the empirical behavior the validate_codex comment describes (fix wave 5):
# `reasoning_level: off` reaches the validator as the string "off" and takes the
# warn-and-pass-through path — NOT the non-string type die (that path is for
# true/false/numbers, covered by Test 41 / 7i).
echo "=== Test 45: reasoning_level: off warns and passes through as a string ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
sed 's/reasoning_level: extreme.*/reasoning_level: off/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on unquoted 'off'" "0" "$RC"
assert_stderr_contains "warns about the unknown level" 'unknown value "off"' "$ERR"
VAL=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>/dev/null)
if [ "$VAL" = "gpt-5.5|off" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex passes 'off' through as a string"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|off')"
fi
rm -rf "$TDIR" "$ERR"

# === Test 46: scalar runtime:/runtime.timeouts sections die cleanly (not raw jq rc=5) ===
# Same class as Test 41 (fix wave 6, Codex PR-review P2): `jq -e '.runtime'` gated on
# truthiness, so `runtime: false` passed validate SILENTLY, and a non-mapping
# `runtime.timeouts` passed rc=0 while spraying raw jq "Cannot index boolean" noise;
# both then crashed cmd_get_runtime (rc=5) — which the mesh-review/mesh-design-review
# watch loops call for timeouts.global_sec. The gate must type-dispatch like the
# codex:/gemini: ones: null → absent, object → validate, anything else → clean die.
echo "=== Test 46: runtime:/runtime.timeouts as non-mapping scalars die cleanly ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime: false\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on runtime: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "runtime: must be a mapping" "$ERR"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-runtime dies cleanly on runtime: false (no raw jq rc=5)" "1" "$RC"
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  timeouts: false\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on runtime.timeouts: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "runtime.timeouts: must be a mapping" "$ERR"
if grep -q -- "Cannot index" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: raw jq indexing noise leaked to validate stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: validate stderr free of raw jq indexing noise"
fi
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-runtime dies cleanly on runtime.timeouts: false (no raw jq rc=5)" "1" "$RC"
# Explicitly EMPTY keys (`runtime:` / `timeouts:` → null) keep the absent semantics.
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'runtime:' key (null = absent)" "0" "$RC"
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  timeouts:\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'timeouts:' key (null = absent)" "0" "$RC"
rm -rf "$TDIR" "$ERR"

# === Test 47: claude: catalog — type gate, charset, duplicates ===
# Same class of gate as Test 41 (codex:/gemini:): a scalar `claude:` section must die
# cleanly instead of crashing the getters with a raw jq "Cannot index boolean" (rc=5).
# The catalog is charset-validated with IDENT_RE (no enum — forward-compat), and
# duplicates are rejected because two reviewers under one name are indistinguishable
# in the dedup tables.
echo "=== Test 47: claude: catalog validation ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

{ printf '%s\n' "$BASE"; printf 'claude: false\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on claude: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "claude: must be a mapping" "$ERR"
if grep -q -- "Cannot index" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: raw jq indexing noise leaked to validate stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: validate stderr free of raw jq indexing noise"
fi

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: opus\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a scalar claude.models" "1" "$RC"
assert_stderr_contains "explains the list requirement" "claude.models: must be a list" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models:\n    - 5\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a non-string catalog entry" "1" "$RC"
assert_stderr_contains "explains the string requirement" "must be a string" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models:\n    - "-opus"\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a leading-dash catalog entry" "1" "$RC"
assert_stderr_contains "names the charset rule" "claude.models\[0\]: must start with" "$ERR"

# A space INSIDE the value. Unquoted YAML flow style makes this easy to write by accident
# (`models: [opus, claude fable]` is two entries, the second with a space), and an entry
# with a space would be word-split by the membership globs downstream.
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, "claude fable"]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a catalog entry containing a space" "1" "$RC"
assert_stderr_contains "names the charset rule for the space" "claude.models\[1\]" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, fable, opus]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate catalog entry" "1" "$RC"
assert_stderr_contains "names the duplicate" "duplicate model" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, fable, "claude-fable-5", "us.anthropic.claude-3-5-sonnet-20241022-v2:0"]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts aliases and full ids (dashes, dots, colon)" "0" "$RC"

# An explicitly EMPTY key (`claude:` → null) keeps the absent semantics, like codex:.
{ printf '%s\n' "$BASE"; printf 'claude:\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'claude:' key (null = absent)" "0" "$RC"

# An empty list is legal and simply means "no catalog" (mirrors defaults.*.models).
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: []\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on an empty claude.models list" "0" "$RC"

# A mapping with no models key at all. `.claude.models | type` is "null" here, so this is
# deliberately equivalent to "no section" — UNLIKE codex:/gemini:, where a section missing
# its `model:` key is a hard error. Pinned by a test so a future maintainer does not
# "restore" the missing check.
{ printf '%s\n' "$BASE"; printf 'claude: {}\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "treats 'claude: {}' as no catalog, not as an error" "0" "$RC"

rm -rf "$TDIR" "$ERR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
