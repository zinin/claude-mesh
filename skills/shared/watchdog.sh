#!/usr/bin/env bash
# watchdog.sh — supervised runner for external CLIs.
# See docs/superpowers/specs/2026-04-24-review-agent-watchdog-design.md
#
# Env:
#   WORK_DIR            — required, target for attempt-*/
#   MAX_RETRIES         — default 2 (so 3 total attempts)
#   HARD_ZERO_TIMEOUT   — default 600 (seconds of no stream-file writes)
#   GLOBAL_TIMEOUT      — default 3600 (wall-clock across all attempts)
#   POLL_INTERVAL       — default 15 (seconds between liveness/mtime checks);
#                         tests set this to 1 for fast feedback.
#   STREAM_FILE_NAME    — default raw.jsonl
#   STDIN_FILE          — optional, fed to command's stdin
# Usage: watchdog.sh -- <cmd> [args...]
# Exit codes:
#   0   — success (one attempt succeeded)
#   2   — all attempts failed OR global_timeout (see watchdog.exit reason)
#   3   — internal failure / signal-driven cleanup paths not covered above
#   130 — SIGINT (user interrupt)
#   143 — SIGTERM (user signal)
#   64  — usage error
set -uo pipefail

# Preconditions: required external tools.
for tool in jq setsid stdbuf pgrep; do
    command -v "$tool" >/dev/null 2>&1 || { echo "watchdog.sh: required tool not found: $tool" >&2; exit 64; }
done

if [[ -z "${WORK_DIR:-}" ]]; then
    echo "watchdog.sh: WORK_DIR is required" >&2
    exit 64
fi
MAX_RETRIES="${MAX_RETRIES:-2}"
HARD_ZERO_TIMEOUT="${HARD_ZERO_TIMEOUT:-600}"
GLOBAL_TIMEOUT="${GLOBAL_TIMEOUT:-3600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

is_positive_integer() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_integer() {
    local value="$1"
    [[ "$value" == "0" || "$value" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_integer "$MAX_RETRIES" || { echo "watchdog.sh: MAX_RETRIES must be a non-negative integer" >&2; exit 64; }
is_positive_integer "$POLL_INTERVAL" || { echo "watchdog.sh: POLL_INTERVAL must be a positive integer" >&2; exit 64; }
is_positive_integer "$HARD_ZERO_TIMEOUT" || { echo "watchdog.sh: HARD_ZERO_TIMEOUT must be a positive integer" >&2; exit 64; }
is_positive_integer "$GLOBAL_TIMEOUT" || { echo "watchdog.sh: GLOBAL_TIMEOUT must be a positive integer" >&2; exit 64; }

STREAM_FILE_NAME="${STREAM_FILE_NAME:-raw.jsonl}"
if [[ -z "$STREAM_FILE_NAME" || "$STREAM_FILE_NAME" == */* || "$STREAM_FILE_NAME" == "." || "$STREAM_FILE_NAME" == ".." || "$STREAM_FILE_NAME" == "stderr.txt" ]]; then
    echo "watchdog.sh: STREAM_FILE_NAME must be a non-reserved filename, not a path" >&2
    exit 64
fi
STDIN_FILE="${STDIN_FILE:-}"

[[ "${1:-}" == "--" ]] || { echo "usage: watchdog.sh -- cmd [args...]" >&2; exit 64; }
shift
(( $# > 0 )) || { echo "usage: watchdog.sh -- cmd [args...]" >&2; exit 64; }

mkdir -p "$WORK_DIR" || { echo "cannot mkdir $WORK_DIR" >&2; exit 3; }

ATTEMPT=0
GLOBAL_START=$(date +%s)
ACTUAL_ATTEMPTS=0
WATCHDOG_LOG="$WORK_DIR/watchdog.log"
WATCHDOG_LOG_ENABLED=0
WATCHDOG_LOG_FD=""
WATCHDOG_LOG_TMP=""

WATCHDOG_LOG_TMP=$(mktemp "$WORK_DIR/.watchdog.log.XXXXXX" 2>/dev/null || true)
if [[ -n "$WATCHDOG_LOG_TMP" ]]; then
    if { exec {WATCHDOG_LOG_FD}>>"$WATCHDOG_LOG_TMP"; } 2>/dev/null; then
        if mv -Tf "$WATCHDOG_LOG_TMP" "$WATCHDOG_LOG" 2>/dev/null; then
            WATCHDOG_LOG_ENABLED=1
            WATCHDOG_LOG_TMP=""
        else
            exec {WATCHDOG_LOG_FD}>&- 2>/dev/null || true
            WATCHDOG_LOG_FD=""
            rm -f "$WATCHDOG_LOG_TMP" 2>/dev/null || true
            WATCHDOG_LOG_TMP=""
        fi
    else
        rm -f "$WATCHDOG_LOG_TMP" 2>/dev/null || true
        WATCHDOG_LOG_TMP=""
        WATCHDOG_LOG_FD=""
    fi
fi

heartbeat() {
    local event="$1"
    local details="${2:-null}"
    local ts
    ts=$(date +%Y-%m-%dT%H:%M:%S%z)
    local line
    line=$(jq -nc \
            --arg ts "$ts" \
            --arg event "$event" \
            --argjson attempt "$ATTEMPT" \
            --argjson details "$details" \
            '{ts:$ts, event:$event, attempt:$attempt, details:$details}' 2>/dev/null) \
        || return 0
    if [[ "$WATCHDOG_LOG_ENABLED" = "1" && -n "$WATCHDOG_LOG_FD" ]]; then
        printf '%s\n' "$line" >&"$WATCHDOG_LOG_FD" 2>/dev/null || true
    fi
    case "$event" in
        alive|attempt_start|attempt_success|attempt_failed|stall_detected|stream_lost|bail|complete|global_timeout_during_attempt)
            echo "[watchdog][$event] attempt=$ATTEMPT $details" >&2
            ;;
    esac
}

RUN_ATTEMPT_INTERNAL_ERROR=0
CURRENT_PGID=""
CLEAN_EXIT=0
_CLEANING=0

cleanup() {
    local rc=${1:-$?}
    if (( _CLEANING > 0 )); then
        return "$rc"
    fi
    _CLEANING=1
    # Record FIRST, tear down after. This line is the only durable evidence of HOW the run ended:
    # verify-delegation.sh reads the last `cleanup` event and, seeing 143/130 with no
    # watchdog.exit beside it, reports KILLED instead of re-dispatching into an identical death.
    # Written after the teardown it could take up to 15s to reach the log (10 grace seconds on
    # TERM plus 5 on KILL, terminate_process_group_with_grace below), and any sender that follows
    # its SIGTERM with a SIGKILL inside that window would leave a log ending at the last `alive`
    # heartbeat — indistinguishable from a genuine stall, which IS re-dispatched.
    heartbeat "cleanup" "$(jq -nc --argjson exit_code "$rc" '{exit_code:$exit_code}')" || true
    if [[ -n "$CURRENT_PGID" ]]; then
        terminate_process_group_with_grace "$CURRENT_PGID" || true
    fi
    if [[ "${CLEAN_EXIT:-0}" = "1" ]]; then
        exit "$rc"
    fi
    case $rc in
        0|2|130|143) exit "$rc" ;;
        *)           exit 3 ;;
    esac
}

terminate_pgid_with_grace() {
    local pid="$1"
    local pgid="$2"
    kill -TERM -- "-$pgid" 2>/dev/null || true
    local grace=0
    while (( grace < 10 )) && kill -0 "$pid" 2>/dev/null; do
        sleep 1 & wait $! 2>/dev/null || true
        grace=$((grace + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pgid" 2>/dev/null || true
        local kill_grace=0
        while (( kill_grace < 5 )) && kill -0 "$pid" 2>/dev/null; do
            sleep 1 & wait $! 2>/dev/null || true
            kill_grace=$((kill_grace + 1))
        done
    fi
    if kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

has_result_event() {
    local stream="$1"
    [[ -f "$stream" ]] || return 1
    grep -qE '^\{"type"\s*:\s*"(result|turn\.completed)"' "$stream"
}

run_attempt() {
    RUN_ATTEMPT_INTERNAL_ERROR=0
    local n=$1; shift
    local attempt_dir="$WORK_DIR/attempt-$n"
    local stream="$attempt_dir/$STREAM_FILE_NAME"
    local stderr_file="$attempt_dir/stderr.txt"
    [[ ! -e "$attempt_dir" && ! -L "$attempt_dir" ]] || { RUN_ATTEMPT_INTERNAL_ERROR=1; return 3; }
    mkdir "$attempt_dir" || { RUN_ATTEMPT_INTERNAL_ERROR=1; return 3; }
    ACTUAL_ATTEMPTS=$((ACTUAL_ATTEMPTS + 1))
    : > "$stream"  || { RUN_ATTEMPT_INTERNAL_ERROR=1; return 3; }
    : > "$stderr_file" || { RUN_ATTEMPT_INTERNAL_ERROR=1; return 3; }
    [[ -f "$stream" && ! -L "$stream" ]] || { RUN_ATTEMPT_INTERNAL_ERROR=1; return 3; }

    if [[ -n "$STDIN_FILE" && ! -f "$STDIN_FILE" ]]; then
        echo "watchdog.sh: STDIN_FILE is not a regular file: $STDIN_FILE" >&2
        RUN_ATTEMPT_INTERNAL_ERROR=1
        return 3
    fi
    if [[ -n "$STDIN_FILE" && ! -r "$STDIN_FILE" ]]; then
        echo "watchdog.sh: STDIN_FILE is not readable: $STDIN_FILE" >&2
        RUN_ATTEMPT_INTERNAL_ERROR=1
        return 3
    fi

    heartbeat "attempt_start" "$(jq -nc --arg dir "$attempt_dir" '{dir:$dir}')"

    # Launch under setsid in new process group; explicit stdin handling.
    if [[ -n "$STDIN_FILE" ]]; then
        setsid "$@" < "$STDIN_FILE" > "$stream" 2> "$stderr_file" &
    else
        setsid "$@" < /dev/null > "$stream" 2> "$stderr_file" &
    fi
    local pid=$!

    # Capture the actual PGID (may differ from PID in rare races).
    local pgid=""
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pgid" ]] && pgid="$pid"  # fallback
    CURRENT_PGID="$pgid"

    local exit_code=0
    local age=0
    local last_hb; last_hb=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        sleep "$POLL_INTERVAL" & wait $! 2>/dev/null || true
        kill -0 "$pid" 2>/dev/null || break
        local now; now=$(date +%s)
        if (( now - GLOBAL_START >= GLOBAL_TIMEOUT )); then
            heartbeat "global_timeout_during_attempt" "$(jq -nc '{}')"
            terminate_pgid_with_grace "$pid" "$pgid" || true
            return 1
        fi
        local mtime
        if ! mtime=$(stat -c %Y "$stream" 2>/dev/null); then
            heartbeat "stream_lost" "$(jq -nc --arg stream "$stream" '{stream:$stream}')"
            terminate_pgid_with_grace "$pid" "$pgid" || true
            RUN_ATTEMPT_INTERNAL_ERROR=1
            return 3
        fi
        age=$((now - mtime))
        if (( age > HARD_ZERO_TIMEOUT )); then
            heartbeat "stall_detected" "$(jq -nc --argjson age_sec "$age" '{age_sec:$age_sec}')"
            terminate_pgid_with_grace "$pid" "$pgid" || true
            if has_result_event "$stream"; then
                heartbeat "attempt_success" "$(jq -nc --argjson exit_code 0 '{exit_code:$exit_code}')"
                return 0
            fi
            heartbeat "attempt_failed" "$(jq -nc --argjson exit_code 2 '{exit_code:$exit_code}')"
            return 1
        fi
        if (( now - last_hb >= 60 )); then
            local event_count=0
            if [[ -f "$stream" ]]; then
                event_count=$(wc -l < "$stream" 2>/dev/null || echo 0)
                event_count=${event_count//[[:space:]]/}
                [[ "$event_count" =~ ^[0-9]+$ ]] || event_count=0
            fi
            heartbeat "alive" "$(jq -nc --argjson event_count "$event_count" --argjson age_sec "$age" '{event_count:$event_count, age_sec:$age_sec}')"
            last_hb="$now"
        fi
    done
    wait "$pid" 2>/dev/null
    exit_code=$?
    if (( exit_code == 0 )) || has_result_event "$stream"; then
        heartbeat "attempt_success" "$(jq -nc --argjson exit_code "$exit_code" '{exit_code:$exit_code}')"
        return 0
    fi
    heartbeat "attempt_failed" "$(jq -nc --argjson exit_code "$exit_code" '{exit_code:$exit_code}')"
    return 1
}

pgid_has_processes() {
    local pgid="$1"
    pgrep -g "$pgid" >/dev/null 2>&1
}

terminate_process_group_with_grace() {
    local pgid="$1"
    kill -TERM -- "-$pgid" 2>/dev/null || true
    local grace=0
    while (( grace < 10 )) && pgid_has_processes "$pgid"; do
        sleep 1 & wait $! 2>/dev/null || true
        grace=$((grace + 1))
    done
    if pgid_has_processes "$pgid"; then
        kill -KILL -- "-$pgid" 2>/dev/null || true
        local kill_grace=0
        while (( kill_grace < 5 )) && pgid_has_processes "$pgid"; do
            sleep 1 & wait $! 2>/dev/null || true
            kill_grace=$((kill_grace + 1))
        done
    fi
    pgid_has_processes "$pgid" && return 1
    return 0
}

trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

run_attempt_wrapper() {
    local n=$1; shift
    CURRENT_PGID=""
    run_attempt "$n" "$@"
    local rc=$?
    # Kill any leftover descendants of the attempt's process group, then clear
    # CURRENT_PGID so future cleanup paths do not target a completed attempt's
    # possibly recycled PGID.
    if [[ -n "$CURRENT_PGID" ]]; then
        if ! terminate_process_group_with_grace "$CURRENT_PGID"; then
            RUN_ATTEMPT_INTERNAL_ERROR=1
            CURRENT_PGID=""
            return 3
        fi
    fi
    CURRENT_PGID=""
    return "$rc"
}

# bail <reason> <attempts> <extra_json_object>
bail() {
    local reason="$1"
    local attempts="${2:-0}"
    local extra="${3:-}"
    [[ -z "$extra" ]] && extra='{}'
    local last_dir=""
    if (( attempts >= 1 )) && [[ -d "$WORK_DIR/attempt-$attempts" ]]; then
        last_dir="$WORK_DIR/attempt-$attempts"
    fi
    local now; now=$(date +%s)
    local elapsed=$((now - GLOBAL_START))

    if (( attempts >= 1 )) && [[ -d "$WORK_DIR/attempt-$attempts" ]]; then
        ln -sfn "attempt-$attempts" "$WORK_DIR/final" || { echo "watchdog.sh: failed to create final symlink on bail" >&2; exit 3; }
        [[ -L "$WORK_DIR/final" ]] || { echo "watchdog.sh: final is not a symlink" >&2; exit 3; }
    fi

    local tmp_exit
    tmp_exit=$(mktemp "$WORK_DIR/.watchdog.exit.XXXXXX") || { echo "watchdog.sh: failed to create temporary watchdog.exit" >&2; exit 3; }
    jq -n \
        --arg reason "$reason" \
        --argjson attempts "$attempts" \
        --arg last_attempt_dir "$last_dir" \
        --argjson elapsed_sec "$elapsed" \
        --argjson global_timeout_sec "$GLOBAL_TIMEOUT" \
        --argjson extra "$extra" \
        '{reason:$reason, attempts:$attempts, last_attempt_dir:$last_attempt_dir, elapsed_sec:$elapsed_sec, global_timeout_sec:$global_timeout_sec} + $extra' \
        > "$tmp_exit" \
        || { rm -f "$tmp_exit"; echo "watchdog.sh: failed to write watchdog.exit" >&2; exit 3; }
    mv -f "$tmp_exit" "$WORK_DIR/watchdog.exit" \
        || { rm -f "$tmp_exit"; echo "watchdog.sh: failed to install watchdog.exit" >&2; exit 3; }
    heartbeat "bail" "$(jq -nc --arg reason "$reason" '{reason:$reason}')"
    CLEAN_EXIT=1
    exit 2
}

for (( n=1; n<=MAX_RETRIES+1; n++ )); do
    ATTEMPT=$n
    now=$(date +%s)
    elapsed=$((now - GLOBAL_START))
    if (( elapsed >= GLOBAL_TIMEOUT )); then
        bail "global_timeout" "$ACTUAL_ATTEMPTS" '{}'
    fi
    attempt_rc=0
    run_attempt_wrapper "$n" "$@" || attempt_rc=$?
    now=$(date +%s)
    elapsed=$((now - GLOBAL_START))
    if (( elapsed >= GLOBAL_TIMEOUT )); then
        bail "global_timeout" "$ACTUAL_ATTEMPTS" '{}'
    fi
    if (( attempt_rc == 0 )); then
        ln -sfn "attempt-$n" "$WORK_DIR/final" || { echo "watchdog.sh: failed to create final symlink" >&2; exit 3; }
        [[ -L "$WORK_DIR/final" ]] || { echo "watchdog.sh: final is not a symlink" >&2; exit 3; }
        heartbeat "complete" "$(jq -nc '{status:"success"}')"
        CLEAN_EXIT=1
        exit 0
    fi
    if (( RUN_ATTEMPT_INTERNAL_ERROR == 1 )); then
        exit 3
    fi
done

now=$(date +%s)
elapsed=$((now - GLOBAL_START))
if (( elapsed >= GLOBAL_TIMEOUT )); then
    bail "global_timeout" "$ACTUAL_ATTEMPTS" '{}'
else
    bail "all_attempts_failed" "$ACTUAL_ATTEMPTS" '{}'
fi
