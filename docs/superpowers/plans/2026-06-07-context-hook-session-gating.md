# Context-Size Hook Session-Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `check-context-size.sh` emit milestone/STOP reminders only inside the session where `/do-plan` was started; stay completely silent everywhere else.

**Architecture:** `/do-plan` writes the current session id (`plan_session_id`) into the per-cwd state file. The hook computes the same id from its transcript path and, before any milestone/STOP logic, exits silently unless the config file exists AND its `plan_session_id` matches. No `config.yaml` parsing in the hook (stays lightweight).

**Tech Stack:** Bash, `jq`, Claude Code PostToolUse hooks, the plugin's existing shell test harness.

---

## File Structure

- `hooks/check-context-size.sh` — **modify**: add the session gate + update header comment.
- `commands/do-plan.md` — **modify**: Step 2 writes `plan_session_id`; Step 6 gains a "session-scoped" note.
- `skills/shared/tests/test-check-context-size.sh` — **create**: gate test suite (self-contained, isolated tmp state).
- `README.md` — **modify**: line 18 clarification.
- `CHANGELOG.md` — **modify**: Unreleased entry.

No new `config.yaml` fields. `START_K`/`INTERVAL_K` (150/25) and `CC_CONTEXT_*` overrides are untouched.

> **Commit ordering (iter-1 review, ISSUE-4):** Task 2's `/do-plan` change (writing
> `plan_session_id`) must land **before — or in the same commit as** — Task 1's hook
> gate. If the gate is committed first, that intermediate commit still has the real
> `/do-plan` writing a legacy `{stop_threshold}`-only config, so the hook is silent
> *inside* `/do-plan` until Task 2 lands. The Task-1 tests do **not** catch this (they
> synthesise their own matching config) — treat it as a commit-hygiene rule: squash
> Tasks 1–2 into one commit, or implement Task 2 first.

---

## Task 1: Hook session gate + test suite

**Files:**
- Create: `skills/shared/tests/test-check-context-size.sh`
- Modify: `hooks/check-context-size.sh`

- [ ] **Step 1: Write the test suite (failing for the gate cases)**

Create `skills/shared/tests/test-check-context-size.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Tests for check-context-size.sh — session-gated milestone/STOP emission.
# Each case runs the hook against an isolated tmp state dir + a synthetic
# transcript carrying a chosen usage total. No real plugin state is touched.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$TESTS_DIR/../../../hooks/check-context-size.sh"

FAIL=0
PASS=0

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -q -- "$needle"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected to contain: '$needle'; got: '$haystack')"
    fi
}

assert_silent() {
    local desc="$1" haystack="$2"
    if [ -z "$haystack" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected empty stdout; got: '$haystack')"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -q -- "$needle"; then
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected NOT to contain: '$needle'; got: '$haystack')"
    else
        PASS=$((PASS+1)); echo "  PASS: $desc"
    fi
}

# run_hook <usage_total> <session> <agent_id> <config_json|->
#   Builds an isolated CLAUDE_PLUGIN_DATA dir, a transcript named <session>.jsonl
#   carrying <usage_total> tokens, optionally a do-plan-config file, runs the
#   hook, and echoes its stdout.
run_hook() {
    local usage="$1" session="$2" agent_id="$3" config="$4"
    local cwd="/test/proj"          # encodes to -test-proj (matches the hook's sed)
    local cwd_enc="-test-proj"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/state"
    local transcript="$tmp/${session}.jsonl"
    jq -nc --argjson u "$usage" \
        '{type:"assistant",message:{usage:{input_tokens:$u,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}' \
        > "$transcript"
    [ "$config" = "-" ] || printf '%s\n' "$config" > "$tmp/state/do-plan-config-${cwd_enc}.json"
    local stdin; stdin="$(jq -nc --arg t "$transcript" --arg c "$cwd" --arg a "$agent_id" \
        '{transcript_path:$t,cwd:$c,hook_event_name:"PostToolUse",agent_id:$a}')"
    local out rc
    out="$(printf '%s' "$stdin" | CLAUDE_PLUGIN_DATA="$tmp" bash "$HOOK" 2>/dev/null)"; rc=$?
    rm -rf "$tmp"
    # iter-1 ISSUE-5: surface a non-zero hook exit so assert_silent (empty-stdout)
    # cannot mistake a crash (set -e abort, no stdout) for intentional silence.
    [ "$rc" -eq 0 ] || out="${out}[hook exited rc=${rc}]"
    printf '%s' "$out"
}

echo "== check-context-size: session gate =="

# --- Gate drivers: hook must be silent outside the /do-plan session ---
assert_silent "no do-plan-config → silent at 200k" \
    "$(run_hook 200000 sessA "" "-")"
assert_silent "wrong plan_session_id → silent at 200k" \
    "$(run_hook 200000 sessA "" '{"stop_threshold":250000,"plan_session_id":"OTHER"}')"
assert_silent "legacy config (no plan_session_id) → silent at 200k" \
    "$(run_hook 200000 sessA "" '{"stop_threshold":250000}')"

# --- Regressions: inside the /do-plan session behavior is unchanged ---
assert_contains "matching session + 150k → ctx:150k" "ctx:150k" \
    "$(run_hook 150000 sessA "" '{"stop_threshold":250000,"plan_session_id":"sessA"}')"

# iter-1 ISSUE-13: lock the STOP line format (milestone floored to 250k, STOP appended).
STOP_OUT="$(run_hook 260000 sessA "" '{"stop_threshold":250000,"plan_session_id":"sessA"}')"
assert_contains "matching session + 260k/thr250k → milestone ctx:250k" "ctx:250k" "$STOP_OUT"
assert_contains "matching session + 260k/thr250k → STOP" "STOP" "$STOP_OUT"

assert_silent "subagent (agent_id set) → silent" \
    "$(run_hook 200000 sessA "sub-123" '{"stop_threshold":250000,"plan_session_id":"sessA"}')"
assert_silent "matching session + 100k (below 150k floor) → silent" \
    "$(run_hook 100000 sessA "" '{"stop_threshold":250000,"plan_session_id":"sessA"}')"

# iter-1 ISSUE-12: negative STOP — threshold is read from config (300k), not hardcoded.
# Usage 260k crosses the 250k milestone but stays below the 300k STOP threshold.
NEG_OUT="$(run_hook 260000 sessA "" '{"stop_threshold":300000,"plan_session_id":"sessA"}')"
assert_contains "matching session + 260k/thr300k → milestone ctx:250k" "ctx:250k" "$NEG_OUT"
assert_not_contains "matching session + 260k/thr300k → no STOP (below threshold)" "STOP" "$NEG_OUT"

# iter-1 ISSUE-12: malformed config JSON → the gate's jq fails safe under set -e → silent.
assert_silent "malformed config JSON → silent" \
    "$(run_hook 200000 sessA "" 'this is not json')"

echo
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

Make it executable:

```bash
chmod +x skills/shared/tests/test-check-context-size.sh
```

- [ ] **Step 2: Run the tests, verify the 3 gate-driver cases FAIL**

Run: `bash skills/shared/tests/test-check-context-size.sh`
Expected: the three `→ silent at 200k` gate-driver cases **and** the `malformed config JSON → silent` case FAIL (the current, ungated hook emits `ctx:200k` for all four); the seven regression assertions PASS. Overall `RESULTS: 7 passed, 4 failed`, non-zero exit.

- [ ] **Step 3: Add the session gate to the hook**

In `hooks/check-context-size.sh`, find this trio of lines (currently ~73–75):

```bash
SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"
STATE_MILESTONE="$STATE_DIR/context-milestone-${SESSION_KEY}.txt"
STATE_STOP="$STATE_DIR/context-stop-${SESSION_KEY}.txt"
```

Replace with (insert the gate right after `SESSION_KEY` — reuse the existing `SESSION_KEY`/`CONFIG_FILE`, do NOT recompute them; keep the two `STATE_*` lines below the gate so the silent path skips their reads):

```bash
SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"

# ---- Gate: emit ONLY inside the session where /do-plan was started ----
# Outside a /do-plan session the hook emits nothing to the model (no milestone,
# no STOP). It has already run its cheap preamble (mkdir + the stop_threshold jq)
# above — "silent" here means no additionalContext, not no work.
# /do-plan records its session id in plan_session_id (see commands/do-plan.md
# Step 2). A missing config file, a missing plan_session_id (legacy file), or a
# mismatch (stale per-cwd file from an earlier session) → exit silently.
# NOTE (set -e): the `|| true` below is required — under `set -euo pipefail`, jq
# exits non-zero on a malformed/empty config and would otherwise abort the hook.
[ -f "$CONFIG_FILE" ] || exit 0
PLAN_SESSION="$(jq -r '.plan_session_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
[ "$PLAN_SESSION" = "$SESSION_KEY" ] || exit 0

STATE_MILESTONE="$STATE_DIR/context-milestone-${SESSION_KEY}.txt"
STATE_STOP="$STATE_DIR/context-stop-${SESSION_KEY}.txt"
```

- [ ] **Step 4: Update the hook header comment**

In `hooks/check-context-size.sh`, find (currently ~5–6):

```bash
# emits a compact additionalContext system reminder to the model:
#
```

Replace with:

```bash
# emits a compact additionalContext system reminder to the model.
#
# SESSION-SCOPED: active only for the session in which /do-plan was started (and
# for the rest of that session, even after /do-plan finishes). The per-cwd state
# file records that session id (plan_session_id); any other session — including an
# ordinary session in the same cwd after a past /do-plan — gets no model-visible
# output (the hook still runs its cheap mkdir/jq preamble, then exits at the gate).
#
```

- [ ] **Step 5: Run the tests, verify all PASS**

Run: `bash skills/shared/tests/test-check-context-size.sh`
Expected: `RESULTS: 11 passed, 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add hooks/check-context-size.sh skills/shared/tests/test-check-context-size.sh
git commit -m "fix: gate context-size hook to the /do-plan session + tests"
```

> ⚠️ Per the Commit-ordering note at the top (ISSUE-4): do **not** ship this commit
> ahead of Task 2's `/do-plan` change. Squash Tasks 1–2 into one commit, or commit
> Task 2 first — otherwise this commit leaves the real `/do-plan` silent.

---

## Task 2: `/do-plan` records `plan_session_id`

**Files:**
- Modify: `commands/do-plan.md`

- [ ] **Step 1: Update Step 2's Bash block to resolve + write the session id**

In `commands/do-plan.md`, find the Step 2 Bash block ending with these two lines:

```bash
CWD_ENC=$(pwd | sed 's|/|-|g')
printf '{"stop_threshold": %d}\n' <THRESHOLD> > "$PLUGIN_DATA/state/do-plan-config-${CWD_ENC}.json"
```

Replace those two lines with:

```bash
CWD_ENC=$(pwd | sed 's|/|-|g')

# Bind the hook to THIS session. check-context-size.sh emits milestone/STOP only
# when plan_session_id matches the current session. The session id equals the
# transcript filename stem, which the hook derives independently from its input.
SID="${CLAUDE_CODE_SESSION_ID:-}"
# Fallback if the var is empty in slash-command Bash: newest transcript of this project.
[ -n "$SID" ] || SID="$(ls -t "$HOME/.claude/projects/${CWD_ENC}"/*.jsonl 2>/dev/null \
    | head -1 | xargs -r -n1 basename | sed 's/\.jsonl$//')"
[ -n "$SID" ] || { echo "/claude-mesh:do-plan: could not resolve session id" >&2; exit 1; }

printf '{"stop_threshold": %d, "plan_session_id": "%s"}\n' <THRESHOLD> "$SID" \
    > "$PLUGIN_DATA/state/do-plan-config-${CWD_ENC}.json"
```

- [ ] **Step 2: Document the new field below the block**

In `commands/do-plan.md`, immediately after the Step 2 code block, find:

```markdown
Substitute `<THRESHOLD>` with the integer resolved in Step 1.
```

Replace with:

```markdown
Substitute `<THRESHOLD>` with the integer resolved in Step 1.

The `plan_session_id` field binds the hook to this session. The hook stays silent
unless it matches the current session id, so an ordinary session in the same cwd
(or a stale config from a past `/do-plan`) gets no milestone/STOP reminders. On
`/claude-mesh:continue-plan-fresh-session`, the new session re-runs `/do-plan`,
which overwrites the field with the new session id.
```

- [ ] **Step 3: Add the session-scoped note to Step 6**

In `commands/do-plan.md`, find (Step 6 intro):

```markdown
The `PostToolUse` hook will inject system reminders of two kinds:
```

Replace with:

```markdown
The `PostToolUse` hook will inject system reminders of two kinds. These appear
**only** in the session where you started `/do-plan` (the hook is gated on the
`plan_session_id` written in Step 2) — and for the rest of that session, even after
`/do-plan` finishes; in any other session (including an ordinary one in the same
cwd) it stays silent.
```

- [ ] **Step 4: Commit**

```bash
git add commands/do-plan.md
git commit -m "fix: /do-plan records plan_session_id for the context hook"
```

---

## Task 3: README + CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Clarify the hook line in README**

In `README.md`, find (line 18):

```markdown
- **Context-size hook** — `check-context-size` warns when approaching STOP threshold
```

Replace with:

```markdown
- **Context-size hook** — `check-context-size` warns when approaching the STOP threshold; active only inside a `/do-plan` session (silent everywhere else)
```

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, find:

```markdown
## [Unreleased]

### Added
- Initial release: ext-claude-* family, codex/gemini wrappers, mesh-review,
  mesh-design-review, session/plan helpers, check-context-size hook.
```

Replace with:

```markdown
## [Unreleased]

### Added
- Initial release: ext-claude-* family, codex/gemini wrappers, mesh-review,
  mesh-design-review, session/plan helpers, check-context-size hook.

### Fixed
- check-context-size hook is now scoped to the `/do-plan` session: it no longer
  injects `ctx:` milestone reminders into ordinary sessions (which made the agent
  economize context prematurely). `/do-plan` records `plan_session_id`; the hook
  emits milestone/STOP only when it matches the current session. Legacy
  `do-plan-config-*.json` files written before this change (no `plan_session_id`)
  are treated as a mismatch and ignored — re-run `/claude-mesh:do-plan` to re-bind
  the hook to the current session.
```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: note context hook is /do-plan-session-scoped"
```

---

## Task 4: Manual verification of the session-id assumption

This task is **manual** (the controller/user runs it interactively — a subagent
cannot run slash commands). It confirms the one design assumption:
`CLAUDE_CODE_SESSION_ID` is populated in slash-command Bash.

- [ ] **Step 1: Run `/do-plan` in a real session and inspect the state file**

In a Claude Code session in this repo, run `/claude-mesh:do-plan 200k` (any
plan or none — Step 2 writes the file before execution). Then check:

```bash
STATE="$HOME/.claude/plugins/data/claude-mesh-zinin/state"
CWD_ENC=$(pwd | sed 's|/|-|g')
cat "$STATE/do-plan-config-${CWD_ENC}.json"
echo "current session id: $CLAUDE_CODE_SESSION_ID"
```

Expected: the file contains both `stop_threshold` and a non-empty
`plan_session_id`, and `plan_session_id` equals `$CLAUDE_CODE_SESSION_ID` (which
equals the current transcript filename stem). If `plan_session_id` is empty, the
fallback failed too — investigate before relying on the gate.

- [ ] **Step 2: Confirm an ordinary session is silent**

Open a separate, fresh Claude Code session in the same repo (do NOT run
`/do-plan`), and do enough tool-using work to push context past 150k. Confirm no
`ctx:` reminders appear. (If you cannot easily reach 150k, trust the automated
"no/ wrong/legacy config → silent" cases in Task 1.)

---

## Self-Review

**Spec coverage:**
- Outside `/do-plan` silent → Task 1 gate (cases 1–3) + Task 4 Step 2. ✓
- Inside `/do-plan` unchanged → Task 1 regressions (cases 4–7). ✓
- Hook stays lightweight (no `config.yaml`) → gate uses only `jq` on the state file. ✓
- `START_K`/`INTERVAL_K` untouched → no task modifies them. ✓
- `/do-plan` writes `plan_session_id` → Task 2. ✓
- Edge cases (continue-fresh, stale config, legacy file, subagent) → Tasks 1–2. ✓
- Docs (hook header, do-plan Step 2/6, README, CHANGELOG) → Tasks 1–3. ✓
- Assumption verification → Task 4. ✓

**Placeholder scan:** `<THRESHOLD>` is the pre-existing do-plan.md substitution token, kept verbatim — not a plan placeholder. No TBD/TODO/"handle edge cases".

**Type/name consistency:** `plan_session_id`, `CONFIG_FILE`, `SESSION_KEY`, `PLAN_SESSION`, `SID`, `CWD_ENC`, `CLAUDE_PLUGIN_DATA` used identically across the hook, the test, and `/do-plan`. State filename `do-plan-config-<cwd-enc>.json` matches the existing hook contract.
