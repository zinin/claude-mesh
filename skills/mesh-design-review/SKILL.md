---
name: mesh-design-review
description: Iterative design review with memory - remembers previous answers, filters duplicates
user_invocable: true
---

# Iterative Design Review (mesh-design-review)

Run iterative design review cycle with memory of previous decisions.

**Announce at start:** "Using mesh-design-review skill for iterative review with memory."

## Locating plugin files (Task 2.5)

When this skill loads, Claude Code prints a line `Base directory for this skill: <ABS>`. **`${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are NOT available inside Bash-tool calls** (verified empty on Claude Code 2.1.156). So at the top of EACH Bash block set `SKILL_BASE` to that printed absolute path. From it:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- sibling shared scripts = `$SKILL_BASE/../shared/<x>`
- data dir = `"$LOADER" data-dir` (the loader self-discovers `~/.claude/plugins/data/claude-mesh-*`); build any state paths under `$PLUGIN_DATA/state/`

Config reads in this skill go through the loader subcommands (`get-flag`, `get-defaults design_review`, `list-models`) — never raw `yq`. `get-flag` returns `1`/`0`; compare to `1`, never to `"true"`.

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
- **DEFAULT** — if `default` argument is passed, skip the Step 5 selection UI and use the `defaults.design_review` preset from `config.yaml` (each `builtin` entry → its executor; each `models` id → `claude-mesh:ext-claude-executor MODEL=<id>`). See Step 5.

## Iron Rules for Processing Issues

These rules are NON-NEGOTIABLE. Steps 9–12 implement them; this list exists so you catch yourself before drifting.

> Sync note: rules 3–8 are mirrored in `commands/mesh-review.md` (Iron Rules / Step 6.4). When editing shared rule text, mirror the edit there (step numbers differ; mesh-review additionally has `default`-mode clauses — this skill is always interactive).

1. **Phase order is fixed:** classify ALL issues first → apply auto-fixes → commit → discuss disputed one-by-one. Never interleave.
2. **Auto-fixes are committed BEFORE disputed discussion starts.** The user gets a clean checkpoint with all the safe edits.
3. **Disputed issues are processed ONE AT A TIME, in separate messages.** Never present a bulk list of disputed issues. Never dump all variants for all issues in one go.
4. **Every disputed issue gets a structured analysis** (Суть → Анализ → Варианты → Рекомендация). Bullet-only one-liners are forbidden. Write enough that someone who hasn't read the review can follow.
5. **Always evaluate the variants you propose.** Each variant gets pros/cons, and you explicitly recommend ONE with reasoning. Never list variants neutrally.
6. **If only one variant is genuinely adequate, do not ask the user.** Announce the decision, briefly say why the others fail, apply, move on. Asking when there's no real choice is noise.
7. **One disputed issue at a time.** Present its analysis; if one variant is adequate, apply it in the same message and move on; if a choice remains, the analysis is the FINAL message of the turn (no tool call) and you wait for the user's free-text answer, then apply and start the next. Never batch.
8. **When a choice remains, the analysis IS the question — never AskUserQuestion.** The structured write-up (variants with pros/cons + recommendation) is the turn-final message; the turn ends with no trailing tool call and the user answers in free text. A trailing AskUserQuestion duplicates your write-up in its own modal UI and makes the harness drop the analysis — the user then sees only a bare modal. This is the regression this rule prevents.

### Red Flags — STOP if you catch yourself doing this

| Anti-pattern | What to do instead |
|---|---|
| About to print a list of all disputed issues in one go | Stop. Take only the first one. Write its full structured analysis. |
| Writing variants as "вариант A / B / C" without pros, cons, and a recommendation | Stop. For each variant write Плюсы / Минусы. Pick the best with 2–3 sentences why. |
| Asking the user a question while three other disputed issues are still unprocessed | Stop. Resolve current → apply → THEN start next. |
| Asking the user to pick when only one option actually works | Stop. Announce the decision and apply it. Asking is noise. |
| About to call AskUserQuestion for a disputed choice | Stop. The analysis + variants + recommendation are the turn's FINAL message; end the turn there and take the answer as free text. A modal would swallow the analysis (that is the regression). |
| Shrinking the analysis so a tool call can follow in the same turn | Stop. The analysis is the final message of the turn, as long as the issue needs. Don't trim it to precede a tool. |
| Applying an auto-fix in the middle of disputed discussion | Stop. Auto-fixes must all happen before disputed phase starts (Step 10), and must be committed (Step 11) before Step 12 begins. |
| Skipping the auto-fix commit because "I'll commit everything at the end" | Stop. The intermediate commit (Step 11) is the user's safe checkpoint. It is mandatory whenever auto-fixes were applied. |

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

### Step 2: Find Previous Iterations

Search for existing iteration files:
```bash
ls docs/superpowers/specs/*-{TOPIC}-review-iter-*.md 2>/dev/null | sort -V
```

Count existing iterations. Next iteration = max + 1 (or 1 if none).

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

Reviewer selection is **config-driven** — there are no hardcoded provider/model lists. Read the available executors and models from `config.yaml` via the loader, then either honor the `defaults.design_review` preset (`default` argument) or run the paginated selection UI. **Selection is made on the FIRST iteration only and reused for every subsequent iteration in the loop** — remember the resulting agent set (built-ins + model ids).

#### Step 5.0: Read available reviewers from config

Run ONE Bash call. Use `config-loader.sh` (NOT raw `yq`) so validation runs the same way everywhere:

```bash
# Task 2.5 (CC 2.1.156): ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA} are EMPTY in
# Bash-tool calls from skills. Locate files via the absolute base dir Claude Code
# prints at skill load ("Base directory for this skill: <ABS>"). See "## Locating
# plugin files (Task 2.5)" near the top.
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
[ -x "$LOADER" ] || { echo "config-loader.sh not found at $LOADER" >&2; exit 1; }

# iter-3 CRITICAL-3: a bare $() swallows the loader exit code. Probe once with explicit rc
# capture so rc=2 (config.yaml not created yet — fresh install) is NOT misreported as
# rc=1 (config invalid).
LOADER_ERR=$(mktemp)
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
HAS_MODELS=$("$LOADER" get-flag has_models)
MODELS=$("$LOADER" list-models)            # `<id>|<label>` per line, ready for pagination
DEFAULTS_JSON=$("$LOADER" get-defaults design_review)   # {"builtin":[...],"models":[...],"run_mode":null}
echo "$DEFAULTS_JSON"
DM_ERR=$(mktemp)
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model 2>"$DM_ERR") \
    || { echo "config.yaml невалиден (runtime.dispatch_model):" >&2; cat "$DM_ERR" >&2; rm -f "$DM_ERR"; exit 1; }
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
```

rc=0 → proceed; rc=2 → fresh-install hint + clean exit; rc=1 → surface the validator stderr and stop (iter-3 CRITICAL-3). Parse `DEFAULTS_JSON` with jq (`.builtin`, `.models`) to build `DEFAULT_IDS` (the recommended model ids) and the recommended built-in set. Compare `HAS_CODEX` / `HAS_GEMINI` / `HAS_MODELS` to `1` (the loader emits `1`/`0`, never `"true"`).

#### Step 5.1: `default` argument → use the preset

**If the `default` argument was passed:** skip the entire selection UI (Steps 5.2–5.3). Use the `defaults.design_review` preset from `DEFAULTS_JSON`:

- If `defaults.design_review` is missing/empty (`.builtin` empty AND `.models` empty) → STOP with a clear error:
  `defaults.design_review not configured in config.yaml. Run /claude-mesh:mesh-design-review without "default" or add the preset.`
- For each entry in `.builtin`:
  - `codex` → spawn `claude-mesh:codex-executor`
  - `gemini` → spawn `claude-mesh:gemini-executor`
- For each model id in `.models` → spawn `claude-mesh:ext-claude-executor` with `MODEL=<id>`.

Remember this agent set for all subsequent iterations. Go directly to Step 6.

#### Step 5.2 (Q1): Ask which reviewer TYPES

**Otherwise** (interactive), on the first iteration ask which executor TYPES to use.

AskUserQuestion has no `preSelected` API — recommendations are communicated visually with a `★` marker in the label (an entry is recommended when it is in the `defaults.design_review` preset).

Use AskUserQuestion (multiSelect: true, max 4, header: "Reviewers"):
```
question: "Какие типы reviewers запустить? (★ = recommended, в defaults.design_review)"
options:
  - "codex CLI ★ default"                          — show only if HAS_CODEX=1; ★ if "codex" in defaults.builtin
  - "gemini CLI ★ default"                         — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.builtin
  - "external models (Anthropic-API) ★ default"    — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```

(Show only the options whose gating flag is `1`. If none are available — no codex, no gemini, no models — STOP with "нет доступных reviewer-типов в config.yaml".) If "external models" is not selected → skip Step 5.3 entirely (only built-in executors run).

#### Step 5.3 (Q2..Qn): Paginated model selection

Only if "external models" was selected in Q1. AskUserQuestion `options` has no `preSelected`/`checked` flag — pre-recommended ids are marked visually in the `label` instead.

Build `DEFAULT_IDS` from `defaults.design_review.models`. For each chunk of 4 models from `MODELS` (`<id>|<label>` lines, in config order):

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

After Q1 (and pagination if it ran), show the full selected set — built-in TYPES plus `SELECTED_IDS` (one per line) — and confirm (mirrors mesh-review Step 3.5):

```
header: "Confirm"
question: "Запустить ревью с этим набором? <bullet list: selected built-ins + SELECTED_IDS>"
options:
  - "Запустить (Recommended)"  — proceeds to Step 6
  - "Перевыбрать"              — restarts Step 5.2 from Q1 with the same DEFAULT_IDS
  - "Отмена"                   — exit the skill without dispatching
```

On "Перевыбрать": clear the selection and restart from Step 5.2. Loop guard: cap re-selects at 3; on the 4th, message "Слишком много перевыборов; запустите /claude-mesh:mesh-design-review заново" and exit. If the user deselected everything (no built-ins AND no models) → STOP with "ничего не выбрано для ревью".

Remember the confirmed set (built-in TYPES + `SELECTED_IDS`) for all subsequent iterations in the loop.

### Step 6: Execute Review via Selected Agents

**LOOP START:**

Before dispatch — via a Bash call, stamp `DISPATCH_EPOCH=$(date +%s)` and keep the number (the result-collection watch below needs it).

Launch **all selected** agents **in parallel** in a single message:

For each selected agent, use Task tool (plugin `subagent_type`s are `claude-mesh:`-namespaced — verified on CC 2.1.156; bare names do not resolve).

**Dispatch model:** if `DISPATCH_MODEL` (from Step 5.0) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch in this step. If it is empty, omit `model:` so each executor inherits this session's model.

**codex / gemini executors** parse `PROMPT` / `MODEL` / `REASONING_LEVEL` as named params (any line), so use the wrapped form:
```
Task tool:
  subagent_type: [claude-mesh:<executor>]
  description: "Design review via [agent-name] (iter N)"
  prompt: "Execute this prompt via [tool]:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    [agent-specific params]"
```

**`claude-mesh:ext-claude-executor`** REQUIRES `MODEL=<id>` on the **FIRST non-blank line** of the prompt (it parses `^MODEL=(\S+)` and STOPs otherwise). Do NOT wrap it behind an `Execute this prompt via…` line — put MODEL first, then the wrapper:
```
Task tool:
  subagent_type: claude-mesh:ext-claude-executor
  description: "Design review via <id> (iter N)"
  prompt: "MODEL=<id>
    Execute this prompt via ext-claude-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N"
```

Agent-specific parameters:
- **`claude-mesh:codex-executor`** (built-in selected: `codex`): pass `MODEL={CODEX_MODEL}` / `REASONING_LEVEL={CODEX_REASONING_LEVEL}` ONLY when the user explicitly set them; otherwise omit both lines entirely — codex-exec resolves model/level from `config.yaml` (`codex.model` / `codex.reasoning_level`, fallbacks `gpt-5.5`/`xhigh`)
- **`claude-mesh:gemini-executor`** (built-in selected: `gemini`): default settings
- **`claude-mesh:ext-claude-executor`** (one per selected model id): `MODEL=<id>` on line 1 (e.g. `MODEL=zai/glm`, `MODEL=alibaba/qwen`, `MODEL=ollama/kimi`) — the model id comes from the config (`SELECTED_IDS`, or `defaults.design_review.models` in `default` mode), NOT a hardcoded provider profile.

Collect output paths from every agent — but do NOT passively wait for completions: the watch loop below is what turns finished runs into reports.

**CRITICAL — an executor's report does NOT arrive on its own: disk-watch the runs and ping idle executors.** Each executor launches its external engine (watchdog + CLI) as a background Bash task, sends an interim status naming its run dir (`runs/<engine>/…` under the plugin data dir), ends its turn and goes idle. The harness delivers NO task-notification to an idle subagent when that background task exits, so the report stalls until pinged (same mechanics verified 2026-07-10 on the mesh-review wrappers: 0 notifications in 5/5 transcripts, reports stalled 8–12 min over a finished `output.txt`). After dispatch:

1. Capture each executor's run dir from its interim status. Fallback when a status names none: the newest dir under `$PLUGIN_DATA/runs/<engine>/[<provider>/<model>/]` (`PLUGIN_DATA` = `"$LOADER" data-dir`) created after `DISPATCH_EPOCH`.
2. Poll the disk via Bash — as a background Bash task (a background watcher that exits on each state change re-invokes the orchestrator per event; a foreground poll loop would block the session). ~30–60 s cadence; bound the whole watch by `runtime.timeouts.global_sec` (read it via `"$LOADER" get-runtime | jq -r '.timeouts.global_sec'`, default 3600) plus a margin. A run is finalized when: root `output.txt` is present and non-empty (gemini-exec pre-creates a zero-byte `output.txt` at launch — an empty file is NOT finalization), or a `final` symlink exists, or the run's `watchdog.log` has a `cleanup` event.
3. When a run is finalized but its executor has not delivered its review — SendMessage that agent: `your external run finished — read its output.txt, extract the findings and send your report`. Ping once per finalized run — re-ping only if the executor is still silent after the next poll interval (~60–90 s).
4. Repeat until every dispatched executor has reported or the watch budget expires; treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings".

### Step 7: Merge Review Results

After all agents complete:

1. Read output from each agent
2. Create a merged review file at `docs/superpowers/specs/YYYY-MM-DD-<TOPIC>-review-merged-iter-N.md`:

```markdown
# Merged Design Review — Iteration N

## codex-executor

[full output from codex]

---

## gemini-executor

[full output from gemini]

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

Display intro:
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

**12.c — Process ONE disputed issue at a time.** Present analysis → (auto-apply if one variant is adequate, otherwise end the turn and wait for the free-text choice) → apply → THEN move to the next. Never batch multiple disputed issues into a single message.

After the loop, also add all `auto_fixes`, `repeated`, `dismissed` entries to `answers` with their statuses (`new-auto`, `repeat`, `new-dismissed` respectively), and every deferred disputed issue with status `deferred` (`answer: "отложено (стоп)"`, `action: "-"`, note your recommended variant if the analysis was already presented), so Step 13 can render the iter file without losing deferred issues.

### Step 13: Generate Iteration File

**Date source:** Use the date from design document filename (`YYYY-MM-DD`), NOT current date.
- Example: design `2026-01-27-checksum-design.md` → iter file `2026-01-27-checksum-review-iter-1.md`

Create `docs/superpowers/specs/YYYY-MM-DD-<topic>-review-iter-N.md` with format:

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
**Статус:** Автоисправлено | Обсуждено с пользователем | Отклонено | Повтор (iter-M, TYPE-K) | Отложено (стоп)
**Ответ:** Auto-fix description / User's answer / Dismissal reason / Previous answer
**Действие:** What was changed in documents

---

[repeat for each issue]

## Изменения в документах

| Файл | Изменение |
|------|-----------|
| file.md | Description of change |

## Статистика

- Всего замечаний: X
- Автоисправлено (без обсуждения): A
- Авто-применено после анализа: B1
- Обсуждено с пользователем: B2
- Отклонено: C
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

### Step 15: Next Steps

Count from answers:
- `auto_fixed` = count where status == "new-auto"
- `auto_after_analysis` = count where status == "new-auto-after-analysis"
- `discussed` = count where status == "new"
- `dismissed` = count where status == "new-dismissed"
- `repeated` = count where status == "repeat"
- `deferred` = count where status == "deferred"

**ALWAYS ask user what to do next** (iterations are always done in fresh sessions):

Use **AskUserQuestion tool**:
```
Question: "Итерация N завершена. Автоисправлено: {auto_fixed}, авто-после-анализа: {auto_after_analysis}, обсуждено: {discussed}, отклонено: {dismissed}, повторов: {repeated}, отложено: {deferred}. Что дальше?"
Header: "Iteration"
Options:
  - label: "Новая итерация (fresh session)"
    description: "Сгенерировать prompt для запуска следующей итерации review в новой сессии"
  - label: "Остановиться и начать работу (fresh session)"
    description: "Сгенерировать prompt для продолжения работы над планом в новой сессии"
```

**Based on user response:**

- **"Новая итерация":** Execute `/claude-mesh:continue-plan-fresh-session` skill via Skill tool with instruction to run `/claude-mesh:mesh-design-review` in the new session, then go to Step 16
- **"Остановиться и начать работу":** Execute `/claude-mesh:continue-plan-fresh-session` skill via Skill tool, then go to Step 16

### Step 16: Present Final Summary

When loop exits, display:

```
## Review Complete

**Iterations:** N
**Total issues processed:** X
**Review agents used:** [list of agents]
**Final status:** [No new issues / User stopped]

**Iteration files:**
- docs/superpowers/specs/YYYY-MM-DD-topic-review-iter-1.md
- docs/superpowers/specs/YYYY-MM-DD-topic-review-iter-2.md
- ...

**Documents updated:**
- [list of modified design/plan files]
```

## Error Handling

| Error | Solution |
|-------|----------|
| No design doc found | Ask user to specify DESIGN_PATH |
| `config.yaml` not found (loader rc=2) | Copy `config.example.yaml` into the dir `"$LOADER" data-dir` prints, fill tokens, retry (a literal placeholder here is substituted by the harness and points at the wrong dir under a `--plugin-dir` load) |
| `config.yaml` invalid (loader rc=1) | Surface the validator stderr to the user; the USER edits config.yaml (agents never modify it); retry after the user confirms |
| `defaults.design_review` missing (with `default` arg) | Run without `default`, or add the preset to `config.yaml` |
| One agent fails, others succeed | Continue with available results, note failure in merged output |
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
