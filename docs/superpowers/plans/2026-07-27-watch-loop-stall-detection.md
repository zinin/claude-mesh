# Watch-loop stall detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `/mesh-review` and `/mesh-design-review` orchestrators notice a dead executor within the stall threshold instead of sitting silent until the hour-long global budget expires.

**Architecture:** Four moves. **A** — turn on the watchdog that `/mesh-design-review` never enabled. **B** — replace the prose "poll the disk" instruction with a tested shared script, `skills/shared/watch-runs.sh`, that takes a *roster* of `engine[/provider/model]` entries plus `--since EPOCH`, re-resolves each executor's newest run directory every tick, and classifies it `DONE` / `FAILED` / `RUN` / `SILENT` / `MISSING`. **C** — route both prompts through it. **D** — make design-review run the existing `verify-delegation.sh` content gate that `/mesh-review` has always run.

**Tech Stack:** bash 4.2+ (the `printf '%(fmt)T'` builtin replaces every `date` call), GNU `stat -c`, `jq` (only to read two config values), markdown prompts.

## Global Constraints

- The stall threshold is `runtime.timeouts.stall_sec`, **floored at 600**. `codex-exec` and `gemini-exec` hardcode `HARD_ZERO_TIMEOUT=600` and ignore the config key, so a lower threshold would let the watcher call a live run silent before its own watchdog acts. No new config key.
- `--since` is an absolute unix epoch and the **only** volatile value the prompts substitute. The deadline is computed inside the script as `since + global_sec + 300`. Never write arithmetic over a shell variable into a prompt: shell state does not survive between Bash-tool calls, and an unset name in a prompt raises nothing at all.
- **Every verdict exits 0.** The harness surfaces a non-zero background exit as "failed with exit code N", which an LLM orchestrator reads as an error. A non-zero exit (64) means the script itself is broken.
- Detection marks a run failed and continues. **No new retry layer.** In `/mesh-review` retry already exists twice (`watchdog.sh` `MAX_RETRIES=2`, and Step 6.0's `max_redispatch`). In `/mesh-design-review` there is exactly **one** — the watchdog, which Task 3 turns on. Do not write "two layers" into the design-review prompt; `max_redispatch` and `Step 6.0` do not exist in that file.
- `skills/shared/verify-delegation.sh` and `skills/shared/watchdog.sh` are **called, never modified**.
- The `SUPERVISED_MODE` default in the `*-exec` skills stays `none`. Flipping it would strip live `progress-monitor.sh` progress from direct `/claude-mesh:*-exec` invocations.
- New shell code follows `verify-delegation.sh` conventions: `set -u` (not `-e`), a bash version guard, a verdict on stdout, diagnostics on stderr.
- Test files follow `skills/shared/tests/test-verify-delegation.sh`: `assert_eq`, `PASS`/`FAIL` counters, `mktemp -d` fixtures, and a closing `=== Summary: $PASS passed, $FAIL failed ===` with `[ "$FAIL" = "0" ]`.
- **Assert `0 failed`, never a hardcoded pass count.** The previous draft of this plan asserted "180 passed" for `test-config-loader.sh`; the real number on this branch is 246. A count inherited without measuring becomes a false gate.
- CHANGELOG entries go under `## [Unreleased]`; the version bump is a separate release chore and is out of scope.

## File Structure

| File | Responsibility |
|---|---|
| `skills/shared/watch-runs.sh` (new) | The whole watch loop: roster → run dir → status → verdict. Reads existence, size and mtime; never content. |
| `skills/shared/tests/test-watch-runs.sh` (new) | Fixtures under a temporary `--data-dir`; one assert per documented behaviour. |
| `skills/mesh-design-review/SKILL.md` | Step 6: dispatch templates gain `SUPERVISED_MODE: shell`; the watch block calls the script; the collection step gains the content gate. |
| `commands/mesh-review.md` | Step 5a watch block calls the script. |
| `agents/{codex,gemini,ext-claude}-executor.md` | Document `SUPERVISED_MODE` so the dispatch line is forwarded as a parameter instead of leaking into `PROMPT`. |
| `skills/shared/tests/test-loader-resolution.sh` | Canary counts, bumped for the new resolver site in `commands/`. |
| `config.example.yaml` | `stall_sec` comment gains the second consumer and the floor. |

---

### Task 1: `watch-runs.sh` — roster resolution, classification, one evaluation

**Files:**
- Create: `skills/shared/watch-runs.sh`
- Test: `skills/shared/tests/test-watch-runs.sh`

**Interfaces:**
- Consumes: `skills/shared/config-loader.sh` (`data-dir`, `get-runtime`), resolved as a sibling of the script.
- Produces: an executable `watch-runs.sh` accepting `--since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR] <engine[/provider/model]>...`. Prints a reason line, then one row per roster entry. Reason strings established here and relied on by Tasks 4–5: `ALL_DONE`, `SETTLED <transitions>`, `CHANGED <transitions>`, `DEADLINE`, `SNAPSHOT`, where a transition is `<entry> RUN→<STATUS>`. All exit 0; usage errors exit 64. Task 2 adds only the blocking loop and reuses the shell functions `resolve_run_dir`, `newest_mtime`, `classify`, `evaluate`, `transitions`, `all_done`, `any_run`, `any_moved`, `emit` defined here.

- [ ] **Step 1: Write the failing test file**

Create `skills/shared/tests/test-watch-runs.sh`:

```bash
#!/usr/bin/env bash
# Regression tests for watch-runs.sh
#
# watch-runs.sh answers the question neither orchestrator could answer on its own: is each
# dispatched executor finished, still working, or dead? A dead executor and a slow one leave
# the same disk — nothing changes — so the classification below is the whole point.
#
# The roster is engine[/provider/model], NOT a run dir: an executor that dies and self-retries
# creates a NEW dir, and a watcher holding the old one reports a LIVE executor dead.
#
# Reasons (stdout line 1), all exit 0:
#   CHANGED <entry> RUN→X   SETTLED <entry> RUN→X   ALL_DONE   DEADLINE   SNAPSHOT
# Usage errors exit 64.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../watch-runs.sh"
LOADER="$TESTS_DIR/../config-loader.sh"

FAIL=0
PASS=0
printf -v NOW '%(%s)T' -1
ERRF="$(mktemp)"
trap 'rm -f "$ERRF"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$pattern' in '$actual')" ;;
    esac
}

assert_between() {
    local desc="$1" lo="$2" hi="$3" actual="$4"
    if [[ "$actual" =~ ^[0-9]+$ ]] && [ "$actual" -ge "$lo" ] && [ "$actual" -le "$hi" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected $lo..$hi, got '$actual')"
    fi
}

# run the script; capture stdout, stderr, reason line and rc
run() { OUT="$(bash "$SCRIPT" "$@" 2>"$ERRF")"; RC=$?; REASON="$(printf '%s\n' "$OUT" | head -1)"; ERR="$(cat "$ERRF")"; }
# the rendered row for a roster entry. Line 1 is the reason line and it names entries too,
# so it must be skipped — otherwise every row assertion silently matches the reason instead.
row() { printf '%s\n' "$OUT" | tail -n +2 | grep -F " $1 " | head -1; }
# the numeric quiet= value out of a row
quiet_of() { printf '%s\n' "$1" | sed -n 's/.*quiet=\([0-9]*\)s.*/\1/p'; }

# a run dir NAME stamped <offset> seconds from now, with an optional pid suffix
stamp() { printf '%(%Y-%m-%d-%H-%M-%S)T-%s' "$(( NOW + ${1:-0} ))" "${2:-100000}"; }
# mk_run <data-dir> <entry> [name-offset-sec] [pid] [name-suffix] → prints the created dir
mk_run() {
    local d="$1/runs/$2/$(stamp "${3:-0}" "${4:-100000}")${5:-}"
    mkdir -p "$d"; printf '%s' "$d"
}
# a watchdog.log holding one cleanup event with the given exit code
wd_log() { printf '{"ts":"x","event":"cleanup","attempt":1,"details":{"exit_code":%s}}\n' "$2" > "$1/watchdog.log"; }

SINCE_OK=$(( NOW - 300 ))    # inside the MISSING grace when --stall-sec is 600
SINCE_OLD=$(( NOW - 900 ))   # past the grace

# === Test 1: finished with output → DONE, and a single-entry roster → ALL_DONE ===
echo "=== Test 1: finished with output → DONE → ALL_DONE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "row is DONE" "DONE" "$(row codex)"
assert_match "row names the resolved dir" "$(basename "$a")" "$(row codex)"
rm -rf "$TDIR"

# === Test 2: bailed run → FAILED with the watchdog.exit reason ===
# watchdog.sh bail() creates `final` and the EXIT trap writes `cleanup`, so a run where every
# attempt failed looks finalized. Across 286 archived logs cleanup appears in 286 and complete
# in 246 — cleanup alone says "it stopped", never "it worked".
echo "=== Test 2: bailed run → FAILED with reason ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" gemini -60); mkdir -p "$a/attempt-2"; ln -s attempt-2 "$a/final"
wd_log "$a" 2
printf '{\n  "reason": "all_attempts_failed",\n  "attempts": 3\n}\n' > "$a/watchdog.exit"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" gemini
assert_eq "reason names the transition" "SETTLED gemini RUN→FAILED" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "row is FAILED" "FAILED" "$(row gemini)"
assert_match "row carries the bail reason" "all_attempts_failed" "$(row gemini)"
rm -rf "$TDIR"

# === Test 3: killed watchdog, nothing on disk → FAILED ===
echo "=== Test 3: cleanup exit_code 143, no output → FAILED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 143
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is FAILED" "FAILED" "$(row codex)"
rm -rf "$TDIR"

# === Test 4: rc 0 but empty output.txt → FAILED ===
# codex-exec/gemini-exec "leave empty" when extraction finds nothing, so rc=0 alone is not proof
# that there is anything to read. DONE must mean the orchestrator's next action can succeed.
echo "=== Test 4: cleanup exit_code 0 but empty output.txt → FAILED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; : > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is FAILED" "FAILED" "$(row codex)"
rm -rf "$TDIR"

# === Test 5: unsupervised finish → DONE ===
echo "=== Test 5: no watchdog.log, non-empty output.txt → DONE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/zai/glm -60); echo 'review' > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" ext-claude/zai/glm
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_match "row is DONE" "DONE" "$(row ext-claude/zai/glm)"
rm -rf "$TDIR"

# === Test 6: gemini's pre-created zero-byte output.txt is NOT finalization ===
echo "=== Test 6: zero-byte output.txt → RUN ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" gemini -60); : > "$a/output.txt"; : > "$a/log.jsonl"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" gemini
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row gemini)"
rm -rf "$TDIR"

# === Test 7: REGRESSION — a watchdog heartbeat keeps a retrying run alive ===
# This is what makes SUPERVISED_MODE=shell safe to enable. Under supervision the CLI writes
# attempt-N/raw.jsonl and root raw.jsonl appears only at the end, so between watchdog retries
# the root stream looks long dead. The `alive` heartbeat is the proof of life; without folding
# watchdog.log into the freshness set, every supervised retry would be reported as a death.
echo "=== Test 7: REGRESSION — watchdog heartbeat keeps a retrying run alive ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/deepseek/v4-pro -60)
: > "$a/raw.jsonl"; touch -d '30 minutes ago' "$a/raw.jsonl"
printf '{"ts":"x","event":"alive","attempt":2,"details":{"event_count":7,"age_sec":3}}\n' > "$a/watchdog.log"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" ext-claude/deepseek/v4-pro
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN, not SILENT" "RUN" "$(row ext-claude/deepseek/v4-pro)"
rm -rf "$TDIR"

# === Test 8: supervised layout — attempt-1/raw.jsonl is the live stream ===
echo "=== Test 8: attempt-1/raw.jsonl is the live stream ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); mkdir -p "$a/attempt-1"; : > "$a/attempt-1/raw.jsonl"
touch -d '30 minutes ago' "$a"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

# === Test 9: log.jsonl alone is a valid freshness source ===
# A codex default-mode run has no raw.jsonl at all.
echo "=== Test 9: log.jsonl as the only freshness source ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/log.jsonl"; touch -d '30 minutes ago' "$a"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

# === Test 10: stale stream → SILENT with a correct quiet value and a last stamp ===
echo "=== Test 10: stale stream → SILENT with quiet and last ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/ollama/kimi -700)
: > "$a/raw.jsonl"; touch -d '660 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/ollama/kimi
assert_eq "reason names the transition" "SETTLED ext-claude/ollama/kimi RUN→SILENT" "$REASON"
assert_match "row is SILENT" "SILENT" "$(row ext-claude/ollama/kimi)"
assert_between "quiet is ~660s" 655 675 "$(quiet_of "$(row ext-claude/ollama/kimi)")"
assert_match "row carries last=" "last=" "$(row ext-claude/ollama/kimi)"
rm -rf "$TDIR"

# === Test 11: threshold neighbourhood ===
# The exact `quiet == stall_sec` boundary is not asserted: a one-second clock tick between
# `touch` and the script's own `now` would flip it, and the difference is immaterial. What is
# asserted is that 600 is a threshold at all — just below stays RUN, just above turns SILENT.
echo "=== Test 11: threshold neighbourhood ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -700); : > "$a/raw.jsonl"; touch -d '590 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "590s quiet is still RUN" "RUN" "$(row codex)"
touch -d '615 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "615s quiet is SILENT" "SILENT" "$(row codex)"
rm -rf "$TDIR"

# === Test 12: an executor that has not created its dir yet is RUN, not dead ===
echo "=== Test 12: no run dir inside the grace → RUN ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_match "row is RUN" "RUN" "$(row codex)"
rm -rf "$TDIR"

# === Test 13: past the grace, a missing dir is MISSING ===
echo "=== Test 13: no run dir past the grace → MISSING ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason names the transition" "SETTLED codex RUN→MISSING" "$REASON"
assert_match "row is MISSING" "MISSING" "$(row codex)"
rm -rf "$TDIR"

# === Test 14: a roster typo is diagnosable, not a silent permanent MISSING ===
echo "=== Test 14: unknown roster entry warns on stderr ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/zia/glm
assert_match "row is MISSING" "MISSING" "$(row ext-claude/zia/glm)"
assert_match "stderr names the missing base" "ext-claude/zia/glm" "$ERR"
rm -rf "$TDIR"

# === Test 15: RETRY — a self-retry into a new dir is followed, the abandoned one ignored ===
# Observed four times on 2026-07-27: executors died unsupervised and re-ran into fresh dirs.
# A watcher holding the first dir would have reported four LIVE executors dead.
echo "=== Test 15: RETRY — the newer dir is watched, including a different suffix ==="
TDIR=$(mktemp -d)
old=$(mk_run "$TDIR" ext-claude/alibaba/qwen -600 2060029)
: > "$old/raw.jsonl"; touch -d '660 seconds ago' "$old/raw.jsonl" "$old"
new=$(mk_run "$TDIR" ext-claude/alibaba/qwen -60 2135662 '-retry')
: > "$new/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/alibaba/qwen
assert_match "row is RUN, not SILENT" "RUN" "$(row ext-claude/alibaba/qwen)"
assert_match "row names the retry dir" "$(basename "$new")" "$(row ext-claude/alibaba/qwen)"
rm -rf "$TDIR"

# === Test 16: a dir created before --since is not selected ===
echo "=== Test 16: a pre-window dir is not selected ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -5000); : > "$a/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "row is MISSING" "MISSING" "$(row codex)"
rm -rf "$TDIR"

# === Test 17: selection is by name, not by mtime ===
# On bail the abandoned dir gets a `final` symlink, which bumps its mtime above the retry dir's.
# Selecting by mtime would then follow the corpse.
echo "=== Test 17: a late write to the abandoned dir does not outrank the retry ==="
TDIR=$(mktemp -d)
old=$(mk_run "$TDIR" gemini -600 111); : > "$old/raw.jsonl"
new=$(mk_run "$TDIR" gemini -60 222); : > "$new/raw.jsonl"
touch -d '30 minutes ago' "$new"
touch "$old"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" gemini
assert_match "the newer NAME is selected" "$(basename "$new")" "$(row gemini)"
rm -rf "$TDIR"

# === Test 18: a data dir path containing a space ===
echo "=== Test 18: a path with a space ==="
TDIR=$(mktemp -d "${TMPDIR:-/tmp}/watch runs XXXXXX")
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
rm -rf "$TDIR"

# === Test 19: MIXED roster — only what moved is named ===
# The suite that shipped with the previous draft passed 36/36 both before and after a real
# reason-line bug, because no test ever had one entry already terminal while another moved.
echo "=== Test 19: mixed roster names only the entry that moved ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
b=$(mk_run "$TDIR" ext-claude/zai/glm -60); : > "$b/raw.jsonl"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex ext-claude/zai/glm
assert_eq "reason names only codex" "CHANGED codex RUN→DONE" "$REASON"
assert_match "codex row is DONE" "DONE" "$(row codex)"
assert_match "glm row is RUN" "RUN" "$(row ext-claude/zai/glm)"
rm -rf "$TDIR"

# === Test 20: two entries moving at once are both named ===
echo "=== Test 20: two transitions in one evaluation ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); wd_log "$a" 0; echo 'review' > "$a/output.txt"
b=$(mk_run "$TDIR" ext-claude/ollama/kimi -700)
: > "$b/raw.jsonl"; touch -d '660 seconds ago' "$b/raw.jsonl" "$b"
c=$(mk_run "$TDIR" ext-claude/zai/glm -60); : > "$c/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex ext-claude/ollama/kimi ext-claude/zai/glm
assert_eq "both transitions named, in roster order" \
    "CHANGED codex RUN→DONE, ext-claude/ollama/kimi RUN→SILENT" "$REASON"
rm -rf "$TDIR"

# === Test 21: --once over an already-silent roster reports CHANGED, not SNAPSHOT ===
# This is what makes a one-shot liveness check worth running when an executor pings: the answer
# names the death instead of handing back a table to diff by eye.
echo "=== Test 21: --once with an already-silent entry → CHANGED ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" ext-claude/ollama/kimi -700)
: > "$a/raw.jsonl"; touch -d '660 seconds ago' "$a/raw.jsonl" "$a"
b=$(mk_run "$TDIR" ext-claude/zai/glm -60); : > "$b/raw.jsonl"
run --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" ext-claude/ollama/kimi ext-claude/zai/glm
assert_eq "reason CHANGED" "CHANGED ext-claude/ollama/kimi RUN→SILENT" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 22: --once with everything running → SNAPSHOT ===
echo "=== Test 22: --once with everything running → SNAPSHOT ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
b=$(mk_run "$TDIR" gemini -60); : > "$b/log.jsonl"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex gemini
assert_eq "reason SNAPSHOT" "SNAPSHOT" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 23: the stall threshold is floored at 600 and says so ===
# codex-exec and gemini-exec hardcode HARD_ZERO_TIMEOUT=600, so a lower watcher threshold would
# call a live run silent 300s before its own watchdog would act on it.
echo "=== Test 23: --stall-sec below 600 is floored, with a warning ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -700); : > "$a/raw.jsonl"; touch -d '300 seconds ago' "$a/raw.jsonl" "$a"
run --once --since "$SINCE_OLD" --stall-sec 120 --data-dir "$TDIR" codex
assert_match "300s quiet stays RUN under the floor" "RUN" "$(row codex)"
assert_match "stderr announces the floor" "600" "$ERR"
rm -rf "$TDIR"

# === Test 24: usage errors ===
echo "=== Test 24: usage errors exit 64 ==="
TDIR=$(mktemp -d); mkdir -p "$TDIR/runs/codex"
run --once --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "missing --since → 64" "64" "$RC"
run --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR"
assert_eq "empty roster → 64" "64" "$RC"
run --once --since 3900 --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "a 1970 --since → 64" "64" "$RC"
assert_match "and it names the likely cause" "DISPATCH_EPOCH" "$ERR"
run --once --since "$SINCE_OK" --stall-sec abc --data-dir "$TDIR" codex
assert_eq "non-numeric --stall-sec → 64" "64" "$RC"
run --once --since "$SINCE_OK" --poll-sec 0 --data-dir "$TDIR" codex
assert_eq "--poll-sec 0 → 64" "64" "$RC"
# --stall-sec swallowing the next flag used to make the script block forever
run --since "$SINCE_OK" --data-dir "$TDIR" --stall-sec --once codex
assert_eq "--stall-sec eating --once → 64" "64" "$RC"
rm -rf "$TDIR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash skills/shared/tests/test-watch-runs.sh 2>&1 | tail -5`
Expected: FAIL — `watch-runs.sh` does not exist yet, so every `run` returns 127 with empty output and nearly every assert reports a mismatch.

- [ ] **Step 3: Write `skills/shared/watch-runs.sh`**

```bash
#!/usr/bin/env bash
# watch-runs.sh — is each dispatched executor finished, still working, or dead?
#
# The /mesh-review (Step 5a) and /mesh-design-review (Step 6) orchestrators disk-watch their
# executors. Finalization is easy to see; DEATH is not — a dead executor and a slow one leave
# exactly the same disk: nothing changes. Both orchestrators used to hand-roll the poll loop
# from prose, and both arrived at "exit when the finished count grows", which death never does.
# On 2026-07-26 four executors died mid-stream and the orchestrator stayed silent for 38
# minutes. This script is that loop, written once.
#
# Usage:
#   watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR]
#                 <engine[/provider/model]>...
#
# The positional arguments are a ROSTER — the subpath under <data-dir>/runs/, e.g. `codex` or
# `ext-claude/zai/glm` — and NOT run directories. An executor that dies and self-retries creates
# a NEW run dir; a fixed list would keep watching the abandoned one, see it go quiet, and report
# a LIVE executor dead. The newest dir at/after --since is re-resolved on every evaluation.
#
# Pass ONLY the executors still being waited for. The baseline is virtual — every entry is
# assumed RUN — so anything else is news and exits immediately. An entry already handled comes
# straight back as news; that is the signal that the roster was not narrowed.
#
# Status per roster entry:
#   DONE     terminal, watchdog exit code 0 (or no watchdog at all), and output.txt non-empty
#   FAILED   terminal, anything else — including a bail, an external kill, and rc=0 with no output
#   SILENT   not terminal, nothing written for longer than the stall threshold
#   RUN      not terminal and writing recently, or no dir yet inside the startup grace
#   MISSING  no run dir at/after --since once the grace has elapsed
#
# EVERY verdict exits 0. The harness surfaces a non-zero background exit as "failed with exit
# code N", and an LLM orchestrator reads that as an error. A non-zero exit (64) means THIS
# SCRIPT is broken — bad arguments, missing dependency — never that an executor died.
set -u
export LC_ALL=C   # run dir names are compared with [[ < ]]; keep collation byte-wise

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "watch-runs: bash 4.2+ required (got ${BASH_VERSION:-unknown}) — printf '%(fmt)T' formats every timestamp here, so no date(1) is needed" >&2
    exit 64
fi

# The only non-builtin dependency. BSD stat spells this `-f %m`; config-loader.sh carries the
# same probe for the same reason.
stat -c %Y "$0" >/dev/null 2>&1 || {
    echo "watch-runs: GNU stat required (BSD stat uses -f). On macOS: 'brew install coreutils' and put gnubin first in PATH." >&2
    exit 64
}

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SELF_DIR/config-loader.sh"

STALL_FLOOR=600
DEADLINE_MARGIN=300

SINCE=""
STALL_SEC=""
POLL_SEC=30
ONCE=0
DATA_DIR=""
ROSTER=()

is_pos_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
die() { echo "watch-runs: $1" >&2; exit 64; }
usage() {
    echo "usage: watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR] <engine[/provider/model]>..." >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)     SINCE="${2:-}";     shift 2 || usage ;;
        --stall-sec) STALL_SEC="${2:-}"; shift 2 || usage ;;
        --poll-sec)  POLL_SEC="${2:-}";  shift 2 || usage ;;
        --data-dir)  DATA_DIR="${2:-}";  shift 2 || usage ;;
        --once)      ONCE=1; shift ;;
        --)          shift; while [ $# -gt 0 ]; do ROSTER+=("$1"); shift; done ;;
        -*)          die "unknown option '$1'" ;;
        *)           ROSTER+=("$1"); shift ;;
    esac
done

# A caller with nothing left to watch should not invoke the watcher at all.
[ "${#ROSTER[@]}" -gt 0 ] || usage

# Every option validates the same way. A silent fallback on one of them is how
# `--stall-sec --once <entry>` used to swallow the flag and then block forever.
is_pos_int "$POLL_SEC" || die "--poll-sec must be a positive integer (got '$POLL_SEC')"
[ -z "$STALL_SEC" ] || is_pos_int "$STALL_SEC" || die "--stall-sec must be a positive integer (got '$STALL_SEC')"
is_pos_int "$SINCE" || die "--since is required and must be a unix epoch (got '$SINCE') — did DISPATCH_EPOCH expand to nothing?"

printf -v NOW '%(%s)T' -1
[ "$SINCE" -le $(( NOW + 60 )) ] || die "--since is in the future ($SINCE)"
[ "$SINCE" -ge $(( NOW - 86400 )) ] || die "--since is more than a day old ($SINCE) — did DISPATCH_EPOCH expand to nothing?"

if [ -z "$DATA_DIR" ]; then
    [ -x "$LOADER" ] || die "config-loader.sh not found beside watch-runs.sh — pass --data-dir"
    DATA_DIR="$("$LOADER" data-dir 2>/dev/null)"
fi
[ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ] || die "data dir not resolved or missing: '$DATA_DIR'"

# Threshold: the caller's flag, else runtime.timeouts.stall_sec, else the floor. jq is optional —
# without it the substitution yields nothing and the fallback takes over, loudly.
if [ -z "$STALL_SEC" ]; then
    if [ -x "$LOADER" ]; then
        STALL_SEC="$("$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.stall_sec // empty' 2>/dev/null)"
    fi
    is_pos_int "$STALL_SEC" || {
        echo "watch-runs: runtime.timeouts.stall_sec not resolved — using $STALL_FLOOR" >&2
        STALL_SEC="$STALL_FLOOR"
    }
fi
if [ "$STALL_SEC" -lt "$STALL_FLOOR" ]; then
    echo "watch-runs: stall threshold $STALL_SEC raised to $STALL_FLOOR — codex-exec and gemini-exec hardcode HARD_ZERO_TIMEOUT=600, so a lower threshold would call a live run silent before its own watchdog acts" >&2
    STALL_SEC="$STALL_FLOOR"
fi

# The deadline lives HERE, not in the prompt. The watcher restarts after every event, so a
# relative budget would reset each time and never expire; and arithmetic over a shell variable
# in a prompt silently collapses to nonsense, because shell state does not survive between
# Bash-tool calls. Deriving it from --since makes that whole class of failure impossible.
GLOBAL_SEC=""
if [ -x "$LOADER" ]; then
    GLOBAL_SEC="$("$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.global_sec // empty' 2>/dev/null)"
fi
is_pos_int "$GLOBAL_SEC" || GLOBAL_SEC=3600
DEADLINE=$(( SINCE + GLOBAL_SEC + DEADLINE_MARGIN ))

# Run dir names begin YYYY-MM-DD-HH-MM-SS-<pid>, fixed width and zero padded, so a lexicographic
# comparison against the same rendering of --since is an exact creation-time window.
printf -v SINCE_STR '%(%Y-%m-%d-%H-%M-%S)T' "$SINCE"

declare -A WARNED_BASE=()
RUNDIR_PATH=""
NEWEST=0
STATUS=""
QUIET=""
LAST=""
DETAIL=""
RUNDIR=""
STATUSES=()
ROWS=""

# The newest run dir for a roster entry, at/after --since. Selection is by NAME, not mtime: on
# bail the abandoned dir gains a `final` symlink, which bumps its mtime above the retry dir's,
# and selecting by mtime would follow the corpse.
resolve_run_dir() {
    local entry="$1" base="$DATA_DIR/runs/$1" best="" name d
    RUNDIR_PATH=""
    if [ ! -d "$base" ]; then
        [ -n "${WARNED_BASE[$entry]:-}" ] || {
            echo "watch-runs: no runs directory for '$entry' ($base) — check the roster entry" >&2
            WARNED_BASE[$entry]=1
        }
        return 1
    fi
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        name="${d%/}"; name="${name##*/}"
        [[ "$name" < "$SINCE_STR" ]] && continue
        [[ -z "$best" || "$name" > "$best" ]] && best="$name"
    done
    [ -n "$best" ] || return 1
    RUNDIR_PATH="$base/$best"
}

# Freshness is the newest mtime across every stream a run can be writing.
#  - supervised: the CLI writes attempt-N/raw.jsonl and root raw.jsonl appears only at the end,
#    but watchdog.log gets an `alive` heartbeat every 60s, so the gap between retries is covered;
#  - unsupervised codex: log.jsonl only, no raw.jsonl at all;
#  - watchdog dead but CLI alive: attempt-*/raw.jsonl still moves.
# Erring toward "do not declare a live run dead" is deliberate; the deadline is the backstop.
newest_mtime() {
    local d="$1" m f
    NEWEST=0
    for f in "$d/raw.jsonl" "$d/log.jsonl" "$d/watchdog.log" "$d"/attempt-*/raw.jsonl; do
        [ -f "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null)" || continue
        [ -n "$m" ] || continue
        [ "$m" -gt "$NEWEST" ] && NEWEST="$m"
    done
    [ "$NEWEST" != 0 ] || NEWEST="$(stat -c %Y "$d" 2>/dev/null || printf '0')"
}

classify() {
    local entry="$1" d wl line rc out has_out
    STATUS=""; QUIET=""; LAST=""; DETAIL=""; RUNDIR=""

    if ! resolve_run_dir "$entry"; then
        # No dir yet is normal right after dispatch: an executor still booting must not be
        # declared dead in milliseconds. Grace runs from --since, so no extra option is needed.
        if [ $(( NOW - SINCE )) -gt "$STALL_SEC" ]; then STATUS=MISSING; else STATUS=RUN; fi
        return
    fi
    d="$RUNDIR_PATH"
    RUNDIR="${d##*/}"

    # `cleanup` is written by the EXIT trap on EVERY watchdog exit — success, bail, or an
    # external kill. Across 286 archived logs it appears in 286 while `complete` appears in 246,
    # and 36 of the runs carrying it have neither `final` nor `output.txt`. So `cleanup` says
    # "it stopped"; only its exit code says whether it worked.
    rc=""
    wl="$d/watchdog.log"
    if [ -f "$wl" ]; then
        while IFS= read -r line; do
            case "$line" in *'"event":"cleanup"'*) ;; *) continue ;; esac
            [[ "$line" =~ \"exit_code\":(-?[0-9]+) ]] && rc="${BASH_REMATCH[1]}"
        done < "$wl"
    fi

    out="$d/output.txt"; [ -s "$out" ] || out="$d/final/output.txt"
    has_out=0
    [ -s "$out" ] && has_out=1

    if [ -n "$rc" ] || { [ ! -f "$wl" ] && [ "$has_out" = 1 ]; }; then
        if [ "${rc:-0}" = 0 ] && [ "$has_out" = 1 ]; then
            STATUS=DONE
        else
            STATUS=FAILED
            if [ -f "$d/watchdog.exit" ] &&
               [[ "$(cat "$d/watchdog.exit" 2>/dev/null)" =~ \"reason\":[[:space:]]*\"([a-z_]+)\" ]]; then
                DETAIL="${BASH_REMATCH[1]}"
            fi
        fi
        return
    fi

    newest_mtime "$d"
    QUIET=$(( NOW - NEWEST ))
    printf -v LAST '%(%H:%M:%S)T' "$NEWEST"
    if [ "$QUIET" -gt "$STALL_SEC" ]; then STATUS=SILENT; else STATUS=RUN; fi
}

evaluate() {
    local i entry row
    printf -v NOW '%(%s)T' -1
    ROWS=""
    for i in "${!ROSTER[@]}"; do
        entry="${ROSTER[$i]}"
        classify "$entry"
        STATUSES[$i]="$STATUS"
        row="$(printf '%-8s %-26s %s' "$STATUS" "$entry" "${RUNDIR:-—}")"
        case "$STATUS" in
            SILENT) row="$row  quiet=${QUIET}s last=$LAST" ;;
            RUN)    [ -n "$QUIET" ] && row="$row  quiet=${QUIET}s" ;;
            FAILED) [ -n "$DETAIL" ] && row="$row  $DETAIL" ;;
        esac
        ROWS="$ROWS$row"$'\n'
    done
}

# The baseline is virtual: every roster entry is assumed RUN, so "what changed" is simply
# "what is not RUN". Establishing the baseline from the first evaluation instead would absorb a
# run that was ALREADY dead when the watcher started — and the watcher restarts after every
# event, so that reproduces the original blindness on every restart.
transitions() {
    local i out=""
    for i in "${!ROSTER[@]}"; do
        [ "${STATUSES[$i]}" = "RUN" ] && continue
        out="$out, ${ROSTER[$i]} RUN→${STATUSES[$i]}"
    done
    printf '%s' "${out#, }"
}

all_done() { local s; for s in "${STATUSES[@]}"; do [ "$s" = DONE ] || return 1; done; return 0; }
any_run()  { local s; for s in "${STATUSES[@]}"; do [ "$s" = RUN ] && return 0; done; return 1; }
any_moved() { local s; for s in "${STATUSES[@]}"; do [ "$s" = RUN ] || return 0; done; return 1; }

emit() { printf '%s\n' "$1"; printf '%s' "$ROWS"; exit 0; }

# Checked in this order on every evaluation: all-done, settle, deadline, change.
# Finished work outranks the budget: with the deadline first, a roster that had completed
# while the orchestrator was busy reported DEADLINE — "time ran out" over six finished runs.
evaluate
all_done && emit "ALL_DONE"
any_run || emit "SETTLED $(transitions)"
[ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE"
any_moved && emit "CHANGED $(transitions)"
emit "SNAPSHOT"
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x skills/shared/watch-runs.sh
bash skills/shared/tests/test-watch-runs.sh
```
Expected: `=== Summary: 52 passed, 0 failed ===` and exit 0. If the count differs but `0 failed` holds, the count is not the gate — `0 failed` is.

- [ ] **Step 5: Confirm the existing suites are untouched**

```bash
for t in check-context-size config-loader extract-result loader-resolution render-template verify-delegation; do
    printf '%-22s ' "$t"; bash "skills/shared/tests/test-$t.sh" 2>&1 | tail -1
done
```
Expected: every line ends `0 failed`. Do not compare the pass counts against any number written in this plan.

- [ ] **Step 6: Verify the execute bit reached the git index and commit**

The prompts invoke `"$WATCH"` directly, not `bash "$WATCH"`. A blob committed as `100644` dies with `Permission denied` inside a background task, which is the worst place for it — this happened on the first live launch of the prototype.

```bash
chmod +x skills/shared/tests/test-watch-runs.sh
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git ls-files -s skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
```
Expected: both lines start with `100755`. If either shows `100644`, re-run `chmod +x` and `git add` before committing.

```bash
git commit -m "feat(shared): classify dispatched executors as done, failed, running, silent or missing

watch-runs.sh answers the question neither orchestrator could: is this
executor working or dead? It holds a roster of engine[/provider/model]
rather than run dirs, because an executor that dies and self-retries
creates a NEW dir and a fixed list would report the live retry dead --
observed four times on 2026-07-27. Freshness is the newest mtime across
raw.jsonl, log.jsonl, watchdog.log and attempt-*/raw.jsonl, so a
supervised run between watchdog retries reads as RUN on its heartbeat.

DONE additionally requires a non-empty output.txt and a zero watchdog exit
code: cleanup is written on every watchdog exit including bail, and 40 of
286 archived runs carry it with nothing to read.

Claude-Session: https://claude.ai/code/session_01PVPdxWYfArCZeArpSJkiMY"
```

---

### Task 2: `watch-runs.sh` — the polling loop

**Files:**
- Modify: `skills/shared/watch-runs.sh` (replace the trailing evaluation block from Task 1 Step 3)
- Test: `skills/shared/tests/test-watch-runs.sh` (append)

**Interfaces:**
- Consumes: `evaluate`, `transitions`, `all_done`, `any_run`, `any_moved`, `emit`, and the variables `NOW`, `DEADLINE`, `POLL_SEC`, `ONCE` from Task 1.
- Produces: blocking behaviour. Without `--once` the script sleeps `--poll-sec` between evaluations and returns on the first evaluation where anything is not `RUN`, or on the deadline. `SNAPSHOT` becomes reachable only under `--once`. No reason string changes.

- [ ] **Step 1: Write the failing tests**

Append to `skills/shared/tests/test-watch-runs.sh`, **before** the closing summary block:

```bash
# The deadline is computed inside the script as --since + global_sec + margin, so these tests
# steer it by choosing --since. global_sec comes from the real config; read it the same way.
GS="$(bash "$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.global_sec // empty' 2>/dev/null)"
[[ "$GS" =~ ^[1-9][0-9]*$ ]] || GS=3600
MARGIN=300

if [ "$GS" -gt 80000 ]; then
    FAIL=$((FAIL+1))
    echo "  FAIL: runtime.timeouts.global_sec=$GS leaves no room inside the --since plausibility window; Tests 25-27 cannot run"
else

# === Test 25: the watcher blocks while everything is RUN, and returns when one goes silent ===
# The 2026-07-26 blind spot: nothing finishes, so a count-based watcher never wakes. There is no
# race with the baseline here — the baseline is virtual, so a change landing before the first
# evaluation is reported just the same.
echo "=== Test 25: a run going quiet wakes the watcher ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
b=$(mk_run "$TDIR" ext-claude/ollama/kimi -60); : > "$b/raw.jsonl"
( sleep 2; touch -d '660 seconds ago' "$b/raw.jsonl" "$b" ) &
TOUCHER=$!
START=$(date +%s)
OUT="$(timeout 30 bash "$SCRIPT" --since "$SINCE_OK" --stall-sec 600 --poll-sec 1 \
        --data-dir "$TDIR" codex ext-claude/ollama/kimi 2>"$ERRF")"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
wait "$TOUCHER" 2>/dev/null
REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason names the death" "CHANGED ext-claude/ollama/kimi RUN→SILENT" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_match "codex row still RUN" "RUN" "$(row codex)"
assert_between "it waited for the change" 1 20 "$ELAPSED"
rm -rf "$TDIR"

# === Test 26: an expired budget reports DEADLINE ===
echo "=== Test 26: an expired budget reports DEADLINE ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
run --since "$(( NOW - GS - MARGIN - 100 ))" --stall-sec 600 --poll-sec 1 --data-dir "$TDIR" codex
assert_eq "reason DEADLINE" "DEADLINE" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test 27: the watcher really blocks rather than returning at once ===
echo "=== Test 27: the watcher blocks until its deadline ==="
TDIR=$(mktemp -d)
a=$(mk_run "$TDIR" codex -60); : > "$a/raw.jsonl"
# NOW was stamped when the suite started and the suite takes seconds to get here; a deadline
# eight seconds past a stale NOW is already behind us. Re-read the clock.
printf -v T27_NOW '%(%s)T' -1
START=$(date +%s)
OUT="$(timeout 40 bash "$SCRIPT" --since "$(( T27_NOW - GS - MARGIN + 8 ))" --stall-sec 600 \
        --poll-sec 1 --data-dir "$TDIR" codex 2>"$ERRF")"
RC=$?
ELAPSED=$(( $(date +%s) - START ))
REASON="$(printf '%s\n' "$OUT" | head -1)"
assert_eq "reason DEADLINE" "DEADLINE" "$REASON"
assert_eq "exit 0" "0" "$RC"
assert_between "it blocked for roughly the remaining budget" 4 30 "$ELAPSED"
rm -rf "$TDIR"

fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash skills/shared/tests/test-watch-runs.sh 2>&1 | tail -20`
Expected: Tests 25 and 27 FAIL. Task 1's script evaluates once and exits, so Test 25 returns `SNAPSHOT` in under a second instead of waiting for the change, and Test 27 returns immediately instead of blocking. Test 26 already passes — an expired deadline is caught on the first evaluation either way.

- [ ] **Step 3: Replace the trailing evaluation block with the loop**

Replace these lines at the end of `watch-runs.sh`:

```bash
# Checked in this order on every evaluation: all-done, settle, deadline, change.
# Finished work outranks the budget: with the deadline first, a roster that had completed
# while the orchestrator was busy reported DEADLINE — "time ran out" over six finished runs.
evaluate
all_done && emit "ALL_DONE"
any_run || emit "SETTLED $(transitions)"
[ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE"
any_moved && emit "CHANGED $(transitions)"
emit "SNAPSHOT"
```

with:

```bash
# Same order, now on a loop: all-done, settle, deadline, change. Because the baseline is
# virtual there is no baseline-establishing pass — the first evaluation and every later one
# run identical logic, and the loop needs no "first time" flag.
while :; do
    evaluate
    all_done && emit "ALL_DONE"
    any_run || emit "SETTLED $(transitions)"
    [ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE"
    any_moved && emit "CHANGED $(transitions)"
    [ "$ONCE" = 0 ] || emit "SNAPSHOT"
    sleep "$POLL_SEC"
done
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash skills/shared/tests/test-watch-runs.sh`
Expected: `=== Summary: 61 passed, 0 failed ===` and exit 0. The suite now takes roughly 20 seconds — Tests 25 and 27 wait on real time. `0 failed` is the gate, not the count.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git commit -m "feat(shared): block until an executor stops running, then name what moved

The improvised watcher exited when the finished count grew. Death does not
grow a count, so RUN -> SILENT went unnoticed for 38 minutes. The loop now
returns as soon as any roster entry is not RUN and says which one and into
what: 'CHANGED ext-claude/ollama/kimi RUN->SILENT'.

The baseline is virtual rather than taken from the first evaluation, so a
run that was already dead when the watcher started is announced instead of
being absorbed -- otherwise every watcher restart, and one happens after
every event, would reproduce the original blindness.

Claude-Session: https://claude.ai/code/session_01PVPdxWYfArCZeArpSJkiMY"
```

---

### Task 3: Enable supervised mode for design-review executors

**Files:**
- Modify: `agents/codex-executor.md` (Optional parameters list)
- Modify: `agents/gemini-executor.md` (Optional parameters list, Output section)
- Modify: `agents/ext-claude-executor.md` (new Optional Parameters section, and the `=` mention at line 29)
- Modify: `skills/mesh-design-review/SKILL.md` (Step 6 dispatch templates)
- Modify: `config.example.yaml` (the `stall_sec` comment)

**Interfaces:**
- Consumes: nothing from Tasks 1–2.
- Produces: design-review executor runs carry `SUPERVISED_MODE: shell`, so `shared/watchdog.sh` runs and those run dirs gain `watchdog.log`, `attempt-N/` and a `final` symlink. Task 4's watch text depends on `watchdog.log` existing for design-review runs; Task 5's content gate depends on the watchdog being the retry layer.

These are prompt files, not code. There is no unit test; verification is by `grep` and by reading.

- [ ] **Step 1: Document `SUPERVISED_MODE` in `agents/codex-executor.md`**

After the `REASONING_LEVEL` bullet in the "Optional parameters" list, add:

```markdown
- **SUPERVISED_MODE** — `none` (default) or `shell`. Forward it to the skill as a named parameter; it is NOT part of `PROMPT`. `shell` wraps the codex run in `shared/watchdog.sh`, which restarts the CLI on a stall or a torn stream and writes a `watchdog.log` the caller can watch for liveness. Orchestrated runs (`/mesh-design-review`) pass `shell`; a one-off interactive run leaves it unset, which keeps the live `progress-monitor.sh` output.
```

- [ ] **Step 2: Document `SUPERVISED_MODE` in `agents/gemini-executor.md`**

After the `APPROVAL_MODE` bullet in the "Optional parameters" list, add:

```markdown
- **SUPERVISED_MODE** — `none` (default) or `shell`. Forward it to the skill as a named parameter; it is NOT part of `PROMPT`. `shell` wraps the gemini run in `shared/watchdog.sh`, which restarts the CLI on a stall or a torn stream and writes a `watchdog.log` the caller can watch for liveness. Orchestrated runs (`/mesh-design-review`) pass `shell`; a one-off interactive run leaves it unset, which keeps the live `progress-monitor.sh` output.
```

- [ ] **Step 3: Fix the gemini artifact list, which supervised mode makes wrong**

`agents/codex-executor.md:44` already carries this caveat; gemini does not, and Task 3 is what makes it matter. In `agents/gemini-executor.md`, in the `## Output` section, change:

```markdown
- Files inside: `prompt.md`, `log.jsonl`, `output.txt`, `report.md`, `stderr.txt`
```

to:

```markdown
- Files inside: `prompt.md`, `log.jsonl`, `output.txt`, `report.md`, `stderr.txt` (supervised mode writes `raw.jsonl` instead of `log.jsonl`)
```

- [ ] **Step 4: Add an Optional Parameters section to `agents/ext-claude-executor.md`**

Insert between the "CRITICAL: You MUST Use the Skill Tool" section and the "PROHIBITIONS" section:

```markdown
## Optional Parameters

Recognise these on their own lines and pass each to the skill as a named parameter.
They are NOT part of `PROMPT`.

- **TASK_NAME** — short identifier for log files (default: "task")
- **SUPERVISED_MODE** — `none` (default) or `shell`. `shell` wraps the `claude -p` run in `shared/watchdog.sh`, which restarts the CLI on a stall or a torn stream and writes a `watchdog.log` the caller can watch for liveness. Orchestrated runs (`/mesh-design-review`) pass `shell`; a one-off interactive run leaves it unset, which keeps the live `progress-monitor.sh` output.
```

- [ ] **Step 5: Remove the contradicting `=` syntax from the same file**

`agents/ext-claude-executor.md:29` spells these parameters with `=` while the dispatch templates and Step 4 above use `: `. Leaving both would put two contradictory syntaxes for one parameter in one file — the exact confusion documenting the parameter is meant to prevent. Change:

```markdown
Once MODEL is parsed, invoke `ext-claude-exec` via the Skill tool. The rest of the
prompt (after `MODEL=...` and any optional `TASK_NAME=...`, `SUPERVISED_MODE=...`)
goes to `PROMPT`.
```

to:

```markdown
Once MODEL is parsed, invoke `ext-claude-exec` via the Skill tool. The rest of the
prompt — everything after the `MODEL=` line and after any of the named parameters
listed below — goes to `PROMPT`.
```

- [ ] **Step 6: Add `SUPERVISED_MODE: shell` to the Step 6 dispatch templates**

In `skills/mesh-design-review/SKILL.md`, change the codex / gemini template intro and body from:

```
**codex / gemini executors** parse `PROMPT` / `MODEL` / `REASONING_LEVEL` as named params (any line), so use the wrapped form:
```
```
Task tool:
  subagent_type: [claude-mesh:<executor>]
  description: "Design review via [agent-name] (iter N)"
  prompt: "Execute this prompt via [tool]:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    [agent-specific params]"
```

to:

```
**codex / gemini executors** parse `PROMPT` / `MODEL` / `REASONING_LEVEL` / `SUPERVISED_MODE` as named params (any line), so use the wrapped form:
```
```
Task tool:
  subagent_type: [claude-mesh:<executor>]
  description: "Design review via [agent-name] (iter N)"
  prompt: "Execute this prompt via [tool]:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell
    [agent-specific params]"
```

And in the ext-claude template, change:

```
  prompt: "MODEL=<id>
    Execute this prompt via ext-claude-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N"
```

to:

```
  prompt: "MODEL=<id>
    Execute this prompt via ext-claude-exec:
    PROMPT: [composed prompt with PREVIOUS_DECISIONS]
    TASK_NAME: design-review-[TOPIC]-iter-N
    SUPERVISED_MODE: shell"
```

- [ ] **Step 7: Explain why, right at the dispatch site**

Immediately after the "Agent-specific parameters" bullet list (after the `ext-claude-executor` bullet, before the "Collect output paths" paragraph), insert:

```markdown
**Every executor template carries `SUPERVISED_MODE: shell` — never drop it.** Without it the `*-exec` skills default to `none`, which means no `shared/watchdog.sh`: no stall detection, no restart when a provider tears the stream mid-response, and no `watchdog.log` — the file whose `cleanup` event tells the watch loop below that a run has stopped, and whose `alive` heartbeat tells it the run is still alive. Design review never set this until 2026-07-27, so supervision was a coin flip: 42 of 223 archived runs got a watchdog, against 242 of 255 on the `/mesh-review` path where it is hardcoded. On 2026-07-26 none of six did, four executors died mid-stream, and nothing noticed for 38 minutes. On 2026-07-27 four of five died again and only recovered because the executor agents improvised their own retries.
```

- [ ] **Step 8: Update the `stall_sec` comment in `config.example.yaml`**

Change:

```yaml
    stall_sec: 600                             # supervised mode: no output for this long → kill + retry. default 600
```

to:

```yaml
    stall_sec: 600                             # no output for this long → supervised mode kills and retries;
                                               #   the /mesh-review and /mesh-design-review watcher
                                               #   (shared/watch-runs.sh) reports the run SILENT. default 600.
                                               #   The watcher floors this at 600: codex-exec and gemini-exec
                                               #   hardcode HARD_ZERO_TIMEOUT=600 and ignore this key, so a
                                               #   lower value would call a live run silent before its own
                                               #   watchdog acts on it.
```

- [ ] **Step 9: Verify mechanically**

```bash
grep -c 'SUPERVISED_MODE: shell' skills/mesh-design-review/SKILL.md
grep -l 'SUPERVISED_MODE' agents/codex-executor.md agents/gemini-executor.md agents/ext-claude-executor.md
grep -c 'SUPERVISED_MODE=' agents/ext-claude-executor.md
grep -n 'watch-runs.sh' config.example.yaml
```
Expected: **`3`** for the first — two template lines plus the explanatory paragraph from Step 7, which contains the same literal. (A previous draft of this plan expected `2` and would have sent the implementer hunting for a defect in correct work.) All three agent files listed by the second; `0` for the third, since Step 5 removed the last `=` spelling; one hit for the fourth.

- [ ] **Step 10: Commit**

```bash
git add agents/codex-executor.md agents/gemini-executor.md agents/ext-claude-executor.md \
        skills/mesh-design-review/SKILL.md config.example.yaml
git commit -m "fix(mesh-design-review): supervise executor runs instead of leaving it to chance

Step 6 asserted that each executor launches a watchdog, but never passed
SUPERVISED_MODE, so the *-exec skills defaulted to none. Whether a run got
stall detection, auto-retry and a watchdog.log was luck: 42 of 223 archived
design-review runs had one, against 242 of 255 for /mesh-review where the
mode is hardcoded. codex-executor and gemini-executor did not document the
parameter at all, so the dispatch line would have leaked into PROMPT.

Also fixed while here: gemini-executor promised log.jsonl, which supervised
mode does not write, and ext-claude-executor spelled the same parameters
with = while every template uses ':'.

Claude-Session: https://claude.ai/code/session_01PVPdxWYfArCZeArpSJkiMY"
```

---

### Task 4: Route both orchestrators through `watch-runs.sh`

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (Step 6 watch block, points 2 and 4)
- Modify: `commands/mesh-review.md` (Step 5a watch block, points 2 and 4)
- Modify: `skills/shared/tests/test-loader-resolution.sh` (canary counts)

**Interfaces:**
- Consumes: `watch-runs.sh` and its reason strings from Tasks 1–2; the `watchdog.log` that Task 3 makes design-review runs produce.
- Produces: point 3 of the design-review block stays as it is here — Task 5 replaces it.

Both prompt files are prompts. Verification is by `grep`, by the canary test, and by reading the two blocks side by side.

- [ ] **Step 1: Replace point 2 of the watch block in `skills/mesh-design-review/SKILL.md`**

Replace this line:

```
2. Poll the disk via Bash — as a background Bash task (a background watcher that exits on each state change re-invokes the orchestrator per event; a foreground poll loop would block the session). ~30–60 s cadence; bound the whole watch by `runtime.timeouts.global_sec` (read it via `"$LOADER" get-runtime | jq -r '.timeouts.global_sec'`, default 3600) plus a margin. A run is finalized when: root `output.txt` is present and non-empty (gemini-exec pre-creates a zero-byte `output.txt` at launch — an empty file is NOT finalization), or a `final` symlink exists, or the run's `watchdog.log` has a `cleanup` event.
```

with:

````
2. Watch the disk with `shared/watch-runs.sh`, launched as a **background** Bash task — a foreground poll loop would block the session, and a background watcher that returns on each event re-invokes you per event. **Do NOT hand-roll a poller.** The one improvised here exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

   ```bash
   SKILL_BASE="<the absolute path Claude Code printed when this skill loaded>"
   WATCH="$SKILL_BASE/../shared/watch-runs.sh"
   [ -x "$WATCH" ] || { echo "watch-runs.sh missing or not executable at $WATCH" >&2; exit 1; }
   "$WATCH" --since 1769515472 codex gemini ext-claude/zai/glm
   ```

   Substitute the **actual** `DISPATCH_EPOCH` number you stamped above. A shell variable does not survive from one Bash call to the next, and an unset name in a prompt raises nothing at all — the script rejects an implausible `--since` rather than silently watching a window that ended in 1970.

   The arguments after the options are a **roster** of `engine[/provider/model]` — the subpath under `runs/` — not run directories. An executor that dies and self-retries creates a new run dir, so the watcher re-resolves the newest one at/after `--since` on every tick and follows the retry by itself. Pass only the executors you are still waiting for (point 5).

   | Status | Meaning |
   |---|---|
   | `DONE` | finished, and there is a non-empty `output.txt` to read |
   | `FAILED` | finished without usable output — the watchdog exited non-zero, or nothing was produced |
   | `RUN` | still producing, or still starting up |
   | `SILENT` | nothing written to any stream for longer than the stall threshold |
   | `MISSING` | no run dir for this executor at all |

   The reason line names what moved — `CHANGED ext-claude/ollama/kimi RUN→SILENT`. Terminal verdicts are `ALL_DONE`, `SETTLED` (nothing left running) and `DEADLINE` (the watch budget expired); those three end the loop. **Every verdict exits 0.** A non-zero exit means the watcher itself is broken, never that an executor died.
````

- [ ] **Step 2: Replace point 4 of the same block in `skills/mesh-design-review/SKILL.md`**

Replace this line:

```
4. Repeat until every dispatched executor has reported or the watch budget expires; treat a still-silent executor as failed per Error Handling ("One agent fails, others succeed") — never interpret silence as "no findings". This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it.
```

with:

```
4. **A `SILENT`, `FAILED` or `MISSING` run is a dead executor** — treat it per Error Handling ("One agent fails, others succeed"): note the failure in the merged file, omit its section, continue with the rest. Do **not** re-dispatch it. `watchdog.sh` already restarts the CLI up to twice inside the run, and that is this file's only retry layer, which is exactly why a third one here would just spend another budget on the same failure. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact an executor died, and the two call for different actions.
5. **Pass only the executors you are still waiting for.** The watcher assumes every roster entry is running, so an entry you have already handled comes straight back as news. If the watcher returns twice in a row with the same reason, you did not narrow the roster. Stop watching once the roster would be empty.
6. Repeat until every dispatched executor has reported, is dead, or the watch budget expires — never interpret silence as "no findings". This loop covers the codex / gemini / ext-claude executors only; claude reviewers are not part of it.

**Anything an executor says while the watch is running is a free liveness check.** Before replying to an interim status, a progress note or a question, run one `"$WATCH" --since <the same epoch> --once <current roster>` and act on the rows. On 2026-07-26 six such messages arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command. `--once` reports `CHANGED` when something has already died, so the answer names the death rather than handing you a table to compare by eye.

> Sync note: points 1–6 are mirrored in `commands/mesh-review.md` (Step 5a). The watch mechanics are identical; only the routing of a dead executor differs (there it lands in Step 6.0, which classifies it mechanically). When editing the mechanics, mirror the edit.
```

- [ ] **Step 3: Replace point 2 of the watch block in `commands/mesh-review.md`**

Replace this line:

```
2. **Poll the disk via Bash — as a background Bash task**, so "Do NOT block" above stays true (a background watcher that exits on each state change re-invokes the orchestrator per event; a foreground poll loop would hold the session hostage). ~30–60 s cadence; bound the whole watch by `runtime.timeouts.global_sec` (read it via `"$LOADER" get-runtime | jq -r '.timeouts.global_sec'`, default 3600) plus a margin. A run is finalized when: root `output.txt` is present **and non-empty** (gemini-exec pre-creates a zero-byte `output.txt` at launch — an empty file is NOT finalization), or a `final` symlink exists, or the run's `watchdog.log` has a `cleanup` event.
```

with:

````
2. **Watch the disk with `shared/watch-runs.sh`, launched as a background Bash task**, so "Do NOT block" above stays true — a foreground poll loop would hold the session hostage, and a background watcher that returns on each event re-invokes you per event. **Do NOT hand-roll a poller.** The improvised one exited only when the count of finished runs grew, and death never grows a count; that is the blind spot this script exists to close.

   ```bash
   LOADER="${CLAUDE_PLUGIN_ROOT}/skills/shared/config-loader.sh"
   [ -f "$LOADER" ] || LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
   [ -f "$LOADER" ] || { echo "config-loader.sh not found" >&2; exit 1; }
   WATCH="$(dirname "$LOADER")/watch-runs.sh"
   [ -x "$WATCH" ] || { echo "watch-runs.sh missing or not executable at $WATCH" >&2; exit 1; }
   "$WATCH" --since 1769515472 codex ext-claude/zai/glm ext-claude/ollama/kimi
   ```

   Substitute the **actual** `DISPATCH_EPOCH` number you stamped in Step 5. A shell variable does not survive from one Bash call to the next, and an unset name in a prompt raises nothing at all — the script rejects an implausible `--since` rather than silently watching a window that ended in 1970.

   The arguments after the options are a **roster** of `engine[/provider/model]` — the subpath under `runs/` — not run directories. A wrapper whose run dies and is re-run creates a new run dir, so the watcher re-resolves the newest one at/after `--since` on every tick and follows it by itself. Pass only the wrappers you are still waiting for (point 5).

   | Status | Meaning |
   |---|---|
   | `DONE` | finished, and there is a non-empty `output.txt` to read |
   | `FAILED` | finished without usable output — the watchdog exited non-zero, or nothing was produced |
   | `RUN` | still producing, or still starting up |
   | `SILENT` | nothing written to any stream for longer than the stall threshold |
   | `MISSING` | no run dir for this wrapper at all |

   The reason line names what moved — `CHANGED ext-claude/ollama/kimi RUN→SILENT`. Terminal verdicts are `ALL_DONE`, `SETTLED` (nothing left running) and `DEADLINE` (the watch budget expired); those three end the loop. **Every verdict exits 0.** A non-zero exit means the watcher itself is broken, never that a wrapper died.
````

- [ ] **Step 4: Replace point 4 of the same block in `commands/mesh-review.md`**

Replace this line:

```
4. **Repeat** until every dispatched wrapper has reported or the watch budget expires; whatever is still silent lands in Step 6.0, which classifies it mechanically. Never interpret wrapper silence as "no findings".
```

with:

```
4. **A `SILENT`, `FAILED` or `MISSING` run is dead — send it to Step 6.0**, which classifies it mechanically, rather than waiting out the budget over a run that will never change. Do **not** re-dispatch it here: `watchdog.sh` already restarts the CLI up to twice inside the run, and Step 6.0 owns the wrapper-level retry via `max_redispatch`. Report what you actually observed: "ext-claude ollama/kimi silent for 612s, last write 14:40:43". Never call a death `WATCH_TIMEOUT`; that claims time ran out when in fact a wrapper died, and the two call for different actions.
5. **Pass only the wrappers you are still waiting for.** The watcher assumes every roster entry is running, so an entry you have already handled comes straight back as news. If the watcher returns twice in a row with the same reason, you did not narrow the roster. Stop watching once the roster would be empty.
6. **Repeat** until every dispatched wrapper has reported, is dead, or the watch budget expires; whatever is still silent lands in Step 6.0. Never interpret wrapper silence as "no findings".

**Anything a wrapper says while the watch is running is a free liveness check.** Before replying to an interim status, a progress note or a question, run one `"$WATCH" --since <the same epoch> --once <current roster>` and act on the rows. On 2026-07-26 six such messages arrived while three executors were already dead; each was answered with "expected, still waiting", and not one triggered a check that would have taken a single command. `--once` reports `CHANGED` when something has already died, so the answer names the death rather than handing you a table to compare by eye.

> Sync note: points 1–6 are mirrored in `skills/mesh-design-review/SKILL.md` (Step 6). The watch mechanics are identical; only the routing of a dead wrapper differs (there it goes to Error Handling). When editing the mechanics, mirror the edit.
```

- [ ] **Step 5: Bump the loader-resolution canary**

Step 3 added a fourth verbatim loader resolver to `commands/mesh-review.md`. `skills/shared/tests/test-loader-resolution.sh` asserts the counts on purpose — its own comment says a new call site *should* break it and the numbers must be raised once the new site is checked to use the same lines. Step 3 uses all three canonical lines, including the `[ -f "$LOADER" ] || { echo …; exit 1; }` guard.

In `skills/shared/tests/test-loader-resolution.sh`, change:

```bash
assert_eq "5 primary lines across commands/" "5" "$n_primary"
assert_eq "5 fallback lines across commands/" "5" "$n_fallback"
assert_eq "mesh-review.md carries 3" "3" "$(grep -Fxc "$PRIMARY" "$CMD_DIR/mesh-review.md")"
```

to:

```bash
assert_eq "6 primary lines across commands/" "6" "$n_primary"
assert_eq "6 fallback lines across commands/" "6" "$n_fallback"
assert_eq "mesh-review.md carries 4" "4" "$(grep -Fxc "$PRIMARY" "$CMD_DIR/mesh-review.md")"
```

And extend the comment above Test 1 with a line recording why:

```bash
# mesh-review.md went 3 -> 4 with the watch-runs.sh call site: the Step 5a watch block needs
# $WATCH, and it runs in a Bash call of its own where $LOADER from any earlier block is gone.
```

- [ ] **Step 6: Verify mechanically**

```bash
bash skills/shared/tests/test-loader-resolution.sh | tail -1
grep -c 'watch-runs.sh' skills/mesh-design-review/SKILL.md commands/mesh-review.md
grep -c 'WATCH_TIMEOUT' skills/mesh-design-review/SKILL.md commands/mesh-review.md
grep -c 'Sync note: points 1–6' skills/mesh-design-review/SKILL.md commands/mesh-review.md
grep -c 'max_redispatch\|Step 6\.0' skills/mesh-design-review/SKILL.md
```
Expected: the canary ends `0 failed`; at least 2 hits for `watch-runs.sh` in each file; exactly `1` `WATCH_TIMEOUT` in each (only the new prohibition); exactly one sync note per file; and **`0`** for the last — `max_redispatch` and `Step 6.0` must not appear in the design-review file, because neither exists there.

- [ ] **Step 7: Read both blocks side by side and confirm they agree**

```bash
sed -n '/CRITICAL — an executor.s report does NOT arrive/,/^### Step 7/p' skills/mesh-design-review/SKILL.md
sed -n '/CRITICAL — a wrapper.s report does NOT arrive/,/^## Step 5b/p' commands/mesh-review.md
```

Confirm by reading: identical status table, identical roster explanation, identical `--since` warning, identical `--once` rule, identical "every verdict exits 0" sentence. The only intended differences are the script-location idiom (`SKILL_BASE` versus the command-file resolver — the skill's own "Locating plugin files" section forbids `${CLAUDE_PLUGIN_ROOT}` inside Bash blocks) and where a dead run is routed (Error Handling versus Step 6.0).

- [ ] **Step 8: Commit**

```bash
git add skills/mesh-design-review/SKILL.md commands/mesh-review.md \
        skills/shared/tests/test-loader-resolution.sh
git commit -m "fix(mesh-review,mesh-design-review): detect dead executors, do not just wait

Both watch loops defined only finalization predicates, so a dead executor
and a slow one were indistinguishable and the only backstop was an hour of
global_sec reported as WATCH_TIMEOUT. They now call shared/watch-runs.sh
with a roster of engine[/provider/model] plus the dispatch epoch, and it
returns the moment anything stops running, naming the executor and the
transition.

The deadline arithmetic and the jq call are gone from both prompts: the
script derives the budget from --since, so the only value the orchestrator
substitutes is one integer that the script validates.

test-loader-resolution.sh goes 5/5/3 -> 6/6/4 for the new resolver site,
which is what that canary is for.

Claude-Session: https://claude.ai/code/session_01PVPdxWYfArCZeArpSJkiMY"
```

---

### Task 5: Verify content before accepting a design-review report

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (point 3 of the Step 6 watch block)

**Interfaces:**
- Consumes: the `DONE` status from Task 4's block; `DISPATCH_EPOCH`, already stamped before dispatch.
- Produces: nothing later tasks depend on.

`DONE` means "it stopped and there is a file", not "there is a review". `/mesh-review` has always closed that gap in Step 6.0 with `verify-delegation.sh`; design-review never has, and Task 4's classifier would otherwise report `DONE` for a narration draft. This is a call to an existing script — `verify-delegation.sh` is not modified.

- [ ] **Step 1: Replace point 3 of the watch block in `skills/mesh-design-review/SKILL.md`**

Replace this line:

```
3. When a run is finalized but its executor has not delivered its review — SendMessage that agent: `your external run finished — read its output.txt, extract the findings and send your report`. Ping once per finalized run — re-ping only if the executor is still silent after the next poll interval (~60–90 s).
```

with:

````
3. When a run reaches `DONE`, check that it actually produced a review **before** pinging its executor. `DONE` means the run stopped and left a non-empty `output.txt`; it does not mean the file holds findings.

   ```bash
   SKILL_BASE="<the absolute path Claude Code printed when this skill loaded>"
   VERIFY="$SKILL_BASE/../shared/verify-delegation.sh"
   bash "$VERIFY" ext-claude zai/glm 1769515472
   ```

   The three arguments are the engine, the model (`-` for codex and gemini) and the **same** `DISPATCH_EPOCH` you pass to the watcher — substitute the actual number.

   - `REAL` — SendMessage that executor: `your external run finished — read its output.txt, extract the findings and send your report`. Ping once per finalized run; re-ping only if it is still silent after the next poll interval (~60–90 s).
   - `STALLED` / `BROKEN` / `FLIP` — the run stopped without producing a usable review. Treat it as a failed executor per point 4 and do **not** ping: asking an agent to extract findings from a file that has none is how a draft becomes a review. On 2026-07-27 a torn run left a 47429-byte `output.txt` containing only the model's narration; `verify-delegation.sh` classified it `STALLED` ("no usable result event in raw.jsonl"), and only the executor's own honesty had kept it out of the merge.
````

- [ ] **Step 2: Verify mechanically**

```bash
grep -c 'verify-delegation.sh' skills/mesh-design-review/SKILL.md
git diff --stat master...HEAD -- skills/shared/verify-delegation.sh
```
Expected: at least `2` for the first (the `VERIFY=` assignment and the `bash "$VERIFY"` call); the second prints nothing, because the gate calls that script and never edits it.

- [ ] **Step 3: Confirm by reading**

Read the whole rewritten watch block top to bottom. Points 1–6 must read as one procedure: capture the roster, watch, verify-then-ping a `DONE` run, fail a dead one, narrow the roster, repeat. Confirm point 3 routes its failures to point 4 rather than inventing a second failure path.

- [ ] **Step 4: Commit**

```bash
git add skills/mesh-design-review/SKILL.md
git commit -m "fix(mesh-design-review): verify a finished run produced a review before pinging

A run that stops and leaves a non-empty output.txt is DONE to the watcher,
which is the honest limit of a liveness classifier -- it reads sizes and
mtimes, never content. On 2026-07-27 a torn run left 47429 bytes of the
model's narration and nothing else; verify-delegation.sh calls that STALLED
because raw.jsonl carries no usable result event, and /mesh-review has
gated on it since Step 6.0 existed. Design review now runs the same guard
before asking an executor to extract findings.

Claude-Session: https://claude.ai/code/session_01PVPdxWYfArCZeArpSJkiMY"
```

---

### Task 6: CHANGELOG and full verification

**Files:**
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the completed work of Tasks 1–5.
- Produces: nothing.

- [ ] **Step 1: Add an Unreleased section to `CHANGELOG.md`**

Insert directly after the `All notable changes to claude-mesh will be documented here.` line and the blank line following it, before `## [0.5.0] - 2026-07-27`:

```markdown
## [Unreleased]

### Fixed
- The `/mesh-review` and `/mesh-design-review` watch loops could not tell a slow
  executor from a dead one — both leave the same disk, and every finalization predicate
  was about a result *appearing*. The only backstop was `runtime.timeouts.global_sec`,
  an hour of blindness by default, and when it fired it reported `WATCH_TIMEOUT` rather
  than naming the death. A new `skills/shared/watch-runs.sh` classifies each dispatched
  executor as `DONE` / `FAILED` / `RUN` / `SILENT` / `MISSING` and returns as soon as any
  of them stops running, naming the executor and the transition. It holds a roster of
  `engine[/provider/model]` rather than run directories, so an executor that dies and
  self-retries into a new directory is followed instead of being reported dead. Freshness
  is the newest mtime across `raw.jsonl`, `log.jsonl`, `watchdog.log` and
  `attempt-*/raw.jsonl`, so a supervised run between watchdog retries reads as `RUN` on
  its heartbeat. Recovery is reported too — `SILENT → RUN` is a transition like any other.
  Both prompts now call the script instead of describing a poll loop in prose; the
  improvised implementation exited only when the finished count grew, which death never
  does. An executor's unprompted message is now spent on a `--once` liveness check rather
  than on an acknowledgement.
- `/mesh-design-review` never passed `SUPERVISED_MODE`, so its executors ran unsupervised
  by default: no `shared/watchdog.sh`, no stall detection, no restart on a torn provider
  stream, and no `watchdog.log`. Whether a run got a watchdog was luck — 42 of 223 archived
  runs did, against 242 of 255 on the `/mesh-review` path. Step 6 now dispatches every
  executor with `SUPERVISED_MODE: shell`, and `codex-executor` / `gemini-executor` /
  `ext-claude-executor` document the parameter so it is forwarded to the skill instead of
  leaking into the prompt.
- `/mesh-design-review` accepted an executor's report without checking that the run had
  produced one. A run that stops and leaves a non-empty `output.txt` looks finished even
  when the file holds only the model's narration. It now runs `verify-delegation.sh` — the
  guard `/mesh-review` has used since Step 6.0 existed — before asking an executor to
  extract findings.

### Configuration
- No new keys. `runtime.timeouts.stall_sec` gains a second consumer: the orchestrator's
  watcher reports a run `SILENT` past that threshold. The watcher floors it at 600, because
  `codex-exec` and `gemini-exec` hardcode `HARD_ZERO_TIMEOUT=600` and ignore the key — a
  lower value would let the watcher call a live run dead before its own watchdog acts.
```

- [ ] **Step 2: Run every test suite**

```bash
for t in watch-runs check-context-size config-loader extract-result loader-resolution render-template verify-delegation; do
    printf '%-22s ' "$t"; bash "skills/shared/tests/test-$t.sh" 2>&1 | tail -1
done
```
Expected: seven lines, every one ending `0 failed`. Compare against `0 failed` only — no pass count in this plan is a gate.

- [ ] **Step 3: Confirm nothing out of scope was touched**

```bash
git diff --stat master...HEAD -- skills/shared/verify-delegation.sh skills/shared/watchdog.sh
git diff --name-only master...HEAD
```
Expected: the first prints nothing. The second lists exactly `CHANGELOG.md`, `agents/codex-executor.md`, `agents/ext-claude-executor.md`, `agents/gemini-executor.md`, `commands/mesh-review.md`, `config.example.yaml`, `skills/mesh-design-review/SKILL.md`, `skills/shared/tests/test-loader-resolution.sh`, `skills/shared/tests/test-watch-runs.sh`, `skills/shared/watch-runs.sh`, plus the `docs/superpowers/` files — which the "Before opening a PR" step removes.

- [ ] **Step 4: Confirm the exec bits survived every commit**

```bash
git ls-files -s skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
```
Expected: both `100755`.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): record watch-loop stall detection

Claude-Session: https://claude.ai/code/session_01PVPdxWYfArCZeArpSJkiMY"
```

---

## Before opening a PR

Per the repository convention (`git log 326942d`), the plan and design documents must not
appear in the PR diff:

```bash
git rm docs/superpowers/plans/2026-07-27-watch-loop-stall-detection.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-design.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-review-merged-iter-1.md \
       docs/superpowers/specs/2026-07-27-watch-loop-stall-detection-dogfood-findings.md
git commit -m "docs: drop the design and review documents before the PR"
```

They stay reachable in this branch's history.
