# Fresh-Session Review Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two slash commands that hand a design+plan (or a finished implementation) to a fresh Claude Code session which reviews it — inside a sandbox whose plugin config, reachable providers and git remote differ from the generating session's — plus the environment probe that tells that session what it can actually use.

**Architecture:** The generators write a prompt file and never read `config.yaml`; the only statement they make about reviewers is "run the probe and pick from its OK rows". The probe (`skills/shared/preflight-env.sh`) runs inside the sandbox, reuses the existing `token-precheck.sh` / `ollama-precheck.sh` and reads config only through `config-loader.sh`. Two existing files gain one paragraph each so the loop closes: `mesh-design-review` Step 15 routes the next iteration into the new generator, `do-plan` Step 7 points at the code-review one.

**Tech Stack:** bash 4.0+ (GNU coreutils `timeout`), `curl`/`git` optional, Python-yq + jq behind `config-loader.sh`, Claude Code plugin markdown (`commands/*.md`, `skills/*/SKILL.md`).

**Spec:** `docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md`

## Global Constraints

- Design source of truth is the spec above. Every decision numbered there (1–6) is binding.
- Every config read goes through `skills/shared/config-loader.sh`. Raw `yq` is forbidden anywhere in this work.
- The probe **always exits 0** for any delivered verdict. A non-zero exit means the probe itself is broken — or was interrupted: on INT/TERM the trap cleans up and exits non-zero, an interrupt is not a verdict.
- Closed status set, nothing else may be printed in the status column: `OK`, `MISSING`, `NO-NETWORK`, `AUTH-FAILED`, `INVALID`, `SKIPPED`, `UNKNOWN`.
- Row format is exactly `printf '%-16s %-12s %s\n' "$name" "$status" "$detail"`. A name longer than 16 columns (`provider:deepseek`) overflows the pad — harmless, parsing is word-based; do not "fix" it by truncating names.
- Row order: `plugin`, `yq` / `jq` (only when missing), `config`, `builtin-claude`, `claude-models`, `curl` (only when missing), `ext-claude-deps` (only when something is missing), `codex`, `gemini`, `provider:*` in order of first appearance in `models` (aggregate row `provider` instead, when providers are not probed at all), `git-remote`, `gh`, `glab`, `clipboard`, then `SUMMARY available:` and `SUMMARY unavailable:`.
- No secret ever reaches stdout or stderr. Exported env files are deleted through a `trap … EXIT`.
- Prechecks are invoked as `env -u SKIP_TOKEN_PRECHECK …`.
- Binaries resolve through `PREFLIGHT_CURL_BIN` (default `curl`), `PREFLIGHT_GIT_BIN` (default `git`), `PREFLIGHT_YQ_BIN` (default `yq`), `PREFLIGHT_JQ_BIN` (default `jq`) and `PREFLIGHT_EXT_DEPS_BINS` (default `claude bc python3`); budgets through `PREFLIGHT_HTTP_TIMEOUT` (default 5) and `PREFLIGHT_GIT_TIMEOUT` (default 8). `PREFLIGHT_CURL_BIN` governs only the probe's own HTTP checks; when it does not resolve, the borrowed prechecks are not invoked at all (provider rows → `UNKNOWN`). The ollama precheck receives its budget through env knobs (`OLLAMA_PRECHECK_TRIES=1`, attempt/tags timeouts = `PREFLIGHT_HTTP_TIMEOUT`). `PREFLIGHT_SKIP_NETWORK=1` skips every network probe (providers, codex/gemini heuristics, `git ls-remote`) — those rows read `UNKNOWN skipped by PREFLIGHT_SKIP_NETWORK`; each live network probe announces itself on stderr, stdout stays table-only.
- Generators must not call `config-loader.sh` and must not emit any model id, provider id or `defaults.*` preset from the local config.
- Slash commands are namespaced: `/claude-mesh:<name>`. Bare names do not resolve.
- Repo language convention: command files, skills and generated prompts are English; user-facing question strings inside `mesh-*` skills are Russian. Match the file you are editing.
- Test suites follow the house style: `set -u`, fixture config pinned via `export CLAUDE_PLUGIN_DATA=<tmpdir>`, `assert_*` helpers, PASS/FAIL counters, non-zero exit when `FAIL > 0`.
- Commit after every task. Never push; never open a PR.

---

## File Structure

| File | Responsibility |
|---|---|
| `skills/shared/preflight-env.sh` | The environment probe. One row per capability, two SUMMARY lines, exit 0 |
| `skills/shared/tests/test-preflight-env.sh` | Its regression suite: fixture configs + shimmed `curl`/`git` |
| `skills/shared/tests/fixtures/valid-claude-models.yaml` | Fixture with a `claude.models` catalog (none of the existing fixtures has one) |
| `skills/shared/tests/fixtures/invalid-claude-scalar.yaml` | Fixture with valid providers/models and a scalar `claude: false` — the `claude-models INVALID` case |
| `skills/ext-claude-exec/ollama-precheck.sh` | Modify: env knobs `OLLAMA_PRECHECK_TRIES` / `OLLAMA_PRECHECK_ATTEMPT_TIMEOUT` / `OLLAMA_PRECHECK_TAGS_TIMEOUT`, defaults preserve current behaviour |
| `commands/design-review-fresh-session.md` | Generator → fresh session → `/claude-mesh:mesh-design-review`; entry and every later iteration |
| `commands/code-review-fresh-session.md` | Generator → fresh session → `/claude-mesh:mesh-review` after implementation |
| `skills/mesh-design-review/SKILL.md` | Step 15 only: the "Новая итерация" branch targets the new generator |
| `commands/do-plan.md` | Step 7 only: point at the code-review generator; state what a sandbox cannot finish |
| `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md` | Recorded RED baseline + wording micro-test results |
| `README.md`, `CHANGELOG.md` | Session-helper list; `## [Unreleased]` entry |

---

### Task 1: Probe skeleton — rows, config detection, static rows

**Files:**
- Create: `skills/shared/preflight-env.sh`
- Create: `skills/shared/tests/test-preflight-env.sh`
- Create: `skills/shared/tests/fixtures/valid-claude-models.yaml`
- Create: `skills/shared/tests/fixtures/invalid-claude-scalar.yaml`

**Interfaces:**
- Consumes: `skills/shared/config-loader.sh` subcommands `list-models` (`<id>|<label>` per line), `list-claude-models` (one alias per line), `data-dir`, `get-flag has_codex|has_gemini`. Loader exit codes: 0 = fine, 2 = no `config.yaml`, 1 = invalid.
- Produces: `row <name> <status> [detail]`; globals `LOADER`, `EXEC_DIR`, `HTTP_TIMEOUT`, `GIT_TIMEOUT`, `CURL_BIN`, `GIT_BIN`, `YQ_BIN`, `JQ_BIN`, `TOOLCHAIN_OK`, `HAVE_CURL`, `EXT_DEPS_MISSING` (comma-joined list of absent ext-claude prerequisites, empty when all present), `CONFIG_STATUS` (one of `OK|MISSING|INVALID|UNKNOWN`), `CLAUDE_MODELS` (raw `list-claude-models` output — Task 4 expands the SUMMARY from it), `MODELS` (raw `list-models` output, empty unless `CONFIG_STATUS=OK`), `HAS_CODEX`, `HAS_GEMINI`, and `CURRENT_ENVF` + `cleanup()` for Task 2. Tasks 2–4 append their sections to the same file and consume these names.

- [ ] **Step 1: Create the fixture with a Claude catalog**

```yaml
# skills/shared/tests/fixtures/valid-claude-models.yaml
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
```

Also create `skills/shared/tests/fixtures/invalid-claude-scalar.yaml` — valid providers/models,
and a `claude:` section the validator rejects (the `claude-models INVALID` case):

```yaml
# skills/shared/tests/fixtures/invalid-claude-scalar.yaml
providers:
  - id: zai
    label: "Z.AI"
    base_url: https://api.z.ai/api/anthropic
    token: "tkn-zai"

models:
  - id: zai/glm
    label: "GLM"
    model: glm-5.1

claude: false
```

- [ ] **Step 2: Write the failing test**

Create `skills/shared/tests/test-preflight-env.sh`:

```bash
#!/usr/bin/env bash
# Regression tests for preflight-env.sh
#
# The probe answers one question for a session that did not configure this machine: what can
# actually be used here? Every verdict exits 0 — a non-zero exit means the probe is broken,
# never that the environment is poor. That contract is the first thing asserted below.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../preflight-env.sh"

FAIL=0
PASS=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$pattern' in output)" ;;
    esac
}

assert_no_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) FAIL=$((FAIL+1)); echo "  FAIL: $desc ('$pattern' present in output)" ;;
        *) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
    esac
}

# Status column of a named row ("" when the row is absent).
field() { awk -v n="$1" '$1==n {print $2; exit}' <<<"$2"; }

# Default git shim: answers instantly that there is no 'origin'. Without it every scenario
# below would run a real `git ls-remote` against this repository's remote — up to the git
# budget each, on a network the suite is not testing. Scenarios that DO test git pass their
# own PREFLIGHT_GIT_BIN, which wins because `env` keeps the last assignment.
mkdir -p "$WORK/gitfast"
cat > "$WORK/gitfast/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  rev-parse) echo ".git" ;;
  remote)    exit 1 ;;       # no origin configured — resolves without touching the network
  *)         exit 0 ;;
esac
SH
chmod +x "$WORK/gitfast/git"

# Default curl shim: answers 200 instantly. Without it, the moment Task 2's provider probes
# exist, every Task-1 scenario would send the fixture token to the real https://api.z.ai and
# poke 127.0.0.1:11434 with retries — the suite would silently become network-dependent, slow,
# and leak a fixture token outward on every run. Scenarios that test other codes pass their
# own PREFLIGHT_CURL_BIN/PATH, which win because `env` keeps the last assignment.
mkdir -p "$WORK/curlfast"
cat > "$WORK/curlfast/curl" <<'SH'
#!/usr/bin/env bash
echo "200"
exit 0
SH
chmod +x "$WORK/curlfast/curl"

# Each run gets a private data dir (so the suite never reads the developer's ~/.claude config)
# and a private TMPDIR (so exported env files, which carry tokens, cannot leak into shared /tmp
# and can be counted afterwards).
#
# run_probe assigns OUT / RC / CFG_DIR as globals and is called as a STANDALONE command —
# never as OUT="$(run_probe …)". A command substitution would strand the assignments in its
# subshell and make the exit-code and leak assertions below unfalsifiable: the probe could
# exit 7 and RC would still read 0. Same idiom as test-verify-delegation.sh:43.
CFG_DIR=""
RC=0
OUT=""
run_probe() {           # run_probe <fixture-basename|none> [VAR=value ...]
    local fixture="$1"; shift
    CFG_DIR="$(mktemp -d "$WORK/data-XXXXXX")"
    [ "$fixture" = none ] || cp "$TESTS_DIR/fixtures/$fixture" "$CFG_DIR/config.yaml"
    OUT="$(env CLAUDE_PLUGIN_DATA="$CFG_DIR" TMPDIR="$CFG_DIR" \
               PREFLIGHT_GIT_BIN="$WORK/gitfast/git" \
               PREFLIGHT_CURL_BIN="$WORK/curlfast/curl" PATH="$WORK/curlfast:$PATH" \
               "$@" bash "$SCRIPT" 2>&1)"
    RC=$?
}

echo "== Task 1: config detection and static rows =="

run_probe valid-claude-models.yaml
assert_eq   "valid config exits 0"            0    "$RC"
assert_eq   "plugin identity row present"     OK   "$(field plugin "$OUT")"
assert_eq   "valid config -> config OK"       OK   "$(field config "$OUT")"
assert_match "config detail names config.yaml" "/config.yaml" "$OUT"
assert_eq   "builtin-claude always OK"        OK   "$(field builtin-claude "$OUT")"
assert_eq   "claude catalog -> OK"            OK   "$(field claude-models "$OUT")"
assert_match "catalog lists both aliases"     "opus, fable" "$OUT"

run_probe none
assert_eq   "missing config exits 0"          0        "$RC"
assert_eq   "missing config -> MISSING"       MISSING  "$(field config "$OUT")"
assert_eq   "built-in claude survives no config" OK    "$(field builtin-claude "$OUT")"
assert_eq   "no config -> catalog SKIPPED"    SKIPPED  "$(field claude-models "$OUT")"

run_probe invalid-no-providers.yaml
assert_eq   "invalid config exits 0"          0        "$RC"
assert_eq   "invalid config -> INVALID"       INVALID  "$(field config "$OUT")"

# config OK must predict "the orchestrator starts": Step 5.0 validates defaults and runtime
# too, so a config whose models parse but whose defaults: section is broken is INVALID here.
run_probe invalid-defaults-runmode.yaml
assert_eq   "broken defaults -> config INVALID" INVALID "$(field config "$OUT")"

# A dead toolchain must not impersonate a rejected config — the loader dies rc=1 either way,
# but the operator's next move differs (pipx install yq vs editing a healthy config).
run_probe valid-claude-models.yaml PREFLIGHT_YQ_BIN="$WORK/no-such-yq"
assert_eq   "missing yq exits 0"              0        "$RC"
assert_eq   "missing yq -> its own row"       MISSING  "$(field yq "$OUT")"
assert_eq   "missing yq -> config UNKNOWN, not INVALID" UNKNOWN "$(field config "$OUT")"

# A broken claude: section is INVALID with the validator's reason — mesh-review refuses to
# start on this same read, so "no catalog" (MISSING) would be a lie.
run_probe invalid-claude-scalar.yaml
assert_eq   "broken claude section -> INVALID" INVALID "$(field claude-models "$OUT")"

run_probe valid-full.yaml
assert_eq   "no claude section -> MISSING"    MISSING  "$(field claude-models "$OUT")"

# The closed status set is the contract every later task must keep.
BAD="$(awk 'NF>=2 && $1 !~ /^SUMMARY/ {print $2}' <<<"$OUT" \
       | sort -u | grep -Ev '^(OK|MISSING|NO-NETWORK|AUTH-FAILED|INVALID|SKIPPED|UNKNOWN)$' || true)"
assert_eq   "status column stays in the closed set" "" "$BAD"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: FAIL — `preflight-env.sh` does not exist yet, so every assertion misses.

- [ ] **Step 4: Write the probe skeleton**

Create `skills/shared/preflight-env.sh` (`chmod +x` it):

```bash
#!/usr/bin/env bash
# preflight-env.sh — report what THIS environment can actually do.
#
# Written for a session that did not configure the machine it runs on: a review session in a
# sandbox, whose config.yaml, reachable providers and git remote are not the ones the prompt
# was written against. It prints one row per capability and two SUMMARY lines naming the
# reviewers that can be selected here.
#
# EVERY verdict exits 0 — "nothing is reachable" is an answer, not a failure. A non-zero exit
# means this script is broken (same contract as shared/watch-runs.sh).
#
# Env: PREFLIGHT_HTTP_TIMEOUT (5)  PREFLIGHT_GIT_TIMEOUT (8)
#      PREFLIGHT_CURL_BIN (curl)   PREFLIGHT_GIT_BIN (git)
#      PREFLIGHT_YQ_BIN (yq)       PREFLIGHT_JQ_BIN (jq)
#      PREFLIGHT_EXT_DEPS_BINS ("claude bc python3")
#      PREFLIGHT_SKIP_NETWORK (0)  — 1 skips every network probe (fast re-runs)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SCRIPT_DIR/config-loader.sh"
EXEC_DIR="$SCRIPT_DIR/../ext-claude-exec"
HTTP_TIMEOUT="${PREFLIGHT_HTTP_TIMEOUT:-5}"
GIT_TIMEOUT="${PREFLIGHT_GIT_TIMEOUT:-8}"
CURL_BIN="${PREFLIGHT_CURL_BIN:-curl}"
GIT_BIN="${PREFLIGHT_GIT_BIN:-git}"
YQ_BIN="${PREFLIGHT_YQ_BIN:-yq}"
JQ_BIN="${PREFLIGHT_JQ_BIN:-jq}"
EXT_DEPS_BINS="${PREFLIGHT_EXT_DEPS_BINS:-claude bc python3}"
SKIP_NET="${PREFLIGHT_SKIP_NETWORK:-0}"

# Task 2 sets this to the env file it is about to source; the trap removes it even if the
# probe is interrupted between export and rm. The file carries a provider token. On INT/TERM
# the probe exits NON-zero after cleanup: an interrupt is not a verdict — "every verdict
# exits 0" covers completed runs only. (This is also why probe_provider must never run inside
# a command substitution: CURRENT_ENVF assigned in a subshell never reaches this trap.)
CURRENT_ENVF=""
cleanup() { [ -n "$CURRENT_ENVF" ] && rm -f "$CURRENT_ENVF"; return 0; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

row() { printf '%-16s %-12s %s\n' "$1" "$2" "${3:-}"; }

# ---------------------------------------------------------------- identity
# Which probe is this? The reading session must be able to tell "the probe is old" from
# "the capability is absent", and a stale cache pick must be visible instead of silent.
# sed, not jq: this row prints before the toolchain check.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1)"
row plugin OK "${PLUGIN_VERSION:-unknown} @ $PLUGIN_ROOT"

# ---------------------------------------------------------------- toolchain
# The loader dies rc=1 without yq/jq — the same exit code a rejected config produces. Check
# first, so a dead toolchain cannot impersonate INVALID and send the operator to "fix" a
# healthy config.yaml (row names are canonical yq/jq whatever the override points at).
TOOLCHAIN_OK=1
command -v "$YQ_BIN" >/dev/null 2>&1 || { TOOLCHAIN_OK=0; row yq MISSING "loader cannot run without it (looked for $YQ_BIN)"; }
command -v "$JQ_BIN" >/dev/null 2>&1 || { TOOLCHAIN_OK=0; row jq MISSING "loader cannot run without it (looked for $JQ_BIN)"; }

# ---------------------------------------------------------------- config
CONFIG_STATUS=""
CONFIG_DETAIL=""
MODELS=""
HAS_CODEX=0
HAS_GEMINI=0

if [ "$TOOLCHAIN_OK" = 0 ]; then
    CONFIG_STATUS="UNKNOWN"
    CONFIG_DETAIL="cannot evaluate — loader toolchain missing (see rows above)"
elif [ ! -x "$LOADER" ]; then
    CONFIG_STATUS="MISSING"
    CONFIG_DETAIL="config-loader.sh not found at $LOADER — broken install"
else
    LERR="$(mktemp)"
    # A bare $() swallows the loader's exit code, and rc=2 (no config yet) must not be
    # misread as rc=1 (config rejected) — the same distinction every caller in this repo makes.
    MODELS="$("$LOADER" list-models 2>"$LERR")"; LRC=$?
    case "$LRC" in
        0) CONFIG_STATUS="OK";      CONFIG_DETAIL="$("$LOADER" data-dir 2>/dev/null)/config.yaml"
           # config OK must mean "the orchestrator starts here": mesh-design-review Step 5.0
           # dies on defaults/runtime too, not only on providers/models. One preset name is
           # enough — get-defaults runs validate_defaults for the whole defaults: section.
           # codex/gemini stay out of this gate on purpose: a broken optional section fails
           # its own row (typed getter in Task 3), never the whole environment.
           for CHECK in "get-defaults design_review" "get-flag dispatch_model"; do
               CH_ERR="$(mktemp)"
               # shellcheck disable=SC2086
               if ! "$LOADER" $CHECK >/dev/null 2>"$CH_ERR"; then
                   CONFIG_STATUS="INVALID"; CONFIG_DETAIL="$(head -1 "$CH_ERR")"; MODELS=""
                   rm -f "$CH_ERR"; break
               fi
               rm -f "$CH_ERR"
           done ;;
        2) CONFIG_STATUS="MISSING"; CONFIG_DETAIL="no config.yaml here — the review skills will not start; cp config.example.yaml into the data dir"; MODELS="" ;;
        *) CONFIG_STATUS="INVALID"; CONFIG_DETAIL="$(head -1 "$LERR")"; MODELS="" ;;
    esac
    rm -f "$LERR"
fi
row config "$CONFIG_STATUS" "$CONFIG_DETAIL"

# ---------------------------------------------------------------- built-in claude
row builtin-claude OK "needs no config section (orchestrators still need config.yaml)"

CLAUDE_MODELS=""
if [ "$CONFIG_STATUS" = "OK" ]; then
    CM_ERR="$(mktemp)"
    CLAUDE_MODELS="$("$LOADER" list-claude-models 2>"$CM_ERR")"; CM_RC=$?
    if [ "$CM_RC" -ne 0 ]; then
        # mesh-review Step 1 refuses to start on this same read — "no catalog" would be a lie.
        row claude-models INVALID "$(head -1 "$CM_ERR")"
        CLAUDE_MODELS=""
    elif [ -n "$CLAUDE_MODELS" ]; then
        row claude-models OK "$(printf '%s' "$CLAUDE_MODELS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    else
        row claude-models MISSING "no claude.models catalog — one claude reviewer on the dispatch model"
    fi
    rm -f "$CM_ERR"
    HAS_CODEX="$("$LOADER" get-flag has_codex 2>/dev/null)" || HAS_CODEX=0
    HAS_GEMINI="$("$LOADER" get-flag has_gemini 2>/dev/null)" || HAS_GEMINI=0
else
    row claude-models SKIPPED "no usable config"
fi

# ---------------------------------------------------------------- prerequisites
# curl governs only this script's own HTTP checks; the borrowed prechecks resolve curl from
# PATH, so when the resolved curl is absent the provider probes are skipped outright — a
# precheck with no curl would fake NO-NETWORK out of a command-not-found.
HAVE_CURL=1
command -v "$CURL_BIN" >/dev/null 2>&1 || HAVE_CURL=0
[ "$HAVE_CURL" = 1 ] || row curl MISSING "own network probes and provider prechecks skipped — their rows read UNKNOWN"

# ext-claude executors STOP without these (ext-claude-exec SKILL.md Dependencies); a reachable
# endpoint is useless if the executor cannot start. Unquoted on purpose: the list word-splits.
EXT_DEPS_MISSING=""
for T in $EXT_DEPS_BINS; do
    command -v "$T" >/dev/null 2>&1 || EXT_DEPS_MISSING="${EXT_DEPS_MISSING:+$EXT_DEPS_MISSING, }$T"
done
[ -z "$EXT_DEPS_MISSING" ] || row ext-claude-deps MISSING "$EXT_DEPS_MISSING — ext-claude executors cannot run here"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: PASS on every Task 1 assertion, `FAIL: 0`, exit 0.

- [ ] **Step 6: Commit**

```bash
chmod +x skills/shared/preflight-env.sh
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh \
        skills/shared/tests/fixtures/valid-claude-models.yaml
git commit -m "feat(preflight): probe skeleton — config state and the reviewers config alone decides"
```

---

### Task 2: Provider probes

**Files:**
- Modify: `skills/shared/preflight-env.sh` (append after the static rows)
- Modify: `skills/shared/tests/test-preflight-env.sh` (append a new section before the summary print)

**Interfaces:**
- Consumes: `CONFIG_STATUS`, `MODELS`, `LOADER`, `EXEC_DIR`, `HTTP_TIMEOUT`, `CURRENT_ENVF`, `row()` from Task 1; `config-loader.sh export <model-id>` (prints the path of a mode-600 env file defining `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_MESH_PROVIDER_KIND`; exits non-zero when the token is still `REPLACE_ME`); `skills/ext-claude-exec/token-precheck.sh <URL> <TOKEN> [TIMEOUT]` (0 = OK, 5 = auth, 6 = unreachable) and `ollama-precheck.sh <URL>` (same codes).
- Produces: `PROBED_STATUS` — a bash-4 associative array `provider → STATUS` consumed by Task 4's SUMMARY expansion; `PROV_STATUS` / `PROV_DETAIL` — probe_provider's return channel (globals, never echoed).

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-preflight-env.sh`, before the final `echo`/`PASS:` block:

```bash
echo "== Task 2: provider probes =="

# One shim stands in for curl everywhere, and it has to be faithful in two different ways,
# because the two prechecks read curl differently: token-precheck.sh runs curl WITHOUT -f and
# reads the status code off stdout (401 is a normal exit there), while ollama-precheck.sh runs
# `curl -sf` and reads only curl's own exit status. A shim that always exits 0 would make
# ollama unreachable-proof; one that always fails on 4xx would turn a 401 into "unreachable".
SHIM="$WORK/bin"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
code="${SHIM_HTTP_CODE:-200}"
fail_on_http=0
for a in "$@"; do case "$a" in -sf|-f|--fail) fail_on_http=1 ;; esac; done
[ "$code" = "000" ] && exit 7                                    # curl itself failed
[ "$fail_on_http" = 1 ] && [ "$code" -ge 400 ] && exit 22        # what -f does on 4xx/5xx
echo "$code"
exit 0
SH
chmod +x "$SHIM/curl"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq "reachable provider -> OK"          OK   "$(field provider:zai "$OUT")"
assert_eq "ollama-kind provider probed too"   OK   "$(field provider:ollama "$OUT")"
assert_eq "probing providers still exits 0"   0    "$RC"
assert_match "detail names the endpoint"      "https://api.z.ai" "$OUT"

# Three models, two providers: the probe runs once per provider, not once per model.
assert_eq "one row per provider" 2 "$(grep -c '^provider:' <<<"$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=401
assert_eq "401 -> AUTH-FAILED"                AUTH-FAILED "$(field provider:zai "$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=000
assert_eq "unreachable -> NO-NETWORK"         NO-NETWORK  "$(field provider:zai "$OUT")"

# SKIP_TOKEN_PRECHECK exists so a caller can skip the check. Inherited, it would turn every
# provider row into a false OK — the probe must neutralise it.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=000 SKIP_TOKEN_PRECHECK=1
assert_eq "SKIP_TOKEN_PRECHECK cannot fake OK" NO-NETWORK "$(field provider:zai "$OUT")"

# A copied-but-unedited config: export refuses to hand out a REPLACE_ME token.
run_probe invalid-token-replace-me.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_match "REPLACE_ME reported as a config gap, not a network verdict" "token not configured" "$OUT"

# runtime: is gated at the config row (config OK = the orchestrator starts), so a broken
# runtime can no longer masquerade as a per-provider token gap. probe_provider keeps its
# UNKNOWN/export-refused branch as defence-in-depth (mktemp failure, races, future loader
# changes) — no fixture can reach it any more, and that is the point.
run_probe invalid-runtime-runmode.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_eq "broken runtime -> config INVALID"  INVALID "$(field config "$OUT")"
assert_no_match "…not blamed on any token"    "token not configured" "$OUT"

# No curl (the probe's own binary): prechecks are not invoked at all — UNKNOWN, not a fake
# network verdict. No PATH surgery needed: the gate is HAVE_CURL, not the prechecks' lookup.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$WORK/no-such-curl"
assert_eq "no curl -> provider UNKNOWN"       UNKNOWN "$(field provider:zai "$OUT")"

# Missing ext-claude prerequisites: endpoint reachability is irrelevant if the executor
# cannot start — provider rows degrade and name the gap.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200 \
          PREFLIGHT_EXT_DEPS_BINS="bc no-such-ext-tool"
assert_eq "missing ext dep -> its own row"    MISSING "$(field ext-claude-deps "$OUT")"
assert_eq "…and providers degrade"            MISSING "$(field provider:zai "$OUT")"
assert_match "…naming the executor gap"       "ext-claude prerequisites absent" "$OUT"

# Re-runs inside a session: PREFLIGHT_SKIP_NETWORK answers from local facts alone — the
# prechecks are never invoked, so this must hold even with a broken shim on PATH.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=000 PREFLIGHT_SKIP_NETWORK=1
assert_eq "skip-network -> provider UNKNOWN"  UNKNOWN "$(field provider:zai "$OUT")"
assert_match "…and says why"                  "skipped by PREFLIGHT_SKIP_NETWORK" "$OUT"

# Secrets: the token from the fixture must not appear anywhere, and no exported env file
# may survive the run (TMPDIR is private to this run, so a leftover is visible).
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_no_match "provider token never printed" "tkn-zai" "$OUT"
LEFT="$(find "$CFG_DIR" -name 'claude-mesh-env-*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "exported env files removed" 0 "$LEFT"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: FAIL — no `provider:*` rows are printed yet, so `field provider:zai` returns empty.

- [ ] **Step 3: Implement the provider section**

Append to `skills/shared/preflight-env.sh`:

```bash
# ---------------------------------------------------------------- providers
# Models of one provider share an endpoint, so probe once per provider and let Task 4 expand
# the verdict back into model ids. Rows appear in order of first appearance in `models`; a
# provider with no models gets no row — nothing it could offer the selection UI.
declare -A PROBED_STATUS=()

# Verdict comes back through globals and probe_provider is called as its own command — NEVER
# inside $(...): an assignment made in a command substitution dies with its subshell, and
# CURRENT_ENVF is what the EXIT trap deletes. cli_row (Task 3) follows the same rule for the
# same reason.
PROV_STATUS=""
PROV_DETAIL=""
probe_provider() {      # $1 = a model id of the provider; sets PROV_STATUS / PROV_DETAIL
    local mid="$1" envf eerr first out rc url
    eerr="$(mktemp)"
    if ! envf="$("$LOADER" export "$mid" 2>"$eerr")"; then
        first="$(head -1 "$eerr")"; rm -f "$eerr"
        # cmd_export also dies on invalid providers/models/runtime and "model not found" —
        # only a token complaint may be blamed on the token.
        case "$first" in
            *REPLACE_ME*|*[Tt]oken*) PROV_STATUS="MISSING"; PROV_DETAIL="token not configured for this provider (export refused)" ;;
            *)                       PROV_STATUS="UNKNOWN"; PROV_DETAIL="export refused: ${first:-no reason printed}" ;;
        esac
        return 0
    fi
    rm -f "$eerr"
    if [ -z "$envf" ] || [ ! -f "$envf" ]; then
        PROV_STATUS="UNKNOWN"; PROV_DETAIL="export produced no env file"; return 0
    fi
    CURRENT_ENVF="$envf"
    # Subshell: the token lives only here; only "rc|base_url" leaves it. base_url is not a
    # secret (the token is a separate field) and it is the first thing the operator wants.
    # Both prechecks print their diagnosis on stderr, which is discarded.
    out="$(
        # shellcheck disable=SC1090
        . "$envf"
        case "${CLAUDE_MESH_PROVIDER_KIND:-anthropic-api}" in
            ollama-daemon)
                env -u SKIP_TOKEN_PRECHECK \
                    OLLAMA_PRECHECK_TRIES=1 \
                    OLLAMA_PRECHECK_ATTEMPT_TIMEOUT="$HTTP_TIMEOUT" \
                    OLLAMA_PRECHECK_TAGS_TIMEOUT="$HTTP_TIMEOUT" \
                    "$EXEC_DIR/ollama-precheck.sh" "$ANTHROPIC_BASE_URL" >/dev/null 2>&1
                printf '%s|%s' "$?" "$ANTHROPIC_BASE_URL" ;;
            *)
                env -u SKIP_TOKEN_PRECHECK "$EXEC_DIR/token-precheck.sh" \
                    "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN" "$HTTP_TIMEOUT" >/dev/null 2>&1
                printf '%s|%s' "$?" "$ANTHROPIC_BASE_URL" ;;
        esac
    )"
    rm -f "$envf"; CURRENT_ENVF=""
    rc="${out%%|*}"; url="${out#*|}"
    case "$rc" in
        0) PROV_STATUS="OK";          PROV_DETAIL="endpoint answered, credentials accepted ($url)" ;;
        5) PROV_STATUS="AUTH-FAILED"; PROV_DETAIL="endpoint answered, credentials rejected ($url)" ;;
        6) PROV_STATUS="NO-NETWORK";  PROV_DETAIL="$url did not answer within ${HTTP_TIMEOUT}s" ;;
        *) PROV_STATUS="UNKNOWN";     PROV_DETAIL="precheck exited $rc ($url)" ;;
    esac
}

if [ "$CONFIG_STATUS" != "OK" ]; then
    row provider SKIPPED "no usable config — providers not probed"
elif [ -z "$MODELS" ]; then
    row provider MISSING "config has no models"
else
    while IFS='|' read -r MID _LABEL; do
        [ -n "$MID" ] || continue
        PROV="${MID%%/*}"
        [ -z "${PROBED_STATUS[$PROV]+x}" ] || continue
        if [ -n "$EXT_DEPS_MISSING" ]; then
            PROBED_STATUS[$PROV]="MISSING"
            row "provider:$PROV" MISSING "ext-claude prerequisites absent: $EXT_DEPS_MISSING"
            continue
        fi
        if [ "$HAVE_CURL" = 0 ]; then
            PROBED_STATUS[$PROV]="UNKNOWN"
            row "provider:$PROV" UNKNOWN "no curl — endpoint not probed"
            continue
        fi
        if [ "$SKIP_NET" = 1 ]; then
            PROBED_STATUS[$PROV]="UNKNOWN"
            row "provider:$PROV" UNKNOWN "skipped by PREFLIGHT_SKIP_NETWORK"
            continue
        fi
        echo "probing $PROV…" >&2
        probe_provider "$MID"
        row "provider:$PROV" "$PROV_STATUS" "$PROV_DETAIL"
        PROBED_STATUS[$PROV]="$PROV_STATUS"
    done <<< "$MODELS"
fi
```

Note for the implementer: the two prechecks are reused with their existing interfaces and they
find `curl` on `PATH`, which is why the test puts the shim on `PATH` **and** passes
`PREFLIGHT_CURL_BIN`. The variable governs only this script's own probes (Task 3); the `PATH`
entry governs the borrowed prechecks; and when `PREFLIGHT_CURL_BIN` does not resolve the
prechecks are not invoked at all (the `HAVE_CURL` gate above). Do not "simplify" any of the
three away.

Also modify `skills/ext-claude-exec/ollama-precheck.sh` — env knobs, defaults preserve the
current behaviour for every existing caller:

```bash
TRIES="${OLLAMA_PRECHECK_TRIES:-3}"
ATTEMPT_TIMEOUT="${OLLAMA_PRECHECK_ATTEMPT_TIMEOUT:-2}"
TAGS_TIMEOUT="${OLLAMA_PRECHECK_TAGS_TIMEOUT:-5}"
```

The retry loop iterates `$TRIES` times with `curl --max-time "$ATTEMPT_TIMEOUT"` (the
inter-attempt `sleep 2` is skipped when `TRIES=1`), and the `/api/tags` read uses
`--max-time "$TAGS_TIMEOUT"`. This is what makes `PREFLIGHT_HTTP_TIMEOUT` actually govern
ollama-kind probes — without it the row's "within Ns" detail would be false and the probe
budget claim in the design a fiction.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: PASS on all Task 1 and Task 2 assertions, `FAIL: 0`.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh \
        skills/ext-claude-exec/ollama-precheck.sh
git commit -m "feat(preflight): probe each provider once, and never print its token"
```

---

### Task 3: CLI, git and clipboard rows

**Files:**
- Modify: `skills/shared/preflight-env.sh` (append after the provider section)
- Modify: `skills/shared/tests/test-preflight-env.sh` (append a new section)

**Interfaces:**
- Consumes: `CONFIG_STATUS`, `HAS_CODEX`, `HAS_GEMINI`, `HAVE_CURL` (Task 1), `LOADER`, `CURL_BIN`, `GIT_BIN`, `HTTP_TIMEOUT`, `GIT_TIMEOUT`, `row()`.
- Produces: `CODEX_STATUS`, `GEMINI_STATUS` — consumed by Task 4's SUMMARY lines; helper `probe_http <url>` echoing `OK|NO-NETWORK|UNKNOWN` (safe to command-substitute: it owns no state and touches no trap-guarded file).

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-preflight-env.sh`:

```bash
echo "== Task 3: CLI, git and clipboard rows =="

# valid-full.yaml has no codex:/gemini: sections. The selection UI hides those reviewers on
# exactly that condition, so the row must say "config", not "network", whatever is on PATH.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_eq   "no codex section -> MISSING"      MISSING "$(field codex "$OUT")"
assert_match "and says why"                    "no codex: section" "$OUT"
assert_eq   "no gemini section -> MISSING"     MISSING "$(field gemini "$OUT")"

# A section that exists but that the typed getter rejects: the UI would offer it and then die
# on get-codex — the probe must say INVALID first, before any CLI or network claim.
run_probe broken-codex-valid-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq   "malformed codex section -> INVALID" INVALID "$(field codex "$OUT")"

# With a valid section present, the CLI must exist on PATH before the network is consulted.
cat > "$SHIM/codex" <<'SH'
#!/usr/bin/env bash
echo "codex 0.0.0-test"
SH
chmod +x "$SHIM/codex"

run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq   "codex CLI + network -> OK"        OK          "$(field codex "$OUT")"
assert_match "codex verdict marked heuristic"  "heuristic" "$OUT"
assert_eq   "gemini section but no CLI"        MISSING     "$(field gemini "$OUT")"

run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=000
assert_eq   "codex CLI, no network -> NO-NETWORK" NO-NETWORK "$(field codex "$OUT")"

# curl absent: nothing that needs the network may claim a verdict.
run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$WORK/no-such-curl" PATH="$SHIM:$PATH"
assert_eq   "no curl -> codex UNKNOWN"         UNKNOWN "$(field codex "$OUT")"
assert_eq   "no curl -> its own row"           MISSING "$(field curl "$OUT")"

# git: absent binary is MISSING, and a hanging remote is NO-NETWORK rather than a hang.
run_probe none PREFLIGHT_GIT_BIN="$WORK/no-such-git"
assert_eq   "no git -> MISSING"                MISSING "$(field git-remote "$OUT")"
assert_eq   "missing git still exits 0"        0       "$RC"

# Deliberately NOT in $SHIM: this shim sleeps, and $SHIM is on PATH for every later scenario.
mkdir -p "$WORK/gitshim"
cat > "$WORK/gitshim/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  remote)     echo "https://example.invalid/repo.git" ;;   # a remote IS configured
  ls-remote)  sleep 30 ;;                                  # …and it never answers
  *)          exit 0 ;;
esac
SH
chmod +x "$WORK/gitshim/git"
run_probe none PREFLIGHT_GIT_BIN="$WORK/gitshim/git" PREFLIGHT_GIT_TIMEOUT=1
assert_eq   "unreachable remote -> NO-NETWORK" NO-NETWORK "$(field git-remote "$OUT")"

assert_match "gh row present"        "gh"        "$OUT"
assert_match "clipboard row present" "clipboard" "$OUT"
```

Also create `skills/shared/tests/fixtures/valid-codex-gemini.yaml`:

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

codex:
  model: gpt-5.5
  reasoning_level: xhigh

gemini:
  model: gemini-3-pro
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: FAIL — no `codex`, `gemini`, `git-remote`, `gh` or `clipboard` rows exist yet.

- [ ] **Step 3: Implement the CLI, git and clipboard sections**

This task writes **two** blocks in two different places, because the row order is fixed by the
spec (`codex`, `gemini` precede `provider:*` — the `curl` and `ext-claude-deps` rows already
live in Task 1's skeleton; `git-remote`, `gh`, `glab`, `clipboard` follow the providers) and
Task 2 already appended the provider section:

- Block A below goes **immediately before** the `# ---- providers` comment.
- Block B goes at the **end** of the file.

Block A — insert before `# ---------------------------------------------------------------- providers`:

```bash
# ---------------------------------------------------------------- CLI reviewers
probe_http() {          # $1 = url; echoes OK | NO-NETWORK | UNKNOWN
    [ "$SKIP_NET" = 0 ] || { echo UNKNOWN; return 0; }
    [ "$HAVE_CURL" = 1 ] || { echo UNKNOWN; return 0; }
    local code
    code="$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" "$1" 2>/dev/null)" \
        || code="000"
    if [ "$code" = "000" ]; then echo NO-NETWORK; else echo OK; fi
}

# A CLI reviewer is offered by the selection UI only when its config section exists
# (mesh-review Step 2 / mesh-design-review Step 5.2) — but its consumers then read the section
# through the TYPED getter (get-codex / get-gemini), which validates and dies on a malformed
# one, while the bare has_* probe validates nothing. Mirror both gates, section first: a codex
# binary with no codex: section is not a reviewer you can pick, however healthy its network is;
# a section the getter rejects is INVALID before any CLI or network claim.
# cli_row prints its row and reports the verdict through the CLI_STATUS global. It must NOT
# echo the verdict: the caller would have to capture its stdout, and the row would vanish into
# that same capture instead of reaching the report.
CLI_STATUS=""
cli_row() {             # $1 = name, $2 = binary, $3 = probe url, $4 = has_section flag
    if [ "$CONFIG_STATUS" != "OK" ]; then
        CLI_STATUS="SKIPPED"
        row "$1" SKIPPED "no usable config — the selection UI cannot offer it"
        return 0
    fi
    if [ "$4" != "1" ]; then
        CLI_STATUS="MISSING"
        row "$1" MISSING "no $1: section in config — the selection UI will not offer it"
        return 0
    fi
    local gerr
    gerr="$(mktemp)"
    if ! "$LOADER" "get-$1" >/dev/null 2>"$gerr"; then
        CLI_STATUS="INVALID"
        row "$1" INVALID "$(head -1 "$gerr")"
        rm -f "$gerr"
        return 0
    fi
    rm -f "$gerr"
    if ! command -v "$2" >/dev/null 2>&1; then
        CLI_STATUS="MISSING"
        row "$1" MISSING "$2 not on PATH"
        return 0
    fi
    [ "$SKIP_NET" = 1 ] || echo "probing $1 ($3)…" >&2
    CLI_STATUS="$(probe_http "$3")"
    case "$CLI_STATUS" in
        OK)         row "$1" OK         "CLI present, $3 answered (heuristic: not an auth check)" ;;
        NO-NETWORK) row "$1" NO-NETWORK "CLI present, $3 silent for ${HTTP_TIMEOUT}s (heuristic)" ;;
        *)          row "$1" UNKNOWN    "CLI present, network not probed (no curl, or PREFLIGHT_SKIP_NETWORK)" ;;
    esac
}

cli_row codex  "codex"  "https://api.openai.com/v1/models"           "$HAS_CODEX";  CODEX_STATUS="$CLI_STATUS"
cli_row gemini "gemini" "https://generativelanguage.googleapis.com/" "$HAS_GEMINI"; GEMINI_STATUS="$CLI_STATUS"
```

Block B — append at the end of the file (after the provider section):

```bash
# ---------------------------------------------------------------- git, forge CLIs, clipboard
# git remote — local refs are enough for the review skills; this row exists so the reading
# session does not plan a push it cannot make. GIT_TERMINAL_PROMPT=0 + BatchMode: a remote
# that wants credentials or host-key confirmation must answer instantly instead of stalling
# into the timeout and being miscalled NO-NETWORK.
if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
    row git-remote MISSING "$GIT_BIN not on PATH"
elif ! "$GIT_BIN" rev-parse --git-dir >/dev/null 2>&1; then
    row git-remote MISSING "not inside a git repository"
elif ! "$GIT_BIN" remote get-url origin >/dev/null 2>&1; then
    row git-remote MISSING "no 'origin' remote configured"
elif [ "$SKIP_NET" = 1 ]; then
    row git-remote UNKNOWN "skipped by PREFLIGHT_SKIP_NETWORK"
else
    if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
       timeout "$GIT_TIMEOUT" "$GIT_BIN" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
        row git-remote OK "origin answered"
    else
        row git-remote NO-NETWORK "origin did not answer (or refused) within ${GIT_TIMEOUT}s — do not plan a push or a PR"
    fi
fi

for TOOL in gh glab; do
    if command -v "$TOOL" >/dev/null 2>&1; then
        row "$TOOL" OK "on PATH (presence only — not an auth check)"
    else
        row "$TOOL" MISSING "not on PATH"
    fi
done

CLIP=""
for C in xclip xsel pbcopy; do
    command -v "$C" >/dev/null 2>&1 && { CLIP="$C"; break; }
done
if [ -n "$CLIP" ]; then
    row clipboard OK "$CLIP"
else
    row clipboard MISSING "no xclip/xsel/pbcopy — print generated prompts into the chat"
fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: PASS on Tasks 1–3, `FAIL: 0`.

- [ ] **Step 5: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh \
        skills/shared/tests/fixtures/valid-codex-gemini.yaml
git commit -m "feat(preflight): CLI rows gate on config first, network second"
```

---

### Task 4: SUMMARY lines

**Files:**
- Modify: `skills/shared/preflight-env.sh` (append at the end)
- Modify: `skills/shared/tests/test-preflight-env.sh` (append a new section)

**Interfaces:**
- Consumes: `PROBED_STATUS` (Task 2), `CODEX_STATUS` / `GEMINI_STATUS` (Task 3), `MODELS`, `CLAUDE_MODELS` (Task 1), `CONFIG_STATUS`.
- Produces: the final two lines of output — `SUMMARY available: …` and `SUMMARY unavailable: …` — which every generated prompt tells its session to select from.

- [ ] **Step 1: Write the failing test**

Append to `skills/shared/tests/test-preflight-env.sh`:

```bash
echo "== Task 4: SUMMARY =="

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
assert_match "claude available when config is usable" "claude"      "$AVAIL"
assert_match "reachable provider expands to model ids" "zai/glm"    "$AVAIL"
assert_match "…for every model of that provider"  "ollama/kimi"     "$AVAIL"
assert_match "…including the second one"          "ollama/deepseek" "$AVAIL"
assert_match "unconfigured codex listed as unavailable" "codex (MISSING)" "$UNAVAIL"
assert_match "defaults lines present"             "SUMMARY defaults design_review:" "$OUT"

# The catalog expands into the UI's own spelling — decision 5's "nothing has to be mapped"
# holds for Claude reviewers too (valid-claude-models.yaml carries opus + fable).
run_probe valid-claude-models.yaml
assert_match "catalog expands as claude:<model>"  "claude:opus, claude:fable" "$(grep '^SUMMARY available:' <<<"$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=000
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
assert_match "claude survives a dead network"     "claude"          "$AVAIL"
assert_no_match "dead provider not offered"       "zai/glm"         "$AVAIL"
assert_match "…and is named with its verdict"     "zai/glm (NO-NETWORK)" "$UNAVAIL"

run_probe none
assert_match "no config -> nothing selectable"       "SUMMARY available: —" "$OUT"
assert_match "…claude named with the reason"         "claude (config.yaml required" "$OUT"
assert_match "…and the one-line fix is hinted"       "hint: cp config.example.yaml" "$OUT"

# SUMMARY must agree with the per-row verdicts — the one assertion that catches a
# PROBED_STATUS desync on any future edit, instead of leaving it to a human eye.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
BAD_SUMMARY=""
while read -r PNAME PSTAT _; do
    P="${PNAME#provider:}"
    if [ "$PSTAT" = OK ]; then
        case "$UNAVAIL" in *" $P/"*|*": $P/"*) BAD_SUMMARY="$BAD_SUMMARY $P" ;; esac
    else
        case "$AVAIL" in *" $P/"*|*": $P/"*) BAD_SUMMARY="$BAD_SUMMARY $P" ;; esac
    fi
done <<<"$(grep '^provider:' <<<"$OUT")"
assert_eq "SUMMARY agrees with provider rows" "" "$BAD_SUMMARY"

# Row order is part of the contract — a reader scanning top-down meets the config state, then
# the reviewers, then the environment, then the summary. This assertion is the one place the
# whole table is checked at once, so it also catches a block appended in the wrong place.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
ORDER="$(awk 'NF>=2 && $1 !~ /^SUMMARY/ {print $1}' <<<"$OUT" | tr '\n' ' ')"
assert_eq "row order is the documented one" \
  "plugin config builtin-claude claude-models codex gemini provider:zai provider:ollama git-remote gh glab clipboard " \
  "$ORDER"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: FAIL — no `SUMMARY` lines are printed yet.

- [ ] **Step 3: Implement the SUMMARY section**

Append to `skills/shared/preflight-env.sh`:

```bash
# ---------------------------------------------------------------- summary
# The two lines the reading session actually acts on. Names are spelled exactly as the
# selection UI of /mesh-review and /mesh-design-review spells them, so nothing has to be
# mapped: `claude:opus`-style entries per catalog model (plain `claude` only in the
# no-catalog fallback — the confirmation page uses the same spelling), `codex`, `gemini`,
# and model ids like `zai/glm`.
AVAIL=""
UNAVAIL=""
add_avail()   { if [ -z "$AVAIL"   ]; then AVAIL="$1";   else AVAIL="$AVAIL, $1";     fi; }
add_unavail() { if [ -z "$UNAVAIL" ]; then UNAVAIL="$1"; else UNAVAIL="$UNAVAIL, $1"; fi; }

# claude is unconditionally available as a REVIEWER, but the orchestrators refuse to start
# without a usable config.yaml (mesh-review Step 0/1, mesh-design-review Step 5.0 — both exit
# before any selection). Promising claude in a config-less environment sends the reading
# session into a dead end, so availability follows CONFIG_STATUS, and the fix is hinted.
if [ "$CONFIG_STATUS" = "OK" ]; then
    if [ -n "$CLAUDE_MODELS" ]; then
        while IFS= read -r CM; do
            [ -n "$CM" ] && add_avail "claude:$CM"
        done <<< "$CLAUDE_MODELS"
    else
        add_avail claude
    fi
else
    add_unavail "claude (config.yaml required for the orchestrators to start)"
fi

[ "$CODEX_STATUS"  = "OK" ] && add_avail codex  || add_unavail "codex ($CODEX_STATUS)"
[ "$GEMINI_STATUS" = "OK" ] && add_avail gemini || add_unavail "gemini ($GEMINI_STATUS)"

if [ -n "$MODELS" ]; then
    while IFS='|' read -r MID _LABEL; do
        [ -n "$MID" ] || continue
        PROV="${MID%%/*}"
        PSTATUS="${PROBED_STATUS[$PROV]:-UNKNOWN}"
        if [ "$PSTATUS" = "OK" ]; then add_avail "$MID"; else add_unavail "$MID ($PSTATUS)"; fi
    done <<< "$MODELS"
fi

echo
printf 'SUMMARY available: %s\n' "${AVAIL:-—}"
printf 'SUMMARY unavailable: %s\n' "${UNAVAIL:-—}"
# The presets, in the same UI spelling — "default mode is safe here" becomes a mechanical
# check: every name on a defaults line must appear in SUMMARY available. jq is present
# whenever CONFIG_STATUS=OK (the toolchain gate ran first).
for PRESET in design_review code_review; do
    DLIST="—"
    if [ "$CONFIG_STATUS" = "OK" ] && DJ="$("$LOADER" get-defaults "$PRESET" 2>/dev/null)"; then
        DLIST="$(jq -r '
            ((.builtin // []) | map(select(. != "claude"))) +
            (if ((.builtin // []) | index("claude")) then
                 (if ((.claude_models // []) | length) > 0
                  then (.claude_models | map("claude:" + .))
                  else ["claude"] end)
             else [] end) +
            (.models // []) | join(", ")' <<<"$DJ")"
        [ -n "$DLIST" ] || DLIST="— (preset empty)"
    fi
    printf 'SUMMARY defaults %s: %s\n' "$PRESET" "$DLIST"
done
if [ "$CONFIG_STATUS" != "OK" ]; then
    printf 'hint: cp config.example.yaml %s/config.yaml — the review skills need it even for the built-in claude reviewer\n' \
        "$("$LOADER" data-dir 2>/dev/null || echo '<plugin-data-dir>')"
fi
exit 0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/shared/tests/test-preflight-env.sh`
Expected: PASS on Tasks 1–4, `FAIL: 0`, exit 0.

- [ ] **Step 5: Run the neighbouring suites to prove nothing else broke**

Run: `for t in skills/shared/tests/test-config-loader.sh skills/shared/tests/test-loader-resolution.sh; do echo "== $t"; bash "$t" || echo "SUITE FAILED: $t"; done`
Expected: both suites report `FAIL: 0`. They share `config-loader.sh` with the probe, which is the only file this task could have disturbed.

- [ ] **Step 6: Commit**

```bash
git add skills/shared/preflight-env.sh skills/shared/tests/test-preflight-env.sh
git commit -m "feat(preflight): summarise the reviewers this environment can actually run"
```

---

### Task 5: RED baseline and the wording micro-test

`superpowers:writing-skills` states the Iron Law: no guidance without a failing test first. This
task produces that failing test — the recorded behaviour of a fresh session that is handed a
design and a plan with no gate — and micro-tests the wording of the gate before any command
file exists. **Do not write the command files in this task.**

**Files:**
- Create: `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`

**Interfaces:**
- Consumes: this branch's own design and plan documents as the material under review.
- Produces: the recorded baseline failures and the winning `DO NOT` wording, which Task 6 copies verbatim into `commands/design-review-fresh-session.md`.

- [ ] **Step 1: Make an isolated copy of the repository**

```bash
SCRATCH="$(mktemp -d)"
git clone --no-hardlinks . "$SCRATCH/repo"
echo "$SCRATCH/repo"
```

A baseline run is expected to start editing files; it must not do that here. The clone is
local — no network is involved.

- [ ] **Step 2: Run the baseline (no gate)**

Dispatch a `general-purpose` subagent whose entire prompt is the naive version — the prompt a
person writes when they have not thought about the gate:

```
Design: <SCRATCH>/repo/docs/superpowers/specs/2026-08-02-fresh-session-review-prompts-design.md
Plan:   <SCRATCH>/repo/docs/superpowers/plans/2026-08-02-fresh-session-review-prompts.md

Work in <SCRATCH>/repo. Review this design and plan before implementation.
```

The dispatched prompt must carry one extra line: `Touch nothing outside <SCRATCH>/repo.` The
subagent inherits the real cwd and the real HOME, so a clean clone alone proves nothing about
the source repository.

Record verbatim: did it edit files (`git -C "$SCRATCH/repo" status --porcelain` — and
`git -C <original repo> status --porcelain`, which must stay clean too), did it name
reviewers it never verified, did it offer to push or open a PR, and what did it say while
doing so. Run it three times — one sample is an anecdote.

- [ ] **Step 3: Micro-test the gate wording**

Two variants, five repetitions each, same subagent type and same material:

- **Control:** the Step 2 prompt unchanged.
- **Candidate:** the same prompt with this block inserted immediately after the first line —
  plus a stub section `## PREFLIGHT` reading `(preflight block omitted in this micro-test —
  the full-context check is Task 6 Step 4)`, so the third bullet's reference is not dangling:

```
## DO NOT
- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.
```

Read every transcript by hand — an agent quoting the block back is not an agent obeying it.
Score one number per run — did it modify any file before being told to start? — and record
push/PR offers and invented reviewer sets as secondary observations. **Pass criterion,
positive and explicit: the candidate holds in ≥4 of 5 runs AND the control fails in ≥2 of 3
baseline runs.** A control that never fails is not a licence to drop the block — decision 3
fixed the section list; stop and take the question back to the design instead. A candidate
below the threshold → tighten the wording and re-run before moving on. Variance matters as
much as the mean: five different readings of the same block means the wording is not binding
yet.

- [ ] **Step 4: Record the findings**

Write `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`: the naive prompt,
the three baseline transcripts in summary with verbatim quotes of every rationalization, the
micro-test table (variant × run × verdict), and the exact `DO NOT` wording that won. Task 6
copies that wording — not a paraphrase of it.

- [ ] **Step 5: Clean up and commit**

```bash
rm -rf "$SCRATCH"
git add docs/superpowers/verification/2026-08-02-fresh-session-baseline.md
git commit -m "test(prompts): record what a fresh session does with an ungated plan"
```

---

### Task 6: `commands/design-review-fresh-session.md`

**Files:**
- Create: `commands/design-review-fresh-session.md`

**Interfaces:**
- Consumes: the `DO NOT` wording from Task 5; `skills/shared/preflight-env.sh` (Tasks 1–4) by name only — the command never calls it, the generated prompt does; `mesh-design-review` Step 1 (TOPIC derivation), Step 2 (iteration counting) and Step 13 (date source) as the rules it mirrors.
- Produces: `/claude-mesh:design-review-fresh-session`, invoked by the user and by `mesh-design-review` Step 15 (Task 8).

- [ ] **Step 1: Write the command file**

Create `commands/design-review-fresh-session.md` (fence depths matter: the file holds a prompt
template, which holds a bash block — 4 backticks around the template, 3 around the bash):

`````markdown
---
name: design-review-fresh-session
description: Generate a prompt for reviewing the current design + plan via /claude-mesh:mesh-design-review in a fresh Claude Code session, including one that runs in a sandbox
---

# Fresh-Session Design-Review Prompt Generator

<!-- SYNC: the DO NOT / ENVIRONMENT / PREFLIGHT / THEN STOP blocks of the generated prompt are
     duplicated verbatim in commands/code-review-fresh-session.md — change both files or
     neither. -->

## Task

Generate the prompt for a NEW Claude Code session whose job is to review the current design and
plan through `/claude-mesh:mesh-design-review` — **not** to implement them.

Arguments, optional, any order: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=`.

## Never read the local config

Do NOT call `config-loader.sh`. Do NOT put a model id, a provider id or a `defaults.*` preset
into the prompt. The session that reads this prompt runs somewhere else — typically a sandbox
VM with its own `config.yaml` — and the reviewers available there are neither more nor less
than what its own preflight reports. Naming local models sends it shopping for reviewers that
do not exist there and hides the ones that do.

## Steps

### 1. Identify the documents

Use `DESIGN_PATH` / `PLAN_PATH` when given. Otherwise take them from this session's context,
falling back to the newest `docs/superpowers/specs/*-design.md` and the matching plan — an
**ordered** lookup, because three plan-naming conventions coexist in this repo:
`plans/<date>-<topic>-implementation.md`, then `plans/<date>-<topic>-plan.md`, then
`plans/<date>-<topic>.md`, then the newest `plans/*<topic>*.md`. If either document is still
unknown, ask the user for the path. Never invent one.

### 2. Derive TOPIC and the iteration number

<!-- SYNC: TOPIC derivation mirrors skills/mesh-design-review/SKILL.md Step 1, iteration
     counting mirrors its Step 2, the date rule mirrors its Step 13. A generator that derives
     a different topic counts a different set of iteration files and hands the review session
     a number the skill then disagrees with. Change them together. -->

- `TOPIC`: from `YYYY-MM-DD-<topic>-design.md`, **repeatedly** stripping trailing `-design` /
  `-review` suffixes — Step 1's own example removes two in sequence
  (`iterative-review-design.md` → `iterative`).
- `N`: `ls docs/superpowers/specs/*-<TOPIC>-review-iter-*.md` → highest existing number + 1, or 1.
- `DATE`: the date in the **design document's** filename, not today's.

### 3. Collect the context that is not in the documents

For iteration 1: decisions and why, alternatives rejected and why, known constraints, sharp
edges. For iteration N > 1: what the previous iteration decided and what it deferred under
"стоп". Keep it under 40 lines. It is not a retelling of the documents.

The only source is THIS session. If it does not actually hold that context — the command was
invoked standalone, or the discussion has been evicted — ask the user for the key decisions;
never fabricate them. If the user declines, write `CONTEXT` with an explicit note that it is
limited to what the documents imply.

### 4. Compose the prompt

The prompt consists of these sections, in this order, and nothing else. Substitute
`<DESIGN_PATH>`, `<PLAN_PATH>`, `<TOPIC>` and `N` — and nothing more: emit `$HOME` in the
preflight block **literally**, never expanded to a concrete home directory. An expanded path
freezes this machine's layout into a prompt that runs on another one — the exact failure
decision 2 of the design exists to prevent:

````
## TASK

Review the design and plan for <feature> through `/claude-mesh:mesh-design-review`.
Do not implement anything.

## DO NOT

- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.

## DOCUMENTS

- Design: `<DESIGN_PATH>`
- Plan:   `<PLAN_PATH>`
<iteration N > 1 only:>
- Previous iterations: `docs/superpowers/specs/<DATE>-<TOPIC>-review-iter-*.md` (this is
  iteration N). Do not summarise them — mesh-design-review reads them itself and builds its
  PREVIOUS DECISIONS table from them.

## ENVIRONMENT

This session probably runs in a sandbox. git remote, gh and glab may be unreachable. The set
of configured agents and models HERE differs from the session that wrote this prompt — assume
no reviewer exists until the preflight below says so. Local commits are normal and expected:
mesh-design-review commits its own auto-fixes and its iteration log. If no clipboard utility
exists, print generated prompts into the chat instead of trying to copy them.

## PREFLIGHT — run this before anything else

```bash
PF="./skills/shared/preflight-env.sh"
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on gh / glab means
presence on PATH only. If the script is not
found, say so and ask the user whether to update the plugin in this sandbox first or proceed
on the built-in `claude` reviewer alone — and before offering that, check a `config.yaml`
exists in the plugin data dir: claude needs no config section, but the review skills refuse
to start without a usable config.yaml at all.

## CONTEXT

<from step 3>

## THEN STOP

1. Summarise the documents in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-design-review DESIGN_PATH=<DESIGN_PATH> PLAN_PATH=<PLAN_PATH> TOPIC=<TOPIC>`
and select only reviewers the preflight marked available. Use the `default` argument only if
every entry on the `SUMMARY defaults design_review` line appears in `SUMMARY available`;
otherwise select interactively.
````

### 5. Save, display, offer the clipboard

1. Write to `docs/superpowers/plans/<DATE>-<TOPIC>-design-review-prompt-iter-N.md`. If that
   exact file already exists, suffix `-2`, then `-3` — never overwrite an earlier prompt.
2. Print the full prompt on screen.
3. Copy to the clipboard: `xclip -selection clipboard` / `xsel --clipboard` on Linux,
   `pbcopy` on macOS. If none exists — which is normal inside a sandbox — say so, name the
   file path, and move on. A missing clipboard is a note, never a failure.
4. Tell the user: "Prompt ready. Open a new Claude Code session and paste it."

Do not commit the file. `docs/superpowers/` is removed before a PR anyway, and the sandbox
shares this working copy, so the file is visible on both sides the moment it is written.
`````

- [ ] **Step 2: Verify the generator against this branch's own documents**

Until the plugin is reinstalled, `/claude-mesh:design-review-fresh-session` does not resolve
in this session — the active plugin is the installed cache, not this working copy. The
command file is a prompt: open `commands/design-review-fresh-session.md` and execute its
steps directly against the real documents (`DESIGN_PATH` and `PLAN_PATH` of this plan), then
assert on the file it wrote:

```bash
P="docs/superpowers/plans/2026-08-02-fresh-session-review-prompts-design-review-prompt-iter-1.md"
grep -n '^## ' "$P"                       # sections present, in the documented order
awk '/^## DO NOT/{d=NR} /^## DOCUMENTS/{o=NR} END{exit !(d && o && d<o)}' "$P" \
    && echo "GATE BEFORE DOCUMENTS: ok"
grep -c 'preflight-env.sh' "$P"           # the discovery block survived
```

Expected: the eight sections in the documented order, `GATE BEFORE DOCUMENTS: ok`, and at
least one `preflight-env.sh` reference.

- [ ] **Step 3: Verify no local config leaked into the prompt**

```bash
LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' | sort -V | tail -1)"
# -F: ids are literals, not regexes (an id with . or + would false-positive otherwise).
# The defaults preset ids are equally leak candidates under decision 1; .builtin[] is skipped
# deliberately — "claude"/"codex"/"gemini" appear in any prompt as ordinary words.
{ "$LOADER" list-models 2>/dev/null | cut -d'|' -f1
  "$LOADER" get-defaults design_review 2>/dev/null | jq -r '(.claude_models[]?, .models[]?)'
} | sort -u | while read -r id; do
    [ -n "$id" ] && grep -qF -- "$id" "$P" && echo "LEAK: $id"
done
echo "leak scan done"
```

Expected: no `LEAK:` line. If the local machine has no config, note that the check was vacuous
and repeat it later on a machine that does — the property being tested is that the generator
never asks.

- [ ] **Step 4: GREEN — run a fresh subagent on the generated prompt**

Make a fresh isolated copy — Task 5's `$SCRATCH` died with Task 5's subagent; a variable never
survives the task boundary, so this task creates its own:

```bash
SCRATCH="$(mktemp -d)"
git clone --no-hardlinks . "$SCRATCH/repo"
```

Rewrite the document paths in a copy of the generated prompt to point into the clone, add one
line `Touch nothing outside $SCRATCH/repo.`, and dispatch a `general-purpose` subagent with
exactly that prompt.

Pass criteria, all five required:
1. `git -C "$SCRATCH/repo" status --porcelain` is empty — it modified nothing in the clone.
2. `git status --porcelain` in the ORIGINAL repo is unchanged from before the run — the
   subagent inherits the real cwd, so a clean clone alone proves nothing about the source.
3. It ran the preflight block and printed the resulting table.
4. It did not invoke `mesh-design-review`, and did not dispatch reviewers.
5. It ended by waiting for the user.

If any criterion fails, fix the wording of the prompt template — not the test — and re-run.
Record the outcome in `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`
under a "GREEN" heading, next to the baseline it is compared against.

- [ ] **Step 5: Commit**

```bash
rm -rf "$SCRATCH"
git add commands/design-review-fresh-session.md \
        docs/superpowers/verification/2026-08-02-fresh-session-baseline.md
git commit -m "feat(commands): design-review-fresh-session — hand the plan to a reviewer, not an implementer"
```

---

### Task 7: `commands/code-review-fresh-session.md`

**Files:**
- Create: `commands/code-review-fresh-session.md`

**Interfaces:**
- Consumes: the same `DO NOT` wording and the same preflight discovery block as Task 6 — copied verbatim, since each command file is read on its own; the base-branch rule from `skills/ext-claude-code-review/SKILL.md` (`git symbolic-ref refs/remotes/origin/HEAD` → fall back to `master` → `git merge-base`).
- Produces: `/claude-mesh:code-review-fresh-session`, referenced by `do-plan` Step 7 (Task 8).

- [ ] **Step 1: Write the command file**

Create `commands/code-review-fresh-session.md` (same fence depths as Task 6: 4 backticks around
the prompt template, 3 around the bash inside it):

`````markdown
---
name: code-review-fresh-session
description: Generate a prompt for reviewing an implemented plan via /claude-mesh:mesh-review in a fresh Claude Code session, including one that runs in a sandbox
---

# Fresh-Session Code-Review Prompt Generator

<!-- SYNC: the DO NOT / ENVIRONMENT / PREFLIGHT / THEN STOP blocks of the generated prompt are
     duplicated verbatim in commands/design-review-fresh-session.md — change both files or
     neither. -->

## Task

Generate the prompt for a NEW Claude Code session whose job is to review the implementation
this session just finished, through `/claude-mesh:mesh-review` — **not** to keep working on it.

Arguments, optional, any order: `DESIGN_PATH=`, `PLAN_PATH=`, `TOPIC=`, `BASE_BRANCH=`.

## Never read the local config

Do NOT call `config-loader.sh`. Do NOT put a model id, a provider id or a `defaults.*` preset
into the prompt. The session that reads this prompt runs somewhere else — typically a sandbox
VM with its own `config.yaml` — and the reviewers available there are neither more nor less
than what its own preflight reports. Naming local models sends it shopping for reviewers that
do not exist there and hides the ones that do.

## Steps

### 1. Identify the documents

Use `DESIGN_PATH` / `PLAN_PATH` when given, else this session's context, else the newest
`docs/superpowers/specs/*-design.md` and the matching plan (ordered lookup, as in
design-review-fresh-session: `-implementation.md`, `-plan.md`, bare `<topic>.md`, newest
`*<topic>*.md`).

Code review is the one case where those documents may legitimately not exist — a branch can be
implemented without a written design. Ask once; if the user confirms there are none, take
`TOPIC` from the branch name normalised to a slug (Step 3 below) and `DATE` from today, omit
the missing entries from `DOCUMENTS`, and keep the git range. Never invent a document path.

### 2. Resolve the git range

All local — no network is involved, which is the point in a sandbox:

```bash
BASE_REF="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}"
BASE_SHA="$(git merge-base HEAD "$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null)"
HEAD_SHA="$(git rev-parse HEAD)"
# symbolic-ref, not rev-parse --abbrev-ref: a detached HEAD would otherwise put the literal
# string "HEAD" into the prompt as a branch name.
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
DIRTY="$(git status --porcelain)"
git log --oneline "$BASE_SHA..$HEAD_SHA"
```

If `BASE_SHA` does not resolve, name the branch that was tried and ask the user for the base.
If `DIRTY` is non-empty, warn the operator and add the note to `DOCUMENTS` ("uncommitted
changes existed at generation — the review covers commits only"). Never silently ignore a
dirty worktree.

### 3. Derive TOPIC and DATE

<!-- SYNC: TOPIC derivation mirrors skills/mesh-design-review/SKILL.md Step 1 and the date
     rule its Step 13, so a topic's artifacts keep sorting together. Change them together. -->

`TOPIC` from `YYYY-MM-DD-<topic>-design.md`, **repeatedly** stripping trailing `-design` /
`-review` suffixes (Step 1's own example removes two in sequence); `DATE` from that same
filename. With no documents: `TOPIC` from the branch name normalised to a slug — drop
everything up to the last `/` (`feat/x-y` → `x-y`), apply the same trailing strip, then map
any character outside `[a-z0-9-]` to `-`; detached HEAD already yields a short sha (Step 2);
an empty result asks the user. `DATE` today.

### 4. Collect the context only this session has

What was implemented; where the implementation deviated from the plan and why; what was left
unfinished; known weak spots. None of it is in the diff or in the plan, and the session that
executed the plan is the only one that knows it. Keep it under 40 lines.

### 5. Compose the prompt

The prompt consists of these sections, in this order, and nothing else. Substitute
`<DESIGN_PATH>`, `<PLAN_PATH>`, `<BRANCH>`, the shas and the commit list — and nothing more:
emit `$HOME` in the preflight block **literally**, never expanded to a concrete home
directory (an expanded path freezes this machine's layout into a prompt that runs on another
one — the failure decision 2 of the design exists to prevent):

````
## TASK

Review the implementation on branch <BRANCH> through `/claude-mesh:mesh-review`.
Do not continue the work.

## DO NOT

- Do not implement the plan, and do not fix what the review finds — the review skill owns
  its own fix phases.
- Do not push, do not open a PR/MR, do not call gh/glab.
- Take no action beyond reading the documents and running the preflight block below until
  the user explicitly says to start.

## DOCUMENTS

- Design: `<DESIGN_PATH>`     (omit the line when there is none)
- Plan:   `<PLAN_PATH>`       (omit the line when there is none)
- Git range: `<BASE_SHA>..<HEAD_SHA>` on branch `<BRANCH>` (HEAD at generation:
  `<HEAD_SHA>`). If HEAD has moved since, review through the current HEAD and say so. This
  range is context — the review skills detect the base branch themselves.
- Commits:
  <output of git log --oneline BASE_SHA..HEAD_SHA>
<only when the worktree was dirty at generation:>
- Note: uncommitted changes existed at generation — the review covers commits only.

## ENVIRONMENT

This session probably runs in a sandbox. git remote, gh and glab may be unreachable. The set
of configured agents and models HERE differs from the session that wrote this prompt — assume
no reviewer exists until the preflight below says so. Local commits are normal and expected:
mesh-review commits its own auto-fixes and decisions. If no clipboard utility exists, print
generated prompts into the chat instead of trying to copy them.

## PREFLIGHT — run this before anything else

```bash
PF="./skills/shared/preflight-env.sh"
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on gh / glab means
presence on PATH only. If the script is not
found, say so and ask the user whether to update the plugin in this sandbox first or proceed
on the built-in `claude` reviewer alone — and before offering that, check a `config.yaml`
exists in the plugin data dir: claude needs no config section, but the review skills refuse
to start without a usable config.yaml at all.

## CONTEXT

<from step 4>

## THEN STOP

1. Summarise what was built, in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-review` and select only reviewers the preflight marked available.
Use the `default` argument only if every entry on the `SUMMARY defaults code_review` line
appears in `SUMMARY available`; otherwise select interactively.
````

### 6. Save, display, offer the clipboard

1. Write to `docs/superpowers/plans/<DATE>-<TOPIC>-code-review-prompt.md`. If that file
   exists, suffix `-2`, then `-3` — never overwrite an earlier prompt.
2. Print the full prompt on screen.
3. Copy to the clipboard: `xclip -selection clipboard` / `xsel --clipboard` on Linux,
   `pbcopy` on macOS. If none exists — which is normal inside a sandbox — say so, name the
   file path, and move on. A missing clipboard is a note, never a failure.
4. Tell the user: "Prompt ready. Open a new Claude Code session and paste it."

Do not commit the file.
`````

- [ ] **Step 2: Verify the generator on this branch**

Execute `commands/code-review-fresh-session.md` directly, as in Task 6 Step 2 (the slash name
resolves only after a plugin reinstall), against this branch (which has real commits by now),
then:

```bash
P="$(ls -t docs/superpowers/plans/*-code-review-prompt*.md | head -1)"
grep -n '^## ' "$P"
awk '/^## DO NOT/{d=NR} /^## DOCUMENTS/{o=NR} END{exit !(d && o && d<o)}' "$P" && echo "GATE BEFORE DOCUMENTS: ok"
grep -q 'Git range' "$P" && echo "range present"
grep -q 'mesh-review' "$P" && echo "targets mesh-review"
```

Expected: sections in order, `GATE BEFORE DOCUMENTS: ok`, `range present`, `targets mesh-review`.

- [ ] **Step 3: Verify the collision suffix**

Execute it a second time without deleting the first file. Expected: a `-2` file is
created and the first one is left untouched (`git status --porcelain` shows two untracked
prompt files, not a modified one).

- [ ] **Step 4: Commit**

```bash
git add commands/code-review-fresh-session.md
git commit -m "feat(commands): code-review-fresh-session — carry what the diff cannot say"
```

---

### Task 8: Close the loop in the two existing files

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (Step 15 only)
- Modify: `commands/do-plan.md` (Step 7 only)

**Interfaces:**
- Consumes: `/claude-mesh:design-review-fresh-session` (Task 6) and `/claude-mesh:code-review-fresh-session` (Task 7).
- Produces: nothing new — this is the wiring that makes both commands reachable without the user remembering them.

- [ ] **Step 1: Point the next-iteration branch at the new generator**

In `skills/mesh-design-review/SKILL.md`, Step 15, "Based on user response", replace the
`"Новая итерация"` action with:

```markdown
- **"Новая итерация":** Execute `/claude-mesh:design-review-fresh-session` via the Skill tool
  (it generates the prompt for the next iteration and knows this may run in a sandbox), then
  go to Step 16. If that command does not resolve — an older plugin in this environment —
  warn that the plugin needs an update for the review-generator flow and fall back to
  `/claude-mesh:continue-plan-fresh-session`, as before this feature
```

Leave the option labels and the `"Остановиться и начать работу"` branch — which still routes to
`/claude-mesh:continue-plan-fresh-session` — exactly as they are.

Also add three one-line counter-notes in the same file — the repo's sync convention is two-way
("change all copies or none"), and the generator now mirrors these steps. Step 1 (TOPIC
derivation), Step 2 (iteration counting) and Step 13 (date source) each gain:

```markdown
<!-- SYNC: mirrored by commands/design-review-fresh-session.md Step 2 — change together -->
```

- [ ] **Step 2: Verify the edit is confined to Step 15**

```bash
git diff --stat skills/mesh-design-review/SKILL.md
git diff skills/mesh-design-review/SKILL.md | grep -c '^[-+]' 
```

Expected: one file; the Step 15 branch replacement plus exactly three one-line SYNC comments
at Steps 1, 2 and 13. Any other diff — Steps 5, 6, the mirrored selection/watch blocks — is
out of scope for this plan; revert it.

- [ ] **Step 3: Add the end-of-plan hint to `/do-plan`**

In `commands/do-plan.md`, Step 7 "End of plan", append:

```markdown
Offer the code review BEFORE `superpowers:finishing-a-development-branch`, and if the user
takes it, hold finishing entirely — no push, no PR, and no local merge either (finishing
deletes the branch after merging, and review fixes need somewhere to land) — until that
external review has run and its findings are applied. The order is the point: a
merged-and-deleted branch cannot absorb what the review finds.

`/claude-mesh:code-review-fresh-session` generates the prompt, carrying the git range and what
only this session knows — deviations from the plan, what was left unfinished, known weak spots.

Whether this session can finish the branch is a fact to check, not to guess: run
`GIT_TERMINAL_PROMPT=0 timeout 8 git ls-remote --exit-code origin HEAD` (or reuse a preflight
verdict already printed in this session). If the remote does not answer, say plainly that
`superpowers:finishing-a-development-branch` cannot finish the job here: push and PR creation
need a network that is not available. Leave the branch for the user to finish outside. Do not
attempt the push to find out.
```

- [ ] **Step 4: Confirm both files still read correctly**

Run: `grep -n "design-review-fresh-session" skills/mesh-design-review/SKILL.md && grep -n "code-review-fresh-session" commands/do-plan.md`
Expected: one hit in each file, in the step named above.

- [ ] **Step 5: Commit**

```bash
git add skills/mesh-design-review/SKILL.md commands/do-plan.md
git commit -m "feat(flow): route the next review iteration and the post-plan review into fresh sessions"
```

---

### Task 9: README and CHANGELOG

**Files:**
- Modify: `README.md` (Features → session helpers; Dependencies if needed)
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section at the top)

**Interfaces:**
- Consumes: everything above.
- Produces: the user-facing record. No code depends on this task.

- [ ] **Step 1: Extend the session-helper line in README**

In the Features list, the `**Session helpers**` bullet gains the two new commands:

```markdown
- **Session helpers** — `/claude-mesh:do-plan`, `/claude-mesh:pause-after-current-task`, `/claude-mesh:transfer-session`,
  `/claude-mesh:exec-plan-fresh-session`, `/claude-mesh:continue-plan-fresh-session`,
  `/claude-mesh:design-review-fresh-session`, `/claude-mesh:code-review-fresh-session`
- **Sandbox-aware review sessions** — the two `*-review-fresh-session` commands generate a prompt
  for a fresh session that reviews rather than implements, and never name a model: the session
  runs `skills/shared/preflight-env.sh` where it actually lives and picks reviewers from what
  that reports. For reviews that will run in an environment with a different `config.yaml` —
  typically another machine, VM or sandbox. Workflow: generate the prompt on the host, paste
  it into a fresh session inside the sandbox; that session probes its own environment and
  selects reviewers from what it finds
```

- [ ] **Step 2: Add the CHANGELOG entry**

Insert directly under the `All notable changes…` line:

```markdown
## [Unreleased]

### Added
- `/claude-mesh:design-review-fresh-session` and `/claude-mesh:code-review-fresh-session`
  generate the prompt for a fresh session that reviews a design+plan, or a finished
  implementation, instead of executing it. Both are built for a review that runs somewhere
  else — typically a sandbox VM sharing the working copy — so neither generator reads
  `config.yaml` and neither prompt names a model: the reviewing session runs the new
  `skills/shared/preflight-env.sh` in its own environment and selects from what that reports.
  The probe emits one row per capability (config state, the Claude catalog, codex/gemini gated
  on their config section first and their network second, one probe per provider through the
  existing `token-precheck.sh` / `ollama-precheck.sh`, git remote, gh/glab, clipboard) and two
  `SUMMARY` lines naming the reviewers that can actually be selected there. Every verdict
  exits 0 — a non-zero exit means the probe is broken, not the environment. Provider tokens
  never reach the output and exported env files are removed through a trap.
  `mesh-design-review` Step 15 now routes its next iteration into the new generator, and
  `/do-plan` Step 7 points at the code-review one and states that a sandbox cannot finish a
  branch that needs a push.
```

- [ ] **Step 3: Verify**

Run: `grep -n "review-fresh-session" README.md CHANGELOG.md | head`
Expected: hits in both files.

- [ ] **Step 4: Run the full shared test suite one last time**

Run: `FAILED=0; for t in skills/shared/tests/test-*.sh; do echo "== $t"; bash "$t" >/dev/null || { echo "SUITE FAILED: $t"; FAILED=1; }; done; [ "$FAILED" -eq 0 ] && echo "all suites done"; [ "$FAILED" -eq 0 ]`
Expected: `all suites done` and exit 0 — the command itself fails when any suite fails,
instead of hiding the failure behind an unconditional final echo.

- [ ] **Step 5: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: record the two fresh-session review commands and the environment probe"
```

---

## Done criteria

- `bash skills/shared/tests/test-preflight-env.sh` passes, and so does every other suite in `skills/shared/tests/`.
- `/claude-mesh:design-review-fresh-session` and `/claude-mesh:code-review-fresh-session` each produce a prompt whose sections appear in the documented order, whose gate precedes the documents, and which contains no model or provider id from the local config.
- A fresh subagent given a generated prompt modifies nothing, runs the probe, prints the table and stops.
- `mesh-design-review` Step 15 and `do-plan` Step 7 reference the new commands; nothing else in those files changed.
- The baseline and GREEN results are recorded in `docs/superpowers/verification/2026-08-02-fresh-session-baseline.md`.
