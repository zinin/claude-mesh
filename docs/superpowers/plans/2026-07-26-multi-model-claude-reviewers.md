# Multi-Model Claude Reviewers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `/claude-mesh:mesh-review` and `/claude-mesh:mesh-design-review` to launch several independent built-in Claude reviewers, each on a different Claude model (e.g. `opus` and `fable`), instead of exactly one reviewer pinned to the global `runtime.dispatch_model`.

**Architecture:** A new optional `claude:` config section holds a catalog of Claude model aliases; a new per-preset key `defaults.<preset>.claude_models` holds the default selection. `config-loader.sh` validates both and exposes them through two new subcommands plus one extended getter. The two orchestrators (`commands/mesh-review.md`, `skills/mesh-design-review/SKILL.md`) read the catalog, offer a selection page in the interactive UI, and dispatch one `general-purpose` subagent per selected model with an explicit `model:` override. When no Claude models are configured or selected, behaviour is byte-for-byte what it is today: one reviewer on `dispatch_model` (or on the session model).

**Tech Stack:** bash 4+ (`config-loader.sh`, test harness), `jq`, Python-yq (`kislyuk/yq`), Claude Code plugin markdown (commands and skills are prompts, not code).

**Spec:** `docs/superpowers/specs/2026-07-26-multi-model-claude-reviewers-design.md`

## Global Constraints

- **Bash 4+, `set -u`.** No associative arrays — duplicate checks use the line-based accumulator idiom already in `validate_models` (`config-loader.sh:207`, `case " $seen_ids " in *" $id "*)`).
- **All config reads go through `config-loader.sh`.** Commands and skills never call raw `yq`/`jq` on `config.yaml`.
- **`die`/`warn` messages are English.** User-facing prose inside `commands/*.md` and `skills/*/SKILL.md` is Russian. Both conventions already hold in the repo — do not mix them.
- **No model enums.** Charset validation only, via the existing `IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._:@-]*$'` (`config-loader.sh:57`). A new Claude model must never require a plugin release.
- **Agents never edit `config.yaml`.** Validation errors are surfaced to the user verbatim.
- **`skills/shared/verify-delegation.sh` is not modified** and is never called for a Claude reviewer.
- **`runtime.dispatch_model` keeps its current meaning** for codex/gemini/ext-claude wrappers, the `review-discussion` agent and `/do-plan` subagents.
- **Full test suite must end green after every task:** `bash skills/shared/tests/test-config-loader.sh` → last line `=== Summary: N passed, 0 failed ===`, exit 0.
- **One commit per task. Never push.** Branch is `feature/multi-model-claude-reviewers` (already created, spec committed as `782ebd0`).
- **`subagent_type: "general-purpose"` is a BUILT-IN agent type — not `claude-mesh:`-namespaced.** Plugin agent types are namespaced; this one is not.
- Line numbers in this plan are as of commit `782ebd0`. If an anchor moved, locate it by the quoted text, not by the number.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `skills/shared/config-loader.sh` | Parse + validate the `claude:` catalog and `defaults.*.claude_models`; expose them via `get-flag has_claude_models`, `list-claude-models`, `get-defaults` | 1, 2, 3, 4 |
| `skills/shared/tests/test-config-loader.sh` | Tests 47–51 for all of the above | 1, 2, 3, 4, 5 |
| `config.example.yaml` | Documents the new section and preset key | 5 |
| `commands/mesh-review.md` | Reads the catalog, adds the selection page, fans out the dispatch, attributes findings | 6 |
| `skills/mesh-design-review/SKILL.md` | Same, plus the fix for `claude` being silently ignored | 7 |
| `README.md`, `CHANGELOG.md` | User-facing documentation of the feature and the fix | 8 |

---

## Task 1: Validate the `claude:` catalog

**Files:**
- Modify: `skills/shared/config-loader.sh` (add `validate_claude()` between `validate_gemini()` — ends at `:333` — and `validate_defaults()` — starts at `:335`; wire into `validate_all()` at `:491-501`)
- Test: `skills/shared/tests/test-config-loader.sh` (append Test 47 before the final `echo ""` / Summary block at `:869`)

**Interfaces:**
- Consumes: `IDENT_RE` (`:57`), `die` (`:38`), `$CONFIG_JSON` (the jq snapshot every validator reads)
- Produces: `validate_claude()` — no args, no stdout, `die`s on the first problem. Called by `validate_all()` (Task 1), `validate_defaults()` (Task 2), `cmd_get_flag has_claude_models` and `cmd_list_claude_models` (Task 3).

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-config-loader.sh`, immediately BEFORE the trailing `echo ""` / `=== Summary` block:

```bash
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

rm -rf "$TDIR" "$ERR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | sed -n '/Test 47/,$p'`

Expected: FAIL lines for the `claude: false`, scalar, non-string, leading-dash and duplicate cases — all report `expected rc=1, got 0`, because nothing reads `.claude` yet. The accept/empty cases already PASS. Summary line shows a non-zero failure count and the script exits 1.

- [ ] **Step 3: Write the implementation**

In `skills/shared/config-loader.sh`, insert this function between the closing `}` of `validate_gemini()` (`:333`) and the `validate_defaults() {` line (`:335`):

```bash
validate_claude() {
    # Type-dispatch gate, same class as validate_codex/validate_gemini (fix wave 5):
    # a scalar `claude:` section must die cleanly instead of crashing the getters with
    # a raw jq "Cannot index boolean" (rc=5). null — key absent or an explicitly empty
    # key — keeps the absent semantics.
    #
    # DELIBERATE ASYMMETRY with codex:/gemini:: those sections are GATES (no section ⇒
    # `builtin: [codex]` is a hard error). `claude:` is NOT a gate — the builtin claude
    # reviewer has no external dependency and works with no section at all. This section
    # only widens it to several models.
    local stype
    stype=$(jq -r '.claude | type' "$CONFIG_JSON" 2>/dev/null)
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "claude: must be a mapping with a models key (got $stype)" ;;
    esac

    local mtype
    mtype=$(jq -r '.claude.models | type' "$CONFIG_JSON" 2>/dev/null)
    case "$mtype" in
        null) return 0 ;;
        array) ;;
        *) die "claude.models: must be a list of Claude model aliases, got $mtype" ;;
    esac

    local count
    count=$(jq '.claude.models | length' "$CONFIG_JSON")
    local i=0
    local seen=""   # line-based accumulator (no bash-4 associative arrays)
    while [ "$i" -lt "$count" ]; do
        local etype v
        etype=$(jq -r ".claude.models[$i] | type" "$CONFIG_JSON")
        [ "$etype" = "string" ] \
            || die "claude.models[$i]: must be a string (got $etype) — quote it, e.g. - \"opus\""
        v=$(jq -r ".claude.models[$i]" "$CONFIG_JSON")
        [ -n "$v" ] || die "claude.models[$i]: empty value"
        # Same forward-compatible charset as runtime.dispatch_model — no enum, a new
        # Claude model must never require a validator change. The leading-alnum anchor
        # rejects flag-injection (-opus/.foo).
        [[ "$v" =~ $IDENT_RE ]] \
            || die "claude.models[$i]: must start with a letter/digit and match [A-Za-z0-9._:@-] (a model alias or id), got \"$v\""
        # Duplicates would produce two reviewers with the same name — indistinguishable
        # in the dedup/attribution tables of both orchestrators.
        case " $seen " in
            *" $v "*) die "claude.models[$i]: duplicate model \"$v\" (two reviewers would be indistinguishable)" ;;
        esac
        seen="$seen $v"
        i=$((i+1))
    done
}
```

Then wire it into `validate_all()` (`:491-501`). Replace:

```bash
    validate_providers
    validate_models
    validate_codex
    validate_gemini
    validate_defaults
    validate_runtime
```

with:

```bash
    validate_providers
    validate_models
    validate_codex
    validate_gemini
    validate_claude
    validate_defaults
    validate_runtime
```

and extend the comment directly above it (`Order matters: providers first (models reference providers), then models, then sections that reference models (defaults), then runtime.`) to read:

```bash
    # Single source of truth for the full validation pipeline.
    # Order matters: providers first (models reference providers), then models, then
    # the per-engine sections, then sections that reference BOTH models and the claude
    # catalog (defaults), then runtime.
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -20`
Expected: `=== Summary: N passed, 0 failed ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh
git commit -m "feat(config-loader): validate the claude: model catalog"
```

---

## Task 2: Validate `defaults.<preset>.claude_models`

**Files:**
- Modify: `skills/shared/config-loader.sh` (`validate_defaults()`, `:335-418`)
- Test: `skills/shared/tests/test-config-loader.sh` (append Test 48)

**Interfaces:**
- Consumes: `validate_claude()` from Task 1
- Produces: no new symbol; `validate_defaults()` now additionally rejects a malformed / unknown / orphaned `claude_models` list. `cmd_get_defaults` (Task 4) relies on this having run.

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-config-loader.sh`, before the Summary block:

```bash
# === Test 48: defaults.<preset>.claude_models validation ===
# Membership mirrors defaults.*.models ⊂ models[].id. The "claude missing from builtin"
# rule is fail-closed on purpose: a silently ignored claude_models list is exactly the
# bug this feature fixes in mesh-design-review, so it must never be introduced here.
echo "=== Test 48: defaults.claude_models validation ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
CATALOG=$(printf 'claude:\n  models: [opus, fable]\n')

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: opus\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a scalar claude_models" "1" "$RC"
assert_stderr_contains "explains the list requirement" "claude_models: must be a list" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, sonnet]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a model absent from the catalog" "1" "$RC"
assert_stderr_contains "names the unknown model" 'unknown claude model "sonnet"' "$ERR"

# No catalog at all: every entry is "unknown", and the message must point at the catalog.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects claude_models with no claude.models catalog" "1" "$RC"
assert_stderr_contains "points at the catalog" "claude.models catalog" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [codex]\n    claude_models: [opus]\ncodex:\n  model: gpt-5.5\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects claude_models without claude in builtin" "1" "$RC"
assert_stderr_contains "names the missing builtin entry" 'is missing from defaults.code_review.builtin' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, opus]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate claude_models entry" "1" "$RC"
assert_stderr_contains "names the duplicate" 'duplicate model "opus"' "$ERR"

# design_review is validated by the same loop.
{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  design_review:\n    builtin: [claude]\n    claude_models: [sonnet]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "applies the same rules to design_review" "1" "$RC"
assert_stderr_contains "names the design_review preset" "defaults.design_review.claude_models" "$ERR"

# Happy path: catalog wider than the presets, presets differing from each other.
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, sonnet, fable]\n'; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, fable]\n  design_review:\n    builtin: [claude]\n    claude_models: [opus]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts differing per-preset subsets of a wider catalog" "0" "$RC"

# Back-compat: claude in builtin with NO claude_models stays valid (fallback = 1 reviewer).
{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts builtin claude with no claude_models" "0" "$RC"

rm -rf "$TDIR" "$ERR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | sed -n '/Test 48/,$p'`
Expected: FAIL lines reporting `expected rc=1, got 0` for the scalar, unknown-model, no-catalog, missing-builtin, duplicate and design_review cases — `claude_models` is currently an unknown key that the validator ignores.

- [ ] **Step 3: Write the implementation**

In `validate_defaults()` (`:335`), insert the `validate_claude` call and the catalog read right after the early-return probe. Replace:

```bash
validate_defaults() {
    if ! jq -e '.defaults' "$CONFIG_JSON" >/dev/null 2>&1; then
        return 0
    fi

    local has_codex has_gemini
```

with:

```bash
validate_defaults() {
    if ! jq -e '.defaults' "$CONFIG_JSON" >/dev/null 2>&1; then
        return 0
    fi

    # claude_models entries are checked against the claude.models catalog below, so the
    # catalog must be a well-formed list FIRST. validate_claude is cheap and idempotent
    # (validate_all calls it directly too); calling it here is what keeps cmd_get_defaults
    # — which runs ONLY this validator, per the typed-getter principle (iter-2
    # CONCERN-2/3) — from indexing a scalar `claude:` section with raw jq.
    validate_claude

    local claude_catalog
    claude_catalog=$(jq -r '(.claude.models // [])[]' "$CONFIG_JSON" | tr '\n' ' ')

    local has_codex has_gemini
```

Then, inside the `for preset in "${presets[@]}"` loop, insert the `claude_models` block between the end of the model-entries `while` loop and the `# run_mode (only for code_review)` comment. Locate:

```bash
            m=$((m+1))
        done

        # run_mode (only for code_review)
```

and replace it with:

```bash
            m=$((m+1))
        done

        # claude_models entries — the built-in claude reviewer fanned out over several
        # Claude models. Same shape as the models[] check above: type gate, membership in
        # the catalog, no duplicates.
        local cmtype
        cmtype=$(jq -r ".defaults.$preset.claude_models | type" "$CONFIG_JSON")
        case "$cmtype" in
            array|null) ;;
            *) die "defaults.$preset.claude_models: must be a list, got $cmtype" ;;
        esac

        local cm_count
        cm_count=$(jq ".defaults.$preset.claude_models | length" "$CONFIG_JSON" 2>/dev/null || echo 0)
        if [ "$cm_count" -gt 0 ]; then
            # Fail closed: a claude_models list with no "claude" in builtin is almost
            # certainly a typo, and a SILENTLY IGNORED list is exactly the bug this
            # feature fixes in mesh-design-review. Never repeat it here.
            local claude_in_builtin
            claude_in_builtin=$(jq "[(.defaults.$preset.builtin // [])[] | select(. == \"claude\")] | length" "$CONFIG_JSON")
            [ "$claude_in_builtin" -gt 0 ] \
                || die "defaults.$preset.claude_models is set but \"claude\" is missing from defaults.$preset.builtin"
        fi

        local c=0
        local seen_cm=""
        while [ "$c" -lt "$cm_count" ]; do
            local cmv
            cmv=$(jq -r ".defaults.$preset.claude_models[$c]" "$CONFIG_JSON")
            # Quoted case-membership (glob/word-split safe), same idiom as the models[]
            # check above. An absent catalog makes $claude_catalog empty, so every entry
            # lands here — hence the "add it to the claude.models catalog" hint.
            case " $claude_catalog " in
                *" $cmv "*) ;;
                *) die "defaults.$preset.claude_models[$c]: unknown claude model \"$cmv\" (add it to the claude.models catalog)" ;;
            esac
            case " $seen_cm " in
                *" $cmv "*) die "defaults.$preset.claude_models[$c]: duplicate model \"$cmv\"" ;;
            esac
            seen_cm="$seen_cm $cmv"
            c=$((c+1))
        done

        # run_mode (only for code_review)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -20`
Expected: `=== Summary: N passed, 0 failed ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh
git commit -m "feat(config-loader): validate defaults.<preset>.claude_models"
```

---

## Task 3: Expose the catalog — `get-flag has_claude_models` and `list-claude-models`

**Files:**
- Modify: `skills/shared/config-loader.sh` (`cmd_get_flag` `:637-688`; new `cmd_list_claude_models` after `cmd_list_models` which ends at `:697`; dispatcher `:760-798`; usage line `:795`)
- Test: `skills/shared/tests/test-config-loader.sh` (append Test 49)

**Interfaces:**
- Consumes: `validate_claude()` from Task 1
- Produces:
  - `config-loader.sh get-flag has_claude_models` → prints `1` or `0`, exit 0 (exit 1 if the `claude:` section is malformed)
  - `config-loader.sh list-claude-models` → prints one model alias per line in config order; prints nothing and exits 0 when there is no catalog

  Both are consumed by `commands/mesh-review.md` (Task 6) and `skills/mesh-design-review/SKILL.md` (Task 7).

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-config-loader.sh`, before the Summary block:

```bash
# === Test 49: get-flag has_claude_models + list-claude-models ===
# Unlike has_codex/has_gemini (plain section-existence probes) these read INSIDE the
# section, so they must validate first — a raw jq read on `claude: false` would exit 5
# with "Cannot index boolean" and the orchestrators would surface that as garbage.
echo "=== Test 49: has_claude_models / list-claude-models ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, fable]\n'; } > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=1 with a catalog"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 1, got '$GOT')"; fi
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" list-claude-models | tr '\n' ',')
if [ "$GOT" = "opus,fable," ]; then PASS=$((PASS+1)); echo "  PASS: list-claude-models keeps config order"; else FAIL=$((FAIL+1)); echo "  FAIL: list-claude-models (expected 'opus,fable,', got '$GOT')"; fi

{ printf '%s\n' "$BASE"; } > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "0" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=0 with no section"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 0, got '$GOT')"; fi
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" list-claude-models >"$TDIR/out" 2>"$ERR"; RC=$?
assert_exit "list-claude-models exits 0 with no catalog" "0" "$RC"
if [ ! -s "$TDIR/out" ]; then PASS=$((PASS+1)); echo "  PASS: list-claude-models prints nothing with no catalog"; else FAIL=$((FAIL+1)); echo "  FAIL: expected empty output, got '$(cat "$TDIR/out")'"; fi

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: []\n'; } > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "0" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=0 on an empty list"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 0, got '$GOT')"; fi

{ printf '%s\n' "$BASE"; printf 'claude: false\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_claude_models >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-flag dies cleanly on claude: false (no raw jq rc=5)" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "claude: must be a mapping" "$ERR"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" list-claude-models >/dev/null 2>"$ERR"; RC=$?
assert_exit "list-claude-models dies cleanly on claude: false" "1" "$RC"

{ printf '%s\n' "$BASE"; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag no_such_flag >/dev/null 2>"$ERR"; RC=$?
assert_exit "unknown get-flag feature still dies" "1" "$RC"
assert_stderr_contains "lists has_claude_models among valid features" "has_claude_models" "$ERR"

rm -rf "$TDIR" "$ERR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | sed -n '/Test 49/,$p'`
Expected: FAILs — `get-flag has_claude_models` currently hits the `*)` branch and dies with `unknown feature`, and `list-claude-models` hits the dispatcher's `*)` usage branch (exit 2). The "unknown feature lists has_claude_models" assert also fails.

- [ ] **Step 3: Write the implementation**

**3a.** In `cmd_get_flag` (`:637`), add a case right after the `has_models)` case (`:655-657`):

```bash
        has_claude_models)
            # Non-empty claude.models catalog? Gates the Claude-model selection page in
            # /mesh-review and /mesh-design-review. Unlike has_codex/has_gemini (plain
            # section-existence probes) this reads INSIDE the section, so it must
            # validate first: a raw jq read on `claude: false` exits 5 with
            # "Cannot index boolean". Mirrors the typed-getter cases below.
            validate_claude
            jq -e '.claude.models[0]' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
```

**3b.** In the same function, update the unknown-feature `die` (`:685`):

```bash
            die "get-flag: unknown feature \"$feature\" (valid: has_codex, has_gemini, has_models, has_claude_models, has_defaults_code_review, do_plan_default_stop_tokens, dispatch_model)"
```

**3c.** Add the new command function immediately after `cmd_list_models()` (which ends at `:697`) and before `cmd_list_providers()`:

```bash
cmd_list_claude_models() {
    # Emit one Claude model alias per line, in config order. Unlike cmd_list_models there
    # is NO "<id>|<label>" pair: a Claude alias (opus / fable / …) is self-describing, so
    # the catalog is a flat list of strings. If labels are ever needed, the catalog can be
    # widened to {id, label} objects without breaking this line-per-entry contract.
    # Prints nothing (exit 0) when there is no catalog.
    load_or_die
    validate_claude
    jq -r '(.claude.models // [])[]' "$CONFIG_JSON"
}
```

**3d.** In the dispatcher `case` (`:760`), add after the `list-models)` branch (`:775-777`):

```bash
    list-claude-models)
        cmd_list_claude_models
        ;;
```

**3e.** Update the usage line (`:795`):

```bash
        echo "Usage: $0 {validate|data-dir|export <model-id>|get-flag <feature>|list-models|list-claude-models|list-providers|get-defaults <category>|get-runtime|get-codex|get-gemini}" >&2
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -20`
Expected: `=== Summary: N passed, 0 failed ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh
git commit -m "feat(config-loader): add has_claude_models flag and list-claude-models"
```

---

## Task 4: `get-defaults` emits `claude_models`

**Files:**
- Modify: `skills/shared/config-loader.sh` (`cmd_get_defaults`, `:729-740`)
- Test: `skills/shared/tests/test-config-loader.sh` (append Test 50)

**Interfaces:**
- Consumes: `validate_defaults()` from Task 2
- Produces: `config-loader.sh get-defaults <code_review|design_review>` → one-line JSON object
  `{"builtin":[…],"claude_models":[…],"models":[…],"run_mode":…}`. Consumed by `commands/mesh-review.md` Step 0 (Task 6) and `skills/mesh-design-review/SKILL.md` Step 5.0/5.1 (Task 7).

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-config-loader.sh`, before the Summary block:

```bash
# === Test 50: get-defaults emits claude_models ===
# The orchestrators read the preset through this single JSON object; a missing key would
# make them fall back to "no claude models" and silently under-dispatch.
echo "=== Test 50: get-defaults emits claude_models ==="
TDIR=$(mktemp -d)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, sonnet, fable]\n'; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, fable]\n  design_review:\n    builtin: [claude]\n    claude_models: [opus]\n'; } > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | join(",")')
if [ "$GOT" = "opus,fable" ]; then PASS=$((PASS+1)); echo "  PASS: code_review claude_models=opus,fable"; else FAIL=$((FAIL+1)); echo "  FAIL: code_review claude_models (expected 'opus,fable', got '$GOT')"; fi
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults design_review | jq -r '.claude_models | join(",")')
if [ "$GOT" = "opus" ]; then PASS=$((PASS+1)); echo "  PASS: design_review claude_models=opus"; else FAIL=$((FAIL+1)); echo "  FAIL: design_review claude_models (expected 'opus', got '$GOT')"; fi

# Absent key → an empty list that is PRESENT in the object, never a missing key and never
# null. Tested with has() on purpose: `null | length` is 0 in jq, so a length check would
# pass even when the field is absent entirely.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r 'has("claude_models")')
if [ "$GOT" = "true" ]; then PASS=$((PASS+1)); echo "  PASS: claude_models key always present"; else FAIL=$((FAIL+1)); echo "  FAIL: expected has(claude_models)=true, got '$GOT'"; fi
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | type')
if [ "$GOT" = "array" ]; then PASS=$((PASS+1)); echo "  PASS: absent claude_models becomes []"; else FAIL=$((FAIL+1)); echo "  FAIL: expected an array, got '$GOT'"; fi
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.builtin | join(",")')
if [ "$GOT" = "claude" ]; then PASS=$((PASS+1)); echo "  PASS: existing get-defaults fields intact"; else FAIL=$((FAIL+1)); echo "  FAIL: builtin (expected 'claude', got '$GOT')"; fi

rm -rf "$TDIR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | sed -n '/Test 50/,$p'`
Expected: four FAILs — the two `join(",")` asserts print an empty string, `has("claude_models")` prints `false`, and `.claude_models | type` prints `null`, because `cmd_get_defaults` does not emit the field yet. The `builtin` assert PASSes.

- [ ] **Step 3: Write the implementation**

In `cmd_get_defaults` (`:729`), replace the final `jq` line and extend the comment above it:

```bash
    # iter-3 CONCERN-1: emit a JSON object so orchestrators get builtin + claude_models +
    # models + run_mode (run_mode meaningful only for code_review) through the loader
    # instead of raw yq. -c = one line. claude_models defaults to [] and never null —
    # both orchestrators iterate it directly.
    jq -c "{builtin: (.defaults.${category}.builtin // []), claude_models: (.defaults.${category}.claude_models // []), models: (.defaults.${category}.models // []), run_mode: (.defaults.${category}.run_mode // null)}" "$CONFIG_JSON"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -20`
Expected: `=== Summary: N passed, 0 failed ===`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh
git commit -m "feat(config-loader): expose claude_models through get-defaults"
```

---

## Task 5: Document the schema in `config.example.yaml`

**Files:**
- Modify: `config.example.yaml` (section header at `:137-141`; `codex:`/`gemini:` block at `:143-151`; `defaults:` block at `:160-180`)
- Test: `skills/shared/tests/test-config-loader.sh` (append Test 51)

**Interfaces:**
- Consumes: everything from Tasks 1–4
- Produces: a worked example whose `claude.models` catalog is WIDER than either preset (so the ★-recommended vs merely-available distinction is visible), and whose two presets declare DIFFERENT sets (so the per-preset capability is visible).

Note: existing Test 31 (`full config.example.yaml validates`) and Test 32 (`export every model in config.example.yaml`) already run against this file and must stay green.

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-config-loader.sh`, before the Summary block:

```bash
# === Test 51: config.example.yaml documents the claude catalog end-to-end ===
# Guards the worked example itself: the catalog must be wider than the presets (so the
# ★-recommended vs available distinction is demonstrable) and the two presets must differ
# (so the per-preset capability is demonstrable). A doc-only example that silently loses
# these properties would mis-teach every new user.
echo "=== Test 51: config.example.yaml claude catalog round-trip ==="
TDIR=$(mktemp -d)
cp "$TESTS_DIR/../../../config.example.yaml" "$TDIR/config.yaml"
CATALOG=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" list-claude-models | tr '\n' ',')
if [ "$CATALOG" = "opus,sonnet,fable," ]; then PASS=$((PASS+1)); echo "  PASS: example catalog is opus,sonnet,fable"; else FAIL=$((FAIL+1)); echo "  FAIL: example catalog (expected 'opus,sonnet,fable,', got '$CATALOG')"; fi
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=1 for the example"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 1, got '$GOT')"; fi
CR=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | join(",")')
DR=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults design_review | jq -r '.claude_models | join(",")')
if [ "$CR" = "opus,fable" ]; then PASS=$((PASS+1)); echo "  PASS: example code_review claude_models=opus,fable"; else FAIL=$((FAIL+1)); echo "  FAIL: code_review claude_models (expected 'opus,fable', got '$CR')"; fi
if [ "$DR" = "opus" ]; then PASS=$((PASS+1)); echo "  PASS: example design_review claude_models=opus"; else FAIL=$((FAIL+1)); echo "  FAIL: design_review claude_models (expected 'opus', got '$DR')"; fi
if [ "$CR" != "$DR" ]; then PASS=$((PASS+1)); echo "  PASS: example presets demonstrate differing sets"; else FAIL=$((FAIL+1)); echo "  FAIL: example presets must differ to demonstrate the feature"; fi
rm -rf "$TDIR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | sed -n '/Test 51/,$p'`
Expected: all five asserts FAIL — the example has no `claude:` section and no `claude_models` keys yet, so the catalog is empty and both preset lists are empty strings (which also makes the "must differ" assert fail).

- [ ] **Step 3: Write the implementation**

**3a.** Replace the section header block at `config.example.yaml:137-141`:

```yaml
# ============================================================================
# (3) External CLI tools                                          [optional]
# ============================================================================
# These are NOT Anthropic-API endpoints — they shell out to the codex / gemini
# CLIs. Omit a section entirely to remove that tool from the UI and from any
# `defaults.*.builtin` list (referencing it in builtin then becomes a hard error).
```

with:

```yaml
# ============================================================================
# (3) Built-in reviewers                                          [optional]
# ============================================================================
# Configuration for the three built-in reviewer types selectable in
# `defaults.*.builtin`: claude, codex, gemini.
#
#   * codex: / gemini: are GATES — they shell out to the codex / gemini CLIs and
#     are NOT Anthropic-API endpoints. Omit a section entirely to remove that tool
#     from the UI and from any `defaults.*.builtin` list (referencing it in builtin
#     then becomes a hard error).
#   * claude: is NOT a gate — the built-in claude reviewer is your own Claude Code
#     and has no external dependency, so `builtin: [claude]` works with no section
#     here at all. The section only WIDENS it to several Claude models.
```

**3b.** Insert the `claude:` block immediately after that header and BEFORE the existing `codex:` block (`:143`):

```yaml
claude:
  # Catalog of Claude models offered when you pick the built-in `claude` reviewer.
  # Each entry becomes ONE independent reviewer: same diff, same prompt, different
  # model — so `[opus, fable]` gives you two genuinely independent cross-checks that
  # your main session then aggregates.
  #
  # Values are what the Task tool's `model:` parameter accepts in YOUR Claude Code
  # build — practically the aliases `opus | sonnet | haiku | fable`. No enum is
  # enforced (a new model must never require a plugin release), so a name your build
  # does not support is not caught here: the dispatch fails at runtime instead.
  #
  # COST: N models = N full reviews. Three Claude models plus codex plus five
  # external models is nine reviewers for one /mesh-review.
  #
  # Omit this section (or leave the list empty) and the built-in claude reviewer
  # behaves exactly as before: exactly ONE reviewer, on runtime.dispatch_model, or
  # on your current session model when that is unset.
  models: [opus, sonnet, fable]              # [optional] list of Claude model aliases
```

**3c.** Add `claude_models` to both presets in the `defaults:` block. Replace `:160-180`:

```yaml
defaults:
  code_review:                                 # used by: /mesh-review default
    builtin: [claude, codex, gemini]           # [optional] list; subset of { claude, codex, gemini }.
                                               #   claude  — your own Claude Code via superpowers:requesting-code-review
                                               #             (needs NO config section).
                                               #   codex   — requires the codex: section above.
                                               #   gemini  — requires the gemini: section above.
    models: [zai/glm, ollama/kimi, deepseek/v4-pro, ollama/minimax]
```

with:

```yaml
defaults:
  code_review:                                 # used by: /mesh-review default
    builtin: [claude, codex, gemini]           # [optional] list; subset of { claude, codex, gemini }.
                                               #   claude  — your own Claude Code via superpowers:requesting-code-review
                                               #             (needs NO config section; see claude: above to fan it
                                               #             out over several models).
                                               #   codex   — requires the codex: section above.
                                               #   gemini  — requires the gemini: section above.
    claude_models: [opus, fable]               # [optional] list; each entry must be in the claude.models
                                               #   catalog above, and "claude" must be present in builtin.
                                               #   In `default` mode: one reviewer per entry.
                                               #   In the interactive UI: these get the ★ recommended marker,
                                               #   while the rest of the catalog is merely offered.
                                               #   Omit it and `default` mode runs exactly ONE claude reviewer,
                                               #   on runtime.dispatch_model — the pre-0.5 behaviour.
    models: [zai/glm, ollama/kimi, deepseek/v4-pro, ollama/minimax]
```

and replace the `design_review:` preset (`:177-180`):

```yaml
  design_review:                               # used by: /mesh-design-review default
    builtin: [codex, gemini]                   # [optional] same valid set { claude, codex, gemini }.
    models: [zai/glm, ollama/kimi, deepseek/v4-pro, ollama/minimax]
                                               # NOTE: design_review has NO run_mode field (ignored if present).
```

with:

```yaml
  design_review:                               # used by: /mesh-design-review default
    builtin: [claude, codex, gemini]           # [optional] same valid set { claude, codex, gemini }.
    claude_models: [opus]                      # [optional] deliberately narrower than code_review's —
                                               #   the two presets are independent.
    models: [zai/glm, ollama/kimi, deepseek/v4-pro, ollama/minimax]
                                               # NOTE: design_review has NO run_mode field (ignored if present).
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -20`
Expected: `=== Summary: N passed, 0 failed ===`, exit 0 — including the pre-existing Tests 31 and 32, which validate and export from this same file.

- [ ] **Step 5: Commit**

```bash
git add config.example.yaml skills/shared/tests/test-config-loader.sh
git commit -m "docs(config): document the claude model catalog and claude_models presets"
```

---

## Task 6: `/mesh-review` — read, offer, dispatch, attribute

**Files:**
- Modify: `commands/mesh-review.md` (Step 0 `:14-22`; Step 1 `:55-62`; new Step 2.4 before `## Step 2.5` at `:82`; Step 2.5 `:84-93`; Step 5a `:147-161`; Step 6.0 `:212` and `:241-248`; Step 6.1 `:272`)

**Interfaces:**
- Consumes: `get-flag has_claude_models`, `list-claude-models`, `get-defaults code_review` `.claude_models` (Tasks 3, 4)
- Produces: nothing other tasks consume. Task 7 mirrors this file's Step 2.4 wording into the design-review skill — keep the two texts aligned.

This file is a prompt, not code: there is no unit test. Verification is a set of grep assertions plus a read-through checklist.

- [ ] **Step 1: Extend the `default`-mode preset expansion (Step 0)**

In `commands/mesh-review.md`, in the first bullet of Step 0, change the jq field list from

`parse with jq (\`.builtin\`, \`.models\`, \`.run_mode\`)`

to

`parse with jq (\`.builtin\`, \`.claude_models\`, \`.models\`, \`.run_mode\`)`

Then replace the "Spawn all reviewers per preset" bullet block (`:18-20`):

```markdown
- Spawn all reviewers per preset:
  - For each entry in `defaults.code_review.builtin` (claude/codex/gemini), spawn the corresponding agent.
  - For each model id in `defaults.code_review.models`, spawn `ext-claude-code-reviewer` with `MODEL=<id>`.
```

with:

```markdown
- Spawn all reviewers per preset:
  - `claude` in `defaults.code_review.builtin` → expand over `defaults.code_review.claude_models`:
    - list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`. This model **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
    - list absent/empty → exactly **one** reviewer named `claude`, dispatched with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise with no `model:` at all (inherits the session model). This is the pre-0.5 behaviour and stays the default.
  - `codex` / `gemini` in `defaults.code_review.builtin` → spawn the corresponding agent.
  - For each model id in `defaults.code_review.models`, spawn `ext-claude-code-reviewer` with `MODEL=<id>`.
```

- [ ] **Step 2: Read the catalog in interactive mode (Step 1)**

In the Step 1 bash fence, after the existing lines

```bash
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
```

append (still inside the same fence):

```bash
# Claude-model catalog (Step 2.4 gate). rc-aware like the dispatch_model read above:
# these two subcommands validate the `claude:` section, so a malformed section must
# fast-fail here with the validator's own message rather than surface as an empty list.
CM_ERR=$(mktemp)
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (секция claude):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
CLAUDE_MODELS=$("$LOADER" list-claude-models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (claude.models):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
rm -f "$CM_ERR"
echo "HAS_CLAUDE_MODELS=$HAS_CLAUDE_MODELS"
echo "CLAUDE_MODELS=[$(echo "$CLAUDE_MODELS" | tr '\n' ' ')]"
```

- [ ] **Step 3: Insert the new Step 2.4 selection page**

Insert this whole section immediately BEFORE the `## Step 2.5 (Q1.5): Confirm reviewer-type selection` heading:

```markdown
## Step 2.4 (Q1.6): Claude-model selection

Runs ONLY when Q1 selected `claude` **and** `HAS_CLAUDE_MODELS=1`.

- `claude` NOT selected in Q1 → skip this step entirely; **no claude reviewer runs at all**, whatever the catalog holds.
- `claude` selected but `HAS_CLAUDE_MODELS=0` → skip this step; exactly **one** reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty).

Build `CLAUDE_DEFAULT_IDS` from the preset: `"$LOADER" get-defaults code_review | jq -r '.claude_models[]?'`.

For each chunk of 4 entries from `CLAUDE_MODELS` (in config order) — same pagination mechanics as Step 3, and the same reason for the ★ marker (AskUserQuestion has no `preSelected` API):

```
header: "Claude"
question: "На каких Claude-моделях запустить ревью? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in CLAUDE_DEFAULT_IDS
                 "★ <model> (recommended)"     if in CLAUDE_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections across pages into `SELECTED_CLAUDE_MODELS`.

**Empty selection is not an error.** It falls back to exactly one reviewer named `claude` on `DISPATCH_MODEL`/session model — identical to the `HAS_CLAUDE_MODELS=0` case. Do not re-ask and do not STOP.

Each selected model becomes an independent reviewer with the same diff and the same prompt — the point is model diversity, so never differentiate their prompts.
```

- [ ] **Step 4: Show the expanded set in the Step 2.5 confirmation**

In `## Step 2.5 (Q1.5): Confirm reviewer-type selection`, replace the opening sentence

`Mirror Step 3.5 (model confirmation): after Q1 answer, show the full SELECTED_TYPES list (one per line) and ask:`

with:

```markdown
Mirror Step 3.5 (model confirmation): after Q1 (and Step 2.4, when it ran), show the full SELECTED_TYPES list (one per line) and ask. **Expand `claude` in that list into one bullet per entry of `SELECTED_CLAUDE_MODELS`** (`claude:opus`, `claude:fable`), or a single `claude (модель по умолчанию)` bullet in the fallback case — the user must see how many Claude reviewers they are about to pay for.
```

and, in the same block, change the "Нет, выбрать заново" option description from `re-runs Q1` to `re-runs Q1 **and** Step 2.4`.

- [ ] **Step 5: Fan out the dispatch (Step 5a) and keep the wrapper list correct**

**5a.** In Step 5a, replace the **Dispatch model** paragraph (`:151`):

```markdown
**Dispatch model:** if `DISPATCH_MODEL` (resolved in Step 0 for `default` mode, or Step 1 for interactive) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch below. If it is empty, omit `model:` so each reviewer inherits this session's model. This applies to the builtin `claude` reviewer dispatch too.
```

with:

```markdown
**Dispatch model:** if `DISPATCH_MODEL` (resolved in Step 0 for `default` mode, or Step 1 for interactive) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch below. If it is empty, omit `model:` so each reviewer inherits this session's model.

**Exception — claude reviewers with an explicit model.** When Step 2.4 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL`. Running the review on a chosen model is the whole point; letting `DISPATCH_MODEL` win here would collapse every claude reviewer onto one model and fake the independence. `DISPATCH_MODEL` still governs the codex / gemini / ext-claude wrappers, and the single fallback `claude` reviewer.
```

**5b.** In the same step, replace the `claude` bullet of the per-reviewer list (`:154`):

```markdown
- claude: `subagent_type: "general-purpose"` (built-in — NOT namespaced), prompt invokes `superpowers:requesting-code-review` skill
```

with:

```markdown
- claude: `subagent_type: "general-purpose"` (built-in — NOT namespaced), prompt invokes `superpowers:requesting-code-review` skill. **One Task per entry of `SELECTED_CLAUDE_MODELS`**, each carrying `model: "<entry>"`; in the fallback case exactly one Task per the Dispatch-model rule above. All of them get the same prompt — only the model differs.
```

**5c.** In the Step 5a preamble (`:147`), replace

`The builtin \`claude\` / \`general-purpose\` reviewer is NOT a wrapper (it reviews inline by design) — exclude it from this list.`

with

`The builtin \`claude\` / \`general-purpose\` reviewers — there may now be several, one per Claude model — are NOT wrappers (they review inline by design). Exclude all of them from this list.`

**5d.** In the CRITICAL note at `:161`, replace the closing parenthetical

`(Only the builtin \`claude\` / \`general-purpose\` reviewer reviews directly.)`

with

`(Only the builtin \`claude\` / \`general-purpose\` reviewers review directly.)`

**5e.** At the end of Step 5a, replace

`The builtin \`claude\` reviewer is exempt: it reviews inline and completes on its own.`

with

`The builtin \`claude\` reviewers are exempt: they review inline, create no \`runs/<engine>/…\` dir and complete on their own. Never wait for a run dir for them and never ping them.`

**5f.** Team mode (Step 5b) delegates its rules to Step 5a, so the claude exception must be spelled out there too or the two steps contradict each other. In `## Step 5b: Team of reviewers mode`, replace item 2:

```markdown
2. Create one task per selected reviewer
```

with:

```markdown
2. Create one task per selected reviewer — with several Claude models selected that means one task per Claude model (`claude:opus`, `claude:fable`), not one shared `claude` task
```

and replace the last sentence of item 3:

```markdown
The Step 5a **Dispatch model** rule also applies here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it.
```

with:

```markdown
The Step 5a **Dispatch model** rule *and its claude exception* also apply here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it — except the claude teammates, which each carry their own `model:` from `SELECTED_CLAUDE_MODELS`.
```

- [ ] **Step 6: Put the claude reviewers into the Step 6.0 roster**

**6a.** Replace the exemption sentence at `:212`:

```markdown
The builtin `claude` / `general-purpose` reviewer is **skipped here** — it reviews inline by design and is always accepted into Step 6.1.
```

with:

```markdown
The builtin `claude` / `general-purpose` reviewers (one per selected Claude model, or a single fallback one) are **skipped by the guard** — they review inline by design and are always accepted into Step 6.1. `verify-delegation.sh` is never invoked for them.
```

**6b.** In point **3 (delegation status table)**, replace the example table with:

```
| Reviewer            | Verdict | Action          |
|---------------------|---------|-----------------|
| claude:opus         | INLINE  | ✅ по построению |
| claude:fable        | INLINE  | ✅ по построению |
| ext-claude/zai/glm  | REAL    | ✅ kept          |
| codex               | FLIP    | ↻ re-dispatch   |
| ext-claude/ollama/… | BROKEN  | ✗ dropped       |
```

and add below it:

```markdown
`INLINE` is a label **you** write, not a `verify-delegation.sh` verdict. Include one row per claude reviewer (a single row named `claude` in the fallback case) so the table is the complete roster of who actually reviewed — with several Claude models in play, a table that silently omits them understates the cross-validation.
```

- [ ] **Step 7: Attribute findings per Claude model (Step 6.1)**

In Step 6.1, replace point 1:

```markdown
1. **Deduplicate:** If multiple agents found the same issue (same file, same problem), merge into one entry. Note all agents that found it.
```

with:

```markdown
1. **Deduplicate:** If multiple agents found the same issue (same file, same problem), merge into one entry. Note all agents that found it. Claude reviewers are attributed as `claude:<model>` (`claude:opus`, `claude:fable`); a single fallback reviewer is just `claude`. Two different Claude models reporting the same issue is corroboration — exactly like codex and ext-claude agreeing — so merge them into one entry that lists both, never collapse them into a nameless "claude".
```

- [ ] **Step 8: Verify the edits**

Run:

```bash
grep -c 'claude_models\|SELECTED_CLAUDE_MODELS\|HAS_CLAUDE_MODELS\|claude:<model>\|claude:opus' commands/mesh-review.md
grep -n 'Step 2.4' commands/mesh-review.md
grep -n 'This applies to the builtin `claude` reviewer dispatch too' commands/mesh-review.md
grep -n 'is exempt: it reviews inline' commands/mesh-review.md
```

Expected:
- first command prints a count `>= 12`
- second prints at least 3 hits (the section heading plus the references from Steps 2.5 and 5a)
- third and fourth print **nothing** (both stale singular sentences are gone)

Then read the file once end-to-end and confirm the checklist:
1. Step 0 expands `claude` over `.claude_models` with the documented fallback.
2. Step 1 reads `HAS_CLAUDE_MODELS` and `CLAUDE_MODELS` rc-aware.
3. Step 2.4 exists, is gated on both conditions, and treats an empty selection as fallback (not an error).
4. Step 2.5 shows expanded `claude:<model>` bullets.
5. Step 5a dispatches one Task per Claude model, with the explicit-model exception spelled out.
5b. Step 5b (team mode) carries the same exception — it must not still say `DISPATCH_MODEL` applies to every teammate.
6. Step 5a excludes ALL claude reviewers from the wrapper list and from the watch/ping loop.
7. Step 6.0 lists them as `INLINE` rows and never calls `verify-delegation.sh` for them.
8. Step 6.1 attributes findings as `claude:<model>`.

- [ ] **Step 9: Run the loader suite (regression guard) and commit**

```bash
bash skills/shared/tests/test-config-loader.sh | tail -3
git add commands/mesh-review.md
git commit -m "feat(mesh-review): fan the builtin claude reviewer out over several models"
```

Expected: the suite still ends `=== Summary: N passed, 0 failed ===`.

---

## Task 7: `/mesh-design-review` — same capability, plus the ignored-`claude` fix

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (Step 5.0 bash fence `:236-243`; Step 5.1 `:247-258`; Step 5.2 `:260-275`; new Step 5.2.5 before `#### Step 5.3` at `:277`; Step 5.4 `:296-310`; Step 6 `:312-358`; Step 7 `:360-389`)

**Interfaces:**
- Consumes: `get-flag has_claude_models`, `list-claude-models` (Task 3), `get-defaults design_review` `.claude_models` (Task 4)
- Produces: nothing other tasks consume.

**Why this task also fixes a bug:** `config-loader.sh` accepts `claude` in `defaults.design_review.builtin`, but Step 5.1 only expands `codex` and `gemini`, and Step 5.2's Q1 has no `claude` option — so today the value is silently dropped and design review never runs a Claude reviewer at all.

- [ ] **Step 1: Read the catalog (Step 5.0)**

In the Step 5.0 bash fence, after

```bash
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
```

append (inside the same fence):

```bash
# Claude-model catalog (Step 5.2.5 gate). rc-aware like the dispatch_model read above:
# both subcommands validate the `claude:` section, so a malformed section fast-fails here.
CM_ERR=$(mktemp)
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (секция claude):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
CLAUDE_MODELS=$("$LOADER" list-claude-models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (claude.models):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
rm -f "$CM_ERR"
echo "HAS_CLAUDE_MODELS=$HAS_CLAUDE_MODELS"
echo "CLAUDE_MODELS=[$(echo "$CLAUDE_MODELS" | tr '\n' ' ')]"
```

Then, in the prose paragraph right below the fence, change

`Parse \`DEFAULTS_JSON\` with jq (\`.builtin\`, \`.models\`) to build \`DEFAULT_IDS\``

to

`Parse \`DEFAULTS_JSON\` with jq (\`.builtin\`, \`.claude_models\`, \`.models\`) to build \`DEFAULT_IDS\` (recommended ext-claude model ids), \`CLAUDE_DEFAULT_IDS\` (recommended Claude models)`

- [ ] **Step 2: Expand `claude` in `default` mode (Step 5.1) — the bug fix**

Replace the builtin-expansion bullets in Step 5.1:

```markdown
- For each entry in `.builtin`:
  - `codex` → spawn `claude-mesh:codex-executor`
  - `gemini` → spawn `claude-mesh:gemini-executor`
- For each model id in `.models` → spawn `claude-mesh:ext-claude-executor` with `MODEL=<id>`.
```

with:

```markdown
- For each entry in `.builtin`:
  - `claude` → expand over `.claude_models` (this branch was MISSING before 0.5, which is why `claude` in `defaults.design_review.builtin` used to be silently dropped):
    - list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`, which **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
    - list absent/empty → exactly **one** reviewer named `claude`, with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise no `model:` at all (inherits the session model).
  - `codex` → spawn `claude-mesh:codex-executor`
  - `gemini` → spawn `claude-mesh:gemini-executor`
- For each model id in `.models` → spawn `claude-mesh:ext-claude-executor` with `MODEL=<id>`.
```

- [ ] **Step 3: Offer `claude` in the interactive Q1 (Step 5.2) — the second half of the fix**

Replace the options block:

```
options:
  - "codex CLI ★ default"                          — show only if HAS_CODEX=1; ★ if "codex" in defaults.builtin
  - "gemini CLI ★ default"                         — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.builtin
  - "external models (Anthropic-API) ★ default"    — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```

with:

```
options:
  - "claude ★ default (свой Claude Code)"          — show ALWAYS; ★ if "claude" in defaults.builtin
  - "codex CLI ★ default"                          — show only if HAS_CODEX=1; ★ if "codex" in defaults.builtin
  - "gemini CLI ★ default"                         — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.builtin
  - "external models (Anthropic-API) ★ default"    — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```

and replace the parenthetical paragraph below it:

```markdown
(Show only the options whose gating flag is `1`. If none are available — no codex, no gemini, no models — STOP with "нет доступных reviewer-типов в config.yaml".) If "external models" is not selected → skip Step 5.3 entirely (only built-in executors run).
```

with:

```markdown
(Show the codex / gemini / external-models options only when their gating flag is `1`. The `claude` option is shown unconditionally — the built-in claude reviewer is your own Claude Code and needs no config section, so the old "нет доступных reviewer-типов" STOP is unreachable and has been removed.) If "external models" is not selected → skip Step 5.3 entirely. If `claude` is not selected → skip Step 5.2.5 and run no claude reviewer at all.
```

- [ ] **Step 4: Insert the new Step 5.2.5 selection page**

Insert this section immediately BEFORE the `#### Step 5.3 (Q2..Qn): Paginated model selection` heading:

```markdown
#### Step 5.2.5: Claude-model selection

Runs ONLY when Q1 selected `claude` **and** `HAS_CLAUDE_MODELS=1`.

- `claude` NOT selected in Q1 → skip; no claude reviewer runs at all, whatever the catalog holds.
- `claude` selected but `HAS_CLAUDE_MODELS=0` → skip; exactly **one** reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty).

For each chunk of 4 entries from `CLAUDE_MODELS` (config order) — same pagination and the same ★ convention as Step 5.3, because AskUserQuestion has no `preSelected` API:

```
header: "Claude"
question: "На каких Claude-моделях запустить design review? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in CLAUDE_DEFAULT_IDS
                 "★ <model> (recommended)"     if in CLAUDE_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections into `SELECTED_CLAUDE_MODELS`.

**Empty selection is not an error** — it falls back to exactly one reviewer named `claude`, as in the `HAS_CLAUDE_MODELS=0` case. Do not re-ask, do not STOP.

Every selected model gets the SAME composed prompt — model diversity is the point, so never differentiate their prompts.
```

- [ ] **Step 5: Show the expanded set in the Step 5.4 confirmation**

In `#### Step 5.4: Confirm selection`, replace the opening sentence

`After Q1 (and pagination if it ran), show the full selected set — built-in TYPES plus \`SELECTED_IDS\` (one per line) — and confirm (mirrors mesh-review Step 3.5):`

with:

```markdown
After Q1 (and Steps 5.2.5 / 5.3 if they ran), show the full selected set — built-in TYPES plus `SELECTED_IDS` (one per line) — and confirm (mirrors mesh-review Step 3.5). **Expand `claude` into one bullet per entry of `SELECTED_CLAUDE_MODELS`** (`claude:opus`, `claude:fable`), or a single `claude (модель по умолчанию)` bullet in the fallback case, so the user sees how many Claude reviewers they are about to pay for.
```

and in the same block change the "Перевыбрать" description from `restarts Step 5.2 from Q1 with the same DEFAULT_IDS` to `restarts Step 5.2 from Q1 with the same DEFAULT_IDS / CLAUDE_DEFAULT_IDS (Step 5.2.5 re-runs too)`.

**The selection is reused across iterations, so the Claude models must be remembered too** — otherwise iteration 2 silently drops back to a single reviewer. Two more edits:

- last line of Step 5.4: replace `Remember the confirmed set (built-in TYPES + \`SELECTED_IDS\`) for all subsequent iterations in the loop.` with `Remember the confirmed set (built-in TYPES + \`SELECTED_CLAUDE_MODELS\` + \`SELECTED_IDS\`) for all subsequent iterations in the loop.`
- Step 5 preamble (`### Step 5: Select Review Agents (first iteration only)`): replace `remember the resulting agent set (built-ins + model ids)` with `remember the resulting agent set (built-ins + Claude models + ext-claude model ids)`.

- [ ] **Step 6: Dispatch the claude reviewers (Step 6)**

**6a.** In Step 6, right after the **Dispatch model** paragraph, insert:

```markdown
**Exception — claude reviewers with an explicit model.** When Step 5.2.5 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL` — otherwise every claude reviewer would collapse onto one model and the independence would be fake. `DISPATCH_MODEL` still governs the codex / gemini / ext-claude executors and the `review-discussion` agent in Step 8.

**built-in `claude` reviewer(s)** — dispatch the composed Step 4 prompt **directly**. That prompt is already self-contained (task, documents, project + session context, PREVIOUS DECISIONS, review focus, output format), so there is no `Execute this prompt via…` wrapper and no skill to invoke:

```
Task tool:
  subagent_type: "general-purpose"     # built-in agent type — NOT claude-mesh:-namespaced
  model: "<claude model>"              # omit ONLY in the fallback case with an empty DISPATCH_MODEL
  description: "Design review via claude:<model> (iter N)"
  prompt: "[composed prompt with PREVIOUS_DECISIONS]"
```

**Claude reviewers are excluded from the disk-watch / ping loop below.** They create no `runs/<engine>/…` dir and finish on their own. Waiting for a run dir that will never appear — or pinging an agent that has already answered — is a bug, not diligence.
```

**6b.** In the numbered watch-loop list further down the same step, change item 4's closing sentence

`treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings".`

to

`treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings". This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it.`

- [ ] **Step 7: Name the merged sections (Step 7)**

In the merged-file template, add a claude section as the first entry:

```markdown
# Merged Design Review — Iteration N

## claude:opus

[full output from the built-in claude reviewer on opus — one section per selected Claude model;
 a single fallback reviewer is titled just `claude`]

---

## codex-executor
```

- [ ] **Step 8: Verify the edits**

Run:

```bash
grep -c 'claude_models\|SELECTED_CLAUDE_MODELS\|HAS_CLAUDE_MODELS\|claude:<model>\|claude:opus' skills/mesh-design-review/SKILL.md
grep -n 'Step 5.2.5' skills/mesh-design-review/SKILL.md
grep -n 'нет доступных reviewer-типов' skills/mesh-design-review/SKILL.md
grep -n 'general-purpose' skills/mesh-design-review/SKILL.md
```

Expected:
- first prints a count `>= 12`
- second prints at least 3 hits (heading plus the references from Steps 5.2, 5.4)
- third prints **nothing** (the unreachable STOP is gone)
- fourth prints at least one hit (the new claude dispatch block)

Then read the file end-to-end and confirm:
1. Step 5.1 expands `claude` (the bug is fixed in `default` mode).
2. Step 5.2 offers `claude` unconditionally (the bug is fixed in interactive mode).
3. Step 5.2.5 exists and is gated on both conditions.
4. Step 6 dispatches `general-purpose` with the composed prompt directly and no wrapper line.
5. Step 6 states that claude reviewers are outside the watch/ping loop.
6. Step 7 shows the `claude:<model>` section naming.
7. Steps 5 and 5.4 remember `SELECTED_CLAUDE_MODELS` across iterations — iteration 2 must not fall back to one reviewer.

- [ ] **Step 9: Run the loader suite (regression guard) and commit**

```bash
bash skills/shared/tests/test-config-loader.sh | tail -3
git add skills/mesh-design-review/SKILL.md
git commit -m "feat(mesh-design-review): run built-in claude reviewers, one per Claude model

The claude entry in defaults.design_review.builtin validated but was never
expanded — design review has never actually run a Claude reviewer. Adds the
missing branch in both default and interactive mode, and fans it out over
claude.models."
```

---

## Task 8: README and CHANGELOG

**Files:**
- Modify: `README.md` (Dependencies bullet at `:54`)
- Modify: `CHANGELOG.md` (`## [Unreleased]` section at `:5`)

**Interfaces:**
- Consumes: the finished behaviour from Tasks 1–7
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Update the README dependency bullet**

Replace `README.md:54`:

```markdown
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
```

with:

```markdown
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
  - `runtime.dispatch_model` governs the *plumbing*: the codex / gemini / ext-claude wrapper agents, the `review-discussion` agent, and `/do-plan` subagents. To choose the models that actually *review*, list them under `claude.models` and pick a per-preset default in `defaults.<preset>.claude_models`: `/mesh-review` and `/mesh-design-review` then run one independent built-in reviewer per model (e.g. `opus` and `fable` at once), and those reviewers ignore `dispatch_model`. Leave the section out and you get exactly one claude reviewer on `dispatch_model`, as before.
```

- [ ] **Step 2: Add the CHANGELOG entry**

Replace `CHANGELOG.md:5`:

```markdown
## [Unreleased]
```

with:

```markdown
## [Unreleased]

### Added
- Multi-model built-in Claude reviewers. A new optional `claude:` section holds a
  catalog of Claude model aliases (`claude.models: [opus, sonnet, fable]`), and a new
  per-preset key `defaults.<preset>.claude_models` picks the default subset. Both
  `/mesh-review` and `/mesh-design-review` now run **one independent reviewer per
  selected Claude model** — same diff, same prompt, different model — so a session on
  `opus` can be cross-checked by `opus` and `fable` at once and aggregate both. The
  interactive UI gains a Claude-model page (★ marks the preset's picks); `default` mode
  reads the preset. Reviewers are attributed as `claude:<model>` in the dedup table, the
  delegation roster (as `INLINE`, never passed to `verify-delegation.sh`) and the merged
  design-review file. Loader support: `get-flag has_claude_models`, `list-claude-models`,
  and a `claude_models` field in `get-defaults`.
  `runtime.dispatch_model` is unchanged and still governs the codex / gemini / ext-claude
  wrappers, `review-discussion` and `/do-plan`; claude reviewers with an explicit model
  ignore it. Configs without a `claude:` section keep the old behaviour exactly: one
  claude reviewer on `dispatch_model`, or on the session model when that is unset.

### Fixed
- `claude` in `defaults.design_review.builtin` was silently dropped. The loader accepted
  the value, but `/mesh-design-review` expanded only `codex` and `gemini` in `default`
  mode and offered neither a `claude` option in its interactive reviewer-type question —
  so design review had never once run a built-in Claude reviewer. Both paths now expand
  it. The related fail-closed guard is new too: `claude_models` set without `claude` in
  the same preset's `builtin` is now a validation error rather than another silently
  ignored list.
```

- [ ] **Step 3: Verify**

Run:

```bash
grep -n 'claude.models' README.md
sed -n '1,40p' CHANGELOG.md
```

Expected: the README bullet mentions `claude.models` and `defaults.<preset>.claude_models`; the CHANGELOG has both an `### Added` and a `### Fixed` block under `## [Unreleased]`, above `## [0.4.3]`.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document multi-model claude reviewers"
```

---

## Task 9: Manual smoke

**Files:** none modified. This task produces a written result, not a diff.

**Interfaces:**
- Consumes: everything from Tasks 1–8
- Produces: a go/no-go on the feature. Nothing consumes it.

The orchestrators are prompts — the loader suite cannot prove they dispatch correctly. Only a real run can.

**Prerequisite:** the user's live `config.yaml` (`~/.claude/plugins/data/claude-mesh-zinin/config.yaml`) has no `claude:` section yet. **Do not edit it — agents never modify `config.yaml`.** Ask the user to add:

```yaml
claude:
  models: [opus, fable]
```

and, if they want `default` mode covered, `claude_models: [opus, fable]` to `defaults.code_review` and `claude_models: [opus]` to `defaults.design_review`.

- [ ] **Step 1: Validate the live config**

Run: `bash skills/shared/config-loader.sh validate && bash skills/shared/config-loader.sh list-claude-models`
Expected: exit 0, then `opus` and `fable` on separate lines.

- [ ] **Step 2: Smoke `/mesh-review` interactively**

Run `/claude-mesh:mesh-review` and select `claude` plus at least one other reviewer type.
Expected:
- the Claude-model page appears with `opus` and `fable`, ★ on the preset entries;
- the Step 2.5 confirmation lists `claude:opus` and `claude:fable` as separate bullets;
- two `general-purpose` Tasks are dispatched, carrying `model: "opus"` and `model: "fable"`;
- the Step 6.0 table has an `INLINE` row for each, and `verify-delegation.sh` is not called for them;
- findings are attributed `claude:opus` / `claude:fable`.

- [ ] **Step 3: Smoke the fallback path**

Ask the user to temporarily comment out the `claude:` section, then run `/claude-mesh:mesh-review` again and select `claude`.
Expected: no Claude-model page; exactly one reviewer named `claude` on `dispatch_model` (`opus` in the user's config). This is the back-compat guarantee — if it regresses, every existing config changes behaviour on upgrade.

- [ ] **Step 4: Smoke `/mesh-design-review default`**

Run `/claude-mesh:mesh-design-review default` on any design doc.
Expected: a claude reviewer actually runs (it never did before), and the merged file has a `## claude:opus` section alongside the codex/ext-claude ones.

- [ ] **Step 5: Report**

Write the outcome of Steps 1–4 into the task report: what ran, what each reviewer's `model:` was, and any deviation. If anything failed, fix it in the owning task's file and re-run — do not paper over it in the report.

- [ ] **Step 6: Commit (only if Step 5 produced fixes)**

```bash
git add -A
git commit -m "fix: address issues found in the multi-model claude reviewer smoke"
```

If nothing needed fixing, skip the commit — this task has no deliverable of its own.
