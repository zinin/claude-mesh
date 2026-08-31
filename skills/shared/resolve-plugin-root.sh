#!/usr/bin/env bash
set -u
loader_at() { [ -f "$1/skills/shared/config-loader.sh" ]; }
if [ -n "${SKILL_BASE:-}" ]; then
    if loader_at "$SKILL_BASE"; then printf '%s\n' "$SKILL_BASE"; exit 0; fi
    # SKILL_BASE is the skill dir (…/skills/ext-claude-exec)
    parent="$(cd "$SKILL_BASE/../.." && pwd)"
    if loader_at "$parent"; then printf '%s\n' "$parent"; exit 0; fi
fi
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && loader_at "$CLAUDE_PLUGIN_ROOT"; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; exit 0
fi
if [ -n "${GROK_PLUGIN_ROOT:-}" ] && loader_at "$GROK_PLUGIN_ROOT"; then
    printf '%s\n' "$GROK_PLUGIN_ROOT"; exit 0
fi
found="$(find "$HOME"/.claude/plugins "$HOME"/.grok/plugins -path '*claude-mesh*/skills/shared/config-loader.sh' 2>/dev/null | sort -V | tail -1)"
if [ -n "$found" ]; then
    printf '%s\n' "$(cd "$(dirname "$found")/../.." && pwd)"
    exit 0
fi
echo "resolve-plugin-root: claude-mesh plugin root not found" >&2
exit 1
