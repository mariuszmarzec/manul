#!/bin/bash
# manul-pr-review.sh - PR review handler for Manul GitHub control protocol
#
# This script handles PR review events (APPROVE, REQUEST_CHANGES) and converts
# them into appropriate Manul tasks while preserving conversation context.
#
# Key invariants:
# - PR review feedback -> REVIEW_FIX task on SAME PR
# - APPROVE does NOT create fix task
# - REQUEST_CHANGES creates fix task with parent relationship
# - conversationId is preserved across review cycles
# - Crash-safe: exactly-one task creation even across crashes/restarts
#
# Usage:
#   manul-pr-review.sh handle --repo REPO --pr-number N --review-id ID --state STATE --body BODY --author AUTHOR --created CREATED
#   manul-pr-review.sh get-conversation --repo REPO --pr-number N
#   manul-pr-review.sh list-reviews --repo REPO --pr-number N
#
# Review state machine (stored in processed_comments):
#   pending     - review claimed, task not yet created
#   task_created - task created, taskId stored, awaiting completion
#   completed   - task completed successfully
#   failed      - task creation or execution failed
#
set -euo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
CONFIG="${MANUL_DIR}/config.json"
EVENTS_SCRIPT="${MANUL_DIR}/manul-github-events.sh"

# JSON output flag
JSON_OUTPUT=false

# Parse global options
ACTION=""
REPO=""
PR_NUMBER=""
REVIEW_ID=""
REVIEW_STATE=""
BODY=""
AUTHOR=""
CREATED=""
REVIEWER_TYPE="${REVIEWER_TYPE:-mock}"
REVIEW_COMMENTS_JSON=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift 1 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr-number) PR_NUMBER="$2"; shift 2 ;;
    --review-id) REVIEW_ID="$2"; shift 2 ;;
    --review-state) REVIEW_STATE="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --created) CREATED="$2"; shift 2 ;;
    --review-comments-json) REVIEW_COMMENTS_JSON="$2"; shift 2 ;;
    handle|get-conversation|list-reviews) ACTION="$1"; shift 1 ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
done

# SQL escaping helper
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# SQLite retry helper - handles transient "database is locked" errors
sqlite3_retry() {
  local sql="$1"
  local max_retries="${2:-3}"
  local retry=0
  local result=""
  local err_msg=""
  while [ $retry -lt $max_retries ]; do
    result="$(sqlite3 "$DB" "$sql" 2>&1)" && echo "$result" && return 0
    err_msg="$(echo "$result" | tail -1)"
    # Only retry on transient SQLite_BUSY errors
    if echo "$err_msg" | grep -qE "database is locked|database table is locked|locked:.*retry"; then
      retry=$((retry + 1))
      # Exponential backoff: 20ms, 40ms, 80ms, 160ms, 320ms, 640ms
      local sleep_ms=$((20 * (1 << (retry - 1))))
      local sleep_sec=$((sleep_ms / 1000))
      local sleep_frac=$((sleep_ms % 1000))
      sleep "$(printf '%d.%03d' $sleep_sec $sleep_frac)"
    else
      # Permanent error - fail immediately
      echo "ERROR: SQLite permanent error: $err_msg" >&2
      return 1
    fi
  done
  echo "ERROR: SQLite retry exhausted after $max_retries attempts: $err_msg" >&2
  return 1
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

# Ensure the processed_comments table has the taskId column for review-task association.
# Idempotent: safe to call multiple times, works on fresh and existing DBs.
init_schema() {
  mkdir -p "$(dirname "$DB")"

  # Create processed_comments table if not exists (mimics manul-conversation.sh schema)
  # Uses retry loop to handle concurrent access
  local max_retries=10
  local retry=0
  local success=false
  while [ "$success" = false ] && [ $retry -lt $max_retries ]; do
    local err
    err="$(sqlite3 "$DB" "
      PRAGMA busy_timeout=5000;
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
        nextAttemptAt TEXT,
        conversationId TEXT,
        parentTaskId TEXT,
        workspaceId TEXT,
        action TEXT DEFAULT 'IMPLEMENT',
        prNumber INTEGER,
        prUrl TEXT,
        resultSummary TEXT,
        resultJson TEXT,
        baseId TEXT,
        taskSourceType TEXT,
        taskSourceId TEXT,
        taskSourceUrl TEXT,
        taskSourceTitle TEXT,
        taskSourceUpdatedAt TEXT
      );
      COMMIT;
    " 2>&1)" && success=true || {
      retry=$((retry + 1))
      if [ $retry -ge $max_retries ]; then
        echo "ERROR: init_schema failed after $max_retries retries: $err" >&2
        return 1
      fi
      if echo "$err" | grep -qE "database is locked|database table is locked"; then
        sleep "0.0$((retry * 2))"
      else
        echo "ERROR: init_schema failed: $err" >&2
        return 1
      fi
    }
  done

  # Migrate generic root task-source identity fields. PR review data is related context only.
  local source_cols
  source_cols="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null)" || true
  if ! echo "$source_cols" | grep -q "|taskSourceType|"; then
    sqlite3_retry "ALTER TABLE processed_comments ADD COLUMN taskSourceType TEXT;" 3
    sqlite3_retry "ALTER TABLE processed_comments ADD COLUMN taskSourceId TEXT;" 3
    sqlite3_retry "ALTER TABLE processed_comments ADD COLUMN taskSourceUrl TEXT;" 3
    sqlite3_retry "ALTER TABLE processed_comments ADD COLUMN taskSourceTitle TEXT;" 3
    sqlite3_retry "ALTER TABLE processed_comments ADD COLUMN taskSourceUpdatedAt TEXT;" 3
  fi

  # Migrate: add taskId column if missing (for review-task association)
  # Safe/idempotent migration: check first, then ALTER with retry
  local col_check
  col_check="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null)" || true
  if ! echo "$col_check" | grep -q '|taskId|'; then
    # Column doesn't exist - attempt to add it with retry on lock
    local migrate_ok=false
    local migrate_retry=0
    while [ "$migrate_ok" = false ] && [ $migrate_retry -lt 5 ]; do
      local migrate_err
      migrate_err="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN taskId TEXT; COMMIT;" 2>&1)" && migrate_ok=true || {
        migrate_retry=$((migrate_retry + 1))
        if [ $migrate_retry -ge 5 ]; then
          echo "ERROR: Failed to migrate processed_comments table after $migrate_retry attempts: $migrate_err" >&2
          return 1
        fi
        if echo "$migrate_err" | grep -qE "database is locked|database table is locked"; then
          sleep "0.0$((migrate_retry * 2))"
        elif echo "$migrate_err" | grep -q "duplicate column name"; then
          # Another process added it concurrently - re-check and continue
          col_check="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null)" || true
          if echo "$col_check" | grep -q '|taskId|'; then
            return 0
          fi
        else
          echo "ERROR: Migration failed for processed_comments.taskId: $migrate_err" >&2
          return 1
        fi
      }
    done
  fi
  # If column already exists, another process added it - silently continue
}

# Get the PR's associated conversation
# Returns conversationId or exits on SQLite failure
get_pr_conversation() {
  local repo="$1"
  local pr_number="$2"

  if [ ! -f "$DB" ]; then
    echo ""
    return
  fi

  # Check if PR number exists in processed_comments
  local conv_id
  if ! conv_id="$(sqlite3_retry "SELECT DISTINCT conversationId FROM processed_comments WHERE repository='$(sql_escape "$repo")' AND prNumber=$pr_number AND status != 'failed' AND action != 'REVIEW' ORDER BY createdAt DESC LIMIT 1;" 3)"; then
    echo "ERROR: SQLite query failed in get_pr_conversation (processed_comments)" >&2
    return 1
  fi

  if [ -n "$conv_id" ]; then
    echo "$conv_id"
    return
  fi

  # Check conversations table for PR association
  if ! conv_id="$(sqlite3_retry "SELECT conversationId FROM conversations WHERE repository='$(sql_escape "$repo")' AND activePrNumber=$(echo "$pr_number" | jq -R . | jq -c .) AND status != 'COMPLETED' LIMIT 1;" 3)"; then
    echo "ERROR: SQLite query failed in get_pr_conversation (conversations)" >&2
    return 1
  fi

  echo "$conv_id"
}

# Get the latest task for a PR that needs review
get_pr_pending_task() {
  local repo="$1"
  local pr_number="$2"

  if [ ! -f "$DB" ]; then
    echo ""
    return
  fi

  # Find the latest running/completed task for this PR (exclude REVIEW actions only)
  local task_id
  if ! task_id="$(sqlite3_retry "SELECT commentId FROM processed_comments WHERE repository='$(sql_escape "$repo")' AND prNumber=$pr_number AND status IN ('running', 'completed') AND action NOT IN ('REVIEW') ORDER BY createdAt DESC LIMIT 1;" 3)"; then
    echo "ERROR: SQLite query failed in get_pr_pending_task" >&2
    return 1
  fi

  echo "$task_id"
}

# Get conversation and task context for a PR
get_pr_context() {
  local repo="$1"
  local pr_number="$2"

  local conv_id
  conv_id="$(get_pr_conversation "$repo" "$pr_number")"

  local task_id
  task_id="$(get_pr_pending_task "$repo" "$pr_number")"

  local parent_task_id=""
  if [ -n "$task_id" ]; then
    parent_task_id="$task_id"
  fi

  # Get PR details
  local pr_title=""
  if command -v gh >/dev/null 2>&1; then
    pr_title="$(gh pr view "$pr_number" --repo "$repo" --json title --jq '.title // ""' 2>/dev/null || echo "")"
  fi

  local result
  result=$(jq -n \
    --arg conversationId "${conv_id:-}" \
    --arg taskId "${task_id:-}" \
    --arg parentTaskId "${parent_task_id:-}" \
    --arg repo "$repo" \
    --argjson prNumber "$pr_number" \
    --arg prTitle "$pr_title" \
    '{
      conversationId: $conversationId,
      taskId: $taskId,
      parentTaskId: $parentTaskId,
      repo: $repo,
      prNumber: $prNumber,
      prTitle: $prTitle,
      hasConversation: ($conversationId != ""),
      hasTask: ($taskId != "")
    }')

  echo "$result" | jq .
}

# Handle incoming PR review
# Creates appropriate tasks based on review state
# Implements crash-safe idempotent state machine:
#   pending -> task_created -> completed
cmd_handle() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ] || [ -z "$REVIEW_STATE" ]; then
    error_exit "handle requires --repo, --pr-number, and --review-state" 3
  fi

  # Serialize processing of the exact same review event.
  # This is intentionally narrower than a global review lock: distinct review
  # IDs may still run concurrently, while duplicate deliveries of one review
  # cannot race through schema migration/state-machine/task creation.
  local review_id="${REVIEW_ID:-review-$PR_NUMBER-$REVIEW_STATE}"
  local review_lock_dir="${MANUL_DIR}/review-locks"
  local review_lock_key
  review_lock_key="$(printf '%s\0%s' "$REPO" "$review_id" | sha256sum | awk '{print $1}')"
  local review_lock_file="$review_lock_dir/$review_lock_key.lock"
  mkdir -p "$review_lock_dir"
  exec 201>"$review_lock_file"
  flock -x 201

  # Initialize schema (migrate if needed)
  init_schema || error_exit "Failed to initialize schema" 1

  # Validate the inline comments attached to this single GitHub review.
  # Polling passes an empty array for reviews without inline comments.
  local review_comments_json='[]'
  if [ -n "$REVIEW_COMMENTS_JSON" ]; then
    if ! jq -e 'type == "array"' <<<"$REVIEW_COMMENTS_JSON" >/dev/null 2>&1; then
      error_exit "--review-comments-json must be a JSON array" 3
    fi
    review_comments_json="$REVIEW_COMMENTS_JSON"
  fi

  # Replies belong to existing review threads. Keep them in conversation history,
  # but only root-level inline comments are new feedback that can trigger a task.
  review_comments_json="$(jq -c '[.[] | select((.in_reply_to_id // null) == null)]' <<<"$review_comments_json")"
  local inline_review_count
  inline_review_count="$(jq -r 'length' <<<"$review_comments_json")"

  # Get context
  local context
  context="$(get_pr_context "$REPO" "$PR_NUMBER")"
  local conv_id task_id
  conv_id="$(echo "$context" | jq -r '.conversationId // empty')"
  task_id="$(echo "$context" | jq -r '.taskId // empty')"

  # Map GitHub review state to Manul action
  local action=""
  local should_create_task=false

  case "$REVIEW_STATE" in
    APPROVE)
      action="APPROVE"
      should_create_task=false
      ;;
    REQUEST_CHANGES)
      action="REQUEST_CHANGES"
      should_create_task=false
      ;;
    COMMENT)
      action="COMMENT"
      should_create_task=false
      ;;
    DISMISS)
      action="DISMISS"
      should_create_task=false
      ;;
    *)
      error_exit "Unknown review state: $REVIEW_STATE" 3
      ;;
  esac

  # Any root-level inline feedback is actionable regardless of the review verdict.
  # A body-only REQUEST_CHANGES review is also actionable. Reply-only reviews are
  # passive unless their review body contains separate, explicit feedback.
  if [ "$inline_review_count" -gt 0 ] && [ "$REVIEW_STATE" != "DISMISS" ]; then
    should_create_task=true
  elif [ "$action" = "REQUEST_CHANGES" ] && [ -n "$(printf '%s' "$BODY" | tr -d '[:space:]')" ]; then
    should_create_task=true
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local review_comment_id="review:$review_id"

  # ========================================================================
  # Phase 1: Check existing review record and determine recovery action
  # ========================================================================
  local review_status=""
  local existing_task_id=""

  if [ -n "$DB" ] && [ -f "$DB" ]; then
    # Read-only SELECT - no BEGIN IMMEDIATE needed
    local status_row
    if ! status_row="$(sqlite3_retry "SELECT status, taskId FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW' LIMIT 1;" 3)"; then
      echo "ERROR: SQLite query failed to check review status for $review_id" >&2
      return 1
    fi

    if [ -n "$status_row" ]; then
      review_status="$(echo "$status_row" | cut -d'|' -f1)"
      existing_task_id="$(echo "$status_row" | cut -d'|' -f2)"
    fi
  fi

  # ========================================================================
  # Phase 2: Handle non-REQUEST_CHANGES reviews (APPROVE/DISMISS/COMMENT)
  # ========================================================================
  if [ "$should_create_task" = false ]; then
    # For APPROVE/DISMISS/COMMENT: record as completed (no task creation)
    if [ -n "$DB" ] && [ -f "$DB" ]; then
      sqlite3_retry "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, action, status, createdAt, conversationId, prNumber) VALUES('$(sql_escape "$review_comment_id")', '$(sql_escape "$REPO")', $PR_NUMBER, 'https://github.com/${REPO}/pull/${PR_NUMBER}', '$(sql_escape "${AUTHOR:-}")', '$(sql_escape "${BODY:-Review: $REVIEW_STATE}")', 'REVIEW', 'completed', '$now', '$(sql_escape "${conv_id:-}")', $PR_NUMBER);" 3 || {
        echo "ERROR: failed to record review $review_id" >&2
        return 1
      }
    fi

    local result
    result=$(jq -n \
      --arg reviewId "$REVIEW_ID" \
      --arg action "$action" \
      --arg conversationId "$conv_id" \
      --arg taskId "${task_id:-}" \
      --argjson prNumber "$PR_NUMBER" \
      '{
        reviewId: $reviewId,
        action: $action,
        conversationId: $conversationId,
        taskId: $taskId,
        prNumber: $prNumber,
        createdTask: false,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }')

    echo "$result" | jq .
    return 0
  fi

  # ========================================================================
  # Phase 3: REQUEST_CHANGES - crash-safe task creation with state machine
  # ========================================================================

  # Parse review body for additional instructions
  local review_prompt="$BODY"
  if [ -n "$BODY" ] && [[ "$BODY" == *"/manul"* ]]; then
    local cmd_output
    cmd_output="$(bash "$EVENTS_SCRIPT" parse-review \
      --repo "$REPO" \
      --pr-number "$PR_NUMBER" \
      --review-id "$REVIEW_ID" \
      --review-state "$REVIEW_STATE" \
      --body "$BODY" \
      --author "$AUTHOR" \
      --created "$CREATED" \
      --json 2>/dev/null)" || cmd_output=""

    if [ -n "$cmd_output" ]; then
      local parsed_action
      parsed_action="$(echo "$cmd_output" | jq -r '.command.prompt // empty')"
      if [ -n "$parsed_action" ]; then
        review_prompt="$parsed_action"
      fi
    fi
  fi

  if [ "$inline_review_count" -gt 0 ]; then
    local inline_review_prompt
    inline_review_prompt="$(jq -r '
      map({
        commentId: (.id | tostring),
        threadRootId: ((.manul_thread_root_id // .in_reply_to_id // .id) | tostring),
        path: (.path // "(location unavailable)"),
        line: (.line // .original_line // ""),
        body: (.body // ""),
        diffHunk: (.diff_hunk // ""),
        url: (.html_url // "")
      })
      | to_entries
      | map(
          "- Comment ID: \(.value.commentId)\n  Thread root ID: \(.value.threadRootId)\n  File/line: \(.value.path):\(.value.line)\n  URL: \(.value.url)\n  Comment:\n\(.value.body)\n  Diff context:\n\(.value.diffHunk)"
        )
      | join("\n\n")
    ' <<<"$review_comments_json")"

    # Keep the whole review in one task. Reply to each distinct inline thread,
    # and reserve the task/attempt marker for the canonical result comment.
    review_prompt+="${review_prompt:+$'\n\n'}All inline comments below were submitted together as one GitHub review. Treat them as one task: analyze every comment, implement applicable changes together, and verify each comment is addressed. After the work, post a concise reply in every distinct inline thread identified by its Thread root ID, explaining how that feedback was handled (including if it was already fixed or no change was appropriate). Use the GitHub pull-request review-comment reply API with the thread root comment ID; only reply once when multiple comments share a root. These per-thread replies are supplementary and MUST NOT contain the Manul task/attempt marker. Also post exactly one canonical result comment on this task's PR conversation containing the normal marker. Do not report completion until all distinct threads have replies and the canonical result comment is verified."$'\n\n'"Inline review comments:\n$inline_review_prompt"
  fi

  # State machine: handle based on existing review status
  case "$review_status" in
    completed)
      # Already completed successfully - skip
      local result
      result=$(jq -n \
        --arg reviewId "$review_id" \
        --arg action "$action" \
        --arg conversationId "$conv_id" \
        --arg parentTaskId "${task_id:-}" \
        --argjson prNumber "$PR_NUMBER" \
        --arg reviewPrompt "${review_prompt:0:200}" \
        '{
          reviewId: $reviewId,
          action: $action,
          conversationId: $conversationId,
          newTaskId: null,
          parentTaskId: $parentTaskId,
          prNumber: $prNumber,
          reviewPrompt: $reviewPrompt,
           createdTask: false,
           duplicate: true,
           skipped: true,
           timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
         }')
       echo "$result" | jq .
       return 0
       ;;

    task_created)
      # Task was created in a previous run - reuse it (crash recovery)
      if [ -n "$existing_task_id" ]; then
        echo "dispatch: review $review_id already has task $existing_task_id, reusing" >&2
        local result
        result=$(jq -n \
          --arg reviewId "$review_id" \
          --arg action "$action" \
          --arg conversationId "$conv_id" \
          --arg newTaskId "$existing_task_id" \
          --arg parentTaskId "${task_id:-}" \
          --argjson prNumber "$PR_NUMBER" \
          --arg reviewPrompt "${review_prompt:0:200}" \
          '{
            reviewId: $reviewId,
            action: $action,
            conversationId: $conversationId,
            newTaskId: $newTaskId,
            parentTaskId: $parentTaskId,
            prNumber: $prNumber,
            reviewPrompt: $reviewPrompt,
             createdTask: true,
             reused: true,
             skipped: true,
             timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
           }')
         echo "$result" | jq .
         return 0
       else
         # Corrupted state: task_created but no taskId - treat as pending
        echo "dispatch: review $review_id has task_created without taskId, recovering" >&2
        review_status=""
        existing_task_id=""
      fi
      ;;

    pending)
      # Review claimed but task not yet created - check if taskId was stored
      if [ -n "$existing_task_id" ]; then
        # Should not happen (task_created should have taskId), but handle gracefully
        echo "dispatch: review $review_id has pending status with taskId $existing_task_id, updating to task_created" >&2
      if [ -n "$DB" ] && [ -f "$DB" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='task_created' WHERE commentId='$review_comment_id' AND status='pending';" || {
          echo "ERROR: failed to update review $review_id status to task_created" >&2
          return 1
        }
      fi
        local result
        result=$(jq -n \
          --arg reviewId "$review_id" \
          --arg action "$action" \
          --arg conversationId "$conv_id" \
          --arg newTaskId "$existing_task_id" \
          --arg parentTaskId "${task_id:-}" \
          --argjson prNumber "$PR_NUMBER" \
          --arg reviewPrompt "${review_prompt:0:200}" \
          '{
            reviewId: $reviewId,
            action: $action,
            conversationId: $conversationId,
            newTaskId: $newTaskId,
            parentTaskId: $parentTaskId,
            prNumber: $prNumber,
            reviewPrompt: $reviewPrompt,
             createdTask: true,
             reused: true,
             skipped: true,
             timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
           }')
         echo "$result" | jq .
         return 0
       fi
       # No taskId yet - proceed to create task (fall through)
      ;;

    failed)
      # Previous attempt failed - retry without deleting (task may already exist)
      echo "dispatch: review $review_id previously failed, retrying" >&2
      review_status=""
      existing_task_id=""
      ;;

    "")
      # No existing record - proceed to create
      ;;

    *)
      # Unknown state - retry without deleting (task may already exist)
      echo "dispatch: review $review_id has unknown status '$review_status', retrying" >&2
      review_status=""
      existing_task_id=""
      ;;
  esac

  # ========================================================================
  # Phase 4: Claim the review (only if no existing record)
  # ========================================================================
  if [ -n "$DB" ] && [ -f "$DB" ] && [ -z "$review_status" ]; then
    # No existing record - insert as pending
    local insert_result
    insert_result="$(sqlite3_retry "BEGIN IMMEDIATE; INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, action, status, createdAt, conversationId, prNumber) VALUES('$review_comment_id', '$(sql_escape "$REPO")', $PR_NUMBER, 'https://github.com/${REPO}/pull/${PR_NUMBER}', '$(sql_escape "${AUTHOR:-}")', '$(sql_escape "${BODY:-Review: $REVIEW_STATE}")', 'REVIEW', 'pending', '$now', '$(sql_escape "$conv_id")', $PR_NUMBER); SELECT changes(); COMMIT;" 5)" || {
      echo "ERROR: failed to claim review $review_id" >&2
      return 1
    }
    local inserted="${insert_result%%$'
'*}"
    if [ "${inserted:-0}" -eq 0 ]; then
      # Race condition: another process inserted first, read its state
      echo "dispatch: duplicate review $review_id during claim (race), reading state" >&2
       local race_status race_task
       local race_retry=0
       local race_max_retries=5
       while [ $race_retry -lt $race_max_retries ]; do
         if ! race_status="$(sqlite3_retry "SELECT status, taskId FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW' LIMIT 1;" 3)"; then
           echo "ERROR: SQLite query failed during race condition resolution for $review_id" >&2
           return 1
         fi
         if [ -n "$race_status" ]; then
          local rs rt
          rs="$(echo "$race_status" | cut -d'|' -f1)"
          rt="$(echo "$race_status" | cut -d'|' -f2)"
          if [ "$rs" = "task_created" ] && [ -n "$rt" ]; then
            local result
            result=$(jq -n \
              --arg reviewId "$review_id" \
              --arg action "$action" \
              --arg conversationId "$conv_id" \
              --arg newTaskId "$rt" \
              --arg parentTaskId "${task_id:-}" \
              --argjson prNumber "$PR_NUMBER" \
              '{
                reviewId: $reviewId,
                action: $action,
                conversationId: $conversationId,
                newTaskId: $newTaskId,
                parentTaskId: $parentTaskId,
                prNumber: $prNumber,
                 createdTask: true,
                 reused: true,
                 skipped: true,
                 timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
               }')
             echo "$result" | jq .
             return 0
           fi
           # Race resulted in pending or other state - wait and retry
          if [ "$rs" = "pending" ] && [ $race_retry -lt $((race_max_retries - 1)) ]; then
            race_retry=$((race_retry + 1))
            sleep "0.0$((race_retry * 2))"
            continue
          fi
         fi
         # Fall through to create our own task
         break
       done
    fi
  fi

  # ========================================================================
  # Phase 5: Create REVIEW_FIX task via manul-conversation.sh
  # ========================================================================
  if [ -z "$conv_id" ]; then
    error_exit "No conversation found for PR #$PR_NUMBER" 2
  fi

  local submit_args=(
    --conversation-id "$conv_id"
    --prompt "$review_prompt"
    --action REVIEW_FIX
    --pr-number "$PR_NUMBER"
    --review-id "$REVIEW_ID"
  )

  if [ -n "$task_id" ]; then
    submit_args+=(--parent-task-id "$task_id")
  fi

  local submit_output=""
  if [ -f "${MANUL_DIR}/manul-conversation.sh" ]; then
    submit_output="$(bash "${MANUL_DIR}/manul-conversation.sh" submit "${submit_args[@]}" --json 2>/dev/null)" || {
      # Submit failed - check if concurrent process already created the task
      local submit_fail_retry=0
      local submit_fail_max_retries=3
      local recovered_task_id=""
      while [ $submit_fail_retry -lt $submit_fail_max_retries ]; do
        if [ -n "$DB" ] && [ -f "$DB" ]; then
          recovered_task_id="$(sqlite3_retry "SELECT taskId FROM processed_comments WHERE commentId='review-fix-${conv_id}-${REVIEW_ID}' AND action='REVIEW_FIX' AND status='task_created' LIMIT 1;" 3)" || true
        fi
        if [ -n "$recovered_task_id" ]; then
          echo "dispatch: review $review_id: submit failed but concurrent process created task $recovered_task_id, recovering" >&2
          submit_output=$(jq -n \
            --arg taskId "$recovered_task_id" \
            '{taskId: $taskId}')
          break
        fi
        # Wait and retry
        if [ $submit_fail_retry -lt $((submit_fail_max_retries - 1)) ]; then
          submit_fail_retry=$((submit_fail_retry + 1))
          sleep "0.0$((submit_fail_retry * 2))"
          continue
        fi
      done
      if [ -z "$submit_output" ] || [ -z "$(echo "$submit_output" | jq -r '.taskId // empty')" ]; then
        # No task found - update review to failed state (with retry for SQLite lock)
        if [ -n "$DB" ] && [ -f "$DB" ]; then
          sqlite3_retry "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" 3 || true
        fi
        local fail_result
        fail_result=$(jq -n \
          --arg reviewId "$REVIEW_ID" \
          --arg action "$action" \
          --arg conversationId "$conv_id" \
          --arg parentTaskId "${task_id:-}" \
          --argjson prNumber "$PR_NUMBER" \
          '{
            reviewId: $reviewId,
            action: $action,
            conversationId: $conversationId,
            newTaskId: null,
            parentTaskId: $parentTaskId,
            prNumber: $prNumber,
            createdTask: false,
            error: "submit_failed",
            timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
          }')
        echo "$fail_result" | jq .
        return 1
      fi
    }
  else
    # manul-conversation.sh not found - cannot create task
    if [ -n "$DB" ] && [ -f "$DB" ]; then
      sqlite3_retry "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" 3 || true
    fi
    local fail_result
    fail_result=$(jq -n \
      --arg reviewId "$REVIEW_ID" \
      --arg action "$action" \
      --arg conversationId "$conv_id" \
      --arg parentTaskId "${task_id:-}" \
      --argjson prNumber "$PR_NUMBER" \
      '{
        reviewId: $reviewId,
        action: $action,
        conversationId: $conversationId,
        newTaskId: null,
        parentTaskId: $parentTaskId,
        prNumber: $prNumber,
        createdTask: false,
        error: "conversation_script_missing",
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
      }')
    echo "$fail_result" | jq .
    return 1
  fi

  # ========================================================================
  # Phase 6: Extract taskId and record atomically
  # ========================================================================
  local new_task_id=""
  local submit_success=false

  if [ -n "$submit_output" ]; then
    new_task_id="$(echo "$submit_output" | jq -r '.taskId // empty')"
    if [ -n "$new_task_id" ]; then
      submit_success=true
    fi
  fi

  if [ "$submit_success" = false ]; then
    # Submit returned no taskId - check if concurrent process already created the task
    local recovered_task_id=""
    if [ "$action" = "REQUEST_CHANGES" ] && [ -n "$conv_id" ] && [ -n "$REVIEW_ID" ]; then
      # For REVIEW_FIX actions, the task_id is deterministic: review-fix-{conv_id}-{review_id}
      # Check if a concurrent process already created it
      recovered_task_id="$(sqlite3_retry "SELECT commentId FROM processed_comments WHERE commentId='review-fix-${conv_id}-${REVIEW_ID}' AND action='REVIEW_FIX' LIMIT 1;" 3)" || true
    fi

    if [ -n "$recovered_task_id" ]; then
      # Concurrent process created the task - recover and use it
      echo "dispatch: review $review_id: concurrent process created task $recovered_task_id, recovering" >&2
      new_task_id="$recovered_task_id"
      submit_success=true
    else
      # No task found - genuinely failed
      if [ -n "$DB" ] && [ -f "$DB" ]; then
        sqlite3_retry "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" 3 || true
      fi
      local fail_result
      fail_result=$(jq -n \
        --arg reviewId "$REVIEW_ID" \
        --arg action "$action" \
        --arg conversationId "$conv_id" \
        --arg parentTaskId "${task_id:-}" \
        --argjson prNumber "$PR_NUMBER" \
        '{
          reviewId: $reviewId,
          action: $action,
          conversationId: $conversationId,
          newTaskId: null,
          parentTaskId: $parentTaskId,
          prNumber: $prNumber,
          createdTask: false,
          error: "submit_failed",
          timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }')
      echo "$fail_result" | jq .
      return 1
    fi
  fi

  # ========================================================================
  # Phase 6.5: Test crash injection point (kill after submit, before taskId record)
  # ========================================================================
  if [ "${MANUL_TEST_CRASH_AFTER_SUBMIT:-}" = "1" ]; then
    echo "CRASHED_AFTER_SUBMIT" > "${TEST_DIR:-/tmp}/.crash_marker"
    kill -9 "$BASHPID"
  fi

  # ========================================================================
  # Phase 7: Record taskId atomically - transition pending -> task_created
  # ========================================================================
  if [ -n "$DB" ] && [ -f "$DB" ]; then
    # Atomic transition: only update if still pending (prevents race with concurrent reviews)
    local update_result
    update_result="$(sqlite3_retry "BEGIN IMMEDIATE; UPDATE processed_comments SET status='task_created', taskId='$new_task_id', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending'; SELECT changes(); COMMIT;" 5)" || {
      echo "ERROR: failed to record taskId for review $review_id" >&2
      return 1
    }
    local rows_updated="${update_result%%$'
'*}"
    if [ "${rows_updated:-0}" -eq 0 ]; then
      # Another process already claimed this review - look up their taskId
      echo "dispatch: review $review_id was claimed by concurrent process, looking up taskId" >&2
      local lookup_result
      local lookup_retry=0
      local lookup_max_retries=5
      while [ $lookup_retry -lt $lookup_max_retries ]; do
        lookup_result="$(sqlite3_retry "SELECT taskId FROM processed_comments WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='task_created' LIMIT 1;" 5)" || {
          echo "ERROR: SQLite query failed looking up concurrent taskId for $review_id" >&2
          return 1
        }
        if [ -n "$lookup_result" ]; then
          new_task_id="$lookup_result"
          break
        fi
        # TaskId not set yet - wait and retry
        if [ $lookup_retry -lt $((lookup_max_retries - 1)) ]; then
          lookup_retry=$((lookup_retry + 1))
          sleep "0.0$((lookup_retry * 2))"
          continue
        fi
        # Max retries reached - check if REVIEW_FIX task exists
        break
      done
      if [ -z "$new_task_id" ]; then
        # Check if task was created by concurrent process before marking as failed
        local existing_task
        existing_task="$(sqlite3_retry "SELECT taskId FROM processed_comments WHERE commentId='review-fix-${conv_id}-${REVIEW_ID}' AND action='REVIEW_FIX' LIMIT 1;" 3)" || true
        if [ -n "$existing_task" ]; then
          # Task exists - another process created it successfully
          new_task_id="$existing_task"
          echo "dispatch: review $review_id: concurrent process created task $existing_task, recovering" >&2
        else
          # Both processes failed - mark as failed
          sqlite3_retry "UPDATE processed_comments SET status='failed', processedAt=datetime('now') WHERE commentId='$review_comment_id' AND action='REVIEW' AND status='pending';" 3 || true
          local fail_result
          fail_result=$(jq -n \
            --arg reviewId "$REVIEW_ID" \
            --arg action "$action" \
            --arg conversationId "$conv_id" \
            --arg parentTaskId "${task_id:-}" \
            --argjson prNumber "$PR_NUMBER" \
            '{
              reviewId: $reviewId,
              action: $action,
              conversationId: $conversationId,
              newTaskId: null,
              parentTaskId: $parentTaskId,
              prNumber: $prNumber,
              createdTask: false,
              error: "concurrent_claim_failed",
              timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
            }')
          echo "$fail_result" | jq .
          return 1
        fi
      fi
    fi
  fi

  # ========================================================================
  # Phase 8: Return success with taskId
  # ========================================================================
  local result
  result=$(jq -n \
    --arg reviewId "$REVIEW_ID" \
    --arg action "$action" \
    --arg conversationId "$conv_id" \
    --arg newTaskId "$new_task_id" \
    --arg parentTaskId "${task_id:-}" \
    --argjson prNumber "$PR_NUMBER" \
    --arg reviewPrompt "${review_prompt:0:200}" \
    '{
      reviewId: $reviewId,
      action: $action,
      conversationId: $conversationId,
      newTaskId: $newTaskId,
      parentTaskId: $parentTaskId,
      prNumber: $prNumber,
      reviewPrompt: $reviewPrompt,
      createdTask: true,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')

  echo "$result" | jq .
  return 0
}

# Get conversation info for a PR
cmd_get_conversation() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
    error_exit "get-conversation requires --repo and --pr-number" 3
  fi

  get_pr_context "$REPO" "$PR_NUMBER"
}

# List reviews for a PR
cmd_list_reviews() {
  if [ -z "$REPO" ] || [ -z "$PR_NUMBER" ]; then
    error_exit "list-reviews requires --repo and --pr-number" 3
  fi

  local reviews="[]"

  if command -v gh >/dev/null 2>&1; then
    reviews="$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" 2>/dev/null | jq '.' || echo '[]')"
  fi

  local result
  result=$(jq -n \
    --argjson reviews "$reviews" \
    --arg repo "$REPO" \
    --argjson prNumber "$PR_NUMBER" \
    '{
      repo: $repo,
      prNumber: $prNumber,
      reviews: $reviews,
      reviewCount: ($reviews | length)
    }')

  echo "$result" | jq .
}

# Main dispatch
case "${ACTION:-}" in
  handle) cmd_handle ;;
  get-conversation) cmd_get_conversation ;;
  list-reviews) cmd_list_reviews ;;
  "")
    echo "Usage: manul-pr-review.sh <command> [options]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  handle           Handle an incoming PR review" >&2
    echo "  get-conversation Get conversation context for a PR" >&2
    echo "  list-reviews     List reviews for a PR" >&2
    exit 3
    ;;
  *)
    error_exit "Unknown command: $ACTION" 3
    ;;
esac
