# Autodecide for disputed review issues — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give both review flows a fourth exit for a disputed issue — the same full spoken-out analysis, an explicit self-rebuttal, and then the agent's own recommendation applied immediately, one commit per decision.

**Architecture:** A new command file, `commands/auto-decide-disputed.md`, holds the entire protocol and is the single source of truth. The user invokes it directly; the new `autodecide` argument makes the orchestrator invoke the very same command through the Skill tool when it enters the disputed phase. `commands/mesh-review.md` and `skills/mesh-design-review/SKILL.md` gain only pointers, carve-outs in their Iron Rules, and reporting fields — no copy of the protocol.

**Tech Stack:** Markdown prompt files in a Claude Code plugin. No shell, no config, no tests directory — verification is `grep` on structure plus a manual smoke run.

**Spec:** `docs/superpowers/specs/2026-08-23-autodecide-disputed-design.md`

## Global Constraints

- Prose in these files is **English**; user-facing output strings stay **Russian**, matching every existing string in both flows (`Спорных вопросов: D…`).
- Slash commands are always written namespaced: `/claude-mesh:<name>`. A bare `/mesh-review` does not resolve (CC 2.1.156).
- **Do not touch** any `.sh` file, `config.example.yaml`, `config-loader.sh`, `skills/shared/tests/`, or the two `*-fresh-session` generators. They are out of scope by design decision.
- Iron Rules 3–8 are mirrored between `commands/mesh-review.md` and `skills/mesh-design-review/SKILL.md` under an existing sync note. **Any edit to one copy must be made in the other in the same task**, worded to its own file (`/mesh-review` says `default`-mode clauses, the skill says it is always interactive).
- The protocol text lives in **one** place — `commands/auto-decide-disputed.md`. Never paste the analysis format, the self-check section or the confidence tests into the other two files; they point at the command instead.
- Never edit the user's `config.yaml`. Never `git push`. Every task ends with a commit on the current branch (`feat/autodecide-disputed`).
- No version bump: `.claude-plugin/plugin.json` is raised by a separate `chore(release)` commit, not by a feature.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `commands/auto-decide-disputed.md` | **create** | The whole autodecide protocol: consent, states, per-issue analysis + self-check, confidence test, commit rules, reporting, red flags |
| `commands/mesh-review.md` | modify | Argument docs, Iron-Rule carve-outs, the Step 6.4 hand-off to the command, Step 6.5 skip, Step 6.6 counters, one Red Flag row |
| `skills/mesh-design-review/SKILL.md` | modify | Same hand-off in its local form, plus `answers` bookkeeping, iteration-file fields, Step 14/15 |
| `README.md` | modify | Feature list mentions the mode and the new command |
| `CHANGELOG.md` | modify | `## [Unreleased]` → `### Added` entry |

---

### Task 1: The command file — single source of truth

**Files:**
- Create: `commands/auto-decide-disputed.md`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the command `/claude-mesh:auto-decide-disputed`, with section headings that Tasks 2 and 3 point at by name: `## Step 1: Identify your state` (states S1–S5), `## Step 2: For each issue — analysis, self-check, decision` (sub-steps 2.a–2.e), `## Step 4: What reaches the summary` (the `answers` status `new-autodecide`, the counters, the `под вопросом` list).

- [ ] **Step 1: Create `commands/auto-decide-disputed.md` with exactly this content**

````markdown
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
- Iron Rule 5 — every variant gets Плюсы/Минусы, and one is recommended with reasoning.

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
| **S4** | The disputed phase is over, or there were no disputed issues | Issues deferred earlier in this session — by «стоп» or by `default` mode — **are** the queue: decide them now. If there are none, say there is nothing left to decide and stop. Do not invent issues |
| **S5** | There is no review cycle in this session at all | Say there is nothing to decide. **Do NOT start a review** — this command decides, it does not review. Point at `/claude-mesh:mesh-review autodecide` or `/claude-mesh:mesh-design-review autodecide` |

Announce the queue before the first issue:

```
Режим autodecide: спорных к разбору — D. Каждый разберу подробно, проверю свою же рекомендацию
и приму решение сам. Вмешаться можно в любой момент; «стоп» останавливает.
```

## Step 2: For each issue — analysis, self-check, decision

Sequential, one issue at a time, each driven to its commit before the next one starts. Batching
analyses is forbidden here exactly as it is interactively.

**2.a — Write the analysis in the format the running flow already defines** — `Step 6.4.a` in
`commands/mesh-review.md`, `12.a` in `skills/mesh-design-review/SKILL.md`. Same sections, same
depth:

```
## [Спорное i/D] <Issue Title>        (design review also carries the [TYPE-N] id)
**Файл:** …  **Уровень:** …  **Нашли:** …
### Суть замечания
### Анализ
### Варианты решения       (each with Что делаем / Плюсы / Минусы; «Не исправлять» where it applies)
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
  nothing in the code or a prior decision behind it;
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
4. Commit. In `/mesh-review`:
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

**Before the first decision — settle the tree.** If it carries uncommitted edits from issues the
USER decided interactively, commit those first, on their own, with the flow's existing message
(`review: apply decisions from external review discussion`; in design review
`docs: review iter N — decisions (<TOPIC>)`). That keeps the human/machine boundary visible in the
history and guarantees a clean tree. If the tree is dirty for unrelated reasons, say so in one line
and continue — staging is per-file, so nothing foreign is swept in.

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

Feed the running flow's own summary — Step 6.6 in `/mesh-review`, Steps 13/15/16 in design review:

- how many issues were decided here (`Решено автоматически`), and how many of those are
  `под вопросом`;
- one line per `под вопросом` decision: issue, chosen variant, commit hash, what was missing;
- the line `Все авто-решения: git log --grep=auto-decide-disputed --oneline`.

In design review, each decision also enters `answers` as
`{issue, status: "new-autodecide", answer: "Вариант X (autodecide)", action: "<what changed>",
confidence: "уверенно" | "под вопросом (<what was missing>)"}` so that Step 13 renders it in the
iteration file and Step 15 counts it.

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

When the run ends, every disputed issue has a full analysis, an explicit counter-argument with an
answer to it, a decision, a confidence flag, and — unless the decision was «не исправлять» — its
own commit. Nothing was deferred, nothing was batched, and no decision is hidden:
`git log --grep=auto-decide-disputed` lists them all.
````

- [ ] **Step 2: Verify the structure**

```bash
grep -c '^## ' commands/auto-decide-disputed.md          # expect 9
grep -n 'Override Authority' commands/auto-decide-disputed.md
grep -n 'Проверка решения' commands/auto-decide-disputed.md
grep -n 'под вопросом' commands/auto-decide-disputed.md
grep -c '^| \*\*S[1-5]\*\*' commands/auto-decide-disputed.md   # expect 5
grep -n 'git log --grep=auto-decide-disputed' commands/auto-decide-disputed.md
head -4 commands/auto-decide-disputed.md | grep -q '^name: auto-decide-disputed' && echo "frontmatter ok"
```

Expected: 9 top-level sections, five state rows, frontmatter `name` matching the filename, and each of the named strings present.

- [ ] **Step 3: Commit**

```bash
git add commands/auto-decide-disputed.md
git commit -m "feat(commands): auto-decide-disputed — decide remaining disputed issues autonomously"
```

---

### Task 2: Wire `/mesh-review` to the command

**Files:**
- Modify: `commands/mesh-review.md` (Arguments §, Iron Rules 7–8, Step 6.4, Step 6.4.b, Step 6.5, Step 6.6, Red Flags table)

**Interfaces:**
- Consumes: `/claude-mesh:auto-decide-disputed` from Task 1 — invoked by name through the Skill tool; its `Step 4: What reaches the summary` defines the counters this task adds.
- Produces: the `autodecide` argument for `/claude-mesh:mesh-review`; the Iron-Rule wording that Task 3 mirrors into the skill.

- [ ] **Step 1: Document the argument.** In `## Arguments`, immediately after the `BASE_BRANCH=<branch>` bullet and before the paragraph starting `Without \`BASE_BRANCH\``, insert:

```markdown
- `autodecide` — decide every disputed issue automatically instead of waiting for an answer: the
  same full analysis, plus an explicit self-check, then your own recommendation applied. Optional,
  orthogonal to `default` and `BASE_BRANCH=`, order-independent — `/claude-mesh:mesh-review default
  autodecide` is a fully unattended run, `/claude-mesh:mesh-review autodecide` picks reviewers
  interactively and only the disputed phase runs unattended. The protocol lives in
  `/claude-mesh:auto-decide-disputed`; Step 6.4 hands over to it.
```

- [ ] **Step 2: Carve out Iron Rules 7 and 8.** In rule 7, replace the sentence

```
In `default` (non-interactive) mode never wait — record the issue as deferred per Step 6.4.b and continue.
```

with

```
In `default` (non-interactive) mode never wait — record the issue as deferred per Step 6.4.b and continue. In `autodecide` mode neither wait nor defer: follow `/claude-mesh:auto-decide-disputed`, which applies your own recommendation after an explicit self-check.
```

and in rule 8, replace

```
(in `default` mode nobody can answer — defer per Step 6.4.b)
```

with

```
(in `default` mode nobody can answer — defer per Step 6.4.b; in `autodecide` mode the analysis is not a question at all — see Step 6.4)
```

- [ ] **Step 3: Hand Step 6.4 over to the command.** In `### Step 6.4`, directly after the line `If \`D == 0\`, finish (jump to Step 6.5 with a brief summary).`, insert:

```markdown
**Autodecide mode.** If the `autodecide` argument was passed (see Arguments), do NOT run the
interactive loop below: invoke `/claude-mesh:auto-decide-disputed` through the Skill tool now and
follow it for the whole disputed queue. It replaces 6.4.b's waiting branch and the `default`-mode
deferral; 6.4.a's analysis format still applies unchanged, and the command points back to it. The
same command may also be invoked by the USER mid-discussion — from that point on the effect is
identical. Do not paste any part of its protocol here.
```

and add a third intro variant after the `default`-mode one:

````markdown
In `autodecide` mode display instead:
```
Спорных вопросов: D. Режим autodecide: каждый разберу подробно, проверю свою же рекомендацию и приму решение сам. Вмешаться можно в любой момент; «стоп» останавливает.
```
````

- [ ] **Step 4: Stop the deferral from firing in autodecide.** In `6.4.b`, in the bullet beginning `**In \`default\` (non-interactive) mode there is nobody to ask.**`, append at the end of the bullet:

```markdown
  **Unless `autodecide` is active** — then this bullet does not apply at all: decide the issue per
  `/claude-mesh:auto-decide-disputed` instead of deferring it. `default` and `autodecide` are
  orthogonal, and when both are set, autodecide wins here.
```

- [ ] **Step 5: Skip Step 6.5 in autodecide.** At the end of `### Step 6.5: Commit Decisions`, append:

```markdown
**In `autodecide` mode this step is skipped:** every decision was already committed on its own, one
commit per decision, so there is nothing left to stage. If some issues were decided interactively
before the mode was switched on, their edits were committed by the command's own "settle the tree"
rule before its first decision.
```

- [ ] **Step 6: Extend the Step 6.6 summary.** Replace the summary block with the version carrying the two new counters, and add the `под вопросом` section plus the grep line after the deferred-issue lines:

```markdown
Итог:
  Авто-исправлено:           A   (закоммичено: <hash if any>)
  Авто-применено по анализу: B1
  Обсуждено с пользователем: B2  (закоммичено: <hash if any>)
  Решено автоматически:      C   (autodecide, по коммиту на решение)
    из них под вопросом:     C?
  Отклонено как ложные:      X
  Отложено по «стоп»:        S1
  Отложено (default-режим):  S2
```

````markdown
For every `под вопросом` decision (C?) add one line, so the user knows exactly what to re-check:
```
  - <Issue title> (`file:line`) — Вариант X, <hash> — не хватило: <what was missing>
```

When C > 0, close the summary with:
```
Все авто-решения: git log --grep=auto-decide-disputed --oneline
```
````

- [ ] **Step 7: Add the Red Flag row.** In the `### Red Flags` table of Step 6, add:

```markdown
| In `autodecide` mode, ending the turn to wait for the user's answer | Stop. That mode exists precisely to not wait: write the analysis, add `Проверка решения`, decide, commit, continue. |
```

- [ ] **Step 8: Verify every edit landed**

```bash
grep -n 'autodecide' commands/mesh-review.md            # expect hits in Arguments, Iron Rules 7 and 8, Step 6.4 (x2), 6.4.b, 6.5, 6.6, Red Flags
grep -c 'auto-decide-disputed' commands/mesh-review.md  # expect >= 4
grep -n 'Режим autodecide' commands/mesh-review.md
grep -n 'Решено автоматически' commands/mesh-review.md
```

Expected: at least one hit per edited location; no protocol text copied — the analysis format, the confidence tests and the commit-message template must appear **only** in `commands/auto-decide-disputed.md`:

```bash
grep -c 'Сильнейшее возражение' commands/mesh-review.md   # expect 0
grep -c 'Уверенность: уверенно' commands/mesh-review.md   # expect 0 — the summary uses "из них под вопросом"
```

- [ ] **Step 9: Commit**

```bash
git add commands/mesh-review.md
git commit -m "feat(mesh-review): autodecide argument hands the disputed phase to auto-decide-disputed"
```

---

### Task 3: Wire `mesh-design-review` to the command

**Files:**
- Modify: `skills/mesh-design-review/SKILL.md` (Input Parameters, Iron Rules 7–8, Red Flags, Step 12, 12.b, Step 13, Step 14, Step 15)

**Interfaces:**
- Consumes: `/claude-mesh:auto-decide-disputed` (Task 1), including its `answers` contract — status `new-autodecide`, fields `answer`, `action`, `confidence`; the Iron-Rule wording from Task 2, mirrored here in this skill's own voice.
- Produces: the `AUTODECIDE` input parameter and the iteration-file fields consumed by nothing further in this plan.

- [ ] **Step 1: Document the parameter.** In `## Input Parameters`, after the `**DEFAULT**` bullet, add:

```markdown
- **AUTODECIDE** — if the `autodecide` argument is passed, the disputed phase (Step 12) does not
  wait for the user: it hands over to `/claude-mesh:auto-decide-disputed`, which writes the same
  analysis, adds an explicit self-check, and applies its own recommendation, one commit per
  decision. Orthogonal to `default` and combinable with it and with `DESIGN_PATH`/`PLAN_PATH`/
  `TOPIC`; order does not matter.
```

- [ ] **Step 2: Mirror the Iron-Rule carve-outs** (this is the same rule as Task 2 Step 2, in this file's voice — the sync note above rules 3–8 requires both). In rule 7, after `…then apply and start the next.` insert:

```
In `autodecide` mode neither wait nor defer: follow `/claude-mesh:auto-decide-disputed`, which applies your own recommendation after an explicit self-check.
```

and in rule 8, after `…the user answers in free text.` insert:

```
In `autodecide` mode the analysis is not a question at all — see Step 12.
```

- [ ] **Step 3: Hand Step 12 over to the command.** After the line `If \`disputed\` is empty, proceed to Step 13.`, insert:

```markdown
**Autodecide mode.** If `AUTODECIDE` was passed, do NOT run the interactive loop below: invoke
`/claude-mesh:auto-decide-disputed` through the Skill tool now and follow it for the whole disputed
queue. It replaces 12.b's waiting branch; 12.a's analysis format still applies unchanged, and the
command points back to it. The same command may also be invoked by the USER mid-discussion — from
that point on the effect is identical. Do not paste any part of its protocol here.
```

and add the intro variant after the existing one:

````markdown
In `autodecide` mode display instead:
```
Спорных вопросов: D. Режим autodecide: каждый разберу подробно, проверю свою же рекомендацию и приму решение сам. Вмешаться можно в любой момент; «стоп» останавливает.
```
````

- [ ] **Step 4: Record auto-decisions in `answers`.** At the end of `**12.b`**, after the `If the turn is resumed by a background event` bullet, add a third top-level bullet:

```markdown
- **In `autodecide` mode neither branch above applies to the waiting case.** The decision is made by
  `/claude-mesh:auto-decide-disputed` and recorded in `answers` as
  `{issue, status: "new-autodecide", answer: "Вариант X (autodecide)", action: "<what changed>",
  confidence: "уверенно" | "под вопросом (<what was missing>)"}` — Step 13 renders it and Step 15
  counts it. The stop check still applies: «стоп» during the run ends it, and the remainder is
  recorded `deferred` as usual.
```

- [ ] **Step 5: Extend the iteration file (Step 13).** In the `### [TYPE-N] Issue Title` block, extend the `**Статус:**` line and add a confidence line after `**Ответ:**`:

```markdown
**Статус:** Автоисправлено | Обсуждено с пользователем | Решено автоматически (autodecide) | Отклонено | Повтор (iter-M, TYPE-K) | Отложено (стоп)
**Уверенность:** уверенно | под вопросом (<чего не хватило>)   ← only for status "Решено автоматически (autodecide)"
```

and in `## Статистика`, after the `Обсуждено с пользователем: B2` line, add:

```markdown
- Решено автоматически (autodecide): C
- из них под вопросом: C?
```

- [ ] **Step 6: Narrow Step 14 in autodecide mode.** At the end of `### Step 14`, after the `**If nothing was produced at all**` paragraph, add:

```markdown
**In `autodecide` mode the document edits are already committed** — one commit per decision, made
by `/claude-mesh:auto-decide-disputed`. This step then stages only the iteration file and the
merged review file, and its message stays `docs: review iter N — decisions + log (<TOPIC>)`.
```

- [ ] **Step 7: Count auto-decisions in Step 15.** Add to the count list:

```markdown
- `autodecided` = count where status == "new-autodecide"
- `autodecided_unsure` = of those, count whose `confidence` starts with "под вопросом"
```

and extend the AskUserQuestion text to `"Итерация N завершена. Автоисправлено: {auto_fixed}, авто-после-анализа: {auto_after_analysis}, обсуждено: {discussed}, решено автоматически: {autodecided} (под вопросом: {autodecided_unsure}), отклонено: {dismissed}, повторов: {repeated}, отложено: {deferred}. Что дальше?"`

- [ ] **Step 8: Add the Red Flag row** to the skill's own `### Red Flags` table:

```markdown
| In `autodecide` mode, ending the turn to wait for the user's answer | Stop. That mode exists precisely to not wait: write the analysis, add `Проверка решения`, decide, commit, continue. |
```

- [ ] **Step 9: Verify, including the mirror**

```bash
grep -n 'autodecide\|AUTODECIDE' skills/mesh-design-review/SKILL.md   # Input Parameters, rules 7-8, Step 12 (x2), 12.b, 13, 14, 15, Red Flags
grep -c 'auto-decide-disputed' skills/mesh-design-review/SKILL.md     # expect >= 4
grep -n 'new-autodecide' skills/mesh-design-review/SKILL.md           # 12.b and Step 15
grep -c 'Сильнейшее возражение' skills/mesh-design-review/SKILL.md    # expect 0 — protocol stays in the command
```

Mirror check — the same carve-out sentence must exist in both Iron-Rule copies:

```bash
grep -c 'In `autodecide` mode neither wait nor defer' commands/mesh-review.md skills/mesh-design-review/SKILL.md
```

Expected: `1` for each file.

- [ ] **Step 10: Commit**

```bash
git add skills/mesh-design-review/SKILL.md
git commit -m "feat(design-review): autodecide argument hands the disputed phase to auto-decide-disputed"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` (Features list)
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section)

**Interfaces:**
- Consumes: the command name and argument from Tasks 1–3.
- Produces: nothing further in this plan.

- [ ] **Step 1: README — mention the mode and the command.** Replace the `/claude-mesh:mesh-review` bullet in `## Features` with:

```markdown
- **`/claude-mesh:mesh-review`** — orchestrate code review across multiple models in parallel; add
  `autodecide` to have the disputed issues decided for you — same full analysis, an explicit
  self-check, one commit per decision
```

and add `/claude-mesh:auto-decide-disputed` to the session-helpers bullet, with its own line
underneath the list:

```markdown
- **`/claude-mesh:auto-decide-disputed`** — invoke mid-review to hand the remaining disputed issues
  to the agent itself: it writes the same structured analysis, rebuts its own recommendation in a
  `Проверка решения` section, marks each decision `уверенно` / `под вопросом`, and commits them one
  by one — `git log --grep=auto-decide-disputed` lists the run, `git revert` undoes any single
  decision. Same protocol as the `autodecide` argument of both review commands
```

- [ ] **Step 2: CHANGELOG — add the `[Unreleased]` section.** Insert directly after the
`All notable changes…` line (the repo has no standing `[Unreleased]` section — the release commit
renames it, cf. `f660fb9`):

```markdown
## [Unreleased]

### Added
- `/claude-mesh:auto-decide-disputed` and the `autodecide` argument for `/claude-mesh:mesh-review`
  and `/claude-mesh:mesh-design-review` — a fourth exit for a disputed review issue. Until now an
  issue with several reasonable variants could only end the turn and wait for a free-text answer,
  or (in `default` mode) be deferred to a re-run. The new mode keeps the analysis exactly as it
  was — суть, анализ, варианты с плюсами и минусами, рекомендация — adds a mandatory
  `Проверка решения` section in which the agent argues against the variant it just chose and
  answers that objection, flags the decision `уверенно` or `под вопросом` by an explicit test
  (unanswered objection, or a deciding fact that is not in this repository), and then applies its
  own recommendation. Each decision is committed on its own, so `git revert <hash>` undoes exactly
  one; `git log --grep=auto-decide-disputed` lists the whole run, and the summary lists every
  `под вопросом` decision with what was missing. The protocol lives in one file — the command —
  and both review flows hand over to it rather than carrying a copy.
```

- [ ] **Step 3: Verify**

```bash
grep -n 'auto-decide-disputed' README.md CHANGELOG.md
head -8 CHANGELOG.md | grep -q '## \[Unreleased\]' && echo "unreleased ok"
```

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document auto-decide-disputed and the autodecide argument"
```

---

### Task 5: Manual smoke verification

**Files:** none modified — this task produces a report, and fixes anything it breaks in the files above.

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: a go/no-go verdict on the feature.

This task cannot be automated: it needs a live session with a real review cycle. Run each scenario,
record what happened, and fix any file from Tasks 1–3 that misbehaved (re-running the relevant
verification step from that task afterwards).

- [ ] **Step 1: S5 — the command outside a review.** In a fresh session with no review running,
invoke `/claude-mesh:auto-decide-disputed`.
Expected: it says there is nothing to decide and points at the `autodecide` argument. **It must not
start a review** and must not edit anything.

- [ ] **Step 2: Argument path, code flow.** On a branch with a diff that yields at least two
disputed issues, run `/claude-mesh:mesh-review autodecide` (interactive reviewer selection is fine).
Expected: after the auto-fix commit, the intro line names the mode; each issue gets the full
analysis plus a `Проверка решения` section with an objection **against the chosen variant**; each
decision is its own commit whose body carries `Уверенность:` and `Решено автоматически:`; the final
summary carries `Решено автоматически: C`, `из них под вопросом: C?`, a line per `под вопросом`
decision, and the `git log --grep` hint.

- [ ] **Step 3: Check the history**

```bash
git log --grep=auto-decide-disputed --oneline
git show <one of those hashes> --stat
```

Expected: one commit per decision; each touches only the files that decision changed.

- [ ] **Step 4: S1 — the command mid-discussion.** Start another `/claude-mesh:mesh-review` **without**
`autodecide`, let it stop on a disputed issue awaiting your answer, then invoke
`/claude-mesh:auto-decide-disputed`.
Expected: the pending issue is decided **without its analysis being rewritten** — only the
`Проверка решения` section is appended — and the remaining issues follow.

- [ ] **Step 5: S4 — nothing left.** Invoke `/claude-mesh:auto-decide-disputed` again once the run
has finished.
Expected: "nothing left to decide", no edits, no commits.

- [ ] **Step 6: Design-review flow.** Run `/claude-mesh:mesh-design-review autodecide` on a design +
plan pair with at least one disputed issue.
Expected: decisions are committed one by one with the `docs: review iter N — auto-decide …` subject;
the iteration file shows `**Статус:** Решено автоматически (autodecide)` and a `**Уверенность:**`
line for those entries, and the `Статистика` block carries the two new counters; Step 14's commit
contains only the iteration and merged files.

- [ ] **Step 7: Record the result.** Report which scenarios passed, what was fixed, and commit any
fixes:

```bash
git add <fixed files>
git commit -m "fix(autodecide): <what the smoke run exposed>"
```
