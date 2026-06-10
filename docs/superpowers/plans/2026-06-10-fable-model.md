# Fable Model Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch claude-mesh's "never delegate to cheaper models" policy from Opus to Fable (`claude-fable-5`) and make session-model diagnostics wording model-neutral.

**Architecture:** Pure text edits — plugin command markdown, agent frontmatter, and one runtime message string in a bash script. No logic changes. Policy spots get the literal `fable`; descriptions of "the session's model" (FLIP diagnostics) become model-neutral so they don't go stale at the next model-family rename. Verified by the existing bash test suites plus grep sweeps.

**Tech Stack:** Claude Code plugin (markdown commands + agent frontmatter), bash test scripts under `skills/shared/tests/`.

**Spec:** `docs/superpowers/specs/2026-06-10-fable-model-design.md`

**Runtime smoke note for the controller:** dispatching the Task 1 implementer subagent with `model: "fable"` is itself the alias smoke test required by the spec (Verification §3). If that dispatch fails with an invalid-model error, STOP and report — do not fall back to another model silently.

---

### Task 1: `commands/do-plan.md` — switch the policy to Fable

✅ Done — see commit(s): `09f4c26`

---

### Task 2: `agents/*.md` — pin all 8 agents to Fable

✅ Done — see commit(s): `7757dfc`

---

### Task 3: `commands/mesh-review.md` — model-neutral FLIP wording

✅ Done — see commit(s): `e7bc560`

---

### Task 4: `verify-delegation.sh` + its test — model-neutral FLIP message

✅ Done — see commit(s): `a9db96a` (regression suite re-run: 24 passed, 0 failed)

---

### Task 5: Full verification sweep

✅ Done — verification only, no commit. All four suites green (test-config-loader 91/0, test-check-context-size 11/0, test-extract-result 28/0, test-verify-delegation 24/0; each exit 0). Repo-wide `\bopus\b` sweep hits ONLY the three sanctioned locations: `config.example.yaml:85`, `skills/shared/tests/test-config-loader.sh:386,398` (Claude Code env-var contract, out of scope) and `commands/do-plan.md:134` (the INTENTIONAL forbidden-downgrade list — the plan's original "zero hits" expectation for this file was an adjudicated typo; do not "fix" line 134). `model: fable` present in all 8 `agents/` frontmatters. Runtime smoke (spec Verification §3) confirmed: every subagent of the executing session was dispatched with `model: "fable"` and succeeded. Final cross-cutting review of `8bfa13a..a9db96a`: Ready to merge — Yes, no Critical/Important findings.
