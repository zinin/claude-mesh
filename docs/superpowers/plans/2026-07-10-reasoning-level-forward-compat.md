# Forward-Compatible reasoning_level Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An unknown `codex.reasoning_level` (e.g. gpt-5.6's `ultra`) never breaks the loader, ext-claude executors, or reviews; codex executors resolve model/level from `config.yaml`; agents never edit user config; ship as plugin release 0.4.0.

**Architecture:** Three layers: (1) `config-loader.sh` warns instead of dying on unknown reasoning levels and `cmd_export` validates only the sections it reads; (2) codex executor skills resolve MODEL/REASONING_LEVEL via `get-codex` with `gpt-5.5`/`xhigh` fallbacks, mirroring the existing gemini-exec idiom; (3) a canonical guardrail sentence in every pre-flight forbids agents from editing `config.yaml`.

**Tech Stack:** bash 4+, jq, Python-yq (kislyuk); plugin markdown skills; no repo test framework — a throwaway fixture harness under `~/tmp/claude-mesh-loader-tests/`.

**Spec:** `docs/superpowers/specs/2026-07-10-reasoning-level-forward-compat-design.md` (same branch).

## Global Constraints

- Branch: `feature/reasoning-level-forward-compat` (already exists; spec committed there).
- Repo root: `/opt/github/zinin/claude-mesh`. All paths below are relative to it.
- `git add` ONLY by explicit file path. NEVER `git add -A` / `git add .` — the repo contains pre-existing untracked `docs/superpowers/plans/2026-06-*` files that must stay untracked.
- NEVER edit `~/.claude/plugins/data/claude-mesh-zinin/config.yaml` (user-owned) or anything under `~/.claude/plugins/cache/` (no cache patching — release only).
- Canonical guardrail sentence (use verbatim where a task says so): `If any pre-flight check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.`
- Precedence rule everywhere: explicit caller parameter > `config.yaml` > built-in fallback (`gpt-5.5` / `xhigh`).
- Known reasoning levels (silent in validator): `none|minimal|low|medium|high|xhigh|ultra`. Unknown → WARN + pass through.
- Conventional commit messages, exactly as given per task.
- Fixture harness lives at `~/tmp/claude-mesh-loader-tests/` (NOT in the repo; deleted in Task 10).

---

### Task 1: Fixture test harness (RED baseline)

The loader honors `CLAUDE_PLUGIN_DATA` (config-loader.sh:27), so fixtures are just directories with a `config.yaml`, selected per call via the env var. No repo files change in this task.

**Files:**
- Create: `~/tmp/claude-mesh-loader-tests/run-tests.sh`
- Create: `~/tmp/claude-mesh-loader-tests/fixtures/{ultra,bogus,nocodex,nomodel,badprov}/config.yaml`

**Interfaces:**
- Produces: `run-tests.sh <abs-path-to-config-loader.sh>` → prints `PASS:`/`FAIL:` lines + `passed=N failed=M`; exit 0 iff `failed=0`. Tasks 2, 3, 9 run it.

- [ ] **Step 1: Create fixtures**

```bash
mkdir -p ~/tmp/claude-mesh-loader-tests/fixtures/{ultra,bogus,nocodex,nomodel,badprov}
cd ~/tmp/claude-mesh-loader-tests/fixtures

cat > ultra/config.yaml << 'EOF'
providers:
  - id: p1
    label: "P1"
    base_url: http://localhost:9
    token: test-token
models:
  - id: p1/m1
    label: "M1"
    model: test-model
codex:
  model: gpt-5.6-sol
  reasoning_level: ultra
EOF

cat > bogus/config.yaml << 'EOF'
providers:
  - id: p1
    label: "P1"
    base_url: http://localhost:9
    token: test-token
models:
  - id: p1/m1
    label: "M1"
    model: test-model
codex:
  model: gpt-5.6-sol
  reasoning_level: bogus-zzz
EOF

cat > nocodex/config.yaml << 'EOF'
providers:
  - id: p1
    label: "P1"
    base_url: http://localhost:9
    token: test-token
models:
  - id: p1/m1
    label: "M1"
    model: test-model
EOF

cat > nomodel/config.yaml << 'EOF'
providers:
  - id: p1
    label: "P1"
    base_url: http://localhost:9
    token: test-token
models:
  - id: p1/m1
    label: "M1"
    model: test-model
codex:
  reasoning_level: xhigh
EOF

cat > badprov/config.yaml << 'EOF'
providers:
  - id: p1
    label: "P1"
    base_url: localhost:9
    token: test-token
models:
  - id: p1/m1
    label: "M1"
    model: test-model
codex:
  model: gpt-5.6-sol
  reasoning_level: ultra
EOF
```

(`badprov` has `base_url` without an `http(s)://` scheme — `validate_providers` dies on it; its codex section is valid. Verifies export still guards its OWN sections after scoping.)

- [ ] **Step 2: Create run-tests.sh**

```bash
cat > ~/tmp/claude-mesh-loader-tests/run-tests.sh << 'EOF'
#!/usr/bin/env bash
# Fixture tests for claude-mesh config-loader.sh (spec §5).
# Usage: run-tests.sh /abs/path/to/config-loader.sh
set -u
LOADER="${1:?usage: run-tests.sh <path-to-config-loader.sh>}"
BASE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

t() { # t <name> <want_rc> <stderr_must_contain|-> <stderr_must_NOT_contain|-> <fixture> <cmd...>
    local name="$1" want_rc="$2" want_err="$3" ban_err="$4" fix="$5"; shift 5
    local err out rc ok=1
    err=$(mktemp)
    out=$(CLAUDE_PLUGIN_DATA="$BASE/fixtures/$fix" "$LOADER" "$@" 2>"$err"); rc=$?
    [ "$rc" -eq "$want_rc" ] || ok=0
    if [ "$want_err" != "-" ]; then grep -q "$want_err" "$err" || ok=0; fi
    if [ "$ban_err" != "-" ]; then grep -q "$ban_err" "$err" && ok=0; fi
    if [ "$ok" -eq 1 ]; then PASS=$((PASS+1)); echo "PASS: $name"
    else FAIL=$((FAIL+1)); echo "FAIL: $name (rc=$rc want=$want_rc)"; sed 's/^/    stderr: /' "$err" | head -3; fi
    rm -f "$err"
    case "$out" in /tmp/*claude-mesh-env*) rm -f "$out" ;; esac  # cleanup export env files
}

chk() { # chk <name> <fixture> <expected_stdout> <cmd...>
    local name="$1" fix="$2" want="$3"; shift 3
    local out
    out=$(CLAUDE_PLUGIN_DATA="$BASE/fixtures/$fix" "$LOADER" "$@" 2>/dev/null)
    if [ "$out" = "$want" ]; then PASS=$((PASS+1)); echo "PASS: $name"
    else FAIL=$((FAIL+1)); echo "FAIL: $name (got: \"$out\" want: \"$want\")"; fi
}

# --- ultra: modern level → fully green, no warnings anywhere
t   "ultra: export rc=0, no WARN"        0 - WARN            ultra   export p1/m1
t   "ultra: get-codex rc=0, no WARN"     0 - WARN            ultra   get-codex
t   "ultra: validate rc=0"               0 - -               ultra   validate
chk "ultra: get-codex output"            ultra "gpt-5.6-sol|ultra"   get-codex
# --- bogus level: WARN-not-die on codex getters/validate; export silent (scoped)
t   "bogus: get-codex rc=0 with WARN"    0 WARN -            bogus   get-codex
t   "bogus: validate rc=0 with WARN"     0 WARN -            bogus   validate
t   "bogus: export rc=0, no WARN"        0 - WARN            bogus   export p1/m1
# --- no codex: section absent stays fine everywhere
t   "nocodex: get-flag rc=0"             0 - -               nocodex get-flag has_codex
chk "nocodex: has_codex output"          nocodex "0"                 get-flag has_codex
t   "nocodex: export rc=0"               0 - -               nocodex export p1/m1
t   "nocodex: get-codex rc=0"            0 - -               nocodex get-codex
chk "nocodex: get-codex lone pipe"       nocodex "|"                 get-codex
# --- codex present but model missing: structural die stays; export unaffected
t   "nomodel: get-codex rc=1"            1 "codex.model" -   nomodel get-codex
t   "nomodel: validate rc=1"             1 "codex.model" -   nomodel validate
t   "nomodel: export rc=0"               0 - "codex.model"   nomodel export p1/m1
# --- broken providers[].base_url: export still guards its own sections
t   "badprov: export rc=1"               1 "base_url" -      badprov export p1/m1

echo ""
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
EOF
chmod +x ~/tmp/claude-mesh-loader-tests/run-tests.sh
```

- [ ] **Step 3: Run to verify RED baseline (current loader)**

Run: `~/tmp/claude-mesh-loader-tests/run-tests.sh /opt/github/zinin/claude-mesh/skills/shared/config-loader.sh`

Expected: `passed=8 failed=8`. Exactly these 8 FAIL (all victims of the current die-on-unknown-level and export's `validate_all`):
`ultra: export rc=0, no WARN` / `ultra: get-codex rc=0, no WARN` / `ultra: validate rc=0` / `ultra: get-codex output` / `bogus: get-codex rc=0 with WARN` / `bogus: validate rc=0 with WARN` / `bogus: export rc=0, no WARN` / `nomodel: export rc=0`.

If a DIFFERENT set fails (e.g. `badprov` or `nocodex` cases), STOP — the harness itself is wrong; fix it before touching the loader.

No commit (nothing in the repo changed).

---

### Task 2: Loader — warn() + level passthrough policy

**Files:**
- Modify: `skills/shared/config-loader.sh:40-43` (add `warn()` after `die()`), `skills/shared/config-loader.sh:245-250` (level policy)

**Interfaces:**
- Produces: `warn()` — prints `config-loader: WARN: <msg>` to stderr, returns 0. `validate_codex_gemini` no longer exits on unknown levels.

- [ ] **Step 1: Add warn() helper after die()**

Old (config-loader.sh:40-43):
```bash
die() {
    echo "config-loader: $*" >&2
    exit 1
}
```

New:
```bash
die() {
    echo "config-loader: $*" >&2
    exit 1
}

warn() {
    echo "config-loader: WARN: $*" >&2
}
```

- [ ] **Step 2: Replace the level allow-list with warn-passthrough**

Old (config-loader.sh:245-250):
```bash
        if [ -n "$level" ]; then
            case "$level" in
                low|medium|high|xhigh) ;;
                *) die "codex.reasoning_level: unknown value \"$level\". Valid: low, medium, high, xhigh" ;;
            esac
        fi
```

New:
```bash
        if [ -n "$level" ]; then
            case "$level" in
                # Known today (OpenAI server-accepted set as of 2026-07). New levels
                # ship with new models (gpt-5.6 added `ultra`) — an unknown value is
                # NOT an error: warn and pass through; the codex CLI/API is the final
                # validator and rejects truly invalid values with a clear HTTP 400.
                none|minimal|low|medium|high|xhigh|ultra) ;;
                *) warn "codex.reasoning_level: unknown value \"$level\" — passing through (codex CLI will validate)" ;;
            esac
        fi
```

- [ ] **Step 3: Run tests**

Run: `~/tmp/claude-mesh-loader-tests/run-tests.sh /opt/github/zinin/claude-mesh/skills/shared/config-loader.sh`

Expected: `passed=14 failed=2`. Remaining FAIL (both are `cmd_export`'s `validate_all` — Task 3's job):
`bogus: export rc=0, no WARN` / `nomodel: export rc=0`.

- [ ] **Step 4: Commit**

```bash
cd /opt/github/zinin/claude-mesh
git add skills/shared/config-loader.sh
git commit -m "fix(config-loader): warn instead of die on unknown codex.reasoning_level"
```

---

### Task 3: Loader — scope cmd_export validation

**Files:**
- Modify: `skills/shared/config-loader.sh:417-421` (cmd_export validation call)

**Interfaces:**
- Consumes: `warn()`/level policy from Task 2.
- Produces: `cmd_export` runs `validate_providers; validate_models; validate_runtime` only. `cmd_validate` stays `validate_all` (full lint).

- [ ] **Step 1: Replace validate_all in cmd_export**

Old (config-loader.sh:417-421):
```bash
    load_or_die
    # Full validation so malformed defaults/runtime/codex/gemini fast-fail BEFORE
    # ext-claude-exec spends 30+ minutes on a flawed config. See CRITICAL-10.
    # Latency cost is amortised by the JSON-snapshot strategy (CONCERN-12 / Risk #12).
    validate_all
```

New:
```bash
    load_or_die
    # Scoped validation (CRITICAL-10, revised 2026-07-10): fast-fail malformed
    # providers/models/runtime BEFORE ext-claude-exec spends 30+ minutes — but ONLY
    # the sections export actually reads (runtime for timeouts). Errors in
    # codex:/gemini:/defaults: cannot affect an ext-claude run and must NOT block it:
    # the `ultra` incident (2026-07-10) killed every ext-claude executor over a codex
    # setting. Mirrors the typed-getter principle (iter-2 CONCERN-2/3); cmd_validate
    # remains the full-config lint. Latency cost amortised by the JSON snapshot
    # (CONCERN-12 / Risk #12).
    validate_providers
    validate_models
    validate_runtime
```

- [ ] **Step 2: Run tests**

Run: `~/tmp/claude-mesh-loader-tests/run-tests.sh /opt/github/zinin/claude-mesh/skills/shared/config-loader.sh`
Expected: `passed=16 failed=0`, exit 0.

- [ ] **Step 3: Live check against the real user config (read-only)**

```bash
L=/opt/github/zinin/claude-mesh/skills/shared/config-loader.sh
"$L" validate && echo "validate: rc=0"          # real config has ultra — must pass silently
"$L" get-codex                                   # expect: gpt-5.6-sol|ultra
ENV=$("$L" export deepseek/v4-pro) && echo "export: OK" && rm -f "$ENV"
```
Expected output: `validate: rc=0`, `gpt-5.6-sol|ultra`, `export: OK` (this exact flow was broken before the fix). Do NOT print the env file contents (it holds tokens).

- [ ] **Step 4: Commit**

```bash
cd /opt/github/zinin/claude-mesh
git add skills/shared/config-loader.sh
git commit -m "fix(config-loader): scope cmd_export validation to providers/models/runtime"
```

---

### Task 4: codex-exec — resolve MODEL/REASONING_LEVEL from config.yaml

Mirror of the gemini-exec idiom (`skills/gemini-exec/SKILL.md:75` and `:167`). Six exact-string edits in `skills/codex-exec/SKILL.md`.

**Files:**
- Modify: `skills/codex-exec/SKILL.md:15-17, 75-76, 81-87, 166-168, 194-196, 288-290, 392-393`

**Interfaces:**
- Consumes: `"$LOADER" get-codex` → `<model>|<level>` (rc≠0 on structural codex errors); `get-flag has_codex` → `1`/`0`.
- Produces: callers (codex-code-review Task 5, mesh flows Task 6) may omit MODEL/REASONING_LEVEL entirely; empty → config → `gpt-5.5`/`xhigh`.

- [ ] **Step 1: Header loader-note — add clause (c)**

Old (lines 15-17):
```
> NOT call `config-loader.sh export` and does NOT source `ANTHROPIC_*`. The loader is
> used ONLY to (a) discover the plugin data dir for run logs and (b) gate on the
> `has_codex` config flag.
```

New:
```
> NOT call `config-loader.sh export` and does NOT source `ANTHROPIC_*`. The loader is
> used ONLY to (a) discover the plugin data dir for run logs, (b) gate on the
> `has_codex` config flag, and (c) resolve the default model/level via `get-codex`.
```

- [ ] **Step 2: Input docs for MODEL / REASONING_LEVEL**

Old (lines 75-76):
```
- **MODEL** — Codex model to use. **MUST be `gpt-5.5` unless the caller EXPLICITLY specifies a different model.** Do NOT choose a model yourself — if not specified, use `gpt-5.5`.
- **REASONING_LEVEL** — reasoning effort level. **MUST be `xhigh` unless the caller EXPLICITLY specifies a different level.** Do NOT choose a level yourself — if not specified, use `xhigh`.
```

New:
```
- **MODEL** — Codex model to use. If the caller does NOT specify a model, the skill resolves the default from config (`"$LOADER" get-codex` reads `codex.model` from `config.yaml`), falling back to `gpt-5.5` when config is absent (fresh install) or the `codex:` section is missing. Do NOT hardcode a model yourself — let the config/loader provide the default, and only override when the caller EXPLICITLY supplies a different model.
- **REASONING_LEVEL** — reasoning effort level. If the caller does NOT specify a level, the skill resolves the default from config (`get-codex` also returns `codex.reasoning_level`), falling back to `xhigh` when unset. Unknown levels are passed through to codex as-is (the codex CLI/API validates them). Do NOT choose a level yourself.
```

- [ ] **Step 3: Reasoning Levels table**

Old (lines 81-87):
```
| Level | Flag value | Description |
|-------|------------|-------------|
| low | `"low"` | Fast responses with lighter reasoning |
| medium | `"medium"` | Balances speed and reasoning depth for everyday tasks |
| high | `"high"` | Greater reasoning depth for complex problems |
| xhigh | `"xhigh"` | Extra high reasoning depth (default, may consume rate limits quickly) |
```

New:
```
| Level | Flag value | Description |
|-------|------------|-------------|
| none | `"none"` | No extended reasoning |
| minimal | `"minimal"` | Minimal reasoning depth |
| low | `"low"` | Fast responses with lighter reasoning |
| medium | `"medium"` | Balances speed and reasoning depth for everyday tasks |
| high | `"high"` | Greater reasoning depth for complex problems |
| xhigh | `"xhigh"` | Extra high reasoning depth (final fallback default; may consume rate limits quickly) |
| ultra | `"ultra"` | Deepest reasoning (gpt-5.6+ models) |

Levels not in this table are passed through unchanged — OpenAI adds levels with
new models, and the codex CLI/API rejects truly invalid values with a clear
HTTP 400 (`Invalid value: ...`).
```

- [ ] **Step 4: "Replace before execution" bullets**

Old (lines 166-168 area):
```
- `{MODEL}` → **MUST be `gpt-5.5`** unless caller explicitly provided a different model. Do NOT substitute any other model name.
- `{REASONING_LEVEL}` → **MUST be `xhigh`** unless caller explicitly provided a different level. Do NOT substitute any other level.
```

New:
```
- `{MODEL}` → leave EMPTY if the caller did not supply a model (the block resolves the default from config via `get-codex`, falling back to `gpt-5.5`). Substitute a model name ONLY when the caller explicitly provided one.
- `{REASONING_LEVEL}` → leave EMPTY if the caller did not supply a level (the block resolves it from config via `get-codex`, falling back to `xhigh`). Substitute a level ONLY when the caller explicitly provided one.
```

- [ ] **Step 5: Default execution block — resolution snippet**

Old (lines 194-196; the default block defines SKILL_BASE late, so the snippet goes right after it):
```
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
SKILL_DIR="$SKILL_BASE"
echo "=== Codex Exec ==="
```

New:
```
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
SKILL_DIR="$SKILL_BASE"
# Resolve model/level from config.yaml when the caller left them empty (mirrors
# gemini-exec). Gated on has_codex; get-codex rc!=0 = broken codex: section —
# STOP and surface it. config.yaml is user-owned: do NOT edit it.
LOADER="$SKILL_BASE/../shared/config-loader.sh"
if [ -z "$MODEL" ] || [ -z "$REASONING_LEVEL" ]; then
    CG="|"
    if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then
        CG=$("$LOADER" get-codex) || { echo "STOP: config-loader get-codex failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }
    fi
    [ -n "$MODEL" ] || MODEL="${CG%%|*}"
    [ -n "$REASONING_LEVEL" ] || REASONING_LEVEL="${CG##*|}"
fi
MODEL="${MODEL:-gpt-5.5}"
REASONING_LEVEL="${REASONING_LEVEL:-xhigh}"
echo "=== Codex Exec ==="
```

- [ ] **Step 6: Supervised execution block — same resolution in `&& \` chain style**

Old (lines 288-290; unique — the default block's TASK_NAME line has no `&& \`):
```
) && \
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR") && \
```

New:
```
) && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
{ [ -n "$MODEL" ] && [ -n "$REASONING_LEVEL" ]; } || { \
  CG="|"; \
  if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then \
    CG=$("$LOADER" get-codex) || { echo "STOP: config-loader get-codex failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }; \
  fi; \
  [ -n "$MODEL" ] || MODEL="${CG%%|*}"; \
  [ -n "$REASONING_LEVEL" ] || REASONING_LEVEL="${CG##*|}"; \
} && \
MODEL="${MODEL:-gpt-5.5}" && \
REASONING_LEVEL="${REASONING_LEVEL:-xhigh}" && \
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR") && \
```

- [ ] **Step 7: Options table rows**

Old (lines 392-393):
```
| `-m $MODEL` | Model to use (**MUST be `gpt-5.5`** unless explicitly overridden) |
| `-c model_reasoning_effort="$REASONING_LEVEL"` | Reasoning effort (**MUST be `xhigh`** unless explicitly overridden) |
```

New:
```
| `-m $MODEL` | Model to use (caller value, else `codex.model` from config.yaml, else `gpt-5.5`) |
| `-c model_reasoning_effort="$REASONING_LEVEL"` | Reasoning effort (caller value, else `codex.reasoning_level` from config.yaml, else `xhigh`; unknown levels pass through) |
```

- [ ] **Step 8: Verify — resolution snippet live + no stale mandates**

```bash
cd /opt/github/zinin/claude-mesh
grep -c 'MUST be `gpt-5.5`' skills/codex-exec/SKILL.md   # expect: 0
grep -c 'get-codex' skills/codex-exec/SKILL.md            # expect: >= 4
# Live dry-run of the snippet against the real config (has codex: gpt-5.6-sol/ultra):
MODEL="" ; REASONING_LEVEL="" ; LOADER=skills/shared/config-loader.sh
if [ -z "$MODEL" ] || [ -z "$REASONING_LEVEL" ]; then
    CG="|"
    if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then
        CG=$("$LOADER" get-codex) || echo "STOP"
    fi
    [ -n "$MODEL" ] || MODEL="${CG%%|*}"
    [ -n "$REASONING_LEVEL" ] || REASONING_LEVEL="${CG##*|}"
fi
echo "resolved: ${MODEL:-gpt-5.5} / ${REASONING_LEVEL:-xhigh}"   # expect: resolved: gpt-5.6-sol / ultra
```

- [ ] **Step 9: Commit**

```bash
cd /opt/github/zinin/claude-mesh
git add skills/codex-exec/SKILL.md
git commit -m "feat(codex-exec): resolve MODEL/REASONING_LEVEL from config.yaml (mirror gemini-exec)"
```

---

### Task 5: codex-code-review + codex-review-native — config-driven params

**Files:**
- Modify: `skills/codex-code-review/SKILL.md:128-136`
- Modify: `skills/codex-review-native/SKILL.md:54-55, 93-94, 99-100, 105-108`

**Interfaces:**
- Consumes: codex-exec resolution (Task 4); `get-codex` / `get-flag has_codex` (Tasks 2-3).

- [ ] **Step 1: codex-code-review Step 4 — stop hardcoding MODEL/REASONING_LEVEL**

Old (lines 128-136 — the fenced param block AND the CRITICAL paragraph after it):
````
```
PROMPT=<formatted prompt from Step 3>
TASK_NAME="review-${BRANCH}"
MODEL=gpt-5.5      # MANDATORY — do NOT change unless user explicitly requested a different model
REASONING_LEVEL=xhigh    # MANDATORY — do NOT change unless user explicitly requested a different level
SUPERVISED_MODE=shell
```

**CRITICAL: You MUST pass MODEL=gpt-5.5 and REASONING_LEVEL=xhigh exactly as shown above. Do NOT substitute o4-mini, gpt-4.1, or any other model. The only exception is when the user has EXPLICITLY asked to use a specific different model.**
````

New:
````
```
PROMPT=<formatted prompt from Step 3>
TASK_NAME="review-${BRANCH}"
SUPERVISED_MODE=shell
```

**Do NOT pass MODEL or REASONING_LEVEL unless the user EXPLICITLY requested specific values. When omitted, codex-exec resolves them from `config.yaml` (`codex.model` / `codex.reasoning_level`), falling back to `gpt-5.5`/`xhigh`. Never substitute o4-mini, gpt-4.1, or any other model on your own.**
````

- [ ] **Step 2: codex-review-native Input docs**

Old (lines 54-55):
```
- **MODEL** — Codex model. **MUST be `gpt-5.5`** unless caller EXPLICITLY specifies a different model. Do NOT choose a model yourself.
- **REASONING_LEVEL** — **MUST be `xhigh`** unless caller EXPLICITLY specifies a different level. Do NOT choose a level yourself.
```

New:
```
- **MODEL** — Codex model. If the caller does NOT specify one, the execution block resolves it from config (`get-codex` → `codex.model`), falling back to `gpt-5.5`. Do NOT choose a model yourself.
- **REASONING_LEVEL** — reasoning level. If the caller does NOT specify one, resolved from config (`get-codex` → `codex.reasoning_level`), falling back to `xhigh`. Unknown levels pass through to codex. Do NOT choose a level yourself.
```

- [ ] **Step 3: codex-review-native substitution bullets**

Old (lines 93-94):
```
- Replace `${MODEL}` with model — **MUST be `gpt-5.5`** unless caller explicitly specified otherwise
- Replace `${REASONING_LEVEL}` with level — **MUST be `xhigh`** unless caller explicitly specified otherwise
```

New:
```
- Replace `${MODEL}` with the caller's model, or leave UNSET — the block resolves it from config (`get-codex`), falling back to `gpt-5.5`
- Replace `${REASONING_LEVEL}` with the caller's level, or leave UNSET — the block resolves it from config (`get-codex`), falling back to `xhigh`
```

- [ ] **Step 4: codex-review-native execution block — defer fallbacks until after config resolution**

Old (lines 99-100):
```
MODEL="${MODEL:-gpt-5.5}" && \
REASONING_LEVEL="${REASONING_LEVEL:-xhigh}" && \
```

New:
```
MODEL="${MODEL:-}" && \
REASONING_LEVEL="${REASONING_LEVEL:-}" && \
```

- [ ] **Step 5: codex-review-native execution block — resolution after LOADER is defined**

Old (lines 105-108, now shifted by earlier edits — match on content):
```
SKILL_BASE="<absolute base dir Claude Code prints at skill load>" && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
PLUGIN_DATA="$("$LOADER" data-dir)" && \
```

New:
```
SKILL_BASE="<absolute base dir Claude Code prints at skill load>" && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
PLUGIN_DATA="$("$LOADER" data-dir)" && \
{ [ -n "$MODEL" ] && [ -n "$REASONING_LEVEL" ]; } || { \
  CG="|"; \
  if [ "$("$LOADER" get-flag has_codex 2>/dev/null)" = "1" ]; then \
    CG=$("$LOADER" get-codex) || { echo "STOP: config-loader get-codex failed — fix config.yaml (user-owned, agents never edit it)"; exit 1; }; \
  fi; \
  [ -n "$MODEL" ] || MODEL="${CG%%|*}"; \
  [ -n "$REASONING_LEVEL" ] || REASONING_LEVEL="${CG##*|}"; \
} && \
MODEL="${MODEL:-gpt-5.5}" && \
REASONING_LEVEL="${REASONING_LEVEL:-xhigh}" && \
```

(The `codex exec review` CMD lines and the `--uncommitted`/`--commit` variations reuse `$MODEL`/`$REASONING_LEVEL` from this block — no further edits there.)

- [ ] **Step 6: Verify**

```bash
cd /opt/github/zinin/claude-mesh
grep -rn 'MUST be `gpt-5.5`\|MUST be `xhigh`' skills/codex-code-review skills/codex-review-native   # expect: no matches
grep -c 'get-codex' skills/codex-review-native/SKILL.md    # expect: >= 3 (2 in docs + 1 in block)
```

- [ ] **Step 7: Commit**

```bash
cd /opt/github/zinin/claude-mesh
git add skills/codex-code-review/SKILL.md skills/codex-review-native/SKILL.md
git commit -m "feat(codex-review): resolve model/level from config.yaml in both review skills"
```

---

### Task 6: mesh flows — executor-resolved codex params + user-owned-config wording

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md:34-35, 338, 673`
- Modify: `commands/mesh-review.md:235, 240`

**Interfaces:**
- Consumes: executor resolution (Tasks 4-5). mesh-review's codex dispatch (`commands/mesh-review.md:147`) already passes no codex params — it needs NO dispatch change.

- [ ] **Step 1: mesh-design-review Input docs**

Old (lines 34-35):
```
- **CODEX_MODEL** — Codex model (default: "gpt-5.5")
- **CODEX_REASONING_LEVEL** — low, medium, high, xhigh (default: "xhigh")
```

New:
```
- **CODEX_MODEL** — Codex model. Default: resolved from `config.yaml` (`codex.model`) by the codex executor itself; final fallback "gpt-5.5". Set only when the user explicitly overrides.
- **CODEX_REASONING_LEVEL** — reasoning level (`none|minimal|low|medium|high|xhigh|ultra`; unknown values pass through to codex). Default: resolved from `config.yaml` (`codex.reasoning_level`) by the executor; final fallback "xhigh". Set only when the user explicitly overrides.
```

- [ ] **Step 2: mesh-design-review dispatch parameter line**

Old (line 338):
```
- **`claude-mesh:codex-executor`** (built-in selected: `codex`): MODEL={CODEX_MODEL}, REASONING_LEVEL={CODEX_REASONING_LEVEL}
```

New:
```
- **`claude-mesh:codex-executor`** (built-in selected: `codex`): pass `MODEL={CODEX_MODEL}` / `REASONING_LEVEL={CODEX_REASONING_LEVEL}` ONLY when the user explicitly set them; otherwise omit both lines entirely — codex-exec resolves model/level from `config.yaml` (`codex.model` / `codex.reasoning_level`, fallbacks `gpt-5.5`/`xhigh`)
```

- [ ] **Step 3: mesh-design-review error table row**

Old (line 673):
```
| `config.yaml` invalid (loader rc=1) | Surface the validator stderr, fix the config, retry |
```

New:
```
| `config.yaml` invalid (loader rc=1) | Surface the validator stderr to the user; the USER edits config.yaml (agents never modify it); retry after the user confirms |
```

- [ ] **Step 4: mesh-review BROKEN wording (2 lines)**

Old (line 235):
```
`BROKEN` reviewers are **never** re-dispatched — retry is futile (fix it by swapping the model in `config.yaml`, not by retrying).
```

New:
```
`BROKEN` reviewers are **never** re-dispatched — retry is futile (the fix is the USER swapping the model in `config.yaml` — agents never edit it — not retrying).
```

Old (line 240):
```
- `BROKEN` reviewers → record: `⚠ <reviewer>: external engine produced no usable review (broken — swap the model in config.yaml)`.
```

New:
```
- `BROKEN` reviewers → record: `⚠ <reviewer>: external engine produced no usable review (broken — ask the user to swap the model in config.yaml; agents never edit it)`.
```

- [ ] **Step 5: Verify + Commit**

```bash
cd /opt/github/zinin/claude-mesh
grep -n 'CODEX_MODEL' skills/mesh-design-review/SKILL.md | head -3   # expect: new wording at ~34 and ~338
git add skills/mesh-design-review/SKILL.md commands/mesh-review.md
git commit -m "docs(mesh): codex params resolved by executor; config.yaml edits are user-only"
```

---

### Task 7: Guardrail sentence in all remaining pre-flights

**Files:**
- Modify: `skills/codex-exec/SKILL.md:116`, `skills/gemini-exec/SKILL.md:116`, `skills/codex-code-review/SKILL.md:74`, `skills/gemini-code-review/SKILL.md:74`, `skills/ext-claude-exec/SKILL.md:89,180,234`, `skills/ext-claude-code-review/SKILL.md:76-77`

**Interfaces:**
- Produces: the canonical guardrail sentence (Global Constraints) present at every config-gate failure path.

- [ ] **Step 1: codex-exec (line 116)**

Old: `If the codex CLI check fails, stop and help user fix it.`
New: `If the codex CLI check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.`

- [ ] **Step 2: gemini-exec (line 116)**

Old: `If the gemini CLI check fails, stop and help user fix it.`
New: `If the gemini CLI check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.`

- [ ] **Step 3: codex-code-review and gemini-code-review (line 74 in each)**

Old (identical in both files): `If any check fails, stop and help user fix it.`
New (identical in both files): `If any pre-flight check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.`

- [ ] **Step 4: ext-claude-exec STOP messages (3 sites)**

Old (line 89, unique — no `>&2`):
```
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed"; exit 1; }
```
New:
```
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)"; exit 1; }
```

Old (lines 180 and 234 — identical; use replace-all):
```
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed" >&2; exit 1; }
```
New (replace-all, 2 occurrences):
```
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)" >&2; exit 1; }
```

- [ ] **Step 5: ext-claude-code-review error-recovery paragraph**

Old (lines 76-77):
```
If `ext-claude-exec` returns an error, surface verbatim and STOP. Do NOT
attempt to review the code yourself — the whole point is external review.
```
New:
```
If `ext-claude-exec` returns an error, surface verbatim and STOP. Do NOT
attempt to review the code yourself — the whole point is external review.
Do NOT edit config.yaml (or any plugin config) to "unblock" the run — config
is user-owned; report the error and wait for the user.
```

- [ ] **Step 6: Verify + Commit**

```bash
cd /opt/github/zinin/claude-mesh
grep -rn "stop and help user fix it" skills/ commands/           # expect: no matches
grep -rln "only the user changes it\|user-owned" skills/ | sort   # expect: 6 files listed
git add skills/codex-exec/SKILL.md skills/gemini-exec/SKILL.md skills/codex-code-review/SKILL.md skills/gemini-code-review/SKILL.md skills/ext-claude-exec/SKILL.md skills/ext-claude-code-review/SKILL.md
git commit -m "fix(skills): STOP-and-report guardrail — agents never edit config.yaml"
```

---

### Task 8: config.example.yaml + README

**Files:**
- Modify: `config.example.yaml:145`
- Modify: `README.md:86-87`

- [ ] **Step 1: config.example.yaml comment**

Old (line 145):
```
  reasoning_level: xhigh                       # [optional] valid: low | medium | high | xhigh
```
New:
```
  reasoning_level: xhigh                       # [optional] none | minimal | low | medium | high | xhigh | ultra; unknown values pass through with a WARN (codex CLI validates)
```

- [ ] **Step 2: README table rows**

Old (lines 86-87):
```
| `codex:` | no | model + reasoning_level for codex CLI |
| `gemini:` | no | model for gemini CLI |
```
New:
```
| `codex:` | no | model + reasoning_level for codex CLI — the default for `/codex-*` skills and reviews unless the caller overrides; unknown levels pass through with a WARN |
| `gemini:` | no | model for gemini CLI — the default for `/gemini-*` skills and reviews unless the caller overrides |
```

- [ ] **Step 3: Commit**

```bash
cd /opt/github/zinin/claude-mesh
git add config.example.yaml README.md
git commit -m "docs(config,readme): new reasoning levels + config-driven executor defaults"
```

---

### Task 9: Full verification sweep

No file changes; gate before release. Every check must pass — on ANY failure, STOP and fix in the task that owns the file before proceeding.

- [ ] **Step 1: Fixture suite green**

Run: `~/tmp/claude-mesh-loader-tests/run-tests.sh /opt/github/zinin/claude-mesh/skills/shared/config-loader.sh`
Expected: `passed=16 failed=0`, exit 0.

- [ ] **Step 2: Real-config live checks (read-only)**

```bash
L=/opt/github/zinin/claude-mesh/skills/shared/config-loader.sh
"$L" validate && echo OK1          # rc=0, silent (ultra is a known level)
[ "$("$L" get-codex)" = "gpt-5.6-sol|ultra" ] && echo OK2
[ "$("$L" get-gemini)" = "gemini-3.1-flash-lite-preview" ] && echo OK3
ENV=$("$L" export deepseek/v4-pro) && echo OK4 && rm -f "$ENV"
```
Expected: OK1 OK2 OK3 OK4.

- [ ] **Step 3: Consistency greps**

```bash
cd /opt/github/zinin/claude-mesh
grep -rn "stop and help user fix it" skills/ commands/                          # no matches
grep -rn 'MUST be `gpt-5.5`' skills/                                            # no matches
grep -rn 'low, medium, high, xhigh (default: "xhigh")' skills/                  # no matches
git status --short                                                              # only ?? docs/superpowers/plans/2026-06-* (pre-existing)
git log --oneline master..HEAD                                                  # spec+plan commits + Tasks 2-8 commits
```

---

### Task 10: Pre-PR cleanup, release 0.4.0, PR, tag

**Files:**
- Delete (from git): `docs/superpowers/` (spec + this plan; they stay in branch history)
- Modify: `CHANGELOG.md` (insert under `## [Unreleased]`), `.claude-plugin/plugin.json:3`
- Delete (disk): `~/tmp/claude-mesh-loader-tests/`

- [ ] **Step 1: Remove planning docs from the PR diff (user's workflow rule)**

```bash
cd /opt/github/zinin/claude-mesh
git rm -r docs/superpowers
git commit -m "docs: remove superpowers planning docs before PR"
git status --short   # expect: ?? docs/superpowers/plans/ (only the pre-existing untracked 2026-06-* files remain on disk)
```

- [ ] **Step 2: CHANGELOG entry**

In `CHANGELOG.md`, replace:
```
## [Unreleased]
```
with:
```
## [Unreleased]

## [0.4.0] - 2026-07-10

### Fixed
- `config-loader.sh` no longer aborts on an unknown `codex.reasoning_level`
  (e.g. the new gpt-5.6 `ultra`): unknown levels WARN and pass through — the
  codex CLI/API is the final validator. Previously a single unknown level in
  the `codex:` section killed `export` for **every** ext-claude executor
  mid-review and pushed blocked review subagents into "fixing" the user's
  config (`ultra` → `xhigh` flips).

### Changed
- `cmd_export` validates only the sections it reads (providers/models/runtime).
  Errors in `codex:` / `gemini:` / `defaults:` can no longer block ext-claude
  runs. `validate` remains the full-config lint.
- Known reasoning levels extended to `none|minimal|low|medium|high|xhigh|ultra`.

### Added
- codex executors (`codex-exec`, `codex-code-review`, `codex-review-native`)
  resolve MODEL / REASONING_LEVEL from `config.yaml` (`codex.model` /
  `codex.reasoning_level`) when the caller passes none — mirroring the existing
  gemini-exec idiom. `/mesh-review` and `/mesh-design-review` become
  config-driven for codex transitively. Precedence: explicit caller parameter >
  config.yaml > `gpt-5.5`/`xhigh` fallbacks.
- Guardrail wording in every pre-flight: on config failures agents STOP and
  report verbatim; `config.yaml` is user-owned and never edited by agents.
```

- [ ] **Step 3: Version bump**

In `.claude-plugin/plugin.json`, replace `"version": "0.3.0",` with `"version": "0.4.0",`.

- [ ] **Step 4: Release commit (mirrors 0.3.0: release commit lives on the feature branch)**

```bash
cd /opt/github/zinin/claude-mesh
git add CHANGELOG.md .claude-plugin/plugin.json
git commit -m "chore(release): 0.4.0"
```

- [ ] **Step 5: Push branch + open PR**

```bash
cd /opt/github/zinin/claude-mesh
git push -u origin feature/reasoning-level-forward-compat
gh pr create \
  --title "fix: forward-compatible reasoning_level validation + config-driven codex executors" \
  --body "## Problem
A \`codex.reasoning_level\` the 0.3.0 validator does not know (gpt-5.6's \`ultra\`) made \`cmd_export\` die for every ext-claude executor mid-review; blocked subagents then edited the user's config.yaml (\`ultra\` -> \`xhigh\` flips). The codex: config values were also dead — nothing read them.

## Fix
- config-loader: unknown reasoning levels WARN + pass through (codex CLI/API is the final validator); known set extended with none/minimal/ultra; \`cmd_export\` validates only providers/models/runtime (typed-getter principle, iter-2 CONCERN-2/3).
- codex-exec / codex-code-review / codex-review-native resolve MODEL/REASONING_LEVEL from config.yaml when the caller passes none (mirrors gemini-exec). Reviews become config-driven transitively.
- Canonical guardrail in every pre-flight: STOP and report; config.yaml is user-owned, agents never edit it.
- Release 0.4.0.

## Verification
16/16 fixture assertions green (ultra / bogus level / no codex / codex-without-model / broken provider across export, get-codex, get-flag, validate); live checks against a real config with \`ultra\` pass; consistency greps clean."
```

- [ ] **Step 6: CHECKPOINT — wait for the user**

STOP here. The user reviews and merges the PR (do not merge it yourself).

- [ ] **Step 7: After merge — tag the release commit and push the tag (mirrors 0.3.0: tag points at the `chore(release)` commit, not the merge commit)**

```bash
cd /opt/github/zinin/claude-mesh
git switch master && git pull
REL=$(git log --format='%H %s' -20 | awk '/chore\(release\): 0\.4\.0/ {print $1; exit}')
git tag "claude-mesh--v0.4.0" "$REL"
git push origin "claude-mesh--v0.4.0"
git tag --points-at "$REL"   # expect: claude-mesh--v0.4.0
```

- [ ] **Step 8: Cleanup + user hand-off**

```bash
rm -rf ~/tmp/claude-mesh-loader-tests
```

Tell the user: update the plugin from the marketplace (new version 0.4.0), then re-run a `/mesh-design-review` smoke to confirm codex runs with `gpt-5.6-sol` + `ultra` from config. The installed 0.3.0 cache was not touched.
