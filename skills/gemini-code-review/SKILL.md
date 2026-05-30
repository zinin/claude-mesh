---
name: gemini-code-review
description: Send code for external review to Gemini CLI for cross-validation
user_invocable: true
---

# Gemini Code Review

Dispatch code review to Google Gemini as external reviewer process.

**Announce at start:** "Using gemini-code-review skill to get external review from Gemini."

## Locating plugin files (Task 2.5)

When this skill loads, Claude Code prints `Base directory for this skill: <ABS>`. **`${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` are NOT available in Bash-tool calls** (CC 2.1.156). Set `SKILL_BASE` to that absolute path at the top of each Bash block; shared scripts live at `$SKILL_BASE/../shared/<x>` (e.g. `code-review-prompt.md`); the loader is `$SKILL_BASE/../shared/config-loader.sh`. Gemini manages its own auth — this skill does NOT source provider tokens; it delegates execution to the `gemini-exec` skill.

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
command -v gemini >/dev/null 2>&1 || { echo "STOP: gemini CLI not found - npm install -g @google/gemini-cli"; exit 1; }
echo "OK: gemini found"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "STOP: Not a git repository"; exit 1; }
echo "OK: git repo"
# Soft gate: warn (don't STOP) if optional gemini: block is unconfigured. gemini uses
# its own auth, so an absent block is non-fatal. get-flag emits 1/0 — compare to "1".
if [ -x "$LOADER" ] && [ "$("$LOADER" get-flag has_gemini 2>/dev/null)" != "1" ]; then
    echo "WARN: gemini: block not configured in config.yaml (gemini uses its own auth — continuing)"
fi
```

If any check fails, stop and help user fix it.

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

Read template from `$SKILL_BASE/../shared/code-review-prompt.md` (`SKILL_BASE` = the absolute base dir Claude Code prints at skill load; see "Locating plugin files" above).

Replace placeholders with **actual values** (not variables):
- `{BASE_SHA}` → actual base SHA (e.g., "abc1234")
- `{HEAD_SHA}` → actual head SHA (e.g., "def5678")
- `{DESCRIPTION}` → what was implemented
- `{PLAN_REFERENCE}` → requirements or "No formal plan"

Store the formatted prompt text.

### Step 4: Execute via gemini-exec Skill

**Use the Skill tool** to invoke the `gemini-exec` skill. Do NOT read the skill file manually — call it via:
```
Skill tool -> skill: "claude-mesh:gemini-exec"
```

Pass these parameters:

```
PROMPT=<formatted prompt from Step 3>
TASK_NAME="review-${BRANCH}"
APPROVAL_MODE=yolo            # Review needs filesystem access to read code and run git diff
SUPERVISED_MODE=shell
```

**Model:** do NOT pass `MODEL` by default. When omitted, `gemini-exec` resolves the
default from config (`config-loader.sh get-gemini` → `gemini.model`, falling back to
`gemini-3.1-pro-preview` on a fresh install). Pass `MODEL=<id>` ONLY when the user has
EXPLICITLY requested a specific different model — do NOT hardcode a model here.

**CRITICAL: APPROVAL_MODE must be `yolo` for code review.** The reviewer needs to run `git diff` and read files. `plan` mode (read-only) is NOT sufficient — Gemini needs tool execution to inspect the codebase.

The gemini-exec skill will create a supervised work directory under the plugin data dir
(`${CLAUDE_PLUGIN_DATA}/runs/gemini/`):
```
${CLAUDE_PLUGIN_DATA}/runs/gemini/{timestamp}-review-{branch}/
├── prompt.md       # The review prompt
├── raw.jsonl       # Raw stream-json events from the final attempt
├── output.txt      # Final Gemini response
├── report.md       # Human-readable report, when generated
├── watchdog.log    # Watchdog supervision log
├── attempt-*/      # Per-attempt raw.jsonl artifacts
└── final/          # Final successful attempt artifacts
```

### Step 5: Present Results

After gemini-exec completes, read `output.txt` from the work directory and present to user. Then run this success-restart diagnostic check:

```bash
WORK_DIR=$(cat <<'WORK_DIR_EOF'
<work directory from gemini-exec>
WORK_DIR_EOF
) && \
ATTEMPTS=0 && \
for attempt_dir in "$WORK_DIR"/attempt-*; do \
  [ -d "$attempt_dir" ] || continue; \
  ATTEMPTS=$((ATTEMPTS + 1)); \
done && \
if [ ! -f "$WORK_DIR/watchdog.exit" ] && [ "$ATTEMPTS" -gt 1 ]; then \
  echo ""; \
  echo "## Review Diagnostics"; \
  echo "- Attempts: $ATTEMPTS (previous attempts were restarted by watchdog)"; \
  echo "- Full log: $WORK_DIR/watchdog.log"; \
fi
```

If `$WORK_DIR/watchdog.exit` exists, do not print additional diagnostics here; `gemini-exec` already emitted the full diagnostics block.

Display with clear formatting. Highlight:
- **Critical Issues** — must fix before proceeding
- **Important Issues** — should fix before merge
- **Assessment** — ready to merge verdict

Also provide links to supervised-compatible artifacts:
- Work directory path
- `report.md` — readable report, when generated
- `raw.jsonl` — raw final-attempt output for debugging
- `watchdog.log` — watchdog supervision log
- `final/` — final successful attempt artifacts, when present

### Step 6: Handle Feedback

Apply `superpowers:receiving-code-review` skill principles:

1. **Verify** — check each issue against actual codebase
2. **Don't blindly agree** — Gemini can be wrong
3. **Fix Critical** — immediately, no exceptions
4. **Fix Important** — before proceeding to next task
5. **Push back** — if Gemini misunderstood, explain why with code references

## Checklist

- [ ] Pre-flight checks passed
- [ ] Git SHA range collected
- [ ] Description/plan identified
- [ ] Prompt formatted from template
- [ ] gemini-exec skill invoked with APPROVAL_MODE=yolo
- [ ] gemini-exec invoked with SUPERVISED_MODE=shell
- [ ] Diagnostics block emitted if restart or bail occurred (success-restart banner here; bail diagnostics from gemini-exec)
- [ ] Results presented to user
- [ ] Feedback processed (fixes or pushback)

## Error Recovery

| Error | Solution |
|-------|----------|
| `gemini: command not found` | `npm install -g @google/gemini-cli` |
| `not authenticated` | `gemini` (interactive mode to login) |
| Timeout (30 min) | Partial log saved; review what was completed |
| Empty response | Check `$WORK_DIR/stderr.txt`, retry |
| No git changes | Skip review, inform user |
| Gemini disagrees with plan | Discuss with user, don't auto-fix |
| Variables empty | Ensure ALL commands in SINGLE Bash call |

## Integration Notes

- Can run **parallel** with `superpowers:requesting-code-review` for dual validation
- Output format matches internal reviewer for consistency
- Uses `receiving-code-review` principles for processing feedback
- Gemini has filesystem access via tools — it reads files and runs git diff itself
- Uses shared `gemini-exec` skill for execution (reusable for other tasks)
