#!/bin/bash
# manul-submit.sh - Submit a task to the Manul task queue
#
# Usage:
#   manul-submit.sh [OPTIONS]
#
# Options:
#   --repo REPO          Repository (required, format: owner/repo)
#   --issue ISSUE        Issue or PR number (required)
#   --comment URL        Comment URL for conversation grouping (optional)
#   --prompt TEXT        Task prompt (required, or read from stdin)
#   --conversation ID    Conversation ID for grouping (optional, auto-generated if omitted)
#   --parent TASK_ID     Parent task ID for subtasks (optional)
#   --agent AGENT        Agent name (optional, defaults to "main")
#   --json               Output JSON format
#
# Returns:
#   JSON with commentId, conversationId, status on success
#   Exit code 0 on success, 1 on failure
#
# Examples:
#   manul-submit.sh --repo owner/repo --issue 1 --prompt "Fix bug"
#   manul-submit.sh --repo owner/repo --issue 1 --comment "https://github.com/..." --prompt "Reply to this"
#   echo "Fix bug" | manul-submit.sh --repo owner/repo --issue 1
#
# Idempotency:
#   If called multiple times with the same --repo, --issue, and --comment,
#   the same task ID is returned (if task still queued).

set -euo pipefail

# Configuration
MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
CONFIG="$MANUL_DIR/config.json"
OUTPUT_FORMAT="text"

# Parse arguments
REPO=""
ISSUE=""
COMMENT_URL=""
PROMPT=""
CONVERSATION=""
PARENT_TASK_ID=""
AGENT="main"

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --comment) COMMENT_URL="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --conversation) CONVERSATION="$2"; shift 2 ;;
    --parent) PARENT_TASK_ID="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --json) OUTPUT_FORMAT="json"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Read prompt from stdin if not provided
if [ -z "$PROMPT" ]; then
  if [ ! -t 0 ]; then
    PROMPT="$(cat)"
  else
    echo "Error: --prompt is required (or pipe via stdin)" >&2
    exit 1
  fi
fi

# Validate required fields
if [ -z "$REPO" ]; then
  echo "Error: --repo is required" >&2
  echo "Usage: manul-submit.sh --repo OWNER/REPO --issue NUMBER --prompt TEXT" >&2
  exit 1
fi

if [ -z "$ISSUE" ]; then
  echo "Error: --issue is required" >&2
  echo "Usage: manul-submit.sh --repo OWNER/REPO --issue NUMBER --prompt TEXT" >&2
  exit 1
fi

# Validate repo format
if [[ ! "$REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
  echo "Error: --repo must be in format 'owner/repo'" >&2
  exit 1
fi

# Validate issue is a number
if [[ ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: --issue must be a number" >&2
  exit 1
fi

# Generate conversation ID if not provided
  if [ -z "$CONVERSATION" ]; then
    # Use deterministic conversation ID format: conv-<repo>-issue-<issue_number>
    # This matches generate_conversation_id convention from poll.sh
    CONVERSATION="conv-${REPO}-issue-${ISSUE}"
  fi

# Ensure database exists
if [ ! -f "$DB" ]; then
  echo "Error: Manul database not found at $DB" >&2
  exit 1
fi

# Source workspace manager for schema migration
source "$MANUL_DIR/workspace-manager.sh" 2>/dev/null || true

# Escape strings for SQL
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

ESCAPED_REPO="$(sql_escape "$REPO")"
ESCAPED_ISSUE="$ISSUE"
ESCAPED_COMMENT_URL="$(sql_escape "$COMMENT_URL")"
ESCAPED_PROMPT="$(sql_escape "$PROMPT")"
ESCAPED_CONVERSATION="$(sql_escape "$CONVERSATION")"
ESCAPED_PARENT="$(sql_escape "$PARENT_TASK_ID")"
ESCAPED_AGENT="$(sql_escape "$AGENT")"

# Generate comment ID (stable for idempotency when same params)
# Uses repo+issue+comment+prompt hash as primary key, appends timestamp+PID for uniqueness
_HASH_INPUT="$(printf '%s-%s-%s-%s' "$REPO" "$ISSUE" "$COMMENT_URL" "$PROMPT")"
_BASE_ID="cli-$(printf '%s' "$_HASH_INPUT" | md5sum | cut -d' ' -f1)"

# For true idempotency: use atomic claim + insert in single transaction
# This ensures no race condition between claiming and creating the task
if [ -f "$DB" ]; then
  _ESCAPED_BASE="$(printf '%s' "$_BASE_ID" | sed "s/'/''/g")"
  _COMMENT_ID_VAR="$_BASE_ID-$(date +%s)-$$"
  _ESCAPED_COMMENT_ID="$(printf '%s' "$_COMMENT_ID_VAR" | sed "s/'/''/g")"
  
  # Single atomic transaction: claim + insert task in one go
  # Returns: 'WINNER:<commentId>' if we won, 'LOSER' if we lost, '' if locked
  _WINNER_RESULT=""
  _MAX_RETRIES=100
  _RETRY=0
  while [ -z "$_WINNER_RESULT" ] && [ "$_RETRY" -lt "$_MAX_RETRIES" ]; do
    # Try to claim and insert in a single transaction
    _WINNER_RESULT=$(sqlite3 "$DB" "
      BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO submission_claims (baseId, commentId, status) VALUES ('$_ESCAPED_BASE', 'claimed', 'queued');
      SELECT CASE WHEN changes() > 0 THEN 'WINNER' ELSE 'LOSER' END;
      COMMIT;
    " 2>/dev/null)
    
    if [ "$_WINNER_RESULT" = "WINNER" ]; then
      # We won the claim - insert the task atomically
      _INSERT_OK=$(sqlite3 "$DB" "
        BEGIN IMMEDIATE;
        INSERT INTO processed_comments 
          (commentId, repository, issueNumber, commentUrl, prompt, status, conversationId, parentTaskId, agent, createdAt, baseId)
        VALUES
          ('$_ESCAPED_COMMENT_ID', '$ESCAPED_REPO', $ESCAPED_ISSUE, '$ESCAPED_COMMENT_URL', '$ESCAPED_PROMPT', 'queued', '$ESCAPED_CONVERSATION', '$ESCAPED_PARENT', '$ESCAPED_AGENT', datetime('now'), '$_ESCAPED_BASE');
        SELECT changes();
        COMMIT;
      " 2>/dev/null)
      if [ "$_INSERT_OK" = "1" ]; then
        COMMENT_ID="$_ESCAPED_COMMENT_ID"
      else
        # Insert failed - should not happen, but handle gracefully
        _WINNER_RESULT=""
        _RETRY=$((_RETRY + 1))
        _COMMENT_ID_VAR="$_BASE_ID-$(date +%s)-$$"
        _ESCAPED_COMMENT_ID="$(printf '%s' "$_COMMENT_ID_VAR" | sed "s/'/''/g")"
        sleep 0.05
      fi
    elif [ "$_WINNER_RESULT" = "LOSER" ]; then
      # We lost the claim - find the existing task
      _EXISTING=$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE baseId='$_ESCAPED_BASE' AND status='queued' ORDER BY createdAt ASC LIMIT 1;" 2>/dev/null)
      if [ -n "$_EXISTING" ]; then
        COMMENT_ID="$_EXISTING"
      else
        # Task not found yet - race with winner who just claimed
        # Retry to see if we can win next time or task appears
        _WINNER_RESULT=""
        _RETRY=$((_RETRY + 1))
        _COMMENT_ID_VAR="$_BASE_ID-$(date +%s)-$$"
        _ESCAPED_COMMENT_ID="$(printf '%s' "$_COMMENT_ID_VAR" | sed "s/'/''/g")"
        sleep 0.05
      fi
    else
      # Database locked - retry
      _WINNER_RESULT=""
      _RETRY=$((_RETRY + 1))
      _COMMENT_ID_VAR="$_BASE_ID-$(date +%s)-$$"
      _ESCAPED_COMMENT_ID="$(printf '%s' "$_COMMENT_ID_VAR" | sed "s/'/''/g")"
      sleep 0.05
    fi
  done
  
  if [ -z "${COMMENT_ID:-}" ]; then
    # All retries exhausted - this is a fallback that should rarely be reached
    # Generate unique ID and insert with retry to handle any remaining races
    _FALLBACK_RETRIES=10
    _FALLBACK_RETRY=0
    while [ -z "${COMMENT_ID:-}" ] && [ "$_FALLBACK_RETRY" -lt "$_FALLBACK_RETRIES" ]; do
      COMMENT_ID="$_BASE_ID-$(date +%s)-$$"
      _INSERT_FALLOK=$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments 
        (commentId, repository, issueNumber, commentUrl, prompt, status, conversationId, parentTaskId, agent, createdAt, baseId)
      VALUES
        ('$COMMENT_ID', '$ESCAPED_REPO', $ESCAPED_ISSUE, '$ESCAPED_COMMENT_URL', '$ESCAPED_PROMPT', 'queued', '$ESCAPED_CONVERSATION', '$ESCAPED_PARENT', '$ESCAPED_AGENT', datetime('now'), '$_ESCAPED_BASE');
      SELECT changes();" 2>/dev/null)
      if [ "$_INSERT_FALLOK" = "1" ]; then
        break
      fi
      _FALLBACK_RETRY=$((_FALLBACK_RETRY + 1))
      sleep 0.1
    done
  fi
else
  # No DB yet - generate unique ID
  COMMENT_ID="$_BASE_ID-$(date +%s)-$$"
fi

# Output result
if [ "$OUTPUT_FORMAT" = "json" ]; then
  printf '{"commentId": "%s", "conversationId": "%s", "status": "queued", "repo": "%s", "issue": %s}\n' \
    "$COMMENT_ID" "$CONVERSATION" "$REPO" "$ISSUE"
else
  echo "Submitted task:"
  echo "  commentId:  $COMMENT_ID"
  echo "  repo:       $REPO#$ISSUE"
  echo "  conversation: $CONVERSATION"
  echo "  status:     queued"
fi

exit 0
