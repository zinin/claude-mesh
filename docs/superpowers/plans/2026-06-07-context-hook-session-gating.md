# Context-Size Hook Session-Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `check-context-size.sh` emit milestone/STOP reminders only inside the session where `/do-plan` was started; stay completely silent everywhere else.

**Architecture:** `/do-plan` writes a **per-session** state file `do-plan-config-<cwd>-<session>.json` (session id from `$CLAUDE_CODE_SESSION_ID`). The hook computes the same id from its transcript path and, before any milestone/STOP logic, exits silently unless *its own* session's config file exists. Per-session keying means two concurrent `/do-plan` runs in one cwd never clobber each other. No `config.yaml` parsing in the hook (stays lightweight).

**Tech Stack:** Bash, `jq`, Claude Code PostToolUse hooks, the plugin's existing shell test harness.

---

## Execution status (2026-06-07)

- **Task 1 + Task 2** — ✅ Done, **squashed into a single commit `3a48501`** (kept atomic per ISSUE-4 — no broken intermediate commit where the hook read-side and the `/do-plan` write-side disagree on the filename).
- **Task 3** — ✅ Done, commit `0ecce92`.
- **Task 4** — ✅ Done (verified 2026-06-07): a one-shot `/check-sid` probe in slash-command Bash showed `$CLAUDE_CODE_SESSION_ID` non-empty (`4b51725a…`) and byte-equal to the transcript stem. All blockers cleared.
- **Reviews:** every task passed a spec-compliance + code-quality review; the final full-implementation review returned *Ready to merge — Yes* (only blocker = Task 4). Tests: `bash skills/shared/tests/test-check-context-size.sh` → `11 passed, 0 failed`.
- **Branch:** `fix/context-hook-session-gating`. **Before opening a PR:** `git rm -r docs/superpowers/` and commit (repo rule — planning docs must not appear in the PR diff; they remain in branch history).

---

## File Structure

- `hooks/check-context-size.sh` — **modify**: add the session gate + update header comment.
- `commands/do-plan.md` — **modify**: Step 2 writes the per-session config file (and its path prose); Step 6 gains a "session-scoped" note.
- `skills/shared/tests/test-check-context-size.sh` — **create**: gate test suite (self-contained, isolated tmp state).
- `README.md` — **modify**: line 18 clarification.
- `CHANGELOG.md` — **modify**: Unreleased entry.

No new `config.yaml` fields. `START_K`/`INTERVAL_K` (150/25) and `CC_CONTEXT_*` overrides are untouched.

> **Commit ordering (iter-1 review, ISSUE-4):** Task 2's `/do-plan` change (writing
> the per-session `do-plan-config-<cwd>-<session>.json`) must land **before — or in
> the same commit as** — Task 1's hook gate. If the gate is committed first, that
> intermediate commit still has the real `/do-plan` writing the old per-cwd
> `do-plan-config-<cwd>.json`, which the new hook (reading the per-session name)
> never finds — so the hook is silent *inside* `/do-plan` until Task 2 lands.
> **Resolved in execution:** Tasks 1 & 2 were squashed into one commit `3a48501`.

---

## Task 1: Hook session gate + test suite

✅ Done — see commit `3a48501`.

Added the per-session gate to `hooks/check-context-size.sh` (`SESSION_KEY` computed
first → `CONFIG_FILE="$STATE_DIR/do-plan-config-${CWD_ENC}-${SESSION_KEY}.json"` →
`[ -f "$CONFIG_FILE" ] || exit 0` above the milestone/STOP logic and below the
existing `agent_id` subagent guard → `STOP_THRESHOLD` read only after the gate).
Created `skills/shared/tests/test-check-context-size.sh` (11 cases; RED 8/3 vs the
ungated hook → GREEN 11/0). Header comment updated, including the per-cwd→per-session
accuracy fixes in the header body and the relocated section label.

---

## Task 2: `/do-plan` writes the per-session config file

✅ Done — see commit `3a48501`.

`commands/do-plan.md` Step 2 now resolves `SID="${CLAUDE_CODE_SESSION_ID:-}"` and
fails loudly if empty (no glob fallback — ISSUE-1/2), then atomically writes
`do-plan-config-<cwd>-<session>.json` via `jq` → `mktemp` (dot-prefixed) → `mv -f`.
Step 2 intro prose + the per-session doc note + the Step 6 session-scoped note were
added; the Step 2 heading and the `300k` argument example were corrected from
"per-cwd" to "per-session".

---

## Task 3: README + CHANGELOG

✅ Done — see commit `0ecce92`.

README line 18 clarified ("active only inside a `/do-plan` session"); CHANGELOG
gained a `### Fixed` entry under `[Unreleased]`.

---

## Task 4: Manual verification of the session-id assumption

This task is **manual** (the controller/user runs it interactively — a subagent
cannot run slash commands). It confirms the one design assumption:
`CLAUDE_CODE_SESSION_ID` is populated in slash-command Bash.

> **✅ VERIFIED 2026-06-07** via a one-shot `/check-sid` slash command (it executes a
> Bash tool call from the slash-command context, exactly as `/do-plan` Step 2 does):
> `SID=[4b51725a-33d8-44b8-9d54-b1a97623d64a]`, the transcript `<cwd>/<SID>.jsonl`
> EXISTS, and `SID == newest transcript stem` → `RESULT: PASS`. The id differs from
> the earlier corroboration (`7370d8e4…`), so the assumption held **independently** in
> a fresh session, not just where it happened to match. Load-bearing assumption
> confirmed; the fallback-free design is safe to ship.

- [x] **Step 1: Run `/do-plan` in a real session and inspect the state file** — done via `/check-sid` (see VERIFIED note above).

This step is **blocking** (iter-1 review): with the glob fallback removed, the gate
relies entirely on `CLAUDE_CODE_SESSION_ID` being populated in slash-command Bash.
If it is empty, `/do-plan` now aborts loudly instead of guessing.

> **Note:** the *installed* plugin is a separate snapshot in
> `~/.claude/plugins/cache/.../claude-mesh/<hash>/`; this branch's changes only live
> in the repo working tree until the plugin is re-installed/updated. To exercise the
> NEW `/do-plan` write + NEW hook read end-to-end, install this branch's build first
> (otherwise the live `/do-plan` still writes the old per-cwd filename).

In a Claude Code session in this repo, run `/claude-mesh:do-plan 200k` (any plan or
none — Step 2 writes the file before execution). Then check:

```bash
STATE="$HOME/.claude/plugins/data/claude-mesh-zinin/state"
CWD_ENC=$(pwd | sed 's|/|-|g')
SID="${CLAUDE_CODE_SESSION_ID:-<empty>}"
echo "env CLAUDE_CODE_SESSION_ID: $SID"
# The per-session config file /do-plan just wrote, named for THIS session:
CONFIG="$STATE/do-plan-config-${CWD_ENC}-${SID}.json"
ls -l "$CONFIG" && cat "$CONFIG"; echo
# What the hook will compute as SESSION_KEY (newest transcript stem):
ls -t "$HOME/.claude/projects/${CWD_ENC}"/*.jsonl 2>/dev/null | head -1 | xargs -r -n1 basename | sed 's/\.jsonl$//'
```

Expected: `CLAUDE_CODE_SESSION_ID` is **non-empty**, the file
`do-plan-config-<cwd>-<session>.json` exists and contains `{"stop_threshold":...}`,
and `<session>` equals the current transcript filename stem. If `/do-plan` aborted
with "CLAUDE_CODE_SESSION_ID is empty", the assumption is false on this platform —
do NOT rely on the gate; reopen the design (a correct session-id source is needed
before the fallback-free version can ship).

> **Corroborating evidence already gathered (agent Bash, this session):**
> `CLAUDE_CODE_SESSION_ID=7370d8e4-338e-4d2f-9ba1-961e5be24db0` and the newest
> transcript stem matched it exactly (`env == stem: YES`). This is *agent*/subagent
> Bash, not the exact slash-command-Bash context, so the formal check above is still
> required — but the assumption looks sound.
>
> **Also verify (final-review note):** under `claude --resume`, confirm the
> transcript filename stem stays stable (else the gate would miss). Low risk.

- [x] **Step 2: Confirm an ordinary session is silent** — covered by the automated suite (cases "no config" / "different-session config" → silent, 11/0); the empirical 150k run is not required.

Open a separate, fresh Claude Code session in the same repo (do NOT run `/do-plan`),
and do enough tool-using work to push context past 150k. Confirm no `ctx:` reminders
appear. (If you cannot easily reach 150k, trust the automated "no config /
different-session config → silent" cases in Task 1.)

---

## Deferred (reviewed, intentionally out of scope)

- **Zero-byte config edge:** a zero-byte `do-plan-config-<cwd>-<session>.json` that
  passes the `[ -f ]` gate makes `jq // 999999999` yield an empty string → a benign
  `[: : integer expression expected` on stderr (fail-safe: no crash, no STOP,
  milestone still emits; stderr not model-visible). Near-unreachable via the atomic
  `mv -f` write. Optional future hardening: a numeric `case` guard after the
  `STOP_THRESHOLD` read, mirroring the existing `CONTEXT_SIZE` sanity check.
- Orphan `context-milestone-*` / `context-stop-*` / old per-session config cleanup;
  resetting the STOP latch on a repeat `/do-plan` in one session; a bash-4 guard.
  (All deferred per iter-1 review.)

---

## Self-Review

**Spec coverage:**
- Outside `/do-plan` silent → Task 1 gate (cases 1–2) + Task 4 Step 2. ✓
- Inside `/do-plan` unchanged → Task 1 regressions (cases 3–8). ✓
- Hook stays lightweight (no `config.yaml`) → gate is `[ -f ]` + one `jq` for the threshold. ✓
- `START_K`/`INTERVAL_K` untouched → no task modifies them. ✓
- `/do-plan` writes the per-session config file → Task 2. ✓
- Concurrent `/do-plan` in one cwd → per-session files, no clobber → Task 1 case 2 + design Edge cases. ✓
- Edge cases (continue-fresh, stale/old-per-cwd file, concurrent, subagent) → Tasks 1–2. ✓
- Docs (hook header, do-plan Step 2 prose + file, Step 6, README, CHANGELOG) → Tasks 1–3. ✓
- Session-id assumption (fallback removed → fail-fast) verification → Task 4 (blocking). ✓
