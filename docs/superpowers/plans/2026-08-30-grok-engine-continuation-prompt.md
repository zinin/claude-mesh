## HOW THIS SESSION MUST BE STARTED

`claude --dangerously-skip-permissions --plugin-dir /opt/github/zinin/claude-mesh`

Plugins resolve at session START. Started without `--plugin-dir`, `/claude-mesh:mesh-review`
comes back as the INSTALLED copy under `~/.claude/plugins/cache/zinin/claude-mesh/0.11.0/`,
which has no grok in it at all and no grok agents, so `subagent_type:
"claude-mesh:grok-code-reviewer"` does not resolve. **The version number will not warn you:**
the repo's `.claude-plugin/plugin.json` and the installed cache both say `0.11.0`. Same number,
different content.

**Do NOT use the `find … | head -1` gate from the previous prompt — it is unreliable.** Measured
2026-08-30: that command searches four copies in unstable readdir order and returned `81` on one
run and `0` on the next three, with no file changing in between. Use one of these instead:

```bash
grep -c -i grok /opt/github/zinin/claude-mesh/commands/mesh-review.md   # branch copy: 81
```

Positive signal that costs nothing: the session's agent roster lists
`claude-mesh:grok-code-reviewer` and `claude-mesh:grok-executor`. Only the branch provides
those — all three installed caches carry zero grok agents.

## TASK

The **grok engine** plan is fully implemented (14/14) AND the whole-branch multi-model review is
done. What remains is the closing sequence: triage the deferred Minors, settle one open question
that needs the user, then `superpowers:finishing-a-development-branch`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start triaging, fixing or finishing the branch
- Make any code changes
- Run any commands (except reading documents)
- Assume which of the remaining items to start with

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-08-28-grok-engine-design.md` (428 lines)
- Plan: `docs/superpowers/plans/2026-08-28-grok-engine.md` (170 lines — every task is a commit
  pointer; what is left of substance is the Global Constraints and the File Structure tables)
- **Ledger:** `.superpowers/sdd/2026-08-28-grok-engine/progress.md` (332 lines) — **read this
  too.** It holds all 40 pre-flight rulings, the per-task measurement notes, **60 deferred Minor
  findings**, and the 2026-08-30 session block with every review decision and its reasoning. It
  is git-ignored scratch: it exists on disk only, never in the repo's history.

Branch: `feat/grok-engine`. Head: `90357c0`. Range vs master: `90c9a08..90357c0`, 48 files,
+6653/-219.

## PROGRESS

**Plan — Tasks 1-14, all done.** Each with a task review and, where findings appeared, a fix
round and a scoped re-review. Task 14 closed against a live `/mesh-review` with grok as the only
reviewer: run scored `REAL` by the guard, 21 turns, 831 s, smoke test 8/8.

**Whole-branch review — done, 2026-08-30.** `/claude-mesh:mesh-review BASE_BRANCH=master`, eight
reviewers dispatched, seven delivered:

| Reviewer | Guard | Verdict |
|---|---|---|
| `claude:opus` | INLINE | ready after 2 Important fixes |
| `claude:fable` | INLINE | ready to merge, 0 Critical/Important |
| `grok:grok-4.6` | REAL (19 turns) | with fixes, 4 Important |
| `ext-claude zai/glm` | REAL (29) | ready to merge, 1 Important |
| `ext-claude deepseek/v4-pro` | REAL (29) | with fixes, 1 Important |
| `ext-claude ollama/kimi` | REAL (36) | with fixes, 1 Important |
| `ext-claude ollama/minimax` | REAL (3) | No — but its wrapper refuted 3 of its 5 Criticals |
| `codex` | STALLED | lost to the provider's usage limit, no findings |

**Nobody found a Critical.** Everything found was applied or decided:

- `93f4f68` — 11 auto-fixes (13 proposed, 2 withdrawn after reading the code)
- `eaf3ad4` `c69d134` `a496435` `bb26375` `d759b51` `0e37b93` `1ebc8b0` — seven decisions from
  `/claude-mesh:auto-decide-disputed`, one per commit, none flagged `под вопросом`
- one disputed issue decided as «не исправлять» (no commit)
- `90357c0` — CHANGELOG

**Suite state at handover, all green:** config-loader 345, verify-delegation 186, preflight-env
221, watch-runs 99, command-sync 34 passed / 1 skipped, extract-result 34, render-template 44,
loader-resolution 12, check-context-size 11, stream-json-report 14 — **ten suites, 1000
assertions, 0 failures.** `config.example.yaml` validates rc=0. Live preflight: `config OK`,
`grok OK`, `SUMMARY unavailable: —`. shellcheck over `skills/shared/*.sh` unchanged at 8
pre-existing SC2155. Working tree clean; two untracked files in the repo root (`output.txt`,
`raw.json`) are a previous session's debris, deliberately not touched.

## WHAT REMAINS

**1. Triage the deferred Minors (the work pass — nothing finishes the branch without it).**
Sixty lines in the ledger match `minor (deferred`. Most are cosmetic. The ones worth knowing
early:

- **`README.md:191`** says "Install Grok Build" but the repository carries no URL and no package
  name for it. **Open question, raised three times now, needs the user.** Branch-level.
- **`verify-delegation.sh:449,:501`** — the ext-claude arm of both `case`s is `*)`, so a third
  engine appended to `ext-claude|grok|…)` silently inherits ext-claude's archive number and its
  remedy.
- **`test-preflight-env.sh:666`** (pre-existing) — the git-remote twin carries the exact defect
  Task 10 fixed for grok: an unscoped `assert_match` on `"timeout"` that holds whatever the row
  says, because the row NAME `bash-timeout` prints in every scenario.
- **`commands/mesh-review.md:265`** (pre-existing) — tells the orchestrator to write
  `BASE_BRANCH=<branch> MODEL=<id> …` for ext-claude, putting BASE_BRANCH ahead of MODEL on one
  line, while `agents/ext-claude-code-reviewer.md:26` requires MODEL "on the first line".
- **`skills/mesh-design-review/SKILL.md:224`↔`:503`** — the link between the two enumerations of
  the remembered set is one-directional, where the file's own idiom is a paired
  `<!-- SYNC: … -->`.
- **Two added by the 2026-08-30 review, routed here rather than folded into it:**
  `watch-runs.sh:243` (freshness falls back to the parent dir's mtime before the first
  `attempt-N/raw.jsonl` exists, so a dead watchdog is indistinguishable from a slow CLI in that
  window) and `verify-delegation.sh:489` ("the `permission_denials` field is absent" and "no
  denials" both read as 0).
- **One about claude-mesh, not about this branch, reproduced by this very review:**
  `MIN_REVIEW_BYTES=400` catches "a notice instead of a review" only while the notice is SHORT.
  `ollama/minimax` delivered 1364 non-space bytes of meta-reply ("the final report is already in
  the previous message") and the guard scored it `REAL`; the actual review sat in earlier
  assistant blocks of `raw.jsonl` and its wrapper recovered it from there.

**2. Optional — re-run codex alone.** Its run died on the ChatGPT usage limit ("try again at
9:57 PM", 2026-08-29), not on anything in the plugin, so the branch was reviewed by seven voices
instead of eight. Both `max_redispatch` rounds were deliberately NOT spent, because the error
names its own reset time. Worth one `/claude-mesh:mesh-review BASE_BRANCH=master` with codex
alone if an eighth independent voice is wanted; not required.

**3. Then:** `superpowers:finishing-a-development-branch`, and per the user's global CLAUDE.md,
before creating a PR: `git rm` everything under `docs/superpowers/` and commit — plan and design
documents must not appear in the PR diff. They stay reachable in branch history.

## SESSION CONTEXT (2026-08-30)

### The three measurements that mattered more than any reading

- **`report.md` was not "partly lossy" — it was empty of the trace.** The shared renderer read
  `.message.content[0]` and nothing else. On this branch's own grok acceptance run, 22 of 23
  assistant messages BEGIN with a `thinking` block, so the 904 KB report held **zero of the run's
  79 tool calls** — only their outputs, rendered by a different branch. Consequences with no
  causes. Fixed in `a496435`; the file got its first regression suite in 187 lines of shared code.
- **`grok: false` grounded the whole environment.** A section of the wrong type made
  `get-defaults` exit 1, so preflight printed `config INVALID` and SKIPPED every row, codex and
  gemini included. Controls measured on identical configs: `codex: false` and `gemini: false`
  pass with rc=0; `claude: false` fails like grok. Fixed in `eaf3ad4`.
- **grok does NOT block-buffer a pipe.** A reviewer's Important rested on the assumption that it
  does. Measured: a five-event agentic run through `while read` delivered events at 3.44, 5.89,
  7.35, 7.70 and 7.71 s against a process exiting at 8.13 s. The premise (the no-stdbuf
  justification had been measured only on a file redirect) was true; the conclusion was false.
  `0e37b93` fixed the evidence, not the code.

### Two habits that paid, and should carry forward

- **Verify a finding against the code before acting on it, including a reviewer's severity.**
  Two of the thirteen auto-fixes were WITHDRAWN on reading: `config.example.yaml`'s effort
  comment does not promise per-model validation (it says the opposite — "no diagnostic from
  here"), and design review's Error Handling table carries no codex or gemini rows either, so
  grok-only rows would have been the asymmetry that file's own note forbids.
- **A refutation can miss the finding it aims at.** `ollama/minimax` declared the `grok_degraded`
  bug unreproducible because "the loader is never sourced and the flag resets at `:69`" — true,
  and about a DIFFERENT mechanism. The real defect is inside one invocation: `validate_defaults`
  walks both presets and `cmd_get_defaults` read the global unconditionally. Four other
  reviewers found it; it was reproduced in both directions before being fixed.

### Process notes carried forward

- **A wrapper never wakes when its background run finishes.** Disk-watch with `watch-runs.sh` as
  a background Bash task, ping once per `DONE`, and read `output.txt` yourself after a second
  unanswered ping. Never record a reviewer as silent while the guard scores its run `REAL`.
- **Reviewer replies get truncated by the delivery channel.** Ask for the tail rather than
  re-dispatching; `ollama/minimax` needed exactly that.
- **`config.yaml` is user-owned.** It was edited once, on 2026-08-29, only because the user said
  so explicitly for that one request. The standing rule stands.
- **Do not prescribe commit boundaries after the fact.**

## QUALITY WARNING

The plan is finished and the branch is reviewed, so what is left is judgement, not construction —
and the branch's own lesson applies hardest there:

**Every Critical and Important on this branch was found by MEASURING, not by reading — and
several lived under green tests.** The 2026-08-30 review added three more of exactly that shape,
including one where the measurement *reversed* the recommendation a careful reading had produced.

For prose-as-code files the equivalent of measuring is the trace: follow each name from where it
is written to where it is read, on every path. And note Task 12's lesson — an enumeration can be
stale without containing any token you grep for.

**If you notice any issue while working:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why it does not work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the documents listed above — including the ledger
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any work
5. Ask: "What would you like me to work on?"
