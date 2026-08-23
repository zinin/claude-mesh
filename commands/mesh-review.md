---
name: mesh-review
description: Launch code review agents (built-in claude on N models, codex, gemini, ext-claude on N models) with selection UI and result deduplication.
---

# /mesh-review

Launch multiple external code review agents in parallel, collect and deduplicate results.

## Arguments

- `default` — run the `defaults.code_review` preset instead of asking (Step 0).
- `BASE_BRANCH=<branch>` — the base the diff is taken against. Optional, and combinable with
  `default`. Bind it and carry it to every reviewer per the **Base branch** rule in Step 5a.
- `autodecide` — decide every disputed issue automatically instead of waiting for an answer: the
  same full analysis, plus an explicit self-check, then your own recommendation applied. Optional,
  orthogonal to `default` and `BASE_BRANCH=`, order-independent — `/claude-mesh:mesh-review default
  autodecide` is a fully unattended run, `/claude-mesh:mesh-review autodecide` picks reviewers
  interactively and only the disputed phase runs unattended. The protocol lives in
  `/claude-mesh:auto-decide-disputed`; Step 6.4 hands over to it.

Without `BASE_BRANCH` each review skill auto-detects the base itself — `git symbolic-ref
refs/remotes/origin/HEAD`, falling back to `master`. Passing it matters exactly where that guess
is wrong: in a repository whose default branch is `main`, or when reviewing against anything
other than the default branch, `merge-base` then finds nothing and the codex / gemini skills fall
back to `HEAD~1` — a single commit reviewed while the caller believes the whole branch was
covered, with nothing on screen saying otherwise.

## Step 0: Check the arguments

**Bind `AUTODECIDE` here**, before anything else: it is `true` when `autodecide` appears among the
arguments, `false` otherwise. Echo it (`AUTODECIDE=true|false`) so it is on screen. Its only
consumer is Step 6.4, twenty minutes and a background watch loop away; an unbound name raises no
error in a prompt — the reader simply improvises, and a run started with `autodecide` quietly
defers every disputed issue instead. Same reason `SELECTED_CLAUDE_MODELS` is bound below and
`BASE_BRANCH` is carried in Step 5a.

**If `default` is among the arguments** — in any order, alone or combined with `BASE_BRANCH=` and
`autodecide` (Task 2.5: commands are namespaced; bare `/mesh-review` does not resolve on CC 2.1.156):
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

**Base branch:** when the `BASE_BRANCH=<branch>` argument was given, prefix every WRAPPER prompt
below with `BASE_BRANCH=<branch> `. Each wrapper's skill reads that name and otherwise
auto-detects (`ext-claude-code-review` SKILL.md:20, `codex-code-review`
/ `gemini-code-review` :84), so without the prefix the reviewers silently examine a different
range than the caller asked for. This is a parameter exactly like `MODEL=<id>`, not review
content — the CRITICAL rule below still forbids inlining scope, diff or focus areas. The builtin
`claude` reviewers resolve the range themselves, so they get the base named in their prompt
sentence instead. Argument absent → change nothing; every skill keeps its own auto-detection.

For each builtin reviewer:
- claude: `subagent_type: "general-purpose"` (built-in — NOT namespaced), prompt invokes `superpowers:requesting-code-review` skill. **One Task per entry of `SELECTED_CLAUDE_MODELS`**, each carrying `model: "<entry>"`; in the fallback case exactly one Task per the Dispatch-model rule above. All of them get the same prompt — only the model differs. With `BASE_BRANCH` given, the prompt names it: `… review the changes on this branch against base <branch> …`.
- codex: `subagent_type: "claude-mesh:codex-code-reviewer"`, prompt: `Review the changes for production readiness` (with the `BASE_BRANCH=<branch> ` prefix when the argument was given)
- gemini: `subagent_type: "claude-mesh:gemini-code-reviewer"`, prompt: `Review the changes for production readiness` (same prefix rule)

For each selected model id:
- `subagent_type: "claude-mesh:ext-claude-code-reviewer"`, prompt: `MODEL=<id> Review the changes for production readiness` — with the base branch it becomes `BASE_BRANCH=<branch> MODEL=<id> Review the changes for production readiness`

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
2. **Watch the disk with `shared/watch-runs.sh`, launched as a background Bash task**, so "Do NOT block" above stays true — a foreground poll loop would hold the session hostage, and a background watcher that returns on each event re-invokes you per event. **Do NOT hand-roll a poller.** The improvised one exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

   ```bash
   LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
   [ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
   [ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
   WATCH="$(dirname "$LOADER")/watch-runs.sh"
   [ -x "$WATCH" ] || { echo "watch-runs.sh missing or not executable at $WATCH" >&2; exit 1; }
   "$WATCH" --since <DISPATCH_EPOCH> codex ext-claude/zai/glm ext-claude/ollama/kimi
   ```

   Substitute the **actual** `DISPATCH_EPOCH` number you stamped in Step 5. A shell variable does not survive from one Bash call to the next, and an unset name in a prompt raises nothing at all — the script rejects an implausible `--since` rather than silently watching a window that ended in 1970.

   The arguments after the options are a **roster** of `engine[/provider/model]` — the subpath under `runs/` — not run directories. A wrapper whose run dies and is re-run creates a new run dir, so the watcher re-resolves the newest one at/after `--since` on every tick and follows it by itself. Pass only the wrappers you are still waiting for (point 5).

   | Status | Meaning |
   |---|---|
   | `DONE` | finished, and there is a non-empty `output.txt` to read |
   | `FAILED` | finished without usable output — the watchdog exited non-zero, or nothing appeared in the minute after the run stopped writing |
   | `RUN` | still producing, or still starting up |
   | `SILENT` | nothing written to any stream for longer than the stall threshold |
   | `MISSING` | no run dir for this wrapper at all |

   The reason line names what moved — `CHANGED ext-claude/ollama/kimi RUN→SILENT`. Terminal verdicts are `ALL_DONE`, `SETTLED` (nothing left running) and `DEADLINE` (the watch budget expired); those three end the loop. A healthy `--once` prints `SNAPSHOT`. **Every verdict exits 0.** A non-zero exit means the watcher itself is broken, never that a wrapper died.

   A `MISSING` row that ends `N run(s) in this window belong to another session` is the one status here that is **not** about the wrapper. Run dirs carry the id of the session that dispatched them, and this session's id no longer matches — a resumed or forked session, not a death. Do not route it to Step 6.0 as a failure; say so and, if the runs are in fact this orchestration's, finish the watch by reading them directly.
3. **When the watcher reports a run `DONE` but its wrapper has not delivered a report — SendMessage that wrapper:** `your external run finished — read its output.txt, extract the findings and send your report`. A pinged wrapper answers promptly. **Ping once per `DONE` run** — track who was already pinged and re-ping only if a wrapper is still silent after the next poll interval (~60–90 s), so a wrapper whose answer is already in flight is not spammed.

   **After a second unanswered ping, read the run yourself and stop waiting.** The file is `<run dir>/output.txt`, or `<run dir>/final/output.txt` when the root one is empty — the same file the wrapper would have read, and the same one `verify-delegation.sh` judges. Take the findings from it and attribute them to that reviewer exactly as if it had reported. Read `output.txt`, never `report.md`: the latter is the whole run rendered by `generate-md.sh` and runs to 137–250 KB in practice, while `output.txt` is the review itself (11 KB for a large one).

   A wrapper's report is a delivery mechanism, not the result, and delivery is the part that fails. The harness sends an idle subagent no notification when its background task exits, and a composed report can be lost in transit on top of that: on 2026-08-05 an `alibaba/qwen` run finished with `num_turns=22` and an 11428-byte review on disk while the orchestration recorded that model as having produced nothing across five runs and dropped it from the cross-validation. **Never record a reviewer as silent, dead or empty-handed while `verify-delegation.sh` scores its run `REAL`** — that verdict is precisely the statement that the file holds an agentic review, and it is made from the disk, which no delivery can lose.
4. **A `SILENT`, `FAILED` or `MISSING` run is dead — send it to Step 6.0**, which classifies it mechanically, rather than waiting out the budget over a run that will never change. Do **not** re-dispatch it here: `watchdog.sh` already restarts the CLI up to twice inside the run, and Step 6.0 owns the wrapper-level retry via `max_redispatch`. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact a wrapper died, and the two call for different actions. A **silent wrapper over a finished run is not one of these three** — that is point 3's case, and its review is on disk waiting to be read.
5. **Pass only the wrappers you are still waiting for.** The watcher assumes every roster entry is running, so an entry you have already handled comes straight back as news. If the watcher returns twice in a row with the same reason, you did not narrow the roster. Stop watching once the roster would be empty.
6. **Repeat** until every dispatched wrapper has reported, is dead, or the watch budget expires; whatever is still silent lands in Step 6.0. Never interpret wrapper silence as "no findings".

**Anything a wrapper says while the watch is running is a free liveness check.** Before replying to an interim status, a progress note or a question, run one `"$WATCH" --since <the same epoch> --once <current roster>` — re-resolve `$WATCH` with the same lines as in point 2 first; it does not survive between Bash calls — and act on the rows. On 2026-07-26 six such messages arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command. `--once` reports `CHANGED` when something has already died, so the answer names the death rather than handing you a table to compare by eye.

> Sync note: points 1–6 are mirrored in `skills/mesh-design-review/SKILL.md` (Step 6) — in substance, not byte for byte, and four things are not mirrored at all. Work out which kind you are touching before copying anything across.
>
> **Mirror the substance.** The status table, the roster explanation, the `--since` warning, the "every verdict exits 0" contract, point 5 and the `--once` liveness rule just above this note say the same thing in both files and must go on saying it: when you change what one of them says, change the other. Do not paste bytes — each copy is worded to its own file (`wrapper` in `/mesh-review`, `executor` in design review), names its own cross-references (where `DISPATCH_EPOCH` was stamped; the "Do NOT block" instruction only `/mesh-review` has) and describes its own retry model (a run re-dispatched by `/mesh-review` versus one that self-retries under design review).
>
> **Never mirror these four.** (1) Points 1–2 resolve paths differently by construction: `/mesh-review` reads `$DATA_DIR` and finds its loader through `${CLAUDE_PLUGIN_ROOT}` with a version-sorted `find` fallback, because the harness substitutes that placeholder into a command file's text; a skill gets no such substitution, so design review starts from the base path Claude Code prints at load (`SKILL_BASE`) and asks the loader for `data-dir`. Copying either block across breaks path resolution outright. (2) Point 3: design review runs the `verify-delegation.sh` content gate inline before pinging, while `/mesh-review` pings on `DONE` and only reaches the same check later, in its own mechanical classification step. (3) Point 4: a dead run goes to Error Handling in design review, whose only retry layer is `watchdog.sh` inside the run, and to Step 6.0 in `/mesh-review`, which classifies it mechanically and owns a second, wrapper-level retry layer; the retry sentence that closes the point differs with the routing. (4) Point 6's closing clause: `/mesh-review` hands whatever is still silent to that same step, while design review instead records that the loop covers the codex / gemini / ext-claude executors only.
>
> Do not restore parity by copying the gate or the routing across, and do not delete either: each file checks a finished run's content exactly once and routes a dead run exactly once, and a copy of either in the other file would be the weaker of the two.

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
7. **One disputed issue at a time.** Present its analysis; if one variant is adequate, apply it in the same message and move on; if a choice remains, the analysis is the FINAL message of the turn (no tool call) and you wait for the user's free-text answer, then apply and start the next. In `default` (non-interactive) mode never wait — record the issue as deferred per Step 6.4.b and continue. In `autodecide` mode neither wait nor defer: follow `/claude-mesh:auto-decide-disputed`, which applies your own recommendation after an explicit self-check. Never batch.
8. **When a choice remains, the analysis IS the question — never AskUserQuestion.** The structured write-up (variants with pros/cons + recommendation) is the turn-final message; the turn ends with no trailing tool call and the user answers in free text (in `default` mode nobody can answer — defer per Step 6.4.b; in `autodecide` mode the analysis is not a question at all — see Step 6.4). A trailing AskUserQuestion duplicates your write-up in its own modal UI and makes the harness drop the analysis — the user then sees only a bare modal. This is the regression this rule prevents.

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
  bash "$VERIFY" "$eng" "$mdl" <DISPATCH_EPOCH> "$DATA_DIR"   # prints REAL|FLIP|STALLED|BROKEN|DEGRADED|KILLED; reason on stderr
done
```

Substitute the **actual** `DISPATCH_EPOCH` number — the one stamped in Step 5, or the fresh one from step 4a on a re-dispatch round — exactly as in the Step 5a watcher call. A shell variable does not survive from one Bash call to the next, and `DISPATCH_EPOCH` was stamped in a different one; left as `"$DISPATCH_EPOCH"` it expands to nothing and the guard prints its usage line and exits 1 for every reviewer, which is not a verdict at all.
Verdicts:
- `REAL` (exit 0) — delegated, real review → **keep** for Step 6.1.
- `FLIP` (exit 3) — no run dir → self-reviewed on the session model → **re-dispatch**. One `FLIP` reason reads differently and is not about the wrapper: `N run dir(s) in the dispatch window belong to another session`. The runs are there, but they carry an id this session does not have — either this session was resumed or forked since Step 5, or the wrapper really did flip and another orchestration's runs happen to sit in the same window on the same model. The guard cannot tell those two apart and deliberately does not guess. Re-dispatch anyway: a fresh run is stamped with this session's id and verifies honestly, which is the only way back to a checkable answer. What changes is how it is reported if it does not recover — see step 5.
- `STALLED` (exit 2) — run dir but died mid-flight / delivered nothing usable → **re-dispatch** (retry helps). For ext-claude that is a missing result event; for codex and gemini, a stream with no `turn.completed` / `result` event, or a non-zero watchdog exit that is not a signal (see `KILLED`). It also covers a run that finished healthily and delivered a **notice instead of a review** — `output.txt` under 400 non-space bytes. That is not hypothetical: on 2026-08-05 `deepseek/v4-pro` twice returned "Ревью запущено … уведомлю вас по завершении" after 24 and 17 tool calls, and the older gate scored both `REAL`, so `/mesh-review` counted a model that said nothing among its cross-validating reviewers. Measured across 624 archived runs the floor moves exactly those two out of `REAL`, plus five that were `DEGRADED` on the same kind of text (an "approve this command" note, leaked tool grammar, a summary of a review that is not in the file).
- `KILLED` (exit 6) — a review **lost** to a signal from OUTSIDE the run: the watchdog's last `cleanup` carries 143 (SIGTERM) or 130 (SIGINT), no `watchdog.exit` sits beside it, so nothing inside the run chose to stop — and what the run left behind is not a usable review → **EXCLUDE, do NOT re-dispatch.** The verdict weighs the cost, not the signal: a run that had already delivered a real review before something killed its tail scores `REAL` and keeps its findings, on every engine. So `KILLED` never means "there may be findings on disk you are discarding" — there are none worth having, which is why there is nothing to ping for. The review itself was healthy right up to the signal; what failed is the launch, and an identical launch is killed identically. The usual sender is the harness capping a *foreground* Bash call at `BASH_MAX_TIMEOUT_MS` (ten minutes by default) and SIGTERMing it there — which is why the exec skills launch the engine as a background task. On 2026-08-05 this verdict did not exist, the five affected runs scored `STALLED`, and three re-dispatches died exactly as the runs they replaced. If the run dirs show this repeatedly, the wrapper is launching in the foreground and the fix is in the skill, not in another round.
- `BROKEN` (exit 4) — run dir but the engine finished without doing any work → **DROP, do NOT retry** (the engine itself is broken). For ext-claude that is thinking-only / DSML grammar / `num_turns≤1` (the maximum across the stream's successful result events); for codex and gemini, a completed turn that ran no tool at all — narration rather than a review.
- `DEGRADED` (exit 5, ext-claude only) — a real, agentic review, but the CLI refused `N` of its tool calls: the reviewer never got outside the directory it was launched in, so it reviewed without the sibling sources it tried to open → **KEEP for Step 6.1, do NOT re-dispatch.** The findings are genuine; what is missing is everything the reviewer could not read, so treat any claim about code outside the project dir as a guess rather than a finding. A retry re-runs the same invocation and is denied identically, and the remedy is not an agent's to apply: the ext-claude run needs `--permission-mode bypassPermissions`, and an *installed* plugin only picks that up through a release — so on any copy predating that release this verdict is the expected outcome, not an anomaly. The reason line names the denial count and which tools were refused (`Read×2, Bash×1`), which says whether the reviewer lost source files, searches, or both. Before this verdict existed such a run scored `REAL`: every liveness signal (finalized, `is_error:false`, `num_turns` well above 1, non-empty output) is healthy on a reviewer that read nothing, which is why it needed a check of its own.

**3. Show the delegation status table** so the user sees who really cross-validated:
```
| Reviewer            | Verdict | Action          |
|---------------------|---------|-----------------|
| claude:opus         | INLINE  | ✅ по построению |
| claude:fable        | INLINE  | ✅ по построению |
| ext-claude/zai/glm  | REAL    | ✅ kept          |
| codex               | FLIP    | ↻ re-dispatch   |
| ext-claude/ollama/… | BROKEN  | ✗ dropped       |
| ext-claude/deepseek/… | DEGRADED | ⚠ kept — 14 denials, partial context |
| ext-claude/alibaba/… | KILLED  | ✗ excluded — killed from outside at 600s |
```

A `DEGRADED` row must say **how many** tool calls were denied — the count is the whole content of the verdict, and a row that hides it reads like a `REAL` with decoration.

`INLINE` is a label **you** write, not a `verify-delegation.sh` verdict. Include one row per claude reviewer (a single row named `claude` in the fallback case) so the table is the complete roster of who actually reviewed — with several Claude models in play, a table that silently omits them understates the cross-validation.

**`INLINE` is for a claude reviewer that actually returned a review.** If its Task errored — the overwhelmingly likely cause being a `claude_models` entry this Claude Code build does not accept — give it a `FAILED` row instead and contribute nothing from it to Step 6.1:

| Reviewer     | Verdict | Action                          |
|--------------|---------|---------------------------------|
| claude:opus  | INLINE  | ✅ по построению                 |
| claude:opuss | FAILED  | ✗ dispatch failed — no findings |

Then continue with the remaining reviewers, per the existing rule "One agent fails, others succeed". Do **NOT** stop the whole review, and do **NOT** silently re-dispatch that reviewer on a different model: a failed dispatch is the *only* signal that a model name is wrong (design §13 — there is no way to verify after the fact which model a subagent really ran on), and quietly substituting another model destroys it. The user asked for N independent models and must be able to see they got N-1.

**4. Auto-redispatch loop (max `N` rounds; `N` = `runtime.max_redispatch`, default 1):**

`PROBLEMS` = reviewers whose verdict is `FLIP` or `STALLED` — **not** `BROKEN`, **not** `DEGRADED`, **not** `KILLED`. All three are already final: a broken engine repeats itself, a denied reviewer is denied identically on the next run because nothing about the invocation changed, and a killed run is killed again by whatever sent the signal. While `PROBLEMS` is non-empty AND rounds-done < `N`:
  - **a. Stamp a fresh window** via Bash: `DISPATCH_EPOCH=$(date +%s)` — so the guard inspects the NEW run, not the old failed one.
  - **b. Re-dispatch ONLY the `PROBLEMS` reviewers** with the EXACT same short delegation prompt as Step 5a (`MODEL=<id> Review the changes for production readiness` for ext-claude; `Review the changes for production readiness` for codex/gemini) — including the `BASE_BRANCH=<branch> ` prefix when the argument was given, since a retry that drops it would review a different range than the attempt it replaces — same `subagent_type`, same run mode. Apply the Step 5a **Dispatch model** rule on re-dispatch too (add `model: "<DISPATCH_MODEL>"` when non-empty, else omit). Then **run the same disk-watch + ping loop as Step 5a** (its points 1–6), with a roster of only these reviewers and the fresh `DISPATCH_EPOCH` from step a, and collect their reports exactly as there. **Do not treat the Task returning as the run finishing.** A wrapper launches its engine as a background Bash task, names the run dir and ends its turn, so its Task completes within seconds of the launch — long before there is anything on disk. Without the watch loop, step c inspects a run dir that has barely been created, scores every re-dispatch `STALLED` (no `final`, no `output.txt`) or `FLIP` (no dir yet), and the whole `max_redispatch` budget is spent without one run ever finishing.
  - **c. Re-run the guard** (step 2) for those reviewers with the new `DISPATCH_EPOCH`; update their verdicts.
  - **d.** rounds-done++.

`BROKEN` reviewers are **never** re-dispatched — retry is futile (the fix is the USER swapping the model in `config.yaml` — agents never edit it — not retrying). `KILLED` reviewers are never re-dispatched either, for the opposite reason: the engine was fine and the launch was not, so the next identical launch dies the same way.

**5. Finalize:**
- `REAL` reviewers → their reviews enter Step 6.1 (dedupe/classify) as normal.
- Reviewers still `FLIP`/`STALLED` after `N` rounds → **EXCLUDE from cross-validation** and record in the Step 6.6 summary: `⚠ <reviewer> did not delegate after N attempts — NOT counted as external review (self-review on the session model / killed mid-flight)`.
- A reviewer whose final `FLIP` names a **session mismatch** is excluded on the same terms — a run this session cannot verify never counts as external cross-validation — but it is recorded for what was actually observed, not as a flip: `⚠ <reviewer>: N run dir(s) in the window carry another session's id — NOT counted as external review (this session's id does not match the one that dispatched them)`. "Did not delegate" would be a false statement about that reviewer: the run dirs exist, and if the id moved under the orchestration they hold its finished work.
- `BROKEN` reviewers → record: `⚠ <reviewer>: external engine produced no usable review (broken — ask the user to swap the model in config.yaml; agents never edit it)`.
- `KILLED` reviewers → record what actually happened, never "did not delegate": `⚠ <reviewer>: run terminated from outside after Ns (SIGTERM, no watchdog.exit) — NOT counted as external review; the review was alive when it was killed, so this is a launch problem, not a model problem`. Name the lifetime — a cluster of deaths at the same round number is the signature of a foreground Bash call hitting `BASH_MAX_TIMEOUT_MS`, and it tells the user the one thing that would fix it. The guard computes it from `watchdog.log` and puts it in the reason line as `after 601s`: copy that number, never estimate one. If the reason carries no lifetime clause the stamps were unparsable — say so instead of inventing a figure.
- The builtin `claude` reviewers' findings always enter Step 6.1 — every one of them whose Task completed, one entry per selected Claude model (or the single fallback reviewer). The ones marked `FAILED` above contribute nothing; they are never re-dispatched on a substitute model.

**Do NOT silently accept a FLIP as an external review.** A flipped wrapper is the session's model reviewing its own work; counting it as independent cross-validation is the exact failure this guard exists to prevent.

> **Concurrency note:** the guard picks the newest run dir for an engine/model created at/after `DISPATCH_EPOCH` **that carries this session's id** — the `*-exec` skills stamp `$CLAUDE_CODE_SESSION_ID` into `<run dir>/.session_id`, and the guard walks past anyone else's. Two `/mesh-review` invocations in two different Claude Code sessions therefore no longer see each other's runs, even on the same model and the same shared data dir. Two invocations *inside one session* still share an identity and can still overlap on a model; run those sequentially if exact attribution matters. Runs left by an older plugin version carry no stamp and stay eligible on purpose — reporting a live unstamped run as "never delegated" would be worse than the collision.

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

**Autodecide mode.** If `AUTODECIDE` is true (Step 0) **or the user has already invoked**
`/claude-mesh:auto-decide-disputed` in this session — its state S3 arms the mode without any
argument being passed — do NOT run the interactive loop below: invoke
`/claude-mesh:auto-decide-disputed` through the Skill tool now and follow it for the whole disputed
queue.

It replaces **the whole of 6.4.b — both branches**: the single-adequate-variant branch as much as
the waiting one, plus the `default`-mode deferral. Every remaining disputed issue goes through the
command's Step 2, so every one of them gets `Проверка решения`, a confidence flag and its own
commit. In this mode 6.4.b's first branch produces nothing and the `Авто-применено по анализу: B1`
counter stays at zero — an issue counted as `B1` here is an edit nobody committed, because Step 6.5
is skipped below. 6.4.a's analysis format still applies unchanged, and the command points back to
it. The intro line for this mode is printed by the command, not here. Do not paste any part of its
protocol here.

**If the command does not resolve** — an older plugin copy in this environment — say so in one line
and fall back to the interactive loop below (or, with `default`, to its deferral bullet). Never
improvise the protocol from memory: Iron Rules 7–8 stand until the command that overrides them is
actually loaded.

Display intro (interactive mode; not when `autodecide` is active — then the command prints its own
line):
```
Спорных вопросов: D. Обсуждаем по одному — для каждого приведу суть, анализ, варианты и обоснованную рекомендацию.
```

In `default` mode display instead (not when `autodecide` is also active — then the command prints its own line):
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
    **Unless `autodecide` is active** — then this `default`-mode bullet does not apply at all:
    decide the issue per `/claude-mesh:auto-decide-disputed` instead of deferring it. `default` and
    `autodecide` are orthogonal, and when both are set, autodecide wins here.

**6.4.c — Process ONE disputed issue at a time.** Present analysis → (auto-apply if one variant is adequate, otherwise end the turn and wait for the free-text choice; in `default` mode defer instead of waiting; in `autodecide` mode neither — the command decides and applies) → apply → THEN move to the next. Never batch multiple disputed issues into a single message.

### Step 6.5: Commit Decisions

If Step 6.4 produced any code changes, commit them now:
```bash
git add <modified files>
git commit -m "review: apply decisions from external review discussion"
```

Do NOT push. If no code changes resulted from Step 6.4 (e.g. all disputed → "Не исправлять"), skip this commit.

**In `autodecide` mode this step is skipped:** every decision was already committed on its own, one
commit per decision, so there is nothing left to stage. Edits produced by the disputed phase before
the mode started — whichever way they were decided — are committed by the command's own "settle the
tree" rule at the start of its run.

**Skip it only if the tree is in fact clean of disputed-phase edits.** Two paths leave edits behind
that no commit of the command's covers: «стоп» arriving before its first decision, so settle-the-
tree never ran; and the user cutting in mid-run to choose a variant themselves. If `git status`
shows such edits, run this step normally instead of skipping it.

### Step 6.6: Final Summary

Track outcomes as a running tally while executing Step 6.4 (auto-applied after analysis / decided by the user / decided in `autodecide` / deferred on «стоп» / deferred in `default` mode) — the counts below come from that tally, not from reconstructing the transcript afterwards.

Display a short summary:
```
Итог:
  Авто-исправлено:           A   (закоммичено: <hash if any>)
  Авто-применено по анализу: B1
  Обсуждено с пользователем: B2  (закоммичено: <hash if any>)
  Решено автоматически:      C   (autodecide, по коммиту на решение; «не исправлять» — без коммита)
    из них под вопросом:     C?
  Отклонено как ложные:      X
  Отложено по «стоп»:        S1
  Отложено (default-режим):  S2
```

For every deferred issue (S1 + S2) add one line so the interactive re-run has an anchor:
```
  - <Issue title> (`file:line`) — рекомендация: Вариант X
```

For every `под вопросом` decision (C?) add one line, so the user knows exactly what to re-check:
```
  - <Issue title> (`file:line`) — Вариант X, <hash> — не хватило: <what was missing>
```

`<hash>` is `—` when that decision was «не исправлять»: 2.e of the command makes it a full outcome
with no edit and no commit, and it can still be flagged `под вопросом` by test (b). Never invent a
hash, and never drop the line for want of one — the design-review side spells the same rule as
`commit: "—"`.

When at least one auto-decision produced a commit, close the summary with:
```
Все авто-решения: git log --grep=auto-decide-disputed --oneline
```

### Red Flags — STOP if you catch yourself doing this

| Anti-pattern | What to do instead |
|---|---|
| About to print a list of all disputed issues in one go | Stop. Take only the first. Write its full structured analysis. |
| Writing "вариант A / B / C" without pros, cons, and a recommendation | Stop. Add Плюсы / Минусы to each. Pick the best with 2–3 sentences why. |
| Asking the user a question while other disputed issues are still unprocessed in the same message | Stop. Resolve current → apply → THEN start next. |
| Asking the user to pick when only one option actually works | Stop. Announce the decision and apply it. Asking is noise. |
| About to call AskUserQuestion for a disputed choice | Stop. The analysis + variants + recommendation are the turn's FINAL message; end the turn there and take the answer as free text. A modal would swallow the analysis (that is the regression). |
| Shrinking the analysis so a tool call can follow in the same turn (interactive and `default` modes) | Stop. The analysis is the final message of the turn, as long as the issue needs. Don't trim it to precede a tool. In `autodecide` this row does not apply — there the analysis is *meant* to be followed by the edit and the commit in the same turn, at full length; see the row below. |
| Applying an auto-fix in the middle of disputed discussion | Stop. Auto-fixes must all happen in Step 6.2 and be committed in Step 6.3 before Step 6.4 begins. |
| Skipping the auto-fix commit ("I'll commit everything at the end") | Stop. The intermediate commit (Step 6.3) is the user's safe checkpoint. Mandatory when auto-fixes were applied. |
| In `autodecide` mode, ending the turn to wait for the user's answer | Stop. That mode exists precisely to not wait: write the analysis, add `Проверка решения`, decide, commit, continue. |
