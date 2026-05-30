#!/usr/bin/env bash
# token-precheck.sh — fast validation of ANTHROPIC_AUTH_TOKEN against an
# Anthropic-compatible /v1/messages endpoint. Catches expired/invalid tokens
# in ~1.5s instead of waiting 3+ minutes for claude CLI's internal retries.
#
# Usage: token-precheck.sh <BASE_URL> <TOKEN> [TIMEOUT_SECS]
#
# Exit codes:
#   0 — token appears valid (any non-401/403/000 response, e.g. 200/400/422)
#   5 — authentication failed (HTTP 401 or 403)
#   6 — endpoint unreachable (curl error / HTTP 000)
#
# Env:
#   SKIP_TOKEN_PRECHECK=1 — skip entirely, exit 0
#
# Probe strategy: POST /v1/messages with body `{}`.
#  - If the token is bad, providers respond 401/403 *before* validating the
#    body (verified for dashscope, z.ai, deepseek).
#  - If the token is good, the body validator fires (400/422 etc.).
#  - This means a non-auth 4xx is a *positive* signal — auth passed.

set -euo pipefail

if [ "${SKIP_TOKEN_PRECHECK:-0}" = "1" ]; then
  echo "token-precheck: skipped (SKIP_TOKEN_PRECHECK=1)" >&2
  exit 0
fi

URL="${1:?Usage: $0 <BASE_URL> <TOKEN> [TIMEOUT_SECS]}"
TOKEN="${2:?Usage: $0 <BASE_URL> <TOKEN> [TIMEOUT_SECS]}"
TIMEOUT="${3:-30}"

BODY_FILE=$(mktemp -t ext-claude-precheck.XXXXXX)
trap 'rm -f "$BODY_FILE"' EXIT

HTTP_CODE=$(curl -sS -o "$BODY_FILE" -w "%{http_code}" \
  --max-time "$TIMEOUT" \
  -X POST "${URL%/}/v1/messages" \
  -H "x-api-key: $TOKEN" \
  -H "authorization: Bearer $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{}' 2>/dev/null) || HTTP_CODE="000"

case "$HTTP_CODE" in
  401|403)
    echo "token-precheck: AUTH FAILED (HTTP $HTTP_CODE)" >&2
    echo "  endpoint: ${URL%/}/v1/messages" >&2
    echo "  response: $(head -c 400 "$BODY_FILE" 2>/dev/null)" >&2
    exit 5
    ;;
  000)
    echo "token-precheck: ENDPOINT UNREACHABLE (curl error or timeout >${TIMEOUT}s)" >&2
    echo "  endpoint: ${URL%/}/v1/messages" >&2
    exit 6
    ;;
  *)
    echo "token-precheck: OK (HTTP $HTTP_CODE) — token appears valid" >&2
    exit 0
    ;;
esac
