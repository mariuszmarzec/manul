#!/bin/bash
# manul-result.sh - Retrieve the final result of a completed task
#
# Usage:
#   manul-result.sh [OPTIONS] TASK_ID
#
# Options:
#   --json    Output JSON format
#
# Returns:
#   JSON with task result details
#   Exit code 0 on success, 1 on failure
#
# Examples:
#   manul-result.sh cli-abc123
#   manul-result.sh --json cli-abc123
#
# JSON Output Schema:
#   {
#     "taskId": "string",
#     "conversationId": "string",
#     "status": "completed|failed",
#     "success": boolean,
#     "summary": "string|null",
#     "changedFiles": ["string"]|null,
#     "commit": "string|null",
#     "pullRequest": "string|null",
#     "error": "string|null",
#     "completedAt": "ISO8601",
#     "attempts": number
#   }

set -euo pipefail

# Configuration
MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
OUTPUT_FORMAT="text"
TASK_ID="${1:-}"

# Parse options
while [[ $# -gt 0 ]]; do
  case $1 in
    --json) OUTPUT_FORMAT="json"; shift ;;
    *) TASK_ID="$1"; shift ;;
  esac
done

# Validate required argument
if [ -z "$TASK_ID" ]; then
  echo "Error: TASK_ID is required" >&2
  echo "Usage: manul-result.sh [--json] TASK_ID" >&2
  exit 1
fi

# Ensure database exists
if [ ! -f "$DB" ]; then
  echo "Error: Manul database not found at $DB" >&2
  exit 1
fi

# Escape strings for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

ESCAPED_TASK_ID="$(sql_escape "$TASK_ID")"

# Query task result - check resultSummary first, fall back to context
RESULT="$(sqlite3 "$DB" "
  SELECT commentId, status, conversationId, attempts, processedAt,
         prompt, COALESCE(resultSummary, context) as summary_data
  FROM processed_comments
  WHERE commentId='$ESCAPED_TASK_ID' AND status IN ('completed', 'failed', 'blocked_user');
" 2>/dev/null)" || {
  echo "Error: Failed to query task result" >&2
  exit 1
}

if [ -z "$RESULT" ]; then
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    printf '{"error": "Task not found or not completed", "taskId": "%s"}\n' "$TASK_ID"
  else
    echo "Error: Task '$TASK_ID' not found or not yet completed" >&2
  fi
  exit 1
fi

IFS='|' read -r tid status conv attempts completed_at prompt summary_data <<< "$RESULT"

# Determine success based on status
if [ "$status" = "completed" ]; then
  SUCCESS="true"
  SUMMARY="${summary_data:-"Task completed successfully"}"
  ERROR="null"
else
  SUCCESS="false"
  SUMMARY="null"
  ERROR="$(printf '%s' "$summary_data" | sed 's/"/\\"/g')"
fi
if [ "$status" = "blocked_user" ]; then
  ERROR="${summary_data:-"Task is blocked waiting for user input"}"
fi

if [ "$OUTPUT_FORMAT" = "json" ]; then
  # Build JSON output
  JSON="{\"taskId\": \"$tid\""
  JSON+=", \"conversationId\": \"$conv\""
  JSON+=", \"status\": \"$status\""
  JSON+=", \"success\": $SUCCESS"
  JSON+=", \"completedAt\": \"$completed_at\""
  JSON+=", \"attempts\": ${attempts:-0}"
  
  # Optional fields
  if [ "$SUCCESS" = "true" ]; then
    JSON+=", \"summary\": \"$(echo "$SUMMARY" | sed 's/"/\\"/g')\""
  else
    JSON+=", \"error\": \"$(echo "$ERROR" | sed 's/"/\\"/g')\""
  fi
  
  # Note: changedFiles, commit, pullRequest would need to be extracted from
  # the GitHub comment or stored separately. For now, these are null.
  JSON+=", \"changedFiles\": null"
  JSON+=", \"commit\": null"
  JSON+=", \"pullRequest\": null"
  
  JSON+="}"
  echo "$JSON"
else
  echo "Task Result:"
  echo "  taskId:         $tid"
  echo "  conversationId: $conv"
  echo "  status:         $status"
  echo "  success:        $SUCCESS"
  echo "  attempts:       ${attempts:-0}"
  echo "  completedAt:    $completed_at"
  if [ "$SUCCESS" = "true" ]; then
    echo "  summary:        $SUMMARY"
  else
    echo "  error:          $ERROR"
  fi
  echo ""
  echo "Note: For detailed results (changed files, commits, PRs), check the linked PR. Todo-source questions are stored here; update the Todo task to resume with a new source version."
fi

exit 0
