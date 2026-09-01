---
name: code-review-fresh-session
description: Generate a prompt for reviewing an implemented plan via /claude-mesh:mesh-review in a fresh Claude Code session, including one that runs in a sandbox
---

# Fresh-Session Code-Review Prompt Generator

<!-- SYNC: six regions of the generated prompt are shared with
     commands/design-review-fresh-session.md — change both files or neither. Ordered by how
     tightly each is held; where they differ, design-review text first, code-review second:
       1. DO NOT — byte-identical. Asserted by skills/shared/tests/test-command-sync.sh.
       2. PREFLIGHT — byte-identical. Asserted by the same test.
       3. ENVIRONMENT — one phrase differs: `mesh-design-review commits its own auto-fixes and
          its iteration log` / `mesh-review commits its own auto-fixes and decisions`. The
          shorter phrase reflows the wrap of the sentence that follows.
       4. THEN STOP item 1 — `Summarise the documents in 5–10 lines.` /
          `Summarise what was built, in 5–10 lines.`
       5. WHEN THE USER SAYS GO, opening paragraph — identical after the invocation sentence
          (`mesh-design-review` with DESIGN_PATH/PLAN_PATH/TOPIC / bare `mesh-review`), whose
          length also sets the wrap of everything after it.
       6. WHEN THE USER SAYS GO, the `default`-safety rule — identical with `design_review`
          swapped for `code_review` and nothing else.
     The DO NOT block's exact wording — line breaks and em dash included — is what a 5-run A/B
     against a no-gate control actually measured (5/5 held, control failed 3/3). Reformat it and
     you are shipping an untested gate. -->

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
# Substitute the BASE_BRANCH= argument into the line below, or leave it as written when the
# argument was not given. A command argument is not an environment variable and does not
# reach this subshell on its own — without this line a user-supplied base is silently lost.
# `${BASE_BRANCH:-}` and not `""`: an agent handed a base branch reaches for the env prefix
# (`BASE_BRANCH=develop bash …`) at least as readily as for the substitution, and a bare `""`
# clobbers exactly that. Both paths arrive here now; the `:-` keeps it safe under `set -u`.
BASE_BRANCH="${BASE_BRANCH:-}"
BASE_REF="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
BASE_BRANCH="${BASE_BRANCH:-${BASE_REF:-master}}"
BASE_SHA="$(git merge-base HEAD "$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null)"
HEAD_SHA="$(git rev-parse HEAD)"
# symbolic-ref, not rev-parse --abbrev-ref: a detached HEAD would otherwise put the literal
# string "HEAD" into the prompt as a branch name.
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD)"
DIRTY="$(git status --porcelain)"
# Print every value this block resolved. Shell state does not survive a Bash tool call, so a
# value that is only assigned here is a value the composing step below never sees — and Step 5
# asks you to substitute four of them. Without this the base silently reverts to a guess, which
# is exactly what resolving it was for.
printf 'BRANCH=%s\nBASE_BRANCH=%s\nBASE_SHA=%s\nHEAD_SHA=%s\nDIRTY=%s\n' \
  "$BRANCH" "$BASE_BRANCH" "$BASE_SHA" "$HEAD_SHA" "${DIRTY:+yes}"
# Guarded: an empty BASE_SHA would make this `HEAD..$HEAD_SHA` — empty output, exit 0, and a
# missing base would look exactly like a branch with no commits.
if [ -z "$BASE_SHA" ]; then
  echo "merge-base found no base against '$BASE_BRANCH' — ask the user for the base branch"
elif [ "$BASE_SHA" = "$HEAD_SHA" ]; then
  # Generating from the base branch itself: the range is empty and the guard above cannot see
  # it, so the prompt would carry an empty commit list with nothing saying why.
  echo "BASE_SHA == HEAD_SHA — this branch is AT '$BASE_BRANCH', so the range is empty; ask the user which branch to review"
else
  git log --oneline "$BASE_SHA..$HEAD_SHA"
fi
```

`BASE_BRANCH` goes into the prompt BY NAME (see `DOCUMENTS` below), because the last line of
that chain is a guess: `refs/remotes/origin/HEAD` is unset in plenty of clones — including the
sandbox case this command is built for — and the fallback to `master` is otherwise silent. A
range computed against a guessed base has to say which base it guessed.

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
`<DESIGN_PATH>`, `<PLAN_PATH>`, `<BRANCH>`, `<BASE_BRANCH>`, the shas and the commit list —
and nothing more:
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
- Git range: `<BASE_SHA>..<HEAD_SHA>` on branch `<BRANCH>`, against base `<BASE_BRANCH>`
  (HEAD at generation: `<HEAD_SHA>`). If HEAD has moved since, review through the current
  HEAD and say so. Pass that base on when starting the review (see the invocation below):
  without it every review skill auto-detects its own — `origin/HEAD`, else `master` — which
  is a different range whenever this base is not the repository default.
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
[ -f "$PF" ] || PF="$(find "$HOME"/.grok/installed-plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || PF="$(find "$HOME"/.claude/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || PF="$(find "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/preflight-env.sh' 2>/dev/null | sort -V | tail -1)"
[ -f "$PF" ] || { echo "preflight-env.sh not found — older claude-mesh here; expected degradation, NOT a broken environment"; exit 0; }
bash "$PF"
```

Print the table verbatim. Do not soften a verdict into "probably fine". `OK` on the codex /
gemini rows is a heuristic — binary present, section valid, endpoint answered; NOT an auth
check, and it does not prove the CLI points at that endpoint. `OK` on grok is stronger: the
probe runs the CLI itself, which answers only when a login is live. `OK` on gh / glab means
presence on PATH only. If the script is not found, say so and ask the user whether to update
the plugin in this sandbox first or proceed on the built-in `claude` reviewer alone — and
before offering that, check a `config.yaml` exists in the plugin data dir: claude needs no
config section, but the review skills refuse to start without a usable config.yaml at all.

## CONTEXT

<from step 4>

## THEN STOP

1. Summarise what was built, in 5–10 lines.
2. Print the preflight table verbatim.
3. One line: which reviewers are actually available here.
4. Wait. Do not start the review on your own.

## WHEN THE USER SAYS GO

Invoke `/claude-mesh:mesh-review BASE_BRANCH=<BASE_BRANCH>` and select only reviewers the
preflight marked available. The argument is what makes the reviewers look at the range named
under DOCUMENTS; drop it and each skill re-detects a base of its own.
The two halves of the table answer different questions, so read both: **`SUMMARY available`
decides eligibility** — a reviewer absent from that line cannot be selected whatever its own row
says, because a row reports whether that endpoint answered, not whether the orchestrator starts.
With a rejected `claude:` section, `provider:*` rows can read `OK` next to `SUMMARY available: —`,
and both orchestrators exit on the catalog read before offering anything. **The ROWS carry the
caveats** the summary has no room for: `OK` on codex / gemini is a heuristic — binary present,
section valid, endpoint answered — and says nothing about auth, while `OK` on grok also means
a live login: its probe runs the CLI itself.

Whether the `default` argument is safe here is a membership check between two SUMMARY lines.
Split both on `, ` and compare WHOLE entries — never substrings: a bare `claude` is a substring
of `claude:<model>`, and `<provider>/<model>` of `<provider>/<model>-<variant>`, so a substring
test reports a match where the orchestrator would find none.

- `SUMMARY available: —` → `default` is never safe, however the defaults line reads. Nothing is
  selectable in that environment, and membership against an empty list is vacuously true — the
  one case where the mechanical check would say yes precisely when the answer is no. With no
  usable config both lines print `—`; with a rejected `claude:` section the defaults line prints
  a real list next to an empty available line.
- `SUMMARY defaults code_review: —` or `— (preset empty)` → also never safe, for the same
  reason read the other way: there is no preset to run, and `default` mode stops instead of
  starting.
- Otherwise `default` is safe only when every entry of the defaults line is also an entry of the
  available line — with one exception: a bare `claude` on the defaults line is satisfied by any
  `claude:<model>` entry on the available line. That spelling means the preset carries no
  `claude_models`, and the orchestrator then runs exactly one reviewer named literally `claude`
  on the session's dispatch model, which asks the catalog for nothing.

Anything short of that → select interactively.
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
