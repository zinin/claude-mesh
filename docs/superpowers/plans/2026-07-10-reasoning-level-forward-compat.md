# Forward-Compatible reasoning_level Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An unknown `codex.reasoning_level` (e.g. gpt-5.6's `ultra`) never breaks the loader, ext-claude executors, or reviews; codex executors resolve model/level from `config.yaml`; agents never edit user config; ship as plugin release 0.4.0.

**Architecture:** Three layers: (1) `config-loader.sh` warns instead of dying on unknown reasoning levels and `cmd_export` validates only the sections it reads; (2) codex executor skills resolve MODEL/REASONING_LEVEL via `get-codex` with `gpt-5.5`/`xhigh` fallbacks, mirroring the existing gemini-exec idiom; (3) a canonical guardrail sentence in every pre-flight forbids agents from editing `config.yaml`.

**Tech Stack:** bash 4+, jq, Python-yq (kislyuk); plugin markdown skills; no repo test framework — a throwaway fixture harness under `~/tmp/claude-mesh-loader-tests/`.

**Spec:** `docs/superpowers/specs/2026-07-10-reasoning-level-forward-compat-design.md` (same branch).

## Global Constraints

- Branch: `feature/reasoning-level-forward-compat` (already exists; spec committed there).
- Repo root: `/opt/github/zinin/claude-mesh`. All paths below are relative to it.
- `git add` ONLY by explicit file path. NEVER `git add -A` / `git add .` — the repo contains pre-existing untracked `docs/superpowers/plans/2026-06-*` files that must stay untracked.
- NEVER edit `~/.claude/plugins/data/claude-mesh-zinin/config.yaml` (user-owned) or anything under `~/.claude/plugins/cache/` (no cache patching — release only).
- Canonical guardrail sentence (use verbatim where a task says so): `If any pre-flight check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.`
- Precedence rule everywhere: explicit caller parameter > `config.yaml` > built-in fallback (`gpt-5.5` / `xhigh`).
- Known reasoning levels (silent in validator): `none|minimal|low|medium|high|xhigh|ultra`. Unknown → WARN + pass through.
- Conventional commit messages, exactly as given per task.
- Fixture harness lives at `~/tmp/claude-mesh-loader-tests/` (NOT in the repo; deleted in Task 10).

---

### Task 1: Fixture test harness (RED baseline)

✅ Done — no repo commits by design (fixture harness at `~/tmp/claude-mesh-loader-tests/`; RED baseline verified `passed=8 failed=8`)

---

### Task 2: Loader — warn() + level passthrough policy

✅ Done — see commit: `6e744d9`

---

### Task 3: Loader — scope cmd_export validation

✅ Done — see commit: `a7af85e`

---

### Task 4: codex-exec — resolve MODEL/REASONING_LEVEL from config.yaml

✅ Done — see commit: `ec2afd6`

---

### Task 5: codex-code-review + codex-review-native — config-driven params

✅ Done — see commit: `0b0f0a8`

---

### Task 6: mesh flows — executor-resolved codex params + user-owned-config wording

✅ Done — see commit: `ad0b357`

---

### Task 7: Guardrail sentence in all remaining pre-flights

✅ Done — see commit: `22ffb39`

---

### Task 8: config.example.yaml + README

✅ Done — see commit: `7534604`

---

### Task 9: Full verification sweep

✅ Done — no commits (release gate): sweep 11/11 green, independently reproduced by a second agent

---

### Task 10: Pre-PR cleanup, release 0.4.0, PR, tag

**Files:**
- Delete (from git): `docs/superpowers/` (spec + this plan; they stay in branch history)
- Modify: `CHANGELOG.md` (insert under `## [Unreleased]`), `.claude-plugin/plugin.json:3`
- Delete (disk): `~/tmp/claude-mesh-loader-tests/`

- [ ] **Step 1: Remove planning docs from the PR diff (user's workflow rule)**

```bash
cd /opt/github/zinin/claude-mesh
git rm -r docs/superpowers
git commit -m "docs: remove superpowers planning docs before PR"
git status --short   # expect: ?? docs/superpowers/plans/ (only the pre-existing untracked 2026-06-* files remain on disk)
```

- [ ] **Step 2: CHANGELOG entry**

In `CHANGELOG.md`, replace:
```
## [Unreleased]
```
with:
```
## [Unreleased]

## [0.4.0] - 2026-07-10

### Fixed
- `config-loader.sh` no longer aborts on an unknown `codex.reasoning_level`
  (e.g. the new gpt-5.6 `ultra`): unknown levels WARN and pass through — the
  codex CLI/API is the final validator. Previously a single unknown level in
  the `codex:` section killed `export` for **every** ext-claude executor
  mid-review and pushed blocked review subagents into "fixing" the user's
  config (`ultra` → `xhigh` flips).

### Changed
- `cmd_export` validates only the sections it reads (providers/models/runtime).
  Errors in `codex:` / `gemini:` / `defaults:` can no longer block ext-claude
  runs. `validate` remains the full-config lint.
- Known reasoning levels extended to `none|minimal|low|medium|high|xhigh|ultra`.

### Added
- codex executors (`codex-exec`, `codex-code-review`, `codex-review-native`)
  resolve MODEL / REASONING_LEVEL from `config.yaml` (`codex.model` /
  `codex.reasoning_level`) when the caller passes none — mirroring the existing
  gemini-exec idiom. `/mesh-review` and `/mesh-design-review` become
  config-driven for codex transitively. Precedence: explicit caller parameter >
  config.yaml > `gpt-5.5`/`xhigh` fallbacks.
- Guardrail wording in every pre-flight: on config failures agents STOP and
  report verbatim; `config.yaml` is user-owned and never edited by agents.
```

- [ ] **Step 3: Version bump**

In `.claude-plugin/plugin.json`, replace `"version": "0.3.0",` with `"version": "0.4.0",`.

- [ ] **Step 4: Release commit (mirrors 0.3.0: release commit lives on the feature branch)**

```bash
cd /opt/github/zinin/claude-mesh
git add CHANGELOG.md .claude-plugin/plugin.json
git commit -m "chore(release): 0.4.0"
```

- [ ] **Step 5: Push branch + open PR**

```bash
cd /opt/github/zinin/claude-mesh
git push -u origin feature/reasoning-level-forward-compat
gh pr create \
  --title "fix: forward-compatible reasoning_level validation + config-driven codex executors" \
  --body "## Problem
A \`codex.reasoning_level\` the 0.3.0 validator does not know (gpt-5.6's \`ultra\`) made \`cmd_export\` die for every ext-claude executor mid-review; blocked subagents then edited the user's config.yaml (\`ultra\` -> \`xhigh\` flips). The codex: config values were also dead — nothing read them.

## Fix
- config-loader: unknown reasoning levels WARN + pass through (codex CLI/API is the final validator); known set extended with none/minimal/ultra; \`cmd_export\` validates only providers/models/runtime (typed-getter principle, iter-2 CONCERN-2/3).
- codex-exec / codex-code-review / codex-review-native resolve MODEL/REASONING_LEVEL from config.yaml when the caller passes none (mirrors gemini-exec). Reviews become config-driven transitively.
- Canonical guardrail in every pre-flight: STOP and report; config.yaml is user-owned, agents never edit it.
- Release 0.4.0.

## Verification
16/16 fixture assertions green (ultra / bogus level / no codex / codex-without-model / broken provider across export, get-codex, get-flag, validate); live checks against a real config with \`ultra\` pass; consistency greps clean."
```

- [ ] **Step 6: CHECKPOINT — wait for the user**

STOP here. The user reviews and merges the PR (do not merge it yourself).

- [ ] **Step 7: After merge — tag the release commit and push the tag (mirrors 0.3.0: tag points at the `chore(release)` commit, not the merge commit)**

```bash
cd /opt/github/zinin/claude-mesh
git switch master && git pull
REL=$(git log --format='%H %s' -20 | awk '/chore\(release\): 0\.4\.0/ {print $1; exit}')
git tag "claude-mesh--v0.4.0" "$REL"
git push origin "claude-mesh--v0.4.0"
git tag --points-at "$REL"   # expect: claude-mesh--v0.4.0
```

- [ ] **Step 8: Cleanup + user hand-off**

```bash
rm -rf ~/tmp/claude-mesh-loader-tests
```

Tell the user: update the plugin from the marketplace (new version 0.4.0), then re-run a `/mesh-design-review` smoke to confirm codex runs with `gpt-5.6-sol` + `ultra` from config. The installed 0.3.0 cache was not touched.
