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
- Row format is exactly `printf '%-16s %-12s %s\n' "$name" "$status" "$detail"`. A name longer than 16 columns (`provider:deepseek`) overflows the pad — harmless, parsing is word-based; do not "fix" it by truncating names.
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
| `skills/shared/preflight-env.sh` | The environment probe. One row per capability, two SUMMARY lines, exit 0 |
| `skills/shared/tests/test-preflight-env.sh` | Its regression suite: fixture configs + shimmed `curl`/`git` |
| `skills/shared/tests/fixtures/valid-claude-models.yaml` | Fixture with a `claude.models` catalog (none of the existing fixtures has one) |
| `skills/shared/tests/fixtures/invalid-claude-scalar.yaml` | Fixture with valid providers/models and a scalar `claude: false` — the `claude-models INVALID` case |
| `skills/ext-claude-exec/ollama-precheck.sh` | Modify: env knobs `OLLAMA_PRECHECK_TRIES` / `OLLAMA_PRECHECK_ATTEMPT_TIMEOUT` / `OLLAMA_PRECHECK_TAGS_TIMEOUT`, defaults preserve current behaviour |
| `commands/design-review-fresh-session.md` | Generator → fresh session → `/claude-mesh:mesh-design-review`; entry and every later iteration |
| `commands/code-review-fresh-session.md` | Generator → fresh session → `/claude-mesh:mesh-review` after implementation |
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

`superpowers:writing-skills` states the Iron Law: no guidance without a failing test first. This
task produces that failing test — the recorded behaviour of a fresh session that is handed a
design and a plan with no gate — and micro-tests the wording of the gate before any command
file exists. **Do not write the command files in this task.**

**Files:**
- Create: `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`

**Interfaces:**
- Consumes: this branch's own design and plan documents as the material under review.
- Produces: the recorded baseline failures and the winning `DO NOT` wording, which Task 6 copies verbatim into `commands/design-review-fresh-session.md`.

- [ ] **Step 1: Make an isolated copy of the repository**

```bash
SCRATCH="$(mktemp -d)"
git clone --no-hardlinks . "$SCRATCH/repo"
echo "$SCRATCH/repo"
```

A baseline run is expected to start editing files; it must not do that here. The clone is
local — no network is involved.

- [ ] **Step 2: Run the baseline (no gate)**

Dispatch a `general-purpose` subagent whose entire prompt is the naive version — the prompt a
person writes when they have not thought about the gate:

```
Design: <SCRATCH>/repo/docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md
Plan:   <SCRATCH>/repo/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md

Work in <SCRATCH>/repo. Review this design and plan before implementation.
```

The dispatched prompt must carry one extra line: `Touch nothing outside <SCRATCH>/repo.` The
subagent inherits the real cwd and the real HOME, so a clean clone alone proves nothing about
the source repository.

Record verbatim: did it edit files (`git -C "$SCRATCH/repo" status --porcelain` — and
`git -C <original repo> status --porcelain`, which must stay clean too), did it name
reviewers it never verified, did it offer to push or open a PR, and what did it say while
doing so. Run it three times — one sample is an anecdote.

- [ ] **Step 3: Micro-test the gate wording**

Two variants, five repetitions each, same subagent type and same material:

- **Control:** the Step 2 prompt unchanged.
- **Candidate:** the same prompt with this block inserted immediately after the first line —
  plus a stub section `## PREFLIGHT` reading `(preflight block omitted in this micro-test —
  the full-context check is Task 6 Step 4)`, so the third bullet's reference is not dangling:

```
## DO NOT
- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.
```

Read every transcript by hand — an agent quoting the block back is not an agent obeying it.
Score one number per run — did it modify any file before being told to start? — and record
push/PR offers and invented reviewer sets as secondary observations. **Pass criterion,
positive and explicit: the candidate holds in ≥4 of 5 runs AND the control fails in ≥2 of 3
baseline runs.** A control that never fails is not a licence to drop the block — decision 3
fixed the section list; stop and take the question back to the design instead. A candidate
below the threshold → tighten the wording and re-run before moving on. Variance matters as
much as the mean: five different readings of the same block means the wording is not binding
yet.

- [ ] **Step 4: Record the findings**

Write `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`: the naive prompt,
the three baseline transcripts in summary with verbatim quotes of every rationalization, the
micro-test table (variant × run × verdict), and the exact `DO NOT` wording that won. Task 6
copies that wording — not a paraphrase of it.

- [ ] **Step 5: Clean up and commit**

```bash
rm -rf "$SCRATCH"
git add docs/superpowers/verification/2026-08-02-fresh-session-baseline.md
git commit -m "test(prompts): record what a fresh session does with an ungated plan"
```

---

### Task 6: `commands/design-review-fresh-session.md`

**Files:**
- Create: `commands/design-review-fresh-session.md`

**Interfaces:**
- Consumes: the `DO NOT` wording from Task 5; `skills/shared/preflight-env.sh` (Tasks 1–4) by name only — the command never calls it, the generated prompt does; `mesh-design-review` Step 1 (TOPIC derivation), Step 2 (iteration counting) and Step 13 (date source) as the rules it mirrors.
- Produces: `/claude-mesh:design-review-fresh-session`, invoked by the user and by `mesh-design-review` Step 15 (Task 8).

- [ ] **Step 1: Write the command file**

Create `commands/design-review-fresh-session.md` (fence depths matter: the file holds a prompt
template, which holds a bash block — 4 backticks around the template, 3 around the bash):

`````markdown
---
name: design-review-fresh-session
description: Generate a prompt for reviewing the current design + plan via /claude-mesh:mesh-design-review in a fresh Claude Code session, including one that runs in a sandbox
---

# Fresh-Session Design-Review Prompt Generator

<!-- SYNC: the DO NOT / ENVIRONMENT / PREFLIGHT / THEN STOP blocks of the generated prompt are
     duplicated verbatim in commands/code-review-fresh-session.md — change both files or
     neither. -->

## Task

Generate the prompt for a NEW Claude Code session whose job is to review the current design and
plan through `/claude-mesh:mesh-design-review` — **not** to implement them.

Arguments, optional, any order: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=`.

## Never read the local config

Do NOT call `config-loader.sh`. Do NOT put a model id, a provider id or a `defaults.*` preset
into the prompt. The session that reads this prompt runs somewhere else — typically a sandbox
VM with its own `config.yaml` — and the reviewers available there are neither more nor less
than what its own preflight reports. Naming local models sends it shopping for reviewers that
do not exist there and hides the ones that do.

## Steps

### 1. Identify the documents

Use `DESIGN_PATH` / `PLAN_PATH` when given. Otherwise take them from this session's context,
falling back to the newest `docs/superpowers/specs/*-design.md` and the matching plan — an
**ordered** lookup, because three plan-naming conventions coexist in this repo:
`plans/<date>-<topic>-implementation.md`, then `plans/<date>-<topic>-plan.md`, then
`plans/<date>-<topic>.md`, then the newest `plans/*<topic>*.md`. If either document is still
unknown, ask the user for the path. Never invent one.

### 2. Derive TOPIC and the iteration number

<!-- SYNC: TOPIC derivation mirrors skills/mesh-design-review/SKILL.md Step 1, iteration
     counting mirrors its Step 2, the date rule mirrors its Step 13. A generator that derives
     a different topic counts a different set of iteration files and hands the review session
     a number the skill then disagrees with. Change them together. -->

- `TOPIC`: from `YYYY-MM-DD-<topic>-design.md`, **repeatedly** stripping trailing `-design` /
  `-review` suffixes — Step 1's own example removes two in sequence
  (`iterative-review-design.md` → `iterative`).
- `N`: `ls docs/superpowers/specs/*-<TOPIC>-review-iter-*.md` → highest existing number + 1, or 1.
- `DATE`: the date in the **design document's** filename, not today's.

### 3. Collect the context that is not in the documents

For iteration 1: decisions and why, alternatives rejected and why, known constraints, sharp
edges. For iteration N > 1: what the previous iteration decided and what it deferred under
"стоп". Keep it under 40 lines. It is not a retelling of the documents.

The only source is THIS session. If it does not actually hold that context — the command was
invoked standalone, or the discussion has been evicted — ask the user for the key decisions;
never fabricate them. If the user declines, write `CONTEXT` with an explicit note that it is
limited to what the documents imply.

### 4. Compose the prompt

The prompt consists of these sections, in this order, and nothing else. Substitute
`<DESIGN_PATH>`, `<PLAN_PATH>`, `<TOPIC>` and `N` — and nothing more: emit `$HOME` in the
preflight block **literally**, never expanded to a concrete home directory. An expanded path
freezes this machine's layout into a prompt that runs on another one — the exact failure
decision 2 of the design exists to prevent:

````
## TASK

Review the design and plan for <feature> through `/claude-mesh:mesh-design-review`.
Do not implement anything.

## DO NOT

- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.

## DOCUMENTS

- Design: `<DESIGN_PATH>`
- Plan:   `<PLAN_PATH>`
<iteration N > 1 only:>
- Previous iterations: `docs/superpowers/specs/<DATE>-<TOPIC>-review-iter-*.md` (this is
  iteration N). Do not summarise them — mesh-design-review reads them itself and builds its
  PREVIOUS DECISIONS table from them.

## ENVIRONMENT

This session probably runs in a sandbox. git remote, gh and glab may be unreachable. The set
of configured agents and models HERE differs from the session that wrote this prompt — assume
no reviewer exists until the preflight below says so. Local commits are normal and expected:
mesh-design-review commits its own auto-fixes and its iteration log. If no clipboard utility
exists, print generated prompts into the chat instead of trying to copy them.

## PREFLIGHT — run this before anything else

```bash
PF="./skills/shared/preflight-env.sh"
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on gh / glab means
presence on PATH only. If the script is not
found, say so and ask the user whether to update the plugin in this sandbox first or proceed
on the built-in `claude` reviewer alone — and before offering that, check a `config.yaml`
exists in the plugin data dir: claude needs no config section, but the review skills refuse
to start without a usable config.yaml at all.

## CONTEXT

<from step 3>

## THEN STOP

1. Summarise the documents in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-design-review DESIGN_PATH=<DESIGN_PATH> PLAN_PATH=<PLAN_PATH> TOPIC=<TOPIC>`
and select only reviewers the preflight marked available. Use the `default` argument only if
every entry on the `SUMMARY defaults design_review` line appears in `SUMMARY available`;
otherwise select interactively.
````

### 5. Save, display, offer the clipboard

1. Write to `docs/superpowers/plans/<DATE>-<TOPIC>-design-review-prompt-iter-N.md`. If that
   exact file already exists, suffix `-2`, then `-3` — never overwrite an earlier prompt.
2. Print the full prompt on screen.
3. Copy to the clipboard: `xclip -selection clipboard` / `xsel --clipboard` on Linux,
   `pbcopy` on macOS. If none exists — which is normal inside a sandbox — say so, name the
   file path, and move on. A missing clipboard is a note, never a failure.
4. Tell the user: "Prompt ready. Open a new Claude Code session and paste it."

Do not commit the file. `docs/superpowers/` is removed before a PR anyway, and the sandbox
shares this working copy, so the file is visible on both sides the moment it is written.
`````

- [ ] **Step 2: Verify the generator against this branch's own documents**

Until the plugin is reinstalled, `/claude-mesh:design-review-fresh-session` does not resolve
in this session — the active plugin is the installed cache, not this working copy. The
command file is a prompt: open `commands/design-review-fresh-session.md` and execute its
steps directly against the real documents (`DESIGN_PATH` and `PLAN_PATH` of this plan), then
assert on the file it wrote:

```bash
P="docs/superpowers/plans/2026-08-02-fresh-session-review-prompts-design-review-prompt-iter-1.md"
grep -n '^## ' "$P"                       # sections present, in the documented order
awk '/^## DO NOT/{d=NR} /^## DOCUMENTS/{o=NR} END{exit !(d && o && d<o)}' "$P" \
    && echo "GATE BEFORE DOCUMENTS: ok"
grep -c 'preflight-env.sh' "$P"           # the discovery block survived
```

Expected: the eight sections in the documented order, `GATE BEFORE DOCUMENTS: ok`, and at
least one `preflight-env.sh` reference.

- [ ] **Step 3: Verify no local config leaked into the prompt**

```bash
LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' | sort -V | tail -1)"
# -F: ids are literals, not regexes (an id with . or + would false-positive otherwise).
# The defaults preset ids are equally leak candidates under decision 1; .builtin[] is skipped
# deliberately — "claude"/"codex"/"gemini" appear in any prompt as ordinary words.
{ "$LOADER" list-models 2>/dev/null | cut -d'|' -f1
  "$LOADER" get-defaults design_review 2>/dev/null | jq -r '(.claude_models[]?, .models[]?)'
} | sort -u | while read -r id; do
    [ -n "$id" ] && grep -qF -- "$id" "$P" && echo "LEAK: $id"
done
echo "leak scan done"
```

Expected: no `LEAK:` line. If the local machine has no config, note that the check was vacuous
and repeat it later on a machine that does — the property being tested is that the generator
never asks.

- [ ] **Step 4: GREEN — run a fresh subagent on the generated prompt**

Make a fresh isolated copy — Task 5's `$SCRATCH` died with Task 5's subagent; a variable never
survives the task boundary, so this task creates its own:

```bash
SCRATCH="$(mktemp -d)"
git clone --no-hardlinks . "$SCRATCH/repo"
```

Rewrite the document paths in a copy of the generated prompt to point into the clone, add one
line `Touch nothing outside $SCRATCH/repo.`, and dispatch a `general-purpose` subagent with
exactly that prompt.

Pass criteria, all five required:
1. `git -C "$SCRATCH/repo" status --porcelain` is empty — it modified nothing in the clone.
2. `git status --porcelain` in the ORIGINAL repo is unchanged from before the run — the
   subagent inherits the real cwd, so a clean clone alone proves nothing about the source.
3. It ran the preflight block and printed the resulting table.
4. It did not invoke `mesh-design-review`, and did not dispatch reviewers.
5. It ended by waiting for the user.

If any criterion fails, fix the wording of the prompt template — not the test — and re-run.
Record the outcome in `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`
under a "GREEN" heading, next to the baseline it is compared against.

- [ ] **Step 5: Commit**

```bash
rm -rf "$SCRATCH"
git add commands/design-review-fresh-session.md \
        docs/superpowers/verification/2026-08-02-fresh-session-baseline.md
git commit -m "feat(commands): design-review-fresh-session — hand the plan to a reviewer, not an implementer"
```

---

### Task 7: `commands/code-review-fresh-session.md`

**Files:**
- Create: `commands/code-review-fresh-session.md`

**Interfaces:**
- Consumes: the same `DO NOT` wording and the same preflight discovery block as Task 6 — copied verbatim, since each command file is read on its own; the base-branch rule from `skills/ext-claude-code-review/SKILL.md` (`git symbolic-ref refs/remotes/origin/HEAD` → fall back to `master` → `git merge-base`).
- Produces: `/claude-mesh:code-review-fresh-session`, referenced by `do-plan` Step 7 (Task 8).

- [ ] **Step 1: Write the command file**

Create `commands/code-review-fresh-session.md` (same fence depths as Task 6: 4 backticks around
the prompt template, 3 around the bash inside it):

`````markdown
---
name: code-review-fresh-session
description: Generate a prompt for reviewing an implemented plan via /claude-mesh:mesh-review in a fresh Claude Code session, including one that runs in a sandbox
---

# Fresh-Session Code-Review Prompt Generator

<!-- SYNC: the DO NOT / ENVIRONMENT / PREFLIGHT / THEN STOP blocks of the generated prompt are
     duplicated verbatim in commands/design-review-fresh-session.md — change both files or
     neither. -->

## Task

Generate the prompt for a NEW Claude Code session whose job is to review the implementation
this session just finished, through `/claude-mesh:mesh-review` — **not** to keep working on it.

Arguments, optional, any order: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=`, `BASE_BRANCH=`.

## Never read the local config

Do NOT call `config-loader.sh`. Do NOT put a model id, a provider id or a `defaults.*` preset
into the prompt. The session that reads this prompt runs somewhere else — typically a sandbox
VM with its own `config.yaml` — and the reviewers available there are neither more nor less
than what its own preflight reports. Naming local models sends it shopping for reviewers that
do not exist there and hides the ones that do.

## Steps

### 1. Identify the documents

Use `DESIGN_PATH` / `PLAN_PATH` when given, else this session's context, else the newest
`docs/superpowers/specs/*-design.md` and the matching plan (ordered lookup, as in
design-review-fresh-session: `-implementation.md`, `-plan.md`, bare `<topic>.md`, newest
`*<topic>*.md`).

Code review is the one case where those documents may legitimately not exist — a branch can be
implemented without a written design. Ask once; if the user confirms there are none, take
`TOPIC` from the branch name normalised to a slug (Step 3 below) and `DATE` from today, omit
the missing entries from `DOCUMENTS`, and keep the git range. Never invent a document path.

### 2. Resolve the git range

All local — no network is involved, which is the point in a sandbox:

```bash
BASE_REF="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}"
BASE_SHA="$(git merge-base HEAD "$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null)"
HEAD_SHA="$(git rev-parse HEAD)"
# symbolic-ref, not rev-parse --abbrev-ref: a detached HEAD would otherwise put the literal
# string "HEAD" into the prompt as a branch name.
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
DIRTY="$(git status --porcelain)"
git log --oneline "$BASE_SHA..$HEAD_SHA"
```

If `BASE_SHA` does not resolve, name the branch that was tried and ask the user for the base.
If `DIRTY` is non-empty, warn the operator and add the note to `DOCUMENTS` ("uncommitted
changes existed at generation — the review covers commits only"). Never silently ignore a
dirty worktree.

### 3. Derive TOPIC and DATE

<!-- SYNC: TOPIC derivation mirrors skills/mesh-design-review/SKILL.md Step 1 and the date
     rule its Step 13, so a topic's artifacts keep sorting together. Change them together. -->

`TOPIC` from `YYYY-MM-DD-<topic>-design.md`, **repeatedly** stripping trailing `-design` /
`-review` suffixes (Step 1's own example removes two in sequence); `DATE` from that same
filename. With no documents: `TOPIC` from the branch name normalised to a slug — drop
everything up to the last `/` (`feat/x-y` → `x-y`), apply the same trailing strip, then map
any character outside `[a-z0-9-]` to `-`; detached HEAD already yields a short sha (Step 2);
an empty result asks the user. `DATE` today.

### 4. Collect the context only this session has

What was implemented; where the implementation deviated from the plan and why; what was left
unfinished; known weak spots. None of it is in the diff or in the plan, and the session that
executed the plan is the only one that knows it. Keep it under 40 lines.

### 5. Compose the prompt

The prompt consists of these sections, in this order, and nothing else. Substitute
`<DESIGN_PATH>`, `<PLAN_PATH>`, `<BRANCH>`, the shas and the commit list — and nothing more:
emit `$HOME` in the preflight block **literally**, never expanded to a concrete home
directory (an expanded path freezes this machine's layout into a prompt that runs on another
one — the failure decision 2 of the design exists to prevent):

````
## TASK

Review the implementation on branch <BRANCH> through `/claude-mesh:mesh-review`.
Do not continue the work.

## DO NOT

- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.

## DOCUMENTS

- Design: `<DESIGN_PATH>`     (omit the line when there is none)
- Plan:   `<PLAN_PATH>`       (omit the line when there is none)
- Git range: `<BASE_SHA>..<HEAD_SHA>` on branch `<BRANCH>` (HEAD at generation:
  `<HEAD_SHA>`). If HEAD has moved since, review through the current HEAD and say so. This
  range is context — the review skills detect the base branch themselves.
- Commits:
  <output of git log --oneline BASE_SHA..HEAD_SHA>
<only when the worktree was dirty at generation:>
- Note: uncommitted changes existed at generation — the review covers commits only.

## ENVIRONMENT

This session probably runs in a sandbox. git remote, gh and glab may be unreachable. The set
of configured agents and models HERE differs from the session that wrote this prompt — assume
no reviewer exists until the preflight below says so. Local commits are normal and expected:
mesh-review commits its own auto-fixes and decisions. If no clipboard utility exists, print
generated prompts into the chat instead of trying to copy them.

## PREFLIGHT — run this before anything else

```bash
PF="./skills/shared/preflight-env.sh"
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on gh / glab means
presence on PATH only. If the script is not
found, say so and ask the user whether to update the plugin in this sandbox first or proceed
on the built-in `claude` reviewer alone — and before offering that, check a `config.yaml`
exists in the plugin data dir: claude needs no config section, but the review skills refuse
to start without a usable config.yaml at all.

## CONTEXT

<from step 4>

## THEN STOP

1. Summarise what was built, in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-review` and select only reviewers the preflight marked available.
Use the `default` argument only if every entry on the `SUMMARY defaults code_review` line
appears in `SUMMARY available`; otherwise select interactively.
````

### 6. Save, display, offer the clipboard

1. Write to `docs/superpowers/plans/<DATE>-<TOPIC>-code-review-prompt.md`. If that file
   exists, suffix `-2`, then `-3` — never overwrite an earlier prompt.
2. Print the full prompt on screen.
3. Copy to the clipboard: `xclip -selection clipboard` / `xsel --clipboard` on Linux,
   `pbcopy` on macOS. If none exists — which is normal inside a sandbox — say so, name the
   file path, and move on. A missing clipboard is a note, never a failure.
4. Tell the user: "Prompt ready. Open a new Claude Code session and paste it."

Do not commit the file.
`````

- [ ] **Step 2: Verify the generator on this branch**

Execute `commands/code-review-fresh-session.md` directly, as in Task 6 Step 2 (the slash name
resolves only after a plugin reinstall), against this branch (which has real commits by now),
then:

```bash
P="$(ls -t docs/superpowers/plans/*-code-review-prompt*.md | head -1)"
grep -n '^## ' "$P"
awk '/^## DO NOT/{d=NR} /^## DOCUMENTS/{o=NR} END{exit !(d && o && d<o)}' "$P" && echo "GATE BEFORE DOCUMENTS: ok"
grep -q 'Git range' "$P" && echo "range present"
grep -q 'mesh-review' "$P" && echo "targets mesh-review"
```

Expected: sections in order, `GATE BEFORE DOCUMENTS: ok`, `range present`, `targets mesh-review`.

- [ ] **Step 3: Verify the collision suffix**

Execute it a second time without deleting the first file. Expected: a `-2` file is
created and the first one is left untouched (`git status --porcelain` shows two untracked
prompt files, not a modified one).

- [ ] **Step 4: Commit**

```bash
git add commands/code-review-fresh-session.md
git commit -m "feat(commands): code-review-fresh-session — carry what the diff cannot say"
```

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
  The probe emits one row per capability (config state, the Claude catalog, codex/gemini gated
  on their config section first and their network second, one probe per provider through the
  existing `token-precheck.sh` / `ollama-precheck.sh`, git remote, gh/glab, clipboard) and two
  `SUMMARY` lines naming the reviewers that can actually be selected there. Every verdict
  exits 0 — a non-zero exit means the probe is broken, not the environment. Provider tokens
  never reach the output and exported env files are removed through a trap.
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
