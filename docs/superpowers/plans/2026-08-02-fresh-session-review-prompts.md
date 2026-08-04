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

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (Step 15 only)
- Modify: `commands/do-plan.md` (Step 7 only)

**Interfaces:**
- Consumes: `/claude-mesh:design-review-fresh-session` (Task 6) and `/claude-mesh:code-review-fresh-session` (Task 7).
- Produces: nothing new — this is the wiring that makes both commands reachable without the user remembering them.

- [ ] **Step 1: Point the next-iteration branch at the new generator**

In `skills/mesh-design-review/SKILL.md`, Step 15, "Based on user response", replace the
`"Новая итерация"` action with:

```markdown
- **"Новая итерация":** Execute `/claude-mesh:design-review-fresh-session` via the Skill tool
  (it generates the prompt for the next iteration and knows this may run in a sandbox), then
  go to Step 16. If that command does not resolve — an older plugin in this environment —
  warn that the plugin needs an update for the review-generator flow and fall back to
  `/claude-mesh:continue-plan-fresh-session`, as before this feature
```

Leave the option labels and the `"Остановиться и начать работу"` branch — which still routes to
`/claude-mesh:continue-plan-fresh-session` — exactly as they are.

Also add three one-line counter-notes in the same file — the repo's sync convention is two-way
("change all copies or none"), and the generator now mirrors these steps. Step 1 (TOPIC
derivation), Step 2 (iteration counting) and Step 13 (date source) each gain:

```markdown
<!-- SYNC: mirrored by commands/design-review-fresh-session.md Step 2 — change together -->
```

- [ ] **Step 2: Verify the edit is confined to Step 15**

```bash
git diff --stat skills/mesh-design-review/SKILL.md
git diff skills/mesh-design-review/SKILL.md | grep -c '^[-+]' 
```

Expected: one file; the Step 15 branch replacement plus exactly three one-line SYNC comments
at Steps 1, 2 and 13. Any other diff — Steps 5, 6, the mirrored selection/watch blocks — is
out of scope for this plan; revert it.

- [ ] **Step 3: Add the end-of-plan hint to `/do-plan`**

In `commands/do-plan.md`, Step 7 "End of plan", append:

```markdown
Offer the code review BEFORE `superpowers:finishing-a-development-branch`, and if the user
takes it, hold finishing entirely — no push, no PR, and no local merge either (finishing
deletes the branch after merging, and review fixes need somewhere to land) — until that
external review has run and its findings are applied. The order is the point: a
merged-and-deleted branch cannot absorb what the review finds.

`/claude-mesh:code-review-fresh-session` generates the prompt, carrying the git range and what
only this session knows — deviations from the plan, what was left unfinished, known weak spots.

Whether this session can finish the branch is a fact to check, not to guess: run
`GIT_TERMINAL_PROMPT=0 timeout 8 git ls-remote --exit-code origin HEAD` (or reuse a preflight
verdict already printed in this session). If the remote does not answer, say plainly that
`superpowers:finishing-a-development-branch` cannot finish the job here: push and PR creation
need a network that is not available. Leave the branch for the user to finish outside. Do not
attempt the push to find out.
```

- [ ] **Step 4: Confirm both files still read correctly**

Run: `grep -n "design-review-fresh-session" skills/mesh-design-review/SKILL.md && grep -n "code-review-fresh-session" commands/do-plan.md`
Expected: one hit in each file, in the step named above.

- [ ] **Step 5: Commit**

```bash
git add skills/mesh-design-review/SKILL.md commands/do-plan.md
git commit -m "feat(flow): route the next review iteration and the post-plan review into fresh sessions"
```

---

### Task 9: README and CHANGELOG

**Files:**
- Modify: `README.md` (Features → session helpers; Dependencies if needed)
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section at the top)

**Interfaces:**
- Consumes: everything above.
- Produces: the user-facing record. No code depends on this task.

- [ ] **Step 1: Extend the session-helper line in README**

In the Features list, the `**Session helpers**` bullet gains the two new commands:

```markdown
- **Session helpers** — `/claude-mesh:do-plan`, `/claude-mesh:pause-after-current-task`, `/claude-mesh:transfer-session`,
  `/claude-mesh:exec-plan-fresh-session`, `/claude-mesh:continue-plan-fresh-session`,
  `/claude-mesh:design-review-fresh-session`, `/claude-mesh:code-review-fresh-session`
- **Sandbox-aware review sessions** — the two `*-review-fresh-session` commands generate a prompt
  for a fresh session that reviews rather than implements, and never name a model: the session
  runs `skills/shared/preflight-env.sh` where it actually lives and picks reviewers from what
  that reports. For reviews that will run in an environment with a different `config.yaml` —
  typically another machine, VM or sandbox. Workflow: generate the prompt on the host, paste
  it into a fresh session inside the sandbox; that session probes its own environment and
  selects reviewers from what it finds
```

- [ ] **Step 2: Add the CHANGELOG entry**

Insert directly under the `All notable changes…` line:

```markdown
## [Unreleased]

### Added
- `/claude-mesh:design-review-fresh-session` and `/claude-mesh:code-review-fresh-session`
  generate the prompt for a fresh session that reviews a design+plan, or a finished
  implementation, instead of executing it. Both are built for a review that runs somewhere
  else — typically a sandbox VM sharing the working copy — so neither generator reads
  `config.yaml` and neither prompt names a model: the reviewing session runs the new
  `skills/shared/preflight-env.sh` in its own environment and selects from what that reports.
  The probe emits one row per capability (plugin identity, config state, the built-in `claude`
  reviewer, the Claude catalog, codex/gemini gated on their config section first and their
  network second, one probe per provider through the existing `token-precheck.sh` /
  `ollama-precheck.sh`, git remote, gh/glab, clipboard) and a `SUMMARY` block naming the
  reviewers that can actually be selected there. Every verdict exits 0 — a non-zero exit means
  the probe is broken or could not start (bash 4+ is required), never that the environment is
  poor. Provider tokens never reach the output and exported env files are removed through a
  trap.
  `mesh-design-review` Step 15 now routes its next iteration into the new generator, and
  `/do-plan` Step 7 points at the code-review one and states that a sandbox cannot finish a
  branch that needs a push.
```

- [ ] **Step 3: Verify**

Run: `grep -n "review-fresh-session" README.md CHANGELOG.md | head`
Expected: hits in both files.

- [ ] **Step 4: Run the full shared test suite one last time**

Run: `FAILED=0; for t in skills/shared/tests/test-*.sh; do echo "== $t"; bash "$t" >/dev/null || { echo "SUITE FAILED: $t"; FAILED=1; }; done; [ "$FAILED" -eq 0 ] && echo "all suites done"; [ "$FAILED" -eq 0 ]`
Expected: `all suites done` and exit 0 — the command itself fails when any suite fails,
instead of hiding the failure behind an unconditional final echo.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: record the two fresh-session review commands and the environment probe"
```

---

## Done criteria

- `bash skills/shared/tests/test-preflight-env.sh` passes, and so does every other suite in `skills/shared/tests/`.
- `/claude-mesh:design-review-fresh-session` and `/claude-mesh:code-review-fresh-session` each produce a prompt whose sections appear in the documented order, whose gate precedes the documents, and which contains no model or provider id from the local config.
- A fresh subagent given a generated prompt modifies nothing, runs the probe, prints the table and stops.
- `mesh-design-review` Step 15 and `do-plan` Step 7 reference the new commands; nothing else in those files changed.
- The baseline and GREEN results are recorded in `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`.
