# Design: Fable everywhere — switch the delegation-model policy from Opus to Fable

**Date:** 2026-06-10
**Status:** Approved (brainstorming session)
**Branch:** feature/fable-model

## Context

claude-mesh enforces a "never delegate to cheaper models" policy: every subagent dispatch during plan execution must run on the top-tier Claude model, preventing the controller from "saving" tokens on simple subtasks. The policy was written when Claude Opus was the top tier and hardcodes `opus` across the repo.

Anthropic released Claude Fable 5 (`claude-fable-5`) — a new tier above Opus (pricing $10/$50 per MTok vs $5/$25 for Opus 4.8). The `fable` alias is accepted by the Claude Code Agent tool (model enum: `sonnet`, `opus`, `haiku`, `fable`) and by agent frontmatter. Opus is now itself a "cheaper" model relative to the top tier, so it joins the forbidden-downgrade list.

## Decision

Hardcode `fable` everywhere the policy names a model (simple swap). Alternatives considered and rejected:

- **Config-driven model** (`runtime.dispatch_model` in config.yaml): agent frontmatter cannot read config — 8 agent files would stay hardcoded anyway, so it only half-solves the problem while adding loader/validation/docs/tests burden for a value that changes roughly once a year. A literal value in the command text is also more reliable for the LLM controller than an indirection it must carry through the session.
- **Intent-only wording** ("strongest available model"): the dispatch parameter must be a literal anyway; vaguer instructions for the controller.

Descriptive mentions of the *session's* model (FLIP diagnostics) become model-neutral so they don't go stale at the next family rename.

## Changes

### 1. `commands/do-plan.md` — policy (3 edits)

- Step 3 status line example: `Opus everywhere, full review rigor` → `Fable everywhere, full review rigor`
- Step 5 heading: `### Model: Opus everywhere` → `### Model: Fable everywhere`
- Step 5 first bullet: `**must explicitly set `model: "opus"`**` → `**must explicitly set `model: "fable"`**`; and `Do not pick `sonnet` / `haiku` for "cheap" or "simple" subtasks.` → `Do not pick `opus` / `sonnet` / `haiku` for "cheap" or "simple" subtasks.`

Other Step 5 bullets (external reviewers, "if a subagent type does not accept a model override, accept the default") stay unchanged.

### 2. `agents/*.md` — frontmatter (8 files)

`model: opus` → `model: fable` in: `codex-executor.md`, `codex-code-reviewer.md`, `codex-native-reviewer.md`, `gemini-executor.md`, `gemini-code-reviewer.md`, `ext-claude-executor.md`, `ext-claude-code-reviewer.md`, `review-discussion.md`.

This default applies when an agent is dispatched without an explicit model override (e.g. via `/mesh-review` outside of do-plan).

### 3. Model-neutral FLIP-diagnostics wording

These spots describe "the model of the current session", whatever it is — neutral wording won't go stale:

- `commands/mesh-review.md` (4 spots):
  - "they skip their `*-code-review` skill and self-review inline on this session's Opus" → "…on this session's own model"
  - "`FLIP` (exit 3) — no run dir → self-reviewed on Opus → **re-dispatch**" → "…self-reviewed on the session model…"
  - "self-review on Opus / killed mid-flight" → "self-review on the session model / killed mid-flight"
  - "A flipped wrapper is Opus reviewing its own session" → "A flipped wrapper is the session's model reviewing its own work"
- `skills/shared/verify-delegation.sh` (3 spots):
  - header comment "…self-review inline on the session's Opus — a false cross-validation…" → "…on the session's own model…"
  - exit-code comment "FLIP=3 … (self-reviewed on Opus)" → "…(self-reviewed on the session model)"
  - runtime emit string: `emit FLIP "no run dir under … — reviewer did not delegate (self-reviewed on Opus)" 3` → "…(self-reviewed on the session model)". Tests assert only the `FLIP` verdict keyword, not the message text — safe to change.
- `skills/shared/tests/test-verify-delegation.sh` (1 spot): header comment "self-reviewed on Opus (FLIP)" → "self-reviewed on the session model (FLIP)"

## Out of scope

- `config.example.yaml` (env-var mapping comment): the names `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` + `CLAUDE_CODE_SUBAGENT_MODEL` are fixed by Claude Code itself (ext-claude alt-provider mapping) — unrelated to the delegation policy.
- `skills/shared/tests/test-config-loader.sh` — tests of that mapping.
- Release / CHANGELOG bump (standard-version) — done separately by the maintainer as usual.

## Verification

1. All bash test suites under `skills/shared/tests/` stay green (text edits touch no logic).
2. Sweep check: `grep -rniE '\bopus\b' --exclude-dir=.git .` (with `docs/superpowers/` excluded) matches only `config.example.yaml` and `skills/shared/tests/test-config-loader.sh`.
3. Runtime smoke: dispatch one subagent with `model: "fable"` and confirm the current Claude Code version accepts the alias.

## Risks

- `fable` alias unsupported on older Claude Code versions → dispatch error at runtime. Accepted: this is a personal plugin run on current CC; the alias is present in the current session's Agent tool enum.
