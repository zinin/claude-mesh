# Changelog

All notable changes to claude-mesh will be documented here.

## [Unreleased]

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
