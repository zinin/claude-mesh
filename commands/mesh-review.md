---
name: mesh-review
description: Launch code review agents (built-in claude on N models, codex, gemini, grok on N models, ext-claude on N models) with selection UI and result deduplication.
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
other than the default branch, `merge-base` then finds nothing and the codex / gemini / grok
skills fall back to `HEAD~1` — a single commit reviewed while the caller believes the whole
branch was covered, with nothing on screen saying otherwise.

## Step 0: Check the arguments

**Bind `AUTODECIDE` here**, before anything else: it is `true` when `autodecide` appears among the
arguments, `false` otherwise. Echo it (`AUTODECIDE=true|false`) so it is on screen. Its only
consumer is Step 6.4, twenty minutes and a background watch loop away; an unbound name raises no
error in a prompt — the reader simply improvises, and a run started with `autodecide` quietly
defers every disputed issue instead. Same reason `SELECTED_CLAUDE_MODELS` is bound below and
`BASE_BRANCH` is carried in Step 5a.

**Detect HOST here**, after AUTODECIDE, before the `default` branch: `HOST=grok` if this session
has a `spawn_subagent` tool, else `HOST=claude-code`. Presence of `spawn_subagent` is the test.
Do not require `Task` to be missing: a future Grok build that also exposes `Task` would otherwise
be classified as Claude Code. Echo it (`HOST=grok|claude-code`) so it is on screen. `$HOST` is
prompt state, not a shell variable across Bash calls — when a later fence branches on host,
substitute the literal `grok` or `claude-code` you echoed.

**If `default` is among the arguments** — in any order, alone or combined with `BASE_BRANCH=` and
`autodecide` (Task 2.5: commands are namespaced; bare `/mesh-review` does not resolve on CC 2.1.156):
- Skip Steps 1-3 entirely.
- Read `defaults.code_review` via `"$LOADER" get-defaults code_review` and parse with jq (`.builtin`, `.claude_models`, `.native_models`, `.grok_models`, `.models`, `.run_mode`, `.grok_degraded`); read the runtime block ONCE via `RUNTIME_JSON=$("$LOADER" get-runtime)` and pull BOTH fields from that single JSON — `DEFAULT_RUN_MODE=$(echo "$RUNTIME_JSON" | jq -r '.default_run_mode')` and `DISPATCH_MODEL=$(echo "$RUNTIME_JSON" | jq -r '.dispatch_model // empty')` — then `echo "DISPATCH_MODEL=$DISPATCH_MODEL"` to surface it (empty = inherit the session model on dispatch). (iter-3 CONCERN-1 — these come through the loader, not raw-yaml reads; `get-runtime` validates the runtime block, so a charset-invalid `dispatch_model` fast-fails here.)
- Read via the loader with the same rc=2/rc=1 distinction as Step 1 (iter-3 CRITICAL-3) — rc=2 ⇒ print the copy-config hint and exit cleanly; rc=1 ⇒ surface the validator stderr verbatim and stop — do NOT edit config.yaml (user-owned, agents never edit it).
- If `defaults.code_review` not configured → STOP with error:
  `defaults.code_review not configured in config.yaml. Use /claude-mesh:mesh-review without argument or add the preset.`
- Spawn all reviewers per preset:
  - `claude` in `defaults.code_review.builtin` → expand over `defaults.code_review.claude_models`:
    - HOST=claude-code, list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`. This model **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
    <!-- SYNC: the fallback rule in the next bullet is ONE rule living in four places — this file's Step 2.4 ("Empty selection is not an error"), and `skills/mesh-design-review/SKILL.md` Step 5.1 / Step 5.2.5. Change all four or none. -->
    - HOST=claude-code, list absent/empty → exactly **one** reviewer named `claude`, dispatched with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise with no `model:` at all (inherits the session model). This is the behaviour from before this feature and stays the default.
    - HOST=grok: one `claude-mesh:claude-code-reviewer` per entry of `claude_models` with `MODEL=` per alias (never `general-purpose` with `model: opus`). Empty/absent list → one reviewer, **no MODEL line** (CLI default, `claude -p` without `-m`). Do not pass spawn `model: opus`. Name them `claude:<model>` (or `claude` in the empty-list fallback).
  - **Bind `SELECTED_CLAUDE_MODELS` to that resolved list here** (it is `defaults.code_review.claude_models`, or empty in the fallback case). Step 5a and Step 5b both dispatch "one Task per entry of `SELECTED_CLAUDE_MODELS`" **unconditionally** — the interactive path fills it in Step 2.4, and without this line the variable would simply be undefined in `default` mode. An undefined name in a shell script raises an error under `set -u`; in a prompt it raises nothing at all — the reader improvises, and `default` mode quietly dispatches one reviewer instead of N.
  - **On HOST=claude-code, `native` in builtin collapses to this same host set.** Treat `native` as `claude` for host reviewers — `native ∪ claude` is one set sourced from `claude_models` (and the empty-list fallback above). Ignore `.native_models`. **Bind `SELECTED_NATIVE_MODELS` to the empty list** — on Claude Code the host set is `SELECTED_CLAUDE_MODELS`; native bullets must not appear on confirm.
  - **On HOST=grok, `native` is a separate type.** `claude` in builtin is the Claude Code CLI (`claude-mesh:claude-code-reviewer`), not host slugs. If `native` is not in `.builtin`: **bind `SELECTED_NATIVE_MODELS` to the empty list**. If `.native_models` is non-empty and `native` is not in builtin, the loader already rejected the file.
  - On HOST=grok, this `default` path skipped Step 1, so run the live catalog probe here (same fence as Step 1; substitute the literal `grok` for `$HOST`). Then:
    - **If `claude` was requested and `HAS_CLAUDE_CLI=0`: print `claude: CLI не найден — claude-ревьюер не запущен; остальные движки работают.`, bind `SELECTED_CLAUDE_MODELS` empty and remove `claude` from selected types.** Design §7 requires a spoken degrade here, exactly like `native_degraded` below and `grok_degraded` above. Without it the reviewer is dispatched, dies inside `skills/claude-code-review/SKILL.md` on its own `command -v claude` STOP, leaves no run dir, and is scored `FLIP` — a verdict that prescribes a re-dispatch which fails identically and spends the whole `max_redispatch` budget misdiagnosing a missing binary as a wrapper that self-reviewed. `HAS_CLAUDE_CLI` is probed in the Step 1 fence and until now was read only by the interactive pages.
    - If `native` was requested and `HOST_MODELS` is empty: print `native не запущен; остальные работают.` **bind `SELECTED_NATIVE_MODELS` empty**, and **remove native from selected types** (`native_degraded` spoken, not a loader flag). Empty `SELECTED_NATIVE_MODELS` is then "no native reviewers", not omit-`model:`.
    - If `native` was requested and `HOST_MODELS` is non-empty: intersect `.native_models` with `HOST_MODELS` (`grep -Fxq`); skip missing slugs with **one WARN** at the start, not one per slug. **Bind `SELECTED_NATIVE_MODELS` to the intersection.** An originally empty/absent `.native_models` stays empty — that is the signal for one session-model reviewer (omit `model:` at dispatch), and `native` stays selected. If `.native_models` was **non-empty** and the intersection is empty: do not run native, **remove native from selected types**, bind `SELECTED_NATIVE_MODELS` empty, and **do not substitute the session model**.
  - `codex` / `gemini` in `defaults.code_review.builtin` → spawn the corresponding agent.
  <!-- SYNC: the "no fallback" rule in the next bullet is ONE rule living in five places — this
       bullet, this file's Step 2.45 ("An empty selection runs no grok reviewer"), and their two
       twins in the sibling orchestrator (`skills/mesh-design-review/SKILL.md` Step 5.1's grok
       preset bullet and Step 5.2.6's same paragraph), plus the design's §1 note that grok_models
       is required whenever grok is in builtin. The count is of PHYSICAL sites, like the claude
       fallback rule's own four-place markers — each orchestrator states the rule twice, in its
       preset branch and on its model page, and the design doc states it once. Change all five or
       none: a copy that still promises a fallback would have the orchestrator dispatch a
       reviewer the agent then refuses to start for want of a MODEL. -->
  - `grok` in `defaults.code_review.builtin` → **one `grok-code-reviewer` per entry of `defaults.code_review.grok_models`**, each dispatched with `MODEL=<entry>` alone on the FIRST line of its prompt (and `BASE_BRANCH=<branch>` on the line directly under it when that argument was given — the exact shape is in Step 5a's grok bullet). Name them `grok:<model>` everywhere downstream. The config validator guarantees that list is non-empty whenever `grok` is in `builtin` (the loader's fail-closed rule — "a grok reviewer cannot start without a model"), so there is no fallback branch here: a preset that names grok and validates always dispatches at least one reviewer. There is exactly ONE case where it dispatches none — a `grok:` catalog that does not validate — and it is never silent; see the next bullet.
  - **If `.grok_degraded` is `true`, run no grok reviewer and SAY SO.** The loader sets it when the preset names grok while the `grok:` catalog does not validate: rather than failing the whole read, it removes `grok` from `.builtin` and empties `.grok_models`, so one typo in a user-owned file cannot ground the claude, codex and gemini reviewers this same run asked for. That removal is invisible in the data — the flag is the ONLY thing saying a reviewer you asked for is not running — so print it verbatim: `grok: каталог grok.models не валидируется — grok-ревьюер не запущен; остальные движки работают. config.yaml правит пользователь, агенты его не трогают.` Do not stop the run, do not retry, and never substitute another engine for it.
  - **Bind `SELECTED_GROK_MODELS` to `defaults.code_review.grok_models` here** (the empty list when `grok` is not in `builtin`), for the same reason `SELECTED_CLAUDE_MODELS` is bound just above: Step 5a and Step 5b consume it unconditionally, the interactive path fills it in Step 2.45, and an unbound name in a prompt raises nothing at all — the reader improvises.
  - For each model id in `defaults.code_review.models`, spawn `ext-claude-code-reviewer` with `MODEL=<id>`.
- Use `run_mode` from preset (default: `background`). **If HOST=grok, skip the run-mode question (Step 4) — always background.** If the preset `run_mode` is `team` and HOST=grok: STOP with `На Grok team mode не поддерживается — остановите запуск и используйте background.` Do not dispatch.
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
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found under ~/.claude/plugins (is claude-mesh installed?)" >&2; exit 1; }
# iter-3 CRITICAL-3: a bare $() swallows the loader exit code. Probe once with explicit rc
# capture so rc=2 (config.yaml not created yet — fresh install) is NOT misreported as
# rc=1 (config invalid). Distinct handling per design §6.6 / iter-2 CONCERN-11.
LOADER_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
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
# grok: BOTH reads below VALIDATE the `grok:` catalog before answering — `has_grok` promises
# "a grok reviewer can be dispatched", which needs a non-empty catalog because the reviewer
# agent stops without a MODEL (the `has_grok)` arm of config-loader.sh), unlike the bare probes has_codex /
# has_gemini above — so either one can exit 1 on a malformed section. Guard both, and WARN
# rather than exit: a broken grok: section must not stop a codex-only review — that is the
# `ultra` incident (2026-07-10: a codex setting killed every ext-claude
# executor) in a new costume, and the reason has_codex is a bare probe. The same rule is
# spelled out in config-loader.sh above validate_grok_section_type — cited by the function it
# guards, not by a line number, because the number has already gone stale once. Degrade grok
# alone: report it, drop the flag, let
# everything else run.
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
MODELS=$("$LOADER" list-models)  # `<id>|<label>` per line, ready for pagination
DM_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model 2>"$DM_ERR") \
    || { echo "config.yaml невалиден (runtime.dispatch_model):" >&2; cat "$DM_ERR" >&2; rm -f "$DM_ERR"; exit 1; }
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
# Claude-model catalog (Step 2.4 gate). rc-aware like the dispatch_model read above:
# these two subcommands validate the `claude:` section, so a malformed section must
# fast-fail here with the validator's own message rather than surface as an empty list.
CM_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (секция claude):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
CLAUDE_MODELS=$("$LOADER" list-claude-models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (claude.models):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
rm -f "$CM_ERR"
echo "HAS_CLAUDE_MODELS=$HAS_CLAUDE_MODELS"
echo "CLAUDE_MODELS=[$(echo "$CLAUDE_MODELS" | tr '\n' ' ')]"
# HOST=grok extra probes. `$HOST` is prompt state from Step 0 — substitute the literal
# `grok` or `claude-code` you echoed; it is not a shell variable across Bash calls.
HAS_CLAUDE_CLI=0
command -v claude >/dev/null 2>&1 && HAS_CLAUDE_CLI=1
echo "HAS_CLAUDE_CLI=$HAS_CLAUDE_CLI"
HOST_MODELS=""
# `grok models` is a network+login round-trip sitting in the same fence as the loader reads
# above. preflight-env.sh wraps the identical call in `timeout "$CLI_TIMEOUT"` behind a
# `command -v timeout` guard, and for the reason spelled out there: no probe failure may take
# the surrounding fence down. Without it a hung listing burns the whole harness budget and the
# fence loses its preflight, not just native. The mktemp carries the same STOP as its four
# siblings in this fence — unguarded, an empty $GM sends native down the "grok models failed"
# branch for a reason that has nothing to do with grok.
if [ "$HOST" = grok ]; then
  if ! command -v timeout >/dev/null 2>&1; then
    echo "ВНИМАНИЕ: timeout(1) отсутствует — grok models не запускался; native деградирует" >&2
  else
    GM=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
    if timeout "${GROK_MODELS_TIMEOUT:-30}" grok models >"$GM" 2>/dev/null; then
      HOST_MODELS=$(bash "$(dirname "$LOADER")/list-host-models.sh" --from-file "$GM")
    fi
    rm -f "$GM"
  fi
fi
echo "HOST_MODELS=[$(printf '%s' "$HOST_MODELS" | tr '\n' ' ')]"
# The preset, READ HERE because Q1 and Step 2.1 draw ★ markers from it and this fence is the
# only thing standing between the config and those two pages. Without it those stars come from
# a list nothing has loaded — the sibling orchestrator has always read it up front (SKILL.md
# Step 5.0 binds DEFAULTS_JSON and says in as many words that its model page "needs no loader
# read of its own"), and this file simply never did. rc-aware and never through a pipe, for the
# reason Step 2.4 gives: get-defaults is what runs validate_defaults, so a fail-closed preset
# error now surfaces on the FIRST screen instead of two steps in.
CR_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
CR_DEFAULTS=$("$LOADER" get-defaults code_review 2>"$CR_ERR") \
    || { echo "config.yaml невалиден (defaults.code_review):" >&2; cat "$CR_ERR" >&2; rm -f "$CR_ERR"; exit 1; }
rm -f "$CR_ERR"
echo "CR_DEFAULTS=$CR_DEFAULTS"
```

Parse `CR_DEFAULTS` with jq (`.builtin`, `.claude_models`, `.native_models`, `.grok_models`, `.models`) into the ★
sets the pages below mark with: the recommended built-in set for Q1 and Step 2.1,
`CLAUDE_DEFAULT_IDS` for Step 2.4, `NATIVE_DEFAULT_IDS` for Step 2.3, `GROK_DEFAULT_IDS` for Step 2.45 and `DEFAULT_IDS` for Step 3.
Those later steps re-read the preset in their own fences anyway — each runs in a fresh shell where
`$LOADER` no longer exists, and re-resolving it costs one local script call — but the ★ decisions
on Q1 and Step 2.1 have no fence of their own and are made from THIS read.

rc=0 → proceed; rc=2 → fresh-install hint + clean exit; rc=1 → surface the validator stderr verbatim and stop — do NOT edit config.yaml (user-owned, agents never edit it) (iter-3 CRITICAL-3).

## Step 2 (Q1): Ask which reviewer TYPES

**Question tool.** HOST=claude-code: `AskUserQuestion`. HOST=grok: `ask_user_question` (same options, same pagination of 4). Applies to every selection and confirm page in this command (Q1, CLI, native, Claude, grok, models, confirm, run-mode). Grok's tool may append **Other**. Other is not an id — re-ask the page, or drop it; never put the raw string in `MODEL=` or in `SELECTED_TYPES` / `SELECTED_*_MODELS` / `SELECTED_IDS`. Pagination stays 4 so Claude Code does not break.

Use AskUserQuestion (multiSelect, max 4). HOST=grok: `ask_user_question` (same options). Other is not an id — re-ask or drop, never put in MODEL= or SELECTED_*:

**iter-2 CONCERN-4:** AskUserQuestion has no `preSelected` API (iter-1 CONCERN-11). The "all checked by default" comment in the legacy `/external-code-review` was aspirational, not enforced. Apply the same `★ recommended` annotation pattern that Step 3 uses for models — types in `defaults.code_review.builtin` get the ★ marker in their label so users see the recommendation. Then add Step 2.5 confirmation (mirrors Step 3.5 for models).

```
header: "Reviewers"
question: "Какие типы reviewers запустить? (★ = recommended, в defaults.code_review.builtin)"
options:
  HOST=claude-code:
  - "claude ★ default (свой Claude через superpowers)"        — always shown; ★ if "claude" OR "native" in defaults.code_review.builtin (`native` ≡ `claude` on CC)
  - "внешние CLI (<the configured engines, " / "-joined>) ★ default"  — show only if HAS_CODEX=1 OR HAS_GEMINI=1 OR HAS_GROK=1; ★ if ANY of codex/gemini/grok is in defaults.code_review.builtin.
    Build the parenthesis from the flags that are 1, in the order codex / gemini / grok: a codex-only machine reads «внешние CLI (codex)», never a roster of two
    engines it does not have. The ★ still fires on ANY of the three appearing in `builtin`, because it marks the OPTION, not an individual engine.
    `claude` is **not** in this parenthesis and is **not** on the CLI page.
  - "external models (Anthropic-API) ★ default"                — show only if HAS_MODELS=1; ★ if defaults.code_review.models is non-empty
  HOST=grok:
  - "свои модели хоста ★ default" (`native`)                  — always shown; ★ if "native" in defaults.code_review.builtin. Do not add `native` as a fourth Q1 option.
  - "внешние CLI (<the configured engines, " / "-joined>) ★ default"  — show if HAS_CLAUDE_CLI=1 OR HAS_CODEX=1 OR HAS_GEMINI=1 OR HAS_GROK=1; ★ if ANY of claude/codex/gemini/grok is in defaults.code_review.builtin.
    Build the parenthesis from the flags that are 1, in the order claude / codex / gemini / grok, only those whose flags are 1.
  - "external models (Anthropic-API) ★ default"                — show only if HAS_MODELS=1; ★ if defaults.code_review.models is non-empty
```

**Q1 is three options and stays three however many CLI engines exist later.** `AskUserQuestion`
accepts at most FOUR, and one option is already spent on the host (`claude` on CC, `native` /
«свои модели хоста» on Grok) and one on the external models, so the CLI engines share the third —
a fourth CLI engine belongs on Step 2.1's page, never as a fifth option here. Do **not** "restore
symmetry" by splitting this option back into one per engine: on a machine with codex, gemini and
grok all configured that call has five options and fails outright, and the failure is the whole
question, not one dropped row. Do **not** add `native` as a fourth Q1 option: on Claude Code it
duplicates `claude`; on Grok the host already occupies option 1.

**What Q1's answer becomes.** «внешние CLI» is not itself a reviewer type and **never enters
`SELECTED_TYPES`** — Step 2.1 turns it into the individual engine names (`codex`, `gemini`,
`grok`, and on Grok also `claude`), and those are what land in `SELECTED_TYPES`. The host option
enters as `claude` (CC) or `native` (Grok). Everything downstream — Step 2.5's bullet
list, Step 5a / Step 5b's dispatch, Step 6.0's `engine:model` roster — keys off that set exactly
as it did when Q1 named the engines directly; no other step changes shape.

- HOST=grok, «свои модели хоста» selected → go to **Step 2.3**. If `HOST_MODELS` is empty: print
  `native не запущен; остальные работают.` **bind `SELECTED_NATIVE_MODELS` empty**, and
  **remove native from selected types** (`native_degraded` spoken, not a loader flag); skip Step 2.3.
- HOST=grok, «свои модели хоста» NOT selected → skip Step 2.3; **bind `SELECTED_NATIVE_MODELS`
  to the empty list**.
- HOST=claude-code → skip Step 2.3 always; **bind `SELECTED_NATIVE_MODELS` to the empty list**
  (host set is `SELECTED_CLAUDE_MODELS`).
- «внешние CLI» selected → go to **Step 2.1** and pick which of them.
- «внешние CLI» NOT selected → **skip Step 2.1**; no `codex` / `gemini` / `grok` (and on Grok
  no `claude`) enters `SELECTED_TYPES`, no CLI reviewer runs at all, and **bind
  `SELECTED_GROK_MODELS` to the empty list** — Step 2.45 never runs on this path and Step 5a
  consumes the name unconditionally. On Grok, `claude` not entering `SELECTED_TYPES` is what
  Step 2.4's skip uses to **bind `SELECTED_CLAUDE_MODELS` empty**.
- "external models" not selected → skip Step 3 entirely.

**Bind `SELECTED_TYPES` here**, to Q1's answer with «внешние CLI» replaced by whatever Step 2.1
selects — by nothing at all when that option was not chosen and Step 2.1 never runs. Q1 and
Step 2.1's fold are the ONLY two writes to this set in the file; Step 2.45's gate, Step 2.5's
list, Step 5a / Step 5b's dispatch and Step 6.0's roster only ever read it.

## Step 2.1: CLI-engine selection

(No `Q1.x` label, for the same reason Step 2.4 carries none: this page runs *before* Step 2.5's
`Q1.5` — earlier still than Step 2.4 — so any `Q1.x` number here would read as an ordering error.
The step number alone is unambiguous.)

Runs ONLY when Q1 selected «внешние CLI». The engines on offer are exactly those whose Step 1
flag is `1`. HOST=claude-code: `codex` (`HAS_CODEX=1`), `gemini` (`HAS_GEMINI=1`), `grok`
(`HAS_GROK=1`). HOST=grok: the same three plus `claude` (`HAS_CLAUDE_CLI=1`). `claude` appears
on this page **only when HOST=grok**. Never offer an engine whose flag is `0` — it has no config
section to run from (and for grok a `0` may also mean Step 1 degraded it after a validator error
it already printed; for `claude` on Grok, `HAS_CLAUDE_CLI=0` means the binary is missing).

**Exactly one engine configured → skip the page and select that engine implicitly**, saying so in
one line (`Внешний CLI: codex (единственный настроенный)`) — the engine enters `SELECTED_TYPES`
exactly as a page selection would, per the fold below. Without this, every single-engine user
pays an extra screen for a problem they do not have.

Otherwise ask ONE page — **not** a pagination loop. `AskUserQuestion` caps options at 4. HOST=claude-code
has three CLI engines; HOST=grok order is `claude, codex, gemini, grok` — that is exactly four.
A FIFTH CLI engine is what would need the Step 2.4 / Step 3 pagination mechanic; add it then, not now.

AskUserQuestion (multiSelect, max 4). HOST=grok: `ask_user_question` (same options). Other is not an id — re-ask or drop, never put in MODEL= or SELECTED_*:
```
header: "CLI"
question: "Какие внешние CLI-движки запустить? (★ = recommended, в defaults.code_review.builtin)"
options:
  HOST=claude-code — for each CONFIGURED engine, in this order — codex, gemini, grok:
    label:       "<engine> CLI"                     if NOT in defaults.code_review.builtin
                 "★ <engine> CLI (recommended)"     if in defaults.code_review.builtin
    description: "внешнее ревью через <engine> CLI"
  HOST=grok — for each CONFIGURED engine, in this order — claude, codex, gemini, grok:
    claude label: "Claude Code CLI"                 if "claude" NOT in defaults.code_review.builtin
                  "★ Claude Code CLI (recommended)" if "claude" in defaults.code_review.builtin
    claude description: "внешнее ревью через claude -p (`claude-mesh:claude-code-reviewer`); never «свой Claude Code»"
    other engines: same "<engine> CLI" / "★ <engine> CLI (recommended)" labels as on CC
```

The ★ comes from the same `defaults.code_review.builtin` list Q1's own ★ markers came from,
which Step 1's fence read into `CR_DEFAULTS` — no
new loader read here. AskUserQuestion has no `preSelected` API, which is why the recommendation
travels in the label text, exactly as in Step 2.4 and Step 3.

**Fold the selection — the page's answer, or the single engine chosen implicitly above — into
`SELECTED_TYPES` as the individual engine names** (`codex`, `gemini`, `grok`, and on Grok `claude`), and never as the
«внешние CLI» option itself. The implicit path folds exactly as the page does; skipping the
question is not skipping the write, and an engine that never reaches `SELECTED_TYPES` is silently
dropped at Step 2.45's gate and dispatched by nothing. That set is what Step 2.5 lists, what
Step 5a and Step 5b dispatch from, and what Step 6.0 builds its roster from.

**Selecting no engine is not an error** — the same rule the model pages already follow. It means
no CLI reviewer runs; do not re-ask and do not STOP.

**If `grok` is not among the selected engines** — however they were selected, on the page above
or implicitly because it is the only one configured — **bind `SELECTED_GROK_MODELS` to the empty
list here.** Step 2.45's own skip bullet states the same binding, deliberately: Step 2.5 and
Step 5a read the name unconditionally, and an unbound name in a prompt raises nothing at all —
the reader improvises.

**If HOST=grok and `claude` is not among the selected engines**, Step 2.4's skip **binds
`SELECTED_CLAUDE_MODELS` to the empty list** — same reason.

## Step 2.3: Native-model selection

Runs ONLY when HOST=grok and Q1 selected «свои модели хоста» (`native`) **and** `HOST_MODELS` is
non-empty. Slugs in `native_models` missing from live `grok models` do not appear on the page.

- HOST=claude-code → skip; **bind `SELECTED_NATIVE_MODELS` to the empty list**.
- HOST=grok and `native` NOT selected in Q1 → skip; **bind `SELECTED_NATIVE_MODELS` to the empty list**.
- HOST=grok, `native` selected, `HOST_MODELS` empty → skip; print `native не запущен; остальные работают.` **bind `SELECTED_NATIVE_MODELS` empty**, and **remove native from selected types** (`native_degraded` spoken, not a loader flag).

Both skip bindings are mandatory: Step 2.5 and Step 5a consume `SELECTED_NATIVE_MODELS`
unconditionally, and an unbound name in a prompt raises nothing at all — the reader improvises.

`NATIVE_DEFAULT_IDS` is `.native_models` from Step 1's `CR_DEFAULTS` parse — no new loader read.
Native order is `grok models` / `HOST_MODELS` order. Do not lift starred entries to the front.
A catalog of ~18 slugs is five pages; do not raise the page size (Claude Code cap is 4).

If `native_models` named slugs that `HOST_MODELS` does not contain: **one WARN** at the start of
this page, not one per slug.

For each chunk of 4 entries from `HOST_MODELS` (in `grok models` order) — same pagination
mechanics as Step 2.4 / Step 3, and the same reason for the ★ marker (AskUserQuestion has no
`preSelected` API):

<!-- SYNC: empty native_models fallback (one session-model reviewer) lives in the loader's
     pairing (absent key is valid), both orchestrators' preset branches, both native model
     pages, and the design §6 paragraph. Change all or none. -->
**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — native на модели сессии`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_NATIVE_MODELS` can never contain it.** Nothing downstream recognises the sentinel — a list holding that string is NON-EMPTY, so the session-model fallback below does not fire and one reviewer is dispatched with `model: "ни одной — native на модели сессии"`. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 2.1 resolves a single ENGINE.

AskUserQuestion (multiSelect, max 4). HOST=grok: `ask_user_question` (same options). Other is not an id — re-ask or drop, never put in MODEL= or SELECTED_*:
```
header: "Native"
question: "На каких native-моделях хоста запустить ревью? (страница N/M, ★ = recommended)"
options:
  For each slug in the chunk:
    label:       "<slug>"                     if NOT in NATIVE_DEFAULT_IDS
                 "★ <slug> (recommended)"     if in NATIVE_DEFAULT_IDS
    description: "отдельный независимый ревьюер native:<slug>"
```

Collect the selections across pages into `SELECTED_NATIVE_MODELS`.

**Empty selection is not an error.** It falls back to exactly one native reviewer on the session
model — `SELECTED_NATIVE_MODELS` stays empty as the signal for "omit `model:`". Do not re-ask
and do not STOP.

Each selected slug becomes an independent reviewer named `native:<slug>`. Double-counting
`native:grok-4.6` vs `grok:grok-4.6` is accepted.

## Step 2.4: Claude-model selection

(No `Q1.x` label: this page runs *before* Step 2.5, so numbering it `Q1.6` ahead of Step 2.5's `Q1.5` reads as an ordering error. The step number alone is unambiguous.)

Runs ONLY when `claude` is in `SELECTED_TYPES` **and** `HAS_CLAUDE_MODELS=1`. On HOST=claude-code,
`claude` enters `SELECTED_TYPES` from Q1 option 1. On HOST=grok, `claude` enters from Step 2.1
(Claude Code CLI) — Q1 option 1 is native, never `claude`. Source is still `claude.models`.

- `claude` NOT in `SELECTED_TYPES` → skip this step entirely; **no claude reviewer runs at all**, whatever the catalog holds. **Bind `SELECTED_CLAUDE_MODELS` to the empty list.**
- `claude` selected but `HAS_CLAUDE_MODELS=0` → skip this step; exactly **one** reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty; on Grok: `claude -p` without `-m`). **Bind `SELECTED_CLAUDE_MODELS` to the empty list.**

Both bindings are mandatory, for the same reason Step 0 binds it in `default` mode: this step holds the ONLY other assignment to `SELECTED_CLAUDE_MODELS`, and Step 2.5 / Step 5a / Step 5b consume it unconditionally. An undefined name in a shell script raises an error under `set -u`; in a prompt it raises nothing at all — the reader improvises.

Build `CLAUDE_DEFAULT_IDS` from the preset — **rc-aware, and never through a pipe**:

```bash
# Same resolution as Step 1 — Q1's AskUserQuestion sits between that fence and this one, so
# this Bash call runs in a FRESH shell where $LOADER no longer exists. Without re-resolving
# it, `$("" get-defaults …)` fails and the `||` below misreports a valid config as invalid.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
# NOT the first get-defaults call on the interactive path any more — Step 1 reads the preset
# for Q1's and Step 2.1's ★ markers, so validate_defaults has already run and a bad
# `claude_models` has already surfaced there. This read stands for the fresh-shell reason
# above, and its rc handling stays: a config the user edited between the two screens is a
# state this page must still survive.
# `"$LOADER" get-defaults … | jq …` would take its status from jq and swallow the new
# fail-closed guard (rc=1) entirely, turning a hard error into an empty list.
CD_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
CR_DEFAULTS=$("$LOADER" get-defaults code_review 2>"$CD_ERR") \
    || { echo "config.yaml невалиден (defaults.code_review):" >&2; cat "$CD_ERR" >&2; rm -f "$CD_ERR"; exit 1; }
rm -f "$CD_ERR"
CLAUDE_DEFAULT_IDS=$(echo "$CR_DEFAULTS" | jq -r '.claude_models[]?')
echo "CLAUDE_DEFAULT_IDS=[$(echo "$CLAUDE_DEFAULT_IDS" | tr '\n' ' ')]"   # empty = no ★ markers below
```

For each chunk of 4 entries from `CLAUDE_MODELS` (in config order) — same pagination mechanics as Step 3, and the same reason for the ★ marker (AskUserQuestion has no `preSelected` API):

**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — claude на модели по умолчанию`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_CLAUDE_MODELS` can never contain it.** Nothing downstream recognises the sentinel — a list holding that string is NON-EMPTY, so the fallback below does not fire and one reviewer is dispatched with `model: "ни одной — claude на модели по умолчанию"`. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 2.1 resolves a single ENGINE. Skipping the page there loses nothing — an engine still has to pass its own model page — while skipping this one would decide which model the single claude reviewer runs on — this catalog's only entry, or `DISPATCH_MODEL` through the fallback below on the user's behalf, silently, in the one configuration where the question matters most.

AskUserQuestion (multiSelect, max 4). HOST=grok: `ask_user_question` (same options). Other is not an id — re-ask or drop, never put in MODEL= or SELECTED_*:
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

## Step 2.45: Grok-model selection

Runs ONLY when Step 2.1 selected `grok` (i.e. `grok` is in `SELECTED_TYPES`). There is no
`HAS_GROK_MODELS` gate: a `grok:` section without a non-empty catalog does not validate, so
`HAS_GROK=1` already guarantees `GROK_MODELS` is non-empty — that is the promise `has_grok`
makes and the reason no separate flag exists (the loader's `has_grok)` arm, which validates the
catalog before answering).

- `grok` NOT selected in Step 2.1 → skip this step; **bind `SELECTED_GROK_MODELS` to the empty
  list** and run no grok reviewer at all.

Read the recommended set from the preset — rc-aware, and never through a pipe, for the same
reason Step 2.4 spells out (this Bash call runs in a fresh shell; `$LOADER` must be
re-resolved):

```bash
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
GD_ERR=$(mktemp) || { echo "STOP: mktemp failed" >&2; exit 1; }
CR_DEFAULTS=$("$LOADER" get-defaults code_review 2>"$GD_ERR") \
    || { echo "config.yaml невалиден (defaults.code_review):" >&2; cat "$GD_ERR" >&2; rm -f "$GD_ERR"; exit 1; }
rm -f "$GD_ERR"
GROK_DEFAULT_IDS=$(echo "$CR_DEFAULTS" | jq -r '.grok_models[]?')
echo "GROK_DEFAULT_IDS=[$(echo "$GROK_DEFAULT_IDS" | tr '\n' ' ')]"   # empty = no ★ markers below
```

For each chunk of 4 entries from `GROK_MODELS` (in config order) — same pagination mechanics as
Step 3, and the same reason for the ★ marker (AskUserQuestion has no `preSelected` API). Unlike
Step 2.1, whose option list is at most three, this catalog is the user's and can exceed 4:

**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — grok не запускать`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_GROK_MODELS` can never contain it.** Nothing downstream recognises the sentinel — `grok-code-review` checks MODEL against the catalog with `grep -Fxq` and STOPs, so the reviewer the user asked NOT to run is the one that reports an error. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 2.1 resolves a single ENGINE. Skipping the page there loses nothing — an engine still has to pass its own model page — while skipping this one would decide whether a grok reviewer runs at all — the one thing this page exists to ask on the user's behalf, silently, in the one configuration where the question matters most.

AskUserQuestion (multiSelect, max 4). HOST=grok: `ask_user_question` (same options). Other is not an id — re-ask or drop, never put in MODEL= or SELECTED_*:
```
header: "Grok"
question: "На каких grok-моделях запустить ревью? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in GROK_DEFAULT_IDS
                 "★ <model> (recommended)"     if in GROK_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections across pages into `SELECTED_GROK_MODELS`. Every entry is a bare catalog
id (`grok-4.6`) — never a `<provider>/<short>` pair like ext-claude's. A slash in that value
never reaches a verdict at all: the Step 6.0 guard rejects it with a usage error and exit 1,
the shape that means "fix the call" — never `FLIP`, which would mean "re-dispatch this
reviewer". It once did report `FLIP`, by resolving `runs/grok/<provider>/<short>`, a path
nothing ever writes; the charset check in `verify-delegation.sh`'s `grok)` arm replaced that.

<!-- SYNC: the "no fallback" rule for grok is ONE rule living in five places — this paragraph,
     this file's Step 0 grok preset bullet, and their two twins in the sibling orchestrator
     (`skills/mesh-design-review/SKILL.md` Step 5.1's grok preset bullet and Step 5.2.6's same
     paragraph), plus the design's §1 note that grok_models is required whenever grok is in
     builtin. The count is of PHYSICAL sites, like the claude fallback rule's own four-place
     markers — each orchestrator states the rule twice, in its preset branch and on its model
     page, and the design doc states it once. Change all five or none: a copy that still promises
     a fallback would have the orchestrator dispatch a reviewer the agent then refuses to start
     for want of a MODEL. -->
**An empty selection runs no grok reviewer — and unlike claude, there is no fallback.** The
grok reviewer agent stops without a `MODEL`, so there is nothing to dispatch. Say so on the
Step 2.5 confirmation page ("grok: модели не выбраны — ревьюер не запускается") and continue;
do not re-ask and do not STOP.

Each selected model becomes an independent reviewer with the same diff and the same prompt —
the point is model diversity, so never differentiate their prompts.

## Step 2.5 (Q1.5): Confirm reviewer-type selection

Mirror Step 3.5 (model confirmation): after Q1 (and Steps 2.1, 2.3, 2.4 and 2.45, each when it ran), show the full SELECTED_TYPES list (one per line) and ask. **Expand `claude` in that list into one bullet per entry of `SELECTED_CLAUDE_MODELS`** (`claude:opus`, `claude:fable`), or a single `claude (модель по умолчанию)` bullet in the fallback case — the user must see how many Claude reviewers they are about to pay for.

**When `native` is in `SELECTED_TYPES` (HOST=grok only), expand it into one `native:<slug>` bullet
per entry of `SELECTED_NATIVE_MODELS`.** Show `native (модель сессии)` only if `native` is still
selected, the list is empty because of the sentinel / absent key, **and** `HOST_MODELS` is
non-empty — that is the **session-model fallback only when HOST_MODELS is non-empty**. If
`HOST_MODELS` was empty or a non-empty preset intersected to nothing, `native` was already
removed from selected types and this page says nothing about native.
**On HOST=claude-code do not show native bullets** — `native`+`claude` collapsed to one host set
in Step 0 / Q1, so a second row would double-count. **When `native` is NOT in `SELECTED_TYPES`**,
the page says nothing about native at all.

**When `grok` is in `SELECTED_TYPES`, expand it the same way**, one bullet per entry of
`SELECTED_GROK_MODELS` (`grok:grok-4.6`). When `grok` is selected and that list is empty, show
`grok: модели не выбраны — ревьюер не запускается` instead of a bullet, so a user who picked grok
in Step 2.1 and then checked nothing in Step 2.45 sees why nothing will run. **When `grok` is NOT
in `SELECTED_TYPES`** — Step 2.1 did not pick it, or `HAS_GROK=0` and it was never on offer — the
page says nothing about grok at all: no bullet and no such line, exactly as it says nothing about
an unconfigured codex. That line reports on a selection the user made; it is not a standing
notice. Without that gate it prints on EVERY review, because both paths that skip Step 2.45 —
Q1 without «внешние CLI», and Step 2.1 without grok — bind `SELECTED_GROK_MODELS` to the empty
list, which is exactly the state the line describes. There
is no fallback bullet here: unlike `claude`, an empty grok list dispatches nothing at all
(Step 2.45). A pair that shows no bullet contributes nothing further either — not to Step 5a's
dispatch, not to its watcher roster, not to Step 6.0's guard. A roster entry with no dispatch
behind it comes back `MISSING`, which is indistinguishable from a dead executor.

**If the effective roster is empty** — `SELECTED_TYPES` holds nothing that can produce a
reviewer: no `native` (Grok host; an empty `SELECTED_NATIVE_MODELS` still counts only while
`native` remains selected — session-model fallback only when HOST_MODELS is non-empty; after
degrade, native was removed from selected types and counts as nothing), no `claude`, no CLI engine with anything to run (grok with an empty model list counts
as nothing), and no `external models` — STOP with `ничего не выбрано для ревью` instead of
showing this page over an empty list and starting an orchestration with no reviewers.
(`external models` in `SELECTED_TYPES` counts as a reviewer here even though its ids are only
chosen in Step 3; that page has its own empty-selection STOP in Step 3.5.)

```
header: "Подтверди"
question: "Использовать эти reviewer-типы? <bullet list of SELECTED_TYPES>"
options:
  - "Да, использовать как выбрано"
  - "Нет, выбрать заново" — re-runs Q1 **and** Steps 2.1, 2.3, 2.4 and 2.45, dropping the current SELECTED_CLAUDE_MODELS, SELECTED_NATIVE_MODELS and SELECTED_GROK_MODELS (cap 3 attempts; on the 4th attempt, surface STOP "пользователь не подтвердил выбор reviewer-типов")
  - "Отмена" — exits command cleanly (no executors dispatched)
```

## Step 3 (Q2..Qn): Paginated model selection

AskUserQuestion `options` schema (verified in iteration 1) does NOT support a `preSelected`/`checked` flag — pre-check requested by defaults must be communicated visually in the `label` text instead. Per CONCERN-11.

Read the default set from `defaults.code_review.models` (if exists). Build a set `DEFAULT_IDS` of model ids that should appear pre-recommended.

For each chunk of 4 models from `models[]` (in config order):

**A page that would carry exactly ONE option still gets asked — with TWO.** `AskUserQuestion` refuses fewer than two (schema `minItems: 2`), so the second option is this page's own documented empty outcome, spelled out as an option: `ни одной — внешние модели не запускать`. **Selecting it IS the empty selection, never a model id: drop it before collecting, so `SELECTED_IDS` can never contain it.** Nothing downstream recognises the sentinel — the id reaches `ext-claude-code-review` as a model name and the run dies on the catalog lookup. **The rule is about the PAGE, not the catalog:** a catalog of one entry produces such a page, and so does the LAST chunk of any catalog whose size leaves a remainder of one — 5, 9, 13 entries, where the earlier pages carry four and the last carries one. Counting the catalog instead of the chunk is how the refusal this paragraph exists to prevent comes back on a catalog of five. Do NOT resolve a single entry the way Step 2.1 resolves a single ENGINE. Skipping the page there loses nothing — an engine still has to pass its own model page — while skipping this one would decide that the user wants this model, when the alternative is the STOP in Step 3.5 on the user's behalf, silently, in the one configuration where the question matters most.
- AskUserQuestion (multiSelect, max 4). HOST=grok: `ask_user_question` (same options). Other is not an id — re-ask or drop, never put in MODEL= or SELECTED_*:
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

**If HOST=grok: skip this question — always background.** Grok has no TeamCreate. If a `default`
preset already STOPped on `run_mode: team` in Step 0, this step is never reached.

AskUserQuestion (single, 2 options). HOST=grok skips this question (always background). HOST=claude-code keeps AskUserQuestion:
```
header: "Run mode"
question: "Как запускать ревьюеров?"
options:
  - "Background tasks (Recommended)"   if runtime.default_run_mode == background
  - "Team of reviewers"
```

Since AskUserQuestion lacks preSelected, the recommended choice gets a "(Recommended)" suffix in its `label` (matches the convention used in other claude-mesh AskUserQuestion sites).

## Step 5a: Background tasks mode

**Before dispatch — stamp the delegation window (Step 6.0 guard needs it).** Via a Bash tool call, record `DISPATCH_EPOCH=$(date +%s)` and keep the number. Also remember the list of *wrapper* reviewers being dispatched as `engine:model` pairs: `codex`→`codex:-`, `gemini`→`gemini:-`, each entry of `SELECTED_GROK_MODELS`→`grok:<model>` (`grok:grok-4.6` — a colon, and the bare catalog id), each selected model id→`ext-claude:<id>`. `grok` with an empty `SELECTED_GROK_MODELS` contributes no pair at all: nothing was dispatched, so there is nothing to verify.

**HOST=claude-code:** the builtin `claude` / `general-purpose` reviewers — there may now be several, one per Claude model — are NOT wrappers (they review inline by design). Exclude all of them from this list. Native is not a separate spawn (`≡ claude`).

**HOST=grok:** native is NOT a wrapper (no `runs/native/…`, Step 6.0 INLINE). Exclude every `native:<slug>` from this list. `claude` IS a wrapper here: each entry of `SELECTED_CLAUDE_MODELS`→`claude:<alias>` (`claude:opus` — a colon); empty list with `claude` still selected → one pair `claude:_default` (roster `claude/_default`). Name them `claude:<alias>` everywhere downstream. The watcher roster spells the same reviewer `claude/opus` (a SLASH), matching `runs/claude/<alias>/` — the two spellings are never interchangeable.

Launch all selected reviewers **in ONE message**:

**HOST=claude-code:** Task tool, each `run_in_background: true`.

**HOST=grok:** `spawn_subagent`, each `background: true`. Do not set `isolation: worktree`; reviewers read the orchestrator's tree. There is no Task, no SendMessage, no TeamCreate.

**Dispatch model (HOST=claude-code):** if `DISPATCH_MODEL` (resolved in Step 0 for `default` mode, or Step 1 for interactive) is non-empty, add `model: "<DISPATCH_MODEL>"` to every Task dispatch below. If it is empty, omit `model:` so each reviewer inherits this session's model.

**Exception — claude reviewers with an explicit model (HOST=claude-code).** When Step 2.4 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL`. Running the review on a chosen model is the whole point; letting `DISPATCH_MODEL` win here would collapse every claude reviewer onto one model and fake the independence. `DISPATCH_MODEL` still governs the codex / gemini / grok / ext-claude wrappers, and the single fallback `claude` reviewer. **A grok reviewer's `MODEL=` is not an exception to that** — the two name different things and both apply at once: `DISPATCH_MODEL` sets the Claude model the `grok-code-reviewer` WRAPPER itself runs on, while `MODEL=<entry>` names the xAI model its CLI reviews with. Exactly as for ext-claude, neither overrides the other.

**Dispatch model (HOST=grok):** do **not** pass `runtime.dispatch_model` / `DISPATCH_MODEL` to `spawn_subagent` unless that value is in `HOST_MODELS` (`grep -Fxq`). `opus` is not a host slug — **never pass `opus` as spawn `model:`**. Native slugs use their own `model: "<slug>"` (omit `model:` when the list is empty). Wrapper spawn `model:` is only a live host slug; it is never the CLI's `MODEL=` line. A native spawn whose `model:` the host rejects is a failed reviewer: record it, do not substitute another slug.

**Base branch:** when the `BASE_BRANCH=<branch>` argument was given, prefix every WRAPPER prompt
below with `BASE_BRANCH=<branch> `. Each wrapper's skill reads that name and otherwise
auto-detects (`ext-claude-code-review` SKILL.md:20, `codex-code-review`
/ `gemini-code-review` :84, `grok-code-review` :29 and :127), so without the prefix the reviewers
silently examine a different range than the caller asked for. This is a parameter exactly like
`MODEL=<id>`, not review content — the CRITICAL rule below still forbids inlining scope, diff or
focus areas. **The prefix is for codex and gemini only; grok and ext-claude are both exceptions
to it** — not to the rule: each of those two agents requires `MODEL=` on the FIRST line, so the
base goes on its own line directly under `MODEL=` and never in front of it; the exact shapes are
in the grok and ext-claude bullets below. The rule reads by what the agent demands, not by engine
name — a fifth wrapper takes the prefix if its agent claims no first line, and the two-line shape
if it does. The builtin `claude` reviewers resolve the range themselves, so they get the base
named in their prompt sentence instead. Argument absent → change nothing; every skill keeps its own auto-detection.

**HOST=claude-code — Task dispatch.** For each builtin reviewer:
- claude: `subagent_type: "general-purpose"` (built-in — NOT namespaced), prompt invokes `superpowers:requesting-code-review` skill. **One Task per entry of `SELECTED_CLAUDE_MODELS`**, each carrying `model: "<entry>"`; in the fallback case exactly one Task per the Dispatch-model rule above. All of them get the same prompt — only the model differs. With `BASE_BRANCH` given, the prompt names it: `… review the changes on this branch against base <branch> …`.
- codex: `subagent_type: "claude-mesh:codex-code-reviewer"`, prompt: `Review the changes for production readiness` (with the `BASE_BRANCH=<branch> ` prefix when the argument was given)
- gemini: `subagent_type: "claude-mesh:gemini-code-reviewer"`, prompt: `Review the changes for production readiness` (same prefix rule)
- grok: `subagent_type: "claude-mesh:grok-code-reviewer"`, **one Task per entry of `SELECTED_GROK_MODELS`** — and none at all when that list is empty. Write `MODEL=<entry>` ALONE on the FIRST line and, when the `BASE_BRANCH` argument was given, `BASE_BRANCH=<branch>` on the line directly under it:

  ```
  MODEL=<entry>
  BASE_BRANCH=<branch>
  Review the changes for production readiness
  ```

  Without that argument, drop the middle line: the prompt is `MODEL=<entry>` then `Review the changes for production readiness`. Do **NOT** collapse this into one line starting with `BASE_BRANCH=` — that is the one shape grok's agent is written to reject, and the ext-claude bullet below now takes the same two-line shape for the same reason. Its contract is prose an agent reads, not a regex: `agents/grok-code-reviewer.md:26` ("MODEL is REQUIRED on the first line") and `:30-31` (a `BASE_BRANCH=<branch>` line "which the caller writes directly under `MODEL=`"). Nothing parses this prompt mechanically, which is precisely why the caller has to get it right — an agent reading `BASE_BRANCH=` at the head of the first line either stops with its `ERROR: MODEL parameter is required on first line` or forwards something it guessed at, and neither outcome is a review. `<entry>` is the bare catalog id (`grok-4.6`), never a `<provider>/<short>` pair. `MODEL=` is a parameter, exactly as for ext-claude; it is not review content, so the CRITICAL rule below still forbids inlining scope or diff.

For each selected model id:
- `subagent_type: "claude-mesh:ext-claude-code-reviewer"`, prompt: `MODEL=<id>` on its own FIRST line, then `BASE_BRANCH=<branch>` directly under it when there is a base branch to name, then `Review the changes for production readiness`. Without a base branch, drop the middle line. The one-line `BASE_BRANCH=<branch> MODEL=<id> …` form this bullet used to prescribe put `BASE_BRANCH=` at the head of the first line, against `agents/ext-claude-code-reviewer.md`'s own requirement that MODEL be there — it worked in practice, but only because every agent so far read past it

**CRITICAL — wrapper reviewers get a SHORT delegation prompt, NOT an inlined review task.** The codex / gemini / grok / ext-claude reviewers (and on HOST=grok, `claude-mesh:claude-code-reviewer`) are thin wrappers; their agent def forces them to invoke the matching `*-code-review` skill, and the SKILL resolves the diff and builds the review prompt itself. Pass each wrapper ONLY the short prompt above (prefixed with `MODEL=<id>` for ext-claude; headed by `MODEL=<entry>` / `MODEL=<alias>` on its own first line for grok and for Grok-host claude). Do **NOT** inline scope / diff / project invariants / focus areas into a wrapper's prompt: a detailed "review this yourself" prompt makes the wrapper self-review on its own model instead of delegating to the external model — silently, with no `runs/<engine>/…` artifacts produced. Extra review context, if any, is forwarded by the agent to the skill's `CONTEXT` argument; it is never a license to review inline. (On HOST=claude-code only the builtin `claude` / `general-purpose` reviewers review directly. On HOST=grok native `explore` children also review directly — they have no skill to invoke.)

**HOST=grok — `spawn_subagent` dispatch, all `background: true`, one message.** Same short wrapper prompts as the CC bullets; `spawn_subagent` instead of Task. Do not pass `runtime.dispatch_model` unless that value is in `HOST_MODELS`. Do not pass `opus` as spawn `model:`.

- **native:** for each `SELECTED_NATIVE_MODELS` entry, `subagent_type: "explore"`, `model: "<slug>"`, `description: "Review via native:<slug>"`. If the list is empty and native was selected (session-model fallback: sentinel / absent key, `HOST_MODELS` non-empty, native still in selected types): one `explore`, **omit** `model:`. Native writes no `runs/native/…` and is not on the watcher roster. Prompt = the requesting-code-review contract (range, findings format Strengths / Critical / Important / Minor / Assessment) + `BASE_BRANCH` named in prose (`… review the changes on this branch against base <branch> …`; argument absent → name auto-detect, do not invent a branch) + grok-code-review's tooling-constraint block **verbatim**. The child reads the tree. Do **not** inline the diff. A nested `spawn_subagent` would fail on depth; an in-process replay of these steps would not — that is why the paragraph is there:

  ```
  spawn_subagent:
    subagent_type: "explore"
    background: true
    model: "<slug>"                 # omit when the list is empty
    description: "Review via native:<slug>"
    prompt: |
      Review the changes on this branch against base <branch> for production
      readiness. You have full access to the project. Read the tree, run
      `git merge-base` / `git diff` yourself — do not expect an inlined diff.
      Follow the requesting-code-review contract: Strengths, Critical Issues,
      Important Issues, Minor Issues, Assessment (Ready to merge: Yes/No/With
      fixes). Be specific: file:line.

      ## Tooling constraint

      Do NOT invoke any skill or slash command, and do NOT delegate this review to another agent or
      orchestration. Names like `claude-mesh:mesh-review` may be visible in your environment; they
      are not part of this task. Read the code with your own file, search and shell tools, and
      answer with the review itself.
  ```

- **claude:** for each `SELECTED_CLAUDE_MODELS` entry, `subagent_type: claude-mesh:claude-code-reviewer`, short prompt `MODEL=<alias>` on the first line, `BASE_BRANCH=<branch>` next when the argument was given, then `Review the changes for production readiness`. Name `claude:<alias>`. Roster `claude/<alias>` (`claude/opus`). If `claude` selected and the list is empty: one reviewer, **no MODEL line** (CLI default, `claude -p` without `-m`); roster `claude/_default`. Do **not** pass spawn `model: opus` — the alias lives on the prompt's `MODEL=` line. `HOST_CLAUDE=1` is the agent's job, not a spawn field.

  ```
  spawn_subagent:
    subagent_type: claude-mesh:claude-code-reviewer
    background: true
    description: "Review via claude:<alias>"
    prompt: |
      MODEL=<alias>
      BASE_BRANCH=<branch>
      Review the changes for production readiness
  ```

- **codex / gemini / grok / ext-claude:** the same short prompts as the HOST=claude-code bullets, `spawn_subagent` instead of Task, `background: true`. Do **not** pass `runtime.dispatch_model` unless that value is in `HOST_MODELS`. Do not pass `opus` as spawn `model:`. Grok still uses `MODEL=<entry>` on line 1; ext-claude still uses `MODEL=<id>` on line 1.

Display:
```
N code review агентов запущены параллельно в фоне:
  [list with descriptions]

Ожидаю результаты. Вы можете продолжать работу — я сообщу, когда ревью завершатся.
```

**Do NOT block.** Continue accepting user instructions while agents work.
When each agent completes, read its output. After all agents finish (or the user cancels some), proceed to **Step 6: Process Results**.

**Wait — HOST=claude-code.** **CRITICAL — a wrapper's report does NOT arrive on its own: disk-watch the runs and ping idle wrappers.** A wrapper launches its external engine (watchdog + CLI) as a background Bash task, sends an interim status naming its run dir (`runs/<engine>/…`), ends its turn and goes idle. The harness delivers NO task-notification to an idle subagent when that background task exits (verified 2026-07-10: 0 notifications in 5/5 smoke transcripts; wrappers sat 8–12 min over a finished `output.txt` until explicitly pinged). Treat the interim status as the last thing a wrapper says unprompted. After dispatch:

1. **Capture each wrapper's run dir** from its interim status. Fallback when a status names none: the newest dir under `$DATA_DIR/runs/<engine>/[<provider>/<model>/]` created after `DISPATCH_EPOCH` — the same discovery `verify-delegation.sh` uses (locate `DATA_DIR` as in Step 6.0 point 1).
2. **Watch the disk with `shared/watch-runs.sh`, launched as a background Bash task**, so "Do NOT block" above stays true — a foreground poll loop would hold the session hostage, and a background watcher that returns on each event re-invokes you per event. **Do NOT hand-roll a poller.** The improvised one exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

   ```bash
   LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
   [ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
   [ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
   WATCH="$(dirname "$LOADER")/watch-runs.sh"
   [ -x "$WATCH" ] || { echo "watch-runs.sh missing or not executable at $WATCH" >&2; exit 1; }
   "$WATCH" --since <DISPATCH_EPOCH> codex grok/grok-4.6 ext-claude/zai/glm ext-claude/ollama/kimi
   ```

   Substitute the **actual** `DISPATCH_EPOCH` number you stamped in Step 5. A shell variable does not survive from one Bash call to the next, and an unset name in a prompt raises nothing at all — the script rejects an implausible `--since` rather than silently watching a window that ended in 1970.

   The arguments after the options are a **roster** of `engine[/provider/model]` — the subpath under `runs/` — not run directories. The depth follows the engine: `codex` and `gemini` have none, `grok` takes one segment (`grok/grok-4.6`, matching `runs/grok/<model>/`) and `ext-claude` takes two. Note the SLASH: the watcher roster spells a grok reviewer `grok/grok-4.6` where the dispatch pair and the reviewer name spell it `grok:grok-4.6`; the two are never interchangeable. A wrapper whose run dies and is re-run creates a new run dir, so the watcher re-resolves the newest one at/after `--since` on every tick and follows it by itself. Pass only the wrappers you are still waiting for (point 5).

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

   **After a second unanswered ping, read the run yourself and stop waiting.** The file is `<run dir>/output.txt`, or `<run dir>/final/output.txt` when the root one is empty — the same file the wrapper would have read, and the same one `verify-delegation.sh` judges. Take the findings from it and attribute them to that reviewer exactly as if it had reported. Read `output.txt`, never `report.md`: the latter is the whole run rendered by the wrapper's report generator and runs to 137–250 KB in practice, while `output.txt` is the review itself (11 KB for a large one).

   A wrapper's report is a delivery mechanism, not the result, and delivery is the part that fails. The harness sends an idle subagent no notification when its background task exits, and a composed report can be lost in transit on top of that: on 2026-08-05 an `alibaba/qwen` run finished with `num_turns=22` and an 11428-byte review on disk while the orchestration recorded that model as having produced nothing across five runs and dropped it from the cross-validation. **Never record a reviewer as silent, dead or empty-handed while `verify-delegation.sh` scores its run `REAL`** — that verdict is precisely the statement that the file holds an agentic review, and it is made from the disk, which no delivery can lose.
4. **A `SILENT`, `FAILED` or `MISSING` run is dead — send it to Step 6.0**, which classifies it mechanically, rather than waiting out the budget over a run that will never change. Do **not** re-dispatch it here: `watchdog.sh` already restarts the CLI up to twice inside the run, and Step 6.0 owns the wrapper-level retry via `max_redispatch`. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact a wrapper died, and the two call for different actions. A **silent wrapper over a finished run is not one of these three** — that is point 3's case, and its review is on disk waiting to be read.
5. **Pass only the wrappers you are still waiting for.** The watcher assumes every roster entry is running, so an entry you have already handled comes straight back as news. If the watcher returns twice in a row with the same reason, you did not narrow the roster. Stop watching once the roster would be empty.
6. **Repeat** until every dispatched wrapper has reported, is dead, or the watch budget expires; whatever is still silent lands in Step 6.0. Never interpret wrapper silence as "no findings".

**Anything a wrapper says while the watch is running is a free liveness check.** Before replying to an interim status, a progress note or a question, run one `"$WATCH" --since <the same epoch> --once <current roster>` — re-resolve `$WATCH` with the same lines as in point 2 first; it does not survive between Bash calls — and act on the rows. On 2026-07-26 six such messages arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command. `--once` reports `CHANGED` when something has already died, so the answer names the death rather than handing you a table to compare by eye.

> Sync note: points 1–6 are mirrored in `skills/mesh-design-review/SKILL.md` (Step 6) — in substance, not byte for byte, and four things are not mirrored at all. Work out which kind you are touching before copying anything across.
>
> **Mirror the substance.** The status table, the roster explanation, the `--since` warning, the "every verdict exits 0" contract, point 5 and the `--once` liveness rule just above this note say the same thing in both files and must go on saying it: when you change what one of them says, change the other. Do not paste bytes — each copy is worded to its own file (`wrapper` in `/mesh-review`, `executor` in design review), names its own cross-references (where `DISPATCH_EPOCH` was stamped; the "Do NOT block" instruction only `/mesh-review` has) and describes its own retry model (a run re-dispatched by `/mesh-review` versus one that self-retries under design review).
>
> **Never mirror these four.** (1) Points 1–2 resolve paths differently by construction: `/mesh-review` reads `$DATA_DIR` and finds its loader through `${CLAUDE_PLUGIN_ROOT}` with a version-sorted `find` fallback, because the harness substitutes that placeholder into a command file's text; a skill gets no such substitution, so design review starts from the base path Claude Code prints at load (`SKILL_BASE`) and asks the loader for `data-dir`. Copying either block across breaks path resolution outright. (2) Point 3: design review runs the `verify-delegation.sh` content gate inline before pinging, while `/mesh-review` pings on `DONE` and only reaches the same check later, in its own mechanical classification step. (3) Point 4: a dead run goes to Error Handling in design review, whose only retry layer is `watchdog.sh` inside the run, and to Step 6.0 in `/mesh-review`, which classifies it mechanically and owns a second, wrapper-level retry layer; the retry sentence that closes the point differs with the routing. (4) Point 6's closing clause: `/mesh-review` hands whatever is still silent to that same step, while design review instead records that the loop covers its wrapper executors only. That clause names the class, not a list of engines, on purpose: a roster spelled out here has to be re-spelled in the sibling every time an engine is added, and the two copies drift the moment one of them is missed.
>
> Do not restore parity by copying the gate or the routing across, and do not delete either: each file checks a finished run's content exactly once and routes a dead run exactly once, and a copy of either in the other file would be the weaker of the two.

**HOST=claude-code:** the builtin `claude` reviewers are exempt: they review inline, create no `runs/<engine>/…` dir and complete on their own. Never wait for a run dir for them and never ping them. Native is not a separate spawn.

**Wait — HOST=grok.** No sleep poller. Completions arrive as harness notifications on the `spawn_subagent` ids; fetch each with `get_command_or_subagent_output`. A wait-all on several ids is allowed; each call's `timeout_ms` ≤ 600000. Loop until every child has finished or `runtime.timeouts.global_sec` elapses. There is no SendMessage.

- **Native** is not on the watcher roster. The result is the child's text. Step 6.0 marks each `native:<slug> INLINE`. `verify-delegation.sh is never invoked for native`.
- **Wrappers** (codex / gemini / grok / ext-claude / Grok-host `claude`) still go through `watch-runs.sh` + `verify-delegation.sh`. Include `claude/opus` on the roster when a Grok-host claude wrapper was dispatched — depth 1, like grok: `claude/opus` matching `runs/claude/opus/`. Example: `"$WATCH" --since <DISPATCH_EPOCH> claude/opus grok/grok-4.6 ext-claude/zai/glm`. Then `bash "$VERIFY" claude opus <DISPATCH_EPOCH> "$DATA_DIR"`. Empty-catalog fallback: roster may still list `claude/_default` (T4 writes that dir); **If MODEL was omitted, skip verify-delegation** for that reviewer — do not pass `_default` to the guard — and read the run dir.
- **Silent wrapper + `REAL`:** read `<run dir>/output.txt` yourself (or `final/output.txt` when the root file is empty). That is the **primary** collection path on Grok, not the "after two pings" fallback. No SendMessage.

After dispatch, print the same "N agents running, do not block" line as HOST=claude-code.

## Step 5b: Team of reviewers mode

**HOST=grok never runs team.** Step 0 / Step 4 already STOP with `На Grok team mode не поддерживается — остановите запуск и используйте background.` If you reach this step on Grok, that is a bug — stop and use Step 5a (background). Grok has no TeamCreate.

1. Generate the team name via a **Bash tool call** (which has a real `$$`, unlike the slash-command context which does not): `TEAM_NAME="code-review-$(date +%Y%m%d-%H%M%S)-$$"; DISPATCH_EPOCH=$(date +%s); echo "$TEAM_NAME $DISPATCH_EPOCH"`. Use the first value as the TeamCreate name (timestamp+PID suffix prevents collisions when two `/mesh-review` invocations run concurrently; on collision, regenerate). **Keep `DISPATCH_EPOCH`** and the same `engine:model` wrapper list as Step 5a (excluding the builtin `claude` reviewers — all of them) — Step 6.0's guard needs both. iter-3 QUESTION-1: do not paste a literal `<pid>` — there is no shell `$$` in the slash-command context itself.
2. Create one task per selected reviewer — with several Claude models selected that means one task per Claude model (`claude:opus`, `claude:fable`), not one shared `claude` task; and **one task per entry of `SELECTED_GROK_MODELS`**, named `grok:<model>`, exactly as Step 5a dispatches them — never one shared `grok` task, and none at all when that list is empty
3. Spawn teammates via Task tool with `team_name: "<the same unique name>"`, using the **same short per-reviewer prompts as Step 5a** (see the CRITICAL note there) — team mode does NOT change the prompt rules. Wrapper reviewers (codex / gemini / grok / ext-claude) must still receive ONLY the short delegation prompt, never an inlined review task — including grok's `MODEL=<entry>` first line and the `BASE_BRANCH=<branch>` line under it, which are parameters and not review content. The Step 5a **Dispatch model** rule *and its claude exception* also apply here: add `model: "<DISPATCH_MODEL>"` to each teammate Task dispatch when `DISPATCH_MODEL` is non-empty, otherwise omit it — except claude teammates that carry an explicit model, which each use their own entry from `SELECTED_CLAUDE_MODELS`. When that list is empty, `DISPATCH_MODEL` governs the single fallback claude teammate like any other.
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

**Run this BEFORE Step 6.1.** Wrapper reviewers (codex / gemini / grok / ext-claude, and on HOST=grok also `claude`) non-deterministically *flip*: they skip their `*-code-review` skill and self-review inline on this session's own model — a polished review that is **NOT** external cross-validation and leaves **no** `runs/<engine>/…` artifacts. The Step 5 prose forcing reduces this but does not eliminate it (the agent defs are already maxed and still flip). This step catches it **mechanically by inspecting on-disk artifacts** — do NOT trust the text a wrapper returned. The inverse failure also exists: a wrapper whose run is `REAL` on disk but which never sent a report is not a flip — it is idle (wrappers do not wake when their background run finishes); collect it per the Step 5a wait (HOST=claude-code: ping; HOST=grok: read `output.txt` yourself) before classifying.

**HOST=claude-code:** the builtin `claude` / `general-purpose` reviewers (one per selected Claude model, or a single fallback one) are **skipped by the guard** — they review inline by design, so every one of them whose Task actually completed is accepted into Step 6.1. `verify-delegation.sh` is never invoked for them. (A claude reviewer whose Task errored is the exception — see the `FAILED` rule below.) Native is not a separate spawn.

**HOST=grok:** native reviewers are **skipped by the guard**. `verify-delegation.sh is never invoked for native`. Each completed native child is `native:<slug> INLINE` (session-model fallback: a single `native` row). A native spawn the host rejected is `FAILED` — record it, do not substitute another slug, `max_redispatch` does not apply. `claude:*` is a wrapper: `verify-delegation.sh claude <alias>` (`claude opus` for `claude:opus`). **If MODEL was omitted, skip verify-delegation** for that reviewer — do not pass `_default` to the guard (leading `_` is a usage error, not a verdict) — and read `runs/claude/_default/` yourself. Other wrappers unchanged.

Run points 1 and 2 in the SAME Bash call: `$VERIFY` and `$DATA_DIR` are stamped in point 1's fence and do not survive into a second call, and `bash "" …` is not a verdict but a "No such file or directory".

**1. Locate the loader, data dir, and guard:**
```bash
# Same resolution as Step 1 — the guard MUST come from the plugin copy that is actually
# running, otherwise a --plugin-dir dev load verifies with the installed cache's guard.
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
VERIFY="$(dirname "$LOADER")/verify-delegation.sh"
DATA_DIR="$("$LOADER" data-dir)"
N="$("$LOADER" get-runtime | jq -r '.max_redispatch // 1')"; [[ "$N" =~ ^[0-9]+$ ]] || N=1
```

**2. Classify each dispatched wrapper.** Iterate the `engine:model` list stamped in Step 5 (substitute the ACTUAL dispatched pairs). On HOST=grok include `claude:<alias>` (`claude:opus`); do **not** include native — `verify-delegation.sh is never invoked for native`:
```bash
# example — replace the list with what was actually dispatched:
# HOST=claude-code (no claude: pairs — those are INLINE):
for spec in "codex:-" "grok:grok-4.6" "ext-claude:zai/glm" "ext-claude:ollama/kimi"; do
  eng="${spec%%:*}"; mdl="${spec#*:}"
  printf '%-28s ' "$spec"
  bash "$VERIFY" "$eng" "$mdl" <DISPATCH_EPOCH> "$DATA_DIR"   # prints REAL|FLIP|STALLED|BROKEN|DEGRADED|KILLED; reason on stderr
done
# HOST=grok (claude is a wrapper; native is not in this loop):
# for spec in "claude:opus" "codex:-" "grok:grok-4.6" "ext-claude:zai/glm"; do
#   … bash "$VERIFY" claude opus <DISPATCH_EPOCH> "$DATA_DIR"
```


A grok pair carries the BARE catalog id (`grok:grok-4.6`), never a `<provider>/<short>` pair. `verify-delegation.sh` rejects an empty model, `-`, and any spelling outside `[A-Za-z0-9][A-Za-z0-9._-]*` — a slashed `grok zai/glm` included — with a usage error and exit 1, printing NO verdict. Read that as "fix the argument", never as a statement about the reviewer: `FLIP` would prescribe a re-dispatch, and re-dispatching cannot repair a call the script refuses to answer. The rejection is what stops `runs/grok/<provider>/<short>` — a path nothing ever writes — from being reported as a reviewer that never delegated.

Substitute the **actual** `DISPATCH_EPOCH` number — the one stamped in Step 5, or the fresh one from step 4a on a re-dispatch round — exactly as in the Step 5a watcher call. A shell variable does not survive from one Bash call to the next, and `DISPATCH_EPOCH` was stamped in a different one; left as `"$DISPATCH_EPOCH"` it expands to nothing and the guard prints its usage line and exits 1 for every reviewer, which is not a verdict at all.
Verdicts:
- `REAL` (exit 0) — delegated, real review → **keep** for Step 6.1.
- `FLIP` (exit 3) — no run dir → self-reviewed on the session model → **re-dispatch**. One `FLIP` reason reads differently and is not about the wrapper: `N run dir(s) in the dispatch window belong to another session`. The runs are there, but they carry an id this session does not have — either this session was resumed or forked since Step 5, or the wrapper really did flip and another orchestration's runs happen to sit in the same window on the same model. The guard cannot tell those two apart and deliberately does not guess. Re-dispatch anyway: a fresh run is stamped with this session's id and verifies honestly, which is the only way back to a checkable answer. What changes is how it is reported if it does not recover — see step 5.
- `STALLED` (exit 2) — run dir but died mid-flight / delivered nothing usable → **re-dispatch** (retry helps). For ext-claude **and grok** — they share one branch of the guard because they share the stream format — that is a missing result event; for codex and gemini, a stream with no `turn.completed` / `result` event, or a non-zero watchdog exit that is not a signal (see `KILLED`). It also covers a run that finished healthily and delivered a **notice instead of a review** — `output.txt` under 400 non-space bytes. That is not hypothetical: on 2026-08-05 `deepseek/v4-pro` twice returned "Ревью запущено … уведомлю вас по завершении" after 24 and 17 tool calls, and the older gate scored both `REAL`, so `/mesh-review` counted a model that said nothing among its cross-validating reviewers. Measured across 624 archived runs the floor moves exactly those two out of `REAL`, plus five that were `DEGRADED` on the same kind of text (an "approve this command" note, leaked tool grammar, a summary of a review that is not in the file).
- `KILLED` (exit 6) — a review **lost** to a signal from OUTSIDE the run: the watchdog's last `cleanup` carries 143 (SIGTERM) or 130 (SIGINT), no `watchdog.exit` sits beside it, so nothing inside the run chose to stop — and what the run left behind is not a usable review → **EXCLUDE, do NOT re-dispatch.** The verdict weighs the cost, not the signal: a run that had already delivered a real review before something killed its tail scores `REAL` and keeps its findings, on every engine. So `KILLED` never means "there may be findings on disk you are discarding" — there are none worth having, which is why there is nothing to ping for. The review itself was healthy right up to the signal; what failed is the launch, and an identical launch is killed identically. The usual sender is the harness capping a *foreground* Bash call at `BASH_MAX_TIMEOUT_MS` (ten minutes by default) and SIGTERMing it there — which is why the exec skills launch the engine as a background task. On 2026-08-05 this verdict did not exist, the five affected runs scored `STALLED`, and three re-dispatches died exactly as the runs they replaced. If the run dirs show this repeatedly, the wrapper is launching in the foreground and the fix is in the skill, not in another round.
- `BROKEN` (exit 4) — run dir but the engine finished without doing any work → **DROP, do NOT retry** (the engine itself is broken). For ext-claude **and grok** that is thinking-only / DSML grammar / `num_turns≤1` (the maximum across the stream's successful result events); for codex and gemini, a completed turn that ran no tool at all — narration rather than a review.
- `DEGRADED` (exit 5, ext-claude, grok, and HOST=grok `claude`) — a real, agentic review, but the CLI refused `N` of its tool calls: the reviewer never got outside the directory it was launched in, so it reviewed without the sibling sources it tried to open → **KEEP for Step 6.1, do NOT re-dispatch.** The findings are genuine; what is missing is everything the reviewer could not read, so treat any claim about code outside the project dir as a guess rather than a finding. A retry re-runs the same invocation and is denied identically, and the remedy is not an agent's to apply: the ext-claude run needs `--permission-mode bypassPermissions`, and an *installed* plugin only picks that up through a release — so on any copy predating that release this verdict is the expected outcome, not an anomaly. The reason line names the denial count and which tools were refused (`Read×2, Bash×1`), which says whether the reviewer lost source files, searches, or both. Before this verdict existed such a run scored `REAL`: every liveness signal (finalized, `is_error:false`, `num_turns` well above 1, non-empty output) is healthy on a reviewer that read nothing, which is why it needed a check of its own. **On grok the remedy differs and the reason line says so:** `grok-exec` already passes `--permission-mode bypassPermissions`, so a denial there is not the missing-flag case at all — it points at the CLI's own permission configuration (`~/.grok`, or a sandbox profile), not at a plugin release. **On HOST=grok `claude` the reason names `HOST_CLAUDE`:** that path already passes `--permission-mode bypassPermissions`, so a denial is the CLI's own config, not a missing plugin flag. The verdict is the same: keep the findings, do not re-dispatch.

**3. Show the delegation status table** so the user sees who really cross-validated:
```
| Reviewer            | Verdict | Action          |
|---------------------|---------|-----------------|
| native:<slug>       | INLINE  | ✅ по построению |
| claude:opus         | INLINE  | ✅ по построению (HOST=claude-code) |
| claude:opus         | REAL    | ✅ kept (HOST=grok, verify-delegation.sh claude opus) |
| ext-claude:zai/glm  | REAL    | ✅ kept          |
| grok:grok-4.6       | REAL    | ✅ kept          |
| codex               | FLIP    | ↻ re-dispatch   |
| ext-claude:ollama/… | BROKEN  | ✗ dropped       |
| ext-claude:deepseek/… | DEGRADED | ⚠ kept — 14 denials, partial context |
| ext-claude:alibaba/… | KILLED  | ✗ excluded — killed from outside at 600s |
```

A `DEGRADED` row must say **how many** tool calls were denied — the count is the whole content of the verdict, and a row that hides it reads like a `REAL` with decoration.

`INLINE` is a label **you** write, not a `verify-delegation.sh` verdict. On HOST=claude-code: include one row per claude reviewer (a single row named `claude` in the fallback case). On HOST=grok: include one `native:<slug> INLINE` row per native child (a single `native` row in the session-model fallback); `claude:*` is **not** INLINE — it is `verify-delegation.sh claude <alias>`. The table is the complete roster of who actually reviewed — a table that silently omits them understates the cross-validation.

**`INLINE` is for a reviewer that actually returned a review** (HOST=claude-code `claude:*`; HOST=grok `native:<slug>`). If its spawn/Task errored — HOST=claude-code: a `claude_models` entry this Claude Code build does not accept; HOST=grok native: a slug the host rejected — give it a `FAILED` row instead and contribute nothing from it to Step 6.1. Do **not** substitute another slug:

| Reviewer     | Verdict | Action                          |
|--------------|---------|---------------------------------|
| claude:opus  | INLINE  | ✅ по построению                 |
| claude:opuss | FAILED  | ✗ dispatch failed — no findings |

Then continue with the remaining reviewers, per the existing rule "One agent fails, others succeed". Do **NOT** stop the whole review, and do **NOT** silently re-dispatch that reviewer on a different model: a failed dispatch is the *only* signal that a model name is wrong (design §13 — there is no way to verify after the fact which model a subagent really ran on), and quietly substituting another model destroys it. The user asked for N independent models and must be able to see they got N-1.

**4. Auto-redispatch loop (max `N` rounds; `N` = `runtime.max_redispatch`, default 1). `max_redispatch` is wrappers only** — never native, never a HOST=claude-code INLINE claude reviewer. A native spawn the host rejected is `FAILED` and is not a `PROBLEM`.

`PROBLEMS` = reviewers whose verdict is `FLIP` or `STALLED` — **not** `BROKEN`, **not** `DEGRADED`, **not** `KILLED`. All three are already final: a broken engine repeats itself, a denied reviewer is denied identically on the next run because nothing about the invocation changed, and a killed run is killed again by whatever sent the signal. While `PROBLEMS` is non-empty AND rounds-done < `N`:
  - **a. Stamp a fresh window** via Bash: `DISPATCH_EPOCH=$(date +%s)` — so the guard inspects the NEW run, not the old failed one.
  - **b. Re-dispatch ONLY the `PROBLEMS` reviewers** with the EXACT same short delegation prompt as Step 5a — read the shape off that step's own bullets rather than restating it here, because a copy of it in this bullet is what went stale last time: `Review the changes for production readiness` for codex and gemini, carrying the `BASE_BRANCH=<branch> ` prefix when the argument was given; for grok, ext-claude, and HOST=grok `claude` the multi-line shape their bullets prescribe — `MODEL=<entry>` (grok) or `MODEL=<id>` (ext-claude) or `MODEL=<alias>` (Grok-host claude) ALONE on the first line, `BASE_BRANCH=<branch>` on the line directly under it when the argument was given, then `Review the changes for production readiness`. A retry that drops the base would review a different range than the attempt it replaces; a retry that puts `BASE_BRANCH=` at the head of the first line is refused by those agents, which is the whole reason their base goes on its own line. Same `subagent_type`, same run mode. Apply the HOST-branched Step 5a **Dispatch model** rule on re-dispatch too: HOST=claude-code add `model: "<DISPATCH_MODEL>"` when non-empty, else omit. **HOST=grok re-dispatch: do not pass DISPATCH_MODEL unless it is in HOST_MODELS** — never pass `opus` as spawn `model:`. Then collect reports via the HOST-branched Step 5a wait, with a roster of only these reviewers and the fresh `DISPATCH_EPOCH` from step a: HOST=claude-code disk-watch + ping; **HOST=grok re-dispatch wait: silent+REAL reads output.txt**, no SendMessage. **Do not treat the Task/spawn returning as the run finishing.** A wrapper launches its engine as a background Bash task, names the run dir and ends its turn, so the spawn completes within seconds of the launch — long before there is anything on disk. Without the watch loop, step c inspects a run dir that has barely been created, scores every re-dispatch `STALLED` (no `final`, no `output.txt`) or `FLIP` (no dir yet), and the whole `max_redispatch` budget is spent without one run ever finishing.
  - **c. Re-run the guard** (step 2) for those reviewers with the new `DISPATCH_EPOCH`; update their verdicts.
  - **d.** rounds-done++.

`BROKEN` reviewers are **never** re-dispatched — retry is futile (the fix is the USER swapping the model in `config.yaml` — agents never edit it — not retrying). `KILLED` reviewers are never re-dispatched either, for the opposite reason: the engine was fine and the launch was not, so the next identical launch dies the same way.

**5. Finalize:**
- `REAL` reviewers → their reviews enter Step 6.1 (dedupe/classify) as normal.
- Reviewers still `FLIP`/`STALLED` after `N` rounds → **EXCLUDE from cross-validation** and record in the Step 6.6 summary: `⚠ <reviewer> did not delegate after N attempts — NOT counted as external review (self-review on the session model / killed mid-flight)`.
- A reviewer whose final `FLIP` names a **session mismatch** is excluded on the same terms — a run this session cannot verify never counts as external cross-validation — but it is recorded for what was actually observed, not as a flip: `⚠ <reviewer>: N run dir(s) in the window carry another session's id — NOT counted as external review (this session's id does not match the one that dispatched them)`. "Did not delegate" would be a false statement about that reviewer: the run dirs exist, and if the id moved under the orchestration they hold its finished work.
- `BROKEN` reviewers → record: `⚠ <reviewer>: external engine produced no usable review (broken — ask the user to swap the model in config.yaml; agents never edit it)`.
- `KILLED` reviewers → record what actually happened, never "did not delegate": `⚠ <reviewer>: run terminated from outside after Ns (SIGTERM, no watchdog.exit) — NOT counted as external review; the review was alive when it was killed, so this is a launch problem, not a model problem`. Name the lifetime — a cluster of deaths at the same round number is the signature of a foreground Bash call hitting `BASH_MAX_TIMEOUT_MS`, and it tells the user the one thing that would fix it. The guard computes it from `watchdog.log` and puts it in the reason line as `after 601s`: copy that number, never estimate one. If the reason carries no lifetime clause the stamps were unparsable — say so instead of inventing a figure.
- The builtin `claude` reviewers' findings always enter Step 6.1 on HOST=claude-code — every one of them whose Task completed, one entry per selected Claude model (or the single fallback reviewer). On HOST=grok, native `INLINE` findings enter the same way; `claude:*` is a wrapper and follows the `REAL`/`FLIP`/… rules (`verify-delegation.sh claude <alias>`). The ones marked `FAILED` above contribute nothing; they are never re-dispatched on a substitute model.

**Do NOT silently accept a FLIP as an external review.** A flipped wrapper is the session's model reviewing its own work; counting it as independent cross-validation is the exact failure this guard exists to prevent.

> **Concurrency note:** the guard picks the newest run dir for an engine/model created at/after `DISPATCH_EPOCH` **that carries this session's id** — the `*-exec` skills stamp `$CLAUDE_CODE_SESSION_ID` into `<run dir>/.session_id`, and the guard walks past anyone else's. Two `/mesh-review` invocations in two different Claude Code sessions therefore no longer see each other's runs, even on the same model and the same shared data dir. Two invocations *inside one session* still share an identity and can still overlap on a model; run those sequentially if exact attribution matters. Runs left by an older plugin version carry no stamp and stay eligible on purpose — reporting a live unstamped run as "never delegated" would be worse than the collision.

### Step 6.1: Deduplicate, Verify, and Classify

1. **Deduplicate:** If multiple agents found the same issue (same file, same problem), merge into one entry. Note all agents that found it. Claude reviewers are attributed as `claude:<model>` (`claude:opus`, `claude:fable`); a single fallback reviewer is just `claude`. Two different Claude models reporting the same issue is corroboration — exactly like codex and ext-claude agreeing — so merge them into one entry that lists both, never collapse them into a nameless "claude". Grok reviewers are attributed the same way, as `grok:<model>` (`grok:grok-4.6`) — two grok models reporting one issue is corroboration exactly as two Claude models are, so merge them into one entry that lists both and never collapse them into a nameless "grok".

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
commit. In this mode 6.4.b's first branch produces nothing **for the issues the command decides**,
and none of them is counted `B1` — an issue counted there would be an edit nobody committed,
because Step 6.5 is skipped below. Issues that branch had already applied BEFORE the hand-off — the
mode can be entered mid-phase, the command's state S1 — stay counted in `B1`: settle-the-tree
commits those edits, so the tally and git agree. 6.4.a's analysis format still applies unchanged,
and the command points back to it. The intro line for this mode is printed by the command, not here. Do not paste any part of its
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
commit per decision, so there is nothing left to stage. «In `autodecide` mode» here means
`AUTODECIDE` is true — the command binds it on the S3 path too, precisely so that this step and
Step 6.6 do not have to re-derive the mode from whether someone invoked a command earlier in the
session. Edits produced by the disputed phase before
the mode started — whichever way they were decided — are committed by the command's own "settle the
tree" rule at the start of its run.

**Skip it only if the tree is in fact clean of disputed-phase edits.** Two paths leave edits behind
that no commit of the command's covers: «стоп» arriving before its first decision, so settle-the-
tree never ran; and the user cutting in mid-run to choose a variant themselves. If `git status`
shows such edits, run this step normally instead of skipping it — **excluding every path a failed
decision commit left changed.** The command names that set when it hands back: its own files plus
anything a hook touched on the way to failing. Those are uncommitted on purpose, for the user to
look at; sweeping any of them in here would record a failure as a decision, under a message that
names neither.

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
