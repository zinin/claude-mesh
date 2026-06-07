# Merged Design Review — Iteration 1

**Date:** 2026-06-07
**Design:** `docs/superpowers/specs/2026-06-07-context-hook-session-gating-design.md`
**Plan:** `docs/superpowers/plans/2026-06-07-context-hook-session-gating.md`
**Review agents:** claude-self (Opus), codex (gpt-5.5, xhigh), ext-claude on zai/glm, alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax

All reviewers verified the design's anchor claims against the real code (`hooks/check-context-size.sh`, `commands/do-plan.md`, `hooks/hooks.json`). Consensus: the core gate mechanism is correct and the anchors/harness are accurate. Critical findings cluster around (1) the fallback session-id glob and (2) the per-cwd single-owner config.

---

## claude-self (Opus)

### Critical Issues
1. **Fallback glob uses wrong cwd-encoding — silently fails on paths with `.`/`_`.** `CWD_ENC=$(pwd | sed 's|/|-|g')` replaces only `/`; Claude Code's `~/.claude/projects/` dir names also replace `.` and `_` with `-`. Verified against real dirs in this environment:
   - `/opt/git/sib.certhub2` → real dir `-opt-git-sib-certhub2`, but sed yields `-opt-git-sib.certhub2`
   - `/opt/git/crypto/linux-amd64_deb` → real `-opt-git-crypto-linux-amd64-deb`, sed yields `…amd64_deb`

   For any path with `.`/`_`, the fallback globs a nonexistent dir → `SID` empty → `/do-plan` hits `exit 1` ("could not resolve session id") and **fails entirely**. The design's claim (design:105-106) that CWD_ENC "already matches the project's transcript dir name for ordinary paths" is false for a common class of paths. The Task-1 harness never exercises this branch (explicit `transcript_path`), and Task 4 on the clean path `/opt/github/zinin/claude-mesh` won't catch it either.

### Concerns
2. **Concurrent sessions in one cwd — "last writer wins" regression.** `do-plan-config-<cwd>.json` holds one `plan_session_id`. Today milestone/STOP state is per-session; after the change, session B's `/do-plan` overwrites `plan_session_id=B`, so session A goes silent mid-plan and never gets STOP. Two terminals in one worktree is not exotic. Neither doc mentions it.
3. **Task 4 can't verify the stated risk.** Step 1 only checks the happy path and can't distinguish "env var worked" from "fallback worked" — and the fallback is where the bug (item 1) lives. Print `$CLAUDE_CODE_SESSION_ID` separately from the written `plan_session_id`, and add a "dirty path" (`.`/`_`) check.

### Suggestions
4. Line 70 `STOP_THRESHOLD` jq read is redundant for no-config/mismatch branches after the gate (already documented as defense-in-depth) — note in comment.
5. Orphan `context-milestone-*`/`context-stop-*` from do-plan sessions still accumulate forever (7 seen in real state dir). Pre-existing, out of scope, but worth acknowledging since the change is about state littering.
6. **Alternative not weighed: per-session marker instead of per-cwd `plan_session_id`.** It naturally solves the concurrency regression (item 2) and removes the fragile glob entirely (hook keys on its own `SESSION_KEY`). The "leaves orphans" rejection is weak — the per-cwd config orphans too. Re-evaluate this trade-off in light of the encoding bug.
7. The 260k/STOP case asserts only substring `STOP`, but actual output is `ctx:250k STOP …` — assert both `ctx:250k` and `STOP` to lock the format.

### Questions
1. Is the fallback even needed if Task 4 confirms `CLAUDE_CODE_SESSION_ID` is always populated? Drop it and fail with a clear error instead?
2. Expected behavior for two parallel `/do-plan` in one repo — "unsupported, document" or "must work"? Drives per-cwd vs per-session.
3. Has Claude Code's real dir-encoding been confirmed (it replaces `.`/`_` too)? Derive the exact rule empirically before relying on the glob.

**Priority:** only item 1 is critical (breaks `/do-plan` on `.`/`_` paths — and such paths really exist; autotests + clean-path Task 4 miss it). Item 2 is a real behavior regression to at least document. The gate itself is correct; anchors/harness accurate.

---

## codex (gpt-5.5, reasoning xhigh)

### Critical Issues
1. **Fallback `newest transcript` unsafe.** In this very repo `CLAUDE_CODE_SESSION_ID=a2a3517b-…` but `ls -t ~/.claude/projects/-opt-github-zinin-claude-mesh/*.jsonl | head -1` selected a **different** session id (empirically run). With parallel/recently-active sessions the fallback can write someone else's `plan_session_id`, silencing the hook in the real `/do-plan` session.
2. **Per-cwd config breaks parallel `/do-plan` in one cwd.** A then B in same cwd → B overwrites the file → A loses milestone/STOP. STOP loss in a long unattended workflow is serious.
3. **The plan creates a broken intermediate commit.** Task 1 adds the gate and commits (plan:174) BEFORE Task 2 makes `/do-plan` write `plan_session_id`. At that commit the real `/do-plan` still writes only `{stop_threshold}` (do-plan.md:79) → legacy config → hook fully silent. Task-1 tests mask this because they synthesize a matching `plan_session_id` themselves.
4. **Harness can yield false PASS for silent cases.** `run_hook` suppresses stderr and ignores exit code (plan:82); `assert_silent` checks only empty stdout (plan:56). A hook that crashes with no stdout is accepted as "silent." Check rc, stderr, and absence of state files.

### Concerns
- Anchors mostly correct: `CONFIG_FILE`:68, `SESSION_KEY`:73, matcher `.*` in hooks.json:5. But inserting the gate after `SESSION_KEY` leaves `STOP_THRESHOLD` already read at :70 — contradicts "after the gate, stop_threshold is always present" (design:87) and leaves a wasted jq on every call.
- Fallback fragile for paths with spaces: `ls | xargs basename` (plan:207) splits on whitespace. Symlink/logical-vs-physical cwd unproven.
- "Outside `/do-plan`: fully silent" ≠ design: after `/do-plan` finishes the hook stays active to session end — that's "session-scoped," not "while `/do-plan` runs."
- New test doesn't check `hookSpecificOutput` JSON shape, one-shot STOP/milestone, absence of `context-milestone-*` outside gated session, or real integration with the markdown `/do-plan`.

### Suggestions
- Prefer fail-fast if `CLAUDE_CODE_SESSION_ID` empty rather than newest-transcript. If a fallback is kept, mark it unsafe and require manual verification.
- Consider per-session state instead of one per-cwd owner: `do-plan-config-${CWD_ENC}-${SESSION_KEY}.json` or a per-cwd JSON map `sessions[session_id]`. Solves parallel `/do-plan` without STOP loss.
- Move `STOP_THRESHOLD` read below the gate and read both fields with one `jq`; validate JSON with `jq -e`. Write the config atomically: `tmp=$(mktemp …); jq -nc … > "$tmp" && mv "$tmp" "$CONFIG_FILE"`.
- Don't commit Task 1 separately from Task 2, or reorder. The final PR must not contain an intermediate commit where the real `/do-plan` is broken.

### Questions
- Are two concurrent `/do-plan` sessions in one cwd allowed? If not, where is that told to the user?
- Confirmation specifically for slash-command Bash that `CLAUDE_CODE_SESSION_ID` is always populated? The fallback already showed a mismatch.
- Should the hook deactivate after `/do-plan` completes in the same session, or is "active until session ends" the intended contract?

---

## ext-claude — zai/glm (GLM 5.1)

### Critical Issues
None. The gate is four lines of Bash/jq in the correct position; "empty string → never matches → silent" is genuinely safe-by-construction. Verified `SESSION_KEY`:73, `CONFIG_FILE`:68, `agent_id` guard:34-52, do-plan Step 2 anchor:79-80, and that `CWD_ENC=sed 's|/|-|g'` matches the real transcript dir for `-opt-github-zinin-claude-mesh`.

### Concerns
1. `STOP_THRESHOLD` computed before the gate (line 70 jq) — wasted jq on every PostToolUse when a stale config exists. Negligible; add a clarifying comment.
2. Fallback uses `ls -t` (most-recently-modified, not newest-created). With concurrent sessions in one cwd it could bind `plan_session_id` to the wrong session, silently breaking `/do-plan` milestones.
3. Hook stays active after `/do-plan` finishes — if the user keeps working and Step 6's framing got compacted, the bare `ctx:200k` problem can reappear inside a "legitimate" session. Suggests an optional `plan_completed: true` flag.
4. No cleanup of orphan `context-milestone-*`/`context-stop-*` (pre-existing).

### Suggestions
1. Move the gate one line up (right after `SESSION_KEY`:73) to skip 4 file reads (STATE_MILESTONE/STATE_STOP/LAST_MILESTONE/STOP_FIRED) on the silent path — zero added complexity.
2. In `/do-plan`, use `jq -nc --argjson … --arg …` instead of `printf` to write the config JSON — defensive against `"`/`\` in `$SID`.
3. Add an exit-code assertion to the harness (follow the `assert_exit` pattern from `test-config-loader.sh`): current `run_hook` captures only stdout, so a crash (zero stdout + stderr) falsely PASSes as "silent."

### Questions
1. Empirically confirmed that `CLAUDE_CODE_SESSION_ID` is populated in slash-command Bash? Could `/do-plan` Step 2 add a diagnostic log to automate the check?
2. Why was the separate sentinel-file alternative (`state/do-plan-active-<session-id>.txt`, gate = `[ -f … ]`) rejected as "more invasive"? It avoids JSON parsing (stat vs jq) and makes orphan cleanup trivial.

Verdict: solid — minimal, correct, well-tested; concerns are nitpicks/defensive improvements, not blockers.

---

## ext-claude — alibaba/qwen (Qwen 3.7 Plus) — recovered from truncated stream (item 8 cut off)

### Critical Issues
1. **Fallback glob + Claude Code dir-encoding (key risk).** Relies on `/`→`-` encoding, NOT verified against real `~/.claude/projects/` structure (couldn't read the dir — permissions). If CC uses percent-encoding or another format the fallback always misses → `plan_session_id` not written → hook silent even inside `/do-plan`. Task 4 is mandatory and blocking.
2. **Race in newest-transcript fallback.** If `/do-plan` starts in a fresh session before its transcript is written, `ls -t | head -1` grabs the PREVIOUS session's transcript → `plan_session_id` points at the old session. If `CLAUDE_CODE_SESSION_ID` is empty, `/do-plan` should refuse to start rather than guess.
3. **`printf %s` JSON build is unsafe.** Fine for a normal UUID, but if the fallback grabs garbage with special chars the JSON silently becomes invalid, `jq … // empty` returns empty → silent, error unnoticed. Use `jq -nc --argjson thr <THR> --arg sid "$SID" '{stop_threshold:$thr,plan_session_id:$sid}'`.

### Concerns
4. Concurrent `/do-plan` in one cwd not documented (A then B → A goes silent). Probably correct (one active plan per cwd) but should be an explicit edge case, maybe a warning when an existing config holds a foreign `plan_session_id`.
5. Lingering state files not cleaned. Minimum: on `/do-plan` start, delete previous `plan_session_id`'s milestone/stop files.
6. `mkdir -p "$STATE_DIR"` (line 66) runs before the gate — every PostToolUse still does mkdir (no-op + fork). Cosmetic; the gate can't move above line 68 because `CONFIG_FILE` depends on `CWD_ENC`.
7. `set -euo pipefail` + gate are correct but brittle to refactoring (rely on `|| exit 0`, `|| true`). Add an inline comment: `|| true is required under set -e — jq fails on malformed JSON`.

### Suggestions
- Add tests: (8) malformed JSON in config → silent (checks `set -e` resilience); (9) explicit `plan_session_id: null` → `// empty` handles both null and missing; (10) milestone boundary crossing across multiple transcript writes.
- `jq -nc` instead of `printf` for JSON.
- Clean milestone/stop files on new `/do-plan` start.

### Verified positives
TDD prediction holds (3 gate-driver cases FAIL pre-gate, 4 regressions PASS — walked all 7). Gate logic under `set -e` correct; `// empty` handles null and missing key; subagent guard stays above the gate; `jq -nc` single-line JSONL is read correctly by `tail|jq|tail`.

### Questions
- Real cwd-encoding scheme confirmed (crit 1)? `CLAUDE_CODE_SESSION_ID` populated in slash-command Bash? Intended behavior for concurrent `/do-plan` (#4)?

---

## ext-claude — deepseek/v4-pro (DeepSeek V4 Pro 1M)

### Critical Issues
1. **Leaked `context-milestone-*`/`context-stop-*` from "silent" sessions.** Design itself confirms (lines 20-22) milestone files already exist for non-`/do-plan` sessions. After the gate the hook is silent but pre-existing files stay forever — the hook never cleans its own litter. Plan has no cleanup.
2. **`mkdir -p "$STATE_DIR"` and `CONFIG_FILE` read happen BEFORE the gate** (lines 65-70). Functionally safe, but "fully silent" should be "silent in output" — side-effects (mkdir, jq) persist on every PostToolUse.
3. **Fallback glob (`ls -t | head -1`) nondeterministic under parallel sessions.** Two Claude Code in one cwd (e.g. main + a `/loop` background) → "newest" transcript may belong to another session, gate matches the wrong one, current session goes silent.

### Concerns
4. Test doesn't cover milestone progression (no 150k→175k→200k in one session; `LAST_MILESTONE`/compaction-reset untested).
5. No negative STOP case (threshold=300k, usage=260k → STOP must NOT fire) — would confirm the threshold is read from config, not hardcoded.
6. Test transcript is a single line; the two-pass strategy (`tail -n 200` → full-file `jq` fallback, lines 82-90) isn't exercised.
7. Edit anchor fragile — lines 73-74 are contiguous with `STATE_STOP`:75; include lines 73-75 in old/new_string.
8. `do-plan.md` Step 2 duplicates Step 1's loader `find` — two `find` over `~/.claude/plugins` slow `/do-plan` startup.

### Suggestions
- S1. Add cleanup of stale milestone/stop files (delete all but current `SESSION_KEY`), or a Task 5.
- S2. Raise the gate above the `STOP_THRESHOLD` jq (move `SESSION_KEY` above `CONFIG_FILE`) so non-`/do-plan` sessions don't even pay a jq (acknowledges the minimal-diff rationale).
- S3. Expand tests: negative STOP; two sequential calls (150k→175k); compaction-reset (200k→150k→silent).
- S4. Document the fallback-glob limitation in a `/do-plan` Step 2 comment.
- S5. Mention the rejected alternative (separate marker file `do-plan-session-<id>.txt`) in the design doc.

### Questions
- Q1. Why insert the gate after `SESSION_KEY` not after `CONFIG_FILE` — minimal diff or another reason?
- Q2. Cleanup of old milestone/stop files — future PR or accepted tech debt?
- Q3. Basis for "CLAUDE_CODE_SESSION_ID available in slash-command Bash, confidence high" — doc or empirics (before Task 4)?

Summary: design correct in substance; anchors verified. Main gaps: incomplete test coverage (milestone progression, compaction-reset, negative STOP) and no state-file cleanup. No blocker.

---

## ext-claude — ollama/kimi (Kimi K2.6) — supervised retry

### Critical Issues
1. **Fallback on `~/.claude/projects/${CWD_ENC}` is an unverified assumption that can break the gate entirely.** If Claude Code names the dir differently (repo basename, symlink, hash), the fallback finds the wrong transcript → `SID` empty/wrong → hook silent inside `/do-plan`. Single point of failure; no confirmation of the naming convention in the repo.
2. **Re-running `/do-plan` in the same session with a new threshold — STOP won't fire.** If `sessA` already ran `/do-plan 250k` (`context-stop-sessA.txt`=1), then `/do-plan 300k` — the file stays `1`, the hook never re-enters `STOP_FIRED=0`, the new threshold never registers. "Inside /do-plan: unchanged" hides this latent defect. Task-1 regressions don't catch it (clean tmp dir).
3. **Legacy config without `plan_session_id` → full silence (breaking change for active sessions).** Updating the plugin mid-`/do-plan` with an old config silently kills milestones and STOP with no warning. No migration step/warning.

### Concerns
4. Race on concurrent `/do-plan` in one cwd (per-cwd file shared). Per-session marker (rejected) has no race.
5. Harness doesn't cover compaction-reset (`run_hook` always starts empty → `LAST_MILESTONE=0`).
6. `jq` on malformed JSON in the gate → silent failure (safe but invisible; "fully silent" suppresses diagnostics).
7. README line 18 imprecise: the gate checks session id, not the literal act of running `/do-plan` (a hand-placed config with a matching id also activates the hook).

### Suggestions
- A. In `/do-plan` Step 2 add `rm -f "$PLUGIN_DATA/state/context-stop-${SID}.txt"` — fixes Critical 2.
- B. Add a malformed-JSON gate test (`assert_silent … 'this is not json'`).
- C. Reconsider per-session state file: per-cwd+`plan_session_id` orphans too, has the race (Concern 4) and needs the fallback; per-session `do-plan-config-<session>.json` solves all three.
- D. CHANGELOG: explicitly note the breaking change ("Legacy do-plan-config files without plan_session_id are ignored; re-run /do-plan to re-bind").
- E. Cleanup: delete `context-milestone-*`/`context-stop-*` older than N days when writing a new config.

### Questions
1. How does Claude Code name `~/.claude/projects/` dirs — empirically confirmed to match `pwd | sed 's|/|-|g'` (not basename/slug/hash)?
2. Why was the per-session config file rejected (it removes the race, the fallback glob, and stale per-cwd state)?
3. On repeat `/do-plan` in one session with a different threshold (`context-stop-<session>.txt` already `1`) — reset `STATE_STOP`, or out of scope?
4. How do tests confirm the gate didn't break compaction-reset?

---

## ext-claude — ollama/minimax (MiniMax M2.7) — supervised retry

### Critical Issues
- CI-1 (re-checked, NOT confirmed): walked all 4 test cases; gate logic is correct (`"" = "sessA"` → false → exit 0).
- CI-2: `|| true` on the gate jq is redundant (`jq -r` already exits 0 + prints empty for a missing key). Stylistic.
- CI-3: Orphaned `context-milestone-*`/`context-stop-*` accumulate, never cleaned. Harmless but unbounded for long-lived cwds. Design Edge-cases doesn't address it.
- CI-4: `check-context-size.sh` lacks the bash-4+ guard `config-loader.sh` has (`pipefail` absent in bash 3 / macOS default). OK since plugin requires bash 4+, but document it.

### Concerns
- CO-1: `CWD_ENC` (`pwd | sed 's|/|-|g'`) asserted to match the transcript-dir naming but not empirically verified; a path with spaces/special chars may encode differently.
- CO-2: Fallback glob race: empty env var + multiple active sessions in one cwd → picks the merely-newest transcript → wrong gate. Document the limitation.
- CO-3: Confirms the subagent guard (`AGENT_ID` non-empty → exit 0 at ~50) correctly sits above the new gate.

### Suggestions
- S-1: Test's `rm -rf "$tmp"` won't run if bash is signaled mid-test; add `trap 'rm -rf "$tmp"' EXIT` inside `run_hook`.
- S-2: No boundary assertion for exactly 149999 tokens (verified correctly silent).
- S-3: Add a rollback/failure note: if `/do-plan` writes the config but the hook later can't read it (perms, disk full), the hook goes silent with no warning — document as expected.
- S-4: README wording "active only inside a `/do-plan` session (silent everywhere else)"; warn "silent" = zero output.

### Questions
- Q-1: Why `// empty` vs `// ""` (no behavioral difference)?
- Q-2: Basis for "high confidence" that `CLAUDE_CODE_SESSION_ID` is populated in slash-command Bash — Anthropic docs or only Task 4?
- Q-3: Re-invoking `/do-plan` in the same session overwrites the config with the same id → gate stays correct (verified).

Verdict: architecture correct (session-binding via transcript stem "elegant and minimal"); main gaps are orphaned state files (CI-3) and unverified path-encoding (CO-1). Feasibility high.

---

## Cross-model convergence (orchestrator note)

- **Fallback session-id resolution is broken two independent ways:** wrong dir-encoding on `.`/`_` paths (claude-self, empirical) AND wrong-session selection via `ls -t` mtime (codex, empirical, even on the clean path). Raised by 6/7 reviewers. Strong cross-recommendation: **drop the fallback and fail-fast** if `CLAUDE_CODE_SESSION_ID` is empty.
- **Per-cwd single-owner config → concurrent `/do-plan` race / last-writer-wins.** Raised by 6/7. Options: document-and-accept vs per-session config file.
- **Broken intermediate commit** (Task 1 gate committed before Task 2's do-plan write). codex, empirically grounded.
- **Test harness masks crashes as "silent"** (no rc/stderr/state-file assertion). codex + glm + minimax.
- **printf → jq** for the config write. qwen + glm.
- **Doc precision** ("fully silent" → "silent in output"; orphan cleanup out of scope). deepseek + qwen + minimax + claude-self.
- **Several test additions** (negative STOP, malformed-JSON gate, milestone progression, compaction-reset, 149999 boundary).
