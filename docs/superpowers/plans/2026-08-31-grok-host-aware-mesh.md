# Host-aware mesh reviewers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/claude-mesh:mesh-review` and `/claude-mesh:mesh-design-review` dispatch native `spawn_subagent` reviewers on Grok Build (slugs from `grok models`) while keeping Claude Code 0.12.0 behaviour for a preset that does not mention `native`.

**Architecture:** One host-aware pair of orchestrators. Host = `spawn_subagent` is present (Grok), else Claude Code. The loader stays host-agnostic. Native reviews are `explore` children with `model:`. On Grok, `claude` is `claude -p` via `ext-claude-exec HOST_CLAUDE=1`. Wrappers on Grok `Read` SKILL.md and wait on their CLI; Claude Code keeps Skill tool + idle/ping.

**Tech Stack:** bash 4.2+, `config-loader.sh` / jq / yq, `verify-delegation.sh`, `watch-runs.sh`, plugin agent markdown, Grok `spawn_subagent` / `ask_user_question` / `get_command_or_subagent_output`.

**Spec:** `docs/superpowers/specs/2026-08-31-grok-host-aware-mesh-design.md`

## Global Constraints

- Same `config.yaml` for both hosts. Loader does not branch on host.
- `native` in `defaults.*.builtin` is valid and is **not** a YAML gate (no `native:` section).
- `native` does **not** satisfy the `claude_models` pairing: a file that wants opus/fable on Claude Code still lists `claude` in `builtin`.
- `native_models` charset is `GROK_IDENT_RE`: `^[A-Za-z0-9][A-Za-z0-9._-]*$`. Not checked against `claude.models` or `grok.models`.
- Host detection: `spawn_subagent` present → Grok; absent → Claude Code. Do not require `Task` to be missing.
- Data dir stays `~/.claude/plugins/data/claude-mesh-*`.
- No grok-plugin package. No `runs/native/`. No team mode on Grok (STOP).
- `claude.models` catalog error strings stay byte-identical (`golden-claude-catalog-messages.txt`).
- AskUserQuestion pagination stays 4 options per page.
- Native reviewers on Grok use `subagent_type: explore`.
- Double-counting `native:grok-4.6` vs `grok:grok-4.6` is accepted.
- Version bump to 0.13.0 is a **later release commit**, not a task here. CHANGELOG goes under `## [Unreleased]`.

---

## File map

| File | Responsibility |
|---|---|
| `skills/shared/config-loader.sh` | `native` in builtin enum; `native_models` pairing/charset; `get-defaults` emits `.native_models` |
| `skills/shared/tests/test-config-loader.sh` + fixtures | TDD for the loader |
| `skills/shared/list-host-models.sh` | Parse `grok models` → one slug per line |
| `skills/shared/tests/test-list-host-models.sh` | Parser fixtures |
| `skills/shared/verify-delegation.sh` | Engine `claude`, path `runs/claude/<alias>/`, same stream branch as grok/ext-claude |
| `skills/shared/watch-runs.sh` | No logic change; roster `claude/opus` already matches `$DATA_DIR/runs/$entry` |
| `skills/shared/tests/test-verify-delegation.sh` | Engine `claude` verdicts + usage errors |
| `skills/shared/tests/test-watch-runs.sh` | Roster `claude/opus` DONE |
| `skills/ext-claude-exec/host-claude-env.sh` | Unset provider export vars for `HOST_CLAUDE=1` |
| `skills/ext-claude-exec/SKILL.md` | `HOST_CLAUDE=1` mode: skip `export`, run dir `runs/claude/<alias>/`, `-m` when set |
| `skills/claude-code-review/SKILL.md` | Thin review wrapper → ext-claude-exec `HOST_CLAUDE=1` |
| `agents/claude-code-reviewer.md`, `agents/claude-executor.md` | New wrappers |
| `agents/*.md` (8 existing wrappers) | Dual Skill-tool / Read SKILL.md; Grok wait-for-CLI |
| `skills/*-code-review/SKILL.md` | Dual invoke of `*-exec` (no Skill tool) |
| `skills/shared/resolve-plugin-root.sh` | Shared plugin-root fallback |
| `commands/mesh-review.md` | Host-aware UI + dispatch + wait |
| `skills/mesh-design-review/SKILL.md` | Same, design-review step numbers |
| `skills/shared/tests/test-command-sync.sh` | Absolute facts for native / Grok CLI `claude` / SELECTED_NATIVE_MODELS |
| `skills/shared/preflight-env.sh` | Rows `native-models` and `claude-cli` |
| `skills/shared/tests/test-preflight-env.sh` | Those rows do not take down the probe |
| `config.example.yaml`, `README.md`, `CHANGELOG.md` | Schema, Grok-only break, Unreleased |

---

### Task 1: Loader — `native` builtin and `native_models`

**Files:**
- Modify: `skills/shared/config-loader.sh` (`validate_defaults` builtin `case` around line 768; after the `claude_models` loop ~886; `cmd_get_defaults` jq at line 1498)
- Modify: `skills/shared/tests/test-config-loader.sh` (append tests after Test 50 / grok_models pairing)
- Create: `skills/shared/tests/fixtures/invalid-defaults-native-models-no-native.yaml`
- Create: `skills/shared/tests/fixtures/invalid-defaults-native-models-charset.yaml`

**Interfaces:**
- Consumes: existing `GROK_IDENT_RE`, `validate_defaults`, `cmd_get_defaults`
- Produces: `builtin` accepts `native`; `get-defaults <category>` JSON always has `native_models` (array, never null); pairing error if `native_models` set without `native` in that preset's `builtin`; empty/absent `native_models` with `native` in builtin is valid

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-config-loader.sh` (use the same `BASE` / `CLAUDE_PLUGIN_DATA` / `assert_exit` / `assert_stderr_contains` / `assert_eq_str` helpers already in the file):

```bash
echo "=== Test: native is a valid builtin ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "accepts builtin native with no native_models" "0" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native_models without native in builtin is invalid ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-native-models-no-native.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "rejects native_models without native" "1" "$RC"
assert_stderr_contains "names the missing builtin entry" 'is missing from defaults.code_review.builtin' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native_models charset rejects a slash ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-native-models-charset.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "rejects slashed native_models entry" "1" "$RC"
assert_stderr_contains "names the charset" '[A-Za-z0-9._-]' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native_models charset rejects @ ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n    native_models: ["opus@bedrock"]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "rejects @ in native_models" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native does not satisfy claude_models pairing ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'claude:\n  models: [opus]\n' >> "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n    claude_models: [opus]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "native does not stand in for claude in claude_models pairing" "1" "$RC"
assert_stderr_contains "still wants claude in builtin" '"claude" is missing from defaults.code_review.builtin' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test: get-defaults emits native_models ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n    native_models: [grok-4.6, glm-5-3]\n' >> "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.native_models | join(",")')
assert_eq_str "native_models list" "grok-4.6,glm-5-3" "$GOT"
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [claude]\n' >> "$TDIR/config.yaml"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r 'has("native_models")')
assert_eq_str "native_models key always present" "true" "$GOT"
GOT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review | jq -r '.native_models | type')
assert_eq_str "absent native_models becomes []" "array" "$GOT"
rm -rf "$TDIR"

echo "=== Test: 0.12.0 preset without native still validates ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'claude:\n  models: [opus]\ncodex:\n  model: gpt-5.5\n' >> "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [claude, codex]\n    claude_models: [opus]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "old preset without native stays valid" "0" "$RC"
rm -rf "$TDIR" "$ERR"
```

`$BASE` is already defined in Test 50 of this file (`providers` + `models` zai/glm). If a later edit moved it, redefine it the same way at the start of this block.

Fixture `invalid-defaults-native-models-no-native.yaml`:

```yaml
providers:
  - id: zai
    label: "Z.AI"
    base_url: https://api.z.ai/api/anthropic
    token: "tkn"
models:
  - id: zai/glm
    label: "GLM"
    model: glm-5.1
defaults:
  code_review:
    builtin: [claude]
    native_models: [grok-4.6]
```

Fixture `invalid-defaults-native-models-charset.yaml`:

```yaml
providers:
  - id: zai
    label: "Z.AI"
    base_url: https://api.z.ai/api/anthropic
    token: "tkn"
models:
  - id: zai/glm
    label: "GLM"
    model: glm-5.1
defaults:
  code_review:
    builtin: [native]
    native_models: ["zai/glm"]
```

- [ ] **Step 2: Run the new tests and confirm they fail**

Run: `bash skills/shared/tests/test-config-loader.sh`

Expected: FAIL on `accepts builtin native` (unknown value `native`) and on `get-defaults emits native_models` (`has("native_models")` is false). The charset/pairing tests may already fail for the same unknown-builtin reason.

- [ ] **Step 3: Implement the loader**

In `validate_defaults`, builtin `case "$v"` (currently dies with `valid: claude, codex, gemini, grok`):

```bash
                claude) ;;
                native) ;;
                codex)
                    [ "$has_codex" = "1" ] || die "defaults.$preset.builtin lists \"codex\" but no codex: section"
                    ;;
```

Change the unknown-value die to:

```bash
                *) die "defaults.$preset.builtin: unknown value \"$v\" (valid: claude, native, codex, gemini, grok)" ;;
```

After the `claude_models` loop (before the grok_models block), add a `native_models` block that:

1. Type-gates list/null.
2. If count > 0, requires `"native"` in that preset's `builtin` with message:
   `defaults.$preset.native_models is set but "native" is missing from defaults.$preset.builtin (add "native" to builtin, or drop native_models)`
3. Does **not** require `native_models` when `native` is in builtin.
4. Per entry: must be string, non-empty, match `$GROK_IDENT_RE`, unique. No catalog membership test.
5. Error for charset:
   `defaults.$preset.native_models[$i]: must start with a letter/digit and match [A-Za-z0-9._-] (a host model slug), got "$v"`

In `cmd_get_defaults`, add `native_models` to the emitted object, always an array:

```bash
jq -c --argjson gd "$gd" "{builtin: ((.defaults.${category}.builtin // []) | if \$gd then map(select(. != \"grok\")) else . end), claude_models: (.defaults.${category}.claude_models // []), grok_models: (if \$gd then [] else (.defaults.${category}.grok_models // []) end), native_models: (.defaults.${category}.native_models // []), models: (.defaults.${category}.models // []), run_mode: (.defaults.${category}.run_mode // null), grok_degraded: \$gd}" "$CONFIG_JSON"
```

Do not add `has_native`. Do not strip `native` when grok degrades.

- [ ] **Step 4: Run the full loader suite**

Run: `bash skills/shared/tests/test-config-loader.sh`

Expected: Summary `0 failed`. Also run the golden claude-catalog messages test inside that suite (it already exists); those strings must not move.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/config-loader.sh \
        skills/shared/tests/test-config-loader.sh \
        skills/shared/tests/fixtures/invalid-defaults-native-models-no-native.yaml \
        skills/shared/tests/fixtures/invalid-defaults-native-models-charset.yaml
git commit -m "$(cat <<'EOF'
feat(loader): accept native builtin and native_models

Host-agnostic schema for Grok native reviewers. native_models is charset-only
and pairs one way: the key requires native in builtin; native without the
key stays valid. native does not satisfy the claude_models pairing.
EOF
)"
```

---

### Task 2: `list-host-models.sh` — parse `grok models`

**Files:**
- Create: `skills/shared/list-host-models.sh`
- Create: `skills/shared/tests/test-list-host-models.sh`
- Create: `skills/shared/tests/fixtures/grok-models-2026-08-31.txt`

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `list-host-models.sh` — reads stdin (or `--from-file PATH`); prints one slug per line, order preserved; exit 0 on empty input; exit 64 on usage error. Does not invoke `grok` itself.

- [ ] **Step 1: Write the fixture and the failing test**

Fixture `skills/shared/tests/fixtures/grok-models-2026-08-31.txt` — exact `grok models` output measured 2026-08-31:

```
You are logged in with grok.com.

Default model: grok-4.6

Available models:
  * grok-4.6 (default)
  - grok-4.5
  - dks-ultra
  - deepseek-v4-flash
  - dks-vision
  - glm-5-3-flash
  - minimax-m3
  - lanit-auto
  - kimi-k3
  - minimax-m3-ollama
  - deepseek-v4-flash-ollama
  - deepseek-v4-pro-ollama
  - glm-5-3
  - glm-5-3-flash-zai
  - deepseek-v4-flash-api
  - deepseek-v4-pro
  - deepseek-v4-flash-vision-exp
  - codex-sol
  - codex-terra
  - codex-luna
```

Test `skills/shared/tests/test-list-host-models.sh`:

```bash
#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../list-host-models.sh"
FIXTURE="$TESTS_DIR/fixtures/grok-models-2026-08-31.txt"
FAIL=0
PASS=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"; fi
}
# script missing → this test fails until Task 2 step 3
GOT=$("$SCRIPT" --from-file "$FIXTURE" | tr '\n' ' ')
assert_eq "first slug is grok-4.6" "grok-4.6" "$("$SCRIPT" --from-file "$FIXTURE" | head -1)"
assert_eq "count is 20" "20" "$("$SCRIPT" --from-file "$FIXTURE" | wc -l | tr -d ' ')"
assert_eq "does not emit Default model line as a slug twice extra" "1" \
    "$("$SCRIPT" --from-file "$FIXTURE" | grep -c '^grok-4.6$')"
assert_eq "last slug is codex-luna" "codex-luna" "$("$SCRIPT" --from-file "$FIXTURE" | tail -1)"
printf '' | "$SCRIPT" >/dev/null
assert_eq "empty stdin is rc 0" "0" "$?"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `bash skills/shared/tests/test-list-host-models.sh`

Expected: FAIL (`list-host-models.sh: No such file or directory`).

- [ ] **Step 3: Implement the parser**

`skills/shared/list-host-models.sh`:

```bash
#!/usr/bin/env bash
# Parse `grok models` human output into one catalog id per line.
# Does not run grok. Callers pipe `grok models` or pass --from-file.
set -u
FILE=""
case "${1:-}" in
    --from-file) FILE="${2:-}"; shift 2 || { echo "usage: list-host-models.sh [--from-file PATH]" >&2; exit 64; } ;;
    -*) echo "usage: list-host-models.sh [--from-file PATH]" >&2; exit 64 ;;
esac
# Lines like `  * grok-4.6 (default)` and `  - kimi-k3`. Do not match
# `Default model: grok-4.6` — that line has no leading * or -.
if [ -n "$FILE" ]; then
    exec <"$FILE" || exit 64
fi
sed -n 's/^[[:space:]]*[-*][[:space:]]\{1,\}\([A-Za-z0-9][A-Za-z0-9._-]*\).*/\1/p'
```

`chmod +x` the script.

- [ ] **Step 4: Run the test and confirm it passes**

Run: `bash skills/shared/tests/test-list-host-models.sh`

Expected: 20 lines, first `grok-4.6`, last `codex-luna`, `grok-4.6` appears once, empty stdin rc 0.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/list-host-models.sh \
        skills/shared/tests/test-list-host-models.sh \
        skills/shared/tests/fixtures/grok-models-2026-08-31.txt
git commit -m "$(cat <<'EOF'
feat: parse grok models output into host slugs

Shared helper for the Grok orchestrator and preflight. Does not invoke grok;
callers pipe or pass --from-file. Pinned against the 2026-08-31 listing.
EOF
)"
```

---

### Task 3: Engine `claude` on disk (`verify-delegation` + `watch-runs`)

**Files:**
- Modify: `skills/shared/verify-delegation.sh` (usage line 14; `case "$ENGINE"` at line 127; `ext-claude|grok)` at line 399; `DENIAL_REMEDY` at 579)
- Modify: `skills/shared/tests/test-verify-delegation.sh` (append after the grok usage-error tests)
- Modify: `skills/shared/tests/test-watch-runs.sh` (clone Test 40)

**Interfaces:**
- Consumes: grok engine path pattern (`runs/grok/$MODEL`, charset `GROK_IDENT_RE`)
- Produces: `verify-delegation.sh claude <alias> <epoch> <data-dir>` — `BASE=$DATA_DIR/runs/claude/$MODEL`; empty/`-`/slash/leading-dot → exit 1, no verdict; classification on the `ext-claude|grok` stream branch; DEGRADED remedy for `claude` states HOST_CLAUDE already passes `--permission-mode bypassPermissions`. Watcher roster `claude/opus` resolves `runs/claude/opus/<timestamp>-*/`.

- [ ] **Step 1: Write the failing tests**

Append to `test-verify-delegation.sh` (reuse `run`, `run_full`, `mk_run`, `mk_output`, `assert_eq`, `assert_match`, `assert_no_match` already in the file):

```bash
echo "=== Test: claude FLIP (no run dir) ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/runs/claude/opus"
run claude opus 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

echo "=== Test: claude REAL (num_turns 12) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/claude/opus" 2026-08-31-11-00-00-1000-review)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12}' > "$rd/raw.jsonl"
run claude opus 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

echo "=== Test: claude requires a model argument ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/claude"
run claude - 1 "$TDIR"
assert_eq "exit 1 (usage error, no verdict)" "1" "$RC"
assert_eq "no verdict printed" "" "$VERDICT"
rm -rf "$TDIR"

echo "=== Test: claude rejects a slashed model ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/claude"
run claude zai/glm 1 "$TDIR"
assert_eq "slashed model: exit 1" "1" "$RC"
assert_eq "slashed model: no verdict" "" "$VERDICT"
run claude opus 1 "$TDIR"
assert_eq "alias still reaches a verdict" "3" "$RC"
assert_eq "…FLIP" "FLIP" "$VERDICT"
rm -rf "$TDIR"

echo "=== Test: claude DEGRADED remedy is not ext-claude's missing-flag line ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/claude/opus" 2026-08-31-11-00-00-1000-denied)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"permission_denials":[{"tool_name":"Read"}]}' > "$rd/raw.jsonl"
run_full claude opus 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "exit 5" "5" "$RC"
assert_no_match "does not prescribe the ext-claude missing-flag remedy" "the ext-claude run needs" "$REASON"
assert_match "names HOST_CLAUDE already passes the flag" "HOST_CLAUDE" "$REASON"
rm -rf "$TDIR"
```

In `test-watch-runs.sh`, clone Test 40 with `claude/opus` instead of `grok/grok-4.6` (same `mk_run` / `assert_match DONE`).

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `bash skills/shared/tests/test-verify-delegation.sh`

Expected: FAIL `unknown engine 'claude'` (exit 1, empty verdict) on the FLIP test.

- [ ] **Step 3: Implement**

`verify-delegation.sh` usage line: `engine      ext-claude | codex | gemini | grok | claude`.

In the engine `case`, after the `grok)` arm, add a `claude)` arm that is a copy of the grok charset/mandatory-model checks with the strings `engine grok` → `engine claude`, example `grok-4.6` → `opus`, and:

```bash
        BASE="$DATA_DIR/runs/claude/$MODEL" ;;
```

Change `ext-claude|grok)` to `ext-claude|grok|claude)`.

In `DENIAL_REMEDY`:

```bash
                grok)       DENIAL_REMEDY="grok-exec already passes --permission-mode bypassPermissions, so this is not the missing-flag case: the CLI refused for a reason of its own (a sandbox profile, or a deny rule in ~/.grok). Keep the findings; do NOT re-dispatch, and check the CLI's own permission configuration" ;;
                claude)     DENIAL_REMEDY="HOST_CLAUDE already passes --permission-mode bypassPermissions, so this is not the missing-flag case: the CLI refused for a reason of its own (a sandbox profile, or a deny rule in the claude CLI config). Keep the findings; do NOT re-dispatch" ;;
                ext-claude) DENIAL_REMEDY="Keep the findings; do NOT re-dispatch, an identical invocation is refused identically. The remedy is the user's, not an agent's: the ext-claude run needs --permission-mode bypassPermissions, and an installed plugin only picks that up through a release" ;;
```

`watch-runs.sh` needs no code change (`resolve_run_dir` uses `$DATA_DIR/runs/$entry`). The new test is the contract.

- [ ] **Step 4: Run both suites**

Run: `bash skills/shared/tests/test-verify-delegation.sh && bash skills/shared/tests/test-watch-runs.sh`

Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/verify-delegation.sh \
        skills/shared/tests/test-verify-delegation.sh \
        skills/shared/tests/test-watch-runs.sh
git commit -m "$(cat <<'EOF'
feat: treat claude as a depth-1 wrapper engine on disk

verify-delegation and watch-runs now resolve runs/claude/<alias>/, with the
same stream classification as grok/ext-claude and a HOST_CLAUDE DEGRADED
remedy. A slashed model is a usage error, not FLIP.
EOF
)"
```

---

### Task 4: `HOST_CLAUDE=1` in `ext-claude-exec`

**Files:**
- Create: `skills/ext-claude-exec/host-claude-env.sh`
- Create: `skills/ext-claude-exec/tests/test-host-claude-env.sh` (or `skills/shared/tests/test-host-claude-env.sh` if you prefer one tests/ tree — put it at `skills/shared/tests/test-host-claude-env.sh` and source the helper by relative path)
- Modify: `skills/ext-claude-exec/SKILL.md` (Input, Pre-flight, Step 1 `WORK_DIR`, Step 2 skip `export`)

**Interfaces:**
- Consumes: `cmd_export` variable names from `config-loader.sh` 1251–1266 and 1274–1277
- Produces: `host-claude-env.sh` unsets those provider vars. SKILL.md: when `HOST_CLAUDE=1`, do not call `config-loader.sh export`; source `host-claude-env.sh`; `WORK_DIR=$PLUGIN_DATA/runs/claude/$MODEL/${TIMESTAMP}-${TASK_NAME}`; `claude -p` gains `-m "$MODEL"` when MODEL is non-empty; still `--permission-mode bypassPermissions --output-format stream-json`. Timeouts from `get-runtime` JSON, not from export.

- [ ] **Step 1: Write the failing env-helper test**

`skills/shared/tests/test-host-claude-env.sh`:

```bash
#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$TESTS_DIR/../../ext-claude-exec/host-claude-env.sh"
FAIL=0
PASS=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then PASS=$((PASS+1)); echo "  PASS: $desc"
    else FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"; fi
}
# Simulate a leftover parent-shell leak from a previous ext-claude export.
export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
export ANTHROPIC_AUTH_TOKEN="tkn-zai"
export ANTHROPIC_API_KEY="should-go"
export ANTHROPIC_MODEL="glm-5.1"
export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.1"
export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.1"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5.1"
export CLAUDE_CODE_SUBAGENT_MODEL="glm-5.1"
export CLAUDE_CODE_USE_BEDROCK="1"
export CLAUDE_CODE_USE_VERTEX="1"
export CLAUDE_CODE_ATTRIBUTION_HEADER="1"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="200000"
# shellcheck source=/dev/null
. "$HELPER"
assert_eq "BASE_URL unset" "" "${ANTHROPIC_BASE_URL:-}"
assert_eq "AUTH_TOKEN unset" "" "${ANTHROPIC_AUTH_TOKEN:-}"
assert_eq "API_KEY unset" "" "${ANTHROPIC_API_KEY:-}"
assert_eq "MODEL unset" "" "${ANTHROPIC_MODEL:-}"
assert_eq "OPUS unset" "" "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
assert_eq "SONNET unset" "" "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
assert_eq "HAIKU unset" "" "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
assert_eq "SUBAGENT unset" "" "${CLAUDE_CODE_SUBAGENT_MODEL:-}"
assert_eq "BEDROCK unset" "" "${CLAUDE_CODE_USE_BEDROCK:-}"
assert_eq "VERTEX unset" "" "${CLAUDE_CODE_USE_VERTEX:-}"
assert_eq "ATTRIBUTION unset" "" "${CLAUDE_CODE_ATTRIBUTION_HEADER:-}"
assert_eq "COMPACT unset" "" "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
```

- [ ] **Step 2: Run it — expect fail** (helper missing).

- [ ] **Step 3: Implement the helper and the SKILL.md branches**

`host-claude-env.sh`:

```bash
# Unset every variable config-loader.sh cmd_export would have set for a provider
# model, so a leftover parent-shell env cannot send HOST_CLAUDE opus to z.ai.
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_MODEL \
      ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
      ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
      CLAUDE_CODE_ATTRIBUTION_HEADER CLAUDE_CODE_AUTO_COMPACT_WINDOW
```

SKILL.md Input: add optional `HOST_CLAUDE` (`1` = official `claude login`, MODEL is a `claude.models` alias with no slash).

Pre-flight: if `HOST_CLAUDE=1`, skip `export` / token-precheck / ollama-precheck. `command -v claude` stays. Source `host-claude-env.sh`. Load timeouts via:

```bash
RUNTIME=$("$LOADER" get-runtime) || exit 1
SINGLE_RUN=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.single_run_sec')
STALL=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.stall_sec')
GLOBAL=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.global_sec')
MAX_RETRIES=$(printf '%s' "$RUNTIME" | jq -r '.timeouts.max_retries')
```

Step 1 WORK_DIR: if HOST_CLAUDE=1, `runs/claude/$MODEL/...` and do not split `PROVIDER/SHORT`. MODEL may be empty (CLI default): then directory `runs/claude/default/...` is forbidden — require MODEL at the skill layer when HOST_CLAUDE=1 unless the caller omitted it; if omitted, use `runs/claude/_default/${TIMESTAMP}-${TASK_NAME}` so the watcher roster for a fallback reviewer is `claude/_default`. Spec: empty catalog → one run without `-m`. Orchestrators that selected a catalog entry always pass MODEL. Document both paths.

Step 2: skip `export`/`source ENV_FILE` when HOST_CLAUDE=1; source `host-claude-env.sh` instead. Invocation:

```bash
# HOST_CLAUDE=1: do not pass -m when MODEL is empty.
if [ -n "$MODEL" ]; then
  timeout "$SINGLE_RUN" stdbuf -oL -eL claude -p -m "$MODEL" --permission-mode bypassPermissions --output-format stream-json
else
  timeout "$SINGLE_RUN" stdbuf -oL -eL claude -p --permission-mode bypassPermissions --output-format stream-json
fi
```

Keep the same watchdog wrapper as the existing supervised block. `unset CLAUDECODE` stays.

- [ ] **Step 4: Run the helper test**

Run: `bash skills/shared/tests/test-host-claude-env.sh`

Expected: 0 failed.

- [ ] **Step 5: Commit**

```bash
git add skills/ext-claude-exec/host-claude-env.sh \
        skills/ext-claude-exec/SKILL.md \
        skills/shared/tests/test-host-claude-env.sh
git commit -m "$(cat <<'EOF'
feat(ext-claude-exec): HOST_CLAUDE mode uses claude login

Skip provider export, unset leaked ANTHROPIC_* vars, write
runs/claude/<alias>/, pass -m when MODEL is set. Same watchdog and
bypassPermissions as the provider path.
EOF
)"
```

---

### Task 5: `claude-code-review` skill and two agents

**Files:**
- Create: `skills/claude-code-review/SKILL.md`
- Create: `agents/claude-code-reviewer.md`
- Create: `agents/claude-executor.md`

**Interfaces:**
- Consumes: Task 4 `HOST_CLAUDE=1`; Task 3 disk paths; grok-code-review shape for MODEL first line / BASE_BRANCH / render-template / SUPERVISED_MODE=shell
- Produces: `claude-mesh:claude-code-reviewer` and `claude-mesh:claude-executor`. Reviewer invokes `claude-code-review`; that skill renders `shared/code-review-prompt.md` and invokes `ext-claude-exec` with `HOST_CLAUDE=1`. Executor invokes `ext-claude-exec` with `HOST_CLAUDE=1` directly. No tooling-constraint paragraph (spec §4). MODEL on the first line; BASE_BRANCH on the next.

- [ ] **Step 1: Write a presence test** (append to `test-command-sync.sh` or a tiny `test-claude-cli-agents.sh`):

```bash
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
assert_eq "reviewer agent exists" "1" "$([ -f "$REPO/agents/claude-code-reviewer.md" ] && echo 1 || echo 0)"
assert_eq "executor agent exists" "1" "$([ -f "$REPO/agents/claude-executor.md" ] && echo 1 || echo 0)"
assert_eq "review skill exists" "1" "$([ -f "$REPO/skills/claude-code-review/SKILL.md" ] && echo 1 || echo 0)"
assert_ge "reviewer requires MODEL on first line" "1" \
    "$(grep -c 'MODEL is REQUIRED on the first line' "$REPO/agents/claude-code-reviewer.md")"
assert_ge "reviewer names HOST_CLAUDE" "1" \
    "$(grep -c 'HOST_CLAUDE=1' "$REPO/skills/claude-code-review/SKILL.md")"
assert_eq "review skill has no tooling-constraint section" "0" \
    "$(grep -c '## Tooling constraint' "$REPO/skills/claude-code-review/SKILL.md")"
```

Put this in `skills/shared/tests/test-command-sync.sh` after Test 6, or in `skills/shared/tests/test-claude-cli-agents.sh` and run it from the same place the other suites run (document the command in Step 4). Prefer a new `test-claude-cli-agents.sh` so Test 6 stays grok-specific.

- [ ] **Step 2: Run it — expect fail** (files missing).

- [ ] **Step 3: Write the three markdown files**

`agents/claude-code-reviewer.md` — copy `agents/grok-code-reviewer.md` and replace: name `claude-code-reviewer`; skill `claude-mesh:claude-code-review`; MODEL example `MODEL=opus`; "NOT the `<provider>/<short>` pair". Include the dual Skill-tool / Read SKILL.md and Grok wait paragraphs from Task 6 (write them here already so Task 6 does not have to revisit these two files).

`agents/claude-executor.md` — copy `agents/grok-executor.md` the same way; first action `ext-claude-exec` with `HOST_CLAUDE=1` in the forwarded params; MODEL first line.

`skills/claude-code-review/SKILL.md` — copy `skills/grok-code-review/SKILL.md` structure (preflight `command -v claude`, MODEL vs `list-claude-models` when the catalog is non-empty, git range, `render-template.py` on `code-review-prompt.md`) but:

- Do **not** append the tooling-constraint heredoc.
- Step 4 invokes `ext-claude-exec` with `HOST_CLAUDE=1`, `MODEL=<alias>`, `SUPERVISED_MODE=shell`, `PROMPT=<rendered>`.
- Preflight: `get-flag has_claude_models` is optional; if the catalog is empty, do not grep-Fxq MODEL (CLI default). If the catalog is non-empty, `list-claude-models | grep -Fxq -- "$MODEL"`.
- Run dir documented as `runs/claude/<alias>/`.

- [ ] **Step 4: Run `bash skills/shared/tests/test-claude-cli-agents.sh`** — 0 failed.

- [ ] **Step 5: Commit**

```bash
git add agents/claude-code-reviewer.md agents/claude-executor.md \
        skills/claude-code-review/SKILL.md \
        skills/shared/tests/test-claude-cli-agents.sh
git commit -m "$(cat <<'EOF'
feat: Claude Code CLI reviewer and executor agents

Thin wrappers around ext-claude-exec HOST_CLAUDE=1. Catalog aliases
(opus, fable), no tooling constraint, run dirs under runs/claude/.
EOF
)"
```

---

### Task 6: Wrapper agents — Skill tool dual-path and Grok wait

**Files:**
- Modify: `agents/codex-code-reviewer.md`, `agents/codex-executor.md`, `agents/gemini-code-reviewer.md`, `agents/gemini-executor.md`, `agents/grok-code-reviewer.md`, `agents/grok-executor.md`, `agents/ext-claude-code-reviewer.md`, `agents/ext-claude-executor.md`
- Modify: `skills/codex-code-review/SKILL.md`, `skills/gemini-code-review/SKILL.md`, `skills/grok-code-review/SKILL.md`, `skills/ext-claude-code-review/SKILL.md` (the "Use the Skill tool to invoke `*-exec`" steps)

Do **not** modify `agents/review-discussion.md`.

**Interfaces:**
- Consumes: Task 5 paragraph text (same dual-path)
- Produces: zero files containing `Do NOT read SKILL.md`; every wrapper agent contains `If this host has no Skill tool` and `Grok Build: do not end the turn while the CLI is alive`

- [ ] **Step 1: Write the failing assertions** — append to `skills/shared/tests/test-claude-cli-agents.sh` from Task 5:

```bash
AGENTS="$REPO/agents"
# 8 pre-existing wrappers; claude-* already have the paragraph from Task 5.
WRAPPERS="codex-code-reviewer.md codex-executor.md gemini-code-reviewer.md gemini-executor.md grok-code-reviewer.md grok-executor.md ext-claude-code-reviewer.md ext-claude-executor.md claude-code-reviewer.md claude-executor.md"
forbid=0
for f in $WRAPPERS; do
    grep -q 'Do NOT read SKILL.md' "$AGENTS/$f" && forbid=$((forbid+1))
done
assert_eq "no wrapper still forbids reading SKILL.md" "0" "$forbid"
missing=0
for f in $WRAPPERS; do
    grep -q 'If this host has no Skill tool' "$AGENTS/$f" || missing=$((missing+1))
    grep -q 'do not end the turn while the CLI is alive' "$AGENTS/$f" || missing=$((missing+1))
done
assert_eq "every wrapper has dual invoke + Grok wait" "0" "$missing"
```

- [ ] **Step 2: Run — expect fail** (`forbid` is 8).

- [ ] **Step 3: Replace the Skill-tool / PROHIBITIONS blocks in each of the eight existing agents with this text** (substitute the skill name). Repeat the full paragraph in every file — do not write "same as Task 5".

```markdown
## Invoke the skill

**If this host has a Skill tool** (Claude Code): your FIRST ACTION is to invoke the skill with the Skill tool, then follow it.

```
Skill tool -> skill: "claude-mesh:<SKILL>"
```

**If this host has no Skill tool** (Grok Build): `Read` the plugin's `skills/<skill-dir>/SKILL.md` and follow every step. Plugin root: `$CLAUDE_PLUGIN_ROOT` or `$GROK_PLUGIN_ROOT` if set to an existing directory; otherwise
`find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/<skill-dir>/SKILL.md' 2>/dev/null | sort -V | tail -1`.
Following the skill **is** CLI delegation. It is not a review you perform yourself.

## After the engine starts

**Claude Code:** name the run dir in an interim status, end the turn, wait to be pinged (SendMessage).

**Grok Build:** do not end the turn while the CLI is alive. The exec skill launches the engine as a background bash command. Wait on that command id with `get_command_or_subagent_output` (loop; each call's ceiling is 600s) until it exits, then read `output.txt` and return the findings. This host has no SendMessage; an idle wrapper cannot be pinged.

## PROHIBITIONS

- Do NOT write findings without running the exec skill
- Do NOT fall back to reviewing the diff on your own model
- Do NOT run the engine CLI directly — the skill chain handles execution
```

`<SKILL>` / `<skill-dir>` per file:

| Agent | Skill id | skill-dir |
|---|---|---|
| codex-code-reviewer | claude-mesh:codex-code-review | codex-code-review |
| codex-executor | claude-mesh:codex-exec | codex-exec |
| gemini-code-reviewer | claude-mesh:gemini-code-review | gemini-code-review |
| gemini-executor | claude-mesh:gemini-exec | gemini-exec |
| grok-code-reviewer | claude-mesh:grok-code-review | grok-code-review |
| grok-executor | claude-mesh:grok-exec | grok-exec |
| ext-claude-code-reviewer | claude-mesh:ext-claude-code-review | ext-claude-code-review |
| ext-claude-executor | claude-mesh:ext-claude-exec | ext-claude-exec |

In each `*-code-review/SKILL.md` Step that currently says "Use the Skill tool to invoke `*-exec`", add the same dual-path: Skill tool if present, else `Read` the exec SKILL.md. Keep the parameter list (`PROMPT`, `MODEL`, `SUPERVISED_MODE=shell`) unchanged.

- [ ] **Step 4: Re-run the wrapper test** — `forbid=0`, `missing=0`.

- [ ] **Step 5: Commit**

```bash
git add agents/codex-code-reviewer.md agents/codex-executor.md \
        agents/gemini-code-reviewer.md agents/gemini-executor.md \
        agents/grok-code-reviewer.md agents/grok-executor.md \
        agents/ext-claude-code-reviewer.md agents/ext-claude-executor.md \
        skills/codex-code-review/SKILL.md skills/gemini-code-review/SKILL.md \
        skills/grok-code-review/SKILL.md skills/ext-claude-code-review/SKILL.md \
        skills/shared/tests/test-claude-cli-agents.sh
git commit -m "$(cat <<'EOF'
fix(agents): invoke skills without Skill tool and wait on Grok

Wrappers Read SKILL.md on Grok instead of flipping to self-review, and
wait on the CLI command id because Grok has no SendMessage ping.
EOF
)"
```

---

### Task 7: `resolve-plugin-root.sh` for skill bash blocks

**Files:**
- Create: `skills/shared/resolve-plugin-root.sh`
- Create: `skills/shared/tests/test-resolve-plugin-root.sh`
- Modify locating-plugin-files sections (prose + first line of each bash fence that sets `SKILL_BASE="<absolute base dir…>"`) in:
  `skills/mesh-design-review/SKILL.md`,
  `skills/ext-claude-exec/SKILL.md`,
  `skills/ext-claude-code-review/SKILL.md`,
  `skills/codex-exec/SKILL.md`,
  `skills/codex-code-review/SKILL.md`,
  `skills/gemini-exec/SKILL.md`,
  `skills/gemini-code-review/SKILL.md`,
  `skills/grok-exec/SKILL.md`,
  `skills/grok-code-review/SKILL.md`,
  `skills/claude-code-review/SKILL.md`

**Interfaces:**
- Consumes: none
- Produces: stdout = absolute plugin root (directory that contains `skills/shared/config-loader.sh`). Order: existing `SKILL_BASE` if it points at a directory containing that loader **or** at `skills/<name>` (then walk to plugin root); else `$CLAUDE_PLUGIN_ROOT`; else `$GROK_PLUGIN_ROOT`; else version-sorted glob.

- [ ] **Step 1: Failing test**

```bash
#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../resolve-plugin-root.sh"
REPO="$(cd "$TESTS_DIR/../../.." && pwd)"
FAIL=0; PASS=0
assert_eq() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1"; else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected '$2', got '$3')"; fi; }
# From a skill directory, walking up should find the repo's config-loader.
GOT=$(SKILL_BASE="$REPO/skills/ext-claude-exec" "$SCRIPT")
assert_eq "SKILL_BASE=skill dir → plugin root" "$REPO" "$GOT"
GOT=$(CLAUDE_PLUGIN_ROOT="$REPO" SKILL_BASE= "$SCRIPT")
assert_eq "CLAUDE_PLUGIN_ROOT wins when SKILL_BASE empty" "$REPO" "$GOT"
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
```

Empty `SKILL_BASE` in the second call: the script must treat unset/empty SKILL_BASE as "not set".

- [ ] **Step 2: Run — fail** (script missing).

- [ ] **Step 3: Implement**

```bash
#!/usr/bin/env bash
set -u
loader_at() { [ -f "$1/skills/shared/config-loader.sh" ]; }
if [ -n "${SKILL_BASE:-}" ]; then
    if loader_at "$SKILL_BASE"; then printf '%s\n' "$SKILL_BASE"; exit 0; fi
    # SKILL_BASE is the skill dir (…/skills/ext-claude-exec)
    parent="$(cd "$SKILL_BASE/../.." && pwd)"
    if loader_at "$parent"; then printf '%s\n' "$parent"; exit 0; fi
fi
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && loader_at "$CLAUDE_PLUGIN_ROOT"; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; exit 0
fi
if [ -n "${GROK_PLUGIN_ROOT:-}" ] && loader_at "$GROK_PLUGIN_ROOT"; then
    printf '%s\n' "$GROK_PLUGIN_ROOT"; exit 0
fi
found="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
if [ -n "$found" ]; then
    printf '%s\n' "$(cd "$(dirname "$found")/../.." && pwd)"
    exit 0
fi
echo "resolve-plugin-root: claude-mesh plugin root not found" >&2
exit 1
```

In each listed SKILL.md, replace the locating paragraph with: set `SKILL_BASE` from the CC print **if present**, then

```bash
PLUGIN_ROOT="$(SKILL_BASE="${SKILL_BASE:-}" bash "$(dirname "$0")/../shared/resolve-plugin-root.sh")"
```

is wrong inside a prompt (no `$0`). The orchestrator/LLM substitutes. Instruct:

```
At the top of EACH bash fence:
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
```

When SKILL_BASE is empty, the LLM must call the resolver by the version-sorted find path already used in `commands/mesh-review.md` Step 1 (`LOADER=... find ... | sort -V | tail -1`), then `PLUGIN_ROOT` is two directories up from that loader. State that fallback explicitly in the locating section of **mesh-design-review** (it has no harness substitution of `CLAUDE_PLUGIN_ROOT` in command-file text).

`commands/mesh-review.md` already has the find fallback; extend the find to also search `$HOME/.grok/plugins`.

- [ ] **Step 4: Run `bash skills/shared/tests/test-resolve-plugin-root.sh`** — 0 failed.

- [ ] **Step 5: Commit** the script, test, and the locating-section edits.

```bash
git commit -m "$(cat <<'EOF'
fix: resolve plugin root when CC does not print SKILL_BASE

Shared helper plus Grok-safe fallbacks (GROK_PLUGIN_ROOT, ~/.grok/plugins)
so exec skills still find config-loader.sh.
EOF
)"
```

---

### Task 8: Orchestrators — host detection, UI, `SELECTED_NATIVE_MODELS`

**Files:**
- Modify: `commands/mesh-review.md` (Step 0, Step 1, Step 2 Q1, CLI page, new native model page, confirm)
- Modify: `skills/mesh-design-review/SKILL.md` (Step 5.0–5.4 counterparts)
- Modify: `skills/shared/tests/test-command-sync.sh` Test 6 (add native facts; keep grok facts)

**Interfaces:**
- Consumes: Task 1 `native_models` in get-defaults; Task 2 `list-host-models.sh`; Task 5 agent names
- Produces: both files bind `SELECTED_NATIVE_MODELS` on every path that later reads it (floor 4 mentions, same as grok); Grok Q1 option 1 is host-native; Grok CLI page order `claude, codex, gemini, grok`; CC Q1 option 1 stays `claude`; `claude` is not on the CC CLI page

- [ ] **Step 1: Write failing Test 6 assertions** (append inside the existing Test 6 loop over the two orchestrator files):

```bash
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    assert_ge "${f#"$REPO"/} binds SELECTED_NATIVE_MODELS" "4" \
        "$(grep -c 'SELECTED_NATIVE_MODELS' "$f")"
    assert_ge "${f#"$REPO"/}: spawn_subagent is the Grok host test" "1" \
        "$(grep -c 'spawn_subagent' "$f")"
    assert_ge "${f#"$REPO"/}: Grok CLI order names claude first" "1" \
        "$(grep -c 'claude / codex / gemini / grok' "$f")"
    assert_ge "${f#"$REPO"/}: native degrade notice" "1" \
        "$(grep -c 'native не запущен' "$f")"
done
# mesh-review dispatches claude-code-reviewer; design review dispatches claude-executor.
assert_ge "design review dispatches claude-executor" "1" \
    "$(grep -c 'claude-mesh:claude-executor' "$DESIGN_SKILL")"
assert_eq "design review never dispatches claude-code-reviewer" "0" \
    "$(grep -c 'claude-mesh:claude-code-reviewer' "$DESIGN_SKILL")"
assert_ge "mesh-review dispatches claude-code-reviewer" "1" \
    "$(grep -c 'claude-mesh:claude-code-reviewer' "$MESH_REVIEW")"
assert_eq "mesh-review never dispatches claude-executor" "0" \
    "$(grep -c 'claude-mesh:claude-executor' "$MESH_REVIEW")"
```

Fix the `grep -c 'claude, codex...'` line: use one exact substring the prose will contain: `claude / codex / gemini / grok` (slash-joined, matching the existing parenthesis style).

Sentinel count: adding a native model page adds one `ни одной` and one `Selecting it IS the empty selection`. The existing equality assertion will fail until both are added together — that is intended.

- [ ] **Step 2: Run `bash skills/shared/tests/test-command-sync.sh`** — expect FAIL on SELECTED_NATIVE_MODELS floor.

- [ ] **Step 3: Edit both orchestrators**

**Host detection** (top of Step 0 / Step 5.0, after AUTODECIDE):

```
HOST=grok if this session has a spawn_subagent tool, else claude-code.
Echo HOST=grok|claude-code.
```

**Step 0 / 5.1 `default`:** parse `.native_models`. If `native` in `.builtin` (or HOST=claude-code and you collapse `native`↔`claude` — on CC, if `native` in builtin, treat as `claude` for host reviewers and **ignore** `.native_models`):

- Grok + native: bind `SELECTED_NATIVE_MODELS` to `.native_models` (empty → one session-model reviewer, list stays empty as the signal for "omit model:").
- Grok + no native: bind `SELECTED_NATIVE_MODELS` to empty.
- CC: bind `SELECTED_NATIVE_MODELS` to empty always (host set is `SELECTED_CLAUDE_MODELS`).

If `.native_models` is non-empty and `native` not in builtin, the loader already rejected the file.

**Step 1 / 5.0 extra Grok probes** (one bash fence):

```bash
HAS_CLAUDE_CLI=0
command -v claude >/dev/null 2>&1 && HAS_CLAUDE_CLI=1
echo "HAS_CLAUDE_CLI=$HAS_CLAUDE_CLI"
HOST_MODELS=""
if [ "$HOST" = grok ]; then
  GM=$(mktemp)
  if grok models >"$GM" 2>/dev/null; then
    HOST_MODELS=$(bash "$(dirname "$LOADER")/list-host-models.sh" --from-file "$GM")
  fi
  rm -f "$GM"
fi
echo "HOST_MODELS=[$(printf '%s' "$HOST_MODELS" | tr '\n' ' ')]"
```

`$HOST` is prompt state, not a shell variable across calls — substitute the literal `grok`/`claude-code` you echoed.

If `HOST=grok` and `native` was requested and `HOST_MODELS` is empty: print `native не запущен; остальные работают.` and bind `SELECTED_NATIVE_MODELS` empty (`native_degraded` spoken, not a loader flag).

Intersect default `native_models` with `HOST_MODELS` (`grep -Fxq`); skip missing slugs with one WARN.

**Q1** remains three options.

- CC: option 1 = `claude` (current label). CLI option parenthesis from HAS_CODEX/HAS_GEMINI/HAS_GROK only, order `codex / gemini / grok`. `claude` is **not** on the CLI page.
- Grok: option 1 = `свои модели хоста` (`native`), ★ if `native` in builtin. CLI option shown if HAS_CLAUDE_CLI or HAS_CODEX or HAS_GEMINI or HAS_GROK. Parenthesis order `claude / codex / gemini / grok`, only those whose flags are 1. Label for claude on the CLI page: `Claude Code CLI`.

**CLI page:** Grok order `claude, codex, gemini, grok`. One engine → skip page. `claude` on this page only when HOST=grok.

**Native model page (Grok, Q1 host selected):** paginate `HOST_MODELS` in `grok models` order, ★ from `native_models`, sentinel `ни одной — native на модели сессии`. Selecting the sentinel **is** the empty selection (drop it; fallback = one session-model reviewer). Bind `SELECTED_NATIVE_MODELS`. If native was not selected, bind empty.

**Claude model page:** unchanged source (`claude.models`). It now also runs on Grok when `claude` was picked on the CLI page.

**Confirm:** expand `native:<slug>` bullets; on CC do not show native bullets. `native`+`claude` on CC → one host set.

Skip run-mode question on Grok (always background). If preset `run_mode` is `team` and HOST=grok: STOP with a one-line error, do not dispatch.

- [ ] **Step 4: Re-run `test-command-sync.sh`** — 0 failed. Sentinel equality still holds.

- [ ] **Step 5: Commit**

```bash
git add commands/mesh-review.md skills/mesh-design-review/SKILL.md \
        skills/shared/tests/test-command-sync.sh
git commit -m "$(cat <<'EOF'
feat(orchestrators): Grok host UI and native model selection

spawn_subagent detects Grok. Q1 option 1 is native there; Claude Code CLI
joins the CLI page. SELECTED_NATIVE_MODELS is bound on every path.
EOF
)"
```

---

### Task 9: Orchestrators — dispatch, wait, Step 6.0

**Files:**
- Modify: `commands/mesh-review.md` Step 5a/5b/6.0
- Modify: `skills/mesh-design-review/SKILL.md` Step 6 and Error Handling
- Modify: `skills/shared/tests/test-command-sync.sh` (dispatch-type facts)

**Interfaces:**
- Consumes: Task 8 bindings; Task 5 agent types; Task 3 engine `claude`
- Produces: Grok native dispatch via `spawn_subagent` `explore` `background: true` `model:` slug; Grok `claude` via `claude-mesh:claude-code-reviewer` / `claude-executor`; wrappers via `spawn_subagent` without `dispatch_model` unless it is in HOST_MODELS; native INLINE in 6.0; watcher roster `claude/opus`; tooling constraint on every native prompt

- [ ] **Step 1: Failing assertions**

```bash
assert_ge "mesh-review Grok native uses explore" "1" \
    "$(grep -c 'subagent_type: "explore"' "$MESH_REVIEW" || grep -c 'subagent_type: explore' "$MESH_REVIEW")"
assert_ge "design review Grok native uses explore" "1" \
    "$(grep -c 'subagent_type: "explore"' "$DESIGN_SKILL" || grep -c 'subagent_type: explore' "$DESIGN_SKILL")"
assert_ge "mesh-review native is INLINE in 6.0" "1" \
    "$(grep -c 'native:<slug> INLINE' "$MESH_REVIEW")"
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    assert_ge "${f#"$REPO"/}: native skipped by verify-delegation" "1" \
        "$(grep -c 'verify-delegation.sh is never invoked for native' "$f")"
done
# Roster spelling for host claude CLI:
for f in "$MESH_REVIEW" "$DESIGN_SKILL"; do
    assert_ge "${f#"$REPO"/}: claude/opus roster spelling" "1" \
        "$(grep -c 'claude/opus' "$f")"
    assert_ge "${f#"$REPO"/}: claude:opus reviewer spelling" "1" \
        "$(grep -c 'claude:opus' "$f")"
done
```

Do not add a brittle STOP-count. Instead pin the exact STOP sentence:

`На Grok team mode не поддерживается — остановите запуск и используйте background.`

```bash
assert_ge "mesh-review Grok team STOP sentence" "1" \
    "$(grep -c 'На Grok team mode не поддерживается' "$MESH_REVIEW")"
assert_ge "design review Grok team STOP sentence" "1" \
    "$(grep -c 'На Grok team mode не поддерживается' "$DESIGN_SKILL")"
```

- [ ] **Step 2: Run test-command-sync — fail.**

- [ ] **Step 3: Dispatch tables**

**mesh-review 5a, HOST=grok**, one message, all `spawn_subagent` `background: true`:

- For each `SELECTED_NATIVE_MODELS` entry: `subagent_type: explore`, `model: "<slug>"`, `description: "Review via native:<slug>"`. If the list is empty and native was selected: one explore, **omit** `model:`. Prompt = requesting-code-review contract + BASE_BRANCH named in prose + tooling-constraint paragraph (copy grok-code-review's `## Tooling constraint` block verbatim). Do not inline the diff.
- For each `SELECTED_CLAUDE_MODELS` entry: `subagent_type: claude-mesh:claude-code-reviewer`, short prompt `MODEL=<alias>` first line, `BASE_BRANCH=` next. Name `claude:<alias>`. Roster `claude/<alias>`. If claude selected and list empty: one reviewer, no MODEL line (CLI default); roster `claude/_default`.
- codex/gemini/grok/ext-claude: existing short prompts, `spawn_subagent` instead of Task, **do not** pass `runtime.dispatch_model` unless that value is in `HOST_MODELS`.
- Do not pass `opus` as spawn `model:`.

**Wait (Grok):** no sleep poller. Completions via harness notification; `get_command_or_subagent_output` on those ids; wait-all allowed with `timeout_ms` ≤ 600000, loop until `global_sec`. Native: not on watcher roster, 6.0 INLINE. Wrappers: still `watch-runs.sh` + `verify-delegation.sh`. Silent wrapper + REAL → read `output.txt` yourself (primary path, not after two pings). No SendMessage.

**mesh-review 5b:** HOST=grok never runs team (already STOP).

**mesh-design-review Step 6:** native gets the composed prompt + tooling constraint, `explore`, `model:` slug. `claude` → `claude-mesh:claude-executor` with `MODEL=` first line, `HOST_CLAUDE=1` forwarded through the executor, `SUPERVISED_MODE: shell`. Claude reviewers (CC host) stay `general-purpose` Task.

**Step 6.0 table:** add rows `native:<slug> INLINE`. `claude:*` on CC INLINE; on Grok `verify-delegation.sh claude <alias>`.

**max_redispatch:** wrappers only.

- [ ] **Step 4: Re-run test-command-sync** — 0 failed. Also `bash skills/shared/tests/test-config-loader.sh` still 0 failed.

- [ ] **Step 5: Commit**

```bash
git add commands/mesh-review.md skills/mesh-design-review/SKILL.md \
        skills/shared/tests/test-command-sync.sh
git commit -m "$(cat <<'EOF'
feat(orchestrators): native spawn_subagent dispatch and Grok wait

explore+model: for host slugs, claude-code-* wrappers for Claude CLI,
INLINE native in the delegation table, no team mode on Grok.
EOF
)"
```

---

### Task 10: Preflight rows `native-models` and `claude-cli`

**Files:**
- Modify: `skills/shared/preflight-env.sh`
- Modify: `skills/shared/tests/test-preflight-env.sh`

**Interfaces:**
- Consumes: Task 2 `list-host-models.sh`
- Produces: rows that never take the probe down; `native-models` is SKIP if `grok models` fails; `claude-cli` is OK/MISSING from `command -v claude`; do **not** print `host: grok-build` from grok-on-PATH. SUMMARY may list `native:<slug>` when the listing succeeded.

- [ ] **Step 1: Add failing assertions** to `test-preflight-env.sh` on an existing valid-config run (the suite already captures probe output). Assert:

```bash
assert_match "native-models row exists" "native-models" "$OUT"
assert_match "claude-cli row exists" "claude-cli" "$OUT"
assert_no_match "does not invent host grok-build from PATH" "host             grok-build" "$OUT"
```

With `PATH` stripped of `grok` (the suite already has PATH tricks for other CLIs), `native-models` must be `SKIP`, not a non-zero exit.

- [ ] **Step 2: Run test-preflight-env.sh — fail** (rows missing).

- [ ] **Step 3: Implement rows** after the existing `cli_row grok` (around line 509). Do not call `cli_row` for native-models (that helper is a binary+URL probe). Print with the existing `row` function:

```bash
# native-models: listing only. Never infer we are inside Grok Build.
NM_STATUS=SKIP
NM_DETAIL="grok models did not run"
if command -v grok >/dev/null 2>&1; then
    GM=$(mktemp) || exit 64
    if timeout "${CLI_TIMEOUT}" grok models >"$GM" 2>/dev/null; then
        NM_LIST=$(bash "$SCRIPT_DIR/list-host-models.sh" --from-file "$GM" | tr '\n' ' ')
        NM_STATUS=OK
        NM_DETAIL="${NM_LIST:-empty listing}"
    else
        NM_STATUS=SKIP
        NM_DETAIL="grok models failed or timed out"
    fi
    rm -f "$GM"
fi
row native-models "$NM_STATUS" "$NM_DETAIL"

if command -v claude >/dev/null 2>&1; then
    row claude-cli OK "claude on PATH"
else
    row claude-cli MISSING "claude CLI not on PATH"
fi
```

Do not add these names to SUMMARY available unless you also update the `*-fresh-session` readers; spec: SUMMARY names what can be selected. Add `native:<slug>` to AVAIL only when NM_STATUS=OK and the listing is non-empty (first three slugs is enough, or all — all is fine). `claude` in SUMMARY on a machine with `claude` on PATH already exists as builtin-claude; do not rename it here. Fresh-session commands already say "run mesh-review default" and read this table.

- [ ] **Step 4: Re-run `bash skills/shared/tests/test-preflight-env.sh`** — 0 failed. Confirm the suite still exits 0 when grok is missing.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh
git commit -m "$(cat <<'EOF'
feat(preflight): list host slugs and the claude CLI

native-models is SKIP when grok models does not answer. claude-cli is
PATH-only. The probe never infers HOST=grok from grok-on-PATH.
EOF
)"
```

---

### Task 11: Example config, README, CHANGELOG

**Files:**
- Modify: `config.example.yaml` (`defaults.code_review` / `defaults.design_review` builtin lists; comments)
- Modify: `README.md` (features, config schema table, Grok-compat paragraph)
- Modify: `CHANGELOG.md` (`## [Unreleased]` at the top)

**Interfaces:**
- Consumes: Task 1 schema
- Produces: example preset includes `native` and `native_models: [grok-4.6, glm-5-3, kimi-k3]`; README states Grok loads the Claude plugin cache (`grok plugin list` empty is not "missing"); Grok-only break: `claude` in builtin means `claude -p`

- [ ] **Step 1: There is no unit test.** Grep the example:

```bash
grep -q 'native_models:' config.example.yaml
grep -q 'builtin: \[native, claude' config.example.yaml
```

Run that by hand; if it fails, the file is not done.

- [ ] **Step 2: Edit `config.example.yaml`**

In both `code_review` and `design_review` presets, set `builtin: [native, claude, codex, gemini, grok]` and add `native_models: [grok-4.6, glm-5-3, kimi-k3]` with a comment: ignored on Claude Code; Grok default native set; slugs must exist in live `grok models` or that reviewer is skipped.

Keep `claude_models` as they are.

- [ ] **Step 3: README**

Add a short "Grok Build" subsection under Features / Configure:

- Grok loads this plugin from `~/.claude/plugins/cache` (Claude compat). `grok plugin list` may say none installed; `grok inspect` is the inventory.
- On Grok, `builtin: native` runs `spawn_subagent` with slugs from `grok models`. `builtin: claude` runs `claude -p` (Claude Code CLI).
- A 0.12.0 preset without `native` does not start host slugs on Grok. Add `native` (and `native_models`) yourself. Claude Code is unchanged.
- Data dir is still `~/.claude/plugins/data/claude-mesh-zinin/`.

Schema table: add `defaults.*.native` / `native_models` rows.

- [ ] **Step 4: CHANGELOG** under a new `## [Unreleased]` (keep `## [0.12.0]` below):

```markdown
## [Unreleased]

### Added
- **Host-aware mesh on Grok Build.** `/mesh-review` and `/mesh-design-review` detect Grok by the presence of `spawn_subagent` and dispatch native `explore` reviewers with `model:` slugs from `grok models` (`defaults.*.native` / `native_models`). Wrappers still run when selected. On Grok, `claude` is the Claude Code CLI (`claude -p`, `runs/claude/<alias>/`).

### Changed
- **Grok-only break:** a 0.12.0 preset with `builtin: [claude, …]` and no `native` no longer means "review on the host model". It means `claude -p`. Claude Code behaviour for that preset is unchanged.
```

Do not bump `.claude-plugin/plugin.json`.

- [ ] **Step 5: Commit**

```bash
git add config.example.yaml README.md CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs: Grok host-aware mesh in example config and README

Document native_models, the Grok-only meaning of builtin claude, and
that grok plugin list is not the Claude-compat inventory.
EOF
)"
```

---

### Task 12: Manual smoke (not optional)

No code. Run on this machine after Tasks 1–11.

- [ ] **Step 1: Grok, temporary preset** with `native` + `native_models: [grok-4.6]` and existing wrappers. `/claude-mesh:mesh-review default`. Confirm native child has `model: grok-4.6`, no `runs/native/`, Step 6.0 INLINE. Wrappers write `runs/…`.

- [ ] **Step 2: Grok, 0.12.0 preset without `native`.** Confirm no host slugs start; `claude` goes to `claude -p` or degrades if `claude` is missing. This is the documented break — it must be visible.

- [ ] **Step 3: Claude Code, 0.12.0 preset.** Confirm 0.12.0 behaviour; transcript has Task, not `spawn_subagent`.

- [ ] **Step 4: Claude Code, preset with `native` and `claude`.** One host set (opus/fable as configured), not two.

- [ ] **Step 5:** Record the four outcomes in the PR description. Do not commit secrets or run dirs.

---

## Spec coverage

| Spec section | Task |
|---|---|
| §1 types, synonym, Grok-only break | 1, 8, 11 |
| §2 schema, pairing, dispatch_model, team STOP | 1, 8, 9 |
| §3 dispatch/wait, explore, tooling constraint, INLINE | 9 |
| §4 HOST_CLAUDE, agents, runs/claude | 3, 4, 5 |
| §5 Skill dual-path, wait, plugin root, tool names | 6, 7, 8, 9 |
| §6 UI | 8 |
| §7 preflight, degrade, 6.0 | 8, 9, 10 |
| §8 tests | 1–11 automated; 12 manual |
| §9 docs / 0.13.0 later | 11 (Unreleased; no version bump) |
| Out of scope | no tasks |
| Checks 1–4 | 4 (unset list from cmd_export), 2 (parser fixture), 9 (explore from spec/user guide), 1 (golden catalog) |
