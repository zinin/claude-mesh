# Design: gate the context-size hook to the `/do-plan` session

**Date:** 2026-06-07
**Status:** Approved (brainstorming)
**Components:** `hooks/check-context-size.sh`, `commands/do-plan.md`, docs, tests

## Problem

`hooks/check-context-size.sh` is wired on `PostToolUse` with matcher `.*`, so it
fires in **every** session after every tool call. Starting at 150k it injects
`ctx:150k`, `ctx:175k`, … into the model context via `additionalContext`.

The only place that tells the agent these are *passive markers — do not change
behavior* is `commands/do-plan.md`, Step 6. That file enters context **only when
`/do-plan` is running**. In an ordinary session the agent sees a bare `ctx:175k`
with no framing and reads it as "context is filling up → start economizing" —
premature context-saving the user never asked for. With Opus' 1M window there is
no reason to economize that early.

Confirmed in the live `state/` dir: `context-milestone-<session>.txt` files exist
for sessions that have **no** `do-plan-config` — i.e. milestones were being
emitted in plain sessions.

The whole milestone/STOP mechanism is only meaningful inside `/do-plan` (the STOP
threshold is written to a state file exclusively by that command). Outside
`/do-plan` the hook emits **only** the useless milestones.

## Goals

- Outside `/do-plan`: the hook emits **nothing into the model context** (no
  `additionalContext`). Note: it still runs its cheap preamble (`mkdir -p` on the
  state dir, one `jq` on the per-cwd config) before the gate — "silent" means *no
  model-visible output*, not *no work*.
- Inside `/do-plan`: behavior is **unchanged** (milestones `START_K`/`INTERVAL_K`
  = 150/25, plus the one-shot STOP at the threshold).
- Keep the hook **lightweight** — it must not parse `config.yaml` (that needs
  `yq`+Python on every `PostToolUse`).

## Non-goals

- Moving `START_K`/`INTERVAL_K` into `config.yaml`. With milestones now confined
  to `/do-plan`, the 150/25 defaults are fine; the existing `CC_CONTEXT_*` env
  overrides stay as the (undocumented) escape hatch.
- Changing the milestone/STOP message formats, the compaction-reset logic, or the
  `do_plan_default_stop_tokens >= 150000` validation.
- Cleaning up accumulated per-session state files (`context-milestone-<session>.txt`
  / `context-stop-<session>.txt`). These are pre-existing and grow one pair per
  `/do-plan` session; the gate only prevents *new* files from being created in
  non-`/do-plan` sessions. Bounded cleanup is left to a future change.

## Design

### Session-scoped gate

Both sides already know the same session id, so we can bind hook activity to "the
session in which `/do-plan` was started". The binding is **session-scoped, not
command-scoped**: once `/do-plan` runs in a session, the hook stays active for the
rest of that session (even after `/do-plan` finishes). Any *other* session —
including an ordinary one in the same cwd — stays silent.

- **Hook** computes `SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"`.
- **`/do-plan`** reads `$CLAUDE_CODE_SESSION_ID`.

These are the same value (verified: env `CLAUDE_CODE_SESSION_ID` equals the
transcript filename stem).

The state file is **per session**: `do-plan-config-<cwd-encoded>-<session>.json`.
`/do-plan` writes the file for its own session; the hook looks for the file named
after *its* session and emits only if it exists. A `/do-plan` in a different
session (or a stale file from a past one) has a different filename, so the current
session never sees it — no "file exists" false-positive, and **two concurrent
`/do-plan` runs in the same cwd never clobber each other** (each owns its own file).

State file schema (session encoded in the filename, so the body is just the
threshold):

```json
{"stop_threshold": 250000}
```

### Hook changes (`check-context-size.sh`)

`CONFIG_FILE` now depends on `SESSION_KEY`, so it must be computed **after**
`SESSION_KEY` (current line ~73), not at the current line ~68. Move the
`CONFIG_FILE` + `STOP_THRESHOLD` read below `SESSION_KEY`, gate on the file's
existence, then read the threshold:

```bash
SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)"

# Gate: this session owns a /do-plan config iff the per-session file exists.
CONFIG_FILE="$STATE_DIR/do-plan-config-${CWD_ENC}-${SESSION_KEY}.json"
[ -f "$CONFIG_FILE" ] || exit 0

# Threshold from THIS session's config (defense in depth: // 999999999).
STOP_THRESHOLD="$(jq -r '.stop_threshold // 999999999' "$CONFIG_FILE" 2>/dev/null || echo "999999999")"
```

Notes:
- The gate is a plain `[ -f ]` — no `jq` match needed, the session is in the
  filename. Old per-cwd `do-plan-config-<cwd>.json` files (no session suffix) have
  a different name → never read → silent. Safe by construction.
- `STOP_THRESHOLD` moves below the gate, so the silent path pays no `jq` at all.
- The `agent_id`-non-empty early `exit 0` (subagent guard) stays above the gate.

### `/do-plan` changes (`commands/do-plan.md`, Step 2)

Resolve the session id and write it into the state file:

```bash
# The hook derives the same id independently as
# SESSION_KEY="$(basename "$TRANSCRIPT_PATH" .jsonl)" and reads the file named for
# its own session, so $SID must be byte-equal to that stem.
SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || { echo "/claude-mesh:do-plan: CLAUDE_CODE_SESSION_ID is empty — cannot bind the context hook. Aborting." >&2; exit 1; }

# Per-session config file (session in the NAME, threshold in the body). Atomic
# write with jq: robust to a concurrent hook read seeing a half-written file.
CONFIG_PATH="$PLUGIN_DATA/state/do-plan-config-${CWD_ENC}-${SID}.json"
CONFIG_TMP="$(mktemp "$PLUGIN_DATA/state/.do-plan-config-${CWD_ENC}-${SID}.XXXXXX")"
jq -nc --argjson thr <THRESHOLD> '{stop_threshold:$thr}' > "$CONFIG_TMP" \
    && mv -f "$CONFIG_TMP" "$CONFIG_PATH"
```

**No transcript-dir glob fallback.** Earlier drafts fell back to
`ls -t ~/.claude/projects/${CWD_ENC}/*.jsonl` when the env var was empty. iter-1
review (ISSUE-1/2, empirically verified) removed it: (a) `~/.claude/projects/` dir
names encode `.`/`_`→`-` too, not just `/`, so `sed 's|/|-|g'` misses on many real
paths (e.g. `/opt/git/sib.certhub2` → real dir `-opt-git-sib-certhub2`); (b)
`ls -t | head -1` picks the most-recently-*modified* transcript, which under
concurrent sessions may be a different session — silently binding the wrong one.
No glob can identify "this" session (that id is exactly what we are resolving), so
a correct fallback does not exist. Failing loudly is safer; **Task 4** verifies
the env var and is blocking.

### What stays unchanged

`START_K`/`INTERVAL_K` (150/25) and `CC_CONTEXT_*` overrides · milestone message
format · STOP message format · compaction-reset logic · `config.yaml` (no new
fields) · `do_plan_default_stop_tokens >= 150000` validation.

## Edge cases

- **continue-plan-fresh-session:** new session B → `/do-plan` writes
  `do-plan-config-<cwd>-B.json` → hook active in B (its own file). ✓
- **Stale config from a prior `/do-plan`:** a past session's file is named for that
  session; the current session looks for its own name → not found → silent. Exactly
  the fix for the reported problem. ✓
- **Two concurrent `/do-plan` in one cwd:** each session writes its own
  `do-plan-config-<cwd>-<session>.json`; neither clobbers the other, both keep their
  STOP. (This is why the config is per-session, not per-cwd — iter-1 review.) ✓
- **Continuing work in the same session after `/do-plan` finished:** hook stays
  active until the session ends — acceptable; the user was in plan mode.
- **Subagent** (`agent_id` non-empty): `exit 0` before the gate, as today.

## Documentation

- `commands/do-plan.md`: Step 2 (write the per-session config file + its path
  prose); Step 6 (note that outside the `/do-plan` session the hook is silent).
- `hooks/check-context-size.sh`: update the header comment describing behavior.
- `README.md` (line 18): clarify the hook is active only within a `/do-plan`
  session.
- `config.example.yaml`: unchanged.
- `CHANGELOG.md`: add an entry.

## Testing

New `skills/shared/tests/test-check-context-size.sh` following the existing test
pattern (`assert_*` helpers), with transcript fixtures carrying a chosen `usage`
(`input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`).

Cases (per-session config; `own` = a `do-plan-config-<cwd>-<session>.json` named
for the session under test):
1. No config for this session + ctx 200k → silent.
2. Config owned by a *different* session + ctx 200k → silent.
3. Own config + ctx 150k → `ctx:150k`.
4. Own config + ctx 260k, threshold 250k → STOP (format-locked: `ctx:250k` + `STOP`).
5. Subagent (`agent_id` set) → silent.
6. Own config + ctx below 150k → silent.
7. Own config + ctx 260k, threshold 300k → milestone but **no** STOP (threshold from config).
8. Malformed own config → milestone still emits, no STOP, no crash (`set -e` safe).

## Assumption & risk

`CLAUDE_CODE_SESSION_ID` is available in slash-command Bash. Confidence is high
(it is a session-level var, unlike the plugin-scoped `CLAUDE_PLUGIN_ROOT`/`DATA`
which are known-empty there). With the glob fallback removed (see above), this
assumption is now **load-bearing**: if the var is empty, `/do-plan` aborts loudly
rather than silently mis-binding. **Task 4 verifies it empirically and is
blocking** — run `/do-plan`, confirm the written file is
`do-plan-config-<cwd>-$CLAUDE_CODE_SESSION_ID.json` (the session id equals the
current transcript stem), and that the env-var branch (not the abort) was taken.
