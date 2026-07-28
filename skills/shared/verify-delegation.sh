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
#     since-epoch only run dirs NAMED at/after this unix time are considered — the same
#                 window watch-runs.sh applies, and creation time rather than mtime
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
#              codex/gemini: watchdog cleanup exit 0 (when logged), non-empty output, and a
#              stream carrying a terminal event, at least one tool call, and no final result
#              with an explicit status != "success"
#   STALLED=2  killed mid-flight or delivered nothing usable: no final / no result event /
#              no successful result event with an integer num_turns / final result event
#              is_error:true / engine rc!=0 / agentic but blank output — and for codex/gemini:
#              no stream file at all, no terminal event, or an error-status final result
#              (retry helps)
#   FLIP=3     no TIMESTAMP-NAMED run dir for this engine in the dispatch window — the reviewer
#              self-reviewed on the session model, or the model argument was truncated and BASE
#              is a provider directory (its children never match the run-dir shape)
#   BROKEN=4   finalized but non-agentic — ext-claude: NT<=1; codex/gemini: terminal event but
#              zero tool calls (thinking-only / DSML grammar / answered without reading code —
#              retry futile; fix by swapping the model in config.yaml)
set -u
export LC_ALL=C   # run dir names are compared with [[ < ]] and sorted; keep both byte-wise.
                  # A UTF-8 collation ignores '-' when comparing, so the name window below
                  # would disagree with watch-runs.sh on exactly the dirs it must agree on.

# 4.2, not 4.0: printf '%(fmt)T' renders --since into a run-dir name below, the same way
# watch-runs.sh does. Both scripts must resolve the same run, so both need the same builtin.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "verify-delegation: bash 4.2+ required (got ${BASH_VERSION:-unknown})" >&2
    exit 1
fi

resolve_plugin_data() {
    if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_DATA"; return; fi
    local d
    for d in "$HOME"/.claude/plugins/data/claude-mesh-*; do
        [ -d "$d" ] && [ -f "$d/config.yaml" ] && { printf '%s\n' "$d"; return; }
    done
    printf '%s\n' "$HOME/.claude/plugins/data/claude-mesh-zinin"
}

# Run identity. CLAUDE_CODE_SESSION_ID is exported into every Bash tool call and inherited
# across the agent boundary, so a run dir stamped by the *-exec skill carries the session that
# dispatched it. The body below is mirrored byte-for-byte in watch-runs.sh — the two must agree
# on which run is "the run", or the watcher reports DONE on one dir while this gate inspects
# another. FAIL-OPEN: an unstamped dir is a legacy run, a direct *-exec invocation, or a
# harness without the variable, and calling those foreign would drop a finished review.
SELF_SID="${CLAUDE_CODE_SESSION_ID:-}"
run_is_mine() {
    [ -n "$SELF_SID" ] || return 0
    local v=""
    [ -r "$1/.session_id" ] && IFS= read -r v < "$1/.session_id"
    [ -z "$v" ] || [ "$v" = "$SELF_SID" ]
}

ENGINE="${1:-}"
MODEL="${2:-}"
SINCE="${3:-}"
DATA_DIR="${4:-}"

[ -n "$ENGINE" ] && [ -n "$SINCE" ] || {
    echo "usage: verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]" >&2
    exit 1
}
# A non-numeric epoch used to reach `find -newermt "@$SINCE"`, which failed silently and left
# no candidate — FLIP, the verdict that says "the reviewer never delegated". Say it is a usage
# error instead: exit 1 prints no verdict, which is what the prompts read as "fix the call".
[[ "$SINCE" =~ ^[0-9]+$ ]] || {
    echo "verify-delegation: since-epoch must be a unix epoch (got '$SINCE') — did DISPATCH_EPOCH expand to nothing?" >&2
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

# Both ELIGIBILITY and the WINNER are decided by NAME, not by mtime. Run dir names start with
# a zero-padded timestamp, so name order is creation order; mtime order is not. On bail an
# abandoned dir gains a `final` symlink, which lifts its mtime above the retry dir that
# superseded it — picking by mtime then inspects the corpse and reports STALLED while
# watch-runs.sh, which picks by name, reports DONE on the retry. mesh-design-review chains the
# two on the same run, so that disagreement discarded a finished review.
#
# Eligibility used to be `find -newermt "@$SINCE"` — MODIFICATION time — while watch-runs.sh
# compares the name against the same epoch rendered as a name. A dir created BEFORE the window
# but still being written stays mtime-eligible forever, so /mesh-review Step 6.4a, which stamps
# a FRESH epoch before re-dispatching precisely "so the guard inspects the NEW run, not the old
# failed one", still handed this script the old one: a wrapper that flipped on re-dispatch
# (no new run dir at all) was scored REAL off the previous round's corpse. Rendering --since
# into the run-dir naming and comparing names makes the two scripts' windows identical by
# construction — and drops the last -newermt, so only -printf keeps GNU find in the picture.
#
# Candidates are also SHAPE-filtered, with the same anchor as watch-runs.sh:213. In LC_ALL=C
# letters sort above digits, so any non-timestamp name — a stray `tmp/`, or the model dirs
# that become children when a truncated MODEL argument makes $BASE a provider directory —
# outranks every real run and gets inspected as if it were one, yielding a terminal STALLED.
# Filtered out, those cases fall through to FLIP, the verdict the prompts say to re-check
# against the engine/model arguments.
#
# The walk stops at the newest candidate that belongs to THIS session (run_is_mine above). A
# foreign one is skipped rather than inspected: two orchestrations of one engine/model share
# this data dir, and inspecting a stranger's run yields a terminal verdict about work nobody
# asked for. Process substitution, not a pipe — a `while` on the right of a pipe runs in a
# subshell and NEWEST would not survive it.
printf -v SINCE_STR '%(%Y-%m-%d-%H-%M-%S)T' "$SINCE"
NEWEST=""
while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Descending name order: the first candidate older than the window ends the walk, because
    # every one after it is older still.
    [[ "$cand" < "$SINCE_STR" ]] && break
    run_is_mine "$BASE/$cand" || continue
    NEWEST="$BASE/$cand"; break
done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
         grep -E '^[0-9]{4}(-[0-9]{2}){5}-' | sort -r)
[ -n "$NEWEST" ] || emit FLIP "no run dir newer than dispatch time — reviewer did not delegate" 3
RD="$NEWEST"

# --- 2. did it finalize? (killed mid-flight = no final symlink AND no root output.txt) ---
if [ ! -e "$RD/final" ] && [ ! -f "$RD/output.txt" ]; then
    emit STALLED "run dir present but not finalized (killed mid-flight)" 2
fi

# -s, not -f, on the root file: gemini-exec pre-creates a zero-byte output.txt at launch and
# the supervised copy-up can land one, and an EXISTING-but-empty root would then win over a
# final/output.txt that holds the actual review. watch-runs.sh:279 picks the same file with -s
# and reports DONE; with -f here the gate answered STALLED on the run the watcher had just
# called finished, and design review's failure path drops it for good.
OUT="$RD/output.txt"; [ -s "$OUT" ] || OUT="$RD/final/output.txt"

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
            # gemini can exit 0 while reporting an API failure as a result event with
            # status!="success" — gemini-exec's own extraction then writes "API Error: …" into
            # output.txt (SKILL.md:350-357), so every other signal here looks healthy. Reject an
            # explicit non-success status on the LAST result event; a result carrying no status
            # field stays accepted — the documented success shape does not promise one, and a
            # false STALLED discards a finished review. codex streams have no "type":"result"
            # lines at all (turn.completed is their terminal), so this never fires for codex.
            LAST_RES="$(grep '"type":"result"' "$STREAM" 2>/dev/null | tail -1)"
            if printf '%s\n' "$LAST_RES" | grep -q '"status"' &&
               ! printf '%s\n' "$LAST_RES" | grep -q '"status":[[:space:]]*"success"'; then
                emit STALLED "final result event carries status != \"success\" — the engine reported an error, not a review" 2
            fi
            grep -q '"type":"command_execution"\|"type":"tool_use"' "$STREAM" 2>/dev/null ||
                emit BROKEN "terminal event but no tool call — narration, not a review" 4
        else
            # Every layout the exec skills produce carries a stream: supervised runs get root
            # raw.jsonl copied back, default-mode runs write log.jsonl (0 of 75 archived runs
            # lack both). No stream means the layout is not one our tooling wrote — nothing can
            # prove the run was agentic, so fail closed instead of silently skipping the gate.
            emit STALLED "no stream file (raw.jsonl / log.jsonl) — cannot verify the run did anything" 2
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
