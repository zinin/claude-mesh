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

✅ Done — see commit `ee6b552`. Step 5.0 gains an rc-aware `get-defaults` read plus the two catalog
reads; Step 5.1 expands `claude` (the bug fix) and binds `SELECTED_CLAUDE_MODELS`; Step 5.2's Q1 offers
`claude` unconditionally and the unreachable no-reviewer-types STOP is gone; new Step 5.2.5 selection
page; Step 5.4 expands the confirmation and remembers the Claude models; Step 6 dispatches
`general-purpose` with the composed prompt directly and carves claude reviewers out of the watch loop;
Step 7 names merged sections `claude:<model>`. Plus two `<!-- SYNC -->` markers and four controller
resolutions — see SESSION CONTEXT.

---

## Task 8: README and CHANGELOG

✅ Done — see commit `364884d` (amend chain e2b4d80 -> 7793bdf -> 364884d). README's dependency bullet
gains the `claude.models` / `defaults.<preset>.claude_models` sub-bullet with the linear-cost note and
the unvalidated-catalog caveat; CHANGELOG gains `### Added` and `### Fixed` under `## [Unreleased]`.
Two fix rounds: the plan-mandated false back-compat guarantee (user-ruled — see SESSION CONTEXT) plus
five minors, then the same false claim surviving in README.

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
