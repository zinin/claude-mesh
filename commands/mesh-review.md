---
name: mesh-review
description: Launch external code review agents (claude-self, codex, gemini, ext-claude on N models) with selection UI and result deduplication.
---

# /mesh-review

Launch multiple external code review agents in parallel, collect and deduplicate results.

## Step 0: Check for `default` argument

If invoked as `/claude-mesh:mesh-review default` (Task 2.5: commands are namespaced; bare `/mesh-review` does not resolve on CC 2.1.156):
- Skip Steps 1-3 entirely.
- Read `defaults.code_review` via `"$LOADER" get-defaults code_review` and parse with jq (`.builtin`, `.models`, `.run_mode`); read the runtime block ONCE via `RUNTIME_JSON=$("$LOADER" get-runtime)` and pull BOTH fields from that single JSON — `DEFAULT_RUN_MODE=$(echo "$RUNTIME_JSON" | jq -r '.default_run_mode')` and `DISPATCH_MODEL=$(echo "$RUNTIME_JSON" | jq -r '.dispatch_model // empty')` — then `echo "DISPATCH_MODEL=$DISPATCH_MODEL"` to surface it (empty = inherit the session model on dispatch). (iter-3 CONCERN-1 — these come through the loader, not raw-yaml reads; `get-runtime` validates the runtime block, so a charset-invalid `dispatch_model` fast-fails here.)
- Read via the loader with the same rc=2/rc=1 distinction as Step 1 (iter-3 CRITICAL-3) — rc=2 ⇒ print the copy-config hint and exit cleanly.
- If `defaults.code_review` not configured → STOP with error:
  `defaults.code_review not configured in config.yaml. Use /claude-mesh:mesh-review without argument or add the preset.`
- Spawn all reviewers per preset:
  - For each entry in `defaults.code_review.builtin` (claude/codex/gemini), spawn the corresponding agent.
  - For each model id in `defaults.code_review.models`, spawn `ext-claude-code-reviewer` with `MODEL=<id>`.
- Use `run_mode` from preset (default: `background`).
- Dispatch via the Step 5a (background) / Step 5b (team) mechanics per that `run_mode`, then go to **Step 6: Process Results**.

## Step 1: Read available reviewers from config

Use `config-loader.sh` instead of raw `yq` so validation runs the same way everywhere (CRITICAL-10):

```bash
# Task 2.5 (CC 2.1.156): ${CLAUDE_PLUGIN_ROOT} is EMPTY in Bash-tool calls from slash
# commands (no skill-load base line either) — locate the loader by globbing the install dir.
LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | head -1)"
[ -n "$LOADER" ] || { echo "config-loader.sh not found under ~/.claude/plugins (is claude-mesh installed?)" >&2; exit 1; }
# iter-3 CRITICAL-3: a bare $() swallows the loader exit code. Probe once with explicit rc
# capture so rc=2 (config.yaml not created yet — fresh install) is NOT misreported as
# rc=1 (config invalid). Distinct handling per design §6.6 / iter-2 CONCERN-11.
LOADER_ERR=$(mktemp)
HAS_CODEX=$("$LOADER" get-flag has_codex 2>"$LOADER_ERR"); LRC=$?
case "$LRC" in
  0) ;;
  2) echo "config.yaml ещё не создан. Скопируйте config.example.yaml в \${CLAUDE_PLUGIN_DATA}/config.yaml, заполните токены и повторите /claude-mesh:mesh-review."; rm -f "$LOADER_ERR"; exit 0 ;;
  *) echo "config.yaml невалиден:" >&2; cat "$LOADER_ERR" >&2; rm -f "$LOADER_ERR"; exit 1 ;;
esac
rm -f "$LOADER_ERR"
HAS_GEMINI=$("$LOADER" get-flag has_gemini)
HAS_MODELS=$("$LOADER" get-flag has_models)
MODELS=$("$LOADER" list-models)  # `<id>|<label>` per line, ready for pagination
DM_ERR=$(mktemp)
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model 2>"$DM_ERR") \
    || { echo "config.yaml невалиден (runtime.dispatch_model):" >&2; cat "$DM_ERR" >&2; rm -f "$DM_ERR"; exit 1; }
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
```

rc=0 → proceed; rc=2 → fresh-install hint + clean exit; rc=1 → surface the validator stderr and stop (iter-3 CRITICAL-3).

## Step 2 (Q1): Ask which reviewer TYPES

Use AskUserQuestion (multiSelect, max 4):

**iter-2 CONCERN-4:** AskUserQuestion has no `preSelected` API (iter-1 CONCERN-11). The "all checked by default" comment in the legacy `/external-code-review` was aspirational, not enforced. Apply the same `★ recommended` annotation pattern that Step 3 uses for models — types in `defaults.code_review.builtin` get the ★ marker in their label so users see the recommendation. Then add Step 2.5 confirmation (mirrors Step 3.5 for models).

```
header: "Reviewers"
question: "Какие типы reviewers запустить? (★ = recommended, в defaults.code_review.builtin)"
options:
  - "claude ★ default (свой Claude через superpowers)"        — always shown; ★ if "claude" in defaults.code_review.builtin
  - "codex CLI ★ default"                                      — show only if HAS_CODEX=1; ★ if "codex" in defaults.code_review.builtin
  - "gemini CLI ★ default"                                     — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.code_review.builtin
  - "external models (Anthropic-API) ★ default"                — show only if HAS_MODELS=1; ★ if defaults.code_review.models is non-empty
```

If "external models" not selected → skip Step 3 entirely.

## Step 2.5 (Q1.5): Confirm reviewer-type selection

Mirror Step 3.5 (model confirmation): after Q1 answer, show the full SELECTED_TYPES list (one per line) and ask:

```
header: "Подтверди"
question: "Использовать эти reviewer-типы? <bullet list of SELECTED_TYPES>"
options:
  - "Да, использовать как выбрано"
  - "Нет, выбрать заново" — re-runs Q1 (cap 3 attempts; on the 4th attempt, surface STOP "пользователь не подтвердил выбор reviewer-типов")
  - "Отмена" — exits command cleanly (no executors dispatched)
```

## Step 3 (Q2..Qn): Paginated model selection

AskUserQuestion `options` schema (verified in iteration 1) does NOT support a `preSelected`/`checked` flag — pre-check requested by defaults must be communicated visually in the `label` text instead. Per CONCERN-11.

Read the default set from `defaults.code_review.models` (if exists). Build a set `DEFAULT_IDS` of model ids that should appear pre-recommended.

For each chunk of 4 models from `models[]` (in config order):
- AskUserQuestion (multiSelect, max 4):
  ```
  header: "Models"
  question: "Какие модели использовать? (страница N/M)"
  options:
    For each model in the chunk:
      label:       "<model.label>" if id NOT in DEFAULT_IDS
                   "★ <model.label> (recommended)" if id IS in DEFAULT_IDS
      description: "<model.id>"
  ```

Collect all selected model ids across pages into `SELECTED_IDS`.

## Step 3.5 (Q_confirm): Final confirmation with full list

Because pagination prevents the user from seeing all selections at once (and there is no preSelected hint to anchor on), show one final read-only-style review question after Step 3:

```
header: "Confirm"
question: "Запустить ревью с этими моделями: <comma-separated SELECTED_IDS>?"
options:
  - "Запустить (Recommended)" — proceeds to Step 4
  - "Перевыбрать модели"      — jumps back to Step 3 with the same DEFAULT_IDS, drops current SELECTED_IDS
  - "Отмена"                  — exit /mesh-review without dispatching
```

On "Перевыбрать": clear SELECTED_IDS, restart Step 3 pagination from page 1 with the same defaults set. Loop guard: cap re-selects at 3 to prevent infinite ping-pong; on the 4th re-select, message "Слишком много перевыборов; начните /claude-mesh:mesh-review заново" and exit.

Skip Step 3.5 if `len(SELECTED_IDS) == 0` (user deselected everything — surface that as STOP "no models selected").

## Step 4 (Q_last): Run mode

AskUserQuestion (single, 2 options):
```
header: "Run mode"
question: "Как запускать ревьюеров?"
options:
  - "Background tasks (Recommended)"   if runtime.default_run_mode == background
  - "Team of reviewers"
```

Since AskUserQuestion lacks preSelected, the recommended choice gets a "(Recommended)" suffix in its `label` (matches the convention used in other claude-mesh AskUserQuestion sites).

## Step 5a: Background tasks mode

**Before dispatch — stamp the delegation window (Step 6.0 guard needs it).** Via a Bash tool call, record `DISPATCH_EPOCH=$(date +%s)` and keep the number. Also remember the list of *wrapper* reviewers being dispatched as `engine:model` pairs: `codex`→`codex:-`, `gemini`→`gemini:-`, each selected model id→`ext-claude:<id>`. The builtin `claude` / `general-purpose` reviewer is NOT a wrapper (it reviews inline by design) — exclude it from this list.

Launch all selected reviewers via Task tool, each `run_in_background: true`, in ONE message:

**Dispatch model:** if `DISPATCH_MODEL` (resolved in Step 0 for `default` mode, or Step 1 for interactive) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch below. If it is empty, omit `model:` so each reviewer inherits this session's model. This applies to the builtin `claude` reviewer dispatch too.

For each builtin reviewer:
- claude: `subagent_type: "general-purpose"` (built-in — NOT namespaced), prompt invokes `superpowers:requesting-code-review` skill
- codex: `subagent_type: "claude-mesh:codex-code-reviewer"`, prompt: `Review the changes for production readiness`
- gemini: `subagent_type: "claude-mesh:gemini-code-reviewer"`, prompt: `Review the changes for production readiness`

For each selected model id:
- `subagent_type: "claude-mesh:ext-claude-code-reviewer"`, prompt: `MODEL=<id> Review the changes for production readiness`

**CRITICAL — wrapper reviewers get a SHORT delegation prompt, NOT an inlined review task.** The codex / gemini / ext-claude reviewers are thin wrappers; their agent def forces them to invoke the matching `*-code-review` skill, and the SKILL resolves the diff and builds the review prompt itself. Pass each wrapper ONLY the short prompt above (prefixed with `MODEL=<id>` for ext-claude). Do **NOT** inline scope / diff / project invariants / focus areas into a wrapper's prompt: a detailed "review this yourself" prompt makes the wrapper self-review on its own Claude model instead of delegating to the external model — silently, with no `runs/<engine>/…` artifacts produced. Extra review context, if any, is forwarded by the agent to the skill's `CONTEXT` argument; it is never a license to review inline. (Only the builtin `claude` / `general-purpose` reviewer reviews directly.)

Display:
```
N code review агентов запущены параллельно в фоне:
  [list with descriptions]

Ожидаю результаты. Вы можете продолжать работу — я сообщу, когда ревью завершатся.
```

**Do NOT block.** Continue accepting user instructions while agents work.
When each agent completes, read its output. After all agents finish (or the user cancels some), proceed to **Step 6: Process Results**.

## Step 5b: Team of reviewers mode

1. Generate the team name via a **Bash tool call** (which has a real `$$`, unlike the slash-command context which does not): `TEAM_NAME="code-review-$(date +%Y%m%d-%H%M%S)-$$"; DISPATCH_EPOCH=$(date +%s); echo "$TEAM_NAME $DISPATCH_EPOCH"`. Use the first value as the TeamCreate name (timestamp+PID suffix prevents collisions when two `/mesh-review` invocations run concurrently; on collision, regenerate). **Keep `DISPATCH_EPOCH`** and the same `engine:model` wrapper list as Step 5a (excluding the builtin `claude` reviewer) — Step 6.0's guard needs both. iter-3 QUESTION-1: do not paste a literal `<pid>` — there is no shell `$$` in the slash-command context itself.
2. Create one task per selected reviewer
3. Spawn teammates via Task tool with `team_name: "<the same unique name>"`, using the **same short per-reviewer prompts as Step 5a** (see the CRITICAL note there) — team mode does NOT change the prompt rules. Wrapper reviewers (codex / gemini / ext-claude) must still receive ONLY the short delegation prompt, never an inlined review task. The Step 5a **Dispatch model** rule also applies here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it.
4. Wait for completion → Step 6
5. Shut down team

## Step 6: Process Results

Issues are processed in a **fixed four-phase order**. Do NOT interleave phases. Do NOT batch disputed discussions.

### Iron Rules

1. **Phase order is fixed:** dedupe + classify ALL issues → apply auto-fixes → commit auto-fixes → discuss disputed one-by-one → commit decisions.
2. **Auto-fixes are committed BEFORE disputed discussion starts.** The user gets a clean checkpoint with the safe edits before any debate.
3. **Disputed issues are processed ONE AT A TIME, in separate messages.** Never present a bulk list of disputed issues. Never dump all variants for all issues in one go.
4. **Every disputed issue gets a structured analysis** (Суть → Анализ → Варианты → Рекомендация). Bullet-only one-liners are forbidden.
5. **Always evaluate the variants you propose.** Each variant gets pros/cons; you explicitly recommend ONE with reasoning. Never list variants neutrally.
6. **If only one variant is genuinely adequate, do not ask the user.** Announce the decision, briefly say why the others fail, apply, move on.
7. **One disputed issue → one message → decide → apply → next.** Only then write the next disputed analysis.

### Step 6.0: Verify delegation (mechanical guard)

**Run this BEFORE Step 6.1.** Wrapper reviewers (codex / gemini / ext-claude) non-deterministically *flip*: they skip their `*-code-review` skill and self-review inline on this session's own model — a polished review that is **NOT** external cross-validation and leaves **no** `runs/<engine>/…` artifacts. The Step 5 prose forcing reduces this but does not eliminate it (the agent defs are already maxed and still flip). This step catches it **mechanically by inspecting on-disk artifacts** — do NOT trust the text a wrapper returned.

The builtin `claude` / `general-purpose` reviewer is **skipped here** — it reviews inline by design and is always accepted into Step 6.1.

**1. Locate the loader, data dir, and guard:**
```bash
LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | head -1)"
[ -n "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
VERIFY="$(dirname "$LOADER")/verify-delegation.sh"
DATA_DIR="$("$LOADER" data-dir)"
N="$("$LOADER" get-runtime | jq -r '.max_redispatch // 1')"; [[ "$N" =~ ^[0-9]+$ ]] || N=1
```

**2. Classify each dispatched wrapper.** Iterate the `engine:model` list stamped in Step 5 (substitute the ACTUAL dispatched pairs):
```bash
# example — replace the list with what was actually dispatched:
for spec in "codex:-" "ext-claude:zai/glm" "ext-claude:ollama/kimi"; do
  eng="${spec%%:*}"; mdl="${spec#*:}"
  printf '%-28s ' "$spec"
  bash "$VERIFY" "$eng" "$mdl" "$DISPATCH_EPOCH" "$DATA_DIR"   # prints REAL|FLIP|STALLED|BROKEN; reason on stderr
done
```
Verdicts:
- `REAL` (exit 0) — delegated, real review → **keep** for Step 6.1.
- `FLIP` (exit 3) — no run dir → self-reviewed on the session model → **re-dispatch**.
- `STALLED` (exit 2) — run dir but killed mid-flight / empty output → **re-dispatch** (retry helps).
- `BROKEN` (exit 4) — run dir but thinking-only / DSML grammar / `num_turns≤1` → **DROP, do NOT retry** (the engine itself is broken).

**3. Show the delegation status table** so the user sees who really cross-validated:
```
| Reviewer            | Verdict | Action          |
|---------------------|---------|-----------------|
| ext-claude/zai/glm  | REAL    | ✅ kept          |
| codex               | FLIP    | ↻ re-dispatch   |
| ext-claude/ollama/… | BROKEN  | ✗ dropped       |
```

**4. Auto-redispatch loop (max `N` rounds; `N` = `runtime.max_redispatch`, default 1):**

`PROBLEMS` = reviewers whose verdict is `FLIP` or `STALLED`. While `PROBLEMS` is non-empty AND rounds-done < `N`:
  - **a. Stamp a fresh window** via Bash: `DISPATCH_EPOCH=$(date +%s)` — so the guard inspects the NEW run, not the old failed one.
  - **b. Re-dispatch ONLY the `PROBLEMS` reviewers** with the EXACT same short delegation prompt as Step 5a (`MODEL=<id> Review the changes for production readiness` for ext-claude; `Review the changes for production readiness` for codex/gemini), same `subagent_type`, same run mode. Apply the Step 5a **Dispatch model** rule on re-dispatch too (add `model: "<DISPATCH_MODEL>"` when non-empty, else omit). Wait for completion.
  - **c. Re-run the guard** (step 2) for those reviewers with the new `DISPATCH_EPOCH`; update their verdicts.
  - **d.** rounds-done++.

`BROKEN` reviewers are **never** re-dispatched — retry is futile (the fix is the USER swapping the model in `config.yaml` — agents never edit it — not retrying).

**5. Finalize:**
- `REAL` reviewers → their reviews enter Step 6.1 (dedupe/classify) as normal.
- Reviewers still `FLIP`/`STALLED` after `N` rounds → **EXCLUDE from cross-validation** and record in the Step 6.6 summary: `⚠ <reviewer> did not delegate after N attempts — NOT counted as external review (self-review on the session model / killed mid-flight)`.
- `BROKEN` reviewers → record: `⚠ <reviewer>: external engine produced no usable review (broken — ask the user to swap the model in config.yaml; agents never edit it)`.
- The builtin `claude` reviewer's findings always enter Step 6.1.

**Do NOT silently accept a FLIP as an external review.** A flipped wrapper is the session's model reviewing its own work; counting it as independent cross-validation is the exact failure this guard exists to prevent.

> **Concurrency note:** the guard picks the newest run dir for an engine/model created after `DISPATCH_EPOCH`. If two `/mesh-review` invocations run the same model concurrently, the window can overlap — rare in practice; run them sequentially if exact attribution matters.

### Step 6.1: Deduplicate, Verify, and Classify

1. **Deduplicate:** If multiple agents found the same issue (same file, same problem), merge into one entry. Note all agents that found it.

2. **Verify each issue against the codebase:** read the code at the reported location.
   - Is the issue real?
   - Is the severity correct (Critical / Important / Minor)?
   - Could this be a false positive or a misunderstanding of the codebase?

3. **Classify each issue into one of four buckets:**

   - **AUTO** — issue is valid AND only one reasonable fix exists. Test: "Would five competent engineers familiar with this codebase all do the same thing?" If yes → AUTO. Typical AUTO cases: missing error handling, wrong types, broken null check, dead code, typo, broken import, missing test for the just-added function, simple naming inconsistency.
   - **DISPUTED** — issue is valid BUT the fix has trade-offs / multiple reasonable approaches / scope decisions / architectural alternatives. Test: "Can I name at least two reasonable approaches where each has a real downside?" If yes → DISPUTED.
   - **DISMISSED** — false positive: reviewer misunderstood the codebase, the issue doesn't apply, or it was already addressed elsewhere.
   - **REPEAT** (only if reviewing iteratively) — same issue raised in a previous review run.

4. **Present a summary table:**

   | # | Суть проблемы | Файл:строка | Уровень | Кто нашёл | Класс |
   |---|---|---|---|---|---|
   | 1 | <одна строка> | `file:line` | Critical / Important / Minor | агенты | AUTO / DISPUTED / DISMISSED |

   Display counts:
   ```
   Классификация:
     AUTO (исправлю автоматически): A
     DISPUTED (обсудим по очереди): D
     DISMISSED (ложные/неприменимые):  X
   ```

   For each DISMISSED entry add one line of justification (so the user can override).

### Step 6.2: Apply All Auto-Fixes (Phase 1)

**In `default` mode:** apply all AUTO fixes immediately without asking.

**In interactive mode:** ask once before starting:
```
Найдено A явных исправлений. Применять автоматически?
```
On confirmation, apply all AUTO fixes.

For each fix, display one-line progress:
```
[i/A] Исправлено [file:line]: <краткое описание>
```

If `A == 0`, skip directly to Step 6.4.

### Step 6.3: Commit Auto-Fixes (Intermediate Commit)

**Right after Phase 1, commit the auto-fixes BEFORE the disputed phase starts.** This locks in the safe edits as a clean checkpoint.

1. Stage only the files modified in Step 6.2
2. Commit with message: `review: auto-fix valid issues from external review`
3. Do NOT push.

If no files were modified, skip this commit.

### Step 6.4: Discuss Disputed Issues One at a Time (Phase 2)

If `D == 0`, finish (jump to Step 6.5 with a brief summary).

Display intro:
```
Спорных вопросов: D. Обсуждаем по одному — для каждого приведу суть, анализ, варианты и обоснованную рекомендацию.
```

**For EACH disputed issue, sequentially (NOT batched, NOT in parallel):**

**6.4.a — Present structured analysis.** Do NOT use one-line bullets. Write enough so a reader who hasn't seen the review can follow:

```markdown
## [Спорное i/D] <Issue Title>

**Файл:** `path/to/file.ext:line`
**Уровень:** Critical / Important / Minor
**Нашли:** <agent(s) that raised it>

### Суть замечания
<2–4 sentences: what the reviewer actually said, where in the code, why they flagged it. Quote a short code fragment if it helps.>

### Анализ
<Why this might be a real problem (impact, risk, blast radius). Why it might NOT be a problem (false positive reasoning, acceptable trade-off, mitigation elsewhere). What codebase context / prior decisions are relevant.>

### Варианты решения

**Вариант A — <short name>**
- Что делаем: <concrete description — which files/functions change>
- Плюсы: <pros>
- Минусы: <cons>

**Вариант B — <short name>**
- Что делаем: <concrete description>
- Плюсы: <pros>
- Минусы: <cons>

[Вариант C if there's a third genuinely-different approach]

**Вариант "Не исправлять"** (если применимо)
- Обоснование: <why leaving as-is could be valid given the codebase>

### Рекомендация
**Вариант X** — <2–3 sentences why this is the best choice given the codebase, current architecture, and constraints>
```

**6.4.b — Decide whether to ask or auto-apply.** After writing the analysis, you'll often discover that only one option is actually adequate. Use this rule:

- **If only ONE option is genuinely adequate** (others have fatal flaws, contradict architecture, or are strictly inferior in this codebase): **do not ask the user.** Announce the decision and apply it:
  ```
  → Принимаю Вариант X. Остальные варианты отпадают: <one-line reason per dropped option>. Применяю правку.
  ```
  - Apply the Edit(s) to source files immediately
  - Continue to next disputed issue

- **If MULTIPLE options are genuinely reasonable**: ask the user via AskUserQuestion:
  ```
  Question: "<Issue title>. Какой вариант выбрать? (моя рекомендация: Вариант X)"
  Header: "Решение"
  Options:
    - "Вариант X — <one-line>"    ← put recommended first
    - "Вариант Y — <one-line>"
    - [Вариант Z if applicable]
    - "Не исправлять" (если применимо)
  ```
  - If user says "стоп" / "достаточно" — record current answer, defer remaining disputed issues, exit loop.
  - Apply the Edit(s) per user's choice.
  - Continue to next disputed issue.

**6.4.c — Process ONE disputed issue at a time.** Present analysis → decide/ask → apply → THEN move to the next. Never batch multiple disputed issues into a single message.

### Step 6.5: Commit Decisions

If Step 6.4 produced any code changes, commit them now:
```bash
git add <modified files>
git commit -m "review: apply decisions from external review discussion"
```

Do NOT push. If no code changes resulted from Step 6.4 (e.g. all disputed → "Не исправлять"), skip this commit.

### Step 6.6: Final Summary

Display a short summary:
```
Итог:
  Авто-исправлено:           A   (закоммичено: <hash if any>)
  Авто-применено по анализу: B1
  Обсуждено с пользователем: B2  (закоммичено: <hash if any>)
  Отклонено как ложные:      X
  Спорных отложено (стоп):   S
```

### Red Flags — STOP if you catch yourself doing this

| Anti-pattern | What to do instead |
|---|---|
| About to print a list of all disputed issues in one go | Stop. Take only the first. Write its full structured analysis. |
| Writing "вариант A / B / C" without pros, cons, and a recommendation | Stop. Add Плюсы / Минусы to each. Pick the best with 2–3 sentences why. |
| Asking the user a question while other disputed issues are still unprocessed in the same message | Stop. Resolve current → apply → THEN start next. |
| Asking the user to pick when only one option actually works | Stop. Announce the decision and apply it. Asking is noise. |
| Applying an auto-fix in the middle of disputed discussion | Stop. Auto-fixes must all happen in Step 6.2 and be committed in Step 6.3 before Step 6.4 begins. |
| Skipping the auto-fix commit ("I'll commit everything at the end") | Stop. The intermediate commit (Step 6.3) is the user's safe checkpoint. Mandatory when auto-fixes were applied. |
