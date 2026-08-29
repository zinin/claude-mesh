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

✅ Done — see commit(s): `91edfb8`

---

### Task 2: The `grok:` config section

✅ Done — see commit(s): `571d5f5`

---

### Task 3: `grok` in the defaults presets

✅ Done — see commit(s): `b05833b`, `604bc53`

---

### Task 4: Config example and schema documentation

✅ Done — see commit(s): `2ee8623`

---

### Task 5: Move the stream-json report renderer into `shared/`

✅ Done — see commit(s): `85f0463`, `3c60bec`

---

### Task 6: The `grok-exec` skill and its executor agent

✅ Done — see commit(s): `51abfba`, `0571072`

---

### Task 7: The `grok-code-review` skill and reviewer agent

✅ Done — see commit(s): `9d6f8e2`, `7014162`

---

### Task 8: `grok` in the delegation guard

✅ Done — see commit(s): `bfdd6c3`

---

### Task 9: `grok` in the run watcher

✅ Done — see commit(s): `3207ea1`

---

### Task 10: `grok` in the environment probe

✅ Done — see commit(s): `5a0e13b`, `043171c`

---

### Task 11: `/mesh-review` integration

✅ Done — see commit(s): `f3b8c2d`, `aaae02c`

---

### Task 12: `/mesh-design-review` integration

✅ Done — see commit(s): `e8c2f01`, `1f5bffa`

---

### Task 13: Fresh-session prompts, README and CHANGELOG

✅ Done — see commit(s): `c5fdacb`, `a84ca8c`

---

### Task 14: Acceptance — a live review with grok

✅ Done — see commit(s): `d8bfb7b` (the acceptance record). The run also produced three
branch fixes: `56f9a22` (the example's grok catalog could not run beside its own effort
value), `f8edb51` (four auto-fixes plus the trailing-line loss in every stream consumer)
and `8c8583f` (a referenced broken grok catalog now degrades grok instead of grounding the
environment). Full evidence in the SDD ledger.

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
