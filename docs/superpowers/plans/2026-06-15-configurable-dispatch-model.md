# Configurable Dispatch Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the subagent dispatch model an optional config knob (`runtime.dispatch_model`); when unset, subagents inherit the session model — so a model opening or closing never requires editing skills or agents.

**Architecture:** Remove the static `model: fable` pin from all 8 agent frontmatter files. Add an optional `runtime.dispatch_model` to config.yaml, read through the existing `config-loader.sh` getters (`get-flag` / `get-runtime`). The dispatch commands (`do-plan`, `mesh-review`, `mesh-design-review`) resolve the value at runtime: if set, they pass `model: "<value>"` on every dispatch; if empty/absent, they omit `model:` so each subagent inherits the session model.

**Tech Stack:** Bash (config-loader.sh + its bash smoke-test suite), Claude Code agent/command/skill Markdown, YAML config.

**Spec:** `docs/superpowers/specs/2026-06-15-configurable-dispatch-model-design.md`

---

## File Structure

- `skills/shared/config-loader.sh` — add `dispatch_model` to `validate_runtime`, `cmd_get_flag`, `cmd_get_runtime`. (Tasks 1–2)
- `skills/shared/tests/test-config-loader.sh` — new tests (inline `printf` configs, mirroring Tests 33–35). (Tasks 1–2)
- `agents/*.md` (8 files) — delete the `model: fable` line. (Task 3)
- `commands/do-plan.md` — resolve `dispatch_model` in Step 1; reword Step 5 policy; update Step 3 status line. (Task 4)
- `commands/mesh-review.md` — read `dispatch_model` in Step 1; pass `model:` in Step 5a/5b + Step 6 re-dispatch. (Task 5)
- `skills/mesh-design-review/SKILL.md` — read `dispatch_model` in Step 5.1; pass `model:` in Step 6 + Step 8. (Task 6)
- `config.example.yaml` — document `runtime.dispatch_model`. (Task 7)
- `README.md` — fix the Dependencies bullet that hard-requires the `fable` alias. (Task 8)

Ordering note: every change is safe in isolation because the fallback (omit `model:` → inherit session) always works. Tasks are ordered loader → agents → consumers → docs → final sweep.

---

### Task 1: `config-loader.sh` — `validate_runtime` validates `dispatch_model`

**Files:**
- Modify: `skills/shared/config-loader.sh:368-373` (inside `validate_runtime`, after the `max_redispatch` block)
- Test: `skills/shared/tests/test-config-loader.sh` (append before the final Summary block)

- [ ] **Step 1: Write the failing test**

Append after Test 35 (the `max_redispatch=0` test, ends ~line 462), before the `echo ""` / `=== Summary` block. Use the `validate` subcommand with a full inline config so this task is a self-contained TDD cycle (no dependency on Task 2's getter):

```bash
# === Test 36: validate rejects dispatch_model with invalid charset ===
echo "=== Test 36: dispatch_model invalid charset is rejected ==="
TDIR=$(mktemp -d)
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "bad model!"\n' > "$TDIR/config.yaml"
ERR=$(mktemp)
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "exits non-zero on bad dispatch_model" "1" "$RC"
assert_stderr_contains "names dispatch_model" "dispatch_model" "$ERR"
rm -rf "$TDIR" "$ERR"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-config-loader.sh`
Expected: FAIL on Test 36 — `dispatch_model` is currently unvalidated, so `validate` reaches the end and exits 0 (the assert expects rc=1).

- [ ] **Step 3: Add the validation block**

In `validate_runtime`, immediately after the `max_redispatch` block (the `mrd` block ending at line 373) and before the `timeouts` loop (`local key`), insert:

```bash
    local dm
    dm=$(jq -r '.runtime.dispatch_model // ""' "$CONFIG_JSON")
    if [ -n "$dm" ]; then
        # Forward-compatible: any model alias (opus/fable/…) or full id (claude-fable-5,
        # us.anthropic.*). No enum — a new model must never require a validator change.
        # The charset also keeps the value safe as it flows through jq/bash downstream.
        [[ "$dm" =~ ^[A-Za-z0-9._-]+$ ]] \
            || die "runtime.dispatch_model: must match [A-Za-z0-9._-] (a model alias or id), got \"$dm\""
    fi
```

- [ ] **Step 4: Run the test to confirm validation fires**

Run: `bash skills/shared/tests/test-config-loader.sh`
Expected: Test 36 passes (rc=1, stderr names `dispatch_model`), and no earlier test regresses.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh
git commit -m "feat(config-loader): validate runtime.dispatch_model charset"
```

---

### Task 2: `config-loader.sh` — expose `dispatch_model` via `get-flag` and `get-runtime`

**Files:**
- Modify: `skills/shared/config-loader.sh:547-564` (`cmd_get_flag` — new case + error string)
- Modify: `skills/shared/config-loader.sh:625` (`cmd_get_runtime` — add field)
- Test: `skills/shared/tests/test-config-loader.sh` (append before the final Summary block)

- [ ] **Step 1: Write the failing tests**

Append after Test 36 (before the `=== Summary` block):

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash skills/shared/tests/test-config-loader.sh`
Expected: Tests 37–39 FAIL — `get-flag dispatch_model` currently dies (unknown feature) and `get-runtime` JSON has no `.dispatch_model` (jq prints `null`, `-r` → `null`/empty mismatch).

- [ ] **Step 3: Add the `get-flag` case**

In `cmd_get_flag`, add a new case immediately before the `*)` catch-all (line 562):

```bash
        dispatch_model)
            # Optional. Empty output = no value set → the caller omits model: on dispatch
            # and the subagent inherits the session model. validate_runtime owns the
            # field's charset check, so run it before reading (mirrors
            # do_plan_default_stop_tokens above).
            validate_runtime
            jq -r '.runtime.dispatch_model // empty' "$CONFIG_JSON"
            ;;
```

- [ ] **Step 4: Update the unknown-feature error string**

Replace the `die` line at line 563:

```bash
            die "get-flag: unknown feature \"$feature\" (valid: has_codex, has_gemini, has_models, has_defaults_code_review, do_plan_default_stop_tokens, dispatch_model)"
```

- [ ] **Step 5: Add the field to `get-runtime`**

Replace the `jq -c` line in `cmd_get_runtime` (line 625) with:

```bash
    jq -c "{default_run_mode: (.runtime.default_run_mode // \"background\"), do_plan_default_stop_tokens: (.runtime.do_plan_default_stop_tokens // 250000), max_redispatch: (.runtime.max_redispatch // 1), dispatch_model: (.runtime.dispatch_model // \"\")}" "$CONFIG_JSON"
```

- [ ] **Step 6: Run the full suite**

Run: `bash skills/shared/tests/test-config-loader.sh`
Expected: final line `=== Summary: N passed, 0 failed ===` (Tests 36–39 all green, no regressions).

- [ ] **Step 7: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/tests/test-config-loader.sh
git commit -m "feat(config-loader): expose runtime.dispatch_model via get-flag and get-runtime"
```

---

### Task 3: Remove the `model: fable` pin from all 8 agent frontmatter files

**Files (delete the `model: fable` line in each):**
- `agents/codex-executor.md:6`
- `agents/codex-code-reviewer.md:6`
- `agents/codex-native-reviewer.md:6`
- `agents/gemini-executor.md:6`
- `agents/gemini-code-reviewer.md:6`
- `agents/ext-claude-executor.md:7`
- `agents/ext-claude-code-reviewer.md:7`
- `agents/review-discussion.md:6`

- [ ] **Step 1: Delete the line in every agent file**

Each file contains exactly one line `model: fable`. Remove it (the surrounding `description:` / `color:` lines stay):

```bash
for f in agents/codex-executor.md agents/codex-code-reviewer.md agents/codex-native-reviewer.md \
         agents/gemini-executor.md agents/gemini-code-reviewer.md agents/ext-claude-executor.md \
         agents/ext-claude-code-reviewer.md agents/review-discussion.md; do
  sed -i '/^model: fable$/d' "$f"
done
```

- [ ] **Step 2: Verify no agent pins a model anymore**

Run: `grep -rn '^model:' agents/ && echo "STILL PINNED (fail)" || echo "OK: no agent model pins"`
Expected: `OK: no agent model pins`

- [ ] **Step 3: Verify frontmatter is still well-formed**

Run: `head -8 agents/codex-executor.md`
Expected: a valid frontmatter block — `---`, `name:`, `description:` (multi-line), `color: orange`, `---` — with no `model:` line.

- [ ] **Step 4: Commit**

```bash
git add agents/
git commit -m "refactor(agents): drop static model pin — caller/session decides the model"
```

---

### Task 4: `commands/do-plan.md` — resolve `dispatch_model`, reword the model policy

**Files:**
- Modify: `commands/do-plan.md:29-34` (Step 1 bash — add resolution)
- Modify: `commands/do-plan.md:119` (Step 3 status line example)
- Modify: `commands/do-plan.md:132-134` (Step 5 model policy)

- [ ] **Step 1: Resolve the dispatch model in the Step 1 bash block**

After the `DEFAULT_STOP` `case "$?" in … esac` block (the `esac` at line 34), and still inside the same ```bash fence (before the closing ``` at line 35), append:

```bash

# Dispatch model for subagents. Empty = inherit the session model.
# rc=2 (no config.yaml on a fresh install) also means inherit.
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model 2>"$LOADER_ERR")
case "$?" in
    0) ;;                      # configured value (may be empty = inherit), already validated
    2) DISPATCH_MODEL="" ;;    # config.yaml not found — inherit session model
    *) cat "$LOADER_ERR" >&2; exit 1 ;;  # any other loader failure — fast-fail
esac
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # surface to the controller (empty = inherit session)
```

- [ ] **Step 2: Update the Step 3 status-line example**

Replace line 119:

```
/claude-mesh:do-plan: STOP threshold = 250000 tokens. Fable everywhere, full review rigor. Starting subagent-driven-development.
```

with:

```
/claude-mesh:do-plan: STOP threshold = 250000 tokens. Dispatch model = opus, full review rigor. Starting subagent-driven-development.
```

Then, directly under the closing ``` of that example block, add a line of prose:

```markdown
Substitute the resolved model: print `Dispatch model = <DISPATCH_MODEL>` when it is non-empty, or `Dispatch model = session-inherited` when `DISPATCH_MODEL` is empty.
```

- [ ] **Step 3: Reword the Step 5 model policy**

Replace the heading at line 132 and the first bullet at line 134.

Old heading:
```
### Model: Fable everywhere
```
New heading:
```
### Model: dispatch tier
```

Old bullet (line 134):
```
- Every `Agent` dispatch (implementer, spec reviewer, code quality reviewer, parallel work, any subagent) **must explicitly set `model: "fable"`**. Do not pick `opus` / `sonnet` / `haiku` for "cheap" or "simple" subtasks.
```
New bullets:
```
- The dispatch model is `$DISPATCH_MODEL`, resolved in Step 1 from config `runtime.dispatch_model`.
  - **Non-empty** → every `Agent` dispatch (implementer, spec reviewer, code quality reviewer, parallel work, any subagent) **must explicitly set `model: "<DISPATCH_MODEL>"`**.
  - **Empty** (no config value, or no config.yaml) → **omit `model:`** so each subagent **inherits this session's model**. Never explicitly pass a model *cheaper* than the session to economize on a "simple" subtask.
```

Leave the two following bullets (lines 135–136: external reviewers; "if a subagent type does not accept a model override, accept the default") unchanged.

- [ ] **Step 4: Verify no stale model literal remains in the policy**

Run: `grep -niE '\b(fable|opus|sonnet|haiku)\b' commands/do-plan.md`
Expected: no match (the forbidden-model list and the `fable` literal are gone; `$DISPATCH_MODEL` carries the value).

- [ ] **Step 5: Commit**

```bash
git add commands/do-plan.md
git commit -m "feat(do-plan): resolve runtime.dispatch_model; inherit session when unset"
```

---

### Task 5: `commands/mesh-review.md` — read `dispatch_model` and pass it on dispatch

**Files:**
- Modify: `commands/mesh-review.md:46` (Step 1 bash — add read)
- Modify: `commands/mesh-review.md:136` (Step 5a — dispatch rule)
- Modify: `commands/mesh-review.md:163` (Step 5b — reference the rule)
- Modify: `commands/mesh-review.md:224` (Step 6 re-dispatch — reference the rule)

- [ ] **Step 1: Read the dispatch model in Step 1**

In the Step 1 bash block, after line 46 (`MODELS=$("$LOADER" list-models) …`), and before the closing ``` at line 47, add:

```bash
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model)   # empty = inherit session model on dispatch
echo "DISPATCH_MODEL=$DISPATCH_MODEL"                  # surface to the controller
```

(By this point rc=2 / rc=1 are already handled by the `has_codex` probe above, so config is present and valid here.)

- [ ] **Step 2: Add the dispatch rule to Step 5a**

In Step 5a, immediately after line 136 (`Launch all selected reviewers via Task tool, each `run_in_background: true`, in ONE message:`), insert a new paragraph:

```markdown
**Dispatch model:** if `DISPATCH_MODEL` (from Step 1) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch below. If it is empty, omit `model:` so each reviewer inherits this session's model. This applies to the builtin `claude` reviewer dispatch too.
```

- [ ] **Step 3: Reference the rule from Step 5b**

In Step 5b item 3 (line 163), append to the sentence (after "team mode does NOT change the prompt rules."):

```markdown
 The Step 5a **Dispatch model** rule also applies here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it.
```

- [ ] **Step 4: Reference the rule from Step 6 re-dispatch**

In Step 6 item b (line 224), append after "same `subagent_type`, same run mode.":

```markdown
 Apply the Step 5a **Dispatch model** rule on re-dispatch too (add `model: "<DISPATCH_MODEL>"` when non-empty, else omit).
```

- [ ] **Step 5: Verify**

Run: `grep -n 'DISPATCH_MODEL' commands/mesh-review.md`
Expected: `DISPATCH_MODEL` appears in the Step 1 bash (read + echo), the Step 5a rule, the Step 5b reference, and the Step 6 reference.
Run: `grep -niE '\b(fable|opus)\b' commands/mesh-review.md`
Expected: no match.

- [ ] **Step 6: Commit**

```bash
git add commands/mesh-review.md
git commit -m "feat(mesh-review): pass runtime.dispatch_model on dispatch; inherit when unset"
```

---

### Task 6: `skills/mesh-design-review/SKILL.md` — read `dispatch_model` and pass it on dispatch

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md:229` (Step 5.1 bash — add read)
- Modify: `skills/mesh-design-review/SKILL.md:306` (Step 6 executor dispatch — dispatch rule)
- Modify: `skills/mesh-design-review/SKILL.md:370` (Step 8 review-discussion dispatch — reference the rule)

- [ ] **Step 1: Read the dispatch model in Step 5.1**

In the Step 5.1 bash block, after line 229 (`DEFAULTS_JSON=$("$LOADER" get-defaults design_review) …`), and before the closing ``` of that block, add:

```bash
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model)   # empty = inherit session model on dispatch
echo "DISPATCH_MODEL=$DISPATCH_MODEL"                  # surface to the controller
```

(rc=2 / rc=1 are already handled by the `has_codex` probe above; config is present and valid here.)

- [ ] **Step 2: Add the dispatch rule to Step 6**

In Step 6, immediately after line 306 (`For each selected agent, use Task tool (plugin `subagent_type`s are `claude-mesh:`-namespaced …).`), insert:

```markdown
**Dispatch model:** if `DISPATCH_MODEL` (from Step 5.1) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch in this step. If it is empty, omit `model:` so each executor inherits this session's model.
```

- [ ] **Step 3: Reference the rule from Step 8**

In Step 8, immediately after line 370 (`Use Task tool to launch the `claude-mesh:review-discussion` agent …`), insert:

```markdown
Apply the same **Dispatch model** rule as Step 6: add `model: "<DISPATCH_MODEL>"` when `DISPATCH_MODEL` is non-empty, otherwise omit `model:`.
```

- [ ] **Step 4: Verify**

Run: `grep -n 'DISPATCH_MODEL' skills/mesh-design-review/SKILL.md`
Expected: `DISPATCH_MODEL` appears in the Step 5.1 bash (read + echo), the Step 6 rule, and the Step 8 reference.
Run: `grep -niE '\b(fable|opus)\b' skills/mesh-design-review/SKILL.md`
Expected: no match.

- [ ] **Step 5: Commit**

```bash
git add skills/mesh-design-review/SKILL.md
git commit -m "feat(mesh-design-review): pass runtime.dispatch_model on dispatch; inherit when unset"
```

---

### Task 7: `config.example.yaml` — document `runtime.dispatch_model`

**Files:**
- Modify: `config.example.yaml:198` (inside the `runtime:` section, after the `max_redispatch` block)

- [ ] **Step 1: Add the documented key**

After the `max_redispatch: 1` block (line 198) and before the `timeouts:` block (line 200), insert:

```yaml

  # Model for subagents dispatched by /do-plan, /mesh-review, /mesh-design-review.
  # [optional] If set, those commands pass `model: "<value>"` on every dispatch.
  # If absent (or config.yaml absent), subagents inherit your current session model
  # (your /model). Set this to FORCE a specific tier regardless of the session.
  # Accepts any Claude Code Agent model alias or id (e.g. opus, sonnet, haiku, fable,
  # claude-fable-5). No enum is enforced — flip it freely when a model opens or closes,
  # no plugin release needed. Charset: [A-Za-z0-9._-].
  # dispatch_model: opus
```

(Ship it commented out so the default behavior stays "inherit the session".)

- [ ] **Step 2: Verify the example still validates**

Run:
```bash
TDIR=$(mktemp -d); cp config.example.yaml "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh validate; echo "rc=$?"
rm -rf "$TDIR"
```
Expected: `rc=0` (the `REPLACE_ME` token passes `validate`; the commented `dispatch_model` line is inert).

- [ ] **Step 3: Verify an uncommented value validates too**

Run:
```bash
TDIR=$(mktemp -d); sed 's/# dispatch_model: opus/dispatch_model: opus/' config.example.yaml > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" bash skills/shared/config-loader.sh validate; echo "rc=$?"
rm -rf "$TDIR"
```
Expected: `rc=0`.

- [ ] **Step 4: Commit**

```bash
git add config.example.yaml
git commit -m "docs(config): document optional runtime.dispatch_model"
```

---

### Task 8: `README.md` — fix the Dependencies bullet that hard-requires `fable`

**Files:**
- Modify: `README.md:54`

- [ ] **Step 1: Replace the bullet**

Old (line 54):
```
- `claude` CLI (this plugin runs on top of Claude Code) — requires a current Claude Code build whose Agent model enum includes the `fable` alias: all mesh agents and the do-plan dispatch policy pin `model: fable`
```
New:
```
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
```

- [ ] **Step 2: Verify**

Run: `grep -nA2 'claude` CLI' README.md`
Expected: the new bullet text; no claim that the `fable` alias is required.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): no model pin — inherit session, optional dispatch_model knob"
```

---

### Task 9: Final verification sweep

**Files:** none modified — this task only verifies the spec's Verification section.

- [ ] **Step 1: Full config-loader suite is green**

Run: `bash skills/shared/tests/test-config-loader.sh`
Expected: `=== Summary: N passed, 0 failed ===`

- [ ] **Step 2: No model pin remains in agent frontmatter**

Run: `grep -rn '^model:' agents/ && echo "FAIL" || echo "OK: no agent model pins"`
Expected: `OK: no agent model pins`

- [ ] **Step 3: No model literal remains in dispatch-policy prose**

Run: `grep -niE '\b(fable|opus)\b' commands/do-plan.md commands/mesh-review.md skills/mesh-design-review/SKILL.md`
Expected: no output.

- [ ] **Step 4: Repo-wide sweep matches only expected places**

Run: `grep -rniE '\b(fable|opus)\b' --exclude-dir=.git --exclude-dir=docs --exclude-dir=.idea .`
Expected: matches ONLY in — `config.example.yaml` (the `ANTHROPIC_DEFAULT_OPUS_MODEL` comment and the commented `dispatch_model: opus` example), `skills/shared/tests/test-config-loader.sh` (the `opus`/`fable` test values + the `ANTHROPIC_DEFAULT_OPUS_MODEL` export test), `README.md` (the `opus`/`fable` examples in the new bullet), and `CHANGELOG.md` (historical entries). No match in `agents/*.md` or the dispatch-policy prose.

- [ ] **Step 5: Runtime smoke (manual, document the result)**

Two paths, exercised via `/mesh-review` or `/do-plan`:
1. With `runtime.dispatch_model: opus` set in config.yaml → a dispatched subagent runs on `opus`.
2. With the key removed → a dispatched subagent inherits the session model and succeeds even though `fable` is unavailable.

Record the observed behavior in the task notes. (No code change; this confirms the end-to-end contract.)

- [ ] **Step 6: No commit needed** (verification only). If Steps 1–4 surface any gap, fix it in the owning task and re-run this sweep.

---

## Notes for the executor

- **Out of scope — do not touch:** the ext-claude provider model mapping (`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`, per-model `subagent_model`) in `config.example.yaml` / `config-loader.sh` / `test-config-loader.sh`; the already-neutral FLIP diagnostics wording; the CHANGELOG / version bump (maintainer does it via standard-version).
- **`<DISPATCH_MODEL>` in the Markdown files** is an instruction to the LLM controller, not a shell variable the Markdown executes — the controller resolves the value from the Step 1 / Step 5.1 bash output and substitutes it into the `model:` dispatch parameter.
- **Test runs**: this repo's checks are the bash smoke suite `skills/shared/tests/test-config-loader.sh`. Run it directly (or via the build-runner agent). There is no compile/lint step for the Markdown changes — grep sweeps are their verification.
