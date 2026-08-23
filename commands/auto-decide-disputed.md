---
name: auto-decide-disputed
description: Decide every remaining disputed review issue autonomously — the same structured analysis and recommendation as the interactive discussion, plus an explicit self-check, applied without waiting for an answer. Use inside /claude-mesh:mesh-review or /claude-mesh:mesh-design-review.
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

## Step 1: Identify your state

| State | Situation | What to do |
|---|---|---|
| **S1** | The disputed phase is running and this turn is waiting for the user's answer on the current issue | That issue is FIRST in the queue. Its analysis is already on screen — do **not** rewrite it: append the `Проверка решения` section, decide, apply, commit, then continue with the rest. If the user answered it before invoking this command, their answer stands — start with the next issue |
| **S2** | Issues are classified but the disputed phase has not started (auto-fixes being applied, or their commit still pending) | Finish the auto-fixes and make the intermediate commit first — Iron Rules 1–2 are not overridden — then start the run |
| **S3** | Reviewers are still working (watch loop / executors running) | Say in one line that the signal is armed and when it fires. Continue the normal flow unchanged — watch loop, delegation guard, dedupe, classification — and start the run when the disputed phase begins |
| **S4** | The disputed phase is over, or there were no disputed issues | Issues deferred earlier in this session — by «стоп» or by `default` mode — **are** the queue: decide them now. Their analyses are usually already in this session — reuse them exactly as S1 does: do not rewrite an analysis that is on screen, append `Проверка решения` to it. If there are none, say there is nothing left to decide and stop. Do not invent issues. In `/claude-mesh:mesh-design-review` the run also has to close the iteration record — see the paragraph below the table |
| **S5** | There is no review cycle in this session at all | Say there is nothing to decide. **Do NOT start a review** — this command decides, it does not review. Point at `/claude-mesh:mesh-review autodecide` or `/claude-mesh:mesh-design-review autodecide` |

**S4 in design review — close the iteration record too.** In `/claude-mesh:mesh-review` the Step 6.6
summary is screen output, so deciding deferred issues needs nothing beyond the run itself. In
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

- in the ORIGINAL section, set `**Статус:** Решено автоматически (autodecide) — см. Дополнение` and
  `**Ответ:**` to the variant you accepted. Editing a committed record in place is already what
  this paragraph does to `Статистика`; the «отложено → решено» history survives in git;
- in `answers`, **replace** that issue's `deferred` entry with its `new-autodecide` entry rather
  than adding a second one. Step 15 counts `deferred` and `autodecided` independently, so an issue
  left in both is counted twice.

Announce the queue before the first issue:

```
Спорных вопросов: D. Режим autodecide: каждый разберу подробно, проверю свою же рекомендацию и приму решение сам. Вмешаться можно в любой момент; «стоп» останавливает.
```

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
3. `git add` **only** the files this decision touched — never `git add -A`, never a directory.
4. Commit. In `/claude-mesh:mesh-review`:
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

The trailing `Решено автоматически:` line is what makes the whole run findable afterwards with
`git log --grep=auto-decide-disputed`. Keep it verbatim.

**Before the first decision — settle the tree.** If it carries any uncommitted edits produced by the
disputed phase so far — issues the user answered and issues you auto-applied after analysis alike —
commit those first, on their own: in `/claude-mesh:mesh-review` with
the flow's existing message `review: apply decisions from external review discussion`; in design
review with `docs: review iter N — decisions (<TOPIC>)` — decisions only, because the iteration log
is not written yet and Step 14 commits it separately under its own `decisions + log` message. That
keeps the human/machine boundary visible in the history and guarantees a clean tree. If the tree is
dirty for unrelated reasons, say so in one line and continue — staging is per-file, so nothing
foreign is swept in.

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
design review:

- how many issues were decided here (`Решено автоматически`), and how many of those are
  `под вопросом`;
- one line per `под вопросом` decision: issue, chosen variant, commit hash, what was missing;
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
| `git add -A` because several files changed | Stop. Per-file staging only — other work may be sitting in the tree. |
| Rewriting an analysis that is already on screen (state S1) | Stop. Append `Проверка решения` to it and decide. Rewriting burns context and changes nothing. |

## Bottom Line

When the run completes uninterrupted, every disputed issue has a full analysis, an explicit
counter-argument with an answer to it, a decision, a confidence flag, and — unless the decision was
«не исправлять» — its own commit. Nothing was deferred, nothing was batched, and no decision is
hidden: `git log --grep=auto-decide-disputed` lists every decision that produced a commit, and the
run's summary lists the «не исправлять» ones, which produce none.

If «стоп» ended the run early (Step 3), that postcondition does not hold: say plainly which issues
were decided and which are left deferred.
