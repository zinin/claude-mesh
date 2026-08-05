# claude-mesh

Claude Code plugin: multi-model code review, alt-Claude execution against
non-Anthropic providers (z.ai, Alibaba DashScope, DeepSeek, LiteLLM, Ollama
daemon), and session helpers.

## Features

(Slash commands are namespaced under `claude-mesh:` — that is how Claude Code surfaces plugin commands.)

- **`/claude-mesh:mesh-review`** — orchestrate code review across multiple models in parallel
- **`/claude-mesh:mesh-design-review`** — iterative design-doc review with discussion of issues
- **`ext-claude-code-reviewer` / `ext-claude-executor` agents** — Anthropic-API-compatible
  models on alt providers (one agent, any provider, any model)
- **`codex-*`, `gemini-*` agents** — wrappers for OpenAI Codex CLI and Gemini CLI
- **Session helpers** — `/claude-mesh:do-plan`, `/claude-mesh:pause-after-current-task`, `/claude-mesh:transfer-session`,
  `/claude-mesh:exec-plan-fresh-session`, `/claude-mesh:continue-plan-fresh-session`,
  `/claude-mesh:design-review-fresh-session`, `/claude-mesh:code-review-fresh-session`
- **Sandbox-aware review sessions** — the two `*-review-fresh-session` commands generate a prompt
  for a fresh session that reviews rather than implements, and never name a model: the session
  runs `skills/shared/preflight-env.sh` where it actually lives and picks reviewers from what
  that reports. For reviews that will run in an environment with a different `config.yaml` —
  typically another machine, VM or sandbox. Workflow: generate the prompt on the host, paste
  it into a fresh session inside the sandbox; that session probes its own environment and
  selects reviewers from what it finds
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
   - Optionally configure `codex:` / `gemini:` sections
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
`KILLED` in a delegation table as the sign that one did (see Troubleshooting).

**`BASH_DEFAULT_TIMEOUT_MS` — 300000 (5 min) is a sane middle.** This one governs ordinary
commands that pass no timeout of their own: builds, test runs, `git log -S` sweeps over full
history, `find` over large trees. The 2-minute stock value is tight enough that this plugin's
own test suite does not fit: `skills/shared/tests/` runs 182 s end to end (2026-08-05, 580
assertions — `test-preflight-env.sh` 97 s, `test-config-loader.sh` 59 s, `test-watch-runs.sh`
21 s), so a foreground run of it dies partway through the longest suite. 5 minutes clears that
with room to spare. Do not push it near the max:
it applies to *every* untimed command, so a genuinely wedged one holds the turn for the whole
value before the harness intervenes — which is exactly the runaway the default exists to catch.

## Dependencies

The plugin requires:
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
  - `runtime.dispatch_model` governs the *plumbing*: the codex / gemini / ext-claude wrapper agents, the `review-discussion` agent, and `/do-plan` subagents. To choose the models that actually *review*, list them under `claude.models` and pick a per-preset default in `defaults.<preset>.claude_models`: `/mesh-review` and `/mesh-design-review` then run one independent built-in reviewer per model (e.g. `opus` and `fable` at once) — whether the models come from the preset or from the interactive selection page — and those reviewers ignore `dispatch_model`. Leave the section out (or leave the list empty) and — whenever `claude` is selected at all (interactively, or via the preset's `builtin`) — you get exactly one claude reviewer on `dispatch_model` — as before for `/mesh-review`, and one more than before for `/mesh-design-review`, where `claude` used to be silently dropped. Without `claude` in play no claude reviewer runs, catalog or no catalog. **Cost scales linearly:** N Claude models = N full reviews of the same diff, on top of codex/gemini and every external model — three Claude models plus codex plus five external models is nine reviewers for one `/mesh-review`. Catalog entries are not checked against your Claude Code build: a name it does not accept fails that reviewer's dispatch — the run continues with the others, and the model is never silently substituted.
- `yq` — **Python-yq (`kislyuk/yq`) ONLY**. Install via `pipx install yq`. **Go-yq (`mikefarah/yq`) is REJECTED** by `config-loader.sh` at startup (iter-2 SUGGESTION-1: aligns Dependencies row with iter-1 CRITICAL-1 / `require_yq()` flavor-detect). See full note below.
- `jq` — for JSON parsing in stream-json mode
- `bc`, `curl` — for `ext-claude-exec` skill
- `python3` — for `ext-claude-exec` and for prompt templating (`shared/render-template.py`) in ALL review skills (`ext-claude-`, `codex-`, `gemini-code-review`)
- `codex` CLI (only if using codex agents)
- `gemini` CLI (only if using gemini agents)

Install missing tools:
- Ubuntu/Debian: `apt install jq bc curl python3 pipx && pipx install yq`
- macOS: `brew install jq pipx bash coreutils util-linux && pipx install yq`

**Important:** `yq` here means **Python-yq** (`kislyuk/yq`, pip package, jq-wrapper). On macOS `brew install yq` and on recent Ubuntu `snap install yq` provide a different tool — **Go-yq** (`mikefarah/yq`) — with an incompatible DSL. claude-mesh's `config-loader.sh` will detect a Go-yq binary and refuse to run with a clear message. Use `pipx install yq` on both platforms.

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
| `defaults:` | no | named presets for `/claude-mesh:mesh-review default` etc. |
| `runtime:` | no | UI defaults + timeouts |

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
| `yq: command not found` | `pipx install yq` (must be Python-yq; see Dependencies) |
| `yq flavor mismatch: detected Go-yq` | Remove Go-yq from PATH (e.g. `brew uninstall yq` on macOS) and install Python-yq via `pipx install yq` |
| `config.yaml not found at ...` | See "Configure" section above |
| `models[X] references missing provider "Y"` | Add a `providers[]` entry with `id: Y` |
| `Token expired or invalid for ...` | Update `token:` in the corresponding `providers[]` entry |
| `Ollama daemon not running` | `ollama serve` or `systemctl start ollama` |
| `Daemon up but /api/tags returns error` | `ollama signin` |
| `HTTP 404 / 501 from LiteLLM provider` | LiteLLM is in OpenAI-compat mode — enable Anthropic mode in your LiteLLM config, or pass `SKIP_TOKEN_PRECHECK=1` to `ext-claude-exec` |
| Want to back up `config.yaml` before `/plugin uninstall` | Run `~/.claude/plugins/cache/*/claude-mesh/*/scripts/backup-config.sh` — it writes `~/claude-mesh-config-backup-<timestamp>.yaml` outside the plugin data dir |
| External review dies at ~600 s; `watchdog.log` ends with `"event":"cleanup" … "exit_code":143` and there is no `watchdog.exit` | The wrapper launched its engine as a **foreground** Bash call and the harness SIGTERMed it at `BASH_MAX_TIMEOUT_MS`. `verify-delegation.sh` reports this as `KILLED` (exit 6) and `/mesh-review` does **not** re-dispatch it — an identical launch dies identically. The exec skills require a background launch; raise the ceiling as a safety net (see "Claude Code settings"). A cluster of deaths at the same round number is the signature |
| `runs/` directory grows large over time | No automatic cleanup (intentional — personal-use plugin, hot-path I/O minimised). Add a cron one-liner: `0 3 * * 0 find ~/.claude/plugins/data/claude-mesh*/runs -mindepth 4 -maxdepth 4 -type d -mtime +30 -exec rm -rf {} +` (Sunday 03:00 weekly, deletes per-run dirs older than 30 days). Adjust `+30` to your retention preference. |

## License

MIT — see [LICENSE](LICENSE).
