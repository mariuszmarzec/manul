#!/bin/bash
# manul-conversation.sh - External orchestration CLI for Manul conversation lifecycle
#
# This script provides a machine-readable contract for external orchestrators
# (e.g., ChatGPT) to drive Manul through a persistent GitHub Issue/PR conversation.
#
# Usage:
#   manul-conversation create    --repo REPO --title TITLE --prompt PROMPT [--json]
#   manul-conversation submit    --conversation-id ID --prompt PROMPT [--action ACTION] [--parent-task-id ID] [--pr-number N] [--review-id ID] [--json]
#   manul-conversation status    --conversation-id ID [--json]
#   manul-conversation result    --task-id ID [--json]
#   manul-conversation close     --conversation-id ID [--json]
#
# JSON stdout contains ONLY JSON. Errors go to stderr.
# Exit codes: 0=success, 1=failure, 2=not found, 3=bad request

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
CONFIG="$MANUL_CONFIG"
POLL="$MANUL_DIR/poll.sh"
FEEDBACK="$MANUL_DIR/feedback.sh"

# JSON output flag
JSON_OUTPUT=false

# Parse global options
ACTION=""
REPO=""
TITLE=""
PROMPT=""
CONVERSATION_ID=""
TASK_ID=""
AGENT=""
PARENT_TASK_ID=""
PR_NUMBER=""
ACTION_TYPE=""
REVIEW_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --conversation-id) CONVERSATION_ID="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --parent-task-id) PARENT_TASK_ID="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --action) ACTION_TYPE="$2"; shift 2 ;;
    --review-id) REVIEW_ID="$2"; shift 2 ;;
    create|status|submit|result|close|init-schema) ACTION="$1"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

# SQL escaping helper
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Error helper
error_exit() {
  local msg="$1"
  local code="${2:-1}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "{\"error\": \"$msg\", \"code\": $code}" >&2
  else
    echo "ERROR: $msg" >&2
  fi
  exit "$code"
}

# Ensure schema is initialized
# Uses atomic transaction to prevent race conditions when multiple
# processes call init_schema() concurrently
init_schema() {
  mkdir -p "$(dirname "$DB")"

  local max_retries=10
  local retry=0
  local success=false

  while [ "$success" = false ] && [ $retry -lt $max_retries ]; do
    local err
    err="$(sqlite3 "$DB" "
      BEGIN IMMEDIATE;
      CREATE TABLE IF NOT EXISTS processed_comments (
        commentId TEXT PRIMARY KEY,
        repository TEXT NOT NULL,
        issueNumber INTEGER NOT NULL,
        commentUrl TEXT NOT NULL,
        author TEXT,
        agent TEXT,
        prompt TEXT NOT NULL,
        context TEXT,
        status TEXT NOT NULL DEFAULT 'queued',
        attempts INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT,
        processedAt TEXT,
        heartbeatAt TEXT,
        leaseExpiresAt TEXT,
        workerPid INTEGER,
        claimToken TEXT,
        nextAttemptAt TEXT,
        conversationId TEXT,
        parentTaskId TEXT,
        workspaceId TEXT,
        session_id TEXT,
        action TEXT DEFAULT 'IMPLEMENT',
        prNumber INTEGER,
        prUrl TEXT,
        taskSourceType TEXT,
        taskSourceId TEXT,
        taskSourceUrl TEXT,
        taskSourceTitle TEXT,
        taskSourceUpdatedAt TEXT
      );
      CREATE TABLE IF NOT EXISTS conversations (
        conversationId TEXT PRIMARY KEY,
        repository TEXT NOT NULL,
        issueNumber INTEGER NOT NULL,
        issueUrl TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'OPEN',
        activeTaskId TEXT,
        activePrNumber TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
      COMMIT;
    " 2>&1)" && success=true || {
      retry=$((retry + 1))
      if [ $retry -ge $max_retries ]; then
        echo "ERROR: init_schema failed after $max_retries retries: $err" >&2
        return 1
      fi
      sleep "0.0$((retry * 2))"
    }
  done

  # Add missing columns (idempotent migration — handles concurrent initialization).
  # Batches all ALTERs into one call; "duplicate column" errors are swallowed
  # as a race-condition safety net. All other errors propagate.
  local col_check
  col_check="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>&1)" || {
    echo "ERROR: Failed to read processed_comments schema" >&2
    return 1
  }

  local alter_sql=""
  if ! echo "$col_check" | grep -q "|taskSourceType|"; then
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN taskSourceType TEXT; "
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN taskSourceId TEXT; "
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN taskSourceUrl TEXT; "
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN taskSourceTitle TEXT; "
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN taskSourceUpdatedAt TEXT; "
  fi

  if ! echo "$col_check" | grep -q '|action|'; then
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN action TEXT DEFAULT 'IMPLEMENT'; "
  fi
  if ! echo "$col_check" | grep -q '|prNumber|'; then
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER; "
  fi
  if ! echo "$col_check" | grep -q '|prUrl|'; then
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN prUrl TEXT; "
  fi
  if ! echo "$col_check" | grep -q '|claimToken|'; then
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN claimToken TEXT; "
  fi
  if ! echo "$col_check" | grep -q '|session_id|'; then
    alter_sql="${alter_sql}ALTER TABLE processed_comments ADD COLUMN session_id TEXT; "
  fi

  if [ -n "$alter_sql" ]; then
    local alter_err
    alter_err="$(sqlite3 "$DB" "$alter_sql" 2>&1)" || {
      if echo "$alter_err" | grep -qi 'duplicate column'; then
        : # race condition: concurrent init already added the column
      else
        echo "ERROR: Schema migration failed: $alter_err" >&2
        return 1
      fi
    }
  fi
}

# Create a new conversation (creates GitHub Issue)
cmd_create() {
  if [ -z "$REPO" ] || [ -z "$TITLE" ] || [ -z "$PROMPT" ]; then
    error_exit "create requires --repo, --title, and --prompt" 3
  fi
  
  init_schema
  
  local escaped_repo
  escaped_repo="$(sql_escape "$REPO")"
  local escaped_title
  escaped_title="$(sql_escape "$TITLE")"
  local escaped_prompt
  escaped_prompt="$(sql_escape "$PROMPT")"
  
  # Generate conversation ID
  local conversation_id
  conversation_id="conv-$(date +%s)-$$-$(printf '%s' "$REPO:$TITLE" | md5sum | cut -d' ' -f1 | cut -c1-8)"
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Create GitHub Issue
  local issue_body
  issue_body="$(cat <<EOF
# ${TITLE}

## Task
${PROMPT}

---
*Created by Manul conversation orchestrator*
EOF
)"
  
  
  local issue_url
  local issue_number

  if command -v gh >/dev/null 2>&1; then
    local gh_response
    gh_response="$(gh issue create \
      --repo "$REPO" \
      --title "$TITLE" \
      --body "$issue_body" \
      --json url,number \
      2>/dev/null)" || {
      error_exit "GitHub issue creation failed" 1
    }

    issue_number="$(printf '%s' "$gh_response" | jq -r '.number // empty' 2>/dev/null)"
    issue_url="$(printf '%s' "$gh_response" | jq -r '.url // empty' 2>/dev/null)"

    if [ -z "$issue_number" ] || ! [[ "$issue_number" =~ ^[0-9]+$ ]] || [ "$issue_number" -le 0 ] || [ -z "$issue_url" ]; then
      error_exit "GitHub issue creation returned invalid response" 1
    fi
  else
    error_exit "GitHub CLI (gh) is required to create the conversation issue" 1
  fi
  
  # Insert conversation record
  sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt)
    VALUES('$conversation_id', '$escaped_repo', $issue_number, '$(sql_escape "$issue_url")', 'OPEN', '$now', '$now');"
  
  # Submit initial task
  local task_id
  task_id="task-${conversation_id}-init-$(date +%s)"
  
  local lease_expires
  lease_expires="$(date -u -d "now + 900 seconds" +%Y-%m-%dT%H:%M:%SZ)"
  
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt, heartbeatAt, leaseExpiresAt, conversationId, parentTaskId, action)
    VALUES('$task_id', '$escaped_repo', $issue_number, '$(sql_escape "$issue_url")', 'orchestrator', '${AGENT:-coder}', '$escaped_prompt', 'queued', '$now', '$now', '$lease_expires', '$conversation_id', NULL, 'IMPLEMENT');"
  
  # Update conversation with active task
  sqlite3 "$DB" "UPDATE conversations SET activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$conversation_id';"
  
  # Output result
  local result
  # Escape issueUrl for JSON
  local escaped_issue_url
  escaped_issue_url="${issue_url//\\/\\\\}"
  escaped_issue_url="${escaped_issue_url//\"/\\\"}"
  result="{\"conversationId\": \"$conversation_id\", \"issueNumber\": $issue_number, \"issueUrl\": \"$escaped_issue_url\", \"status\": \"OPEN\", \"activeTaskId\": \"$task_id\", \"action\": \"create\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation created:"
    echo "  conversationId: $conversation_id"
    echo "  issueNumber: $issue_number"
    echo "  issueUrl: $issue_url"
    echo "  activeTaskId: $task_id"
  fi
}

# Submit a task into an existing conversation
cmd_submit() {
  if [ -z "$CONVERSATION_ID" ] || [ -z "$PROMPT" ]; then
    error_exit "submit requires --conversation-id and --prompt" 3
  fi
  
  init_schema
  
  # Verify conversation exists
  local conv_exists
  conv_exists="$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  if [ "$conv_exists" = "0" ]; then
    error_exit "Conversation not found: $CONVERSATION_ID" 2
  fi
  
  # Get conversation details
  local conv_repo conv_issue_num conv_status
  conv_repo="$(sqlite3 "$DB" "SELECT repository FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  conv_issue_num="$(sqlite3 "$DB" "SELECT issueNumber FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  conv_status="$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  
  # Validate action type
  local action="${ACTION_TYPE:-IMPLEMENT}"
  case "$action" in
    IMPLEMENT|REVIEW_FIX|VERIFY|INVESTIGATE|FINALIZE) ;;
    *) error_exit "Invalid action: $action. Must be one of: IMPLEMENT, REVIEW_FIX, VERIFY, INVESTIGATE, FINALIZE" 3 ;;
  esac
  
  # Check for concurrent tasks on same conversation
  local running_count
  running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status='running';" 2>/dev/null)"
  
  if [ "$running_count" -gt 0 ] && [ "$action" = "REVIEW_FIX" ] && [ -n "$PR_NUMBER" ]; then
    # Allow review-fix to proceed even with running tasks (race condition handling)
    :
  elif [ "$running_count" -gt 0 ] && [ "$conv_status" != "REVIEW" ] && [ "$conv_status" != "FIXING" ]; then
    error_exit "Conversation has running tasks. Wait for completion before submitting." 3
  fi
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local lease_expires
  lease_expires="$(date -u -d "now + 900 seconds" +%Y-%m-%dT%H:%M:%SZ)"
  
  # Generate task ID
  local task_id
  if [ "$action" = "REVIEW_FIX" ] && [ -n "$PR_NUMBER" ]; then
    if [ -z "$REVIEW_ID" ]; then
      error_exit "REVIEW_FIX action requires --review-id for deterministic task identity" 3
    fi
    # Deterministic ID for crash-safe idempotency: same review always gets same task
    # Invariant: same repo + same PR + same review ID => same task
    task_id="review-fix-${CONVERSATION_ID}-${REVIEW_ID}"
  else
    task_id="task-${CONVERSATION_ID}-$(date +%s)-$$"
  fi
  
  # Build context for task
  local context="action=${action};conversationId=${CONVERSATION_ID}"
  if [ -n "$PARENT_TASK_ID" ]; then
    context="${context};parentTaskId=${PARENT_TASK_ID}"
  fi
  if [ -n "$PR_NUMBER" ]; then
    context="${context};prNumber=${PR_NUMBER}"
  fi
  
  # Escape values for SQL
  local escaped_prompt escaped_context
  escaped_prompt="$(sql_escape "$PROMPT")"
  escaped_context="$(sql_escape "$context")"

  # Atomic submit: INSERT + UPDATE in single transaction with retry
  local max_retries=10
  local retry=0
  local submit_success=false
  local submit_err=""

  while [ "$submit_success" = false ] && [ $retry -lt $max_retries ]; do
    submit_err="$(sqlite3 "$DB" "
      BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, context, status, createdAt, heartbeatAt, leaseExpiresAt, conversationId, parentTaskId, action, prNumber)
        VALUES('$task_id', '$(sql_escape "$conv_repo")', $conv_issue_num, 'https://github.com/${conv_repo}/issues/${conv_issue_num}', 'orchestrator', '${AGENT:-coder}', '$escaped_prompt', '$escaped_context', 'queued', '$now', '$now', '$lease_expires', '$CONVERSATION_ID', '$(sql_escape "${PARENT_TASK_ID:-}")', '$action', ${PR_NUMBER:-NULL});
      $(case "$action" in
         REVIEW_FIX) echo "UPDATE conversations SET status='FIXING', activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';";;
         IMPLEMENT) echo "UPDATE conversations SET status='WORKING', activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';";;
         VERIFY|INVESTIGATE) echo "UPDATE conversations SET activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';";;
         FINALIZE) echo "UPDATE conversations SET status='WORKING', activeTaskId='$task_id', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';";;
       esac)
      COMMIT;
    " 2>&1)" && submit_success=true || {
      retry=$((retry + 1))
      if [ $retry -ge $max_retries ]; then
        echo "ERROR: submit failed after $max_retries retries: $submit_err" >&2
        return 1
      fi
      # Check if error is transient (database locked) or permanent
      if echo "$submit_err" | grep -q "database is locked"; then
        sleep "0.0$((retry * 2))"
      else
        echo "ERROR: submit failed: $submit_err" >&2
        return 1
      fi
    }
  done

  # Verify task was created (or already existed)
  local canonical_task
  canonical_task="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE commentId='$task_id' LIMIT 1;" 2>/dev/null)" || true
  if [ -z "$canonical_task" ]; then
    error_exit "Task not found after submit: $task_id" 1
  fi

  local result
  result="{\"taskId\": \"$task_id\", \"conversationId\": \"$CONVERSATION_ID\", \"status\": \"queued\", \"action\": \"$action\", \"repo\": \"$conv_repo\", \"issue\": $conv_issue_num}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Task submitted:"
    echo "  taskId: $task_id"
    echo "  conversationId: $CONVERSATION_ID"
    echo "  action: $action"
    echo "  status: queued"
  fi
}

# Get conversation status
cmd_status() {
  if [ -z "$CONVERSATION_ID" ]; then
    error_exit "status requires --conversation-id" 3
  fi
  
  init_schema
  
  # Get conversation info
  local conv_row
  conv_row="$(sqlite3 "$DB" "SELECT conversationId, repository, issueNumber, issueUrl, status, activeTaskId, activePrNumber, createdAt, updatedAt FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  
  if [ -z "$conv_row" ]; then
    error_exit "Conversation not found: $CONVERSATION_ID" 2
  fi
  
  IFS='|' read -r conv_id repo issue_num issue_url status active_task active_pr created_at updated_at <<< "$conv_row"
  
  # Get task list for this conversation
  local tasks_json="[]"
  tasks_json="$(sqlite3 -json "$DB" "SELECT commentId as taskId, prompt, status, action, parentTaskId, prNumber, prUrl, createdAt, processedAt FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' ORDER BY createdAt ASC;" 2>/dev/null || echo "[]")"
  
  # Get latest task result if available
  local latest_task_result="null"
  local latest_task_id
  latest_task_id="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status='completed' ORDER BY processedAt DESC LIMIT 1;" 2>/dev/null)"
  
  if [ -n "$latest_task_id" ]; then
    local result_file="$MANUL_DIR/results/$(manul_task_file_key "$latest_task_id").json"
    if [ -f "$result_file" ]; then
      latest_task_result="$(cat "$result_file" | jq -c '. // empty' 2>/dev/null || echo "null")"
    fi
  fi
  
  local result
  result=$(jq -n \
    --arg conversationId "$conv_id" \
    --arg repo "$repo" \
    --argjson issueNumber "${issue_num:-0}" \
    --arg issueUrl "$issue_url" \
    --arg status "$status" \
    --arg activeTaskId "${active_task:-}" \
    --argjson activePrNumber "${active_pr:-null}" \
    --arg createdAt "$created_at" \
    --arg updatedAt "$updated_at" \
    --argjson tasks "$tasks_json" \
    --argjson latestResult "$latest_task_result" \
    '{
      conversationId: $conversationId,
      repository: $repo,
      issueNumber: $issueNumber,
      issueUrl: $issueUrl,
      status: $status,
      activeTaskId: $activeTaskId,
      activePrNumber: $activePrNumber,
      createdAt: $createdAt,
      updatedAt: $updatedAt,
      tasks: $tasks,
      latestResult: $latestResult
    }')
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation: $conv_id"
    echo "  Repository: $repo"
    echo "  Issue: #$issue_num ($issue_url)"
    echo "  Status: $status"
    echo "  Active Task: ${active_task:-none}"
    echo "  Active PR: ${active_pr:-none}"
    echo "  Created: $created_at"
    echo "  Updated: $updated_at"
    echo ""
    echo "Tasks:"
    echo "$tasks_json" | jq -r '.[] | "  \(.taskId) [\(.status)] \(.action): \(.prompt[0:60])..."' 2>/dev/null || echo "  (no tasks)"
  fi
}

# Get task result
cmd_result() {
  if [ -z "$TASK_ID" ]; then
    error_exit "result requires --task-id" 3
  fi
  
  init_schema
  
  # Get task from DB
  local task_row
  task_row="$(sqlite3 "$DB" "SELECT commentId, status, action, conversationId, prNumber, prUrl, repository, issueNumber, processedAt FROM processed_comments WHERE commentId='$(sql_escape "$TASK_ID")';" 2>/dev/null)"
  
  if [ -z "$task_row" ]; then
    error_exit "Task not found: $TASK_ID" 2
  fi
  
  IFS='|' read -r task_id status action conv_id pr_num pr_url repo issue_num processed_at <<< "$task_row"
  local result_json=""
  
  # Try to get result from file
  local result_file="$MANUL_DIR/results/$(manul_task_file_key "$TASK_ID").json"
  local final_result="{}"
  
  if [ -f "$result_file" ]; then
    final_result="$(cat "$result_file" 2>/dev/null || echo "{}")"
  fi
  
  # Determine next action based on conversation state
  local next_action="none"
  if [ -n "$conv_id" ]; then
    local conv_status
    conv_status="$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='$(sql_escape "$conv_id")';" 2>/dev/null)"
    case "$conv_status" in
      WORKING) next_action="wait_for_completion" ;;
      REVIEW) next_action="request_review" ;;
      FIXING) next_action="submit_review_fix" ;;
      COMPLETED) next_action="none" ;;
      *) next_action="check_status" ;;
    esac
  fi
  
  local result
  # Build JSON manually to avoid jq issues with multiline content
  result=$(cat <<EOF
{
  "taskId": $(printf '%s' "$task_id" | jq -Rs .),
  "status": $(printf '%s' "$status" | jq -Rs .),
  "action": $(printf '%s' "$action" | jq -Rs .),
  "conversationId": $(printf '%s' "${conv_id:-}" | jq -Rs .),
  "prNumber": ${pr_num:-null},
  "prUrl": $(printf '%s' "$pr_url" | jq -Rs .),
  "repository": $(printf '%s' "$repo" | jq -Rs .),
  "issueNumber": ${issue_num:-0},
  "processedAt": $(printf '%s' "${processed_at:-}" | jq -Rs .),
  "result": $final_result,
  "nextAction": $(printf '%s' "$next_action" | jq -Rs .)
}
EOF
)
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Task Result: $task_id"
    echo "  Status: $status"
    echo "  Action: $action"
    echo "  Conversation: $conv_id"
    echo "  PR: ${pr_num:-none} (${pr_url:-none})"
    echo "  Processed: ${processed_at:-not yet}"
    if [ -n "$final_result" ] && [ "$final_result" != "null" ]; then
      echo ""
      echo "Result:"
      echo "$final_result" | jq . 2>/dev/null || echo "$final_result"
    fi
  fi
}

# Close a conversation
cmd_close() {
  if [ -z "$CONVERSATION_ID" ]; then
    error_exit "close requires --conversation-id" 3
  fi
  
  init_schema
  
  # Verify conversation exists
  local conv_exists
  conv_exists="$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null)"
  if [ "$conv_exists" = "0" ]; then
    error_exit "Conversation not found: $CONVERSATION_ID" 2
  fi
  
  # Check all tasks are complete
  local incomplete
  incomplete="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status IN ('queued', 'running', 'blocked_user');" 2>/dev/null)"
  
  if [ "$incomplete" -gt 0 ]; then
    error_exit "Cannot close conversation with incomplete tasks" 3
  fi
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Update conversation status
  sqlite3 "$DB" "UPDATE conversations SET status='COMPLETED', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';"
  
  local result
  result="{\"conversationId\": \"$CONVERSATION_ID\", \"status\": \"COMPLETED\", \"closedAt\": \"$now\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation $CONVERSATION_ID marked as COMPLETED"
  fi
}

# Main dispatch
case "${ACTION:-}" in
  create) cmd_create ;;
  submit) cmd_submit ;;
  status) cmd_status ;;
  result) cmd_result ;;
  close) cmd_close ;;
  init-schema)
    # Lightweight schema initializer — only runs CREATE IF NOT EXISTS, no business logic.
    # Used by repair-manul-runtime.sh and tests to bring a fresh DB up to schema spec.
    export MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
    export DB="${DB:-$MANUL_DB}"
    init_schema
    ;;
  "")
    echo "Usage: manul-conversation <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  init-schema  Initialize or validate DB schema (idempotent, no business logic)" >&2
    echo "  create   --repo REPO --title TITLE --prompt PROMPT [--json]" >&2
    echo "  submit   --conversation-id ID --prompt PROMPT [--action ACTION] [--parent-task-id ID] [--pr-number N] [--json]" >&2
    echo "  status   --conversation-id ID [--json]" >&2
    echo "  result   --task-id ID [--json]" >&2
    echo "  close    --conversation-id ID [--json]" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
