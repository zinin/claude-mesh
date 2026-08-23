# Autodecide for disputed review issues — design

**Date:** 2026-08-23
**Topic:** `autodecide-disputed`
**Status:** design approved in brainstorming; implementation plan pending

## Problem

Both review flows resolve a disputed issue the same way — `/claude-mesh:mesh-review` in Step 6.4
and the `mesh-design-review` skill in Step 12. Each writes a structured analysis
(Суть → Анализ → Варианты → Рекомендация) and then takes one of three exits:

- exactly one variant is adequate → the agent applies it and moves on (already autonomous);
- several variants are reasonable → the turn ends with no tool call and waits for a free-text
  answer (Iron Rules 7-8);
- `/mesh-review default` has nobody to ask → the issue is deferred and listed in the summary.

A fourth exit is missing: the same analysis, written out in full, decided immediately on the
agent's own recommendation. The point is not speed. It is that the agent argues the issue with
itself, checks the recommendation it just made, and then acts on it — and the user reads the
whole thing afterwards instead of answering it question by question.

## Decisions taken

| Question | Decision | Rationale |
|---|---|---|
| Entry points | Both a signal command and an argument | The command covers "you take it from here" mid-discussion; the argument covers an unattended run from the start |
| Autonomy | Decide everything; defer nothing; flag confidence instead | The request is explicitly "all remaining disputed". Deferring on "not enough data" gives the agent a legal excuse and leaves the queue unfinished |
| Quality mechanism | Mandatory `Проверка решения` section, written by the agent itself | In interactive mode the analysis is held up by a human reading it. With nobody reading, only an explicit self-rebuttal step keeps it from degenerating |
| Commits | One commit per decision | The user did not participate in these decisions, so point-in-time reversibility is the only real safety net |
| Where the rules live | Approach A: the command file is the single source of truth; the argument means "call that command yourself" | The repo already carries a "ONE rule living in four places" debt (`mesh-review.md:34`). A fourth copy of a ~100-line protocol would be worse than the indirection |
| Scope | The two entry points only | The fresh-session prompt generators and `config.yaml` stay untouched — `autodecide` is one word a user can type into a generated prompt by hand |

## Architecture: one text, three callers

`commands/auto-decide-disputed.md` holds the whole protocol. Both entry points execute that same
file:

- the user invokes `/claude-mesh:auto-decide-disputed` → the harness loads the text into context;
- the `autodecide` argument makes the orchestrator invoke the same command through the Skill tool
  at the moment it enters the disputed phase.

So the argument has no behaviour of its own; it automates the keystroke. `SKILL.md:796` already
invokes a `commands/` file this way (`/claude-mesh:design-review-fresh-session`), so the mechanism
is not new here.

The one thing the command does **not** restate is the analysis format itself. That format is
already written out in `Step 6.4.a` / `Step 12.a`, and whichever of the two is running is in
context when the command is loaded. The command carries the section skeleton plus a pointer; a
full copy would be the fourth one.

## Entry points

**Command:** `/claude-mesh:auto-decide-disputed` — valid at any point of a review session.

**Argument:** `autodecide`, orthogonal to `default` and to `BASE_BRANCH=`, order-independent:

```
/claude-mesh:mesh-review autodecide
/claude-mesh:mesh-review default autodecide
/claude-mesh:mesh-review BASE_BRANCH=main default autodecide
/claude-mesh:mesh-design-review autodecide
/claude-mesh:mesh-design-review DESIGN_PATH=... PLAN_PATH=... TOPIC=... autodecide
```

`/claude-mesh:mesh-review autodecide` without `default` is a deliberate combination: reviewers are
picked by hand, the disputed phase runs unattended.

## States when the command is invoked

Modelled on the `States` table of `pause-after-current-task`.

| State | Situation | Action |
|---|---|---|
| S1 | Disputed phase running, turn is waiting for the user's answer on the current issue | The current issue is first in the auto queue. Its analysis is already written — do not rewrite it; append `Проверка решения`, take the recommendation, apply, commit, continue. If the user already answered before invoking, that answer stands and the auto run starts with the next issue |
| S2 | Classification done, disputed phase not started (auto-fixes being applied or committed) | Iron Rules 1-2 hold: finish the auto-fixes, make the intermediate commit, then start the auto run |
| S3 | Reviewers still working (watch loop, executors) | Arm the signal and say so in one line. Watch loop, Step 6.0 and classification proceed unchanged; the mode engages when the disputed phase begins |
| S4 | Disputed phase finished, or there were no disputed issues | Issues deferred earlier in this session (by «стоп» or by `default` mode) **are** the queue — decide them. If there are none, say there is nothing to decide and do nothing |
| S5 | No review cycle in this session at all | Say there is nothing to decide. **Do not start a review.** Point at `/claude-mesh:mesh-review autodecide` |

Three standing rules:

- **The invocation is the consent.** Same posture as `Override Authority` in
  `pause-after-current-task`: never ask "are you sure", never offer to discuss it after all.
- **Still one at a time.** Iron Rule 3 survives in substance: one issue, one analysis block,
  driven to its commit, and only then the next. Batching analyses is as forbidden as it is
  interactively. The single difference is that the turn does not end on a wait.
- **The user can cut in at any point.** Their message is handled normally; «стоп» / «stop» /
  «достаточно» stops the run and the remainder is deferred under the existing rule.

## Per-issue protocol

The analysis format is unchanged — Суть → Анализ → Варианты (with Плюсы/Минусы) → Рекомендация.
Autodecide mode has no licence to shorten it: the analysis is the only record of why the decision
was made, which matters more here than interactively, not less.

One section is added, after Рекомендация and before any edit:

```markdown
### Проверка решения

**Сильнейшее возражение против Варианта X:** <the objection against the CHOSEN variant — what
someone who prefers variant Y would say — not a restatement of why the others were dropped>

**Ответ:** <why it does not outweigh — grounded in the code, a prior decision, or a project
invariant. Or, honestly: it does outweigh>

**Что заставило бы передумать:** <a concrete fact or condition>

→ Авто-решение: Вариант X. Уверенность: уверенно | под вопросом (<what was missing>)
```

**The check may reverse the decision.** If the answer to the objection is "it outweighs", write
`Проверка развернула рекомендацию: принимаю Вариант Y` and apply Y. Without that outcome the
section is decoration; with it, it does work.

**The check is mandatory for every disputed issue**, including the case where exactly one variant
is adequate (today's first branch of `6.4.b`, which already applies without asking). Uniformity is
worth more than the paragraph saved, and "it looked like there was only one option" is precisely
the error the check catches.

**«Не исправлять» / «Оставить как есть» is a full outcome.** No edit, no commit; the decision is
recorded in the summary (and, for design review, in the iteration file). The rule is stated
explicitly so that nothing gets invented merely to have something to commit.

### Confidence flag

Two values, decided by a mechanical test rather than by feel. `под вопросом` when any of:

- (a) the objection got no substantive answer — "unlikely" / "won't happen in practice" with no
  anchor in the code or in a prior decision;
- (b) the decision rests on a fact **outside the repository**: a product priority, a deadline,
  someone's intent, the behaviour of an external system that cannot be read from here;
- (c) "what would change my mind" is knowable, but not from this repository ("if X is actually
  used in production").

Otherwise `уверенно`. Tests (b) and (c) cover exactly the subclass that would otherwise be a
reason to defer; the decision here is to decide it anyway and mark it, so it surfaces in the
"перепроверьте" section of the summary.

## Commits

One commit per decision, immediately after its edit. Fixed order: edit → verify it applied →
`git add` **only** the files that decision touched → commit → next issue. Nothing accumulates; each
issue starts on a clean tree.

`/mesh-review` (code):

```
review: auto-decide <short issue name> — вариант <X>

<1-2 sentences: what was done and why this variant>
Уверенность: уверенно | под вопросом (<what was missing>)
Нашли: <reviewers that raised it>
Решено автоматически: /claude-mesh:auto-decide-disputed
```

`mesh-design-review` (documents), matching the neighbouring messages
(`docs: review iter N — auto-fixes (<TOPIC>)`):

```
docs: review iter N — auto-decide [TYPE-K] <issue> (<TOPIC>)
```

The trailing line is not decoration: it makes the whole run findable with
`git log --grep=auto-decide-disputed`. That is the reversibility this design promises.

**Human/machine boundary.** If uncommitted edits from interactively decided issues are in the tree
when the command is invoked, they are committed first, separately, under the existing message
`review: apply decisions from external review discussion`. That also guarantees a clean tree at the
start of the run. If the tree is dirty for unrelated reasons, warn in one line and continue —
staging is per-file, so nothing foreign is swept in.

**Existing commit steps.** Step 6.3 / Step 11 (auto-fixes) unchanged. Step 6.5 is skipped in
autodecide mode — there is nothing left to commit. Step 14 commits only the iteration file and the
merged review file.

## Reporting

Step 6.6 gains two counters and one section:

```
Итог:
  Авто-исправлено:            A   (закоммичено: <hash>)
  Авто-применено по анализу:  B1
  Обсуждено с пользователем:  B2  (закоммичено: <hash>)
  Решено автоматически:       C   (autodecide, по коммиту на решение)
    из них под вопросом:      C?
  Отклонено как ложные:       X
  Отложено по «стоп»:         S1
  Отложено (default-режим):   S2

Под вопросом — перепроверьте:
  - <Issue title> (`file:line`) — Вариант X, <hash> — не хватило: <what>

Все авто-решения: git log --grep=auto-decide-disputed --oneline
```

The design-review iteration file (Step 13) gains the status value
`Решено автоматически (autodecide)`, a `**Уверенность:**` field on those entries, and two lines in
`Статистика` (`Решено автоматически: C`, `из них под вопросом: C?`).

## File-by-file changes

**New — `commands/auto-decide-disputed.md`** (~180 lines), structured like
`pause-after-current-task`: Purpose → Override Authority → entry points → states S1-S5 → per-issue
protocol → `Проверка решения` and the confidence test → commit protocol → what reaches the summary
→ Red Flags → Bottom Line.

**`commands/mesh-review.md`** — six targeted edits:

1. `## Arguments` — `autodecide`: what it does, orthogonal to `default` and `BASE_BRANCH=`.
2. Iron Rules 7 and 8 — carve-out: in autodecide mode neither wait nor defer; follow the command's
   protocol. Mirrored in `SKILL.md` under the sync note that already covers rules 3-8.
3. Step 6.4 — a block before `6.4.a`: if `autodecide` is active, invoke
   `/claude-mesh:auto-decide-disputed` through the Skill tool and follow it; its own intro line
   replaces the two existing ones.
4. Step 6.4.b, last bullet — the `default`-mode deferral does not apply while autodecide is active,
   otherwise the two rules contradict each other.
5. Step 6.5 — skipped in autodecide mode: every decision is already committed on its own.
6. Step 6.6 and the Red Flags table — counters, the "под вопросом" section, and a row for
   "waiting for the user's answer while in autodecide mode".

**`skills/mesh-design-review/SKILL.md`** — five of those six in their local form (edit 4 has no
counterpart: this skill has no non-interactive disputed phase, so there is no `default`-mode
deferral bullet to carve out), plus the `answers` bookkeeping and the iteration-file format:
`Input Parameters` (`AUTODECIDE`), Iron Rules 7-8, the block in Step 12 and the edit to 12.b —
which also records each auto-decision in `answers` with status `new-autodecide` and its confidence,
since that is what Steps 13 and 15 count — Step 13 (status value, `**Уверенность:**`, two
statistics lines), Step 14 (commits only iter+merged in this mode), Step 15 (counters in the
"what next" question).

**`README.md`** — the Features entry for `/claude-mesh:mesh-review` mentions the mode; the new
command joins the session-helpers list. **`CHANGELOG.md`** — a feature entry.

## Out of scope

The fresh-session prompt generators (`code-review-fresh-session`, `design-review-fresh-session`),
`config.yaml` and `config-loader.sh`. No shell script changes, hence no additions to
`skills/shared/tests/`. Both can be added later as their own iteration once the mode has been
exercised.

## Verification (manual)

1. **S1** — invoke the command mid-discussion, with an analysis already on screen awaiting an
   answer: the current issue is decided without its analysis being rewritten, then the rest follow.
2. **Argument** — `/claude-mesh:mesh-review autodecide` on a diff with at least two disputed
   issues: one commit per decision, each carrying the `Проверка решения` output in the session, and
   a summary with the counters and the "под вопросом" section.
3. **S4** — invoke with no disputed issues left: says there is nothing to decide, changes nothing.
4. **S5** — invoke outside a review cycle: says there is nothing to decide and does **not** start a
   review.
5. **Design review** — `/claude-mesh:mesh-design-review autodecide`: the iteration file carries the
   new status and the confidence field; Step 14 commits only iter+merged.

## Risks

| Risk | Mitigation |
|---|---|
| With the argument, the orchestrator never invokes the command and silently falls back to waiting | The instruction sits at the one place the phase starts, in both files; and a miss is visible — no `Проверка решения` in the output, and `Решено автоматически: 0` in a run started with `autodecide` |
| The analysis degenerates because nobody is reading it | Red Flags row aimed at exactly that thought, plus the mandatory self-rebuttal section, which cannot be written without engaging the alternatives |
| Confidence is always reported as `уверенно` | The flag is set by mechanical tests (a)/(b)/(c), not by feel; (b) in particular is objective — either the deciding fact is in the repo or it is not |
| Unrelated working-tree edits swept into a decision commit | Per-file staging (as in Step 6.3), human decisions committed first, and a one-line warning on a dirty tree |
| Commit noise in the user's repository | Accepted deliberately: reversibility is the safety net that replaces the user's approval, and `git log --grep` collapses the run back into one view |
