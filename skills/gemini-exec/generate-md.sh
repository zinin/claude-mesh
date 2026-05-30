#!/bin/bash
# Generate human-readable markdown from Gemini stream-json log
# Usage: ./generate-md.sh <log_file> <md_file> [task_name_override]
#
# task_name_override: if non-empty, used as TASK_NAME in the report header
# (after sanitisation). Required when WORK_DIR uses the TIMESTAMP-PID-NAME
# format because the path regex below cannot strip the PID component.

LOG_FILE="$1"
MD_FILE="$2"
TASK_NAME_OVERRIDE="${3:-}"
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

# Extract timestamp from directory path; TASK_NAME parsed only if no override.
DIR_NAME=$(basename "$(dirname "$ORIGINAL_LOG_FILE")")
TIMESTAMP=$(echo "$DIR_NAME" | sed 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/')
if [ -n "$TASK_NAME_OVERRIDE" ]; then
    # Defense-in-depth: sanitize even if caller already sanitized.
    TASK_NAME=$(printf '%s' "$TASK_NAME_OVERRIDE" | tr -cd '[:alnum:]._-' | head -c 64)
    [ -z "$TASK_NAME" ] && TASK_NAME="task"
else
    TASK_NAME=$(echo "$DIR_NAME" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-//')
fi

{
    echo "# Gemini Execution Report"
    echo ""
    echo "**Date:** $(echo $TIMESTAMP | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1 \2:\3:\4/')"
    echo "**Task:** $TASK_NAME"

    # Get session info from init event
    INIT_LINE=$(grep '"init"' "$LOG_FILE" | head -1 | sed 's/^\[[^]]*\] //')
    if [ -n "$INIT_LINE" ]; then
        SESSION_ID=$(echo "$INIT_LINE" | jq -r '.session_id // empty')
        MODEL=$(echo "$INIT_LINE" | jq -r '.model // empty')
        [ -n "$SESSION_ID" ] && echo "**Session:** \`$SESSION_ID\`"
        [ -n "$MODEL" ] && echo "**Model:** $MODEL"
    fi
    echo ""
    echo "---"
    echo ""

    # Process tool calls and results in order
    grep -E '"tool_use"|"tool_result"' "$LOG_FILE" | while IFS= read -r line; do
        TS=$(echo "$line" | sed 's/^\[\([^]]*\)\].*/\1/')
        JSON=$(echo "$line" | sed 's/^\[[^]]*\] //')
        TYPE=$(echo "$JSON" | jq -r '.type')

        case "$TYPE" in
            "tool_use")
                TOOL_NAME=$(echo "$JSON" | jq -r '.tool_name')
                PARAMS=$(echo "$JSON" | jq -r '.parameters // empty')
                echo "## Tool Call: $TOOL_NAME [$TS]"
                echo ""
                if [ -n "$PARAMS" ] && [ "$PARAMS" != "null" ] && [ "$PARAMS" != "{}" ]; then
                    echo "\`\`\`json"
                    echo "$PARAMS" | jq '.'
                    echo "\`\`\`"
                fi
                echo ""
                ;;
            "tool_result")
                STATUS=$(echo "$JSON" | jq -r '.status')
                OUTPUT=$(echo "$JSON" | jq -r '.output // empty')
                echo "**Result:** $STATUS"
                echo ""
                if [ -n "$OUTPUT" ] && [ "$OUTPUT" != "null" ]; then
                    echo "<details>"
                    echo "<summary>Output (click to expand)</summary>"
                    echo ""
                    echo "\`\`\`"
                    echo "$OUTPUT"
                    echo "\`\`\`"
                    echo "</details>"
                fi
                echo ""
                echo "---"
                echo ""
                ;;
        esac
    done

    # Concatenate assistant response from message events
    RESPONSE=""
    while IFS= read -r line; do
        JSON=$(echo "$line" | sed 's/^\[[^]]*\] //')
        CONTENT=$(echo "$JSON" | jq -r '.content // empty')
        RESPONSE="${RESPONSE}${CONTENT}"
    done < <(grep '"message"' "$LOG_FILE" | grep '"assistant"')

    if [ -n "$RESPONSE" ]; then
        echo "## Response"
        echo ""
        echo "$RESPONSE"
        echo ""
        echo "---"
        echo ""
    fi

    # Token usage from result event
    RESULT_LINE=$(grep '"result"' "$LOG_FILE" | tail -1 | sed 's/^\[[^]]*\] //')
    if [ -n "$RESULT_LINE" ]; then
        INPUT=$(echo "$RESULT_LINE" | jq -r '.stats.input_tokens // 0')
        OUTPUT_TOKENS=$(echo "$RESULT_LINE" | jq -r '.stats.output_tokens // 0')
        TOTAL=$(echo "$RESULT_LINE" | jq -r '.stats.total_tokens // 0')
        CACHED=$(echo "$RESULT_LINE" | jq -r '.stats.cached // 0')
        TOOL_CALLS=$(echo "$RESULT_LINE" | jq -r '.stats.tool_calls // 0')
        DURATION_MS=$(echo "$RESULT_LINE" | jq -r '.stats.duration_ms // 0')

        echo "## Usage"
        echo ""
        echo "- **Input tokens:** $INPUT"
        echo "- **Output tokens:** $OUTPUT_TOKENS"
        echo "- **Total tokens:** $TOTAL"
        echo "- **Cached:** $CACHED"
        echo "- **Tool calls:** $TOOL_CALLS"
        echo "- **API duration:** ${DURATION_MS}ms"
    fi

    # Timing from log timestamps
    FIRST_TS=$(head -1 "$LOG_FILE" | sed 's/^\[\([^]]*\)\].*/\1/')
    LAST_TS=$(tail -1 "$LOG_FILE" | sed 's/^\[\([^]]*\)\].*/\1/')

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
        if [ "$END_SECS" -lt "$START_SECS" ]; then
            END_SECS=$((END_SECS + 86400))
        fi

        DURATION=$((END_SECS - START_SECS))
        DURATION_MIN=$((DURATION / 60))
        DURATION_SEC=$((DURATION % 60))

        echo "- **Started:** $FIRST_TS"
        echo "- **Finished:** $LAST_TS"
        echo "- **Duration:** ${DURATION_MIN}m ${DURATION_SEC}s"
    fi
} > "$MD_FILE"

echo "Generated: $MD_FILE"
