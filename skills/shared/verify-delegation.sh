#!/usr/bin/env bash
# verify-delegation.sh — did a wrapper reviewer actually DELEGATE to its external
# engine and produce a REAL review, or did it flip / stall / break?
#
# Wrapper reviewers (codex / gemini / ext-claude-code-reviewer) are supposed to invoke
# their *-code-review skill, which runs the external engine and writes a run dir under
# ${DATA}/runs/<engine>/.../. Non-deterministically they sometimes "flip": skip the
# skill and self-review inline on the session's own model — a false cross-validation that
# leaves NO run dir. This script lets the /mesh-review orchestrator (Step 6.0) detect
# that mechanically instead of trusting the agent's returned text.
#
# Usage:
#   verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]
#     engine      ext-claude | codex | gemini
#     model       for ext-claude: "<provider>/<short>" (e.g. zai/glm); "-" for codex/gemini
#     since-epoch only run dirs created at/after this unix time are considered
#                 (the orchestrator stamps this just before dispatch)
#     data-dir    optional; defaults to config-loader resolve_plugin_data()
#
# Verdict on stdout + exit code:
#   REAL=0     finalized + agentic — ext-claude: num_turns>1 & non-empty output;
#                                     codex/gemini: watchdog rc=0 & non-empty output
#   STALLED=2  killed mid-flight: no final / no result event / engine rc!=0 (retry helps)
#   FLIP=3     no run dir for this engine in the dispatch window (self-reviewed on the session model)
#   BROKEN=4   finalized but num_turns<=1 — thinking-only / DSML grammar / answered
#              without reading code (retry futile; fix by swapping the model in config.yaml)
set -u

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
    echo "verify-delegation: bash 4+ required (got ${BASH_VERSION:-unknown})" >&2
    exit 1
}

resolve_plugin_data() {
    if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_DATA"; return; fi
    local d
    for d in "$HOME"/.claude/plugins/data/claude-mesh-*; do
        [ -d "$d" ] && [ -f "$d/config.yaml" ] && { printf '%s\n' "$d"; return; }
    done
    printf '%s\n' "$HOME/.claude/plugins/data/claude-mesh-zinin"
}

ENGINE="${1:-}"
MODEL="${2:-}"
SINCE="${3:-}"
DATA_DIR="${4:-}"

[ -n "$ENGINE" ] && [ -n "$SINCE" ] || {
    echo "usage: verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]" >&2
    exit 1
}
[ -n "$DATA_DIR" ] || DATA_DIR="$(resolve_plugin_data)"

case "$ENGINE" in
    ext-claude) BASE="$DATA_DIR/runs/ext-claude/$MODEL" ;;
    codex)      BASE="$DATA_DIR/runs/codex" ;;
    gemini)     BASE="$DATA_DIR/runs/gemini" ;;
    *) echo "verify-delegation: unknown engine '$ENGINE'" >&2; exit 1 ;;
esac

emit() { echo "$1"; [ -n "${2:-}" ] && echo "verify-delegation[$ENGINE${MODEL:+/$MODEL}]: $2" >&2; exit "$3"; }

# --- 1. did anything run? (run dir created in the dispatch window) ---
[ -d "$BASE" ] || emit FLIP "no run dir under ${BASE#"$DATA_DIR"/} — reviewer did not delegate (self-reviewed on the session model)" 3

NEWEST="$(find "$BASE" -mindepth 1 -maxdepth 1 -type d -newermt "@$SINCE" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
[ -n "$NEWEST" ] || emit FLIP "no run dir newer than dispatch time — reviewer did not delegate" 3
RD="$NEWEST"

# --- 2. did it finalize? (killed mid-flight = no final symlink AND no root output.txt) ---
if [ ! -e "$RD/final" ] && [ ! -f "$RD/output.txt" ]; then
    emit STALLED "run dir present but not finalized (killed mid-flight)" 2
fi

OUT="$RD/output.txt"; [ -f "$OUT" ] || OUT="$RD/final/output.txt"

# --- 3. is the content a REAL review? ---
case "$ENGINE" in
    codex|gemini)
        # codex/gemini CLIs have their own stream format (no type:result/num_turns);
        # the watchdog return code is the success signal.
        RCF="$RD/.watchdog_rc"
        if [ -f "$RCF" ] && [ "$(cat "$RCF" 2>/dev/null)" != "0" ]; then
            emit STALLED "engine exit code != 0 ($(cat "$RCF" 2>/dev/null))" 2
        fi
        [ -s "$OUT" ] || emit STALLED "output.txt empty — no usable review produced" 2
        emit REAL "delegated, non-empty review" 0
        ;;
    ext-claude)
        # num_turns is the authoritative signal that the model did agentic work (read code /
        # ran tools). Classify on it directly — it is robust to HOW a non-review surfaces
        # (empty output, thinking-only, or DSML tool-grammar leaked as literal text), so it
        # depends on neither sniffing output.txt for marker strings nor the thinking-fallback
        # that used to populate output.txt.
        #
        # Take the MAXIMUM over ALL result events, not the last one: a run that dispatches a
        # background subagent answers "started", then resumes and delivers the real review, and
        # progress-monitor.sh appends both segments to the same raw.jsonl. The closing segment's
        # num_turns counts only itself (1), so `tail -1` would call a genuine review BROKEN —
        # the one verdict mesh-review never retries. max and not sum: summing two non-agentic
        # segments (1+1) would fake a REAL. fromjson? skips a truncated line instead of
        # aborting the scan on it.
        RAW="$RD/raw.jsonl"; [ -f "$RAW" ] || RAW="$RD/final/raw.jsonl"
        NT="$(grep -h '"type":"result"' "$RAW" 2>/dev/null | jq -Rr 'fromjson? | .num_turns // empty' 2>/dev/null | sort -n | tail -1)"
        if [ -z "$NT" ]; then
            # finalized dir but no result event carried a num_turns → run was cut off
            emit STALLED "no usable result event in raw.jsonl — killed mid-flight" 2
        fi
        if [ "$NT" -le 1 ] 2>/dev/null; then
            emit BROKEN "num_turns=$NT: model produced no agentic review (thinking-only / DSML / answered without reading code — retry futile)" 4
        fi
        # num_turns > 1: genuinely agentic — require non-empty output to call it REAL.
        [ -s "$OUT" ] || emit STALLED "num_turns=$NT but output.txt empty — retry" 2
        emit REAL "delegated, agentic review (num_turns=$NT)" 0
        ;;
esac
