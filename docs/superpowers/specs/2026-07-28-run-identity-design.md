# Session-scoped run identity — design

Date: 2026-07-28
Branch: `fix/watch-loop-stall-detection`
Status: approved for planning

## Problem

Codex's automated review of PR #9 named it (P1, `skills/shared/watch-runs.sh:191`): a roster
entry resolves to the newest run directory under `runs/<entry>`, with nothing binding that
directory to the dispatch that created it. The plugin's data directory is global
(`~/.claude/plugins/data/claude-mesh-*/runs`), so two orchestrations of the same
engine/model — two `/mesh-review` sessions, or a `/mesh-review` and a `/mesh-design-review`,
in two different repositories — write into one namespace. The earlier session's watcher then
switches to the later session's run: it reports `DONE` / `FAILED` / `SILENT` about a run it
never dispatched, pings its own wrapper early, and — because design review now chains the
content gate to the watcher — hands `verify-delegation.sh` the wrong directory, which
discards a finished review.

Two parts of that review shaped this design by being wrong, and are recorded so they are not
re-derived:

- *"Concurrent invocations are explicitly supported in `commands/mesh-review.md`."* The file
  says the opposite at `:386`, a line inherited from master: "If two `/mesh-review`
  invocations run the same model concurrently, the window can overlap — rare in practice; run
  them sequentially if exact attribution matters." Line `:290` makes the *team name*
  collision-proof, not the run directories.
- *"Include a dispatch-specific task suffix in resolution."* `TASK_NAME` carries nothing
  session-unique: design review sends `design-review-[TOPIC]-iter-N`
  (`skills/mesh-design-review/SKILL.md:403,416`) and the `/mesh-review` path builds
  `review-${BRANCH}` inside the review skills (`skills/codex-code-review/SKILL.md:160`). Two
  concurrent sessions on one topic or one branch produce byte-identical suffixes — the exact
  case reported. A token appended to the name is also cut: the exec skills sanitize with
  `tr -cd '[:alnum:]._-' | head -c 64`, and a real name is already 47 characters
  (`design-review-watch-loop-stall-detection-iter-1`).

The property is **inherited, not introduced**. On master `verify-delegation.sh` already
selected `find -newermt "@$SINCE" … | sort -rn | head -1` — the newest directory across every
session. What this branch adds is a second consumer of the same rule and a chain between the
two, which turns a documented caveat into a discarded review.

## Root cause

Nothing inside a run directory says who dispatched it. Identity therefore has to come from
somewhere the directory can record at creation, and creation happens in the exec skills —
`codex-exec:151`, `gemini-exec:144`, `ext-claude-exec:150`, `codex-review-native:118` — from
`date +%Y-%m-%d-%H-%M-%S-$$` plus a sanitized `TASK_NAME`. The `$$` is unique per run but
belongs to a process the orchestrator never sees, and the name is not the orchestrator's to
control.

## Decisions

### 1. Identity is ambient, not passed

`CLAUDE_CODE_SESSION_ID` is exported into Bash tool calls and **inherited across the agent
boundary**. Verified 2026-07-28 by dispatching a subagent that printed its environment: the
same UUID as the orchestrator (`23bfdbad-68df-40af-bfc3-3f72f8b04b61`), the same
`CLAUDE_PID`, and the same value inside a subshell. The repository already keys per-session
state on that identifier — `hooks/check-context-size.sh:76` derives its session key from the
transcript basename, which is that UUID.

The exec skill therefore stamps it into the run directory itself. No new parameter, no prompt
text, no agent contract:

- an executor cannot fail to forward what it never handles, and this branch's own history is
  a catalogue of dispatch-contract non-compliance;
- an improvised re-run — the failure mode the roster design exists for, observed four times
  in one run — happens inside the same session and inherits the same stamp automatically. A
  `RUN_TAG` parameter would not guarantee that: the retry is improvised, and so is the
  parameter list it carries;
- both orchestrator prompts and their sync note stay exactly as they are.

`CLAUDE_CODE_SESSION_ID` and not `CLAUDE_CODE_BRIDGE_SESSION_ID`: the former is the local
session UUID the repository already uses, and it survives `claude --resume`, so a resumed
session still recognises its own runs.

**Rejected — `RUN_TAG` threaded through the dispatch.** Orchestrator → executor agent → exec
skill is two hops in design review and three on the `/mesh-review` path (the reviewer agent
and the `*-code-review` skill sit in between, and that path's wrapper prompts are
deliberately kept short — `mesh-review.md:231`). About twelve files, and the whole chain is
LLM-mediated: when forwarding fails, the run is unstamped, which is precisely the fail-open
hole in Decision 2. It buys one thing this design does not: identity finer than a session.

**Rejected — anchor the watcher on the reported run dir.** The orchestrator does capture each
wrapper's directory from its interim status (`mesh-review.md:246`), so the watcher could take
it as an anchor and move on only when the anchor goes quiet. It needs no plumbing, but it is
a heuristic that adopts a foreign run whenever one's own dies first, and it gives
`verify-delegation.sh` — a one-shot call with no anchor — nothing at all.

### 2. An absent stamp means eligible

A directory with no `.session_id` — or one whose stamp is empty — is a run from a plugin
version older than this change, a direct `/claude-mesh:*-exec` invocation, or a harness that
does not export the variable. Those must stay selectable, so the predicate fails **open**.

Fail-closed was considered and rejected: an unstamped live run would resolve to no candidate,
the watcher would report `MISSING`, and the orchestrator would declare a working executor
dead — worse than the collision being fixed, and in the same direction as the bug this branch
exists to remove (never declare a live run dead).

The cost is stated rather than hidden: isolation is complete only when both sides stamp.
While this change is on a branch and 0.5.0 is installed, the dogfooding configuration itself
is a mixed pair.

### 3. Selection becomes "newest acceptable"

Both consumers keep their present ordering — shape-filtered candidates, newest by name — and
walk down it until one passes the predicate, instead of taking the maximum and then checking
it. Reading the stamp only as far as the walk goes keeps the common case at one file read.

If no candidate qualifies, both behave exactly as they already do when nothing matched:
`watch-runs.sh` reports `RUN` inside the grace window and `MISSING` after it,
`verify-delegation.sh` emits `FLIP`. Neither needs a new status: "none of these runs is mine"
and "there is no run" call for the same action.

### 4. The predicate is duplicated, not extracted

Six lines in each consumer with a cross-reference comment, following the precedent this
branch already set for the shape filter (`verify-delegation.sh:88` points at
`watch-runs.sh:189`). `skills/shared/` has no sourcing convention today; introducing one for
six lines would be a new pattern where an existing one fits.

## Component A — stamp at creation

One line in each of the four sites that create a run directory:

```bash
printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}" > "$WORK_DIR/.session_id"
```

Three of them take it directly after the existing `.task_name` write —
`skills/codex-exec/SKILL.md:155`, `skills/gemini-exec/SKILL.md:148`,
`skills/ext-claude-exec/SKILL.md:152`. The fourth is easy to miss and matters:
`skills/codex-review-native/SKILL.md:119` writes `${TIMESTAMP}-native-review-${BRANCH}` into
the same `runs/codex/` namespace and does not write `.task_name` at all, yet its directories
pass the shape filter and compete for selection like any other run. There the line goes into
the `&&` chain immediately after `mkdir -p "$WORK_DIR" && \`.

**The write is unconditional, and that is a requirement rather than a shortcut.** That fourth
site is a single `&&`-chained command list (`:115-126`), so a guarded form —
`[ -n "$X" ] && printf …` — would evaluate to false whenever the variable is empty and
silently skip **every command after it in the chain**, killing the run. `printf` always
returns 0, so one unconditional line is safe in all four sites and needs no per-site variant.

With no session id the file holds an empty line, which the reader treats exactly as an absent
file (Decision 2). "No identity available" and "legacy run" therefore behave identically
without the writer having to branch.

## Component B — filter at selection

```bash
SELF_SID="${CLAUDE_CODE_SESSION_ID:-}"
run_is_mine() {                                   # $1 = run dir
    [ -n "$SELF_SID" ] || return 0                # reader has no identity → filter off
    local v=""
    [ -r "$1/.session_id" ] && IFS= read -r v < "$1/.session_id"
    [ -z "$v" ] || [ "$v" = "$SELF_SID" ]         # unstamped → eligible (Decision 2)
}
```

**`watch-runs.sh`** (`resolve_run_dir`, `:172-195`): the single glob pass stays, but eligible
names go into an array instead of collapsing to a maximum. Bash expands the glob in ascending
order and `LC_ALL=C` is exported at `:35`, so walking the array backwards yields
newest-first; the first entry passing `run_is_mine` wins. No subprocess, matching the
script's existing "no `find`, no `date`, no subshell" property.

**`verify-delegation.sh`** (`:94-95`): `find … | grep -E … | LC_ALL=C sort -r | head -1`
loses its `head` and feeds a `while read` that breaks on the first acceptable name.

Nothing else changes: not the interfaces of either script, not the orchestrator prompts, not
the agent contracts, not `config.example.yaml`.

## Testing

`skills/shared/tests/test-watch-runs.sh` — six new assertions:

| Fixture | Expectation |
|---|---|
| newest dir stamped with a foreign id, own-stamped dir older | the own dir resolves |
| newest dir unstamped | accepted (legacy fallback) |
| reader's `CLAUDE_CODE_SESSION_ID` unset | filter off — newest wins regardless of stamps |
| every candidate foreign | `RUN` inside grace, `MISSING` past it |
| `.session_id` empty or unreadable | treated as unstamped |
| own quiet original, own newer retry, a foreign dir newer than both | the own retry is followed |

`skills/shared/tests/test-verify-delegation.sh` — four new assertions: the first three of the
above, plus "every candidate foreign → `FLIP`".

Tests that exercise the filter set `CLAUDE_CODE_SESSION_ID` explicitly; the "filter off" case
runs under `env -u CLAUDE_CODE_SESSION_ID`. The other 484 assertions are **not** rewritten:
their fixtures create unstamped directories, for which the predicate is inert.

The exec skills are prompt markdown and are verified the way Component A of the parent design
was — by reading and by grep: four write sites, each inside the same Bash block as its
`mkdir -p`.

One end-to-end smoke run (`codex-exec` with a trivial prompt) confirms the stamp appears on
disk. It is the only check that covers substitution in the markdown template rather than a
test fixture.

Every existing suite must end `0 failed`, with no hardcoded pass count.

## Files

New: none.

Modified:
- `skills/shared/watch-runs.sh` — predicate, `resolve_run_dir` walk
- `skills/shared/verify-delegation.sh` — predicate, candidate walk
- `skills/codex-exec/SKILL.md`, `skills/gemini-exec/SKILL.md`,
  `skills/ext-claude-exec/SKILL.md`, `skills/codex-review-native/SKILL.md` — stamp
- `skills/shared/tests/test-watch-runs.sh`, `skills/shared/tests/test-verify-delegation.sh`
- `CHANGELOG.md` — `[Unreleased]`

## Out of scope, and known limits

- **Two orchestrations inside one session**, and a manual `/claude-mesh:*-exec` run started
  while a review is in flight, share the session id and stay indistinguishable. Broken today
  in the same way; not closed here. `RUN_TAG` would close it and can be layered on top if the
  case is ever observed.
- **Mixed plugin versions.** An unstamped run from an older installed version is eligible for
  every reader, by Decision 2.
- **Not a security boundary.** Any process can write `.session_id`; this coordinates
  cooperating tools, it does not isolate hostile ones.
- The `mtime`-versus-name eligibility difference between the two consumers, documented as
  deliberate in the parent design, is untouched.
- No change to `watchdog.sh`, to `max_redispatch`, or to either orchestrator prompt.
