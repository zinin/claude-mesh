## TASK

Execute the implementation plan for multi-model built-in Claude reviewers in claude-mesh
(let `/mesh-review` and `/mesh-design-review` run several independent Claude reviewers, one
per Claude model, instead of exactly one pinned to `runtime.dispatch_model`).

Use `/superpowers:subagent-driven-development` skill for execution.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-07-26-multi-model-claude-reviewers-design.md`
- Plan: `docs/superpowers/plans/2026-07-26-multi-model-claude-reviewers.md`

Read both documents first.

## IMPORTANT: DO NOT START WORK YET

After reading the documents:
1. Confirm you have loaded all context
2. Summarize your understanding briefly
3. **WAIT for user instruction before taking any action**

Do NOT begin implementation until the user explicitly tells you to start.

## SESSION CONTEXT

### Repo state

- Branch `feature/multi-model-claude-reviewers` is already checked out. It carries two
  commits: `782ebd0` (design doc) and `74c05cb` (plan). Nothing else is implemented yet.
- Per the user's CLAUDE.md workflow: before opening a PR, `git rm` everything under
  `docs/superpowers/` and commit, so plan documents never appear in the PR diff. They stay
  reachable in branch history.
- Line numbers cited throughout the plan are as of `782ebd0` and will drift as tasks land.
  Locate anchors by their quoted text, not by number.

### What the feature actually fixes

The user's live config (`~/.claude/plugins/data/claude-mesh-zinin/config.yaml`) has
`runtime.dispatch_model: opus` and `builtin: [claude, codex]` in **both** presets. Two
consequences that motivated the whole design:

1. The built-in claude reviewer has silently always been on `opus`, because the Dispatch
   model rule stamps `model: "opus"` on every Task dispatch. There is currently no way to
   run a review on a different Claude model without also moving the codex/gemini/ext-claude
   wrappers, `review-discussion` and `/do-plan` subagents onto it.
2. `claude` in `defaults.design_review.builtin` validates but is **silently dropped** —
   `mesh-design-review` Step 5.1 expands only `codex` and `gemini`, and its Q1 has no
   `claude` option. Design review has never once run a built-in Claude reviewer. Task 7
   fixes both halves. This is the reason the plan makes "a silently ignored list" a
   fail-closed validation error rather than a warning.

### Decisions with rationale (do not re-litigate)

- **Config shape: catalog + per-preset selection** (`claude.models` + `defaults.<preset>.claude_models`).
  Rejected: a single `claude.models` list doubling as the default set — `default` mode would
  then always run the whole catalog and the ★-recommended marker in the UI would degenerate
  (a star on everything). Also rejected: presets with no catalog — a model would have to be
  put into a preset just to appear in the UI, and would instantly become ★-recommended,
  destroying the "available vs recommended" distinction.
- **Fallback when `claude_models` is absent = exactly one reviewer, as today.** Explicitly
  chosen over "fall back to the whole catalog": the user's existing presets must not change
  behaviour the moment a `claude:` section appears, and the alternative would silently
  triple token spend on upgrade.
- **`claude` in `builtin` stays the gate.** `claude_models` set without `claude` in the same
  preset's `builtin` is a hard error, not a warning — a silently ignored list is precisely
  the bug being fixed elsewhere in this change.
- **No enum of model names.** Charset only, via the existing `IDENT_RE`. This is a standing
  project rule (see `runtime.dispatch_model` and `codex.reasoning_level`): a new model must
  never require a plugin release.
- **The catalog is a flat list of strings, not `{id, label}` objects.** Task-tool `model:`
  values are short self-describing aliases (`opus`, `fable`), so a label adds nothing. If
  labels are ever needed, the catalog can be widened to objects without breaking the
  line-per-entry output of `list-claude-models`.
- **`list-claude-models` prints only the id** — deliberately unlike `list-models`, which
  prints `<id>|<label>`. Do not "fix" this into pipe format for symmetry.
- **`runtime.dispatch_model` is not renamed, split or repurposed.** It keeps governing the
  wrappers, `review-discussion` and `/do-plan`.

### Edge cases the plan already accounts for — do not undo them

- `validate_defaults()` must call `validate_claude()` itself, not rely on `validate_all()`.
  `cmd_get_defaults` runs **only** `validate_defaults` (typed-getter principle), so without
  that call a scalar `claude: false` reaches a raw jq index and exits 5 with
  "Cannot index boolean".
- In jq, `null | length` is `0`. A `.claude_models | length` check therefore passes even
  when the key is absent entirely — Test 50 uses `has("claude_models")` for the real RED.
  Do not simplify it back to a length check.
- `/mesh-review` Step 5b (team mode) delegates its rules to Step 5a but *also* states
  `DISPATCH_MODEL` goes on every teammate. Task 6 step 5f amends it; skipping that leaves
  the two steps contradicting each other and team mode collapsing all claude reviewers onto
  one model.
- `/mesh-design-review` picks reviewers on iteration 1 and reuses the set for every later
  iteration. `SELECTED_CLAUDE_MODELS` must be added to the remembered set, or iteration 2
  silently falls back to a single reviewer.
- Tests 31 and 32 already validate and export from `config.example.yaml`. Task 5 edits that
  file — both must stay green.
- `subagent_type: "general-purpose"` is a **built-in** agent type and is NOT
  `claude-mesh:`-namespaced. Plugin agents are.
- In design review the claude reviewer receives the composed Step 4 prompt **directly** — no
  `Execute this prompt via…` wrapper, no skill invocation. That prompt is already
  self-contained.
- Claude reviewers create no `runs/<engine>/…` directory. They are outside the disk-watch /
  ping loop and outside `verify-delegation.sh` entirely; in the Step 6.0 roster they get an
  `INLINE` label that the orchestrator writes, not a script verdict.

### Warnings and limitations

- **There is no way to verify a subagent really executed on the requested model.** The
  orchestrator cannot see Task metadata, and asking the model "who are you" is unreliable.
  The design accepts this and relies on an unsupported model name failing the dispatch
  outright. Do not invent a guard for it; if you think you have found a mechanism, raise it
  with the user rather than adding it.
- **Token cost is multiplicative.** N Claude models = N full reviews, on top of codex and
  every ext-claude model. Keep the cost note in `config.example.yaml`.
- **Never edit `config.yaml`.** Agents surface validation errors to the user; the user
  edits. Task 9 (smoke) therefore requires the user to add the `claude:` section by hand
  before it can run.
- `skills/shared/verify-delegation.sh` is not part of this change. Leave it alone.
- `die`/`warn` messages are English; user-facing prose inside `commands/*.md` and
  `skills/*/SKILL.md` is Russian. Both conventions are already established in the repo —
  keep them separated.
- After every task: `bash skills/shared/tests/test-config-loader.sh` must end
  `=== Summary: N passed, 0 failed ===`. One commit per task. Never push.

## PLAN QUALITY WARNING

The plan was written for a large task and may contain:
- Errors or inaccuracies in implementation details
- Oversights about edge cases or dependencies
- Assumptions that don't match the actual codebase
- Missing steps or incomplete instructions

**If you notice any issues during implementation:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why the plan doesn't work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around plan issues or make significant deviations without user approval.
