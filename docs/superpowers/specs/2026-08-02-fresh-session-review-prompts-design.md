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
   `skills/mesh-design-review/SKILL.md` Step 6 records a 2026-07-26 run where four of six
   executors — none supervised by a watchdog — died mid-stream and nothing noticed for
   38 minutes, and a 2026-07-27 run where four of five died again.
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
Step 1 derives it: extract from `YYYY-MM-DD-<topic>-design.md`, then **repeatedly** strip
trailing `-review` / `-design` suffixes — Step 1's own example removes two in sequence,
`iterative-review-design.md` → `iterative`. The iteration number is
`max(N in docs/superpowers/specs/*-<TOPIC>-review-iter-N.md) + 1`, which is Step 2's rule.

The "matching plan" lookup is ordered and explicit — three plan-naming conventions coexist in
this repo, so an undefined "matching" would derive differently in two places:
`plans/<date>-<topic>-implementation.md`, then `plans/<date>-<topic>-plan.md`, then
`plans/<date>-<topic>.md`, then the newest `plans/*<topic>*.md`; nothing found → ask.

Both are copies, so both carry a sync note naming the step they mirror. A generator that
derives a different topic counts a different set of iteration files, and would hand the review
session an iteration number the skill then disagrees with.

The output filename takes its date from the **design document's** filename, not from today —
the rule `mesh-design-review` Step 13 already applies to iteration files, so all artifacts of
one topic sort together.

### 5. Probe per provider, report per model, always exit 0

Models of one provider share an endpoint, so the probe runs one check per provider and expands
the verdict back into model ids in its `SUMMARY` line — in the exact spelling the selection UI
of `mesh-review` / `mesh-design-review` uses, so the reading session has nothing to map. The
built-in reviewer follows the same rule: with a `claude.models` catalog the SUMMARY expands it
as `claude:opus, claude:fable` — the spelling the confirmation page uses — and prints plain
`claude` only in the no-catalog fallback.

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
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```
Print the table verbatim. Do not soften a verdict into "probably fine". The not-found branch
exits 0 on purpose: an old plugin is a fact about the environment, not a failed tool call —
a non-zero exit would send the session repairing the probe instead of following the
degradation instructions. (`bash "$PF"`, not `"$PF"`: a shared-folder mount may drop the
exec bit.)

## CONTEXT
What is not in the documents: decisions and why, rejected alternatives, known constraints,
sharp edges. <= 40 lines. Not a retelling of the documents.

## THEN STOP
1. A summary of the documents in 5–10 lines.
2. The preflight table, verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO
Invoke `/claude-mesh:mesh-design-review DESIGN_PATH=<path> PLAN_PATH=<path> TOPIC=<topic>`
(code-review tail: `/claude-mesh:mesh-review`), selecting only reviewers the preflight
marked OK.
````

### Tail — `design-review-fresh-session`

- Arguments: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=` (all optional; discovery mirrors
  `exec-plan-fresh-session` Step 1, and asks when nothing is found).
- Iteration 1: `CONTEXT` is the brainstorming residue — decisions, rejected alternatives,
  constraints. Its only source is the generating session itself: when that session does not
  hold the residue (standalone invocation, or the discussion already evicted from context),
  the generator asks the user for the key decisions — it never fabricates them — or, if the
  user declines, writes `CONTEXT` with an explicit note that it is limited to what the
  documents imply.
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
  `TOPIC` from the branch name **normalised to a slug**: drop everything up to the last `/`
  (`feat/x-y` → `x-y`), apply the usual trailing `-design` / `-review` strip, then map any
  character outside `[a-z0-9-]` to `-`; detached HEAD (`git symbolic-ref --short HEAD` fails)
  falls back to `git rev-parse --short HEAD`; an empty result asks the user. `DATE` is today.
  Omit the missing entries from `DOCUMENTS`, and keep the git range. Never invent a document
  path.
- The generator checks `git status --porcelain` before writing the file: a dirty worktree is
  warned to the operator and named in the prompt ("uncommitted changes existed at generation —
  the review covers commits only"); it is never silently ignored.

Neither generator commits the prompt file. Writing it is enough — `docs/superpowers/` is
removed before a PR anyway, and the sandbox shares the working copy, so the file is visible on
both sides the moment it is written.

## `skills/shared/preflight-env.sh`

**Invocation:** no arguments. `PREFLIGHT_HTTP_TIMEOUT` (default 5) and `PREFLIGHT_GIT_TIMEOUT`
(default 8) override the per-probe budgets — the ollama precheck receives the same budget
through env knobs (`OLLAMA_PRECHECK_TRIES=1`, attempt/tags timeouts = `PREFLIGHT_HTTP_TIMEOUT`);
the knobs are added to `ollama-precheck.sh` by this work, with defaults that preserve its
current behaviour for every other caller. `PREFLIGHT_CURL_BIN` (default `curl`),
`PREFLIGHT_GIT_BIN` (default `git`), `PREFLIGHT_YQ_BIN` (default `yq`) and `PREFLIGHT_JQ_BIN`
(default `jq`) name the binaries — resolved through a variable so that "the tool is absent" is
a testable state rather than an exercise in PATH surgery. `PREFLIGHT_CURL_BIN` governs only the
probe's **own** HTTP checks (the codex / gemini heuristics): the reused prechecks resolve
`curl` from `PATH`, so when the resolved curl is absent the probe does not invoke them at all —
provider rows report `UNKNOWN — no curl` instead of a fake network verdict.

**Output:** one line per capability, `name`, status, detail — fixed order, so a test can assert
on it:

```
config           OK           /home/u/.claude/plugins/data/claude-mesh-zinin/config.yaml
builtin-claude   OK           always available, needs no config section
claude-models    OK           opus, fable
codex            NO-NETWORK   CLI present, api.openai.com unreachable in 5s (heuristic)
gemini           MISSING      no gemini: section in config — the UI will not offer it
provider:zai     OK           endpoint answered, credentials accepted (https://api.z.ai/api/anthropic)
provider:ollama  NO-NETWORK   http://localhost:11434 timed out after 5s
git-remote       NO-NETWORK   git ls-remote origin timed out after 8s
gh               MISSING      not on PATH
glab             MISSING      not on PATH
clipboard        MISSING      no xclip/xsel/pbcopy

SUMMARY available: claude:opus, claude:fable, zai/glm, zai/glm-air
SUMMARY unavailable: codex (NO-NETWORK), gemini (MISSING), ollama/kimi (NO-NETWORK)
```

Order: `yq` / `jq` (only when missing), `config`, `builtin-claude`, `claude-models`, `curl`
(only when missing), `ext-claude-deps` (only when something is missing), `codex`, `gemini`,
`provider:*` in order of first appearance in `models` — a provider with no models gets no row,
there is nothing it could offer the selection UI; the aggregate row `provider` replaces
`provider:*` when providers are not probed at all (no usable config, or no models) — then
`git-remote`, `gh`, `glab`, `clipboard`, and the two `SUMMARY` lines.

**Status set (closed):** `OK`, `MISSING` (tool or section absent), `NO-NETWORK` (present but
its endpoint did not answer), `AUTH-FAILED` (endpoint answered, credentials rejected),
`INVALID` (config only — the validator rejected it), `SKIPPED` (not probed — e.g. providers
when there is no config), `UNKNOWN` (the probe could not decide, e.g. `curl` absent).

**`codex` / `gemini` rows report what the selection UI will actually offer**, which is a
config question before it is a network one: `mesh-review` Step 2 and `mesh-design-review`
Step 5.2 show those options only when `get-flag has_codex` / `has_gemini` returns 1 — but the
UI's consumers then read the section through the **typed getters** (`get-codex` /
`get-gemini`), which validate it and die on a malformed one, while the bare `has_*` probe
validates nothing. The probe mirrors both gates: section absent (`has_*` = 0) →
`MISSING — no codex: section in config`, whatever the CLI on PATH says; section present but
the typed getter exits non-zero → `INVALID` with the first line of the validator's stderr
(`broken-codex-valid-gemini.yaml` exists for exactly this class); only a present-and-valid
section reaches the network heuristic.
`claude-models` reports the sandbox's `claude.models` catalog (or `MISSING`, meaning one
claude reviewer on the dispatch model) — a local read, no network, and the operator otherwise
learns how many Claude reviewers exist there only after entering the selection UI. That read
is rc-aware too: a broken `claude:` section is `INVALID` with the validator's reason — the
same read `mesh-review` Step 1 refuses to start on — never conflated with an absent catalog.

**Reuse, do not reimplement:** providers are probed through the existing
`skills/ext-claude-exec/token-precheck.sh` (exit 0 → `OK`, 5 → `AUTH-FAILED`, 6 →
`NO-NETWORK`) and `ollama-precheck.sh`, routed by the provider `kind` exactly as
`ext-claude-exec` routes it. Model and provider data come only through `config-loader.sh`
(`list-models`, `export`) — never raw `yq`.

**Config states:** before touching the loader the probe checks the loader's own toolchain
(`PREFLIGHT_YQ_BIN` / `PREFLIGHT_JQ_BIN`): a missing tool prints its own `MISSING` row and
`config UNKNOWN cannot evaluate — <tool> not installed`, providers `SKIPPED`, and the loader
is never invoked — rc=1 from a dead toolchain must not impersonate a rejected config. With the
toolchain present: loader rc=2 → `config MISSING`, providers `SKIPPED`, `SUMMARY available`
still contains `claude`. Loader rc=1 → `config INVALID <first line of the validator's message>`,
providers `SKIPPED`. Loader script itself not found → `config MISSING (config-loader.sh not
found)`. All of these exit 0: they are facts about the environment, not failures of the probe.

**Secrets:** `config-loader.sh export <model>` writes an env file containing the provider
token and prints its path. The probe sources it in a subshell and deletes it from a
`trap … EXIT`; no byte of that file reaches stdout or stderr. This is a test assertion, not an
intention. The prechecks are invoked through `env -u SKIP_TOKEN_PRECHECK`: that variable
exists so a caller can skip the check, and inherited from the surrounding shell it would turn
every provider row into a false `OK`.

`probe_provider` reports through globals and is called as its own command, **never inside a
command substitution**: an assignment made in `$()` dies with its subshell, which is exactly
how `CURRENT_ENVF` — and with it the trap guarantee — would silently vanish (the `cli_row`
rule exists for the same reason). The sourcing subshell hands back only `rc|base_url`:
`base_url` is not a secret and goes into the row's detail; the token never crosses the
boundary. On INT / TERM the trap removes the file and the probe exits **non-zero** — an
interrupt is not a verdict; "every verdict exits 0" covers completed runs only.

**Providers with no usable token:** `export` fails (rc≠0) when the token is still
`REPLACE_ME`. That is `MISSING — token not configured for this provider`, not a network
verdict. `export` also dies on things that are no token problem at all — a `runtime:` section
its validator rejects, a model id it cannot find, a failed `mktemp` — so the probe captures
its stderr: a message naming the token / `REPLACE_ME` stays `MISSING`, anything else becomes
`UNKNOWN — export refused: <first stderr line>` rather than a lie about the token.

**Cost:** probes are sequential. Per provider the worst case is `PREFLIGHT_HTTP_TIMEOUT` for
anthropic-kind and ~2×`PREFLIGHT_HTTP_TIMEOUT` for ollama-kind (reachability + tags, one
attempt each under the probe's env knobs), so five providers land in the 25–50 s range at
default budgets, plus up to `PREFLIGHT_GIT_TIMEOUT` for the remote. That is still the price of
one check, against six reviewers hanging for minutes.

**Dependencies:** bash 4.0+, `timeout` (GNU coreutils, already required by this repo);
Python-yq and `jq` are hard requirements of the loader and are probed **before** it — their
absence degrades `config` to `UNKNOWN`, it does not error. `git` and `curl` stay optional —
their absence produces `MISSING` / `UNKNOWN` rows. `ext-claude-deps` reports `claude` / `bc` /
`python3` (the ext-claude executors STOP without them), printed only when something is
missing; provider rows then read `MISSING — ext-claude prerequisites absent: <list>` and skip
the network.

**Authority and lifetime:** the probe is the single source of truth about this environment —
no other shared script probes the network or the git remote on its own; consumers read the
table instead of re-checking. Its output is a snapshot at invocation: a config edited after
the run is not reflected until the probe is re-run.

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
| `/claude-mesh:design-review-fresh-session` not found (sandbox on an older plugin) | `mesh-design-review` Step 15 falls back to `/claude-mesh:continue-plan-fresh-session` with a warning that the plugin needs an update for the review-generator flow |

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
   control, every flagged match read by hand, before the full scenario runs. Pass criterion is
   positive, not only negative: the candidate holds in ≥4 of 5 runs **and** the control fails
   in ≥2 of 3; a control that never fails sends the block back to decision 3 for
   reconsideration — it is never silently dropped.
5. **Subagent runs are a proxy, not the acceptance test** — system prompt, defaults and loaded
   context all differ from a real fresh session. Acceptance is one manual run of a generated
   prompt in a real sandbox session on an updated plugin, recorded in the baseline file under
   an `ACCEPTANCE` heading.

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
  stays the most likely reason a generated prompt underperforms. Decision 6 covers the probe;
  the missing-**command** case (`design-review-fresh-session` not resolving in Step 15) is
  covered by the fallback row in Error handling — an older plugin lacks both, and each has its
  own degradation.
