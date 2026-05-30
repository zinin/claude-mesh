#!/bin/bash
# Generate human-readable markdown from ext-claude JSON log
# Usage: ./generate-md.sh <log_file> <md_file> <profile> [report_title] [task_name_override]
#
# task_name_override: if non-empty, used verbatim as TASK_NAME in the report
# header. Otherwise TASK_NAME is parsed from the directory path (legacy
# behavior). Callers with non-standard WORK_DIR formats (e.g. ollama-exec
# uses TIMESTAMP-PID-NAME with extra `-$$` PID component, supervised mode
# stores logs under `$WORK_DIR/final/` so basename loses TASK_NAME) should
# pass an explicit override.

LOG_FILE="$1"
MD_FILE="$2"
PROFILE="$3"
REPORT_TITLE="${4:-Ext-Claude Execution Report}"
TASK_NAME_OVERRIDE="${5:-}"
ORIGINAL_LOG_FILE="$LOG_FILE"

RAW_PREFIXED_LOG=""
FIRST_INPUT_LINE=$(grep -m 1 '[^[:space:]]' "$LOG_FILE" 2>/dev/null || true)
case "$FIRST_INPUT_LINE" in
    \[* ) ;;
    * )
        RAW_PREFIXED_LOG=$(mktemp)
        sed 's/^/[??:??:??] /' "$LOG_FILE" > "$RAW_PREFIXED_LOG"
        LOG_FILE="$RAW_PREFIXED_LOG"
        trap 'rm -f "$RAW_PREFIXED_LOG"' EXIT
        ;;
esac

# Extract timestamp from directory path (always parsed); task name from
# explicit 5th arg if provided, else from path (legacy fallback).
DIR_NAME=$(basename "$(dirname "$ORIGINAL_LOG_FILE")")
TIMESTAMP=$(echo "$DIR_NAME" | sed 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/')
if [ -n "$TASK_NAME_OVERRIDE" ]; then
    # Defense-in-depth: sanitize even if caller already sanitized.
    # Direct external callers may pass unfiltered values.
    TASK_NAME=$(printf '%s' "$TASK_NAME_OVERRIDE" | tr -cd '[:alnum:]._-' | head -c 64)
    [ -z "$TASK_NAME" ] && TASK_NAME="task"
else
    TASK_NAME=$(echo "$DIR_NAME" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-//')
fi

# Get model from system init line
SYSTEM_LINE=$(grep '\[.*\] {"type":"system"' "$LOG_FILE" 2>/dev/null | head -1 | sed 's/^\[[^]]*\] //')
MODEL=$(echo "$SYSTEM_LINE" | jq -r '.model // "unknown"' 2>/dev/null)
[ -z "$MODEL" ] || [ "$MODEL" = "null" ] && MODEL="unknown"

# Get result metrics from last line
RESULT_LINE=$(grep '\[.*\] {"type":"result"' "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/^\[[^]]*\] //')
DURATION_MS=$(echo "$RESULT_LINE" | jq -r '.duration_ms // 0' 2>/dev/null)
[ -z "$DURATION_MS" ] || [ "$DURATION_MS" = "null" ] && DURATION_MS=0
DURATION_SEC=$(echo "scale=1; $DURATION_MS / 1000" | bc 2>/dev/null || echo "0")
COST=$(echo "$RESULT_LINE" | jq -r '.total_cost_usd // 0' 2>/dev/null)
[ -z "$COST" ] || [ "$COST" = "null" ] && COST="0"
INPUT_TOKENS=$(echo "$RESULT_LINE" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
[ -z "$INPUT_TOKENS" ] || [ "$INPUT_TOKENS" = "null" ] && INPUT_TOKENS=0
OUTPUT_TOKENS=$(echo "$RESULT_LINE" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
[ -z "$OUTPUT_TOKENS" ] || [ "$OUTPUT_TOKENS" = "null" ] && OUTPUT_TOKENS=0

{
    echo "# $REPORT_TITLE"
    echo ""
    echo "**Date:** $(echo $TIMESTAMP | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1 \2:\3:\4/')"
    echo "**Task:** $TASK_NAME"
    echo "**Profile:** $PROFILE | **Model:** $MODEL"
    echo "**Duration:** ${DURATION_SEC}s | **Cost:** \$${COST}"
    echo ""
    echo "---"
    echo ""

    # Process each message
    while IFS= read -r line; do
        TS=$(echo "$line" | sed 's/^\[\([^]]*\)\].*/\1/')
        JSON=$(echo "$line" | sed 's/^\[[^]]*\] //')
        TYPE=$(echo "$JSON" | jq -r '.type' 2>/dev/null)

        case "$TYPE" in
            "assistant")
                # Check content type
                CONTENT_TYPE=$(echo "$JSON" | jq -r '.message.content[0].type // empty' 2>/dev/null)

                if [ "$CONTENT_TYPE" = "tool_use" ]; then
                    TOOL_NAME=$(echo "$JSON" | jq -r '.message.content[0].name' 2>/dev/null)
                    # For Bash tool, get the command
                    if [ "$TOOL_NAME" = "Bash" ]; then
                        TOOL_CMD=$(echo "$JSON" | jq -r '.message.content[0].input.command // empty' 2>/dev/null)
                        echo "## Tool: $TOOL_NAME [$TS]"
                        echo ""
                        echo '```bash'
                        echo "$TOOL_CMD"
                        echo '```'
                    else
                        TOOL_INPUT=$(echo "$JSON" | jq -r '.message.content[0].input | tostring' 2>/dev/null)
                        echo "## Tool: $TOOL_NAME [$TS]"
                        echo ""
                        echo '```json'
                        echo "$TOOL_INPUT"
                        echo '```'
                    fi
                    echo ""
                    echo "---"
                    echo ""
                elif [ "$CONTENT_TYPE" = "text" ]; then
                    TEXT=$(echo "$JSON" | jq -r '.message.content[0].text' 2>/dev/null)
                    echo "## Response [$TS]"
                    echo ""
                    echo "$TEXT"
                    echo ""
                    echo "---"
                    echo ""
                fi
                ;;

            "user")
                # tool_result
                OUTPUT=$(echo "$JSON" | jq -r '.tool_use_result.stdout // .message.content[0].content // empty' 2>/dev/null)
                if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "null" ]; then
                    echo "<details>"
                    echo "<summary>Output (click to expand)</summary>"
                    echo ""
                    echo '```'
                    echo "$OUTPUT"
                    echo '```'
                    echo "</details>"
                    echo ""
                    echo "---"
                    echo ""
                fi
                ;;
        esac
    done < "$LOG_FILE"

    # Usage section
    TOTAL=$((INPUT_TOKENS + OUTPUT_TOKENS))
    echo "## Usage"
    echo ""
    echo "- **Input tokens:** $INPUT_TOKENS"
    echo "- **Output tokens:** $OUTPUT_TOKENS"
    echo "- **Total:** $TOTAL"

    # Timing section
    FIRST_TS=$(head -1 "$LOG_FILE" 2>/dev/null | sed 's/^\[\([^]]*\)\].*/\1/')
    LAST_TS=$(tail -1 "$LOG_FILE" 2>/dev/null | sed 's/^\[\([^]]*\)\].*/\1/')

    time_to_seconds() {
        local time="$1"
        local h=$(echo "$time" | cut -d: -f1)
        local m=$(echo "$time" | cut -d: -f2)
        local s=$(echo "$time" | cut -d: -f3 | cut -d. -f1)  # drop .mmm: bash 10# rejects fractional
        echo $((10#$h * 3600 + 10#$m * 60 + 10#$s))
    }

    ts_to_sec() {
        local time="$1"
        if [ -z "$time" ] || [ "$time" = "??:??:??" ]; then
            echo 0
        else
            time_to_seconds "$time"
        fi
    }

    START_SECS=$(ts_to_sec "$FIRST_TS")
    END_SECS=$(ts_to_sec "$LAST_TS")

    echo ""
    echo "## Timing"
    echo ""
    if [ "$START_SECS" -eq 0 ] && [ "$END_SECS" -eq 0 ]; then
        echo "Timing: unknown (raw stream — no timestamps)"
    else
        echo "- **Started:** $FIRST_TS"
        echo "- **Finished:** $LAST_TS"
    fi

} > "$MD_FILE"

echo "Generated: $MD_FILE"
