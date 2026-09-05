## TASK

Continue after `/claude-mesh:mesh-review` on branch `feat/do-plan-grok-host-dispatch`.
The implementation of `/do-plan` on Grok is in; AUTO review fixes are committed.
What remains is the deferred disputed queue (and optional live verification).

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start implementing tasks
- Make any code changes
- Run any commands (except reading documents)
- Assume what task to work on next
- Re-run `/claude-mesh:mesh-review` unless the user asks
- Open a PR/MR unless the user asks

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- No written design. No implementation plan. Bounded in-chat design; the feature shipped as two commits plus a review auto-fix.
- Review prompt that started the previous session (history only): `docs/superpowers/plans/2026-09-05-do-plan-grok-host-dispatch-code-review-prompt.md`
- Branch: `feat/do-plan-grok-host-dispatch` vs base `master`
- Commits on the branch:
  - `4314d93` fix: `/do-plan` on Grok inherits host models and polls `signals.json` for STOP
  - `151d160` fix: drop PreToolUse from the context hook (`hooks/hooks.json` byte-identical to master)
  - `eff7536` review: auto-fix valid issues from external review

HEAD at generation of this file: run `git rev-parse HEAD` and name it. If it has moved, say so.

Before a PR: `git rm -r docs/superpowers/` and commit — these prompt files must not appear in the PR diff (AGENTS.md).

## PROGRESS

**Completed:**
- [x] Grok host-dispatch for `/do-plan`: catalog probe, fail-closed inherit, `SID` fallback to `GROK_SESSION_ID`, poll `signals.json` as primary STOP on Grok
- [x] Hook Grok envelope (`sessionId`, `signals.json`, `GROK_PLUGIN_DATA`, `subagentType`); Claude Code path additive only
- [x] `PreToolUse` added then removed so `hooks.json` matches master
- [x] `/claude-mesh:mesh-review BASE_BRANCH=master` (default minus Codex, then Codex added back)
- [x] AUTO fixes from that review (`eff7536`)

**Remaining (deferred disputed from mesh-review, default mode — not applied):**
- [ ] Critical: `signals.json` is a turn-boundary snapshot; mid-`/do-plan` poll cannot see growth. Recommendation: poll `updates.jsonl` `params._meta.totalTokens` after confirming it is context size, not spend; else drop the mid-run STOP claim (WARN at start).
- [ ] Important: host detect uses `GROK_SESSION_ID` (leaks into `claude -p`). Recommendation: substitute `HOST=grok|claude-code` like `/mesh-review`.
- [ ] Important: STOP threshold not checked against `contextWindowTokens`. Recommendation: WARN/fast-fail if `threshold >= window`, do not clamp.
- [ ] Important: catalog fence is grep-on-markdown only. Recommendation: do not extract in this PR; follow-up with mesh-review.
- [ ] Important: Grok 1.0.13 may inject PostToolUse context. Recommendation: measure once; do not switch STOP back to the hook without that measurement.

**Out of scope / already dismissed:**
- Missing `signals.json` → WARN and continue (intentional)
- `--plugin-dir` data-dir mismatch (pre-existing, documented)
- Live `/do-plan` run that crosses the threshold (never done; optional if the user asks)
- Grok plugin reinstall (copy, not live mount)

## SESSION CONTEXT

Reviewers that counted: `native:grok-4.6`, `native:kimi-k3`, `native:deepseek-v4-pro` (INLINE); `claude:opus`, `claude:fable` (REAL, `runs/claude/<alias>/…`, `num_turns=40`). Codex: `KILLED` after 2365s (attempt 1 hit `timeout 1800` on `gpt-5.6-sol` / `max`; watchdog started attempt 2; user said wait for timeout then proceed without it; SIGTERM, no `watchdog.exit`). Do not re-dispatch Codex unless asked. Limits were exhausted earlier in the session, then came back.

Empirical check in that same Grok session (`~/.grok/sessions/%2Fopt%2Fgithub%2Fzinin%2Fclaude-mesh/01a07209-b173-7ff1-b61d-cede0d756cd8/`):
- `signals.json` mtime matched `turn_ended` (`15:20:47Z`); `contextTokensUsed=139652`, `contextWindowTokens=500000`
- Next `turn_started` `15:34:46Z`; during the long review turn the file did not move
- `updates.jsonl` `params._meta.totalTokens` was live (`177124`)
- So the Critical is not speculative. `_meta.totalTokens` semantics (window vs spend) were not proven.

AUTO in `eff7536` (do not redo):
- Poll snippet now prints `CONTEXT_USED=` + WARN on stderr + `exit 0` when the file is missing
- Distinct WARN if `list-host-models.sh` is absent
- Hook uses transcript stem only when the file exists (`-f`); dummy `transcript_path` falls through to `sessionId`
- Tests: parent `PostToolUse` on Task with `tool_input.subagent_type` still emits; dummy transcript + Grok envelope still emits
- Comment/README/150k-floor wording; `trap` on `$GM`
- Tests: `test-do-plan.sh` 15/15, `test-check-context-size.sh` 22/22

Default-mode disputed were recorded, not applied. Interactive re-run or an explicit “do the deferred queue” is how they get decided. `autodecide` was never set.

Do not treat a missing hook reminder on Grok as a defect. `hooks.json` must stay PostToolUse-only.

## PLAN QUALITY WARNING

There was no implementation plan. The review prompt’s CONTEXT is the spec. AUTO already drifted the poll snippet and hook keying; disputed items can change the STOP channel. If a requested change fights Claude Code identity of `hooks.json` or invents a token count, STOP and ask.

## INSTRUCTIONS

1. Read the documents listed above and `git log origin/master..HEAD`
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any implementation
5. Ask: "What would you like me to work on?"
