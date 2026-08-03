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
# curl governs only this script's own HTTP checks; the borrowed prechecks resolve curl from
# PATH, so when the resolved curl is absent the provider probes are skipped outright — a
# precheck with no curl would fake NO-NETWORK out of a command-not-found.
HAVE_CURL=1
command -v "$CURL_BIN" >/dev/null 2>&1 || HAVE_CURL=0
[ "$HAVE_CURL" = 1 ] || row curl MISSING "own network probes and provider prechecks skipped — their rows read UNKNOWN"

# ext-claude executors STOP without these (ext-claude-exec SKILL.md Dependencies); a reachable
# endpoint is useless if the executor cannot start. Unquoted on purpose: the list word-splits.
EXT_DEPS_MISSING=""
for T in $EXT_DEPS_BINS; do
    command -v "$T" >/dev/null 2>&1 || EXT_DEPS_MISSING="${EXT_DEPS_MISSING:+$EXT_DEPS_MISSING, }$T"
done
[ -z "$EXT_DEPS_MISSING" ] || row ext-claude-deps MISSING "$EXT_DEPS_MISSING — ext-claude executors cannot run here"

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
    local mid="$1" envf eerr first out rc url
    eerr="$(mktemp)"
    if ! envf="$("$LOADER" export "$mid" 2>"$eerr")"; then
        first="$(head -1 "$eerr")"; rm -f "$eerr"
        # cmd_export also dies on invalid providers/models/runtime and "model not found" —
        # only a token complaint may be blamed on the token.
        case "$first" in
            *REPLACE_ME*|*[Tt]oken*) PROV_STATUS="MISSING"; PROV_DETAIL="token not configured for this provider (export refused)" ;;
            *)                       PROV_STATUS="UNKNOWN"; PROV_DETAIL="export refused: ${first:-no reason printed}" ;;
        esac
        return 0
    fi
    rm -f "$eerr"
    if [ -z "$envf" ] || [ ! -f "$envf" ]; then
        PROV_STATUS="UNKNOWN"; PROV_DETAIL="export produced no env file"; return 0
    fi
    CURRENT_ENVF="$envf"
    # Subshell: the token lives only here; only "rc|base_url" leaves it. base_url is not a
    # secret (the token is a separate field) and it is the first thing the operator wants.
    # Both prechecks print their diagnosis on stderr, which is discarded.
    out="$(
        # shellcheck disable=SC1090
        . "$envf"
        case "${CLAUDE_MESH_PROVIDER_KIND:-anthropic-api}" in
            ollama-daemon)
                env -u SKIP_TOKEN_PRECHECK \
                    OLLAMA_PRECHECK_TRIES=1 \
                    OLLAMA_PRECHECK_ATTEMPT_TIMEOUT="$HTTP_TIMEOUT" \
                    OLLAMA_PRECHECK_TAGS_TIMEOUT="$HTTP_TIMEOUT" \
                    "$EXEC_DIR/ollama-precheck.sh" "$ANTHROPIC_BASE_URL" >/dev/null 2>&1
                printf '%s|%s' "$?" "$ANTHROPIC_BASE_URL" ;;
            *)
                env -u SKIP_TOKEN_PRECHECK "$EXEC_DIR/token-precheck.sh" \
                    "$ANTHROPIC_BASE_URL" "$ANTHROPIC_AUTH_TOKEN" "$HTTP_TIMEOUT" >/dev/null 2>&1
                printf '%s|%s' "$?" "$ANTHROPIC_BASE_URL" ;;
        esac
    )"
    rm -f "$envf"; CURRENT_ENVF=""
    rc="${out%%|*}"; url="${out#*|}"
    case "$rc" in
        0) PROV_STATUS="OK";          PROV_DETAIL="endpoint answered, credentials accepted ($url)" ;;
        5) PROV_STATUS="AUTH-FAILED"; PROV_DETAIL="endpoint answered, credentials rejected ($url)" ;;
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
