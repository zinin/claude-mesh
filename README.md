# claude-mesh

Claude Code plugin: multi-model code review, alt-Claude execution against
non-Anthropic providers (z.ai, Alibaba DashScope, DeepSeek, LiteLLM, Ollama
daemon), and session helpers.

## Features

(Slash commands are namespaced under `claude-mesh:` — that is how Claude Code surfaces plugin commands.)

- **`/claude-mesh:mesh-review`** — orchestrate code review across multiple models in parallel; add
  `autodecide` to have the disputed issues decided for you — same full analysis, an explicit
  self-check, one commit per decision
- **`/claude-mesh:mesh-design-review`** — iterative design-doc review with discussion of issues;
  takes the same `autodecide` argument
- **`ext-claude-code-reviewer` / `ext-claude-executor` agents** — Anthropic-API-compatible
  models on alt providers (one agent, any provider, any model)
- **`codex-*`, `gemini-*`, `grok-*` agents** — wrappers for the OpenAI Codex, Gemini and xAI
  Grok CLIs. The grok wrappers take a `MODEL` from the `grok.models` catalog, so one
  `/mesh-review` can run several grok models as independent reviewers
- **Session helpers** — `/claude-mesh:do-plan`, `/claude-mesh:pause-after-current-task`, `/claude-mesh:transfer-session`,
  `/claude-mesh:exec-plan-fresh-session`, `/claude-mesh:continue-plan-fresh-session`,
  `/claude-mesh:design-review-fresh-session`, `/claude-mesh:code-review-fresh-session`
- **`/claude-mesh:auto-decide-disputed`** — invoke mid-review to hand the remaining disputed issues
  to the agent itself: it writes the same structured analysis, rebuts its own recommendation in a
  `Проверка решения` section, marks each decision `уверенно` / `под вопросом`, and commits them one
  by one — `git log --grep=auto-decide-disputed` lists the run, `git revert` undoes any single
  decision. Same protocol as the `autodecide` argument of both review commands
- **Sandbox-aware review sessions** — the two `*-review-fresh-session` commands generate a prompt
  for a fresh session that reviews rather than implements, and never name a model: the session
  runs `skills/shared/preflight-env.sh` where it actually lives and picks reviewers from what
  that reports. For reviews that will run in an environment with a different `config.yaml` —
  typically another machine, VM or sandbox. Workflow: generate the prompt on the host, paste
  it into a fresh session inside the sandbox; that session probes its own environment and
  selects reviewers from what it finds
- **`/claude-mesh:claude-md-writer`** — best practices for writing and refactoring `CLAUDE.md`:
  size budgets, the three-tier `CLAUDE.md` → `.claude/rules/` → co-located layout, `paths:`
  frontmatter for conditional loading, quality checklist. Vendored from an external project —
  see [Credits](#credits)
- **Context-size hook** — `check-context-size` warns when approaching the STOP threshold; active only inside a `/do-plan` session (silent everywhere else)

## Install

```
/plugin marketplace add zinin/claude-plugins
/plugin install claude-mesh@zinin
```

## Configure

1. Copy the example config:

```bash
# Data dir id is <plugin>-<marketplace> = claude-mesh-zinin (verified §11.A / Task 2.5).
cp ~/.claude/plugins/cache/*/claude-mesh/*/config.example.yaml \
   ~/.claude/plugins/data/claude-mesh-zinin/config.yaml
```

2. Edit `~/.claude/plugins/data/claude-mesh-zinin/config.yaml`:
   - Add your providers (URL + token) under `providers:`
   - Add your models under `models:` with id format `<provider>/<short>`
   - Optionally configure `claude:` / `codex:` / `gemini:` / `grok:` sections (`grok:` also
     needs a non-empty `models:` catalog — see the schema table below)
   - Adjust `defaults:` for `/claude-mesh:mesh-review default` and `/claude-mesh:mesh-design-review default`

3. Verify config:

```bash
~/.claude/plugins/cache/*/claude-mesh/*/skills/shared/config-loader.sh validate
```

Any errors → fix as instructed in the message.

## Claude Code settings (not plugin config)

Two Claude Code environment variables bound how long a **single Bash tool call** may run. They
belong in `~/.claude/settings.json` (or a project `.claude/settings.json` / `.local.json`) —
**not** in the plugin's `config.yaml` — and they cap the harness, not the shell: nothing outside
Claude Code sees them.

| Variable | What it does | Claude Code default |
|---|---|---|
| `BASH_DEFAULT_TIMEOUT_MS` | timeout applied when the model passes none | `120000` (2 min) |
| `BASH_MAX_TIMEOUT_MS` | ceiling on what the model may request; the effective ceiling is the **larger** of the two | `600000` (10 min) |

A foreground Bash call that reaches its timeout is SIGTERMed, and the signal takes the whole
process group with it — every child dies, mid-write, with no chance to finalize.

Recommended:

```json
{
  "env": {
    "BASH_DEFAULT_TIMEOUT_MS": "300000",
    "BASH_MAX_TIMEOUT_MS": "3600000"
  }
}
```

**`BASH_MAX_TIMEOUT_MS` — set it to at least `runtime.timeouts.global_sec × 1000`** (default
`3600` → `3600000`). The rule is an invariant, not a preference: below it the plugin's own
budgets are decorative. `global_sec` 3600 and `single_run_sec` 1800 both sit above the stock
10-minute ceiling, so on the stock value a synchronous wait on a run is cut long before the
watchdog's restarts or its wall clock can act. Measured 2026-08-05 on CC 2.1.222: five external
reviewers launched as foreground calls died at 600–605 s while their streams were still growing,
each tool result reading `Exit code 143 / Command timed out after 10m 0s`. Values are JSON
**strings**; `settings.json` changes apply on save, a shell `export` from the next `claude`.

Since the release that made the exec skills launch their engine as a background task, this
ceiling is no longer load-bearing for reviews — a background task is not subject to it at all.
Keep it raised anyway as a safety net for a wrapper that ignores the instruction, and read
`KILLED` in a delegation table as the sign that one did (see Troubleshooting). The environment
probe checks the rule for you: a ceiling below `global_sec × 1000` shows up as a `bash-timeout
LOW` row carrying the exact value to set.

**`BASH_DEFAULT_TIMEOUT_MS` — 300000 (5 min) is a sane middle.** This one governs ordinary
commands that pass no timeout of their own: builds, test runs, `git log -S` sweeps over full
history, `find` over large trees. The 2-minute stock value is tight enough that this plugin's
own test suite does not fit: `skills/shared/tests/` runs 176 s end to end (2026-08-30, thirteen
suites, 1088 assertions — `test-preflight-env.sh` 105 s, `test-config-loader.sh` 48 s,
`test-watch-runs.sh` 22 s), so a foreground run of it dies partway through the longest
suite. 5 minutes clears that with room to spare. Do not push it near the max:
it applies to *every* untimed command, so a genuinely wedged one holds the turn for the whole
value before the harness intervenes — which is exactly the runaway the default exists to catch.

## Dependencies

The plugin requires:
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
  - `runtime.dispatch_model` governs the *plumbing*: the codex / gemini / grok / ext-claude wrapper agents, the `review-discussion` agent, and `/do-plan` subagents. To choose the models that actually *review*, list them under `claude.models` and pick a per-preset default in `defaults.<preset>.claude_models`: `/mesh-review` and `/mesh-design-review` then run one independent built-in reviewer per model (e.g. `opus` and `fable` at once) — whether the models come from the preset or from the interactive selection page — and those reviewers ignore `dispatch_model`. Leave the section out (or leave the list empty) and — whenever `claude` is selected at all (interactively, or via the preset's `builtin`) — you get exactly one claude reviewer on `dispatch_model` — as before for `/mesh-review`, and one more than before for `/mesh-design-review`, where `claude` used to be silently dropped. Without `claude` in play no claude reviewer runs, catalog or no catalog. **Cost scales linearly:** N Claude models = N full reviews of the same diff, on top of codex/gemini and every external model — three Claude models plus codex plus five external models is nine reviewers for one `/mesh-review`. Catalog entries are not checked against your Claude Code build: a name it does not accept fails that reviewer's dispatch — the run continues with the others, and the model is never silently substituted.
- `yq` — **either flavor**: Python-yq (`kislyuk/yq`) or Go-yq v4+ (`mikefarah/yq`). `config-loader.sh` does not identify the binary: it runs the transcode, keeps whichever invocation produced JSON, and — when the config contains a value that could have been mis-resolved — checks that `off`/`on`/`yes`/`no` came through as strings before trusting it. A `yq` that fails either check is refused by name, and your `config.yaml` is not blamed for it.
- `jq` — for JSON parsing in stream-json mode
- `bc`, `curl` — for `ext-claude-exec` skill
- `python3` — for `ext-claude-exec` and for prompt templating (`shared/render-template.py`) in ALL review skills (`ext-claude-`, `codex-`, `gemini-`, `grok-code-review`); also for `shared/extract-result.py`, which `ext-claude-exec` and `grok-exec` both use to pull the final answer out of the stream
- `codex` CLI (only if using codex agents)
- `gemini` CLI (only if using gemini agents)
- `grok` CLI (only if using grok agents). It authenticates itself (`grok login`); claude-mesh never handles a grok token. Unlike codex and gemini, grok also reads your `~/.claude/CLAUDE.md` and every installed claude-* plugin — a grok reviewer starts with your project rules in context, and its review prompt forbids it from invoking any of those skills

Install missing tools:
- Ubuntu/Debian: `apt install jq bc curl python3`
- macOS: `brew install jq bash coreutils util-linux findutils`

Plus a `yq`, installed however your platform provides one. If your package manager has none, or ships a Go-yq older than v4, `pipx install yq` works everywhere (that is Python-yq, and it needs `pipx`).

### macOS additional setup

claude-mesh's scripts use **GNU coreutils** (`timeout`, `stdbuf`, `stat -c`, `setsid` from util-linux) and **GNU findutils** (`find -printf`, used by the delegation guard). macOS ships only BSD variants by default. After `brew install bash coreutils util-linux findutils`, prepend the gnubin paths to your `PATH` so `timeout`/`stat`/`setsid`/`find` resolve to the GNU versions:

```sh
# Add to ~/.zshrc or ~/.bashrc
export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/util-linux/sbin:$(brew --prefix)/opt/util-linux/bin:$PATH"
```

A bash 4.2+ shell is also required (macOS system bash is 3.2). `brew install bash` provides this; ensure `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash` (Intel) appears in `$SHELL` or your terminal config. `config-loader.sh` and `ext-claude-exec` preflights detect Darwin and fail fast with these instructions if the setup is missing; `shared/watch-runs.sh` and `shared/verify-delegation.sh` are the two that need 4.2 rather than 4.0, for the `printf '%(fmt)T'` builtin, and `verify-delegation.sh` probes for GNU `find` at startup.

## Config schema reference

See `config.example.yaml` for the canonical example. Sections:

| Section | Required | Purpose |
|---|---|---|
| `providers:` | yes | API endpoint + auth + kind (anthropic-api / ollama-daemon) |
| `models:` | yes | id = `<provider>/<short>`, model name, optional alias overrides |
| `claude:` | no | `models:` — catalog of Claude model aliases offered for the built-in `claude` reviewer; each selected entry becomes one independent reviewer. Omit it (together with any `defaults.*.claude_models`) for the previous single-reviewer behaviour |
| `codex:` | no | model + reasoning_level for codex CLI — the default for `/codex-*` skills and reviews unless the caller overrides; unknown levels pass through with a WARN (known set as of 2026-07 is listed in `config.example.yaml`) |
| `gemini:` | no | model for gemini CLI — the default for `/gemini-*` skills and reviews unless the caller overrides |
| `grok:` | no | `models:` — catalog of grok model ids for the built-in `grok` reviewer, **required and non-empty** while the section exists. `reasoning_effort:` — optional section-wide default; `model_efforts:` — optional per-model overrides of it, because the CLI validates the level per model. One reviewer per selected entry, so cost scales as for `claude.models`. All three keys have rules worth reading before you edit them — see below |
| `defaults:` | no | named presets for `/claude-mesh:mesh-review default` etc. |
| `runtime:` | no | UI defaults + timeouts |


### The `grok:` section: a mandatory catalog, and an effort key the CLI checks per model

**`models:` is required and non-empty whenever the section exists** — a missing `models:` and an
empty `models: []` are both hard errors, because the grok reviewer agent refuses to start without
a model. (`claude:`'s catalog is optional; this one is not.) Its charset is narrower than
`claude.models`, since a grok model id becomes a directory name and a run-watcher roster entry —
`config.example.yaml` states the exact set. Entries are never checked against your CLI's own list
and never substituted: an id your `grok` does not accept fails that reviewer's run, and the other
reviewers carry on.

**`reasoning_effort:` is one value per section — the CLI validates it per model.** This loader
passes five values without a WARN — `low`, `medium`, `high`, `xhigh`, `max` — and anything else
with one, so a level xAI ships tomorrow needs no plugin release. Run `grok --help` for the
current set; `config.example.yaml`'s `grok.reasoning_effort` comment is the canonical copy of
the list, and this note and `config-loader.sh` follow it.

**Those five are no single model's set.** The CLI validates the flag PER MODEL at argument
parsing, before any API call, and rejects with rc=1. Measured 2026-08-30 on grok 1.0.5:
`grok-4.6` accepts `xhigh|high|medium|low`, `grok-4.5` only `high|medium|low`, and that CLI's own
default model all five — three sets behind one binary. Reading a model's own set is free, since
the probe fails on the flag and never reaches the API:

```sh
grok -m <id> --effort __bogus__ -p x
```

Rank each printed set by `low < medium < high < xhigh < max`: the CLI prints them in different
orders per model, so position is not rank.

**`model_efforts:` is how one catalog holds models with different sets.** It maps a model id to
the level that model runs at, overriding `reasoning_effort` for it alone; the section-wide value
still serves every entry the table does not name. Without it, the section default has to be valid
for EVERY catalog entry, and the entries that reject it lose their whole run with no diagnostic
from this plugin. Keys must be catalog entries — a key outside `models:` is a hard error rather
than a silent no-op, since the whole point is that you can trust a model ran at the level you
wrote. Write only the exceptions: most models accept the top level.

The resolution order a run follows is: the level a caller passed explicitly, then
`grok.model_efforts[<model>]`, then `grok.reasoning_effort`, then — with none of them set — no
`--effort` at all, which hands the choice to `~/.grok/config.toml`.

## WARNING: Uninstall wipes config

`/plugin uninstall claude-mesh@zinin` deletes `${CLAUDE_PLUGIN_DATA}` entirely,
including your `config.yaml` with API tokens. **Always pass `--keep-data` if you
want to keep the config.**

If you want a separate backup, copy `~/.claude/plugins/data/claude-mesh-zinin/config.yaml`
to a safe location before uninstalling.

## Troubleshooting

| Problem | Solution |
|---|---|
| `claude: command not found` | Install Claude Code CLI first |
| `yq: command not found` | Install either flavor — `pipx install yq` (Python-yq) or `apt install yq` / `brew install yq` (Go-yq v4+) |
| `yq cannot produce JSON` | The `yq` on PATH answers neither `yq .` nor `yq -o=json .` with JSON — it is too old, or not a `yq` at all. Install one of the two flavors above |
| `yq mis-resolves YAML scalars` | The `yq` on PATH resolves YAML 1.1, turning `off`/`yes` into booleans. Upgrade it, or install one of the two flavors above |
| `config.yaml not found at ...` | See "Configure" section above |
| `models[X] references missing provider "Y"` | Add a `providers[]` entry with `id: Y` |
| `Token expired or invalid for ...` | Update `token:` in the corresponding `providers[]` entry |
| `grok: command not found` | Install Grok Build — `curl -fsSL https://x.ai/cli/install.sh \| bash`, the installer xAI documents in the CLI's own README — then `grok login` |
| `grok` row reads `NO-NETWORK` in the probe | `grok models` failed: no network, or the CLI is signed out — run `grok login` |
| A grok reviewer's `output.txt` reads `API Error: Couldn't set model to <id>` | The id in `grok.models` is not one this machine's CLI accepts — claude-mesh does not check ids and never substitutes one. Run `grok models`: it prints `Default model:` and then `Available models:`, one `  - <id>` per line with `*` marking the default — copy an id from there verbatim |
| `Ollama daemon not running` | `ollama serve` or `systemctl start ollama` |
| `Daemon up but /api/tags returns error` | `ollama signin` |
| `HTTP 404 / 501 from LiteLLM provider` | LiteLLM is in OpenAI-compat mode — enable Anthropic mode in your LiteLLM config, or pass `SKIP_TOKEN_PRECHECK=1` to `ext-claude-exec` |
| Want to back up `config.yaml` before `/plugin uninstall` | Run `~/.claude/plugins/cache/*/claude-mesh/*/scripts/backup-config.sh` — it writes `~/claude-mesh-config-backup-<timestamp>.yaml` outside the plugin data dir |
| External review dies at ~600 s; `watchdog.log` ends with `"event":"cleanup" … "exit_code":143` and there is no `watchdog.exit` | The wrapper launched its engine as a **foreground** Bash call and the harness SIGTERMed it at `BASH_MAX_TIMEOUT_MS`. `verify-delegation.sh` reports this as `KILLED` (exit 6) and `/mesh-review` does **not** re-dispatch it — an identical launch dies identically. The exec skills require a background launch; raise the ceiling as a safety net (see "Claude Code settings"). A cluster of deaths at the same round number is the signature |
| `runs/` directory grows large over time | No automatic cleanup (intentional — personal-use plugin, hot-path I/O minimised). Add a cron one-liner: `0 3 * * 0 find ~/.claude/plugins/data/claude-mesh*/runs -mindepth 4 -maxdepth 4 -type d -mtime +30 -exec rm -rf {} +` (Sunday 03:00 weekly, deletes per-run dirs older than 30 days). Adjust `+30` to your retention preference. |

## Credits

`skills/claude-md-writer/` is vendored from
[serejaris/personal-corp-os](https://github.com/serejaris/personal-corp-os/tree/main/skills/claude-md-writer)
(MIT), then corrected against the current Claude Code docs — the upstream copy had drifted
since it was written. The skill's own footer lists every change. Upstream still maintains it;
to see what has moved there, diff against
`https://raw.githubusercontent.com/serejaris/personal-corp-os/main/skills/claude-md-writer/SKILL.md`,
expecting our corrections to show up as differences.

## License

MIT — see [LICENSE](LICENSE).
