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
#   STALLED=2  died mid-flight or delivered nothing usable: no final / no result event /
#              no successful result event with an integer num_turns / final result event
#              is_error:true / engine rc!=0 / agentic but blank output — and for codex/gemini:
#              no stream file at all, no terminal event, or an error-status final result
#              (retry helps)
#   KILLED=6   the run was stopped by a signal from OUTSIDE it: the watchdog's last cleanup
#              carries 143 (SIGTERM) or 130 (SIGINT) and no watchdog.exit sits beside it, so
#              nothing inside the run decided to stop. Distinct from STALLED because retry is
#              not the remedy — whatever sent the signal sends it again. The commonest sender
#              is the harness capping a FOREGROUND Bash call at BASH_MAX_TIMEOUT_MS
#   FLIP=3     no TIMESTAMP-NAMED run dir of THIS session for this engine in the dispatch
#              window — the reviewer self-reviewed on the session model, the model argument was
#              truncated and BASE is a provider directory (its children never match the run-dir
#              shape), or every run in the window carries another session's id, which the
#              reason line names because it is the one FLIP that is not the reviewer's doing
#   BROKEN=4   finalized but non-agentic — ext-claude: NT<=1; codex/gemini: terminal event but
#              zero tool calls (thinking-only / DSML grammar / answered without reading code —
#              retry futile; fix by swapping the model in config.yaml)
#   DEGRADED=5 ext-claude only: everything above says REAL, but the result event's
#              `permission_denials` is non-empty — the CLI refused N of the run's tool calls,
#              so the reviewer was confined to its working directory and wrote the review
#              without the sources it tried to open. KEEP the findings (they are real, just
#              partial) and do NOT retry: the cause is the invocation, not the run. codex and
#              gemini carry no such field and cannot reach this verdict
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

# GNU find. The candidate walk below uses -printf, which BSD find does not have; without a
# probe it fails silently, no candidate survives, and EVERY reviewer is reported FLIP — a
# verdict /mesh-review acts on by re-dispatching all of them. config-loader.sh and
# watch-runs.sh carry the same probe for GNU stat, for the same reason.
find / -maxdepth 0 -printf '' >/dev/null 2>&1 || {
    echo "verify-delegation: GNU find required (BSD find has no -printf). On macOS: 'brew install findutils' and put gnubin first in PATH." >&2
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
FOREIGN=0
while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Descending name order: the first candidate older than the window ends the walk, because
    # every one after it is older still.
    [[ "$cand" < "$SINCE_STR" ]] && break
    run_is_mine "$BASE/$cand" || { FOREIGN=$(( FOREIGN + 1 )); continue; }
    NEWEST="$BASE/$cand"; break
done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
         grep -E '^[0-9]{4}(-[0-9]{2}){5}-' | sort -r)
# "Never delegated" and "delegated, but the session id moved under us" are both FLIP, and the
# prompts act on FLIP by re-dispatching. Name the second one: it is a third cause on top of the
# two the design-review prose lists, and it is the reviewer's fault least of all.
[ -n "$NEWEST" ] || [ "$FOREIGN" = 0 ] ||
    emit FLIP "$FOREIGN run dir(s) in the dispatch window belong to another session — this session's id does not match the one that dispatched them" 3
[ -n "$NEWEST" ] || emit FLIP "no run dir newer than dispatch time — reviewer did not delegate" 3
RD="$NEWEST"

# --- 1.5. was it stopped from OUTSIDE the run? -------------------------------------------
# watchdog.sh records the two signals it can be killed by as its own exit code
# (`trap 'cleanup 143' TERM`, `trap 'cleanup 130' INT` — watchdog.sh:287-288) and writes
# `watchdog.exit` ONLY when it stops on its own judgement (retries exhausted / global timeout).
# A cleanup of 143/130 with no watchdog.exit beside it therefore says: nothing inside the run
# decided anything, the signal came from outside — and whatever sent it will send it again.
# That is the whole reason this is not STALLED, which /mesh-review Step 6.0.4 re-dispatches:
# on 2026-08-05 three such re-dispatches died exactly as the runs they replaced.
#
# The commonest sender is the harness itself. A FOREGROUND Bash call is capped at
# BASH_MAX_TIMEOUT_MS — ten minutes out of the box — and SIGTERMed at the cap, taking the whole
# process group with it; five ext-claude runs died that way at 600-605s while still writing,
# each tool result reading "Exit code 143 / Command timed out after 10m 0s", while every run
# launched with `run_in_background: true` outlived the cap (812s, 1397s, 2001s, 2028s). Every
# engine budget here sits ABOVE that cap (single_run_sec 1800, global_sec 3600), so on a
# foreground launch none of them is reachable. The launch side is fixed in the exec skills; this
# is the reading side, and it covers the two other senders seen the same day just as well — an
# orchestrator TaskStop on the wrapper, and a wrapper killing its own run.
WDOG_CLEANUP_RC=""
[ ! -f "$RD/watchdog.log" ] ||
    WDOG_CLEANUP_RC="$(grep '"event":"cleanup"' "$RD/watchdog.log" 2>/dev/null | tail -1 |
                       grep -o '"exit_code":[[:space:]]*-\?[0-9]\+' | grep -o -- '-\?[0-9]\+$')"
SIGNALLED=0
SIGNAL_NAME=""
case "$WDOG_CLEANUP_RC" in
    143) [ -f "$RD/watchdog.exit" ] || { SIGNALLED=1; SIGNAL_NAME=SIGTERM; } ;;
    130) [ -f "$RD/watchdog.exit" ] || { SIGNALLED=1; SIGNAL_NAME=SIGINT; } ;;
esac
KILLED_REASON="terminated from outside ($SIGNAL_NAME: watchdog cleanup exit $WDOG_CLEANUP_RC, no watchdog.exit) — nothing inside the run chose to stop, so the run itself was healthy. Do NOT re-dispatch: an identical launch is killed identically. A foreground Bash call is the usual sender — the harness caps one at BASH_MAX_TIMEOUT_MS (10 min by default) and SIGTERMs it there; the exec skills launch in the background for exactly this reason"

# --- 2. did it finalize? (died mid-flight = no final symlink AND no root output.txt) ---
if [ ! -e "$RD/final" ] && [ ! -f "$RD/output.txt" ]; then
    [ "$SIGNALLED" = 0 ] || emit KILLED "$KILLED_REASON" 6
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
        if [ -f "$RCF" ]; then
            RCV=""; IFS= read -r RCV < "$RCF" 2>/dev/null || true
            [ "$RCV" = "0" ] || emit STALLED "engine exit code != 0 ($RCV)" 2
        fi
        # The watchdog records its own exit in watchdog.log; that file really is written.
        # Read it from the value step 1.5 already parsed, so both readings of the same field
        # can never disagree. A signalled death is KILLED, not STALLED — same reasoning as
        # there, reached down a different path: this branch sees runs that DID finalize, so a
        # codex run killed after writing output.txt lands here rather than at the check above.
        if [ -n "$WDOG_CLEANUP_RC" ] && [ "$WDOG_CLEANUP_RC" != 0 ]; then
            [ "$SIGNALLED" = 0 ] || emit KILLED "$KILLED_REASON" 6
            emit STALLED "watchdog cleanup exit code $WDOG_CLEANUP_RC" 2
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

        # --- was it allowed to READ what it reviewed? ---
        # Every check above can pass on a run that never got outside its own cwd. Under `-p`
        # a permission prompt has nobody to answer it, so the CLI auto-denies: the reviewer
        # loses the sibling repositories it needs to check an API signature against real
        # source, falls back to guessing, and still finalizes with is_error:false and a
        # healthy num_turns. Nothing above can see that — on 2026-08-04 five reviewers came
        # back this way and this gate called every one of them REAL.
        #
        # The signal is `permission_denials` on the result event: one entry per refusal,
        # carrying the tool name and the exact input that was refused (verified on CC 2.1.221,
        # 2026-08-04 — a refused Read yields tool_name "Read", a refused Bash "Bash", and a run
        # under --permission-mode bypassPermissions yields []). Read it rather than grepping
        # the refusal text out of tool_result bodies, which is what the first version of this
        # check did and which fails in BOTH directions: it misses every wording that was not
        # sampled (the CLI has several, and the Bash one contains no "permission" at all), and
        # it fires on any FAILED tool call whose OUTPUT happens to quote one — grepping this
        # repository does exactly that, since the wordings are written down in it.
        #
        # Successful segments only, matching NT above: a stream split by a background subagent
        # carries several result events, and refusals belonging to an abandoned segment did not
        # constrain the review that was actually delivered. Summed and not maxed — each entry is
        # one refusal, not a running total.
        #
        # This cannot fail open. NT above is pulled from the same field of the same events of
        # the same file by the same jq; a broken jq, an unreadable $RAW or a stream with no
        # parsable result event leaves NT empty and exits STALLED before reaching this line. A
        # result event that simply omits the field (an older build) yields no entries and stays
        # REAL — absent is not denied.
        DENIED_TOOLS="$(grep -h '"type":"result"' "$RAW" 2>/dev/null \
            | jq -Rr 'fromjson? | objects | select(.type == "result" and .is_error == false)
                      | .permission_denials | arrays | .[] | .tool_name // "unknown"' 2>/dev/null)"
        DENIED="$(printf '%s\n' "$DENIED_TOOLS" | grep -c '[^[:space:]]')"
        if [ "$DENIED" -gt 0 ]; then
            # "Read×2, Bash×1" — which tools were refused says whether the reviewer lost source
            # files, searches, or both, and a bare count does not.
            BREAKDOWN="$(printf '%s\n' "$DENIED_TOOLS" | grep '[^[:space:]]' | sort | uniq -c |
                         sort -rn | awk '{printf "%s%s×%s", (n++ ? ", " : ""), $2, $1}')"
            emit DEGRADED "num_turns=$NT but the CLI refused $DENIED tool call(s) ($BREAKDOWN) — the reviewer was confined to its working directory and reviewed on incomplete context. Keep the findings; do NOT re-dispatch, an identical invocation is refused identically. The remedy is the user's, not an agent's: the ext-claude run needs --permission-mode bypassPermissions, and an installed plugin only picks that up through a release" 5
        fi
        emit REAL "delegated, agentic review (num_turns=$NT)" 0
        ;;
esac
