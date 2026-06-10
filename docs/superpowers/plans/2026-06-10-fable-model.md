# Fable Model Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch claude-mesh's "never delegate to cheaper models" policy from Opus to Fable (`claude-fable-5`) and make session-model diagnostics wording model-neutral.

**Architecture:** Pure text edits — plugin command markdown, agent frontmatter, and one runtime message string in a bash script. No logic changes. Policy spots get the literal `fable`; descriptions of "the session's model" (FLIP diagnostics) become model-neutral so they don't go stale at the next model-family rename. Verified by the existing bash test suites plus grep sweeps.

**Tech Stack:** Claude Code plugin (markdown commands + agent frontmatter), bash test scripts under `skills/shared/tests/`.

**Spec:** `docs/superpowers/specs/2026-06-10-fable-model-design.md`

**Runtime smoke note for the controller:** dispatching the Task 1 implementer subagent with `model: "fable"` is itself the alias smoke test required by the spec (Verification §3). If that dispatch fails with an invalid-model error, STOP and report — do not fall back to another model silently.

---

### Task 1: `commands/do-plan.md` — switch the policy to Fable

**Files:**
- Modify: `commands/do-plan.md` (3 edits: lines ~119, ~132, ~134)

- [ ] **Step 1: Edit the Step 3 status-line example (line ~119)**

Use the Edit tool on `commands/do-plan.md`.

Old string:
```
/claude-mesh:do-plan: STOP threshold = 250000 tokens. Opus everywhere, full review rigor. Starting subagent-driven-development.
```

New string:
```
/claude-mesh:do-plan: STOP threshold = 250000 tokens. Fable everywhere, full review rigor. Starting subagent-driven-development.
```

- [ ] **Step 2: Edit the Step 5 heading (line ~132)**

Old string:
```
### Model: Opus everywhere
```

New string:
```
### Model: Fable everywhere
```

- [ ] **Step 3: Edit the Step 5 model mandate (line ~134)**

Old string (one line):
```
- Every `Agent` dispatch (implementer, spec reviewer, code quality reviewer, parallel work, any subagent) **must explicitly set `model: "opus"`**. Do not pick `sonnet` / `haiku` for "cheap" or "simple" subtasks.
```

New string (one line):
```
- Every `Agent` dispatch (implementer, spec reviewer, code quality reviewer, parallel work, any subagent) **must explicitly set `model: "fable"`**. Do not pick `opus` / `sonnet` / `haiku` for "cheap" or "simple" subtasks.
```

Do NOT touch the other Step 5 bullets ("Same for external reviewers…", "If a subagent type does not accept a model override…").

- [ ] **Step 4: Verify the file**

Run: `grep -ni 'opus' commands/do-plan.md`
Expected: no output, exit code 1.

Run: `grep -nic 'fable' commands/do-plan.md`
Expected: `3` (the three edited lines).

- [ ] **Step 5: Commit**

```bash
git add commands/do-plan.md
git commit -m "feat(do-plan): switch model policy from opus to fable"
```

---

### Task 2: `agents/*.md` — pin all 8 agents to Fable

**Files (modify each):**
- `agents/codex-executor.md`
- `agents/codex-code-reviewer.md`
- `agents/codex-native-reviewer.md`
- `agents/gemini-executor.md`
- `agents/gemini-code-reviewer.md`
- `agents/ext-claude-executor.md`
- `agents/ext-claude-code-reviewer.md`
- `agents/review-discussion.md`

- [ ] **Step 1: Edit the frontmatter of each of the 8 files**

In every file listed above, apply the same Edit (the string occurs exactly once per file, in the YAML frontmatter):

Old string:
```
model: opus
```

New string:
```
model: fable
```

- [ ] **Step 2: Verify**

Run: `grep -rn 'model: opus' agents/`
Expected: no output, exit code 1.

Run: `grep -rln 'model: fable' agents/ | wc -l`
Expected: `8`

- [ ] **Step 3: Commit**

```bash
git add agents/
git commit -m "feat(agents): pin all mesh agents to fable"
```

---

### Task 3: `commands/mesh-review.md` — model-neutral FLIP wording

**Files:**
- Modify: `commands/mesh-review.md` (4 edits: lines ~183, ~207, ~232, ~236)

- [ ] **Step 1: Edit the Step 6.0 intro (line ~183)**

Old string:
```
they skip their `*-code-review` skill and self-review inline on this session's Opus — a polished review
```

New string:
```
they skip their `*-code-review` skill and self-review inline on this session's own model — a polished review
```

- [ ] **Step 2: Edit the FLIP verdict line (line ~207)**

Old string:
```
- `FLIP` (exit 3) — no run dir → self-reviewed on Opus → **re-dispatch**.
```

New string:
```
- `FLIP` (exit 3) — no run dir → self-reviewed on the session model → **re-dispatch**.
```

- [ ] **Step 3: Edit the Step 6.6 summary template (line ~232)**

Old string:
```
NOT counted as external review (self-review on Opus / killed mid-flight)
```

New string:
```
NOT counted as external review (self-review on the session model / killed mid-flight)
```

- [ ] **Step 4: Edit the final warning (line ~236)**

Old string:
```
**Do NOT silently accept a FLIP as an external review.** A flipped wrapper is Opus reviewing its own session; counting it as independent cross-validation is the exact failure this guard exists to prevent.
```

New string:
```
**Do NOT silently accept a FLIP as an external review.** A flipped wrapper is the session's model reviewing its own work; counting it as independent cross-validation is the exact failure this guard exists to prevent.
```

- [ ] **Step 5: Verify**

Run: `grep -ni 'opus' commands/mesh-review.md`
Expected: no output, exit code 1.

- [ ] **Step 6: Commit**

```bash
git add commands/mesh-review.md
git commit -m "docs(mesh-review): model-neutral FLIP wording"
```

---

### Task 4: `verify-delegation.sh` + its test — model-neutral FLIP message

**Files:**
- Modify: `skills/shared/verify-delegation.sh` (3 edits: lines ~8, ~24, ~64)
- Modify: `skills/shared/tests/test-verify-delegation.sh` (1 edit: line ~6)

The tests assert only the verdict keyword (`FLIP`) and exit codes — not the human-readable stderr message — so the wording change is safe. Step 5 proves it.

- [ ] **Step 1: Edit the header comment (line ~8)**

In `skills/shared/verify-delegation.sh`:

Old string:
```
# skill and self-review inline on the session's Opus — a false cross-validation that
```

New string:
```
# skill and self-review inline on the session's own model — a false cross-validation that
```

- [ ] **Step 2: Edit the exit-code legend comment (line ~24)**

Old string:
```
#   FLIP=3     no run dir for this engine in the dispatch window (self-reviewed on Opus)
```

New string:
```
#   FLIP=3     no run dir for this engine in the dispatch window (self-reviewed on the session model)
```

- [ ] **Step 3: Edit the runtime emit message (line ~64)**

Old string:
```
[ -d "$BASE" ] || emit FLIP "no run dir under ${BASE#"$DATA_DIR"/} — reviewer did not delegate (self-reviewed on Opus)" 3
```

New string:
```
[ -d "$BASE" ] || emit FLIP "no run dir under ${BASE#"$DATA_DIR"/} — reviewer did not delegate (self-reviewed on the session model)" 3
```

- [ ] **Step 4: Edit the test header comment (line ~6)**

In `skills/shared/tests/test-verify-delegation.sh`:

Old string:
```
# self-reviewed on Opus (FLIP), was killed mid-flight (STALLED), or got an
```

New string:
```
# self-reviewed on the session model (FLIP), was killed mid-flight (STALLED), or got an
```

- [ ] **Step 5: Run the regression suite**

Run: `bash skills/shared/tests/test-verify-delegation.sh`
Expected: final line `=== Summary: <N> passed, 0 failed ===`, exit code 0.

- [ ] **Step 6: Verify no opus left**

Run: `grep -ni 'opus' skills/shared/verify-delegation.sh skills/shared/tests/test-verify-delegation.sh`
Expected: no output, exit code 1.

- [ ] **Step 7: Commit**

```bash
git add skills/shared/verify-delegation.sh skills/shared/tests/test-verify-delegation.sh
git commit -m "refactor(verify-delegation): model-neutral FLIP message"
```

---

### Task 5: Full verification sweep

**Files:** none modified (verification only).

- [ ] **Step 1: Run all four bash test suites**

```bash
bash skills/shared/tests/test-config-loader.sh
bash skills/shared/tests/test-check-context-size.sh
bash skills/shared/tests/test-extract-result.sh
bash skills/shared/tests/test-verify-delegation.sh
```

Expected: each ends with `0 failed` in its summary line (`=== Summary: <N> passed, 0 failed ===` or `RESULTS: <N> passed, 0 failed`), each exits 0.

- [ ] **Step 2: Repo-wide opus sweep**

Run: `grep -rniE '\bopus\b' --exclude-dir=.git --exclude-dir=docs --exclude-dir=.idea /opt/github/zinin/claude-mesh`
Expected: hits ONLY in these two files (env-var mapping fixed by Claude Code itself — out of scope per spec):
- `config.example.yaml` (the `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` comment)
- `skills/shared/tests/test-config-loader.sh` (provider-mapping tests)

Any other hit = a missed spot; go back and fix it, then re-run the sweep.

- [ ] **Step 3: Fable count check**

Run: `grep -rln 'model: fable' /opt/github/zinin/claude-mesh/agents/ | wc -l`
Expected: `8`

- [ ] **Step 4: Confirm the runtime smoke happened**

Confirm that at least one Agent dispatch with `model: "fable"` succeeded during execution of Tasks 1–4 (subagent-driven execution satisfies this automatically; for inline execution, dispatch one trivial subagent with `model: "fable"` — e.g. "echo OK" — and confirm it returns).

No commit in this task.
