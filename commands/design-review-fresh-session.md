---
name: design-review-fresh-session
description: Generate a prompt for reviewing the current design + plan via /claude-mesh:mesh-design-review in a fresh Claude Code session, including one that runs in a sandbox
---

# Fresh-Session Design-Review Prompt Generator

<!-- SYNC: six regions of the generated prompt are shared with
     commands/code-review-fresh-session.md — change both files or neither. Ordered by how
     tightly each is held; where they differ, design-review text first, code-review second:
       1. DO NOT — byte-identical. Asserted by skills/shared/tests/test-command-sync.sh.
       2. PREFLIGHT — byte-identical. Asserted by the same test.
       3. ENVIRONMENT — one phrase differs: `mesh-design-review commits its own auto-fixes and
          its iteration log` / `mesh-review commits its own auto-fixes and decisions`. The
          shorter phrase reflows the wrap of the sentence that follows.
       4. THEN STOP item 1 — `Summarise the documents in 5–10 lines.` /
          `Summarise what was built, in 5–10 lines.`
       5. WHEN THE USER SAYS GO, opening paragraph — identical after the invocation sentence
          (`mesh-design-review` with DESIGN_PATH/PLAN_PATH/TOPIC / bare `mesh-review`), whose
          length also sets the wrap of everything after it.
       6. WHEN THE USER SAYS GO, the `default`-safety rule — identical with `design_review`
          swapped for `code_review` and nothing else.
     The DO NOT block's exact wording — line breaks and em dash included — is what a 5-run A/B
     against a no-gate control actually measured (5/5 held, control failed 3/3). Reformat it and
     you are shipping an untested gate. -->

## Task

Generate the prompt for a NEW Claude Code session whose job is to review the current design and
plan through `/claude-mesh:mesh-design-review` — **not** to implement them.

Arguments, optional, any order: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=`.

## Never read the local config

Do NOT call `config-loader.sh`. Do NOT put a model id, a provider id or a `defaults.*` preset
into the prompt. The session that reads this prompt runs somewhere else — typically a sandbox
VM with its own `config.yaml` — and the reviewers available there are neither more nor less
than what its own preflight reports. Naming local models sends it shopping for reviewers that
do not exist there and hides the ones that do.

## Steps

### 1. Identify the documents

Use `DESIGN_PATH` / `PLAN_PATH` when given. Otherwise take them from this session's context,
falling back to the newest `docs/superpowers/specs/*-design.md` and the matching plan — an
**ordered** lookup, because three plan-naming conventions coexist in this repo:
`plans/<date>-<topic>-implementation.md`, then `plans/<date>-<topic>-plan.md`, then
`plans/<date>-<topic>.md`, then the newest `plans/*<topic>*.md`. If either document is still
unknown, ask the user for the path. Never invent one.

### 2. Derive TOPIC and the iteration number

<!-- SYNC: TOPIC derivation mirrors skills/mesh-design-review/SKILL.md Step 1, iteration
     counting mirrors its Step 2, the date rule mirrors its Step 13. A generator that derives
     a different topic counts a different set of iteration files and hands the review session
     a number the skill then disagrees with. Change them together. -->

- `TOPIC`: from `YYYY-MM-DD-<topic>-design.md`, **repeatedly** stripping trailing `-design` /
  `-review` suffixes — Step 1's own example removes two in sequence
  (`iterative-review-design.md` → `iterative`).
- `N`: `ls docs/superpowers/specs/*-<TOPIC>-review-iter-*.md` → highest existing number + 1, or 1.
- `DATE`: the date in the **design document's** filename, not today's.

### 3. Collect the context that is not in the documents

For iteration 1: decisions and why, alternatives rejected and why, known constraints, sharp
edges. For iteration N > 1: what the previous iteration decided and what it deferred under
"стоп". Keep it under 40 lines. It is not a retelling of the documents.

The only source is THIS session. If it does not actually hold that context — the command was
invoked standalone, or the discussion has been evicted — ask the user for the key decisions;
never fabricate them. If the user declines, write `CONTEXT` with an explicit note that it is
limited to what the documents imply.

### 4. Compose the prompt

The prompt consists of these sections, in this order, and nothing else. Substitute
`<DESIGN_PATH>`, `<PLAN_PATH>`, `<TOPIC>`, `<DATE>` (Step 2), `<feature>` — a short human name
for what is under review, taken from the design's title — and `N`; and nothing more: emit
`$HOME` in the preflight block **literally**, never expanded to a concrete home directory. An expanded path
freezes this machine's layout into a prompt that runs on another one — the exact failure
decision 2 of the design exists to prevent:

````
## TASK

Review the design and plan for <feature> through `/claude-mesh:mesh-design-review`.
Do not implement anything.

## DO NOT

- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.

## DOCUMENTS

- Design: `<DESIGN_PATH>`
- Plan:   `<PLAN_PATH>`
<iteration N > 1 only:>
- Previous iterations: `docs/superpowers/specs/<DATE>-<TOPIC>-review-iter-*.md` (this is
  iteration N). Do not summarise them — mesh-design-review reads them itself and builds its
  PREVIOUS DECISIONS table from them.

## ENVIRONMENT

This session probably runs in a sandbox. git remote, gh and glab may be unreachable. The set
of configured agents and models HERE differs from the session that wrote this prompt — assume
no reviewer exists until the preflight below says so. Local commits are normal and expected:
mesh-design-review commits its own auto-fixes and its iteration log. If no clipboard utility
exists, print generated prompts into the chat instead of trying to copy them.

## PREFLIGHT — run this before anything else

```bash
PF="./skills/shared/preflight-env.sh"
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -n "$PF" ] || PF="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on grok is stronger: the
probe runs the CLI itself, which answers only when a login is live. `OK` on gh / glab means
presence on PATH only. If the script is not found, say so and ask the user whether to update
the plugin in this sandbox first or proceed on the built-in `claude` reviewer alone — and
before offering that, check a `config.yaml` exists in the plugin data dir: claude needs no
config section, but the review skills refuse to start without a usable config.yaml at all.

## CONTEXT

<from step 3>

## THEN STOP

1. Summarise the documents in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-design-review DESIGN_PATH=<DESIGN_PATH> PLAN_PATH=<PLAN_PATH> TOPIC=<TOPIC>`
and select only reviewers the preflight marked available. The two halves of the table answer
different questions, so read both: **`SUMMARY available` decides eligibility** — a reviewer
absent from that line cannot be selected whatever its own row says, because a row reports
whether that endpoint answered, not whether the orchestrator starts. With a rejected `claude:`
section, `provider:*` rows can read `OK` next to `SUMMARY available: —`, and both orchestrators
exit on the catalog read before offering anything. **The ROWS carry the caveats** the summary
has no room for: `OK` on codex / gemini is a heuristic — binary present, section valid,
endpoint answered — and says nothing about auth, while `OK` on grok also means a live login:
its probe runs the CLI itself.

Whether the `default` argument is safe here is a membership check between two SUMMARY lines.
Split both on `, ` and compare WHOLE entries — never substrings: a bare `claude` is a substring
of `claude:<model>`, and `<provider>/<model>` of `<provider>/<model>-<variant>`, so a substring
test reports a match where the orchestrator would find none.

- `SUMMARY available: —` → `default` is never safe, however the defaults line reads. Nothing is
  selectable in that environment, and membership against an empty list is vacuously true — the
  one case where the mechanical check would say yes precisely when the answer is no. With no
  usable config both lines print `—`; with a rejected `claude:` section the defaults line prints
  a real list next to an empty available line.
- `SUMMARY defaults design_review: —` or `— (preset empty)` → also never safe, for the same
  reason read the other way: there is no preset to run, and `default` mode stops instead of
  starting.
- Otherwise `default` is safe only when every entry of the defaults line is also an entry of the
  available line — with one exception: a bare `claude` on the defaults line is satisfied by any
  `claude:<model>` entry on the available line. That spelling means the preset carries no
  `claude_models`, and the orchestrator then runs exactly one reviewer named literally `claude`
  on the session's dispatch model, which asks the catalog for nothing.

Anything short of that → select interactively.
````

### 5. Save, display, offer the clipboard

1. Write to `docs/superpowers/plans/<DATE>-<TOPIC>-design-review-prompt-iter-N.md`. If that
   exact file already exists, suffix `-2`, then `-3` — never overwrite an earlier prompt.
2. Print the full prompt on screen.
3. Copy to the clipboard: `xclip -selection clipboard` / `xsel --clipboard` on Linux,
   `pbcopy` on macOS. If none exists — which is normal inside a sandbox — say so, name the
   file path, and move on. A missing clipboard is a note, never a failure.
4. Tell the user: "Prompt ready. Open a new Claude Code session and paste it."

Do not commit the file. `docs/superpowers/` is removed before a PR anyway, and the sandbox
shares this working copy, so the file is visible on both sides the moment it is written.
