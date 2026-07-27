#!/usr/bin/env bash
# watch-runs.sh — is each dispatched executor finished, still working, or dead?
#
# The /mesh-review (Step 5a) and /mesh-design-review (Step 6) orchestrators disk-watch their
# executors. Finalization is easy to see; DEATH is not — a dead executor and a slow one leave
# exactly the same disk: nothing changes. Both orchestrators used to hand-roll the poll loop
# from prose, and both arrived at "exit when the finished count grows", which death never does.
# On 2026-07-26 four executors died mid-stream and the orchestrator stayed silent for 38
# minutes. This script is that loop, written once.
#
# Usage:
#   watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR]
#                 <engine[/provider/model]>...
#
# The positional arguments are a ROSTER — the subpath under <data-dir>/runs/, e.g. `codex` or
# `ext-claude/zai/glm` — and NOT run directories. An executor that dies and self-retries creates
# a NEW run dir; a fixed list would keep watching the abandoned one, see it go quiet, and report
# a LIVE executor dead. The newest dir at/after --since is re-resolved on every evaluation.
#
# Pass ONLY the executors still being waited for. The baseline is virtual — every entry is
# assumed RUN — so anything else is news and exits immediately. An entry already handled comes
# straight back as news; that is the signal that the roster was not narrowed.
#
# Status per roster entry:
#   DONE     terminal, watchdog exit code 0 (or no watchdog at all), and output.txt non-empty
#   FAILED   terminal, anything else — including a bail, an external kill, and rc=0 with no output
#   SILENT   not terminal, nothing written for longer than the stall threshold
#   RUN      not terminal and writing recently, or no dir yet inside the startup grace
#   MISSING  no run dir at/after --since once the grace has elapsed
#
# EVERY verdict exits 0. The harness surfaces a non-zero background exit as "failed with exit
# code N", and an LLM orchestrator reads that as an error. A non-zero exit (64) means THIS
# SCRIPT is broken — bad arguments, missing dependency — never that an executor died.
set -u
export LC_ALL=C   # run dir names are compared with [[ < ]]; keep collation byte-wise

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "watch-runs: bash 4.2+ required (got ${BASH_VERSION:-unknown}) — printf '%(fmt)T' formats every timestamp here, so no date(1) is needed" >&2
    exit 64
fi

# The only non-builtin dependency. BSD stat spells this `-f %m`; config-loader.sh carries the
# same probe for the same reason.
stat -c %Y "$0" >/dev/null 2>&1 || {
    echo "watch-runs: GNU stat required (BSD stat uses -f). On macOS: 'brew install coreutils' and put gnubin first in PATH." >&2
    exit 64
}

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SELF_DIR/config-loader.sh"

STALL_FLOOR=600
DEADLINE_MARGIN=300

SINCE=""
STALL_SEC=""
POLL_SEC=30
ONCE=0
DATA_DIR=""
ROSTER=()

is_pos_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
die() { echo "watch-runs: $1" >&2; exit 64; }
usage() {
    echo "usage: watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR] <engine[/provider/model]>..." >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)     SINCE="${2:-}";     shift 2 || usage ;;
        --stall-sec) STALL_SEC="${2:-}"; shift 2 || usage ;;
        --poll-sec)  POLL_SEC="${2:-}";  shift 2 || usage ;;
        --data-dir)  DATA_DIR="${2:-}";  shift 2 || usage ;;
        --once)      ONCE=1; shift ;;
        --)          shift; while [ $# -gt 0 ]; do ROSTER+=("$1"); shift; done ;;
        -*)          die "unknown option '$1'" ;;
        *)           ROSTER+=("$1"); shift ;;
    esac
done

# A caller with nothing left to watch should not invoke the watcher at all.
[ "${#ROSTER[@]}" -gt 0 ] || usage

# Every option validates the same way. A silent fallback on one of them is how
# `--stall-sec --once <entry>` used to swallow the flag and then block forever.
is_pos_int "$POLL_SEC" || die "--poll-sec must be a positive integer (got '$POLL_SEC')"
[ -z "$STALL_SEC" ] || is_pos_int "$STALL_SEC" || die "--stall-sec must be a positive integer (got '$STALL_SEC')"
is_pos_int "$SINCE" || die "--since is required and must be a unix epoch (got '$SINCE') — did DISPATCH_EPOCH expand to nothing?"

printf -v NOW '%(%s)T' -1
[ "$SINCE" -le $(( NOW + 60 )) ] || die "--since is in the future ($SINCE)"
[ "$SINCE" -ge $(( NOW - 86400 )) ] || die "--since is more than a day old ($SINCE) — did DISPATCH_EPOCH expand to nothing?"

if [ -z "$DATA_DIR" ]; then
    [ -x "$LOADER" ] || die "config-loader.sh not found beside watch-runs.sh — pass --data-dir"
    DATA_DIR="$("$LOADER" data-dir 2>/dev/null)"
fi
[ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ] || die "data dir not resolved or missing: '$DATA_DIR'"

# Threshold: the caller's flag, else runtime.timeouts.stall_sec, else the floor. jq is optional —
# without it the substitution yields nothing and the fallback takes over, loudly.
if [ -z "$STALL_SEC" ]; then
    if [ -x "$LOADER" ]; then
        STALL_SEC="$("$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.stall_sec // empty' 2>/dev/null)"
    fi
    is_pos_int "$STALL_SEC" || {
        echo "watch-runs: runtime.timeouts.stall_sec not resolved — using $STALL_FLOOR" >&2
        STALL_SEC="$STALL_FLOOR"
    }
fi
if [ "$STALL_SEC" -lt "$STALL_FLOOR" ]; then
    echo "watch-runs: stall threshold $STALL_SEC raised to $STALL_FLOOR — codex-exec and gemini-exec hardcode HARD_ZERO_TIMEOUT=600, so a lower threshold would call a live run silent before its own watchdog acts" >&2
    STALL_SEC="$STALL_FLOOR"
fi

# The deadline lives HERE, not in the prompt. The watcher restarts after every event, so a
# relative budget would reset each time and never expire; and arithmetic over a shell variable
# in a prompt silently collapses to nonsense, because shell state does not survive between
# Bash-tool calls. Deriving it from --since makes that whole class of failure impossible.
GLOBAL_SEC=""
if [ -x "$LOADER" ]; then
    GLOBAL_SEC="$("$LOADER" get-runtime 2>/dev/null | jq -r '.timeouts.global_sec // empty' 2>/dev/null)"
fi
is_pos_int "$GLOBAL_SEC" || GLOBAL_SEC=3600
DEADLINE=$(( SINCE + GLOBAL_SEC + DEADLINE_MARGIN ))

# Run dir names begin YYYY-MM-DD-HH-MM-SS-<pid>, fixed width and zero padded, so a lexicographic
# comparison against the same rendering of --since is an exact creation-time window.
printf -v SINCE_STR '%(%Y-%m-%d-%H-%M-%S)T' "$SINCE"

declare -A WARNED_BASE=()
RUNDIR_PATH=""
NEWEST=0
STATUS=""
QUIET=""
LAST=""
DETAIL=""
RUNDIR=""
STATUSES=()
ROWS=""

# The newest run dir for a roster entry, at/after --since. Selection is by NAME, not mtime: on
# bail the abandoned dir gains a `final` symlink, which bumps its mtime above the retry dir's,
# and selecting by mtime would follow the corpse.
resolve_run_dir() {
    local entry="$1" base="$DATA_DIR/runs/$1" best="" name d
    RUNDIR_PATH=""
    if [ ! -d "$base" ]; then
        [ -n "${WARNED_BASE[$entry]:-}" ] || {
            echo "watch-runs: no runs directory for '$entry' ($base) — check the roster entry" >&2
            WARNED_BASE[$entry]=1
        }
        return 1
    fi
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        name="${d%/}"; name="${name##*/}"
        [[ "$name" < "$SINCE_STR" ]] && continue
        [[ -z "$best" || "$name" > "$best" ]] && best="$name"
    done
    [ -n "$best" ] || return 1
    RUNDIR_PATH="$base/$best"
}

# Freshness is the newest mtime across every stream a run can be writing.
#  - supervised: the CLI writes attempt-N/raw.jsonl and root raw.jsonl appears only at the end,
#    but watchdog.log gets an `alive` heartbeat every 60s, so the gap between retries is covered;
#  - unsupervised codex: log.jsonl only, no raw.jsonl at all;
#  - watchdog dead but CLI alive: attempt-*/raw.jsonl still moves.
# Erring toward "do not declare a live run dead" is deliberate; the deadline is the backstop.
newest_mtime() {
    local d="$1" m f
    NEWEST=0
    for f in "$d/raw.jsonl" "$d/log.jsonl" "$d/watchdog.log" "$d"/attempt-*/raw.jsonl; do
        [ -f "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null)" || continue
        [ -n "$m" ] || continue
        [ "$m" -gt "$NEWEST" ] && NEWEST="$m"
    done
    [ "$NEWEST" != 0 ] || NEWEST="$(stat -c %Y "$d" 2>/dev/null || printf '0')"
}

classify() {
    local entry="$1" d wl line rc out has_out
    STATUS=""; QUIET=""; LAST=""; DETAIL=""; RUNDIR=""

    if ! resolve_run_dir "$entry"; then
        # No dir yet is normal right after dispatch: an executor still booting must not be
        # declared dead in milliseconds. Grace runs from --since, so no extra option is needed.
        if [ $(( NOW - SINCE )) -gt "$STALL_SEC" ]; then STATUS=MISSING; else STATUS=RUN; fi
        return
    fi
    d="$RUNDIR_PATH"
    RUNDIR="${d##*/}"

    # `cleanup` is written by the EXIT trap on EVERY watchdog exit — success, bail, or an
    # external kill. Across 286 archived logs it appears in 286 while `complete` appears in 246,
    # and 36 of the runs carrying it have neither `final` nor `output.txt`. So `cleanup` says
    # "it stopped"; only its exit code says whether it worked.
    rc=""
    wl="$d/watchdog.log"
    if [ -f "$wl" ]; then
        while IFS= read -r line; do
            case "$line" in *'"event":"cleanup"'*) ;; *) continue ;; esac
            [[ "$line" =~ \"exit_code\":(-?[0-9]+) ]] && rc="${BASH_REMATCH[1]}"
        done < "$wl"
    fi

    out="$d/output.txt"; [ -s "$out" ] || out="$d/final/output.txt"
    has_out=0
    [ -s "$out" ] && has_out=1

    if [ -n "$rc" ] || { [ ! -f "$wl" ] && [ "$has_out" = 1 ]; }; then
        if [ "${rc:-0}" = 0 ] && [ "$has_out" = 1 ]; then
            STATUS=DONE
        else
            STATUS=FAILED
            if [ -f "$d/watchdog.exit" ] &&
               [[ "$(cat "$d/watchdog.exit" 2>/dev/null)" =~ \"reason\":[[:space:]]*\"([a-z_]+)\" ]]; then
                DETAIL="${BASH_REMATCH[1]}"
            fi
        fi
        return
    fi

    newest_mtime "$d"
    QUIET=$(( NOW - NEWEST ))
    printf -v LAST '%(%H:%M:%S)T' "$NEWEST"
    if [ "$QUIET" -gt "$STALL_SEC" ]; then STATUS=SILENT; else STATUS=RUN; fi
}

evaluate() {
    local i entry row
    printf -v NOW '%(%s)T' -1
    ROWS=""
    for i in "${!ROSTER[@]}"; do
        entry="${ROSTER[$i]}"
        classify "$entry"
        STATUSES[$i]="$STATUS"
        row="$(printf '%-8s %-26s %s' "$STATUS" "$entry" "${RUNDIR:-—}")"
        case "$STATUS" in
            SILENT) row="$row  quiet=${QUIET}s last=$LAST" ;;
            RUN)    [ -n "$QUIET" ] && row="$row  quiet=${QUIET}s" ;;
            FAILED) [ -n "$DETAIL" ] && row="$row  $DETAIL" ;;
        esac
        ROWS="$ROWS$row"$'\n'
    done
}

# The baseline is virtual: every roster entry is assumed RUN, so "what changed" is simply
# "what is not RUN". Establishing the baseline from the first evaluation instead would absorb a
# run that was ALREADY dead when the watcher started — and the watcher restarts after every
# event, so that reproduces the original blindness on every restart.
transitions() {
    local i out=""
    for i in "${!ROSTER[@]}"; do
        [ "${STATUSES[$i]}" = "RUN" ] && continue
        out="$out, ${ROSTER[$i]} RUN→${STATUSES[$i]}"
    done
    printf '%s' "${out#, }"
}

all_done() { local s; for s in "${STATUSES[@]}"; do [ "$s" = DONE ] || return 1; done; return 0; }
any_run()  { local s; for s in "${STATUSES[@]}"; do [ "$s" = RUN ] && return 0; done; return 1; }
any_moved() { local s; for s in "${STATUSES[@]}"; do [ "$s" = RUN ] || return 0; done; return 1; }

emit() { printf '%s\n' "$1"; printf '%s' "$ROWS"; exit 0; }

# Same order, now on a loop: all-done, settle, deadline, change. Because the baseline is
# virtual there is no baseline-establishing pass — the first evaluation and every later one
# run identical logic, and the loop needs no "first time" flag.
while :; do
    evaluate
    all_done && emit "ALL_DONE"
    any_run || emit "SETTLED $(transitions)"
    [ "$NOW" -lt "$DEADLINE" ] || emit "DEADLINE"
    any_moved && emit "CHANGED $(transitions)"
    [ "$ONCE" = 0 ] || emit "SNAPSHOT"
    sleep "$POLL_SEC"
done
