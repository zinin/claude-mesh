#!/usr/bin/env bash
# ollama-precheck.sh — verify ollama daemon is reachable and signed in.
#
# Usage: ollama-precheck.sh <base_url>
# Exit:
#   0 — daemon up and /api/tags reachable
#   5 — auth/signin missing or expired
#   6 — daemon unreachable after the retry budget (3×2s by default)
#
# Env (defaults reproduce the original fixed 3×2s budget exactly):
#   OLLAMA_PRECHECK_TRIES (3)            — daemon ping attempts
#   OLLAMA_PRECHECK_ATTEMPT_TIMEOUT (2)  — --max-time per ping attempt, in seconds
#   OLLAMA_PRECHECK_TAGS_TIMEOUT (5)     — --max-time for the /api/tags read
# A caller that must answer inside a fixed budget (shared/preflight-env.sh) sets TRIES=1 and
# both timeouts to its own budget; the inter-attempt sleep is then skipped as well.
#
# Per design Section 6.1.

set -u
BASE_URL="${1:-}"
[ -n "$BASE_URL" ] || { echo "ollama-precheck: base_url required" >&2; exit 2; }

TRIES="${OLLAMA_PRECHECK_TRIES:-3}"
ATTEMPT_TIMEOUT="${OLLAMA_PRECHECK_ATTEMPT_TIMEOUT:-2}"
TAGS_TIMEOUT="${OLLAMA_PRECHECK_TAGS_TIMEOUT:-5}"
# These three became a public interface when preflight-env.sh started setting them, so an
# operator can now type them by hand — and unvalidated they fail in the direction this check
# exists to prevent. TRIES=0 skips the loop entirely and reports UNREACHABLE "after 0x2s"
# without ever contacting the daemon; a non-numeric value adds `[: abc: integer expression
# expected` to stderr and still produces a confident verdict. A positive integer or the
# documented default, exactly as preflight-env.sh normalises its own budgets.
case "$TRIES"           in ''|*[!0-9]*|0) TRIES=3 ;; esac
case "$ATTEMPT_TIMEOUT" in ''|*[!0-9]*|0) ATTEMPT_TIMEOUT=2 ;; esac
case "$TAGS_TIMEOUT"    in ''|*[!0-9]*|0) TAGS_TIMEOUT=5 ;; esac

# Ping with cold-start retry (TRIES attempts × ATTEMPT_TIMEOUT)
DAEMON_OK=0
i=1
while [ "$i" -le "$TRIES" ]; do
    if curl --max-time "$ATTEMPT_TIMEOUT" -sf "$BASE_URL/" >/dev/null 2>&1; then
        DAEMON_OK=1; break
    fi
    # No sleep after the final attempt — with TRIES=1 there is none at all.
    [ "$i" -lt "$TRIES" ] && sleep 2
    i=$((i+1))
done

if [ "$DAEMON_OK" != "1" ]; then
    echo "ollama-precheck: ENDPOINT UNREACHABLE ($BASE_URL) after ${TRIES}×${ATTEMPT_TIMEOUT}s retry" >&2
    echo "  Start it: ollama serve  (or: systemctl start ollama)" >&2
    exit 6
fi

# /api/tags probes auth state
if ! curl --max-time "$TAGS_TIMEOUT" -sf "$BASE_URL/api/tags" >/dev/null 2>&1; then
    echo "ollama-precheck: AUTH FAILED (daemon up but /api/tags errored)" >&2
    echo "  Run: ollama signin" >&2
    exit 5
fi

exit 0
