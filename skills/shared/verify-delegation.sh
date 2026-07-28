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
# ext-claude runs are judged on NT = the maximum num_turns across the SUCCESSFUL result
# events of raw.jsonl (a stream can carry several: a background subagent splits it into a
# "started" segment and the resumed one that delivers the review). Errored events and
# non-integer counts never enter that maximum — see the ext-claude branch for why.
#
# Verdict on stdout + exit code:
#   REAL=0     finalized + agentic — ext-claude: NT>1 & output.txt has non-whitespace content;
#                                     codex/gemini: watchdog rc=0 & non-empty output
#   STALLED=2  killed mid-flight or delivered nothing usable: no final / no result event /
#              no successful result event with an integer num_turns / final result event
#              is_error:true / engine rc!=0 / agentic but blank output (retry helps)
#   FLIP=3     no run dir for this engine in the dispatch window (self-reviewed on the session model)
#   BROKEN=4   finalized but NT<=1 — thinking-only / DSML grammar / answered
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

# Eligibility is still "modified inside the dispatch window", but the WINNER is the newest by
# NAME, not by mtime. Run dir names start with a zero-padded timestamp, so name order is
# creation order; mtime order is not. On bail an abandoned dir gains a `final` symlink, which
# lifts its mtime above the retry dir that superseded it — picking by mtime then inspects the
# corpse and reports STALLED while watch-runs.sh, which picks by name, reports DONE on the
# retry. mesh-design-review chains the two on the same run, so that disagreement discarded a
# finished review.
NEWEST="$(find "$BASE" -mindepth 1 -maxdepth 1 -type d -newermt "@$SINCE" -printf '%f\n' 2>/dev/null | LC_ALL=C sort -r | head -1)"
[ -z "$NEWEST" ] || NEWEST="$BASE/$NEWEST"
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
        # These CLIs carry no type:result/num_turns, so this branch used to check only
        # `.watchdog_rc` — which nothing under skills/ writes, only test fixtures — and then a
        # non-empty output.txt. That made it a no-op: it asked exactly what the caller already
        # knew, and a narration-only file passed as REAL. Use the signals that are on disk.
        RCF="$RD/.watchdog_rc"
        if [ -f "$RCF" ] && [ "$(cat "$RCF" 2>/dev/null)" != "0" ]; then
            emit STALLED "engine exit code != 0 ($(cat "$RCF" 2>/dev/null))" 2
        fi
        # The watchdog records its own exit in watchdog.log; that file really is written.
        if [ -f "$RD/watchdog.log" ]; then
            WRC="$(grep '"event":"cleanup"' "$RD/watchdog.log" 2>/dev/null | tail -1 |
                   grep -o '"exit_code":[[:space:]]*-\?[0-9]\+' | grep -o -- '-\?[0-9]\+$')"
            [ -z "$WRC" ] || [ "$WRC" = 0 ] || emit STALLED "watchdog cleanup exit code $WRC" 2
        fi
        [ -s "$OUT" ] || emit STALLED "output.txt empty — no usable review produced" 2
        # Content, when a stream is present. codex emits turn.completed / command_execution;
        # gemini emits result / tool_use. No terminal event means the CLI was killed mid-flight
        # and output.txt is salvage. A terminal event with no tool call at all is the codex and
        # gemini analogue of ext-claude's num_turns<=1: it finished, and it did nothing —
        # exactly the 47429-byte narration draft this gate exists to stop.
        STREAM="$RD/raw.jsonl"
        [ -s "$STREAM" ] || STREAM="$RD/final/raw.jsonl"
        [ -s "$STREAM" ] || STREAM="$RD/log.jsonl"
        if [ -s "$STREAM" ]; then
            grep -q '"type":"turn\.completed"\|"type":"result"' "$STREAM" 2>/dev/null ||
                emit STALLED "stream has no terminal event — killed mid-flight" 2
            grep -q '"type":"command_execution"\|"type":"tool_use"' "$STREAM" 2>/dev/null ||
                emit BROKEN "terminal event but no tool call — narration, not a review" 4
        fi
        emit REAL "delegated, non-empty review" 0
        ;;
    ext-claude)
        # num_turns is the authoritative signal that the model did agentic work (read code /
        # ran tools). Classify on it directly — it is robust to HOW a non-review surfaces
        # (empty output, thinking-only, or DSML tool-grammar leaked as literal text), so it
        # depends on neither sniffing output.txt for marker strings nor the thinking-fallback
        # that used to populate output.txt.
        #
        # Take the MAXIMUM over all SUCCESSFUL result events, not the last one: a run that
        # dispatches a background subagent answers "started", then resumes and delivers the real
        # review, and progress-monitor.sh appends both segments to the same raw.jsonl. The
        # closing segment's num_turns counts only itself (1), so `tail -1` would call a genuine
        # review BROKEN — the one verdict mesh-review never retries. max and not sum: summing
        # two non-agentic segments (1+1) would fake a REAL.
        #
        # Only successful events, and only integer counts, may enter that maximum:
        #   - is_error:true carries a turn count that measured a FAILURE. Real streams do this —
        #     five historical run dirs hold {"subtype":"success","is_error":true,"num_turns":95,
        #     "result":"Prompt is too long"} (note subtype lies; is_error is the signal), and both
        #     `tail -1` and a naive max elect 95, admitting that 18-character string as a REAL
        #     cross-validation.
        #   - a non-integer would reach `[ "$NT" -le 1 ]`, where `[` errors, the error is
        #     swallowed by 2>/dev/null, the `if` reads false and the run falls through to REAL.
        # Reading each line as a raw string (`jq -R`) is what keeps a truncated final line — the
        # shape a killed, live-appended stream leaves — from aborting the scan.
        RAW="$RD/raw.jsonl"; [ -f "$RAW" ] || RAW="$RD/final/raw.jsonl"

        # progress-monitor.sh:171-175 REWRITES output.txt from every result event, so the text
        # actually delivered is the LAST segment's. If that segment failed, the run delivered no
        # review however agentic the earlier ones were — and the lone "\n" it leaves behind would
        # sail through a bare `[ -s ]`. Retry can help, so STALLED rather than BROKEN.
        LAST_ERR="$(grep -h '"type":"result"' "$RAW" 2>/dev/null \
            | jq -Rr 'fromjson? | objects | select(.type == "result") | .is_error' 2>/dev/null | tail -1)"
        if [ "$LAST_ERR" = "true" ]; then
            emit STALLED "final result event is_error:true — the delivered output is the failed segment, not a review" 2
        fi

        NT="$(grep -h '"type":"result"' "$RAW" 2>/dev/null \
            | jq -Rr 'fromjson? | objects | select(.type == "result" and .is_error == false)
                      | .num_turns | numbers | select(. == floor and . >= 0)' 2>/dev/null \
            | sort -n | tail -1)"
        if [ -z "$NT" ]; then
            # finalized dir but no successful result event carried an integer num_turns
            emit STALLED "no usable result event in raw.jsonl — killed mid-flight" 2
        fi
        if [ "$NT" -le 1 ]; then
            emit BROKEN "num_turns=$NT: model produced no agentic review (thinking-only / DSML / answered without reading code — retry futile)" 4
        fi
        # num_turns > 1: genuinely agentic — require output with actual content to call it REAL.
        grep -q '[^[:space:]]' "$OUT" 2>/dev/null \
            || emit STALLED "num_turns=$NT but output.txt has no content — retry" 2
        emit REAL "delegated, agentic review (num_turns=$NT)" 0
        ;;
esac
