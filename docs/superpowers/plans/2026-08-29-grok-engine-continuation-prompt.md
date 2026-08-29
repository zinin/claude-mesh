## HOW THIS SESSION MUST BE STARTED

`claude --dangerously-skip-permissions --plugin-dir /opt/github/zinin/claude-mesh`

**Verify it before any live plugin work** — one command, and it is not optional:

```bash
grep -c -i grok "$(dirname "$(find ~/.claude/plugins /opt/github/zinin/claude-mesh \
    -path '*claude-mesh*/commands/mesh-review.md' 2>/dev/null | head -1)")/mesh-review.md"
```

A previous session lost a launch to this. Plugins resolve at session START; started without
`--plugin-dir`, `/claude-mesh:mesh-review` comes back as the INSTALLED copy
(`~/.claude/plugins/cache/zinin/claude-mesh/0.11.0/`) — `grep -c -i grok` = **0**, the pre-R29
four-option Q1, no Step 2.1, no Step 2.45, and no grok agents at all, so
`subagent_type: "claude-mesh:grok-code-reviewer"` does not resolve. The branch's copy measures
**80**. Running the installed one dispatches codex/gemini/claude and proves nothing.

**The version number will not warn you:** the repo's `.claude-plugin/plugin.json` and the
installed cache both say `0.11.0`. Same number, different content. Check the grep, not the
version. Positive signal: the agent roster lists `claude-mesh:grok-code-reviewer` and
`claude-mesh:grok-executor`.

## TASK

The **grok engine** plan is FULLY IMPLEMENTED — all 14 tasks, including Task 14's live
acceptance. What remains is the closing sequence: review the slice of the branch nobody has
reviewed, decide on a multi-model whole-branch pass, triage the deferred Minors, then
`superpowers:finishing-a-development-branch`.

## CRITICAL: DO NOT START WORKING

**STOP. READ THIS CAREFULLY.**

After loading all context below, you MUST:
1. Read the documents and understand the context
2. Report what you understood (brief summary)
3. **WAIT for explicit user instructions** before taking ANY action

**DO NOT:**
- Start reviewing, fixing or finishing the branch
- Make any code changes
- Run any commands (except reading documents)
- Assume which of the remaining items to start with

**The user will tell you exactly what to do.** Until then, only read and summarize.

## DOCUMENTS

- Design: `docs/superpowers/specs/2026-08-28-grok-engine-design.md` (428 lines)
- Plan: `docs/superpowers/plans/2026-08-28-grok-engine.md` (170 lines — every task is now a
  commit pointer; what is left of substance is the Global Constraints and the File Structure
  tables)
- **Ledger:** `.superpowers/sdd/2026-08-28-grok-engine/progress.md` — **read this too.** It
  holds all 40 rulings with their reasoning and cost-if-wrong, **53 deferred Minor findings**,
  the pre-flight conflict scan, and the per-task measurement notes including the whole of
  Task 14. It is git-ignored scratch, so it exists only on disk, not in the repo's history.

Branch: `feat/grok-engine`. Head: `e37f791`.

## PROGRESS

**Tasks 1-13** — each with a task review and, where findings appeared, a fix round and a scoped
re-review: `91edfb8`, `571d5f5`, `b05833b`+`604bc53`, `2ee8623`, `85f0463`+`3c60bec`,
`51abfba`+`0571072`, `9d6f8e2`+`7014162`, `bfdd6c3`, `3207ea1`, `5a0e13b`+`043171c`,
`f3b8c2d`+`aaae02c`, `e8c2f01`+`1f5bffa`, `c5fdacb`+`a84ca8c`.

**Task 14 — DONE.** Commits from the session of 2026-08-29:

- `56f9a22` `fix(config)` — the example's grok catalog could not run beside its own effort value
- `f8edb51` `review:` — four auto-fixes from the live review, plus the trailing-line loss fixed
  in every stream consumer
- `8c8583f` `review:` — a referenced broken grok catalog now degrades grok instead of grounding
  the environment (the one DISPUTED finding, decided by the user as Variant A)
- `d8bfb7b` `test(grok)` — the empty acceptance record
- `e37f791` `docs` — the plan trim

**Suite state at handover, all green:** config-loader **328**, verify-delegation 176,
watch-runs 99, preflight-env **221**, command-sync **34** passed / 1 skipped, extract-result 34,
render-template 44, loader-resolution 12, check-context-size 11. Live smoke test 8/8 with
`GROK_SMOKE=1`. Working tree clean, no subagents in flight.

## WHAT REMAINS

Three distinct things. The user asked, correctly, which one "the final review" means — do not
collapse them again.

**1. The delta nobody has reviewed (recommended first, cheap, highest risk).**
grok reviewed `90c9a08..56f9a22`. Everything after it — `f8edb51` and `8c8583f` — is 13 files,
**+183/-24, of which 109 lines are product code**, and it has been read by no reviewer. Measure
it as `git diff 56f9a22 8c8583f`, not against HEAD: `d8bfb7b` is the empty acceptance record and
`e37f791` is the plan trim, and both would inflate the count with documentation churn. It
contains `skills/shared/config-loader.sh` +49: a **behaviour change to `validate_defaults`**,
the function every orchestrator and `preflight-env.sh` hits first. Every other change on this
branch went implementer → reviewer → fix round → scoped re-review. This one went "the
controller decided, implemented and tested it". That asymmetry is the real gap.
Sharpest form: `/claude-mesh:mesh-review BASE_BRANCH=56f9a22`. **Do not use grok alone for it** —
the finding behind that change is grok's own, so grok reviewing the implementation is
self-checking, not cross-validation. codex and gemini are configured and independent.

**2. The multi-model whole-branch pass** — the SDD skill's actual last step. The branch HAS been
reviewed whole, but by one model. Cost on this machine: the `code_review` preset is ~9 reviewers
over a 41-file diff. The user's call, and it was left open.

**3. Triage of the 53 deferred Minors** in the ledger under `minor (deferred)`. Not a review — a
work pass. Nothing finishes the branch without it. The ones worth knowing early:

- **`README.md:191`** says "Install Grok Build" but the repository carries no URL and no package
  name for it. Open question raised twice already; branch-level, needs the user.
- **`README.md:116-118`** — suite figures stale: measured today it is ten suites and **~950**
  assertions against the documented "182 s, 580".
- **`verify-delegation.sh:449,:501`** — the ext-claude arm of both new `case`s is `*)`, so a third
  engine appended to `ext-claude|grok|…)` silently inherits ext-claude's archive number and its
  `bypassPermissions` remedy.
- **`verify-delegation.sh:131-140`** — the mandatory-model guard rejects `''` and `'-'` but not a
  model containing `/`, so a mis-templated `verify-delegation.sh grok zai/glm` resolves
  `runs/grok/zai/glm` and reports FLIP about a reviewer that ran.
- **`commands/mesh-review.md:265`** (pre-existing) — tells the orchestrator to write
  `BASE_BRANCH=<branch> MODEL=<id> …` for ext-claude, putting BASE_BRANCH ahead of MODEL on one
  line, while `agents/ext-claude-code-reviewer.md:26` requires MODEL "on the first line". Same
  ambiguity Task 7's Critical came from, one engine over.
- **`test-preflight-env.sh:666`** (pre-existing) — the git-remote twin carries the exact defect
  Task 10 fixed for grok: an unscoped `assert_match` on `"timeout"` that holds whatever the row
  says, because the row NAME `bash-timeout` prints in every scenario.
- **`skills/mesh-design-review/SKILL.md:224`↔`:503`** — the link between the two enumerations of
  the remembered set is one-directional, where the file's own idiom is a paired
  `<!-- SYNC: … -->`.

**Then:** `superpowers:finishing-a-development-branch`, and per the user's global CLAUDE.md,
before creating a PR: `git rm` everything under `docs/superpowers/` and commit — plan and design
documents must not appear in the PR diff. They stay reachable in branch history.

## SESSION CONTEXT (2026-08-29)

### The config, and a defect the plan itself shipped

The user **explicitly lifted** this plan's first Global Constraint for their own file
(«поправь сам конфиг»), so the live `config.yaml` was edited by the controller — backup taken,
mode 600 preserved. It now reads `grok: {models: [grok-4.6], reasoning_effort: xhigh}`.

**Why one model and not the plan's two.** `--effort` is validated PER MODEL, at argument
parsing, before any API call, and every rejection exits rc=1. Measured on grok 1.0.5 — three
different sets behind one binary:

| probe | answer |
|---|---|
| `grok -m grok-4.6 --effort __bogus__ -p x` | `xhigh, high, medium, low` — four, no `max` |
| `grok -m grok-4.5 --effort __bogus__ -p x` | `high, medium, low` — three |
| `grok --effort __bogus__ -p x` (default `codex-sol`) | `low, medium, high, xhigh, max` — five |

So the plan's Task 14 block AND `config.example.yaml` both shipped
`models: [grok-4.6, grok-4.5]` beside `reasoning_effort: xhigh` — a pair where half the catalog
dies at argument parsing with no diagnostic from the plugin. Fixed in `56f9a22` (catalog cut to
one model, not the effort lowered — the user's call). **The "five known values" in
`config-loader.sh:503`, `config.example.yaml` and `README.md:167` are correct as what the loader
passes without a WARN, but they are no model's set** — the five come from this machine's DEFAULT
model, and no grok-family model here accepts `max`. README still lacks that caveat; left for the
triage.

### Task 14's evidence

`/claude-mesh:mesh-review BASE_BRANCH=master`, grok:grok-4.6 the only reviewer, dispatched
through the real selection UI. Run dir
`runs/grok/grok-4.6/2026-08-29-16-30-42-25408-review-feat-grok-engine`: depth 2 as designed, one
attempt, no restart, no bail, `is_error=false`, 21 turns, 831 s, raw.jsonl 3.0 MB with exactly
one result event, output.txt 8332 non-space bytes against the 400 floor, stderr.txt empty,
`final -> attempt-1`. **Guard: `REAL`, rc 0.**

Both "never yet tested for real" items closed against a live run: the reviewer agent's depth-2
`find` located and named the run dir itself, and BASE_BRANCH reached `git merge-base` — the
skill reported `90c9a08..56f9a22` and `git merge-base master HEAD` is exactly `90c9a08`, so
Task 7's Critical is verified fixed by measurement. Delivery was exercised too: the wrapper went
idle after its interim status and answered the FIRST ping, its report matching `output.txt` read
independently from disk.

### The review's findings and how each was resolved

grok's verdict: **With fixes** — 0 Critical, 3 Important, 7 Minor. Every item was verified
against the code before acting.

- **AUTO (4), commit `f8edb51`.** (a) `grok-exec/SKILL.md`'s pre-flight gate compared
  `$(… 2>/dev/null)` against `"1"`, swallowing stderr and rc; `has_grok` VALIDATES, so a
  malformed catalog exited 1 with empty stdout and was reported as "not configured", after which
  the run continued onto the CLI default — `codex-sol`, not a grok model. Now rc-aware; driven
  through all four config states, exactly one behaviour changed. (b) Test 57's comment claimed
  `validate_defaults` "does not touch grok yet" — false since Task 3, and it hid a coverage gap.
  (c) `agents/grok-executor.md` gained the `${CLAUDE_PLUGIN_DATA}`-is-empty caveat its reviewer
  sibling already carried — and design review dispatches the EXECUTOR. (d) `test-command-sync`
  gained the mirror assertion, mutation-tested.
- **DECIDED (2).** The trailing-line loss (`while IFS= read -r line`) turned out to be a shared
  idiom, not a grok defect, so it was NOT auto-applied; the user chose to fix it everywhere. In
  the exec pipelines the dropped line is appended to `raw.jsonl`, so losing it removes the
  `result` event — verbatim what `verify-delegation.sh` calls STALLED, turning a completed run
  into a re-dispatch. Measured 2-of-3 events before, 3-of-3 after. Fixed in codex-exec,
  gemini-exec, grok-exec and `shared/stream-json-report.sh`; loops over `find`/`grep`/`printf`
  output deliberately left alone. **No comments were added inside those three fences** — each
  `while` closes a backslash continuation, which is R19's defect. And the DISPUTED item below.
- **DISMISSED (3).** The CHANGELOG minor is a false positive (`git show 85f0463` = R097
  `ext-claude-exec/generate-md.sh` → `shared/stream-json-report.sh`, so the entry names the
  source correctly). "Task 14 not done" was true at review time and was closed by that very run.
  `docs/superpowers/` on the branch is the user's own pre-PR `git rm` step.
- **REPEAT (1).** The Q1 label naming three engines on a one-engine machine — already in the
  ledger as an R29-mandated deferred Minor.

### The riskiest code on the branch — read `8c8583f` before touching the loader

Variant A, decided by the user. `validate_defaults` used to reach the full catalog check
whenever a preset named grok, and **die** there. Measured on `config.example.yaml`'s own shape
with one typo: both `get-defaults` calls exit 1, preflight prints `config INVALID` and SKIPPED on
EVERY row — claude, codex and gemini included — with `SUMMARY available: —`. A control with the
same broken catalog but grok in no preset gave `config OK` and INVALID on the grok row alone, so
the laziness only ever covered half its own invariant, while the design states that invariant
without qualification.

Now: the check runs in a **subshell** so its message is captured instead of ending the process;
`GROK_CATALOG_BROKEN=1`; grok is stripped from the emitted `builtin`, `grok_models` is emptied,
and a **new `grok_degraded: true` field** carries the fact to both orchestrators' preset
branches, which must announce the missing reviewer — the flag is the only signal, since grok is
already gone from the data. Strictness unchanged where it belongs: `validate` still rejects on
the full path, and `has_grok` / `list-grok-models` / `get-grok` still exit 1, which is what makes
preflight print INVALID rather than MISSING. Catalog-membership checking is skipped when there is
no readable catalog; charset and duplicate rules still apply. The fail-closed preset rules and
their five SYNC sites are untouched.

Measured after: `config OK`, claude-models OK, codex OK, grok INVALID alone,
`SUMMARY available: claude:opus, claude:fable, codex, zai/glm`, no grok on the defaults line.

RED before GREEN (7 failures, exactly the new assertions). New fixture
`fixtures/broken-grok-referenced.yaml`. config-loader 319→328, preflight-env 216→221,
command-sync 32→34.

### New findings from this session, for the triage

- **Step 2.45 cannot be asked as written when the catalog holds exactly ONE entry.**
  `AskUserQuestion` requires 2-4 options; the step says "for each chunk of 4 entries … max 4"
  with no single-entry clause. Step 2.1 HAS such a clause ("exactly one engine configured → skip
  the page"); the three model pages do not. Driven today by adding a second option from the
  step's own documented semantics ("ни одной — grok не запускать"), which is faithful but is not
  what the file says to build. Same shape in Step 2.4 (a one-entry `claude.models`), Step 3 (one
  ext-claude model) and Step 5.2.6 of the sibling. **The config change made this reachable** —
  with two catalog entries nothing would have shown.
- **`watch-runs.sh` startup message misleads on a first-ever run of an engine/model.** At
  dispatch it printed `no runs directory for 'grok/grok-4.6' … — check the roster entry` because
  `runs/grok/grok-4.6/` did not exist yet (dispatch 16:28:59, dir created 16:30:42). It
  re-resolved on a later tick and ended `ALL_DONE`/`DONE` correctly, but the advice is wrong for
  exactly the acceptance path. Engine-agnostic and pre-existing.
- **Unverified claim, not acted on:** `agents/grok-executor.md` states that `report.md` "shows
  only the first content block of each message". Worth one check against
  `shared/stream-json-report.sh`. The operational rule (read `output.txt`, never `report.md`)
  already stands for size reasons — 573 KB vs 9 KB on the acceptance run.
- **Repo-root debris, deliberately not touched:** `output.txt` (0 bytes) and `raw.json` (`[]`),
  both stamped 2026-08-29 00:15 — a previous session running `extract-result.py` with the repo
  root as work_dir. Untracked, excluded from every commit; the user was told rather than having
  them deleted unasked.

### Two controller mistakes worth not repeating

- **`grep … "$OUT"` in `test-preflight-env.sh`.** `$OUT` holds the report TEXT, not a path, so
  grep read it as a filename and its own error message became the haystack — one new assertion
  passed **vacuously** against "No such file or directory". Use a here-string (`<<<"$OUT"`), as
  the suite's own `field()` does.
- **Reverting a mutation with an unanchored `sed`.** The inverse substitution rewrote TWO
  pre-existing assertions (Task 10's scoped `grep '^grok'` at :577 and :585) along with the
  intended one. Repaired addressively; `git diff` on that file is additions only. Revert a
  mutation by restoring the file, not by inverting the sed.

### Process notes carried forward

- The user runs plan execution via `/claude-mesh:do-plan <threshold>`, driving
  `superpowers:subagent-driven-development`. `runtime.dispatch_model` is `opus`, so every `Agent`
  dispatch sets `model: "opus"`.
- **Reviewer replies get truncated by the delivery channel.** Have reviewers write the full
  report to `<workspace>/task-N-review.md` and return only the verdict, the Critical/Important
  findings in full, one-line Minors, and the Assessment. Ask for the tail rather than
  re-dispatching.
- **A wrapper never wakes on its own** when its background run finishes: disk-watch with
  `watch-runs.sh`, ping once per `DONE`, and read `output.txt` yourself after a second unanswered
  ping. Never record a reviewer as silent while the guard scores its run `REAL`.
- **`config.yaml` is user-owned.** It was edited this session ONLY because the user said so
  explicitly, for that one request. The standing rule stands.
- **Do not prescribe commit boundaries after the fact.**

## QUALITY WARNING

The plan is finished, so its own defects no longer matter — but the lesson it taught does, and
it applied three more times today:

**Every Critical and Important finding on this branch was found by MEASURING, not by reading —
and several lived under green tests.** Today: `config.example.yaml` shipped a model/effort pair
that could never run, and no test noticed because no test runs the CLI; `grok-exec`'s gate
reported "not configured" for a broken catalog, and the suites were green; and a test comment
**predicted** the referenced-catalog defect in words — "the day the full catalog check creeps
onto that path, these two assertions are what go red" — while the fixture held the one shape the
defect cannot reach, so they could not go red. The guard was written; the target was never
placed.

For prose-as-code files the equivalent of measuring is the trace: follow each name from where it
is written to where it is read, on every path. And note Task 12's lesson — an enumeration can be
stale without containing any token you grep for.

**If you notice any issue while working:**
1. STOP before proceeding with the problematic step
2. Clearly describe the problem you found
3. Explain why it does not work or seems incorrect
4. Ask the user how to proceed

Do NOT silently work around issues or make significant deviations without user approval.

## INSTRUCTIONS

1. Read the documents listed above — including the ledger
2. Understand current progress and session context
3. Provide a brief summary of what you understood
4. **STOP and WAIT** — do NOT proceed with any work
5. Ask: "What would you like me to work on?"
