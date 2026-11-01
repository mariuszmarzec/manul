#!/bin/bash
# manul-wait.sh - Wait for a Manul task to complete
#
# Usage:
#   manul-wait.sh --task-id ID [--timeout SECONDS] [--json]
#
# Polls the Manul database until the task completes or times out.
#
# Exit codes:
#   0 - Task completed successfully
#   1 - Task failed
#   2 - Task not found
#   4 - Timeout

set -euo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"

JSON_OUTPUT=false
TASK_ID=""
TIMEOUT=600

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

if [ -z "$TASK_ID" ]; then
  echo "Error: --task-id is required" >&2
  exit 3
fi

# Check if database exists
if [ ! -f "$DB" ]; then
  output="{\"taskId\": \"$TASK_ID\", \"status\": \"not_found\", \"error\": \"Manul database not found at $DB\"}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$output" | jq .
  else
    echo "Error: Manul database not found at $DB"
  fi
  exit 2
fi

# Poll for task completion
elapsed=0
interval=5

while [ "$elapsed" -lt "$TIMEOUT" ]; do
  # Query task status
  task_info="$(sqlite3 "$DB" "SELECT status, prNumber, commentUrl FROM processed_comments WHERE commentId='$(printf '%s' "$TASK_ID" | sed "s/'/''/g")';" 2>/dev/null || echo "")"

  if [ -n "$task_info" ]; then
    IFS='|' read -r status pr_number comment_url <<< "$task_info"

    case "$status" in
      completed)
        # Get result from result file if available
        result_file="$MANUL_DIR/results/$(manul_task_file_key "$TASK_ID").json"
        result="{}"
        if [ -f "$result_file" ]; then
          result="$(cat "$result_file")"
        fi

        # Build output
        output=$(jq -n \
          --arg taskId "$TASK_ID" \
          --arg status "completed" \
          --arg prNumber "${pr_number:-}" \
          --arg prUrl "${comment_url:-}" \
          --argjson result "$result" \
          '{
            taskId: $taskId,
            status: $status,
            prNumber: ($prNumber | tonumber? // null),
            prUrl: $prUrl,
            result: $result
          }')

        if [ "$JSON_OUTPUT" = true ]; then
          echo "$output" | jq .
        else
          echo "Task $TASK_ID completed"
          if [ -n "$pr_number" ]; then
            echo "  PR: #$pr_number"
          fi
        fi
        exit 0
        ;;
      failed)
        output="{\"taskId\": \"$TASK_ID\", \"status\": \"failed\"}"
        if [ "$JSON_OUTPUT" = true ]; then
          echo "$output" | jq .
        else
          echo "Task $TASK_ID failed"
        fi
        exit 1
        ;;
      queued|running)
        # Still waiting
        ;;
      blocked_user)
        if [ "$JSON_OUTPUT" = true ]; then
          echo "{"taskId":"$TASK_ID","status":"blocked_user","message":"Waiting for user input; reply with /manul continue <answer>"}"
        else
          echo "Task $TASK_ID is blocked waiting for user input"
          echo "  Reply on GitHub with: /manul continue <answer>"
        fi
        exit 3
        ;;
      *)
        # Unknown status, treat as failed
        output="{\"taskId\": \"$TASK_ID\", \"status\": \"unknown\", \"error\": \"Unexpected status: $status\"}"
        if [ "$JSON_OUTPUT" = true ]; then
          echo "$output" | jq .
        else
          echo "Task $TASK_ID has unknown status: $status"
        fi
        exit 1
        ;;
    esac
  else
    # Task not found in database
    sleep "$interval"
    elapsed=$((elapsed + interval))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      output="{\"taskId\": \"$TASK_ID\", \"status\": \"timeout\", \"error\": \"Task not found in database after ${TIMEOUT}s\"}"
      if [ "$JSON_OUTPUT" = true ]; then
        echo "$output" | jq .
      else
        echo "Task $TASK_ID not found (timeout)"
      fi
      exit 4
    fi
  fi

  sleep "$interval"
  elapsed=$((elapsed + interval))
done

# Timeout
output="{\"taskId\": \"$TASK_ID\", \"status\": \"timeout\", \"error\": \"Wait timed out after ${TIMEOUT}s\"}"
if [ "$JSON_OUTPUT" = true ]; then
  echo "$output" | jq .
else
  echo "Task $TASK_ID wait timed out after ${TIMEOUT}s"
fi
exit 4
