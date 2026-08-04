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
# Normalise ONCE, here, so the flag cannot be half-honoured. Its three consumers do not test it
# the same way — probe_http asks "is it 0?" (skips on anything else), the provider loop and the
# git row ask "is it 1?" (probe on anything else) — so PREFLIGHT_SKIP_NETWORK=true used to skip
# the CLI probes and still spend the git budget on the operator's real remote. Anything that is
# not exactly 0 now means 1: a flag whose whole purpose is "touch nothing" must fail toward
# touching nothing. (Fixing it here rather than at the three call sites keeps them literally as
# the plan wrote them, and keeps the next consumer from having to know which convention to pick.)
[ "$SKIP_NET" = 0 ] || SKIP_NET=1

# Task 2 sets this to the env file it is about to source; the trap removes it even if the
# probe is interrupted between export and rm. The file carries a provider token. On INT/TERM
# the probe exits NON-zero after cleanup: an interrupt is not a verdict — "every verdict
# exits 0" covers completed runs only. (This is also why probe_provider must never run inside
# a command substitution: CURRENT_ENVF assigned in a subshell never reaches this trap.)
CURRENT_ENVF=""
# SC2317: reached only through the traps below, and since the summary section ends the file in
# an explicit `exit 0` shellcheck 0.9's reachability pass stops seeing that. Deleting the body
# on the strength of that note would leave a mode-600 token file behind on every interrupt.
# shellcheck disable=SC2317
cleanup() { [ -n "$CURRENT_ENVF" ] && rm -f "$CURRENT_ENVF"; return 0; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 18, not 16: `provider:deepseek` is 17 characters and any 8-character provider id overflows a
# 16-wide pad, which pushes the status column right on exactly the row a reader is scanning for
# a red verdict. Every gate that parses this table splits on whitespace (awk $1/$2), so the pad
# is presentation only — but this table IS the deliverable the generated prompts tell a session
# to print verbatim, so a ragged column is a defect in the product, not a cosmetic detail.
row() { printf '%-18s %-12s %s\n' "$1" "$2" "${3:-}"; }

# EVERY temp file in this probe comes from here, and every caller checks the return. An
# unwritable or full TMPDIR is not exotic on the machines this probe exists for, and an
# unchecked mktemp fails in the one direction this file never tolerates: the empty name turns
# `cmd 2>"$f"` into an ambiguous redirect, which fails the command it was only supposed to
# watch — so the probe reports a verdict about a config it never read, and prints mktemp's and
# head's own complaints on the stderr that must carry probe chatter and nothing else.
# The emptiness test is not redundant with the exit code: a name is only usable if BOTH hold.
mktemp_or_fail() {      # echoes a temp-file path; non-zero and silent when it cannot
    local f
    f="$(mktemp 2>/dev/null)" || return 1
    [ -n "$f" ] || return 1
    printf '%s\n' "$f"
}

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
# WHICH tool is missing decides the fix the summary hints at the bottom — `pipx install yq`
# (Python-yq specifically) is not the same advice as `apt install jq`, and by then the rows
# printed here can no longer be read back.
TOOLCHAIN_MISSING=""
command -v "$YQ_BIN" >/dev/null 2>&1 || { TOOLCHAIN_OK=0; TOOLCHAIN_MISSING="${TOOLCHAIN_MISSING:+$TOOLCHAIN_MISSING, }yq"; row yq MISSING "loader cannot run without it (looked for $YQ_BIN)"; }
command -v "$JQ_BIN" >/dev/null 2>&1 || { TOOLCHAIN_OK=0; TOOLCHAIN_MISSING="${TOOLCHAIN_MISSING:+$TOOLCHAIN_MISSING, }jq"; row jq MISSING "loader cannot run without it (looked for $JQ_BIN)"; }

# ---------------------------------------------------------------- config
CONFIG_STATUS=""
CONFIG_DETAIL=""
MODELS=""
HAS_CODEX=0
HAS_GEMINI=0
# WHICH way the probe failed to decide. UNKNOWN has more than one cause and their fixes have
# nothing in common, so the blocker hint at the bottom branches on this rather than guessing
# from TOOLCHAIN_MISSING — see the case there. Set it wherever CONFIG_STATUS becomes UNKNOWN.
CONFIG_UNKNOWN_CAUSE=""

if [ "$TOOLCHAIN_OK" = 0 ]; then
    CONFIG_STATUS="UNKNOWN"
    CONFIG_UNKNOWN_CAUSE="toolchain"
    CONFIG_DETAIL="cannot evaluate — loader toolchain missing (see rows above)"
elif [ ! -x "$LOADER" ]; then
    CONFIG_STATUS="MISSING"
    CONFIG_DETAIL="config-loader.sh not found at $LOADER — broken install"
elif ! LERR="$(mktemp_or_fail)"; then
    # Before the loader is invoked, so nothing here is a claim about config.yaml: without the
    # file to catch its stderr the read below would fail on the redirect alone and be reported
    # as INVALID — a healthy config accused of being malformed, with no detail to argue back.
    CONFIG_STATUS="UNKNOWN"
    CONFIG_UNKNOWN_CAUSE="tmpfile"
    CONFIG_DETAIL="cannot evaluate — no temp file could be created (TMPDIR unwritable or full)"
else
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
               # Same guard as the LERR one above, and it matters more here: this branch is
               # reached only after the loader ANSWERED, so an OK is already on the table and
               # an unchecked failure would downgrade a config that just proved itself.
               if ! CH_ERR="$(mktemp_or_fail)"; then
                   CONFIG_STATUS="UNKNOWN"; CONFIG_UNKNOWN_CAUSE="tmpfile"
                   CONFIG_DETAIL="cannot finish the check — no temp file could be created (TMPDIR unwritable or full)"
                   MODELS=""; break
               fi
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
# A rejected catalog and an absent one both leave CLAUDE_MODELS empty, and the summary at the
# bottom has to tell them apart: "no catalog" means one claude reviewer on the dispatch model,
# "rejected" means the orchestrator exits on this very read and offers nothing at all.
CLAUDE_CATALOG_OK=1
if [ "$CONFIG_STATUS" = "OK" ]; then
    # CLAUDE_CATALOG_OK stays 1 deliberately: 0 means "both orchestrators exit on this read",
    # which is a claim about the section's CONTENTS, and its blocker says the section is
    # rejected. A temp file we could not create is no evidence for that accusation. The summary
    # then falls back to a bare `claude` — one reviewer on the dispatch model, the only claim
    # that needs no catalog — exactly as it does when there is no catalog at all.
    if ! CM_ERR="$(mktemp_or_fail)"; then
        row claude-models UNKNOWN "cannot create a temp file (TMPDIR full or unwritable) — catalog not read"
        CLAUDE_MODELS=""
    else
        CLAUDE_MODELS="$("$LOADER" list-claude-models 2>"$CM_ERR")"; CM_RC=$?
        if [ "$CM_RC" -ne 0 ]; then
            # mesh-review Step 1 refuses to start on this same read — "no catalog" would be a lie.
            row claude-models INVALID "$(head -1 "$CM_ERR")"
            CLAUDE_MODELS=""
            CLAUDE_CATALOG_OK=0
        elif [ -n "$CLAUDE_MODELS" ]; then
            row claude-models OK "$(printf '%s' "$CLAUDE_MODELS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
        else
            row claude-models MISSING "no claude.models catalog — one claude reviewer on the dispatch model"
        fi
        rm -f "$CM_ERR"
    fi
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
    # A three-digit code is the ONLY evidence of an answer. An `else echo OK` would turn a
    # curl that exits 0 printing nothing — a wrapper, a stub, a future --write-out change —
    # into a green verdict, which is the one direction this file never fabricates: every other
    # guard here (HAVE_CURL, the timeout(1) check below) degrades toward UNKNOWN instead.
    case "$code" in
        000)             echo NO-NETWORK ;;
        [0-9][0-9][0-9]) echo OK ;;
        *)               echo UNKNOWN ;;
    esac
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
    # Checked, because the failure is silent and ugly: gerr="" makes `2>"$gerr"` an ambiguous
    # redirect, which fails the command, which makes the branch below look like a REJECTED
    # section — and then `head -1 ""` prints its own complaint on the probe's stderr. A full
    # TMPDIR must not be reported as a malformed config. (This site is where the guard was
    # written first; mktemp_or_fail is that check, hoisted so the other four cannot skip it.)
    if ! gerr="$(mktemp_or_fail)"; then
        CLI_STATUS="UNKNOWN"
        row "$1" UNKNOWN "cannot create a temp file (TMPDIR full or unwritable) — section not validated"
        return 0
    fi
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
    # Unlike the sites above, the verdict here was already honest without the guard — export
    # would fail on the redirect and land in the UNKNOWN arm below. What the check buys is the
    # stderr: three raw mktemp/head diagnostics on the stream the suite gates on, from a probe
    # whose stdout is meant to be the whole report.
    if ! eerr="$(mktemp_or_fail)"; then
        PROV_STATUS="UNKNOWN"
        PROV_DETAIL="cannot create a temp file (TMPDIR full or unwritable) — endpoint not probed"
        return 0
    fi
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

# ---------------------------------------------------------------- summary
# The two lines the reading session actually acts on. Names are spelled exactly as the
# selection UI of /mesh-review and /mesh-design-review spells them, so nothing has to be
# mapped: `claude:opus`-style entries per catalog model (plain `claude` only in the
# no-catalog fallback — the confirmation page uses the same spelling), `codex`, `gemini`,
# and model ids like `zai/glm`.
AVAIL=""
UNAVAIL=""

# TWO reads decide whether the orchestrators ever REACH their selection step, and neither of
# them belongs to a single reviewer: config.yaml (mesh-review Step 0/1, mesh-design-review
# Step 5.0) and the claude: catalog (commands/mesh-review.md:71 and
# skills/mesh-design-review/SKILL.md:256 both `|| exit 1` on the same list-claude-models read
# the claude-models row reports above). Either one exits BEFORE anything is offered, so either
# one makes EVERY reviewer unselectable — including a provider whose endpoint just answered.
# Offering one here sends the reading session into a dead end it cannot debug from the table.
#
# The hint below is a LITERALLY EXECUTABLE command, so it must branch on WHICH state produced
# the block — `CONFIG_STATUS != OK` covers three of them and `cp config.example.yaml …` is
# right in only one. For INVALID and UNKNOWN a real config.yaml exists (in the UNKNOWN case
# possibly a perfectly good one, on a machine that merely lacks yq) and that command overwrites
# it, tokens and all. config.yaml is user-owned and agents never edit it (commands/mesh-review.md,
# Step 1), so a table the generated prompts tell a session to print verbatim must not carry an
# instruction to clobber it. It is also the distinction Task 1's config row exists to draw:
# "pipx install yq" and "edit a healthy config" are different days' work.
BLOCKER=""
BLOCKER_HINT=""
DATA_DIR="<plugin-data-dir>"
if [ "$CONFIG_STATUS" != "OK" ] || [ "$CLAUDE_CATALOG_OK" = 0 ]; then
    # Only a blocked run needs a path, and only a blocked run pays for the extra loader start.
    # Guarded because data-dir prints nothing when the loader is absent or its toolchain dead,
    # and a hint whose path starts at the filesystem root points at a file nobody has.
    DD="$("$LOADER" data-dir 2>/dev/null)"
    [ -z "$DD" ] || DATA_DIR="$DD"
fi
case "$CONFIG_STATUS" in
    OK) ;;
    MISSING)
        BLOCKER="config.yaml required for the orchestrators to start"
        BLOCKER_HINT="cp config.example.yaml $DATA_DIR/config.yaml — the review skills need it even for the built-in claude reviewer" ;;
    INVALID)
        BLOCKER="config.yaml is rejected — see the config row"
        BLOCKER_HINT="edit $DATA_DIR/config.yaml to fix what the config row reports — do NOT overwrite it with config.example.yaml: it is user-owned and holds your provider tokens" ;;
    UNKNOWN)
        # UNKNOWN: the loader never ran, so nothing above is a statement about the file's
        # contents. MORE THAN ONE cause reaches here and their fixes have nothing in common —
        # an operator whose TMPDIR is unwritable must not be sent to install yq, and this arm
        # used to be spelled `*)` and say exactly that to both. Branch on the cause recorded
        # where the verdict was made, never re-derive it here: a third cause that forgets to
        # set it must fall through to "read the row", not inherit whichever advice is last.
        BLOCKER="config state could not be evaluated"
        U_FIX=""
        case "$CONFIG_UNKNOWN_CAUSE" in
            toolchain)
                # Naming the tool matters more than usual here — Go-yq is a DIFFERENT program
                # that config-loader.sh rejects on sight (config-loader.sh:71), so "install yq"
                # alone sends a fair number of people to the wrong binary.
                T_FIX=""
                case "$TOOLCHAIN_MISSING" in *yq*) T_FIX="pipx install yq (Python-yq — NOT brew/Go-yq)" ;; esac
                case "$TOOLCHAIN_MISSING" in *jq*) T_FIX="${T_FIX:+$T_FIX; }apt install jq (or brew install jq)" ;; esac
                U_FIX="install the loader toolchain — ${T_FIX:-see README Dependencies}" ;;
            tmpfile)
                U_FIX="make TMPDIR writable, free space on it, or point TMPDIR at a directory that has both" ;;
            *)
                U_FIX="fix what the config row above reports" ;;
        esac
        BLOCKER_HINT="$U_FIX — then re-run; $DATA_DIR/config.yaml was never read, so nothing above says anything about its contents" ;;
    *)
        # Defence in depth: every member of the closed status set is spelled out above, so this
        # arm is unreachable today. It exists because the alternative to an unreachable arm is a
        # silent one — a status added later would leave BLOCKER empty and the summary would
        # cheerfully offer reviewers the orchestrator never reaches.
        BLOCKER="config state is not usable ($CONFIG_STATUS)"
        BLOCKER_HINT="see the config row above — this probe has no advice for that state" ;;
esac
if [ -z "$BLOCKER" ] && [ "$CLAUDE_CATALOG_OK" = 0 ]; then
    BLOCKER="the claude: section is rejected and both orchestrators exit on that read"
    BLOCKER_HINT="fix the claude: section of $DATA_DIR/config.yaml (the claude-models row above carries the validator's reason) — both orchestrators exit on that read before offering anything"
fi

add_unavail() { if [ -z "$UNAVAIL" ]; then UNAVAIL="$1"; else UNAVAIL="$UNAVAIL, $1"; fi; }
add_avail() {
    # One switch instead of one test per reviewer type: while a blocker stands nothing is
    # selectable, whatever the individual rows say. Redirecting HERE rather than at each call
    # site means a reviewer type added to this section later cannot forget the gate.
    if [ -n "$BLOCKER" ]; then add_unavail "$1 (blocked)"; return 0; fi
    if [ -z "$AVAIL" ]; then AVAIL="$1"; else AVAIL="$AVAIL, $1"; fi
}

# claude is unconditionally available as a REVIEWER — it needs no config section of its own —
# but see BLOCKER above: promising it in an environment where the orchestrator exits before the
# selection UI is the one thing this line must never do. The one-line fix is hinted at the end.
if [ -z "$BLOCKER" ]; then
    if [ -n "$CLAUDE_MODELS" ]; then
        while IFS= read -r CM; do
            [ -n "$CM" ] && add_avail "claude:$CM"
        done <<< "$CLAUDE_MODELS"
    else
        add_avail claude
    fi
else
    add_unavail "claude ($BLOCKER)"
fi

# if/else, not `A && add_avail || add_unavail`: in that form C also runs when B fails, so the
# day add_avail grows a non-zero path a reviewer gets listed on BOTH lines. Same reason cli_row
# spells out its progress gate rather than chaining it (SC2015).
if [ "$CODEX_STATUS"  = "OK" ]; then add_avail codex;  else add_unavail "codex ($CODEX_STATUS)";   fi
if [ "$GEMINI_STATUS" = "OK" ]; then add_avail gemini; else add_unavail "gemini ($GEMINI_STATUS)"; fi

if [ -n "$MODELS" ]; then
    while IFS='|' read -r MID _LABEL; do
        [ -n "$MID" ] || continue
        PROV="${MID%%/*}"
        PSTATUS="${PROBED_STATUS[$PROV]:-UNKNOWN}"
        if [ "$PSTATUS" = "OK" ]; then add_avail "$MID"; else add_unavail "$MID ($PSTATUS)"; fi
    done <<< "$MODELS"
fi

echo
printf 'SUMMARY available: %s\n' "${AVAIL:-—}"
printf 'SUMMARY unavailable: %s\n' "${UNAVAIL:-—}"
# PREFLIGHT_SKIP_NETWORK turns every network verdict into UNKNOWN, and UNKNOWN is not a
# degraded OK: on a fast re-run a perfectly working machine reports as "claude only". The
# reading session did not set that flag and cannot see it from the table, so the summary says
# so itself. SUMMARY-prefixed like the lines above — that is what the report's non-row prose
# is prefixed with, and what the suite's closed-set gate skips.
#
# Gated on an (UNKNOWN) actually having been printed, not on the flag alone: with no usable
# config every entry reads (SKIPPED) and there is no network verdict to qualify, so the note
# would point at a marker that is not on the page.
SAW_UNKNOWN=0
case "$UNAVAIL" in *"(UNKNOWN)"*) SAW_UNKNOWN=1 ;; esac
if [ "$SKIP_NET" = 1 ] && [ "$SAW_UNKNOWN" = 1 ]; then
    printf 'SUMMARY note: PREFLIGHT_SKIP_NETWORK was set, so nothing was probed — every (UNKNOWN) above is unestablished, not broken; re-run without it before concluding a reviewer is unusable\n'
fi
# The presets, in the same UI spelling — "default mode is safe here" becomes a mechanical
# check: every name on a defaults line must appear in SUMMARY available. jq is present
# whenever CONFIG_STATUS=OK (the toolchain gate ran first).
for PRESET in design_review code_review; do
    DLIST="—"
    if [ "$CONFIG_STATUS" = "OK" ] && DJ="$("$LOADER" get-defaults "$PRESET" 2>/dev/null)"; then
        DLIST="$("$JQ_BIN" -r '
            ((.builtin // []) | map(select(. != "claude"))) +
            (if ((.builtin // []) | index("claude")) then
                 (if ((.claude_models // []) | length) > 0
                  then (.claude_models | map("claude:" + .))
                  else ["claude"] end)
             else [] end) +
            (.models // []) | join(", ")' <<<"$DJ")"
        # "—" alone would be read as "not answered", which is what the no-config case above
        # means. A preset that WAS read and is empty is a different fact: `default` mode will
        # refuse to start (mesh-design-review Step 5.1), and the fix is to write the preset.
        [ -n "$DLIST" ] || DLIST="— (preset empty)"
    fi
    printf 'SUMMARY defaults %s: %s\n' "$PRESET" "$DLIST"
done
# One `hint:` line, whose text was chosen with the blocker above. The literal `hint: ` prefix is
# load-bearing: the suite's closed-set gate skips this line on `$1 != "hint:"`, and $1 alone —
# the second word differs per state.
if [ -n "$BLOCKER" ]; then
    printf 'hint: %s\n' "$BLOCKER_HINT"
fi
exit 0
