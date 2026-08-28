# Grok as a third CLI engine

Date: 2026-08-28
Branch: `feat/grok-engine`
Status: approved design, ready for an implementation plan

## Goal

Make `grok` a first-class reviewer engine in claude-mesh, equal to `codex` and `gemini`:
its own exec skill, its own code-review skill, two wrapper agents, a gated config section,
a row in the environment probe, a verdict in the delegation guard, an entry in the run
watcher, and a place in the selection UI of `/mesh-review` and `/mesh-design-review`.

The user holds a grok.com subscription; the CLI authenticates itself, exactly as codex and
gemini do. claude-mesh never handles a grok token.

## Verified facts about the grok CLI

Measured on 2026-08-28 with `grok 1.0.5 (5115b46bc9) [stable]`, logged in via grok.com.
Every claim below was produced by running the command, not read from documentation.

**Read the first three rows as a snapshot of ONE machine, not as properties of grok.** The
catalog and both defaults live in the user's own `~/.grok/config.toml`, which they edit; the
same command run on 2026-08-28 returned a 2-model catalog in one session and a 20-model one
in another, hours apart. Nothing in this plugin may hardcode either. The rows are here to say
what the CLI's interface looks like, not to pin its contents.

| Fact | Evidence |
|---|---|
| The catalog is user-defined and can be large | `grok models` on this machine listed 20 entries — `grok-4.6`, `grok-4.5` and 18 models the user proxied in (`deepseek-*`, `glm-5-3*`, `minimax-m3`, `kimi-k3`, `codex-*`, …), the starred default being `codex-sol` |
| Reasoning effort accepts `low`, `medium`, `high`, `xhigh`, `max` — five values | `grok -p x --reasoning-effort=__bogus__` answers `use one of: low, medium, high, xhigh, max`. The same error names BOTH spellings (`--effort/--reasoning-effort`), so `--effort` is a real alias, not a guess |
| The CLI carries its own defaults, whatever they happen to be | `~/.grok/config.toml` on this machine: `[models] default = "codex-sol"`, `default_reasoning_effort = "low"`. Both are the user's settings — which is exactly why this plugin substitutes neither |
| Headless runs are agentic | `grok -p "list the files …" --output-format streaming-json --always-approve` called `list_dir` and answered from its output |
| `--prompt-file` feeds a prompt from disk | run with `--prompt-file`, no stdin |
| `--output-format streaming-messages-json` emits the Claude Code wire format | `system`/`init` (keys `apiKeySource, cwd, mcp_servers, model, permissionMode, session_id, skills, slash_commands, tools, uuid`), `assistant` with `text`/`thinking`/`tool_use` blocks, `user` with `tool_result`, terminal `result` with `subtype`, `is_error`, `num_turns`, `stop_reason`, `duration_ms`, `total_cost_usd`, `usage` |
| The stream is not buffered when redirected to a file | file grew 5 098 → 49 999 bytes over 30 s |
| `--permission-mode bypassPermissions` reaches outside the working directory | a run in `inner/` read `../outside.txt` and returned its contents; `result` carried no `permission_denials` field |
| An invalid model fails loudly | stdout `{"type":"error","message":"Couldn't set model …"}`, same text on stderr, rc=1 |
| Grok loads the Claude Code world | `grok inspect` lists `~/.claude/CLAUDE.md` and every installed claude-* plugin with its skills; the `system`/`init` event repeats them in `skills` and `slash_commands` |
| An empty prompt already costs ~19 k input tokens | `usage.input_tokens` on a one-word prompt — the skills inventory, cached across calls |

## Approach

Grok is built the way codex and gemini are built, with one exception: the model-catalog
validator is extracted into a shared helper that `claude:` and `grok:` both call.

**Rejected alternatives, and why.** `grok.models` as a list of `{id, label}` objects was
rejected because the value becomes a path component (`runs/grok/<model>/`) and a
`watch-runs.sh` roster entry — a bare string is the only shape all four consumers already
agree on. Routing grok through `claude:` as another provider kind was rejected because grok
authenticates itself and carries its own `~/.grok/config.toml`; folding it into the
Anthropic-API provider table would mean inventing a token path the CLI does not want. Copying
those sixty lines a third time would fork three subtle guards — the span attack on a missing
comma, the element type gate, the empty-value check against an absent catalog — and they
would drift on the first edit. Nothing else in the working codex/gemini path changes.

## 1. Configuration schema

```yaml
grok:                                  # GATE: no section => grok is never offered,
  models: [grok-4.6, grok-4.5]         #   and builtin: [grok] is a hard error
  reasoning_effort: xhigh              # [optional] known: low | medium | high | xhigh

defaults:
  code_review:
    builtin: [claude, codex, gemini, grok]
    grok_models: [grok-4.6]            # required whenever "grok" is in builtin
```

**`grok:` is a gate, `grok.models` is required inside it.** The reviewer agent demands a
model (§3), so an empty catalog is not a runnable state. `grok.models` is required and
non-empty when the section exists, mirroring `codex.model`. Message:
`grok.models: required when grok: section present`.

**`defaults.<preset>.grok_models` is required when `grok` appears in that preset's
`builtin`**, because `default` mode would otherwise have nothing to dispatch. This mirrors
the existing fail-closed rule that rejects `claude_models` without `claude` in `builtin`.

**Every entry of `grok_models` must be a member of the `grok.models` catalog**, must be
unique, and must be a string — the same three checks `claude_models` gets.

**The grok charset is narrower than the claude one:** `[A-Za-z0-9._-]`, not
`[A-Za-z0-9._:@-]`. A grok model name becomes a path component (`runs/grok/<model>/`) and a
roster entry for `watch-runs.sh`, whose validation is
`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$` and rejects `:` and `@`. Claude model names never
enter a path, so that catalog keeps its wider charset unchanged.

**The key is `reasoning_effort`, not `reasoning_level`** — the name the CLI flag
(`--reasoning-effort`) and the CLI's own config (`default_reasoning_effort`) use. One value
per section, not per model. The five known values (`low`, `medium`, `high`, `xhigh`, `max`)
pass silently; anything else passes with a WARN, exactly as `codex.reasoning_level` does, so a
new xAI level never needs a plugin release.

**The enumeration is a hint, not a contract, and it WILL go stale.** `codex.reasoning_level`
already proves it: its known set (`config-loader.sh:384`) still lacks `max`, the user's own
`config.yaml` sets exactly that, and every loader invocation on this machine therefore prints
`WARN: codex.reasoning_level: unknown value "max"`. WARN-and-pass is what keeps that from being
an outage. So: re-read the list from `grok --help` whenever this section is edited, and never
write a test asserting that an unknown value is REJECTED — only that it warns and passes.

**claude-mesh never substitutes a grok model of its own.** When no caller and no catalog
names one, `-m` is omitted and `~/.grok/config.toml` decides. A hardcoded fallback would
silently override the user's own setting. This applies to a direct `/claude-mesh:grok-exec`
call; review dispatch always carries a model.

**A broken `grok:` section fails its own row, never the environment.** The catalog check that
runs on the `validate_defaults` path — the one `cmd_get_defaults` triggers, and through it
`preflight-env.sh`'s `CONFIG_STATUS` and the first read of both orchestrators — is LAZY: an
unconditional type gate (so `jq` never meets `grok: false`), and the full catalog check only
when the preset actually references grok. Otherwise the likeliest user error of all, given the
catalog is mandatory — writing `grok:` and forgetting `models:` — would print `CONFIG INVALID`
and SKIP every codex and gemini row, which is exactly what `preflight-env.sh` forbids in its
own words and what the `ultra` incident of 2026-07-10 cost once already. Nothing is weakened:
`validate_all` still checks the catalog for `config-loader.sh validate`, and `list-grok-models`
/ `get-grok` are typed getters that fail loudly for anyone asking about the catalog itself. The
orchestrators degrade the same way — a section that will not validate switches `has_grok` off
for that run and reports it, instead of stopping a codex-only review.

**Shared validator.** `validate_model_catalog <jq-path> <label> <charset-re>` replaces the
body of `validate_claude` and serves `validate_grok`. Claude's error messages must survive
character for character — the test suite asserts their text.

**New loader commands:** `get-flag has_grok`, `list-grok-models`, and `get-grok`, which
prints `reasoning_effort` — or an empty line, with rc=0, when the key is unset. No
`has_grok_models` flag exists: the catalog cannot be empty while the section exists, so
`has_grok` answers both questions.

**That sentence is only true because `has_grok` VALIDATES before reading**, the way
`has_claude_models` does and the bare probes `has_codex` / `has_gemini` deliberately do not.
Written as a bare `jq -e '.grok'`, the flag would report `1` for a section whose catalog is
malformed or missing, and the invariant would rest on every caller separately remembering to
read `list-grok-models` too, in the right order — the class of implicit obligation this design
otherwise avoids. The distinction is about what each flag promises: `has_codex` answers "is
there a codex section", while `has_grok` is consumed as "can a grok reviewer be dispatched".

## 2. Execution layer — `skills/grok-exec`

### Stream format

`--output-format streaming-messages-json`, not the native ACP stream. The format is the one
`claude -p --output-format stream-json` produces, which this plugin already parses, and that
buys three things:

- `shared/extract-result.py` consumes it after ONE additive fix — no third extractor. The fix is
  required, not optional: grok emits a TOP-LEVEL `{"type":"error","message":"…"}`, while the
  extractor's error fallback reads the NESTED `.error.message`, so today an error-only stream
  yields the literal `API Error: {}` and the message is lost. Reproduced:
  `printf '{"type":"error","message":"…"}' > D/raw.jsonl && python3 extract-result.py D`.
  Adding a top-level `.message` fallback beside the existing nested one keeps all three current
  engines byte-identical and makes the "no third extractor" claim true;
- the `ext-claude` branch of `verify-delegation.sh` classifies it unchanged — grok becomes
  ELIGIBLE for the `DEGRADED` verdict, which codex and gemini cannot reach. Eligible, not
  demonstrated: no run has yet been observed emitting `permission_denials`, because every
  measured invocation passed `--permission-mode bypassPermissions` and that field was absent
  from the result event. The branch is engine-agnostic and its test drives a synthetic event,
  so what is verified is the classifier, not the CLI's willingness to populate the field;
- the stream reaches disk unbuffered, so the watchdog's stall detection works as designed.

The risk is that xAI maintains this as a compatibility layer and could change it. `raw.jsonl`
is kept whole, and the post-run check requires at least one `"type":"result"` event and says
so plainly when it finds none, instead of leaving an empty `output.txt` behind.

### Invocation

```bash
timeout 1800 grok \
  --prompt-file "$PROMPT_FILE" \
  --output-format streaming-messages-json \
  --permission-mode bypassPermissions \
  --no-plan \
  [-m "$MODEL"] [--effort "$EFFORT"]
```

- **No `stdbuf`**, unlike the three sibling skills. The grok binary is statically linked, and
  `stdbuf` works by preloading `libstdbuf` through a dynamic loader that is not there — it
  would be a silent no-op. Nor is it needed: the stream was measured reaching a redirected
  file unbuffered. Stated here so the omission reads as a decision, not an oversight.
- `--prompt-file` replaces the stdin plumbing codex (`-`) and gemini (`-p ""`) need.
  `watchdog.sh` treats `STDIN_FILE` as optional, so the launch drops it.
- `--permission-mode bypassPermissions` beats `--always-approve`: it lets the reviewer read
  outside its working directory. Confinement is what pushed five ext-claude reviewers into
  `DEGRADED` on 2026-08-04.
- `--no-plan` stops grok from entering plan mode and answering with a plan instead of a
  review. Neither codex nor gemini has such a mode. It is NOT redundant with
  `--permission-mode bypassPermissions`: the two are orthogonal — permissions govern what a
  tool call may touch, plan mode governs whether the model answers with a plan instead of
  doing the work. A run can be fully permitted and still return a plan.
- Subagents stay enabled. The shared guard already reads a stream split into segments by a
  background subagent: it takes the maximum `num_turns` across successful `result` events.

### Run directories

`runs/grok/<model>/<timestamp>-<task>/`, the shape `runs/ext-claude/<provider>/<short>/`
already uses. A direct `/claude-mesh:grok-exec` call that names no model writes to
`runs/grok/<timestamp>-<task>/` instead, one level up. The two never collide: the guard and
the watcher accept a run directory only if its name matches `^[0-9]{4}(-[0-9]{2}){5}-`, so a
model directory is never mistaken for a run, nor a run for a model. Contents: `.task_name`, `.model` (the validated model id, so the run dir and the `-m` argument can never disagree), `.session_id`, `prompt.md`, `raw.jsonl`, `raw.json`,
`output.txt`, `report.md`, `stderr.txt`; supervised mode adds `attempt-N/`, `final/` and
`watchdog.log`.

### Supervised mode

`watchdog.sh` with `STREAM_FILE_NAME=raw.jsonl`, `HARD_ZERO_TIMEOUT=600`,
`GLOBAL_TIMEOUT=3600`, `MAX_RETRIES=2` — the codex and gemini settings. The launch is a
background Bash call, never a foreground one, for the reason the other two skills document
at length: a foreground call dies at `BASH_MAX_TIMEOUT_MS` and takes its process group with
it.

### Progress output

Unsupervised mode prints one `::` line per `assistant` message carrying a `tool_use` block
and one on the terminal `result`. This format sends whole messages rather than token deltas,
so the progress log stays short by construction.

### The Claude Code world inside grok

Grok reads `~/.claude/CLAUDE.md` and every installed claude-* plugin; the CLI offers no flag
to suppress them. claude-mesh accepts this: project rules help a reviewer, and the ~19 k
tokens of inventory are cached. The review prompt adds one line forbidding skills and slash
commands, so grok cannot answer a review request by launching `claude-mesh:mesh-review`
inside it. `SKILL.md` and the README record the difference from codex and gemini.

## 3. Review layer and orchestrator integration

**`skills/grok-code-review/SKILL.md`** follows `gemini-code-review`: resolve the diff range
(`BASE_BRANCH`, `merge-base`), render `shared/code-review-prompt.md` through
`render-template.py`, delegate execution to `grok-exec` with `SUPERVISED_MODE=shell`. The
only addition to the shared prompt is the no-skills line from §2.

**`agents/grok-executor.md` and `agents/grok-code-reviewer.md`** are wrappers whose first
action must be the Skill tool. `MODEL` is REQUIRED on the first line, written as
`MODEL=grok-4.6` — a single catalog entry, not the `<provider>/<short>` pair `ext-claude`
uses. An agent that receives none stops and returns the usage error rather than reviewing on
its own model.

**Reviewer names follow the claude pattern:** `grok:grok-4.6`. The name is what the
selection UI shows, what the delegation table carries, what `preflight-env.sh` reports, and
what finding attribution uses — so two grok models reporting one issue count as two
independent corroborations, exactly like `claude:opus` and `claude:fable`.

**One caveat the catalog makes real.** `grok models` on this machine proxies models that
claude-mesh ALSO reaches through `ext-claude` — `deepseek-*`, `glm-5-3*`, `minimax-m3`,
`kimi-k3`. Selecting `grok:deepseek-v4-pro` beside `ext-claude deepseek/v4-pro` puts ONE model
behind two transports, and the attribution table counts its single opinion twice. The plugin
cannot detect this — it never learns what a grok alias resolves to — so the rule is
documentary: a grok model duplicating a configured ext-claude provider is not an independent
corroboration, and `config.example.yaml` recommends keeping `grok.models` to the grok family
for exactly that reason.

**Q1 has to be restructured before grok can appear in it — a design change, not a plan detail.**
`AskUserQuestion` accepts at most four options, and Q1 already carries exactly four (`claude`,
`codex`, `gemini`, `external models`) in both orchestrators. grok would be the fifth on a fully
configured machine, which is the machine this feature targets. So Q1 collapses the CLI engines
into ONE option:

```
  claude ★ default (свой Claude Code)
  внешние CLI (codex / gemini / grok) ★ default     — shown when any of the three is configured
  external models (Anthropic-API) ★ default          — shown when models: is non-empty
```

Choosing the CLI option opens a second page listing the configured engines, built on the SAME
`chunk of 4` pagination Step 2.4 and Step 3 already use — no new UI mechanic is introduced.
**When exactly one CLI engine is configured that page is skipped and the engine selected
implicitly**, so the common single-engine setup costs no extra screen; the page appears only
where a choice actually exists.

The grouping is not arbitrary: codex / gemini / grok are precisely the class `preflight-env.sh`
already treats as one through `cli_row` — third-party binaries the user installs and
authenticates outside this plugin — as opposed to the built-in `claude` and the `provider:*`
rows behind `external models`. The UI now names a division the code already makes. A fourth CLI
engine will need no Q1 change at all.

**`/mesh-review`** gains `HAS_GROK` and `list-grok-models` in Step 1 with
the established rc handling (rc=2 means "config not created yet", rc=1 means "print the
validator's stderr and stop"); a `grok CLI ★ default` option in Q1, shown only when
`HAS_GROK=1`; a grok-model selection step mirroring Step 2.4, including its two mandatory
empty-list bindings; `grok:<model>` pairs in the dispatch roster; and `grok/<model>` entries
for the watcher.

**`/mesh-design-review`** gains the same four points at its own step numbers (5.0, 5.1, a new
5.2.6, 5.4) plus `defaults.design_review.grok_models`. These must be written for that file,
not copied: it documents four places where the two orchestrators deliberately differ — path
resolution, the order of guard and ping, the routing of a dead run, and the scope of the
watch loop.

**Both `*-fresh-session` commands** list grok among the engines. They name no models and read
what `preflight-env.sh` found, so the change is small.

**When grok is selected but no model is checked**, no grok reviewer runs, and the confirmation
page says so.

## 4. Delegation guard and observability

**`verify-delegation.sh`** gets one line in the path resolver
(`grok) BASE="$DATA_DIR/runs/grok/$MODEL"`) and `grok` added to the existing `ext-claude`
classification branch, which applies unchanged because the stream format is identical:
`is_error` on the last `result`, the maximum `num_turns` across successful events, the
`MIN_REVIEW_BYTES` floor, and `permission_denials` (absent on grok, and absence already means
"nothing was denied"). Two message texts inside that branch are true only of ext-claude — the
archive floor "the shortest genuine review in the archive is 460" and the `DEGRADED` remedy,
which prescribes a flag grok already sets — and must branch on `$ENGINE`.

**`watch-runs.sh`** needs no logic change: its roster pattern accepts `grok/grok-4.6`, and
freshness already reads `raw.jsonl`, `attempt-*/raw.jsonl` and `watchdog.log`. Only the
comment naming codex-exec and gemini-exec as the owners of `HARD_ZERO_TIMEOUT=600` is
updated.

**`preflight-env.sh`** gets a `grok` row and contributes `grok:<model>` names to the summary.
The probe runs `grok models`, which checks reachability and login in one call; a curl against
`api.x.ai` would test an endpoint the subscription path does not use, since grok.com relays
the traffic. Measured at 1.0–1.2 s warm across three consecutive runs, so the existing
`HTTP_TIMEOUT` of 5 s carries roughly fourfold headroom; a cold start has not been measured,
and if one is ever seen to exceed the budget the fix is a `PREFLIGHT_CLI_TIMEOUT` of its own,
following the `PREFLIGHT_GIT_TIMEOUT` precedent — not a raise of the shared HTTP budget.

**The two halves of the row mean different things.** `grok OK` is a statement about the CLI:
it is installed and logged in. `grok:<model>` in `SUMMARY available` is a statement about the
CONFIG: that name is listed in `grok.models`. The probe deliberately does not cross-check the
two — that would mean parsing the human-readable output of `grok models`, a format with no
stability promise — so a model the subscription no longer serves still appears as available
and fails at dispatch instead. Say so in the row's comment, so no reader mistakes the second
half for a subscription check.

## 5. Tests

New fixtures under `skills/shared/tests/fixtures/`:

- `valid-grok.yaml` and `valid-codex-gemini-grok.yaml`
- `invalid-grok-scalar.yaml` — `grok: false`
- `invalid-grok-models-missing.yaml` — section present, catalog absent
- `invalid-grok-models-empty.yaml` — empty list
- `invalid-grok-model-charset.yaml` — a name containing `:`
- `invalid-grok-model-duplicate.yaml`
- `invalid-defaults-builtin-grok-no-section.yaml`
- `invalid-defaults-grok-models-unknown.yaml` — entry outside the catalog
- `invalid-defaults-builtin-grok-no-grok-models.yaml`
- `unknown-grok-effort.yaml` — WARN and pass through
- `broken-grok-valid-codex.yaml` — a malformed grok section must not block a codex run. **The
  fixture must carry a `defaults:` block**, or it proves nothing: `get-defaults` is the call
  that validates the preset, so without one the test never reaches the path where grok could
  ground codex, and passes for the wrong reason
- `unreferenced-broken-grok.yaml` — a grok section that no preset references must not fail the
  preset read at all

Extensions to the existing suites:

- `test-config-loader.sh` — the new getters, the new validator, and a regression asserting
  that every claude-catalog error message is byte-identical after the shared-helper move
- `test-verify-delegation.sh` — grok scoring REAL, STALLED, BROKEN, FLIP, DEGRADED and KILLED
- `test-watch-runs.sh` — a `grok/<model>` roster entry
- `test-preflight-env.sh` — the grok row in its OK, unconfigured and unavailable states
- `test-command-sync.sh` — the grok wording shared by both orchestrators. Note what this suite
  can and cannot do: it compares two files against EACH OTHER, so it catches drift but never
  a mistake made identically in both. The orchestrator defects this design is most likely to
  produce are of the second kind (wrong agent type, a missing binding, `grok/<model>` where
  `grok:<model>` belongs), so a separate static orchestrator-contract block is added — it
  asserts absolute facts per file, not equality between them

Finally, a live `/mesh-review` on this repository with grok selected.

## 6. Documentation

`config.example.yaml` gains the `grok:` section written in the file's own commented style.
The README gains grok in the config-schema table, in the dependency list, and in
troubleshooting. CHANGELOG records the feature.

## Backward compatibility

A config without a `grok:` section stays valid and behaves exactly as it does today. No
existing error message changes. No existing run directory moves.

## Out of scope

- Rewriting codex and gemini onto a shared engine registry.
- Per-model reasoning effort.
- Any grok API-key path: the CLI owns authentication.
- Suppressing the Claude Code plugins grok loads.

## Checks the plan must run first

1. Read `cli_row` in `preflight-env.sh` and decide how a `grok models` probe fits a helper
   built around curl — extend the helper or add a sibling.
2. Run `test-config-loader.sh` before and after the shared-validator move and diff the
   output; the claude messages must not move.
3. Measure `raw.jsonl` for one full review to confirm the message-level stream keeps the
   file growing well inside the 600 s stall window without `--include-partial-messages`.
