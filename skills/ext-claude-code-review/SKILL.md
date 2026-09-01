---
name: ext-claude-code-review
description: Run code review via claude -p on an alt-provider model (ext-claude-exec wrapper). Returns categorized Critical/Important/Minor findings.
user_invocable: true
---

# Ext-Claude Code Review

Wraps `ext-claude-exec` skill to run a code review prompt against any configured model.

**Announce at start:** "Using ext-claude-code-review skill to review via configured external model."

## Locating plugin files (Task 2.5)

Set `SKILL_BASE` from the `Base directory for this skill: <ABS>` line Claude Code prints at load **if present**. Do not rely on Grok printing that line. `${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` are NOT available in Bash-tool calls (CC 2.1.156).

At the top of EACH bash fence:
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the two plugin trees. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
  [ -n "$_LOADER" ] || { echo "STOP: claude-mesh plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-code-review"
fi

Do not rewrite the fence. The else-branch searches `$HOME/.claude/plugins` first — version-sorted, `| sort -V | tail -1` — and only falls back to `$HOME/.grok/plugins` when that finds nothing. The roots are tried in PRIORITY order, never in one find over both: `sort -V` compares whole paths, and `.claude` < `.grok`, so a single find picked the `.grok` copy whatever its version. `.claude` is where the active copy lives on both hosts — Grok loads claude-mesh from the Claude cache. It then sets `PLUGIN_ROOT` two directories up, and sets `SKILL_BASE=$PLUGIN_ROOT/skills/<this-skill>`. The else-branch repeats `resolve-plugin-root.sh`'s remaining order IDENTICALLY — `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT`, then the two plugin trees — because it cannot call the helper (that is the file it is locating). Keep the two in step: they are one contract in two copies. If nothing resolves it STOPs, rather than resolving a `PLUGIN_ROOT` from the current directory.

Shared scripts live at `$SKILL_BASE/../shared/<x>`; get the data dir via `"$LOADER" data-dir` where `LOADER="$SKILL_BASE/../shared/config-loader.sh"`.

## Input

- **MODEL** — model id (e.g. `zai/glm`, `ollama/kimi`)
- **BASE_BRANCH** — optional; default is auto-detected from `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `master` (iter-2 CONCERN-9 — user repos default to `master`, but auto-detect handles either)
- **CONTEXT** — optional context about the changes

## Process

> **Pre-flight is delegated entirely to ext-claude-exec.** Do NOT duplicate
> daemon/token checks here — copying the precheck blocks from the old
> `ccs-code-review` / `ollama-code-review` sources would create double prechecks.

### Step 1: Build review prompt

```bash
# Task 2.5: SKILL_BASE = absolute base dir Claude Code prints at skill load.
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the two plugin trees. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
  [ -n "$_LOADER" ] || { echo "STOP: claude-mesh plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/ext-claude-code-review"
fi
SHARED_DIR="$SKILL_BASE/../shared"
# Resolve the base branch ONCE. Auto-detect origin/HEAD, else fall back to master.
# NB: do NOT write the fallback as `symbolic-ref | sed || echo master` — `||` binds to
# the pipeline whose status is sed's (0 on empty input), so `echo master` would be dead
# code and BASE would silently resolve empty → `git diff ..HEAD` → empty review, no error.
BASE_REF=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}"
# Two lookups, because the name above need NOT exist as a local branch: origin/HEAD yields a
# bare name, and a caller's `BASE_BRANCH=` names whatever they want reviewed against — neither
# is guaranteed to be checked out here (--single-branch clones, worktrees, a release branch
# that was never fetched into a local ref). With one lookup BASE_SHA stayed empty and the
# template below rendered `git diff ..$HEAD_SHA`, which git reads as `HEAD..HEAD`: zero bytes,
# exit 0 — the reviewer then reports "no issues" about a diff it never saw. `|| true` keeps the
# assignment's status out of it, so the guard below is what decides, `set -e` or not.
# Deliberately NOT codex/gemini's third fallback `|| git rev-parse HEAD~1`: reviewing one commit
# while the caller believes the whole branch was covered is the same silent lie in another
# shape. No base ⇒ stop and say which names were tried.
BASE_SHA=$(git merge-base HEAD "$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null || true)
[ -n "$BASE_SHA" ] || { echo "STOP: no merge-base against '$BASE_BRANCH' (tried the bare name and origin/$BASE_BRANCH) - name a base that exists here"; exit 1; }
HEAD_SHA=$(git rev-parse HEAD)
# Fill the shared template's placeholders with REAL values — parity with the original
# ccs-/ollama-code-review (their Step 3). The reviewer model then runs `git diff
# $BASE_SHA..$HEAD_SHA` and reads files ITSELF, per the template's "## Your Task". We do
# NOT inline the diff: a real repo diff is hundreds of KB (it stalled the weaker
# providers), and an agent that fetches its own diff needs only the SHA range. Fresh
# alt-provider models (DeepSeek/Qwen/Kimi) drive Claude-Code tool_use fine.
# Rendering is delegated to render-template.py, NOT bash ${var//find/replace}: on
# bash >= 5.2 the patsub_replacement shopt is ON by default, so an unquoted '&' in the
# replacement expands to the matched pattern — a CONTEXT carrying shell commands like
# `cd test-server && python3 -m unittest` rendered as `cd test-server
# {DESCRIPTION}{DESCRIPTION} python3 -m unittest` (2026-07-16 incident). The renderer
# substitutes argv values literally on ANY bash version, in a single pass (text
# injected from a value is never re-scanned for placeholders). Tests:
# shared/tests/test-render-template.sh.
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found - required by render-template.py"; exit 1; }
DESC="${CONTEXT:-(no description provided)}"
PROMPT_FILE=$(mktemp)
python3 "$SHARED_DIR/render-template.py" "$SHARED_DIR/code-review-prompt.md" \
    BASE_SHA="$BASE_SHA" \
    HEAD_SHA="$HEAD_SHA" \
    DESCRIPTION="$DESC" \
    PLAN_REFERENCE="No formal plan - review for general quality" \
    > "$PROMPT_FILE" \
    || { echo "STOP: prompt render failed - see stderr above"; exit 1; }
[ -s "$PROMPT_FILE" ] || { echo "STOP: rendered prompt is empty"; exit 1; }
```

### Step 2: Delegate to ext-claude-exec

**If this host has a Skill tool** (Claude Code): invoke `ext-claude-exec` with the Skill tool, then follow it.

```
Skill tool -> skill: "claude-mesh:ext-claude-exec"
```

**If this host has no Skill tool** (Grok Build): `Read` the plugin's `skills/ext-claude-exec/SKILL.md` and follow every step. Plugin root: `$CLAUDE_PLUGIN_ROOT` or `$GROK_PLUGIN_ROOT` if set to an existing directory; otherwise
`find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/ext-claude-exec/SKILL.md' 2>/dev/null | sort -V | tail -1` — and, only if that prints nothing, `find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/ext-claude-exec/SKILL.md' 2>/dev/null | sort -V | tail -1`.
Following the skill **is** CLI delegation. It is not a review you perform yourself.

Pass these parameters:
- `MODEL={MODEL}`
- `PROMPT={contents of PROMPT_FILE}`
- `TASK_NAME=code-review-{branch-name}`
- `SUPERVISED_MODE=shell`

### Step 3: Return review findings

Read `${WORK_DIR}/output.txt` and surface the categorized findings as the
agent's response. Append a one-liner pointing to the full `report.md`.

## Error Recovery

If `ext-claude-exec` returns an error, surface verbatim and STOP. Do NOT
attempt to review the code yourself — the whole point is external review.
Do NOT edit config.yaml (or any plugin config) to "unblock" the run — config
is user-owned; report the error and wait for the user.
