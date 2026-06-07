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

The per-cwd state file `do-plan-config-<cwd-encoded>.json` is persistent and NOT
session-bound, so a naive "file exists" check would re-enable the hook in ordinary
sessions in the same cwd after the first `/do-plan` ever run there. We therefore
record the session id **inside** the file and require it to match.

State file schema (extended):

```json
{"stop_threshold": 250000, "plan_session_id": "b3545e84-f42e-4799-bcc6-2dc3819b71d5"}
```

### Hook changes (`check-context-size.sh`)

The hook already computes both `CONFIG_FILE` (current line ~68) and `SESSION_KEY`
(current line ~73). Insert the gate after those are defined and before the
milestone logic — **reuse** the existing `SESSION_KEY`, do not recompute it.
Everything below the gate is unchanged.

```bash
# (SESSION_KEY and CONFIG_FILE already defined above — do not duplicate.)
# /do-plan never ran in this cwd → stay silent.
[ -f "$CONFIG_FILE" ] || exit 0
PLAN_SESSION="$(jq -r '.plan_session_id // empty' "$CONFIG_FILE" 2>/dev/null || true)"
# Config belongs to a different (stale) session → stay silent.
[ "$PLAN_SESSION" = "$SESSION_KEY" ] || exit 0
```

Notes:
- Old config files without `plan_session_id` → `PLAN_SESSION` empty → never matches
  → silent. Safe by construction.
- After the gate, `stop_threshold` is always present (written by `/do-plan`); the
  existing `// 999999999` default stays as defense in depth.
- The `agent_id`-non-empty early `exit 0` (subagent guard) stays above the gate.

### `/do-plan` changes (`commands/do-plan.md`, Step 2)

Resolve the session id and write it into the state file:

```bash
SID="${CLAUDE_CODE_SESSION_ID:-}"
# Fallback if the var is empty in slash-command Bash: newest transcript of this project.
[ -n "$SID" ] || SID="$(ls -t "$HOME/.claude/projects/${CWD_ENC}"/*.jsonl 2>/dev/null \
    | head -1 | xargs -r -n1 basename | sed 's/\.jsonl$//')"
[ -n "$SID" ] || { echo "/claude-mesh:do-plan: could not resolve session id" >&2; exit 1; }
printf '{"stop_threshold": %d, "plan_session_id": "%s"}\n' <THRESHOLD> "$SID" \
    > "$PLUGIN_DATA/state/do-plan-config-${CWD_ENC}.json"
```

`CWD_ENC` (`pwd | sed 's|/|-|g'`) already matches the project's transcript dir
name for ordinary paths, so the fallback glob targets the right directory.

### What stays unchanged

`START_K`/`INTERVAL_K` (150/25) and `CC_CONTEXT_*` overrides · milestone message
format · STOP message format · compaction-reset logic · `config.yaml` (no new
fields) · `do_plan_default_stop_tokens >= 150000` validation.

## Edge cases

- **continue-plan-fresh-session:** new session B → `/do-plan` rewrites the config
  with `plan_session_id=B` → hook active in B. ✓
- **Stale persistent config from a prior `/do-plan`:** session mismatch → silent.
  This is exactly the fix for the reported problem. ✓
- **Continuing work in the same session after `/do-plan` finished:** hook stays
  active until the session ends — acceptable; the user was in plan mode.
- **Subagent** (`agent_id` non-empty): `exit 0` before the gate, as today.

## Documentation

- `commands/do-plan.md`: Step 2 (write `plan_session_id`); Step 6 (note that
  outside the `/do-plan` session the hook is silent).
- `hooks/check-context-size.sh`: update the header comment describing behavior.
- `README.md` (line 18): clarify the hook is active only within a `/do-plan`
  session.
- `config.example.yaml`: unchanged.
- `CHANGELOG.md`: add an entry.

## Testing

New `skills/shared/tests/test-check-context-size.sh` following the existing test
pattern (`assert_*` helpers), with transcript fixtures carrying a chosen `usage`
(`input_tokens` + `cache_creation_input_tokens` + `cache_read_input_tokens`).

Cases:
1. No `do-plan-config` + ctx 200k → silent.
2. Config with a different `plan_session_id` + ctx 200k → silent.
3. Config with matching `plan_session_id` + ctx 150k → `ctx:150k`.
4. Matching session + ctx 260k, threshold 250k → STOP message.
5. Subagent (`agent_id` set) → silent.
6. Matching session + ctx below 150k → silent.
7. Legacy config without `plan_session_id` → silent.

## Assumption & risk

`CLAUDE_CODE_SESSION_ID` is available in slash-command Bash. Confidence is high
(it is a session-level var, unlike the plugin-scoped `CLAUDE_PLUGIN_ROOT`/`DATA`
which are known-empty there). The newest-transcript fallback covers the risk;
verify empirically during implementation (run `/do-plan`, confirm the written
`plan_session_id` equals the current transcript stem).
