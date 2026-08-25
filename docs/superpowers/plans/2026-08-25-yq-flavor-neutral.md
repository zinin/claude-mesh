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

Deliverable: a machine whose `yq` is Go-yq runs the loader. Both suites green.

**Files:**
- Create: `skills/shared/tests/lib-yq-doubles.sh`
- Create: `skills/shared/tests/fixtures/valid-claude-models-level-off.yaml`
- Modify: `skills/shared/tests/test-config-loader.sh` (source the library after line 6; append Test 52)
- Modify: `skills/shared/tests/test-preflight-env.sh:215-232` (the Go-yq scenario)
- Modify: `skills/shared/config-loader.sh:60-72` (`require_yq`) and `:126-135` (the transcode)

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces:
  - `mkyq_go <dir>`, `mkyq_nojson <dir>`, `mkyq_yaml11 <dir>` — each writes an executable `yq` into `<dir>`; callers put `<dir>` first on PATH for one invocation.
  - `have_pyyaml` — rc 0 when `python3 -c 'import yaml'` succeeds.
  - `find_real_go_yq` — prints the path of a real mikefarah `yq` found anywhere on PATH, or nothing; rc 1 when there is none.
  - `yq_to_json <src_yaml> <dst_json>` — rc 0 when one of the two forms produced JSON that `jq` parsed, rc 1 otherwise. Sets no globals.

- [ ] **Step 1: Create the shared doubles library**

Create `skills/shared/tests/lib-yq-doubles.sh`:

```bash
#!/usr/bin/env bash
# Fake `yq` binaries and flavor discovery, shared by test-config-loader.sh and
# test-preflight-env.sh. Sourced, never executed.
#
# WHY A DOUBLE HAS TO REALLY TRANSCODE. config-loader.sh no longer asks a `yq` who it is; it
# asks whether the output is JSON. The Go-yq stub this file replaces answered `--version` with
# a mikefarah banner and `exit 0` to everything else — under the new loader it writes nothing,
# `jq .` accepts the empty file, the first form "succeeds" with an empty snapshot and the
# scenario passes while testing nothing at all. Identity can be faked with a banner; capability
# cannot.
#
# All three doubles are built out of the python-yq already required by both suites, so they add
# no install step.

# Resolved once, at source time. The doubles must NOT call bare `yq`: they are placed ON PATH
# under exactly that name, so a bare call would recurse into itself.
YQ_REAL="$(command -v yq)"

mkyq_go() {             # mkyq_go <dir> — Go-yq v4: bare '.' prints YAML, -o=json prints JSON
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/yq" <<SH
#!/usr/bin/env bash
[ "\$1" = --version ] && { echo "yq (https://github.com/mikefarah/yq/) version v4.44.1"; exit 0; }
if [ "\$1" = "-o=json" ]; then shift 2; exec "$YQ_REAL" '.' "\$@"; fi
shift; exec "$YQ_REAL" -y '.' "\$@"
SH
    chmod +x "$dir/yq"
}

mkyq_nojson() {         # mkyq_nojson <dir> — emits YAML whatever it is asked for
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/yq" <<SH
#!/usr/bin/env bash
[ "\$1" = --version ] && { echo "yq 0.0-nojson"; exit 0; }
if [ "\$1" = "-o=json" ]; then shift 2; else shift; fi
exec "$YQ_REAL" -y '.' "\$@"
SH
    chmod +x "$dir/yq"
}

mkyq_yaml11() {         # mkyq_yaml11 <dir> — emits JSON, but resolves scalars per YAML 1.1
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/yq" <<'SH'
#!/usr/bin/env bash
[ "$1" = --version ] && { echo "yq 1.1-flavour 0.1"; exit 0; }
if [ "$1" = "-o=json" ]; then shift 2; else shift; fi
exec python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"
SH
    chmod +x "$dir/yq"
}

have_pyyaml() { python3 -c 'import yaml' >/dev/null 2>&1; }

# Finds a REAL Go-yq anywhere on PATH, even when a python-yq earlier in the search order
# shadows it — the usual arrangement on a machine that has both.
#
# These tests deliberately ask the identity question production no longer asks. The two are not
# in conflict: production needs "can this one do the job", a test needs "is the implementation I
# must exercise here installed at all".
find_real_go_yq() {
    local b
    for b in $(type -a yq 2>/dev/null | awk '{print $NF}' | sort -u); do
        [ -x "$b" ] || continue
        case "$("$b" --version 2>&1 | head -1)" in
            *mikefarah*) printf '%s\n' "$b"; return 0 ;;
        esac
    done
    return 1
}
```

- [ ] **Step 2: Create the diverging fixture**

Create `skills/shared/tests/fixtures/valid-claude-models-level-off.yaml`:

```yaml
providers:
  - id: zai
    label: "Z.AI"
    base_url: https://api.z.ai/api/anthropic
    token: "tkn-zai"

models:
  - id: zai/glm
    label: "GLM"
    model: glm-5.1

claude:
  models:
    - opus
    - fable

# `off` is the STRING "off" under both supported flavors (YAML 1.2 core) and the BOOLEAN false
# under a YAML-1.1 resolver. That divergence is the only thing that can trigger the loader's
# scalar probe, and no other fixture in this directory carries off/on/yes/no as a value.
codex:
  model: gpt-5.5
  reasoning_level: off
```

- [ ] **Step 3: Source the library from `test-config-loader.sh`**

After `FIXTURES="$TESTS_DIR/fixtures"` (line 6), add:

```bash
# shellcheck source=lib-yq-doubles.sh
. "$TESTS_DIR/lib-yq-doubles.sh"
```

- [ ] **Step 4: Write the failing test (Test 52)**

Append to `skills/shared/tests/test-config-loader.sh`, before the final `echo ""` / summary block:

```bash
# === Test 52: Go-yq transcodes, and its scalars match Python-yq's ===
# The failure this whole change exists for: `apt install yq` / `brew install yq` deliver Go-yq,
# whose bare `yq '.'` prints YAML rather than JSON. The loader must find the -o=json form on its
# own. The `off` assertion is Test 45's, re-run through the other flavor: it is the property
# validate_codex and validate_defaults depend on, and the reason accepting Go-yq is safe.
echo "=== Test 52: the loader works under Go-yq, with Test-45 scalar semantics ==="
TDIR=$(mktemp -d); GODIR=$(mktemp -d); ERR=$(mktemp)
mkyq_go "$GODIR"
sed 's/reasoning_level: extreme.*/reasoning_level: off/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
PATH="$GODIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero under Go-yq" "0" "$RC"
assert_stderr_contains "warns about the unknown level, as it does under Python-yq" 'unknown value "off"' "$ERR"
VAL=$(PATH="$GODIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>/dev/null)
if [ "$VAL" = "gpt-5.5|off" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex passes 'off' through as a string under Go-yq"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' under Go-yq (expected 'gpt-5.5|off')"
fi
# The same document through both flavors must produce the same snapshot, not merely a valid one.
A=$(CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime 2>/dev/null)
B=$(PATH="$GODIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-runtime 2>/dev/null)
if [ "$A" = "$B" ]; then
    PASS=$((PASS+1)); echo "  PASS: both flavors yield an identical runtime block"
else
    FAIL=$((FAIL+1)); echo "  FAIL: flavors disagree — python-yq '$A' vs Go-yq '$B'"
fi
rm -rf "$TDIR" "$GODIR" "$ERR"

# The doubles prove the plumbing, not that a REAL Go-yq behaves. When this machine has one —
# even shadowed by a python-yq earlier in PATH, which is the usual arrangement — exercise it.
# When it has none, say so out loud: a silent single-flavor run is exactly what let the Go-yq
# path rot unnoticed in the first place. Hard-requiring both binaries is not an option — there
# is no CI here and the suites are run by hand on whatever machine is at hand.
if REAL_GO="$(find_real_go_yq)"; then
    TDIR=$(mktemp -d); REALDIR=$(mktemp -d); ERR=$(mktemp)
    ln -s "$REAL_GO" "$REALDIR/yq"
    sed 's/reasoning_level: extreme.*/reasoning_level: off/' \
        "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
    PATH="$REALDIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "validate exits zero under the REAL Go-yq on this machine" "0" "$RC"
    VAL=$(PATH="$REALDIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" get-codex 2>/dev/null)
    if [ "$VAL" = "gpt-5.5|off" ]; then
        PASS=$((PASS+1)); echo "  PASS: real Go-yq ($("$REAL_GO" --version 2>&1|head -1)) keeps 'off' a string"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: real Go-yq printed '$VAL' (expected 'gpt-5.5|off')"
    fi
    rm -rf "$TDIR" "$REALDIR" "$ERR"
else
    echo "  SKIP: no real Go-yq found — the mikefarah path was exercised only against a double"
fi
```

- [ ] **Step 5: Run it and watch it fail**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | grep -A6 "Test 52"`
Expected: FAIL — `validate exits zero under Go-yq (expected rc=0, got 1)`, stderr carrying `yq flavor mismatch: detected Go-yq`.

- [ ] **Step 6: Replace `require_yq` with a presence check**

In `skills/shared/config-loader.sh`, replace the whole of `require_yq()` (lines 60-72) with:

```bash
require_yq() {
    # Presence only. WHICH yq this is has stopped mattering: the transcode below tries both
    # known JSON invocations and keeps the one whose output jq can parse, so a flavor check
    # here would only be able to reject binaries that work.
    # The substring "yq not found" is matched by preflight-env.sh:239 — do not reword it.
    command -v yq >/dev/null 2>&1 || die "yq not found. claude-mesh accepts either flavor: \
Python-yq (kislyuk/yq — 'pipx install yq') or Go-yq v4+ (mikefarah/yq — 'apt install yq', \
'brew install yq'). Install either one."
}
```

- [ ] **Step 7: Add `yq_to_json` and rewrite the transcode call site**

In `skills/shared/config-loader.sh`, add above `load_or_die()`:

```bash
# Python-yq (kislyuk/yq) is a jq wrapper: its DEFAULT output is already JSON. Go-yq (mikefarah)
# v4 prints YAML unless told -o=json. We do not ask which one is installed — the only property
# the snapshot needs is "this invocation returned JSON", and that is checked rather than
# guessed. The order is not arbitrary: the python-yq form goes first so the historically
# recommended flavor pays nothing for the fallback.
# `jq .` and NOT `jq -e .`: on an empty snapshot -e returns rc=4 while plain jq returns 0, and
# an empty or comment-only config.yaml legitimately transcodes to zero bytes (see :148).
yq_to_json() {                       # $1 = source YAML, $2 = destination JSON
    yq '.'         "$1" > "$2" 2>/dev/null && jq . "$2" >/dev/null 2>&1 && return 0
    yq -o=json '.' "$1" > "$2" 2>/dev/null && jq . "$2" >/dev/null 2>&1 && return 0
    return 1
}
```

Then replace the note at `:126-132` and the transcode at `:133-136` with:

```bash
    # ONE yq -> $CONFIG_JSON, then every read via jq on the snapshot. Which of the two JSON
    # invocations does the transcoding is decided by yq_to_json, not by this call site.
    if ! yq_to_json "$CONFIG_FILE" "$CONFIG_JSON"; then
        rm -f "$CONFIG_JSON"
        die "config snapshot: yaml→json conversion failed for $CONFIG_FILE (check yaml syntax)"
    fi
```

Leave the block that follows exactly as it is — the `# Cleanup runs even on \`die\` …` comment and its `trap 'rm -f "$CONFIG_JSON"' EXIT`. It is what removes the snapshot on every exit path, including the new `die`s, and nothing in this change replaces it.

- [ ] **Step 8: Run the loader suite and watch Test 52 pass**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -3`
Expected: `=== Summary: N passed, 0 failed ===`

- [ ] **Step 9: Flip the preflight Go-yq scenario**

The old stub at `test-preflight-env.sh:215-232` no longer stands in for a Go-yq — under the new loader it produces an empty snapshot and the run comes back `config INVALID`. Replace the whole block (the `mkdir -p "$WORK/goyq"` heredoc and its five assertions) with:

```bash
# The trigger a presence check CANNOT catch, and the one operators actually hit: `apt install yq`
# on Debian and `brew install yq` on macOS both deliver Go-yq. It IS present under the name the
# loader looks for, and the loader now USES it — so a working Go-yq must come back as a working
# environment, not as a verdict about the config.
mkyq_go "$WORK/goyq"
run_probe valid-claude-models.yaml PATH="$WORK/goyq:$WORK/curlfast:$WORK/noyq"
assert_eq   "Go-yq exits 0"                            0    "$RC"
assert_eq   "Go-yq -> config OK"                       OK   "$(field config "$OUT")"
assert_no_match "…and nothing claims a flavour mismatch" "flavor mismatch" "$OUT"
assert_no_match "…and nobody is sent to install a different yq" "pipx install yq" "$OUT"
```

Also source the library: after `SCRIPT="$TESTS_DIR/../preflight-env.sh"` (line 10) add

```bash
# shellcheck source=lib-yq-doubles.sh
. "$TESTS_DIR/lib-yq-doubles.sh"
```

and reword the precondition comment at line 13 from "without Python-yq or jq" to "without a `yq` or `jq`".

- [ ] **Step 10: Run the preflight suite**

Run: `bash skills/shared/tests/test-preflight-env.sh 2>&1 | tail -3`
Expected: `=== Summary: N passed, 0 failed ===`

- [ ] **Step 11: Commit**

```bash
git add skills/shared/tests/lib-yq-doubles.sh \
        skills/shared/tests/fixtures/valid-claude-models-level-off.yaml \
        skills/shared/tests/test-config-loader.sh \
        skills/shared/tests/test-preflight-env.sh \
        skills/shared/config-loader.sh
git commit -m "fix(config): accept whichever yq can produce JSON

The plugin uses yq for exactly one operation, a single YAML->JSON transcode,
so the incompatibility with Go-yq was never the DSL the rejection cited: it
is that Go-yq needs -o=json to print JSON. The loader now tries both known
forms and keeps the one whose output jq can parse.

Claude-Session: https://claude.ai/code/session_015gyjW55gtc8ER5wMj1a9mz"
```

---

## Task 2: The scalar probe, and naming the toolchain instead of the config

Deliverable: a `yq` that cannot emit JSON, or that resolves YAML 1.1, is named as the culprit; a genuinely malformed `config.yaml` still is. Preflight routes both new failures by cause.

**Files:**
- Modify: `skills/shared/config-loader.sh` (add `yq_probe` beside `yq_to_json`; extend the call site from Task 1)
- Modify: `skills/shared/tests/test-config-loader.sh` (add `assert_stderr_lacks`; Tests 53-55)
- Modify: `skills/shared/preflight-env.sh:239` (signature match), `:693` (hint), and the comments at `~231-236`, `~649-651`, `~689-693`
- Modify: `skills/shared/tests/test-preflight-env.sh` (two new scenarios; hint wording at `:654` and `:669`)

**Interfaces:**
- Consumes: `yq_to_json <src> <dst>` and the doubles from Task 1.
- Produces:
  - `yq_probe` — sets `YQ_PROBE_TYPES`; prints nothing. Empty means this `yq` produced JSON by neither form on a known-good document.
  - `YQ_SCALARS_1_2` — the expected type tuple, `"string","string","boolean","number"`.
  - `assert_stderr_lacks <desc> <needle> <file>` in `test-config-loader.sh`.

- [ ] **Step 1: Add the negative assertion helper**

In `skills/shared/tests/test-config-loader.sh`, after `assert_stderr_contains()`:

```bash
assert_stderr_lacks() {
    local desc="$1" needle="$2" stderr_file="$3"
    if grep -q -- "$needle" "$stderr_file"; then
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (stderr should NOT contain: $needle)"
        echo "    stderr was:"; sed 's/^/      /' "$stderr_file"
    else
        PASS=$((PASS+1)); echo "  PASS: $desc"
    fi
}
```

- [ ] **Step 2: Write the failing tests (53, 54, 55)**

Append to `skills/shared/tests/test-config-loader.sh`, after Test 52:

```bash
# === Test 53: a yq that cannot emit JSON is named as the toolchain ===
# Until this split existed, every transcode failure read "check yaml syntax" and sent the
# operator to edit a file nothing had opened. The negative assertion is the point of the test.
echo "=== Test 53: a yq that cannot produce JSON does not get the config blamed for it ==="
TDIR=$(mktemp -d); NJDIR=$(mktemp -d); ERR=$(mktemp)
mkyq_nojson "$NJDIR"
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
PATH="$NJDIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 when yq cannot emit JSON" "1" "$RC"
assert_stderr_contains "names the toolchain" "yq cannot produce JSON" "$ERR"
assert_stderr_lacks "and does NOT accuse a healthy config.yaml" "check yaml syntax" "$ERR"
rm -rf "$TDIR" "$NJDIR" "$ERR"

# === Test 54: a YAML-1.1 resolver is caught where it matters, and only where it matters ===
# Today such a yq surfaces as `codex.reasoning_level: must be a string (got boolean) — quote
# it`, telling the user to fix a value that is already correct. Half (a) is that message being
# replaced by an accurate one. Half (b) is the gate staying per-document: on a config that
# yields no booleans the same binary emitted exactly what a YAML-1.2-core resolver would, and
# the snapshot is all anything downstream reads. Both halves must hold, or a later refactor
# will quietly turn the gate into a blanket probe on every load.
echo "=== Test 54: a YAML-1.1 yq is refused when it can change the config, accepted when it cannot ==="
if ! have_pyyaml; then
    echo "  SKIP: python3 has no PyYAML — the YAML-1.1 double cannot be built"
else
    Y11DIR=$(mktemp -d); mkyq_yaml11 "$Y11DIR"
    TDIR=$(mktemp -d); ERR=$(mktemp)
    cp "$FIXTURES/valid-claude-models-level-off.yaml" "$TDIR/config.yaml"
    PATH="$Y11DIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "validate exits 1 under a YAML-1.1 yq" "1" "$RC"
    assert_stderr_contains "names the resolver" "yq mis-resolves YAML scalars" "$ERR"
    assert_stderr_lacks "and does not tell the user to quote a correct value" \
        "must be a string (got boolean)" "$ERR"
    rm -rf "$TDIR" "$ERR"
    TDIR=$(mktemp -d); ERR=$(mktemp)
    cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
    PATH="$Y11DIR:$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "…and the same yq is accepted on a config that yields no booleans" "0" "$RC"
    rm -rf "$TDIR" "$ERR" "$Y11DIR"
fi

# === Test 55: a healthy yq plus broken yaml still blames the yaml; empty configs are unchanged ===
# The other half of Test 53's split, and the degenerate case where `jq .` cannot tell the
# flavors apart because both emit the same thing: the verdict must stay the config-level one.
echo "=== Test 55: malformed yaml blames the yaml; empty/comment-only configs unchanged under both flavors ==="
TDIR=$(mktemp -d); ERR=$(mktemp); GODIR=$(mktemp -d)
mkyq_go "$GODIR"
printf 'providers:\n  - id: zai\n    label: "[unclosed\n' > "$TDIR/config.yaml"
CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on malformed yaml" "1" "$RC"
assert_stderr_contains "blames the yaml" "check yaml syntax" "$ERR"
assert_stderr_lacks "and does not accuse the yq" "yq cannot produce JSON" "$ERR"
for FLAVOR in python-yq go-yq; do
    case "$FLAVOR" in python-yq) PFX="" ;; go-yq) PFX="$GODIR:" ;; esac
    : > "$TDIR/config.yaml"
    PATH="$PFX$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "empty config exits 1 ($FLAVOR)" "1" "$RC"
    assert_stderr_contains "…and says providers is empty ($FLAVOR)" \
        "providers: section is empty or missing" "$ERR"
    printf '# only a comment\n' > "$TDIR/config.yaml"
    PATH="$PFX$PATH" CLAUDE_PLUGIN_DATA="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "comment-only config exits 1 ($FLAVOR)" "1" "$RC"
    assert_stderr_contains "…and says providers is empty ($FLAVOR)" \
        "providers: section is empty or missing" "$ERR"
done
rm -rf "$TDIR" "$ERR" "$GODIR"
```

- [ ] **Step 3: Run the loader suite and watch 53 and 54 fail**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | grep -E "FAIL|Summary"`
Expected: FAIL on `names the toolchain` and `names the resolver`; Test 55 already passes (that behaviour exists).

- [ ] **Step 4: Add `yq_probe` to the loader**

In `skills/shared/config-loader.sh`, directly after `yq_to_json`:

```bash
YQ_SCALARS_1_2='"string","string","boolean","number"'
# The one property that accepting a second flavor can break: off/on/yes/no must stay STRINGS
# (YAML 1.2 core). A YAML-1.1 resolver turns them into booleans, and validate_codex (:288),
# validate_defaults (:522) and Test 45 then read that as a type error or a failed membership
# test — the user is told to quote a value that was already correct. Checked against the binary
# that is actually installed, not inferred from a version number.
# SETS YQ_PROBE_TYPES; does NOT print. A `die` inside a $(...) substitution would exit only the
# SUBSHELL and the caller would read the empty result as "this yq cannot emit JSON" — a tmpfile
# failure reported as a toolchain verdict. An empty YQ_PROBE_TYPES must mean one thing only.
yq_probe() {
    YQ_PROBE_TYPES=""
    local d
    d=$(mktemp -d -t claude-mesh-yqprobe-XXXXXX) || die "mktemp failed for the yq probe"
    printf 'a: off\nb: yes\nc: true\nd: 3\n' > "$d/probe.yaml"
    yq_to_json "$d/probe.yaml" "$d/probe.json" \
        && YQ_PROBE_TYPES=$(jq -r '[.a,.b,.c,.d|type]|@csv' "$d/probe.json" 2>/dev/null)
    rm -rf "$d"
}
```

- [ ] **Step 5: Extend the call site with the gate and the split**

Replace the `if ! yq_to_json …` block written in Task 1 with:

```bash
    if yq_to_json "$CONFIG_FILE" "$CONFIG_JSON"; then
        # A YAML-1.1 resolver differs from YAML-1.2-core by ONE thing that reaches this schema:
        # it turns off/on/yes/no into booleans. Such a divergence therefore always shows up AS A
        # BOOLEAN IN THE SNAPSHOT. No booleans means no divergence was possible on this
        # document, whichever binary produced it — a property of the artifact, not an inference
        # about who ran. Gating on "which form won" instead would be an identity check smuggled
        # back in: a flavor whose DEFAULT output is JSON wins with the first form and skips this
        # entirely. Measured 2026-08-25: config.example.yaml and the installed config.yaml both
        # hold ZERO booleans, so on a real config the probe never runs.
        # ${bools:-0} guards the same case as $count at :151 — an empty snapshot prints nothing.
        local bools
        bools=$(jq '[paths(type=="boolean")] | length' "$CONFIG_JSON" 2>/dev/null)
        if [ "${bools:-0}" -gt 0 ]; then
            yq_probe
            if [ "$YQ_PROBE_TYPES" != "$YQ_SCALARS_1_2" ]; then
                rm -f "$CONFIG_JSON"
                die "yq mis-resolves YAML scalars: off/on/yes/no must stay strings (YAML 1.2 \
core), but this yq turned them into booleans. claude-mesh needs Python-yq (kislyuk/yq) or \
Go-yq v4+ (mikefarah/yq). Got: $(yq --version 2>&1 | head -1)"
            fi
        fi
    else
        rm -f "$CONFIG_JSON"
        # The transcode failed: is that the yq's fault or the yaml's? The probe runs a document
        # that is known to be good, so it separates the two. Before this split every failure
        # here read "check yaml syntax" and sent the operator to edit a healthy file.
        yq_probe
        if [ -n "$YQ_PROBE_TYPES" ]; then
            die "config snapshot: yaml→json conversion failed for $CONFIG_FILE (check yaml syntax)"
        else
            die "yq cannot produce JSON: neither 'yq .' nor 'yq -o=json .' returned JSON for a \
known-good document. claude-mesh accepts Python-yq (kislyuk/yq — 'pipx install yq') or Go-yq \
v4+ (mikefarah/yq — 'apt install yq', 'brew install yq'). Got: $(yq --version 2>&1 | head -1)"
        fi
    fi
```

- [ ] **Step 6: Update the two flavor comments the loader still carries**

At `config-loader.sh:288` replace "with kislyuk-yq the YAML-1.1 words `off`/`on`/`yes`/`no` parse as STRINGS" with "under every yq flavor this loader accepts — the transcode verifies it — the YAML-1.1 words `off`/`on`/`yes`/`no` parse as STRINGS". Make the same substitution at `:522` for "under kislyuk-yq those are the STRINGS".

- [ ] **Step 7: Run the loader suite; 53, 54 and 55 all pass**

Run: `bash skills/shared/tests/test-config-loader.sh 2>&1 | tail -3`
Expected: `=== Summary: N passed, 0 failed ===`

- [ ] **Step 8: Route the two new dies in preflight**

At `skills/shared/preflight-env.sh:239` replace the pattern list:

```bash
               *"yq not found"*|*"yq cannot produce JSON"*|*"yq mis-resolves"*)
```

At `:693` replace the yq hint:

```bash
                case "$TOOLCHAIN_MISSING" in *yq*) T_FIX="install a yq that emits JSON — 'pipx install yq' (Python-yq) or 'apt install yq' / 'brew install yq' (Go-yq v4+)" ;; esac
```

One line and not three on purpose: "absent" and "incapable" share a fix, the YAML-1.1 state is unobserved, and the `config` row already prints the loader's own sentence verbatim.

- [ ] **Step 9: Rewrite the three comment blocks that this change makes false**

- `~231-236`: the routing rationale stands, its example does not. Replace "a Go-yq binary (what `apt install yq` and `brew install yq` actually deliver) is present under the name the loader looks for, and passes it" with "a `yq` that is present under the name the loader looks for can still be one the loader cannot use — it emits no JSON, or it resolves YAML 1.1 — and the presence check above passes it".
- `~649-651`: replace `"pipx install yq" and "edit a healthy config" are different days' work` with `"install a usable yq" and "edit a healthy config" are different days' work`.
- `~689-693`: delete the claim that Go-yq "is a DIFFERENT program that config-loader.sh rejects on sight (config-loader.sh:71)" — the cited line no longer exists. Replace with "Naming what to install matters more than usual here: both flavors are accepted, so the advice has to name both rather than send half the readers to the wrong binary."

- [ ] **Step 10: Add the two preflight scenarios and reword the hint assertions**

Append after the Go-yq scenario from Task 1:

```bash
# A yq that is present, is used, and still cannot do the job. The loader dies rc=1 exactly as a
# rejected config does, so only the routing by cause keeps a healthy config.yaml from being
# blamed — and this scenario is what keeps the probe's signature match in step with the
# loader's own wording.
mkyq_nojson "$WORK/nojsonyq"
run_probe valid-claude-models.yaml PATH="$WORK/nojsonyq:$WORK/curlfast:$WORK/noyq"
assert_eq   "unusable yq exits 0"                          0        "$RC"
assert_eq   "unusable yq -> config UNKNOWN, not INVALID"   UNKNOWN  "$(field config "$OUT")"
assert_match "…and the detail names the tool"              "cannot produce JSON" "$OUT"
assert_match "…and the hint names both flavours"           "Go-yq v4+"      "$OUT"
assert_match "…and says the config was never read"         "was never read" "$OUT"

# The other toolchain die, and the one a version gate would have missed: a yq that DOES emit
# JSON but resolves YAML 1.1. The fixture is the only one whose scalars diverge between the two
# schemas — with any other config the loader is right to accept this binary.
if have_pyyaml; then
    mkyq_yaml11 "$WORK/y11yq"
    run_probe valid-claude-models-level-off.yaml PATH="$WORK/y11yq:$WORK/curlfast:$WORK/noyq"
    assert_eq   "YAML-1.1 yq exits 0"                      0        "$RC"
    assert_eq   "YAML-1.1 yq -> config UNKNOWN"            UNKNOWN  "$(field config "$OUT")"
    assert_match "…named as a resolver, not as a bad config" "mis-resolves" "$OUT"
    assert_no_match "…and the user is not told to quote a correct value" \
        "must be a string (got boolean)" "$OUT"
else
    echo "  SKIP: python3 has no PyYAML — the YAML-1.1 preflight scenario cannot run"
fi
```

At `:654` change `assert_match "…the hint names the tool the rows above reported" "pipx install yq" "$OUT"` to look for `install a yq that emits JSON`. At `:669` change `assert_no_match "…and never at yq" "pipx install yq" "$OUT"` to `assert_no_match "…and never at yq" "install a yq that emits JSON" "$OUT"`.

- [ ] **Step 11: Run the preflight suite**

Run: `bash skills/shared/tests/test-preflight-env.sh 2>&1 | tail -3`
Expected: `=== Summary: N passed, 0 failed ===`

- [ ] **Step 12: Commit**

```bash
git add skills/shared/config-loader.sh skills/shared/preflight-env.sh \
        skills/shared/tests/test-config-loader.sh skills/shared/tests/test-preflight-env.sh
git commit -m "fix(config): name the yq when the yq is the problem

A transcode failure used to read 'check yaml syntax' whatever caused it, and
a yq resolving YAML 1.1 surfaced as 'reasoning_level must be a string (got
boolean) - quote it' against a value that was already correct. Both are now
attributed to the toolchain, and preflight routes them by cause.

Claude-Session: https://claude.ai/code/session_015gyjW55gtc8ER5wMj1a9mz"
```

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
