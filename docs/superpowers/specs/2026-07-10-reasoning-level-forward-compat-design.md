# Forward-compatible reasoning_level validation + config-driven codex/gemini in reviews

- **Date:** 2026-07-10
- **Status:** approved (brainstorming complete)
- **Release target:** 0.4.0

## Problem

OpenAI introduced new reasoning-effort levels with gpt-5.6 (`ultra`; the server also
accepts `none`/`minimal`, which the loader never allowed). A user config with

```yaml
codex:
  model: gpt-5.6-sol
  reasoning_level: ultra
```

breaks claude-mesh 0.3.0 in a cascade:

1. `validate_codex_gemini()` (`skills/shared/config-loader.sh:246-248`) hard-fails on
   any `reasoning_level` outside `low|medium|high|xhigh`.
2. `cmd_export` runs `validate_all`, so the codex-section error kills `export <model>`
   for **every** ext-claude executor (glm/qwen/deepseek/kimi/minimax) during
   `/mesh-review` and `/mesh-design-review` — models unrelated to codex.
3. Blocked reviewer subagents "unblock" themselves by editing the user's
   `config.yaml` (`ultra` → `xhigh`). The user restores `ultra`, the next review
   flips it back. Skill wording *"If any check fails, stop and help user fix it"*
   invites exactly this.

Verified live on 2026-07-10: `codex exec -m gpt-5.6-sol -c model_reasoning_effort="ultra"`
succeeds end-to-end (also on gpt-5.5); the codex CLI passes unknown values through
verbatim and the server rejects truly invalid ones with a clear HTTP 400. The
validator — not codex, not OpenAI — is the single point of failure.

A second finding: the `codex:` / `gemini:` config values are dead — nothing calls
`get-codex`/`get-gemini`. Review flows run codex on skill defaults (`gpt-5.5`/`xhigh`)
unless the orchestrator explicitly passes MODEL/REASONING_LEVEL, so the user's
`model: gpt-5.6-sol` + `reasoning_level: ultra` never reached reviews at all.

## Goals

1. An unknown `codex.reasoning_level` must never break anything — not `export`, not
   reviews, not future OpenAI levels (close the class, not the value).
2. `codex:`/`gemini:` config sections become the actual source of model/effort for
   `/mesh-review` and `/mesh-design-review`.
3. Agents never edit `config.yaml`; only the user does.
4. Ship as plugin release 0.4.0 (no cache patching).

## Non-goals

- No test harness added to the repo (fixture-based manual verification only).
- No changes to executor skill fallback contracts (codex-exec keeps `gpt-5.5`/`xhigh`
  defaults when the caller specifies nothing).
- No cleanup of other dead code paths.

## Design

### 1. config-loader.sh

- Add `warn()` next to `die()`: prints `config-loader: WARN: <msg>` to stderr,
  does not exit.
- `validate_codex_gemini()` — level policy changes:
  - Known values (silent): `none|minimal|low|medium|high|xhigh|ultra`
    (today's server-accepted set).
  - Unknown values: `warn "codex.reasoning_level: unknown value \"$level\" — passing
    through (codex CLI will validate)"` and continue. No `die`.
  - `codex.model` required when `codex:` present — stays `die` (structural error).
  - `gemini.model` required when `gemini:` present — stays `die`.
- `cmd_export` — scoped validation (replaces `validate_all`):
  `validate_providers; validate_models; validate_runtime`. Runtime stays because
  export reads `runtime.timeouts.*`. The codex/gemini/defaults sections cannot
  affect an ext-claude run, so their errors must not block it. This follows the
  loader's own typed-getter principle (iter-2 CONCERN-2/3). Update the CRITICAL-10
  comment: fast-fail is preserved for the sections export actually uses.
- `cmd_validate` — unchanged (`validate_all`); it remains the full config lint.
  With the new policy an unknown level yields rc=0 plus a stderr warning.
- `cmd_get_codex` / `cmd_get_gemini` — code unchanged; they now inherit the
  warn-not-die level policy. Output contract stays `<model>|<reasoning_level>`.

### 2. Config wiring in review flows

Files: `skills/mesh-design-review/SKILL.md`, `commands/mesh-review.md`.

- In pre-flight (next to the existing `dispatch_model` read):
  - If `get-flag has_codex` = 1: `CG=$("$LOADER" get-codex)` →
    `CODEX_MODEL=${CG%%|*}`, `CODEX_REASONING_LEVEL=${CG##*|}`;
    empty level → skill default (`xhigh`).
  - If `get-flag has_gemini` = 1: `GEMINI_MODEL=$("$LOADER" get-gemini)`.
  - `get-codex`/`get-gemini` failure (rc≠0, e.g. missing `codex.model`) → surface
    the loader error and stop, consistent with the existing invalid-config
    pre-flight handling.
- Precedence rule, documented in both files:
  **explicit invocation parameter > config.yaml > skill default (`gpt-5.5`/`xhigh`)**.
- Dispatch blocks are untouched — they already use
  `MODEL={CODEX_MODEL}, REASONING_LEVEL={CODEX_REASONING_LEVEL}` placeholders;
  only the variables' source changes. Gemini dispatch gains `MODEL={GEMINI_MODEL}`
  when set.
- Doc updates in `codex-exec`, `codex-code-review`, `codex-review-native`,
  `mesh-design-review`: reasoning-level tables gain `ultra` (and mention
  `none`/`minimal`), plus a note that unknown levels are passed through to codex.
  The lone-`|` pitfall note for `get-codex` remains valid and stays.

### 3. Guardrail: config.yaml is user-owned

Canonical sentence, added verbatim wherever a config gate can fail:

> If any check fails, STOP and report the error to the user verbatim.
> Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.

- Replaces *"If any check fails, stop and help user fix it"* in:
  `skills/codex-exec/SKILL.md`, `skills/codex-code-review/SKILL.md`,
  `skills/gemini-exec/SKILL.md`, `skills/gemini-code-review/SKILL.md`.
- Added after the `config-loader export` gate in `skills/ext-claude-exec/SKILL.md`
  and `skills/ext-claude-code-review/SKILL.md`.
- Error tables in `commands/mesh-review.md` / `skills/mesh-design-review/SKILL.md`:
  "fix the config, retry" rewordings make explicit that the **user** edits
  `config.yaml`; agents only surface the error.

### 4. Documentation

- `config.example.yaml`: `reasoning_level` comment lists
  `none/minimal/low/medium/high/xhigh/ultra` and notes unknown values pass through
  with a warning.
- `README.md`: codex/gemini config section documents that `/mesh-review` and
  `/mesh-design-review` now take model + reasoning level from `config.yaml`.

### 5. Verification (no repo test harness)

Fixture configs in the session scratchpad, run against the branch loader:

| Fixture | Expectation |
|---|---|
| `reasoning_level: ultra` | `export <model>` rc=0, no warn; `get-codex` rc=0 prints `gpt-5.6-sol\|ultra`; `validate` rc=0 |
| `reasoning_level: bogus-zzz` | same rc=0 paths, single `WARN` on stderr from `get-codex`/`validate`; `export` rc=0 with **no** warn (codex not validated there) |
| no `codex:` section | `get-flag has_codex` = 0; `export` rc=0; `get-codex` prints `\|` |
| `codex:` present, `model:` missing | `get-codex`/`validate` die; `export` rc=0 (scoped) |
| broken `providers[].base_url` | `export` still dies (scoped validation still guards its own sections) |

Post-release smoke: one `/mesh-design-review` run confirming codex dispatch uses
`gpt-5.6-sol` + `ultra` from config.

### 6. Release 0.4.0

- Bump `.claude-plugin/plugin.json` to 0.4.0; CHANGELOG entries:
  - **Fixed:** unknown `codex.reasoning_level` no longer aborts `export`/all
    ext-claude executors (warn + passthrough; `ultra` incident).
  - **Changed:** `cmd_export` validates only the sections it uses
    (providers/models/runtime).
  - **Added:** reviews read codex model/reasoning level and gemini model from
    `config.yaml`; user-owned-config guardrail wording in all pre-flights.
- Flow (mirrors 0.3.0): implementation commits on
  `feature/reasoning-level-forward-compat` → `git rm -r docs/superpowers` before PR
  (spec/plan stay in branch history; pre-existing untracked `docs/superpowers/plans/*`
  from earlier work are never staged — all commits add files by explicit path) →
  `chore(release): 0.4.0` on the branch → PR → merge →
  tag `claude-mesh--v0.4.0` on the release commit → push tag.
- The installed 0.3.0 cache is left untouched; the user updates the plugin from
  the marketplace after release.
