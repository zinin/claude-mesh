---
name: mesh-review
description: Launch code review agents (built-in claude on N models, codex, gemini, ext-claude on N models) with selection UI and result deduplication.
---

# /mesh-review

Launch multiple external code review agents in parallel, collect and deduplicate results.

## Step 0: Check for `default` argument

If invoked as `/claude-mesh:mesh-review default` (Task 2.5: commands are namespaced; bare `/mesh-review` does not resolve on CC 2.1.156):
- Skip Steps 1-3 entirely.
- Read `defaults.code_review` via `"$LOADER" get-defaults code_review` and parse with jq (`.builtin`, `.claude_models`, `.models`, `.run_mode`); read the runtime block ONCE via `RUNTIME_JSON=$("$LOADER" get-runtime)` and pull BOTH fields from that single JSON — `DEFAULT_RUN_MODE=$(echo "$RUNTIME_JSON" | jq -r '.default_run_mode')` and `DISPATCH_MODEL=$(echo "$RUNTIME_JSON" | jq -r '.dispatch_model // empty')` — then `echo "DISPATCH_MODEL=$DISPATCH_MODEL"` to surface it (empty = inherit the session model on dispatch). (iter-3 CONCERN-1 — these come through the loader, not raw-yaml reads; `get-runtime` validates the runtime block, so a charset-invalid `dispatch_model` fast-fails here.)
- Read via the loader with the same rc=2/rc=1 distinction as Step 1 (iter-3 CRITICAL-3) — rc=2 ⇒ print the copy-config hint and exit cleanly; rc=1 ⇒ surface the validator stderr verbatim and stop — do NOT edit config.yaml (user-owned, agents never edit it).
- If `defaults.code_review` not configured → STOP with error:
  `defaults.code_review not configured in config.yaml. Use /claude-mesh:mesh-review without argument or add the preset.`
- Spawn all reviewers per preset:
  - `claude` in `defaults.code_review.builtin` → expand over `defaults.code_review.claude_models`:
    - list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`. This model **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
    <!-- SYNC: the fallback rule in the next bullet is ONE rule living in four places — this file's Step 2.4 ("Empty selection is not an error"), and `skills/mesh-design-review/SKILL.md` Step 5.1 / Step 5.2.5. Change all four or none. -->
    - list absent/empty → exactly **one** reviewer named `claude`, dispatched with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise with no `model:` at all (inherits the session model). This is the behaviour from before this feature and stays the default.
  - **Bind `SELECTED_CLAUDE_MODELS` to that resolved list here** (it is `defaults.code_review.claude_models`, or empty in the fallback case). Step 5a and Step 5b both dispatch "one Task per entry of `SELECTED_CLAUDE_MODELS`" **unconditionally** — the interactive path fills it in Step 2.4, and without this line the variable would simply be undefined in `default` mode. An undefined name in a shell script raises an error under `set -u`; in a prompt it raises nothing at all — the reader improvises, and `default` mode quietly dispatches one reviewer instead of N.
  - `codex` / `gemini` in `defaults.code_review.builtin` → spawn the corresponding agent.
  - For each model id in `defaults.code_review.models`, spawn `ext-claude-code-reviewer` with `MODEL=<id>`.
- Use `run_mode` from preset (default: `background`).
- Dispatch via the Step 5a (background) / Step 5b (team) mechanics per that `run_mode`, then go to **Step 6: Process Results**.

## Step 1: Read available reviewers from config

Use `config-loader.sh` instead of raw `yq` so validation runs the same way everywhere (CRITICAL-10):

```bash
# CLAUDE_PLUGIN_ROOT is EMPTY as a shell VARIABLE here (Task 2.5, CC 2.1.156), but the
# harness substitutes the placeholder into this command's TEXT — inside bash fences too —
# before the Bash call, so the line below arrives as a literal path naming the ACTIVE plugin
# copy, including a `--plugin-dir <repo>` dev load. (Which is why this comment spells the
# name without the braces: it would be substituted here too.) Fallback for harnesses that do
# not substitute: a VERSION-sorted glob — plain `find | head -1` is directory order and was
# observed picking a stale cached 0.4.0 over the installed 0.4.2.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found under ~/.claude/plugins (is claude-mesh installed?)" >&2; exit 1; }
# iter-3 CRITICAL-3: a bare $() swallows the loader exit code. Probe once with explicit rc
# capture so rc=2 (config.yaml not created yet — fresh install) is NOT misreported as
# rc=1 (config invalid). Distinct handling per design §6.6 / iter-2 CONCERN-11.
LOADER_ERR=$(mktemp)
HAS_CODEX=$("$LOADER" get-flag has_codex 2>"$LOADER_ERR"); LRC=$?
case "$LRC" in
  0) ;;
  # Name the dir the loader actually reads — a literal placeholder here would be substituted
  # by the harness and, under a --plugin-dir load, would point at the wrong data dir.
  2) echo "config.yaml ещё не создан. Скопируйте config.example.yaml в $("$LOADER" data-dir)/config.yaml, заполните токены и повторите /claude-mesh:mesh-review."; rm -f "$LOADER_ERR"; exit 0 ;;
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
# Claude-model catalog (Step 2.4 gate). rc-aware like the dispatch_model read above:
# these two subcommands validate the `claude:` section, so a malformed section must
# fast-fail here with the validator's own message rather than surface as an empty list.
CM_ERR=$(mktemp)
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (секция claude):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
CLAUDE_MODELS=$("$LOADER" list-claude-models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (claude.models):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
rm -f "$CM_ERR"
echo "HAS_CLAUDE_MODELS=$HAS_CLAUDE_MODELS"
echo "CLAUDE_MODELS=[$(echo "$CLAUDE_MODELS" | tr '\n' ' ')]"
```

rc=0 → proceed; rc=2 → fresh-install hint + clean exit; rc=1 → surface the validator stderr verbatim and stop — do NOT edit config.yaml (user-owned, agents never edit it) (iter-3 CRITICAL-3).

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

## Step 2.4: Claude-model selection

(No `Q1.x` label: this page runs *before* Step 2.5, so numbering it `Q1.6` ahead of Step 2.5's `Q1.5` reads as an ordering error. The step number alone is unambiguous.)

Runs ONLY when Q1 selected `claude` **and** `HAS_CLAUDE_MODELS=1`.

- `claude` NOT selected in Q1 → skip this step entirely; **no claude reviewer runs at all**, whatever the catalog holds. **Bind `SELECTED_CLAUDE_MODELS` to the empty list.**
- `claude` selected but `HAS_CLAUDE_MODELS=0` → skip this step; exactly **one** reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty). **Bind `SELECTED_CLAUDE_MODELS` to the empty list.**

Both bindings are mandatory, for the same reason Step 0 binds it in `default` mode: this step holds the ONLY other assignment to `SELECTED_CLAUDE_MODELS`, and Step 2.5 / Step 5a / Step 5b consume it unconditionally. An undefined name in a shell script raises an error under `set -u`; in a prompt it raises nothing at all — the reader improvises.

Build `CLAUDE_DEFAULT_IDS` from the preset — **rc-aware, and never through a pipe**:

```bash
# Same resolution as Step 1 — Q1's AskUserQuestion sits between that fence and this one, so
# this Bash call runs in a FRESH shell where $LOADER no longer exists. Without re-resolving
# it, `$("" get-defaults …)` fails and the `||` below misreports a valid config as invalid.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
# This is the FIRST get-defaults call on the interactive path, so it is the first thing
# that runs validate_defaults — which means a bad `claude_models` surfaces exactly here.
# `"$LOADER" get-defaults … | jq …` would take its status from jq and swallow the new
# fail-closed guard (rc=1) entirely, turning a hard error into an empty list.
CD_ERR=$(mktemp)
CR_DEFAULTS=$("$LOADER" get-defaults code_review 2>"$CD_ERR") \
    || { echo "config.yaml невалиден (defaults.code_review):" >&2; cat "$CD_ERR" >&2; rm -f "$CD_ERR"; exit 1; }
rm -f "$CD_ERR"
CLAUDE_DEFAULT_IDS=$(echo "$CR_DEFAULTS" | jq -r '.claude_models[]?')
echo "CLAUDE_DEFAULT_IDS=[$(echo "$CLAUDE_DEFAULT_IDS" | tr '\n' ' ')]"   # empty = no ★ markers below
```

For each chunk of 4 entries from `CLAUDE_MODELS` (in config order) — same pagination mechanics as Step 3, and the same reason for the ★ marker (AskUserQuestion has no `preSelected` API):

AskUserQuestion (multiSelect, max 4):
```
header: "Claude"
question: "На каких Claude-моделях запустить ревью? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in CLAUDE_DEFAULT_IDS
                 "★ <model> (recommended)"     if in CLAUDE_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections across pages into `SELECTED_CLAUDE_MODELS`.

<!-- SYNC: the fallback rule below is ONE rule living in four places — Step 0's "list absent/empty" bullet in this file, and `skills/mesh-design-review/SKILL.md` Step 5.1 / Step 5.2.5. Change all four or none. -->
**Empty selection is not an error.** It falls back to exactly one reviewer named `claude` on `DISPATCH_MODEL`/session model — identical to the `HAS_CLAUDE_MODELS=0` case. Do not re-ask and do not STOP.

Each selected model becomes an independent reviewer with the same diff and the same prompt — the point is model diversity, so never differentiate their prompts.

## Step 2.5 (Q1.5): Confirm reviewer-type selection

Mirror Step 3.5 (model confirmation): after Q1 (and Step 2.4, when it ran), show the full SELECTED_TYPES list (one per line) and ask. **Expand `claude` in that list into one bullet per entry of `SELECTED_CLAUDE_MODELS`** (`claude:opus`, `claude:fable`), or a single `claude (модель по умолчанию)` bullet in the fallback case — the user must see how many Claude reviewers they are about to pay for.

```
header: "Подтверди"
question: "Использовать эти reviewer-типы? <bullet list of SELECTED_TYPES>"
options:
  - "Да, использовать как выбрано"
  - "Нет, выбрать заново" — re-runs Q1 **and** Step 2.4, dropping the current SELECTED_CLAUDE_MODELS (cap 3 attempts; on the 4th attempt, surface STOP "пользователь не подтвердил выбор reviewer-типов")
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

**Before dispatch — stamp the delegation window (Step 6.0 guard needs it).** Via a Bash tool call, record `DISPATCH_EPOCH=$(date +%s)` and keep the number. Also remember the list of *wrapper* reviewers being dispatched as `engine:model` pairs: `codex`→`codex:-`, `gemini`→`gemini:-`, each selected model id→`ext-claude:<id>`. The builtin `claude` / `general-purpose` reviewers — there may now be several, one per Claude model — are NOT wrappers (they review inline by design). Exclude all of them from this list.

Launch all selected reviewers via Task tool, each `run_in_background: true`, in ONE message:

**Dispatch model:** if `DISPATCH_MODEL` (resolved in Step 0 for `default` mode, or Step 1 for interactive) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch below. If it is empty, omit `model:` so each reviewer inherits this session's model.

**Exception — claude reviewers with an explicit model.** When Step 2.4 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL`. Running the review on a chosen model is the whole point; letting `DISPATCH_MODEL` win here would collapse every claude reviewer onto one model and fake the independence. `DISPATCH_MODEL` still governs the codex / gemini / ext-claude wrappers, and the single fallback `claude` reviewer.

For each builtin reviewer:
- claude: `subagent_type: "general-purpose"` (built-in — NOT namespaced), prompt invokes `superpowers:requesting-code-review` skill. **One Task per entry of `SELECTED_CLAUDE_MODELS`**, each carrying `model: "<entry>"`; in the fallback case exactly one Task per the Dispatch-model rule above. All of them get the same prompt — only the model differs.
- codex: `subagent_type: "claude-mesh:codex-code-reviewer"`, prompt: `Review the changes for production readiness`
- gemini: `subagent_type: "claude-mesh:gemini-code-reviewer"`, prompt: `Review the changes for production readiness`

For each selected model id:
- `subagent_type: "claude-mesh:ext-claude-code-reviewer"`, prompt: `MODEL=<id> Review the changes for production readiness`

**CRITICAL — wrapper reviewers get a SHORT delegation prompt, NOT an inlined review task.** The codex / gemini / ext-claude reviewers are thin wrappers; their agent def forces them to invoke the matching `*-code-review` skill, and the SKILL resolves the diff and builds the review prompt itself. Pass each wrapper ONLY the short prompt above (prefixed with `MODEL=<id>` for ext-claude). Do **NOT** inline scope / diff / project invariants / focus areas into a wrapper's prompt: a detailed "review this yourself" prompt makes the wrapper self-review on its own Claude model instead of delegating to the external model — silently, with no `runs/<engine>/…` artifacts produced. Extra review context, if any, is forwarded by the agent to the skill's `CONTEXT` argument; it is never a license to review inline. (Only the builtin `claude` / `general-purpose` reviewers review directly.)

Display:
```
N code review агентов запущены параллельно в фоне:
  [list with descriptions]

Ожидаю результаты. Вы можете продолжать работу — я сообщу, когда ревью завершатся.
```

**Do NOT block.** Continue accepting user instructions while agents work.
When each agent completes, read its output. After all agents finish (or the user cancels some), proceed to **Step 6: Process Results**.

**CRITICAL — a wrapper's report does NOT arrive on its own: disk-watch the runs and ping idle wrappers.** A wrapper launches its external engine (watchdog + CLI) as a background Bash task, sends an interim status naming its run dir (`runs/<engine>/…`), ends its turn and goes idle. The harness delivers NO task-notification to an idle subagent when that background task exits (verified 2026-07-10: 0 notifications in 5/5 smoke transcripts; wrappers sat 8–12 min over a finished `output.txt` until explicitly pinged). Treat the interim status as the last thing a wrapper says unprompted. After dispatch:

1. **Capture each wrapper's run dir** from its interim status. Fallback when a status names none: the newest dir under `$DATA_DIR/runs/<engine>/[<provider>/<model>/]` created after `DISPATCH_EPOCH` — the same discovery `verify-delegation.sh` uses (locate `DATA_DIR` as in Step 6.0 point 1).
2. **Poll the disk via Bash — as a background Bash task**, so "Do NOT block" above stays true (a background watcher that exits on each state change re-invokes the orchestrator per event; a foreground poll loop would hold the session hostage). ~30–60 s cadence; bound the whole watch by `runtime.timeouts.global_sec` (read it via `"$LOADER" get-runtime | jq -r '.timeouts.global_sec'`, default 3600) plus a margin. A run is finalized when: root `output.txt` is present **and non-empty** (gemini-exec pre-creates a zero-byte `output.txt` at launch — an empty file is NOT finalization), or a `final` symlink exists, or the run's `watchdog.log` has a `cleanup` event.
3. **When a run is finalized but its wrapper has not delivered a report — SendMessage that wrapper:** `your external run finished — read its output.txt, extract the findings and send your report`. A pinged wrapper answers promptly. **Ping once per finalized run** — track who was already pinged and re-ping only if a wrapper is still silent after the next poll interval (~60–90 s), so a wrapper whose answer is already in flight is not spammed.
4. **Repeat** until every dispatched wrapper has reported or the watch budget expires; whatever is still silent lands in Step 6.0, which classifies it mechanically. Never interpret wrapper silence as "no findings".

The builtin `claude` reviewers are exempt: they review inline, create no `runs/<engine>/…` dir and complete on their own. Never wait for a run dir for them and never ping them.

## Step 5b: Team of reviewers mode

1. Generate the team name via a **Bash tool call** (which has a real `$$`, unlike the slash-command context which does not): `TEAM_NAME="code-review-$(date +%Y%m%d-%H%M%S)-$$"; DISPATCH_EPOCH=$(date +%s); echo "$TEAM_NAME $DISPATCH_EPOCH"`. Use the first value as the TeamCreate name (timestamp+PID suffix prevents collisions when two `/mesh-review` invocations run concurrently; on collision, regenerate). **Keep `DISPATCH_EPOCH`** and the same `engine:model` wrapper list as Step 5a (excluding the builtin `claude` reviewers — all of them) — Step 6.0's guard needs both. iter-3 QUESTION-1: do not paste a literal `<pid>` — there is no shell `$$` in the slash-command context itself.
2. Create one task per selected reviewer — with several Claude models selected that means one task per Claude model (`claude:opus`, `claude:fable`), not one shared `claude` task
3. Spawn teammates via Task tool with `team_name: "<the same unique name>"`, using the **same short per-reviewer prompts as Step 5a** (see the CRITICAL note there) — team mode does NOT change the prompt rules. Wrapper reviewers (codex / gemini / ext-claude) must still receive ONLY the short delegation prompt, never an inlined review task. The Step 5a **Dispatch model** rule *and its claude exception* also apply here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it — except claude teammates that carry an explicit model, which each use their own entry from `SELECTED_CLAUDE_MODELS`. When that list is empty, `DISPATCH_MODEL` governs the single fallback claude teammate like any other.
4. Wait for completion → Step 6. Teammate wrappers idle exactly like the Step 5a background ones — run the same disk-watch + ping loop from Step 5a to collect their reports
5. Shut down team

## Step 6: Process Results

Issues are processed in a **fixed four-phase order**. Do NOT interleave phases. Do NOT batch disputed discussions.

### Iron Rules

> Sync note: rules 3–8 are mirrored in `skills/mesh-design-review/SKILL.md` (Iron Rules / Step 12). When editing shared rule text, mirror the edit there (step numbers differ; `default`-mode clauses are mesh-review-only).

1. **Phase order is fixed:** dedupe + classify ALL issues → apply auto-fixes → commit auto-fixes → discuss disputed one-by-one → commit decisions.
2. **Auto-fixes are committed BEFORE disputed discussion starts.** The user gets a clean checkpoint with the safe edits before any debate.
3. **Disputed issues are processed ONE AT A TIME, in separate messages.** Never present a bulk list of disputed issues. Never dump all variants for all issues in one go.
4. **Every disputed issue gets a structured analysis** (Суть → Анализ → Варианты → Рекомендация). Bullet-only one-liners are forbidden.
5. **Always evaluate the variants you propose.** Each variant gets pros/cons; you explicitly recommend ONE with reasoning. Never list variants neutrally.
6. **If only one variant is genuinely adequate, do not ask the user.** Announce the decision, briefly say why the others fail, apply, move on.
7. **One disputed issue at a time.** Present its analysis; if one variant is adequate, apply it in the same message and move on; if a choice remains, the analysis is the FINAL message of the turn (no tool call) and you wait for the user's free-text answer, then apply and start the next. In `default` (non-interactive) mode never wait — record the issue as deferred per Step 6.4.b and continue. Never batch.
8. **When a choice remains, the analysis IS the question — never AskUserQuestion.** The structured write-up (variants with pros/cons + recommendation) is the turn-final message; the turn ends with no trailing tool call and the user answers in free text (in `default` mode nobody can answer — defer per Step 6.4.b). A trailing AskUserQuestion duplicates your write-up in its own modal UI and makes the harness drop the analysis — the user then sees only a bare modal. This is the regression this rule prevents.

### Step 6.0: Verify delegation (mechanical guard)

**Run this BEFORE Step 6.1.** Wrapper reviewers (codex / gemini / ext-claude) non-deterministically *flip*: they skip their `*-code-review` skill and self-review inline on this session's own model — a polished review that is **NOT** external cross-validation and leaves **no** `runs/<engine>/…` artifacts. The Step 5 prose forcing reduces this but does not eliminate it (the agent defs are already maxed and still flip). This step catches it **mechanically by inspecting on-disk artifacts** — do NOT trust the text a wrapper returned. The inverse failure also exists: a wrapper whose run is `REAL` on disk but which never sent a report is not a flip — it is idle (wrappers do not wake when their background run finishes); ping it per the Step 5a watch loop to collect the report before classifying.

The builtin `claude` / `general-purpose` reviewers (one per selected Claude model, or a single fallback one) are **skipped by the guard** — they review inline by design, so every one of them whose Task actually completed is accepted into Step 6.1. `verify-delegation.sh` is never invoked for them. (A claude reviewer whose Task errored is the exception — see the `FAILED` rule below.)

**1. Locate the loader, data dir, and guard:**
```bash
# Same resolution as Step 1 — the guard MUST come from the plugin copy that is actually
# running, otherwise a --plugin-dir dev load verifies with the installed cache's guard.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
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
- `BROKEN` (exit 4) — run dir but thinking-only / DSML grammar / `num_turns≤1` (the maximum across the stream's successful result events) → **DROP, do NOT retry** (the engine itself is broken).

**3. Show the delegation status table** so the user sees who really cross-validated:
```
| Reviewer            | Verdict | Action          |
|---------------------|---------|-----------------|
| claude:opus         | INLINE  | ✅ по построению |
| claude:fable        | INLINE  | ✅ по построению |
| ext-claude/zai/glm  | REAL    | ✅ kept          |
| codex               | FLIP    | ↻ re-dispatch   |
| ext-claude/ollama/… | BROKEN  | ✗ dropped       |
```

`INLINE` is a label **you** write, not a `verify-delegation.sh` verdict. Include one row per claude reviewer (a single row named `claude` in the fallback case) so the table is the complete roster of who actually reviewed — with several Claude models in play, a table that silently omits them understates the cross-validation.

**`INLINE` is for a claude reviewer that actually returned a review.** If its Task errored — the overwhelmingly likely cause being a `claude_models` entry this Claude Code build does not accept — give it a `FAILED` row instead and contribute nothing from it to Step 6.1:

| Reviewer     | Verdict | Action                          |
|--------------|---------|---------------------------------|
| claude:opus  | INLINE  | ✅ по построению                 |
| claude:opuss | FAILED  | ✗ dispatch failed — no findings |

Then continue with the remaining reviewers, per the existing rule "One agent fails, others succeed". Do **NOT** stop the whole review, and do **NOT** silently re-dispatch that reviewer on a different model: a failed dispatch is the *only* signal that a model name is wrong (design §13 — there is no way to verify after the fact which model a subagent really ran on), and quietly substituting another model destroys it. The user asked for N independent models and must be able to see they got N-1.

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
- The builtin `claude` reviewers' findings always enter Step 6.1 — every one of them whose Task completed, one entry per selected Claude model (or the single fallback reviewer). The ones marked `FAILED` above contribute nothing; they are never re-dispatched on a substitute model.

**Do NOT silently accept a FLIP as an external review.** A flipped wrapper is the session's model reviewing its own work; counting it as independent cross-validation is the exact failure this guard exists to prevent.

> **Concurrency note:** the guard picks the newest run dir for an engine/model created after `DISPATCH_EPOCH`. If two `/mesh-review` invocations run the same model concurrently, the window can overlap — rare in practice; run them sequentially if exact attribution matters.

### Step 6.1: Deduplicate, Verify, and Classify

1. **Deduplicate:** If multiple agents found the same issue (same file, same problem), merge into one entry. Note all agents that found it. Claude reviewers are attributed as `claude:<model>` (`claude:opus`, `claude:fable`); a single fallback reviewer is just `claude`. Two different Claude models reporting the same issue is corroboration — exactly like codex and ext-claude agreeing — so merge them into one entry that lists both, never collapse them into a nameless "claude".

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

**In interactive mode:** present the Step 6.1 classification table as its own turn-final message, then ask once — as free text, NOT via AskUserQuestion (a modal glued right after the table would drop it):
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

Display intro (interactive mode):
```
Спорных вопросов: D. Обсуждаем по одному — для каждого приведу суть, анализ, варианты и обоснованную рекомендацию.
```

In `default` mode display instead:
```
Спорных вопросов: D. Режим default: для каждого приведу анализ с рекомендацией; вопросы с несколькими равноценными вариантами будут отложены (см. итог).
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

- **If MULTIPLE options are genuinely reasonable — do NOT call AskUserQuestion or any other tool** (interactive mode; in `default` mode see the last bullet — defer, don't wait). The structured analysis you just wrote already IS the question. Make it the **final message of the turn** and end the turn on it, closing with an explicit free-text prompt:
  ```
  Выберите вариант: ответьте его буквой/названием или предложите свой.
  Моя рекомендация — Вариант X.
  ```
  - The turn ENDS here. Emit **no tool call** after the analysis. A trailing AskUserQuestion (whose own question/options UI duplicates your write-up) makes the harness treat the analysis as skippable preamble, and the user sees only a bare modal; a turn-final text message is always shown in full. This is the whole point of the fix — do not "help" by adding a modal.
  - **On the user's next message — check for stop FIRST.** If the answer contains "стоп" / "stop" / "достаточно": record the current issue as undecided (apply nothing), defer it and the remaining disputed issues, exit the loop. Otherwise apply the Edit(s) for the chosen variant, then move to the next disputed issue's analysis.
  - **If the turn is resumed by a background event** (e.g. a Step 5a watcher or task notification) rather than a user reply: handle the event, then end the turn again with a one-line reminder of the pending choice. A non-user event is never the user's answer.
  - **In `default` (non-interactive) mode there is nobody to ask.** Do NOT wait. Record the issue as *deferred* with your recommended variant noted, do NOT apply it, and continue to the next. The full analysis above stays in the run output as the decision record. Deferred disputed issues are surfaced in the Step 6.6 summary; the user re-runs interactively to decide them.

**6.4.c — Process ONE disputed issue at a time.** Present analysis → (auto-apply if one variant is adequate, otherwise end the turn and wait for the free-text choice; in `default` mode defer instead of waiting) → apply → THEN move to the next. Never batch multiple disputed issues into a single message.

### Step 6.5: Commit Decisions

If Step 6.4 produced any code changes, commit them now:
```bash
git add <modified files>
git commit -m "review: apply decisions from external review discussion"
```

Do NOT push. If no code changes resulted from Step 6.4 (e.g. all disputed → "Не исправлять"), skip this commit.

### Step 6.6: Final Summary

Track outcomes as a running tally while executing Step 6.4 (auto-applied after analysis / decided by the user / deferred on «стоп» / deferred in `default` mode) — the counts below come from that tally, not from reconstructing the transcript afterwards.

Display a short summary:
```
Итог:
  Авто-исправлено:           A   (закоммичено: <hash if any>)
  Авто-применено по анализу: B1
  Обсуждено с пользователем: B2  (закоммичено: <hash if any>)
  Отклонено как ложные:      X
  Отложено по «стоп»:        S1
  Отложено (default-режим):  S2
```

For every deferred issue (S1 + S2) add one line so the interactive re-run has an anchor:
```
  - <Issue title> (`file:line`) — рекомендация: Вариант X
```

### Red Flags — STOP if you catch yourself doing this

| Anti-pattern | What to do instead |
|---|---|
| About to print a list of all disputed issues in one go | Stop. Take only the first. Write its full structured analysis. |
| Writing "вариант A / B / C" without pros, cons, and a recommendation | Stop. Add Плюсы / Минусы to each. Pick the best with 2–3 sentences why. |
| Asking the user a question while other disputed issues are still unprocessed in the same message | Stop. Resolve current → apply → THEN start next. |
| Asking the user to pick when only one option actually works | Stop. Announce the decision and apply it. Asking is noise. |
| About to call AskUserQuestion for a disputed choice | Stop. The analysis + variants + recommendation are the turn's FINAL message; end the turn there and take the answer as free text. A modal would swallow the analysis (that is the regression). |
| Shrinking the analysis so a tool call can follow in the same turn | Stop. The analysis is the final message of the turn, as long as the issue needs. Don't trim it to precede a tool. |
| Applying an auto-fix in the middle of disputed discussion | Stop. Auto-fixes must all happen in Step 6.2 and be committed in Step 6.3 before Step 6.4 begins. |
| Skipping the auto-fix commit ("I'll commit everything at the end") | Stop. The intermediate commit (Step 6.3) is the user's safe checkpoint. Mandatory when auto-fixes were applied. |
