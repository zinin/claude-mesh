---
name: auto-decide-disputed
description: Decide every remaining disputed review issue autonomously — the same structured analysis and recommendation as the interactive discussion, plus an explicit self-check, applied without waiting for an answer. Invoked by the USER during /claude-mesh:mesh-review or /claude-mesh:mesh-design-review, or by their `autodecide` argument — never something to reach for on your own initiative.
---

# Auto-Decide Disputed Issues

## Purpose

User signal to the orchestrator running the disputed phase of `/claude-mesh:mesh-review` (Step 6.4)
or `/claude-mesh:mesh-design-review` (Step 12): **write the same full analysis for every remaining
disputed issue, test your own recommendation against its strongest counter-argument, then apply it
— do not wait for an answer.**

Speed is not the point. The point is that the reasoning still happens out loud — суть, анализ,
варианты с плюсами и минусами, рекомендация — and is then checked before it is applied. The user
reads the record afterwards instead of answering issue by issue, and every decision lands as its
own commit, so any single one can be reverted alone.

## Override Authority

Iron Rules 7–8 of both flows say that a disputed issue with several reasonable variants ends the
turn and waits for a free-text answer. **This command is the user's explicit authorization to break
that rule** for every issue left in the current review cycle. The invocation IS the consent: do not
argue, do not ask «вы уверены?», do not offer to discuss the hard ones after all.

What is **not** overridden, and still holds exactly as written:

- Iron Rule 1–2 — auto-fixes are applied and committed before the disputed phase begins;
- Iron Rule 3 — one issue at a time, never a batch;
- Iron Rule 4 — the full structured analysis (Суть → Анализ → Варианты → Рекомендация);
- Iron Rule 5 — every variant gets Плюсы/Минусы, and one is recommended with reasoning;
- Iron Rule 6 — a single adequate variant is decided, not asked about; the self-check in 2.b
  applies to it too.

## Two entry points, one protocol

- **The user invokes `/claude-mesh:auto-decide-disputed`** at any point of a review session.
- **The `autodecide` argument** was passed to `/claude-mesh:mesh-review` or
  `/claude-mesh:mesh-design-review`; the orchestrator then invokes this command itself, through the
  Skill tool, at the moment it enters the disputed phase. The argument has no behaviour of its own
  — it automates the invocation.

Both paths execute this file, and from the moment it is loaded it governs the disputed phase.

**Before anything else — whose invocation is this?** This file is reachable through the Skill tool,
so a model can invoke it as readily as a user can type it, and everything below then acts on the
repository without asking. Proceed only when the invocation traces to one of the two entry points
above: the user typed the command, or `AUTODECIDE` was bound `true` at `/claude-mesh:mesh-review`
Step 0 / `/claude-mesh:mesh-design-review` Step 5 and the running flow is handing over at the top of
its disputed phase. If neither holds — you reached for this command yourself, mid-review, because an
issue was hard — **that is not consent.** Say so in one line and go back to Iron Rules 7–8: write
the analysis and end the turn on it.

## Step 1: Identify your state

**If the running flow just handed over** — Step 6.4 / Step 12 invoked this command because
`autodecide` was passed — none of the rows below applies: the disputed phase has begun, nothing is
pending, and there is nothing to arm. Start at issue 1 of the queue and go to Step 2. The table is
for the other entry point, the user invoking the command somewhere in the middle of a session.

| State | Situation | What to do |
|---|---|---|
| **S1** | The disputed phase is running and this turn is waiting for the user's answer on the current issue | That issue is FIRST in the queue. Its analysis is already on screen — do **not** rewrite it: append the `Проверка решения` section, decide, apply, commit, then continue with the rest. If the user answered it before invoking this command, their answer stands — start with the next issue |
| **S2** | Issues are classified but the disputed phase has not started (auto-fixes being applied, or their commit still pending) | Finish the auto-fixes and make the intermediate commit first — Iron Rules 1–2 are not overridden — then start the run. **Invoking this command is not approval of the auto-fixes**: if the flow is waiting for that confirmation, still ask for it as usual — the consent this invocation carries is about deciding disputed issues, nothing else |
| **S3** | Anything else before the disputed phase begins — reviewers being selected or dispatched, the watch loop running, the delegation guard, dedupe, classification | Bind `AUTODECIDE = true` and echo it (see the paragraph below the table), then say in one line that the signal is armed and when it fires. Continue the normal flow completely unchanged, and start the run when the disputed phase begins |
| **S4** | The disputed phase is over, or there were no disputed issues | Issues deferred earlier in this session — by «стоп» or by `default` mode — **are** the queue: decide them now. Their analyses are usually already in this session — reuse them exactly as S1 does: do not rewrite an analysis that is on screen, append `Проверка решения` to it. If there are none, say there is nothing left to decide and stop. Do not invent issues. In `/claude-mesh:mesh-design-review` the run also has to close the iteration record — see the paragraph below the table |
| **S5** | There is no review cycle in this session at all | Say there is nothing to decide. **Do NOT start a review** — this command decides, it does not review. Point at `/claude-mesh:mesh-review autodecide` or `/claude-mesh:mesh-design-review autodecide` |

**More than one row can match — take the lowest-numbered one.** S3 is deliberately broad, so that
every moment before the disputed phase has a row; the specific states win over it by number. Two
cases where this decides something real: auto-fixes still in flight is S2, not S3, so they are
finished and committed first; and `D == 0` with auto-fixes still pending is S2, not S4 — commit
them, and only then say there is nothing left to decide.

**Bind `AUTODECIDE = true` and echo it before the first issue**, whichever state you came in
through — and in S3 already at the moment you arm the signal, since there the run itself starts
later. Both hosts gate the disputed phase on a disjunction (the flag, or this command having been
invoked), but every step after it tests the flag alone: Step 6.5's skip, Step 6.6's counters, Step
14's stage set and subject. On a user-invoked run Step 0 / Step 5 echoed `AUTODECIDE=false`, so
without this those steps read the mode as off and make exactly the sweep-up commit this mode exists
to replace.

**S4 — the record has to be closed by hand, in either host.** Step 6.6 and Steps 13–15 have already
run; they do not run again. In `/claude-mesh:mesh-review` that means printing a closing block
yourself when the S4 run ends — the `Решено автоматически` and `из них под вопросом` counts for what
you have just decided, one line per `под вопросом` decision, and the
`Все авто-решения: git log --grep=auto-decide-disputed --oneline` line. Skip it and the last summary
on screen still lists those issues as deferred, contradicting git, while the confidence flags — what
2.c makes the user re-check by — are recorded nowhere they will ever see. In
`/claude-mesh:mesh-design-review` those issues were already written into the current iteration file
as `Отложено (стоп)` and committed by Step 14 — a committed record that now contradicts the
decisions you have just made, and the one the next iteration reads as what was decided. So after the
run, append a `## Дополнение — autodecide (после «стоп»)` block to that same iteration file, with
one entry per decision in Step 13's per-issue format (`**Статус:** Решено автоматически
(autodecide)`, `**Ответ:**`, `**Уверенность:**`, `**Коммит:**`, `**Действие:**`); correct the
`Статистика` counts in place (`Отложено (стоп)` down, `Решено автоматически (autodecide)` and
`из них под вопросом` up); and commit that file alone with
`docs: review iter N — autodecide addendum (<TOPIC>)` — carrying the same trailing
`Решено автоматически: /claude-mesh:auto-decide-disputed` line as every decision commit, so the
addendum is not invisible to `git log --grep=auto-decide-disputed`.

**Appending is not enough — supersede the original record too.** The issue's existing
`### [TYPE-N]` section still says `Отложено (стоп)`, and `agents/review-discussion.md` builds the
next iteration's answer base out of *every* `### [TYPE-N]` section it finds, with no rule for
duplicates: left alone, the file states two contradictory answers for one issue and the next
iteration can quote the stale one. So, in the same edit and before the commit:

- in the ORIGINAL section, bring every field into the shape Step 13 gives an autodecided issue —
  `**Статус:** Решено автоматически (autodecide) — см. Дополнение`, `**Ответ:**` the variant you
  accepted, plus `**Уверенность:**`, `**Коммит:**` and `**Действие:**`. Not the status and answer
  alone: a deferred entry's `**Действие:** -` left in place reads to the next iteration as
  «answered, nothing was changed» while git holds a commit that changed the document, and the
  missing `**Коммит:**` makes the decision's SHA unrecoverable from the record. Editing a committed
  record in place is already what this paragraph does to `Статистика`; the «отложено → решено»
  history survives in git;
- in `answers`, **replace** that issue's `deferred` entry with its `new-autodecide` entry rather
  than adding a second one. Step 15 counts `deferred` and `autodecided` independently, so an issue
  left in both is counted twice.

Announce the queue before the first issue:

```
Спорных вопросов: D. Режим autodecide: каждый разберу подробно, проверю свою же рекомендацию и приму решение сам. Вмешаться можно в любой момент; «стоп» останавливает.
```

**Before the first issue — settle the tree.** Do this now, as part of the announcement, not later:
«стоп» is allowed during the very first analysis, and the sweep-up steps that used to catch these
edits (Step 6.5 / Step 14) stand down in this mode, so a rule that waits for the first decision can
be skipped entirely by an early exit. If it carries any uncommitted edits produced by the
disputed phase so far — issues the user answered and issues you auto-applied after analysis alike —
commit those first, on their own: in `/claude-mesh:mesh-review` with
the flow's existing message `review: apply decisions from external review discussion`; in design
review with `docs: review iter N — decisions (<TOPIC>)` — decisions only, because the iteration log
is not written yet and Step 14 commits it separately, under the `docs: review iter N — log
(<TOPIC>)` subject this mode gives it. Step 14 reuses the `decisions` subject above when a user's
mid-run choice leaves an edit behind, so human-decided edits have one shape here, not two. That
keeps the human/machine boundary visible in the history and guarantees a clean tree. If the tree is
dirty for unrelated reasons — or if the user has work sitting staged in the index — say so in one
line and continue: 2.d commits by pathspec, so neither can reach a decision's commit, and neither is
yours to clean up. The one thing that construction does **not** cover is an unrelated edit inside a
file a decision does touch; 2.d step 3 reads exactly that and stops rather than committing it.

## Step 2: For each issue — analysis, self-check, decision

Sequential, one issue at a time, each driven to its commit before the next one starts. Batching
analyses is forbidden here exactly as it is interactively.

**2.a — Write the analysis in the format the running flow already defines** — `Step 6.4.a` in
`commands/mesh-review.md`, `12.a` in `skills/mesh-design-review/SKILL.md`. Same sections, same
depth:

```
## [Спорное i/D] <Issue Title>
<header verbatim from the running flow — do NOT mix the two:
   /claude-mesh:mesh-review  → **Файл:** …  **Уровень:** …  **Нашли:** …
   design review            → title carries the [TYPE-N] id, and the only field is **Источник:** …>
### Суть замечания
### Анализ
### Варианты решения       (each with Что делаем / Плюсы / Минусы; the no-change variant where it
                           applies — «Не исправлять» in /claude-mesh:mesh-review, «Оставить как
                           есть» in design review)
### Рекомендация
```

**Nobody is waiting on this text, and that is exactly why it must not shrink.** It is the only
record of why the change was made: the user reads it after the fact, and in design review part of
it lands in the iteration file.

**2.b — Add the self-check.** Mandatory for every disputed issue — including one where you believe
only a single variant is adequate:

```markdown
### Проверка решения

**Сильнейшее возражение против Варианта X:** <against the CHOSEN variant — what someone who
prefers Y would say. Not a restatement of why the others lost>

**Ответ:** <why it does not outweigh — anchored in the code, a prior decision, or a project
invariant. Or, honestly: it does>

**Что заставило бы передумать:** <a concrete fact or condition>

→ Авто-решение: Вариант X. Уверенность: уверенно | под вопросом (<what was missing>)
```

**The check may reverse the decision.** If the objection outweighs, write
`Проверка развернула рекомендацию: принимаю Вариант Y` and apply Y. A check that can never change
the outcome is decoration.

**2.c — Set the confidence flag by test, not by feel.** `под вопросом` if ANY of these holds:

- (a) the objection got no substantive answer — «маловероятно», «на практике не встретится», with
  nothing in the code or a prior decision behind it. Unanswered is not the same as outweighing:
  an objection you cannot rebut but judge weaker leaves the decision standing and flags it here,
  while one that actually outweighs reverses the decision under 2.b instead of landing in (a);
- (b) the decision rests on a fact **outside this repository**: a product priority, a deadline,
  someone's intent, the behaviour of an external system you cannot read from here;
- (c) «что заставило бы передумать» names something knowable, but not from here («если X реально
  используется в проде»).

Otherwise `уверенно`. Never soften a `под вопросом` to keep the summary looking clean — that flag
is what the user re-checks by.

**2.d — Apply and commit. One commit per decision, order fixed:**

1. Apply the Edit(s).
2. Verify they landed.
3. Read what this decision's own files actually carry — content, not names, and **both sides**:
   ```bash
   git diff HEAD          -- <the files this decision touched>   # working tree vs HEAD
   git diff --cached HEAD -- <the files this decision touched>   # index vs HEAD
   ```
   The question is whether one of them holds a change this decision did not make, and it can hide
   on either side. The working-tree diff catches an edit that was already there, or one the user
   made while you worked. The index diff catches the worse case: a hunk the user staged inside a
   file you are about to commit. Step 4 records the working-tree content **and replaces that path's
   index entry**, so a staged-only hunk is at once invisible to the first diff and destroyed by the
   commit — index `USER_STAGED`, worktree `MY_EDIT`, `git diff HEAD` showing nothing but your own
   change, and the index holding `MY_EDIT` afterwards with the user's work gone. `git diff --cached
   --name-only` answers neither question: it prints paths and never content.

   **Stop the run** (the failure rule below) if either diff shows a hunk you did not write; say
   which file and which side it was on, and let the user sort it out. Everything OUTSIDE this
   decision's files — dirty, staged, or both — is not this case at all: step 4 excludes it by
   construction, and settle-the-tree has already had its one-line say about it.
4. Commit exactly those files, by pathspec, **message first**:
   ```bash
   git commit -F - -- <the files this decision touched> <<'EOF'
   <the message below>
   EOF
   ```
   Four things there are load-bearing, and most have already been got wrong once. **No flag may
   follow `--`**, because everything after it is a pathspec: `git commit -- <files> -m "…"` dies
   with `error: pathspec '-m' did not match any file(s)`. The `-F -` form above sidesteps the
   ordering by taking the message on stdin; `git commit -m "<subject>" -m "<body>" -- <files>`
   works too, flags first. **No `git add` for a file that already exists** — the pathspec form
   commits those files' working-tree content directly, which is also why step 3 reads the working
   tree and not the index, and `git add <existing file>` is exactly what would take a foreign hunk
   along with your edit. **A file this decision CREATED is the exception and must be staged**: a
   pathspec matches only paths git already knows, so `git commit -F - -- new-file` dies with
   `error: pathspec 'new-file' did not match any file(s) known to git` and stops the run over a
   decision that was perfectly fine. `git add` the new paths first — there is nothing foreign
   inside a file that did not exist a moment ago — then commit with the full pathspec. A deletion
   needs no staging: that path is already tracked. And **nothing else moves**: work the user had
   staged before the run stays staged and uncommitted, neither swept into this commit nor cleared
   out of their index, so it is not something to stop over. Blanket per-file staging never was the
   isolation here — `git add <file>` takes the whole file anyway; the pathspec is.

   In `/claude-mesh:mesh-review` the message is:
   ```
   review: auto-decide <short issue name> — вариант <X>

   <1–2 sentences: what changed and why this variant>
   Уверенность: уверенно | под вопросом (<what was missing>)
   Нашли: <reviewers that raised it>
   Решено автоматически: /claude-mesh:auto-decide-disputed
   ```
   In design review, the subject follows its neighbours instead, body unchanged:
   ```
   docs: review iter N — auto-decide [TYPE-K] <issue> (<TOPIC>)
   ```
5. Only then start the next issue. Do **not** push.

**If any of those four steps fails, the run stops there** — with the one exception below. Do not
record the decision, do not mark the issue decided, do not move to the next one. Say which step
failed and why, name the issue you were on and the ones still queued, and leave the edit where it
is for the user to look at. Never roll the edit back: an automatic `git checkout` over your own
edit can take work that is not yours with it. And do not retry — an unset `user.email`, a locked
index, no write permission, a hook that rejects the commit on policy all fail a second attempt
identically (the same reasoning `verify-delegation.sh` applies to `BROKEN` and `KILLED`).

**The exception: a hook that repaired the files and failed the commit once.** `black`, `prettier`
and the rest of that family rewrite what they are handed and exit non-zero the first time —
committing again over the repaired files is their documented workflow, not a gamble. Treated as
terminal, every repository with a formatting hook stops this run on its first decision, in the mode
meant
to need no supervision. So, when the commit failed **and** the hook left changes in this decision's
own files — it repaired them — run the same commit command once more. **Once.**

Check one thing before that second attempt, and only that one: that the hook changed nothing
outside this decision's files. That is a comparison of CONTENT, taken before the commit attempt and
again after it:

```bash
git status --porcelain                                         # did a path appear that was not there?
git diff HEAD -- . ':(exclude)<each of this decision's files>'  # did anything outside change?
```

Retry only when the first gained no path and the second is byte-identical between the two
snapshots, and treat neither half as optional. Reading the after-status raw would refuse the retry
in every tree that is not pristine: the user's own dirty or staged files are in it by design,
settle-the-tree having explicitly let them stay. And status cannot answer the second question at
all — a path already listed ` M` is still ` M` after a formatter rewrites it, so the two snapshots
match while the hook has in fact reached outside.

**Do not re-run step 3's content check.** A formatter rewriting a file wholesale produces exactly
the «changes this decision did not make» that step 3 stops on, so re-entering it would abort the
run this exception exists to save. The repaired content goes into the decision's commit, which is right: it is the
project's own formatting policy applied to your own edit. If the second commit fails too, or the
hook reached a file this decision did not touch, the paragraph above applies as written.

Continuing instead would leave an edit on disk that no commit covers while the tally counts the
issue as decided — the one divergence between history and summary that this mode cannot afford,
because `git log --grep=auto-decide-disputed` is the whole of its accountability.

**Hand the run back before you stop — but not the failed edit.** Stopping is not vanishing: the
decisions already committed still have to reach the record, exactly as «стоп» hands control back in
Step 3. The failing issue's files are the one thing that does NOT go with it: both hosts' sweep-up
guards (Step 6.5, Step 14) treat leftover disputed-phase edits as work to commit, so handing them
over unqualified files a failure as a decision, under a generic message, while the summary calls
that same issue deferred. Name those files to the host as out of scope, leave them where they are,
and say so. In
`/claude-mesh:mesh-review` go on to Step 6.6 and print its summary for what was decided, with the
failed issue and the rest of the queue listed as deferred. In `/claude-mesh:mesh-design-review` go
on to Steps 13–14: the iteration file and its commit are what the NEXT iteration reads, and
`agents/review-discussion.md` builds its answer base out of iteration files, not out of `git log` —
skip them and issues already committed into the design document come back as new, with nothing on
record saying they were ever decided.

The trailing `Решено автоматически:` line is what makes the whole run findable afterwards with
`git log --grep=auto-decide-disputed`. Keep it verbatim.

**2.e — «Не исправлять» / «Оставить как есть» is a full outcome.** No edit, no commit. Record it in
the summary like any other decision. Never invent an edit so that there is something to commit.

## Step 3: Interruptions

- Any user message during the run is handled normally.
- «стоп» / «stop» / «достаточно» stops the run: the current issue gets no decision, it and the
  remaining ones are recorded as deferred by the flow's existing rule, and you report what was
  done.
- A background event — a watcher tick, a task notification — is **not** an interruption and never
  an answer. Handle it and continue the run.
- Disagreement with a decision already made needs nothing special: it has its own commit, so
  `git revert <hash>` undoes exactly that one.

## Step 4: What reaches the summary

Feed the running flow's own summary — Step 6.6 in `/claude-mesh:mesh-review`, Steps 13/15/16 in
design review. In state S4 those steps have already run and do not run again; print the same facts
yourself instead, as §S4 says:

- how many issues were decided here (`Решено автоматически`), and how many of those are
  `под вопросом` — Step 6.6's counters, `Статистика` in Step 13 and the counts in Step 15;
- one line per `под вопросом` decision: issue, chosen variant, commit hash (`—` when the decision
  was the no-change variant), what was missing. In `/claude-mesh:mesh-review` that goes in Step
  6.6 — or, in state S4, in the closing block you print yourself; in design review, in Step 16's
  `Под вопросом — перепроверьте` section, with the same fact recorded per issue as
  `**Уверенность:**` by Step 13. Step 15 is a fixed question — do not put
  per-issue lines there;
- the line `Все авто-решения: git log --grep=auto-decide-disputed --oneline`.

<!-- SYNC: the `answers` shape below is ONE contract living in two places — this block and
     `skills/mesh-design-review/SKILL.md` Step 12.b. Change both or neither. -->
In design review, each decision also enters `answers` as
`{issue, status: "new-autodecide", answer: "Вариант X (autodecide)", action: "<what changed>",
confidence: "уверенно" | "под вопросом (<what was missing>)", commit: "<short SHA>" | "—"}` so that
Step 13 renders it in the iteration file and Step 15 counts it. `commit` is `«—»` exactly when the
decision was «не исправлять» — 2.e produces no edit and no commit.

## Red Flags — STOP if you catch yourself doing this

| Anti-pattern | What to do instead |
|---|---|
| «Никто это не читает — напишу покороче» | Stop. The analysis is the only record of the decision, and the user reads it after the fact. Full format, every issue. |
| Writing the objection against the variants you rejected | Stop. The check is against the CHOSEN variant. An objection to a discarded option proves nothing. |
| «Поставлю „уверенно“, чтобы итог выглядел лучше» | Stop. Apply tests (a)/(b)/(c) as written. The flag is how the user knows what to re-check. |
| Analysing three issues and then committing once | Stop. One decision, one commit, before the next issue begins. |
| «На всякий случай всё-таки спрошу пользователя» | Stop. The invocation was the consent — see Override Authority. |
| «Ревью в сессии нет — запущу его сам» | Stop. That is state S5: say there is nothing to decide. This command decides; it does not review. |
| Inventing an edit for an issue whose answer is «не исправлять», so there is something to commit | Stop. That is a full outcome: no edit, no commit, recorded in the summary. |
| `git add -A` because several files changed | Stop. The commit names its files as a pathspec and stages nothing except a path this decision created (2.d step 4) — other work is sitting in that tree and in that index. |
| A commit failed, so trying again — and again | Stop. Exactly one retry, and only for a hook that repaired this decision's own files (2.d). Every other failure is terminal on the first one. |
| Rewriting an analysis that is already on screen (state S1) | Stop. Append `Проверка решения` to it and decide. Rewriting burns context and changes nothing. |
| Invoking this command yourself because the issue in front of you is hard | Stop. The consent is the user's invocation or the `autodecide` argument — nothing else. Write the analysis and end the turn on it. |

## Bottom Line

When the run completes uninterrupted, every disputed issue has a full analysis, an explicit
counter-argument with an answer to it, a decision, a confidence flag, and — unless the decision was
«не исправлять» — its own commit. Nothing was deferred, nothing was batched, and no decision is
hidden: `git log --grep=auto-decide-disputed` lists every decision that produced a commit, and the
run's summary lists the «не исправлять» ones, which produce none.

If «стоп» ended the run early (Step 3), that postcondition does not hold: say plainly which issues
were decided and which are left deferred.
