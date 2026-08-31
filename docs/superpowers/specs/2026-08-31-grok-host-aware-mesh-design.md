# Host-aware mesh reviewers on Grok Build

Date: 2026-08-31
Branch: `feat/grok-host-aware-mesh`
Status: written spec, awaiting review of this file

## Goal

`/claude-mesh:mesh-review` and `/claude-mesh:mesh-design-review` run on Grok Build by
dispatching **native** child agents (`spawn_subagent` + `model:` slug from `grok models`)
and still run the existing CLI wrappers when the user asks for them.

Claude Code keeps the 0.12.0 behaviour for a preset that does not mention `native`. The
same `config.yaml` serves both hosts. The plugin stays a Claude Code plugin that Grok
already loads; it is not republished as a grok-plugin.

## Verified facts about this Grok host

Measured 2026-08-31 in Grok Build against the machine that runs this repo. Claims below
come from `grok inspect --json`, `grok models`, `grok plugin list`, and the session's
tool list, not from documentation alone.

| Fact | Evidence |
|---|---|
| Grok loads claude-mesh from the Claude cache | `grok inspect`: plugin `claude-mesh`, path `~/.claude/plugins/cache/zinin/claude-mesh/0.12.0`, scope `user`, enabled |
| `grok plugin list` is a different inventory | printed `No plugins installed` while inspect listed eight Claude-compat plugins |
| Plugin agents resolve as `claude-mesh:<name>` | inspect `agents`: all nine wrapper/discussion agents plus the three builtins |
| Native slugs this session accepts on `spawn_subagent` | `grok models` printed, in this order: `grok-4.6` (default), `grok-4.5`, `dks-ultra`, `deepseek-v4-flash`, `dks-vision`, `glm-5-3-flash`, `minimax-m3`, `lanit-auto`, `kimi-k3`, `minimax-m3-ollama`, `deepseek-v4-flash-ollama`, `deepseek-v4-pro-ollama`, `glm-5-3`, `glm-5-3-flash-zai`, `deepseek-v4-flash-api`, `deepseek-v4-pro`, `deepseek-v4-flash-vision-exp`, `codex-sol`, `codex-terra`, `codex-luna` |
| Gemini is not a host slug | absent from `grok models`; a gemini review still needs the CLI wrapper |
| `opus` / `fable` / `sonnet` are not host slugs | absent from `grok models`; passing them as `spawn_subagent.model` fails |
| Ordinary bash has no plugin root | `GROK_PLUGIN_ROOT`, `GROK_PLUGIN_DATA`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA` all unset (same Task 2.5 hole as Claude Code) |
| Data dir is still Claude's | `~/.claude/plugins/data/claude-mesh-*` |
| Grok has no Task, Skill tool, SendMessage, or TeamCreate | session tool list: `spawn_subagent`, `ask_user_question`, `get_command_or_subagent_output`, `kill_command_or_subagent` |
| `get_command_or_subagent_output` can wait at most 600 s per call | tool schema `timeout_ms` max 600000 |
| Subagent nesting depth is one | Grok user guide; a child that calls `spawn_subagent` is rejected |
| `explore` is read-only | builtin type: read, search, shell; no file edits |
| Background subagent completion notifies the parent | Grok user guide; no disk watcher required for a child that *is* the review |

## Approach

One pair of orchestrator files, host-aware. The orchestrator detects the host by **which
tools it has**, not by `PATH` and not by `config.yaml`:

| Rule | Host |
|---|---|
| `spawn_subagent` is present | Grok Build |
| `spawn_subagent` is absent | Claude Code |

Presence of `spawn_subagent` is the test. Do not require `Task` to be missing: a future
Grok build that also exposes `Task` would otherwise be classified as Claude Code.

`config-loader.sh` stays host-agnostic: one schema, one `validate`. Runtime meaning of
`claude` and `native` is an orchestrator concern.

Do not split `*-grok.md` copies. Do not move the fan-out into a Grok Rhai workflow.

## 1. Reviewer types

`defaults.*.builtin` becomes `{ native, claude, codex, gemini, grok }`. Ext-claude ids stay
in `defaults.*.models`.

| Type | Claude Code | Grok Build |
|---|---|---|
| `native` | Synonym of `claude`: the same host reviewers, never a second set | `spawn_subagent` + `model:` from the live `grok models` list |
| `claude` | Host `Task` `general-purpose`, catalog `claude.models` (unchanged) | Wrapper around `claude -p`, catalog `claude.models`, one reviewer per selected alias |
| `codex` / `gemini` / `grok` | CLI wrappers as today | The same wrappers; they must start without a Skill tool (§5) |
| ext-claude `models:` | `claude -p` at `provider/short` | The same |

On Claude Code, `native ∪ claude` in one preset collapses to one host set sourced from
`claude_models` (and the existing empty-list fallback). `native_models` is ignored there.

On Grok, a preset that lists `claude` and not `native` does **not** start host slugs.
That is a breaking change **on Grok only**, for anyone who already runs 0.12.0 there with
`builtin: [claude, …]` expecting host reviews. Claude Code is unchanged. The example
preset adds `native`. The user's live file is theirs to edit.

Reviewer names never collide across types: `native:grok-4.6` and `grok:grok-4.6` are two
reviewers. Double-counting the same underlying model is accepted; the plugin does not
dedupe them.

## 2. Configuration schema

The loader does not branch on host.

```yaml
defaults:
  code_review:
    builtin: [native, claude, codex, gemini, grok]
    native_models: [grok-4.6, glm-5-3, kimi-k3]  # ignored on Claude Code
    claude_models: [opus, fable]                 # CC = host; Grok = claude -p
    grok_models: [grok-4.6]
    models: [zai/glm, ollama/kimi, deepseek/v4-pro, ollama/minimax]
```

`native` is not a YAML gate: no `native:` section, and `builtin: [native]` is valid without
one.

`defaults.<preset>.native_models`:

| File state | Loader |
|---|---|
| no `native` in builtin, key absent | valid |
| no `native` in builtin, key present | invalid — same pairing as `grok_models` without `grok` |
| `native` in builtin, key absent or `[]` | valid: Grok runs one native on the session model; CC uses the `claude` fallback |
| entries | charset `GROK_IDENT_RE` (`[A-Za-z0-9][A-Za-z0-9._-]*`). Not checked against `claude.models` or `grok.models` — those are other namespaces |
| a preset slug missing from live `grok models` | not a loader error; the Grok orchestrator WARNs and skips that reviewer |

`claude_models` without `claude` in builtin stays invalid. `native` does not satisfy that
pairing: a shared file that wants opus/fable on Claude Code still lists `claude` in
`builtin`. `claude` in builtin without `claude_models` stays valid on **both** hosts (one
reviewer on the engine default). Making that fail-closed on Grok would break the shared
file on Claude Code.

`get-defaults` grows `.native_models` (array, possibly empty). There is no `has_native`
flag and no `native_degraded` in the loader. The orchestrator computes availability.

`runtime.dispatch_model` keeps its schema. On Grok the orchestrator **does not** pass it
to `spawn_subagent` unless the value is in the live `grok models` list: `opus` is rejected
there. Wrappers inherit the parent session model. Native reviewers pass their own slug.
Claude CLI carries the alias in `MODEL=`, not in the spawn `model:` parameter.

`run_mode: team` stays in the schema (Claude Code). On Grok the orchestrator never offers
team; a preset that sets `team` STOPs rather than falling through to background.

A 0.12.0 file without `native` remains valid.

## 3. Dispatch and wait

Launch every selected reviewer in one message, as today. Only the spawn/wait mechanics
branch.

### Spawn

| Who | Claude Code | Grok |
|---|---|---|
| `native` | not a separate spawn (`≡ claude`) | `spawn_subagent`, `subagent_type: explore`, `background: true`, `model: "<slug>"` (omit `model:` when the list is empty) |
| `claude` | `Task` `general-purpose` + `model:` from `claude_models` | `claude-mesh:claude-code-reviewer` / `claude-executor` (§4), no spawn `model: opus` |
| other wrappers | `Task` `claude-mesh:*`, `run_in_background: true`, `model:` from `dispatch_model` if set | `spawn_subagent` `claude-mesh:*`, `background: true`, no `dispatch_model` unless it is a live host slug |

`explore` is Grok-only: a reviewer must not edit. Claude Code keeps `general-purpose`.
Do not set `isolation: worktree`; reviewers read the orchestrator's tree.

A native spawn whose `model:` the host rejects is a failed reviewer: record it, do not
substitute another slug. `max_redispatch` applies only to wrappers (FLIP/STALLED).

### Native prompt

Native reviewers do not get the short wrapper prompt. There is no Skill tool to invoke
`requesting-code-review`.

- **mesh-review:** the same review contract as `requesting-code-review` (range, `BASE_BRANCH`
  named in the prose, findings format). The child reads the tree. Do not inline the diff.
- **mesh-design-review:** the composed Step 4 prompt, already self-contained.

Every native prompt ends with the tooling-constraint paragraph grok CLI already carries:
do not invoke `mesh-review` / `mesh-design-review`, do not orchestrate other reviewers.
A nested `spawn_subagent` would fail on depth, but an in-process replay of the
orchestrator steps would not.

Wrapper prompts stay short. A long "review this yourself" prompt is still how wrappers
FLIP.

### Wait

Claude Code is unchanged: `watch-runs.sh` + SendMessage pings + `verify-delegation.sh` for
wrappers; host `claude` is INLINE and is not watched.

Grok:

1. Every reviewer is a background `spawn_subagent`. After dispatch, print the same "N
   agents running, do not block" line.
2. Native writes no `runs/native/…` and is not on the watcher roster. Step 6.0 marks it
   `INLINE`. The result is the child's text.
3. The parent does not sleep-poll. Harness completion notifications drive collection;
   `get_command_or_subagent_output` fetches that id. A wait-all on several ids is allowed;
   each call's ceiling is 600 s, so loop until every child has finished or
   `runtime.timeouts.global_sec` elapses.
4. Wrappers on Grok must not go idle before their CLI exits (§5). `watch-runs.sh` and
   `verify-delegation.sh` remain the disk guard against FLIP/STALLED. If the wrapper is
   silent and the run is `REAL`, the parent reads `output.txt` itself — that is the
   primary collection path on Grok, not the "after a second ping" fallback. There is no
   SendMessage.

`review-discussion` stays a sibling plugin agent spawned by the orchestrator, not a
grandchild.

## 4. `claude` on Grok is `claude -p`

On Claude Code, `claude` remains the host `Task`. This section is Grok-only.

`ext-claude-exec` already launches `claude -p`, the stream, the run dir, and supervised
mode. Official Claude Code is that binary without the provider `export` from `config.yaml`.
Auth is `claude login`. No Anthropic `providers:` entry, no token in yaml, no new section.

Two thin agents, so the table does not call this ext-claude:

- `agents/claude-code-reviewer.md`
- `agents/claude-executor.md`

They invoke `ext-claude-exec` with `HOST_CLAUDE=1`. `skills/claude-code-review/SKILL.md` is
a thin wrapper: resolve the diff / `BASE_BRANCH`, render `shared/code-review-prompt.md`,
delegate to exec. Do not copy watchdog, stream rendering, or `extract-result.py`.

**`HOST_CLAUDE=1` must not leak a provider endpoint.** Skip `config-loader.sh export`.
Unset `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, and the other variables that export
would have set, so a leftover env from the parent shell cannot send `opus` to z.ai.
`claude` then uses its own credential store. Pass `-m "$MODEL"` when MODEL is set.

Prompt contract matches grok/ext-claude: `MODEL=<alias>` on the first line (`opus`, never
`zai/glm`). If `claude.models` is non-empty, the alias must be in it. If the catalog is
empty, one run with no `-m`. `BASE_BRANCH=` on the next line. Design-review: composed
prompt, `SUPERVISED_MODE: shell`. No tooling-constraint paragraph: `claude -p` does not
see Grok's plugin list.

| | |
|---|---|
| run dir | `$DATA_DIR/runs/claude/<alias>/` |
| reviewer name | `claude:opus` |
| watcher roster | `claude/opus` (depth 1, like grok) |
| `verify-delegation.sh` | new engine `claude` on the ext-claude/grok classification branch (same wire format) |

The orchestrator does not guess from "id has no slash". The agent type is the mode.
`defaults.models` ids remain `provider/short` and always take the ext-claude path. A
slash in a `claude` engine model is a usage error from the guard, not `FLIP`.

Preflight on Grok: `command -v claude`. Missing binary + `claude` selected → degrade
that type only, same spoken line style as `grok_degraded`. The loader has no such flag.
An unauthenticated CLI fails as STALLED/BROKEN; do not tell the user to paste a token
into yaml.

## 5. Wrappers on a host without Skill tool or SendMessage

Three holes. Patch the existing agents and skills; do not fork `*-grok` copies.

### Invoke the skill

Every wrapper agent today says: first action is the Skill tool; do not read SKILL.md.
On Grok that instruction either no-ops or pushes the agent into self-review.

One rule, identical text, in every `*-reviewer` / `*-executor` and in every skill that
chains into `*-exec`:

- Skill tool present → invoke it, unchanged.
- Skill tool absent → `Read` the target `SKILL.md` (plugin root: `CLAUDE_PLUGIN_ROOT` /
  `GROK_PLUGIN_ROOT`, else the version-sorted glob over `~/.claude/plugins` and
  `~/.grok/plugins`) and follow every step. That *is* CLI delegation.
- Still forbidden: write findings without running exec.

The `*-code-review` → `*-exec` chain on Grok is a second `Read`, not a second subagent.

### Wait for the CLI

On Claude Code a wrapper starts watchdog+CLI in the background, names the run dir, and
goes idle; the parent pings with SendMessage. Grok has no SendMessage.

On Grok the wrapper does not end its turn while the CLI is alive: `run_terminal_command`
with `background: true`, then `get_command_or_subagent_output` on that **command** id
until it exits (not a nested subagent; depth stays 1). Then read `output.txt` and report.
Claude Code keeps idle+ping.

### Plugin root in bash

`mesh-design-review` and the exec skills rely on Claude Code printing `Base directory for
this skill:`. Do not rely on Grok printing that line. `${CLAUDE_PLUGIN_ROOT}` is empty in
bash on both hosts. The fallback below always runs when the print is missing.

One header for every skill bash block:

1. `SKILL_BASE` if the skill already knows it (CC print or injected skill path)
2. else `$CLAUDE_PLUGIN_ROOT` / `$GROK_PLUGIN_ROOT`
3. else `find … | sort -V | tail -1` under `~/.claude/plugins` and `~/.grok/plugins`

`config-loader.sh data-dir` is unchanged: `~/.claude/plugins/data/claude-mesh-*`.

### Orchestrator tool names

| Claude Code | Grok |
|---|---|
| Task, `run_in_background` | `spawn_subagent`, `background` |
| AskUserQuestion | `ask_user_question` (keep 4-per-page so CC does not break) |
| SendMessage | none; parent reads `output.txt` on `REAL` |
| TeamCreate | none; `team` → STOP |

## 6. Selection UI

Pagination of 4, sentinel on a one-option page, stars from the preset, final confirm:
Claude Code mechanics stay. Grok's `ask_user_question` may append Other; Other is not an
id — re-ask or parse a slug, never put the raw string in `MODEL=`.

### Q1 stays three options

| Option | Claude Code | Grok |
|---|---|---|
| 1. Host | `claude` — always shown | `native` ("свои модели хоста") — always shown |
| 2. External CLIs | shown if any of codex/gemini/grok; parentheses list those | the same, plus `claude` when `command -v claude` succeeds; parentheses `claude / codex / gemini / grok` |
| 3. External models | `HAS_MODELS` | `HAS_MODELS` |

Do not add `native` as a fourth Q1 option. On Claude Code it duplicates `claude`. On Grok
the host already occupies option 1.

"External CLIs" is not a reviewer type. Selecting it opens the engine page. Not selecting
it starts no CLI, including no Claude Code CLI.

### CLI engine page

One configured engine → skip the page. Otherwise one page, max 4.

Grok order: `claude`, `codex`, `gemini`, `grok`. That is exactly four. A fifth engine
later uses the model-page pagination; not in this work.

`claude` appears on this page **only on Grok**. Label: "Claude Code CLI", never "свой
Claude Code".

### Model pages

| Page | When | Source | Empty selection |
|---|---|---|---|
| native (Grok only) | Q1 host | live `grok models`, stars from `native_models` | one native on the session model |
| Claude | `claude` selected (CC: Q1; Grok: CLI page) | `claude.models`, stars from `claude_models` | one reviewer on the engine default (CC: Task / `dispatch_model`; Grok: `claude -p` without `-m`) |
| grok CLI | grok selected | `grok.models` | no grok reviewer (unchanged) |
| ext-claude | external models selected | `models:` | STOP if that was the only source |

Slugs in `native_models` that are missing from live `grok models` do not appear on the
page. One WARN at the start of the page, not one per slug.

Native order is `grok models` order. Do not lift starred entries to the front. A catalog
of ~18 slugs is five pages; do not raise the page size (Claude Code cap is 4).

Confirm lists `native:<slug>`, `claude:<model>`, `grok:<model>` as distinct bullets. On
Claude Code, `native`+`claude` in the preset must not produce two host bullets.

### `default` and run mode

`default` skips the UI and uses the preset. On Grok, run `grok models` once before
dispatch and intersect with `native_models`.

Skip the background/team question on Grok; always background. A preset `run_mode: team`
STOPs (§2).

Bind `SELECTED_NATIVE_MODELS` in both orchestrators wherever `SELECTED_CLAUDE_MODELS` is
bound today (preset branch, skip branch, model page), including `mesh-design-review`
iteration memory. An unbound name in a prompt invents a dispatch.

<!-- SYNC: empty native_models fallback (one session-model reviewer) lives in the loader's
     pairing (absent key is valid), both orchestrators' preset branches, both native model
     pages, and this paragraph. Change all or none. -->

## 7. Preflight and errors

The loader still either accepts the file or does not. Host-specific probes are the
orchestrator's (and `preflight-env.sh` when a fresh-session prompt runs it). Agents never
edit `config.yaml`.

Grok start-of-run bash, next to the existing flag reads:

| Probe | Role |
|---|---|
| `grok models` (existing `PREFLIGHT_CLI_TIMEOUT`) | live native catalog; empty/non-zero → degrade native |
| `command -v claude` | Claude Code CLI; missing → do not offer `claude` as an engine |
| existing `has_codex` / `has_gemini` / `has_grok` / `has_models` | YAML gates |

Claude Code does not probe `grok models` for native (the type is a synonym) and does not
hide Q1 `claude` because the binary is missing.

Degrade, do not STOP the whole mesh:

| Event | Action |
|---|---|
| `grok models` failed and `native` is selected | no native reviewers; say so; others run |
| preset slug absent from live `grok models` | WARN, skip that slug, start the rest |
| native spawn rejected | table row, no substitute slug |
| no `claude` binary, `claude` selected on Grok | skip those reviewers only |
| `claude -p` not logged in | wrapper STALLED/BROKEN, no "put a token in yaml" |
| preset `run_mode: team` on Grok | STOP, not a silent background fallback |
| Other from the question tool | not an id; re-ask |

`config.yaml` missing (rc=2) / invalid (rc=1) is unchanged. `native` in builtin on Claude
Code is valid. `native_models` without `native` is a loader error on every host.

Step 6.0: native is INLINE (`verify-delegation` not called). `claude:*` on Claude Code is
INLINE. `claude:*` on Grok uses engine `claude`. Other wrappers unchanged.

### `preflight-env.sh`

Do not infer `host: grok-build` from `command -v grok`. Print:

- `native-models`: slugs from `grok models`, or `SKIP` if that CLI did not answer
- `claude-cli`: `OK` / `MISSING` from `command -v claude`

SUMMARY names what this machine can select. On a Grok session `native` appears, and
`claude` means the CLI. The `*-fresh-session` generators keep "run
`/claude-mesh:mesh-review default`" and do not hardcode `Task` or `opus`. That is the
only session-helper change in this work. The generated session reads the probe it just
ran.

## 8. Tests

Loader fixtures (host-agnostic):

- `native` is a valid `builtin` value; an unknown value still dies
- `native` requires no YAML section
- `native_models` without `native` in builtin → invalid
- `native` without `native_models` → valid
- `native_models` charset: a slash or `opus@foo` → invalid
- `get-defaults` emits `.native_models`
- a 0.12.0 preset `[claude, codex, gemini, grok]` without `native` stays valid
- `builtin: [native, claude, …]` is valid (the loader does not collapse the synonym)

`verify-delegation.sh` / `watch-runs.sh`: engine `claude`, alias with no slash, roster
`claude/opus` at depth 1. A slashed claude model is a usage error (exit 1, no verdict),
not `FLIP`.

`preflight-env.sh`: new rows must not take down the probe. Mock `grok models` and
`command -v claude`. Do not assert `host: grok-build` from grok-on-PATH.

`test-command-sync.sh` test 6: absolute facts in **both** orchestrators —
`SELECTED_NATIVE_MODELS` is bound on every path that later reads it; native is excluded
from `verify-delegation`; Grok has no TeamCreate; `claude` on the CLI page exists only
in the Grok branch. Not a byte-equality of the two files.

Do not emulate `spawn_subagent` or Skill-tool absence in the bash suite.

### Manual smoke

1. Grok, preset with `native` + wrappers: native children have `model:` and no
   `runs/native/`; wrappers write `runs/…`; Step 6.0 distinguishes INLINE from REAL.
2. Grok, 0.12.0 preset without `native`: no host slugs start; `claude` goes to
   `claude -p` (or degrades if the binary is missing). This is the breaking change;
   it must be visible.
3. Claude Code, 0.12.0 preset: 0.12.0 behaviour; no `spawn_subagent` in the transcript.
4. Claude Code, preset with `native` and `claude`: one host set, not two.

## 9. Documentation and release

Release **0.13.0**. `config.example.yaml` adds `native` to `builtin` and a
`native_models` list in the file's commented style. README: host table from §1, the
Grok meaning of `claude`, `HOST_CLAUDE`, the Claude-compat load path (`grok plugin list`
being empty is not "the plugin is missing"), and the Grok-only break. CHANGELOG records
the feature and the break.

## Backward compatibility

Claude Code + a file without `native`: 0.12.0.

Grok + a file without `native`: `claude` in builtin now means `claude -p`, not host
models. Host slugs require `native` in builtin. Documented, not silently remapped.

No existing run directory moves. `runs/claude/` is new and only used on Grok.

## Out of scope

- A grok-plugin package or a second marketplace index
- Moving the data dir to `~/.grok`
- A Rhai workflow for the fan-out
- Auto-dedup of `native:grok-4.6` vs `grok:grok-4.6` (or glm vs `zai/glm`)
- Team mode on Grok
- Raising the AskUserQuestion page size
- `claude.reasoning_*`
- An Anthropic `providers:` entry to make the CLI start
- Switching Claude Code host reviewers to `explore`
- Forked `*-grok` skills
- `do-plan` / context-size hook changes

## Implementation order

One plan, likely one PR. Order is dependency, not ceremony:

1. Loader enum, `native_models` pairing, `get-defaults`, fixtures. Claude catalog error
   strings stay byte-identical.
2. `verify-delegation.sh` + `watch-runs.sh` engine `claude`; `ext-claude-exec HOST_CLAUDE=1`
   (env isolation, `runs/claude/<alias>/`).
3. Thin `claude-code-review` skill + two agents. Dual Skill-tool / Read SKILL.md paragraph
   and Grok wait-for-CLI paragraph on **all** wrapper agents. Shared bash plugin-root
   header in skills that currently need `SKILL_BASE`.
4. Both orchestrators: host detection, Q1/CLI/native pages, dispatch/wait tables,
   `SELECTED_NATIVE_MODELS`, Grok team STOP, Step 6.0 INLINE for native.
5. `preflight-env.sh` rows; fresh-session prompts drop any Task/opus hardcoding;
   `config.example.yaml`, README, CHANGELOG.

## Checks the plan must run first

1. Confirm `ext-claude-exec` export variable names so `HOST_CLAUDE=1` unsets every one,
   not a guessed subset.
2. Parse `grok models` on this machine (star/hyphen list under "Available models:") into
   a helper the orchestrator and preflight both use; pin the parser with a fixture of
   that output.
3. Confirm Grok `explore` may run shell (`git diff`, `git merge-base`). If a build cannot,
   native uses `general-purpose` and the plan records why.
4. Run `test-config-loader.sh` before and after the enum change; no existing valid
   fixture may flip to invalid except ones that list an unknown builtin (none should).
