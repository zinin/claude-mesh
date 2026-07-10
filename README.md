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
  `/claude-mesh:exec-plan-fresh-session`, `/claude-mesh:continue-plan-fresh-session`
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

## Dependencies

The plugin requires:
- `claude` CLI (this plugin runs on top of Claude Code). Mesh agents pin no model — subagents inherit your session model by default. To force a specific tier (e.g. `opus`, `fable`), set `runtime.dispatch_model` in config.yaml; if you name a model your Claude Code build does not support, dispatch fails at runtime — pick a supported alias/id.
- `yq` — **Python-yq (`kislyuk/yq`) ONLY**. Install via `pipx install yq`. **Go-yq (`mikefarah/yq`) is REJECTED** by `config-loader.sh` at startup (iter-2 SUGGESTION-1: aligns Dependencies row with iter-1 CRITICAL-1 / `require_yq()` flavor-detect). See full note below.
- `jq` — for JSON parsing in stream-json mode
- `bc`, `curl`, `python3` — for `ext-claude-exec` skill
- `codex` CLI (only if using codex agents)
- `gemini` CLI (only if using gemini agents)

Install missing tools:
- Ubuntu/Debian: `apt install jq bc curl python3 pipx && pipx install yq`
- macOS: `brew install jq pipx bash coreutils util-linux && pipx install yq`

**Important:** `yq` here means **Python-yq** (`kislyuk/yq`, pip package, jq-wrapper). On macOS `brew install yq` and on recent Ubuntu `snap install yq` provide a different tool — **Go-yq** (`mikefarah/yq`) — with an incompatible DSL. claude-mesh's `config-loader.sh` will detect a Go-yq binary and refuse to run with a clear message. Use `pipx install yq` on both platforms.

### macOS additional setup

claude-mesh's scripts use **GNU coreutils** (`timeout`, `stdbuf`, `stat -c`, `setsid` from util-linux). macOS ships only BSD variants by default. After `brew install bash coreutils util-linux`, prepend the gnubin paths to your `PATH` so `timeout`/`stat`/`setsid` resolve to the GNU versions:

```sh
# Add to ~/.zshrc or ~/.bashrc
export PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$(brew --prefix)/opt/util-linux/sbin:$(brew --prefix)/opt/util-linux/bin:$PATH"
```

A bash 4+ shell is also required (macOS system bash is 3.2). `brew install bash` provides this; ensure `/opt/homebrew/bin/bash` (Apple Silicon) or `/usr/local/bin/bash` (Intel) appears in `$SHELL` or your terminal config. `config-loader.sh` and `ext-claude-exec` preflights detect Darwin and fail fast with these instructions if the setup is missing.

## Config schema reference

See `config.example.yaml` for the canonical example. Sections:

| Section | Required | Purpose |
|---|---|---|
| `providers:` | yes | API endpoint + auth + kind (anthropic-api / ollama-daemon) |
| `models:` | yes | id = `<provider>/<short>`, model name, optional alias overrides |
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
| `runs/` directory grows large over time | No automatic cleanup (intentional — personal-use plugin, hot-path I/O minimised). Add a cron one-liner: `0 3 * * 0 find ~/.claude/plugins/data/claude-mesh*/runs -mindepth 4 -maxdepth 4 -type d -mtime +30 -exec rm -rf {} +` (Sunday 03:00 weekly, deletes per-run dirs older than 30 days). Adjust `+30` to your retention preference. |

## License

MIT — see [LICENSE](LICENSE).
