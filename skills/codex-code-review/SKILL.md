---
name: codex-code-review
description: Send code for external review to OpenAI Codex CLI for cross-validation
user_invocable: true
---

# Codex Code Review

Dispatch code review to OpenAI Codex as external reviewer process.

**Announce at start:** "Using codex-code-review skill to get external review from Codex."

## Locating plugin files (Task 2.5)

When this skill loads, Claude Code prints `Base directory for this skill: <ABS>`. **`${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` are NOT available in Bash-tool calls** (CC 2.1.156). Set `SKILL_BASE` to that absolute path at the top of each Bash block; shared scripts live at `$SKILL_BASE/../shared/<x>` (e.g. `code-review-prompt.md`); the loader is `$SKILL_BASE/../shared/config-loader.sh`. Codex manages its own auth — this skill does NOT source provider tokens; it delegates execution to the `codex-exec` skill.

## CRITICAL: Tool Execution Rules

### Bash Variables

**The Bash tool runs each call in an ISOLATED shell. Variables DO NOT persist between calls.**

BAD (will fail):
```bash
# Call 1
BASE_SHA=$(git merge-base origin/main HEAD)
# Call 2
echo "$BASE_SHA"  # ERROR: $BASE_SHA is empty!
```

GOOD (use single call with &&):
```bash
BASE_SHA=$(git merge-base origin/main HEAD) && echo "$BASE_SHA"
```

**Rule: Put ALL related commands in ONE Bash call using `&&` to chain them.**

### Write Tool Limitation

**Write tool requires reading a file first.** For NEW files, use Bash heredoc:
```bash
cat > "/path/new-file.txt" << 'EOF'
content here
EOF
```

## When to Use

**Mandatory:**
- Critical changes (auth, payments, data migrations)
- Before merge to main on important features

**Optional:**
- When want "second opinion" from different model
- Parallel with internal superpowers:requesting-code-review

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

If any pre-flight check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.

## Process

### Step 1: Collect Git Context (SINGLE Bash call)

```bash
BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') && \
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}" && \
BASE_SHA=$(git merge-base origin/$BASE_BRANCH HEAD 2>/dev/null || git merge-base $BASE_BRANCH HEAD 2>/dev/null || git rev-parse HEAD~1) && \
HEAD_SHA=$(git rev-parse HEAD) && \
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-' || echo "unknown") && \
echo "Review range: $BASE_SHA..$HEAD_SHA" && \
echo "Branch: $BRANCH" && \
echo "" && \
git diff --stat "$BASE_SHA" "$HEAD_SHA"
```

Save the output values (BASE_SHA, HEAD_SHA, BRANCH) for Step 3.

### Step 2: Gather Description and Plan

Ask user (if not obvious from context):
- **What was implemented?** → fills `{DESCRIPTION}`
- **Where is the plan/requirements?** → fills `{PLAN_REFERENCE}`

Look for plans in:
- `docs/superpowers/**/*.md` (recent files)
- PR description
- Commit messages: `git log --oneline $BASE_SHA..$HEAD_SHA`

If no formal plan exists, use: `{PLAN_REFERENCE}` = "No formal plan - review for general quality"

### Step 3: Prepare Prompt

Render the template `$SKILL_BASE/../shared/code-review-prompt.md` (`SKILL_BASE` = the absolute base dir Claude Code prints at skill load; see "Locating plugin files" above) via `render-template.py`, substituting the **actual values** (not variables) collected in Steps 1-2 — SINGLE Bash call:

```bash
SKILL_BASE="<absolute base dir Claude Code prints at skill load>" && \
PROMPT_FILE=$(mktemp) && \
python3 "$SKILL_BASE/../shared/render-template.py" "$SKILL_BASE/../shared/code-review-prompt.md" \
    BASE_SHA=<actual base SHA> \
    HEAD_SHA=<actual head SHA> \
    DESCRIPTION='<what was implemented>' \
    PLAN_REFERENCE='<requirements or "No formal plan - review for general quality">' \
    > "$PROMPT_FILE" && \
echo "PROMPT_FILE=$PROMPT_FILE" && \
cat "$PROMPT_FILE"
```

Do NOT hand-assemble the prompt with bash `${var//find/replace}` substitution: on
bash >= 5.2 (`patsub_replacement` on by default) an unquoted `&` in the replacement
expands to the matched pattern, so a DESCRIPTION containing shell commands like
`a && b` silently corrupts the prompt. `render-template.py` substitutes argv values
literally on any bash version (tests: `shared/tests/test-render-template.sh`).

The `cat` output is the formatted prompt text for Step 4.

### Step 4: Execute via codex-exec Skill

**Use the Skill tool** to invoke the `codex-exec` skill. Do NOT read the skill file manually — call it via:
```
Skill tool -> skill: "claude-mesh:codex-exec"
```

Pass these parameters:

```
PROMPT=<formatted prompt from Step 3>
TASK_NAME="review-${BRANCH}"
SUPERVISED_MODE=shell
```

**Do NOT pass MODEL or REASONING_LEVEL unless the user EXPLICITLY requested specific values. When omitted, codex-exec resolves them from `config.yaml` (`codex.model` / `codex.reasoning_level`), falling back to `gpt-5.5`/`xhigh`. Never substitute o4-mini, gpt-4.1, or any other model on your own.**

The codex-exec skill will create a supervised work directory under the plugin data dir
(`${CLAUDE_PLUGIN_DATA}/runs/codex/`):
```
${CLAUDE_PLUGIN_DATA}/runs/codex/{timestamp}-review-{branch}/
├── prompt.md       # The review prompt
├── raw.jsonl       # Raw combined JSONL log
├── output.txt      # Final Codex response
├── report.md       # Human-readable report
├── watchdog.log    # Watchdog supervision log
├── attempt-1/      # Per-attempt artifacts
├── attempt-N/      # Additional restarted attempts, if any
└── final -> attempt-N/  # Final attempt artifacts
```

### Step 5: Present Results

After codex-exec completes, read `output.txt` from the work directory and present to user.

If the run succeeded after watchdog restart, include this short diagnostics banner after the review output:
```bash
ATTEMPTS=$(find "$WORK_DIR" -maxdepth 1 -type d -name 'attempt-*' | wc -l)
if [ ! -e "$WORK_DIR/watchdog.exit" ] && [ "$ATTEMPTS" -gt 1 ]; then
  printf '\n## Review Diagnostics\n'
  printf -- '- Attempts: %s (previous attempts were restarted by watchdog)\n' "$ATTEMPTS"
  printf -- '- Full log: %s/watchdog.log\n' "$WORK_DIR"
fi
```

Do not emit additional diagnostics when `watchdog.exit` exists; `codex-exec` already printed the full diagnostics block.

Display with clear formatting. Highlight:
- **Critical Issues** — must fix before proceeding
- **Important Issues** — should fix before merge
- **Assessment** — ready to merge verdict

Also provide links to supervised-compatible artifacts:
- Work directory path
- `report.md` — readable report
- `raw.jsonl` — raw combined JSONL log for debugging
- `watchdog.log` — watchdog supervision log
- `final/` — final attempt artifacts, when present

### Step 6: Handle Feedback

Apply `superpowers:receiving-code-review` skill principles:

1. **Verify** — check each issue against actual codebase
2. **Don't blindly agree** — Codex can be wrong
3. **Fix Critical** — immediately, no exceptions
4. **Fix Important** — before proceeding to next task
5. **Push back** — if Codex misunderstood, explain why with code references

## Checklist

- [ ] Pre-flight checks passed
- [ ] Git SHA range collected
- [ ] Description/plan identified
- [ ] Prompt formatted from template
- [ ] codex-exec skill invoked
- [ ] codex-exec invoked with SUPERVISED_MODE=shell
- [ ] Results presented to user
- [ ] Diagnostics block emitted if restart or bail occurred (restart banner is emitted here; bail diagnostics are emitted by codex-exec)
- [ ] Feedback processed (fixes or pushback)

## Error Recovery

| Error | Solution |
|-------|----------|
| `codex: command not found` | `npm install -g @openai/codex` |
| `not authenticated` | `codex login` |
| Timeout (30 min) | Partial log saved; review what was completed |
| Empty response | Check codex's own logs (`~/.codex/logs/`), retry |
| No git changes | Skip review, inform user |
| Codex disagrees with plan | Discuss with user, don't auto-fix |
| Variables empty | Ensure ALL commands in SINGLE Bash call |

## Integration Notes

- Can run **parallel** with `superpowers:requesting-code-review` for dual validation
- Output format matches internal reviewer for consistency
- Uses `receiving-code-review` principles for processing feedback
- Codex has filesystem access — it will read files itself
- Uses shared `codex-exec` skill for execution (reusable for other tasks)
