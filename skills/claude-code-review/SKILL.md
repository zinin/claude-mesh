---
name: claude-code-review
description: Send code for review to the official Claude Code CLI (claude -p, HOST_CLAUDE=1)
user_invocable: true
---

# Claude Code Review

Dispatch code review to the official Claude Code CLI (`claude -p` after `claude login`).

**Announce at start:** "Using claude-code-review skill to get review from the Claude Code CLI."

## Optional argument: MODEL

`MODEL=<alias>` — one entry of the `claude.models` catalog, e.g. `MODEL=opus`.

**An omitted MODEL is a first-class path, not an error.** It means "run the CLI default"
(`claude -p` without `-m`), and the run lands in `runs/claude/_default/`. Both orchestrators
dispatch it deliberately: `commands/mesh-review.md` Step 0 and Step 2.4 ("Empty selection is
not an error"), and the sentinel option every one-option model page carries. That path is
reachable with a NON-empty `claude.models` catalog — the preset's `claude_models` list and the
`claude.models` catalog are different things — so the catalog being non-empty must never turn
an omitted MODEL into a STOP. `agents/claude-code-reviewer.md` says the same thing from the
other side: "If the first line is not `MODEL=`, still invoke the skill. Do not STOP."

A MODEL that IS supplied is still checked against the catalog when the catalog is non-empty.

Never pick a model yourself: the catalog belongs to the user's config, and an invented alias
fails at the CLI after a run directory has already been created.
`config-loader.sh list-claude-models` prints the catalog when you need to show the caller what
is available. `get-flag has_claude_models` is optional: a missing or empty catalog is not a
STOP (CLI default). A non-empty catalog must contain MODEL (`list-claude-models | grep -Fxq`).

## Optional arguments

- **BASE_BRANCH** — what to diff against. The orchestrator passes it on the line right after
  `MODEL=`. Substitute it into the FIRST line of Step 1's fence; left empty there, Step 1
  auto-detects `origin/HEAD` and falls back to `master`.
- **CONTEXT** — review context the caller inlined (scope, focus areas, project invariants).
  Use it as `{DESCRIPTION}` in Step 2 instead of asking the user.

## Locating plugin files (Task 2.5)

Set `SKILL_BASE` from the `Base directory for this skill: <ABS>` line Claude Code prints at load **if present**. Do not rely on Grok printing that line. **`${CLAUDE_PLUGIN_ROOT}`/`${CLAUDE_PLUGIN_DATA}` are NOT available in Bash-tool calls** (CC 2.1.156).

At the top of EACH bash fence:
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: claude-mesh plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/claude-code-review"
fi

Do not rewrite the fence. The else-branch searches `$HOME/.grok/installed-plugins` first (only inside a Grok session: bash has `GROK_SESSION_ID` there and not on Claude Code, so a two-host machine's stale snapshot never reaches a Claude Code run) — an unpublished `grok plugin install <tree>` copy, the one `grok inspect` loads, which a stale Claude cache must not outrank (measured 2026-09-01: `sort -V` on the cache picked 0.12.0 and the wrappers ran the old loader) — then `$HOME/.claude/plugins`, then `$HOME/.grok/plugins`, each version-sorted, `| sort -V | tail -1`, and each tried only when the previous root finds nothing. The roots are tried in PRIORITY order, never in one find over all three: `sort -V` compares whole paths, and `.claude` < `.grok`, so a single find picked the `.grok` copy whatever its version. `.claude` is where a published copy lives on both hosts — Grok loads a marketplace claude-mesh from the Claude cache; only an unpublished tree sits under `installed-plugins`. It then sets `PLUGIN_ROOT` two directories up, and sets `SKILL_BASE=$PLUGIN_ROOT/skills/<this-skill>`. The else-branch repeats `resolve-plugin-root.sh`'s remaining order IDENTICALLY — `$CLAUDE_PLUGIN_ROOT`, `$GROK_PLUGIN_ROOT`, then the three plugin trees — because it cannot call the helper (that is the file it is locating). Keep the two in step: they are one contract in two copies. If nothing resolves it STOPs, rather than resolving a `PLUGIN_ROOT` from the current directory.

Shared scripts live at `$SKILL_BASE/../shared/<x>` (e.g. `code-review-prompt.md`); the loader is `$SKILL_BASE/../shared/config-loader.sh`. Auth is `claude login` — this skill does NOT source provider tokens; it delegates execution to `ext-claude-exec` with `HOST_CLAUDE=1`.

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
- On Grok Build, when the user asked for `claude` reviewers (`opus` / `fable`) rather than
  native host slugs

**Optional:**
- When want "second opinion" from the Claude Code CLI
- Parallel with internal superpowers:requesting-code-review

## Pre-flight Checks

Run in ONE Bash call:
```bash
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: claude-mesh plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/claude-code-review"
fi
LOADER="$SKILL_BASE/../shared/config-loader.sh"
command -v claude >/dev/null 2>&1 || { echo "STOP: claude CLI not found — install Claude Code, then run 'claude login'"; exit 1; }
echo "OK: claude found"
command -v python3 >/dev/null 2>&1 || { echo "STOP: python3 not found - required by shared/render-template.py (Step 3)"; exit 1; }
echo "OK: python3 found"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "STOP: Not a git repository"; exit 1; }
echo "OK: git repo"
[ -x "$LOADER" ] || { echo "STOP: config-loader.sh not found or not executable at $LOADER"; exit 1; }
# has_claude_models is OPTIONAL: an empty or missing catalog means CLI default (no -m),
# not a STOP. Branch on the rc anyway: the flag VALIDATES before it reads, and a malformed
# claude: section must not be reported as "no catalog". rc=2 is "no config.yaml at all",
# which is unconfigured — continue without a membership check. Swallowing the rc reports
# "empty catalog" for a section that is right there.
CLAUDE_ERR=$(mktemp) || { echo "STOP: mktemp failed"; exit 1; }
FLAG_RC=0
HAS_CLAUDE_MODELS=$("$LOADER" get-flag has_claude_models 2>"$CLAUDE_ERR") || FLAG_RC=$?
if [ "$FLAG_RC" -eq 1 ]; then
    echo "STOP: config-loader could not read claude.models (rc=$FLAG_RC) — config.yaml is user-owned; agents never edit it. The loader says:"
    cat "$CLAUDE_ERR"; rm -f "$CLAUDE_ERR"; exit 1
fi
rm -f "$CLAUDE_ERR"
CLAUDE_CAT=""
if [ "$FLAG_RC" -eq 0 ]; then
    CLAUDE_CAT=$("$LOADER" list-claude-models) || { echo "STOP: claude.models is present but does not validate — fix config.yaml (user-owned; agents never edit it)" >&2; exit 1; }
fi
# Quoted heredoc, not a double-quoted assignment: a substituted value lands in an
# executable context, and the catalog check two lines down runs AFTER it — measured, a
# value carrying `"; cmd; x="` executed before that check rejected it. Same binding
# grok-code-review gives MODEL. `&&` cannot chain across a heredoc (it turns the body
# into commands), which is why the assignment stands alone.
MODEL=$(cat <<'__MODEL_BOUNDARY_4b7e2c19_MODEL_END__'
<the MODEL argument this skill was called with>
__MODEL_BOUNDARY_4b7e2c19_MODEL_END__
)
# An omitted MODEL is the CLI-default path and is valid whatever the catalog holds — see
# "Optional argument: MODEL" above. Membership is checked only for a MODEL that was supplied;
# gating a STOP on a non-empty catalog would break the documented empty-`claude_models`
# reviewer that `runs/claude/_default/` and the orchestrators' Step 5a already implement.
# A supplied MODEL becomes TWO things downstream, and the second is stricter than the
# catalog it came from. claude.models is validated with IDENT_RE ([A-Za-z0-9._:@-]) because
# its original role is a Task `model:` value on Claude Code, where it is never a path — and
# config.example.yaml keeps it deliberately permissive so a new model never needs a plugin
# release. On this path the same alias also becomes `runs/claude/<alias>/` and a
# `claude/<alias>` watch-runs roster entry, and BOTH of those are held to the narrow charset
# for the reason config-loader.sh:59-62 gives for grok.models. Catch that here, before a run
# dir exists: verify-delegation.sh and watch-runs.sh would each reject the alias afterwards
# with a usage error, which the orchestrator reads as "fix the call" over a reviewer that
# actually ran.
case "${MODEL:-}" in
    ''|*[!A-Za-z0-9._-]*|[!A-Za-z0-9]*)
        [ -z "$MODEL" ] || { echo "STOP: MODEL '$MODEL' cannot be used as a claude reviewer here — the alias becomes a run-dir component (runs/claude/<alias>/) and a watch-runs roster entry, both limited to [A-Za-z0-9][A-Za-z0-9._-]*. claude.models allows ':' and '@' for the Claude Code Task model: parameter, which is not a path. Pick an alias without ':' or '@'."; exit 1; } ;;
esac
if [ -n "$CLAUDE_CAT" ] && [ -n "$MODEL" ]; then
    printf '%s\n' "$CLAUDE_CAT" | grep -Fxq -- "$MODEL" || { echo "STOP: MODEL '$MODEL' is not in the claude.models catalog ($(printf '%s' "$CLAUDE_CAT" | tr '\n' ' ')) — pick one of those, or add it to config.yaml yourself. claude-mesh never substitutes a model of its own."; exit 1; }
    echo "OK: claude.models catalog ($(printf '%s' "$CLAUDE_CAT" | tr '\n' ' '))"
elif [ -n "$CLAUDE_CAT" ]; then
    echo "OK: MODEL omitted — CLI default (claude -p without -m), runs/claude/_default/; catalog ($(printf '%s' "$CLAUDE_CAT" | tr '\n' ' ')) not consulted"
else
    echo "OK: claude.models catalog empty (has_claude_models=${HAS_CLAUDE_MODELS:-0}) — CLI default if MODEL is omitted"
fi
```

If any pre-flight check fails, STOP and report the error to the user verbatim. Do NOT edit config.yaml (or any plugin config) yourself — only the user changes it.

Do **not** append a tooling-constraint paragraph. `claude -p` does not see Grok's plugin list
(spec §4). This skill has no such section.

## Process

### Step 1: Collect Git Context (SINGLE Bash call)

```bash
BASE_BRANCH=$(cat <<'__BASE_BOUNDARY_4b7e2c19_BASE_END__'
<the BASE_BRANCH argument, or leave empty to auto-detect>
__BASE_BOUNDARY_4b7e2c19_BASE_END__
)
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

**Fill in the heredoc body before running it.** Put the caller's `BASE_BRANCH` argument on
that line, or leave it empty to auto-detect. A QUOTED heredoc, for the reason the MODEL
binding above states: a substituted value in a double-quoted assignment is an executable
context. The `&&` chain therefore starts at `BASE_REF=` — it cannot cross a heredoc. It has to be substituted HERE, the way `SKILL_BASE` is:
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

Render the template `$SKILL_BASE/../shared/code-review-prompt.md` (`SKILL_BASE` = the absolute base dir Claude Code prints at skill load; see "Locating plugin files" above) via `render-template.py`, substituting the **actual values** (not variables) collected in Steps 1-2 — SINGLE Bash call. Do **not** append a tooling constraint.

```bash
SKILL_BASE="<absolute base dir Claude Code printed, or empty>"
if [ -n "$SKILL_BASE" ]; then
  PLUGIN_ROOT=$(SKILL_BASE="$SKILL_BASE" bash "$SKILL_BASE/../shared/resolve-plugin-root.sh")
else
  # Same order as resolve-plugin-root.sh: env roots, then the three plugin trees, installed-plugins first inside a Grok session. The
  # helper cannot be called from here (it is what we are locating), so the branch has
  # to repeat it — and repeat it IDENTICALLY, or the two copies of one contract drift.
  _LOADER=""
  for _R in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
    [ -n "$_R" ] && [ -f "$_R/skills/shared/config-loader.sh" ] && { _LOADER="$_R/skills/shared/config-loader.sh"; break; }
  done
  [ -f "$_LOADER" ] || [ -z "${GROK_SESSION_ID:-}" ] || _LOADER="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -f "$_LOADER" ] || _LOADER="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || _LOADER="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)" || true
  [ -n "$_LOADER" ] || { echo "STOP: claude-mesh plugin root not found — \$CLAUDE_PLUGIN_ROOT and \$GROK_PLUGIN_ROOT hold no plugin, and nothing under $HOME/.grok/installed-plugins, $HOME/.claude/plugins or $HOME/.grok/plugins matched" >&2; exit 1; }
  PLUGIN_ROOT=$(cd "$(dirname "$_LOADER")/../.." && pwd)
  SKILL_BASE="$PLUGIN_ROOT/skills/claude-code-review"
fi
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
echo "PROMPT_FILE=$PROMPT_FILE"
cat "$PROMPT_FILE"
```

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

The `cat` output — the rendered template — is the formatted prompt text for Step 4.

### Step 4: Execute via ext-claude-exec

**If this host has a Skill tool** (Claude Code): invoke `ext-claude-exec` with the Skill tool, then follow it.

```
Skill tool -> skill: "claude-mesh:ext-claude-exec"
```

**If this host has no Skill tool** (Grok Build): `Read` the plugin's `skills/ext-claude-exec/SKILL.md` and follow every step. Plugin root: `$CLAUDE_PLUGIN_ROOT` or `$GROK_PLUGIN_ROOT` if set to an existing directory; otherwise
`find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/ext-claude-exec/SKILL.md' 2>/dev/null | sort -V | tail -1` — and, only if that prints nothing, `find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/ext-claude-exec/SKILL.md' 2>/dev/null | sort -V | tail -1` — and, only if that prints nothing, `find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/ext-claude-exec/SKILL.md' 2>/dev/null | sort -V | tail -1`.
Following the skill **is** CLI delegation. It is not a review you perform yourself.

Pass these parameters:

```
HOST_CLAUDE=1
PROMPT=<formatted prompt from Step 3>
TASK_NAME="review-${BRANCH}"
MODEL=<the MODEL argument this skill was called with>
SUPERVISED_MODE=shell
```

**Model:** pass it through when the caller named one. An empty MODEL with an empty catalog
omits `-m` (CLI default). Do NOT invent an alias.

The run lands in `${CLAUDE_PLUGIN_DATA}/runs/claude/<alias>/{timestamp}-review-{branch}/`
(or `runs/claude/_default/` when MODEL is omitted):

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

After ext-claude-exec completes, read `output.txt` from the work directory and present to user. Then run this success-restart diagnostic check:

```bash
WORK_DIR=$(cat <<'WORK_DIR_EOF'
<work directory from ext-claude-exec>
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

If `$WORK_DIR/watchdog.exit` exists, do not print additional diagnostics here; `ext-claude-exec`
already emitted the full diagnostics block on its bail path.

Decide from `output.txt`, never from `report.md`: the renderer walks the WHOLE run, so
`report.md` runs to hundreds of KB against `output.txt`'s ten, and `output.txt` is the review
itself. It used to say the renderer showed only the first content block of each message; that
was true and is not any more — `shared/stream-json-report.sh` iterates every block on both the
assistant and the user branch, pinned by `shared/tests/test-stream-json-report.sh`. The rule
survives its old reason: size, not loss.

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
2. **Don't blindly agree** — the CLI reviewer can be wrong
3. **Fix Critical** — immediately, no exceptions
4. **Fix Important** — before proceeding to next task
5. **Push back** — if the reviewer misunderstood, explain why with code references

## Checklist

- [ ] MODEL argument received when the catalog is non-empty (never invented)
- [ ] Pre-flight checks passed (`command -v claude`; catalog membership only when a MODEL was supplied)
- [ ] Git SHA range collected
- [ ] Description/plan identified
- [ ] Prompt formatted from template (no tooling-constraint append)
- [ ] ext-claude-exec invoked with HOST_CLAUDE=1 and the caller's MODEL
- [ ] ext-claude-exec invoked with SUPERVISED_MODE=shell
- [ ] Diagnostics block emitted if restart or bail occurred (success-restart banner here; bail diagnostics from ext-claude-exec)
- [ ] Results presented to user
- [ ] Feedback processed (fixes or pushback)

## Error Recovery

| Error | Solution |
|-------|----------|
| `claude: command not found` | Install Claude Code, then `claude login` |
| `not authenticated` | `claude login` — do not paste a token into config.yaml |
| `unknown model` / CLI refuses `-m` | The MODEL is not a Claude Code alias — show `config-loader.sh list-claude-models` and let the caller choose; never substitute one |
| empty catalog, no MODEL | Expected: one run with no `-m` (CLI default). Run dir `runs/claude/_default/` |
| Timeout (30 min per attempt, 60 min overall) | Watchdog bail: read `watchdog.exit` and the per-attempt tails ext-claude-exec printed |
| Empty response | Check `$WORK_DIR/stderr.txt` and `$WORK_DIR/raw.jsonl`, retry |
| No git changes | Skip review, inform user |
| Reviewer disagrees with plan | Discuss with user, don't auto-fix |
| Variables empty | Ensure ALL commands in SINGLE Bash call |

## Integration Notes

- Can run **parallel** with `superpowers:requesting-code-review` for dual validation
- Output format matches internal reviewer for consistency
- Uses `receiving-code-review` principles for processing feedback
- The Claude Code CLI has filesystem access via tools — it reads files and runs git diff itself
- Uses shared `ext-claude-exec` skill with `HOST_CLAUDE=1` (official `claude login`, not a provider export)
- Run dirs are `$DATA_DIR/runs/claude/<alias>/` (depth 2, like grok)
- No tooling-constraint paragraph: `claude -p` does not see Grok's plugin list
