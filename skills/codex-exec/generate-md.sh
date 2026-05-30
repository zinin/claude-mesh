#!/bin/bash
# Generate human-readable markdown from Codex JSONL log
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

# Extract timestamp and task name from directory path
# e.g., /path/to/2026-01-28-08-31-17-review-feature/log.jsonl
DIR_NAME=$(basename "$(dirname "$ORIGINAL_LOG_FILE")")
# Parse: YYYY-MM-DD-HH-MM-SS-taskname (TASK_NAME parsed only when no override)
TIMESTAMP=$(echo "$DIR_NAME" | sed 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/')
if [ -n "$TASK_NAME_OVERRIDE" ]; then
    # Defense-in-depth: sanitize even if caller already sanitized.
    TASK_NAME=$(printf '%s' "$TASK_NAME_OVERRIDE" | tr -cd '[:alnum:]._-' | head -c 64)
    [ -z "$TASK_NAME" ] && TASK_NAME="task"
else
    TASK_NAME=$(echo "$DIR_NAME" | sed 's/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}-//')
fi

{
    echo "# Codex Execution Report"
    echo ""
    echo "**Date:** $(echo $TIMESTAMP | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1 \2:\3:\4/')"
    echo "**Task:** $TASK_NAME"
    THREAD_ID=$(grep '"thread.started"' "$LOG_FILE" | sed 's/^\[[^]]*\] //' | jq -r '.thread_id' | head -1)
    [ -n "$THREAD_ID" ] && echo "**Thread:** \`$THREAD_ID\`"
    echo ""
    echo "---"
    echo ""

    # Process each item.completed event
    grep '"item.completed"' "$LOG_FILE" | while IFS= read -r line; do
        TS=$(echo "$line" | sed 's/^\[\([^]]*\)\].*/\1/')
        JSON=$(echo "$line" | sed 's/^\[[^]]*\] //')
        ITEM_TYPE=$(echo "$JSON" | jq -r '.item.type')
        case "$ITEM_TYPE" in
            "reasoning")
                TEXT=$(echo "$JSON" | jq -r '.item.text')
                echo "## Reasoning [$TS]"
                echo ""
                echo "$TEXT"
                echo ""
                echo "---"
                echo ""
                ;;
            "command_execution")
                CMD=$(echo "$JSON" | jq -r '.item.command')
                EXIT=$(echo "$JSON" | jq -r '.item.exit_code')
                OUTPUT=$(echo "$JSON" | jq -r '.item.aggregated_output // empty')
                echo "## Command [$TS]"
                echo ""
                echo "\`\`\`bash"
                echo "$CMD"
                echo "\`\`\`"
                echo ""
                echo "**Exit code:** $EXIT"
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
            "agent_message")
                TEXT=$(echo "$JSON" | jq -r '.item.text')
                echo "## Final Response [$TS]"
                echo ""
                echo "$TEXT"
                echo ""
                echo "---"
                echo ""
                ;;
        esac
    done

    # Add token usage
    USAGE=$(grep '"turn.completed"' "$LOG_FILE" | tail -1 | sed 's/^\[[^]]*\] //' | jq -r '.usage // empty')
    if [ -n "$USAGE" ] && [ "$USAGE" != "null" ]; then
        INPUT=$(echo "$USAGE" | jq -r '.input_tokens // 0')
        OUTPUT=$(echo "$USAGE" | jq -r '.output_tokens // 0')
        TOTAL=$((INPUT + OUTPUT))
        echo "## Usage"
        echo ""
        echo "- **Input tokens:** $INPUT"
        echo "- **Output tokens:** $OUTPUT"
        echo "- **Total:** $TOTAL"
    fi

    # Add timing section
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
