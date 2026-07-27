# Changelog

All notable changes to claude-mesh will be documented here.

## [Unreleased]

### Fixed
- The `/mesh-review` and `/mesh-design-review` watch loops could not tell a slow
  executor from a dead one — both leave the same disk, and every finalization predicate
  was about a result *appearing*. The only backstop was `runtime.timeouts.global_sec`,
  an hour of blindness by default, and when it fired it reported `WATCH_TIMEOUT` rather
  than naming the death. A new `skills/shared/watch-runs.sh` classifies each dispatched
  executor as `DONE` / `FAILED` / `RUN` / `SILENT` / `MISSING` and returns as soon as any
  of them stops running, naming the executor and the transition. It holds a roster of
  `engine[/provider/model]` rather than run directories, so an executor that dies and
  self-retries into a new directory is followed instead of being reported dead. Freshness
  is the newest mtime across `raw.jsonl`, `log.jsonl`, `watchdog.log` and
  `attempt-*/raw.jsonl`, so a supervised run between watchdog retries reads as `RUN` on
  its heartbeat. Recovery is deliberately not signalled: the baseline is virtual — every
  roster entry is assumed `RUN`, so an already-dead run is caught on the first tick after
  every restart, and an executor that recovers on its own produces no event. Both prompts
  now call the script instead of describing a poll loop in prose; the improvised
  implementation exited only when the finished count grew, which death never does. An
  executor's unprompted message is now spent on a `--once` liveness check rather than on
  an acknowledgement.
- `/mesh-design-review` never passed `SUPERVISED_MODE`, so its executors ran unsupervised
  by default: no `shared/watchdog.sh`, no stall detection, no restart on a torn provider
  stream, and no `watchdog.log`. Whether a run got a watchdog was luck — 42 of 223 archived
  runs did, against 242 of 255 on the `/mesh-review` path. Step 6 now dispatches every
  executor with `SUPERVISED_MODE: shell`, and `codex-executor` / `gemini-executor` /
  `ext-claude-executor` document the parameter so it is forwarded to the skill instead of
  leaking into the prompt.
- `/mesh-design-review` accepted an executor's report without checking that the run had
  produced one. A run that stops and leaves a non-empty `output.txt` looks finished even
  when the file holds only the model's narration. It now runs `verify-delegation.sh` — the
  guard `/mesh-review` has used since Step 6.0 existed — before asking an executor to
  extract findings.

### Configuration
- No new keys. `runtime.timeouts.stall_sec` gains a second consumer: the orchestrator's
  watcher reports a run `SILENT` past that threshold. The watcher floors it at 600, because
  `codex-exec` and `gemini-exec` hardcode `HARD_ZERO_TIMEOUT=600` and ignore the key — a
  lower value would let the watcher call a live run dead before its own watchdog acts.

## [0.5.0] - 2026-07-27

### Added
- Multi-model built-in Claude reviewers. A new optional `claude:` section holds a
  catalog of Claude model aliases (`claude.models: [opus, sonnet, fable]`), and a new
  per-preset key `defaults.<preset>.claude_models` picks the default subset. Both
  `/mesh-review` and `/mesh-design-review` now run **one independent reviewer per
  selected Claude model** — same input, same prompt, different model — so a session on
  `opus` can be cross-checked by `opus` and `fable` at once, with your session
  aggregating both. The interactive UI gains a Claude-model page (★ marks the preset's
  picks); `default` mode reads the preset. Reviewers are attributed as `claude:<model>`
  in the dedup table, the delegation roster (as `INLINE`, never passed to
  `verify-delegation.sh`) and the merged design-review file. Loader support:
  `get-flag has_claude_models`, `list-claude-models`, and a `claude_models` field in
  `get-defaults`.
  `runtime.dispatch_model` is unchanged and still governs the codex / gemini / ext-claude
  wrappers, `review-discussion` and `/do-plan`; claude reviewers with an explicit model
  ignore it. Configs without a `claude:` section — or with a catalog but no models
  selected — keep the old `/mesh-review` behaviour exactly: one claude reviewer on
  `dispatch_model`, or on the session model when that is unset.

### Fixed
- `claude` in `defaults.design_review.builtin` was silently dropped. The loader accepted
  the value, but `/mesh-design-review` expanded only `codex` and `gemini` in `default`
  mode and offered no `claude` option in its interactive reviewer-type question —
  so design review had never once run a built-in Claude reviewer. Both paths now expand
  it — so a `design_review` preset that already lists `claude` gains one reviewer, and
  its cost, on upgrade with no config change. The related fail-closed guard is new too:
  `claude_models` set without `claude` in the same preset's `builtin` is now a validation
  error rather than another silently ignored list.
- `/mesh-design-review` swallowed the validator's exit code when reading its preset. Its
  Step 5.0 fence ran `DEFAULTS_JSON=$("$LOADER" get-defaults design_review)` bare, so a
  config.yaml that failed validation left `DEFAULTS_JSON` empty and Step 5.1 then STOPped
  with the misleading "defaults.design_review not configured" instead of the real error.
  The read is now rc-aware and surfaces the validator's stderr verbatim, matching the
  `dispatch_model` read directly below it and `/mesh-review` Step 1.

## [0.4.3] - 2026-07-22

### Fixed
- Delegation guard no longer discards genuine external reviews whose stream
  carries more than one `type:result` event. `verify-delegation.sh` read
  `num_turns` from the LAST event (`tail -1`); when an external model
  dispatches a background subagent it answers "work started", the session
  resumes, and the final event describes only the short closing segment
  (`num_turns:1`) — so a full agentic review (44 assistant events, 19
  `tool_use`, 8933 bytes of findings whose cited line numbers checked out) was
  stamped `BROKEN`, the one verdict `/mesh-review` never retries: findings
  dropped, user told to swap the model in `config.yaml`. Classification now
  takes the MAXIMUM `num_turns` over result events — max and not sum, since
  summing two non-agentic segments (1+1) would fabricate a `REAL` out of a run
  that read no code. `ext-claude-exec/generate-md.sh` keeps its `tail -1`:
  there the last result legitimately carries the answer.
- Hardening of that guard after a 7-reviewer `/mesh-review` (codex, zai/glm,
  alibaba/qwen, deepseek/v4-pro, ollama/kimi, ollama/minimax, builtin claude —
  all seven verified `REAL` by the guard under test): errored result events no
  longer feed the maximum, because five historical runs carry
  `{"subtype":"success","is_error":true,"num_turns":95,"result":"Prompt is too
  long"}` — `subtype` lies, `is_error` is the signal — and both the old and the
  new selection had been admitting that 18-character failure string as a real
  cross-validation; a stream whose FINAL result event errored is `STALLED`,
  since `progress-monitor.sh` REWRITES `output.txt` per result event, so the
  delivered text is the last segment's and the lone `"\n"` it leaves sailed
  through `[ -s ]`; `num_turns` must be a non-negative integer to reach
  `[ "$NT" -le 1 ]` (`[` errors on anything else, the error was swallowed, the
  `if` read false and the run fell through to `REAL`); `REAL` now requires
  `output.txt` to hold non-whitespace, not merely bytes. Replaying the old and
  the new logic over 228 historical run dirs gives 12 verdict changes, all
  accounted for.
- Slash commands no longer run a stale copy of the shared loader. All four
  sites located `config-loader.sh` with `find … | head -1` — directory order,
  not version order — which returned 0.4.0 while 0.4.2 was installed, and was
  blind to `--plugin-dir` (command TEXT came from the working tree but SCRIPTS
  from the installed cache, so a dogfood run never exercised the copy under
  test). `CLAUDE_PLUGIN_ROOT` is empty as a shell variable in slash-command
  Bash calls, but the harness substitutes the placeholder into command and
  skill TEXT before the call, inside bash fences too (measured on CC 2.1.217);
  it names the active copy, so it is tried first and the glob stays a fallback,
  now `sort -V | tail -1`. The same substitution made the "config.yaml ещё не
  создан" hint print the wrong data dir under a `--plugin-dir` load; both twins
  now print `$("$LOADER" data-dir)`. New `shared/tests/test-loader-resolution.sh`
  extracts the live snippet out of the markdown and executes it, so the four
  duplicated copies cannot drift from the assertions.
- `/do-plan` Step 2 no longer claims that the command and the `PostToolUse`
  hook "converge on one absolute path". The hook takes the data dir from
  `$CLAUDE_PLUGIN_DATA` while the command asks the loader; on a marketplace
  install both land on `claude-mesh-zinin`, but under a `--plugin-dir` dev load
  they diverge, the per-session config is written where the hook never looks,
  and the STOP threshold silently never fires. Documented here; the hook itself
  is a separate task.

## [0.4.2] - 2026-07-17

### Fixed
- Disputed-issue discussion no longer loses the structured analysis behind an
  `AskUserQuestion` modal (`/mesh-review` Step 6.4, `mesh-design-review`
  Step 12). The model withholds prose emitted before a self-presenting tool
  call, so users saw a bare modal without the Суть → Анализ → Варианты →
  Рекомендация write-up. The analysis is now the turn-final message (no
  trailing tool call) and the user answers in free text; `AskUserQuestion`
  remains only at self-contained sites (reviewer/model selection,
  design-review "what next"). `/mesh-review default` defers multi-variant
  disputed issues instead of waiting for an absent user.
- Hardening from the pre-merge max-effort review of that fix (12 findings,
  5 confirmed): stop-token sets synced between the twin flows (`stop` is now
  recognized by `/mesh-review` too) and the stop check runs BEFORE
  apply/record, so a «стоп» reply can no longer produce a phantom answers
  entry or an unintended edit; the turn-final closing prompt is Russian like
  every other user-facing template; `default`-mode carve-outs added to Iron
  Rules 7–8 and 6.4.c (the unconditional "wait" wording could hang an
  unattended run); the Step 6.6 summary separates «стоп» deferrals from
  `default`-mode ones and lists every deferred issue with its recommended
  variant; `mesh-design-review` deferred issues now reach `answers`, the
  iteration log and Step 15 counts (previously they silently vanished from
  the committed iter file); a background watcher/task event resuming the
  turn-final wait is never treated as the user's answer; `review-discussion`
  agent description matched to reality (parses and returns results — never
  talks to the user or edits documents).

## [0.4.1] - 2026-07-16

### Fixed
- Review-prompt templating no longer corrupts CONTEXT on bash >= 5.2: the
  `${PROMPT//\{DESCRIPTION\}/$DESC}` snippet in `ext-claude-code-review` relied
  on a literal-replacement guarantee that bash 5.2 revoked — the
  `patsub_replacement` shopt (on by default) expands an unquoted `&` in the
  replacement to the matched pattern, so a CONTEXT carrying shell commands
  (`cd test-server && python3 -m unittest ...`) rendered as `cd test-server
  {DESCRIPTION}{DESCRIPTION} python3 ...` (2026-07-16 mesh-review incident;
  wrappers recovered only when the reviewer model noticed the corruption
  itself). All three review skills (`ext-claude-code-review`,
  `codex-code-review`, `gemini-code-review`) now render
  `shared/code-review-prompt.md` via the new `shared/render-template.py`:
  argv values are substituted str-literally on any bash version, in a single
  pass (placeholder-looking text inside a value is never re-substituted).
  Covered by `shared/tests/test-render-template.sh`, including a dry run of
  the real template with a hostile `&& & \&` CONTEXT.
- Hardening pass on the templating fix after a 7-reviewer `/mesh-review`
  (codex gpt-5.5, 5 ext-claude models, builtin claude): `codex-` /
  `gemini-code-review` Step 3 now passes DESCRIPTION / PLAN_REFERENCE through
  quoted heredocs into `"$VAR"` expansions instead of instructing the agent to
  inline prose into single quotes — an apostrophe in commit-derived text broke
  the command, and a crafted `x'; cmd; : '` value would have executed
  (found by 6 of 7 reviewers, escalated to Critical by codex); `python3` is
  now pre-flighted in all three review skills and its README Dependencies row
  covers the shared renderer; `ext-claude-code-review` Step 1 fails loudly
  when rendering fails or yields an empty prompt (previously an empty
  `$PROMPT_FILE` would silently produce an empty review); the renderer
  documents last-wins duplicate pairs and its byte-preserving surrogateescape
  I/O contract, derives both name regexes from one charset and truncates bad
  NAME=VALUE diagnostics to 64 chars; tests grew a metacharacter-zoo calling
  convention case, an `LC_ALL=C` round-trip, a byte-exact `cmp` check and a
  duplicate-pair contract case.

## [0.4.0] - 2026-07-10

### Fixed
- `config-loader.sh` no longer aborts on an unknown `codex.reasoning_level`
  (e.g. the new gpt-5.6 `ultra`): unknown levels WARN and pass through — the
  codex CLI/API is the final validator. Previously a single unknown level in
  the `codex:` section killed `export` for **every** ext-claude executor
  mid-review and pushed blocked review subagents into "fixing" the user's
  config (`ultra` → `xhigh` flips).
- codex agent definitions (`codex-executor`, `codex-code-reviewer`,
  `codex-native-reviewer`) no longer hardcode `gpt-5.5`/`xhigh` mandates that
  bypassed config-driven resolution on the `/mesh-review` and
  `/mesh-design-review` dispatch paths (final-review finding).
- `validate_codex` now type- and charset-checks `codex.model` /
  `codex.reasoning_level` (same forward-compatible charset as
  `runtime.dispatch_model`): a non-string value (e.g. an unquoted
  `reasoning_level: 3`) used to pass validation and then crash `get-codex`
  with a raw jq type error, and a `|` in a value silently corrupted the
  `model|level` protocol. Unknown-but-safe string levels still WARN and pass
  through; the known-levels contract is now locked by tests (0.4.0 pre-merge
  external review, fix wave 3).
- `/mesh-review` and `/mesh-design-review` orchestrators now disk-watch
  external runs and ping idle wrapper reviewers: a wrapper launches its engine
  as a background task and never wakes on its completion (the harness delivers
  no task-notification to idle subagents), so finished reviews sat unreported
  until a manual ping (0.4.0 pre-merge external review, fix wave 4).
- Wave-5 fixes from the 0.4.0 pre-merge `/mesh-review` smoke (7 reviewers):
  `codex.model` charset now allows provider-qualified ids
  (`openai/gpt-oss-20b`); `get-runtime` exposes the `timeouts` block the
  orchestrator disk-watch is told to read; a scalar `codex:`/`gemini:` section
  (`codex: false`) dies cleanly instead of crashing typed getters with a raw
  jq error; an empty config.yaml dies without bash arithmetic noise; watch
  loops run as a background Bash task, count only a non-empty root
  `output.txt` as finalization (gemini-exec pre-creates a zero-byte one) and
  ping each finished-but-silent wrapper once per poll cycle; loader test
  suite grown to 171 assertions (export-own-sections and known-level
  round-trip regression guards; duplicate test numbering fixed).
- `validate_runtime` type-gates `runtime:` and `runtime.timeouts` like the
  wave-5 `codex:`/`gemini:` gates: `runtime: false` used to pass validation
  silently, and a non-mapping `timeouts` passed it with raw jq noise — both
  then crashed `get-runtime` (raw jq rc=5), which the `/mesh-review` /
  `/mesh-design-review` watch loops call for `timeouts.global_sec` (Codex
  PR-review P2, fix wave 6; loader suite 171 → 180 assertions).

### Changed
- `cmd_export` validates only the sections it reads (providers/models/runtime).
  Errors in `codex:` / `gemini:` / `defaults:` can no longer block ext-claude
  runs. `validate` remains the full-config lint.
- `get-codex` / `get-gemini` likewise validate only their own section — a
  malformed `gemini:` section no longer blocks config-driven codex resolution
  (and vice versa); Codex PR-review finding.
- Known reasoning levels extended to `none|minimal|low|medium|high|xhigh|ultra`.
- Loader test suite: the unknown-level test asserts the new warn-and-pass
  contract; new scoped-export assertion (codex-section errors don't block
  `export`).

### Added
- codex executors (`codex-exec`, `codex-code-review`, `codex-review-native`)
  resolve MODEL / REASONING_LEVEL from `config.yaml` (`codex.model` /
  `codex.reasoning_level`) when the caller passes none — mirroring the existing
  gemini-exec idiom. `/mesh-review` and `/mesh-design-review` become
  config-driven for codex transitively. Precedence: explicit caller parameter >
  config.yaml > `gpt-5.5`/`xhigh` fallbacks.
- Guardrail wording in every pre-flight: on config failures agents STOP and
  report verbatim; `config.yaml` is user-owned and never edited by agents.

## [0.3.0] - 2026-06-15

### Changed
- Subagent dispatch model is no longer hardcoded. The static `model: fable` pin
  was removed from all mesh agents; by default subagents now **inherit your
  current session model** (your `/model`), so a model alias opening or closing no
  longer requires editing the plugin. The "never delegate to a cheaper model"
  policy is preserved relative to the resolved/session model rather than a literal.
- README/Dependencies: dropped the hard requirement for a Claude Code build whose
  Agent model enum includes the `fable` alias.

### Added
- Optional `runtime.dispatch_model` config knob: set it to **force** a specific
  tier on every `/do-plan`, `/mesh-review`, and `/mesh-design-review` dispatch;
  leave it unset (or omit `config.yaml`) to inherit the session model. Accepts any
  model alias or full id, including cloud-provider ids (Bedrock `…-v2:0`, Vertex
  `…@date`). Exposed via `config-loader.sh` (`get-flag` / `get-runtime`).

## [0.2.0] - 2026-06-10

### Changed
- Model policy switched from `opus` to `fable` (`claude-fable-5`): `/do-plan`
  now treats Opus as a forbidden "cheaper" model for subagent dispatch, and all
  mesh agents are pinned to `model: fable` via frontmatter.
- verify-delegation FLIP diagnostics reworded to be model-neutral.
- README: Dependencies now require a Claude Code build whose Agent tool model
  enum includes the `fable` alias.

## [0.1.0] - 2026-06-07

### Added
- Initial release: ext-claude-* family, codex/gemini wrappers, mesh-review,
  mesh-design-review, session/plan helpers, check-context-size hook.

### Fixed
- check-context-size hook is now scoped to the `/do-plan` session: it no longer
  injects `ctx:` milestone reminders into ordinary sessions (which made the agent
  economize context prematurely). `/do-plan` writes a per-session config file
  `do-plan-config-<cwd>-<session>.json`; the hook emits milestone/STOP only in the
  session that owns a file. Two concurrent `/do-plan` runs in one cwd no longer
  clobber each other. Old per-cwd `do-plan-config-<cwd>.json` files (pre-change)
  have a different name and are ignored — re-run `/claude-mesh:do-plan` to re-bind.
