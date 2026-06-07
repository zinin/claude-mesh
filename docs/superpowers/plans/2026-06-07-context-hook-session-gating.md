# Context-Size Hook Session-Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `check-context-size.sh` emit milestone/STOP reminders only inside the session where `/do-plan` was started; stay completely silent everywhere else.

**Architecture:** `/do-plan` writes a **per-session** state file `do-plan-config-<cwd>-<session>.json` (session id from `$CLAUDE_CODE_SESSION_ID`). The hook computes the same id from its transcript path and, before any milestone/STOP logic, exits silently unless *its own* session's config file exists. Per-session keying means two concurrent `/do-plan` runs in one cwd never clobber each other. No `config.yaml` parsing in the hook (stays lightweight).

**Tech Stack:** Bash, `jq`, Claude Code PostToolUse hooks, the plugin's existing shell test harness.

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
> never finds — so the hook is silent *inside* `/do-plan` until Task 2 lands. The
> Task-1 tests do **not** catch this (they synthesise their own per-session config)
> — treat it as a commit-hygiene rule: squash Tasks 1–2 into one commit, or
> implement Task 2 first.

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
#
# Gating model (per-session config, iter-1 review Variant B): /do-plan writes a
# per-session file do-plan-config-<cwd>-<session>.json; the hook emits only when
# THIS session's own file exists. Concurrent /do-plan runs in one cwd never clash.
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

# run_hook <usage_total> <session> <agent_id> <config_owner|-> [stop_threshold] [raw_config]
#   Runs the hook AS <session> (transcript <session>.jsonl carrying <usage_total>).
#   If <config_owner> != "-", writes a per-session config
#   do-plan-config-<cwd>-<config_owner>.json carrying {stop_threshold:[default 250000]}.
#   The gate emits only when the hook's own session owns a config, i.e.
#   <config_owner> == <session>. If [raw_config] is non-empty, that literal string
#   is written as the config body instead of well-formed JSON (malformed-file test).
run_hook() {
    local usage="$1" session="$2" agent_id="$3" config_owner="$4" threshold="${5:-250000}" raw="${6:-}"
    local cwd="/test/proj"          # encodes to -test-proj (matches the hook's sed)
    local cwd_enc="-test-proj"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/state"
    local transcript="$tmp/${session}.jsonl"
    jq -nc --argjson u "$usage" \
        '{type:"assistant",message:{usage:{input_tokens:$u,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}' \
        > "$transcript"
    if [ "$config_owner" != "-" ]; then
        local cfg="$tmp/state/do-plan-config-${cwd_enc}-${config_owner}.json"
        if [ -n "$raw" ]; then
            printf '%s\n' "$raw" > "$cfg"
        else
            jq -nc --argjson thr "$threshold" '{stop_threshold:$thr}' > "$cfg"
        fi
    fi
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

# --- Gate drivers: silent unless THIS session owns a /do-plan config ---
assert_silent "no config for this session → silent at 200k" \
    "$(run_hook 200000 sessA "" "-")"
assert_silent "config owned by a DIFFERENT session → silent at 200k" \
    "$(run_hook 200000 sessA "" sessB)"

# --- Regressions: inside the /do-plan session behavior is unchanged ---
assert_contains "own config + 150k → ctx:150k" "ctx:150k" \
    "$(run_hook 150000 sessA "" sessA)"

# iter-1 ISSUE-13: lock the STOP line format (milestone floored to 250k, STOP appended).
STOP_OUT="$(run_hook 260000 sessA "" sessA 250000)"
assert_contains "own config + 260k/thr250k → milestone ctx:250k" "ctx:250k" "$STOP_OUT"
assert_contains "own config + 260k/thr250k → STOP" "STOP" "$STOP_OUT"

assert_silent "subagent (agent_id set) → silent" \
    "$(run_hook 200000 sessA "sub-123" sessA)"
assert_silent "own config + 100k (below 150k floor) → silent" \
    "$(run_hook 100000 sessA "" sessA)"

# iter-1 ISSUE-12: negative STOP — threshold is read from config (300k), not hardcoded.
# Usage 260k crosses the 250k milestone but stays below the 300k STOP threshold.
NEG_OUT="$(run_hook 260000 sessA "" sessA 300000)"
assert_contains "own config + 260k/thr300k → milestone ctx:250k" "ctx:250k" "$NEG_OUT"
assert_not_contains "own config + 260k/thr300k → no STOP (below threshold)" "STOP" "$NEG_OUT"

# iter-1 ISSUE-12: malformed own config → [ -f ] gate passes; the stop_threshold jq
# fails safe under set -e (no STOP). Milestone still emits; the hook must not crash.
MAL_OUT="$(run_hook 200000 sessA "" sessA 250000 'this is not json')"
assert_contains "malformed own config → milestone still emits (no crash)" "ctx:200k" "$MAL_OUT"
assert_not_contains "malformed own config → no STOP (threshold unreadable)" "STOP" "$MAL_OUT"

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
Expected against the current (ungated, per-cwd-reading) hook: the two gate-driver `→ silent at 200k` cases and the `own config + 260k/thr250k → STOP` assertion FAIL — the current hook reads the old per-cwd `do-plan-config-<cwd>.json`, never finds the test's per-session files, so it emits milestones everywhere and never reads a threshold. The other eight assertions PASS. Overall `RESULTS: 8 passed, 3 failed`, non-zero exit.

- [ ] **Step 3: Add the session gate to the hook**

The current hook computes `CONFIG_FILE` (per-cwd) at ~line 68 and reads `STOP_THRESHOLD` at ~line 70, *before* `SESSION_KEY` (~line 73). For a per-session file, `CONFIG_FILE` must move **below** `SESSION_KEY`. Find this block (currently ~68–75):

```bash
CONFIG_FILE="$STATE_DIR/do-plan-config-${CWD_ENC}.json"
# Default: 999_999_999 = effectively no STOP threshold if /do-plan not invoked
STOP_THRESHOLD="$(jq -r '.stop_threshold // 999999999' "$CONFIG_FILE" 2>/dev/null || echo "999999999")"

# ---- Per-session state (keyed off transcript filename, NOT cwd) ----
SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"
STATE_MILESTONE="$STATE_DIR/context-milestone-${SESSION_KEY}.txt"
STATE_STOP="$STATE_DIR/context-stop-${SESSION_KEY}.txt"
```

Replace with (compute `SESSION_KEY` first, then gate on the per-session config's existence, then read the threshold — the silent path pays no `jq` at all):

```bash
# ---- Per-session state (keyed off transcript filename, NOT cwd) ----
SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"

# ---- Gate: emit ONLY inside the session where /do-plan was started ----
# /do-plan writes a PER-SESSION config do-plan-config-<cwd>-<session>.json (see
# commands/do-plan.md Step 2). No file for THIS session → /do-plan never ran here
# → exit silently (no milestone, no STOP). Keying the config by session (not just
# cwd) means two concurrent /do-plan runs in one cwd never clobber each other; old
# per-cwd configs (different filename) are simply ignored. "Silent" = no
# additionalContext; the mkdir preamble above still runs.
CONFIG_FILE="$STATE_DIR/do-plan-config-${CWD_ENC}-${SESSION_KEY}.json"
[ -f "$CONFIG_FILE" ] || exit 0

# stop_threshold from THIS session's config. Default 999_999_999 = no STOP
# (defense in depth; /do-plan always writes it). The `|| echo` keeps the hook
# alive under `set -euo pipefail` if the file is somehow malformed.
STOP_THRESHOLD="$(jq -r '.stop_threshold // 999999999' "$CONFIG_FILE" 2>/dev/null || echo "999999999")"

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
# for the rest of that session, even after /do-plan finishes). /do-plan writes a
# per-session config do-plan-config-<cwd>-<session>.json; the hook emits only if
# the file named for ITS session exists. Any other session — including an ordinary
# one in the same cwd after a past /do-plan — gets no model-visible output (the
# hook still runs its cheap mkdir preamble, then exits at the gate).
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

## Task 2: `/do-plan` writes the per-session config file

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

# Bind the hook to THIS session via a PER-SESSION config file
# do-plan-config-<cwd>-<session>.json. check-context-size.sh reads the file named
# for its own session (SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"), so the
# id below must be byte-equal to that stem. Per-session keying means two concurrent
# /do-plan runs in one cwd never clobber each other.
#
# No transcript-dir glob fallback (iter-1 review ISSUE-1/2): ~/.claude/projects/
# dir names encode '.'/'_'->'-' too (not just '/'), so a sed 's|/|-|g' glob misses
# on many real paths; and `ls -t | head -1` can pick another session's transcript
# under concurrency. No glob can identify "this" session, so fail loudly instead.
# Task 4 verifies CLAUDE_CODE_SESSION_ID is populated in slash-command Bash.
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || { echo "/claude-mesh:do-plan: CLAUDE_CODE_SESSION_ID is empty — cannot bind the context hook to this session. Aborting (see Task 4)." >&2; exit 1; }

# Atomic write with jq (not printf): robust to a concurrent hook read seeing a
# half-written file. Session is in the filename, so the body is just the threshold.
CONFIG_PATH="$PLUGIN_DATA/state/do-plan-config-${CWD_ENC}-${SID}.json"
CONFIG_TMP="$(mktemp "$PLUGIN_DATA/state/.do-plan-config-${CWD_ENC}-${SID}.XXXXXX")" \
    || { echo "/claude-mesh:do-plan: mktemp failed for config" >&2; exit 1; }
jq -nc --argjson thr <THRESHOLD> '{stop_threshold:$thr}' > "$CONFIG_TMP" \
    && mv -f "$CONFIG_TMP" "$CONFIG_PATH"
```

- [ ] **Step 2: Update the path prose and document the per-session file**

First, in `commands/do-plan.md`, update the Step 2 intro prose. Find:

```markdown
The hook reads `<plugin-data>/state/do-plan-config-<cwd-encoded>.json` to know the STOP threshold, where `<plugin-data>` is the plugin's data dir (resolved by the loader) and `<cwd-encoded>` is the absolute `pwd` with every `/` replaced by `-`. The hook (`check-context-size.sh`) resolves the same data dir and computes `<cwd-encoded>` from the same `pwd` encoding, so both sides converge on one absolute path.
```

Replace with:

```markdown
The hook reads `<plugin-data>/state/do-plan-config-<cwd-encoded>-<session>.json` to know the STOP threshold, where `<plugin-data>` is the plugin's data dir (resolved by the loader), `<cwd-encoded>` is the absolute `pwd` with every `/` replaced by `-`, and `<session>` is the current session id. The hook (`check-context-size.sh`) resolves the same data dir, computes `<cwd-encoded>` from the same `pwd` encoding, and derives `<session>` from its transcript filename stem — so both sides converge on one absolute path. Per-session keying lets two concurrent `/do-plan` runs in one cwd coexist without clobbering each other's threshold.
```

Then, immediately after the Step 2 code block, find:

```markdown
Substitute `<THRESHOLD>` with the integer resolved in Step 1.
```

Replace with:

```markdown
Substitute `<THRESHOLD>` with the integer resolved in Step 1.

The per-session filename (`do-plan-config-<cwd>-<session>.json`) binds the hook to
this session: the hook reads the file named for its own session, so an ordinary
session in the same cwd (or a stale file from a past `/do-plan`) is never seen and
gets no milestone/STOP reminders. Two concurrent `/do-plan` runs in one cwd each
own their own file and don't clobber each other. On
`/claude-mesh:continue-plan-fresh-session`, the new session re-runs `/do-plan`,
which writes a file for the new session id.
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
per-session config file written in Step 2) — and for the rest of that session, even
after `/do-plan` finishes; in any other session (including an ordinary one in the
same cwd) it stays silent.
```

- [ ] **Step 4: Commit**

```bash
git add commands/do-plan.md
git commit -m "fix: /do-plan writes a per-session config for the context hook"
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
  economize context prematurely). `/do-plan` writes a per-session config file
  `do-plan-config-<cwd>-<session>.json`; the hook emits milestone/STOP only in the
  session that owns a file. Two concurrent `/do-plan` runs in one cwd no longer
  clobber each other. Old per-cwd `do-plan-config-<cwd>.json` files (pre-change)
  have a different name and are ignored — re-run `/claude-mesh:do-plan` to re-bind.
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

This step is now **blocking** (iter-1 review): with the glob fallback removed, the
gate relies entirely on `CLAUDE_CODE_SESSION_ID` being populated in slash-command
Bash. If it is empty, `/do-plan` now aborts loudly instead of guessing.

In a Claude Code session in this repo, run `/claude-mesh:do-plan 200k` (any
plan or none — Step 2 writes the file before execution). Then check:

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

- [ ] **Step 2: Confirm an ordinary session is silent**

Open a separate, fresh Claude Code session in the same repo (do NOT run
`/do-plan`), and do enough tool-using work to push context past 150k. Confirm no
`ctx:` reminders appear. (If you cannot easily reach 150k, trust the automated
"no config / different-session config → silent" cases in Task 1.)

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

**Placeholder scan:** `<THRESHOLD>` is the pre-existing do-plan.md substitution token, kept verbatim — not a plan placeholder. No TBD/TODO/"handle edge cases".

**Type/name consistency:** `CONFIG_FILE`, `SESSION_KEY`, `SID`, `CWD_ENC`, `CLAUDE_PLUGIN_DATA`, `STOP_THRESHOLD` used identically across the hook, the test, and `/do-plan`. Per-session state filename `do-plan-config-<cwd-enc>-<session>.json` is computed identically on both sides (hook from `SESSION_KEY`, `/do-plan` from `$CLAUDE_CODE_SESSION_ID`). The `plan_session_id` JSON field is gone — the session lives in the filename.
