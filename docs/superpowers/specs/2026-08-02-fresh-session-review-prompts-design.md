# Fresh-session review prompts — design

Date: 2026-08-02
Branch: `feat/fresh-session-review-prompts`
Status: approved for planning

## Problem

`/claude-mesh:exec-plan-fresh-session` hands a finished design and plan to a fresh session
that starts implementing. Nothing hands the same pair to a fresh session that **reviews** the
plan first, and nothing routes a finished implementation into `/claude-mesh:mesh-review`.
Both reviews are launched today by pasting an ad-hoc prompt.

Ad-hoc is unreliable because of where the review actually runs: a sandbox VM with this
repository mounted through a shared folder. Three properties of that environment break a
prompt written outside it.

1. **The reviewer set belongs to the sandbox, not to the generating session.** claude-mesh
   reads `config.yaml` from the plugin data dir, and the sandbox has its own — different
   providers, different models, possibly none at all. The generating session may equally have
   no config. A prompt that names models resolved locally sends the review session shopping
   for reviewers that do not exist there, and hides the ones that do.
2. **Reachability is unknown until probed.** git remote, `gh` and `glab` are typically
   unreachable there; `codex` / `gemini` CLIs may be absent, or present with no route to their
   API. A dispatched-but-dead reviewer is not a cheap mistake:
   `skills/mesh-design-review/SKILL.md` Step 6 records a run where four of five executors died
   mid-stream and nothing noticed for 38 minutes.
3. **A fresh session handed a plan implements it.** That is the default reading of "here is a
   design and a plan", and it is exactly what must not happen before the review.

## Scope

**In:** two prompt generators, one shared environment probe with a test, two localized edits
to existing files.

**Out:** filtering unavailable reviewers inside `mesh-design-review` Step 5 or `mesh-review`
Steps 1–3. The operator reads the probe table before choosing, so the selection code — whose
text is mirrored between those two files under explicit sync notes — stays untouched.
Execution helpers (`exec-plan-fresh-session`, `continue-plan-fresh-session`) keep their
current behaviour; the `mesh-design-review` Step 15 branch "Остановиться и начать работу"
still routes to `continue-plan-fresh-session`.

## Artifacts

| File | Kind | Purpose |
|---|---|---|
| `commands/design-review-fresh-session.md` | new | Generator: fresh session → `/claude-mesh:mesh-design-review`. Covers the entry (iteration 1) and every later iteration |
| `commands/code-review-fresh-session.md` | new | Generator: fresh session → `/claude-mesh:mesh-review`, after the plan has been implemented |
| `skills/shared/preflight-env.sh` | new | Environment probe. Runs **inside** the sandbox and reports what is actually available there |
| `skills/shared/tests/test-preflight-env.sh` | new | Fixture + PATH-shim test for the probe |
| `skills/mesh-design-review/SKILL.md` | edit | Step 15, branch "Новая итерация (fresh session)" → invoke the new generator instead of `continue-plan-fresh-session` |
| `commands/do-plan.md` | edit | Step 7 "End of plan" → point at the code-review generator, and state that push/PR cannot close the loop from inside a sandbox |

## Decisions

### 1. The generators never read `config.yaml`

Neither generator calls `config-loader.sh`, and no model id, provider id or `defaults.*`
preset ever reaches the generated prompt. The only claim the prompt makes about reviewers is
"run the probe and choose from its `OK` rows".

This is what makes one prompt correct in two environments. It also means generation works on a
machine where claude-mesh has no config at all — the generating session and the sandbox are
configured independently, and neither is authoritative about the other.

### 2. The probe is discovered by glob, never by `${CLAUDE_PLUGIN_ROOT}`

The harness substitutes that placeholder into a *command file's text* (`commands/mesh-review.md`
Step 1 documents this), so baking it into the generated prompt would freeze the **host's**
plugin path into a file that is executed on another machine. The prompt therefore carries a
discovery block:

```bash
PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
```

Version-sorted for the reason `commands/mesh-review.md` already records: a plain
`find | head -1` returns directory order, and was observed picking a stale cached 0.4.0 over
an installed 0.4.2.

### 3. The prompt is a recipe; it holds exactly one prohibition block, and that block comes second

The prompt is specified as an ordered list of sections it *consists of*, not as a list of
things not to write. `superpowers:writing-skills` ("Match the Form to the Failure") is
explicit that prohibitions backfire on output-shaping problems, where a positive recipe binds
and a "don't restate the design" clause invites negotiation.

The one failure that *is* a discipline failure — a fresh session implementing the plan it was
asked to review — gets the opposite treatment: an explicit prohibition block. It sits
**second, before `DOCUMENTS`**, because a session that has already read a 12-task plan is
past the point where the gate is cheap.

### 4. Iteration numbering reuses the skill's own rule

`TOPIC` is derived from the design filename exactly as `skills/mesh-design-review/SKILL.md`
Step 1 derives it (extract from `YYYY-MM-DD-<topic>-design.md`, strip a trailing `-review` or
`-design`). The iteration number is `max(N in docs/superpowers/specs/*-<TOPIC>-review-iter-N.md) + 1`,
which is Step 2's rule.

Both are copies, so both carry a sync note naming the step they mirror. A generator that
derives a different topic counts a different set of iteration files, and would hand the review
session an iteration number the skill then disagrees with.

The output filename takes its date from the **design document's** filename, not from today —
the rule `mesh-design-review` Step 13 already applies to iteration files, so all artifacts of
one topic sort together.

### 5. Probe per provider, report per model, always exit 0

Models of one provider share an endpoint, so the probe runs one check per provider and expands
the verdict back into model ids in its `SUMMARY` line — in the exact spelling the selection UI
of `mesh-review` / `mesh-design-review` uses, so the reading session has nothing to map.

Every verdict — including "everything is unreachable" — exits 0. A non-zero exit means the
probe itself is broken. This is the contract `shared/watch-runs.sh` already established
("every verdict exits 0"), for the same reason: a session that reads a verdict as a crash
starts repairing the probe instead of reporting the environment.

### 6. Degradation is specified, not improvised

Two failures are expected often enough to be part of the design rather than the error table:

- **The sandbox runs an older plugin with no `preflight-env.sh`.** The discovery block prints
  a named error; the prompt instructs the session to report it, treat only `claude` as
  available (the built-in reviewer needs no config section), and ask the operator whether to
  proceed on that alone or update the plugin inside the sandbox.
- **No clipboard utility.** `xclip` / `xsel` / `pbcopy` are usually absent in a sandbox, and
  iterations 2..N generate their prompt *there*. The generators print the prompt in full and
  name the file path; a missing clipboard is a note, never a failure.

## The generated prompt

Both generators emit the same shape. Sections appear in this order; the tails differ.

````
## TASK
One sentence: review this design/plan (or this implementation). Do not implement anything.

## DO NOT
- Do not implement the plan, and do not fix what the review finds — the review skill owns its
  own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab. They are unlikely to work here and
  are not part of this task.
- Take no action beyond reading the documents and running the preflight block below until the
  user explicitly says to start.

## DOCUMENTS
- Design: <path>
- Plan:   <path>
<code-review tail adds the git range and the commit list>

## ENVIRONMENT
This session probably runs in a sandbox. git remote / gh / glab may be unreachable. The set of
configured agents and models HERE differs from the session that wrote this prompt — do not
assume any reviewer exists; the preflight below is the only authority. Local commits are
normal and expected: mesh-design-review commits its own auto-fixes and iteration log. If no
clipboard utility exists, print generated prompts into the chat instead.

## PREFLIGHT — run this first
```bash
PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -x "$PF" ] || { echo "preflight-env.sh not found — is claude-mesh installed here?" >&2; exit 1; }
"$PF"
```
Print the table verbatim. Do not soften a verdict into "probably fine".

## CONTEXT
What is not in the documents: decisions and why, rejected alternatives, known constraints,
sharp edges. <= 40 lines. Not a retelling of the documents.

## THEN STOP
1. A summary of the documents in 5–10 lines.
2. The preflight table, verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO
Invoke `/claude-mesh:mesh-design-review DESIGN_PATH=<path> PLAN_PATH=<path>`
(code-review tail: `/claude-mesh:mesh-review`), selecting only reviewers the preflight
marked OK.
````

### Tail — `design-review-fresh-session`

- Arguments: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=` (all optional; discovery mirrors
  `exec-plan-fresh-session` Step 1, and asks when nothing is found).
- Iteration 1: `CONTEXT` is the brainstorming residue — decisions, rejected alternatives,
  constraints.
- Iteration N > 1: `DOCUMENTS` additionally states that `*-<TOPIC>-review-iter-*.md` files
  exist and where. Their content is **not** copied: Step 3 of the skill reads them itself and
  builds the PREVIOUS DECISIONS table. `CONTEXT` becomes what the previous iteration decided
  and what it deferred under "стоп".
- Output: `docs/superpowers/plans/<design-date>-<topic>-design-review-prompt-iter-N.md`.

### Tail — `code-review-fresh-session`

- Arguments: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=`, `BASE_BRANCH=` (all optional).
- `DOCUMENTS` additionally carries the git range, resolved locally by the same rule
  `skills/ext-claude-code-review/SKILL.md` uses (`git symbolic-ref refs/remotes/origin/HEAD`,
  falling back to `master`, then `git merge-base`), plus `git log --oneline BASE..HEAD`. No
  network is involved. The recorded HEAD sha is labelled "HEAD at generation" — if HEAD has
  moved by the time the review runs, the session reviews through the current HEAD and says so.
  The range is context, not an override: the review skills auto-detect the base themselves.
- `CONTEXT` is the part worth generating at all: what was implemented, where the
  implementation deviated from the plan and why, what was left unfinished, and known weak
  spots. None of that is in the diff or the plan, and the session that executed the plan is
  the only one that knows it.
- Output: `docs/superpowers/plans/<design-date>-<topic>-code-review-prompt.md`; on collision,
  suffix `-2`, `-3`.
- Code review is the one case where the documents may legitimately not exist — a branch can be
  implemented without a written design. Ask once; if the user confirms there are none, take
  `TOPIC` and the output date from the branch name and today's date, omit the missing entries
  from `DOCUMENTS`, and keep the git range. Never invent a document path.

Neither generator commits the prompt file. Writing it is enough — `docs/superpowers/` is
removed before a PR anyway, and the sandbox shares the working copy, so the file is visible on
both sides the moment it is written.

## `skills/shared/preflight-env.sh`

**Invocation:** no arguments. `PREFLIGHT_HTTP_TIMEOUT` (default 5) and `PREFLIGHT_GIT_TIMEOUT`
(default 8) override the per-probe budgets.

**Output:** one line per capability, `name`, status, detail — fixed order, so a test can assert
on it:

```
config           OK           /home/u/.claude/plugins/data/claude-mesh-zinin/config.yaml
builtin-claude   OK           always available, needs no config section
codex            NO-NETWORK   CLI present, api.openai.com unreachable in 5s (heuristic)
gemini           MISSING      not on PATH
provider:zai     OK           HTTP 200, token accepted
provider:ollama  NO-NETWORK   http://localhost:11434 timed out after 5s
git-remote       NO-NETWORK   git ls-remote origin timed out after 8s
gh               MISSING      not on PATH
glab             MISSING      not on PATH
clipboard        MISSING      no xclip/xsel/pbcopy

SUMMARY available: claude, zai/glm, zai/glm-air
SUMMARY unavailable: codex (NO-NETWORK), gemini (MISSING), ollama/kimi (NO-NETWORK)
```

Order: `config`, `builtin-claude`, `curl` (only when missing), `codex`, `gemini`,
`provider:*` in config order, `git-remote`, `gh`, `glab`, `clipboard`, then the two `SUMMARY`
lines.

**Status set (closed):** `OK`, `MISSING` (tool or section absent), `NO-NETWORK` (present but
its endpoint did not answer), `AUTH-FAILED` (endpoint answered, credentials rejected),
`SKIPPED` (not probed — e.g. providers when there is no config), `UNKNOWN` (the probe could
not decide, e.g. `curl` absent).

**Reuse, do not reimplement:** providers are probed through the existing
`skills/ext-claude-exec/token-precheck.sh` (exit 0 → `OK`, 5 → `AUTH-FAILED`, 6 →
`NO-NETWORK`) and `ollama-precheck.sh`, routed by the provider `kind` exactly as
`ext-claude-exec` routes it. Model and provider data come only through `config-loader.sh`
(`list-models`, `export`) — never raw `yq`.

**Config states:** loader rc=2 → `config MISSING`, providers `SKIPPED`, `SUMMARY available`
still contains `claude`. Loader rc=1 → `config INVALID <first line of the validator's message>`,
providers `SKIPPED`. Loader script itself not found → `config MISSING (config-loader.sh not
found)`. All three exit 0: they are facts about the environment, not failures of the probe.

**Secrets:** `config-loader.sh export <model>` writes an env file containing the provider
token and prints its path. The probe sources it in a subshell and deletes it from a
`trap … EXIT`; no byte of that file reaches stdout or stderr. This is a test assertion, not an
intention.

**Cost:** probes are sequential — five providers is a ~35 s worst case. That is the price of
one check, against six reviewers hanging for minutes.

**Dependencies:** bash 4.0+, `timeout` (GNU coreutils, already required by this repo), `git`
and `curl` optional — their absence produces `MISSING` / `UNKNOWN` rows rather than an error.

## Edits to existing files

**`skills/mesh-design-review/SKILL.md`, Step 15.** The branch "Новая итерация (fresh session)"
invokes `/claude-mesh:design-review-fresh-session` instead of
`/claude-mesh:continue-plan-fresh-session`. Option labels and the second branch are unchanged.

**`commands/do-plan.md`, Step 7 "End of plan".** After the final full-implementation review,
suggest `/claude-mesh:code-review-fresh-session`. State plainly that inside a sandbox
`superpowers:finishing-a-development-branch` cannot finish the job — push and PR creation need
the network that is not there — so the branch is left for the operator to finish outside.
Short paragraph; no behavioural change to the rest of `/do-plan`.

## Error handling

| Situation | Behaviour |
|---|---|
| Design or plan document not found | Ask the user for the path, as `exec-plan-fresh-session` does. Never invent one |
| No `*-review-iter-*.md` files | Iteration 1 |
| `preflight-env.sh` not found in the sandbox | Prompt-side: report, treat only `claude` as available, ask whether to proceed |
| `config.yaml` absent or invalid in the sandbox | Probe reports it and continues; `claude` remains available |
| Clipboard utility absent | Print the prompt and its path; note it, do not fail |
| `git` absent, or no `origin` remote | `git-remote MISSING (no remote configured)`; code-review generator falls back to `master` and says so in the prompt |

## Testing

Per `superpowers:writing-skills`, the guidance is tested before it is trusted.

1. **Probe unit test** — `skills/shared/tests/test-preflight-env.sh`, in the style of the
   seven existing suites: fixture `config.yaml` pinned via `export CLAUDE_PLUGIN_DATA=<tmpdir>`
   plus PATH shims for `curl`, `git`, `codex`, `gemini`. Scenarios: all OK; CLI present with no
   network; HTTP 401 → `AUTH-FAILED`; config absent; config invalid. Assertions: exit 0 in
   every scenario, statuses drawn only from the closed set, `SUMMARY` consistent with the
   per-line verdicts, the fixture token absent from stdout and stderr, no exported env file
   left behind.
2. **Generator output test** — run each command against fixture documents and assert the
   section order, that `DO NOT` precedes `DOCUMENTS`, and that no model or provider id from
   the local config appears anywhere in the output.
3. **RED baseline, then GREEN** — dispatch a subagent with a naive prompt ("here is the design
   and the plan, review them in this fresh session") and record verbatim what it does: starts
   editing, assumes a reviewer set, offers to push. Then the same scenario with the generated
   prompt: it must touch no files, run the probe block, print the table and stop.
4. **Wording micro-test** for the `DO NOT` block — 5+ repetitions against a no-guidance
   control, every flagged match read by hand, before the full scenario runs.

## Assumptions and risks

- **The `codex` / `gemini` probes are heuristics.** They test that the CLI exists and that the
  provider's public endpoint answers — not that the CLI is authenticated, and not that it is
  even pointed at that endpoint (codex may use ChatGPT auth or a proxy). `OK` there means
  "network and binary are present", and the detail column says `heuristic` so no reader
  upgrades it into a guarantee.
- **`/mesh-review` has no cross-run memory of earlier reviews.** By decision, the code-review
  prompt does not carry links to previous review files: if that matters, it is the skill's job
  to find them, not the prompt's.
- **The shared-folder mount means commits land in the host repository.** Nothing needs to be
  exported from the sandbox, and no part of this design tries to.
- **The plugin version inside the sandbox may lag the host's.** Handled by decision 6, but it
  stays the most likely reason a generated prompt underperforms.
