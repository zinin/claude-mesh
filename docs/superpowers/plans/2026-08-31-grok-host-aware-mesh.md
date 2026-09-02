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
✅ Done — see commit(s): `6123a75`

### Task 2: `list-host-models.sh` — parse `grok models`
✅ Done — see commit(s): `575912d`

### Task 3: Engine `claude` on disk (`verify-delegation` + `watch-runs`)
✅ Done — see commit(s): `af2ad43`

### Task 4: `HOST_CLAUDE=1` in `ext-claude-exec`
✅ Done — see commit(s): `0a37c27`

### Task 5: `claude-code-review` skill and two agents
✅ Done — see commit(s): `f4e1088`

### Task 6: Wrapper agents — Skill tool dual-path and Grok wait
✅ Done — see commit(s): `323d7ab`

### Task 7: `resolve-plugin-root.sh` for skill bash blocks
✅ Done — see commit(s): `0de94c0`

### Task 8: Orchestrators — host detection, UI, `SELECTED_NATIVE_MODELS`
✅ Done — see commit(s): `9164417`, `63f756f`

### Task 9: Orchestrators — dispatch, wait, Step 6.0
✅ Done — see commit(s): `617b627`, `01e0e5b`

### Task 10: Preflight rows `native-models` and `claude-cli`
✅ Done — see commit(s): `514905e`, `827948c`

### Task 11: Example config, README, CHANGELOG
✅ Done — see commit(s): `12947f1`

### Post-implementation: review waves

Not plan tasks — recorded so the smoke below is run against the right tree.

- `e4bb7ec` — fixes for a Grok review of Tasks 1–11 (MODEL optional on the claude agents,
  `SKILL_BASE` find-fallback, `review-discussion` spawn on Grok, question-tool mapping,
  Step 0 no longer spawns Grok `claude` as `general-purpose`).
- `02cc219` — 16 auto-fixes from `/claude-mesh:mesh-review` (7 reviewers).
- `75d6d2e`, `f353ea6`, `b8df39b`, `d9a4797`, `38459e1`, `a05b837`, `117e0a2`, `6ff0ee8` —
  8 disputed issues decided under `autodecide`, one commit each with its full analysis.

Suite after all of it: 18 scripts, every one `rc=0`.

Second wave, 2026-09-02 — `/claude-mesh:mesh-review default` on Claude Code under
`--plugin-dir`, which is also Task 12 Step 4. Reviewers: claude:opus, claude:fable,
ext-claude zai/glm and deepseek/v4-pro (REAL); codex STALLED on the OpenAI quota.
- `fdee5a0` — 20 auto-fixes. Critical: `grok_child_of_self` globbed `sessions/*/subagents/`,
  one level shallower than the real `sessions/<cwd>/<parent id>/subagents/<child>/meta.json`,
  so `0c851d0` never matched a file on a live host (fixtures mirrored the mistake).
- `2d1d7bf` — resolver root-order / prose canary in `test-claude-cli-agents.sh`.
- six `autodecide` commits, one per decision: `0002b48`, `52351e2`, `ae805b0`, `d188ed9`,
  `a50e02f` (под вопросом), `f2dfa42`.
Suite after `fdee5a0`: 18 scripts, 1360 assertions, every one `rc=0`.

### Task 12: Manual smoke (not optional)

No code. Run on this machine after Tasks 1–11.

- [ ] **Step 1: Grok, temporary preset** with `native` + `native_models: [grok-4.6]` and existing wrappers. `/claude-mesh:mesh-review default`. Confirm native child has `model: grok-4.6`, no `runs/native/`, Step 6.0 INLINE. Wrappers write `runs/…`.

- [ ] **Step 2: Grok, 0.12.0 preset without `native`.** Confirm no host slugs start; `claude` goes to `claude -p` or degrades if `claude` is missing. This is the documented break — it must be visible.

- [ ] **Step 3: Claude Code, 0.12.0 preset.** Confirm 0.12.0 behaviour; transcript has Task, not `spawn_subagent`.

- [x] **Step 4: Claude Code, preset with `native` and `claude`.** One host set (opus/fable as configured), not two. ✅ 2026-09-02: `/mesh-review default` under `--plugin-dir`; `HOST=claude-code`, exactly two host reviewers (opus, fable) via Task, no native rows, no `spawn_subagent`; codex and two ext-claude wrappers dispatched, watched, verified, re-dispatched. Findings: second review wave above.

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
