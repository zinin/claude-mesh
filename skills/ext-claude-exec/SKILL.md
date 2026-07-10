---
name: ext-claude-exec
description: Execute prompts via claude -p against alt-provider Anthropic-compatible endpoints (z.ai, Alibaba, DeepSeek, LiteLLM, Ollama daemon) with logging
user_invocable: true
---

# Ext-Claude Exec

Execute arbitrary prompts via `claude -p` with provider/model env taken from
`${CLAUDE_PLUGIN_DATA}/config.yaml`. Wraps both Anthropic-API-style providers
(GLM, Alibaba, DeepSeek, LiteLLM) and Ollama daemon.

**Announce at start:** "Using ext-claude-exec skill to run prompt via configured provider."

## CRITICAL: Tool Execution Rules

### Bash Variables

**The Bash tool runs each call in an ISOLATED shell. Variables DO NOT persist between calls.**

GOOD (single call with `&&`):
```bash
WORK_DIR="/path/to/dir" && cat "$WORK_DIR/file"
```

**Rule: Put ALL related commands in ONE Bash call using `&&` to chain them.**

### Write Tool Limitation

For NEW files, use Bash heredoc:
```bash
cat > "/path/new-file.txt" << 'EOF'
content here
EOF
```

## Input

The caller must provide:
- **MODEL** — id from `models[]` in config, e.g. `zai/glm`, `ollama/kimi`, `alibaba/qwen`
- **PROMPT** — the full prompt text

Optional:
- **TASK_NAME** — short name for log dirs (default: "task")
- **SUPERVISED_MODE** — `none` (default) or `shell` (wraps in `shared/watchdog.sh`)
- **SKIP_TOKEN_PRECHECK** — set to `1` to skip token-precheck for anthropic-api providers

## Template substitution convention

This SKILL.md contains `{NAME}` placeholders (e.g. `{MODEL}`, `{PROMPT}`, `{TASK_NAME}`, `{WORK_DIR}`). When the calling LLM composes the Bash tool call, **it replaces each `{NAME}` literally with the caller-supplied value** before the shell sees the script. Two embedding patterns are used, chosen by the shape of the value:

1. **Short, constrained scalars** (`MODEL`, `WORK_DIR`): plain double-quoted assignment, e.g. `MODEL="{MODEL}"`. Safe because these values are constrained to `[a-z0-9._/-]` (model id grammar, see Design §5) or are paths derived inside the script. If a value could ever contain `"` or `$`, use the heredoc form below — this is exactly why `TASK_NAME` (free-form caller text) is embedded via heredoc in Step 1, not as a plain assignment.

2. **Multi-line or free-form values** (`PROMPT`, `TASK_NAME`): bash heredoc with a unique 16-hex delimiter, e.g. `__PROMPT_BOUND_a8f7e2c4__`. The hex suffix makes accidental collision with prompt content astronomically unlikely; if a collision is ever observed, regenerate the delimiter with a fresh suffix and retry. The single-quoted form `<<'__BOUND__'` is mandatory — it disables `$VAR`/backtick expansion inside the heredoc so prompt content cannot leak shell metachars into the surrounding script.

Why this matters (CONCERN-2): wrapping every value in a heredoc with a fixed delimiter (`__MODEL_BOUND__`) created a small but non-zero collision risk and added noise around values that don't need it. The two-tier convention removes the collision class for short ids while keeping the heredoc protection where it actually matters.

## Locating plugin files (Task 2.5)

When this skill loads, Claude Code prints a line `Base directory for this skill: <ABS>`. **`${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are NOT available inside Bash-tool calls** (verified empty on Claude Code 2.1.156). So at the top of EACH Bash block set `SKILL_BASE` to that printed absolute path. From it:
- loader = `$SKILL_BASE/../shared/config-loader.sh`
- sibling scripts = `$SKILL_BASE/../shared/<x>`; this skill's own scripts = `$SKILL_BASE/<x>`
- data dir = `"$LOADER" data-dir` (the loader self-discovers `~/.claude/plugins/data/claude-mesh-*`)

## Pre-flight Checks

Run in ONE Bash call. Resolves provider kind via `config-loader.sh export`:

```bash
set -u
MODEL="{MODEL}"
# Task 2.5 (CC 2.1.156): ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA} are EMPTY in
# Bash-tool calls from skills. Locate files via the absolute base dir Claude Code
# prints at skill load ("Base directory for this skill: <ABS>"). See "## Locating
# plugin files (Task 2.5)" below.
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
SKILL_DIR="$SKILL_BASE"
LOADER="$SKILL_BASE/../shared/config-loader.sh"

command -v claude >/dev/null 2>&1 || { echo "STOP: claude CLI not found"; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "STOP: jq not found"; exit 1; }
command -v bc     >/dev/null 2>&1 || { echo "STOP: bc not found (used by progress-monitor.sh)"; exit 1; }
command -v curl   >/dev/null 2>&1 || { echo "STOP: curl not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found"; exit 1; }

# Validate + resolve env via loader. cmd_export writes a mode-600 tmpfile and
# prints its path on stdout — see CONCERN-1. We source it and unlink immediately
# so the token never lands in the Bash-tool transcript.
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)"; exit 1; }
[ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] || { echo "STOP: config-loader produced no env file"; exit 1; }
trap 'rm -f "$ENV_FILE"' EXIT
# shellcheck source=/dev/null
source "$ENV_FILE"
rm -f "$ENV_FILE"
trap - EXIT

case "$CLAUDE_MESH_PROVIDER_KIND" in
    anthropic-api)
        if [ "${SKIP_TOKEN_PRECHECK:-0}" != "1" ]; then
            PRECHECK_RC=0
            "$SKILL_DIR/token-precheck.sh" "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN" || PRECHECK_RC=$?
            case "$PRECHECK_RC" in
                0) echo "OK: anthropic-api precheck passed" ;;
                5) echo "STOP: Token expired or invalid for $MODEL" >&2; exit 5 ;;
                6) echo "STOP: Endpoint unreachable for $MODEL ($ANTHROPIC_BASE_URL)" >&2; exit 6 ;;
                *) echo "WARN: anthropic-api precheck rc=$PRECHECK_RC, continuing" >&2 ;;
            esac
        fi
        ;;
    ollama-daemon)
        # Capture rc BEFORE echo — otherwise $? becomes rc of `echo` (always 0)
        # and the real precheck failure code (5=auth / 6=unreachable) is masked.
        "$SKILL_DIR/ollama-precheck.sh" "$ANTHROPIC_BASE_URL" \
            || { rc=$?; echo "STOP: ollama-precheck failed (rc=$rc)" >&2; exit "$rc"; }
        ;;
    *)
        echo "STOP: unknown provider kind $CLAUDE_MESH_PROVIDER_KIND" >&2
        exit 1
        ;;
esac
```

## Process

### Step 1: Save Prompt to File

```bash
set -euo pipefail
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S)-$$
# TASK_NAME is free-form caller text, so it MUST be embedded via a single-quoted
# heredoc (not a plain "{TASK_NAME}" assignment): that disables $VAR/backtick/quote
# expansion at LLM-substitution time, BEFORE tr sanitizes the value. See the
# "Template substitution convention" section above. tr -cd then allow-lists a safe component.
RAW_TASK_NAME=$(cat <<'__TASK_NAME_BOUND_b3d9f1a7__'
{TASK_NAME}
__TASK_NAME_BOUND_b3d9f1a7__
)
TASK_NAME=$(printf '%s' "$RAW_TASK_NAME" | tr -cd '[:alnum:]._-' | head -c 64)
[ -z "$TASK_NAME" ] && TASK_NAME="task"

MODEL="{MODEL}"
PROVIDER="${MODEL%%/*}"
SHORT="${MODEL#*/}"

# Task 2.5: data dir is self-discovered by the loader (CLAUDE_PLUGIN_DATA is empty
# in skill Bash calls). SKILL_BASE = absolute base dir Claude Code prints at load.
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
WORK_DIR="$PLUGIN_DATA/runs/ext-claude/$PROVIDER/$SHORT/${TIMESTAMP}-${TASK_NAME}"
mkdir -p "$WORK_DIR"
echo "$TASK_NAME" > "$WORK_DIR/.task_name"

cat > "$WORK_DIR/prompt.md" << '__PROMPT_BOUND_a8f7e2c4__'
{PROMPT}
__PROMPT_BOUND_a8f7e2c4__

echo "WORK_DIR=$WORK_DIR"
```

### Step 2: Execute Claude (SINGLE Bash call)

Branch on `SUPERVISED_MODE`:
- `none` (default) → `progress-monitor.sh` pipeline
- `shell` → `shared/watchdog.sh` wrapper

#### Default mode

```bash
set -euo pipefail
WORK_DIR="{WORK_DIR}"
MODEL="{MODEL}"
# Task 2.5: SKILL_BASE = absolute base dir Claude Code prints at skill load.
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
SKILL_DIR="$SKILL_BASE"
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")

# Resolve env via loader tmpfile (CONCERN-1)
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)" >&2; exit 1; }
trap 'rm -f "$ENV_FILE"' EXIT
# shellcheck source=/dev/null
source "$ENV_FILE"
rm -f "$ENV_FILE"
trap - EXIT

echo "=== Ext-Claude Exec (stream mode) ==="
echo "Work dir: $WORK_DIR"
echo "Model:    $MODEL ($ANTHROPIC_MODEL)"
echo "Provider kind: $CLAUDE_MESH_PROVIDER_KIND"
echo ""
echo "=== Executing claude (live progress below) ==="
unset CLAUDECODE

PIPELINE_RC=0
# Timeout from config (CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC exported by config-loader).
{ timeout "${CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC:-1800}" claude -p --output-format stream-json < "$WORK_DIR/prompt.md" 2>"$WORK_DIR/stderr.txt" | \
  "$SKILL_DIR/progress-monitor.sh" "$WORK_DIR" "$MODEL" ; } || PIPELINE_RC=$?

echo ""
echo "=== Generating report ==="
{ "$SKILL_DIR/generate-md.sh" "$WORK_DIR/log.jsonl" "$WORK_DIR/report.md" "$MODEL" "" "$TASK_NAME" \
    || echo "WARN: generate-md.sh failed" >&2 ; } || true

if [ ! -s "$WORK_DIR/output.txt" ] && [ -s "$WORK_DIR/raw.jsonl" ]; then
  echo "ERROR: output.txt empty but raw.jsonl has data" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  echo "--- raw.jsonl tail ---" >&2; tail -5 "$WORK_DIR/raw.jsonl" >&2
  exit 4
fi

if [ "$PIPELINE_RC" -ne 0 ]; then
  echo "WARN: claude pipeline exited rc=$PIPELINE_RC" >&2
  [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
  exit "$PIPELINE_RC"
fi
```

#### Supervised mode (SUPERVISED_MODE=shell)

```bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "supervised mode requires jq" >&2; exit 64; }
WORK_DIR="{WORK_DIR}"
MODEL="{MODEL}"
# Task 2.5: SKILL_BASE = absolute base dir Claude Code prints at skill load.
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
SKILL_DIR="$SKILL_BASE"
WATCHDOG="$SKILL_BASE/../shared/watchdog.sh"
TASK_NAME=$(cat "$WORK_DIR/.task_name" 2>/dev/null || basename "$WORK_DIR")

# Resolve env via loader tmpfile (CONCERN-1)
ENV_FILE=$("$LOADER" export "$MODEL") || { echo "STOP: config-loader failed — surface the error verbatim; do NOT edit config.yaml (user-owned)" >&2; exit 1; }
trap 'rm -f "$ENV_FILE"' EXIT
# shellcheck source=/dev/null
source "$ENV_FILE"
rm -f "$ENV_FILE"
trap - EXIT

# Timeouts already in env from cmd_export (CLAUDE_MESH_TIMEOUT_*); use those directly
# instead of re-reading yaml here — avoids a second config-load and stays consistent with
# default mode.
SINGLE_RUN="${CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC:-1800}"
STALL="${CLAUDE_MESH_TIMEOUT_STALL_SEC:-600}"
GLOBAL="${CLAUDE_MESH_TIMEOUT_GLOBAL_SEC:-3600}"
MAX_RETRIES="${CLAUDE_MESH_TIMEOUT_MAX_RETRIES:-2}"

echo "=== Ext-Claude Exec (supervised) ==="
echo "Work dir: $WORK_DIR"
echo "Model:    $MODEL ($ANTHROPIC_MODEL)"
echo "Timeouts: single=${SINGLE_RUN}s stall=${STALL}s global=${GLOBAL}s retries=$MAX_RETRIES"
echo ""
unset CLAUDECODE

WATCHDOG_RC=0
{ env \
    WORK_DIR="$WORK_DIR" \
    STDIN_FILE="$WORK_DIR/prompt.md" \
    MAX_RETRIES="$MAX_RETRIES" \
    HARD_ZERO_TIMEOUT="$STALL" \
    GLOBAL_TIMEOUT="$GLOBAL" \
    STREAM_FILE_NAME=raw.jsonl \
    "$WATCHDOG" -- \
      timeout "$SINGLE_RUN" stdbuf -oL -eL claude -p --output-format stream-json \
  || WATCHDOG_RC=$?; }

# Watchdog writes each attempt's artefacts under $WORK_DIR/attempt-N/ and makes
# $WORK_DIR/final a SYMLINK to the winning attempt (watchdog.sh: `ln -sfn attempt-N final`).
# Branch on WATCHDOG_RC exactly like the legacy ccs-exec/ollama-exec supervised blocks:
#   rc=0 → copy the winning attempt's artefacts up, extract, report, empty-output post-check
#   rc=2 → watchdog bailed (retries exhausted / global timeout): surface watchdog.exit
#          diagnostics + per-attempt tails, then exit 2. Do NOT run the exit-4 path here —
#          on a bail `final` points at a partial attempt with an empty output.txt, so the
#          exit-4 check would fire first and mask the bail (exit 4 instead of 2, diagnostics lost).
#   else → watchdog internal error: propagate rc.
echo ""
echo "=== Watchdog result (rc=$WATCHDOG_RC) ==="
if [ "$WATCHDOG_RC" -eq 0 ]; then
  # Copy the winning attempt's files up to $WORK_DIR root so the rest of the pipeline
  # behaves like default mode. NOTE: no log.jsonl — that file is produced by
  # progress-monitor.sh (default mode only); supervised mode has raw.jsonl + stderr.txt.
  if [ -d "$WORK_DIR/final" ]; then
    for f in raw.jsonl stderr.txt; do
      [ -f "$WORK_DIR/final/$f" ] && cp "$WORK_DIR/final/$f" "$WORK_DIR/$f"
    done
  fi

  # Extract output.txt + raw.json from raw.jsonl via shared script (same script used by
  # default mode → DRY, eliminates the 80-line duplicate that legacy ollama-exec and
  # ccs-exec carried).
  python3 "$SKILL_BASE/../shared/extract-result.py" "$WORK_DIR" \
    || { echo "WARN: extract-result.py rc=$?" >&2; }

  echo ""
  echo "=== Generating report ==="
  # Supervised mode has no log.jsonl; feed raw.jsonl. generate-md.sh detects the missing
  # timestamp prefix and synthesizes one — same call the legacy supervised blocks used.
  { "$SKILL_DIR/generate-md.sh" "$WORK_DIR/raw.jsonl" "$WORK_DIR/report.md" "$MODEL" "" "$TASK_NAME" \
      || echo "WARN: generate-md.sh failed" >&2 ; } || true

  # Diagnostics: empty output despite a non-empty stream is a recoverable signal — fail loudly.
  if [ ! -s "$WORK_DIR/output.txt" ] && [ -s "$WORK_DIR/raw.jsonl" ]; then
    echo "ERROR: output.txt empty but raw.jsonl has data" >&2
    [ -s "$WORK_DIR/stderr.txt" ] && { echo "--- stderr ---" >&2; cat "$WORK_DIR/stderr.txt" >&2; }
    echo "--- raw.jsonl tail ---" >&2; tail -5 "$WORK_DIR/raw.jsonl" >&2
    exit 4
  fi
elif [ "$WATCHDOG_RC" -eq 2 ]; then
  # Watchdog bailed: retries exhausted or global timeout. Surface the structured
  # diagnostics watchdog.sh wrote to watchdog.exit (reason/attempts/elapsed/last_attempt_dir)
  # plus per-attempt tails, so the caller sees WHY it failed instead of a bare empty output.
  echo "## Watchdog Diagnostics"
  if [ -f "$WORK_DIR/watchdog.exit" ]; then
    jq -r '"- Attempts: \(.attempts)\n- Reason: \(.reason)\n- Elapsed: \(.elapsed_sec)s\n- Last attempt: \(.last_attempt_dir)"' \
      "$WORK_DIR/watchdog.exit" 2>/dev/null || cat "$WORK_DIR/watchdog.exit"
  fi
  echo ""
  echo "=== PER-ATTEMPT TAILS ==="
  for a in "$WORK_DIR"/attempt-*; do
    [ -d "$a" ] || continue
    echo "-- $a --"; tail -20 "$a/raw.jsonl" 2>/dev/null || true
    [ -s "$a/stderr.txt" ] && { echo "-- $a/stderr --"; tail -20 "$a/stderr.txt" || true; }
    echo ""
  done
  exit 2
else
  echo "WARN: watchdog internal error (rc=$WATCHDOG_RC)" >&2
  exit "$WATCHDOG_RC"
fi
```

The supervised block mirrors default mode (Step 3 above) but uses `watchdog.sh` instead of a single `claude | progress-monitor.sh` pipeline. Result extraction is asymmetric (iter-2 CRITICAL-3): **default mode** keeps `progress-monitor.sh` (battle-tested, streams progress lines live to stdout while extracting from `type=result` events). **Supervised mode** uses `shared/extract-result.py` because watchdog produces per-attempt dirs (`attempt-N/raw.jsonl`, with `final` a symlink to the winning attempt) — that layout doesn't fit progress-monitor.sh's stdin-pipe assumption. The Python extractor reads `type=result` first (matching progress-monitor.sh), then assistant-message text, and finally — if neither exists — surfaces an `error` event as `API Error: <msg>` (parity with the legacy ccs/ollama extractor). The supervised tail branches on the watchdog exit code: `rc=0` copies the winning attempt up and runs extraction + `generate-md.sh` from `raw.jsonl`; `rc=2` (watchdog bail) prints the `watchdog.exit` diagnostics + per-attempt tails and exits 2 (no exit-4 masking); any other code is propagated.

### Step 3: Handle Errors

```bash
# Task 2.5: data dir self-discovered by loader (CLAUDE_PLUGIN_DATA empty in skill Bash).
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
PLUGIN_DATA="$("$LOADER" data-dir)"
# iter-3 CONCERN-3: run dirs are depth 3 (provider/short/run)
LATEST=$(find "$PLUGIN_DATA/runs/ext-claude" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | xargs -I{} stat -c '%Y {}' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$LATEST" ] && { echo "Latest run: $LATEST"; ls -la "$LATEST"; }
```

**Return to caller:** WORK_DIR path and the contents of `output.txt`.

## Error Recovery

| Error | Solution |
|-------|----------|
| `claude: command not found` | Install Claude CLI |
| `config.yaml not found` | Copy from plugin's `config.example.yaml` |
| `yq not found` | `pipx install yq` (Python-yq required; **don't** `brew install yq` — that's Go-yq, incompatible DSL) |
| `models[X] references missing provider` | Add missing provider to `providers:` in config |
| Token precheck failed (HTTP 401/403) | Update `token:` in `providers[X]` |
| Ollama daemon unreachable | `ollama serve` / `systemctl start ollama` |
| Ollama auth failed | `ollama signin` |

## Checklist

- [ ] Pre-flight checks passed
- [ ] config-loader.sh exported env successfully
- [ ] Token/daemon precheck OK (by kind)
- [ ] Prompt saved to `prompt.md`
- [ ] `claude -p` executed (default or supervised)
- [ ] `output.txt` extracted
- [ ] `report.md` generated
