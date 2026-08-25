# Flavor-neutral yq Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `claude-mesh` start and run on either flavor of `yq` — Python-yq (`kislyuk/yq`) or Go-yq v4+ (`mikefarah/yq`) — by checking what the installed binary can do instead of what it calls itself.

**Architecture:** `config-loader.sh` uses `yq` for exactly one operation — a single YAML→JSON transcode into a snapshot that every later read consumes through `jq`. The loader stops identifying the binary and instead tries the two known JSON invocations in order, accepting the first whose output `jq` can parse. Scalar semantics are then verified against the *produced snapshot*: a YAML-1.1 resolver betrays itself by turning `off/on/yes/no` into booleans. No version number and no vendor banner takes part in any decision.

**Tech Stack:** bash 4+, `jq`, `yq` (either flavor), `python3` + PyYAML (test doubles only). Shell test suites, run by hand — this repository has no CI.

**Spec:** `docs/superpowers/specs/2026-08-25-yq-flavor-neutral-design.md`

## Global Constraints

- **Load-bearing `die` substrings.** `preflight-env.sh` classifies loader failures by matching its stderr. The substrings `yq not found`, `yq cannot produce JSON` and `yq mis-resolves` are a contract between the two files. Never reword one without changing the matcher in the same commit; a toolchain `die` that no branch matches falls through to `config INVALID` and blames a `config.yaml` that was never opened.
- **The JSON validity gate is `jq .`, never `jq -e .`.** On an empty snapshot `jq -e .` returns rc=4 and `jq .` returns rc=0, and Python-yq transcodes an empty or comment-only `config.yaml` to zero bytes.
- **Never gate the scalar probe on which invocation won.** That is an identity check in disguise: a flavor whose default output is JSON wins with the first form and skips the check. Gate on a boolean appearing in the snapshot.
- **`${var:-0}` around every `jq … | length` read**, matching the guard at `config-loader.sh:151`: an empty snapshot makes `jq` print nothing, and bare arithmetic on `""` sprays bash noise before the intended `die`.
- **PATH overrides go on the individual invocation**, never exported across a suite. `test-config-loader.sh:638` calls raw `yq -r '.models[].id'` in its own harness and a global export would send it through a double.
- **No package-manager→flavor claims in documentation.** Which flavor `apt`/`brew`/`snap` deliver depends on the repositories configured, not on the distribution name. That table was wrong once already; it is deleted, not inverted.
- **Comments in `config-loader.sh` and `preflight-env.sh` are documentation.** Where a comment states something this change makes false, rewrite it in the same commit.
- **Every `preflight-env.sh` verdict exits 0.** A non-zero exit means the probe is broken, never that the environment is poor.
- **Suite runtimes:** `test-config-loader.sh` ≈ 59 s, `test-preflight-env.sh` ≈ 97 s. Neither has a test selector — run the whole file and `grep` for the section you care about. Budget the Bash timeout accordingly; these are not hangs.

---

## File Structure

| File | Responsibility |
|---|---|
| `skills/shared/tests/lib-yq-doubles.sh` *(new)* | Fake `yq` binaries and flavor discovery, shared by both suites. One responsibility, sourced by two callers — the alternative is three shell-script factories duplicated across two 60 KB files. |
| `skills/shared/tests/fixtures/valid-claude-models-level-off.yaml` *(new)* | The only fixture whose scalars diverge between YAML 1.1 and YAML 1.2 core. Nothing else in `fixtures/` contains `off`/`on`/`yes`/`no` as a value, so without it the scalar probe can never be triggered from the preflight suite. |
| `skills/shared/config-loader.sh` | `require_yq` becomes a presence check; `yq_to_json` and `yq_probe` are added; the transcode call site gains the scalar gate and the toolchain-versus-config split. |
| `skills/shared/preflight-env.sh` | Verdict routing for the two new toolchain `die`s; flavor-neutral hint; OK rows for `yq`/`jq`; three comment blocks rewritten. |
| `skills/shared/tests/test-config-loader.sh` | Tests 52-55 and one new assertion helper. |
| `skills/shared/tests/test-preflight-env.sh` | The Go-yq scenario flips to OK; two new toolchain scenarios; hint wording; OK-row assertions. |
| `README.md`, `skills/ext-claude-exec/SKILL.md`, `CHANGELOG.md` | The user-facing dependency contract. |
| `docs/superpowers/verification/2026-08-25-yq-both-flavors.sh` *(new)* | Runs both suites once per flavor present on the machine. Working artifact; removed with the rest of `docs/superpowers/` before the PR. |

---

## Task 1: Test doubles and the flavor-neutral transcode

✅ Done — see commit(s): `5076a4c`

Full task text preserved in git history (plan commit `3bf05ec`). The extracted brief also survives at
`.superpowers/sdd/2026-08-25-yq-flavor-neutral/task-1-brief.md`.

---

## Task 2: The scalar probe, and naming the toolchain instead of the config

✅ Done — see commit(s): `08c7bed`, `a588bd2`, `3ed62b3`

Full task text preserved in git history (plan commit `3bf05ec`). The extracted brief also survives at
`.superpowers/sdd/2026-08-25-yq-flavor-neutral/task-2-brief.md`.

---

## Task 3: Preflight says which yq is in play

Deliverable: the probe's table names the `yq` and `jq` it found, so the next toolchain problem is diagnosable from the table a fresh session prints.

**Files:**
- Modify: `skills/shared/preflight-env.sh:152-165` (`toolchain_row`)
- Modify: `skills/shared/tests/test-preflight-env.sh` (assertions on the happy path)

**Interfaces:**
- Consumes: `row <name> <status> <detail>` (`preflight-env.sh:49`), `field <name> <output>` (test helper).
- Produces: an `OK` row for `yq` and for `jq` on every run where the tool is present.

- [ ] **Step 1: Write the failing assertions**

In `skills/shared/tests/test-preflight-env.sh`, immediately after the Go-yq scenario added in Task 1, add a scenario with no toolchain override at all:

```bash
# toolchain_row used to print nothing at all on success, so the table said nothing about which
# yq was in play. With both flavors accepted that is a real variable — it decides the transcode
# form and the loader's speed — and "what can actually be used here" is the question this probe
# exists to answer.
run_probe valid-claude-models.yaml
assert_eq "a usable yq gets its own OK row"  OK  "$(field yq "$OUT")"
assert_eq "…and so does jq"                  OK  "$(field jq "$OUT")"
# Not assert_match on the banner: a real one carries parentheses and slashes, and the row must
# be proved NON-EMPTY rather than proved to contain the word "yq", which its own name supplies.
YQ_ROW_DETAIL="$(awk '$1=="yq"{ $1=""; $2=""; sub(/^ +/,""); print; exit }' <<<"$OUT")"
if [ -n "$YQ_ROW_DETAIL" ]; then
    PASS=$((PASS+1)); echo "  PASS: the yq row carries a version banner ($YQ_ROW_DETAIL)"
else
    FAIL=$((FAIL+1)); echo "  FAIL: the yq row has no detail column"
fi
```

- [ ] **Step 2: Run and watch it fail**

Run: `bash skills/shared/tests/test-preflight-env.sh 2>&1 | grep -E "OK row|so does jq"`
Expected: FAIL — `expected 'OK', got ''` (no row is printed).

- [ ] **Step 3: Print the OK row**

In `skills/shared/preflight-env.sh`, replace the early return in `toolchain_row` (`[ -n "$gap" ] || return 0`) with:

```bash
    if [ -z "$gap" ]; then
        # Present and usable: say WHICH one. Both yq flavors are accepted now, and which is
        # installed changes the transcode form and the loader's speed, so a silent success
        # leaves the reading session guessing. The banner comes from $bin, matching this
        # function's contract that the override governs what THIS script checks. The row does
        # NOT name the working invocation: deriving that would duplicate the loader's decision,
        # and re-deriving a verdict made elsewhere is exactly what this file forbids.
        row "$canon" OK "$("$bin" --version 2>&1 | head -1)"
        return 0
    fi
```

- [ ] **Step 4: Run the preflight suite**

Run: `bash skills/shared/tests/test-preflight-env.sh 2>&1 | tail -3`
Expected: `=== Summary: N passed, 0 failed ===`

- [ ] **Step 5: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh
git commit -m "feat(preflight): name the yq and jq the loader will use

toolchain_row printed nothing on success, so a table a fresh session is told
to print verbatim said nothing about which yq was in play. With both flavors
accepted that is a variable worth reporting.

Claude-Session: https://claude.ai/code/session_015gyjW55gtc8ER5wMj1a9mz"
```

---

## Task 4: The user-facing dependency contract

Deliverable: documentation states what is actually required, with no package-manager→flavor claims.

**Files:**
- Modify: `README.md:128`, `:136-137`, `:139`, `:180-181`
- Modify: `skills/ext-claude-exec/SKILL.md:415`
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section directly under the intro line)

**Interfaces:**
- Consumes: the `die` wordings introduced in Tasks 1-2 — the troubleshooting rows are keyed to them.
- Produces: nothing other tasks read.

- [ ] **Step 1: Rewrite the Dependencies row (`README.md:128`)**

```markdown
- `yq` — **either flavor**: Python-yq (`kislyuk/yq`) or Go-yq v4+ (`mikefarah/yq`). `config-loader.sh` does not identify the binary: it runs the transcode, keeps whichever invocation produced JSON, and — when the config contains a value that could have been mis-resolved — checks that `off`/`on`/`yes`/`no` came through as strings before trusting it. A `yq` that can do neither is refused by name, and your `config.yaml` is not blamed for it.
```

- [ ] **Step 2: Rewrite the install commands (`README.md:136-137`)**

```markdown
Install missing tools:
- Ubuntu/Debian: `apt install jq bc curl python3`
- macOS: `brew install jq bash coreutils util-linux findutils`

Plus a `yq`, installed however your platform provides one. If your package manager has none, or ships one older than v4, `pipx install yq` works everywhere (that is Python-yq, and it needs `pipx`).
```

- [ ] **Step 3: Delete the "Important" flavor paragraph (`README.md:139`)**

Remove it outright. What was useful in it — which flavors work and what happens when one does not — now lives in the Dependencies row. The package-manager→flavor table goes with it: which flavor `apt`, `brew` or `snap` deliver depends on the repositories configured, not on the distribution name.

- [ ] **Step 4: Rewrite the troubleshooting rows (`README.md:180-181`)**

```markdown
| `yq: command not found` | Install either flavor — `pipx install yq` (Python-yq) or `apt install yq` / `brew install yq` (Go-yq v4+) |
| `yq cannot produce JSON` | The `yq` on PATH answers neither `yq .` nor `yq -o=json .` with JSON — it is too old, or not a `yq` at all. Install one of the two flavors above |
| `yq mis-resolves YAML scalars` | The `yq` on PATH resolves YAML 1.1, turning `off`/`yes` into booleans. Upgrade it, or install one of the two flavors above |
```

- [ ] **Step 5: Rewrite `skills/ext-claude-exec/SKILL.md:415`**

```markdown
| `yq not found` | Install either flavor: `pipx install yq` (Python-yq) or `apt install yq` / `brew install yq` (Go-yq v4+) |
```

- [ ] **Step 6: Add the CHANGELOG entry**

Insert directly after the `All notable changes to claude-mesh will be documented here.` line — `chore(release):` renames `[Unreleased]` to a version later, which is why no version number appears here:

```markdown
## [Unreleased]

### Requirements
- `yq` may now be **either flavor**: Python-yq (`kislyuk/yq`) or Go-yq v4+ (`mikefarah/yq`).
  The loader no longer identifies the binary — it runs the transcode, keeps whichever
  invocation produced JSON, and verifies scalar resolution when the config contains something
  that could have been mis-resolved. `pipx install yq` stops being the only supported route.
  README's package-manager→flavor table is deleted rather than inverted: which flavor a package
  manager delivers depends on the repositories configured, not on the distribution name.

### Fixed
- claude-mesh could not start at all where `yq` is Go-yq — which is what `apt install yq`,
  `brew install yq` and recent `snap install yq` deliver. `config-loader.sh` refused it on
  sight, and since it died before opening `config.yaml`, `preflight-env.sh` reported
  `config UNKNOWN` and `SUMMARY available: —`: not one reviewer selectable, not even the
  built-in `claude`. The plugin uses `yq` for exactly one operation, a single YAML→JSON
  transcode, so the incompatibility was never the DSL the rejection cited — Go-yq simply needs
  `-o=json` to print JSON.
- Every transcode failure used to be reported as a broken `config.yaml`. A `yq` that cannot
  emit JSON now says so, and only a genuinely malformed file is sent back to the user as one.
  This also covers the flavors the old string matcher never recognised: it keyed on the
  `mikefarah` URL or the literal `version v`, and anything else passed the check and then died
  blaming the config.
- A `yq` that resolves scalars per YAML 1.1 used to surface as `codex.reasoning_level: must be
  a string (got boolean) — quote it`, telling the user to fix a value that was already correct.
  It is now named as what it is.
```

- [ ] **Step 7: Check no stale claim survives**

Run: `grep -rn "Go-yq.*REJECT\|incompatible DSL\|flavor mismatch\|Python-yq.*ONLY" README.md skills/ext-claude-exec/SKILL.md`
Expected: no output. The scan is limited to the two documentation files this task owns, and deliberately so: `skills/shared/tests/` legitimately contains those phrases inside assertions (`assert_no_match … "flavor mismatch"`), and the CHANGELOG entry narrates the old behaviour on purpose. Widening the scan turns both into false positives.

- [ ] **Step 8: Commit**

```bash
git add README.md skills/ext-claude-exec/SKILL.md CHANGELOG.md
git commit -m "docs: both yq flavors are supported

The package-manager to flavor table is deleted rather than inverted: which
flavor apt/brew/snap deliver depends on the repositories configured, not on
the distribution name, and that table was already wrong once.

Claude-Session: https://claude.ai/code/session_015gyjW55gtc8ER5wMj1a9mz"
```

---

## Task 5: Verification under both flavors

Deliverable: recorded evidence that both suites pass under each `yq` present on the machine, and an explicit statement of what was not covered.

**Files:**
- Create: `docs/superpowers/verification/2026-08-25-yq-both-flavors.sh`

**Interfaces:**
- Consumes: `find_real_go_yq` from `skills/shared/tests/lib-yq-doubles.sh`.
- Produces: nothing the code reads — this is an acceptance artifact.

- [ ] **Step 1: Write the runner**

Create `docs/superpowers/verification/2026-08-25-yq-both-flavors.sh`:

```bash
#!/usr/bin/env bash
# Runs both shell suites once per yq flavor installed on this machine.
#
# The suites resolve bare `yq` from PATH, so pointing PATH at one flavor at a time is the whole
# mechanism — no new test machinery, only time (about 156 s per pass). What this cannot do is
# invent a flavor the machine does not have: when only one is installed it says so instead of
# reporting a pass it did not earn.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
. "$ROOT/skills/shared/tests/lib-yq-doubles.sh"

run_pass() {            # run_pass <label> <dir-holding-that-yq>
    local label="$1" dir="$2" rc=0
    echo "########## $label ($dir/yq: $("$dir/yq" --version 2>&1 | head -1)) ##########"
    for suite in test-config-loader.sh test-preflight-env.sh; do
        echo "--- $suite ---"
        # PIPESTATUS, not `|| rc=1`: after a pipe the shell reports `tail`'s status, which is 0
        # almost always, so a failing suite would be recorded as a pass by the very artifact
        # whose job is to prove it passed.
        PATH="$dir:$PATH" bash "$ROOT/skills/shared/tests/$suite" | tail -3
        [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
    done
    return $rc
}

FAILED=0
PY_YQ="$(command -v yq)"
run_pass "pass 1: yq as PATH resolves it" "$(dirname "$PY_YQ")" || FAILED=1

if GO_YQ="$(find_real_go_yq)" && [ "$GO_YQ" != "$PY_YQ" ]; then
    run_pass "pass 2: real Go-yq" "$(dirname "$GO_YQ")" || FAILED=1
else
    echo "########## SKIPPED: no second flavor on this machine ##########"
    echo "The mikefarah path was exercised only against the doubles in lib-yq-doubles.sh."
fi

echo "########## FAILED=$FAILED ##########"
exit "$FAILED"
```

- [ ] **Step 2: Run it**

Run: `bash docs/superpowers/verification/2026-08-25-yq-both-flavors.sh 2>&1 | tail -25`
Expected: a `Summary: N passed, 0 failed` line from each suite in each pass, and `FAILED=0`. If pass 2 is skipped, the skip line must be visible in the output — a silent single-flavor run is the failure this artifact exists to prevent.

- [ ] **Step 3: Confirm the timing claim from the spec**

Run: `time (for i in 1 2 3 4 5; do bash skills/shared/config-loader.sh list-models >/dev/null 2>&1; done)`
Expected: roughly 0.6 s total (about 120 ms per call) under Python-yq, down from about 480 ms per call before this change. A figure at or above the old one means the `yq --version` call was not actually removed from the hot path, or the scalar probe is running on a config that holds no booleans.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/verification/2026-08-25-yq-both-flavors.sh
git commit -m "test: verification runner for both yq flavors

Claude-Session: https://claude.ai/code/session_015gyjW55gtc8ER5wMj1a9mz"
```

---

## Task 6: Drop the working documents before the PR

Deliverable: a branch whose diff against `master` contains only the change, with the design, plan and verification artifacts preserved in this branch's history.

**Files:**
- Delete from the index: everything under `docs/superpowers/`

- [ ] **Step 1: Confirm what is tracked there**

Run: `git ls-files docs/superpowers/`
Expected: the design doc, this plan, and the verification runner — nothing else. Files listed as untracked by `git status` were never committed and must stay untouched on disk.

- [ ] **Step 2: Remove them from the index**

```bash
git rm -r docs/superpowers/
```

This is what the previous branch did (`a8c8f37`): a plain deletion of the tracked files. Untracked files under the same directory are not touched by `git rm`, and the deleted documents stay reachable in this branch's history.

- [ ] **Step 3: Verify the diff is clean**

Run: `git diff --stat master...HEAD -- docs/`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git commit -m "docs: drop the design and plan documents before the PR

Claude-Session: https://claude.ai/code/session_015gyjW55gtc8ER5wMj1a9mz"
```
