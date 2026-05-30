#!/usr/bin/env bash
# Copy config.yaml to a timestamped backup OUTSIDE ${CLAUDE_PLUGIN_DATA}, so it
# survives `/plugin uninstall` (which deletes the entire data directory by default).
set -eu
# Task 2.5: this script may run from a plain shell where ${CLAUDE_PLUGIN_DATA} is unset.
# Resolve the data dir robustly: prefer the env var (set in plugin/hook contexts), else the
# ~/.claude/plugins/data/claude-mesh-* dir containing config.yaml, else the prod default.
resolve_data_dir() {
    if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_DATA"; return; fi
    local d
    for d in "$HOME"/.claude/plugins/data/claude-mesh-*; do
        [ -d "$d" ] && [ -f "$d/config.yaml" ] && { printf '%s\n' "$d"; return; }
    done
    printf '%s\n' "$HOME/.claude/plugins/data/claude-mesh-zinin"
}
SRC="$(resolve_data_dir)/config.yaml"
[ -f "$SRC" ] || { echo "backup-config: no config.yaml at $SRC" >&2; exit 1; }
DEST="$HOME/claude-mesh-config-backup-$(date +%Y%m%d-%H%M%S).yaml"
cp -- "$SRC" "$DEST"
chmod 600 "$DEST"
echo "Backed up to $DEST"
