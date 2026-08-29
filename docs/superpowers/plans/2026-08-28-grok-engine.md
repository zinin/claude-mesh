# Grok Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `grok` a first-class reviewer engine in claude-mesh, equal to `codex` and `gemini`, with a model catalog of its own.

**Architecture:** Grok is built the way codex and gemini are built — a gated config section, an exec skill, a code-review skill, two wrapper agents, a row in the environment probe, a verdict in the delegation guard. Two things differ. The stream format is `--output-format streaming-messages-json`, which grok emits in the same wire format `claude -p` produces, so `shared/extract-result.py`, the shared stream-json report renderer, and the `ext-claude` branch of `verify-delegation.sh` all serve grok unchanged. And the model-catalog validator moves into a shared helper that `claude:` and `grok:` both call, instead of becoming a third copy of guards that would drift.

**Tech Stack:** bash 4.2+, `jq`, `yq` (either flavor), `python3`, GNU coreutils/findutils, the `grok` CLI (1.0.5+), Claude Code plugin markdown (skills, agents, commands).

**Spec:** `docs/superpowers/specs/2026-08-28-grok-engine-design.md` — read it before Task 1. It carries the measured facts about the CLI that every task below assumes.

## Global Constraints

- **Never edit `config.yaml`.** It is user-owned; validators report, agents never fix. Same rule for every task here.
- **Claude catalog messages are frozen.** After Task 1, every `claude.models` / `claude_models` error must be byte-identical to what it was before. Tests assert their text.
- **grok model charset:** `[A-Za-z0-9._-]`, anchored to a leading alphanumeric (`GROK_IDENT_RE`). Never widen it: the value becomes a path component and a `watch-runs.sh` roster entry, whose own pattern rejects `:` and `@`.
- **claude model charset stays `[A-Za-z0-9._:@-]`** (`IDENT_RE`). Do not narrow it.
- **Known reasoning efforts:** `low | medium | high | xhigh | max` — FIVE, verified against `grok 1.0.5` (`grok -p x --reasoning-effort=__bogus__` answers `use one of: low, medium, high, xhigh, max`). Unknown values WARN and pass through — the CLI validates. Never make this an enum, and never write a test asserting an unknown value is REJECTED; assert only that it warns and passes. The list goes stale on its own: `codex.reasoning_level` (`config-loader.sh:384`) still lacks `max` while the user's `config.yaml` sets exactly that, so every loader run on this machine already prints a spurious WARN.
- **Never hardcode a grok model.** When neither caller nor catalog names one, omit `-m` and let `~/.grok/config.toml` decide.
- **Watchdog budgets:** `HARD_ZERO_TIMEOUT=600`, `GLOBAL_TIMEOUT=3600`, `MAX_RETRIES=2`, `timeout 1800` per attempt. Supervised runs launch as **background** Bash calls, never foreground.
- **Review floor:** `MIN_REVIEW_BYTES=400` non-space bytes, unchanged.
- **Optional bash arrays expand as `${arr[@]+"${arr[@]}"}`.** Under `set -u`, bash 4.2 and
  4.3 treat `"${arr[@]}"` on an empty array as an unbound variable and abort — and this
  project supports bash 4.2. Do not "simplify" that form back.
- **Engine name is `grok`;** reviewer names are `grok:<model>`; run dirs are `runs/grok/<model>/<timestamp>-<task>/`.
- **Commit style:** conventional commits (`feat(config): …`, `test(verify): …`, `docs: …`), one commit per task step that says "Commit".
- **Run the full suite before any commit that touches `skills/shared/`:** `bash skills/shared/tests/test-config-loader.sh` and the sibling suites named per task. The whole directory takes ~3 minutes.

---

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `skills/grok-exec/SKILL.md` | Run a prompt through the grok CLI; own the run dir, stream, extraction, report, watchdog |
| `agents/grok-executor.md` | Thin wrapper agent that must call `grok-exec`; requires `MODEL` |
| `skills/grok-code-review/SKILL.md` | Resolve the diff, render the review prompt, delegate to `grok-exec` |
| `agents/grok-code-reviewer.md` | Thin wrapper agent that must call `grok-code-review`; requires `MODEL` |
| `skills/shared/stream-json-report.sh` | Anthropic stream-json → markdown report (moved out of `ext-claude-exec/`, now shared by two engines) |
| `skills/shared/tests/test-grok-exec-smoke.sh` | Opt-in live smoke test of the grok invocation (`GROK_SMOKE=1`) |
| `skills/shared/tests/fixtures/valid-grok.yaml` and 7 siblings (8 files; the design lists 11 cases — the remaining 3 are written inline in the test, which reads better beside the assertion. Keep these three numbers in agreement) | Config fixtures for the new validator |

**Modified:**

| Path | Change |
|---|---|
| `skills/shared/config-loader.sh` | `validate_model_catalog` helper; `validate_grok` / `validate_grok_catalog`; `has_grok`; `list-grok-models`; `get-grok`; defaults gating; usage line |
| `skills/shared/verify-delegation.sh` | `grok` path resolver, `grok` in the `ext-claude` classification branch, engine-specific message texts |
| `skills/shared/watch-runs.sh` | Comment listing which exec skills pin `HARD_ZERO_TIMEOUT=600` |
| `skills/shared/preflight-env.sh` | Optional command-probe argument for `cli_row`; the `grok` row; `grok:<model>` in the summary |
| `skills/ext-claude-exec/SKILL.md` | Renderer path now points at `shared/stream-json-report.sh` |
| `commands/mesh-review.md` | Gates, Q1 option, grok-model selection step, dispatch pairs, roster, guard specs |
| `skills/mesh-design-review/SKILL.md` | The same four points at its own step numbers, plus `defaults.design_review.grok_models` |
| `commands/code-review-fresh-session.md`, `commands/design-review-fresh-session.md` | grok listed among the engines |
| `config.example.yaml`, `README.md`, `CHANGELOG.md` | Documentation |
| `skills/shared/tests/test-config-loader.sh`, `test-verify-delegation.sh`, `test-watch-runs.sh`, `test-preflight-env.sh` | New cases |

---

### Task 1: Shared model-catalog validator

✅ Done — see commit(s): `91edfb8`

---

### Task 2: The `grok:` config section

✅ Done — see commit(s): `571d5f5`

---

### Task 3: `grok` in the defaults presets

✅ Done — see commit(s): `b05833b`, `604bc53`

---

### Task 4: Config example and schema documentation

✅ Done — see commit(s): `2ee8623`

---

### Task 5: Move the stream-json report renderer into `shared/`

✅ Done — see commit(s): `85f0463`, `3c60bec`

---

### Task 6: The `grok-exec` skill and its executor agent

✅ Done — see commit(s): `51abfba`, `0571072`

---

### Task 7: The `grok-code-review` skill and reviewer agent

✅ Done — see commit(s): `9d6f8e2`, `7014162`

---

### Task 8: `grok` in the delegation guard

**Files:**
- Modify: `skills/shared/verify-delegation.sh` (header comment, usage, path resolver, classification branch, two message texts)
- Test: `skills/shared/tests/test-verify-delegation.sh` (new grok section)

**Interfaces:**
- Consumes: run directories from Task 6.
- Produces: `verify-delegation.sh grok <model> <since-epoch> [data-dir]` — verdicts REAL=0, STALLED=2, FLIP=3, BROKEN=4, DEGRADED=5, KILLED=6, identical in meaning to the ext-claude ones.

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-verify-delegation.sh`, before the summary block:

```bash
# === grok: the engine shares ext-claude's classification, because it shares its stream format ===
# grok --output-format streaming-messages-json emits the Claude Code wire format verbatim, so
# every signal the ext-claude branch reads — is_error, num_turns, permission_denials — is on
# disk here too. These tests exist to keep the two wired together: a future edit that splits
# the branch must keep grok scoring the same way.
echo "=== Test: grok FLIP (no run dir) ==="
TDIR=$(mktemp -d)
mkdir -p "$TDIR/runs/grok/grok-4.6"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok REAL (num_turns 12, real review) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-review)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12}' > "$rd/raw.jsonl"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok BROKEN (num_turns 1 — answered without reading code) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-lazy)
mk_output "$rd/output.txt" 'Looks fine to me.'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1}' > "$rd/raw.jsonl"
run grok grok-4.6 1 "$TDIR"
assert_eq "verdict BROKEN" "BROKEN" "$VERDICT"
assert_eq "exit 4" "4" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok STALLED (torn stream, no result event) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.5" 2026-08-28-11-00-00-1000-torn)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}' > "$rd/raw.jsonl"
run grok grok-4.5 1 "$TDIR"
assert_eq "verdict STALLED" "STALLED" "$VERDICT"
assert_eq "exit 2" "2" "$RC"
rm -rf "$TDIR"

# Design §5 promises grok coverage for REAL, STALLED, BROKEN, FLIP, DEGRADED **and KILLED**;
# KILLED and the engine-specific STALLED floor note are the two the first draft omitted.
echo "=== Test: grok KILLED (watchdog cleanup 143, no watchdog.exit) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-30-00-1000-killed)
printf '%s\n' '{"ts":"2026-08-28T11:40:00+0300","event":"cleanup","attempt":1,"details":{"exit_code":143}}' > "$rd/watchdog.log"
: > "$rd/output.txt"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict KILLED" "KILLED" "$VERDICT"
assert_eq "exit 6" "6" "$RC"
rm -rf "$TDIR"

echo "=== Test: grok STALLED floor note is grok's, not ext-claude's archive number ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-45-00-1000-short)
mk_output "$rd/output.txt" 'ok'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":4}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
# "the shortest genuine review in the archive is 460" is a measured ext-claude fact; quoting it
# for grok would cite evidence that does not exist for this engine.
assert_no_match "no ext-claude archive number" "archive" "$REASON"
assert_match "names the floor itself" "400 non-space" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok DEGRADED (denials on an otherwise real review) ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/grok/grok-4.6" 2026-08-28-11-00-00-1000-denied)
mk_output "$rd/output.txt" '### Findings'
ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"permission_denials":[{"tool_name":"Read"},{"tool_name":"Bash"}]}' > "$rd/raw.jsonl"
run_full grok grok-4.6 1 "$TDIR"
assert_eq "verdict DEGRADED" "DEGRADED" "$VERDICT"
assert_eq "exit 5" "5" "$RC"
assert_eq "counts both denials" "2" "$(reason_count)"
# The ext-claude remedy prescribes a flag grok already passes — saying it here would send the
# reader after a setting that is not the cause.
assert_no_match "does not prescribe the ext-claude remedy" "the ext-claude run needs" "$REASON"
# assert_no_match alone would also pass on an EMPTY or generic reason, so pin the grok text too:
# the branch must say something true about grok, not merely avoid saying something false.
assert_match "names the grok remedy" "grok-exec already passes" "$REASON"
rm -rf "$TDIR"

echo "=== Test: grok requires a model argument ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/grok"
run grok - 1 "$TDIR"
assert_eq "exit 1 (usage error, no verdict)" "1" "$RC"
assert_eq "no verdict printed" "" "$VERDICT"
rm -rf "$TDIR"
```

- [ ] **Step 2: Run to watch them fail**

Run: `bash skills/shared/tests/test-verify-delegation.sh 2>&1 | grep -B1 -A3 'grok'`
Expected: every grok case fails — the script exits 1 with `unknown engine 'grok'`.

- [ ] **Step 3: Implement the path resolver**

In `skills/shared/verify-delegation.sh`, replace the engine `case` (around line 123):

```bash
case "$ENGINE" in
    ext-claude) BASE="$DATA_DIR/runs/ext-claude/$MODEL" ;;
    # A model is MANDATORY for grok, and '-' is not one: the run dirs live under
    # runs/grok/<model>/, so a missing argument would resolve to runs/grok/- and report FLIP
    # about a directory nothing ever writes. Usage error, exit 1, no verdict — the shape both
    # orchestrators read as "fix the call", not as a verdict about the reviewer.
    grok)
        case "$MODEL" in
            ''|'-') echo "verify-delegation: engine grok requires a model argument (e.g. grok-4.6), got '${MODEL:-}'" >&2; exit 1 ;;
        esac
        BASE="$DATA_DIR/runs/grok/$MODEL" ;;
    codex)      BASE="$DATA_DIR/runs/codex" ;;
    gemini)     BASE="$DATA_DIR/runs/gemini" ;;
    *) echo "verify-delegation: unknown engine '$ENGINE'" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: Share the classification branch and split the two engine-specific texts**

Change the branch head from `ext-claude)` to:

```bash
    ext-claude|grok)
        # Two more strings in this branch are ext-claude-specific besides the archive floor and
        # the DEGRADED remedy: sweep the whole branch for engine-specific wording rather than
        # patching the two the design names, and either move each into `case "$ENGINE"` or
        # rephrase it so it is true for both engines.
```

Inside it, the two message texts that are true only of ext-claude become engine-aware. Above
the `OUT_BYTES` check, add:

```bash
        # The floor is one number for both engines; the sentence that explains it is not.
        # ext-claude's cites its own archive (336 runs); grok has no archive yet, and quoting
        # one would be a measurement nobody made.
        case "$ENGINE" in
            grok) FLOOR_NOTE="the floor is $MIN_REVIEW_BYTES non-space bytes" ;;
            *)    FLOOR_NOTE="the shortest genuine review in the archive is 460" ;;
        esac
```

and use it in the message:

```bash
            fail STALLED "num_turns=$NT but output.txt holds only $OUT_BYTES non-space bytes — the run worked and then delivered a notice, not a review ($FLOOR_NOTE)" 2
```

Then, in the `permission_denials` branch, replace the single remedy sentence with a per-engine one:

```bash
            case "$ENGINE" in
                grok) DENIAL_REMEDY="grok-exec already passes --permission-mode bypassPermissions, so this is not the missing-flag case: the CLI refused for a reason of its own (a sandbox profile, or a deny rule in ~/.grok). Keep the findings; do NOT re-dispatch, and check the CLI's own permission configuration" ;;
                *)    DENIAL_REMEDY="Keep the findings; do NOT re-dispatch, an identical invocation is refused identically. The remedy is the user's, not an agent's: the ext-claude run needs --permission-mode bypassPermissions, and an installed plugin only picks that up through a release" ;;
            esac
            emit DEGRADED "num_turns=$NT but the CLI refused $DENIED tool call(s) ($BREAKDOWN) — the reviewer was confined to its working directory and reviewed on incomplete context. $DENIAL_REMEDY" 5
```

- [ ] **Step 5: Update the header comment and the usage line**

At the top of the file, the engine list appears twice — in the prose block and in the usage
string. Make both read `ext-claude | codex | gemini | grok`, and extend the model line to:

```bash
#     model       for ext-claude: "<provider>/<short>" (e.g. zai/glm); for grok: the model id
#                 (e.g. grok-4.6); "-" for codex/gemini
```

Also update the `usage:` echo in the argument check:

```bash
    echo "usage: verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]" >&2
```

stays as it is — only the comment block enumerates engines.

- [ ] **Step 6: Run the tests**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-verify-delegation.sh > /tmp/test-verify-delegation.txt 2>&1; RC=$?
tail -3 /tmp/test-verify-delegation.txt; echo "rc=$RC"
```

Expected: `0 failed`, including every pre-existing ext-claude, codex and gemini case.

- [ ] **Step 7: Commit**

```bash
git add skills/shared/verify-delegation.sh skills/shared/tests/test-verify-delegation.sh
git commit -m "feat(verify): score grok runs through the shared stream-json branch"
```

---

### Task 9: `grok` in the run watcher

`watch-runs.sh` needs no logic change — its roster pattern already accepts `grok/grok-4.6`,
and freshness already reads `raw.jsonl`, `attempt-*/raw.jsonl` and `watchdog.log`. This task
proves that with tests and fixes the one comment that would now be wrong.

**Files:**
- Modify: `skills/shared/watch-runs.sh` (the `HARD_ZERO_TIMEOUT` comment, ~line 143)
- Test: `skills/shared/tests/test-watch-runs.sh` (new cases)

**Interfaces:**
- Consumes: run directories from Task 6.
- Produces: nothing new — `grok/<model>` is simply a valid roster entry.

- [ ] **Step 1: Write the tests**

Append to `skills/shared/tests/test-watch-runs.sh`, before its summary block:

```bash
echo ""
echo "Test 40: a grok roster entry follows runs/grok/<model>/"
TDIR="$(mktemp -d)"
A="$(mk_run "$TDIR" grok/grok-4.6)"
wd_log "$A" 0; printf 'findings\n' > "$A/output.txt"
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" grok/grok-4.6
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_match "grok row is DONE" "DONE" "$(row grok/grok-4.6)"
rm -rf "$TDIR"

echo ""
echo "Test 41: two grok models are watched independently"
TDIR="$(mktemp -d)"
A="$(mk_run "$TDIR" grok/grok-4.6)"
wd_log "$A" 0; printf 'findings\n' > "$A/output.txt"
mk_run "$TDIR" grok/grok-4.5 >/dev/null
run --since "$SINCE_OK" --stall-sec 600 --once --data-dir "$TDIR" grok/grok-4.6 grok/grok-4.5
assert_match "4.6 is DONE" "DONE" "$(row grok/grok-4.6)"
assert_match "4.5 is still RUN" "RUN" "$(row grok/grok-4.5)"
rm -rf "$TDIR"
```

- [ ] **Step 2: Run them**

`test-watch-runs.sh` already contains tests numbered up to **39**, so 31/32 would be duplicates
— the numbers above are 40/41. Verify no number is used twice before running:

```bash
grep -o 'Test [0-9]\+' skills/shared/tests/test-watch-runs.sh | sort -V | uniq -d   # expect empty
bash skills/shared/tests/test-watch-runs.sh > /tmp/watch.txt 2>&1; RC=$?
grep -A4 'Test 40\|Test 41' /tmp/watch.txt; echo "rc=$RC"
```
Expected: they PASS immediately — the script is already engine-agnostic. If they fail, the
roster pattern or the freshness list regressed; fix that before continuing.

- [ ] **Step 3: Correct the stale comment**

The message at `watch-runs.sh:143` names only two exec skills as the owners of the 600-second
floor. Update it:

```bash
        echo "watch-runs: stall threshold $STALL_SEC raised to $STALL_FLOOR — codex-exec, gemini-exec and grok-exec hardcode HARD_ZERO_TIMEOUT=600, so a lower threshold would call a live run silent before its own watchdog acts" >&2
```

Check whether a test pins that string:

```bash
grep -n 'hardcode HARD_ZERO_TIMEOUT' skills/shared/tests/test-watch-runs.sh skills/shared/watch-runs.sh
```

If a test asserts the old wording, update the assertion in the same commit.

- [ ] **Step 4: Run the suite**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-watch-runs.sh > /tmp/test-watch-runs.txt 2>&1; RC=$?
tail -3 /tmp/test-watch-runs.txt; echo "rc=$RC"
```

Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git commit -m "test(watch): pin grok roster entries; name grok-exec in the stall floor note"
```

---

### Task 10: `grok` in the environment probe

**Files:**
- Modify: `skills/shared/preflight-env.sh` (`cli_row` gains an optional command probe; the `grok` gate, row and summary entries)
- Test: `skills/shared/tests/test-preflight-env.sh` (new grok cases)

**Interfaces:**
- Consumes: `get-flag has_grok`, `get-grok`, `list-grok-models` (Task 2).
- Produces: a `grok` row in the report, and `grok:<model>` entries on the `SUMMARY available:` line — spelled exactly as the two orchestrators spell them, so a reading session needs no mapping.

- [ ] **Step 0: Update the pinned row order — the suite fails without it**

`skills/shared/tests/test-preflight-env.sh:826-828` pins the report's row order as one literal
string, and the comment above it says why: it "catches a block appended in the wrong place".
The `grok` row prints **unconditionally** (as `grok MISSING` when there is no section, exactly
like codex and gemini), so this assertion goes red the moment Step 5 lands, and nothing else in
this task touches it. Insert `grok` between `gemini` and `provider:zai`, matching where Step 5
puts the row:

```bash
assert_eq "row order is the documented one" \
  "plugin yq jq config builtin-claude claude-models codex gemini grok provider:zai provider:ollama git-remote gh glab clipboard bash-timeout " \
  "$ORDER"
```

If Step 6 still reports a failure here, the row was added in the wrong place — fix the row's
position, not this string.

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-preflight-env.sh`, in the CLI-row section beside the codex
and gemini scenarios:

```bash
# --- grok ---------------------------------------------------------------------------------
# Unlike codex and gemini, grok's reachability is probed with the CLI itself: `grok models`
# answers only when the machine has network AND a live login, and the subscription path never
# touches the public api.x.ai an HTTP probe would have to guess at.
mkdir -p "$WORK/cli-grok"
cat > "$WORK/cli-grok/grok" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  models) [ "${GROK_SHIM_FAIL:-0}" = 1 ] && { echo "not logged in" >&2; exit 1; }
          printf 'You are logged in with grok.com.\n\nDefault model: grok-4.6\n' ;;
  *)      exit 0 ;;
esac
SH
chmod +x "$WORK/cli-grok/grok"

# No grok: section -> MISSING, and the reason says the UI will not offer it.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/cli-grok:$PATH"
assert_eq   "no grok section -> MISSING"    MISSING "$(field grok "$OUT")"
assert_match "and says why"                 "no grok: section" "$OUT"

# Section present, CLI present, `grok models` answers -> OK, and the catalog reaches the summary.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH"
assert_eq   "grok CLI + login -> OK"        OK "$(field grok "$OUT")"
assert_match "summary names each grok model" "grok:grok-4.6" "$OUT"
assert_match "…including the second one"     "grok:grok-4.5" "$OUT"

# The CLI is there but not logged in -> NO-NETWORK, and the hint names the fix.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH" GROK_SHIM_FAIL=1
assert_eq   "grok models fails -> NO-NETWORK" NO-NETWORK "$(field grok "$OUT")"
assert_match "…and suggests logging in"       "grok login" "$OUT"

# Section present, binary absent -> MISSING (the section gate passes, the CLI gate does not).
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli"
assert_eq   "grok binary absent -> MISSING"  MISSING "$(field grok "$OUT")"

# A malformed grok: section is INVALID before any CLI or network claim — same order as codex.
run_probe broken-grok-valid-codex.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq   "malformed grok section -> INVALID" INVALID "$(field grok "$OUT")"
assert_match "…with the validator's own reason" "grok.models" "$OUT"

# PREFLIGHT_SKIP_NETWORK must skip the command probe too, not run it silently.
run_probe valid-grok.yaml PREFLIGHT_SKIP_NETWORK=1 PATH="$WORK/cli-grok:$SHIM:$PATH"
assert_eq   "skip-network -> UNKNOWN"        UNKNOWN "$(field grok "$OUT")"
assert_match "…named as the flag's doing"    "skipped by PREFLIGHT_SKIP_NETWORK" "$OUT"
```

Add `grok` to the farm of deleted binaries so the "binary absent" case is real:

```bash
mkfarm "$WORK/nocli" codex gemini grok
```

- [ ] **Step 2: Run to watch them fail**

Run: `bash skills/shared/tests/test-preflight-env.sh 2>&1 | grep -c FAIL`
Expected: a non-zero count — there is no `grok` row at all yet, so `field grok` returns empty.

- [ ] **Step 3: Teach `cli_row` an optional command probe**

In `skills/shared/preflight-env.sh`, extend the signature comment and add the branch just
before the existing `if [ "$SKIP_NET" = 0 ] && [ "$HAVE_CURL" = 1 ]` announcement:

```bash
cli_row() {             # $1 = name, $2 = binary, $3 = probe url, $4 = has_section flag, $5 = probe command (optional)
                        # $5 is deliberately UNQUOTED at the call below: it must split into argv
                        # ("grok models" -> two words). That makes word splitting part of this
                        # function's public contract, so a caller may never pass a value
                        # carrying spaces-in-one-argument, and glob characters must be disabled
                        # around the expansion (`set -f` / `set +f`) or a probe like `foo *`
                        # would expand against the cwd.
```

```bash
    # An OPTIONAL command probe replaces the HTTP one for a CLI whose reachability an HTTP
    # request cannot answer. grok is the case: on a grok.com subscription the traffic goes
    # through a relay, not through the public api.x.ai, so a curl there would report on an
    # endpoint this CLI never calls — while `grok models` answers only with network AND a live
    # login, and prints nothing secret. Same degrade-toward-UNKNOWN discipline as probe_http:
    # the flag skips it, and only a clean exit is allowed to mean OK.
    if [ -n "${5:-}" ]; then
        if [ "$SKIP_NET" = 1 ]; then
            CLI_STATUS="UNKNOWN"
            row "$1" UNKNOWN "CLI present, skipped by PREFLIGHT_SKIP_NETWORK"
        elif ! command -v timeout >/dev/null 2>&1; then
            CLI_STATUS="UNKNOWN"
            row "$1" UNKNOWN "CLI present, no timeout(1) — \`$5\` not run (brew install coreutils)"
        else
            echo "probing $1 (\`$5\`)…" >&2
            set -f                                   # see the contract note on $5 above
            timeout "$HTTP_TIMEOUT" $5 >/dev/null 2>&1; PROBE_RC=$?
            set +f                                   # restored on BOTH paths, before any branch
            if [ "$PROBE_RC" -eq 0 ]; then
                CLI_STATUS="OK"
                row "$1" OK "CLI present, \`$5\` answered (checks login as well as network)"
            else
                CLI_STATUS="NO-NETWORK"
                row "$1" NO-NETWORK "CLI present, \`$5\` failed or timed out after ${HTTP_TIMEOUT}s — no network, or not logged in (\`$2 login\`)"
            fi
        fi
        return 0
    fi
```

`$5` is deliberately unquoted: it is a command line, and word splitting is what turns
`grok models` into two argv entries.

- [ ] **Step 4: Read the grok gate and catalog**

Beside the `HAS_CODEX` / `HAS_GEMINI` reads (~line 308):

```bash
    HAS_GROK="$(bash "$LOADER" get-flag has_grok 2>/dev/null)" || HAS_GROK=0
    # The catalog feeds the SUMMARY line, which must spell reviewer names exactly as the
    # orchestrators do: grok:grok-4.6, like claude:opus. A failed read leaves it empty and the
    # row below reports the section as INVALID through the typed getter.
    GROK_MODELS="$(bash "$LOADER" list-grok-models 2>/dev/null)" || GROK_MODELS=""
```

Declare `GROK_MODELS=""` beside the existing `CLAUDE_MODELS=""` initialisation (~line 280) so
the no-config branch leaves it defined.

**And declare `HAS_GROK=0` at line 186, beside `HAS_CODEX=0` / `HAS_GEMINI=0` (:184-185).**
This is not optional tidiness — it is the difference between a working probe and a broken one.
Those two are initialised THERE, outside the `if [ "$CONFIG_STATUS" = "OK" ]` branch that
begins at :285, precisely because `cli_row … "$HAS_CODEX"` at :421 runs unconditionally.
The reads added above live INSIDE that branch, so on any path where the config is not usable —
`run_probe none`, no `config.yaml`, no `yq`/`jq`, an invalid config — `preflight-env.sh:19`'s
`set -u` aborts on `HAS_GROK: unbound variable`, killing the probe before git-remote,
bash-timeout and SUMMARY. That breaks scenarios which have nothing to do with grok, and it
turns the suite's `every verdict exits 0` backstop red across the board.

Verify both, since a missing initialisation is invisible on the happy path:

```bash
grep -n '^HAS_GROK=0' skills/shared/preflight-env.sh          # must print one line, ~186
PREFLIGHT_SKIP_NETWORK=1 bash skills/shared/preflight-env.sh >/dev/null 2>&1; echo "rc=$?"
```

- [ ] **Step 5: Add the row and the summary entries**

Beside the codex and gemini `cli_row` calls:

```bash
cli_row codex  "codex"  "https://api.openai.com/v1/models"           "$HAS_CODEX";  CODEX_STATUS="$CLI_STATUS"
cli_row gemini "gemini" "https://generativelanguage.googleapis.com/" "$HAS_GEMINI"; GEMINI_STATUS="$CLI_STATUS"
# The URL argument is unused when a command probe is given; pass the CLI's own docs host so the
# row's shape stays uniform and a future reader can see what an HTTP fallback would target.
cli_row grok   "grok"   "https://api.x.ai/v1/models"                 "$HAS_GROK" "grok models"; GROK_STATUS="$CLI_STATUS"
```

And in the summary block, after the gemini line:

```bash
if [ "$GROK_STATUS" = "OK" ]; then
    # One entry per catalog model, exactly as claude expands over claude.models. The bare
    # `grok` fallback cannot normally happen — the validator requires a non-empty catalog
    # whenever the section exists — but a reader is better served by a name than by silence
    # if some future config shape reaches here with an empty list.
    if [ -n "$GROK_MODELS" ]; then
        while IFS= read -r GM; do
            [ -n "$GM" ] && add_avail "grok:$GM"
        done <<< "$GROK_MODELS"
    else
        # Unreachable through the validator (a section without a non-empty catalog does not
        # validate), kept only so a future config shape cannot reach the summary silently.
        add_avail grok
    fi
else
    add_unavail "grok ($GROK_STATUS)"
fi
```

**And expand grok on the `SUMMARY defaults` line too — otherwise the probe starts lying about
`default` mode.** `preflight-env.sh:794-802` expands only `claude` into `claude:<model>`; every
other `builtin` name passes through bare. After Step 5, `SUMMARY available` carries
`grok:grok-4.6` while `SUMMARY defaults code_review` carries a bare `grok`, and the invariant
stated in the comment above that block — "every name on a defaults line must appear in
SUMMARY available" — breaks. It is checked mechanically by `defaults_not_available()`
(`test-preflight-env.sh:625-643`), which compares WHOLE entries and hard-codes exactly one
exception, for `claude`. Expand `grok` over `.grok_models` in that jq, the same way `claude` is
expanded over `.claude_models`; the validator guarantees a non-empty `grok_models` whenever
`grok` is in `builtin`, so the expansion is always defined. Do NOT instead add a second
hard-coded exception to the test helper: that would leave the product printing two different
names for one reviewer, and a reader deciding whether `default` is safe would have to know the
exception to get the right answer.

- [ ] **Step 6: Run the tests**

Run — keep the rc; `| tail` would return **tail's** status and a failing suite would read as success:

```bash
bash skills/shared/tests/test-preflight-env.sh > /tmp/test-preflight-env.txt 2>&1; RC=$?
tail -3 /tmp/test-preflight-env.txt; echo "rc=$RC"
```

Expected: `0 failed`.

- [ ] **Step 7: See the real probe**

Run: `bash skills/shared/preflight-env.sh 2>&1 | grep -E '^grok|SUMMARY'`
Expected on this machine: `grok  OK  CLI present, \`grok models\` answered …` once a `grok:`
section exists in the live config, and `grok:grok-4.6` on the available line. With no section
yet: `grok MISSING no grok: section in config — the selection UI will not offer it`.

- [ ] **Step 8: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh
git commit -m "feat(preflight): probe grok with its own CLI, report grok:<model>"
```

---

### Task 11: `/mesh-review` integration

**Files:**
- Modify: `commands/mesh-review.md` — frontmatter description, Step 0 (`default` mode), Step 1 (gates), Step 2 (Q1), a new Step 2.45, Step 2.5, Step 5a, Step 6.0, Step 6.1

**Interfaces:**
- Consumes: `has_grok`, `list-grok-models`, `get-defaults …grok_models` (Tasks 2-3); the `grok-code-reviewer` agent (Task 7); `verify-delegation.sh grok <model>` (Task 8).
- Produces: reviewer names `grok:<model>`, dispatch pairs `grok:<model>`, roster entries `grok/<model>`.

- [ ] **Step 1: Widen the gates in Step 1**

After the `HAS_GEMINI` read in the Step 1 fence, add — with the same rc-awareness the claude
catalog read has, because `list-grok-models` validates the section:

```bash
HAS_GROK=$("$LOADER" get-flag has_grok)
GM_ERR=$(mktemp)
# WARN, do not exit. A broken grok: section must not stop a codex-only review — that is the
# `ultra` incident (config-loader.sh:733-740) in a new costume, and the reason has_codex is a
# bare probe. Degrade grok alone: report it, drop the flag, let everything else run.
if ! GROK_MODELS=$("$LOADER" list-grok-models 2>"$GM_ERR"); then
    echo "ВНИМАНИЕ: секция grok: не валидируется — grok-ревьюеры отключены на этот запуск:" >&2
    cat "$GM_ERR" >&2
    HAS_GROK=0; GROK_MODELS=""
fi
rm -f "$GM_ERR"
echo "HAS_GROK=$HAS_GROK"
echo "GROK_MODELS=[$(echo "$GROK_MODELS" | tr '\n' ' ')]"
```

- [ ] **Step 2: Restructure Q1 — it cannot simply gain a fifth option**

`AskUserQuestion` takes at most four options and Q1 (`commands/mesh-review.md:109-121`) already
has four. Adding grok as a fifth is not a thing the tool permits, so Q1 changes shape, per
design §3:

1. Replace the separate `codex` and `gemini` entries with ONE option,
   `внешние CLI (codex / gemini / grok) ★ default`, shown when **any** of `HAS_CODEX`,
   `HAS_GEMINI`, `HAS_GROK` is `1`; mark it ★ when any of the three appears in
   `defaults.code_review.builtin`. Q1 is then three options and stays three however many CLI
   engines exist later.
2. Add a new engine-selection page, reached only when that option is chosen: a multiSelect over
   the CONFIGURED engines (`codex`, `gemini`, `grok` — each shown only when its flag is `1`),
   using the same `chunk of 4` pagination as Step 2.4, with ★ from `builtin`.
3. **Skip that page and select the engine implicitly when exactly one is configured.** Without
   this, every single-engine user pays an extra screen for a problem they do not have.
4. Selecting no engine on that page is not an error — it means no CLI reviewer runs, the same
   rule the model pages already follow.

Everything downstream keys off the ENGINE set this page produces, exactly as it keyed off the
old per-engine Q1 answers; no other step changes shape.

- [ ] **Step 2b: Add the Q1 option**

In Step 2's option list, after the gemini line:

```
  - "grok CLI ★ default"                                       — show only if HAS_GROK=1; ★ if "grok" in defaults.code_review.builtin
```

- [ ] **Step 3: Add Step 2.45 — grok-model selection**

Insert a new step between Step 2.4 and Step 2.5:

````markdown
## Step 2.45: Grok-model selection

Runs ONLY when Q1 selected `grok`. There is no `HAS_GROK_MODELS` gate: a `grok:` section
without a non-empty catalog does not validate, so `HAS_GROK=1` already guarantees
`GROK_MODELS` is non-empty.

- `grok` NOT selected in Q1 → skip this step; **bind `SELECTED_GROK_MODELS` to the empty
  list** and run no grok reviewer at all.

Read the recommended set from the preset — rc-aware, and never through a pipe, for the same
reason Step 2.4 spells out (this Bash call runs in a fresh shell; `$LOADER` must be
re-resolved):

```bash
LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
[ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
GD_ERR=$(mktemp)
CR_DEFAULTS=$("$LOADER" get-defaults code_review 2>"$GD_ERR") \
    || { echo "config.yaml невалиден (defaults.code_review):" >&2; cat "$GD_ERR" >&2; rm -f "$GD_ERR"; exit 1; }
rm -f "$GD_ERR"
GROK_DEFAULT_IDS=$(echo "$CR_DEFAULTS" | jq -r '.grok_models[]?')
echo "GROK_DEFAULT_IDS=[$(echo "$GROK_DEFAULT_IDS" | tr '\n' ' ')]"   # empty = no ★ markers below
```

For each chunk of 4 entries from `GROK_MODELS` (in config order) — same pagination mechanics
as Step 3, and the same reason for the ★ marker (AskUserQuestion has no `preSelected` API):

AskUserQuestion (multiSelect, max 4):
```
header: "Grok"
question: "На каких grok-моделях запустить ревью? (страница N/M, ★ = recommended)"
options:
  For each model in the chunk:
    label:       "<model>"                     if NOT in GROK_DEFAULT_IDS
                 "★ <model> (recommended)"     if in GROK_DEFAULT_IDS
    description: "отдельный независимый ревьюер на этой модели"
```

Collect the selections into `SELECTED_GROK_MODELS`.

<!-- SYNC: the "no fallback" rule for grok is ONE rule living in four places — this paragraph,
     the preset branch of Step 0/5.1, the same paragraph in the sibling orchestrator, and the
     design's §1 note that grok_models is required whenever grok is in builtin. It is the exact
     mirror of the four-place SYNC marker the claude fallback rule already carries. Change all
     four or none: a copy that still promises a fallback would have the orchestrator dispatch a
     reviewer the agent then refuses to start for want of a MODEL. -->
**An empty selection runs no grok reviewer — and unlike claude, there is no fallback.** The
grok reviewer agent stops without a `MODEL`, so there is nothing to dispatch. Say so on the
Step 2.5 confirmation page ("grok: модели не выбраны — ревьюер не запускается") and continue;
do not re-ask and do not STOP.

Each selected model becomes an independent reviewer with the same diff and the same prompt —
the point is model diversity, so never differentiate their prompts.
````

- [ ] **Step 4: Expand grok on the confirmation page (Step 2.5) — including the empty case**

Define the empty-roster state explicitly, in both orchestrators. "grok selected, no model
checked" is reachable interactively (it is NOT reachable in `default` mode, where the validator
forbids an empty `grok_models`), and today nothing says what happens: the confirmation page
would list a reviewer that never runs, and the watcher would be handed a roster entry with no
dispatch behind it — a `MISSING` row indistinguishable from a dead executor. Required
behaviour: the page states "grok выбран, но ни одной модели не отмечено — grok-ревьюер не
запускается", the pair contributes nothing to the dispatch roster, the watcher roster and the
guard, and if the TOTAL effective roster is empty the run stops with "ничего не выбрано для
ревью" instead of starting an orchestration with no reviewers.


In Step 2.5, extend the expansion sentence: after "**Expand `claude` in that list into one
bullet per entry of `SELECTED_CLAUDE_MODELS`**", add:

```markdown
**Expand `grok` the same way**, one bullet per entry of `SELECTED_GROK_MODELS` (`grok:grok-4.6`).
When that list is empty, show `grok: модели не выбраны — ревьюер не запускается` instead of a
bullet, so a user who selected grok and then skipped its models sees why nothing will run.
```

And in the "Нет, выбрать заново" option, extend the re-run list to "re-runs Q1 **and** Steps
2.4 and 2.45, dropping the current `SELECTED_CLAUDE_MODELS` and `SELECTED_GROK_MODELS`".

- [ ] **Step 5: Handle the preset in Step 0**

In Step 0's `default`-mode bullet list, after the `codex` / `gemini` bullet:

```markdown
  - `grok` in `defaults.code_review.builtin` → **one `grok-code-reviewer` per entry of
    `defaults.code_review.grok_models`**, each dispatched with `MODEL=<entry>` on the first
    line of its prompt. The config validator guarantees that list is non-empty whenever `grok`
    is in `builtin`, so there is no fallback branch here and no case where `grok` in the preset
    dispatches nothing.
  - **Bind `SELECTED_GROK_MODELS` to `defaults.code_review.grok_models` here** (empty when
    `grok` is not in `builtin`), for the same reason `SELECTED_CLAUDE_MODELS` is bound: Step 5a
    consumes it unconditionally, and an unbound name in a prompt raises nothing at all.
```

- [ ] **Step 5b: Cover team mode — it dispatches separately**

`/mesh-review` has a second dispatch path (Step 5b, team mode) with its own enumeration of
wrapper reviewers. Nothing in the steps above touches it, so a team-mode run would spawn codex,
gemini and ext-claude reviewers and silently none for grok. Extend that step's wrapper list and
spawn one task per `grok:<model>` pair, exactly as Step 5a does. Then re-check by name:

```bash
grep -n 'codex / gemini / ext-claude' commands/mesh-review.md   # expect: no functional list left
grep -c 'grok' commands/mesh-review.md
```

**And sweep the stale engine enumerations while you are here.** The phrase
"codex / gemini / ext-claude" (and its variants) appears in both orchestrators and in the
header of `verify-delegation.sh`; each one that describes what the plugin CAN dispatch is now
wrong. Fix them by name, not by eye:

```bash
grep -rn 'codex / gemini / ext-claude\|codex/gemini/ext-claude' commands/ skills/ | grep -v grok
```

Expect zero lines left that enumerate dispatchable engines without grok. Lines that describe a
historical incident or a measured fact about those three engines stay as they are — they are
statements about the past, not about the roster.


- [ ] **Step 6: Dispatch in Step 5a**

In the "Before dispatch" paragraph, extend the pair list: `codex`→`codex:-`,
`gemini`→`gemini:-`, each entry of `SELECTED_GROK_MODELS`→`grok:<model>`, each selected model
id→`ext-claude:<id>`.

In the builtin reviewer list, after the gemini bullet:

```markdown
- grok: `subagent_type: "claude-mesh:grok-code-reviewer"`, **one Task per entry of
  `SELECTED_GROK_MODELS`**, prompt: `MODEL=<entry> Review the changes for production readiness`
  — **`MODEL=` must be the FIRST non-blank line**, so write `MODEL=<entry>` first and
  `BASE_BRANCH=<branch>` on the next line; the agent contract (Task 7) parses `^MODEL=(\S+)`
  and a line that begins with `BASE_BRANCH=` does not match it. Spelled the other way round it
  becomes `BASE_BRANCH=<branch> MODEL=<entry> Review the changes for
  production readiness`. The `MODEL=` prefix is a parameter, exactly as for ext-claude; it is
  not review content, so the CRITICAL rule below still forbids inlining scope or diff.
```

Add grok to the CRITICAL paragraph's list of wrappers ("The codex / gemini / grok / ext-claude
reviewers are thin wrappers") and to the Dispatch-model exception paragraph, which must keep
saying that `DISPATCH_MODEL` governs the wrappers — the grok model is the engine's model, not
the wrapper's, so both apply at once and neither overrides the other.

In the watcher example, show a grok entry:

```bash
   "$WATCH" --since <DISPATCH_EPOCH> codex grok/grok-4.6 ext-claude/zai/glm
```

- [ ] **Step 7: Extend the guard step (6.0)**

In the classification example, add a grok pair:

```bash
for spec in "codex:-" "grok:grok-4.6" "ext-claude:zai/glm"; do
```

In the verdict list, extend the engine-specific clauses:
- `STALLED`: "…for ext-claude **and grok** that is a missing result event; for codex and gemini, …"
- `BROKEN`: "…for ext-claude **and grok** that is thinking-only / `num_turns≤1` …"
- `DEGRADED`: change the parenthetical from "(exit 5, ext-claude only)" to "(exit 5, ext-claude
  and grok)" and add: "On grok the remedy differs and the reason line says so: `grok-exec`
  already passes `--permission-mode bypassPermissions`, so a denial there points at the CLI's
  own permission configuration (`~/.grok`), not at a plugin release."

In the status table example, add a row: `| grok:grok-4.6 | REAL | ✅ kept |`.

In the re-dispatch step (6.4b), extend the exact-prompt list with
`MODEL=<model> Review the changes for production readiness` for grok.

- [ ] **Step 8: Attribution in Step 6.1**

In the deduplication rule, extend the claude attribution sentence:

```markdown
Grok reviewers are attributed the same way, as `grok:<model>` (`grok:grok-4.6`) — two grok
models reporting one issue is corroboration exactly as two Claude models are, so merge them
into one entry that lists both and never collapse them into a nameless "grok".
```

- [ ] **Step 9: Update the frontmatter description**

```yaml
description: Launch code review agents (built-in claude on N models, codex, gemini, grok on N models, ext-claude on N models) with selection UI and result deduplication.
```

- [ ] **Step 10: Verify the file is internally consistent**

```bash
cd /opt/github/zinin/claude-mesh
grep -c 'grok' commands/mesh-review.md
grep -n 'SELECTED_GROK_MODELS' commands/mesh-review.md
```

Expected: `SELECTED_GROK_MODELS` appears in Step 0 (bind), Step 2.45 (bind + fill), Step 2.5
(expand), Step 5a (dispatch) — four sites at minimum, mirroring `SELECTED_CLAUDE_MODELS`.

```bash
grep -n 'SELECTED_CLAUDE_MODELS' commands/mesh-review.md | wc -l
```

- [ ] **Step 11: Commit**

```bash
git add commands/mesh-review.md
git commit -m "feat(mesh-review): offer and dispatch grok reviewers per model"
```

---

### Task 12: `/mesh-design-review` integration

The same four points at this file's own step numbers. **Do not copy the Step 2.45 text across**
— the file documents four places where the two orchestrators deliberately differ (path
resolution, the order of guard and ping, the routing of a dead run, the scope of the watch
loop), and its "Never mirror these four" note exists because someone will try.

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` — parameters block, Step 5.0 (gates), Step 5.1 (`default` preset), Step 5.2 (Q1), a new Step 5.2.6, **Step 5.4 (Confirm selection — NOT dispatch)**, Step 6 (dispatch, watcher and guard live there), the per-executor output section of Step 7

**Step numbering, checked against the file:** 5.4 is *Confirm selection* (`SKILL.md:368`), and
dispatch begins at Step 6 (`:385`). An executor following "Step 5.4 (dispatch)" would look for
the routing in the wrong section and, finding none, improvise.

**Interfaces:** identical to Task 11, on the `design_review` preset.

- [ ] **Step 1: Extend the gates in Step 5.0**

After the `HAS_GEMINI` read, add the same two reads as Task 11 Step 1 (`HAS_GROK`,
`GROK_MODELS`), with this file's own wording for the rc handling. Extend the sentence that
follows the fence — "Compare `HAS_CODEX` / `HAS_GEMINI` / `HAS_MODELS` / `HAS_CLAUDE_MODELS` to
`1`" — to include `HAS_GROK`, and extend the `DEFAULTS_JSON` parse list with `.grok_models`.

- [ ] **Step 2: Handle the preset in Step 5.1**

After the `gemini` bullet:

```markdown
  - `grok` → **one `claude-mesh:grok-executor` per entry of `.grok_models`** — the EXECUTOR,
    never `grok-code-reviewer`. Design review composes its own prompt in Step 4 and hands it
    over verbatim; `grok-code-reviewer` would instead resolve a `BASE_BRANCH`/`merge-base`
    diff and render `shared/code-review-prompt.md`, i.e. review the working tree and ignore
    the two documents entirely. That is why this file dispatches `codex-executor` /
    `gemini-executor` / `ext-claude-executor` and not the `*-code-reviewer` agents. Each gets
    `MODEL=<entry>` on the first line. The validator guarantees a non-empty list whenever
    `grok` is in `builtin`, so this branch has no fallback and cannot dispatch nothing.
  - **Bind `SELECTED_GROK_MODELS` to that list here** (empty when `grok` is absent from
    `builtin`), exactly as `SELECTED_CLAUDE_MODELS` is bound: Step 5.4 remembers it for
    iterations 2..N.
```

- [ ] **Step 3: Restructure Q1 the same way, then add Step 5.2.6**

Q1 here (`skills/mesh-design-review/SKILL.md:309-317`) has the same four options and the same
four-option ceiling, so it takes the same restructure as Task 11 Step 2 — written for this file,
not copied: one `внешние CLI (codex / gemini / grok)` option shown when any of the three flags is
`1`, a follow-up engine page on the Step 5.3 pagination mechanic, that page skipped when exactly
one engine is configured, and an empty selection meaning "no CLI reviewer runs".

Extend the parenthetical after that list ("Show the codex / gemini / external-models options
only when their gating flag is `1`") accordingly, and add: "If `grok` is not selected → skip
Step 5.2.6 and run no grok reviewer."

Then add Step 5.2.6 after Step 5.2.5, written for this file: the same paginated
AskUserQuestion over `GROK_MODELS` with ★ from `.grok_models`, collecting into
`SELECTED_GROK_MODELS`, and the same "empty selection runs no grok reviewer, and there is no
fallback" rule. Do **not** copy Step 2.45's loader-resolution fence: this file resolves the
loader from `SKILL_BASE` and asks it for `data-dir`, as its own note explains.

- [ ] **Step 3b: Cover Step 5.4 (Confirm selection) — five edits, none optional**

Task 11 spells the symmetric edits out for `/mesh-review`; without them here, grok works for
exactly one iteration and then vanishes from an orchestrator whose whole purpose is iterating.

1. **`SKILL.md:381` — "Remember the confirmed set (built-in TYPES + `SELECTED_CLAUDE_MODELS` +
   `SELECTED_IDS`) for all subsequent iterations in the loop."** Add `SELECTED_GROK_MODELS` to
   that list. Miss it and the grok reviewers run on iteration 1 and silently disappear on
   iteration 2 — the "silently ignored list" failure that the `validate_defaults` comment cites
   as the very reason `claude_models` is fail-closed.
2. **Expand `grok` into one bullet per selected model on the confirmation page**
   (`grok:grok-4.6`, `grok:grok-4.5`), exactly as `claude` is expanded, so the user sees how
   many reviewers they are about to pay for.
3. **The "Перевыбрать" clause** currently reads "restarts Step 5.2 from Q1 with the same
   DEFAULT_IDS / CLAUDE_DEFAULT_IDS (Step 5.2.5 re-runs too)". Add 5.2.6, or a re-select leaves
   a stale `SELECTED_GROK_MODELS` behind.
4. **The "grok selected, no models checked" line.** Design §3 requires the confirmation page to
   say so outright. Task 11 Step 4 does this for `/mesh-review`; it must be written here too.
5. **Bind `SELECTED_GROK_MODELS` to the empty list when `grok` is not selected in Q1.** Step 3
   above says "skip Step 5.2.6 and run no grok reviewer" but never binds the name, and this
   file is emphatic about why that matters (`SKILL.md:328`: "Both bindings are mandatory… An
   undefined name in a shell script raises an error under `set -u`; in a prompt it raises
   nothing at all — the reader improvises"). Task 11 Step 3 binds both; the asymmetry is a
   defect, not a decision.

Then verify mechanically, the way Task 11 Step 10 does for its own file — design review has no
such check today, which is why these five went missing in the first place:

```bash
grep -c 'SELECTED_GROK_MODELS' skills/mesh-design-review/SKILL.md   # expect >= 4
grep -n 'grok' skills/mesh-design-review/SKILL.md | grep -ci 'code-reviewer'   # expect 0
```

- [ ] **Step 4: Dispatch, watch and verify**

- In the executors list, add: **`claude-mesh:grok-executor`** (built-in selected: `grok`)
  — one per entry of `SELECTED_GROK_MODELS`, no `REASONING_EFFORT` unless the user named one.
  Write the dispatch template out in full, in the `ext-claude` shape, because `MODEL` must be
  the FIRST non-blank line and an `Execute this prompt via…` line above it would break the
  parse:

  ```
  Task tool:
    subagent_type: claude-mesh:grok-executor
    description: "Design review via grok:<model> (iter N)"
    prompt: "MODEL=<model>
      Execute this prompt via grok-exec:
      PROMPT: [composed prompt with PREVIOUS_DECISIONS]
      TASK_NAME: design-review-[TOPIC]-iter-N
      SUPERVISED_MODE: shell"
  ```
- In the parameters block at the top of the file, add `GROK_REASONING_EFFORT` beside
  `CODEX_REASONING_LEVEL`, described as: "resolved from `config.yaml` (`grok.reasoning_effort`)
  by the executor; when that is unset too, the CLI's own default applies. Set only when the
  user explicitly overrides."
- In the watcher example, add `grok/grok-4.6` to the roster.
- In the guard example, extend the sentence "The arguments are the engine, the model (`-` for
  codex and gemini)" to read "(`-` for codex and gemini; the model id for grok;
  `<provider>/<short>` for ext-claude)". **There is no "spec loop" in this file** — that is
  `/mesh-review`'s shape; here the guard is a single command (`SKILL.md:480-485`), so add a
  grok invocation line beside it, e.g. `bash "$VERIFY" grok grok-4.6 <DISPATCH_EPOCH> "$DATA_DIR"`.
- In the closing clause of watch-loop point 6, extend "the codex / gemini / ext-claude
  executors only" to include grok.
- In the per-executor output section, add a `## grok-executor (<model>)` block beside the
  codex and gemini ones — the section is named after the agent that ran, and per the bullet
  above that agent is the executor.
- **Carry the tooling constraint into the PROMPT block.** In `/mesh-review` the no-skills line
  is appended by `grok-code-review` (Task 7 Step 4); design review bypasses that skill entirely
  and hands its own composed prompt to the executor, so nothing adds the line here. Without it,
  grok — which sees every installed claude-* plugin, `claude-mesh:mesh-design-review` included —
  can answer a review request by launching an orchestration that writes run dirs this session
  never dispatched. Append the same paragraph to the composed prompt for grok dispatches only;
  codex, gemini and ext-claude cannot see those skills and need no such line.

- [ ] **Step 5: Check both orchestrators still agree where they must**

```bash
cd /opt/github/zinin/claude-mesh
bash skills/shared/tests/test-command-sync.sh > /tmp/sync.txt 2>&1; RC=$?; tail -3 /tmp/sync.txt; echo "rc=$RC"
grep -c 'grok' skills/mesh-design-review/SKILL.md
```

Expected: the sync suite passes (it guards the two fresh-session generators, which Task 13
touches — a failure here means Task 13's edits leaked in early), and grok appears throughout
the design-review file.

- [ ] **Step 6: Commit**

```bash
git add skills/mesh-design-review/SKILL.md
git commit -m "feat(design-review): offer and dispatch grok reviewers per model"
```

---

### Task 13: Fresh-session prompts, README and CHANGELOG

**Files:**
- Modify: `commands/code-review-fresh-session.md`, `commands/design-review-fresh-session.md`, `README.md`, `CHANGELOG.md`

**Interfaces:** consumes everything above; produces documentation only.

- [ ] **Step 1: Add grok to both generators**

Both files name the engines in prose while deliberately naming no models — the generated
prompt tells a fresh session to run `preflight-env.sh` and pick from what it reports. Find the
two mentions per file and extend them:

```bash
cd /opt/github/zinin/claude-mesh
grep -n 'codex' commands/code-review-fresh-session.md commands/design-review-fresh-session.md
```

**Read this before editing — the naive reading of the instruction contradicts itself.** One of
the two mentions per file lives INSIDE the `PREFLIGHT` region
(`commands/code-review-fresh-session.md:177`, region 168-185;
`commands/design-review-fresh-session.md:126`, region 117-134), which
`test-command-sync.sh:144-145` pins at 17 lines and asserts byte-identical across the pair.
"Extend both mentions" and "change nothing inside PREFLIGHT" cannot both be obeyed literally.
The resolution: **edit the in-region sentence in BOTH files identically and without changing
the line count.** Both assertions then stay green — they check equality between the files and
the region's length, not its content.

There is a second, worse problem in that same sentence. It currently reads: "`OK` on the
codex / gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an
auth check". Mechanically appending grok to that list ships a false statement into the one
region the suite guards most carefully: grok's probe runs `grok models`, which answers only
with a live login, so for grok it IS an auth check (Task 10 Step 3 says exactly that). Rewrite
with the distinction instead of extending the list, same line count, both files:

> `OK` on codex / gemini is a heuristic — binary present, section valid, endpoint answered,
> NOT an auth check. `OK` on grok is stronger: the probe runs the CLI itself, which answers
> only when a login is live.

The second mention per file (`:207` / `:155`, under `## WHEN THE USER SAYS GO`) is outside every
synced region — extend that one freely. The `DO NOT` region is not touched at all; its wording
is a measured experimental result.

- [ ] **Step 1b: Add a static orchestrator-contract block to `test-command-sync.sh`**

`test-command-sync.sh` compares the two orchestrators against EACH OTHER, so it catches drift
but is blind to a mistake made identically in both — and to a mistake made in only one file
about a place where the two are *supposed* to differ. Every orchestrator defect this review
surfaced was of that kind: the wrong agent type in design review, a missing
`SELECTED_GROK_MODELS` binding, an enumeration left at three engines. Assert absolute facts per
file, not equality between them:

```bash
echo "=== Test: orchestrator contract (grok) ==="
# design review dispatches EXECUTORS (it composes its own prompt); /mesh-review dispatches
# the code-reviewer wrappers. Crossing them makes grok review a git diff in a document review.
assert_eq "design review dispatches grok-executor" "1" \
  "$(grep -c 'claude-mesh:grok-executor' skills/mesh-design-review/SKILL.md)"
assert_eq "design review never dispatches grok-code-reviewer" "0" \
  "$(grep -c 'claude-mesh:grok-code-reviewer' skills/mesh-design-review/SKILL.md)"
assert_eq "mesh-review dispatches grok-code-reviewer" "1" \
  "$(grep -c 'claude-mesh:grok-code-reviewer' commands/mesh-review.md)"
# the empty-list binding both files insist on, in both files
for f in commands/mesh-review.md skills/mesh-design-review/SKILL.md; do
    [ "$(grep -c 'SELECTED_GROK_MODELS' "$f")" -ge 4 ] \
      && { PASS=$((PASS+1)); echo "  PASS: $f binds SELECTED_GROK_MODELS"; } \
      || { FAIL=$((FAIL+1)); echo "  FAIL: $f under-binds SELECTED_GROK_MODELS"; }
done
# roster spelling vs reviewer-name spelling — one slash, one colon, never swapped
assert_eq "watcher roster uses grok/<model>" "1" "$(grep -c 'grok/grok-4.6' commands/mesh-review.md)"
assert_eq "reviewer name uses grok:<model>"  "1" "$(grep -c 'grok:grok-4.6' commands/mesh-review.md)"
# no enumeration of dispatchable engines left without grok
assert_eq "no stale engine enumeration" "0" \
  "$(grep -rc 'codex / gemini / ext-claude' commands/mesh-review.md skills/mesh-design-review/SKILL.md | awk -F: '{s+=$2} END{print s+0}')"
```

Also extend `LOADER_SUBCMDS` in that suite with `list-grok-models` and `get-grok`: the list
pins which loader subcommands the orchestrators may call, and a new getter absent from it is
invisible to the check.


- [ ] **Step 2: Re-run the sync suite**

```bash
bash skills/shared/tests/test-command-sync.sh > /tmp/sync-after.txt 2>&1; RC=$?
tail -3 /tmp/sync-after.txt; echo "rc=$RC"
```

Expected: `rc=0`, `0 failed`. A failure here means either an edit landed inside a synced region,
or the two files drifted — read which assertion failed before moving anything.

- [ ] **Step 3: Finish the README**

Beyond the schema and dependency entries added in Task 4, add three troubleshooting rows:

```markdown
| `grok: command not found` | Install Grok Build, then `grok login` |
| `grok` row reads `NO-NETWORK` in the probe | `grok models` failed: no network, or the CLI is signed out — run `grok login` |
| `unknown model id` from a grok reviewer | The id in `grok.models` is not one this machine's CLI accepts. Run `grok models`: it prints `Available models:` followed by one `- <id>` per line, with `*` marking the default — copy an id from there verbatim |
```

And add grok to the feature bullet that currently reads "**`codex-*`, `gemini-*` agents** —
wrappers for OpenAI Codex CLI and Gemini CLI":

```markdown
- **`codex-*`, `gemini-*`, `grok-*` agents** — wrappers for the OpenAI Codex, Gemini and xAI
  Grok CLIs. The grok wrappers take a `MODEL` from the `grok.models` catalog, so one
  `/mesh-review` can run several grok models as independent reviewers
```

- [ ] **Step 4: Write the CHANGELOG entry**

At the top of `CHANGELOG.md`, under a new `## [Unreleased]` heading:

```markdown
### Added
- **grok is a third CLI reviewer engine**, alongside codex and gemini: `grok-exec` /
  `grok-code-review` skills, `grok-executor` / `grok-code-reviewer` agents, a gated `grok:`
  config section, a row in the environment probe, and a place in the selection UI of both
  `/mesh-review` and `/mesh-design-review`. Unlike codex and gemini, grok carries a model
  CATALOG — `grok.models`, with `defaults.<preset>.grok_models` choosing which entries a
  preset runs — so one review can cross-check itself across several grok models, exactly as
  `claude.models` already allows for the built-in reviewer.
- The grok runs speak the Claude Code wire format (`--output-format streaming-messages-json`),
  so `shared/extract-result.py`, the report renderer and the `ext-claude` branch of
  `verify-delegation.sh` serve them unchanged — and grok reaches the `DEGRADED` verdict, which
  codex and gemini cannot.

### Changed
- `skills/ext-claude-exec/generate-md.sh` moved to `skills/shared/stream-json-report.sh`. Two
  engines render reports from the same stream format; the renderer had been living inside one
  of them. Same signature, same output.
- The model-catalog validator is now one function serving `claude:` and `grok:`. Its error
  messages for `claude.models` are unchanged, byte for byte.
- `preflight-env.sh` probes a CLI with a command when an HTTP request cannot answer for it:
  `grok models` reports network and login together, while a curl against `api.x.ai` would
  describe an endpoint a grok.com subscription never calls.

### Requirements
- `grok` CLI (only when using the grok agents). It authenticates itself; claude-mesh never
  handles a grok token. Note that grok also reads `~/.claude/CLAUDE.md` and every installed
  claude-* plugin — the review prompt therefore forbids it from invoking any skill.
```

- [ ] **Step 5: Commit**

```bash
git add commands/code-review-fresh-session.md commands/design-review-fresh-session.md README.md CHANGELOG.md
git commit -m "docs: grok in the fresh-session prompts, README and changelog"
```

---

### Task 14: Acceptance — a live review with grok

The suites prove the parts. This proves the chain: config → UI → agent → skill → CLI → run dir
→ guard → findings.

**Files:** none modified. This task either passes or sends you back to a specific task.

- [ ] **Step 1: Configure the live plugin**

**Ask the user to add this to their `config.yaml`; do not edit it yourself.** The file is
user-owned — the first Global Constraint of this plan says validators report and agents never
fix, and "or have them do it" leaves the wrong door open. The commands below only print and
check; the edit is the user's:

```bash
cd /opt/github/zinin/claude-mesh
DATA="$(bash skills/shared/config-loader.sh data-dir)"
echo "$DATA/config.yaml"
grep -n 'grok' "$DATA/config.yaml" || printf '%s\n' "no grok section yet — add:" "grok:" "  models: [grok-4.6, grok-4.5]" "  reasoning_effort: xhigh"
```

Then verify:

```bash
bash skills/shared/config-loader.sh validate; echo "rc=$?"
bash skills/shared/config-loader.sh list-grok-models
bash skills/shared/preflight-env.sh 2>/dev/null | grep -E '^grok|SUMMARY available'
```

Expected: `rc=0`, both models listed, `grok OK`, and `grok:grok-4.6` on the available line.

- [ ] **Step 2: Run one grok reviewer end to end**

In a session with the plugin loaded, run `/claude-mesh:mesh-review` and select **only** the
grok reviewer with one model. Let it finish.

- [ ] **Step 3: Verify the run on disk**

```bash
cd /opt/github/zinin/claude-mesh
DATA="$(bash skills/shared/config-loader.sh data-dir)"
RD="$(ls -td "$DATA"/runs/grok/*/*/ 2>/dev/null | head -1)"
echo "RUN=$RD"
ls -la "$RD"
echo "--- terminal event:"; grep -c '"type":"result"' "$RD/raw.jsonl"
echo "--- num_turns:"; grep '"type":"result"' "$RD/raw.jsonl" | jq -r 'select(.is_error==false)|.num_turns' | sort -n | tail -1
echo "--- review size:"; tr -d '[:space:]' < "$RD/output.txt" | wc -c
```

Expected: a run directory two levels under `runs/grok/` (model, then timestamp), one or more
`result` events, `num_turns` well above 1, and an `output.txt` far above the 400-byte floor.

- [ ] **Step 4: Verify the guard agrees**

```bash
cd /opt/github/zinin/claude-mesh
DATA="$(bash skills/shared/config-loader.sh data-dir)"
RD="$(ls -td "$DATA"/runs/grok/*/*/ 2>/dev/null | head -1)"
MODEL="$(basename "$(dirname "$RD")")"
SINCE="$(( $(date +%s) - 7200 ))"
bash skills/shared/verify-delegation.sh grok "$MODEL" "$SINCE" "$DATA"; echo "rc=$?"
```

Expected: `REAL` on stdout, `rc=0`. Any other verdict is a real finding — read the reason on
stderr and fix the task it points at (`FLIP` → the agent never called the skill, Task 7;
`STALLED` with no result event → the flag set in Task 6; `BROKEN` → the model answered without
reading code, which is a prompt problem, not a plumbing one).

- [ ] **Step 5: Run every suite one last time**

The loop must ACCUMULATE failures and exit non-zero. As written before this fix it printed
`FAILED` and moved on, so an acceptance step could end green with three suites broken:

```bash
cd /opt/github/zinin/claude-mesh
FAILED=0
for t in test-config-loader test-verify-delegation test-watch-runs test-preflight-env test-command-sync test-extract-result test-render-template test-loader-resolution test-check-context-size; do
    printf '%-28s ' "$t"
    if bash "skills/shared/tests/$t.sh" >/tmp/"$t".log 2>&1; then echo OK
    else echo FAILED; FAILED=$((FAILED+1)); tail -5 /tmp/"$t".log; fi
done
GROK_SMOKE=1 bash skills/shared/tests/test-grok-exec-smoke.sh > /tmp/smoke.txt 2>&1 \
    || FAILED=$((FAILED+1))
tail -2 /tmp/smoke.txt
echo "suites failed: $FAILED"
[ "$FAILED" -eq 0 ] || { echo "ACCEPTANCE NOT MET"; exit 1; }
```

Expected: `OK` on every line, `0 failed` from the smoke test, `suites failed: 0`, rc 0. If the
smoke test SKIPs because `GROK_SMOKE` was forgotten or `grok` is absent, that is not a pass —
read its output and say which.

- [ ] **Step 6: Commit the acceptance record**

```bash
git commit --allow-empty -m "test(grok): live /mesh-review acceptance run verified REAL"
```

---

## Self-Review Record

Checked after writing, against `docs/superpowers/specs/2026-08-28-grok-engine-design.md`:

**Spec coverage.** §1 configuration → Tasks 1-4. §2 execution layer → Tasks 5-6. §3 review layer
and orchestrators → Tasks 7, 11, 12. §4 guard and observability → Tasks 8, 9, 10. §5 tests →
folded into the task each one guards, plus Task 14 for the live run. §6 documentation → Tasks 4
and 13. The spec's three "checks the plan must run first" are folded in where they act: the
`cli_row` decision in Task 10 Step 3, the claude-message diff in Task 1 Steps 1 and 5, and the
stream-growth measurement in Task 6 Step 11.

**Naming consistency.** `SELECTED_GROK_MODELS` (orchestrators), `GROK_MODELS` (catalog read),
`GROK_DEFAULT_IDS` (preset ★ markers), `GROK_IDENT_RE` (charset), `validate_grok_catalog` /
`validate_grok` (split by whether it can `warn`), `has_grok` / `list-grok-models` / `get-grok`
(loader commands), `grok:<model>` (reviewer name), `grok/<model>` (roster), `runs/grok/<model>/`
(path). Each is used under one spelling everywhere it appears above.

**Deliberate omission.** There is no `has_grok_models` flag: `grok.models` is required and
non-empty whenever the section exists, so `has_grok` answers both questions. Every step that
would have gated on it gates on `HAS_GROK` instead.
