---
name: mesh-design-review
description: Iterative design review with memory - remembers previous answers, filters duplicates
user_invocable: true
---

# Iterative Design Review (mesh-design-review)

Run iterative design review cycle with memory of previous decisions.

**Announce at start:** "Using mesh-design-review skill for iterative review with memory."

## Locating plugin files (Task 2.5)

Set `SKILL_BASE` from the `Base directory for this skill: <ABS>` line Claude Code prints at load **if present**. Do not rely on Grok printing that line. **`${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are NOT available inside Bash-tool calls** (verified empty on Claude Code 2.1.156). This skill is not a command file: the harness does **not** substitute `${CLAUDE_PLUGIN_ROOT}` into its text.

At the top of EACH bash fence:
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")

When `SKILL_BASE` is empty, that second line cannot expand `$SKILL_BASE/../shared/…`. Call the resolver by the version-sorted find already used in `commands/mesh-review.md` Step 1:
LOADER="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
then `PLUGIN_ROOT` is two directories up from that loader (`$(cd "$(dirname "$LOADER")/../.." && pwd)`), and `SKILL_BASE` is `$PLUGIN_ROOT/skills/mesh-design-review`. `$CLAUDE_PLUGIN_ROOT` / `$GROK_PLUGIN_ROOT` also work when set to an existing plugin root — `resolve-plugin-root.sh` tries them after an empty `SKILL_BASE`.

From `SKILL_BASE` / `PLUGIN_ROOT`:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- sibling shared scripts = `$SKILL_BASE/../shared/<x>`
- data dir = `"$LOADER" data-dir` (the loader self-discovers `~/.claude/plugins/data/claude-mesh-*`); build any state paths under `$PLUGIN_DATA/state/`

Config reads in this skill go through the loader subcommands (`get-flag`, `get-defaults design_review`, `list-models`, `list-claude-models`) — never raw `yq`. `get-flag` returns `1`/`0`; compare to `1`, never to `"true"`.

## When to Use

- When you have design/plan documents ready for external critique
- When you want an automated review cycle until no new issues remain
- To avoid answering the same review comments across iterations (skill remembers prior decisions)

## Input Parameters

Optional (caller can specify):
- **DESIGN_PATH** — explicit path to design document
- **PLAN_PATH** — explicit path to plan document
- **TOPIC** — topic name for file naming
- **CODEX_MODEL** — Codex model. Default: resolved from `config.yaml` (`codex.model`) by the codex executor itself; final fallback "gpt-5.5". Set only when the user explicitly overrides.
- **CODEX_REASONING_LEVEL** — reasoning level (`none|minimal|low|medium|high|xhigh|ultra`, known set as of 2026-07; unknown values pass through to codex). Default: resolved from `config.yaml` (`codex.reasoning_level`) by the executor; final fallback "xhigh". Set only when the user explicitly overrides.
- **GROK_REASONING_EFFORT** — reasoning effort for grok (`low|medium|high|xhigh|max`, known set as of 2026-08; unknown values pass through to the grok CLI). Default: resolved from `config.yaml` by the executor for the model it runs — `grok.model_efforts[<model>]`, then the section-wide `grok.reasoning_effort`; when both are unset, the CLI's own default applies — there is no hardcoded final fallback here, unlike codex. Set only when the user explicitly overrides.
- **DEFAULT** — if `default` argument is passed, skip the Step 5 selection UI and use the `defaults.design_review` preset from `config.yaml` (`codex` / `gemini` in `builtin` → their executor; `grok` in `builtin` → one `claude-mesh:grok-executor` per entry of `grok_models`; `claude` in `builtin` → one built-in `general-purpose` reviewer per entry of `claude_models`, no executor agent involved, or a single one in the fallback case; each `models` id → `claude-mesh:ext-claude-executor MODEL=<id>`). See Step 5.
- **AUTODECIDE** — **bind this at the top of Step 5**, before that step's `default` branch, and
  echo `AUTODECIDE=true|false`. Not inside Step 5.1: that sub-step executes only when `default`
  was passed, so a binding placed there never runs on an interactive `autodecide` review.
  Its only consumer is Step 12, a whole review cycle and a background watch loop away; an unbound
  name raises no error in a prompt — the reader improvises, and a run started with `autodecide`
  silently waits for the user after all. If the `autodecide` argument is passed, the disputed
  phase (Step 12) does not
  wait for the user: it hands over to `/claude-mesh:auto-decide-disputed`, which writes the same
  analysis, adds an explicit self-check, and applies its own recommendation, one commit per
  decision. Orthogonal to `default` and combinable with it and with `DESIGN_PATH`/`PLAN_PATH`/
  `TOPIC`; order does not matter.

## Iron Rules for Processing Issues

These rules are NON-NEGOTIABLE. Steps 9–12 implement them; this list exists so you catch yourself before drifting.

> Sync note: rules 3–8 are mirrored in `commands/mesh-review.md` (Iron Rules / Step 6.4). When editing shared rule text, mirror the edit there (step numbers differ; `/mesh-review` additionally has `default`-mode deferral clauses in the disputed phase, which this skill has none of — its `default` argument only selects reviewers, and its only non-waiting path in the disputed phase is the `autodecide` argument).

1. **Phase order is fixed:** classify ALL issues first → apply auto-fixes → commit → discuss disputed one-by-one. Never interleave.
2. **Auto-fixes are committed BEFORE disputed discussion starts.** The user gets a clean checkpoint with all the safe edits.
3. **Disputed issues are processed ONE AT A TIME, in separate messages.** Never present a bulk list of disputed issues. Never dump all variants for all issues in one go.
4. **Every disputed issue gets a structured analysis** (Суть → Анализ → Варианты → Рекомендация). Bullet-only one-liners are forbidden. Write enough that someone who hasn't read the review can follow.
5. **Always evaluate the variants you propose.** Each variant gets pros/cons, and you explicitly recommend ONE with reasoning. Never list variants neutrally.
6. **If only one variant is genuinely adequate, do not ask the user.** Announce the decision, briefly say why the others fail, apply, move on. Asking when there's no real choice is noise.
7. **One disputed issue at a time.** Present its analysis; if one variant is adequate, apply it in the same message and move on; if a choice remains, the analysis is the FINAL message of the turn (no tool call) and you wait for the user's free-text answer, then apply and start the next. In `autodecide` mode do not wait: follow `/claude-mesh:auto-decide-disputed`, which applies your own recommendation after an explicit self-check. (This skill has no `default`-mode deferral to suppress; «стоп» still stops the run and defers the remainder.) Never batch.
8. **When a choice remains, the analysis IS the question — never AskUserQuestion.** The structured write-up (variants with pros/cons + recommendation) is the turn-final message; the turn ends with no trailing tool call and the user answers in free text. In `autodecide` mode the analysis is not a question at all — see Step 12. A trailing AskUserQuestion duplicates your write-up in its own modal UI and makes the harness drop the analysis — the user then sees only a bare modal. This is the regression this rule prevents.

### Red Flags — STOP if you catch yourself doing this

| Anti-pattern | What to do instead |
|---|---|
| About to print a list of all disputed issues in one go | Stop. Take only the first one. Write its full structured analysis. |
| Writing variants as "вариант A / B / C" without pros, cons, and a recommendation | Stop. For each variant write Плюсы / Минусы. Pick the best with 2–3 sentences why. |
| Asking the user a question while three other disputed issues are still unprocessed | Stop. Resolve current → apply → THEN start next. |
| Asking the user to pick when only one option actually works | Stop. Announce the decision and apply it. Asking is noise. |
| About to call AskUserQuestion for a disputed choice | Stop. The analysis + variants + recommendation are the turn's FINAL message; end the turn there and take the answer as free text. A modal would swallow the analysis (that is the regression). |
| Shrinking the analysis so a tool call can follow in the same turn (interactive mode) | Stop. The analysis is the final message of the turn, as long as the issue needs. Don't trim it to precede a tool. In `autodecide` this row does not apply — there the analysis is *meant* to be followed by the edit and the commit in the same turn, at full length; see the row below. |
| Applying an auto-fix in the middle of disputed discussion | Stop. Auto-fixes must all happen before disputed phase starts (Step 10), and must be committed (Step 11) before Step 12 begins. |
| Skipping the auto-fix commit because "I'll commit everything at the end" | Stop. The intermediate commit (Step 11) is the user's safe checkpoint. It is mandatory whenever auto-fixes were applied. |
| In `autodecide` mode, ending the turn to wait for the user's answer | Stop. That mode exists precisely to not wait: write the analysis, add `Проверка решения`, decide, commit, continue. |

## Process

### Step 1: Find Documents

**If DESIGN_PATH provided:** Use it directly.

**Otherwise search:**
1. Search `docs/superpowers/specs/*-design.md`, sort by date, take latest
2. If not found, ask user to specify path

**For plan document:**
- If PLAN_PATH provided, use it
- Otherwise look for matching: `YYYY-MM-DD-<topic>-implementation.md`
- Plan is optional

**Extract TOPIC** from design filename: `YYYY-MM-DD-<topic>-design.md` → topic

**Normalize TOPIC:** Remove suffixes `-review`, `-design` if present.
- Example: `iterative-review-design.md` → TOPIC = `iterative` (not `iterative-review`)

<!-- SYNC: TOPIC derivation is mirrored by commands/design-review-fresh-session.md
     Step 2 and commands/code-review-fresh-session.md Step 3 — change all three together. -->

### Step 2: Find Previous Iterations

Search for existing iteration files:
```bash
ls docs/superpowers/specs/*-{TOPIC}-review-iter-*.md 2>/dev/null | sort -V
```

Count existing iterations. Next iteration = max + 1 (or 1 if none).

<!-- SYNC: iteration counting is mirrored by commands/design-review-fresh-session.md
     Step 2 — change together. -->

### Step 3: Build Review History

If previous iterations exist, parse them to build PREVIOUS_DECISIONS table:

```markdown
## PREVIOUS REVIEW DECISIONS

The following issues were already raised and resolved in previous iterations.
Do NOT repeat these — they are documented decisions.

### Iteration 1 (YYYY-MM-DD)

| Issue | Decision | Rationale |
|-------|----------|-----------|
| Issue summary | Decision made | Why |

[repeat for each iteration]

Focus only on NEW issues not covered above.
```

### Step 4: Compose Review Prompt

**Read documents.** Read the design document (and plan if found) to understand what's being reviewed.

**Collect project context.** Gather brief context (if available) from:
- Project's `CLAUDE.md`
- `package.json` or `README.md` (project name, tech stack)

Keep it concise — just enough for reviewer to understand the project.

**Collect session context.** If brainstorming session context is available, extract:
- Key decisions made and their rationale
- Alternatives considered but rejected (and why)
- Known constraints and trade-offs
- Non-obvious details from discussion

**Be concise.** Only include what adds value for the reviewer. Skip if no brainstorming context available.

**Build the prompt** using this template:

```markdown
## TASK

Review and critique the design document(s) for [TOPIC].

You have full access to the project. Read the documents and explore the codebase as needed.

**IMPORTANT: Respond in Russian language.**

## DOCUMENTS

- Design: `[DESIGN_PATH]`
- Plan: `[PLAN_PATH]` (include only if plan exists)

Read the document(s) before reviewing.

## PROJECT CONTEXT

[Brief project description - what it is, tech stack]

(omit section if no context)

## SESSION CONTEXT

[From brainstorming:
- Key decisions and rationale
- Rejected alternatives
- Known constraints]

(omit section if no brainstorming context)

## PREVIOUS REVIEW DECISIONS

[Insert PREVIOUS_DECISIONS table from Step 3 here if iterations > 0]

Focus only on NEW issues not covered above.

(omit section if iterations == 0)

## REVIEW FOCUS

Critique the design/plan on:

1. **Architecture** - design decisions, scalability, maintainability
2. **Completeness** - missing edge cases, unclear requirements, gaps
3. **Feasibility** - implementation complexity, potential blockers
4. **Alternatives** - better approaches not considered

Be critical. Point out problems, not just praise.

## OUTPUT FORMAT

### Critical Issues
[Problems that must be addressed before implementation]

### Concerns
[Potential problems worth discussing]

### Suggestions
[Improvements and alternative approaches]

### Questions
[Clarifications needed from the author]
```

This composed prompt is self-contained and gets passed to each executor agent in Step 6.

### Step 5: Select Review Agents (first iteration only)

<!-- SYNC: the remembered set is ONE list living in two places — the sentence below
     (in prose, because Step 5 introduces the set before any variable exists to name it)
     and Step 5.4's "Remember the confirmed set" line (the names that hold it). The drift
     this guards against already happened once: grok was added to Step 5.4 and not here.
     Change both or neither. -->
Reviewer selection is **config-driven** — there are no hardcoded provider/model lists. Read the available executors and models from `config.yaml` via the loader, then either honor the `defaults.design_review` preset (`default` argument) or run the paginated selection UI. **Selection is made on the FIRST iteration only and reused for every subsequent iteration in the loop** — remember the resulting agent set (built-ins + native models + Claude models + grok models + ext-claude model ids). Step 5.4 states the same items, named variables among them — the built-in TYPES is the one Q1 and Step 5.2.1 write directly, with no variable of its own ("What Q1's answer becomes" below says so in as many words); the two must always agree about what is remembered.

**Bind `AUTODECIDE` here, before anything else in this step** — unconditionally, whether or not `default` was passed: it is `true` when `autodecide` appears among the arguments, `false` otherwise. Echo it (`AUTODECIDE=true|false`) so it is on screen. Step 5.1 is the wrong home for it — that sub-step runs in `default` mode only, while `autodecide` is orthogonal to `default` and just as valid on an interactive run. Its only consumer is Step 12, a whole review cycle and a background watch loop away; an unbound name raises no error in a prompt — the reader improvises, and a run started with `autodecide` quietly waits for the user after all. Like the agent set, it is bound on the first iteration and holds for any further iteration run in THIS session — it does not survive into a fresh one, since `/claude-mesh:design-review-fresh-session` builds the next invocation out of DESIGN_PATH/PLAN_PATH/TOPIC and carries no `autodecide`, so a next iteration that should also run unattended needs the word typed into that generated prompt by hand. Same reason `/claude-mesh:mesh-review` binds it in its Step 0.

**Detect HOST here**, after AUTODECIDE, before Step 5.0: `HOST=grok` if this session has a
`spawn_subagent` tool, else `HOST=claude-code`. Presence of `spawn_subagent` is the test. Do not
require `Task` to be missing: a future Grok build that also exposes `Task` would otherwise be
classified as Claude Code. Echo it (`HOST=grok|claude-code`) so it is on screen. `$HOST` is prompt
state, not a shell variable across Bash calls — when a later fence branches on host, substitute
the literal `grok` or `claude-code` you echoed.

#### Step 5.0: Read available reviewers from config

Run ONE Bash call. Use `config-loader.sh` (NOT raw `yq`) so validation runs the same way everywhere:

```bash
# Task 2.5 (CC 2.1.156): ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA} are EMPTY in
# Bash-tool calls from skills. Locate files via the absolute base dir Claude Code
# prints at skill load ("Base directory for this skill: <ABS>"). See "## Locating
# plugin files (Task 2.5)" near the top.
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
LOADER="$SKILL_BASE/../shared/config-loader.sh"
[ -x "$LOADER" ] || { echo "config-loader.sh not found at $LOADER" >&2; exit 1; }

# iter-3 CRITICAL-3: a bare $() swallows the loader exit code. Probe once with explicit rc
# capture so rc=2 (config.yaml not created yet — fresh install) is NOT misreported as
# rc=1 (config invalid).
LOADER_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
HAS_CODEX=$("$LOADER" get-flag has_codex 2>"$LOADER_ERR"); LRC=$?
case "$LRC" in
  0) ;;
  # Name the dir the loader actually reads — a literal placeholder here would be substituted
  # by the harness and, under a --plugin-dir load, would point at the wrong data dir.
  2) echo "config.yaml ещё не создан. Скопируйте config.example.yaml в $("$LOADER" data-dir)/config.yaml, заполните токены и повторите /claude-mesh:mesh-design-review."; rm -f "$LOADER_ERR"; exit 0 ;;
  *) echo "config.yaml невалиден:" >&2; cat "$LOADER_ERR" >&2; rm -f "$LOADER_ERR"; exit 1 ;;
esac
rm -f "$LOADER_ERR"
HAS_GEMINI=$("$LOADER" get-flag has_gemini)
# grok: BOTH reads below VALIDATE the `grok:` catalog before answering, unlike the bare probes
# has_codex / has_gemini beside them. That is a difference in what the flag PROMISES, not an
# inconsistency: `has_grok` is consumed as "a grok reviewer can be dispatched", which needs a
# non-empty catalog because the grok agent stops without a MODEL (the `has_grok)` arm of the loader).
# So either call can exit 1 on a malformed section. WARN and degrade grok ALONE rather than
# exiting: a broken `grok:` section must not kill a codex-only design review — that is the
# `ultra` incident (2026-07-10: one codex setting killed every ext-claude
# executor) in a new costume. Report it, drop the flag, let everything else run.
GM_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
if ! HAS_GROK=$("$LOADER" get-flag has_grok 2>"$GM_ERR") \
   || ! GROK_MODELS=$("$LOADER" list-grok-models 2>"$GM_ERR"); then
    echo "ВНИМАНИЕ: секция grok: не валидируется — grok-ревьюеры отключены на этот запуск:" >&2
    cat "$GM_ERR" >&2
    HAS_GROK=0; GROK_MODELS=""
fi
rm -f "$GM_ERR"
echo "HAS_GROK=$HAS_GROK"
echo "GROK_MODELS=[$(echo "$GROK_MODELS" | tr '\n' ' ')]"
HAS_MODELS=$("$LOADER" get-flag has_models)
MODELS=$("$LOADER" list-models)            # `<id>|<label>` per line, ready for pagination
# rc-aware, like the dispatch_model read below. A bare $() swallows the loader exit code
# (the fence says so 14 lines above, for has_codex) — and get-defaults is what runs
# validate_defaults, so the new fail-closed claude_models guard reports through THIS call.
# Swallowed, it leaves DEFAULTS_JSON empty and Step 5.1 then STOPs with the misleading
# "defaults.design_review not configured" instead of the real validation error.
DJ_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
DEFAULTS_JSON=$("$LOADER" get-defaults design_review 2>"$DJ_ERR") \
    || { echo "config.yaml невалиден (defaults.design_review):" >&2; cat "$DJ_ERR" >&2; rm -f "$DJ_ERR"; exit 1; }
rm -f "$DJ_ERR"   # {"builtin":[...],"claude_models":[...],"native_models":[...],"grok_models":[...],"models":[...],"run_mode":null}
echo "$DEFAULTS_JSON"
DM_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model 2>"$DM_ERR") \
    || { echo "config.yaml невалиден (runtime.dispatch_model):" >&2; cat "$DM_ERR" >&2; rm -f "$DM_ERR"; exit 1; }
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
# Claude-model catalog (Step 5.2.5 gate). rc-aware like the dispatch_model read above:
# both subcommands validate the `claude:` section, so a malformed section fast-fails here.
CM_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (секция claude):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
CLAUDE_MODELS=$("$LOADER" list-claude-models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (claude.models):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
rm -f "$CM_ERR"
echo "HAS_CLAUDE_MODELS=$HAS_CLAUDE_MODELS"
echo "CLAUDE_MODELS=[$(echo "$CLAUDE_MODELS" | tr '\n' ' ')]"
# HOST=grok extra probes. `$HOST` is prompt state from Step 5 — substitute the literal
# `grok` or `claude-code` you echoed; it is not a shell variable across Bash calls.
HAS_CLAUDE_CLI=0
command -v claude >/dev/null 2>&1 && HAS_CLAUDE_CLI=1
echo "HAS_CLAUDE_CLI=$HAS_CLAUDE_CLI"
HOST_MODELS=""
if [ "$HOST" = grok ]; then
  GM=$(mktemp)
  if grok models >"$GM" 2>/dev/null; then
    HOST_MODELS=$(bash "$(dirname "$LOADER")/list-host-models.sh" --from-file "$GM")
  fi
  rm -f "$GM"
fi
echo "HOST_MODELS=[$(printf '%s' "$HOST_MODELS" | tr '\n' ' ')]"
```

rc=0 → proceed; rc=2 → fresh-install hint + clean exit; rc=1 → surface the validator stderr and stop (iter-3 CRITICAL-3). Parse `DEFAULTS_JSON` with jq (`.builtin`, `.claude_models`, `.native_models`, `.grok_models`, `.models`, `.grok_degraded`) to build `DEFAULT_IDS` (recommended ext-claude model ids), `CLAUDE_DEFAULT_IDS` (recommended Claude models), `NATIVE_DEFAULT_IDS` (recommended native slugs — the ★ set Step 5.2.3 marks with), `GROK_DEFAULT_IDS` (recommended grok models — the ★ set Step 5.2.6 marks with, so that page needs no loader read of its own) and the recommended built-in set. Compare `HAS_CODEX` / `HAS_GEMINI` / `HAS_GROK` / `HAS_MODELS` / `HAS_CLAUDE_MODELS` to `1` (the loader emits `1`/`0`, never `"true"`).

#### Step 5.1: `default` argument → use the preset

**If the `default` argument was passed:** skip the entire selection UI (Steps 5.2–5.3). Use the `defaults.design_review` preset from `DEFAULTS_JSON`:

- If `defaults.design_review` is missing/empty (`.builtin` empty AND `.models` empty) → STOP with a clear error:
  `defaults.design_review not configured in config.yaml. Run /claude-mesh:mesh-design-review without "default" or add the preset.`
- For each entry in `.builtin`:
  - `claude` → expand over `.claude_models` (this branch was MISSING before this feature, which is why `claude` in `defaults.design_review.builtin` used to be silently dropped):
    - list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`, which **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
    <!-- SYNC: the fallback rule in the next bullet is ONE rule living in four places — this file's Step 5.2.5 ("Empty selection is not an error"), and `commands/mesh-review.md` Step 0 / Step 2.4. Change all four or none. -->
    - list absent/empty → exactly **one** reviewer named `claude`, with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise no `model:` at all (inherits the session model).
  - **Bind `SELECTED_CLAUDE_MODELS` to that resolved list here** (`.claude_models`, or empty in the fallback case), exactly as `/mesh-review` Step 0 does. Step 5.4 remembers `SELECTED_CLAUDE_MODELS` for iterations 2..N, so in `default` mode it must actually hold something by then.
  - **On HOST=claude-code, `native` in builtin collapses to this same host set.** Treat `native` as `claude` for host reviewers — `native ∪ claude` is one set sourced from `claude_models` (and the empty-list fallback above). Ignore `.native_models`. **Bind `SELECTED_NATIVE_MODELS` to the empty list** — on Claude Code the host set is `SELECTED_CLAUDE_MODELS`; native bullets must not appear on confirm.
  - **On HOST=grok, `native` is a separate type.** `claude` in builtin is the Claude Code CLI (`claude-mesh:claude-executor`), not host slugs. If `native` is not in `.builtin`: **bind `SELECTED_NATIVE_MODELS` to the empty list**. If `.native_models` is non-empty and `native` is not in builtin, the loader already rejected the file.
  - On HOST=grok, use `HOST_MODELS` from Step 5.0:
    - If `native` was requested and `HOST_MODELS` is empty: print `native не запущен; остальные работают.` **bind `SELECTED_NATIVE_MODELS` empty**, and **remove native from selected types** (`native_degraded` spoken, not a loader flag). Empty `SELECTED_NATIVE_MODELS` is then "no native reviewers", not omit-`model:`.
    - If `native` was requested and `HOST_MODELS` is non-empty: intersect `.native_models` with `HOST_MODELS` (`grep -Fxq`); skip missing slugs with **one WARN**, not one per slug. **Bind `SELECTED_NATIVE_MODELS` to the intersection.** An originally empty/absent `.native_models` stays empty — that is the signal for one session-model reviewer (omit `model:` at dispatch), and `native` stays selected. If `.native_models` was **non-empty** and the intersection is empty: do not run native, **remove native from selected types**, bind `SELECTED_NATIVE_MODELS` empty, and **do not substitute the session model**.
  - `codex` → spawn `claude-mesh:codex-executor`
  - `gemini` → spawn `claude-mesh:gemini-executor`
  <!-- SYNC: the "no fallback" rule in the next bullet is ONE rule living in five places — this
       bullet, this file's Step 5.2.6 ("An empty selection runs no grok reviewer"), and their two
       twins in the sibling orchestrator (`commands/mesh-review.md` Step 0's grok preset bullet
       and Step 2.45's same paragraph), plus the design's §1 note that grok_models is required
       whenever grok is in builtin. The count is of PHYSICAL sites, like the claude fallback
       rule's own four-place markers — each orchestrator states the rule twice, in its preset
       branch and on its model page, and the design doc states it once. Change all five or none:
       a copy that still promises a fallback would have the orchestrator dispatch a reviewer the
       agent then refuses to start for want of a MODEL. -->
  - `grok` → **one `claude-mesh:grok-executor` per entry of `.grok_models`** — the EXECUTOR, never
    a review-wrapper agent. Design review composes its own prompt in Step 4 and hands it over
    verbatim, while a review wrapper would resolve a `BASE_BRANCH`/`merge-base` diff and render
    `shared/code-review-prompt.md` instead: it would review the working tree and ignore the two
    documents entirely. That is the same reason this file dispatches `codex-executor` /
    `gemini-executor` / `ext-claude-executor`. Each gets `MODEL=<entry>` on the FIRST non-blank
    line and the tooling-constraint paragraph appended to the composed prompt — both shapes are
    written out in Step 6. Name them `grok:<model>` everywhere downstream. The validator
    guarantees a non-empty list whenever `grok` is in `builtin` (the loader's fail-closed rule — "a grok
    reviewer cannot start without a model"), so this branch has no fallback and cannot dispatch
    nothing.
  - **If `.grok_degraded` is `true`, dispatch no grok executor and SAY SO.** The loader sets it when this preset names grok while the `grok:` catalog does not validate: it strips `grok` from `.builtin` and empties `.grok_models` instead of failing the read, so one typo cannot ground the codex, gemini, claude and ext-claude executors this run also asked for. The flag is the only signal that a requested executor is absent, so print it: `grok: каталог grok.models не валидируется — grok-исполнитель не запущен; остальные движки работают. config.yaml правит пользователь, агенты его не трогают.` Do not stop and do not substitute another engine.
  - **Bind `SELECTED_GROK_MODELS` to that list here** (the empty list when `grok` is absent from
    `builtin`), exactly as `SELECTED_CLAUDE_MODELS` is bound above. Step 5.4 remembers it for
    iterations 2..N and the Step 6 dispatch consumes it unconditionally, so in `default` mode it
    must actually hold something by then; an undefined name in a shell script raises an error
    under `set -u`, while in a prompt it raises nothing at all — the reader improvises.
- For each model id in `.models` → spawn `claude-mesh:ext-claude-executor` with `MODEL=<id>`.
- **If HOST=grok and the preset `run_mode` is `team`: STOP** with `На Grok team mode не поддерживается — остановите запуск и используйте background.` Do not dispatch. Grok has no TeamCreate; always background.

Remember this agent set for all subsequent iterations. Go directly to Step 6.

#### Step 5.2 (Q1): Ask which reviewer TYPES

**Otherwise** (interactive), on the first iteration ask which executor TYPES to use.

AskUserQuestion has no `preSelected` API — recommendations are communicated visually with a `★` marker in the label (an entry is recommended when it is in the `defaults.design_review` preset).

Use AskUserQuestion (multiSelect: true, max 4, header: "Reviewers"):
```
question: "Какие типы reviewers запустить? (★ = recommended, в defaults.design_review)"
options:
  HOST=claude-code:
  - "claude ★ default (свой Claude Code)"           — show ALWAYS; ★ if "claude" OR "native" in defaults.builtin (`native` ≡ `claude` on CC)
  - "внешние CLI (<the configured engines, " / "-joined>) ★ default" — show only if HAS_CODEX=1 OR HAS_GEMINI=1 OR HAS_GROK=1; ★ if ANY of codex/gemini/grok is in defaults.builtin.
    Build the parenthesis from the flags that are 1, in the order codex / gemini / grok: a codex-only machine reads «внешние CLI (codex)», never a roster of two
    engines it does not have. The ★ still fires on ANY of the three appearing in `builtin`, because it marks the OPTION, not an individual engine.
    `claude` is **not** in this parenthesis and is **not** on the CLI page.
  - "external models (Anthropic-API) ★ default"     — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
  HOST=grok:
  - "свои модели хоста ★ default" (`native`)        — show ALWAYS; ★ if "native" in defaults.builtin. Do not add `native` as a fourth Q1 option.
  - "внешние CLI (<the configured engines, " / "-joined>) ★ default" — show if HAS_CLAUDE_CLI=1 OR HAS_CODEX=1 OR HAS_GEMINI=1 OR HAS_GROK=1; ★ if ANY of claude/codex/gemini/grok is in defaults.builtin.
    Build the parenthesis from the flags that are 1, in the order claude / codex / gemini / grok, only those whose flags are 1.
  - "external models (Anthropic-API) ★ default"     — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```

**Q1 is three options and stays three however many CLI engines exist later.** AskUserQuestion accepts at most FOUR, and one option is already spent on the host (`claude` on CC, `native` / «свои модели хоста» on Grok) and one on the external models, so the CLI engines share the third — a fourth CLI engine belongs on Step 5.2.1's page, never as a fifth option here. Do **not** "restore symmetry" by splitting this option back into one per engine: on a machine with codex, gemini and grok all configured that call has five options and fails outright, and the failure is the whole question, not one dropped row. Do **not** add `native` as a fourth Q1 option: on Claude Code it duplicates `claude`; on Grok the host already occupies option 1.

(Show the «внешние CLI» and external-models options only when their gating flag is `1` — «внешние CLI» is gated by the OR of the engine flags, since it stands for all of them. The host option is shown unconditionally.)

**What Q1's answer becomes.** «внешние CLI» is not itself a reviewer type and **never enters the selected built-in TYPES** — Step 5.2.1 turns it into the individual engine names (`codex`, `gemini`, `grok`, and on Grok also `claude`), and those are what land in that set. The host option enters as `claude` (CC) or `native` (Grok). It is the same set Step 5.4 confirms and remembers; there is no second selection variable. Everything downstream — Step 5.4's bullet list, the Step 6 dispatch, its watcher roster and its guard — keys off it exactly as it did when Q1 named the engines directly, and no other step changes shape.

- HOST=grok, «свои модели хоста» selected → go to **Step 5.2.3**. If `HOST_MODELS` is empty: print `native не запущен; остальные работают.` **bind `SELECTED_NATIVE_MODELS` empty**, and **remove native from selected types** (`native_degraded` spoken, not a loader flag); skip Step 5.2.3.
- HOST=grok, «свои модели хоста» NOT selected → skip Step 5.2.3; **bind `SELECTED_NATIVE_MODELS` to the empty list**.
- HOST=claude-code → skip Step 5.2.3 always; **bind `SELECTED_NATIVE_MODELS` to the empty list** (host set is `SELECTED_CLAUDE_MODELS`).
- «внешние CLI» selected → go to **Step 5.2.1** and pick which of them.
- «внешние CLI» NOT selected → **skip Step 5.2.1**; no `codex` / `gemini` / `grok` (and on Grok no `claude`) enters the selected TYPES, no CLI reviewer runs at all, and **bind `SELECTED_GROK_MODELS` to the empty list** — Step 5.2.6 never runs on this path, while Step 5.4 and the Step 6 dispatch read that name unconditionally. On Grok, `claude` not entering TYPES is what Step 5.2.5's skip uses to **bind `SELECTED_CLAUDE_MODELS` empty**.
- If "external models" is not selected → skip Step 5.3 entirely.
- If `claude` is not in the selected TYPES → skip Step 5.2.5 and run no claude reviewer at all.
- If `grok` is not selected (in Step 5.2.1) → skip Step 5.2.6 and run no grok reviewer.

#### Step 5.2.1: CLI-engine selection

(No `Q1.x` label. This page runs *before* Step 5.2.5 and Step 5.3, both of which are already numbered off Q1, so any `Q1.x` number here would read as an ordering error. The step number alone is unambiguous.)

Runs ONLY when Q1 selected «внешние CLI». The engines on offer are exactly those whose Step 5.0 flag is `1`. HOST=claude-code: `codex` (`HAS_CODEX=1`), `gemini` (`HAS_GEMINI=1`), `grok` (`HAS_GROK=1`). HOST=grok: the same three plus `claude` (`HAS_CLAUDE_CLI=1`). `claude` appears on this page **only when HOST=grok**. Never offer an engine whose flag is `0` — it has no config section to run from (and for grok a `0` may also mean Step 5.0 degraded it after a validator error it already printed; for `claude` on Grok, `HAS_CLAUDE_CLI=0` means the binary is missing).

**Exactly one engine configured → skip the page and select that engine implicitly**, saying so in one line (`Внешний CLI: codex (единственный настроенный)`). The engine enters the selected TYPES exactly as a page selection would, per the fold below. Without this, every single-engine user pays an extra screen for a problem they do not have.

Otherwise ask ONE page — **not** a pagination loop. AskUserQuestion caps options at 4. HOST=claude-code has three CLI engines; HOST=grok order is `claude, codex, gemini, grok` — that is exactly four. A FIFTH CLI engine is what would need this file's Step 5.3 pagination mechanic; add it then, not now.

AskUserQuestion (multiSelect, max 4):
```
header: "CLI"
question: "Какие внешние CLI-движки запустить? (★ = recommended, в defaults.design_review.builtin)"
options:
  HOST=claude-code — for each CONFIGURED engine, in this order — codex, gemini, grok:
    label:       "<engine> CLI"                     if NOT in defaults.design_review.builtin
                 "★ <engine> CLI (recommended)"     if in defaults.design_review.builtin
    description: "внешнее ревью через <engine> CLI"
  HOST=grok — for each CONFIGURED engine, in this order — claude, codex, gemini, grok:
    claude label: "Claude Code CLI"                 if "claude" NOT in defaults.design_review.builtin
                  "★ Claude Code CLI (recommended)" if "claude" in defaults.design_review.builtin
    claude description: "внешнее ревью через claude -p (`claude-mesh:claude-executor`); never «свой Claude Code»"
    other engines: same "<engine> CLI" / "★ <engine> CLI (recommended)" labels as on CC
```

The ★ comes from the same `defaults.design_review.builtin` list Q1's own ★ markers came from — `DEFAULTS_JSON` was read and echoed in Step 5.0, so there is no loader read here. AskUserQuestion has no `preSelected` API, which is why the recommendation travels in the label text, exactly as in Steps 5.2.5, 5.2.6 and 5.3.

**Fold the selection — the page's answer, or the single engine chosen implicitly above — into the selected built-in TYPES as the individual engine names** (`codex`, `gemini`, `grok`, and on Grok `claude`), never as the «внешние CLI» option itself. The implicit path folds exactly as the page does: skipping the question is not skipping the write. An engine that never reaches that set is dropped at Step 5.2.6's gate and dispatched by nothing — and on a machine where grok is the only configured CLI engine, that is *every* grok reviewer, gone silently if `claude` was also selected and the run still produced a review. That set is what Step 5.4 lists and confirms, what Step 6 dispatches from, and what its watcher roster and guard are built from.

**Selecting no engine is not an error** — the same rule the model pages already follow. It means no CLI reviewer runs; do not re-ask and do not STOP.

**If `grok` is not among the selected engines** — however they were selected, on the page above or implicitly because it is the only one configured — **bind `SELECTED_GROK_MODELS` to the empty list here.** Step 5.2.6's own skip bullet states the same binding, deliberately: Step 5.4 and the Step 6 dispatch read the name unconditionally, and an unbound name in a prompt raises nothing at all — the reader improvises.

**If HOST=grok and `claude` is not among the selected engines**, Step 5.2.5's skip **binds `SELECTED_CLAUDE_MODELS` to the empty list** — same reason.

#### Step 5.2.3: Native-model selection

Runs ONLY when HOST=grok and Q1 selected «свои модели хоста» (`native`) **and** `HOST_MODELS` is non-empty. Slugs in `native_models` missing from live `grok models` do not appear on the page.

- HOST=claude-code → skip; **bind `SELECTED_NATIVE_MODELS` to the empty list**.
- HOST=grok and `native` NOT selected in Q1 → skip; **bind `SELECTED_NATIVE_MODELS` to the empty list**.
- HOST=grok, `native` selected, `HOST_MODELS` empty → skip; print `native не запущен; остальные работают.` **bind `SELECTED_NATIVE_MODELS` empty**, and **remove native from selected types** (`native_degraded` spoken, not a loader flag).

Both skip bindings are mandatory: Step 5.4 remembers `SELECTED_NATIVE_MODELS` for iterations 2..N and the Step 6 dispatch consumes it unconditionally. An unbound name in a prompt raises nothing at all — the reader improvises.

`NATIVE_DEFAULT_IDS` is `.native_models` from Step 5.0's `DEFAULTS_JSON` parse — no new loader read. Native order is `grok models` / `HOST_MODELS` order. Do not lift starred entries to the front. A catalog of ~18 slugs is five pages; do not raise the page size (Claude Code cap is 4).

If `native_models` named slugs that `HOST_MODELS` does not contain: **one WARN** at the start of this page, not one per slug.

For each chunk of 4 entries from `HOST_MODELS` (in `grok models` order) — the same pagination and the same ★ convention as Steps 5.2.5 and 5.3:

<!-- SYNC: empty native_models fallback (one session-model reviewer) lives in the loader's
     pairing (absent key is valid), both orchestrators' preset branches, both native model
     pages, and the design §6 paragraph. Change all or none. -->
**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — native на модели сессии`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_NATIVE_MODELS` can never contain it.** Nothing downstream recognises the sentinel — a list holding that string is NON-EMPTY, so the session-model fallback below does not fire and one reviewer is dispatched with `model: "ни одной — native на модели сессии"`. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 5.2.1 resolves a single ENGINE.

AskUserQuestion (multiSelect, max 4):
```
header: "Native"
question: "На каких native-моделях хоста запустить design review? (страница N/M, ★ = recommended)"
options:
  For each slug in the chunk:
    label:       "<slug>"                     if NOT in NATIVE_DEFAULT_IDS
                 "★ <slug> (recommended)"     if in NATIVE_DEFAULT_IDS
    description: "отдельный независимый ревьюер native:<slug>"
```

Collect the selections across pages into `SELECTED_NATIVE_MODELS`.

**Empty selection is not an error.** It falls back to exactly one native reviewer on the session model — `SELECTED_NATIVE_MODELS` stays empty as the signal for "omit `model:`". Do not re-ask and do not STOP.

Each selected slug becomes an independent reviewer named `native:<slug>`. Double-counting `native:grok-4.6` vs `grok:grok-4.6` is accepted.

#### Step 5.2.5: Claude-model selection

Runs ONLY when `claude` is in the selected TYPES **and** `HAS_CLAUDE_MODELS=1`. On HOST=claude-code, `claude` enters TYPES from Q1 option 1. On HOST=grok, `claude` enters from Step 5.2.1 (Claude Code CLI) — Q1 option 1 is native, never `claude`. Source is still `claude.models`.

- `claude` NOT in the selected TYPES → skip; no claude reviewer runs at all, whatever the catalog holds. **Bind `SELECTED_CLAUDE_MODELS` to the empty list.**
- `claude` selected but `HAS_CLAUDE_MODELS=0` → skip; exactly **one** reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty; on Grok: `claude -p` without `-m`). **Bind `SELECTED_CLAUDE_MODELS` to the empty list.**

Both bindings are mandatory, for the same reason Step 5.1 binds it in `default` mode: this step holds the ONLY other assignment to `SELECTED_CLAUDE_MODELS`, and Step 5.4 and the Step 6 dispatch consume it unconditionally. An undefined name in a shell script raises an error under `set -u`; in a prompt it raises nothing at all — the reader improvises.

For each chunk of 4 entries from `CLAUDE_MODELS` (config order) — same pagination and the same ★ convention as Step 5.3, because AskUserQuestion has no `preSelected` API:

**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — claude на модели по умолчанию`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_CLAUDE_MODELS` can never contain it.** Nothing downstream recognises the sentinel — a list holding that string is NON-EMPTY, so the fallback below does not fire and one reviewer is dispatched with `model: "ни одной — claude на модели по умолчанию"`. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 5.2.1 resolves a single ENGINE. Skipping the page there loses nothing — an engine still has to pass its own model page — while skipping this one would decide which model the single claude reviewer runs on — this catalog's only entry, or `DISPATCH_MODEL` through the fallback below on the user's behalf, silently, in the one configuration where the question matters most.

AskUserQuestion (multiSelect, max 4):
```
header: "Claude"
question: "На каких Claude-моделях запустить design review? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in CLAUDE_DEFAULT_IDS
                 "★ <model> (recommended)"     if in CLAUDE_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections into `SELECTED_CLAUDE_MODELS`.

<!-- SYNC: the fallback rule below is ONE rule living in four places — Step 5.1's "list absent/empty" bullet in this file, and `commands/mesh-review.md` Step 0 / Step 2.4. Change all four or none. -->
**Empty selection is not an error** — it falls back to exactly one reviewer named `claude`, as in the `HAS_CLAUDE_MODELS=0` case. Do not re-ask, do not STOP.

Every selected model gets the SAME composed prompt — model diversity is the point, so never differentiate their prompts.

#### Step 5.2.6: Grok-model selection

Runs ONLY when Step 5.2.1 selected `grok`. There is no `HAS_GROK_MODELS` gate: a `grok:` section without a non-empty catalog does not validate, so `HAS_GROK=1` already guarantees `GROK_MODELS` is non-empty — that is the promise `has_grok` makes and the reason no separate flag exists (the loader's `has_grok)` arm, which validates the catalog before answering).

- `grok` NOT selected in Step 5.2.1 → skip this step; **bind `SELECTED_GROK_MODELS` to the empty list** and run no grok reviewer at all.

The recommended set is `GROK_DEFAULT_IDS`, already parsed out of `DEFAULTS_JSON` in Step 5.0 — no second loader read here, and no loader-resolution fence: this skill resolves the loader from `SKILL_BASE`, not from a placeholder the harness substitutes into a command file, so a fence copied from `/mesh-review` would resolve nothing (see "Locating plugin files" at the top, and point (1) of the "Never mirror these four" note in Step 6).

For each chunk of 4 entries from `GROK_MODELS` (config order) — the same pagination and the same ★ convention as Steps 5.2.5 and 5.3, because AskUserQuestion has no `preSelected` API. Unlike Step 5.2.1, whose option list is at most three, this catalog is the user's and can exceed 4:

**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — grok не запускать`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_GROK_MODELS` can never contain it.** Nothing downstream recognises the sentinel — `grok-code-review` checks MODEL against the catalog with `grep -Fxq` and STOPs, so the reviewer the user asked NOT to run is the one that reports an error. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 5.2.1 resolves a single ENGINE. Skipping the page there loses nothing — an engine still has to pass its own model page — while skipping this one would decide whether a grok reviewer runs at all — the one thing this page exists to ask on the user's behalf, silently, in the one configuration where the question matters most.

AskUserQuestion (multiSelect, max 4):
```
header: "Grok"
question: "На каких grok-моделях запустить design review? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in GROK_DEFAULT_IDS
                 "★ <model> (recommended)"     if in GROK_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections across pages into `SELECTED_GROK_MODELS`. Every entry is a bare catalog id (`grok-4.6`) — never a `<provider>/<short>` pair like ext-claude's. A slash in that value never reaches a verdict at all: the Step 6 guard rejects it with a usage error and exit 1, the shape that means "fix the call" — never `FLIP`, which would mean "re-dispatch this reviewer". It once did report `FLIP`, by resolving `runs/grok/<provider>/<short>`, a path nothing ever writes; the charset check in `verify-delegation.sh`'s `grok)` arm replaced that.

<!-- SYNC: the "no fallback" rule below is ONE rule living in five places — this paragraph, this
     file's Step 5.1 grok preset bullet, and their two twins in the sibling orchestrator
     (`commands/mesh-review.md` Step 0's grok preset bullet and Step 2.45's same paragraph), plus
     the design's §1 note that grok_models is required whenever grok is in builtin. The count is
     of PHYSICAL sites, like the claude fallback rule's own four-place markers — each
     orchestrator states the rule twice, in its preset branch and on its model page, and the
     design doc states it once. Change all five or none: a copy that still promises a fallback
     would have the orchestrator dispatch a reviewer the agent then refuses to start for want of
     a MODEL. -->
**An empty selection runs no grok reviewer — and unlike claude, there is no fallback.** The grok executor agent stops without a `MODEL`, so there is nothing to dispatch. Say so on the Step 5.4 confirmation page ("grok: модели не выбраны — ревьюер не запускается") and continue; do not re-ask and do not STOP.

Every selected model gets the SAME composed prompt — model diversity is the point, so never differentiate their prompts.

#### Step 5.3 (Q2..Qn): Paginated model selection

Only if "external models" was selected in Q1. AskUserQuestion `options` has no `preSelected`/`checked` flag — pre-recommended ids are marked visually in the `label` instead.

Build `DEFAULT_IDS` from `defaults.design_review.models`. For each chunk of 4 models from `MODELS` (`<id>|<label>` lines, in config order):

**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — внешние модели не запускать`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_IDS` can never contain it.** Nothing downstream recognises the sentinel — the id reaches `ext-claude-code-review` as a model name and the run dies on the catalog lookup. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 5.2.1 resolves a single ENGINE. Skipping the page there loses nothing — an engine still has to pass its own model page — while skipping this one would decide that the user wants this model, when the alternative is this step's own empty-selection outcome on the user's behalf, silently, in the one configuration where the question matters most.

- AskUserQuestion (multiSelect: true, max 4, header: "Models"):
  ```
  question: "Какие модели использовать? (страница N/M)"
  options:
    For each model in the chunk:
      label:       "<label>"                       if id NOT in DEFAULT_IDS
                   "★ <label> (recommended)"        if id IS in DEFAULT_IDS
      description: "<id>"
  ```

Collect all selected model ids across pages into `SELECTED_IDS`.

#### Step 5.4: Confirm selection

After Q1 (and Steps 5.2.1 / 5.2.3 / 5.2.5 / 5.2.6 / 5.3, each if it ran), show the full selected set — built-in TYPES plus `SELECTED_IDS` (one per line) — and confirm (mirrors mesh-review Step 3.5). **Expand `claude` into one bullet per entry of `SELECTED_CLAUDE_MODELS`** (`claude:opus`, `claude:fable`), or a single `claude (модель по умолчанию)` bullet in the fallback case, so the user sees how many Claude reviewers they are about to pay for.

**When `native` is in the selected TYPES (HOST=grok only), expand it into one `native:<slug>` bullet per entry of `SELECTED_NATIVE_MODELS`.** Show `native (модель сессии)` only if `native` is still selected, the list is empty because of the sentinel / absent key, **and** `HOST_MODELS` is non-empty — that is the **session-model fallback only when HOST_MODELS is non-empty**. If `HOST_MODELS` was empty or a non-empty preset intersected to nothing, `native` was already removed from selected types and this page says nothing about native. **On HOST=claude-code do not show native bullets** — `native`+`claude` collapsed to one host set in Step 5.1 / Q1, so a second row would double-count. **When `native` is NOT in the selected TYPES**, the page says nothing about native at all.

**When `grok` is in the selected TYPES, expand it the same way**, one bullet per entry of `SELECTED_GROK_MODELS` (`grok:grok-4.6`, `grok:grok-4.5`) — same reason: one external run, and one bill, per bullet. When `grok` is selected and that list is empty, show `grok: модели не выбраны — ревьюер не запускается` instead of a bullet, so a user who selected grok in Step 5.2.1 and then checked nothing in Step 5.2.6 sees why nothing will run. When `grok` is NOT in the selected TYPES — Step 5.2.1 did not pick it, or `HAS_GROK=0` and it was never on offer — the page says nothing about grok at all: no bullet and no such line, exactly as it says nothing about an unconfigured codex. That line is a report on a selection the user made, not a standing notice. There is no fallback bullet here: unlike `claude`, an empty grok list dispatches nothing at all (Step 5.2.6). A pair that shows no bullet contributes nothing further either — not to the Step 6 dispatch, not to its watcher roster, not to its guard. A roster entry with no dispatch behind it comes back `MISSING`, which is indistinguishable from a dead executor.

```
header: "Confirm"
question: "Запустить ревью с этим набором? <bullet list: selected built-ins + SELECTED_IDS>"
options:
  - "Запустить (Recommended)"  — proceeds to Step 6
  - "Перевыбрать"              — restarts Step 5.2 from Q1 with the same DEFAULT_IDS / CLAUDE_DEFAULT_IDS / NATIVE_DEFAULT_IDS / GROK_DEFAULT_IDS (Steps 5.2.1, 5.2.3, 5.2.5 and 5.2.6 re-run too)
  - "Отмена"                   — exit the skill without dispatching
```

On "Перевыбрать": clear the selection — `SELECTED_CLAUDE_MODELS`, `SELECTED_NATIVE_MODELS` and `SELECTED_GROK_MODELS` included, or the re-select leaves the previous round's models standing behind a new set of TYPES — and restart from Step 5.2. Loop guard: cap re-selects at 3; on the 4th, message "Слишком много перевыборов; запустите /claude-mesh:mesh-design-review заново" and exit. If the user deselected everything — no built-in left that can actually produce a reviewer (`native` with an empty `SELECTED_NATIVE_MODELS` still counts only while `native` remains selected — session-model fallback only when HOST_MODELS is non-empty; after degrade, native was removed from selected types and counts as nothing; `grok` with an empty `SELECTED_GROK_MODELS` counts as nothing, per Step 5.2.6) and no models — STOP with "ничего не выбрано для ревью".

<!-- SYNC: this list is the twin of the prose enumeration at the head of Step 5 ("remember
     the resulting agent set"). Change both or neither. -->
Remember the confirmed set (built-in TYPES + `SELECTED_NATIVE_MODELS` + `SELECTED_CLAUDE_MODELS` + `SELECTED_GROK_MODELS` + `SELECTED_IDS`) for all subsequent iterations in the loop. Miss `SELECTED_NATIVE_MODELS` or `SELECTED_GROK_MODELS` in that list and those reviewers run on iteration 1 and silently vanish on iteration 2 — the "silently ignored list" failure the `validate_defaults` comment names as the very reason `claude_models` is fail-closed.

### Step 6: Execute Review via Selected Agents

**LOOP START:**

Before dispatch — via a Bash call, stamp `DISPATCH_EPOCH=$(date +%s)` and keep the number (the result-collection watch below needs it).

Launch **all selected** agents **in parallel** in a single message:

**HOST=claude-code:** for each selected agent, use Task tool (plugin `subagent_type`s are `claude-mesh:`-namespaced — verified on CC 2.1.156; bare names do not resolve). **Exception: `general-purpose` is a BUILT-IN agent type and is correctly bare** — never prefix it with `claude-mesh:`. The rule above is about *plugin* agents.

**HOST=grok:** `spawn_subagent`, each `background: true`. Do not set `isolation: worktree`. Plugin types stay `claude-mesh:`-namespaced. Native uses the builtin `explore` type (bare). Do **not** pass `runtime.dispatch_model` to `spawn_subagent` unless that value is in `HOST_MODELS`. Never pass `opus` as spawn `model:`.

**Dispatch model (HOST=claude-code):** if `DISPATCH_MODEL` (from Step 5.0) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch in this step. If it is empty, omit `model:` so each executor inherits this session's model.

**Exception — claude reviewers with an explicit model (HOST=claude-code).** When Step 5.2.5 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL` — otherwise every claude reviewer would collapse onto one model and the independence would be fake. `DISPATCH_MODEL` still governs the codex / gemini / grok / ext-claude executors and the `review-discussion` agent in Step 8. **A grok executor's `MODEL=` is not an exception to that** — the two name different things and both apply at once: `DISPATCH_MODEL` sets the Claude model the `grok-executor` agent itself runs on, while `MODEL=<entry>` names the xAI model its CLI reviews with. Exactly as for ext-claude, neither overrides the other.

**Dispatch model (HOST=grok):** do **not** pass `DISPATCH_MODEL` to `spawn_subagent` unless it is in `HOST_MODELS` (`grep -Fxq`). Never pass `opus` as spawn `model:`. Native slugs use their own `model: "<slug>"` (omit `model:` when the list is empty). Wrapper spawn `model:` is only a live host slug, never the CLI's `MODEL=` line. `max_redispatch` is wrappers only — a native spawn the host rejects is a failed reviewer: record it, do not substitute another slug.

**HOST=claude-code — built-in `claude` reviewer(s)** — dispatch the composed Step 4 prompt **directly**. That prompt is already self-contained (task, documents, project + session context, PREVIOUS DECISIONS, review focus, output format), so there is no `Execute this prompt via…` wrapper and no skill to invoke. **One Task per entry of `SELECTED_CLAUDE_MODELS`**, each carrying `model: "<entry>"`; in the fallback case (that list empty) exactly one Task per the Dispatch-model rule above. The template below is ONE such Task — all of them get the same prompt, only the model differs. Native is not a separate spawn (`≡ claude`).

```
Task tool:
  subagent_type: "general-purpose"     # built-in agent type — NOT claude-mesh:-namespaced
  model: "<claude model>"              # omit ONLY in the fallback case with an empty DISPATCH_MODEL
  description: "Design review via claude:<model> (iter N)"
                                       # fallback case: plain "Design review via claude (iter N)" —
                                       # per design §9 the single fallback reviewer is named just
                                       # `claude`, with no model suffix anywhere.
  prompt: "[composed prompt with PREVIOUS_DECISIONS]"
```

**HOST=claude-code: Claude reviewers are excluded from the disk-watch / ping loop below.** They create no `runs/<engine>/…` dir and finish on their own. Waiting for a run dir that will never appear — or pinging an agent that has already answered — is a bug, not diligence.

**If a HOST=claude-code claude reviewer's Task errors** — most likely a `claude_models` entry this Claude Code build does not accept — treat it exactly like a failed executor per Error Handling ("One agent fails, others succeed"): note the failure in the merged file, omit its section, continue with the rest. Never silently re-dispatch it on a different model: a failed dispatch is the only signal that a model name is wrong (design §13), and substituting another model hides it while pretending the cross-check happened.

**HOST=grok — native:** the composed Step 4 prompt + tooling constraint. `subagent_type: "explore"`, `background: true`, `model: "<slug>"`, `description: "Design review via native:<slug> (iter N)"`. **One `explore` per entry of `SELECTED_NATIVE_MODELS`**. If the list is empty and native was selected (session-model fallback): one `explore`, **omit** `model:`. Native writes no `runs/native/…` and is not on the watcher roster. The result is the child's text — `verify-delegation.sh is never invoked for native`. Do not inline the documents (the prompt already names them). A native spawn the host rejects is a failed reviewer: record it, do not substitute another slug.

```
spawn_subagent:
  subagent_type: "explore"
  background: true
  model: "<slug>"                      # omit when the list is empty
  description: "Design review via native:<slug> (iter N)"
  prompt: "[composed prompt with PREVIOUS_DECISIONS, plus the tooling constraint]"
```

**HOST=grok — `claude`:** `claude-mesh:claude-executor` (never `general-purpose`, never `claude-code-reviewer`). `MODEL=<alias>` on the first line, `HOST_CLAUDE=1` forwarded through the executor (the agent always sends that named param; it is not a spawn field), `SUPERVISED_MODE: shell`. Name them `claude:<alias>` (`claude:opus`). Roster `claude/<alias>` (`claude/opus`). If `claude` selected and the list is empty: one executor, **no MODEL line** (CLI default); roster `claude/_default`. Do not pass spawn `model: opus`.

```
spawn_subagent:
  subagent_type: claude-mesh:claude-executor
  background: true
  description: "Design review via claude:<alias> (iter N)"
  prompt: "MODEL=<alias>
    Execute this prompt via ext-claude-exec:
    HOST_CLAUDE=1
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell"
```

`HOST_CLAUDE=1` is a named parameter the executor forwards; putting it in the prompt as well is how the caller makes that forwarding unmissable. Empty-catalog fallback: drop the `MODEL=` line, keep `HOST_CLAUDE=1` and `SUPERVISED_MODE: shell`.

**codex / gemini executors** parse `PROMPT` / `MODEL` / `REASONING_LEVEL` / `SUPERVISED_MODE` as named params (any line), so use the wrapped form. HOST=claude-code: Task. HOST=grok: `spawn_subagent` `background: true`, same prompt; do not pass `DISPATCH_MODEL` unless it is in `HOST_MODELS`; never pass `opus` as spawn `model:`:
```
Task tool:                         # HOST=claude-code
spawn_subagent, background: true:  # HOST=grok
  subagent_type: [claude-mesh:<executor>]
  description: "Design review via [agent-name] (iter N)"
  prompt: "Execute this prompt via [tool]:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell
    [agent-specific params]"
```

**`claude-mesh:ext-claude-executor`** REQUIRES `MODEL=<id>` on the **FIRST non-blank line** of the prompt (it parses `^MODEL=(\S+)` and STOPs otherwise). Do NOT wrap it behind an `Execute this prompt via…` line — put MODEL first, then the wrapper. HOST=claude-code: Task. HOST=grok: `spawn_subagent` `background: true`; do not pass `DISPATCH_MODEL` unless it is in `HOST_MODELS`; never pass `opus` as spawn `model:`:
```
Task tool:                         # HOST=claude-code
spawn_subagent, background: true:  # HOST=grok
  subagent_type: claude-mesh:ext-claude-executor
  description: "Design review via <id> (iter N)"
  prompt: "MODEL=<id>
    Execute this prompt via ext-claude-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell"
```

**`claude-mesh:grok-executor`** takes `MODEL=<model>` on the **FIRST non-blank line** for the same reason: `agents/grok-executor.md:27` requires it there and the agent STOPs without it, so an `Execute this prompt via…` line above it would break the parse. Nothing checks that mechanically — the contract is prose the agent reads, which is exactly why the caller has to get it right. **One spawn per entry of `SELECTED_GROK_MODELS`**, and none at all when that list is empty. HOST=claude-code: Task. HOST=grok: `spawn_subagent` `background: true`; do not pass `DISPATCH_MODEL` unless it is in `HOST_MODELS`; never pass `opus` as spawn `model:`:
```
Task tool:                         # HOST=claude-code
spawn_subagent, background: true:  # HOST=grok
  subagent_type: claude-mesh:grok-executor
  description: "Design review via grok:<model> (iter N)"
  prompt: "MODEL=<model>
    Execute this prompt via grok-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS, plus the tooling constraint below]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell"
```

`<model>` is the bare catalog id (`grok-4.6`), never a `<provider>/<short>` pair like ext-claude's. Three spellings are in play here and none of them is interchangeable: the reviewer name and this `description` use `grok:<model>` (a COLON), the watcher roster below uses `grok/<model>` (a SLASH), and the run dir on disk is `runs/grok/<model>/`.

**Grok-CLI executor dispatches and HOST=grok native dispatches carry the tooling constraint in their PROMPT.** In `/mesh-review` the `grok-code-review` skill appends that paragraph itself; design review bypasses that skill entirely and hands the executor (or native `explore`) its own Step 4 prompt, so nothing adds the line unless you do. Grok reads `~/.claude/CLAUDE.md` and every installed claude-* plugin — `claude-mesh:mesh-design-review` is among the skills it can see — so without the paragraph it can answer a review request by launching an orchestration of its own, writing run dirs this session never dispatched. Append it verbatim as the LAST section of the composed prompt, for grok-executor **and** native:

```markdown
## Tooling constraint

Do NOT invoke any skill or slash command, and do NOT delegate this review to another agent or
orchestration. Names like `claude-mesh:mesh-design-review` may be visible in your environment;
they are not part of this task. Read the documents and the code with your own file, search and
shell tools, and answer with the review itself.
```

codex, gemini and ext-claude get no such paragraph: they cannot see those skills at all.

Agent-specific parameters:
- **`claude-mesh:codex-executor`** (built-in selected: `codex`): pass `MODEL={CODEX_MODEL}` / `REASONING_LEVEL={CODEX_REASONING_LEVEL}` ONLY when the user explicitly set them; otherwise omit both lines entirely — codex-exec resolves model/level from `config.yaml` (`codex.model` / `codex.reasoning_level`, fallbacks `gpt-5.5`/`xhigh`)
- **`claude-mesh:gemini-executor`** (built-in selected: `gemini`): default settings
- **`claude-mesh:grok-executor`** (built-in selected: `grok`; one per entry of `SELECTED_GROK_MODELS`): `MODEL=<model>` on line 1 (e.g. `MODEL=grok-4.6`) — the id comes from the config (`SELECTED_GROK_MODELS`, or `defaults.design_review.grok_models` in `default` mode), never invented here. Pass `REASONING_EFFORT={GROK_REASONING_EFFORT}` ONLY when the user explicitly set it; otherwise omit the line entirely — grok-exec resolves the effort for the model it runs from `config.yaml` (`grok.model_efforts[<model>]`, then the section-wide `grok.reasoning_effort`), and when both are unset the CLI's own default applies.
- **`claude-mesh:ext-claude-executor`** (one per selected model id): `MODEL=<id>` on line 1 (e.g. `MODEL=zai/glm`, `MODEL=alibaba/qwen`, `MODEL=ollama/kimi`) — the model id comes from the config (`SELECTED_IDS`, or `defaults.design_review.models` in `default` mode), NOT a hardcoded provider profile.
- **`claude-mesh:claude-executor`** (HOST=grok, built-in selected: `claude`; one per entry of `SELECTED_CLAUDE_MODELS`): `MODEL=<alias>` on line 1 (e.g. `MODEL=opus`) — empty list: omit the MODEL line. Always `HOST_CLAUDE=1` forwarded through the executor, always `SUPERVISED_MODE: shell`. Do not pass spawn `model: opus`.

**Every executor template carries `SUPERVISED_MODE: shell` — never drop it.** Without it the `*-exec` skills default to `none`, which means no `shared/watchdog.sh`: no stall detection, no restart when a provider tears the stream mid-response, and no `watchdog.log` — the file whose `cleanup` event tells the watch loop below that a run has stopped, and whose `alive` heartbeat tells it the run is still alive. Design review never set this until 2026-07-27, so supervision was a coin flip: 42 of 223 archived runs got a watchdog, against 242 of 255 on the `/mesh-review` path where it is hardcoded. On 2026-07-26 none of six did, four executors died mid-stream, and nothing noticed for 38 minutes. On 2026-07-27 four of five died again and only recovered because the executor agents improvised their own retries.

Collect output paths from every **executor** (codex / gemini / grok / ext-claude, and on HOST=grok also `claude`) — but do NOT passively wait for completions: the watch loop below is what turns finished runs into reports. HOST=claude-code claude reviewers have no output path to collect: they create no `runs/<engine>/…` dir and return their review as the Task result. HOST=grok native has no output path either: no `runs/native/…`; `verify-delegation.sh is never invoked for native`; the result is the child's text (INLINE).

**Wait — HOST=grok.** No sleep poller. Completions arrive as harness notifications on the `spawn_subagent` ids; fetch each with `get_command_or_subagent_output`. A wait-all on several ids is allowed; each call's `timeout_ms` ≤ 600000. Loop until every child has finished or `runtime.timeouts.global_sec` elapses. Native is not on the watcher roster (`verify-delegation.sh is never invoked for native`). Wrappers still go through `watch-runs.sh` + `verify-delegation.sh`. Silent wrapper + `REAL` → read `output.txt` yourself — that is the **primary** collection path on Grok, not after two pings. No SendMessage.

**Wait — HOST=claude-code.** **CRITICAL — an executor's report does NOT arrive on its own: disk-watch the runs and ping idle executors.** Each executor launches its external engine (watchdog + CLI) as a background Bash task, sends an interim status naming its run dir (`runs/<engine>/…` under the plugin data dir), ends its turn and goes idle. The harness delivers NO task-notification to an idle subagent when that background task exits, so the report stalls until pinged (same mechanics verified 2026-07-10 on the mesh-review wrappers: 0 notifications in 5/5 transcripts, reports stalled 8–12 min over a finished `output.txt`). After dispatch (both hosts run the disk watch for wrappers; HOST=grok does not SendMessage):

1. Capture each executor's run dir from its interim status. Fallback when a status names none: the newest dir under `$PLUGIN_DATA/runs/<engine>/[<provider>/<model>/]` (`PLUGIN_DATA` = `"$LOADER" data-dir`) created after `DISPATCH_EPOCH`.
2. Watch the disk with `shared/watch-runs.sh`, launched as a **background** Bash task — a foreground poll loop would block the session, and a background watcher that returns on each event re-invokes you per event. **Do NOT hand-roll a poller.** The one improvised here exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

   ```bash
   SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
   PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
   WATCH="$SKILL_BASE/../shared/watch-runs.sh"
   [ -x "$WATCH" ] || { echo "watch-runs.sh missing or not executable at $WATCH" >&2; exit 1; }
   "$WATCH" --since <DISPATCH_EPOCH> claude/opus grok/grok-4.6 ext-claude/zai/glm
   ```

   Substitute the **actual** `DISPATCH_EPOCH` number you stamped above. A shell variable does not survive from one Bash call to the next, and an unset name in a prompt raises nothing at all — the script rejects an implausible `--since` rather than silently watching a window that ended in 1970.

   The arguments after the options are a **roster** of `engine[/provider/model]` — the subpath under `runs/` — not run directories. The depth follows the engine: `codex` and `gemini` have none, `grok` and HOST=grok `claude` take one segment (`grok/grok-4.6`, `claude/opus`, matching `runs/grok/<model>/` and `runs/claude/<alias>/`) and `ext-claude` takes two. Note the SLASH: the roster spells a grok reviewer `grok/grok-4.6` where its name and its `description` spell it `grok:grok-4.6`; the two are never interchangeable. Same split for `claude/opus` vs `claude:opus`. Native is never a roster entry. An executor that dies and self-retries creates a new run dir, so the watcher re-resolves the newest one at/after `--since` on every tick and follows the retry by itself. Pass only the executors you are still waiting for (point 5). HOST=claude-code: do not put `claude/opus` on the roster — those reviewers are INLINE. HOST=grok: do put `claude/opus` (or `claude/_default`) on the roster when a claude executor was dispatched.

   | Status | Meaning |
   |---|---|
   | `DONE` | finished, and there is a non-empty `output.txt` to read |
   | `FAILED` | finished without usable output — the watchdog exited non-zero, or nothing appeared in the minute after the run stopped writing |
   | `RUN` | still producing, or still starting up |
   | `SILENT` | nothing written to any stream for longer than the stall threshold |
   | `MISSING` | no run dir for this executor at all |

   The reason line names what moved — `CHANGED ext-claude/ollama/kimi RUN→SILENT`. Terminal verdicts are `ALL_DONE`, `SETTLED` (nothing left running) and `DEADLINE` (the watch budget expired); those three end the loop. A healthy `--once` prints `SNAPSHOT`. **Every verdict exits 0.** A non-zero exit means the watcher itself is broken, never that an executor died.

   A `MISSING` row that ends `N run(s) in this window belong to another session` is the one status here that is **not** about the executor. Run dirs carry the id of the session that dispatched them, and this session's id no longer matches — a resumed or forked session, not a death. Do not route it to Error Handling as a failed executor; say so and, if the runs are in fact this orchestration's, finish the watch by reading them directly. `verify-delegation.sh` reports the same cause as a `FLIP` whose reason names the session mismatch — that one is not a flip either.
3. When a run reaches `DONE`, check that it actually produced a review **before** pinging its executor. `DONE` means the run stopped and left a non-empty `output.txt`; it does not mean the file holds findings.

   ```bash
   SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
   PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
   VERIFY="$SKILL_BASE/../shared/verify-delegation.sh"
   DATA_DIR="$("$SKILL_BASE/../shared/config-loader.sh" data-dir)"
   bash "$VERIFY" ext-claude zai/glm <DISPATCH_EPOCH> "$DATA_DIR"
   bash "$VERIFY" grok grok-4.6 <DISPATCH_EPOCH> "$DATA_DIR"
   bash "$VERIFY" claude opus <DISPATCH_EPOCH> "$DATA_DIR"   # HOST=grok only; never for native
   ```

   The arguments are the engine, the model (`-` for codex and gemini; the bare catalog id for grok, e.g. `grok-4.6`; the alias for HOST=grok `claude`, e.g. `opus`; `<provider>/<short>` for ext-claude), the **same** `DISPATCH_EPOCH` you pass to the watcher — substitute the actual number — and the data dir, so the gate reads the tree the watcher read instead of resolving one for itself. `verify-delegation.sh is never invoked for native`. It prints the verdict on stdout and the reason on stderr, and exits non-zero for every verdict but `REAL`: `STALLED`=2, `FLIP`=3, `BROKEN`=4, `DEGRADED`=5, `KILLED`=6. **For those five codes the non-zero exit is the answer, not a breakage** — unlike the watcher, do not re-run the gate and do not skip it over a 2, 3, 4, 5 or 6. Any *other* non-zero code is the script failing rather than answering: `1` is a usage error (missing or unknown engine, a `since-epoch` that is not a number — the shape an unsubstituted `DISPATCH_EPOCH` takes — bash < 4.2, or a non-GNU `find`), `126`/`127` mean the path is wrong. Those print no verdict on stdout at all, so treat them as your own mistake — fix the invocation and re-run that one.

   **A grok model argument is the bare catalog id and nothing else.** The script rejects an empty model, `-`, and any spelling outside `[A-Za-z0-9][A-Za-z0-9._-]*` — a slashed `grok zai/glm` included — with a usage error and exit 1, printing NO verdict. Read that as "fix the argument", never as a statement about the reviewer: `FLIP` would prescribe a re-dispatch, and re-dispatching cannot repair a call the script refuses to answer. Mind the split too: the watcher takes `grok/grok-4.6` as ONE token, this script takes `grok grok-4.6` as TWO, and copying the roster entry across as-is is a usage error rather than a verdict.

   - `REAL` — **HOST=claude-code:** SendMessage that executor: `your external run finished — read its output.txt, extract the findings and send your report`. Ping once per `DONE` run **that has not already sent its report**: an executor sometimes delivers on its own the moment its run lands, and a ping that crosses the report in flight costs it a turn and you a duplicate. Re-ping only if it is still silent after the next poll interval (~60–90 s). **If a second ping also goes unanswered, read `<run dir>/output.txt` yourself** (or `final/output.txt` when the root file is empty). **HOST=grok:** there is no SendMessage. Silent wrapper + `REAL` → read `<run dir>/output.txt` yourself (or `final/output.txt` when the root file is empty). That is the **primary** collection path on Grok, not the after-two-pings fallback. Merge those findings under that executor's section as though it had answered — but never `report.md`, which is the whole run rendered out and runs to hundreds of kilobytes. A report is how findings travel, and travel is what breaks: an idle subagent gets no notification when its background task ends, and even a composed report can fail to arrive — on 2026-08-05 an 11428-byte review sat finished on disk while its model was written off as having produced nothing. A `REAL` verdict is a statement about that file, read from the disk, so an executor whose run is `REAL` is never "silent" in the sense that matters.
   - `DEGRADED` — the run delivered a real review, but the CLI refused N of its tool calls: it was confined to the directory it was launched in and never reached the sibling repositories it tried to open. **Ping it exactly like a `REAL`** — the findings exist and are worth having — then record in the merged file that this reviewer worked on incomplete context, and weigh its findings accordingly: an "issue" it raises about code it could not read is a guess. Do **not** re-dispatch it: a retry runs under the same invocation and is denied the same way. The remedy belongs to the user, not to you — the ext-claude run needs `--permission-mode bypassPermissions`, and an *installed* plugin only picks that up through a release, so on a copy predating that release this verdict is the expected outcome rather than an anomaly. The reason line names the denial count and which tools were refused (`Read×2, Bash×1`), which tells you whether the reviewer lost source files, searches, or both. **On grok the remedy differs, and the reason line says so:** `grok-exec` already runs the CLI with `--permission-mode bypassPermissions`, so a denial there is not the missing-flag case at all — it points at the CLI's own permission configuration (`~/.grok`, or a sandbox profile), not at a plugin release. The verdict's handling is unchanged: keep the findings, record the incomplete context, do not re-dispatch.
   - `KILLED` — a review lost to a signal from outside the run (watchdog `cleanup` 143/130 with no `watchdog.exit`), so nothing inside it chose to stop and it was alive when it died. Treat it as a failed executor per point 4 and do **not** ping — nothing usable survived, so there is nothing to extract. That is a property of the verdict, not a guess about the directory: the gate weighs the content first and returns `REAL` for a run that had already delivered a review before something killed its tail, so anything still scoring `KILLED` left behind an empty, torn or narration-only `output.txt`. Record it for what it was: killed from outside after N seconds, not "produced nothing". The usual sender is the harness capping a *foreground* Bash call at `BASH_MAX_TIMEOUT_MS` (ten minutes by default) and SIGTERMing it there, which is why the exec skills launch the engine as a background task; a cluster of deaths at the same round number is that signature, and the fix is in the executor's launch, not in another attempt.
   - `STALLED` / `BROKEN` / `FLIP` — the run produced no usable review: it died mid-flight, or it finished and delivered a **notice instead of a review** (`output.txt` under 400 non-space bytes — "запущено, уведомлю по завершении", an approval request, a summary of findings that are not in the file). Treat it as a failed executor per point 4 and do **not** ping: asking an agent to extract findings from a file that has none is how a draft becomes a review. On 2026-07-27 a torn run left a 47429-byte `output.txt` containing only the model's narration; `verify-delegation.sh` classified it `STALLED` ("no usable result event in raw.jsonl"), and only the executor's own honesty had kept it out of the merge. `FLIP` is the one verdict here that earns a check first. The script emits it in three places: when the engine/model directory does not exist at all; when it exists but holds no run NAMED at/after the `--since` you passed; and when the runs in that window carry another session's id, which the reason line says outright — that third one is a session that was resumed or forked mid-orchestration, not a reviewer that skipped its skill, so re-dispatching it would only make a second orphan. After a `DONE` none of the three can mean "never delegated" — the watcher just saw that directory. Both mean the two are looking in different places, or at different windows. Re-check the engine and model against the roster entry from point 2 — the watcher takes them as **one** token, `ext-claude/zai/glm`, while this script takes **two**, `ext-claude zai/glm`, and copying the roster entry across as-is is an unknown-engine usage error, not a verdict. Then re-check the epoch: Step 6 is a loop that stamps a fresh `DISPATCH_EPOCH` each iteration, so one carried over from another iteration yields `FLIP` with engine, model and data dir all correct. Only when all of those match is the executor dead; otherwise you would drop a finished report over a typo.
4. **A `SILENT`, `FAILED` or `MISSING` run is a dead executor** — treat it per Error Handling ("One agent fails, others succeed"): note the failure in the merged file, omit its section, continue with the rest. Do **not** re-dispatch it. `watchdog.sh` already restarts the CLI up to twice inside the run, and that is this file's only retry layer, which is exactly why a third one here would just spend another budget on the same failure. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact an executor died, and the two call for different actions. An executor that stays quiet over a `DONE` run is none of these three: point 3 says how to collect its review without it.
5. **Pass only the executors you are still waiting for.** The watcher assumes every roster entry is running, so an entry you have already handled comes straight back as news. If the watcher returns twice in a row with the same reason, you did not narrow the roster. Stop watching once the roster would be empty.
6. Repeat until every dispatched executor has reported, is dead, or the watch budget expires — never interpret silence as "no findings". This loop covers its wrapper executors only. HOST=claude-code: claude reviewers are not part of it. HOST=grok: native is not part of it (`verify-delegation.sh is never invoked for native`); Grok-host `claude` (`claude/opus`) is a wrapper and is part of it.

**Anything an executor says while the watch is running is a free liveness check.** Before replying to an interim status, a progress note or a question, run one `"$WATCH" --since <the same epoch> --once <current roster>` — re-resolve `$WATCH` with the same lines as in point 2 first; it does not survive between Bash calls — and act on the rows. On 2026-07-26 six such messages arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command. `--once` reports `CHANGED` when something has already died, so the answer names the death rather than handing you a table to compare by eye.

> Sync note: points 1–6 are mirrored in `commands/mesh-review.md` (Step 5a) — in substance, not byte for byte, and four things are not mirrored at all. Work out which kind you are touching before copying anything across.
>
> **Mirror the substance.** The status table, the roster explanation, the `--since` warning, the "every verdict exits 0" contract, point 5 and the `--once` liveness rule just above this note say the same thing in both files and must go on saying it: when you change what one of them says, change the other. Do not paste bytes — each copy is worded to its own file (`wrapper` in `/mesh-review`, `executor` in design review), names its own cross-references (where `DISPATCH_EPOCH` was stamped; the "Do NOT block" instruction only `/mesh-review` has) and describes its own retry model (a run re-dispatched by `/mesh-review` versus one that self-retries under design review).
>
> **Never mirror these four.** (1) Points 1–2 resolve paths differently by construction: `/mesh-review` reads `$DATA_DIR` and finds its loader through `${CLAUDE_PLUGIN_ROOT}` with a version-sorted `find` fallback, because the harness substitutes that placeholder into a command file's text; a skill gets no such substitution, so design review starts from the base path Claude Code prints at load (`SKILL_BASE`) and asks the loader for `data-dir`. Copying either block across breaks path resolution outright. (2) Point 3: design review runs the `verify-delegation.sh` content gate inline before pinging, while `/mesh-review` pings on `DONE` and only reaches the same check later, in its own mechanical classification step. (3) Point 4: a dead run goes to Error Handling in design review, whose only retry layer is `watchdog.sh` inside the run, and to Step 6.0 in `/mesh-review`, which classifies it mechanically and owns a second, wrapper-level retry layer; the retry sentence that closes the point differs with the routing. (4) Point 6's closing clause: `/mesh-review` hands whatever is still silent to that same step, while design review instead records that the loop covers its wrapper executors only. That clause names the class, not a list of engines, on purpose: a roster spelled out here has to be re-spelled in the sibling every time an engine is added, and the two copies drift the moment one of them is missed.
>
> Do not restore parity by copying the gate or the routing across, and do not delete either: each file checks a finished run's content exactly once and routes a dead run exactly once, and a copy of either in the other file would be the weaker of the two.

### Step 7: Merge Review Results

After all agents complete:

1. Read output from each agent
2. Create a merged review file at `docs/superpowers/specs/YYYY-MM-DD-<TOPIC>-review-merged-iter-N.md`:

```markdown
# Merged Design Review — Iteration N

## claude:opus

[full output from the built-in claude reviewer on opus — one section per selected Claude model;
 a single fallback reviewer is titled just `claude`]

---

## codex-executor

[full output from codex]

---

## gemini-executor

[full output from gemini]

---

## grok-executor (grok-4.6)

[full output from this grok model — one section per entry of `SELECTED_GROK_MODELS`]

---

## ext-claude-executor (zai/glm)

[full output from this model — one section per selected model id]
```

Only include sections for agents that were actually selected and completed successfully.

3. Use this merged file as REVIEW_OUTPUT for the next step

### Step 8: Parse Issues via Discussion Agent

Use Task tool to launch the `claude-mesh:review-discussion` agent (plugin agent — namespaced; ported in Task 17):

Apply the same **Dispatch model** rule as Step 6: add `model: "<DISPATCH_MODEL>"` when `DISPATCH_MODEL` is non-empty, otherwise omit `model:`.
```
Task tool:
  subagent_type: claude-mesh:review-discussion
  description: "Parse review issues (iter N)"
  prompt: "Parse and analyze design review issues:
    DESIGN_PATH: [design path]
    PLAN_PATH: [plan path or empty]
    ITER_FILES: [comma-separated paths to all previous iter files]
    REVIEW_OUTPUT: [path to merged review file from Step 7]
    ITERATION: N"
```

Wait for completion. Parse PARSED_ISSUES result to get list of issues with their status (NEW/REPEAT) and options.

### Step 9: Classify All Issues (No Fixes Yet)

**This step is performed by the orchestrator (you), not the agent.**

**CRITICAL: In this step you only classify. Do NOT apply fixes, do NOT ask the user anything yet.** All fixes happen in Step 10, all discussion happens in Step 12.

Initialize tracking buckets:
- `repeated = []` — REPEAT issues (previous answer applies)
- `auto_fixes = []` — NEW issues that are valid AND have one obvious fix
- `disputed = []` — NEW issues that are valid AND have real trade-offs / multiple reasonable approaches
- `dismissed = []` — NEW issues that are false positives / not applicable / already addressed
- `stop = false` — stop flag (used in Step 12)

For each issue from PARSED_ISSUES, classify into exactly one bucket:

**REPEAT** — review-discussion already flagged it as duplicate of a prior iteration:
- Bucket: `repeated`
- Carry over `prev_answer`, `prev_action`, `source_iter`
- **Except when `prev_answer` carries `под вопросом`** — an autodecided call the previous iteration
  flagged for re-checking. Bucket it as `disputed` instead and let Step 12 decide it on the merits,
  with the previous answer and what was missing as context. A reviewer raising it again is the
  strongest evidence available that the shaky call was wrong; auto-answering it would close that
  flag's safety net after exactly one iteration, silently.

**AUTO** — issue is valid AND only one reasonable approach exists. Test: "If I asked five competent engineers familiar with this codebase, would they all do the same thing?" If yes → AUTO. Typical AUTO cases:
- Missing error handling, missed edge case
- Inconsistent naming / terminology
- Forgotten section, missing field in schema
- Typo, broken reference, dead link
- Plan step missing for a documented design change
- Bucket: `auto_fixes` with `planned_action: "<concrete description of the fix>"`

**DISPUTED** — issue is valid BUT solution involves trade-offs, scope decisions, architectural alternatives, or conflicting requirements. Test: "Can I name at least two reasonable approaches where each has a real downside?" If yes → DISPUTED.
- Bucket: `disputed` (analysis happens in Step 12, NOT here)

**DISMISSED** — false positive: reviewer misunderstood context, issue doesn't apply, or already addressed in design/plan:
- Bucket: `dismissed` with `reason: "<why dismissed>"`

**After classification, display a summary table:**

```
Классификация замечаний (всего: N):
  Повторы (автоответ):       R
  Авто-исправления:          A
  Спорных (обсудим):         D
  Отклонено (ложные):        X
```

Briefly list issue IDs in each bucket so the user sees what's been classified where:
```
  AUTO:      [CRITICAL-1, CONCERN-2, SUGGESTION-1, ...]
  DISPUTED:  [CRITICAL-3, CONCERN-1, ...]
  DISMISSED: [SUGGESTION-2 — already covered in §X of design]
  REPEAT:    [QUESTION-1 — answered in iter-2 as Y]
```

### Step 10: Apply Auto-Fixes (Phase 1)

For each issue in `repeated` and `auto_fixes`, apply the planned edit to design AND/OR plan documents.

**CRITICAL: Check BOTH documents for each issue.**
- Architecture, API, data model → design document
- Implementation steps, task breakdown, order of work → plan document
- Most issues require changes to BOTH — design describes WHAT, plan describes HOW
- After applying, explicitly verify per issue: "Design updated: Yes/No. Plan updated: Yes/No."
- If plan document exists (PLAN_PATH is set) and you only changed design — STOP and check if plan needs a corresponding update

After each edit, display one-line progress:
```
[1/A] Автоисправлено [TYPE-X]: <краткое описание что исправлено>
[2/A] Автоисправлено [TYPE-Y]: <краткое описание>
...
```

Record `action: "<what was changed>"` for each. Preserve document formatting.

If `repeated` and `auto_fixes` are both empty, skip directly to Step 12 (no commit needed in Step 11).

### Step 11: Commit Auto-Fixes (Intermediate Commit)

**Right after Phase 1 changes are applied, commit them — BEFORE moving to disputed discussion.** This locks in the safe, uncontroversial edits and gives the user a clean checkpoint.

1. Stage modified files:
   - Design document (DESIGN_PATH) if modified
   - Plan document (PLAN_PATH) if modified
2. Commit with message: `docs: review iter N — auto-fixes (<TOPIC>)`
3. Do NOT push.

If no files were modified in Step 10, skip this commit.

### Step 12: Discuss Disputed Issues One at a Time (Phase 2)

If `disputed` is empty, proceed to Step 13.

**Autodecide mode.** If `AUTODECIDE` is true (Step 5) **or the user has already invoked**
`/claude-mesh:auto-decide-disputed` in this session — its state S3 arms the mode with no argument
passed — do NOT run the interactive loop below: invoke `/claude-mesh:auto-decide-disputed` through
the Skill tool now and follow it for the whole disputed queue, then come back for the "After the
loop" paragraph at the end of 12.c before Step 13.

It replaces **the whole of 12.b — both branches**: the single-adequate-variant branch as much as
the waiting one. Every remaining disputed issue goes through the command's Step 2, so every one of
them gets `Проверка решения`, a confidence flag, its own commit and status `new-autodecide`. In
this mode 12.b's first branch produces nothing **for the issues this command decides**, and none of
them is recorded `new-auto-after-analysis` — such an entry would be a document edit that no commit
covers, because Step 14 stages only the iteration and merged files. Issues that branch had already
applied BEFORE the hand-off — the mode can be entered mid-phase, state S1 — keep their
`new-auto-after-analysis` entries: settle-the-tree commits those edits, so record and git agree, and
dropping them would make Step 13 omit an issue the next iteration then re-raises as new. 12.a's
analysis format still applies unchanged, and the command points back to it. The intro line for this mode is printed by the command, not here. Do not paste
any part of its protocol here.

**If the command does not resolve** — an older plugin copy in this environment — say so in one line
and fall back to the interactive loop below. Never improvise the protocol from memory: Iron Rules
7–8 stand until the command that overrides them is actually loaded.

Display intro (interactive mode):
```
Спорных вопросов: D. Обсуждаем по одному — для каждого приведу суть, анализ, варианты и обоснованную рекомендацию.
```

**For EACH issue in `disputed`, sequentially (NOT batched, NOT in parallel):**

**12.a — Present structured analysis.** Do NOT use one-line bullets. Write enough so a reader who has not seen the review can follow:

```markdown
## [Спорное i/D] [TYPE-N] <Issue Title>

**Источник:** <agent(s) that raised it>

### Суть замечания
<2–4 sentences. What the reviewer actually said. Where in the doc/code (section, file:line). Why they flagged it. Quote a short fragment if it helps.>

### Анализ
<Why this might be a real problem (impact, risk, blockers). Why it might NOT be a problem (false positive, acceptable trade-off, already mitigated elsewhere). What constraints/decisions are relevant — pull from PROJECT CONTEXT, SESSION CONTEXT, and prior iterations.>

### Варианты решения

**Вариант A — <short name>**
- Что делаем: <concrete description, including which doc/section changes>
- Плюсы: <pros>
- Минусы: <cons>

**Вариант B — <short name>**
- Что делаем: <concrete description>
- Плюсы: <pros>
- Минусы: <cons>

[Вариант C if there's a third genuinely-different approach]

**Вариант "Оставить как есть"** (если применимо)
- Обоснование: <why this could be valid given current context>

### Рекомендация
**Вариант X** — <2–3 sentences why this beats the others given the project's constraints, prior decisions, and what the design is optimizing for>
```

**12.b — Decide whether to ask or auto-apply.** After writing the analysis, you'll often discover that only one option is actually adequate. Use this rule:

- **If only ONE option is genuinely adequate** (others have fatal flaws, contradict prior decisions, or are strictly inferior in this project's context): **do not ask the user.** Announce the decision and apply it:
  ```
  → Принимаю Вариант X. Остальные варианты отпадают: <one-line reason per dropped option>. Применяю правку.
  ```
  - Apply the Edit(s) to design/plan immediately
  - Add to `answers`: `{issue, status: "new-auto-after-analysis", answer: "Вариант X (auto)", action: "<fix>"}`
  - Continue to next disputed issue

- **If MULTIPLE options are genuinely reasonable — do NOT call AskUserQuestion or any other tool.** The structured analysis you just wrote already IS the question. Make it the **final message of the turn** and end the turn on it, closing with an explicit free-text prompt:
  ```
  Выберите вариант: ответьте его буквой/названием или предложите свой.
  Моя рекомендация — Вариант X.
  ```
  - The turn ENDS here. Emit **no tool call** after the analysis. A trailing AskUserQuestion (whose own question/options UI duplicates your write-up) makes the harness treat the analysis as skippable preamble, and the user sees only a bare modal; a turn-final text message is always shown in full.
  - **On the user's next message — check for stop FIRST.** If the response contains "стоп" / "stop" / "достаточно": set `stop = true`, record the current issue as deferred/undecided (apply nothing), mark all remaining disputed as deferred, and exit the loop. Otherwise apply the Edit(s) for the chosen variant, add to `answers`: `{issue, status: "new", answer: user_choice, action: "<fix>"}`, then move to the next disputed issue.
  - **If the turn is resumed by a background event** (e.g. a Step 6 watcher or task notification) rather than a user reply: handle the event, then end the turn again with a one-line reminder of the pending choice. A non-user event is never the user's answer.

<!-- SYNC: the `answers` shape below is ONE contract living in two places — this bullet and
     `commands/auto-decide-disputed.md` Step 4. Change both or neither. -->
- **In `autodecide` mode neither branch above applies** — not the waiting one and not the
  single-adequate-variant one. Every remaining disputed issue is decided by
  `/claude-mesh:auto-decide-disputed` and recorded in `answers` as
  `{issue, status: "new-autodecide", answer: "Вариант X (autodecide)", action: "<what changed>",
  confidence: "уверенно" | "под вопросом (<what was missing>)", commit: "<short SHA>" | "—"}` —
  Step 13 renders it and Step 15 counts it. `commit` is `«—»` exactly when the decision was the
  no-change variant («Оставить как есть», spelled «не исправлять» in `/claude-mesh:mesh-review`),
  which produces no edit and no commit. The stop check still applies, and running it is this
  bullet's job: «стоп» during the run sets `stop = true` — Step 9's flag, whose only other
  assignment lives in the waiting branch this mode replaces — ends the run, and records the
  remainder as `deferred`. Miss that assignment and the committed iteration file reads
  `Отложено (стоп): 6` beside `Пользователь сказал "стоп": Нет`, while Step 16 prints
  `Final status: No new issues` for a run the user cut short.

**12.c — Process ONE disputed issue at a time.** Present analysis → (auto-apply if one variant is adequate, otherwise end the turn and wait for the free-text choice; in `autodecide` mode neither — the command decides and applies) → apply → THEN move to the next. Never batch multiple disputed issues into a single message.

After the loop, also add all `auto_fixes`, `repeated`, `dismissed` entries to `answers` with their statuses (`new-auto`, `repeat`, `new-dismissed` respectively), and every deferred disputed issue with status `deferred` (`answer: "отложено (стоп)"`, `action: "-"`, note your recommended variant if the analysis was already presented), so Step 13 can render the iter file without losing deferred issues.

### Step 13: Generate Iteration File

**Date source:** Use the date from design document filename (`YYYY-MM-DD`), NOT current date.
- Example: design `2026-01-27-checksum-design.md` → iter file `2026-01-27-checksum-review-iter-1.md`

<!-- SYNC: the date rule is mirrored by commands/design-review-fresh-session.md Step 2
     and commands/code-review-fresh-session.md Step 3 — change all three together. -->

Create `docs/superpowers/specs/YYYY-MM-DD-<topic>-review-iter-N.md` with the format below. Its
`**Уверенность:**` and `**Коммит:**` lines belong only to issues whose `**Статус:**` is
`Решено автоматически (autodecide)` — omit both lines entirely for every other status. A
`под вопросом` decision repeats its flag inside `**Ответ:**` as well, and that duplication is the
point: `agents/review-discussion.md` builds the next iteration's answer base out of `**Ответ:**` and
reads no other field, so this is the only place the flag survives into the session meant to re-check
it — where Step 9 then buckets the repeat as `disputed` instead of auto-answering it.
Every single letter in its `Статистика` list is a count, `X` («Отклонено») included: the `X` of
`Вариант X` elsewhere on the page is a different placeholder in a different position, and the two
never share a slot. Counts, however, are not all buckets: `из них под вопросом: C?` sits INSIDE
`Решено автоматически: C`, not beside it, and `Всего замечаний: T` is the sum of the buckets only —
see Step 15:

```markdown
# Review Iteration N — YYYY-MM-DD HH:MM

## Источник

- Design: `[DESIGN_PATH]`
- Plan: `[PLAN_PATH]`
- Review agents: [list of agents used]
- Merged output: `[REVIEW_OUTPUT]`

## Замечания

### [TYPE-N] Issue Title

> Issue text from review...

**Источник:** [which agent(s) raised this issue]
**Статус:** Автоисправлено | Обсуждено с пользователем | Решено автоматически (autodecide) | Отклонено | Повтор (iter-M, TYPE-K) | Отложено (стоп)
**Ответ:** Auto-fix description / User's answer / Dismissal reason / Previous answer / Auto-decision (`Вариант X (autodecide)`, or `Вариант X (autodecide, под вопросом: <чего не хватило>)`)
**Уверенность:** уверенно | под вопросом (<чего не хватило>)
**Коммит:** <short SHA>, или «—» для решения «Оставить как есть» («не исправлять»)
**Действие:** What was changed in documents

---

[repeat for each issue]

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| file.md | Description of change |

## Статистика

- Всего замечаний: T
- Автоисправлено (без обсуждения): A
- Авто-применено после анализа: B1
- Обсуждено с пользователем: B2
- Решено автоматически (autodecide): C
- из них под вопросом: C?
- Отклонено: X
- Повторов (автоответ): Z
- Отложено (стоп): S
- Пользователь сказал "стоп": Да/Нет
- Агенты: [list of agents used]
```

### Step 14: Commit Decisions and Iteration Log

**The auto-fixes were already committed in Step 11.** This step commits everything produced by the disputed discussion plus the iteration log itself.

1. Stage:
   - Design document (DESIGN_PATH) — if modified during Step 12
   - Plan document (PLAN_PATH) — if modified during Step 12
   - Iteration file (`docs/superpowers/specs/YYYY-MM-DD-<TOPIC>-review-iter-N.md`)
   - Merged review file (`docs/superpowers/specs/YYYY-MM-DD-<TOPIC>-review-merged-iter-N.md`)
2. Commit with message: `docs: review iter N — decisions + log (<TOPIC>)`
3. Do NOT push.

**If only the iter+merged files exist and no doc edits happened in Step 12** (e.g. all disputed → "Оставить как есть"), still commit so the log is preserved.

**If nothing was produced at all** (no auto-fixes, no disputed, no iter file written — unlikely), skip the commit.

**In `autodecide` mode the document edits are already committed** — one commit per decision, made
by `/claude-mesh:auto-decide-disputed`. This step then stages only the iteration file and the
merged review file, and its message becomes `docs: review iter N — log (<TOPIC>)`: naming
decisions in a commit that carries none would misdescribe the history, and the decisions are in
their own commits beside it, findable with `git log --grep=auto-decide-disputed`.

**Stage only those two if the tree is in fact clean of disputed-phase edits.** A user who cuts into
the run to pick a variant themselves — `/claude-mesh:auto-decide-disputed` Step 3 allows it
explicitly — has that choice applied by the ordinary handler, which makes no decision commit of its
own; Step 13 then records the issue as `Обсуждено с пользователем` with a `**Действие:**` naming a
change nothing in git carries. So look at `git status` before staging: if DESIGN_PATH or PLAN_PATH
holds uncommitted edits from Step 12, commit those on their own FIRST, under the message
settle-the-tree already uses for exactly this content — `docs: review iter N — decisions (<TOPIC>)`
— and only then stage the iteration and merged files for the `log` commit. Two commits, and the
human/machine boundary stays visible in the history. **Exclude every path a failed decision commit
left changed** — the set the command names when it hands back, its own files plus anything a hook
touched on the way to failing. A hook's collateral rewrite of DESIGN_PATH is not the decision's
file, and committing it here would record a failure as a decision. `/claude-mesh:mesh-review` Step 6.5 carries the
same guard in its own form.

**If the command was invoked only after this step already ran** — «стоп» ended Step 12, Steps 13–14
committed those issues as `Отложено (стоп)`, and the user then handed the deferred queue to
`/claude-mesh:auto-decide-disputed` (its state S4) — this step does not run again and does not cover
those decisions. **The command closes the record itself** — it appends a `## Дополнение` block to
the iteration file this step committed, supersedes the superseded records, fixes `Статистика` and
commits that file on its own. The procedure is written once, in
`commands/auto-decide-disputed.md` §S4; do not restate it here. What belongs to this step is only
the fact above: in that situation Step 14 does not run again.

### Step 15: Next Steps

Count from answers:
- `auto_fixed` = count where status == "new-auto"
- `auto_after_analysis` = count where status == "new-auto-after-analysis"
- `discussed` = count where status == "new"
- `autodecided` = count where status == "new-autodecide"
- `autodecided_unsure` = of those, count whose `confidence` starts with "под вопросом" — a SUBSET of `autodecided`, not a bucket beside it
- `dismissed` = count where status == "new-dismissed"
- `repeated` = count where status == "repeat"
- `deferred` = count where status == "deferred"
- `total` (`T` in Step 13's `Статистика` and in Step 16) = the sum of the BUCKETS above — `auto_fixed + auto_after_analysis + discussed + autodecided + dismissed + repeated + deferred`. `autodecided_unsure` is not one of them; adding it counts every `под вопросом` decision twice and makes `T` exceed the number of `### [TYPE-N]` sections Step 13 writes, contradicting review-discussion's own `SUMMARY total` and the Step 9 classification table

**ALWAYS ask user what to do next** (iterations are always done in fresh sessions):

Use **AskUserQuestion tool**:
```
Question: "Итерация N завершена. Автоисправлено: {auto_fixed}, авто-после-анализа: {auto_after_analysis}, обсуждено: {discussed}, решено автоматически: {autodecided} (под вопросом: {autodecided_unsure}), отклонено: {dismissed}, повторов: {repeated}, отложено: {deferred}. Что дальше?"
Header: "Iteration"
Options:
  - label: "Новая итерация (fresh session)"
    description: "Сгенерировать prompt для запуска следующей итерации review в новой сессии"
  - label: "Остановиться и начать работу (fresh session)"
    description: "Сгенерировать prompt для продолжения работы над планом в новой сессии"
```

**Based on user response:**

- **"Новая итерация":** Execute `/claude-mesh:design-review-fresh-session` via the Skill tool
  (it generates the prompt for the next iteration and knows this may run in a sandbox), then
  go to Step 16. If that command does not resolve — an older plugin in this environment —
  warn that the plugin needs an update for the review-generator flow and fall back to
  `/claude-mesh:continue-plan-fresh-session` **with an instruction to run
  `/claude-mesh:mesh-design-review` in the new session**, as before this feature — then go to
  Step 16 either way
- **"Остановиться и начать работу":** Execute `/claude-mesh:continue-plan-fresh-session` skill via Skill tool, then go to Step 16

### Step 16: Present Final Summary

When loop exits, display the block below. Its `**Под вопросом — перепроверьте:**` section belongs
only to a run with `autodecided_unsure > 0`, and its closing `**Все авто-решения:**` line only to
one with `autodecided > 0` — drop each otherwise. The recheck section is where the confidence flag
does its work: one line per such decision, so the user knows what to look at without opening the
iteration file:

```
## Review Complete

**Iterations:** N
**Total issues processed:** T
**Review agents used:** [list of agents]
**Final status:** [No new issues / User stopped]

**Iteration files:**
- docs/superpowers/specs/YYYY-MM-DD-topic-review-iter-1.md
- docs/superpowers/specs/YYYY-MM-DD-topic-review-iter-2.md
- ...

**Documents updated:**
- [list of modified design/plan files]

**Под вопросом — перепроверьте:**
- [TYPE-N] <Issue title> — Вариант X, <short SHA или «—»> — не хватило: <what was missing>

**Все авто-решения:** git log --grep=auto-decide-disputed --oneline
```

## Error Handling

| Error | Solution |
|-------|----------|
| No design doc found | Ask user to specify DESIGN_PATH |
| `config.yaml` not found (loader rc=2) | Copy `config.example.yaml` into the dir `"$LOADER" data-dir` prints, fill tokens, retry (a literal placeholder here is substituted by the harness and points at the wrong dir under a `--plugin-dir` load) |
| `config.yaml` invalid (loader rc=1) | Surface the validator stderr to the user; the USER edits config.yaml (agents never modify it); retry after the user confirms |
| `defaults.design_review` missing (with `default` arg) | Run without `default`, or add the preset to `config.yaml` |
| A CLI engine's own section does not validate while a preset names it (`get-defaults` returns `grok_degraded: true`) | Not an error to stop on: the loader has already degraded that engine ALONE — dropped from `builtin`, its model list emptied — so every other reviewer this run asked for still runs. That flag is the only thing saying a reviewer you asked for is not running, so announce it verbatim per Step 5.1, continue, and never substitute another engine for it. The USER edits `config.yaml`; agents never do |
| One agent fails, others succeed | Continue with available results, note failure in merged output |
| Native spawn rejected (HOST=grok, `model:` slug the host does not accept) | Table row, no substitute slug. `max_redispatch` is wrappers only. `verify-delegation.sh is never invoked for native` |
| HOST=grok preset `run_mode: team` | Already STOP in Step 5.1: `На Grok team mode не поддерживается — остановите запуск и используйте background.` Do not dispatch |
| Silent wrapper + `REAL` on HOST=grok | Read `output.txt` yourself (primary path). No SendMessage |
| All agents fail | Show error, save progress, allow retry |
| `claude-mesh:review-discussion` fails | Show error, save progress |
| User interrupts | Save current progress to iter file |

## Example Usage

**Start iterative review** (commands/skills are namespaced — bare names do not resolve on CC 2.1.156):
```
/claude-mesh:mesh-design-review
```

**Use the configured default reviewer set (skip selection UI):**
```
/claude-mesh:mesh-design-review default
```

**With explicit paths:**
```
/claude-mesh:mesh-design-review DESIGN_PATH=docs/superpowers/specs/2026-01-28-auth-design.md
```

**Continue from previous session:**
Just run again — skill finds existing iter files and continues.
