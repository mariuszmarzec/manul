#!/bin/bash
# manul-conversation-linker.sh - Conversation linking layer for GitHub control protocol
#
# This script provides utilities for linking GitHub objects (issues, PRs, comments)
# to Manul conversations and tasks. It ensures that all GitHub interactions
# maintain proper conversation context.
#
# Conversation Mapping:
#   Issue <-> conversationId (one-to-one for main conversation)
#   PR <-> conversationId (many-to-one, PRs belong to conversations)
#   Comments <-> tasks (comments can trigger tasks)
#   Reviews <-> tasks (reviews trigger review-fix tasks)
#
# Usage:
#   manul-conversation-linker.sh link-issue --repo REPO --issue NUMBER --conversation-id ID
#   manul-conversation-linker.sh link-pr --repo REPO --pr-number N --conversation-id ID
#   manul-conversation-linker.sh get-conversation --repo REPO --issue NUMBER
#   manul-conversation-linker.sh get-conversation --repo REPO --pr-number N
#   manul-conversation-linker.sh get-task --repo REPO --comment-id ID
#   manul-conversation-linker.sh link-task --repo REPO --comment-id ID --conversation-id ID --pr-number N --parent-task-id ID --action ACTION

set -euo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
CONFIG="${MANUL_DIR}/config.json"

# JSON output flag
JSON_OUTPUT=false

# Parse global options
ACTION=""
REPO=""
ISSUE_NUMBER=""
PR_NUMBER=""
CONVERSATION_ID=""
COMMENT_ID=""
PARENT_TASK_ID=""
ACTION_TYPE=""
TASK_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE_NUMBER="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --conversation-id) CONVERSATION_ID="$2"; shift 2 ;;
    --comment-id) COMMENT_ID="$2"; shift 2 ;;
    --parent-task-id) PARENT_TASK_ID="$2"; shift 2 ;;
    --action) ACTION_TYPE="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    link-issue|link-pr|get-conversation|get-task|link-task) ACTION="$1"; shift ;;
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
    echo "{\"error\": $(printf '%s' "$msg" | jq -Rs .), \"code\": $code}" >&2
  else
    echo "ERROR: $msg" >&2
  fi
  exit "$code"
}

# Ensure database schema exists
init_schema() {
  if [ ! -f "$DB" ]; then
    mkdir -p "$(dirname "$DB")"
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversations (
      conversationId TEXT PRIMARY KEY,
      repository TEXT NOT NULL,
      issueNumber INTEGER,
      issueUrl TEXT,
      activePrNumber INTEGER,
      activePrUrl TEXT,
      status TEXT NOT NULL DEFAULT 'OPEN',
      createdAt TEXT NOT NULL,
      updatedAt TEXT NOT NULL
    );"

    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_links (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversationId TEXT NOT NULL,
      repo TEXT NOT NULL,
      issueNumber INTEGER,
      prNumber INTEGER,
      commentId TEXT,
      taskCommentId TEXT,
      linkType TEXT NOT NULL,
      createdAt TEXT NOT NULL,
      FOREIGN KEY (conversationId) REFERENCES conversations(conversationId)
    );"

    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_links_repo_issue ON conversation_links(repo, issueNumber);"
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_links_repo_pr ON conversation_links(repo, prNumber);"
    sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_links_conversation ON conversation_links(conversationId);"
  fi

  # Add columns to processed_comments if missing
  if [ -f "$DB" ]; then
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|conversationId|'; then
      sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;" 2>/dev/null || true
    fi
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|parentTaskId|'; then
      sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;" 2>/dev/null || true
    fi
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|action|'; then
      sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN action TEXT DEFAULT 'IMPLEMENT';" 2>/dev/null || true
    fi
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|prNumber|'; then
      sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;" 2>/dev/null || true
    fi
  fi
}

# Link an issue to a conversation
cmd_link_issue() {
  if [ -z "$REPO" ] || [ -z "$ISSUE_NUMBER" ] || [ -z "$CONVERSATION_ID" ]; then
    error_exit "link-issue requires --repo, --issue, and --conversation-id" 3
  fi

  init_schema

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Get issue URL
  local issue_url=""
  if command -v gh >/dev/null 2>&1; then
    issue_url="$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json url --jq '.url // empty' 2>/dev/null || echo "")"
  fi
  [ -z "$issue_url" ] && issue_url="https://github.com/${REPO}/issues/${ISSUE_NUMBER}"

  # Insert or update conversation
  sqlite3 "$DB" "INSERT OR REPLACE INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt)
    VALUES('$(sql_escape "$CONVERSATION_ID")', '$(sql_escape "$REPO")', $ISSUE_NUMBER, '$(sql_escape "$issue_url")', 'OPEN', '$now', '$now');" 2>/dev/null || true

  # Create link
  sqlite3 "$DB" "INSERT OR IGNORE INTO conversation_links(conversationId, repo, issueNumber, linkType, createdAt)
    VALUES('$(sql_escape "$CONVERSATION_ID")', '$(sql_escape "$REPO")', $ISSUE_NUMBER, 'ISSUE', '$now');" 2>/dev/null || true

  local result
  result=$(jq -n \
    --arg conversationId "$CONVERSATION_ID" \
    --arg repo "$REPO" \
    --argjson issueNumber "$ISSUE_NUMBER" \
    --arg issueUrl "$issue_url" \
    --arg timestamp "$now" \
    '{
      conversationId: $conversationId,
      repo: $repo,
      issueNumber: $issueNumber,
      issueUrl: $issueUrl,
      linkType: "ISSUE",
      timestamp: $timestamp,
      status: "linked"
    }')

  echo "$result" | jq .
}

# Link a PR to a conversation
cmd_link_pr() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ] || [ -z "$CONVERSATION_ID" ]; then
    error_exit "link-pr requires --repo, --pr-number, and --conversation-id" 3
  fi

  init_schema

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Get PR URL
  local pr_url=""
  if command -v gh >/dev/null 2>&1; then
    pr_url="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json url --jq '.url // empty' 2>/dev/null || echo "")"
  fi
  [ -z "$pr_url" ] && pr_url="https://github.com/${REPO}/pull/${PR_NUMBER}"

  # Update conversation with PR
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=$PR_NUMBER, activePrUrl='$(sql_escape "$pr_url")', updatedAt='$now' WHERE conversationId='$(sql_escape "$CONVERSATION_ID")';" 2>/dev/null || true

  # Create link
  sqlite3 "$DB" "INSERT OR IGNORE INTO conversation_links(conversationId, repo, prNumber, linkType, createdAt)
    VALUES('$(sql_escape "$CONVERSATION_ID")', '$(sql_escape "$REPO")', $PR_NUMBER, 'PR', '$now');" 2>/dev/null || true

  local result
  result=$(jq -n \
    --arg conversationId "$CONVERSATION_ID" \
    --arg repo "$REPO" \
    --argjson prNumber "$PR_NUMBER" \
    --arg prUrl "$pr_url" \
    --arg timestamp "$now" \
    '{
      conversationId: $conversationId,
      repo: $repo,
      prNumber: $prNumber,
      prUrl: $prUrl,
      linkType: "PR",
      timestamp: $timestamp,
      status: "linked"
    }')

  echo "$result" | jq .
}

# Get conversation for an issue or PR
cmd_get_conversation() {
  if [ -z "$REPO" ]; then
    error_exit "get-conversation requires --repo" 3
  fi

  init_schema

  local conv_id=""

  if [ -n "${ISSUE_NUMBER:-}" ]; then
    conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='$(sql_escape "$REPO")' AND issueNumber=$ISSUE_NUMBER AND status='OPEN' ORDER BY updatedAt DESC LIMIT 1;" 2>/dev/null || echo "")"
  elif [ -n "${PR_NUMBER:-}" ]; then
    # Check for direct PR association
    conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='$(sql_escape "$REPO")' AND activePrNumber=$PR_NUMBER AND status != 'COMPLETED' ORDER BY updatedAt DESC LIMIT 1;" 2>/dev/null || echo "")"

    # If no direct association, check links
    if [ -z "$conv_id" ]; then
      conv_id="$(sqlite3 "$DB" "SELECT cl.conversationId FROM conversation_links cl WHERE cl.repo='$(sql_escape "$REPO")' AND cl.prNumber=$PR_NUMBER ORDER BY cl.createdAt DESC LIMIT 1;" 2>/dev/null || echo "")"
    fi
  fi

  if [ -z "$conv_id" ]; then
    # Generate conversation ID from repo+object hash
    local obj_id="${ISSUE_NUMBER:-${PR_NUMBER:-}}"
    conv_id="conv-$(printf '%s-%s' "$REPO" "$obj_id" | md5sum | cut -d' ' -f1 | cut -c1-8)"
  fi

  # Get full conversation details
  local conv_data
  conv_data="$(sqlite3 -json "$DB" "SELECT * FROM conversations WHERE conversationId='$(sql_escape "$conv_id")';" 2>/dev/null || echo "[]")"

  local result
  result=$(jq -n \
    --arg conversationId "$conv_id" \
    --arg repo "$REPO" \
    --argjson issueNumber "${ISSUE_NUMBER:-null}" \
    --argjson prNumber "${PR_NUMBER:-null}" \
    --argjson conversation "$(echo "$conv_data" | jq '.[0] // {}')" \
    '{
      conversationId: $conversationId,
      repo: $repo,
      issueNumber: $issueNumber,
      prNumber: $prNumber,
      conversation: $conversation,
      found: ($conversation.conversationId != null)
    }')

  echo "$result" | jq .
}

# Get task associated with a comment
cmd_get_task() {
  if [ -z "$REPO" ] || [ -z "$COMMENT_ID" ]; then
    error_exit "get-task requires --repo and --comment-id" 3
  fi

  init_schema

  local task_data
  task_data="$(sqlite3 -json "$DB" "SELECT * FROM processed_comments WHERE commentId='$(sql_escape "$COMMENT_ID")' LIMIT 1;" 2>/dev/null || echo "{}")"

  local result
  result=$(jq -n \
    --argjson task "$(echo "$task_data" | jq '. // {}')" \
    '{
      taskId: $task.commentId,
      conversationId: $task.conversationId,
      action: $task.action,
      status: $task.status,
      prNumber: $task.prNumber,
      parentTaskId: $task.parentTaskId,
      repo: $task.repository,
      issueNumber: $task.issueNumber
    }')

  echo "$result" | jq .
}

# Link a task to a conversation
cmd_link_task() {
  if [ -z "$REPO" ] || [ -z "$COMMENT_ID" ] || [ -z "$CONVERSATION_ID" ]; then
    error_exit "link-task requires --repo, --comment-id, and --conversation-id" 3
  fi

  init_schema

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Update task in processed_comments
  local update_fields=("conversationId='$(sql_escape "$CONVERSATION_ID")'")
  if [ -n "${PARENT_TASK_ID:-}" ]; then
    update_fields+=("parentTaskId='$(sql_escape "$PARENT_TASK_ID")'")
  fi
  if [ -n "${ACTION_TYPE:-}" ]; then
    update_fields+=("action='$(sql_escape "$ACTION_TYPE")'")
  fi
  if [ -n "${PR_NUMBER:-}" ]; then
    update_fields+=("prNumber=$PR_NUMBER")
  fi

  local set_clause
  set_clause="$(IFS=','; echo "${update_fields[*]}")"

  sqlite3 "$DB" "UPDATE processed_comments SET $set_clause, updatedAt='$now' WHERE commentId='$(sql_escape "$COMMENT_ID")';" 2>/dev/null || true

  # Create link record
  sqlite3 "$DB" "INSERT OR IGNORE INTO conversation_links(conversationId, repo, taskCommentId, linkType, createdAt)
    VALUES('$(sql_escape "$CONVERSATION_ID")', '$(sql_escape "$REPO")', '$(sql_escape "$COMMENT_ID")', 'TASK', '$now');" 2>/dev/null || true

  local result
  result=$(jq -n \
    --arg conversationId "$CONVERSATION_ID" \
    --arg commentId "$COMMENT_ID" \
    --arg parentTaskId "${PARENT_TASK_ID:-}" \
    --arg action "${ACTION_TYPE:-}" \
    --argjson prNumber "${PR_NUMBER:-null}" \
    --arg timestamp "$now" \
    '{
      conversationId: $conversationId,
      taskId: $commentId,
      parentTaskId: $parentTaskId,
      action: $action,
      prNumber: $prNumber,
      timestamp: $timestamp,
      status: "linked"
    }')

  echo "$result" | jq .
}

# Generate conversation ID for a GitHub object
generate_conversation_id() {
  local repo="$1"
  local obj_number="$2"
  local obj_type="${3:-issue}"

  printf 'conv-%s-%s-%s' "$repo" "$obj_type" "$(printf '%s' "${repo}:${obj_number}" | md5sum | cut -d' ' -f1 | cut -c1-8)"
}

# Main dispatch
case "${ACTION:-}" in
  link-issue) cmd_link_issue ;;
  link-pr) cmd_link_pr ;;
  get-conversation) cmd_get_conversation ;;
  get-task) cmd_get_task ;;
  link-task) cmd_link_task ;;
  "")
    echo "Usage: manul-conversation-linker.sh <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  link-issue     Link an issue to a conversation" >&2
    echo "  link-pr        Link a PR to a conversation" >&2
    echo "  get-conversation Get conversation for an issue or PR" >&2
    echo "  get-task       Get task for a comment" >&2
    echo "  link-task      Link a task to a conversation" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
