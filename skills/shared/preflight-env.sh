#!/usr/bin/env bash
# preflight-env.sh — report what THIS environment can actually do.
#
# Written for a session that did not configure the machine it runs on: a review session in a
# sandbox, whose config.yaml, reachable providers and git remote are not the ones the prompt
# was written against. It prints one row per capability and two SUMMARY lines naming the
# reviewers that can be selected here.
#
# EVERY verdict exits 0 — "nothing is reachable" is an answer, not a failure. A non-zero exit
# means this script is broken (same contract as shared/watch-runs.sh).
#
# Env: PREFLIGHT_HTTP_TIMEOUT (5)  PREFLIGHT_GIT_TIMEOUT (8)
#      PREFLIGHT_CURL_BIN (curl)   PREFLIGHT_GIT_BIN (git)
#      PREFLIGHT_YQ_BIN (yq)       PREFLIGHT_JQ_BIN (jq)
#      PREFLIGHT_EXT_DEPS_BINS ("claude bc python3")
#      PREFLIGHT_SKIP_NETWORK (0)  — 1 skips every network probe (fast re-runs)
set -u

# Bash 4+ required: PROBED_STATUS is an associative array. Exit 64 — not 1 — for the same
# reason watch-runs.sh does: a bare 1 is indistinguishable from a verdict, and this probe's
# whole job is to run on a machine nobody configured (macOS system bash is 3.2). "Every
# verdict exits 0" covers DELIVERED verdicts; a probe that cannot run delivers none.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "preflight-env: bash 4+ required (got ${BASH_VERSION:-unknown}). Install: brew install bash" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SCRIPT_DIR/config-loader.sh"
EXEC_DIR="$SCRIPT_DIR/../ext-claude-exec"
HTTP_TIMEOUT="${PREFLIGHT_HTTP_TIMEOUT:-5}"
GIT_TIMEOUT="${PREFLIGHT_GIT_TIMEOUT:-8}"
CURL_BIN="${PREFLIGHT_CURL_BIN:-curl}"
GIT_BIN="${PREFLIGHT_GIT_BIN:-git}"
YQ_BIN="${PREFLIGHT_YQ_BIN:-yq}"
JQ_BIN="${PREFLIGHT_JQ_BIN:-jq}"
EXT_DEPS_BINS="${PREFLIGHT_EXT_DEPS_BINS:-claude bc python3}"
SKIP_NET="${PREFLIGHT_SKIP_NETWORK:-0}"

# Task 2 sets this to the env file it is about to source; the trap removes it even if the
# probe is interrupted between export and rm. The file carries a provider token. On INT/TERM
# the probe exits NON-zero after cleanup: an interrupt is not a verdict — "every verdict
# exits 0" covers completed runs only. (This is also why probe_provider must never run inside
# a command substitution: CURRENT_ENVF assigned in a subshell never reaches this trap.)
CURRENT_ENVF=""
cleanup() { [ -n "$CURRENT_ENVF" ] && rm -f "$CURRENT_ENVF"; return 0; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

row() { printf '%-16s %-12s %s\n' "$1" "$2" "${3:-}"; }

# ---------------------------------------------------------------- identity
# Which probe is this? The reading session must be able to tell "the probe is old" from
# "the capability is absent", and a stale cache pick must be visible instead of silent.
# sed, not jq: this row prints before the toolchain check.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1)"
row plugin OK "${PLUGIN_VERSION:-unknown} @ $PLUGIN_ROOT"

# ---------------------------------------------------------------- toolchain
# The loader dies rc=1 without yq/jq — the same exit code a rejected config produces. Check
# first, so a dead toolchain cannot impersonate INVALID and send the operator to "fix" a
# healthy config.yaml (row names are canonical yq/jq whatever the override points at).
TOOLCHAIN_OK=1
command -v "$YQ_BIN" >/dev/null 2>&1 || { TOOLCHAIN_OK=0; row yq MISSING "loader cannot run without it (looked for $YQ_BIN)"; }
command -v "$JQ_BIN" >/dev/null 2>&1 || { TOOLCHAIN_OK=0; row jq MISSING "loader cannot run without it (looked for $JQ_BIN)"; }

# ---------------------------------------------------------------- config
CONFIG_STATUS=""
CONFIG_DETAIL=""
MODELS=""
HAS_CODEX=0
HAS_GEMINI=0

if [ "$TOOLCHAIN_OK" = 0 ]; then
    CONFIG_STATUS="UNKNOWN"
    CONFIG_DETAIL="cannot evaluate — loader toolchain missing (see rows above)"
elif [ ! -x "$LOADER" ]; then
    CONFIG_STATUS="MISSING"
    CONFIG_DETAIL="config-loader.sh not found at $LOADER — broken install"
else
    LERR="$(mktemp)"
    # A bare $() swallows the loader's exit code, and rc=2 (no config yet) must not be
    # misread as rc=1 (config rejected) — the same distinction every caller in this repo makes.
    MODELS="$("$LOADER" list-models 2>"$LERR")"; LRC=$?
    case "$LRC" in
        0) CONFIG_STATUS="OK";      CONFIG_DETAIL="$("$LOADER" data-dir 2>/dev/null)/config.yaml"
           # config OK must mean "the orchestrator starts here": mesh-design-review Step 5.0
           # dies on defaults/runtime too, not only on providers/models. One preset name is
           # enough — get-defaults runs validate_defaults for the whole defaults: section.
           # codex/gemini stay out of this gate on purpose: a broken optional section fails
           # its own row (typed getter in Task 3), never the whole environment.
           for CHECK in "get-defaults design_review" "get-flag dispatch_model"; do
               CH_ERR="$(mktemp)"
               # shellcheck disable=SC2086
               if ! "$LOADER" $CHECK >/dev/null 2>"$CH_ERR"; then
                   CONFIG_STATUS="INVALID"; CONFIG_DETAIL="$(head -1 "$CH_ERR")"; MODELS=""
                   rm -f "$CH_ERR"; break
               fi
               rm -f "$CH_ERR"
           done ;;
        2) CONFIG_STATUS="MISSING"; CONFIG_DETAIL="no config.yaml here — the review skills will not start; cp config.example.yaml into the data dir"; MODELS="" ;;
        *) CONFIG_STATUS="INVALID"; CONFIG_DETAIL="$(head -1 "$LERR")"; MODELS="" ;;
    esac
    rm -f "$LERR"
fi
row config "$CONFIG_STATUS" "$CONFIG_DETAIL"

# ---------------------------------------------------------------- built-in claude
row builtin-claude OK "needs no config section (orchestrators still need config.yaml)"

CLAUDE_MODELS=""
if [ "$CONFIG_STATUS" = "OK" ]; then
    CM_ERR="$(mktemp)"
    CLAUDE_MODELS="$("$LOADER" list-claude-models 2>"$CM_ERR")"; CM_RC=$?
    if [ "$CM_RC" -ne 0 ]; then
        # mesh-review Step 1 refuses to start on this same read — "no catalog" would be a lie.
        row claude-models INVALID "$(head -1 "$CM_ERR")"
        CLAUDE_MODELS=""
    elif [ -n "$CLAUDE_MODELS" ]; then
        row claude-models OK "$(printf '%s' "$CLAUDE_MODELS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    else
        row claude-models MISSING "no claude.models catalog — one claude reviewer on the dispatch model"
    fi
    rm -f "$CM_ERR"
    HAS_CODEX="$("$LOADER" get-flag has_codex 2>/dev/null)" || HAS_CODEX=0
    HAS_GEMINI="$("$LOADER" get-flag has_gemini 2>/dev/null)" || HAS_GEMINI=0
else
    row claude-models SKIPPED "no usable config"
fi

# ---------------------------------------------------------------- prerequisites
# TWO lookups, not one. CURL_BIN governs this script's own HTTP checks, but the borrowed
# prechecks resolve `curl` from PATH — so an override that resolves while PATH has no curl
# would let them run, and token-precheck.sh turns command-not-found into HTTP 000 (:43), i.e.
# a NO-NETWORK row fabricated out of a missing binary. Either gap skips the probes outright.
HAVE_CURL=1
CURL_GAP=""
command -v "$CURL_BIN" >/dev/null 2>&1 || CURL_GAP="$CURL_BIN"
if [ "$CURL_BIN" != curl ] && ! command -v curl >/dev/null 2>&1; then
    CURL_GAP="${CURL_GAP:+$CURL_GAP, }curl on PATH (where the prechecks look)"
fi
if [ -n "$CURL_GAP" ]; then
    HAVE_CURL=0
    row curl MISSING "not found: $CURL_GAP — own network probes and provider prechecks skipped, their rows read UNKNOWN"
fi

# ext-claude executors STOP without these (ext-claude-exec SKILL.md Dependencies); a reachable
# endpoint is useless if the executor cannot start. Unquoted on purpose: the list word-splits.
EXT_DEPS_MISSING=""
for T in $EXT_DEPS_BINS; do
    command -v "$T" >/dev/null 2>&1 || EXT_DEPS_MISSING="${EXT_DEPS_MISSING:+$EXT_DEPS_MISSING, }$T"
done
[ -z "$EXT_DEPS_MISSING" ] || row ext-claude-deps MISSING "$EXT_DEPS_MISSING — ext-claude executors cannot run here"

# ---------------------------------------------------------------- CLI reviewers
probe_http() {          # $1 = url; echoes OK | NO-NETWORK | UNKNOWN
    [ "$SKIP_NET" = 0 ] || { echo UNKNOWN; return 0; }
    [ "$HAVE_CURL" = 1 ] || { echo UNKNOWN; return 0; }
    local code
    code="$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" "$1" 2>/dev/null)" \
        || code="000"
    if [ "$code" = "000" ]; then echo NO-NETWORK; else echo OK; fi
}

# A CLI reviewer is offered by the selection UI only when its config section exists
# (mesh-review Step 2 / mesh-design-review Step 5.2) — but its consumers then read the section
# through the TYPED getter (get-codex / get-gemini), which validates and dies on a malformed
# one, while the bare has_* probe validates nothing. Mirror both gates, section first: a codex
# binary with no codex: section is not a reviewer you can pick, however healthy its network is;
# a section the getter rejects is INVALID before any CLI or network claim.
# cli_row prints its row and reports the verdict through the CLI_STATUS global. It must NOT
# echo the verdict: the caller would have to capture its stdout, and the row would vanish into
# that same capture instead of reaching the report.
CLI_STATUS=""
cli_row() {             # $1 = name, $2 = binary, $3 = probe url, $4 = has_section flag
    if [ "$CONFIG_STATUS" != "OK" ]; then
        CLI_STATUS="SKIPPED"
        row "$1" SKIPPED "no usable config — the selection UI cannot offer it"
        return 0
    fi
    if [ "$4" != "1" ]; then
        CLI_STATUS="MISSING"
        row "$1" MISSING "no $1: section in config — the selection UI will not offer it"
        return 0
    fi
    local gerr
    gerr="$(mktemp)"
    if ! "$LOADER" "get-$1" >/dev/null 2>"$gerr"; then
        CLI_STATUS="INVALID"
        row "$1" INVALID "$(head -1 "$gerr")"
        rm -f "$gerr"
        return 0
    fi
    rm -f "$gerr"
    if ! command -v "$2" >/dev/null 2>&1; then
        CLI_STATUS="MISSING"
        row "$1" MISSING "$2 not on PATH"
        return 0
    fi
    # Announce only a probe that will actually happen — same order as the provider loop below.
    # "probing codex…" followed by an UNKNOWN row would describe work the probe never did.
    if [ "$SKIP_NET" = 0 ] && [ "$HAVE_CURL" = 1 ]; then
        echo "probing $1 ($3)…" >&2
    fi
    CLI_STATUS="$(probe_http "$3")"
    case "$CLI_STATUS" in
        OK)         row "$1" OK         "CLI present, $3 answered (heuristic: not an auth check)" ;;
        NO-NETWORK) row "$1" NO-NETWORK "CLI present, $3 silent for ${HTTP_TIMEOUT}s (heuristic)" ;;
        *)          row "$1" UNKNOWN    "CLI present, network not probed (no curl, or PREFLIGHT_SKIP_NETWORK)" ;;
    esac
}

cli_row codex  "codex"  "https://api.openai.com/v1/models"           "$HAS_CODEX";  CODEX_STATUS="$CLI_STATUS"
cli_row gemini "gemini" "https://generativelanguage.googleapis.com/" "$HAS_GEMINI"; GEMINI_STATUS="$CLI_STATUS"

# ---------------------------------------------------------------- providers
# Models of one provider share an endpoint, so probe once per provider and let Task 4 expand
# the verdict back into model ids. Rows appear in order of first appearance in `models`; a
# provider with no models gets no row — nothing it could offer the selection UI.
declare -A PROBED_STATUS=()

# Verdict comes back through globals and probe_provider is called as its own command — NEVER
# inside $(...): an assignment made in a command substitution dies with its subshell, and
# CURRENT_ENVF is what the EXIT trap deletes. cli_row (Task 3) follows the same rule for the
# same reason.
PROV_STATUS=""
PROV_DETAIL=""
probe_provider() {      # $1 = a model id of the provider; sets PROV_STATUS / PROV_DETAIL
    local mid="$1" eerr first out rc rest kind url
    eerr="$(mktemp)"
    # Assigned STRAIGHT into the global, never into a local first: the mode-600 token file
    # exists from the moment export returns, so any window in which the file is on disk and
    # CURRENT_ENVF is not yet set is a window in which a signal leaks it.
    if ! CURRENT_ENVF="$("$LOADER" export "$mid" 2>"$eerr")"; then
        first="$(head -1 "$eerr")"; rm -f "$eerr"
        # export prints the path only on success, so this is normally empty. If a future
        # loader ever printed one and then died, leave it set so the trap deletes the file.
        [ -n "$CURRENT_ENVF" ] && [ -f "$CURRENT_ENVF" ] || CURRENT_ENVF=""
        # cmd_export also dies on invalid providers/models/runtime and "model not found" —
        # only a token complaint may be blamed on the token.
        case "$first" in
            *REPLACE_ME*|*[Tt]oken*) PROV_STATUS="MISSING"; PROV_DETAIL="token not configured for this provider (export refused)" ;;
            *)                       PROV_STATUS="UNKNOWN"; PROV_DETAIL="export refused: ${first:-no reason printed}" ;;
        esac
        return 0
    fi
    rm -f "$eerr"
    if [ -z "$CURRENT_ENVF" ] || [ ! -f "$CURRENT_ENVF" ]; then
        CURRENT_ENVF=""
        PROV_STATUS="UNKNOWN"; PROV_DETAIL="export produced no env file"; return 0
    fi
    # Subshell: the token lives only here; only "rc|kind|base_url" leaves it. base_url is not
    # a secret (the token is a separate field) and it is the first thing the operator wants;
    # kind decides how to word an rc=5. Both prechecks print their diagnosis on stderr, which
    # is discarded — dropping that 2>&1 would put up to 400 bytes of raw provider response on
    # the probe's own stderr (token-precheck.sh:49), which the suite's stderr gate rejects.
    out="$(
        # shellcheck disable=SC1090
        . "$CURRENT_ENVF"
        # :- guards: a truncated env file must degrade to a verdict, not abort the subshell
        # under `set -u` and print bash's own diagnostic on stderr.
        KIND="${CLAUDE_MESH_PROVIDER_KIND:-anthropic-api}"
        case "$KIND" in
            ollama-daemon)
                env -u SKIP_TOKEN_PRECHECK \
                    OLLAMA_PRECHECK_TRIES=1 \
                    OLLAMA_PRECHECK_ATTEMPT_TIMEOUT="$HTTP_TIMEOUT" \
                    OLLAMA_PRECHECK_TAGS_TIMEOUT="$HTTP_TIMEOUT" \
                    "$EXEC_DIR/ollama-precheck.sh" "${ANTHROPIC_BASE_URL:-}" >/dev/null 2>&1
                printf '%s|%s|%s' "$?" "$KIND" "${ANTHROPIC_BASE_URL:-}" ;;
            *)
                env -u SKIP_TOKEN_PRECHECK "$EXEC_DIR/token-precheck.sh" \
                    "${ANTHROPIC_BASE_URL:-}" "${ANTHROPIC_AUTH_TOKEN:-}" "$HTTP_TIMEOUT" >/dev/null 2>&1
                printf '%s|%s|%s' "$?" "$KIND" "${ANTHROPIC_BASE_URL:-}" ;;
        esac
    )"
    # Cleared only once the unlink actually succeeded: otherwise the trap must keep the name
    # so it can try again at exit.
    rm -f "$CURRENT_ENVF" && CURRENT_ENVF=""
    # url takes everything after the SECOND separator, so a '|' inside a base_url survives.
    rc="${out%%|*}"; rest="${out#*|}"; kind="${rest%%|*}"; url="${rest#*|}"
    case "$rc" in
        0) PROV_STATUS="OK";          PROV_DETAIL="endpoint answered, credentials accepted ($url)" ;;
        5) PROV_STATUS="AUTH-FAILED"
           # An ollama daemon has no credential to reject — rc=5 there means the daemon is up
           # but /api/tags errored. "credentials rejected" would send the operator hunting for
           # a token that does not exist.
           if [ "$kind" = "ollama-daemon" ]; then
               PROV_DETAIL="daemon up but /api/tags errored — run: ollama signin ($url)"
           else
               PROV_DETAIL="endpoint answered, credentials rejected ($url)"
           fi ;;
        6) PROV_STATUS="NO-NETWORK";  PROV_DETAIL="$url did not answer within ${HTTP_TIMEOUT}s" ;;
        *) PROV_STATUS="UNKNOWN";     PROV_DETAIL="precheck exited $rc ($url)" ;;
    esac
}

if [ "$CONFIG_STATUS" != "OK" ]; then
    row provider SKIPPED "no usable config — providers not probed"
elif [ -z "$MODELS" ]; then
    row provider MISSING "config has no models"
else
    while IFS='|' read -r MID _LABEL; do
        [ -n "$MID" ] || continue
        PROV="${MID%%/*}"
        [ -z "${PROBED_STATUS[$PROV]+x}" ] || continue
        if [ -n "$EXT_DEPS_MISSING" ]; then
            PROBED_STATUS[$PROV]="MISSING"
            row "provider:$PROV" MISSING "ext-claude prerequisites absent: $EXT_DEPS_MISSING"
            continue
        fi
        if [ "$HAVE_CURL" = 0 ]; then
            PROBED_STATUS[$PROV]="UNKNOWN"
            row "provider:$PROV" UNKNOWN "no curl — endpoint not probed"
            continue
        fi
        if [ "$SKIP_NET" = 1 ]; then
            PROBED_STATUS[$PROV]="UNKNOWN"
            row "provider:$PROV" UNKNOWN "skipped by PREFLIGHT_SKIP_NETWORK"
            continue
        fi
        echo "probing $PROV…" >&2
        probe_provider "$MID"
        row "provider:$PROV" "$PROV_STATUS" "$PROV_DETAIL"
        PROBED_STATUS[$PROV]="$PROV_STATUS"
    done <<< "$MODELS"
fi

# ---------------------------------------------------------------- git, forge CLIs, clipboard
# git remote — local refs are enough for the review skills; this row exists so the reading
# session does not plan a push it cannot make. GIT_TERMINAL_PROMPT=0 + BatchMode: a remote
# that wants credentials or host-key confirmation must answer instantly instead of stalling
# into the timeout and being miscalled NO-NETWORK.
if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
    row git-remote MISSING "$GIT_BIN not on PATH"
elif ! "$GIT_BIN" rev-parse --git-dir >/dev/null 2>&1; then
    row git-remote MISSING "not inside a git repository"
elif ! "$GIT_BIN" remote get-url origin >/dev/null 2>&1; then
    row git-remote MISSING "no 'origin' remote configured"
elif [ "$SKIP_NET" = 1 ]; then
    row git-remote UNKNOWN "skipped by PREFLIGHT_SKIP_NETWORK"
elif ! command -v timeout >/dev/null 2>&1; then
    # timeout(1) is GNU-only and absent on a stock macOS — precisely the unconfigured machine
    # this probe exists for (config-loader.sh:76 fails for the same reason). Without this
    # branch the command-not-found would fail the `if` below and print NO-NETWORK: an endpoint
    # verdict invented out of a missing binary, the same defect the curl gate above prevents.
    row git-remote UNKNOWN "no timeout(1) — ls-remote not run (brew install coreutils)"
else
    if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
       timeout "$GIT_TIMEOUT" "$GIT_BIN" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
        row git-remote OK "origin answered"
    else
        row git-remote NO-NETWORK "origin did not answer (or refused) within ${GIT_TIMEOUT}s — do not plan a push or a PR"
    fi
fi

for TOOL in gh glab; do
    if command -v "$TOOL" >/dev/null 2>&1; then
        row "$TOOL" OK "on PATH (presence only — not an auth check)"
    else
        row "$TOOL" MISSING "not on PATH"
    fi
done

CLIP=""
for C in xclip xsel pbcopy; do
    command -v "$C" >/dev/null 2>&1 && { CLIP="$C"; break; }
done
if [ -n "$CLIP" ]; then
    row clipboard OK "$CLIP"
else
    row clipboard MISSING "no xclip/xsel/pbcopy — print generated prompts into the chat"
fi
