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

echo "=== Test 14: full config.example.yaml validates ==="
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

echo "=== Test 15: export every model in config.example.yaml ==="
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

# === Test 30: get-runtime surfaces runtime.max_redispatch from config ===
# (consumed by /mesh-review Step 6.0 guard as the auto-redispatch round cap)
echo "=== Test 33: get-runtime emits max_redispatch from config ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  max_redispatch: 3\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.max_redispatch')
if [ "$GOT" = "3" ]; then PASS=$((PASS+1)); echo "  PASS: max_redispatch=3"; else FAIL=$((FAIL+1)); echo "  FAIL: max_redispatch (expected 3, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 31: get-runtime defaults max_redispatch to 1 when absent ===
echo "=== Test 34: get-runtime defaults max_redispatch to 1 ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  default_run_mode: team\n' > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime | jq -r '.max_redispatch')
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: default 1"; else FAIL=$((FAIL+1)); echo "  FAIL: default (expected 1, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 32: validate_runtime rejects non-positive max_redispatch ===
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

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
