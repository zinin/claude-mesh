# Session-scoped run identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a watcher or a content gate from resolving another session's run directory when two orchestrations of the same engine/model share the plugin's global data dir.

**Architecture:** Identity is ambient. `CLAUDE_CODE_SESSION_ID` is exported into every Bash tool call and inherited across the agent boundary, so the four skills that create a run directory stamp it into `<run dir>/.session_id`, and the two consumers — `watch-runs.sh` and `verify-delegation.sh` — walk their existing newest-first candidate order until they hit one that is theirs. An unstamped directory stays eligible, so nothing regresses for legacy runs, direct `*-exec` invocations, or a harness without the variable.

**Tech Stack:** bash 4.2+ (`printf '%(fmt)T'`, arrays, process substitution), GNU `stat`/`find`, markdown prompts. No new dependency, no new option, no new config key.

## Global Constraints

- **The predicate fails open.** A candidate with no `.session_id`, or an empty/unreadable one, is eligible. Fail-closed would report `MISSING` for a live unstamped run and mark a working executor dead — worse than the collision being fixed, and against this branch's governing rule: never declare a live run dead.
- **The reader with no identity does not filter at all.** Empty `CLAUDE_CODE_SESSION_ID` means today's behaviour exactly.
- **The two predicates are byte-identical in body** and each carries a comment naming the other file. They are duplicated on purpose, following the shape filter precedent (`verify-delegation.sh:88` points at `watch-runs.sh:189`); `skills/shared/` has no sourcing convention and this change does not invent one.
- **Every `watch-runs.sh` verdict still exits 0.** A non-zero exit (64) means the script itself is broken.
- **Nothing else changes:** not the interfaces of either script, not `commands/mesh-review.md`, not `skills/mesh-design-review/SKILL.md`, not the agent contracts, not `config.example.yaml`.
- **The stamp is written unconditionally.** `skills/codex-review-native/SKILL.md:115-126` is one `&&`-chained command list; a guarded `[ -n "$X" ] && printf …` evaluates false when the variable is empty and silently skips every command after it in the chain. `printf` always returns 0.
- Test files follow the existing suites: `assert_eq` / `assert_match`, `mktemp -d` fixtures, and a closing `=== Summary: $PASS passed, $FAIL failed ===` with `[ "$FAIL" = "0" ]`.
- **Assert `0 failed`, never a hardcoded pass count.**
- CHANGELOG entries go under `## [Unreleased]`.

## File Structure

| File | Responsibility |
|---|---|
| `skills/shared/watch-runs.sh` | `SELF_SID` global + `run_is_mine()`; `resolve_run_dir` walks candidates newest-first and takes the first that is ours. |
| `skills/shared/verify-delegation.sh` | The same predicate; the candidate pipeline stops at the first acceptable name instead of `head -1`. |
| `skills/{codex,gemini,ext-claude}-exec/SKILL.md`, `skills/codex-review-native/SKILL.md` | One line each: stamp `$CLAUDE_CODE_SESSION_ID` into the run dir at creation. |
| `skills/shared/tests/test-watch-runs.sh` | Tests 34–39 plus two helpers (`run_as`, `sid_stamp`). |
| `skills/shared/tests/test-verify-delegation.sh` | Four tests plus a `run_as` helper. |
| `CHANGELOG.md` | `[Unreleased]` entry. |

---

### Task 1: `watch-runs.sh` — resolve only this session's runs

**Files:**
- Modify: `skills/shared/watch-runs.sh:61-67` (globals) and `:169-195` (`resolve_run_dir`)
- Test: `skills/shared/tests/test-watch-runs.sh` (helpers after `wd_log`, Tests 34–39 before the summary block)

**Interfaces:**
- Produces: global `SELF_SID` (string, possibly empty) and `run_is_mine <abs-run-dir>` → exit 0 when the directory may be selected. Task 2 mirrors both, byte-identical in body.

- [ ] **Step 1: Add the two test helpers**

In `skills/shared/tests/test-watch-runs.sh`, directly after the `wd_log()` definition (`:74`):

```bash
# run the script under an explicit session identity: <sid>, or '-' for no identity at all.
# The assignment prefixes the EXTERNAL command on purpose: `CLAUDE_CODE_SESSION_ID=x run …`
# would leak into the rest of the suite, because bash scopes a prefix assignment to a command,
# not to a function call.
run_as() {
    local sid="$1"; shift
    if [ "$sid" = "-" ]; then
        OUT="$(env -u CLAUDE_CODE_SESSION_ID timeout 10 bash "$SCRIPT" "$@" 2>"$ERRF")"; RC=$?
    else
        OUT="$(env "CLAUDE_CODE_SESSION_ID=$sid" timeout 10 bash "$SCRIPT" "$@" 2>"$ERRF")"; RC=$?
    fi
    REASON="$(printf '%s\n' "$OUT" | head -1)"; ERR="$(cat "$ERRF")"
}
# stamp a run dir with a session id; sid_stamp "$dir" '' writes the empty-stamp case
sid_stamp() { printf '%s\n' "$2" > "$1/.session_id"; }
```

- [ ] **Step 2: Append Tests 34–39**

At the end of `skills/shared/tests/test-watch-runs.sh`, immediately before the `echo ""` /
`=== Summary` block:

```bash
echo ""
echo "Test 34: a foreign-stamped newest dir is skipped for the older own-stamped one"
TDIR="$(mktemp -d)"
mine=$(mk_run "$TDIR" codex -120 100001);  sid_stamp "$mine" sid-A
theirs=$(mk_run "$TDIR" codex -60 100002); sid_stamp "$theirs" sid-B
printf 'my review'    > "$mine/output.txt";   wd_log "$mine" 0
printf 'their review' > "$theirs/output.txt"; wd_log "$theirs" 0
run_as sid-A --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "resolves the own dir" "$(basename "$mine")" "$(row codex)"
assert_eq "reason ALL_DONE" "ALL_DONE" "$REASON"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

echo ""
echo "Test 35: an unstamped dir stays eligible — legacy runs and direct *-exec calls"
TDIR="$(mktemp -d)"
old=$(mk_run "$TDIR" codex -120 100001); sid_stamp "$old" sid-A
new=$(mk_run "$TDIR" codex -60 100002)          # deliberately no .session_id
printf 'review' > "$new/output.txt"; wd_log "$new" 0
run_as sid-A --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "resolves the unstamped newest dir" "$(basename "$new")" "$(row codex)"
rm -rf "$TDIR"

echo ""
echo "Test 36: a reader with no session identity does not filter at all"
TDIR="$(mktemp -d)"
mine=$(mk_run "$TDIR" codex -120 100001);  sid_stamp "$mine" sid-A
theirs=$(mk_run "$TDIR" codex -60 100002); sid_stamp "$theirs" sid-B
printf 'their review' > "$theirs/output.txt"; wd_log "$theirs" 0
run_as - --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "newest wins regardless of stamps" "$(basename "$theirs")" "$(row codex)"
rm -rf "$TDIR"

echo ""
echo "Test 37: when every candidate belongs to another session there is no run to watch"
TDIR="$(mktemp -d)"
theirs=$(mk_run "$TDIR" codex -60 100002); sid_stamp "$theirs" sid-B
printf 'their review' > "$theirs/output.txt"; wd_log "$theirs" 0
run_as sid-A --once --since "$SINCE_OLD" --stall-sec 600 --data-dir "$TDIR" codex
assert_eq "reason names the transition" "SETTLED codex RUN→MISSING" "$REASON"
assert_match "row is MISSING" "MISSING" "$(row codex)"
rm -rf "$TDIR"

echo ""
echo "Test 38: an empty .session_id reads as unstamped (so does an unreadable one — same branch)"
TDIR="$(mktemp -d)"
a=$(mk_run "$TDIR" codex -60); sid_stamp "$a" ''
printf 'review' > "$a/output.txt"; wd_log "$a" 0
run_as sid-A --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" codex
assert_match "empty stamp is still selected" "$(basename "$a")" "$(row codex)"
rm -rf "$TDIR"

echo ""
echo "Test 39: the own retry is followed even when a foreign dir is newer than both"
TDIR="$(mktemp -d)"
dead=$(mk_run "$TDIR" gemini -280 100001);  sid_stamp "$dead" sid-A
: > "$dead/log.jsonl"; touch -d "@$(( NOW - 280 ))" "$dead/log.jsonl"
retry=$(mk_run "$TDIR" gemini -120 100002); sid_stamp "$retry" sid-A
printf 'full answer' > "$retry/output.txt"; : > "$retry/log.jsonl"; printf '# report\n' > "$retry/report.md"
theirs=$(mk_run "$TDIR" gemini -60 100003); sid_stamp "$theirs" sid-B
: > "$theirs/log.jsonl"
run_as sid-A --once --since "$SINCE_OK" --stall-sec 600 --data-dir "$TDIR" gemini
assert_match "follows the own retry" "$(basename "$retry")" "$(row gemini)"
assert_match "row is DONE" "DONE" "$(row gemini)"
rm -rf "$TDIR"
```

- [ ] **Step 3: Run the suite and confirm exactly the right three fail**

Run: `bash skills/shared/tests/test-watch-runs.sh 2>&1 | tail -30`

Expected: **5 failed**, and exactly these — the suite counts assertions, not blocks:

| Block | Failing assertions | Why |
|---|---|---|
| Test 34 | 1 — "resolves the own dir" | the foreign dir wins; it is also `DONE`, so the reason and rc assertions pass |
| Test 37 | 2 — reason and row | the foreign `DONE` run resolves, so the reason reads `ALL_DONE` |
| Test 39 | 2 — dir and status | the foreign dir wins and it is still `RUN` |

Tests 35, 36 and 38 must **pass already**: they pin the fail-open contract, which today holds
trivially because nothing filters. If any of those three fails, or if the failure count is not
5, stop — the fixture is wrong, not the implementation.

- [ ] **Step 4: Add the identity global**

In `skills/shared/watch-runs.sh`, after `ROSTER=()` (`:66`):

```bash

# Run identity. CLAUDE_CODE_SESSION_ID is exported into every Bash tool call and inherited
# across the agent boundary (verified 2026-07-28: a subagent's Bash call sees the
# orchestrator's value), so a run dir stamped by the *-exec skill at creation carries the
# session that dispatched it. Two orchestrations of one engine/model share the global data
# dir, and without this the newest dir wins even when it belongs to someone else's dispatch.
SELF_SID="${CLAUDE_CODE_SESSION_ID:-}"
```

- [ ] **Step 5: Add the predicate and rewrite the resolver**

Replace `resolve_run_dir` (`skills/shared/watch-runs.sh:172-195`) with:

```bash
# A candidate belongs to this dispatch. The body is mirrored byte-for-byte in
# verify-delegation.sh — the two must agree on which run is "the run", or the watcher reports
# DONE on one directory while the gate inspects another. FAIL-OPEN by design: an unstamped dir
# is a run from a plugin version older than this stamp, a direct *-exec invocation, or a
# harness that does not export the variable. Calling those foreign would resolve nothing and
# report MISSING for a live run — the one thing this whole feature exists not to do.
run_is_mine() {
    [ -n "$SELF_SID" ] || return 0
    local v=""
    [ -r "$1/.session_id" ] && IFS= read -r v < "$1/.session_id"
    [ -z "$v" ] || [ "$v" = "$SELF_SID" ]
}

# The newest run dir for a roster entry, at/after --since. Selection is by NAME, not mtime: on
# bail the abandoned dir gains a `final` symlink, which bumps its mtime above the retry dir's,
# and selecting by mtime would follow the corpse.
resolve_run_dir() {
    local entry="$1" base="$DATA_DIR/runs/$1" name d i
    local -a cands=()
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
        # Only timestamped run dirs are candidates. Anything else — a stray `tmp/`, or a
        # provider directory reached through a malformed entry — sorts ABOVE every timestamp
        # (letters outrank digits) and would shadow the entry not just now but for every
        # future run under it, reporting a finished review as SILENT forever.
        [[ "$name" =~ ^[0-9]{4}(-[0-9]{2}){5}- ]] || continue
        [[ "$name" < "$SINCE_STR" ]] && continue
        cands+=("$name")
    done
    # Bash expands a glob in ascending byte order (LC_ALL=C, :35), so walking the array
    # backwards is newest-first. Take the newest that is ours; reading the stamp only as far
    # as the walk goes keeps the common case at a single file read.
    for (( i=${#cands[@]}-1; i>=0; i-- )); do
        run_is_mine "$base/${cands[i]}" || continue
        RUNDIR_PATH="$base/${cands[i]}"
        return 0
    done
    return 1
}
```

- [ ] **Step 6: Run the suite and confirm it is green**

Run: `bash skills/shared/tests/test-watch-runs.sh 2>&1 | tail -12`
Expected: `=== Summary: 91 passed, 0 failed ===` (81 existing + 10 new assertions), exit 0.
Do not hardcode that number anywhere; it is a reading, not a gate.

- [ ] **Step 7: Commit**

```bash
git add skills/shared/watch-runs.sh skills/shared/tests/test-watch-runs.sh
git commit -m "fix(watch): resolve only the run dirs this session dispatched"
```

---

### Task 2: `verify-delegation.sh` — the same filter at the content gate

**Files:**
- Modify: `skills/shared/verify-delegation.sh:56` (after `resolve_plugin_data`) and `:94-97` (candidate selection)
- Test: `skills/shared/tests/test-verify-delegation.sh` (helper after `run()`, four tests before the summary block)

**Interfaces:**
- Consumes: the predicate body defined in Task 1 — identical, with the comment pointing back at `watch-runs.sh`.

- [ ] **Step 1: Add the test helper**

In `skills/shared/tests/test-verify-delegation.sh`, directly after `run()` (`:35`):

```bash
# run the script under an explicit session identity: <sid>, or '-' for no identity at all.
# The assignment prefixes the EXTERNAL command; a prefix on a function call would leak into
# the rest of the suite.
run_as() {
    local sid="$1"; shift
    if [ "$sid" = "-" ]; then
        VERDICT=$(env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" "$@" 2>/dev/null); RC=$?
    else
        VERDICT=$(env "CLAUDE_CODE_SESSION_ID=$sid" bash "$SCRIPT" "$@" 2>/dev/null); RC=$?
    fi
}
# stamp a run dir with a session id
sid_stamp() { printf '%s\n' "$2" > "$1/.session_id"; }
```

- [ ] **Step 2: Append the four tests**

At the end of `skills/shared/tests/test-verify-delegation.sh`, immediately before the summary
block:

```bash
# === Test: a foreign-stamped newest run is skipped for the older own-stamped one ===
# The gate and watch-runs.sh must agree on which run is "the run". mesh-design-review chains
# them: the watcher reports DONE, the gate then reads content. Disagreement discards a review.
echo "=== Test: run identity — the foreign newest run is not inspected ==="
TDIR=$(mktemp -d)
mine=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-mine)
echo 'real review' > "$mine/output.txt"; ln -s attempt-1 "$mine/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$mine/raw.jsonl"
sid_stamp "$mine" sid-A
theirs=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-12-00-00-1000-theirs)
sid_stamp "$theirs" sid-B                       # newer by name, killed mid-flight
run_as sid-A ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL (own run inspected)" "REAL" "$VERDICT"
assert_eq "exit 0" "0" "$RC"
rm -rf "$TDIR"

# === Test: an unstamped run stays eligible ===
echo "=== Test: run identity — an unstamped run is still inspected ==="
TDIR=$(mktemp -d)
rd=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-legacy)
echo 'real review' > "$rd/output.txt"; ln -s attempt-1 "$rd/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$rd/raw.jsonl"
run_as sid-A ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
rm -rf "$TDIR"

# === Test: a reader with no session identity does not filter ===
echo "=== Test: run identity — no reader identity means no filtering ==="
TDIR=$(mktemp -d)
theirs=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-theirs)
echo 'real review' > "$theirs/output.txt"; ln -s attempt-1 "$theirs/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$theirs/raw.jsonl"
sid_stamp "$theirs" sid-B
run_as - ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict REAL" "REAL" "$VERDICT"
rm -rf "$TDIR"

# === Test: every candidate foreign → FLIP, the same verdict as no run dir at all ===
echo "=== Test: run identity — only foreign runs present → FLIP ==="
TDIR=$(mktemp -d)
theirs=$(mk_run "$TDIR/runs/ext-claude/zai/glm" 2026-07-28-11-00-00-1000-theirs)
echo 'real review' > "$theirs/output.txt"; ln -s attempt-1 "$theirs/final"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":26}' > "$theirs/raw.jsonl"
sid_stamp "$theirs" sid-B
run_as sid-A ext-claude zai/glm 1 "$TDIR"
assert_eq "verdict FLIP" "FLIP" "$VERDICT"
assert_eq "exit 3" "3" "$RC"
rm -rf "$TDIR"
```

- [ ] **Step 3: Run the suite and confirm exactly two fail**

Run: `bash skills/shared/tests/test-verify-delegation.sh 2>&1 | tail -30`

Expected: **4 failed**, two assertions in each of two blocks:

| Block | Failing assertions | Why |
|---|---|---|
| "the foreign newest run is not inspected" | verdict and rc | the foreign dir has no `final` and no `output.txt`, so it classifies `STALLED` (rc 2) |
| "only foreign runs present → FLIP" | verdict and rc | the foreign dir classifies `REAL` (rc 0) |

The two middle blocks must pass already; they pin fail-open. Any other count means the fixture
is wrong.

- [ ] **Step 4: Add the identity global and the predicate**

In `skills/shared/verify-delegation.sh`, after the closing `}` of `resolve_plugin_data`
(`:55`) and before `ENGINE="${1:-}"`:

```bash

# Run identity. CLAUDE_CODE_SESSION_ID is exported into every Bash tool call and inherited
# across the agent boundary, so a run dir stamped by the *-exec skill carries the session that
# dispatched it. The body below is mirrored byte-for-byte in watch-runs.sh — the two must agree
# on which run is "the run", or the watcher reports DONE on one dir while this gate inspects
# another. FAIL-OPEN: an unstamped dir is a legacy run, a direct *-exec invocation, or a
# harness without the variable, and calling those foreign would drop a finished review.
SELF_SID="${CLAUDE_CODE_SESSION_ID:-}"
run_is_mine() {
    [ -n "$SELF_SID" ] || return 0
    local v=""
    [ -r "$1/.session_id" ] && IFS= read -r v < "$1/.session_id"
    [ -z "$v" ] || [ "$v" = "$SELF_SID" ]
}
```

- [ ] **Step 5: Walk the candidates instead of taking the head**

Replace `skills/shared/verify-delegation.sh:94-97` — the `NEWEST="$(find …)"` assignment, the
`[ -z "$NEWEST" ] || NEWEST="$BASE/$NEWEST"` line and the `emit FLIP` guard — with:

```bash
NEWEST=""
while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    run_is_mine "$BASE/$cand" || continue
    NEWEST="$BASE/$cand"; break
done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -newermt "@$SINCE" -printf '%f\n' 2>/dev/null |
         grep -E '^[0-9]{4}(-[0-9]{2}){5}-' | LC_ALL=C sort -r)
[ -n "$NEWEST" ] || emit FLIP "no run dir newer than dispatch time — reviewer did not delegate" 3
```

Process substitution, not a pipe: a `while` on the right of a pipe runs in a subshell and
`NEWEST` would not survive it.

- [ ] **Step 6: Run the suite and confirm it is green**

Run: `bash skills/shared/tests/test-verify-delegation.sh 2>&1 | tail -12`
Expected: `=== Summary: 68 passed, 0 failed ===` (62 existing + 6 new assertions), exit 0.

- [ ] **Step 7: Commit**

```bash
git add skills/shared/verify-delegation.sh skills/shared/tests/test-verify-delegation.sh
git commit -m "fix(gate): inspect only the run dirs this session dispatched"
```

---

### Task 3: Stamp the run directory at creation

**Files:**
- Modify: `skills/codex-exec/SKILL.md:155`, `skills/gemini-exec/SKILL.md:148`,
  `skills/ext-claude-exec/SKILL.md:152`, `skills/codex-review-native/SKILL.md:119`
- Modify: `CHANGELOG.md` (`[Unreleased]`)

**Interfaces:**
- Produces: `<run dir>/.session_id`, one line, the value of `$CLAUDE_CODE_SESSION_ID` at
  creation (an empty line when the variable is unset). Consumed by the predicate from Tasks
  1–2.

- [ ] **Step 1: Prove the line is safe in both environments before editing prompts**

The point of this check is the `&&`-chain site: a guarded form would break it. Run:

```bash
W=$(mktemp -d) && mkdir -p "$W" && \
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$W/.session_id" && \
echo "chain survived with the variable set: [$(cat "$W/.session_id")]" && \
env -u CLAUDE_CODE_SESSION_ID bash -c '
  W=$(mktemp -d) && mkdir -p "$W" && \
  printf "%s\n" "${CLAUDE_CODE_SESSION_ID:-}" > "$W/.session_id" && \
  echo "chain survived without the variable: [$(cat "$W/.session_id")]"'
```

Expected: both lines print; the second shows an empty value. If either line is missing the
chain broke and the form is wrong.

- [ ] **Step 2: Stamp in the three `*-exec` skills**

In each of `skills/codex-exec/SKILL.md`, `skills/gemini-exec/SKILL.md` and
`skills/ext-claude-exec/SKILL.md`, directly after the existing line
`echo "$TASK_NAME" > "$WORK_DIR/.task_name"`, add:

```bash
# Stamp the dispatching session. CLAUDE_CODE_SESSION_ID is inherited across the agent
# boundary, so shared/watch-runs.sh and shared/verify-delegation.sh can tell this run from one
# a concurrent orchestration started under the same engine/model in the same data dir.
# Unconditional: an empty value writes an empty line, which both readers treat as unstamped.
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$WORK_DIR/.session_id"
```

- [ ] **Step 3: Stamp in `codex-review-native`**

In `skills/codex-review-native/SKILL.md`, inside the `&&` chain, directly after
`mkdir -p "$WORK_DIR" && \` (`:119`), add — note the trailing `&& \`, which the surrounding
chain requires:

```bash
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$WORK_DIR/.session_id" && \
```

This site writes `${TIMESTAMP}-native-review-${BRANCH}` into the same `runs/codex/` namespace
and writes no `.task_name`, yet its directories pass the shape filter and compete for
selection like any other run.

- [ ] **Step 4: Verify all four sites mechanically**

```bash
grep -l 'CLAUDE_CODE_SESSION_ID' skills/*/SKILL.md
grep -c 'CLAUDE_CODE_SESSION_ID.*\.session_id' skills/*/SKILL.md | grep -v ':0'
```

Expected: exactly four files — `codex-exec`, `gemini-exec`, `ext-claude-exec`,
`codex-review-native` — with one write site each.

- [ ] **Step 5: Write the CHANGELOG entry**

Append to the `### Fixed` list under `## [Unreleased]` in `CHANGELOG.md`:

```markdown
- A watcher or content gate could resolve a run directory belonging to a different
  orchestration. Both pick the newest run dir under `runs/<engine>[/provider/model]`, and the
  plugin's data dir is global, so two `/mesh-review` or `/mesh-design-review` sessions on the
  same engine/model — in two different repositories — saw each other's runs: the earlier
  session could report `DONE`/`SILENT` about a run it never dispatched, ping its wrapper
  early, and hand `verify-delegation.sh` the wrong directory, discarding a finished review.
  The four skills that create a run dir now stamp `$CLAUDE_CODE_SESSION_ID` into
  `<run dir>/.session_id`, and both consumers walk their existing newest-first order until
  they reach a run of their own. The identity is ambient rather than passed down the dispatch:
  the variable is inherited across the agent boundary, so an executor cannot fail to forward
  it and an improvised re-run inherits it automatically. A directory with no stamp stays
  eligible — legacy runs, direct `/claude-mesh:*-exec` invocations and a harness without the
  variable must keep working, and reporting `MISSING` for a live unstamped run would be worse
  than the collision. Two orchestrations inside one session remain indistinguishable.
```

- [ ] **Step 6: Run every suite**

```bash
for t in skills/shared/tests/test-*.sh; do
  out=$(bash "$t" 2>&1); rc=$?
  printf '%-40s rc=%s  %s\n' "$(basename "$t")" "$rc" \
    "$(printf '%s\n' "$out" | grep -E '^(=== Summary|RESULTS)' | tail -1)"
done
```

Expected: seven lines, every one `rc=0` and `0 failed`.

- [ ] **Step 7: Commit**

```bash
git add skills/codex-exec/SKILL.md skills/gemini-exec/SKILL.md \
        skills/ext-claude-exec/SKILL.md skills/codex-review-native/SKILL.md CHANGELOG.md
git commit -m "fix(exec): stamp the dispatching session into every run dir"
```

---

## After the tasks

- [ ] Push; PR #9 updates and the codex bot re-reviews the new commits.
- [ ] **Manual, outside this plan:** the end-to-end check that a real run produces
      `.session_id` requires a session started with `--plugin-dir` pointing at this working
      tree — otherwise the dispatched executor reads the *installed* plugin, whose skills carry
      no stamp, and the check proves nothing. Fold it into the next dogfooding run.
- [ ] Before merging, `git rm` the documents this work added under `docs/superpowers/`
      (derive the list with `git diff --name-only 3d5c004..HEAD -- docs/superpowers/`) and
      commit.
