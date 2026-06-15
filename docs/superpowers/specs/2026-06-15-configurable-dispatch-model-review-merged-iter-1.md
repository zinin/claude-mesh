# Merged Design Review — Iteration 1

**Date:** 2026-06-15
**Design:** `docs/superpowers/specs/2026-06-15-configurable-dispatch-model-design.md`
**Plan:** `docs/superpowers/plans/2026-06-15-configurable-dispatch-model.md`
**Reviewer preset (`default`):** builtin `codex` + ext-claude × {`zai/glm`, `alibaba/qwen`, `deepseek/v4-pro`, `ollama/kimi`, `ollama/minimax`}. (Preset also lists builtin `claude`, which mesh-design-review does not implement as a reviewer type — skipped.)
**Completed:** 5 / 6. `zai/glm` stalled (runaway extended-thinking loop, two attempts, no `type=result` — deterministic model-side failure, not a config/prompt defect).

---

## codex-executor (gpt-5.5, reasoning xhigh) — OK

### Critical
1. **`/mesh-review default` never sees `DISPATCH_MODEL`.** Step 0 (`mesh-review.md:12,22`) skips Steps 1–3 and goes straight to the Step 5a/5b dispatch; the plan reads `dispatch_model` only in Step 1 (`plan:312,317`). The new Step 5a rule would reference an unset variable on the `default` path. Fix: resolve `dispatch_model` in Step 0 too (ideally from the `get-runtime` it already reads).
2. **Bare `$()` breaks fail-fast in mesh-review / mesh-design-review.** `DISPATCH_MODEL=$("$LOADER" get-flag dispatch_model)` (`plan:317,375`) with no `set -e` won't stop on non-zero. The plan's claim "rc handled by the `has_codex` probe" is wrong: `has_codex` does not call `validate_runtime` (`config-loader.sh:535`). A charset-invalid value prints to stderr but the block continues with empty → silent inherit instead of hard fail. Use the rc-aware idiom the plan already uses for do-plan (`plan:235`).
3. **do-plan self-contradiction leaves a literal `opus`.** Task 4 sets the status example to `Dispatch model = opus` (`plan:255`), but Task 4 Step 4 greps `\b(fable|opus|sonnet|haiku)\b` expecting nothing (`plan:290`); also violates the "no model literal" goal. Use `Dispatch model = <resolved-model>` / `session-inherited`.
4. **Validation vs. stated schema contract.** `jq -r '.runtime.dispatch_model // ""'` + `[ -n ]` skips empty/null; `dispatch_model: 123`/`true` stringify to `123`/`true` and pass the charset. Design §80 says "non-empty string" — pick one rule and sync design/tests/code.

### Concerns
- No test that `get-flag dispatch_model` itself runs `validate_runtime` on a bad value (the `do_plan_default_stop_tokens` analog exists at `test-config-loader.sh:142`).
- Plan says "Step 5.1 bash" but the `DEFAULTS_JSON` block is **Step 5.0** (`SKILL.md:202,229`). Behaviorally better (covers default + interactive), but rename.
- Design sweep vs. plan sweep disagree on expected README matches (`design:153` vs `plan:478,516`).

### Suggestions
- Architecture is sound; no better alternative beyond the rejected ones.
- For mesh-review, read the runtime JSON once (`get-runtime`) and take `default_run_mode` / `max_redispatch` / `dispatch_model` from it.
- **Verified:** `model: fable` appears exactly once per agent file; the `sed` delete is safe.

### Questions
- Is `dispatch_model: ""` a valid inherit-signal or a schema error? (Design says both in different places.)
- Should `dispatch_model: true` / `123` be a type error even if the stringified value passes the charset?

---

## ext-claude-executor (zai/glm → glm-5.2) — FAILED (model stall)

Did not produce a review on two consecutive attempts. The model read/verified the files, then entered a runaway extended-thinking loop (~8.3K / ~8.8K thinking-token events) and hit the 1800s timeout with no `type=result`. Skill executed correctly end-to-end (pre-flight, env, prompt save, file reads all OK); this is a deterministic model-side stall, exit 4. Only intermediate narration captured. Its one partial (unverified) lead matched codex Critical #1: `/mesh-review default` (Step 0) appears to skip the `dispatch_model` read. Recommend not retrying glm-5.2 for long read-heavy synthesis.

---

## ext-claude-executor (alibaba/qwen → qwen3.7-plus) — OK

No implementation-blocking defects; architecture sound, fallback complete, line refs spot-checked accurate (`config-loader.sh:368-373,547-564,625`; `agents/*.md:6/7`; `do-plan.md:29-34/119/132-134`; `mesh-review.md:46/136/163/224`; `SKILL.md:229/306/370`; one `model: fable` per agent confirmed).

### Critical (wording/consistency, not hard blockers)
- **C1:** `get-flag dispatch_model` in mesh-review/mesh-design-review has no stderr capture / rc handling; `cmd_get_flag` re-invokes `load_or_die` each call (`config-loader.sh:533`). Fold into the same `case` as `has_codex`, or document why rc is unhandled.
- **C2:** do-plan `line 135` ("Same for external reviewers…") was a continuation of old bullet 134 ("must set `model: "fable"`"). After replacing 134 with the new rule, "Same for" dangles — reword 135 as an explicit part of the new two-branch rule.

### Concerns
W1 charset allows leading dash / empty segments (`-opus`, `foo..bar`) → suggest `^[A-Za-z][A-Za-z0-9._-]*$`; W2 Test 39 bundles two scenarios (split per 33/34 style); W3 `// empty` vs `// ""` inconsistency; W4 add "exactly one line, grep-verified" comment to the sed; W5 Task 4 reuses `LOADER_ERR` without clearing; W6 document "empty value vs absent key both inherit".

### Suggestions
S1 loader test that `get-flag dispatch_model` doesn't trip on a partial `runtime:`; S2 config.example alias list still names `fable`; S3 README should say the failure surfaces at the Agent tool, not config validation; S4 final sweep should also cover `AGENTS.md`/`CLAUDE.md`.

### Questions
Q1 why Test 36 uses `validate` not `get-flag`; Q2 add a "config known-good past this line" invariant comment; Q3 "cheaper" is subjective — define explicit tier ordering; Q4 confirm no missed dispatch path (flags `/continue-plan-fresh-session`, `/exec-plan-fresh-session` for grep coverage).

---

## ext-claude-executor (deepseek/v4-pro) — OK (supervised retry)

### Critical
1. **`SKILL.md` Task 6 mislabels Step 5.0 as "Step 5.1"** and the insert point is ambiguous vs `echo "$DEFAULTS_JSON"` (`SKILL.md:229-230`). Specify "after line 230, before the closing fence on 231".
2. **Task 9 Step 3 grep misses `sonnet`/`haiku`.** `do-plan.md:134` forbids `opus / sonnet / haiku`; the bullet is replaced (so they vanish) but the final sweep only greps `fable|opus`. Extend to `\b(fable|opus|sonnet|haiku)\b`.
3. **`LOADER_ERR` already removed before the mesh-review `DISPATCH_MODEL` read** (`mesh-review.md:43`); bare read without capture — inconsistent with do-plan's `case`.

### Concerns
4 charset admits leading dash/dot/all-dots; 5 `get-flag dispatch_model` validates the whole `runtime` (note it); 6 Task 3 de-pins before Tasks 4–6 update consumers (safe fallback, but `/do-plan` in that window inherits); 7 Step 8 "same rule as Step 6" is confusing (Step 6 dispatches executors, Step 8 review-discussion); 8 do-plan status example hardcodes `opus`; 9 `review-discussion` isn't a CLI wrapper — losing its pin matters more (covered only when configured); 10 check no double blank line remains after deleting the frontmatter line.

### Suggestions
11 add a one-line rc comment in code; 12 charset `^[A-Za-z0-9][A-Za-z0-9._-]*$`; 13 grep `sonnet`/`haiku`; 14 (optional) combine do-plan's two `case` blocks; 15 `# dispatch_model: opus` example (claims `opus` legacy — **note: opus is current**); 16 confirm `mesh-review.md:224` insertion point.

### Questions
Q1 behavior of `dispatch_model: ""` (passes `[ -n ]` guard → inherit; intended?); Q2 should `/mesh-review default` (Step 0) resolve `DISPATCH_MODEL`? (plan adds it only to Step 1); Q3 confirm Step 5.1 `default` path actually flows through the Step 6 dispatch-model rule.

### Bottom line
Design sound; plan accurate; line numbers verified; sed safe; rc logic consistent. Main fixes: extend the grep (#2), unify rc comments (#3), resolve the `default`-mode question (Q2).

---

## ext-claude-executor (ollama/kimi → kimi-k2.6) — OK (supervised retry)

### Critical
None. All 8 dispatch sites (agents + dispatch-policy prose in do-plan / mesh-review / mesh-design-review) are covered.

### Concerns
1 line drift: plan says `*)` at 562 — reviewer claims 563 (**note: verified `*)` is at 562, plan is right**); 2 rc-asymmetry: bare `$()` in mesh-review/mesh-design-review vs do-plan's `case` (safe because `get-flag dispatch_model` itself `die`s rc=1, but inconsistent); 3 pre-existing duplicate Test numbers (14/15) — separate cleanup; 4 charset admits `.`, `1.2.3.4`, `---`, `____` (accepted forward-compat tradeoff); 5 `sed -i` is GNU-only (`require_gnu_coreutils` doesn't check `sed`); 6 builtin `claude`/`general-purpose` reviewer + `model:` override — couldn't verify the override is honored.

### Suggestions
1 add a positive validation test (`dispatch_model: "claude-fable-5"` → exit 0); 2 unify on one `get-runtime` + `jq` read; 3 note in config.example that `""` == absent; 4 use a portable deletion instead of GNU `sed -i`.

### Questions
1 confirm the `echo "DISPATCH_MODEL=…"` stdout→prose pattern is reliable (notes `$DEFAULT_STOP` uses it, so likely yes); 2 is the bare `$()` deliberate or should it get rc-handling; 3 do `/exec-plan-fresh-session` / `subagent-driven-development` form a separate dispatch path needing `dispatch_model`; 4 confirm sed safe on ext-claude frontmatter.

### Bottom line
Design sound, plan detailed, no missed dispatch site. Main concerns: rc-handling consistency + regex edge cases. No critical blockers.

---

## ext-claude-executor (ollama/minimax → minimax-m2.7) — OK (supervised retry)

### Critical
1. **`mesh-review.md` Step 0 (`default` mode) does not read `DISPATCH_MODEL`** (Step 0 lines 10–22 read `get-runtime | jq .default_run_mode` but not `dispatch_model`). `/mesh-review default` always inherits the session model. Not in the plan (Tasks 5/6 touch lines 46/136/163/224, not Step 0).
2. **Inconsistent dispatch-model behavior** between `default` (ignores it) and interactive (honors it) — not noted in design or plan.
3. **do-plan status example still says `Fable everywhere`** (`do-plan.md:119`); Task 4 Step 2 replaces it, but the verification grep runs only after the change — no "before" guard for that line.
4. **Line-number fragility:** Task 4 inserts into the Step 1 block → shifts later lines; Tasks 5/6 reference fixed line numbers. (Note: Tasks 5/6 are in *different files*, so do-plan edits don't shift them — but within a task, earlier inserts shift later refs.) Prefer grep-anchored insertion.

### Concerns
5 empty `dispatch_model: ""` passes `[ -n ]` → inherit, not covered by the sweep; 6 empty semantics (`get-flag` empty stdout vs `get-runtime` `""`); 7 `verify-delegation.sh` is orthogonal (accepted).

### Suggestions
8 add the Step 0 `DISPATCH_MODEL` read; 9 add a `grep -n 'Fable everywhere'` check (must be 0 after Task 4); 10 document the Step 0 / hybrid-model deviation.

### Questions
Q1 should `/mesh-review default` honor `runtime.dispatch_model`, or is it an accepted limitation? Q2 fixed line numbers vs grep anchors for Tasks 5/6? Q3 what does design §5 "mesh-design-review.md if it spawns agents" mean — grep shows 0 existing `dispatch_model` (all inserts new, not replacements); correct?

### Bottom line
Plan correct and complete overall. Main issues: (1) Critical — Step 0 `default` misses `DISPATCH_MODEL`; (2) Medium — line-number fragility Task 4 vs 5/6; (3) Low — status line (119) skipped by the verification grep. Architecture justified; charset safe; 8 agents verified; TDD correct.

---

## Cross-reviewer convergence (orchestrator note)

- **`/mesh-review default` Step 0 misses `dispatch_model`** — codex C1, deepseek Q2, ollama/minimax C1–C2, zai partial. **Verified real** against `mesh-review.md:10-22`.
- **rc-handling for `get-flag dispatch_model`** (mesh-review/mesh-design-review) — codex C2, alibaba C1, deepseek #3, ollama/kimi #2. **Verified:** `has_codex`/`list-models` don't call `validate_runtime` (`config-loader.sh`); `get-runtime` and the typed getter do.
- **do-plan status-line literal `opus`/`Fable` vs the verification grep** — codex C3, deepseek #8, ollama/minimax C3. **Verified** at `do-plan.md:119` + plan Task 4 Step 2/Step 4.
- **Task 9 grep misses `sonnet`/`haiku`** — deepseek #2/#13.
- **Plan mislabels SKILL Step 5.0 as "5.1"** — codex, deepseek #1. **Verified:** the `DEFAULTS_JSON` block is Step 5.0 and runs for both paths (so mesh-design-review has NO default-path gap).
- **charset / empty-string semantics** — codex C4, alibaba W1/W6, deepseek #4, ollama/kimi #4, ollama/minimax #5.
