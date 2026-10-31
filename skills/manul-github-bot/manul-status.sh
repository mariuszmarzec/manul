#!/bin/bash
# manul-status.sh - Query task status from the Manul queue
#
# Usage:
#   manul-status.sh [OPTIONS] [TASK_ID]
#
# Options:
#   --task ID        Task/comment ID to query (required if no positional arg)
#   --json           Output JSON format
#   --list           List active tasks plus recent terminal tasks
#   --history        List terminal task history retained for the longer window
#   --status S       Filter by status (queued, running, blocked_user, completed, failed, stale)
#   --log            Show daemon.log instead of task status
#   --tail N         Number of log lines to show (default: 100)
#   --tail=N         Same as --tail N
#
# Returns:
#   JSON with task details or list of tasks
#   Exit code 0 on success, 1 on failure
#
# Examples:
#   manul-status.sh cli-abc123
#   manul-status.sh --task cli-abc123 --json
#   manul-status.sh --list --status queued
#   manul-status.sh --list --json
#   manul-status.sh --history --json
#   manul-status.sh --log --tail=200
#
# JSON Output Schema:
#   {
#     "taskId": "string",
#     "conversationId": "string",
#     "status": "queued|running|completed|failed|stale",
#     "repo": "string",
#     "issue": number,
#     "attempts": number,
#     "preExecutionFailures": number,
#     "agentStartedAt": "ISO8601|null",
#     "createdAt": "ISO8601",
#     "startedAt": "ISO8601|null",
#     "completedAt": "ISO8601|null",
#     "workerId": "number|null",
#     "workspaceId": "string|null",
#     "nextAttemptAt": "ISO8601|null",
#     "prompt": "string"
#   }

set -euo pipefail

# Configuration
MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
OUTPUT_FORMAT="text"
LIST_MODE=false
FILTER_STATUS=""
TASK_ID=""
LOG_MODE=false
HISTORY_MODE=false
LOG_TAIL=100

TASK_RETENTION_DEFAULT_LIST_DAYS=7
TASK_RETENTION_DEFAULT_HISTORY_DAYS=14
TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --task)
      [ $# -ge 2 ] || { echo "Error: --task requires an ID" >&2; exit 1; }
      TASK_ID="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    --list) LIST_MODE=true; shift ;;
    --history) HISTORY_MODE=true; LIST_MODE=true; shift ;;
    --status)
      [ $# -ge 2 ] || { echo "Error: --status requires a value" >&2; exit 1; }
      FILTER_STATUS="$2"; shift 2 ;;
    --log) LOG_MODE=true; shift ;;
    --tail)
      [ $# -ge 2 ] || { echo "Error: --tail requires a number" >&2; exit 1; }
      LOG_TAIL="$2"; shift 2 ;;
    --tail=*) LOG_TAIL="${1#--tail=}"; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) TASK_ID="$1"; shift ;;
  esac
done

if ! [[ "$LOG_TAIL" =~ ^[0-9]+$ ]] || [ "$LOG_TAIL" -lt 1 ]; then
  echo "Error: --tail must be a positive integer" >&2
  exit 1
fi

if [ "$LOG_MODE" = true ]; then
  LOG_FILE="$MANUL_LOG_DIR/daemon.log"
  if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Manul daemon log not found at $LOG_FILE" >&2
    exit 1
  fi
  tail -n "$LOG_TAIL" "$LOG_FILE"
  exit 0
fi

# Ensure database exists
# Status is a read-only operation. Refuse missing/empty files before
# invoking sqlite3, and use SQLite's read-only mode below so diagnostics can
# never create or mutate the queue database.
if [ ! -s "$DB" ]; then
  echo "Error: Manul database not found or empty at $DB" >&2
  exit 1
fi

# Escape strings for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

db_has_column() {
  local column="$1"
  sqlite3 -readonly "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null |
    awk -F'|' -v column="$column" '$2 == column { found=1 } END { exit !found }'
}

# Older databases may not have recovery diagnostics yet. Render safe defaults
# until the daemon's normal schema migration adds these columns.
PRE_EXECUTION_FAILURES_SQL="0"
AGENT_STARTED_AT_SQL="''"
if db_has_column preExecutionFailures; then
  PRE_EXECUTION_FAILURES_SQL="COALESCE(preExecutionFailures,0)"
fi
if db_has_column agentStartedAt; then
  AGENT_STARTED_AT_SQL="COALESCE(agentStartedAt,'')"
fi

task_source_label() {
  case "$1" in
    github_issues) printf 'GitHub' ;;
    jira_tasks) printf 'Jira' ;;
    todo_local_mcp) printf 'Todo Local' ;;
    todo_remote_mcp) printf 'Todo Remote' ;;
    "") printf 'CLI / Manual' ;;
    *) printf '%s' "$1" ;;
  esac
}

task_source_record_id() {
  local source_type="$1" source_id="$2"
  case "$source_type" in
    todo_local_mcp|todo_remote_mcp)
      # The stored identity is "<root task id>@<structural fingerprint>".
      # The CLI shows the stable provider task ID, not the internal fingerprint.
      printf '%s' "$source_id" | cut -d'@' -f1
      ;;
    *)
      printf '%s' "$source_id"
      ;;
  esac
}
load_task_retention() {
  local list_days history_days
  list_days="$(jq -r '.retention.listDays // empty' "$MANUL_DIR/config.json" 2>/dev/null || true)"
  history_days="$(jq -r '.retention.historyDays // empty' "$MANUL_DIR/config.json" 2>/dev/null || true)"

  if ! [[ "$list_days" =~ ^[0-9]+$ ]] || [ "$list_days" -lt 1 ] || \
     ! [[ "$history_days" =~ ^[0-9]+$ ]] || [ "$history_days" -lt 1 ] || \
     [ "$history_days" -lt $((list_days * 2)) ]; then
    TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
    TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"
  else
    TASK_LIST_RETENTION_DAYS="$list_days"
    TASK_HISTORY_RETENTION_DAYS="$history_days"
  fi
}


if [ "$LIST_MODE" = true ]; then
  # List mode: query multiple tasks
  # Active tasks are always shown, including blocked_user tasks. Terminal tasks
  # are limited by the configured retention window. --history uses the longer window.
  load_task_retention
  local_retention_days="$TASK_LIST_RETENTION_DAYS"
  if [ "$HISTORY_MODE" = true ]; then
    local_retention_days="$TASK_HISTORY_RETENTION_DAYS"
  fi

  if [ -n "$FILTER_STATUS" ]; then
    if [ "$FILTER_STATUS" = "queued" ] || [ "$FILTER_STATUS" = "running" ] || [ "$FILTER_STATUS" = "blocked_user" ]; then
      WHERE_CLAUSE="WHERE status='$(sql_escape "$FILTER_STATUS")'"
    else
      WHERE_CLAUSE="WHERE status='$(sql_escape "$FILTER_STATUS")' AND COALESCE(processedAt, createdAt) >= datetime('now', '-$local_retention_days days')"
    fi
  elif [ "$HISTORY_MODE" = true ]; then
    WHERE_CLAUSE="WHERE status IN ('completed', 'failed', 'stale') AND COALESCE(processedAt, createdAt) >= datetime('now', '-$local_retention_days days')"
  else
    WHERE_CLAUSE="WHERE (status IN ('queued', 'running', 'blocked_user') OR (status IN ('completed', 'failed', 'stale') AND COALESCE(processedAt, createdAt) >= datetime('now', '-$local_retention_days days')))"
  fi

  # Source columns were added with task-source support. Keep status readable
  # against an older DB that has not yet gone through the normal migration.
  SOURCE_TYPE_SQL="''"
  SOURCE_ID_SQL="''"
  if db_has_column taskSourceType; then
    SOURCE_TYPE_SQL="COALESCE(taskSourceType,'')"
  fi
  if db_has_column taskSourceId; then
    SOURCE_ID_SQL="COALESCE(taskSourceId,'')"
  fi

  RESULTS="$(sqlite3 -readonly "$DB" "
    SELECT commentId, repository, issueNumber, status, conversationId,
           attempts, $PRE_EXECUTION_FAILURES_SQL AS preExecutionFailures,
           $AGENT_STARTED_AT_SQL AS agentStartedAt,
           createdAt, processedAt, workerPid, workspaceId, nextAttemptAt,
           $SOURCE_TYPE_SQL AS taskSourceType, $SOURCE_ID_SQL AS taskSourceId
    FROM processed_comments $WHERE_CLAUSE
    ORDER BY createdAt DESC
    LIMIT 100;
  " 2>/dev/null)" || {
    echo "Error: Failed to query task status" >&2
    exit 1
  }

  if [ -z "$RESULTS" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      echo "[]"
    else
      echo "No tasks found"
    fi
    exit 0
  fi

  if [ "$OUTPUT_FORMAT" = "json" ]; then
    echo "["
    FIRST=true
    while IFS='|' read -r tid repo issue status conv attempts pre_execution_failures agent_started_at created started worker ws next task_source_type task_source_id; do
      if [ "$FIRST" = true ]; then
        FIRST=false
      else
        printf ',\n'
      fi

      source_name="$(task_source_label "$task_source_type")"
      source_record_id="$(task_source_record_id "$task_source_type" "$task_source_id")"
      json_object="$(jq -cn \
        --arg taskId "$tid" \
        --arg repo "$repo" \
        --arg issue "$issue" \
        --arg status "$status" \
        --arg conversationId "$conv" \
        --arg attempts "$attempts" \
        --arg preExecutionFailures "$pre_execution_failures" \
        --arg agentStartedAt "$agent_started_at" \
        --arg createdAt "$created" \
        --arg startedAt "$started" \
        --arg workerId "$worker" \
        --arg workspaceId "$ws" \
        --arg nextAttemptAt "$next" \
        --arg taskSourceType "$task_source_type" \
        --arg taskSourceId "$task_source_id" \
        --arg source "$source_name" \
        --arg sourceId "$source_record_id" \
        '{
          taskId: $taskId,
          repo: $repo,
          issue: ($issue | tonumber),
          status: $status,
          conversationId: $conversationId,
          attempts: ($attempts | tonumber),
          preExecutionFailures: ($preExecutionFailures | tonumber),
          agentStartedAt: (if $agentStartedAt == "" then null else $agentStartedAt end),
          createdAt: $createdAt,
          startedAt: (if $startedAt == "" then null else $startedAt end),
          workerId: (if $workerId == "" then null else ($workerId | tonumber) end),
          workspaceId: (if $workspaceId == "" then null else $workspaceId end),
          nextAttemptAt: (if $nextAttemptAt == "" then null else $nextAttemptAt end),
          source: $source,
          sourceId: (if $sourceId == "" then null else $sourceId end),
          taskSourceType: (if $taskSourceType == "" then null else $taskSourceType end),
          taskSourceId: (if $taskSourceId == "" then null else $taskSourceId end)
        }')"
      printf '  %s' "$json_object"
    done <<< "$RESULTS"
    printf '\n]\n'
  else
    # Calculate widths from all rendered values. printf field widths are minimums,
    # not maximums, so fixed widths let long task IDs/repository names shift columns.
    header_task_id="TASK_ID"
    header_repo_issue="REPO#ISSUE"
    header_source="SOURCE"
    header_source_id="SOURCE_ID"
    header_status="STATUS"
    header_attempts="ATTEMPTS"
    header_pre_execution_failures="PRE-EXEC"
    header_agent_started_at="AGENT-STARTED"
    header_created="CREATED"

    task_id_width=${#header_task_id}
    repo_issue_width=${#header_repo_issue}
    source_width=${#header_source}
    source_id_width=${#header_source_id}
    status_width=${#header_status}
    attempts_width=${#header_attempts}
    pre_execution_failures_width=${#header_pre_execution_failures}
    agent_started_at_width=${#header_agent_started_at}
    created_width=${#header_created}

    while IFS='|' read -r tid repo issue status conv attempts pre_execution_failures agent_started_at created started worker ws next task_source_type task_source_id; do
      source_name="$(task_source_label "$task_source_type")"
      source_record_id="$(task_source_record_id "$task_source_type" "$task_source_id")"
      repo_reference="$repo"
      if [ "$issue" != "0" ]; then
        repo_reference="$repo#$issue"
      fi

      [ ${#tid} -le "$task_id_width" ] || task_id_width=${#tid}
      [ ${#repo_reference} -le "$repo_issue_width" ] || repo_issue_width=${#repo_reference}
      [ ${#source_name} -le "$source_width" ] || source_width=${#source_name}
      [ ${#source_record_id} -le "$source_id_width" ] || source_id_width=${#source_record_id}
      [ ${#status} -le "$status_width" ] || status_width=${#status}
      [ ${#attempts} -le "$attempts_width" ] || attempts_width=${#attempts}
      [ ${#pre_execution_failures} -le "$pre_execution_failures_width" ] || pre_execution_failures_width=${#pre_execution_failures}
      [ ${#agent_started_at} -le "$agent_started_at_width" ] || agent_started_at_width=${#agent_started_at}
      [ ${#created} -le "$created_width" ] || created_width=${#created}
    done <<< "$RESULTS"

    printf "%-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n" \
      "$task_id_width" "$header_task_id" \
      "$repo_issue_width" "$header_repo_issue" \
      "$source_width" "$header_source" \
      "$source_id_width" "$header_source_id" \
      "$status_width" "$header_status" \
      "$attempts_width" "$header_attempts" \
      "$pre_execution_failures_width" "$header_pre_execution_failures" \
      "$agent_started_at_width" "$header_agent_started_at" "$header_created"
    printf "%s  %s  %s  %s  %s  %s  %s  %s  %s\n" \
      "$(printf '%*s' "$task_id_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$repo_issue_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$source_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$source_id_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$status_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$attempts_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$pre_execution_failures_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$agent_started_at_width" '' | tr ' ' '-')" \
      "$(printf '%*s' "$created_width" '' | tr ' ' '-')"

    while IFS='|' read -r tid repo issue status conv attempts pre_execution_failures agent_started_at created started worker ws next task_source_type task_source_id; do
      source_name="$(task_source_label "$task_source_type")"
      source_record_id="$(task_source_record_id "$task_source_type" "$task_source_id")"
      repo_reference="$repo"
      if [ "$issue" != "0" ]; then
        repo_reference="$repo#$issue"
      fi
      printf "%-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %-*s  %s\n" \
        "$task_id_width" "$tid" \
        "$repo_issue_width" "$repo_reference" \
        "$source_width" "$source_name" \
        "$source_id_width" "$source_record_id" \
        "$status_width" "$status" \
        "$attempts_width" "$attempts" \
        "$pre_execution_failures_width" "$pre_execution_failures" \
        "$agent_started_at_width" "$agent_started_at" "$created"
    done <<< "$RESULTS"
  fi
else
  # Single task mode
  if [ -z "$TASK_ID" ]; then
    echo "Error: TASK_ID is required (use --list to see all tasks)" >&2
    exit 1
  fi

  ESCAPED_TASK_ID="$(sql_escape "$TASK_ID")"
  
  RESULT="$(sqlite3 -readonly "$DB" "
    SELECT commentId, repository, issueNumber, status, conversationId,
           parentTaskId, agent, attempts,
           $PRE_EXECUTION_FAILURES_SQL AS preExecutionFailures,
           $AGENT_STARTED_AT_SQL AS agentStartedAt,
           createdAt, processedAt, workerPid, workspaceId, nextAttemptAt, prompt
    FROM processed_comments
    WHERE commentId='$ESCAPED_TASK_ID';
  " 2>/dev/null)" || {
    echo "Error: Failed to query task status" >&2
    exit 1
  }

  if [ -z "$RESULT" ]; then
    if [ "$OUTPUT_FORMAT" = "json" ]; then
      printf '{"error": "Task not found", "taskId": "%s"}\n' "$TASK_ID"
    else
      echo "Error: Task '$TASK_ID' not found" >&2
    fi
    exit 1
  fi

  IFS='|' read -r tid repo issue status conv parent agent attempts pre_execution_failures agent_started_at created started worker ws next prompt <<< "$RESULT"

  if [ "$OUTPUT_FORMAT" = "json" ]; then
    # Build JSON output
    JSON="{\"taskId\": \"$tid\""
    JSON+=", \"conversationId\": \"$conv\""
    JSON+=", \"status\": \"$status\""
    JSON+=", \"repo\": \"$repo\""
    JSON+=", \"issue\": $issue"
    [ -n "$agent" ] && JSON+=", \"agent\": \"$agent\""
    [ -n "$parent" ] && JSON+=", \"parentTaskId\": \"$parent\""
    JSON+=", \"attempts\": ${attempts:-0}"
    JSON+=", \"preExecutionFailures\": ${pre_execution_failures:-0}"
    if [ -n "$agent_started_at" ]; then
      JSON+=", \"agentStartedAt\": \"$agent_started_at\""
    else
      JSON+=", \"agentStartedAt\": null"
    fi
    JSON+=", \"createdAt\": \"$created\""
    
    # Optional fields
    [ -n "$started" ] && JSON+=", \"startedAt\": \"$started\""
    [ -n "$worker" ] && JSON+=", \"workerId\": $worker"
    [ -n "$ws" ] && JSON+=", \"workspaceId\": \"$ws\""
    [ -n "$next" ] && JSON+=", \"nextAttemptAt\": \"$next\""
    [ -n "$prompt" ] && JSON+=", \"prompt\": \"$(echo "$prompt" | sed 's/"/\\"/g')\""
    
    JSON+="}"
    echo "$JSON"
  else
    echo "Task Status:"
    echo "  taskId:         $tid"
    echo "  conversationId: $conv"
    echo "  status:         $status"
    echo "  repo:           $repo#$issue"
    [ -n "$agent" ] && echo "  agent:          $agent"
    [ -n "$parent" ] && echo "  parentTaskId:   $parent"
    echo "  attempts:       ${attempts:-0}"
    echo "  preExecutionFailures: ${pre_execution_failures:-0}"
    [ -n "$agent_started_at" ] && echo "  agentStartedAt: $agent_started_at"
    echo "  createdAt:      ${created:-}"
    [ -n "$started" ] && echo "  startedAt:      $started"
    [ -n "$worker" ] && echo "  workerId:       $worker"
    [ -n "$ws" ] && echo "  workspaceId:    $ws"
    [ -n "$next" ] && echo "  nextAttemptAt:  $next"
  fi
fi

exit 0
