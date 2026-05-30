#!/usr/bin/env bash
# ollama-precheck.sh — verify ollama daemon is reachable and signed in.
#
# Usage: ollama-precheck.sh <base_url>
# Exit:
#   0 — daemon up and /api/tags reachable
#   5 — auth/signin missing or expired
#   6 — daemon unreachable after 3×2s retry
#
# Per design Section 6.1.

set -u
BASE_URL="${1:-}"
[ -n "$BASE_URL" ] || { echo "ollama-precheck: base_url required" >&2; exit 2; }

# Ping with cold-start retry (3 attempts × 2s)
DAEMON_OK=0
for i in 1 2 3; do
    if curl --max-time 2 -sf "$BASE_URL/" >/dev/null 2>&1; then
        DAEMON_OK=1; break
    fi
    [ "$i" -lt 3 ] && sleep 2
done

if [ "$DAEMON_OK" != "1" ]; then
    echo "ollama-precheck: ENDPOINT UNREACHABLE ($BASE_URL) after 3×2s retry" >&2
    echo "  Start it: ollama serve  (or: systemctl start ollama)" >&2
    exit 6
fi

# /api/tags probes auth state
if ! curl --max-time 5 -sf "$BASE_URL/api/tags" >/dev/null 2>&1; then
    echo "ollama-precheck: AUTH FAILED (daemon up but /api/tags errored)" >&2
    echo "  Run: ollama signin" >&2
    exit 5
fi

exit 0
