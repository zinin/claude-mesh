---
name: grok-code-review
description: Send code for external review to the xAI Grok CLI for cross-validation
user_invocable: true
---

# Grok Code Review

Dispatch code review to xAI Grok as an external reviewer process.

**Announce at start:** "Using grok-code-review skill to get external review from Grok."

## Required argument: MODEL

`MODEL=<grok model id>` — one entry of the `grok.models` catalog, e.g. `MODEL=grok-4.6`.
Without it, STOP and report:

```
ERROR: MODEL is required. Example: MODEL=grok-4.6 Review the changes for production readiness
```

Never pick a model yourself: the catalog belongs to the user's config, and an invented id
fails at the CLI with `unknown model id` after a run directory has already been created.
`config-loader.sh list-grok-models` prints the catalog when you need to show the caller what
is available.

## Optional arguments

- **BASE_BRANCH** — what to diff against. The orchestrator passes it on the line right after
  `MODEL=`. Substitute it into the FIRST line of Step 1's fence; left empty there, Step 1
  auto-detects `origin/HEAD` and falls back to `master`.
- **CONTEXT** — review context the caller inlined (scope, focus areas, project invariants).
  Use it as `{DESCRIPTION}` in Step 2 instead of asking the user.

## Locating plugin files (Task 2.5)

When this skill loads, Claude Code prints `Base directory for this skill: <ABS>`. **`${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` are NOT available in Bash-tool calls** (CC 2.1.156). Set `SKILL_BASE` to that absolute path at the top of each Bash block; shared scripts live at `$SKILL_BASE/../shared/<x>` (e.g. `code-review-prompt.md`); the loader is `$SKILL_BASE/../shared/config-loader.sh`. Grok manages its own auth — this skill does NOT source provider tokens; it delegates execution to the `grok-exec` skill.

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
command -v grok >/dev/null 2>&1 || { echo "STOP: grok CLI not found — install Grok Build and run 'grok login'"; exit 1; }
echo "OK: grok found"
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found - required by shared/render-template.py (Step 3)"; exit 1; }
echo "OK: python3 found"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "STOP: Not a git repository"; exit 1; }
echo "OK: git repo"
# HARD gate here, unlike grok-exec's soft one. grok-exec only WARNs on a missing grok: section
# because grok handles its own auth, so a direct call is still runnable without a catalog. A
# REVIEW names a model FROM that catalog, and there is no catalog without the section — so this
# skill STOPs where grok-exec continues. Keep the two behaviours distinct.
[ -x "$LOADER" ] || { echo "STOP: config-loader.sh not found or not executable at $LOADER"; exit 1; }
# `get-flag has_grok` VALIDATES before it reads: it prints 1/0 when the config parses, and exits
# NON-ZERO carrying the validator's own message when the grok: section is present but malformed
# (config-loader.sh cmd_get_flag: "a consumer telling absent from broken must check rc, not
# stdout"; rc=2 is the separate "no config.yaml at all"). So branch on the rc and keep stderr out
# of the value — swallowing the rc reports "no grok: section" for a section that is right there,
# and the user then hunts for something that is not missing.
GROK_ERR=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
FLAG_RC=0
HAS_GROK=$("$LOADER" get-flag has_grok 2>"$GROK_ERR") || FLAG_RC=$?
if [ "$FLAG_RC" -ne 0 ]; then
    echo "STOP: config-loader could not read the grok: section (rc=$FLAG_RC) — config.yaml is user-owned; agents never edit it. The loader says:"
    cat "$GROK_ERR"; rm -f "$GROK_ERR"; exit 1
fi
rm -f "$GROK_ERR"
if [ "$HAS_GROK" != "1" ]; then
    echo "STOP: no grok: section in config.yaml — add one with a models: catalog, or pick another reviewer"; exit 1
fi
# The catalog itself, so the caller can see which ids are on offer. After the gate above this
# `||` branch is near-dead (has_grok validated the same catalog); it stays because it costs one
# line and it is what reports a config.yaml edited between the two calls.
GROK_CAT=$("$LOADER" list-grok-models) || { echo "STOP: grok: section is present but its catalog does not validate — fix config.yaml (user-owned; agents never edit it)" >&2; exit 1; }
echo "OK: grok: section present ($(printf '%s' "$GROK_CAT" | tr '\n' ' '))"
```

If any pre-flight check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.

## Process

### Step 1: Collect Git Context (SINGLE Bash call)

```bash
BASE_BRANCH="<the BASE_BRANCH argument, or leave empty to auto-detect>" && \
BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@') && \
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}" && \
BASE_SHA=$(git merge-base "origin/$BASE_BRANCH" HEAD 2>/dev/null || git merge-base "$BASE_BRANCH" HEAD 2>/dev/null || git rev-parse HEAD~1) && \
HEAD_SHA=$(git rev-parse HEAD) && \
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-') && BRANCH="${BRANCH:-unknown}" && \
echo "Review range: $BASE_SHA..$HEAD_SHA" && \
echo "Branch: $BRANCH" && \
echo "" && \
git diff --stat "$BASE_SHA" "$HEAD_SHA"
```

**Fill in the first line before running it.** Put the caller's `BASE_BRANCH` argument there, or
leave the string empty to auto-detect. It has to be substituted HERE, the way `SKILL_BASE` is:
`BASE_BRANCH` does NOT arrive as a shell variable — the Bash tool starts a fresh shell for every
call (see "Bash Variables" above) and the caller's value is prompt text, not environment. An
unsubstituted line makes `${BASE_BRANCH:-…}` take the fallback every time, and the review then
covers the wrong range while looking entirely successful. Empty is safe: `:-` fires on empty as
well as unset, so the no-argument path still auto-detects.

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

Render the template `$SKILL_BASE/../shared/code-review-prompt.md` (`SKILL_BASE` = the absolute base dir Claude Code prints at skill load; see "Locating plugin files" above) via `render-template.py`, substituting the **actual values** (not variables) collected in Steps 1-2, then append the tooling constraint — SINGLE Bash call:

```bash
SKILL_BASE="<absolute base dir Claude Code prints at skill load>"
DESC=$(cat <<'MESH_DESC_EOF'
<what was implemented — plain prose; apostrophes, quotes, &&, $(), backticks are all safe inside this quoted heredoc>
MESH_DESC_EOF
)
PLAN_REF=$(cat <<'MESH_PLAN_EOF'
<requirements, or: No formal plan - review for general quality>
MESH_PLAN_EOF
)
PROMPT_FILE=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
python3 "$SKILL_BASE/../shared/render-template.py" "$SKILL_BASE/../shared/code-review-prompt.md" \
    BASE_SHA=<actual base SHA> \
    HEAD_SHA=<actual head SHA> \
    DESCRIPTION="$DESC" \
    PLAN_REFERENCE="$PLAN_REF" \
    > "$PROMPT_FILE" || { echo "STOP: prompt render failed - see stderr above"; exit 1; }
[ -s "$PROMPT_FILE" ] || { echo "STOP: rendered prompt is empty"; exit 1; }
# Grok loads the user's Claude Code plugins, so `claude-mesh:mesh-review` and every other
# skill on this machine is visible to it. Nothing stops it from "helpfully" launching one
# instead of reviewing — and a nested orchestration would write run dirs this session never
# dispatched. codex and gemini need no such line: they cannot see those skills at all.
cat >> "$PROMPT_FILE" << 'GROK_TOOLING_EOF' || { echo "STOP: could not append the tooling constraint"; exit 1; }

## Tooling constraint

Do NOT invoke any skill or slash command, and do NOT delegate this review to another agent or
orchestration. Names like `claude-mesh:mesh-review` may be visible in your environment; they
are not part of this task. Read the code with your own file, search and shell tools, and
answer with the review itself.
GROK_TOOLING_EOF
echo "PROMPT_FILE=$PROMPT_FILE"
cat "$PROMPT_FILE"
```

**The append is part of THIS block — never its own Bash call.** A shell variable does not
survive from one Bash-tool call to the next (see "Bash Variables" above), so a separately
opened `cat >> "$PROMPT_FILE"` expands to `cat >> ""` and dies with `ambiguous redirect`,
shipping an unconstrained prompt or no prompt at all.

**No `&&` chaining across the heredoc** — which is why this block uses sequential commands with
explicit `|| { …; exit 1; }` guards instead of the `&&` chain the sibling skills use. What breaks
is the backslash-continued chain, not the `||`. Measured on bash 5.2: with
`cat >> "$f" << 'INNER' && \` the backslash pulls the body's first line into the command list,
where bash RUNS it (`appended-line: command not found`), and the delimiter line then closes an
EMPTY heredoc — so nothing is appended at all, `cat` exits 0, and the block reports success while
handing Step 4 an unconstrained prompt. A guard on the opener line with NO trailing backslash —
`cat >> "$f" << 'EOF' || { …; exit 1; }`, the form used above — is a different construct and was
measured safe under `set -euo pipefail`: the whole body is appended, none of it is executed, and
a failed redirect stops the block. Which is what that guard is for: an unguarded append that
fails would let Step 4 ship a prompt with no tooling constraint, which is exactly the prompt that
lets grok launch a nested orchestration.

Quoting rules (mesh-review hardening, 2026-07-16):
- Prose values go through quoted heredocs (`<<'MESH_DESC_EOF'`) and `"$VAR"` expansions —
  NEVER inline them into single/double quotes on the command line: an apostrophe in a
  commit-derived description breaks the quoting, and a crafted value (`x'; cmd; : '`)
  would EXECUTE when the block is run verbatim.
- Only constraint: the heredoc body must not contain a line consisting solely of the
  delimiter — if it does, switch that heredoc to another unique delimiter.
- Do NOT hand-assemble the prompt with bash `${var//find/replace}` substitution: on
  bash >= 5.2 (`patsub_replacement` on by default) an unquoted `&` in the replacement
  expands to the matched pattern, so a DESCRIPTION containing shell commands like
  `a && b` silently corrupts the prompt. `render-template.py` substitutes argv values
  literally on any bash version (tests: `shared/tests/test-render-template.sh`).

The `cat` output — the rendered template plus the tooling constraint — is the formatted prompt
text for Step 4.

### Step 4: Execute via grok-exec Skill

**Use the Skill tool** to invoke the `grok-exec` skill. Do NOT read the skill file manually:

```
Skill tool -> skill: "claude-mesh:grok-exec"
```

Pass these parameters:

```
PROMPT=<formatted prompt from Step 3, including the tooling constraint>
TASK_NAME="review-${BRANCH}"
MODEL=<the MODEL argument this skill was called with>
SUPERVISED_MODE=shell
```

**Model:** always pass it through — this skill refuses to run without one, so there is
nothing to resolve. Do NOT pass `REASONING_EFFORT` unless the caller explicitly named one;
`grok-exec` reads `grok.reasoning_effort` from config by itself.

The run lands in `${CLAUDE_PLUGIN_DATA}/runs/grok/<model>/{timestamp}-review-{branch}/`:

```
├── prompt.md       # The review prompt
├── raw.jsonl       # Anthropic-wire-format stream events from the final attempt
├── raw.json        # The same events as one JSON array
├── output.txt      # The review itself — this is what the caller reads
├── report.md       # Human-readable render of the whole run
├── watchdog.log    # Watchdog supervision log
```

Under `SUPERVISED_MODE=shell` the directory also carries `stderr.txt`, the per-attempt
`attempt-N/` directories and a `final` symlink to the winning attempt.

### Step 5: Present Results

After grok-exec completes, read `output.txt` from the work directory and present to user. Then run this success-restart diagnostic check:

```bash
WORK_DIR=$(cat <<'WORK_DIR_EOF'
<work directory from grok-exec>
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

If `$WORK_DIR/watchdog.exit` exists, do not print additional diagnostics here; `grok-exec`
already emitted the full diagnostics block on its bail path.

Decide from `output.txt`, never from `report.md`: the shared renderer shows only the first
content block of each message, so a reasoning model's answer can be missing from it entirely.

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
2. **Don't blindly agree** — Grok can be wrong
3. **Fix Critical** — immediately, no exceptions
4. **Fix Important** — before proceeding to next task
5. **Push back** — if Grok misunderstood, explain why with code references

## Checklist

- [ ] MODEL argument received (never invented)
- [ ] Pre-flight checks passed, including the hard `grok:` section gate
- [ ] Git SHA range collected
- [ ] Description/plan identified
- [ ] Prompt formatted from template
- [ ] Tooling constraint appended in the SAME Bash call as the render
- [ ] grok-exec skill invoked with the caller's MODEL
- [ ] grok-exec invoked with SUPERVISED_MODE=shell
- [ ] Diagnostics block emitted if restart or bail occurred (success-restart banner here; bail diagnostics from grok-exec)
- [ ] Results presented to user
- [ ] Feedback processed (fixes or pushback)

## Error Recovery

| Error | Solution |
|-------|----------|
| `grok: command not found` | Install Grok Build, then run `grok login` |
| `not authenticated` | `grok login` |
| `unknown model id` | The MODEL is not one xAI serves — show `config-loader.sh list-grok-models` and let the caller choose; never substitute one |
| `STOP: no grok: section` | The user adds a `grok:` block with a `models:` catalog — agents never edit config.yaml |
| Timeout (30 min per attempt, 60 min overall) | Watchdog bail: read `watchdog.exit` and the per-attempt tails grok-exec printed |
| Empty response | Check `$WORK_DIR/stderr.txt` and `$WORK_DIR/raw.jsonl`, retry |
| No git changes | Skip review, inform user |
| Grok disagrees with plan | Discuss with user, don't auto-fix |
| Variables empty | Ensure ALL commands in SINGLE Bash call |

## Integration Notes

- Can run **parallel** with `superpowers:requesting-code-review` for dual validation
- Output format matches internal reviewer for consistency
- Uses `receiving-code-review` principles for processing feedback
- Grok has filesystem access via tools — it reads files and runs git diff itself
- Uses shared `grok-exec` skill for execution (reusable for other tasks)
- Grok is the one engine here that can SEE this machine's Claude Code skills (`grok inspect`
  lists `~/.claude/CLAUDE.md` and every installed `claude-*` plugin), which is why Step 3
  appends the tooling constraint. There is no CLI flag that suppresses it.
