#!/bin/bash
# ext-claude Progress Monitor
# Reads stream-json from stdin, shows live progress, saves raw output
# Usage: claude -p --output-format stream-json | ./progress-monitor.sh <work_dir> [profile]

set -euo pipefail

WORK_DIR="$1"
PROFILE="${2:-unknown}"

RAW_JSONL="$WORK_DIR/raw.jsonl"
RAW_JSON="$WORK_DIR/raw.json"
OUTPUT_FILE="$WORK_DIR/output.txt"
LOG_FILE="$WORK_DIR/log.jsonl"

# Counters
TURN=0
TOOL_COUNT=0
START_TIME=$(date +%s%3N)
INITIALIZED=false
HEARTBEAT_INTERVAL=10

fmt_size() {
    local bytes=$1
    if [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)KB"
    else
        echo "${bytes}B"
    fi
}

fmt_elapsed() {
    local secs=$1
    local mins=$((secs / 60))
    local rem=$((secs % 60))
    if [ "$mins" -gt 0 ]; then
        echo "${mins}m ${rem}s"
    else
        echo "${secs}s"
    fi
}

progress() {
    local ts
    ts=$(date +%H:%M:%S)
    echo "[$ts] $*"
}

process_line() {
    local line="$1"

    # Save raw line
    echo "$line" >> "$RAW_JSONL"

    # Parse type
    TYPE=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('type',''))" 2>/dev/null || echo "")

    case "$TYPE" in
        system)
            SUBTYPE=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('subtype',''))" 2>/dev/null || echo "")
            case "$SUBTYPE" in
                init)
                    MODEL=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('model','?'))" 2>/dev/null || echo "?")
                    progress "📋 Session initialized (profile: $PROFILE, model: $MODEL)"
                    # Save to log with timestamp
                    echo "[$(date +%H:%M:%S.%3N)] $line" >> "$LOG_FILE"
                    INITIALIZED=true
                    ;;
            esac
            ;;

        assistant)
            TURN=$((TURN + 1))
            # Parse content items
            CONTENT_INFO=$(echo "$line" | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg = d.get('message', {})
contents = msg.get('content', [])
tools = []
text_len = 0
for c in contents:
    if c.get('type') == 'tool_use':
        name = c.get('name', '?')
        inp = c.get('input', {})
        if name == 'Bash':
            cmd = inp.get('command', '')
            preview = cmd.split('&&')[0].strip()[:60]
            tools.append(f'Bash({preview})')
        elif name == 'Read':
            fp = inp.get('file_path', '?')
            tools.append(f'Read({fp})')
        elif name == 'Grep':
            pat = inp.get('pattern', '?')
            tools.append(f'Grep({pat})')
        elif name == 'Glob':
            pat = inp.get('pattern', '?')
            tools.append(f'Glob({pat})')
        elif name == 'Edit':
            fp = inp.get('file_path', '?')
            tools.append(f'Edit({fp})')
        elif name == 'Write':
            fp = inp.get('file_path', '?')
            tools.append(f'Write({fp})')
        else:
            tools.append(name)
    elif c.get('type') == 'text':
        text_len += len(c.get('text', ''))
if tools:
    for t in tools:
        print(f'TOOL:{t}')
if text_len > 0:
    print(f'TEXT:{text_len}')
" 2>/dev/null || echo "")

            # Display progress for each content item
            while IFS= read -r info; do
                case "$info" in
                    TOOL:*)
                        TOOL_COUNT=$((TOOL_COUNT + 1))
                        TOOL_DESC="${info#TOOL:}"
                        progress "🔧 #$TOOL_COUNT $TOOL_DESC"
                        ;;
                    TEXT:*)
                        TEXT_LEN="${info#TEXT:}"
                        progress "💬 Response ($(fmt_size "$TEXT_LEN"))"
                        ;;
                esac
            done <<< "$CONTENT_INFO"

            # Save to log
            echo "[$(date +%H:%M:%S.%3N)] $line" >> "$LOG_FILE"
            ;;

        user)
            # Tool result - show size
            RESULT_SIZE=$(echo "$line" | wc -c)
            progress "📄 Tool result ($(fmt_size "$RESULT_SIZE"))"
            # Save to log
            echo "[$(date +%H:%M:%S.%3N)] $line" >> "$LOG_FILE"
            ;;

        result)
            # Final result
            METRICS=$(echo "$line" | python3 -c "
import sys, json
d = json.load(sys.stdin)
dur = d.get('duration_ms', 0)
cost = d.get('total_cost_usd', 0)
usage = d.get('usage', {})
inp = usage.get('input_tokens', 0) + usage.get('cache_read_input_tokens', 0) + usage.get('cache_creation_input_tokens', 0)
out = usage.get('output_tokens', 0)
dur_s = dur / 1000
if inp >= 1000:
    inp_str = f'{inp/1000:.1f}K'
else:
    inp_str = str(inp)
if out >= 1000:
    out_str = f'{out/1000:.1f}K'
else:
    out_str = str(out)
print(f'{dur_s:.1f}s|\${cost:.4f}|{inp_str} in / {out_str} out')
" 2>/dev/null || echo "?|?|?")

            IFS='|' read -r DUR COST_STR TOKENS_STR <<< "$METRICS"
            progress "✅ Completed in $DUR | Cost: $COST_STR | Tokens: $TOKENS_STR"

            # Extract result text
            echo "$line" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('result', ''))
" > "$OUTPUT_FILE" 2>/dev/null

            # Save to log
            echo "[$(date +%H:%M:%S.%3N)] $line" >> "$LOG_FILE"
            ;;
    esac
}

# Main read loop with heartbeat support
# read -t returns >128 on timeout, 1 on EOF
while true; do
    READ_RC=0
    IFS= read -r -t "$HEARTBEAT_INTERVAL" line || READ_RC=$?

    if [ "$READ_RC" -eq 0 ]; then
        process_line "$line"
    elif [ "$READ_RC" -gt 128 ]; then
        # Timeout — show heartbeat while waiting for data
        if $INITIALIZED; then
            ELAPSED=$(( ($(date +%s%3N) - START_TIME) / 1000 ))
            progress "⏳ Generating... $(fmt_elapsed $ELAPSED)"
        fi
    else
        # EOF — process any trailing partial line
        [ -n "${line:-}" ] && process_line "$line"
        break
    fi
done

# Build raw.json (array format) for backward compatibility.
# Pass paths via sys.argv (not shell interpolation) — protects against
# injection / parse breakage if a path contains a single quote.
python3 -c "
import json, sys
lines = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                lines.append(json.loads(line))
            except:
                pass
with open(sys.argv[2], 'w') as f:
    json.dump(lines, f, indent=2)
" "$RAW_JSONL" "$RAW_JSON" 2>/dev/null || true

echo ""
echo "=== FILES ==="
echo "Directory: $WORK_DIR"
ls -la "$WORK_DIR"

echo ""
echo "=== OUTPUT (preview) ==="
# Tolerate missing OUTPUT_FILE: if claude crashed before emitting a `result`
# event, the file is never created. Under `set -euo pipefail` an unguarded
# `head` would kill the script before this diagnostic could print anything.
if [ -f "$OUTPUT_FILE" ]; then
    head -30 "$OUTPUT_FILE"
    OUTPUT_LINES=$(wc -l < "$OUTPUT_FILE")
    if [ "$OUTPUT_LINES" -gt 30 ]; then
        echo ""
        echo "... ($OUTPUT_LINES lines total, full output: $OUTPUT_FILE)"
    fi
else
    echo "(no result event received — $OUTPUT_FILE was not created)"
fi
