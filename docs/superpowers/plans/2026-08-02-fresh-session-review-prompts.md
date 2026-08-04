# Fresh-Session Review Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two slash commands that hand a design+plan (or a finished implementation) to a fresh Claude Code session which reviews it — inside a sandbox whose plugin config, reachable providers and git remote differ from the generating session's — plus the environment probe that tells that session what it can actually use.

**Architecture:** The generators write a prompt file and never read `config.yaml`; the only statement they make about reviewers is "run the probe and pick from its OK rows". The probe (`skills/shared/preflight-env.sh`) runs inside the sandbox, reuses the existing `token-precheck.sh` / `ollama-precheck.sh` and reads config only through `config-loader.sh`. Two existing files gain one paragraph each so the loop closes: `mesh-design-review` Step 15 routes the next iteration into the new generator, `do-plan` Step 7 points at the code-review one.

**Tech Stack:** bash 4.0+ (GNU coreutils `timeout`), `curl`/`git` optional, Python-yq + jq behind `config-loader.sh`, Claude Code plugin markdown (`commands/*.md`, `skills/*/SKILL.md`).

**Spec:** `docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md`

## Global Constraints

- Design source of truth is the spec above. Every decision numbered there (1–6) is binding.
- Every config read goes through `skills/shared/config-loader.sh`. Raw `yq` is forbidden anywhere in this work.
- The probe **always exits 0** for any delivered verdict. A non-zero exit means the probe itself is broken — or was interrupted: on INT/TERM the trap cleans up and exits non-zero, an interrupt is not a verdict.
- Closed status set, nothing else may be printed in the status column: `OK`, `MISSING`, `NO-NETWORK`, `AUTH-FAILED`, `INVALID`, `SKIPPED`, `UNKNOWN`.
- Row format is exactly `printf '%-18s %-12s %s\n' "$name" "$status" "$detail"`. A name longer than 18 columns (`provider:openrouter`) overflows the pad — harmless, parsing is word-based; do not "fix" it by truncating names, and do not compute the width from the rows (it would mean buffering the table, and the rows are the only progress signal a 25-50 s run gives — see the comment at the `row()` helper).
- Row order: `plugin`, `yq` / `jq` (only when missing), `config`, `builtin-claude`, `claude-models`, `curl` (only when missing), `ext-claude-deps` (only when something is missing), `codex`, `gemini`, `provider:*` in order of first appearance in `models` (aggregate row `provider` instead, when providers are not probed at all), `git-remote`, `gh`, `glab`, `clipboard`, then `SUMMARY available:` and `SUMMARY unavailable:`.
- No secret ever reaches stdout or stderr. Exported env files are deleted through a `trap … EXIT`.
- Prechecks are invoked as `env -u SKIP_TOKEN_PRECHECK …`.
- Binaries resolve through `PREFLIGHT_CURL_BIN` (default `curl`), `PREFLIGHT_GIT_BIN` (default `git`), `PREFLIGHT_YQ_BIN` (default `yq`), `PREFLIGHT_JQ_BIN` (default `jq`) and `PREFLIGHT_EXT_DEPS_BINS` (default `claude bc python3`); budgets through `PREFLIGHT_HTTP_TIMEOUT` (default 5) and `PREFLIGHT_GIT_TIMEOUT` (default 8). `PREFLIGHT_CURL_BIN` governs only the probe's own HTTP checks; when it does not resolve, the borrowed prechecks are not invoked at all (provider rows → `UNKNOWN`). The ollama precheck receives its budget through env knobs (`OLLAMA_PRECHECK_TRIES=1`, attempt/tags timeouts = `PREFLIGHT_HTTP_TIMEOUT`). `PREFLIGHT_SKIP_NETWORK=1` skips every network probe (providers, codex/gemini heuristics, `git ls-remote`) — those rows read `UNKNOWN skipped by PREFLIGHT_SKIP_NETWORK`; each live network probe announces itself on stderr, stdout stays table-only.
- Generators must not call `config-loader.sh` and must not emit any model id, provider id or `defaults.*` preset from the local config.
- Slash commands are namespaced: `/claude-mesh:<name>`. Bare names do not resolve.
- Repo language convention: command files, skills and generated prompts are English; user-facing question strings inside `mesh-*` skills are Russian. Match the file you are editing.
- Test suites follow the house style: `set -u`, fixture config pinned via `export CLAUDE_PLUGIN_DATA=<tmpdir>`, `assert_*` helpers, PASS/FAIL counters, non-zero exit when `FAIL > 0`.
- Commit after every task. Never push; never open a PR.

---

## File Structure

| File | Responsibility |
|---|---|
| `skills/shared/preflight-env.sh` | The environment probe. One row per capability, a SUMMARY block, exit 0 |
| `skills/shared/tests/test-preflight-env.sh` | Its regression suite: fixture configs + shimmed `curl`/`git` |
| `skills/shared/tests/fixtures/valid-claude-models.yaml` | Fixture with a `claude.models` catalog (none of the existing fixtures has one) |
| `skills/shared/tests/fixtures/invalid-claude-scalar.yaml` | Fixture with valid providers/models and a scalar `claude: false` — the `claude-models INVALID` case |
| `skills/ext-claude-exec/ollama-precheck.sh` | Modify: env knobs `OLLAMA_PRECHECK_TRIES` / `OLLAMA_PRECHECK_ATTEMPT_TIMEOUT` / `OLLAMA_PRECHECK_TAGS_TIMEOUT`, defaults preserve current behaviour |
| `commands/design-review-fresh-session.md` | Generator → fresh session → `/claude-mesh:mesh-design-review`; entry and every later iteration |
| `commands/code-review-fresh-session.md` | Generator → fresh session → `/claude-mesh:mesh-review` after implementation |
| `skills/shared/tests/test-command-sync.sh` | Byte-identity guard for the two generators: the `DO NOT` gate and the `PREFLIGHT` block |
| `skills/mesh-design-review/SKILL.md` | Step 15 only: the "Новая итерация" branch targets the new generator |
| `commands/do-plan.md` | Step 7 only: point at the code-review generator; state what a sandbox cannot finish |
| `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md` | Recorded RED baseline + wording micro-test results |
| `README.md`, `CHANGELOG.md` | Session-helper list; `## [Unreleased]` entry |

---

### Task 1: Probe skeleton — rows, config detection, static rows

✅ Done — see commit(s): `f6f2a1e`, `ff5f780`

---

### Task 2: Provider probes

✅ Done — see commit(s): `40c3900`, `c77be62`

---

### Task 3: CLI, git and clipboard rows

✅ Done — see commit(s): `41791cf`, `fb92e95`

---

### Task 4: SUMMARY lines

✅ Done — see commit(s): `81749dd`, `33b6f4e`

---

### Task 5: RED baseline and the wording micro-test

✅ Done — see commit(s): `1d07f92`, `a145035`, `d655539`

---

### Task 6: `commands/design-review-fresh-session.md`

✅ Done — see commit(s): `ae3de83`, `033781c`

---

### Task 7: `commands/code-review-fresh-session.md`

✅ Done — see commit(s): `e7d6d2e`, `796f41c` (preceded by `cb62207`, the design ruling).
Scope grew by one file on a user ruling: `skills/shared/tests/test-command-sync.sh`.

---

### Task 8: Close the loop in the two existing files

✅ Done — see commit(s): `021e715`, `b64ec73`

---

### Task 9: README and CHANGELOG

✅ Done — see commit(s): `90651ef`, `466f4bf`

---

### Post-plan: final whole-branch review and its single fix wave

✅ Done — see commit(s): `8660f4a`, `e45dbdc`, `52991bf`, `5d8caa2`

---

## Done criteria

- `bash skills/shared/tests/test-preflight-env.sh` passes, and so does every other suite in `skills/shared/tests/`.
- `/claude-mesh:design-review-fresh-session` and `/claude-mesh:code-review-fresh-session` each produce a prompt whose sections appear in the documented order, whose gate precedes the documents, and which contains no model or provider id from the local config.
- A fresh subagent given a generated prompt modifies nothing, runs the probe, prints the table and stops.
- `mesh-design-review` Step 15 and `do-plan` Step 7 reference the new commands. `do-plan.md` carries exactly one hunk. `mesh-design-review/SKILL.md` carries four: Step 15 plus three `<!-- SYNC -->` comments (at the Iron Rules list, the iteration-file glob, and the auto-fix step) naming the rules this work now mirrors — the file already used that convention before this branch, and the comments are the mechanism that keeps the mirrored copies honest. No behaviour outside Step 15 changed.
- `commands/mesh-review.md` gained the `BASE_BRANCH=` argument and passes it to every wrapper, including on re-dispatch. This was added during the post-implementation review, after a reviewer showed that a caller's base was named in the generated prompt but never reached the reviewers — in a `main`-default repository that silently reviewed a single commit. It widens the branch beyond the original scope by one file, deliberately.
- The baseline and GREEN results are recorded in `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`.
