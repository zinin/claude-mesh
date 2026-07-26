# Multi-Model Claude Reviewers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `/claude-mesh:mesh-review` and `/claude-mesh:mesh-design-review` to launch several independent built-in Claude reviewers, each on a different Claude model (e.g. `opus` and `fable`), instead of exactly one reviewer pinned to the global `runtime.dispatch_model`.

**Architecture:** A new optional `claude:` config section holds a catalog of Claude model aliases; a new per-preset key `defaults.<preset>.claude_models` holds the default selection. `config-loader.sh` validates both and exposes them through two new subcommands plus one extended getter. The two orchestrators (`commands/mesh-review.md`, `skills/mesh-design-review/SKILL.md`) read the catalog, offer a selection page in the interactive UI, and dispatch one `general-purpose` subagent per selected model with an explicit `model:` override. When no Claude models are configured or selected, the *review behaviour* is what it is today: one reviewer on `dispatch_model` (or on the session model). "Byte-for-byte" would be too strong a claim — the `get-defaults` JSON gains a `claude_models` key, the Step 1 / Step 5.0 shell transcripts gain two echoed variables, the Step 6.0 roster gains a row, and `config.example.yaml` changes `design_review.builtin` (that last one is the intended bug fix, and it only affects users who re-copy the example). What is guaranteed is narrower and is the part that matters: **an existing `config.yaml` with no `claude:` section dispatches the same number of claude reviewers, on the same model, as before.**

**Tech Stack:** bash 4+ (`config-loader.sh`, test harness), `jq`, Python-yq (`kislyuk/yq`), Claude Code plugin markdown (commands and skills are prompts, not code).

**Spec:** `docs/superpowers/specs/2026-07-26-multi-model-claude-reviewers-design.md`

## Global Constraints

- **Bash 4+, `set -u`.** No associative arrays — duplicate checks use the line-based accumulator idiom already in `validate_models` (`config-loader.sh:207`, `case " $seen_ids " in *" $id "*)`).
- **All config reads go through `config-loader.sh`.** Commands and skills never call raw `yq`/`jq` on `config.yaml`.
- **`die`/`warn` messages are English.** User-facing prose inside `commands/*.md` and `skills/*/SKILL.md` is Russian. Both conventions already hold in the repo — do not mix them.
- **No model enums.** Charset validation only, via the existing `IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._:@-]*$'` (`config-loader.sh:57`). A new Claude model must never require a plugin release.
- **Agents never edit `config.yaml`.** Validation errors are surfaced to the user verbatim.
- **`skills/shared/verify-delegation.sh` is not modified** and is never called for a Claude reviewer.
- **`runtime.dispatch_model` keeps its current meaning** for codex/gemini/ext-claude wrappers, the `review-discussion` agent and `/do-plan` subagents.
- **Full test suite must end green after every task:** `bash skills/shared/tests/test-config-loader.sh` → last line `=== Summary: N passed, 0 failed ===`, exit 0. Baseline before this change: `180 passed, 0 failed`.
- **Never assert an exit code through a pipe.** `bash …test-config-loader.sh | tail -20` returns *tail's* status, so "exit 0" / "the script exits 1" is unobservable that way — `( exit 1 ) | tail -1; echo $?` prints `0`. Where a step below pipes the suite into `sed`/`tail` for readability, that is a *display* convenience only. When the exit code is the thing being checked, run it unpiped and capture rc, or prefix `set -o pipefail`.
- **One commit per task. Never push.** Branch is `feature/multi-model-claude-reviewers` (already created, spec committed as `782ebd0`).
- **`subagent_type: "general-purpose"` is a BUILT-IN agent type — not `claude-mesh:`-namespaced.** Plugin agent types are namespaced; this one is not.
- Line numbers in this plan are as of commit `782ebd0`. If an anchor moved, locate it by the quoted text, not by the number.
- **The fallback rule is written four times — keep the four texts word-identical.** It appears in `commands/mesh-review.md` Step 0 and Step 2.4, and in `skills/mesh-design-review/SKILL.md` Step 5.1 and Step 5.2.5. The canonical wording is the Step 0 one:

  > list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`, which **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
  > list absent/empty → exactly **one** reviewer named `claude`, dispatched with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise with no `model:` at all (inherits the session model).

  Three lexical variants of one rule is a real hazard here: these files are instructions for an LLM, which has no way to tell "differently worded" from "deliberately different". Above each of the four blocks put a marker naming its siblings, e.g. `<!-- SYNC: same rule in skills/mesh-design-review/SKILL.md Step 5.1 / 5.2.5 -->`, so the next editor changes all four or none.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `skills/shared/config-loader.sh` | Parse + validate the `claude:` catalog and `defaults.*.claude_models`; expose them via `get-flag has_claude_models`, `list-claude-models`, `get-defaults` | 1, 2, 3, 4 |
| `skills/shared/tests/test-config-loader.sh` | Tests 47–51 for all of the above | 1, 2, 3, 4, 5 |
| `config.example.yaml` | Documents the new section and preset key | 5 |
| `commands/mesh-review.md` | Reads the catalog, adds the selection page, fans out the dispatch, attributes findings | 6 |
| `skills/mesh-design-review/SKILL.md` | Same, plus the fix for `claude` being silently ignored | 7 |
| `README.md`, `CHANGELOG.md` | User-facing documentation of the feature and the fix | 8 |

---

## Task 1: Validate the `claude:` catalog
✅ Done — see commit `03ae1e0`. Adds `validate_claude()` (type gate, `IDENT_RE` charset, no enum,
duplicate rejection, side-effect-free) and wires it into `validate_all()` between `validate_gemini`
and `validate_defaults`. Test 47.

---

## Task 2: Validate `defaults.<preset>.claude_models`
✅ Done — see commit `70cde80`. `validate_defaults()` calls `validate_claude` after the `.defaults`
early-return, reads the catalog, then per preset: type gate, fail-closed `claude` -in-`builtin` check,
element type gate, empty check **before** membership, membership, duplicates. Test 48 plus one added
assert pinning `validate_claude`'s side-effect-freedom under its now-real double call.

---

## Task 3: Expose the catalog — `get-flag has_claude_models` and `list-claude-models`
✅ Done — see commit `200f6a6`. Both subcommands validate before reading inside the section; the
`get-flag` unknown-feature `die` and the usage line list the new names; `cmd_get_flag`'s header
contract was corrected (it claimed "Exit: 0 always"). Test 49.

---

## Task 4: `get-defaults` emits `claude_models`
✅ Done — see commit `33b51e9`. The JSON object gains `claude_models`, always present, `[]` when
absent, never null. Test 50 plus an added case pinning the clean death of `get-defaults` on
`claude: false` + a `defaults:` section — the only thing distinguishing the `validate_claude` call
inside `validate_defaults`.

---

## Task 5: Document the schema in `config.example.yaml`
✅ Done — see commit `2f7fa7f`. Section (3) renamed to "Built-in reviewers", `claude:` catalog block
added with the gate asymmetry and cost note, `claude_models` added to both presets with deliberately
different sets, `design_review.builtin` gains `claude`. Test 51 plus an added assert covering
`models` length and `run_mode` for both presets. Fallback wording is version-agnostic — the plan's
"pre-0.5" phrasing was dropped, see SESSION CONTEXT.

---

## Task 6: `/mesh-review` — read, offer, dispatch, attribute
✅ Done — see commit `568961c`. All nine steps applied: Step 0 fan-out and `SELECTED_CLAUDE_MODELS`
binding, Step 1 rc-aware catalog reads, new Step 2.4 selection page, Step 2.5 expansion, Step 5a/5b
dispatch exception and plural rewrites, Step 6.0 `INLINE`/`FAILED` roster rows, Step 6.1 attribution.
Plus two SYNC markers and two controller-approved additions — see SESSION CONTEXT.

---

## Task 7: `/mesh-design-review` — same capability, plus the ignored-`claude` fix

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (Step 5.0 bash fence `:236-243`; Step 5.1 `:247-258`; Step 5.2 `:260-275`; new Step 5.2.5 before `#### Step 5.3` at `:277`; Step 5.4 `:296-310`; Step 6 `:312-358`; Step 7 `:360-389`)

**Interfaces:**
- Consumes: `get-flag has_claude_models`, `list-claude-models` (Task 3), `get-defaults design_review` `.claude_models` (Task 4)
- Produces: nothing other tasks consume.

**Why this task also fixes a bug:** `config-loader.sh` accepts `claude` in `defaults.design_review.builtin`, but Step 5.1 only expands `codex` and `gemini`, and Step 5.2's Q1 has no `claude` option — so today the value is silently dropped and design review never runs a Claude reviewer at all.

- [ ] **Step 1: Read the catalog (Step 5.0)**

**1a. Make the existing `DEFAULTS_JSON` read rc-aware first.** In the Step 5.0 fence, replace

```bash
DEFAULTS_JSON=$("$LOADER" get-defaults design_review)   # {"builtin":[...],"models":[...],"run_mode":null}
```

with

```bash
# rc-aware, like the dispatch_model read below. A bare $() swallows the loader exit code
# (the fence says so 14 lines above, for has_codex) — and get-defaults is what runs
# validate_defaults, so the new fail-closed claude_models guard reports through THIS call.
# Swallowed, it leaves DEFAULTS_JSON empty and Step 5.1 then STOPs with the misleading
# "defaults.design_review not configured" instead of the real validation error.
DJ_ERR=$(mktemp)
DEFAULTS_JSON=$("$LOADER" get-defaults design_review 2>"$DJ_ERR") \
    || { echo "config.yaml невалиден (defaults.design_review):" >&2; cat "$DJ_ERR" >&2; rm -f "$DJ_ERR"; exit 1; }
rm -f "$DJ_ERR"   # {"builtin":[...],"claude_models":[...],"models":[...],"run_mode":null}
```

**1b.** In the Step 5.0 bash fence, after

```bash
rm -f "$DM_ERR"
echo "DISPATCH_MODEL=$DISPATCH_MODEL"   # empty = inherit session model on dispatch
```

append (inside the same fence):

```bash
# Claude-model catalog (Step 5.2.5 gate). rc-aware like the dispatch_model read above:
# both subcommands validate the `claude:` section, so a malformed section fast-fails here.
CM_ERR=$(mktemp)
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (секция claude):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
CLAUDE_MODELS=$("$LOADER" list-claude-models 2>"$CM_ERR") \
    || { echo "config.yaml невалиден (claude.models):" >&2; cat "$CM_ERR" >&2; rm -f "$CM_ERR"; exit 1; }
rm -f "$CM_ERR"
echo "HAS_CLAUDE_MODELS=$HAS_CLAUDE_MODELS"
echo "CLAUDE_MODELS=[$(echo "$CLAUDE_MODELS" | tr '\n' ' ')]"
```

Then, in the prose paragraph right below the fence, change

`Parse \`DEFAULTS_JSON\` with jq (\`.builtin\`, \`.models\`) to build \`DEFAULT_IDS\``

to

`Parse \`DEFAULTS_JSON\` with jq (\`.builtin\`, \`.claude_models\`, \`.models\`) to build \`DEFAULT_IDS\` (recommended ext-claude model ids), \`CLAUDE_DEFAULT_IDS\` (recommended Claude models)`

- [ ] **Step 2: Expand `claude` in `default` mode (Step 5.1) — the bug fix**

Replace the builtin-expansion bullets in Step 5.1:

```markdown
- For each entry in `.builtin`:
  - `codex` → spawn `claude-mesh:codex-executor`
  - `gemini` → spawn `claude-mesh:gemini-executor`
- For each model id in `.models` → spawn `claude-mesh:ext-claude-executor` with `MODEL=<id>`.
```

with:

```markdown
- For each entry in `.builtin`:
  - `claude` → expand over `.claude_models` (this branch was MISSING before 0.5, which is why `claude` in `defaults.design_review.builtin` used to be silently dropped):
    - list non-empty → **one `general-purpose` reviewer per entry**, each dispatched with `model: "<entry>"`, which **overrides** `DISPATCH_MODEL` for these reviewers. Name them `claude:<model>` everywhere downstream.
    - list absent/empty → exactly **one** reviewer named `claude`, with `model: "<DISPATCH_MODEL>"` when that is non-empty, otherwise no `model:` at all (inherits the session model).
  - **Bind `SELECTED_CLAUDE_MODELS` to that resolved list here** (`.claude_models`, or empty in the fallback case), exactly as `/mesh-review` Step 0 does. Step 5.4 remembers `SELECTED_CLAUDE_MODELS` for iterations 2..N, so in `default` mode it must actually hold something by then.
  - `codex` → spawn `claude-mesh:codex-executor`
  - `gemini` → spawn `claude-mesh:gemini-executor`
- For each model id in `.models` → spawn `claude-mesh:ext-claude-executor` with `MODEL=<id>`.
```

- [ ] **Step 3: Offer `claude` in the interactive Q1 (Step 5.2) — the second half of the fix**

Replace the options block:

```
options:
  - "codex CLI ★ default"                          — show only if HAS_CODEX=1; ★ if "codex" in defaults.builtin
  - "gemini CLI ★ default"                         — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.builtin
  - "external models (Anthropic-API) ★ default"    — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```

with:

```
options:
  - "claude ★ default (свой Claude Code)"          — show ALWAYS; ★ if "claude" in defaults.builtin
  - "codex CLI ★ default"                          — show only if HAS_CODEX=1; ★ if "codex" in defaults.builtin
  - "gemini CLI ★ default"                         — show only if HAS_GEMINI=1; ★ if "gemini" in defaults.builtin
  - "external models (Anthropic-API) ★ default"    — show only if HAS_MODELS=1; ★ if defaults.models is non-empty
```

and replace the parenthetical paragraph below it:

```markdown
(Show only the options whose gating flag is `1`. If none are available — no codex, no gemini, no models — STOP with "нет доступных reviewer-типов в config.yaml".) If "external models" is not selected → skip Step 5.3 entirely (only built-in executors run).
```

with:

```markdown
(Show the codex / gemini / external-models options only when their gating flag is `1`. The `claude` option is shown unconditionally — the built-in claude reviewer is your own Claude Code and needs no config section, so the old no-reviewer-types-available STOP is unreachable and has been removed.) If "external models" is not selected → skip Step 5.3 entirely. If `claude` is not selected → skip Step 5.2.5 and run no claude reviewer at all.
```

- [ ] **Step 4: Insert the new Step 5.2.5 selection page**

Insert this section immediately BEFORE the `#### Step 5.3 (Q2..Qn): Paginated model selection` heading:

```markdown
#### Step 5.2.5: Claude-model selection

Runs ONLY when Q1 selected `claude` **and** `HAS_CLAUDE_MODELS=1`.

- `claude` NOT selected in Q1 → skip; no claude reviewer runs at all, whatever the catalog holds.
- `claude` selected but `HAS_CLAUDE_MODELS=0` → skip; exactly **one** reviewer named `claude` runs, on `DISPATCH_MODEL` (or on the session model when that is empty).

For each chunk of 4 entries from `CLAUDE_MODELS` (config order) — same pagination and the same ★ convention as Step 5.3, because AskUserQuestion has no `preSelected` API:

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

**Empty selection is not an error** — it falls back to exactly one reviewer named `claude`, as in the `HAS_CLAUDE_MODELS=0` case. Do not re-ask, do not STOP.

Every selected model gets the SAME composed prompt — model diversity is the point, so never differentiate their prompts.
```

- [ ] **Step 5: Show the expanded set in the Step 5.4 confirmation**

In `#### Step 5.4: Confirm selection`, replace the opening sentence

`After Q1 (and pagination if it ran), show the full selected set — built-in TYPES plus \`SELECTED_IDS\` (one per line) — and confirm (mirrors mesh-review Step 3.5):`

with:

```markdown
After Q1 (and Steps 5.2.5 / 5.3 if they ran), show the full selected set — built-in TYPES plus `SELECTED_IDS` (one per line) — and confirm (mirrors mesh-review Step 3.5). **Expand `claude` into one bullet per entry of `SELECTED_CLAUDE_MODELS`** (`claude:opus`, `claude:fable`), or a single `claude (модель по умолчанию)` bullet in the fallback case, so the user sees how many Claude reviewers they are about to pay for.
```

and in the same block change the "Перевыбрать" description from `restarts Step 5.2 from Q1 with the same DEFAULT_IDS` to `restarts Step 5.2 from Q1 with the same DEFAULT_IDS / CLAUDE_DEFAULT_IDS (Step 5.2.5 re-runs too)`.

**Within one session's iteration loop the selection is reused, so the Claude models must be remembered alongside the rest of the set** — otherwise a second iteration in the same session drops back to a single reviewer. Two more edits:

**Scope of that guarantee — state it accurately, do not overpromise.** It holds *within a session*. It does **not** survive into a fresh session: Step 5 is explicitly "first iteration only", Step 15 states that iterations are always done in fresh sessions, and Step 16 hands off through `continue-plan-fresh-session` without serialising the reviewer set anywhere. A fresh-session iteration therefore re-runs the selection UI — exactly as it already does today for `SELECTED_IDS`. That is pre-existing behaviour shared by every reviewer type, not something this change introduces or worsens, and deliberately not fixed here: persisting the set belongs in a separate task that can cover built-ins, Claude models and ext-claude ids uniformly (and decide whether a fresh session should restore silently at all, which is not obvious — after a run where reviewers failed, re-picking is often what the user wants).

- last line of Step 5.4: replace `Remember the confirmed set (built-in TYPES + \`SELECTED_IDS\`) for all subsequent iterations in the loop.` with `Remember the confirmed set (built-in TYPES + \`SELECTED_CLAUDE_MODELS\` + \`SELECTED_IDS\`) for all subsequent iterations in the loop.`
- Step 5 preamble (`### Step 5: Select Review Agents (first iteration only)`): replace `remember the resulting agent set (built-ins + model ids)` with `remember the resulting agent set (built-ins + Claude models + ext-claude model ids)`.

- [ ] **Step 6: Dispatch the claude reviewers (Step 6)**

**6a.** In Step 6, right after the **Dispatch model** paragraph, insert:

```markdown
**Exception — claude reviewers with an explicit model.** When Step 5.2.5 (interactive) or the preset (`default` mode) resolved a non-empty set of Claude models, each of those reviewers is dispatched with `model: "<its own Claude model>"`, NOT with `DISPATCH_MODEL` — otherwise every claude reviewer would collapse onto one model and the independence would be fake. `DISPATCH_MODEL` still governs the codex / gemini / ext-claude executors and the `review-discussion` agent in Step 8.

**built-in `claude` reviewer(s)** — dispatch the composed Step 4 prompt **directly**. That prompt is already self-contained (task, documents, project + session context, PREVIOUS DECISIONS, review focus, output format), so there is no `Execute this prompt via…` wrapper and no skill to invoke:

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

**Claude reviewers are excluded from the disk-watch / ping loop below.** They create no `runs/<engine>/…` dir and finish on their own. Waiting for a run dir that will never appear — or pinging an agent that has already answered — is a bug, not diligence.

**If a claude reviewer's Task errors** — most likely a `claude_models` entry this Claude Code build does not accept — treat it exactly like a failed executor per Error Handling ("One agent fails, others succeed"): note the failure in the merged file, omit its section, continue with the rest. Never silently re-dispatch it on a different model: a failed dispatch is the only signal that a model name is wrong (design §13), and substituting another model hides it while pretending the cross-check happened.
```

**6b.** In the numbered watch-loop list further down the same step, change item 4's closing sentence

`treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings".`

to

`treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings". This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it.`

**6c.** The general namespacing rule at the top of Step 6 now sits next to a deliberately bare `subagent_type`. Replace

`For each selected agent, use Task tool (plugin \`subagent_type\`s are \`claude-mesh:\`-namespaced — verified on CC 2.1.156; bare names do not resolve).`

with

`For each selected agent, use Task tool (plugin \`subagent_type\`s are \`claude-mesh:\`-namespaced — verified on CC 2.1.156; bare names do not resolve). **Exception: \`general-purpose\` is a BUILT-IN agent type and is correctly bare** — never prefix it with \`claude-mesh:\`. The rule above is about *plugin* agents.`

**6d.** The collection sentence promises artifacts the claude reviewers never produce. Replace

`Collect output paths from every agent — but do NOT passively wait for completions: the watch loop below is what turns finished runs into reports.`

with

`Collect output paths from every **executor** (codex / gemini / ext-claude) — but do NOT passively wait for completions: the watch loop below is what turns finished runs into reports. Claude reviewers have no output path to collect: they create no \`runs/<engine>/…\` dir and return their review as the Task result.`

- [ ] **Step 7: Name the merged sections (Step 7)**

In the merged-file template, add a claude section as the first entry:

```markdown
# Merged Design Review — Iteration N

## claude:opus

[full output from the built-in claude reviewer on opus — one section per selected Claude model;
 a single fallback reviewer is titled just `claude`]

---

## codex-executor
```

- [ ] **Step 8: Verify the edits**

Run:

```bash
grep -c 'claude_models\|SELECTED_CLAUDE_MODELS\|HAS_CLAUDE_MODELS\|claude:<model>\|claude:opus' skills/mesh-design-review/SKILL.md
grep -n 'Step 5.2.5' skills/mesh-design-review/SKILL.md
grep -n 'нет доступных reviewer-типов' skills/mesh-design-review/SKILL.md
grep -n 'general-purpose' skills/mesh-design-review/SKILL.md
```

Expected:
- first prints a count `>= 12`
- second prints at least 3 hits (heading plus the references from Steps 5.2, 5.4)
- third prints **nothing** (the unreachable STOP is gone)
- fourth prints at least one hit (the new claude dispatch block)

Then read the file end-to-end and confirm:
1. Step 5.1 expands `claude` (the bug is fixed in `default` mode).
2. Step 5.2 offers `claude` unconditionally (the bug is fixed in interactive mode).
3. Step 5.2.5 exists and is gated on both conditions.
4. Step 6 dispatches `general-purpose` with the composed prompt directly and no wrapper line.
5. Step 6 states that claude reviewers are outside the watch/ping loop.
6. Step 7 shows the `claude:<model>` section naming.
7. Steps 5 and 5.4 remember `SELECTED_CLAUDE_MODELS` alongside the rest of the set, so a second iteration **in the same session** does not fall back to one reviewer. The text must scope that claim to the session and must not promise it across fresh sessions — nothing serialises the set, and `SELECTED_IDS` already behaves the same way.

- [ ] **Step 9: Run the loader suite (regression guard) and commit**

```bash
bash skills/shared/tests/test-config-loader.sh > /tmp/suite.out 2>&1; RC=$?; tail -3 /tmp/suite.out; echo "rc=$RC"
git add skills/mesh-design-review/SKILL.md
git commit -m "feat(mesh-design-review): run built-in claude reviewers, one per Claude model

The claude entry in defaults.design_review.builtin validated but was never
expanded — design review has never actually run a Claude reviewer. Adds the
missing branch in both default and interactive mode, and fans it out over
claude.models."
```

---

## Task 8: README and CHANGELOG

**Files:**
- Modify: `README.md` (Dependencies bullet at `:54`)
- Modify: `CHANGELOG.md` (`## [Unreleased]` section at `:5`)

**Interfaces:**
- Consumes: the finished behaviour from Tasks 1–7
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Update the README dependency bullet**

Replace `README.md:54`:

```markdown
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
```

with:

```markdown
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
  - `runtime.dispatch_model` governs the *plumbing*: the codex / gemini / ext-claude wrapper agents, the `review-discussion` agent, and `/do-plan` subagents. To choose the models that actually *review*, list them under `claude.models` and pick a per-preset default in `defaults.<preset>.claude_models`: `/mesh-review` and `/mesh-design-review` then run one independent built-in reviewer per model (e.g. `opus` and `fable` at once), and those reviewers ignore `dispatch_model`. Leave the section out and — whenever `claude` is selected at all (interactively, or via the preset's `builtin`) — you get exactly one claude reviewer on `dispatch_model`, as before. Without `claude` in play no claude reviewer runs, catalog or no catalog. **Cost scales linearly:** N Claude models = N full reviews of the same diff, on top of codex/gemini and every external model — three Claude models plus codex plus five external models is nine reviewers for one `/mesh-review`.
```

- [ ] **Step 2: Add the CHANGELOG entry**

Replace `CHANGELOG.md:5`:

```markdown
## [Unreleased]
```

with:

```markdown
## [Unreleased]

### Added
- Multi-model built-in Claude reviewers. A new optional `claude:` section holds a
  catalog of Claude model aliases (`claude.models: [opus, sonnet, fable]`), and a new
  per-preset key `defaults.<preset>.claude_models` picks the default subset. Both
  `/mesh-review` and `/mesh-design-review` now run **one independent reviewer per
  selected Claude model** — same diff, same prompt, different model — so a session on
  `opus` can be cross-checked by `opus` and `fable` at once and aggregate both. The
  interactive UI gains a Claude-model page (★ marks the preset's picks); `default` mode
  reads the preset. Reviewers are attributed as `claude:<model>` in the dedup table, the
  delegation roster (as `INLINE`, never passed to `verify-delegation.sh`) and the merged
  design-review file. Loader support: `get-flag has_claude_models`, `list-claude-models`,
  and a `claude_models` field in `get-defaults`.
  `runtime.dispatch_model` is unchanged and still governs the codex / gemini / ext-claude
  wrappers, `review-discussion` and `/do-plan`; claude reviewers with an explicit model
  ignore it. Configs without a `claude:` section keep the old behaviour exactly: one
  claude reviewer on `dispatch_model`, or on the session model when that is unset.

### Fixed
- `claude` in `defaults.design_review.builtin` was silently dropped. The loader accepted
  the value, but `/mesh-design-review` expanded only `codex` and `gemini` in `default`
  mode and offered neither a `claude` option in its interactive reviewer-type question —
  so design review had never once run a built-in Claude reviewer. Both paths now expand
  it. The related fail-closed guard is new too: `claude_models` set without `claude` in
  the same preset's `builtin` is now a validation error rather than another silently
  ignored list.
```

- [ ] **Step 3: Verify**

Run:

```bash
grep -n 'claude.models' README.md
sed -n '1,40p' CHANGELOG.md
```

Expected: the README bullet mentions `claude.models` and `defaults.<preset>.claude_models`; the CHANGELOG has both an `### Added` and a `### Fixed` block under `## [Unreleased]`, above `## [0.4.3]`.

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document multi-model claude reviewers"
```

---

## Task 9: Manual smoke

**Files:** none modified. This task produces a written result, not a diff.

**Interfaces:**
- Consumes: everything from Tasks 1–8
- Produces: a go/no-go on the feature. Nothing consumes it.

The orchestrators are prompts — the loader suite cannot prove they dispatch correctly. Only a real run can.

**Prerequisite:** the user's live `config.yaml` (`~/.claude/plugins/data/claude-mesh-zinin/config.yaml`) has no `claude:` section yet. **Do not edit it — agents never modify `config.yaml`.** Ask the user to add:

```yaml
claude:
  models: [opus, fable]
```

and, if they want `default` mode covered, `claude_models: [opus, fable]` to `defaults.code_review` and `claude_models: [opus]` to `defaults.design_review`.

- [ ] **Step 1: Validate the live config**

Run: `bash skills/shared/config-loader.sh validate && bash skills/shared/config-loader.sh list-claude-models`
Expected: exit 0, then `opus` and `fable` on separate lines.

- [ ] **Step 2: Smoke `/mesh-review` interactively**

Run `/claude-mesh:mesh-review` and select `claude` plus at least one other reviewer type.
Expected:
- the Claude-model page appears with `opus` and `fable`, ★ on the preset entries;
- the Step 2.5 confirmation lists `claude:opus` and `claude:fable` as separate bullets;
- two `general-purpose` Tasks are dispatched, carrying `model: "opus"` and `model: "fable"`;
- the Step 6.0 table has an `INLINE` row for each, and `verify-delegation.sh` is not called for them;
- findings are attributed `claude:opus` / `claude:fable`.

- [ ] **Step 3: Smoke the fallback path**

Ask the user to comment out the `claude:` section **together with both `claude_models:` keys**. Commenting out only the catalog leaves the preset lists orphaned, and the fail-closed guard added in Task 2 then makes the config invalid — every command fast-fails on validation and the fallback path never runs at all. That failure would look like a regression while actually being the new validator working correctly.

Then run `/claude-mesh:mesh-review` again and select `claude`.
Expected: no Claude-model page; exactly one reviewer named `claude` on `dispatch_model` (`opus` in the user's config). This is the back-compat guarantee — if it regresses, every existing config changes behaviour on upgrade.

- [ ] **Step 3b: Restore the config before continuing**

Ask the user to uncomment everything they commented out in Step 3, then confirm with `bash skills/shared/config-loader.sh validate && bash skills/shared/config-loader.sh list-claude-models`.
Expected: exit 0 and the catalog printed again. **Step 4 below asserts a `## claude:opus` section, which cannot appear while the catalog is still commented out** — skipping this restore makes Step 4 fail for the wrong reason.

- [ ] **Step 4: Smoke `/mesh-design-review default`**

Run `/claude-mesh:mesh-design-review default` on any design doc.
Expected: a claude reviewer actually runs (it never did before), and the merged file has a `## claude:opus` section alongside the codex/ext-claude ones.

- [ ] **Step 5: Report**

Write the outcome of Steps 1–4 into the task report: what ran, what each reviewer's `model:` was, and any deviation. If anything failed, fix it in the owning task's file and re-run — do not paper over it in the report.

- [ ] **Step 6: Commit (only if Step 5 produced fixes)**

```bash
git add -A
git commit -m "fix: address issues found in the multi-model claude reviewer smoke"
```

If nothing needed fixing, skip the commit — this task has no deliverable of its own.
