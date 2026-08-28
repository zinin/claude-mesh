#!/usr/bin/env bash
# Live smoke test for the grok invocation grok-exec/SKILL.md prescribes.
#
# OPT-IN: it spends real API budget, so it runs only with GROK_SMOKE=1 and skips otherwise.
# What it pins is the CONTRACT the rest of the plugin is built on — that the flags in SKILL.md
# are accepted, that the stream is the Anthropic wire format, and that extract-result.py can
# read it. Nothing here asserts what the model SAYS.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$TESTS_DIR/.."

if [ "${GROK_SMOKE:-0}" != "1" ]; then
    echo "SKIP: set GROK_SMOKE=1 to run the live grok smoke test (it spends API budget)"
    exit 0
fi
for REQ in grok jq python3; do
    # A missing grok binary is "the user did not opt in" -> SKIP. A missing jq or python3 is a
    # broken environment, and reporting that as SKIP hides it: the suite would look clean on a
    # machine where nothing could have run.
    command -v "$REQ" >/dev/null 2>&1 || { echo "FAIL: $REQ not installed — this is an environment defect, not an opt-out"; exit 1; }
done

FAIL=0
PASS=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d)"
# Keep the evidence when something failed — a red smoke test whose stream was deleted is a
# report nobody can act on.
cleanup() {
    if [ "$FAIL" = "0" ]; then rm -rf "$WORK"; else echo "  (kept for inspection: $WORK)"; fi
}
trap cleanup EXIT
printf 'alpha\n' > "$WORK/a.txt"
cat > "$WORK/prompt.md" << 'PROMPT'
List the files in your working directory using your tools, then reply with their names.
PROMPT

# Run in the BACKGROUND so the stream can be sampled while it is still being written. A single
# final size proves nothing about buffering — a fully buffered stream also ends up large — and
# the whole stall-detection design rests on the file GROWING while the run is live. The rc
# marker file, not `kill -0`, is what tells the sampler the run is over: a finished child is a
# zombie until reaped, and `kill -0` still succeeds on one.
( cd "$WORK" && timeout 300 grok \
    --prompt-file "$WORK/prompt.md" \
    --output-format streaming-messages-json \
    --permission-mode bypassPermissions \
    --no-plan \
    > "$WORK/raw.jsonl" 2> "$WORK/stderr.txt"; echo $? > "$WORK/rc" ) &

SZ1=""
SZ2=""
SECS=0
while [ ! -f "$WORK/rc" ] && [ "$SECS" -lt 320 ]; do
    sleep 3
    SECS=$((SECS+3))
    CUR=$(wc -c < "$WORK/raw.jsonl" 2>/dev/null || echo 0)
    if [ -z "$SZ1" ]; then
        if [ "$CUR" -gt 0 ]; then SZ1="$CUR"; fi
        continue
    fi
    if [ "$CUR" -gt "$SZ1" ]; then SZ2="$CUR"; break; fi
done
wait
RC=$(cat "$WORK/rc" 2>/dev/null || echo 99)

[ "$RC" = 0 ] && ok "grok accepts the SKILL.md flag set (rc=0)" || bad "grok exited rc=$RC — $(head -2 "$WORK/stderr.txt")"

grep -q '"type":"system"' "$WORK/raw.jsonl" && ok "stream opens with a system event" || bad "no system event in the stream"
jq -Rr 'fromjson? | objects | select(.type=="result")' "$WORK/raw.jsonl" 2>/dev/null | grep -q . && ok "stream carries a terminal result event" || bad "no result event — verify-delegation would score this STALLED"

NT="$(grep '"type":"result"' "$WORK/raw.jsonl" | jq -Rr 'fromjson? | objects | select(.type=="result" and .is_error==false) | .num_turns' | sort -n | tail -1)"
case "$NT" in
    ''|*[!0-9]*) bad "result event carries no integer num_turns (got '$NT') — the guard needs it" ;;
    *) [ "$NT" -gt 1 ] && ok "num_turns=$NT proves agentic work" || bad "num_turns=$NT — the model used no tools" ;;
esac

grep -q '"type":"tool_use"' "$WORK/raw.jsonl" && ok "tool_use blocks are present" || bad "no tool_use block in the stream"

python3 "$SHARED/extract-result.py" "$WORK" >/dev/null 2>&1 \
    && [ -s "$WORK/output.txt" ] \
    && ok "extract-result.py reads the grok stream into output.txt" \
    || bad "extract-result.py produced no output.txt"

bash "$SHARED/stream-json-report.sh" "$WORK/raw.jsonl" "$WORK/report.md" grok "Grok Execution Report" smoke >/dev/null 2>&1 \
    && [ -s "$WORK/report.md" ] \
    && ok "stream-json-report.sh renders a report" \
    || bad "no report.md rendered"

echo ""
if [ -n "$SZ2" ]; then
    ok "stream grows while the run is live ($SZ1 -> $SZ2 bytes)"
else
    echo "  NOTE: no growth seen between 3s samples — the run may have finished inside one sampling window, or the stream is buffered; re-run against a longer prompt before trusting stall detection"
fi
echo "  (stream size: $(wc -c < "$WORK/raw.jsonl") bytes, $(wc -l < "$WORK/raw.jsonl") events)"
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
