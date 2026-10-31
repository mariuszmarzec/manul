#!/bin/bash
# orchestrator-reviewer.sh - Pluggable reviewer interface for Manul orchestrator
#
# This script provides a clean interface for reviewing PRs.
# It can be replaced with ChatGPT or other reviewers in the future.
#
# Usage:
#   orchestrator-reviewer.sh review --task-id ID [--json]
#   orchestrator-reviewer.sh approve --task-id ID [--json]
#   orchestrator-reviewer.sh request-changes --task-id ID --feedback "Feedback" [--json]
#   orchestrator-reviewer.sh comment --task-id ID --feedback "Comment" [--json]
#
# Review decisions:
#   APPROVE         - PR is good to merge
#   REQUEST_CHANGES - PR needs modifications
#   COMMENT         - Additional feedback only
#   BLOCKED         - Blocking issues found

set -euo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
REVIEWER_TYPE="${REVIEWER_TYPE:-mock}"

JSON_OUTPUT=false
ACTION=""
TASK_ID=""
FEEDBACK=""
PR_NUMBER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --feedback) FEEDBACK="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    approve|request-changes|comment) ACTION="$1"; shift ;;
    review) ACTION="review"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

# Mock reviewer implementation
mock_review() {
  local task_id="$1"
  local decision=""
  
  # Check for explicit decision file
  local decision_file="$MANUL_DIR/reviews/${task_id}.decision"
  if [ -f "$decision_file" ]; then
    decision="$(cat "$decision_file")"
  fi
  
  # Default to requesting changes for testing
  if [ -z "$decision" ]; then
    decision="REQUEST_CHANGES"
  fi
  
  local result
  result=$(jq -n \
    --arg taskId "$task_id" \
    --arg decision "$decision" \
    --arg reviewer "mock" \
    '{
      taskId: $taskId,
      decision: $decision,
      reviewer: $reviewer,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')
  
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "Reviewer: $decision"
    echo "  task: $task_id"
  fi
}

# Explicit decision commands
cmd_approve() {
  local result="{\"taskId\": \"$TASK_ID\", \"decision\": \"APPROVE\", \"reviewer\": \"mock\"}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "APPROVE"
  fi
}

cmd_request_changes() {
  local result="{\"taskId\": \"$TASK_ID\", \"decision\": \"REQUEST_CHANGES\", \"reviewer\": \"mock\", \"feedback\": $(printf '%s' "$FEEDBACK" | jq -Rs .)}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "REQUEST_CHANGES"
    if [ -n "$FEEDBACK" ]; then
      echo "  Feedback: $FEEDBACK"
    fi
  fi
}

cmd_comment() {
  local result="{\"taskId\": \"$TASK_ID\", \"decision\": \"COMMENT\", \"reviewer\": \"mock\", \"feedback\": $(printf '%s' "$FEEDBACK" | jq -Rs .)}"
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$result" | jq .
  else
    echo "COMMENT"
    if [ -n "$FEEDBACK" ]; then
      echo "  Feedback: $FEEDBACK"
    fi
  fi
}

case "${ACTION:-}" in
  review) mock_review "$TASK_ID" ;;
  approve) cmd_approve ;;
  request-changes) cmd_request_changes ;;
  comment) cmd_comment ;;
  "")
    echo "Usage: orchestrator-reviewer.sh <action> --task-id ID [options]" >&2
    echo "" >&2
    echo "Actions:" >&2
    echo "  review           Auto-determine review decision" >&2
    echo "  approve          Always approve" >&2
    echo "  request-changes  Request changes with optional feedback" >&2
    echo "  comment          Add comment without blocking" >&2
    exit 3
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    exit 3
    ;;
esac
