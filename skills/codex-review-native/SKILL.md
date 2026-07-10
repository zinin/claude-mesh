---
name: codex-review-native
description: Code review using built-in Codex review command with native diff detection
user_invocable: true
---

# Codex Review (Native)

Use built-in `codex exec review` command for code review.

**Announce at start:** "Using codex-review-native skill for code review via built-in Codex review."

## Locating plugin files (Task 2.5)

When this skill loads, Claude Code prints `Base directory for this skill: <ABS>`. **`${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` are NOT available in Bash-tool calls** (CC 2.1.156). Set `SKILL_BASE` to that absolute path at the top of each Bash block. From it: loader = `$SKILL_BASE/../shared/config-loader.sh`; data dir = `"$LOADER" data-dir` (run logs go under `$PLUGIN_DATA/runs/codex/...`); the shared `generate-md.sh` lives in the sibling skill at `$SKILL_BASE/../codex-exec/generate-md.sh`. Codex manages its own auth — this skill does NOT source provider tokens.

## CRITICAL: Bash Execution Rules

**The Bash tool runs each call in an ISOLATED shell. Variables DO NOT persist between calls.**

BAD (will fail):
```bash
# Call 1
LOG_FILE="/path/to/file.log"
# Call 2
cat "$LOG_FILE"  # ERROR: $LOG_FILE is empty!
```

GOOD (use single call with &&):
```bash
LOG_FILE="/path/to/file.log" && cat "$LOG_FILE"
```

GOOD (inline values):
```bash
cat "/path/to/file.log"
```

**Rule: Put ALL related commands in ONE Bash call using `&&` to chain them.**

## When to Use

- Quick code review without custom prompt formatting
- When built-in Codex review logic is sufficient
- Alternative to `codex-code-review` skill

## Input Parameters

Optional (caller can specify):
- **BASE_BRANCH** — base branch for comparison (default: auto-detected from `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `master`)
- **COMMIT_SHA** — review changes introduced by a specific commit
- **UNCOMMITTED** — set to `true` to review staged/unstaged/untracked changes
- **TITLE** — optional title for review summary
- **MODEL** — Codex model. If the caller does NOT specify one, the execution block resolves it from config (`get-codex` → `codex.model`), falling back to `gpt-5.5`. Do NOT choose a model yourself.
- **REASONING_LEVEL** — reasoning level. If the caller does NOT specify one, resolved from config (`get-codex` → `codex.reasoning_level`), falling back to `xhigh`. Unknown levels pass through to codex. Do NOT choose a level yourself.

**Priority:** UNCOMMITTED > COMMIT_SHA > BASE_BRANCH (first non-empty wins)

**Note:** For custom SHA ranges (BASE..HEAD), use `codex-code-review` skill instead.

## Limitations

`codex exec review` has these constraints:
- No `-o` flag (must parse output from JSONL)
- `--base`/`--commit` cannot be combined with `[PROMPT]`
- Use `--base` for branch comparison OR custom prompt, not both

## Pre-flight Checks

Run in ONE Bash call:
```bash
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
LOADER="$SKILL_BASE/../shared/config-loader.sh"
command -v codex >/dev/null 2>&1 || { echo "STOP: codex CLI not found - npm install -g @openai/codex"; exit 1; }
echo "OK: codex found"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "STOP: Not a git repository"; exit 1; }
echo "OK: git repo"
# Soft gate: warn (don't STOP) if optional codex: block is unconfigured. NEVER test
# get-codex's string for truthiness (it prints a lone '|' when unset) — use get-flag.
if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_codex 2>/dev/null)" != "1" ]; then
    echo "WARN: codex: block not configured in config.yaml (codex uses its own auth — continuing)"
fi
```

## Process

### Step 1: Execute Review (SINGLE Bash call)

**IMPORTANT:** Execute the ENTIRE script below in ONE Bash call. Do not split it.

Substitute parameters before execution:
- Replace `${BASE_BRANCH}` with actual value (e.g., "master")
- Replace `${MODEL}` with the caller's model, or leave UNSET — the block resolves it from config (`get-codex`), falling back to `gpt-5.5`
- Replace `${REASONING_LEVEL}` with the caller's level, or leave UNSET — the block resolves it from config (`get-codex`), falling back to `xhigh`

```bash
# === EXECUTE THIS ENTIRE BLOCK AS ONE BASH CALL ===
set -e && \
MODEL="${MODEL:-}" && \
REASONING_LEVEL="${REASONING_LEVEL:-}" && \
BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') && \
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}" && \
TIMESTAMP=$(date +%Y-%m-%d-%H-%M-%S) && \
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || echo "unknown") && \
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
WORK_DIR="$PLUGIN_DATA/runs/codex/${TIMESTAMP}-native-review-${BRANCH}" && \
mkdir -p "$WORK_DIR" && \
LOG_FILE="$WORK_DIR/log.jsonl" && \
OUTPUT_FILE="$WORK_DIR/output.txt" && \
MD_FILE="$WORK_DIR/report.md" && \
echo "=== Codex Native Review ===" && \
echo "Work dir: $WORK_DIR" && \
echo "Model: $MODEL | Reasoning: $REASONING_LEVEL | Base: $BASE_BRANCH" && \
echo "" && \
CMD="codex exec review --json --dangerously-bypass-approvals-and-sandbox --base $BASE_BRANCH -m $MODEL -c model_reasoning_effort=\"$REASONING_LEVEL\"" && \
echo "Executing: $CMD" && \
echo "" && \
eval "timeout 1800 $CMD" 2>&1 | while IFS= read -r line; do
    TS=$(date +%H:%M:%S)
    echo "[$TS] $line" >> "$LOG_FILE"
    TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
    case "$TYPE" in
        "thread.started") echo ":: Session started" ;;
        "item.completed")
            ITEM_TYPE=$(echo "$line" | jq -r '.item.type')
            [ "$ITEM_TYPE" = "reasoning" ] && echo ":: Reasoning..."
            [ "$ITEM_TYPE" = "command_execution" ] && echo ":: Running command..."
            [ "$ITEM_TYPE" = "agent_message" ] && echo ":: Review response received"
            ;;
        "turn.completed") echo ":: Completed" ;;
    esac
done && \
echo "" && \
echo "=== Extracting results ===" && \
grep '"type":"item.completed"' "$LOG_FILE" | sed 's/^\[[0-9:]*\] //' | jq -r 'select(.item.type == "agent_message") | .item.text' | tail -1 > "$OUTPUT_FILE" && \
GENERATE_MD="$SKILL_BASE/../codex-exec/generate-md.sh" && \
[ -s "$LOG_FILE" ] && "$GENERATE_MD" "$LOG_FILE" "$MD_FILE" && \
echo "" && \
echo "=== FILES ===" && \
echo "Directory: $WORK_DIR" && \
ls -la "$WORK_DIR" && \
echo "" && \
echo "=== REVIEW RESULT ===" && \
cat "$OUTPUT_FILE"
```

### Step 2: If Codex times out or fails

Check partial results:
```bash
SKILL_BASE="<absolute base dir Claude Code prints at skill load>" && \
LOADER="$SKILL_BASE/../shared/config-loader.sh" && \
LOG_DIR="$("$LOADER" data-dir)/runs/codex" && \
LATEST_DIR=$(ls -td "$LOG_DIR"/*-native-review-*/ 2>/dev/null | head -1) && \
[ -n "$LATEST_DIR" ] && echo "Latest: $LATEST_DIR" && ls -la "$LATEST_DIR" && \
[ -f "$LATEST_DIR/log.jsonl" ] && echo "=== Last 20 lines ===" && tail -20 "$LATEST_DIR/log.jsonl"
```

## Variations

### Review uncommitted changes

Replace the CMD line with:
```bash
CMD="codex exec review --json --dangerously-bypass-approvals-and-sandbox --uncommitted -m $MODEL -c model_reasoning_effort=\"$REASONING_LEVEL\""
```

### Review single commit

Replace the CMD line with:
```bash
CMD="codex exec review --json --dangerously-bypass-approvals-and-sandbox --commit ${COMMIT_SHA} -m $MODEL -c model_reasoning_effort=\"$REASONING_LEVEL\""
```

### Lower reasoning for speed

Set `REASONING_LEVEL="medium"` or `REASONING_LEVEL="low"` at the start.

## Comparison with codex-code-review

| Feature | codex-code-review | codex-review-native |
|---------|-------------------|---------------------|
| Prompt | Custom template | Built-in Codex |
| SHA range | Yes (via prompt) | No (branch only) |
| Uncommitted | No | Yes (`--uncommitted`) |
| Output file | `-o` flag | Parse from JSONL |
| Complexity | More control | Simpler |

**Use `codex-code-review` when:** you need custom SHA range or detailed prompt control.

**Use `codex-review-native` when:** reviewing against branch or uncommitted changes.

## Error Recovery

| Error | Solution |
|-------|----------|
| `codex: command not found` | `npm install -g @openai/codex` |
| `not authenticated` | `codex login` |
| `--base cannot be used with [PROMPT]` | Don't combine, use one or other |
| `-o unexpected argument` | Not supported, output parsed from log |
| Timeout | Check partial log with Step 2 |
| Variables empty | Ensure ALL commands in SINGLE Bash call |

## Log File Format

Log files have timestamp prefix on each line:
```
[HH:MM:SS] {"type":"...", ...}
```

**When parsing logs with jq, ALWAYS strip the timestamp first:**
```bash
grep 'pattern' "$LOG_FILE" | sed 's/^\[[0-9:]*\] //' | jq '...'
```

Without `sed`, jq will fail to parse and may cause "command not found" errors.
