#!/bin/bash
# manul-orchestrator.sh - External orchestration layer for Manul
#
# This script provides a state-machine-driven orchestrator that can:
# - Create conversations
# - Submit and manage tasks
# - Wait for task completion
# - Inspect PRs
# - Submit review-fix tasks
# - Handle multi-cycle review/fix workflows
#
# The orchestrator is a CLIENT/CONTROL layer above Manul's existing CLI.
# It does NOT duplicate Manul's internal systems.
#
# Usage:
#   manul-orchestrator.sh create    --repo REPO --title TITLE --prompt PROMPT [--json]
#   manul-orchestrator.sh submit    --conversation-id ID --prompt PROMPT [--action ACTION] [--pr-number N] [--parent-task-id ID] [--json]
#   manul-orchestrator.sh wait      --task-id ID [--timeout SECONDS] [--json]
#   manul-orchestrator.sh status    --conversation-id ID [--json]
#   manul-orchestrator.sh result    --task-id ID [--json]
#   manul-orchestrator.sh review    --task-id ID --decision APPROVE|REQUEST_CHANGES|--pr-number N [--json]
#   manul-orchestrator.sh fix       --conversation-id ID --prompt PROMPT --task-id ID [--pr-number N] [--json]
#   manul-orchestrator.sh run       --repo REPO --title TITLE --prompt PROMPT [--max-review-cycles N] [--json]
#   manul-orchestrator.sh close     --conversation-id ID [--json]
#
# State machine:
#   NEW -> SUBMITTING -> RUNNING -> PR_READY -> REVIEWING -> (APPROVED | CHANGES)
#                                                     |                    |
#                                                     v                    v
#                                                  COMPLETE           FIXING -> RUNNING -> PR_READY
#
# JSON stdout contains ONLY JSON. Errors go to stderr.
# Exit codes: 0=success, 1=failure, 2=not found, 3=bad request, 4=timeout
#
# Orchestration state is persisted in ORCHESTRATOR_DIR/orchestrator.db

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"

# Directory configuration
ORCHESTRATOR_DIR="${ORCHESTRATOR_DIR:-${MANUL_ORCHESTRATOR_DIR:-${MANUL_DIR:-$HOME/.manul}}}"
ORCH_DB="${ORCHESTRATOR_DIR}/orchestrator.db"
MANUL_CONV="${ORCHESTRATOR_DIR}/manul-conversation.sh"
MANUL_WAIT="${ORCHESTRATOR_DIR}/manul-wait.sh"
REVIEWER_SCRIPT="${ORCHESTRATOR_DIR}/orchestrator-reviewer.sh"

# JSON output flag
JSON_OUTPUT=false
DRY_RUN=false

# Parse global options
ACTION=""
REPO=""
TITLE=""
PROMPT=""
CONVERSATION_ID=""
TASK_ID=""
ACTION_TYPE=""
PR_NUMBER=""
PARENT_TASK_ID=""
TIMEOUT=""
MAX_REVIEW_CYCLES=""
DECISION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --conversation-id) CONVERSATION_ID="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --action) ACTION_TYPE="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --parent-task-id) PARENT_TASK_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --max-review-cycles) MAX_REVIEW_CYCLES="$2"; shift 2 ;;
    --decision) DECISION="$2"; shift 2 ;;
    create|submit|wait|status|result|review|fix|run|close) ACTION="$1"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

# ============================================================================
# SQL helpers
# ============================================================================
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# ============================================================================
# Error handling
# ============================================================================
error_exit() {
  local msg="$1"
  local code="${2:-1}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "{\"error\": $(printf '%s' "$msg" | jq -Rs .), \"code\": $code}" >&2
  else
    echo "ERROR: $msg" >&2
  fi
  exit "$code"
}

# ============================================================================
# Database initialization
# ============================================================================
init_orchestrator_db() {
  mkdir -p "$ORCHESTRATOR_DIR"
  
  sqlite3 "$ORCH_DB" "CREATE TABLE IF NOT EXISTS conversations (
    conversationId TEXT PRIMARY KEY,
    repo TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    issueUrl TEXT NOT NULL,
    title TEXT NOT NULL,
    initialState TEXT NOT NULL DEFAULT 'NEW',
    currentPhase TEXT NOT NULL DEFAULT 'NEW',
    currentTaskId TEXT,
    prNumber TEXT,
    prUrl TEXT,
    reviewCycle INTEGER NOT NULL DEFAULT 0,
    maxReviewCycles INTEGER NOT NULL DEFAULT 3,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
  );"
  
  sqlite3 "$ORCH_DB" "CREATE TABLE IF NOT EXISTS task_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversationId TEXT NOT NULL,
    taskId TEXT NOT NULL,
    action TEXT NOT NULL,
    status TEXT NOT NULL,
    prNumber INTEGER,
    parentTaskId TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    createdAt TEXT NOT NULL,
    completedAt TEXT,
    FOREIGN KEY (conversationId) REFERENCES conversations(conversationId)
  );"
  
  sqlite3 "$ORCH_DB" "CREATE TABLE IF NOT EXISTS review_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversationId TEXT NOT NULL,
    taskId TEXT NOT NULL,
    decision TEXT NOT NULL,
    feedback TEXT,
    createdAt TEXT NOT NULL,
    FOREIGN KEY (conversationId) REFERENCES conversations(conversationId)
  );"
}

# ============================================================================
# Helper: get orchestrator state
# ============================================================================
get_conversation_state() {
  local conv_id="$1"
  sqlite3 "$ORCH_DB" "SELECT conversationId, repo, issueNumber, issueUrl, title, initialState, currentPhase, currentTaskId, prNumber, prUrl, reviewCycle, maxReviewCycles, createdAt, updatedAt FROM conversations WHERE conversationId='$(sql_escape "$conv_id")';" 2>/dev/null
}

get_task_result() {
  local task_id="$1"
  local result_file="$ORCHESTRATOR_DIR/results/$(manul_task_file_key "$task_id").json"
  if [ -f "$result_file" ]; then
    cat "$result_file"
  else
    echo "{}"
  fi
}

# ============================================================================
# Command: create
# ============================================================================
cmd_create() {
  if [ -z "$REPO" ] || [ -z "$TITLE" ] || [ -z "$PROMPT" ]; then
    error_exit "create requires --repo, --title, and --prompt" 3
  fi
  
  init_orchestrator_db
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Check for existing conversation with same repo/title
  local existing
  existing="$(sqlite3 "$ORCH_DB" "SELECT conversationId FROM conversations WHERE repo='$(sql_escape "$REPO")' AND title='$(sql_escape "$TITLE")' AND currentPhase != 'COMPLETED' LIMIT 1;" 2>/dev/null)"
  
  if [ -n "$existing" ] && [ "$DRY_RUN" = false ]; then
    # Resume existing conversation
    local conv_state
    conv_state="$(get_conversation_state "$existing")"
    IFS='|' read -r _ _ _ _ _ _ current_phase current_task _ _ _ review_cycle _ _ _ <<< "$conv_state"
    
    if [ "$current_phase" = "APPROVED" ] || [ "$current_phase" = "COMPLETED" ]; then
      # Create new conversation
      :
    else
      # Resume existing
      local result
      result="{\"conversationId\": \"$existing\", \"resumed\": true, \"phase\": \"$current_phase\", \"status\": \"exists\"}"
      if [ "$JSON_OUTPUT" = true ]; then
        echo "$result" | jq .
      else
        echo "Resuming existing conversation: $existing"
      fi
      return 0
    fi
  fi
  
  # Create conversation via Manul CLI
  local conv_output
  if [ "$DRY_RUN" = true ]; then
    echo "{\"conversationId\": \"dry-run-$(date +%s)\", \"issueNumber\": 0, \"issueUrl\": \"https://github.com/${REPO}/issues/0\", \"status\": \"OPEN\", \"phase\": \"NEW\", \"dryRun\": true}"
    return 0
  fi
  
  conv_output="$(bash "$MANUL_CONV" create \
    --repo "$REPO" \
    --title "$TITLE" \
    --prompt "$PROMPT" \
    --json 2>/dev/null)" || error_exit "Failed to create conversation" 1
  
  local conversation_id
  conversation_id="$(echo "$conv_output" | jq -r '.conversationId // empty')"
  
  if [ -z "$conversation_id" ]; then
    error_exit "Invalid conversation response" 1
  fi
  
  local issue_number issue_url
  issue_number="$(echo "$conv_output" | jq -r '.issueNumber // 0')"
  issue_url="$(echo "$conv_output" | jq -r '.issueUrl // empty')"
  
  # Get initial task ID
  local initial_task_id
  initial_task_id="$(echo "$conv_output" | jq -r '.activeTaskId // empty')"
  
  # Store in orchestrator DB
  sqlite3 "$ORCH_DB" "INSERT OR REPLACE INTO conversations(conversationId, repo, issueNumber, issueUrl, title, initialState, currentPhase, currentTaskId, reviewCycle, maxReviewCycles, createdAt, updatedAt)
    VALUES('$conversation_id', '$(sql_escape "$REPO")', $issue_number, '$(sql_escape "$issue_url")', '$(sql_escape "$TITLE")', 'NEW', 'SUBMITTING', '$initial_task_id', 0, ${MAX_REVIEW_CYCLES:-3}, '$now', '$now');"
  
  # Record task history
  sqlite3 "$ORCH_DB" "INSERT INTO task_history(conversationId, taskId, action, status, createdAt)
    VALUES('$conversation_id', '$initial_task_id', 'IMPLEMENT', 'queued', '$now');"
  
  local result
  result="{\"conversationId\": \"$conversation_id\", \"issueNumber\": $issue_number, \"issueUrl\": \"$issue_url\", \"initialTaskId\": \"$initial_task_id\", \"phase\": \"SUBMITTING\", \"status\": \"created\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation created:"
    echo "  conversationId: $conversation_id"
    echo "  issueNumber: #$issue_number"
    echo "  phase: SUBMITTING"
  fi
}

# ============================================================================
# Command: submit
# ============================================================================
cmd_submit() {
  if [ -z "$CONVERSATION_ID" ] || [ -z "$PROMPT" ]; then
    error_exit "submit requires --conversation-id and --prompt" 3
  fi
  
  init_orchestrator_db
  
  local action="${ACTION_TYPE:-IMPLEMENT}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Check if conversation exists in orchestrator DB
  local conv_state
  conv_state="$(get_conversation_state "$CONVERSATION_ID")"
  
  if [ -z "$conv_state" ]; then
    error_exit "Conversation not found in orchestrator: $CONVERSATION_ID" 2
  fi
  
  # Submit via Manul CLI
  local submit_args=(
    --conversation-id "$CONVERSATION_ID"
    --prompt "$PROMPT"
    --action "$action"
  )
  
  if [ -n "$PR_NUMBER" ]; then
    submit_args+=(--pr-number "$PR_NUMBER")
  fi
  
  if [ -n "$PARENT_TASK_ID" ]; then
    submit_args+=(--parent-task-id "$PARENT_TASK_ID")
  fi
  
  local submit_output
  if [ "$DRY_RUN" = true ]; then
    echo "{\"taskId\": \"dry-run-$(date +%s)\", \"conversationId\": \"$CONVERSATION_ID\", \"action\": \"$action\", \"phase\": \"SUBMITTING\", \"dryRun\": true}"
    return 0
  fi
  
  submit_output="$(bash "$MANUL_CONV" submit "${submit_args[@]}" --json 2>/dev/null)" || error_exit "Failed to submit task" 1
  
  local task_id
  task_id="$(echo "$submit_output" | jq -r '.taskId // empty')"
  
  if [ -z "$task_id" ]; then
    error_exit "Invalid submit response" 1
  fi
  
  # Update orchestrator state
  sqlite3 "$ORCH_DB" "UPDATE conversations SET currentTaskId='$task_id', currentPhase='SUBMITTING', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';"
  
  # Record task history
  sqlite3 "$ORCH_DB" "INSERT INTO task_history(conversationId, taskId, action, status, prNumber, parentTaskId, createdAt)
    VALUES('$CONVERSATION_ID', '$task_id', '$action', 'queued', ${PR_NUMBER:-NULL}, '$(sql_escape "${PARENT_TASK_ID:-}")', '$now');"
  
  local result
  result="{\"taskId\": \"$task_id\", \"conversationId\": \"$CONVERSATION_ID\", \"action\": \"$action\", \"phase\": \"SUBMITTING\", \"status\": \"submitted\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Task submitted:"
    echo "  taskId: $task_id"
    echo "  action: $action"
    echo "  phase: SUBMITTING"
  fi
}

# ============================================================================
# Command: wait
# ============================================================================
cmd_wait() {
  if [ -z "$TASK_ID" ]; then
    error_exit "wait requires --task-id" 3
  fi
  
  init_orchestrator_db
  
  local timeout="${TIMEOUT:-600}"  # Default 10 minutes
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Find conversation for this task
  local conv_id
  conv_id="$(sqlite3 "$ORCH_DB" "SELECT conversationId FROM task_history WHERE taskId='$TASK_ID' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    # Try to get from Manul DB directly. sqlite3 creates a new database file
    # when given a missing path, even for a SELECT; do not turn a not-found
    # lookup into an empty production database before manul-wait handles it.
    local db="$MANUL_DB"
    if [ -f "$db" ]; then
      conv_id="$(sqlite3 "$db" "SELECT conversationId FROM processed_comments WHERE commentId='$(sql_escape "$TASK_ID")' LIMIT 1;" 2>/dev/null || echo "")"
    fi
  fi
  
  # Wait via Manul CLI
  if [ "$DRY_RUN" = true ]; then
    echo "{\"taskId\": \"$TASK_ID\", \"phase\": \"WAITING\", \"timeout\": $timeout, \"dryRun\": true}"
    return 0
  fi
  
  local wait_output wait_rc=0
  wait_output="$(bash "$MANUL_WAIT" --task-id "$TASK_ID" --timeout "$timeout" --json 2>/dev/null)" || wait_rc=$?
  if [ "$wait_rc" -ne 0 ]; then
    case "$wait_rc" in
      2)
        # A missing Manul DB/task is an expected query result, not a generic
        # wrapper failure. Preserve the machine-readable not_found payload.
        if [ -n "$wait_output" ] && printf '%s' "$wait_output" | jq -e '.status == "not_found"' >/dev/null 2>&1; then
          if [ "$JSON_OUTPUT" = true ]; then
            printf '%s\n' "$wait_output" | jq .
          else
            printf '%s\n' "$wait_output" | jq -r '.error // "Task not found"'
          fi
          return 2
        fi
        error_exit "Wait failed" "$wait_rc"
        ;;
      4) error_exit "Task wait timed out" 4 ;;
      *) error_exit "Wait failed" "$wait_rc" ;;
    esac
  fi
  
  local task_status task_result
  task_status="$(echo "$wait_output" | jq -r '.status // empty')"
  task_result="$(echo "$wait_output" | jq '. // {}')"
  
  # Update orchestrator state
  if [ -n "$conv_id" ]; then
    sqlite3 "$ORCH_DB" "UPDATE conversations SET currentPhase='RUNNING', updatedAt='$now' WHERE conversationId='$conv_id';"
    
    # Update task history
    sqlite3 "$ORCH_DB" "UPDATE task_history SET status='$task_status', completedAt='$now', resultJson=$(printf '%s' "$task_result" | jq -Rs .) WHERE taskId='$TASK_ID';"
  fi
  
  local phase="RUNNING"
  case "$task_status" in
    completed) phase="PR_READY" ;;
    failed) phase="FAILED" ;;
    *) phase="WAITING" ;;
  esac
  
  local result
  result=$(jq -n \
    --arg taskId "$TASK_ID" \
    --arg convId "${conv_id:-}" \
    --arg status "$task_status" \
    --arg phase "$phase" \
    --argjson result "$task_result" \
    '{
      taskId: $taskId,
      conversationId: $convId,
      status: $status,
      phase: $phase,
      result: $result
    }')
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Task $TASK_ID completed:"
    echo "  status: $task_status"
    echo "  phase: $phase"
  fi
}

# ============================================================================
# Command: status
# ============================================================================
cmd_status() {
  if [ -z "$CONVERSATION_ID" ]; then
    error_exit "status requires --conversation-id" 3
  fi
  
  init_orchestrator_db
  
  local conv_state
  conv_state="$(get_conversation_state "$CONVERSATION_ID")"
  
  if [ -z "$conv_state" ]; then
    error_exit "Conversation not found in orchestrator: $CONVERSATION_ID" 2
  fi
  
  IFS='|' read -r cid repo issue_num issue_url title initial_phase current_phase current_task pr_num pr_url review_cycle max_cycles created updated <<< "$conv_state"
  
  # Get task history
  local tasks_json
  tasks_json="$(sqlite3 -json "$ORCH_DB" "SELECT taskId, action, status, prNumber, parentTaskId, createdAt, completedAt FROM task_history WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' ORDER BY createdAt ASC;" 2>/dev/null || echo "[]")"
  
  # Get review history
  local reviews_json
  reviews_json="$(sqlite3 -json "$ORCH_DB" "SELECT taskId, decision, feedback, createdAt FROM review_history WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' ORDER BY createdAt ASC;" 2>/dev/null || echo "[]")"
  
  # Get latest task result
  local latest_result="{}"
  if [ -n "$current_task" ]; then
    latest_result="$(get_task_result "$current_task")"
  fi
  
  local result
  result=$(jq -n \
    --arg conversationId "$cid" \
    --arg repo "$repo" \
    --argjson issueNumber "${issue_num:-0}" \
    --arg issueUrl "$issue_url" \
    --arg title "$title" \
    --arg initialPhase "$initial_phase" \
    --arg currentPhase "$current_phase" \
    --arg currentTaskId "${current_task:-}" \
    --argjson prNumber "${pr_num:-null}" \
    --arg prUrl "$pr_url" \
    --argjson reviewCycle "${review_cycle:-0}" \
    --argjson maxReviewCycles "${max_cycles:-3}" \
    --arg createdAt "$created" \
    --arg updatedAt "$updated" \
    --argjson tasks "$tasks_json" \
    --argjson reviews "$reviews_json" \
    --argjson latestResult "$latest_result" \
    '{
      conversationId: $conversationId,
      repository: $repo,
      issueNumber: $issueNumber,
      issueUrl: $issueUrl,
      title: $title,
      initialPhase: $initialPhase,
      currentPhase: $currentPhase,
      currentTaskId: $currentTaskId,
      prNumber: $prNumber,
      prUrl: $prUrl,
      reviewCycle: $reviewCycle,
      maxReviewCycles: $maxReviewCycles,
      createdAt: $createdAt,
      updatedAt: $updatedAt,
      tasks: $tasks,
      reviews: $reviews,
      latestResult: $latestResult
    }')
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation: $cid"
    echo "  Repository: $repo"
    echo "  Issue: #$issue_num"
    echo "  Phase: $current_phase"
    echo "  Review Cycle: ${review_cycle:-0}/${max_cycles:-3}"
    if [ -n "$pr_num" ]; then
      echo "  PR: #$pr_num ($pr_url)"
    fi
  fi
}

# ============================================================================
# Command: result
# ============================================================================
cmd_result() {
  if [ -z "$TASK_ID" ]; then
    error_exit "result requires --task-id" 3
  fi
  
  init_orchestrator_db
  
  # Get from Manul CLI
  local result_output
  result_output="$(bash "$MANUL_CONV" result --task-id "$TASK_ID" --json 2>/dev/null)" || error_exit "Failed to get result" 1
  
  # Also check orchestrator DB
  local task_record
  task_record="$(sqlite3 "$ORCH_DB" "SELECT conversationId, action, status, prNumber, parentTaskId, resultSummary, createdAt, completedAt FROM task_history WHERE taskId='$(sql_escape "$TASK_ID")';" 2>/dev/null)"
  
  local conv_id=""
  local action=""
  local status=""
  local pr_num=""
  local parent_id=""
  local summary=""
  
  if [ -n "$task_record" ]; then
    IFS='|' read -r conv_id action status pr_num parent_id summary _ _ <<< "$task_record"
  fi
  
  # Merge with Manul result
  local merged
  merged=$(jq -n \
    --argjson manul "$(echo "$result_output" | jq '. // {}')" \
    --arg convId "$conv_id" \
    --arg action "$action" \
    --arg status "$status" \
    --argjson prNum "${pr_num:-null}" \
    --arg parentId "$parent_id" \
    --arg summary "$summary" \
    '{
      taskId: $manul.taskId,
      conversationId: $convId,
      action: $action,
      status: $status,
      parentTaskId: $parentId,
      prNumber: $prNum,
      prUrl: $manul.prUrl,
      resultSummary: $summary,
      result: $manul.result,
      nextAction: $manul.nextAction
    }')
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$merged" | jq .
  else
    echo "Result for task $TASK_ID"
    echo "  conversationId: $conv_id"
    echo "  action: $action"
    echo "  status: $status"
  fi
}

# ============================================================================
# Command: review
# ============================================================================
cmd_review() {
  if [ -z "$TASK_ID" ]; then
    error_exit "review requires --task-id" 3
  fi
  
  init_orchestrator_db
  
  # Determine decision
  local decision="${DECISION:-}"
  if [ -z "$decision" ]; then
    # Try to use reviewer script
    if [ -f "$REVIEWER_SCRIPT" ]; then
      decision="$(bash "$REVIEWER_SCRIPT" review --task-id "$TASK_ID" --json 2>/dev/null | jq -r '.decision // empty')"
    fi
  fi
  
  if [ -z "$decision" ]; then
    error_exit "No review decision provided. Use --decision APPROVE|REQUEST_CHANGES" 3
  fi
  
  case "$decision" in
    APPROVE|REQUEST_CHANGES|COMMENT|BLOCKED) ;;
    *) error_exit "Invalid decision: $decision. Must be APPROVE, REQUEST_CHANGES, COMMENT, or BLOCKED" 3 ;;
  esac
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Get conversation and task info
  local conv_id task_action pr_num
  conv_id="$(sqlite3 "$ORCH_DB" "SELECT conversationId FROM task_history WHERE taskId='$(sql_escape "$TASK_ID")' LIMIT 1;" 2>/dev/null)"
  task_action="$(sqlite3 "$ORCH_DB" "SELECT action FROM task_history WHERE taskId='$(sql_escape "$TASK_ID")' LIMIT 1;" 2>/dev/null)"
  pr_num="$(sqlite3 "$ORCH_DB" "SELECT prNumber FROM task_history WHERE taskId='$(sql_escape "$TASK_ID")' LIMIT 1;" 2>/dev/null)"
  
  if [ -z "$conv_id" ]; then
    error_exit "Task not found in orchestrator: $TASK_ID" 2
  fi
  
  # Record review history
  sqlite3 "$ORCH_DB" "INSERT INTO review_history(conversationId, taskId, decision, createdAt)
    VALUES('$conv_id', '$TASK_ID', '$decision', '$now');"
  
  # Update conversation state
  local new_phase="REVIEWED"
  case "$decision" in
    APPROVE) new_phase="APPROVED" ;;
    REQUEST_CHANGES) new_phase="CHANGES_REQUESTED" ;;
    BLOCKED) new_phase="BLOCKED" ;;
  esac
  
  sqlite3 "$ORCH_DB" "UPDATE conversations SET currentPhase='$new_phase', updatedAt='$now' WHERE conversationId='$conv_id';"
  
  local result
  result="{\"taskId\": \"$TASK_ID\", \"conversationId\": \"$conv_id\", \"decision\": \"$decision\", \"phase\": \"$new_phase\", \"status\": \"reviewed\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Review completed:"
    echo "  taskId: $TASK_ID"
    echo "  decision: $decision"
    echo "  phase: $new_phase"
  fi
}

# ============================================================================
# Command: fix
# ============================================================================
cmd_fix() {
  if [ -z "$CONVERSATION_ID" ] || [ -z "$PROMPT" ] || [ -z "$TASK_ID" ]; then
    error_exit "fix requires --conversation-id, --prompt, and --task-id" 3
  fi
  
  init_orchestrator_db
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Get conversation info
  local conv_state pr_num review_cycle
  conv_state="$(get_conversation_state "$CONVERSATION_ID")"
  
  if [ -z "$conv_state" ]; then
    error_exit "Conversation not found: $CONVERSATION_ID" 2
  fi
  
  IFS='|' read -r _ _ _ _ _ _ _ _ pr_num _ review_cycle _ _ _ <<< "$conv_state"
  
  # Increment review cycle
  local new_cycle=$(( ${review_cycle:-0} + 1 ))
  
  # Check max cycles
  local max_cycles="${MAX_REVIEW_CYCLES:-3}"
  if [ "$new_cycle" -ge "$max_cycles" ]; then
    error_exit "Maximum review cycles ($max_cycles) exceeded" 3
  fi
  
  # If no PR number in conversation, get from task
  if [ -z "$pr_num" ]; then
    pr_num="$(sqlite3 "$ORCH_DB" "SELECT prNumber FROM task_history WHERE taskId='$(sql_escape "$TASK_ID")' LIMIT 1;" 2>/dev/null)"
  fi
  
  # Submit REVIEW_FIX task
  local fix_args=(
    --conversation-id "$CONVERSATION_ID"
    --prompt "$PROMPT"
    --action REVIEW_FIX
    --parent-task-id "$TASK_ID"
  )

  # The conversation CLI requires a stable review ID whenever REVIEW_FIX
  # targets a PR. The orchestrator does not receive a GitHub review ID, so
  # derive one from the parent task: retries for the same task keep the same
  # identity, while fixes for different parent tasks remain independent.
  local review_id task_hash
  if command -v sha256sum >/dev/null 2>&1; then
    task_hash="$(printf '%s' "$TASK_ID" | sha256sum | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    task_hash="$(printf '%s' "$TASK_ID" | shasum -a 256 | awk '{print $1}')"
  else
    error_exit "REVIEW_FIX requires sha256sum or shasum for deterministic task identity" 1
  fi
  review_id="orchestrator-fix-${task_hash:0:32}"
  fix_args+=(--review-id "$review_id")

  if [ -n "$pr_num" ]; then
    fix_args+=(--pr-number "$pr_num")
  fi
  
  local fix_output
  if [ "$DRY_RUN" = true ]; then
    echo "{\"taskId\": \"dry-run-$(date +%s)\", \"conversationId\": \"$CONVERSATION_ID\", \"action\": \"REVIEW_FIX\", \"phase\": \"FIXING\", \"dryRun\": true}"
    return 0
  fi
  
  fix_output="$(bash "$MANUL_CONV" submit "${fix_args[@]}" --json 2>/dev/null)" || error_exit "Failed to submit fix task" 1
  
  local task_id
  task_id="$(echo "$fix_output" | jq -r '.taskId // empty')"
  
  if [ -z "$task_id" ]; then
    error_exit "Invalid fix submission response" 1
  fi
  
  # Update orchestrator state
  sqlite3 "$ORCH_DB" "UPDATE conversations SET currentTaskId='$task_id', currentPhase='FIXING', prNumber='$pr_num', reviewCycle=$new_cycle, updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';"
  
  # Record task history
  sqlite3 "$ORCH_DB" "INSERT INTO task_history(conversationId, taskId, action, status, prNumber, parentTaskId, createdAt)
    VALUES('$CONVERSATION_ID', '$task_id', 'REVIEW_FIX', 'queued', ${pr_num:-NULL}, '$TASK_ID', '$now');"
  
  local result
  result="{\"taskId\": \"$task_id\", \"conversationId\": \"$CONVERSATION_ID\", \"action\": \"REVIEW_FIX\", \"phase\": \"FIXING\", \"prNumber\": ${pr_num:-null}, \"reviewCycle\": $new_cycle, \"status\": \"submitted\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Fix task submitted:"
    echo "  taskId: $task_id"
    echo "  action: REVIEW_FIX"
    echo "  phase: FIXING"
    echo "  PR: #${pr_num:-unknown}"
    echo "  reviewCycle: $new_cycle"
  fi
}

# ============================================================================
# Command: run
# ============================================================================
cmd_run() {
  if [ -z "$REPO" ] || [ -z "$TITLE" ] || [ -z "$PROMPT" ]; then
    error_exit "run requires --repo, --title, and --prompt" 3
  fi
  
  init_orchestrator_db
  
  local max_review_cycles="${MAX_REVIEW_CYCLES:-3}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Create conversation
  local create_output
  create_output="$(bash "$0" create \
    --repo "$REPO" \
    --title "$TITLE" \
    --prompt "$PROMPT" \
    --max-review-cycles "$max_review_cycles" \
    --json 2>/dev/null)" || error_exit "Failed to create conversation" 1
  
  local conversation_id
  conversation_id="$(echo "$create_output" | jq -r '.conversationId // empty')"
  
  if [ -z "$conversation_id" ]; then
    error_exit "Invalid create response" 1
  fi
  
  local initial_task_id
  initial_task_id="$(echo "$create_output" | jq -r '.initialTaskId // empty')"
  
  # Wait for initial task
  local wait_output
  wait_output="$(bash "$0" wait \
    --task-id "$initial_task_id" \
    --json 2>/dev/null)" || {
      local rc=$?
      error_exit "Initial task failed (rc=$rc)" "$rc"
    }
  
  local task_status
  task_status="$(echo "$wait_output" | jq -r '.status // empty')"
  
  if [ "$task_status" != "completed" ]; then
    error_exit "Initial task did not complete successfully" 1
  fi
  
  # Get PR number from result
  local pr_number
  pr_number="$(echo "$wait_output" | jq -r '.result.prNumber // .prNumber // empty')"
  
  # Update conversation with PR
  if [ -n "$pr_number" ]; then
    sqlite3 "$ORCH_DB" "UPDATE conversations SET prNumber='$pr_number', currentPhase='PR_READY', updatedAt='$now' WHERE conversationId='$conversation_id';"
  fi
  
  # Return workflow result
  local result
  result=$(jq -n \
    --arg conversationId "$conversation_id" \
    --arg initialTaskId "$initial_task_id" \
    --argjson prNumber "${pr_number:-null}" \
    --arg phase "$(sqlite3 "$ORCH_DB" "SELECT currentPhase FROM conversations WHERE conversationId='$conversation_id';" 2>/dev/null || echo "PR_READY")" \
    --argjson maxReviewCycles "$max_review_cycles" \
    '{
      conversationId: $conversationId,
      initialTaskId: $initialTaskId,
      prNumber: $prNumber,
      phase: $phase,
      maxReviewCycles: $maxReviewCycles,
      status: "ready_for_review"
    }')
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Workflow started:"
    echo "  conversationId: $conversation_id"
    echo "  initialTaskId: $initial_task_id"
    if [ -n "$pr_number" ]; then
      echo "  prNumber: $pr_number"
    fi
    echo "  phase: $(echo "$result" | jq -r '.phase')"
    echo ""
    echo "Next steps:"
    echo "  bash $0 review --task-id $initial_task_id --decision APPROVE|REQUEST_CHANGES"
    echo "  bash $0 fix --conversation-id $conversation_id --prompt 'Fix feedback' --task-id $initial_task_id"
  fi
}

# ============================================================================
# Command: close
# ============================================================================
cmd_close() {
  if [ -z "$CONVERSATION_ID" ]; then
    error_exit "close requires --conversation-id" 3
  fi
  
  init_orchestrator_db
  
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  # Check conversation exists
  local conv_state
  conv_state="$(get_conversation_state "$CONVERSATION_ID")"
  
  if [ -z "$conv_state" ]; then
    error_exit "Conversation not found in orchestrator: $CONVERSATION_ID" 2
  fi
  
  IFS='|' read -r _ _ _ _ _ _ current_phase _ _ _ _ _ _ _ <<< "$conv_state"
  
  # Check all tasks are complete
  local incomplete
  incomplete="$(sqlite3 "$ORCH_DB" "SELECT COUNT(*) FROM task_history WHERE conversationId='$(sql_escape "$CONVERSATION_ID")' AND status NOT IN ('completed', 'failed');" 2>/dev/null)"
  
  if [ "${incomplete:-0}" -gt 0 ]; then
    error_exit "Cannot close conversation with incomplete tasks" 3
  fi
  
  # Close via Manul CLI
  if [ "$DRY_RUN" = false ]; then
    bash "$MANUL_CONV" close --conversation-id "$CONVERSATION_ID" --json 2>/dev/null || true
  fi
  
  # Update orchestrator state
  sqlite3 "$ORCH_DB" "UPDATE conversations SET currentPhase='COMPLETED', updatedAt='$now' WHERE conversationId='$CONVERSATION_ID';"
  
  local result
  result="{\"conversationId\": \"$CONVERSATION_ID\", \"phase\": \"COMPLETED\", \"closedAt\": \"$now\"}"
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Conversation $CONVERSATION_ID marked as COMPLETED"
  fi
}

# ============================================================================
# Main dispatch
# ============================================================================
case "${ACTION:-}" in
  create) cmd_create ;;
  submit) cmd_submit ;;
  wait) cmd_wait ;;
  status) cmd_status ;;
  result) cmd_result ;;
  review) cmd_review ;;
  fix) cmd_fix ;;
  run) cmd_run ;;
  close) cmd_close ;;
  "")
    echo "Usage: manul-orchestrator.sh <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  create   --repo REPO --title TITLE --prompt PROMPT [--max-review-cycles N] [--json] [--dry-run]" >&2
    echo "  submit   --conversation-id ID --prompt PROMPT [--action ACTION] [--pr-number N] [--parent-task-id ID] [--json] [--dry-run]" >&2
    echo "  wait     --task-id ID [--timeout SECONDS] [--json]" >&2
    echo "  status   --conversation-id ID [--json]" >&2
    echo "  result   --task-id ID [--json]" >&2
    echo "  review   --task-id ID --decision APPROVE|REQUEST_CHANGES [--json]" >&2
    echo "  fix      --conversation-id ID --prompt PROMPT --task-id ID [--pr-number N] [--json] [--dry-run]" >&2
    echo "  run      --repo REPO --title TITLE --prompt PROMPT [--max-review-cycles N] [--json] [--dry-run]" >&2
    echo "  close    --conversation-id ID [--json]" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
