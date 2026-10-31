#!/bin/bash
# manul-github-events.sh - GitHub control protocol event parser
#
# This script parses GitHub comments and reviews to extract structured commands
# for the Manul orchestrator. It supports both human-readable and machine-readable
# formats.
#
# Command Grammar:
#   /manul run <task>                    - Submit new implementation task
#   /manul run --agent <agent> <task>    - Submit with specific agent
#   /manul --auto run <task>             - Run via OpenCode with --auto
#   /manul review-fix <feedback>         - Submit review-fix task
#   /manul continue                      - Continue with parent task's PR
#   /manul verify                        - Request verification
#   /manul status                        - Query conversation status
#   /manul close                         - Close conversation
#
# Event Format (Machine-readable HTML comments):
#   <!-- manul:event {type, id, timestamp} -->
#   <!-- manul:event TASK_CREATED -->
#   <!-- manul:event TASK_STARTED -->
#   <!-- manul:event TASK_DONE {taskId, conversationId, action, status, prNumber} -->
#   <!-- manul:event TASK_FAILED {taskId, conversationId, action, error} -->
#   <!-- manul:event REVIEW_REQUESTED {prNumber, taskId} -->
#   <!-- manul:event REVIEW_APPROVED {prNumber, taskId} -->
#   <!-- manul:event REVIEW_CHANGES {prNumber, taskId, feedback} -->
#   <!-- manul:event TASK_LINKED {taskId, parentId, relationship} -->
#
# Usage:
#   manul-github-events.sh parse-comment [--repo REPO] [--issue ISSUE] [--comment-id ID] [--body BODY] [--author AUTHOR] [--created CREATED]
#   manul-github-events.sh parse-review [--repo REPO] [--pr-number N] [--review-id ID] [--state STATE] [--body BODY] [--author AUTHOR] [--created CREATED]
#   manul-github-events.sh extract-events [--body BODY]
#   manul-github-events.sh post-event [--repo REPO] [--issue ISSUE] [--pr-number N] [--event-type TYPE] [--data DATA] [--signature SIGNATURE]
#
# Exit codes: 0=success, 1=failure, 2=not found, 3=bad request

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
ISSUE=""
COMMENT_ID=""
BODY=""
AUTHOR=""
CREATED=""
PR_NUMBER=""
REVIEW_ID=""
REVIEW_STATE=""
EVENT_TYPE=""
EVENT_DATA=""
SIGNATURE="— manul 🐈"

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --comment-id) COMMENT_ID="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --created) CREATED="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --review-id) REVIEW_ID="$2"; shift 2 ;;
    --review-state) REVIEW_STATE="$2"; shift 2 ;;
    --event-type) EVENT_TYPE="$2"; shift 2 ;;
    --event-data) EVENT_DATA="$2"; shift 2 ;;
    --signature) SIGNATURE="$2"; shift 2 ;;
    parse-comment|parse-review|extract-events|post-event) ACTION="$1"; shift ;;
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

# Parse command from comment/review body
# Returns JSON with action, prompt, agent, and metadata
parse_command() {
  local body="$1"
  local trigger="/manul"

  # Find the trigger line (anchored at line start, optional leading whitespace)
  local command_line=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*$trigger([[:space:]]|$) ]]; then
      command_line="$line"
      break
    fi
  done <<< "$body"

  if [ -z "$command_line" ]; then
    echo '{"error": "no trigger found", "valid": false}'
    return 1
  fi

  # Extract command after trigger (remove anchored trigger at line start)
  local cmd
  cmd="$(echo "$command_line" | sed -E "s#^[[:space:]]*$trigger([[:space:]]+|$)##")"

  # --auto is an OpenCode-only per-task mode. Strip it before parsing the task.
  local auto_accept=false
  if [[ "$cmd" =~ (^|[[:space:]])--auto([[:space:]]|$) ]]; then
    auto_accept=true
    cmd="$(printf '%s\n' "$cmd" | sed -E 's/(^|[[:space:]])--auto([[:space:]]|$)/\1\2/g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  fi

  # Parse command structure
  local action="IMPLEMENT"
  local agent=""
  local prompt=""
  local flags=""

  # Role allow-list is configured by Manul, with a fallback for older configs.
  local known_agents
  known_agents="$(jq -r '.agents[]?' "$CONFIG" 2>/dev/null | paste -sd ' ' -)"
  if [ -z "$known_agents" ]; then
    known_agents="architect coder coder-cheap coder-strong coder-expert reviewer reviewer-expert reviewer-adversarial debugger debugger-expert researcher tester security performance refactorer"
  fi

  # Known actions
  local known_actions="run review-fix continue verify status close"

  # First token is the action
  local first_token
  first_token="$(echo "$cmd" | awk '{print $1}')"

  case "$first_token" in
    run)
      action="IMPLEMENT"
      local run_args
      run_args="${cmd#run}"
      run_args="${run_args#"${run_args%%[![:space:]]*}"}"
      if [[ "$run_args" == --agent* ]]; then
        if [[ "$run_args" =~ ^--agent[[:space:]]+([^[:space:]]+)([[:space:]]+(.*))?$ ]]; then
          agent="${BASH_REMATCH[1]}"
          prompt="${BASH_REMATCH[3]:-}"
        else
          # Preserve malformed selectors so routing fails visibly instead of
          # silently treating the selector as part of the task.
          agent="__missing_agent__"
          prompt=""
        fi
      else
        prompt="$run_args"
      fi
      ;;
    review-fix)
      action="REVIEW_FIX"
      prompt="$(echo "$cmd" | sed 's/^review-fix[[:space:]]*//')"
      ;;
    continue)
      action="CONTINUE"
      prompt="$(echo "$cmd" | sed 's/^continue[[:space:]]*//')"
      ;;
    verify)
      action="VERIFY"
      prompt="$(echo "$cmd" | sed 's/^verify[[:space:]]*//')"
      ;;
    status)
      action="STATUS"
      prompt=""
      ;;
    close)
      action="CLOSE"
      prompt=""
      ;;
    *)
      # Try to use first token as a configured role agent.
      if echo "$known_agents" | grep -qw "$first_token"; then
        agent="$first_token"
        prompt="$(echo "$cmd" | sed "s/^${first_token}[[:space:]]*//")"
        action="IMPLEMENT"
      else
        # Default to IMPLEMENT with full prompt
        action="IMPLEMENT"
        prompt="$cmd"
      fi
      ;;
  esac

  # Empty agent means automatic runtime entry-point selection; non-empty means
  # the user explicitly selected a canonical role.
  local agent_selection="automatic"
  [ -n "${agent:-}" ] && agent_selection="explicit"

  # Build JSON output
  local result
  result=$(jq -n \
    --arg action "$action" \
    --arg prompt "${prompt:-}" \
    --arg agent "${agent:-}" \
    --arg agentSelection "$agent_selection" \
    --arg raw_command "$cmd" \
    --argjson autoAccept "$auto_accept" \
    '{
      valid: true,
      action: $action,
      prompt: $prompt,
      agent: $agent,
      agentSelection: $agentSelection,
      autoAccept: $autoAccept,
      rawCommand: $raw_command
    }')

  echo "$result"
}

# Parse GitHub comment
cmd_parse_comment() {
  if [ -z "$BODY" ]; then
    error_exit "parse-comment requires --body" 3
  fi

  local result
  result=$(jq -n \
    --arg body "$BODY" \
    --arg repo "${REPO:-}" \
    --arg issue "${ISSUE:-}" \
    --arg comment_id "${COMMENT_ID:-}" \
    --arg author "${AUTHOR:-}" \
    --arg created "${CREATED:-}" \
    '{
      type: "COMMENT",
      repo: $repo,
      issueNumber: ($issue | tonumber? // null),
      commentId: $comment_id,
      author: $author,
      createdAt: $created,
      body: $body
    }')

  # Parse command from body
  local parsed
  parsed="$(parse_command "$BODY")" || true

  # Merge results
  local command
  command="$(echo "$parsed" | jq '. // {}')"

  local final
  final=$(jq -n \
    --argjson event "$result" \
    --argjson command "$command" \
    '{
      event: $event,
      command: $command,
      hasCommand: ($command.valid == true),
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')

  echo "$final" | jq .
}

# Parse GitHub PR review
cmd_parse_review() {
  if [ -z "$REVIEW_STATE" ] || [ -z "$BODY" ]; then
    error_exit "parse-review requires --review-state and --body" 3
  fi

  local result
  result=$(jq -n \
    --arg state "$REVIEW_STATE" \
    --arg body "$BODY" \
    --arg repo "${REPO:-}" \
    --arg pr_number "${PR_NUMBER:-}" \
    --arg review_id "${REVIEW_ID:-}" \
    --arg author "${AUTHOR:-}" \
    --arg created "${CREATED:-}" \
    '{
      type: "REVIEW",
      repo: $repo,
      prNumber: ($pr_number | tonumber? // null),
      reviewId: $review_id,
      state: $state,
      author: $author,
      createdAt: $created,
      body: $body
    }')

  # Check if review contains a command (anchored at line start)
  local has_command=false
  local command
  if echo "$BODY" | grep -qE '^[[:space:]]*/manul([[:space:]]|$)'; then
    has_command=true
    command="$(parse_command "$BODY")" || true
  else
    command='{"valid": false}'
  fi

  # Map GitHub review state to Manul action
  local action="COMMENT"
  case "$REVIEW_STATE" in
    APPROVE) action="APPROVE" ;;
    REQUEST_CHANGES) action="REQUEST_CHANGES" ;;
    COMMENT) action="COMMENT" ;;
    DISMITTED) action="DISMISS" ;;
  esac

  local final
  final=$(jq -n \
    --argjson event "$result" \
    --argjson command "$command" \
    --argjson has_command "$has_command" \
    --arg action "$action" \
    '{
      event: $event,
      command: $command,
      hasCommand: $has_command,
      githubState: $state,
      manulAction: $action,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')

  echo "$final" | jq .
}

# Extract structured events from comment body
# Events are in HTML comments: <!-- manul:event {...} -->
cmd_extract_events() {
  if [ -z "$BODY" ]; then
    error_exit "extract-events requires --body" 3
  fi

  local events="[]"

  # Extract all manul:event HTML comments
  while IFS= read -r event_line; do
    [ -z "$event_line" ] && continue
    # Remove HTML comment markers
    local event_content="${event_line#<!-- manul:event }"
    event_content="${event_content% -->}"

    # Try to parse as JSON
    if echo "$event_content" | jq empty 2>/dev/null; then
      events="$(echo "$events" | jq --argjson e "$event_content" '. + [$e]')"
    fi
  done < <(grep -oE '<!-- manul:event [^>]+ -->' <<< "$BODY" 2>/dev/null || true)

  local result
  result=$(jq -n \
    --argjson events "$events" \
    --arg body "$BODY" \
    '{
      events: $events,
      eventCount: ($events | length),
      rawBody: $body
    }')

  echo "$result" | jq .
}

# Post a structured event as an HTML comment
cmd_post_event() {
  if [ -z "$EVENT_TYPE" ]; then
    error_exit "post-event requires --event-type" 3
  fi

  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local event_data="{}"
  if [ -n "$EVENT_DATA" ]; then
    event_data="$(echo "$EVENT_DATA" | jq '.' 2>/dev/null || echo '{}')"
  fi

  # Build event JSON
  local event_json
  event_json=$(jq -n \
    --arg type "$EVENT_TYPE" \
    --arg timestamp "$timestamp" \
    --argjson data "$event_data" \
    '{
      type: $type,
      timestamp: $timestamp,
      data: $data
    }')

  # Build HTML comment
  local html_event
  html_event="<!-- manul:event $(echo "$event_json" | jq -c .) -->"

  # Output
  local result
  result=$(jq -n \
    --arg event_type "$EVENT_TYPE" \
    --arg timestamp "$timestamp" \
    --argjson data "$event_data" \
    --arg html "$html_event" \
    '{
      type: $event_type,
      timestamp: $timestamp,
      data: $data,
      htmlComment: $html
    }')

  echo "$result" | jq .
}

# Main dispatch
case "${ACTION:-}" in
  parse-comment) cmd_parse_comment ;;
  parse-review) cmd_parse_review ;;
  extract-events) cmd_extract_events ;;
  post-event) cmd_post_event ;;
  "")
    echo "Usage: manul-github-events.sh <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  parse-comment    Parse a GitHub comment" >&2
    echo "  parse-review     Parse a GitHub PR review" >&2
    echo "  extract-events   Extract structured events from body" >&2
    echo "  post-event       Post a structured event" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
