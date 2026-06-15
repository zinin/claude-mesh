# Design: configurable dispatch model — optional config, else inherit the session

**Date:** 2026-06-15
**Status:** Approved (brainstorming session)
**Branch:** feature/configurable-dispatch-model

## Context

claude-mesh enforces a "never delegate to cheaper models" policy: during plan
execution and external review, subagents should run on a top-tier model rather
than the controller silently economizing on "simple" subtasks. Releases hardcoded
the tier as a literal: `opus` in 0.1.0, then `fable` (`claude-fable-5`) in 0.2.0.

The literal lives in two structurally different places:

1. **Policy prose** — `commands/do-plan.md` (and the dispatch step of
   `commands/mesh-review.md`). Read by the LLM controller at runtime, so a config
   value *can* reach it.
2. **Agent frontmatter** — `agents/*.md` (8 files), static YAML `model: fable`.
   Read by Claude Code when the plugin loads; it cannot interpolate config.yaml
   values. This is the barrier that made 0.2.0 reject the config-driven option.

The literal turned out to be brittle: `fable` was pulled from access within days
of the 0.2.0 release, which breaks every dispatch that names it. The "changes
once a year" assumption behind hardcoding was wrong. We want the dispatch tier to
be configurable so a model opening or closing never requires editing skills or
agents.

Key Claude Code mechanic that unlocks this: an agent's frontmatter `model:` is
only a **default**. The caller may override it by passing `model:` in the dispatch.
If frontmatter has no `model:` **and** the caller passes none, the subagent
**inherits the session model** (the model the user's `/model` selected) — which is
by definition a currently-available model.

## Decision

Make the dispatch tier a **hybrid, optional** setting. No model literal remains in
skills or agents.

- Single optional knob: `runtime.dispatch_model` in config.yaml.
- **Set** → mesh commands pass `model: "<value>"` on every dispatch.
- **Unset / no config.yaml** → commands pass no `model:` → subagents inherit the
  session model.

The "don't economize" policy is preserved by re-wording, not by a literal: *never
pass a model cheaper than the resolved one; when no model is resolved, inherit the
session model — never pick a cheaper one to save tokens.*

Alternatives considered and rejected:

- **Codegen flip-script** (one script rewrites all 9 spots, commit per flip):
  simpler runtime and keeps a literal the controller can't fumble, but every flip
  mutates tracked plugin files → a release/patch for users, and the value lives in
  version control rather than per-user space.
- **De-pin only, always inherit the session** (no config knob at all): zero
  machinery and never breaks, but removes the ability to *force* a specific tier
  independent of the session. The hybrid keeps that ability as an opt-in.

## Changes

### 1. `agents/*.md` — frontmatter (8 files)

Delete the `model: fable` line from: `codex-executor.md`, `codex-code-reviewer.md`,
`codex-native-reviewer.md`, `gemini-executor.md`, `gemini-code-reviewer.md`,
`ext-claude-executor.md`, `ext-claude-code-reviewer.md`, `review-discussion.md`.

With no frontmatter pin, a dispatch with an explicit `model:` uses that model; a
dispatch without one inherits the session model.

### 2. config schema — new optional key

Add an optional `runtime.dispatch_model` (string) under the existing `runtime`
section:

```yaml
runtime:
  dispatch_model: opus      # optional; empty / key absent = inherit the session model
```

Validation in `validate_runtime` is **minimal and forward-compatible**: if the key
is present it must be a non-empty string matching the safe charset `[A-Za-z0-9._-]`
(covers aliases like `opus`/`fable` and full ids like `claude-fable-5`). **No enum**
— a new model alias must never require a validator change. The charset also
prevents the value from breaking out of the jq/bash handling in config-loader.

### 3. `skills/shared/config-loader.sh` — read path

Expose `dispatch_model` through the existing `get-flag` verb (whitelist in the
`get-flag` `case`) and include it in the `get-runtime` JSON. Return-code semantics
mirror `do_plan_default_stop_tokens`:

- value present, config valid → print value, rc 0
- key absent, config valid → print empty, rc 0
- config.yaml absent → rc 2 (caller treats as "inherit")

Read form: `"$LOADER" get-flag dispatch_model`.

### 4. `commands/do-plan.md` — policy

In the existing config-reading Bash step (the one that resolves `DEFAULT_STOP`),
also resolve `dispatch_model` with the same rc-tolerant idiom already used there
(rc 0 with value → use it; rc 0 empty or rc 2 → inherit; any other rc → propagate
the loader error). Then:

- Rename the model-policy heading `### Model: Fable everywhere` to a model-neutral
  one (e.g. `### Model: dispatch tier`).
- Re-word the first bullet to be model-literal-free: *if `dispatch_model` resolved,
  set `model: "<value>"` on every Agent dispatch; if it did not resolve, omit
  `model:` so subagents inherit the session model, and never explicitly pass a
  cheaper model to economize.* Remove the absolute forbidden-model list
  (`opus` / `sonnet` / `haiku`) that 0.2.0 kept in this bullet — "cheaper" is now
  relative to the resolved/session model, so no literal belongs here. Keep the
  other bullets unchanged (external reviewers; "if a subagent type does not accept
  a model override, accept the default").
- The Step 3 status line shows the resolved value (or `session-inherited`).

### 5. `commands/mesh-review.md` (and `mesh-design-review.md` if it spawns agents)

Alongside the existing `get-runtime` read, resolve `dispatch_model`. In the Step 5
dispatch, pass `model: "<value>"` to each reviewer dispatch when set; omit it
otherwise (inherit). This replaces the previous reliance on the agents' frontmatter
`fable` default. During planning, grep all `subagent_type:` / Agent-dispatch points
in commands and apply the same read-and-pass rule.

### 6. `config.example.yaml` — documentation

Document `runtime.dispatch_model` under the existing `runtime` section: optional;
set = force this tier on all mesh dispatches, empty/absent = inherit the session
model; accepts any Agent-tool model alias or id; flip it when a model opens or
closes — no plugin release needed.

### 7. `README.md`

Update the dependency bullet (~line 54): drop the hard requirement that the Claude
Code build's Agent model enum include the `fable` alias. Explain the default
(inherit the session model) and the optional `runtime.dispatch_model` knob.

## Out of scope

- **ext-claude provider model mapping** — `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`,
  `CLAUDE_CODE_SUBAGENT_MODEL`, per-model `subagent_model` for the inner `claude -p`.
  A separate layer; unchanged.
- **FLIP / delegation diagnostics wording** — already made model-neutral in 0.2.0.
- **CHANGELOG / version bump** — done separately via standard-version by the maintainer.

## Verification

1. All bash test suites under `skills/shared/tests/` stay green.
2. `test-config-loader.sh` gains cases: `dispatch_model` set → returned by
   `get-flag`; key absent → empty; invalid charset → validation error.
3. Sweep confirms no model literal remains in agent frontmatter or dispatch-policy
   prose:
   `grep -rniE '\b(fable|opus)\b' --exclude-dir=.git --exclude-dir=docs --exclude-dir=.idea .`
   Expected remaining matches only: ext-claude config docs/tests
   (`ANTHROPIC_DEFAULT_OPUS_MODEL` etc.), the example `dispatch_model` value in
   `config.example.yaml`, and historical `CHANGELOG.md` entries. No match in
   `agents/*.md` or the do-plan / mesh-review policy text.
4. Runtime smoke — two paths: (a) with `runtime.dispatch_model: opus` set, a mesh
   dispatch runs on opus; (b) with the key removed, a dispatch inherits the session
   model and succeeds with `fable` unavailable.

## Risks

- **Controller must pass the resolved `model:`** on premium paths. This is the same
  expectation as today's "set `model: fable`" prose; the value is now surfaced
  concretely in the Step 3 status line, so the burden does not increase. The bash
  read itself is deterministic, not LLM-dependent.
- **Uncovered dispatch paths inherit the session model.** A direct `@codex-executor`
  outside a mesh command, with no explicit `model:`, runs on the session model
  rather than a forced tier. Accepted: these are thin wrapper agents that
  immediately shell out to codex/gemini/ext-claude, so their own orchestrating
  model barely matters.
- **A misconfigured `dispatch_model`** (a closed/invalid model name) errors at
  dispatch time. Accepted and self-inflicted; the fix is a one-line config edit,
  and the default (inherit) never has this failure mode.
