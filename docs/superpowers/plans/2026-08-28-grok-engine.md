# Grok Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `grok` a first-class reviewer engine in claude-mesh, equal to `codex` and `gemini`, with a model catalog of its own.

**Architecture:** Grok is built the way codex and gemini are built — a gated config section, an exec skill, a code-review skill, two wrapper agents, a row in the environment probe, a verdict in the delegation guard. Two things differ. The stream format is `--output-format streaming-messages-json`, which grok emits in the same wire format `claude -p` produces, so `shared/extract-result.py`, the shared stream-json report renderer, and the `ext-claude` branch of `verify-delegation.sh` all serve grok unchanged. And the model-catalog validator moves into a shared helper that `claude:` and `grok:` both call, instead of becoming a third copy of guards that would drift.

**Tech Stack:** bash 4.2+, `jq`, `yq` (either flavor), `python3`, GNU coreutils/findutils, the `grok` CLI (1.0.5+), Claude Code plugin markdown (skills, agents, commands).

**Spec:** `docs/superpowers/specs/2026-08-28-grok-engine-design.md` — read it before Task 1. It carries the measured facts about the CLI that every task below assumes.

## Global Constraints

- **Never edit `config.yaml`.** It is user-owned; validators report, agents never fix. Same rule for every task here.
- **Claude catalog messages are frozen.** After Task 1, every `claude.models` / `claude_models` error must be byte-identical to what it was before. Tests assert their text.
- **grok model charset:** `[A-Za-z0-9._-]`, anchored to a leading alphanumeric (`GROK_IDENT_RE`). Never widen it: the value becomes a path component and a `watch-runs.sh` roster entry, whose own pattern rejects `:` and `@`.
- **claude model charset stays `[A-Za-z0-9._:@-]`** (`IDENT_RE`). Do not narrow it.
- **Known reasoning efforts:** `low | medium | high | xhigh | max` — FIVE, verified against `grok 1.0.5` (`grok -p x --reasoning-effort=__bogus__` answers `use one of: low, medium, high, xhigh, max`). Unknown values WARN and pass through — the CLI validates. Never make this an enum, and never write a test asserting an unknown value is REJECTED; assert only that it warns and passes. The list goes stale on its own: `codex.reasoning_level` (`config-loader.sh:384`) still lacks `max` while the user's `config.yaml` sets exactly that, so every loader run on this machine already prints a spurious WARN.
- **Never hardcode a grok model.** When neither caller nor catalog names one, omit `-m` and let `~/.grok/config.toml` decide.
- **Watchdog budgets:** `HARD_ZERO_TIMEOUT=600`, `GLOBAL_TIMEOUT=3600`, `MAX_RETRIES=2`, `timeout 1800` per attempt. Supervised runs launch as **background** Bash calls, never foreground.
- **Review floor:** `MIN_REVIEW_BYTES=400` non-space bytes, unchanged.
- **Optional bash arrays expand as `${arr[@]+"${arr[@]}"}`.** Under `set -u`, bash 4.2 and
  4.3 treat `"${arr[@]}"` on an empty array as an unbound variable and abort — and this
  project supports bash 4.2. Do not "simplify" that form back.
- **Engine name is `grok`;** reviewer names are `grok:<model>`; run dirs are `runs/grok/<model>/<timestamp>-<task>/`.
- **Commit style:** conventional commits (`feat(config): …`, `test(verify): …`, `docs: …`), one commit per task step that says "Commit".
- **Run the full suite before any commit that touches `skills/shared/`:** `bash skills/shared/tests/test-config-loader.sh` and the sibling suites named per task. The whole directory takes ~3 minutes.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `skills/grok-exec/SKILL.md` | Run a prompt through the grok CLI; own the run dir, stream, extraction, report, watchdog |
| `agents/grok-executor.md` | Thin wrapper agent that must call `grok-exec`; requires `MODEL` |
| `skills/grok-code-review/SKILL.md` | Resolve the diff, render the review prompt, delegate to `grok-exec` |
| `agents/grok-code-reviewer.md` | Thin wrapper agent that must call `grok-code-review`; requires `MODEL` |
| `skills/shared/stream-json-report.sh` | Anthropic stream-json → markdown report (moved out of `ext-claude-exec/`, now shared by two engines) |
| `skills/shared/tests/test-grok-exec-smoke.sh` | Opt-in live smoke test of the grok invocation (`GROK_SMOKE=1`) |
| `skills/shared/tests/fixtures/valid-grok.yaml` and 7 siblings (8 files; the design lists 11 cases — the remaining 3 are written inline in the test, which reads better beside the assertion. Keep these three numbers in agreement) | Config fixtures for the new validator |

**Modified:**

| Path | Change |
|---|---|
| `skills/shared/config-loader.sh` | `validate_model_catalog` helper; `validate_grok` / `validate_grok_catalog`; `has_grok`; `list-grok-models`; `get-grok`; defaults gating; usage line |
| `skills/shared/verify-delegation.sh` | `grok` path resolver, `grok` in the `ext-claude` classification branch, engine-specific message texts |
| `skills/shared/watch-runs.sh` | Comment listing which exec skills pin `HARD_ZERO_TIMEOUT=600` |
| `skills/shared/preflight-env.sh` | Optional command-probe argument for `cli_row`; the `grok` row; `grok:<model>` in the summary |
| `skills/ext-claude-exec/SKILL.md` | Renderer path now points at `shared/stream-json-report.sh` |
| `commands/mesh-review.md` | Gates, Q1 option, grok-model selection step, dispatch pairs, roster, guard specs |
| `skills/mesh-design-review/SKILL.md` | The same four points at its own step numbers, plus `defaults.design_review.grok_models` |
| `commands/code-review-fresh-session.md`, `commands/design-review-fresh-session.md` | grok listed among the engines |
| `config.example.yaml`, `README.md`, `CHANGELOG.md` | Documentation |
| `skills/shared/tests/test-config-loader.sh`, `test-verify-delegation.sh`, `test-watch-runs.sh`, `test-preflight-env.sh` | New cases |

---

### Task 1: Shared model-catalog validator

Extract the body of `validate_claude` into a parameterised helper, with `claude:` as its only caller for now. Behaviour must not change by one byte — this task's whole deliverable is a refactor that the existing suite cannot tell apart from the code it replaces.

**Files:**
- Modify: `skills/shared/config-loader.sh` (`validate_claude`, around line 405-462)
- Test: `skills/shared/tests/test-config-loader.sh` (existing Test 47 — no new cases here)

**Interfaces:**
- Produces: `validate_model_catalog <jq-path> <label> <charset-re> <charset-display>` — validates every entry of a YAML list of model names: element type is string, value non-empty, matches the charset, no duplicates. Dies with `<label>[<i>]: …` messages. Side-effect free (no `warn`), because callers invoke it more than once per run.
- Produces: `GROK_IDENT_RE` — declared here beside `IDENT_RE`, used from Task 2 on.

- [ ] **Step 1: Capture the baseline messages**

The claude catalog's error text is a contract the tests assert. Record it before touching anything:

```bash
cd /opt/github/zinin/claude-mesh
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
TDIR=$(mktemp -d)
: > /tmp/claude-catalog-baseline.txt
for CASE in 'claude:\n  models: opus\n' \
            'claude:\n  models:\n    - 5\n' \
            'claude:\n  models:\n    - "-opus"\n' \
            'claude:\n  models: [opus, "claude fable"]\n' \
            'claude:\n  models: [opus, fable, opus]\n' \
            'claude:\n  models: [opus, ""]\n' \
            'claude:\n  models: []\n' \
            'claude:\n  other_key: x\n' \
            'claude: false\n'; do
    { printf '%s\n' "$BASE"; printf "$CASE"; } > "$TDIR/config.yaml"
    printf -- '--- case: %s\n' "$CASE" >> /tmp/claude-catalog-baseline.txt
    CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh validate \
        2>> /tmp/claude-catalog-baseline.txt
done
rm -rf "$TDIR"
cat /tmp/claude-catalog-baseline.txt
```

Expected: NINE `--- case:` blocks. Read the actual text, do not assume its shape — `die()`
(`config-loader.sh:40-43`) prints `config-loader: <msg>`, with **no** `ERROR:` in it, and only
the per-element failures carry an index. The nine cases cover four distinct code paths, and
the last three are the ones a six-case baseline silently missed:
`claude.models: must be a list…` (scalar value, no index), the four `claude.models[<i>]: …`
element failures, the empty-list path, the absent-`.models` path (`mtype == null` → early
`return 0`, i.e. NO output at all), and the non-mapping section (`claude: must be a mapping…`).
A case that legitimately prints nothing is still a contract: record the silence.

- [ ] **Step 2: Record the suite's current state**

Run: `bash skills/shared/tests/test-config-loader.sh > /tmp/config-loader-before.txt 2>&1; echo "rc=$?"; tail -2 /tmp/config-loader-before.txt`
Expected: `rc=0` and a summary line ending `0 failed`. If it already fails, stop and report — this plan assumes a green baseline.

- [ ] **Step 3: Add the helper and the second charset constant**

In `skills/shared/config-loader.sh`, beside `IDENT_RE` (line 57), add:

```bash
IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._:@-]*$'    # reasoning levels, claude.models, runtime.dispatch_model
# grok.models is NARROWER than IDENT_RE, and deliberately so: a grok model name becomes a path
# component (runs/grok/<model>/) and a watch-runs.sh roster entry, and that script's own
# validation is ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ — a ':' or '@' accepted here would be
# rejected there, after the run had already been written somewhere the watcher cannot name.
GROK_IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
```

Then, immediately above `validate_claude`, add the helper:

```bash
# Shared by claude: and grok: — the two sections that expose a LIST of model names the
# orchestrators fan independent reviewers out over. The four guards below are what the two
# lists must never diverge on, and each of them is here because it once mattered:
#   - element type: `jq -r` stringifies a number/boolean, so an unquoted `- 5` would compare
#     as the string "5" downstream and a catalog of ["5"] would accept a preset of [5];
#   - empty value: an empty entry makes the membership glob *"  "* match against an EMPTY
#     catalog, silently accepting anything;
#   - charset: it forbids the space that a missing comma produces, which is what stops a
#     preset entry from SPANNING two adjacent catalog members in the substring membership
#     test ("opus fable" matched " opus fable ");
#   - duplicates: two reviewers with one name are indistinguishable in every attribution
#     table both orchestrators print.
# MUST stay side-effect free (no warn): validate_defaults calls it again after validate_all.
# $1 = jq path to the list, $2 = message label, $3 = charset regex, $4 = charset for the message,
# $5 = an example value for the message (OPTIONAL, defaults to the claude-flavoured wording).
# Without $5 a grok failure reads `... (a model alias or id), got "..."` — harmless — but any
# example baked into the shared text would be claude-specific and wrong for half the callers.
# Keep examples out of the shared string, or pass them per caller; never hardcode "opus" here.
validate_model_catalog() {
    local jq_path="$1" label="$2" charset_re="$3" charset_display="$4"
    local count i=0 seen=""   # line-based accumulator (no bash-4 associative arrays)
    count=$(jq "$jq_path | length" "$CONFIG_JSON")
    while [ "$i" -lt "$count" ]; do
        local etype v
        etype=$(jq -r "$jq_path[$i] | type" "$CONFIG_JSON")
        [ "$etype" = "string" ] \
            || die "$label[$i]: must be a string (got $etype) — quote it, e.g. - \"opus\""
        v=$(jq -r "$jq_path[$i]" "$CONFIG_JSON")
        [ -n "$v" ] || die "$label[$i]: empty value"
        [[ "$v" =~ $charset_re ]] \
            || die "$label[$i]: must start with a letter/digit and match $charset_display (a model alias or id), got \"$v\""
        case " $seen " in
            *" $v "*) die "$label[$i]: duplicate model \"$v\" (two reviewers would be indistinguishable)" ;;
        esac
        seen="$seen $v"
        i=$((i+1))
    done
}
```

- [ ] **Step 4: Point `validate_claude` at the helper**

Replace the whole `while [ "$i" -lt "$count" ] … done` loop in `validate_claude` — together with the `local count`, `local i=0` and `local seen=""` lines that feed it — with a single call. Keep every comment above the type gates untouched:

```bash
    validate_model_catalog '.claude.models' 'claude.models' "$IDENT_RE" '[A-Za-z0-9._:@-]'
}
```

- [ ] **Step 5: Verify the messages did not move**

```bash
cd /opt/github/zinin/claude-mesh
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
TDIR=$(mktemp -d)
: > /tmp/claude-catalog-after.txt
for CASE in 'claude:\n  models: opus\n' \
            'claude:\n  models:\n    - 5\n' \
            'claude:\n  models:\n    - "-opus"\n' \
            'claude:\n  models: [opus, "claude fable"]\n' \
            'claude:\n  models: [opus, fable, opus]\n' \
            'claude:\n  models: [opus, ""]\n' \
            'claude:\n  models: []\n' \
            'claude:\n  other_key: x\n' \
            'claude: false\n'; do
    { printf '%s\n' "$BASE"; printf "$CASE"; } > "$TDIR/config.yaml"
    printf -- '--- case: %s\n' "$CASE" >> /tmp/claude-catalog-after.txt
    CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh validate \
        2>> /tmp/claude-catalog-after.txt
done
rm -rf "$TDIR"
diff /tmp/claude-catalog-baseline.txt /tmp/claude-catalog-after.txt && echo "IDENTICAL"
```

Expected: `IDENTICAL`, no diff output. Any difference is a defect in Step 3/4 — fix it, do not update the baseline.

- [ ] **Step 6: Run the suite**

Run — capture the rc, never pipe it away (`| tail` returns `tail`'s status, so a failing suite
would read as success):

```bash
bash skills/shared/tests/test-config-loader.sh > /tmp/config-loader-after.txt 2>&1; RC=$?
tail -3 /tmp/config-loader-after.txt; echo "rc=$RC"
```

Expected: `rc=0`, same pass count as `/tmp/config-loader-before.txt`, `0 failed`.

- [ ] **Step 7: Make the byte-identity permanent**

Steps 1 and 5 compare two files in `/tmp`; nothing stops the NEXT edit from moving a claude
message. Design §5 promises a standing regression, so add one to
`skills/shared/tests/test-config-loader.sh` (new Test 59, after the grok cases of Tasks 2-3):
commit the nine-case stderr from Step 1 as
`skills/shared/tests/fixtures/golden-claude-catalog-messages.txt` and assert the freshly
produced text equals it byte for byte. Committed golden text is the only form of this check
that survives the session that wrote it.

- [ ] **Step 8: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh \
        skills/shared/tests/fixtures/golden-claude-catalog-messages.txt
git commit -m "refactor(config): one catalog validator for claude: and grok:"
```

---

### Task 2: The `grok:` config section

**Files:**
- Modify: `skills/shared/config-loader.sh` (`validate_grok_catalog`, `validate_grok`, `validate_all`, `cmd_get_flag`, `cmd_list_grok_models`, `cmd_get_grok`, dispatch `case`, usage line)
- Create: `skills/shared/tests/fixtures/valid-grok.yaml`, `invalid-grok-scalar.yaml`, `invalid-grok-models-missing.yaml`, `invalid-grok-models-empty.yaml`, `invalid-grok-model-charset.yaml`, `unknown-grok-effort.yaml`, `broken-grok-valid-codex.yaml`
- Test: `skills/shared/tests/test-config-loader.sh` (new Test 57)

**Interfaces:**
- Consumes: `validate_model_catalog`, `GROK_IDENT_RE` (Task 1).
- Produces:
  - `validate_grok_catalog()` — type gates plus the catalog; no `warn`; called by `validate_defaults`.
  - `validate_grok()` — `validate_grok_catalog` plus `reasoning_effort`, which may `warn`.
  - `config-loader.sh get-flag has_grok` → `1` / `0`.
  - `config-loader.sh list-grok-models` → one model per line, config order, nothing when the section is absent.
  - `config-loader.sh get-grok` → the `reasoning_effort` string, or an empty line; rc=0 either way. **No model is returned** — the catalog is a list; read it with `list-grok-models`.

- [ ] **Step 1: Write the fixtures**

```bash
cd /opt/github/zinin/claude-mesh/skills/shared/tests/fixtures
BASE='providers:
  - id: zai
    label: "Z.AI"
    base_url: https://api.z.ai/api/anthropic
    token: "tkn"
models:
  - id: zai/glm
    label: "GLM"
    model: glm-5.1'
printf '%s\ngrok:\n  models: [grok-4.6, grok-4.5]\n  reasoning_effort: xhigh\n' "$BASE" > valid-grok.yaml
printf '%s\ngrok: false\n' "$BASE" > invalid-grok-scalar.yaml
printf '%s\ngrok:\n  reasoning_effort: xhigh\n' "$BASE" > invalid-grok-models-missing.yaml
printf '%s\ngrok:\n  models: []\n' "$BASE" > invalid-grok-models-empty.yaml
printf '%s\ngrok:\n  models: ["grok-4.6", "vendor:grok-4.5"]\n' "$BASE" > invalid-grok-model-charset.yaml
printf '%s\ngrok:\n  models: [grok-4.6]\n  reasoning_effort: "ludicrous"\n' "$BASE" > unknown-grok-effort.yaml
printf '%s\ngrok:\n  models: grok-4.6\ncodex:\n  model: gpt-5.5\n' "$BASE" > broken-grok-valid-codex.yaml
ls -1 *grok*.yaml
```

- [ ] **Step 2a: Add the missing `assert_eq_str` helper FIRST**

The tests below compare VALUES, and `test-config-loader.sh` has no helper for that: it defines
exactly three (`assert_exit` :14, `assert_stderr_contains` :23, `assert_stderr_lacks` :33) and
does value comparison inline (see :1086). Calling an undefined `assert_eq_str` would not fail
the suite — the file runs under `set -u` but **not** `set -e`, so `command not found` returns
127, touches neither `PASS` nor `FAIL`, and the summary still prints `0 failed` while none of
these assertions ran. A silently green suite is worse than a red one, so define the helper
beside the other three before writing a single test that uses it:

```bash
assert_eq_str() {
    # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); echo "  PASS: $1"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $1 — expected '$2', got '$3'"
    fi
}
```

Verify it is really there before continuing: `grep -c '^assert_eq_str()' skills/shared/tests/test-config-loader.sh` must print `1`.

- [ ] **Step 2: Write the failing tests**

Append to `skills/shared/tests/test-config-loader.sh`, immediately before the final `echo ""` / `=== Summary` block:

```bash
# === Test 57: the grok: section ===
# grok: is a GATE like codex:/gemini: — but unlike claude:, its catalog is REQUIRED, because
# the grok reviewer agent refuses to start without a MODEL. A section with no models would
# advertise a reviewer that cannot run.
echo "=== Test 57: grok: section validation ==="
TDIR=$(mktemp -d); ERR=$(mktemp)

cp "$FIXTURES/valid-grok.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a well-formed grok: section" "0" "$RC"

cp "$FIXTURES/invalid-grok-scalar.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a scalar grok: section" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "grok: must be a mapping" "$ERR"
assert_stderr_lacks "no raw jq indexing noise" "Cannot index" "$ERR"

cp "$FIXTURES/invalid-grok-models-missing.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a grok: section with no catalog" "1" "$RC"
assert_stderr_contains "says the catalog is required" "grok.models: required when grok: section present" "$ERR"

cp "$FIXTURES/invalid-grok-models-empty.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects an empty grok catalog" "1" "$RC"
assert_stderr_contains "says the catalog is required" "grok.models: required when grok: section present" "$ERR"

# The charset is the narrow one. A colon is legal in claude.models and must NOT be here:
# the value becomes a path component and a watch-runs.sh roster entry.
cp "$FIXTURES/invalid-grok-model-charset.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a colon in a grok model id" "1" "$RC"
assert_stderr_contains "names the narrow charset" "grok.models\[1\]" "$ERR"
assert_stderr_contains "shows which charset applies" "\[A-Za-z0-9._-\]" "$ERR"

{ printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n'
  printf 'grok:\n  models: [grok-4.6, grok-4.6]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate grok model" "1" "$RC"
assert_stderr_contains "names the duplicate" "duplicate model" "$ERR"

# Unknown effort passes with a WARN — xAI adds levels without asking this plugin.
cp "$FIXTURES/unknown-grok-effort.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts an unknown reasoning_effort" "0" "$RC"
assert_stderr_contains "warns about it" "unknown value \"ludicrous\"" "$ERR"

# No grok: section at all — every existing config on earth.
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "a config with no grok: section stays valid" "0" "$RC"
GF=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_grok 2>/dev/null)
assert_eq_str "has_grok=0 without a section" "0" "$GF"

cp "$FIXTURES/valid-grok.yaml" "$TDIR/config.yaml"
GF=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-flag has_grok 2>/dev/null)
assert_eq_str "has_grok=1 with a section" "1" "$GF"
LIST=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" list-grok-models 2>/dev/null | tr '\n' ' ')
assert_eq_str "list-grok-models emits the catalog in config order" "grok-4.6 grok-4.5 " "$LIST"
EFFORT=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-grok 2>/dev/null)
assert_eq_str "get-grok returns the effort" "xhigh" "$EFFORT"

# get-grok is a TYPED getter: a malformed section must die here, not return an empty string.
cp "$FIXTURES/broken-grok-valid-codex.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-grok >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-grok rejects a malformed catalog" "1" "$RC"
# …while the codex getter beside it still answers: a broken grok section must not
# ground the other engines (the `ultra` incident, 2026-07-10).
CG=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>/dev/null); RC=$?
assert_exit "get-codex still works with a broken grok section" "0" "$RC"
assert_eq_str "…and returns the codex model" "gpt-5.5|" "$CG"

rm -rf "$TDIR" "$ERR"
```

- [ ] **Step 3: Run the tests to watch them fail**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | grep -A40 'Test 57'`
Expected: FAILs — `grok: must be a mapping` never appears, `list-grok-models` is an unknown command, `has_grok` dies with `get-flag: unknown feature`.

- [ ] **Step 4: Implement the validators**

In `skills/shared/config-loader.sh`, after `validate_gemini`, add:

```bash
# Split in two on purpose. validate_defaults needs the CATALOG validated before it can check
# preset membership, and it runs after validate_all has already validated the section — so the
# half that can `warn` must not be on that path, or every run with an unknown effort prints the
# warning twice. Same discipline the comment at validate_claude spells out.
validate_grok_catalog() {
    # Type-dispatch gate, same class as validate_codex/validate_gemini: a scalar section must
    # die cleanly instead of crashing the getters with a raw jq "Cannot index boolean" (rc=5).
    local stype
    stype=$(jq -r '.grok | type' "$CONFIG_JSON" 2>/dev/null)
    # `grok:` written with NO value (YAML null) counts as ABSENT, not as "present but empty".
    # That is the established precedent, not a new choice: `codex:` with no value already
    # yields has_codex=0 rather than a "model required" error, and a user who comments out a
    # section's body means "off", not "misconfigured".
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "grok: must be a mapping with models/reasoning_effort keys (got $stype)" ;;
    esac

    # DELIBERATE ASYMMETRY with claude:, where a section without `models` simply means "no
    # catalog". Here the catalog is REQUIRED: the grok reviewer agent stops without a MODEL,
    # so a section with no models advertises a reviewer that cannot start. Closer to
    # codex.model / gemini.model, which are required for the same kind of reason.
    local mtype
    mtype=$(jq -r '.grok.models | type' "$CONFIG_JSON" 2>/dev/null)
    case "$mtype" in
        array) ;;
        null) die "grok.models: required when grok: section present" ;;
        *) die "grok.models: must be a list of grok model ids, got $mtype" ;;
    esac
    [ "$(jq '.grok.models | length' "$CONFIG_JSON")" -gt 0 ] \
        || die "grok.models: required when grok: section present"

    validate_model_catalog '.grok.models' 'grok.models' "$GROK_IDENT_RE" '[A-Za-z0-9._-]'
}

validate_grok() {
    validate_grok_catalog
    # reasoning_effort mirrors codex.reasoning_level, including the pass-through: xAI adds
    # levels with new models, and the CLI rejects a truly invalid one by name.
    local ltype effort
    ltype=$(jq -r '.grok.reasoning_effort | type' "$CONFIG_JSON" 2>/dev/null)
    case "$ltype" in
        ""|null) return 0 ;;
        string) ;;
        *) die "grok.reasoning_effort: must be a string (got $ltype) — quote it, e.g. reasoning_effort: \"xhigh\"" ;;
    esac
    effort=$(jq -r '.grok.reasoning_effort' "$CONFIG_JSON")
    # Empty string == key not set, the codex.reasoning_level semantics. A user who comments a
    # value out and leaves `reasoning_effort: ""` behind means "let the CLI decide", and dying
    # on that would be stricter than the section this one is modelled on.
    [ -n "$effort" ] || return 0
    [[ "$effort" =~ $IDENT_RE ]] \
        || die "grok.reasoning_effort: must start with a letter/digit and match [A-Za-z0-9._:@-], got \"$effort\""
    case "$effort" in
        low|medium|high|xhigh|max) ;;
        *) warn "grok.reasoning_effort: unknown value \"$effort\" — passing through (the grok CLI will validate)" ;;
    esac
}
```

- [ ] **Step 5: Wire it into `validate_all`, the flags, the getters and the dispatch**

In `validate_all`, add `validate_grok` on its own line after `validate_gemini`:

```bash
    validate_codex
    validate_gemini
    validate_grok
    validate_claude
```

In `cmd_get_flag`'s `case`, beside `has_gemini`:

```bash
        has_grok)
            jq -e '.grok' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
```

In the same function's final `die`, extend the valid list: `(valid: has_codex, has_gemini, has_grok, has_models, has_claude_models, has_defaults_code_review, do_plan_default_stop_tokens, dispatch_model)`.

After `cmd_get_gemini`, add:

```bash
cmd_list_grok_models() {
    # One grok model id per line, config order — same line-per-entry contract as
    # cmd_list_claude_models. Prints nothing (exit 0) when there is no grok: section.
    load_or_die
    validate_grok_catalog
    jq -r '(.grok.models // [])[]' "$CONFIG_JSON"
}

cmd_get_grok() {
    load_or_die
    validate_grok
    # Format: <reasoning_effort>, empty when unset. Deliberately NOT "<model>|<effort>" like
    # get-codex: grok carries a CATALOG, not one model — read it with list-grok-models. Callers
    # gate on `get-flag has_grok` first, exactly as they do for codex and gemini.
    jq -r '.grok.reasoning_effort // ""' "$CONFIG_JSON"
}
```

In the bottom dispatch `case`, beside `get-gemini)`:

```bash
    list-grok-models)
        cmd_list_grok_models
        ;;
    get-grok)
        cmd_get_grok
        ;;
```

And extend the usage line to:

```bash
        echo "Usage: $0 {validate|data-dir|export <model-id>|get-flag <feature>|list-models|list-claude-models|list-grok-models|list-providers|get-defaults <category>|get-runtime|get-codex|get-gemini|get-grok}" >&2
```

- [ ] **Step 6: Run the tests**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-config-loader.sh > /tmp/test-config-loader.txt 2>&1; RC=$?
tail -3 /tmp/test-config-loader.txt; echo "rc=$RC"
```

Expected: `0 failed`, pass count higher than `/tmp/config-loader-before.txt` by the number of new assertions.

- [ ] **Step 7: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh skills/shared/tests/fixtures/
git commit -m "feat(config): grok: section with a required model catalog"
```

---

### Task 3: `grok` in the defaults presets

**Files:**
- Modify: `skills/shared/config-loader.sh` (`validate_defaults`, `cmd_get_defaults`)
- Create: `skills/shared/tests/fixtures/invalid-defaults-builtin-grok-no-section.yaml`
- Test: `skills/shared/tests/test-config-loader.sh` (new Test 58)

**Interfaces:**
- Consumes: `validate_grok_catalog`, `list-grok-models` (Task 2).
- Produces: `get-defaults <category>` JSON gains a `grok_models` key — always an array, never null, exactly like `claude_models`.

- [ ] **Step 1: Write the fixture**

```bash
cd /opt/github/zinin/claude-mesh/skills/shared/tests/fixtures
printf 'providers:\n  - id: zai\n    label: "Z.AI"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ndefaults:\n  code_review:\n    builtin: [grok]\n' > invalid-defaults-builtin-grok-no-section.yaml
cat invalid-defaults-builtin-grok-no-section.yaml
```

- [ ] **Step 2: Write the failing tests**

Append to `skills/shared/tests/test-config-loader.sh` before the summary block:

```bash
# === Test 58: defaults.<preset> grok gating ===
# Two rules, and they point in OPPOSITE directions. grok_models without grok in builtin is the
# same fail-closed rule claude_models has. grok in builtin WITHOUT grok_models is also an
# error — the mirror image, and unlike claude there is no single-reviewer fallback to land on,
# because the reviewer agent stops without a MODEL.
echo "=== Test 58: defaults grok gating ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
GCAT=$(printf 'grok:\n  models: [grok-4.6, grok-4.5]\n')

cp "$FIXTURES/invalid-defaults-builtin-grok-no-section.yaml" "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects builtin grok with no grok: section" "1" "$RC"
assert_stderr_contains "says which section is missing" 'builtin lists "grok" but no grok: section' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects builtin grok with no grok_models" "1" "$RC"
assert_stderr_contains "explains the reviewer needs a model" "grok_models is empty" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    grok_models: [grok-4.6]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects grok_models without grok in builtin" "1" "$RC"
assert_stderr_contains "names the missing builtin entry" 'missing from defaults.code_review.builtin' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n    grok_models: [grok-4.7]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a grok_models entry outside the catalog" "1" "$RC"
assert_stderr_contains "points at the catalog" "grok.models catalog" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n    grok_models: [grok-4.6, grok-4.6]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate grok_models entry" "1" "$RC"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  design_review:\n    builtin: [grok]\n    grok_models: [grok-4.5]\n'; } > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a well-formed design_review preset" "0" "$RC"
DJ=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults design_review 2>/dev/null)
GM=$(printf '%s' "$DJ" | jq -r '.grok_models | join(",")')
assert_eq_str "get-defaults carries grok_models" "grok-4.5" "$GM"

# A preset with no grok at all still emits an ARRAY, never null — both orchestrators iterate it.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
DJ=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-defaults code_review 2>/dev/null)
GT=$(printf '%s' "$DJ" | jq -r '.grok_models | type')
assert_eq_str "grok_models defaults to an array" "array" "$GT"

rm -rf "$TDIR" "$ERR"
```

- [ ] **Step 3: Run to watch them fail**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | grep -A25 'Test 58'`
Expected: the first case fails with `unknown value "grok"` (the current enum), and `get-defaults` has no `grok_models` key.

- [ ] **Step 4: Implement**

In `validate_defaults`, after the `validate_claude` call, add the catalog validation and read the catalog:

```bash
    validate_claude
    # Same reason validate_claude runs here: preset entries are checked against the catalog,
    # so the catalog must be a well-formed list first. The _catalog half, not validate_grok —
    # this call site is reached twice per run and must not repeat the effort warning.
    validate_grok_catalog

    local claude_catalog grok_catalog
    claude_catalog=$(jq -r '(.claude.models // [])[]' "$CONFIG_JSON" | tr '\n' ' ')
    grok_catalog=$(jq -r '(.grok.models // [])[]' "$CONFIG_JSON" | tr '\n' ' ')
```

Extend the `has_*` probes beside them:

```bash
    local has_codex has_gemini has_grok
    has_codex=$(jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    has_gemini=$(jq -e '.gemini' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    has_grok=$(jq -e '.grok' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
```

Add the `builtin` case arm and widen the error:

```bash
                grok)
                    [ "$has_grok" = "1" ] || die "defaults.$preset.builtin lists \"grok\" but no grok: section"
                    ;;
                *) die "defaults.$preset.builtin: unknown value \"$v\" (valid: claude, codex, gemini, grok)" ;;
```

Then, after the whole `claude_models` block (immediately before the loop's closing `done` for the preset), add the `grok_models` block:

```bash
        # grok_models — the same shape as claude_models, with the requirement running BOTH ways.
        # claude tolerates "claude in builtin, no claude_models": it falls back to one reviewer
        # on the dispatch model. grok has no such fallback — its reviewer agent stops without a
        # MODEL — so the missing list is an error rather than a default.
        local gmtype
        gmtype=$(jq -r ".defaults.$preset.grok_models | type" "$CONFIG_JSON")
        case "$gmtype" in
            array|null) ;;
            *) die "defaults.$preset.grok_models: must be a list, got $gmtype" ;;
        esac

        local gm_count grok_in_builtin
        gm_count=$(jq ".defaults.$preset.grok_models | length" "$CONFIG_JSON")
        grok_in_builtin=$(jq "[(.defaults.$preset.builtin // [])[] | select(. == \"grok\")] | length" "$CONFIG_JSON")
        if [ "$gm_count" -gt 0 ] && [ "$grok_in_builtin" = 0 ]; then
            die "defaults.$preset.grok_models is set but \"grok\" is missing from defaults.$preset.builtin (add \"grok\" to builtin, or drop grok_models)"
        fi
        if [ "$grok_in_builtin" -gt 0 ] && [ "$gm_count" = 0 ]; then
            die "defaults.$preset.builtin lists \"grok\" but defaults.$preset.grok_models is empty — a grok reviewer cannot start without a model (name one from the grok.models catalog)"
        fi

        local g=0
        local seen_gm=""
        while [ "$g" -lt "$gm_count" ]; do
            local gmetype gmv
            gmetype=$(jq -r ".defaults.$preset.grok_models[$g] | type" "$CONFIG_JSON")
            [ "$gmetype" = "string" ] \
                || die "defaults.$preset.grok_models[$g]: must be a string (got $gmetype) — quote it, e.g. - \"grok-4.6\""
            gmv=$(jq -r ".defaults.$preset.grok_models[$g]" "$CONFIG_JSON")
            [ -n "$gmv" ] || die "defaults.$preset.grok_models[$g]: empty value"
            [[ "$gmv" =~ $GROK_IDENT_RE ]] \
                || die "defaults.$preset.grok_models[$g]: must start with a letter/digit and match [A-Za-z0-9._-] (a grok model id), got \"$gmv\""
            case " $grok_catalog " in
                *" $gmv "*) ;;
                *) die "defaults.$preset.grok_models[$g]: unknown grok model \"$gmv\" (add it to the grok.models catalog)" ;;
            esac
            case " $seen_gm " in
                *" $gmv "*) die "defaults.$preset.grok_models[$g]: duplicate model \"$gmv\"" ;;
            esac
            seen_gm="$seen_gm $gmv"
            g=$((g+1))
        done
```

Finally, extend `cmd_get_defaults`'s jq object:

```bash
    jq -c "{builtin: (.defaults.${category}.builtin // []), claude_models: (.defaults.${category}.claude_models // []), grok_models: (.defaults.${category}.grok_models // []), models: (.defaults.${category}.models // []), run_mode: (.defaults.${category}.run_mode // null)}" "$CONFIG_JSON"
```

- [ ] **Step 5: Run the tests**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-config-loader.sh > /tmp/test-config-loader.txt 2>&1; RC=$?
tail -3 /tmp/test-config-loader.txt; echo "rc=$RC"
```

Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/
git commit -m "feat(config): grok in defaults presets, with grok_models required both ways"
```

---

### Task 4: Config example and schema documentation

**Files:**
- Modify: `config.example.yaml` (section 3 and section 4), `README.md` (config-schema table, dependencies)

**Interfaces:**
- Consumes: everything Tasks 2-3 produced. Nothing consumes this task.

- [ ] **Step 1: Add the `grok:` block to `config.example.yaml`**

In section 3, after the `gemini:` block, insert:

```yaml
grok:
  # Catalog of grok models offered when you pick the built-in `grok` reviewer. REQUIRED when
  # this section exists, and it must hold at least one entry: the grok reviewer agent refuses
  # to start without a model, so an empty catalog would offer a reviewer that cannot run.
  # (This is the one place grok differs from claude:, whose catalog is optional.)
  #
  # Each entry becomes ONE independent reviewer, exactly as under claude: — same diff, same
  # prompt, different model. Run `grok models` to see what your subscription offers.
  #
  # CHARSET: [A-Za-z0-9._-], narrower than claude.models. A grok model id becomes a directory
  # name (runs/grok/<model>/) and a roster entry for the run watcher, and neither accepts ':'.
  models: [grok-4.6, grok-4.5]                 # [required when grok: present, >=1 entry]

  # [optional] known values: low | medium | high | xhigh. Unknown values pass through with a
  # WARN (the grok CLI validates them). One value for the whole section, not per model.
  # Omit it and the CLI's own default applies (~/.grok/config.toml, [models]
  # default_reasoning_effort).
  reasoning_effort: xhigh
```

Also update section 3's header comment, which currently says "the three built-in reviewer types selectable in `defaults.*.builtin`: claude, codex, gemini" — make it four and name grok in the same sentence as codex/gemini as a GATE.

In section 4, add to both presets:

```yaml
    grok_models: [grok-4.6]                    # [optional] list; each entry must be in the
                                               #   grok.models catalog above. REQUIRED whenever
                                               #   "grok" is in builtin — unlike claude_models,
                                               #   there is no single-reviewer fallback here.
```

**Leave `grok` OUT of the `builtin:` lines at this task, and add it in Task 13 instead.** This
task lands five tasks before the reviewer agents exist (Task 7) and before either orchestrator
knows the word (Tasks 11-12), so putting grok into the shipped presets here makes every commit
in between advertise a reviewer that cannot be dispatched — and a user who copies
`config.example.yaml` in that window gets a config the orchestrators reject. Add the `grok:`
section itself here as documentation, and switch the presets on in Task 13, once everything
behind them is in place. When that moment comes, extend both `builtin:` lines and their
comments to `[claude, codex, gemini, grok]`, with `grok — requires the grok: section above.` on the list of per-entry notes.

**Renderer limitation, recorded rather than fixed.** `stream-json-report.sh` renders only the
first block of each `.message.content[]`, so a mixed message (thinking + text + tool_use) loses
the rest in `report.md`. The defect predates grok and affects ext-claude identically, and
`report.md` is an auxiliary artifact — every decision in this plugin is made from `output.txt`,
which `extract-result.py` builds independently. Fixing the renderer for all engines is a
separate change; note the limitation in `grok-exec/SKILL.md` so nobody debugs a run by reading
a report that quietly dropped half of it.

- [ ] **Step 2: Verify the example still validates**

```bash
cd /opt/github/zinin/claude-mesh
TDIR=$(mktemp -d) && cp config.example.yaml "$TDIR/config.yaml" && \
CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh validate; echo "rc=$?"; \
CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh list-grok-models; \
CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh get-defaults code_review | jq .grok_models; \
rm -rf "$TDIR"
```

Expected: `rc=0`, the two models on their own lines, `["grok-4.6"]`.

Then run the suite that reads `config.example.yaml` directly — Tests 31, 32 and 51 in
`test-config-loader.sh` load that file, so an edit here can break them while the ad-hoc check
above stays green — and confirm the example produces the row a user without a section sees:

```bash
bash skills/shared/tests/test-config-loader.sh > /tmp/cfg-task4.txt 2>&1; RC=$?
tail -3 /tmp/cfg-task4.txt; echo "rc=$RC"
bash skills/shared/preflight-env.sh 2>/dev/null | grep '^grok'   # a user with no grok: section -> grok MISSING
```

- [ ] **Step 3: Update the README**

In the config-schema table, after the `gemini:` row:

```markdown
| `grok:` | no | `models:` — catalog of grok model ids for the built-in `grok` reviewer (required when the section exists); `reasoning_effort:` — one of low/medium/high/xhigh/max (run `grok --help` for the current set), unknown values pass through with a WARN. Each selected entry becomes one independent reviewer |
```

In the dependency list, after the gemini CLI line:

```markdown
- `grok` CLI (only if using grok agents). It authenticates itself (`grok login`); claude-mesh never handles a grok token. Unlike codex and gemini, grok also reads your `~/.claude/CLAUDE.md` and every installed claude-* plugin — a grok reviewer starts with your project rules in context, and its review prompt forbids it from invoking any of those skills
```

- [ ] **Step 4: Commit**

```bash
git add config.example.yaml README.md
git commit -m "docs(config): document the grok: section and its preset keys"
```

---

### Task 5: Move the stream-json report renderer into `shared/`

`skills/ext-claude-exec/generate-md.sh` renders a markdown report from an Anthropic
stream-json log. Grok emits that exact format, and its `report_title` is already a parameter —
so this is a renderer with two engines, sitting inside one engine's directory. Move it once,
now, rather than copying 178 lines.

**Files:**
- Move: `skills/ext-claude-exec/generate-md.sh` → `skills/shared/stream-json-report.sh`
- Modify: `skills/ext-claude-exec/SKILL.md` (two call sites, and the prose that names the file)

**Interfaces:**
- Produces: `shared/stream-json-report.sh <log_file> <md_file> <profile> [report_title] [task_name_override]` — unchanged signature, unchanged behaviour. `profile` is a free label printed in the header (ext-claude passes the model id; grok passes `grok`).

- [ ] **Step 1: Capture a before-picture**

```bash
cd /opt/github/zinin/claude-mesh
FIX=$(mktemp -d)/run && mkdir -p "$FIX" && cat > "$FIX/raw.jsonl" << 'JSONL'
{"type":"system","subtype":"init","session_id":"abc-123","model":"grok-4.6","tools":["read_file"]}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading the diff."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a.py"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"print(1)"}]}}
{"type":"result","subtype":"success","is_error":false,"num_turns":4,"result":"### Findings\n- a.py:1 — no issues","total_cost_usd":0.01,"usage":{"input_tokens":10,"output_tokens":20}}
JSONL
bash skills/ext-claude-exec/generate-md.sh "$FIX/raw.jsonl" /tmp/report-before.md "grok" "Grok Execution Report" "smoke"
echo "rc=$?"; echo "FIXDIR=$FIX"; head -8 /tmp/report-before.md
```

Keep the printed `FIXDIR` — Step 3 reuses it. Expected: `rc=0` and a report whose first line is `# Grok Execution Report`.

- [ ] **Step 2: Move the file and repoint its caller**

```bash
cd /opt/github/zinin/claude-mesh
git mv skills/ext-claude-exec/generate-md.sh skills/shared/stream-json-report.sh
sed -i 's|"\$SKILL_DIR/generate-md\.sh"|"$SKILL_DIR/../shared/stream-json-report.sh"|g' skills/ext-claude-exec/SKILL.md
grep -n 'stream-json-report\|generate-md' skills/ext-claude-exec/SKILL.md
```

Expected: the two call sites now name `stream-json-report.sh`; the remaining hits are prose
(lines that read "generate-md.sh detects the missing timestamp prefix", the supervised-mode
paragraph, the flag table and the checklist). The count is **six**, not five, and two of them
(`SKILL.md:223` and `:346`) are RUNTIME lines — they build the path the skill actually executes,
so leaving them stale breaks the shipped skill rather than merely misdescribing it; the rest are
prose. The verification grep below is also too narrow: it looks for `ext-claude-exec/generate-md`
and misses a bare `generate-md.sh`, so run both forms. Rewrite all six to say
`shared/stream-json-report.sh`, leaving the sentences otherwise as they are.

Also fix the usage comment inside the moved script itself:

```bash
sed -i 's|^# Usage: \./generate-md\.sh |# Usage: ./stream-json-report.sh |' skills/shared/stream-json-report.sh
sed -i 's|^# Generate human-readable markdown from ext-claude JSON log|# Generate human-readable markdown from an Anthropic stream-json log (ext-claude and grok)|' skills/shared/stream-json-report.sh
head -4 skills/shared/stream-json-report.sh
```

- [ ] **Step 3: Verify the output is byte-identical**

```bash
cd /opt/github/zinin/claude-mesh
FIX=<the FIXDIR printed in Step 1>
bash skills/shared/stream-json-report.sh "$FIX/raw.jsonl" /tmp/report-after.md "grok" "Grok Execution Report" "smoke"
diff /tmp/report-before.md /tmp/report-after.md && echo "IDENTICAL"
```

Expected: `IDENTICAL`. Then confirm nothing else in the repo still points at the old path:

```bash
grep -rn 'generate-md' --exclude-dir=.git --exclude-dir=docs --exclude-dir=.superpowers . || echo "no stale references"
```

`CHANGELOG.md` may mention the old path in a historical entry — leave history alone; only code and live docs must move.

- [ ] **Step 4: Commit**

```bash
git add -A skills/ext-claude-exec skills/shared/stream-json-report.sh
git commit -m "refactor(exec): share the stream-json report renderer between engines"
```

---

### Task 6: The `grok-exec` skill and its executor agent

**Files:**
- Create: `skills/grok-exec/SKILL.md`, `agents/grok-executor.md`, `skills/shared/tests/test-grok-exec-smoke.sh`
- Reference while writing: `skills/gemini-exec/SKILL.md` (structure), `skills/codex-exec/SKILL.md` (supervised block)

**Interfaces:**
- Consumes: `config-loader.sh data-dir`, `get-flag has_grok`, `get-grok` (Task 2); `shared/watchdog.sh`; `shared/extract-result.py`; `shared/stream-json-report.sh` (Task 5).
- Produces: a run directory `${PLUGIN_DATA}/runs/grok/<model>/<TIMESTAMP>-<TASK_NAME>/` — or `${PLUGIN_DATA}/runs/grok/<TIMESTAMP>-<TASK_NAME>/` when no model is given — holding `.task_name`, `.model`, `.session_id`, `prompt.md`, `raw.jsonl`, `raw.json`, `output.txt`, `report.md`, `stderr.txt`, and under supervision `attempt-N/`, `final/`, `watchdog.log`.
- Produces: skill parameters `PROMPT` (required), `TASK_NAME`, `MODEL`, `REASONING_EFFORT`, `SUPERVISED_MODE` (`none` | `shell`).

- [ ] **Step 0: Teach `extract-result.py` grok's error shape — FIRST, and with a test**

Design §2 rests on "no third extractor", and that claim is false until this lands. grok emits
a **top-level** `{"type":"error","message":"…"}`; `extract-result.py:96-102` reads the
**nested** `.error.message`. Reproduce it before changing anything, so the fix is anchored to
observed behaviour:

```bash
cd /opt/github/zinin/claude-mesh
D=$(mktemp -d)
printf '%s\n' '{"type":"error","message":"Couldn'"'"'t set model to bogus-model"}' > "$D/raw.jsonl"
python3 skills/shared/extract-result.py "$D" && cat "$D/output.txt"; echo
rm -rf "$D"
```

Observed today: `API Error: {}` — the message is gone, and the single most common user error
(a typo in a model name) reaches the report as an empty brace pair. Fix it ADDITIVELY, keeping
the nested branch first so all three current engines stay byte-identical:

```python
            if ev.get("type") == "error":
                err = ev.get("error", {})
                if isinstance(err, dict):
                    err_msg = err.get("message") or ev.get("message") or str(err)
                else:
                    err_msg = str(err)
```

Then add a regression to `skills/shared/tests/test-extract-result.sh` covering BOTH shapes —
nested (`{"type":"error","error":{"message":"x"}}`) and top-level — and re-run that suite,
capturing the rc rather than piping it away. Existing engines must show no change.

- [ ] **Step 1: Scaffold the skill from its sibling**

Copy `skills/gemini-exec/SKILL.md` to `skills/grok-exec/SKILL.md` and keep, with `gemini`→`grok`
wording applied, these sections verbatim in structure: the frontmatter, "Locating plugin files",
"CRITICAL: Tool Execution Rules" (both subsections — they are about the harness, not the engine),
"When to Use", "Input", "Pre-flight Checks", "Process" Steps 1-3, "Options Explained",
"Error Recovery", "Checklist". Steps 2-6 below replace the engine-specific content.

```bash
cd /opt/github/zinin/claude-mesh
mkdir -p skills/grok-exec
cp skills/gemini-exec/SKILL.md skills/grok-exec/SKILL.md
```

- [ ] **Step 2: Write the frontmatter, the header and the auth note**

Replace the file's first 15 lines with:

```markdown
---
name: grok-exec
description: Execute any prompt via the xAI Grok CLI with full logging and progress display
user_invocable: true
---

# Grok Exec

Execute arbitrary prompts via the Grok Build CLI with streaming progress and full logging.

**Announce at start:** "Using grok-exec skill to run prompt via Grok."

> **Grok manages its own auth.** Like codex and gemini — and unlike the ext-claude skills —
> grok is NOT an anthropic-api provider: the `grok` CLI logs in by itself (`grok login`).
> This skill does NOT call `config-loader.sh export` and does NOT source `ANTHROPIC_*`. The
> loader is used ONLY to (a) find the plugin data dir for run logs, (b) gate on the `has_grok`
> config flag, and (c) resolve the default reasoning effort via `get-grok`.

> **Grok reads the Claude Code world.** `grok inspect` shows it loading `~/.claude/CLAUDE.md`
> and every installed claude-* plugin with its skills, and the `system`/`init` event repeats
> them. That costs ~19k cached input tokens per run and, more importantly, means grok can SEE
> skills like `claude-mesh:mesh-review`. Callers that care — the review skill does — put an
> explicit "do not invoke skills" line in the prompt. There is no CLI flag to suppress this.
```

- [ ] **Step 3: Write the input contract**

Replace the "## Input" section with:

```markdown
## Input

The caller must provide:
- **PROMPT** — the full prompt text to send to Grok

Optional:
- **TASK_NAME** — short name for log files (default: "task")
- **MODEL** — a grok model id (e.g. `grok-4.6`). **Do NOT choose one yourself.** When the
  caller names none, `-m` is omitted entirely and the CLI's own default applies
  (`~/.grok/config.toml`, `[models] default`). This skill hardcodes no model, unlike
  codex-exec and gemini-exec: grok ships a user-level default and overriding it silently
  would be wrong. The review path always passes a model, chosen from the `grok.models`
  catalog.
- **REASONING_EFFORT** — `low` | `medium` | `high` | `xhigh` (the set the CLI itself names).
  When the caller passes none, the skill reads `grok.reasoning_effort` from config via
  `get-grok`; when that is unset too, `--effort` is omitted and the CLI's
  `default_reasoning_effort` applies. Unknown values are passed through — the CLI validates.
- **SUPERVISED_MODE** — `none` (default) or `shell`. Under `shell` the run is wrapped by
  `shared/watchdog.sh` (`$SKILL_BASE/../shared/watchdog.sh`), which restarts the CLI when the
  stream stops growing for `HARD_ZERO_TIMEOUT` seconds (600) up to `MAX_RETRIES=2` times,
  under a `GLOBAL_TIMEOUT=3600` wall clock. Artifacts land in `$WORK_DIR/attempt-N/`, the
  winning attempt is exposed as `$WORK_DIR/final/`, and `raw.jsonl` / `output.txt` /
  `report.md` are copied to `$WORK_DIR/` root for callers that read the root paths.
```

- [ ] **Step 4: Write the pre-flight block**

Replace the "## Pre-flight Checks" bash fence with:

```bash
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"

command -v grok >/dev/null 2>&1 || { echo "STOP: grok CLI not found — install Grok Build and run 'grok login'"; exit 1; }
echo "OK: grok found"
command -v jq >/dev/null 2>&1 || { echo "STOP: jq not found — required to parse the stream"; exit 1; }
echo "OK: jq found"
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found — required by shared/extract-result.py"; exit 1; }
echo "OK: python3 found"

# Soft gate: warn (don't STOP) if the optional grok: block is unconfigured. grok handles its
# own auth, so an absent block is non-fatal for a direct call — it only means no catalog and
# no configured effort. get-flag emits 1/0 — compare to "1".
if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_grok 2>/dev/null)" != "1" ]; then
    echo "WARN: grok: block not configured in config.yaml (grok uses its own auth — continuing)"
fi
```

- [ ] **Step 5: Write Step 1 of the Process (run directory)**

Replace the Step 1 bash fence with this one. The only structural difference from gemini-exec
is the model path segment:

```bash
set -euo pipefail
# PID suffix prevents collision when the same TASK_NAME lands within the same second.
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)-$$
RAW_TASK_NAME=$(cat <<'__TASK_NAME_BOUNDARY_9f21c6b4_TASK_NAME_END__'
{TASK_NAME}
__TASK_NAME_BOUNDARY_9f21c6b4_TASK_NAME_END__
)
TASK_NAME=$(printf '%s' "$RAW_TASK_NAME" | tr -cd '[:alnum:]._-' | head -c 64)
[ -z "$TASK_NAME" ] && TASK_NAME="task"
RAW_MODEL=$(cat <<'__MODEL_BOUNDARY_9f21c6b4_MODEL_END__'
{MODEL}
__MODEL_BOUNDARY_9f21c6b4_MODEL_END__
)
# REJECT, never rewrite. `tr -cd` is NOT "the same allow-list the config validator enforces":
# GROK_IDENT_RE anchors the first character, tr does not. `..` survives the filter intact and
# sends WORK_DIR to runs/grok/../<ts>-task — outside the tree verify-delegation.sh searches,
# so a run that genuinely happened scores FLIP; `-p` survives too. And a 70-char id that the
# config accepts is silently truncated to 64, after which the directory carries one string
# while `-m` below is handed another, leaving guard and watcher hunting a path that does not
# exist. Silent rewriting is the wrong tool for a value that is simultaneously a path
# component and a CLI argument: one string, or a hard stop.
[[ "$RAW_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [ -z "$RAW_MODEL" ] || {
    echo "STOP: MODEL must match [A-Za-z0-9][A-Za-z0-9._-]* (got '$RAW_MODEL')" >&2; exit 1; }
MODEL="$RAW_MODEL"
# Persist it so Step 2 reads the SAME string instead of re-expanding {MODEL} from the template
# unfiltered — that second, unchecked read is what let the path and the -m argument diverge.
# Mirrors the existing .task_name file.
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
# With a model: runs/grok/<model>/<ts>-<task>. Without: runs/grok/<ts>-<task>, one level up.
# The two never collide — verify-delegation.sh and watch-runs.sh only accept a run directory
# whose name matches ^[0-9]{4}(-[0-9]{2}){5}-, so a model directory is never read as a run.
WORK_DIR="$PLUGIN_DATA/runs/grok${MODEL:+/$MODEL}/${TIMESTAMP}-${TASK_NAME}"
mkdir -p "$WORK_DIR"
echo "$TASK_NAME" > "$WORK_DIR/.task_name"
# The validated model, so Step 2 uses the SAME string the path was built from.
printf '%s\n' "$MODEL" > "$WORK_DIR/.model"
# Stamp the dispatching session so watch-runs.sh and verify-delegation.sh can tell this run
# from one a concurrent orchestration started under the same engine/model in the same data dir.
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$WORK_DIR/.session_id"
cat > "$WORK_DIR/prompt.md" << '__PROMPT_BOUNDARY_9f21c6b4_PROMPT_END__'
{PROMPT_TEXT_HERE}
__PROMPT_BOUNDARY_9f21c6b4_PROMPT_END__
echo "WORK_DIR=$WORK_DIR"
```

- [ ] **Step 6: Write Step 2 — default execution**

```bash
# === EXECUTE THIS ENTIRE BLOCK AS ONE BASH CALL ===
set -euo pipefail
WORK_DIR="{WORK_DIR}"
# Read the model Step 1 validated and persisted. Do NOT re-expand {MODEL} here: that second,
# unchecked read is exactly how the directory name and the -m argument came apart.
MODEL=$(cat "$WORK_DIR/.model" 2>/dev/null || true)
EFFORT=$(cat <<'__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__'
{REASONING_EFFORT}
__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__
)
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")
PROMPT_FILE="$WORK_DIR/prompt.md"
RAW_FILE="$WORK_DIR/raw.jsonl"
# Resolve the effort from config when the caller left it empty. Gated on has_grok; a get-grok
# rc!=0 means a broken grok: section — STOP and surface it. config.yaml is user-owned: never
# edit it.
if [ -z "$EFFORT" ] && [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_grok 2>/dev/null)" = "1" ]; then
    EFFORT=$("$LOADER" get-grok) || { echo "STOP: config-loader get-grok failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }
fi
# NO fallback model and NO fallback effort: an unset value means "let ~/.grok/config.toml
# decide", which is the whole reason this skill differs from codex-exec and gemini-exec.
# if/then, not `test && cmd`: the second form is the SC2015 shape this codebase avoids, and
# under `set -e` its failing test is only saved by an exception in the manual.
GROK_ARGS=()
if [ -n "$MODEL" ];  then GROK_ARGS+=(-m "$MODEL"); fi
if [ -n "$EFFORT" ]; then GROK_ARGS+=(--effort "$EFFORT"); fi
echo "=== Grok Exec ==="
echo "Work dir: $WORK_DIR"
echo "Model: ${MODEL:-<CLI default>} | Effort: ${EFFORT:-<CLI default>}"
echo ""

# raw.jsonl is written UNPREFIXED — extract-result.py parses it line by line as JSON, so a
# timestamp prefix (which codex-exec and gemini-exec add to their log.jsonl) would break it.
PIPELINE_RC=0
{ timeout 1800 grok \
    --prompt-file "$PROMPT_FILE" \
    --output-format streaming-messages-json \
    --permission-mode bypassPermissions \
    --no-plan \
    ${GROK_ARGS[@]+"${GROK_ARGS[@]}"} 2>"$WORK_DIR/stderr.txt" | while IFS= read -r line; do
    printf '%s\n' "$line" >> "$RAW_FILE"
    TYPE=$(printf '%s' "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$TYPE" in
        system) echo ":: Session started" ;;
        assistant)
            # `[ -n "$X" ] && echo` is the SC2015 shape this project avoids: as the LAST
            # command of a loop body it makes the whole loop exit 1 whenever the string is
            # empty — i.e. on a perfectly healthy run whose final message called no tool.
            TOOLS=$(printf '%s' "$line" | jq -r '[.message.content[]? | select(.type=="tool_use") | .name] | join(", ")' 2>/dev/null)
            if [ -n "$TOOLS" ]; then echo ":: Tools: $TOOLS"; fi
            ;;
        result) echo ":: Completed" ;;
    esac
done ; } || PIPELINE_RC=$?

# Extraction and report generation run UNCONDITIONALLY, so a crash still leaves whatever the
# stream carried — including an {"type":"error"} event, which extract-result.py surfaces as
# "API Error: <msg>" in output.txt — but ONLY after the Step 0 fix below; today the extractor
# reads the NESTED .error.message while grok emits a TOP-LEVEL .message, so an error-only
# stream renders the literal "API Error: {}" and the text is lost (that is the shape an
# unknown model produces: the CLI prints
# the error on stdout AND stderr and exits 1).
python3 "$SKILL_BASE/../shared/extract-result.py" "$WORK_DIR" || echo "WARN: extract-result.py failed" >&2
{ [ -s "$RAW_FILE" ] && "$SKILL_BASE/../shared/stream-json-report.sh" "$RAW_FILE" "$WORK_DIR/report.md" "grok" "Grok Execution Report" "$TASK_NAME" \
    || echo "WARN: report generation skipped or failed — report.md may be missing" >&2 ; } || true

# The stream is the evidence. A run with events but no terminal result event is a torn stream;
# a run with no output at all is a failed launch. Both must be loud rather than empty.
# jq, not grep: the substring "type":"result" also occurs inside tool_result payloads and any
# assistant text quoting it, so grep answers "there was a terminal event" for a stream that has
# none. This is the check design §2 offers against a wire-format change — it must not be
# satisfiable by prose. Same idiom verify-delegation.sh uses.
if [ -s "$RAW_FILE" ] && ! jq -Rr 'fromjson? | objects | select(.type=="result")' "$RAW_FILE" \
     2>/dev/null | grep -q .; then
  echo "WARN: no terminal result event in raw.jsonl — the run was cut off, or the CLI changed its wire format" >&2
fi
if [ ! -s "$WORK_DIR/output.txt" ]; then
  echo "ERROR: output.txt is empty" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  [ -s "$RAW_FILE" ] && { echo "--- raw.jsonl tail ---" >&2; tail -5 "$RAW_FILE" >&2; }
  exit 4
fi
if [ "$PIPELINE_RC" -ne 0 ]; then
  echo "WARN: grok pipeline exited rc=$PIPELINE_RC" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  exit "$PIPELINE_RC"
fi

echo ""
echo "=== FILES ==="
ls -la "$WORK_DIR"
echo ""
echo "=== OUTPUT ==="
cat "$WORK_DIR/output.txt"
```

- [ ] **Step 7: Write Step 2 — supervised execution**

Keep gemini-exec's surrounding prose about why the launch must be a **background** Bash call
(`run_in_background: true`) verbatim — it is about the harness, not the engine — and replace
its fence with:

```bash
set -euo pipefail && \
command -v jq >/dev/null 2>&1 || { echo "supervised mode requires jq" >&2; exit 64; } && \
WORK_DIR="{WORK_DIR}" && \
SKILL_BASE="<absolute base dir Claude Code prints at skill load>" && \
WATCHDOG="$SKILL_BASE/../shared/watchdog.sh" && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
MODEL=$(cat "$WORK_DIR/.model" 2>/dev/null || true) && \
EFFORT=$(cat <<'__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__'
{REASONING_EFFORT}
__EFFORT_BOUNDARY_9f21c6b4_EFFORT_END__
) && \
{ [ -n "$EFFORT" ] || { \
    if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_grok 2>/dev/null)" = "1" ]; then \
      EFFORT=$("$LOADER" get-grok) || { echo "STOP: config-loader get-grok failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }; \
    fi; }; } && \
GROK_ARGS=() && \
{ [ -z "$MODEL" ] || GROK_ARGS+=(-m "$MODEL"); } && \
{ [ -z "$EFFORT" ] || GROK_ARGS+=(--effort "$EFFORT"); } && \
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR") && \
PROMPT_FILE="$WORK_DIR/prompt.md" && \
echo "=== Grok Exec (supervised: shell watchdog) ===" && \
echo "Work dir: $WORK_DIR" && \
echo "Model: ${MODEL:-<CLI default>} | Effort: ${EFFORT:-<CLI default>}" && \
echo "" && \
WATCHDOG_RC=0 && { \
    WORK_DIR="$WORK_DIR" \
      MAX_RETRIES=2 \
      HARD_ZERO_TIMEOUT=600 \
      GLOBAL_TIMEOUT=3600 \
      STREAM_FILE_NAME=raw.jsonl \
      "$WATCHDOG" -- \
        # No stdbuf: the grok binary is statically linked (`file $(command -v grok)` says so),
        # and stdbuf works by preloading libstdbuf into a dynamic loader that is not there —
        # it would be a silent no-op. It is not needed either: the stream was measured
        # reaching a redirected file unbuffered (5 KB -> 50 KB over 30 s). Keep this comment;
        # without it the next reader "restores parity" with codex/gemini and reintroduces it.
        timeout 1800 grok \
          --prompt-file "$PROMPT_FILE" \
          --output-format streaming-messages-json \
          --permission-mode bypassPermissions \
          --no-plan \
          ${GROK_ARGS[@]+"${GROK_ARGS[@]}"} \
    || WATCHDOG_RC=$?; \
} && \
echo "" && \
echo "=== WATCHDOG RESULT (rc=$WATCHDOG_RC) ===" && \
if [ "$WATCHDOG_RC" = "0" ]; then \
  FINAL="$WORK_DIR/final" && \
  python3 "$SKILL_BASE/../shared/extract-result.py" "$FINAL" && \
  cp -f "$FINAL/raw.jsonl" "$WORK_DIR/raw.jsonl" && \
  cp -f "$FINAL/output.txt" "$WORK_DIR/output.txt" && \
  { "$SKILL_BASE/../shared/stream-json-report.sh" "$FINAL/raw.jsonl" "$FINAL/report.md" "grok" "Grok Execution Report" "$TASK_NAME" || true; } && \
  { [ ! -f "$FINAL/report.md" ] || cp -f "$FINAL/report.md" "$WORK_DIR/report.md" || true; } && \
  echo "=== FILES ===" && ls -la "$WORK_DIR" && \
  echo "=== OUTPUT ===" && cat "$WORK_DIR/output.txt"; \
elif [ "$WATCHDOG_RC" = "2" ]; then \
  echo "## Review Diagnostics" && \
  jq -r '"- Attempts: \(.attempts)\n- Reason: \(.reason)\n- Elapsed: \(.elapsed_sec)s\n- Last attempt: \(.last_attempt_dir)"' "$WORK_DIR/watchdog.exit" 2>/dev/null || cat "$WORK_DIR/watchdog.exit" && \
  echo "" && echo "=== PER-ATTEMPT TAILS ===" && \
  for a in "$WORK_DIR"/attempt-*; do \
    [ -d "$a" ] || continue; \
    echo "-- $a --"; tail -20 "$a/raw.jsonl" 2>/dev/null || true; \
    [ -s "$a/stderr.txt" ] && { echo "-- $a/stderr --"; tail -20 "$a/stderr.txt" || true; }; \
    echo ""; \
  done; \
  exit 2; \
else \
  echo "Watchdog internal error (exit $WATCHDOG_RC)" && exit "$WATCHDOG_RC"; \
fi
```

Note there is **no `STDIN_FILE`**: the prompt reaches grok through `--prompt-file`, and
`watchdog.sh` treats `STDIN_FILE` as optional (`watchdog.sh:58`).

- [ ] **Step 8: Write the options table**

Replace "## Options Explained" with:

```markdown
| Flag | Purpose |
|------|---------|
| `--prompt-file <path>` | Single-turn prompt read from disk — no stdin plumbing, so the watchdog runs without `STDIN_FILE` |
| `--output-format streaming-messages-json` | NDJSON in the Anthropic Messages wire format — the same shape `claude -p --output-format stream-json` emits, which is why `shared/extract-result.py` and `shared/stream-json-report.sh` consume it unchanged |
| `--permission-mode bypassPermissions` | Approves tool use AND lets the run read outside its working directory. `--always-approve` covers only the first half; a reviewer confined to its cwd reviews on incomplete context and still finalizes cleanly, which is the failure `verify-delegation.sh` scores DEGRADED |
| `--no-plan` | Prevents grok from entering plan mode and answering with a plan instead of doing the work |
| `-m <model>` | Only when the caller named one — otherwise `~/.grok/config.toml` decides |
| `--effort <level>` | Caller value, else `grok.reasoning_effort` from config, else the CLI default |
| `timeout 1800` | 30-minute cap per attempt |
```

- [ ] **Step 9: Write the executor agent**

```bash
cd /opt/github/zinin/claude-mesh
cat > agents/grok-executor.md << 'AGENT_EOF'
---
name: grok-executor
description: |
  Execute any prompt via the xAI Grok CLI. Use when you need to delegate tasks to Grok,
  get a "second opinion" from a different model, or run analysis through an external agent.
  Requires MODEL parameter.
color: purple
---

You are an agent that executes prompts via the xAI Grok CLI.

## CRITICAL: You MUST Use the Skill Tool

**YOUR FIRST ACTION must be to invoke the `grok-exec` skill using the Skill tool.**

Do NOT run grok commands directly. Do NOT create your own logging structure.
The skill handles everything: file paths, logging format, progress display.

```
Skill tool -> skill: "claude-mesh:grok-exec"
```

Then follow ALL steps in the skill exactly as written.

## CRITICAL: Required Parameter (MODEL)

**MODEL is REQUIRED on the first line of the prompt.** Format: `MODEL=<grok model id>` — a
single id from the `grok.models` catalog (e.g. `MODEL=grok-4.6`), NOT the
`<provider>/<short>` pair the ext-claude agents take.

Pass MODEL through to the skill as its `MODEL` parameter. If the caller did not provide it,
STOP and return:

```
ERROR: MODEL parameter is required on first line.
Example: MODEL=grok-4.6 Analyse the failing test and report the cause
```

Do NOT substitute a model of your own. The catalog is in the user's config; a model this
session invents is a model nobody chose.

## Input Parameters

- **PROMPT** (required) — the full prompt text to execute
- **MODEL** (required) — see above
- **TASK_NAME** — short identifier for log files (default: "task")
- **REASONING_EFFORT** — `low` | `medium` | `high` | `xhigh`. Omit it and the skill resolves
  `grok.reasoning_effort` from config, then the CLI's own default. Pass one ONLY when the
  caller explicitly asked for it — do NOT choose a level yourself.
- **SUPERVISED_MODE** — `none` (default) or `shell`. Forward it as a named parameter; it is
  NOT part of `PROMPT`. `shell` wraps the run in `shared/watchdog.sh`, which restarts the CLI
  on a stall and writes a `watchdog.log` the caller can watch for liveness.
  - **Under `shell`, launch the skill's supervised block as a BACKGROUND Bash task
    (`run_in_background: true`) and never wait for it in the foreground.** The harness caps a
    foreground call at `BASH_MAX_TIMEOUT_MS` — ten minutes out of the box — and SIGTERMs it at
    the cap, taking the whole process group with it; the watchdog then records `exit_code: 143`
    and the run is lost. Every budget it supervises (1800s per attempt, 3600s overall) sits
    above that cap. Launch, report the work dir, end your turn, and read
    `$WORK_DIR/output.txt` / `report.md` when the orchestrator pings you.
  - If the run dies, report the death — do **not** relaunch it yourself. A second run dir
    nobody is tracking breaks attribution: `watch-runs.sh` follows the newest dir, so the
    orchestrator starts watching a run it never asked for.

## Process

1. **IMMEDIATELY** invoke the `grok-exec` skill via Skill tool
2. Follow every step in the skill (pre-flight, save prompt, execute, generate report)
3. Return file paths and output as specified by the skill

## Output

You will return:
- Work directory path: `${CLAUDE_PLUGIN_DATA}/runs/grok/<model>/YYYY-MM-DD-HH-MM-SS-taskname/`
- Files inside: `prompt.md`, `raw.jsonl`, `raw.json`, `output.txt`, `report.md`
- The final output content from Grok

## WARNING

If you run grok directly without invoking the skill, you are doing it WRONG.
The skill ensures consistent file structure and logging format.
AGENT_EOF
head -8 agents/grok-executor.md
```

- [ ] **Step 9b: Bring the supervised block to ext-claude parity — four gaps**

Review always runs `SUPERVISED_MODE=shell` (Task 7 Step 5), so the supervised branch is the
production path and the default branch is the one used by hand. Every safeguard below exists in
`skills/ext-claude-exec/SKILL.md` or in this file's own default branch, and is missing from the
supervised one:

1. **Call the extractor tolerantly.** ext-claude uses
   `python3 extract-result.py "$FINAL" || { echo "WARN: extract-result.py rc=$?" >&2; }`. As a
   link in an `&&` chain instead, rc=3 ("raw.jsonl exists but nothing parses") aborts the block
   before the report is written — and rc=3 is exactly the shape "xAI changed the wire format"
   takes, the risk design §2 names. Aborting there destroys the evidence for it.
2. **Empty-output guard.** The default branch prints stderr plus the stream tail and exits 4
   when `output.txt` is empty while `raw.jsonl` is not. Supervised has nothing, so it leaves a
   silent empty file.
3. **Copy `stderr.txt` and `raw.json` to the run root**, as ext-claude does
   (`for f in raw.jsonl stderr.txt; do …`). Design §2 and this task's own Interfaces list both
   at the root; today supervised leaves them only under `final/`.
4. **Move the terminal-result check into a tail both branches run.** It currently lives only in
   the default branch, so the check design §2 offers as the answer to a wire-format change
   never executes on the path every review takes.


- [ ] **Step 10: Write the opt-in smoke test**

```bash
cd /opt/github/zinin/claude-mesh
cat > skills/shared/tests/test-grok-exec-smoke.sh << 'SMOKE_EOF'
#!/usr/bin/env bash
# Live smoke test for the grok invocation grok-exec/SKILL.md prescribes.
#
# OPT-IN: it spends real API budget, so it runs only with GROK_SMOKE=1 and skips otherwise.
# What it pins is the CONTRACT the rest of the plugin is built on — that the flags in SKILL.md
# are accepted, that the stream is the Anthropic wire format, and that extract-result.py can
# read it. Nothing here asserts what the model SAYS.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$TESTS_DIR/.."

if [ "${GROK_SMOKE:-0}" != "1" ]; then
    echo "SKIP: set GROK_SMOKE=1 to run the live grok smoke test (it spends API budget)"
    exit 0
fi
for REQ in grok jq python3; do
    # A missing grok binary is "the user did not opt in" -> SKIP. A missing jq or python3 is a
    # broken environment, and reporting that as SKIP hides it: the suite would look clean on a
    # machine where nothing could have run.
    command -v "$REQ" >/dev/null 2>&1 || { echo "FAIL: $REQ not installed — this is an environment defect, not an opt-out"; exit 1; }
done

FAIL=0
PASS=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf 'alpha\n' > "$WORK/a.txt"
cat > "$WORK/prompt.md" << 'PROMPT'
List the files in your working directory using your tools, then reply with their names.
PROMPT

( cd "$WORK" && timeout 300 grok \
    --prompt-file "$WORK/prompt.md" \
    --output-format streaming-messages-json \
    --permission-mode bypassPermissions \
    --no-plan \
    > "$WORK/raw.jsonl" 2> "$WORK/stderr.txt" )
RC=$?
[ "$RC" = 0 ] && ok "grok accepts the SKILL.md flag set (rc=0)" || bad "grok exited rc=$RC — $(head -2 "$WORK/stderr.txt")"

grep -q '"type":"system"' "$WORK/raw.jsonl" && ok "stream opens with a system event" || bad "no system event in the stream"
jq -Rr 'fromjson? | objects | select(.type=="result")' "$WORK/raw.jsonl" 2>/dev/null | grep -q . && ok "stream carries a terminal result event" || bad "no result event — verify-delegation would score this STALLED"

NT="$(grep '"type":"result"' "$WORK/raw.jsonl" | jq -Rr 'fromjson? | objects | select(.type=="result" and .is_error==false) | .num_turns' | sort -n | tail -1)"
case "$NT" in
    ''|*[!0-9]*) bad "result event carries no integer num_turns (got '$NT') — the guard needs it" ;;
    *) [ "$NT" -gt 1 ] && ok "num_turns=$NT proves agentic work" || bad "num_turns=$NT — the model used no tools" ;;
esac

grep -q '"type":"tool_use"' "$WORK/raw.jsonl" && ok "tool_use blocks are present" || bad "no tool_use block in the stream"

python3 "$SHARED/extract-result.py" "$WORK" >/dev/null 2>&1 \
    && [ -s "$WORK/output.txt" ] \
    && ok "extract-result.py reads the grok stream into output.txt" \
    || bad "extract-result.py produced no output.txt"

bash "$SHARED/stream-json-report.sh" "$WORK/raw.jsonl" "$WORK/report.md" grok "Grok Execution Report" smoke >/dev/null 2>&1 \
    && [ -s "$WORK/report.md" ] \
    && ok "stream-json-report.sh renders a report" \
    || bad "no report.md rendered"

# The whole stall-detection design rests on this: the file must grow while the run is live.
echo ""
# A single final size proves nothing about buffering — a fully buffered stream also ends up
# large. Stall detection rests on the file GROWING while the run is live, so sample twice.
SZ1=$(wc -c < "$WORK/raw.jsonl"); sleep 5; SZ2=$(wc -c < "$WORK/raw.jsonl")
[ "$SZ2" -gt "$SZ1" ] && ok "stream grows while the run is live ($SZ1 -> $SZ2 bytes)" \
    || echo "  NOTE: no growth between samples — either the run had already finished, or the stream is buffered; re-run against a longer prompt before trusting stall detection"
echo "  (stream size: $(wc -c < "$WORK/raw.jsonl") bytes, $(wc -l < "$WORK/raw.jsonl") events)"
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
SMOKE_EOF
chmod +x skills/shared/tests/test-grok-exec-smoke.sh
bash skills/shared/tests/test-grok-exec-smoke.sh
```

Expected without the flag: the SKIP line, exit 0.

- [ ] **Step 11: Run the smoke test for real**

Run: `GROK_SMOKE=1 bash skills/shared/tests/test-grok-exec-smoke.sh`
Expected: `0 failed`, and a stream-size line. This is also the spec's third pre-check — record
the byte count in the commit message so a later reader knows how fast the stream grows.

- [ ] **Step 12: Commit**

```bash
git add skills/grok-exec agents/grok-executor.md skills/shared/tests/test-grok-exec-smoke.sh
git commit -m "feat(grok): grok-exec skill and executor agent"
```

---

### Task 7: The `grok-code-review` skill and reviewer agent

**Files:**
- Create: `skills/grok-code-review/SKILL.md`, `agents/grok-code-reviewer.md`
- Reference while writing: `skills/gemini-code-review/SKILL.md`

**Interfaces:**
- Consumes: `shared/code-review-prompt.md`, `shared/render-template.py`, the `grok-exec` skill (Task 6).
- Produces: a review run under `runs/grok/<model>/<timestamp>-review-<branch>/`, whose `output.txt` is the review.

- [ ] **Step 1: Scaffold from the sibling**

```bash
cd /opt/github/zinin/claude-mesh
mkdir -p skills/grok-code-review
cp skills/gemini-code-review/SKILL.md skills/grok-code-review/SKILL.md
```

Keep, with `gemini`→`grok` wording applied: frontmatter, "Locating plugin files", "CRITICAL:
Tool Execution Rules", "When to Use", Step 1 (git context) and Step 2 (description and plan)
**verbatim** — they are engine-independent. Steps 2-4 below replace the rest.

- [ ] **Step 2: Write the frontmatter and the MODEL contract**

````markdown
---
name: grok-code-review
description: Send code for external review to the xAI Grok CLI for cross-validation
user_invocable: true
---

# Grok Code Review

Dispatch code review to xAI Grok as an external reviewer process.

**Announce at start:** "Using grok-code-review skill to get external review from Grok."

## Required argument: MODEL

`MODEL=<grok model id>` — one entry of the `grok.models` catalog, e.g. `MODEL=grok-4.6`.
Without it, STOP and report:

```
ERROR: MODEL is required. Example: MODEL=grok-4.6 Review the changes for production readiness
```

Never pick a model yourself: the catalog belongs to the user's config, and an invented id
fails at the CLI with `unknown model id` after a run directory has already been created.
`config-loader.sh list-grok-models` prints the catalog when you need to show the caller what
is available.
````

- [ ] **Step 3: Write the pre-flight fence**

```bash
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
command -v grok >/dev/null 2>&1 || { echo "STOP: grok CLI not found — install Grok Build and run 'grok login'"; exit 1; }
echo "OK: grok found"
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found - required by shared/render-template.py (Step 3)"; exit 1; }
echo "OK: python3 found"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "STOP: Not a git repository"; exit 1; }
echo "OK: git repo"
# Hard gate here, unlike grok-exec's soft one: a review names a model from the catalog, and
# there is no catalog without the section.
if [ ! -x "$LOADER" ] || [ "$("$LOADER" get-flag has_grok 2>/dev/null)" != "1" ]; then
    echo "STOP: no grok: section in config.yaml — add one with a models: catalog, or pick another reviewer"; exit 1
fi
GROK_CAT=$("$LOADER" list-grok-models) || { echo "STOP: grok: section is present but its catalog does not validate — fix config.yaml (user-owned; agents never edit it)" >&2; exit 1; }
echo "OK: grok: section present ($(printf '%s' "$GROK_CAT" | tr '\n' ' '))"
```

- [ ] **Step 4: Append the tooling constraint to the rendered prompt**

**This fence must be part of Step 3's block, not a new one.** A shell variable does not survive
from one Bash-tool call to the next — this repository says so in several places, and it is the
reason `$PROMPT_FILE` is re-derived rather than remembered. Opened as its own call, the
`cat >> "$PROMPT_FILE"` below expands to `cat >> ""` and the shipped skill fails with
`ambiguous redirect` on its first real use. So: append this to the SAME fence that runs
`render-template.py` in Process Step 3, after that call and before Step 4 hands the prompt to
`grok-exec`; and name Process Steps 3 and 5 explicitly in Step 1's keep-list so the scaffold
does not drop them.

```bash
# Grok loads the user's Claude Code plugins, so `claude-mesh:mesh-review` and every other
# skill on this machine is visible to it. Nothing stops it from "helpfully" launching one
# instead of reviewing — and a nested orchestration would write run dirs this session never
# dispatched. codex and gemini need no such line: they cannot see those skills at all.
cat >> "$PROMPT_FILE" << 'GROK_TOOLING_EOF'

## Tooling constraint

Do NOT invoke any skill or slash command, and do NOT delegate this review to another agent or
orchestration. Names like `claude-mesh:mesh-review` may be visible in your environment; they
are not part of this task. Read the code with your own file, search and shell tools, and
answer with the review itself.
GROK_TOOLING_EOF
echo "PROMPT_FILE=$PROMPT_FILE"
tail -12 "$PROMPT_FILE"
```

- [ ] **Step 5: Write the delegation step**

Replace "### Step 4: Execute via gemini-exec Skill" with:

````markdown
### Step 4: Execute via grok-exec Skill

**Use the Skill tool** to invoke the `grok-exec` skill. Do NOT read the skill file manually:

```
Skill tool -> skill: "claude-mesh:grok-exec"
```

Pass these parameters:

```
PROMPT=<formatted prompt from Step 3, including the tooling constraint>
TASK_NAME="review-${BRANCH}"
MODEL=<the MODEL argument this skill was called with>
SUPERVISED_MODE=shell
```

**Model:** always pass it through — this skill refuses to run without one, so there is
nothing to resolve. Do NOT pass `REASONING_EFFORT` unless the caller explicitly named one;
`grok-exec` reads `grok.reasoning_effort` from config by itself.

The run lands in `${CLAUDE_PLUGIN_DATA}/runs/grok/<model>/{timestamp}-review-{branch}/`:

```
├── prompt.md       # The review prompt
├── raw.jsonl       # Anthropic-wire-format stream events from the final attempt
├── raw.json        # The same events as one JSON array
├── output.txt      # The review itself — this is what the caller reads
├── report.md       # Human-readable render of the whole run
├── watchdog.log    # Watchdog supervision log
```
````

- [ ] **Step 6: Write the reviewer agent**

```bash
cd /opt/github/zinin/claude-mesh
cat > agents/grok-code-reviewer.md << 'AGENT_EOF'
---
name: grok-code-reviewer
description: |
  Use this agent in parallel with superpowers:requesting-code-review when a major project step
  has been completed. Provides external code review via the xAI Grok CLI for cross-validation.
  Requires MODEL parameter.
color: purple
---

You are an external code reviewer that delegates review to xAI Grok. You are a WRAPPER, not a
reviewer.

## CRITICAL: You MUST Use the Skill Tool

**YOUR FIRST ACTION must be to invoke the `grok-code-review` skill using the Skill tool.**

```
Skill tool -> skill: "claude-mesh:grok-code-review"
```

Then follow ALL steps in the skill exactly as written. The skill resolves the diff, builds the
review prompt, runs the grok CLI against the named model, and returns the findings.

## CRITICAL: Required Parameter (MODEL)

**MODEL is REQUIRED on the first line of the prompt.** Format: `MODEL=<grok model id>` (e.g.
`MODEL=grok-4.6`) — a single catalog entry, NOT the `<provider>/<short>` pair the ext-claude
agents take.

Pass MODEL through to the skill as its first argument. If the caller ALSO inlined review
context (scope, diff, project invariants, focus areas), forward it to the skill as its
`CONTEXT` argument — do **NOT** treat that context as a review task to perform yourself.

If the caller did not provide MODEL on the first line, STOP and return:

```
ERROR: MODEL parameter is required on first line.
Example: MODEL=grok-4.6 Review the changes for production readiness
```

## PROHIBITIONS

- Do NOT read SKILL.md and follow steps manually — use the Skill tool
- Do NOT perform the code review yourself — you are a WRAPPER, not a reviewer
- Do NOT fall back to manual review if the Skill tool call fails
- Do NOT run grok commands directly — the skill chain handles execution
- Do NOT choose a model — the caller names one from the user's catalog

## On Failure

If the Skill tool call fails or any step in the chain fails → **STOP and return the error**.
Do NOT attempt to review the code yourself. The entire point of this agent is to get a review
from a **different model** (xAI Grok), not from Claude.

## Verification

Before returning, confirm the run directory exists under
`${CLAUDE_PLUGIN_DATA}/runs/grok/<model>/` and name it in your report. A review with no run
directory did not happen — the orchestrator's delegation guard checks exactly that and scores
a missing directory FLIP.
AGENT_EOF
head -8 agents/grok-code-reviewer.md
```

- [ ] **Step 7: Verify both agents parse as plugin components**

```bash
cd /opt/github/zinin/claude-mesh
for f in agents/grok-executor.md agents/grok-code-reviewer.md; do
    head -1 "$f" | grep -qx -- '---' && echo "OK frontmatter opens: $f" || echo "BROKEN: $f"
    grep -qE '^name: grok-' "$f" && echo "OK name field: $f" || echo "BROKEN name: $f"
done
ls skills/grok-exec/SKILL.md skills/grok-code-review/SKILL.md
```

- [ ] **Step 8: Commit**

```bash
git add skills/grok-code-review agents/grok-code-reviewer.md
git commit -m "feat(grok): grok-code-review skill and reviewer agent"
```

---

### Task 8: `grok` in the delegation guard

**Files:**
- Modify: `skills/shared/verify-delegation.sh` (header comment, usage, path resolver, classification branch, two message texts)
- Test: `skills/shared/tests/test-verify-delegation.sh` (new grok section)

**Interfaces:**
- Consumes: run directories from Task 6.
- Produces: `verify-delegation.sh grok <model> <since-epoch> [data-dir]` — verdicts REAL=0, STALLED=2, FLIP=3, BROKEN=4, DEGRADED=5, KILLED=6, identical in meaning to the ext-claude ones.

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-verify-delegation.sh`, before the summary block:

```bash
# === grok: the engine shares ext-claude's classification, because it shares its stream format ===
# grok --output-format streaming-messages-json emits the Claude Code wire format verbatim, so
# every signal the ext-claude branch reads — is_error, num_turns, permission_denials — is on
# disk here too. These tests exist to keep the two wired together: a future edit that splits
# the branch must keep grok scoring the same way.
echo "=== Test: grok FLIP (no run dir) ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/runs/grok/grok-4.6"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok REAL (num_turns 12, real review) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-review)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12}' > "$rd/raw.jsonl"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok BROKEN (num_turns 1 — answered without reading code) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-lazy)
mk_output "$rd/output.txt" 'Looks fine to me.'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok STALLED (torn stream, no result event) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.5" 2026-08-28-11-00-00-1000-torn)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/raw.jsonl"
run grok grok-4.5 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# Design §5 promises grok coverage for REAL, STALLED, BROKEN, FLIP, DEGRADED **and KILLED**;
# KILLED and the engine-specific STALLED floor note are the two the first draft omitted.
echo "=== Test: grok KILLED (watchdog cleanup 143, no watchdog.exit) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-30-00-1000-killed)
printf '%s\n' '{"ts":"2026-08-28T11:40:00+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}' > "$rd/watchdog.log"
: > "$rd/output.txt"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok STALLED floor note is grok's, not ext-claude's archive number ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-45-00-1000-short)
mk_output "$rd/output.txt" 'ok'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":4}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
# "the shortest genuine review in the archive is 460" is a measured ext-claude fact; quoting it
# for grok would cite evidence that does not exist for this engine.
assert_no_match "no ext-claude archive number" "archive" "$REASON"
assert_match "names the floor itself" "400 non-space" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok DEGRADED (denials on an otherwise real review) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-denied)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"permission_denials":[{"tool_name":"Read"},{"tool_name":"Bash"}]}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "exit 5" "5" "$RC"
assert_eq "counts both denials" "2" "$(reason_count)"
# The ext-claude remedy prescribes a flag grok already passes — saying it here would send the
# reader after a setting that is not the cause.
assert_no_match "does not prescribe the ext-claude remedy" "the ext-claude run needs" "$REASON"
# assert_no_match alone would also pass on an EMPTY or generic reason, so pin the grok text too:
# the branch must say something true about grok, not merely avoid saying something false.
assert_match "names the grok remedy" "grok-exec already passes" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok requires a model argument ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/grok"
run grok - 1 "$TDIR"
assert_eq "exit 1 (usage error, no verdict)" "1" "$RC"
assert_eq "no verdict printed" "" "$VERDICT"
rm -rf "$TDIR"
```

- [ ] **Step 2: Run to watch them fail**

Run: `bash skills/shared/tests/test-verify-delegation.sh 2>&1 | grep -B1 -A3 'grok'`
Expected: every grok case fails — the script exits 1 with `unknown engine 'grok'`.

- [ ] **Step 3: Implement the path resolver**

In `skills/shared/verify-delegation.sh`, replace the engine `case` (around line 123):

```bash
case "$ENGINE" in
    ext-claude) BASE="$DATA_DIR/runs/ext-claude/$MODEL" ;;
    # A model is MANDATORY for grok, and '-' is not one: the run dirs live under
    # runs/grok/<model>/, so a missing argument would resolve to runs/grok/- and report FLIP
    # about a directory nothing ever writes. Usage error, exit 1, no verdict — the shape both
    # orchestrators read as "fix the call", not as a verdict about the reviewer.
    grok)
        case "$MODEL" in
            ''|'-') echo "verify-delegation: engine grok requires a model argument (e.g. grok-4.6), got '${MODEL:-}'" >&2; exit 1 ;;
        esac
        BASE="$DATA_DIR/runs/grok/$MODEL" ;;
    codex)      BASE="$DATA_DIR/runs/codex" ;;
    gemini)     BASE="$DATA_DIR/runs/gemini" ;;
    *) echo "verify-delegation: unknown engine '$ENGINE'" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: Share the classification branch and split the two engine-specific texts**

Change the branch head from `ext-claude)` to:

```bash
    ext-claude|grok)
        # Two more strings in this branch are ext-claude-specific besides the archive floor and
        # the DEGRADED remedy: sweep the whole branch for engine-specific wording rather than
        # patching the two the design names, and either move each into `case "$ENGINE"` or
        # rephrase it so it is true for both engines.
```

Inside it, the two message texts that are true only of ext-claude become engine-aware. Above
the `OUT_BYTES` check, add:

```bash
        # The floor is one number for both engines; the sentence that explains it is not.
        # ext-claude's cites its own archive (336 runs); grok has no archive yet, and quoting
        # one would be a measurement nobody made.
        case "$ENGINE" in
            grok) FLOOR_NOTE="the floor is $MIN_REVIEW_BYTES non-space bytes" ;;
            *)    FLOOR_NOTE="the shortest genuine review in the archive is 460" ;;
        esac
```

and use it in the message:

```bash
            fail STALLED "num_turns=$NT but output.txt holds only $OUT_BYTES non-space bytes — the run worked and then delivered a notice, not a review ($FLOOR_NOTE)" 2
```

Then, in the `permission_denials` branch, replace the single remedy sentence with a per-engine one:

```bash
            case "$ENGINE" in
                grok) DENIAL_REMEDY="grok-exec already passes --permission-mode bypassPermissions, so this is not the missing-flag case: the CLI refused for a reason of its own (a sandbox profile, or a deny rule in ~/.grok). Keep the findings; do NOT re-dispatch, and check the CLI's own permission configuration" ;;
                *)    DENIAL_REMEDY="Keep the findings; do NOT re-dispatch, an identical invocation is refused identically. The remedy is the user's, not an agent's: the ext-claude run needs --permission-mode bypassPermissions, and an installed plugin only picks that up through a release" ;;
            esac
            emit DEGRADED "num_turns=$NT but the CLI refused $DENIED tool call(s) ($BREAKDOWN) — the reviewer was confined to its working directory and reviewed on incomplete context. $DENIAL_REMEDY" 5
```

- [ ] **Step 5: Update the header comment and the usage line**

At the top of the file, the engine list appears twice — in the prose block and in the usage
string. Make both read `ext-claude | codex | gemini | grok`, and extend the model line to:

```bash
#     model       for ext-claude: "<provider>/<short>" (e.g. zai/glm); for grok: the model id
#                 (e.g. grok-4.6); "-" for codex/gemini
```

Also update the `usage:` echo in the argument check:

```bash
    echo "usage: verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]" >&2
```

stays as it is — only the comment block enumerates engines.

- [ ] **Step 6: Run the tests**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-verify-delegation.sh > /tmp/test-verify-delegation.txt 2>&1; RC=$?
tail -3 /tmp/test-verify-delegation.txt; echo "rc=$RC"
```

Expected: `0 failed`, including every pre-existing ext-claude, codex and gemini case.

- [ ] **Step 7: Commit**

```bash
git add skills/shared/verify-delegation.sh skills/shared/tests/test-verify-delegation.sh
git commit -m "feat(verify): score grok runs through the shared stream-json branch"
```

---

### Task 9: `grok` in the run watcher

`watch-runs.sh` needs no logic change — its roster pattern already accepts `grok/grok-4.6`,
and freshness already reads `raw.jsonl`, `attempt-*/raw.jsonl` and `watchdog.log`. This task
proves that with tests and fixes the one comment that would now be wrong.

**Files:**
- Modify: `skills/shared/watch-runs.sh` (the `HARD_ZERO_TIMEOUT` comment, ~line 143)
- Test: `skills/shared/tests/test-watch-runs.sh` (new cases)

**Interfaces:**
- Consumes: run directories from Task 6.
- Produces: nothing new — `grok/<model>` is simply a valid roster entry.

- [ ] **Step 1: Write the tests**

Append to `skills/shared/tests/test-watch-runs.sh`, before its summary block:

```bash
echo ""
echo "Test 40: a grok roster entry follows runs/grok/<model>/"
TDIR="$(mktemp -d)"
A="$(mk_run "$TDIR" grok/grok-4.6)"
wd_log "$A" 0; printf 'findings\n' > "$A/output.txt"
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" grok/grok-4.6
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_match "grok row is DONE" "DONE" "$(row grok/grok-4.6)"
rm -rf "$TDIR"

echo ""
echo "Test 41: two grok models are watched independently"
TDIR="$(mktemp -d)"
A="$(mk_run "$TDIR" grok/grok-4.6)"
wd_log "$A" 0; printf 'findings\n' > "$A/output.txt"
mk_run "$TDIR" grok/grok-4.5 >/dev/null
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" grok/grok-4.6 grok/grok-4.5
assert_match "4.6 is DONE" "DONE" "$(row grok/grok-4.6)"
assert_match "4.5 is still RUN" "RUN" "$(row grok/grok-4.5)"
rm -rf "$TDIR"
```

- [ ] **Step 2: Run them**

`test-watch-runs.sh` already contains tests numbered up to **39**, so 31/32 would be duplicates
— the numbers above are 40/41. Verify no number is used twice before running:

```bash
grep -o 'Test [0-9]\+' skills/shared/tests/test-watch-runs.sh | sort -V | uniq -d   # expect empty
bash skills/shared/tests/test-watch-runs.sh > /tmp/watch.txt 2>&1; RC=$?
grep -A4 'Test 40\|Test 41' /tmp/watch.txt; echo "rc=$RC"
```
Expected: they PASS immediately — the script is already engine-agnostic. If they fail, the
roster pattern or the freshness list regressed; fix that before continuing.

- [ ] **Step 3: Correct the stale comment**

The message at `watch-runs.sh:143` names only two exec skills as the owners of the 600-second
floor. Update it:

```bash
        echo "watch-runs: stall threshold $STALL_SEC raised to $STALL_FLOOR — codex-exec, gemini-exec and grok-exec hardcode HARD_ZERO_TIMEOUT=600, so a lower threshold would call a live run silent before its own watchdog acts" >&2
```

Check whether a test pins that string:

```bash
grep -n 'hardcode HARD_ZERO_TIMEOUT' skills/shared/tests/test-watch-runs.sh skills/shared/watch-runs.sh
```

If a test asserts the old wording, update the assertion in the same commit.

- [ ] **Step 4: Run the suite**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-watch-runs.sh > /tmp/test-watch-runs.txt 2>&1; RC=$?
tail -3 /tmp/test-watch-runs.txt; echo "rc=$RC"
```

Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git commit -m "test(watch): pin grok roster entries; name grok-exec in the stall floor note"
```

---

### Task 10: `grok` in the environment probe

**Files:**
- Modify: `skills/shared/preflight-env.sh` (`cli_row` gains an optional command probe; the `grok` gate, row and summary entries)
- Test: `skills/shared/tests/test-preflight-env.sh` (new grok cases)

**Interfaces:**
- Consumes: `get-flag has_grok`, `get-grok`, `list-grok-models` (Task 2).
- Produces: a `grok` row in the report, and `grok:<model>` entries on the `SUMMARY available:` line — spelled exactly as the two orchestrators spell them, so a reading session needs no mapping.

- [ ] **Step 0: Update the pinned row order — the suite fails without it**

`skills/shared/tests/test-preflight-env.sh:826-828` pins the report's row order as one literal
string, and the comment above it says why: it "catches a block appended in the wrong place".
The `grok` row prints **unconditionally** (as `grok MISSING` when there is no section, exactly
like codex and gemini), so this assertion goes red the moment Step 5 lands, and nothing else in
this task touches it. Insert `grok` between `gemini` and `provider:zai`, matching where Step 5
puts the row:

```bash
assert_eq "row order is the documented one" \
  "plugin yq jq config builtin-claude claude-models codex gemini grok provider:zai provider:ollama git-remote gh glab clipboard bash-timeout " \
  "$ORDER"
```

If Step 6 still reports a failure here, the row was added in the wrong place — fix the row's
position, not this string.

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-preflight-env.sh`, in the CLI-row section beside the codex
and gemini scenarios:

```bash
# --- grok ---------------------------------------------------------------------------------
# Unlike codex and gemini, grok's reachability is probed with the CLI itself: `grok models`
# answers only when the machine has network AND a live login, and the subscription path never
# touches the public api.x.ai an HTTP probe would have to guess at.
mkdir -p "$WORK/cli-grok"
cat > "$WORK/cli-grok/grok" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) [ "${GROK_SHIM_FAIL:-0}" = 1 ] && { echo "not logged in" >&2; exit 1; }
          printf 'You are logged in with grok.com.\n\nDefault model: grok-4.6\n' ;;
  *)      exit 0 ;;
esac
SH
chmod +x "$WORK/cli-grok/grok"

# No grok: section -> MISSING, and the reason says the UI will not offer it.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/cli-grok:$PATH"
assert_eq   "no grok section -> MISSING"    MISSING "$(field grok "$OUT")"
assert_match "and says why"                 "no grok: section" "$OUT"

# Section present, CLI present, `grok models` answers -> OK, and the catalog reaches the summary.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH"
assert_eq   "grok CLI + login -> OK"        OK "$(field grok "$OUT")"
assert_match "summary names each grok model" "grok:grok-4.6" "$OUT"
assert_match "…including the second one"     "grok:grok-4.5" "$OUT"

# The CLI is there but not logged in -> NO-NETWORK, and the hint names the fix.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH" GROK_SHIM_FAIL=1
assert_eq   "grok models fails -> NO-NETWORK" NO-NETWORK "$(field grok "$OUT")"
assert_match "…and suggests logging in"       "grok login" "$OUT"

# Section present, binary absent -> MISSING (the section gate passes, the CLI gate does not).
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli"
assert_eq   "grok binary absent -> MISSING"  MISSING "$(field grok "$OUT")"

# A malformed grok: section is INVALID before any CLI or network claim — same order as codex.
run_probe broken-grok-valid-codex.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq   "malformed grok section -> INVALID" INVALID "$(field grok "$OUT")"
assert_match "…with the validator's own reason" "grok.models" "$OUT"

# PREFLIGHT_SKIP_NETWORK must skip the command probe too, not run it silently.
run_probe valid-grok.yaml PREFLIGHT_SKIP_NETWORK=1 PATH="$WORK/cli-grok:$SHIM:$PATH"
assert_eq   "skip-network -> UNKNOWN"        UNKNOWN "$(field grok "$OUT")"
assert_match "…named as the flag's doing"    "skipped by PREFLIGHT_SKIP_NETWORK" "$OUT"
```

Add `grok` to the farm of deleted binaries so the "binary absent" case is real:

```bash
mkfarm "$WORK/nocli" codex gemini grok
```

- [ ] **Step 2: Run to watch them fail**

Run: `bash skills/shared/tests/test-preflight-env.sh 2>&1 | grep -c FAIL`
Expected: a non-zero count — there is no `grok` row at all yet, so `field grok` returns empty.

- [ ] **Step 3: Teach `cli_row` an optional command probe**

In `skills/shared/preflight-env.sh`, extend the signature comment and add the branch just
before the existing `if [ "$SKIP_NET" = 0 ] && [ "$HAVE_CURL" = 1 ]` announcement:

```bash
cli_row() {             # $1 = name, $2 = binary, $3 = probe url, $4 = has_section flag, $5 = probe command (optional)
                        # $5 is deliberately UNQUOTED at the call below: it must split into argv
                        # ("grok models" -> two words). That makes word splitting part of this
                        # function's public contract, so a caller may never pass a value
                        # carrying spaces-in-one-argument, and glob characters must be disabled
                        # around the expansion (`set -f` / `set +f`) or a probe like `foo *`
                        # would expand against the cwd.
```

```bash
    # An OPTIONAL command probe replaces the HTTP one for a CLI whose reachability an HTTP
    # request cannot answer. grok is the case: on a grok.com subscription the traffic goes
    # through a relay, not through the public api.x.ai, so a curl there would report on an
    # endpoint this CLI never calls — while `grok models` answers only with network AND a live
    # login, and prints nothing secret. Same degrade-toward-UNKNOWN discipline as probe_http:
    # the flag skips it, and only a clean exit is allowed to mean OK.
    if [ -n "${5:-}" ]; then
        if [ "$SKIP_NET" = 1 ]; then
            CLI_STATUS="UNKNOWN"
            row "$1" UNKNOWN "CLI present, skipped by PREFLIGHT_SKIP_NETWORK"
        elif ! command -v timeout >/dev/null 2>&1; then
            CLI_STATUS="UNKNOWN"
            row "$1" UNKNOWN "CLI present, no timeout(1) — \`$5\` not run (brew install coreutils)"
        else
            echo "probing $1 (\`$5\`)…" >&2
            set -f                                   # see the contract note on $5 above
            timeout "$HTTP_TIMEOUT" $5 >/dev/null 2>&1; PROBE_RC=$?
            set +f                                   # restored on BOTH paths, before any branch
            if [ "$PROBE_RC" -eq 0 ]; then
                CLI_STATUS="OK"
                row "$1" OK "CLI present, \`$5\` answered (checks login as well as network)"
            else
                CLI_STATUS="NO-NETWORK"
                row "$1" NO-NETWORK "CLI present, \`$5\` failed or timed out after ${HTTP_TIMEOUT}s — no network, or not logged in (\`$2 login\`)"
            fi
        fi
        return 0
    fi
```

`$5` is deliberately unquoted: it is a command line, and word splitting is what turns
`grok models` into two argv entries.

- [ ] **Step 4: Read the grok gate and catalog**

Beside the `HAS_CODEX` / `HAS_GEMINI` reads (~line 308):

```bash
    HAS_GROK="$(bash "$LOADER" get-flag has_grok 2>/dev/null)" || HAS_GROK=0
    # The catalog feeds the SUMMARY line, which must spell reviewer names exactly as the
    # orchestrators do: grok:grok-4.6, like claude:opus. A failed read leaves it empty and the
    # row below reports the section as INVALID through the typed getter.
    GROK_MODELS="$(bash "$LOADER" list-grok-models 2>/dev/null)" || GROK_MODELS=""
```

Declare `GROK_MODELS=""` beside the existing `CLAUDE_MODELS=""` initialisation (~line 280) so
the no-config branch leaves it defined.

**And declare `HAS_GROK=0` at line 186, beside `HAS_CODEX=0` / `HAS_GEMINI=0` (:184-185).**
This is not optional tidiness — it is the difference between a working probe and a broken one.
Those two are initialised THERE, outside the `if [ "$CONFIG_STATUS" = "OK" ]` branch that
begins at :285, precisely because `cli_row … "$HAS_CODEX"` at :421 runs unconditionally.
The reads added above live INSIDE that branch, so on any path where the config is not usable —
`run_probe none`, no `config.yaml`, no `yq`/`jq`, an invalid config — `preflight-env.sh:19`'s
`set -u` aborts on `HAS_GROK: unbound variable`, killing the probe before git-remote,
bash-timeout and SUMMARY. That breaks scenarios which have nothing to do with grok, and it
turns the suite's `every verdict exits 0` backstop red across the board.

Verify both, since a missing initialisation is invisible on the happy path:

```bash
grep -n '^HAS_GROK=0' skills/shared/preflight-env.sh          # must print one line, ~186
PREFLIGHT_SKIP_NETWORK=1 bash skills/shared/preflight-env.sh >/dev/null 2>&1; echo "rc=$?"
```

- [ ] **Step 5: Add the row and the summary entries**

Beside the codex and gemini `cli_row` calls:

```bash
cli_row codex  "codex"  "https://api.openai.com/v1/models"           "$HAS_CODEX";  CODEX_STATUS="$CLI_STATUS"
cli_row gemini "gemini" "https://generativelanguage.googleapis.com/" "$HAS_GEMINI"; GEMINI_STATUS="$CLI_STATUS"
# The URL argument is unused when a command probe is given; pass the CLI's own docs host so the
# row's shape stays uniform and a future reader can see what an HTTP fallback would target.
cli_row grok   "grok"   "https://api.x.ai/v1/models"                 "$HAS_GROK" "grok models"; GROK_STATUS="$CLI_STATUS"
```

And in the summary block, after the gemini line:

```bash
if [ "$GROK_STATUS" = "OK" ]; then
    # One entry per catalog model, exactly as claude expands over claude.models. The bare
    # `grok` fallback cannot normally happen — the validator requires a non-empty catalog
    # whenever the section exists — but a reader is better served by a name than by silence
    # if some future config shape reaches here with an empty list.
    if [ -n "$GROK_MODELS" ]; then
        while IFS= read -r GM; do
            [ -n "$GM" ] && add_avail "grok:$GM"
        done <<< "$GROK_MODELS"
    else
        # Unreachable through the validator (a section without a non-empty catalog does not
        # validate), kept only so a future config shape cannot reach the summary silently.
        add_avail grok
    fi
else
    add_unavail "grok ($GROK_STATUS)"
fi
```

**And expand grok on the `SUMMARY defaults` line too — otherwise the probe starts lying about
`default` mode.** `preflight-env.sh:794-802` expands only `claude` into `claude:<model>`; every
other `builtin` name passes through bare. After Step 5, `SUMMARY available` carries
`grok:grok-4.6` while `SUMMARY defaults code_review` carries a bare `grok`, and the invariant
stated in the comment above that block — "every name on a defaults line must appear in
SUMMARY available" — breaks. It is checked mechanically by `defaults_not_available()`
(`test-preflight-env.sh:625-643`), which compares WHOLE entries and hard-codes exactly one
exception, for `claude`. Expand `grok` over `.grok_models` in that jq, the same way `claude` is
expanded over `.claude_models`; the validator guarantees a non-empty `grok_models` whenever
`grok` is in `builtin`, so the expansion is always defined. Do NOT instead add a second
hard-coded exception to the test helper: that would leave the product printing two different
names for one reviewer, and a reader deciding whether `default` is safe would have to know the
exception to get the right answer.

- [ ] **Step 6: Run the tests**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-preflight-env.sh > /tmp/test-preflight-env.txt 2>&1; RC=$?
tail -3 /tmp/test-preflight-env.txt; echo "rc=$RC"
```

Expected: `0 failed`.

- [ ] **Step 7: See the real probe**

Run: `bash skills/shared/preflight-env.sh 2>&1 | grep -E '^grok|SUMMARY'`
Expected on this machine: `grok  OK  CLI present, \`grok models\` answered …` once a `grok:`
section exists in the live config, and `grok:grok-4.6` on the available line. With no section
yet: `grok MISSING no grok: section in config — the selection UI will not offer it`.

- [ ] **Step 8: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh
git commit -m "feat(preflight): probe grok with its own CLI, report grok:<model>"
```

---

### Task 11: `/mesh-review` integration

**Files:**
- Modify: `commands/mesh-review.md` — frontmatter description, Step 0 (`default` mode), Step 1 (gates), Step 2 (Q1), a new Step 2.45, Step 2.5, Step 5a, Step 6.0, Step 6.1

**Interfaces:**
- Consumes: `has_grok`, `list-grok-models`, `get-defaults …grok_models` (Tasks 2-3); the `grok-code-reviewer` agent (Task 7); `verify-delegation.sh grok <model>` (Task 8).
- Produces: reviewer names `grok:<model>`, dispatch pairs `grok:<model>`, roster entries `grok/<model>`.

- [ ] **Step 1: Widen the gates in Step 1**

After the `HAS_GEMINI` read in the Step 1 fence, add — with the same rc-awareness the claude
catalog read has, because `list-grok-models` validates the section:

```bash
HAS_GROK=$("$LOADER" get-flag has_grok)
GM_ERR=$(mktemp)
GROK_MODELS=$("$LOADER" list-grok-models 2>"$GM_ERR") \
    || { echo "config.yaml невалиден (секция grok):" >&2; cat "$GM_ERR" >&2; rm -f "$GM_ERR"; exit 1; }
rm -f "$GM_ERR"
echo "HAS_GROK=$HAS_GROK"
echo "GROK_MODELS=[$(echo "$GROK_MODELS" | tr '\n' ' ')]"
```

- [ ] **Step 2: Add the Q1 option**

In Step 2's option list, after the gemini line:

```
  - "grok CLI ★ default"                                       — show only if HAS_GROK=1; ★ if "grok" in defaults.code_review.builtin
```

- [ ] **Step 3: Add Step 2.45 — grok-model selection**

Insert a new step between Step 2.4 and Step 2.5:

````markdown
## Step 2.45: Grok-model selection

Runs ONLY when Q1 selected `grok`. There is no `HAS_GROK_MODELS` gate: a `grok:` section
without a non-empty catalog does not validate, so `HAS_GROK=1` already guarantees
`GROK_MODELS` is non-empty.

- `grok` NOT selected in Q1 → skip this step; **bind `SELECTED_GROK_MODELS` to the empty
  list** and run no grok reviewer at all.

Read the recommended set from the preset — rc-aware, and never through a pipe, for the same
reason Step 2.4 spells out (this Bash call runs in a fresh shell; `$LOADER` must be
re-resolved):

```bash
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
GD_ERR=$(mktemp)
CR_DEFAULTS=$("$LOADER" get-defaults code_review 2>"$GD_ERR") \
    || { echo "config.yaml невалиден (defaults.code_review):" >&2; cat "$GD_ERR" >&2; rm -f "$GD_ERR"; exit 1; }
rm -f "$GD_ERR"
GROK_DEFAULT_IDS=$(echo "$CR_DEFAULTS" | jq -r '.grok_models[]?')
echo "GROK_DEFAULT_IDS=[$(echo "$GROK_DEFAULT_IDS" | tr '\n' ' ')]"   # empty = no ★ markers below
```

For each chunk of 4 entries from `GROK_MODELS` (in config order) — same pagination mechanics
as Step 3, and the same reason for the ★ marker (AskUserQuestion has no `preSelected` API):

AskUserQuestion (multiSelect, max 4):
```
header: "Grok"
question: "На каких grok-моделях запустить ревью? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in GROK_DEFAULT_IDS
                 "★ <model> (recommended)"     if in GROK_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections into `SELECTED_GROK_MODELS`.

**An empty selection runs no grok reviewer — and unlike claude, there is no fallback.** The
grok reviewer agent stops without a `MODEL`, so there is nothing to dispatch. Say so on the
Step 2.5 confirmation page ("grok: модели не выбраны — ревьюер не запускается") and continue;
do not re-ask and do not STOP.

Each selected model becomes an independent reviewer with the same diff and the same prompt —
the point is model diversity, so never differentiate their prompts.
````

- [ ] **Step 4: Expand grok on the confirmation page (Step 2.5) — including the empty case**

Define the empty-roster state explicitly, in both orchestrators. "grok selected, no model
checked" is reachable interactively (it is NOT reachable in `default` mode, where the validator
forbids an empty `grok_models`), and today nothing says what happens: the confirmation page
would list a reviewer that never runs, and the watcher would be handed a roster entry with no
dispatch behind it — a `MISSING` row indistinguishable from a dead executor. Required
behaviour: the page states "grok выбран, но ни одной модели не отмечено — grok-ревьюер не
запускается", the pair contributes nothing to the dispatch roster, the watcher roster and the
guard, and if the TOTAL effective roster is empty the run stops with "ничего не выбрано для
ревью" instead of starting an orchestration with no reviewers.


In Step 2.5, extend the expansion sentence: after "**Expand `claude` in that list into one
bullet per entry of `SELECTED_CLAUDE_MODELS`**", add:

```markdown
**Expand `grok` the same way**, one bullet per entry of `SELECTED_GROK_MODELS` (`grok:grok-4.6`).
When that list is empty, show `grok: модели не выбраны — ревьюер не запускается` instead of a
bullet, so a user who selected grok and then skipped its models sees why nothing will run.
```

And in the "Нет, выбрать заново" option, extend the re-run list to "re-runs Q1 **and** Steps
2.4 and 2.45, dropping the current `SELECTED_CLAUDE_MODELS` and `SELECTED_GROK_MODELS`".

- [ ] **Step 5: Handle the preset in Step 0**

In Step 0's `default`-mode bullet list, after the `codex` / `gemini` bullet:

```markdown
  - `grok` in `defaults.code_review.builtin` → **one `grok-code-reviewer` per entry of
    `defaults.code_review.grok_models`**, each dispatched with `MODEL=<entry>` on the first
    line of its prompt. The config validator guarantees that list is non-empty whenever `grok`
    is in `builtin`, so there is no fallback branch here and no case where `grok` in the preset
    dispatches nothing.
  - **Bind `SELECTED_GROK_MODELS` to `defaults.code_review.grok_models` here** (empty when
    `grok` is not in `builtin`), for the same reason `SELECTED_CLAUDE_MODELS` is bound: Step 5a
    consumes it unconditionally, and an unbound name in a prompt raises nothing at all.
```

- [ ] **Step 5b: Cover team mode — it dispatches separately**

`/mesh-review` has a second dispatch path (Step 5b, team mode) with its own enumeration of
wrapper reviewers. Nothing in the steps above touches it, so a team-mode run would spawn codex,
gemini and ext-claude reviewers and silently none for grok. Extend that step's wrapper list and
spawn one task per `grok:<model>` pair, exactly as Step 5a does. Then re-check by name:

```bash
grep -n 'codex / gemini / ext-claude' commands/mesh-review.md   # expect: no functional list left
grep -c 'grok' commands/mesh-review.md
```

**And sweep the stale engine enumerations while you are here.** The phrase
"codex / gemini / ext-claude" (and its variants) appears in both orchestrators and in the
header of `verify-delegation.sh`; each one that describes what the plugin CAN dispatch is now
wrong. Fix them by name, not by eye:

```bash
grep -rn 'codex / gemini / ext-claude\|codex/gemini/ext-claude' commands/ skills/ | grep -v grok
```

Expect zero lines left that enumerate dispatchable engines without grok. Lines that describe a
historical incident or a measured fact about those three engines stay as they are — they are
statements about the past, not about the roster.


- [ ] **Step 6: Dispatch in Step 5a**

In the "Before dispatch" paragraph, extend the pair list: `codex`→`codex:-`,
`gemini`→`gemini:-`, each entry of `SELECTED_GROK_MODELS`→`grok:<model>`, each selected model
id→`ext-claude:<id>`.

In the builtin reviewer list, after the gemini bullet:

```markdown
- grok: `subagent_type: "claude-mesh:grok-code-reviewer"`, **one Task per entry of
  `SELECTED_GROK_MODELS`**, prompt: `MODEL=<entry> Review the changes for production readiness`
  — **`MODEL=` must be the FIRST non-blank line**, so write `MODEL=<entry>` first and
  `BASE_BRANCH=<branch>` on the next line; the agent contract (Task 7) parses `^MODEL=(\S+)`
  and a line that begins with `BASE_BRANCH=` does not match it. Spelled the other way round it
  becomes `BASE_BRANCH=<branch> MODEL=<entry> Review the changes for
  production readiness`. The `MODEL=` prefix is a parameter, exactly as for ext-claude; it is
  not review content, so the CRITICAL rule below still forbids inlining scope or diff.
```

Add grok to the CRITICAL paragraph's list of wrappers ("The codex / gemini / grok / ext-claude
reviewers are thin wrappers") and to the Dispatch-model exception paragraph, which must keep
saying that `DISPATCH_MODEL` governs the wrappers — the grok model is the engine's model, not
the wrapper's, so both apply at once and neither overrides the other.

In the watcher example, show a grok entry:

```bash
   "$WATCH" --since <DISPATCH_EPOCH> codex grok/grok-4.6 ext-claude/zai/glm
```

- [ ] **Step 7: Extend the guard step (6.0)**

In the classification example, add a grok pair:

```bash
for spec in "codex:-" "grok:grok-4.6" "ext-claude:zai/glm"; do
```

In the verdict list, extend the engine-specific clauses:
- `STALLED`: "…for ext-claude **and grok** that is a missing result event; for codex and gemini, …"
- `BROKEN`: "…for ext-claude **and grok** that is thinking-only / `num_turns≤1` …"
- `DEGRADED`: change the parenthetical from "(exit 5, ext-claude only)" to "(exit 5, ext-claude
  and grok)" and add: "On grok the remedy differs and the reason line says so: `grok-exec`
  already passes `--permission-mode bypassPermissions`, so a denial there points at the CLI's
  own permission configuration (`~/.grok`), not at a plugin release."

In the status table example, add a row: `| grok:grok-4.6 | REAL | ✅ kept |`.

In the re-dispatch step (6.4b), extend the exact-prompt list with
`MODEL=<model> Review the changes for production readiness` for grok.

- [ ] **Step 8: Attribution in Step 6.1**

In the deduplication rule, extend the claude attribution sentence:

```markdown
Grok reviewers are attributed the same way, as `grok:<model>` (`grok:grok-4.6`) — two grok
models reporting one issue is corroboration exactly as two Claude models are, so merge them
into one entry that lists both and never collapse them into a nameless "grok".
```

- [ ] **Step 9: Update the frontmatter description**

```yaml
description: Launch code review agents (built-in claude on N models, codex, gemini, grok on N models, ext-claude on N models) with selection UI and result deduplication.
```

- [ ] **Step 10: Verify the file is internally consistent**

```bash
cd /opt/github/zinin/claude-mesh
grep -c 'grok' commands/mesh-review.md
grep -n 'SELECTED_GROK_MODELS' commands/mesh-review.md
```

Expected: `SELECTED_GROK_MODELS` appears in Step 0 (bind), Step 2.45 (bind + fill), Step 2.5
(expand), Step 5a (dispatch) — four sites at minimum, mirroring `SELECTED_CLAUDE_MODELS`.

```bash
grep -n 'SELECTED_CLAUDE_MODELS' commands/mesh-review.md | wc -l
```

- [ ] **Step 11: Commit**

```bash
git add commands/mesh-review.md
git commit -m "feat(mesh-review): offer and dispatch grok reviewers per model"
```

---

### Task 12: `/mesh-design-review` integration

The same four points at this file's own step numbers. **Do not copy the Step 2.45 text across**
— the file documents four places where the two orchestrators deliberately differ (path
resolution, the order of guard and ping, the routing of a dead run, the scope of the watch
loop), and its "Never mirror these four" note exists because someone will try.

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` — parameters block, Step 5.0 (gates), Step 5.1 (`default` preset), Step 5.2 (Q1), a new Step 5.2.6, **Step 5.4 (Confirm selection — NOT dispatch)**, Step 6 (dispatch, watcher and guard live there), the per-executor output section of Step 7

**Step numbering, checked against the file:** 5.4 is *Confirm selection* (`SKILL.md:368`), and
dispatch begins at Step 6 (`:385`). An executor following "Step 5.4 (dispatch)" would look for
the routing in the wrong section and, finding none, improvise.

**Interfaces:** identical to Task 11, on the `design_review` preset.

- [ ] **Step 1: Extend the gates in Step 5.0**

After the `HAS_GEMINI` read, add the same two reads as Task 11 Step 1 (`HAS_GROK`,
`GROK_MODELS`), with this file's own wording for the rc handling. Extend the sentence that
follows the fence — "Compare `HAS_CODEX` / `HAS_GEMINI` / `HAS_MODELS` / `HAS_CLAUDE_MODELS` to
`1`" — to include `HAS_GROK`, and extend the `DEFAULTS_JSON` parse list with `.grok_models`.

- [ ] **Step 2: Handle the preset in Step 5.1**

After the `gemini` bullet:

```markdown
  - `grok` → **one `claude-mesh:grok-executor` per entry of `.grok_models`** — the EXECUTOR,
    never `grok-code-reviewer`. Design review composes its own prompt in Step 4 and hands it
    over verbatim; `grok-code-reviewer` would instead resolve a `BASE_BRANCH`/`merge-base`
    diff and render `shared/code-review-prompt.md`, i.e. review the working tree and ignore
    the two documents entirely. That is why this file dispatches `codex-executor` /
    `gemini-executor` / `ext-claude-executor` and not the `*-code-reviewer` agents. Each gets
    `MODEL=<entry>` on the first line. The validator guarantees a non-empty list whenever
    `grok` is in `builtin`, so this branch has no fallback and cannot dispatch nothing.
  - **Bind `SELECTED_GROK_MODELS` to that list here** (empty when `grok` is absent from
    `builtin`), exactly as `SELECTED_CLAUDE_MODELS` is bound: Step 5.4 remembers it for
    iterations 2..N.
```

- [ ] **Step 3: Add the Q1 option and Step 5.2.6**

In Step 5.2's option list:

```
  - "grok CLI ★ default"                           — show only if HAS_GROK=1; ★ if "grok" in defaults.builtin
```

Extend the parenthetical after that list ("Show the codex / gemini / external-models options
only when their gating flag is `1`") to name grok, and add: "If `grok` is not selected → skip
Step 5.2.6 and run no grok reviewer."

Then add Step 5.2.6 after Step 5.2.5, written for this file: the same paginated
AskUserQuestion over `GROK_MODELS` with ★ from `.grok_models`, collecting into
`SELECTED_GROK_MODELS`, and the same "empty selection runs no grok reviewer, and there is no
fallback" rule. Do **not** copy Step 2.45's loader-resolution fence: this file resolves the
loader from `SKILL_BASE` and asks it for `data-dir`, as its own note explains.

- [ ] **Step 3b: Cover Step 5.4 (Confirm selection) — five edits, none optional**

Task 11 spells the symmetric edits out for `/mesh-review`; without them here, grok works for
exactly one iteration and then vanishes from an orchestrator whose whole purpose is iterating.

1. **`SKILL.md:381` — "Remember the confirmed set (built-in TYPES + `SELECTED_CLAUDE_MODELS` +
   `SELECTED_IDS`) for all subsequent iterations in the loop."** Add `SELECTED_GROK_MODELS` to
   that list. Miss it and the grok reviewers run on iteration 1 and silently disappear on
   iteration 2 — the "silently ignored list" failure that the `validate_defaults` comment cites
   as the very reason `claude_models` is fail-closed.
2. **Expand `grok` into one bullet per selected model on the confirmation page**
   (`grok:grok-4.6`, `grok:grok-4.5`), exactly as `claude` is expanded, so the user sees how
   many reviewers they are about to pay for.
3. **The "Перевыбрать" clause** currently reads "restarts Step 5.2 from Q1 with the same
   DEFAULT_IDS / CLAUDE_DEFAULT_IDS (Step 5.2.5 re-runs too)". Add 5.2.6, or a re-select leaves
   a stale `SELECTED_GROK_MODELS` behind.
4. **The "grok selected, no models checked" line.** Design §3 requires the confirmation page to
   say so outright. Task 11 Step 4 does this for `/mesh-review`; it must be written here too.
5. **Bind `SELECTED_GROK_MODELS` to the empty list when `grok` is not selected in Q1.** Step 3
   above says "skip Step 5.2.6 and run no grok reviewer" but never binds the name, and this
   file is emphatic about why that matters (`SKILL.md:328`: "Both bindings are mandatory… An
   undefined name in a shell script raises an error under `set -u`; in a prompt it raises
   nothing at all — the reader improvises"). Task 11 Step 3 binds both; the asymmetry is a
   defect, not a decision.

Then verify mechanically, the way Task 11 Step 10 does for its own file — design review has no
such check today, which is why these five went missing in the first place:

```bash
grep -c 'SELECTED_GROK_MODELS' skills/mesh-design-review/SKILL.md   # expect >= 4
grep -n 'grok' skills/mesh-design-review/SKILL.md | grep -ci 'code-reviewer'   # expect 0
```

- [ ] **Step 4: Dispatch, watch and verify**

- In the executors list, add: **`claude-mesh:grok-executor`** (built-in selected: `grok`)
  — one per entry of `SELECTED_GROK_MODELS`, no `REASONING_EFFORT` unless the user named one.
  Write the dispatch template out in full, in the `ext-claude` shape, because `MODEL` must be
  the FIRST non-blank line and an `Execute this prompt via…` line above it would break the
  parse:

  ```
  Task tool:
    subagent_type: claude-mesh:grok-executor
    description: "Design review via grok:<model> (iter N)"
    prompt: "MODEL=<model>
      Execute this prompt via grok-exec:
      PROMPT: [composed prompt with PREVIOUS_DECISIONS]
      TASK_NAME: design-review-[TOPIC]-iter-N
      SUPERVISED_MODE: shell"
  ```
- In the parameters block at the top of the file, add `GROK_REASONING_EFFORT` beside
  `CODEX_REASONING_LEVEL`, described as: "resolved from `config.yaml` (`grok.reasoning_effort`)
  by the executor; when that is unset too, the CLI's own default applies. Set only when the
  user explicitly overrides."
- In the watcher example, add `grok/grok-4.6` to the roster.
- In the guard example, extend the sentence "The arguments are the engine, the model (`-` for
  codex and gemini)" to read "(`-` for codex and gemini; the model id for grok;
  `<provider>/<short>` for ext-claude)". **There is no "spec loop" in this file** — that is
  `/mesh-review`'s shape; here the guard is a single command (`SKILL.md:480-485`), so add a
  grok invocation line beside it, e.g. `bash "$VERIFY" grok grok-4.6 <DISPATCH_EPOCH> "$DATA_DIR"`.
- In the closing clause of watch-loop point 6, extend "the codex / gemini / ext-claude
  executors only" to include grok.
- In the per-executor output section, add a `## grok-executor (<model>)` block beside the
  codex and gemini ones — the section is named after the agent that ran, and per the bullet
  above that agent is the executor.
- **Carry the tooling constraint into the PROMPT block.** In `/mesh-review` the no-skills line
  is appended by `grok-code-review` (Task 7 Step 4); design review bypasses that skill entirely
  and hands its own composed prompt to the executor, so nothing adds the line here. Without it,
  grok — which sees every installed claude-* plugin, `claude-mesh:mesh-design-review` included —
  can answer a review request by launching an orchestration that writes run dirs this session
  never dispatched. Append the same paragraph to the composed prompt for grok dispatches only;
  codex, gemini and ext-claude cannot see those skills and need no such line.

- [ ] **Step 5: Check both orchestrators still agree where they must**

```bash
cd /opt/github/zinin/claude-mesh
bash skills/shared/tests/test-command-sync.sh > /tmp/sync.txt 2>&1; RC=$?; tail -3 /tmp/sync.txt; echo "rc=$RC"
grep -c 'grok' skills/mesh-design-review/SKILL.md
```

Expected: the sync suite passes (it guards the two fresh-session generators, which Task 13
touches — a failure here means Task 13's edits leaked in early), and grok appears throughout
the design-review file.

- [ ] **Step 6: Commit**

```bash
git add skills/mesh-design-review/SKILL.md
git commit -m "feat(design-review): offer and dispatch grok reviewers per model"
```

---

### Task 13: Fresh-session prompts, README and CHANGELOG

**Files:**
- Modify: `commands/code-review-fresh-session.md`, `commands/design-review-fresh-session.md`, `README.md`, `CHANGELOG.md`

**Interfaces:** consumes everything above; produces documentation only.

- [ ] **Step 1: Add grok to both generators**

Both files name the engines in prose while deliberately naming no models — the generated
prompt tells a fresh session to run `preflight-env.sh` and pick from what it reports. Find the
two mentions per file and extend them:

```bash
cd /opt/github/zinin/claude-mesh
grep -n 'codex' commands/code-review-fresh-session.md commands/design-review-fresh-session.md
```

**Read this before editing — the naive reading of the instruction contradicts itself.** One of
the two mentions per file lives INSIDE the `PREFLIGHT` region
(`commands/code-review-fresh-session.md:177`, region 168-185;
`commands/design-review-fresh-session.md:126`, region 117-134), which
`test-command-sync.sh:144-145` pins at 17 lines and asserts byte-identical across the pair.
"Extend both mentions" and "change nothing inside PREFLIGHT" cannot both be obeyed literally.
The resolution: **edit the in-region sentence in BOTH files identically and without changing
the line count.** Both assertions then stay green — they check equality between the files and
the region's length, not its content.

There is a second, worse problem in that same sentence. It currently reads: "`OK` on the
codex / gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an
auth check". Mechanically appending grok to that list ships a false statement into the one
region the suite guards most carefully: grok's probe runs `grok models`, which answers only
with a live login, so for grok it IS an auth check (Task 10 Step 3 says exactly that). Rewrite
with the distinction instead of extending the list, same line count, both files:

> `OK` on codex / gemini is a heuristic — binary present, section valid, endpoint answered,
> NOT an auth check. `OK` on grok is stronger: the probe runs the CLI itself, which answers
> only when a login is live.

The second mention per file (`:207` / `:155`, under `## WHEN THE USER SAYS GO`) is outside every
synced region — extend that one freely. The `DO NOT` region is not touched at all; its wording
is a measured experimental result.

- [ ] **Step 1b: Add a static orchestrator-contract block to `test-command-sync.sh`**

`test-command-sync.sh` compares the two orchestrators against EACH OTHER, so it catches drift
but is blind to a mistake made identically in both — and to a mistake made in only one file
about a place where the two are *supposed* to differ. Every orchestrator defect this review
surfaced was of that kind: the wrong agent type in design review, a missing
`SELECTED_GROK_MODELS` binding, an enumeration left at three engines. Assert absolute facts per
file, not equality between them:

```bash
echo "=== Test: orchestrator contract (grok) ==="
# design review dispatches EXECUTORS (it composes its own prompt); /mesh-review dispatches
# the code-reviewer wrappers. Crossing them makes grok review a git diff in a document review.
assert_eq "design review dispatches grok-executor" "1" \
  "$(grep -c 'claude-mesh:grok-executor' skills/mesh-design-review/SKILL.md)"
assert_eq "design review never dispatches grok-code-reviewer" "0" \
  "$(grep -c 'claude-mesh:grok-code-reviewer' skills/mesh-design-review/SKILL.md)"
assert_eq "mesh-review dispatches grok-code-reviewer" "1" \
  "$(grep -c 'claude-mesh:grok-code-reviewer' commands/mesh-review.md)"
# the empty-list binding both files insist on, in both files
for f in commands/mesh-review.md skills/mesh-design-review/SKILL.md; do
    [ "$(grep -c 'SELECTED_GROK_MODELS' "$f")" -ge 4 ] \
      && { PASS=$((PASS+1)); echo "  PASS: $f binds SELECTED_GROK_MODELS"; } \
      || { FAIL=$((FAIL+1)); echo "  FAIL: $f under-binds SELECTED_GROK_MODELS"; }
done
# roster spelling vs reviewer-name spelling — one slash, one colon, never swapped
assert_eq "watcher roster uses grok/<model>" "1" "$(grep -c 'grok/grok-4.6' commands/mesh-review.md)"
assert_eq "reviewer name uses grok:<model>"  "1" "$(grep -c 'grok:grok-4.6' commands/mesh-review.md)"
# no enumeration of dispatchable engines left without grok
assert_eq "no stale engine enumeration" "0" \
  "$(grep -rc 'codex / gemini / ext-claude' commands/mesh-review.md skills/mesh-design-review/SKILL.md | awk -F: '{s+=$2} END{print s+0}')"
```

Also extend `LOADER_SUBCMDS` in that suite with `list-grok-models` and `get-grok`: the list
pins which loader subcommands the orchestrators may call, and a new getter absent from it is
invisible to the check.


- [ ] **Step 2: Re-run the sync suite**

```bash
bash skills/shared/tests/test-command-sync.sh > /tmp/sync-after.txt 2>&1; RC=$?
tail -3 /tmp/sync-after.txt; echo "rc=$RC"
```

Expected: `rc=0`, `0 failed`. A failure here means either an edit landed inside a synced region,
or the two files drifted — read which assertion failed before moving anything.

- [ ] **Step 3: Finish the README**

Beyond the schema and dependency entries added in Task 4, add three troubleshooting rows:

```markdown
| `grok: command not found` | Install Grok Build, then `grok login` |
| `grok` row reads `NO-NETWORK` in the probe | `grok models` failed: no network, or the CLI is signed out — run `grok login` |
| `unknown model id` from a grok reviewer | The id in `grok.models` is not one your subscription offers — `grok models` lists them |
```

And add grok to the feature bullet that currently reads "**`codex-*`, `gemini-*` agents** —
wrappers for OpenAI Codex CLI and Gemini CLI":

```markdown
- **`codex-*`, `gemini-*`, `grok-*` agents** — wrappers for the OpenAI Codex, Gemini and xAI
  Grok CLIs. The grok wrappers take a `MODEL` from the `grok.models` catalog, so one
  `/mesh-review` can run several grok models as independent reviewers
```

- [ ] **Step 4: Write the CHANGELOG entry**

At the top of `CHANGELOG.md`, under a new `## [Unreleased]` heading:

```markdown
### Added
- **grok is a third CLI reviewer engine**, alongside codex and gemini: `grok-exec` /
  `grok-code-review` skills, `grok-executor` / `grok-code-reviewer` agents, a gated `grok:`
  config section, a row in the environment probe, and a place in the selection UI of both
  `/mesh-review` and `/mesh-design-review`. Unlike codex and gemini, grok carries a model
  CATALOG — `grok.models`, with `defaults.<preset>.grok_models` choosing which entries a
  preset runs — so one review can cross-check itself across several grok models, exactly as
  `claude.models` already allows for the built-in reviewer.
- The grok runs speak the Claude Code wire format (`--output-format streaming-messages-json`),
  so `shared/extract-result.py`, the report renderer and the `ext-claude` branch of
  `verify-delegation.sh` serve them unchanged — and grok reaches the `DEGRADED` verdict, which
  codex and gemini cannot.

### Changed
- `skills/ext-claude-exec/generate-md.sh` moved to `skills/shared/stream-json-report.sh`. Two
  engines render reports from the same stream format; the renderer had been living inside one
  of them. Same signature, same output.
- The model-catalog validator is now one function serving `claude:` and `grok:`. Its error
  messages for `claude.models` are unchanged, byte for byte.
- `preflight-env.sh` probes a CLI with a command when an HTTP request cannot answer for it:
  `grok models` reports network and login together, while a curl against `api.x.ai` would
  describe an endpoint a grok.com subscription never calls.

### Requirements
- `grok` CLI (only when using the grok agents). It authenticates itself; claude-mesh never
  handles a grok token. Note that grok also reads `~/.claude/CLAUDE.md` and every installed
  claude-* plugin — the review prompt therefore forbids it from invoking any skill.
```

- [ ] **Step 5: Commit**

```bash
git add commands/code-review-fresh-session.md commands/design-review-fresh-session.md README.md CHANGELOG.md
git commit -m "docs: grok in the fresh-session prompts, README and changelog"
```

---

### Task 14: Acceptance — a live review with grok

The suites prove the parts. This proves the chain: config → UI → agent → skill → CLI → run dir
→ guard → findings.

**Files:** none modified. This task either passes or sends you back to a specific task.

- [ ] **Step 1: Configure the live plugin**

**Ask the user to add this to their `config.yaml`; do not edit it yourself.** The file is
user-owned — the first Global Constraint of this plan says validators report and agents never
fix, and "or have them do it" leaves the wrong door open. The commands below only print and
check; the edit is the user's:

```bash
cd /opt/github/zinin/claude-mesh
DATA="$(bash skills/shared/config-loader.sh data-dir)"
echo "$DATA/config.yaml"
grep -n 'grok' "$DATA/config.yaml" || printf '%s\n' "no grok section yet — add:" "grok:" "  models: [grok-4.6, grok-4.5]" "  reasoning_effort: xhigh"
```

Then verify:

```bash
bash skills/shared/config-loader.sh validate; echo "rc=$?"
bash skills/shared/config-loader.sh list-grok-models
bash skills/shared/preflight-env.sh 2>/dev/null | grep -E '^grok|SUMMARY available'
```

Expected: `rc=0`, both models listed, `grok OK`, and `grok:grok-4.6` on the available line.

- [ ] **Step 2: Run one grok reviewer end to end**

In a session with the plugin loaded, run `/claude-mesh:mesh-review` and select **only** the
grok reviewer with one model. Let it finish.

- [ ] **Step 3: Verify the run on disk**

```bash
cd /opt/github/zinin/claude-mesh
DATA="$(bash skills/shared/config-loader.sh data-dir)"
RD="$(ls -td "$DATA"/runs/grok/*/*/ 2>/dev/null | head -1)"
echo "RUN=$RD"
ls -la "$RD"
echo "--- terminal event:"; grep -c '"type":"result"' "$RD/raw.jsonl"
echo "--- num_turns:"; grep '"type":"result"' "$RD/raw.jsonl" | jq -r 'select(.is_error==false)|.num_turns' | sort -n | tail -1
echo "--- review size:"; tr -d '[:space:]' < "$RD/output.txt" | wc -c
```

Expected: a run directory two levels under `runs/grok/` (model, then timestamp), one or more
`result` events, `num_turns` well above 1, and an `output.txt` far above the 400-byte floor.

- [ ] **Step 4: Verify the guard agrees**

```bash
cd /opt/github/zinin/claude-mesh
DATA="$(bash skills/shared/config-loader.sh data-dir)"
RD="$(ls -td "$DATA"/runs/grok/*/*/ 2>/dev/null | head -1)"
MODEL="$(basename "$(dirname "$RD")")"
SINCE="$(( $(date +%s) - 7200 ))"
bash skills/shared/verify-delegation.sh grok "$MODEL" "$SINCE" "$DATA"; echo "rc=$?"
```

Expected: `REAL` on stdout, `rc=0`. Any other verdict is a real finding — read the reason on
stderr and fix the task it points at (`FLIP` → the agent never called the skill, Task 7;
`STALLED` with no result event → the flag set in Task 6; `BROKEN` → the model answered without
reading code, which is a prompt problem, not a plumbing one).

- [ ] **Step 5: Run every suite one last time**

The loop must ACCUMULATE failures and exit non-zero. As written before this fix it printed
`FAILED` and moved on, so an acceptance step could end green with three suites broken:

```bash
cd /opt/github/zinin/claude-mesh
FAILED=0
for t in test-config-loader test-verify-delegation test-watch-runs test-preflight-env test-command-sync test-extract-result test-render-template test-loader-resolution test-check-context-size; do
    printf '%-28s ' "$t"
    if bash "skills/shared/tests/$t.sh" >/tmp/"$t".log 2>&1; then echo OK
    else echo FAILED; FAILED=$((FAILED+1)); tail -5 /tmp/"$t".log; fi
done
GROK_SMOKE=1 bash skills/shared/tests/test-grok-exec-smoke.sh > /tmp/smoke.txt 2>&1 \
    || FAILED=$((FAILED+1))
tail -2 /tmp/smoke.txt
echo "suites failed: $FAILED"
[ "$FAILED" -eq 0 ] || { echo "ACCEPTANCE NOT MET"; exit 1; }
```

Expected: `OK` on every line, `0 failed` from the smoke test, `suites failed: 0`, rc 0. If the
smoke test SKIPs because `GROK_SMOKE` was forgotten or `grok` is absent, that is not a pass —
read its output and say which.

- [ ] **Step 6: Commit the acceptance record**

```bash
git commit --allow-empty -m "test(grok): live /mesh-review acceptance run verified REAL"
```

---

## Self-Review Record

Checked after writing, against `docs/superpowers/specs/2026-08-28-grok-engine-design.md`:

**Spec coverage.** §1 configuration → Tasks 1-4. §2 execution layer → Tasks 5-6. §3 review layer
and orchestrators → Tasks 7, 11, 12. §4 guard and observability → Tasks 8, 9, 10. §5 tests →
folded into the task each one guards, plus Task 14 for the live run. §6 documentation → Tasks 4
and 13. The spec's three "checks the plan must run first" are folded in where they act: the
`cli_row` decision in Task 10 Step 3, the claude-message diff in Task 1 Steps 1 and 5, and the
stream-growth measurement in Task 6 Step 11.

**Naming consistency.** `SELECTED_GROK_MODELS` (orchestrators), `GROK_MODELS` (catalog read),
`GROK_DEFAULT_IDS` (preset ★ markers), `GROK_IDENT_RE` (charset), `validate_grok_catalog` /
`validate_grok` (split by whether it can `warn`), `has_grok` / `list-grok-models` / `get-grok`
(loader commands), `grok:<model>` (reviewer name), `grok/<model>` (roster), `runs/grok/<model>/`
(path). Each is used under one spelling everywhere it appears above.

**Deliberate omission.** There is no `has_grok_models` flag: `grok.models` is required and
non-empty whenever the section exists, so `has_grok` answers both questions. Every step that
would have gated on it gates on `HAS_GROK` instead.
