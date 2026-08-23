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
- Iron Rules 3–8 are mirrored between `commands/mesh-review.md` and `skills/mesh-design-review/SKILL.md` under an existing sync note. This plan splits that mirror on purpose — Task 2 owns one copy, Task 3 the other — so **the tree is knowingly out of mirror between those two tasks**; do not "fix" the other file from inside a task that does not own it. Task 3 Step 9 greps both copies and is the gate that closes the mirror. Each copy is worded to its own file (`/mesh-review` carries `default`-mode clauses, the skill is always interactive).
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
✅ Done — see commit(s): `5bc8727`, `bb9c02e`, `112b99a`

---

### Task 2: Wire `/mesh-review` to the command
✅ Done — see commit(s): `b6244f8`, `62a6505`

---

### Task 3: Wire `mesh-design-review` to the command
✅ Done — see commit(s): `48737bb`, `b97cdf3`, `158df92`, `112b99a`

---

### Task 4: Documentation
✅ Done — see commit(s): `934346f`, `f594883`, `112b99a`

---

> **The four completed tasks were edited further after they were written.** A code review of the
> whole branch (`/claude-mesh:mesh-review default`, eight reviewers) applied 18 auto-fixes and 9
> decisions on top of them — commits `b3609e0` through `1a8c6c0`. **The shipped files are ahead of
> every excerpt this plan quotes**; read the files, never this document, for current text.

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
