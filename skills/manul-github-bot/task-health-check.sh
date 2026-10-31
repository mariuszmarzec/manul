#!/bin/bash
# task-health-check.sh — Proactive task health monitor for manul daemon
#
# This script runs as a background process and monitors manul task state,
# detecting stuck tasks and taking corrective action.
#
# Recommended cron schedule: every 2 minutes
#   */2 * * * * $MANUL_DIR/task-health-check.sh
#
# Supported env vars (set in environment or override in config):
#   MANUL_DIR       — manul directory (default: $HOME/.manul)
#   MANUL_DB        — SQLite database path (default: $MANUL_DIR/manul.db)
#
# History:
#   2026-08-25 — Initial version with health monitoring
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
source "$SCRIPT_DIR/manul-failure-utils.sh"
# DB on native ext4 (NOT on 9p /mnt/f); honor an explicit test/operator override.
MANUL_DB="${DB:-$MANUL_DB}"
LOG="$MANUL_LOG_DIR/task-health.log"

# Configuration defaults (can be overridden via config.json)
DEFAULT_MAX_RUNNING_TIME=1800      # 30 minutes max task runtime
DEFAULT_MAX_FAILURES=3            # mark as failed after N attempts
DEFAULT_RESET_COOLDOWN=300        # seconds between resets for same task

# Load config overrides if available
if [ -f "$MANUL_DIR/config.json" ]; then
    LOADED_MAX_RUNNING="$(jq -r '.automation.maxTaskRunningTime // empty' "$MANUL_DIR/config.json" 2>/dev/null)"
    [ -n "$LOADED_MAX_RUNNING" ] && DEFAULT_MAX_RUNNING_TIME="$LOADED_MAX_RUNNING"
    LOADED_MAX_FAILURES="$(jq -r '.automation.maxAttemptsBeforeFail // empty' "$MANUL_DIR/config.json" 2>/dev/null)"
    [ -n "$LOADED_MAX_FAILURES" ] && DEFAULT_MAX_FAILURES="$LOADED_MAX_FAILURES"
    LOADED_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$MANUL_DIR/config.json" 2>/dev/null || echo "60")"
    [ -n "$LOADED_RETRY_DELAY" ] && RETRY_DELAY_SECONDS="$LOADED_RETRY_DELAY"
fi
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${RETRY_DELAY_SECONDS:-60}}"

log() { echo "[$(date -Is)] $*" >> "$LOG"; }

# Function: get_db_query - run sqlite3 query against manul.db
get_db_query() {
    sqlite3 "$MANUL_DB" "$1" 2>/dev/null || echo ""
}

post_terminal_failure_feedback() {
    if [ "${MANUL_MODE:-bot}" = "human" ]; then
        log "terminal failure status comment suppressed in human mode for $1"
        return 0
    fi
    local comment_id="$1" repo="$2" issue_num="$3" error="$4" stage="${5:-task_health_check}"
    error="$(manul_redact_failure_details "$error")"
    local args=(post-failed --repo "$repo" --issue "$issue_num" --comment-id "$comment_id" --task-id "$comment_id" --error "$error" --stage "$stage")
    if [[ "$comment_id" =~ ^review:[0-9]+$ ]]; then args+=(--pr-number "$issue_num"); fi
    local try
    for try in 1 2 3; do
        if MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result-feedback.sh" "${args[@]}" >>"$LOG" 2>&1; then
            log "terminal failure comment confirmed for $comment_id at stage task_health_check (new or already published, try=$try)"
            return 0
        fi
        log "WARN: terminal failure comment failed for $comment_id (try=$try/3)"
        [ "$try" -lt 3 ] && sleep "$try"
    done
    log "ERROR: terminal failure comment could not be posted for $comment_id"
    return 1
}

# Function: mark_task_failed - finalize a stuck task after its claim budget is used.
# Attempts count actual claims, so recovery must not increment it again.
mark_task_failed() {
    local comment_id="$1"
    local attempts="$2"
    local safe_comment_id repo issue_num current_attempt row changed
    safe_comment_id="$(printf '%s' "$comment_id" | sed "s/'/''/g")"
    row="$(sqlite3 "$MANUL_DB" "SELECT repository || '|' || issueNumber || '|' || attempts FROM processed_comments WHERE commentId='$safe_comment_id' AND status='running' LIMIT 1;" 2>>"$LOG" || true)"
    if [ -z "$row" ]; then
        log "WARN: refusing to mark task failed because it is no longer running: $comment_id"
        return 1
    fi
    IFS='|' read -r repo issue_num current_attempt <<< "$row"
    [[ "$current_attempt" =~ ^[0-9]+$ ]] || current_attempt="$attempts"

    changed="$(sqlite3 "$MANUL_DB" "
        UPDATE processed_comments
        SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=NULL
        WHERE commentId='$safe_comment_id' AND status='running' AND attempts >= $DEFAULT_MAX_FAILURES;
        SELECT changes();
    " 2>>"$LOG" | tail -n 1)"
    if [ "${changed:-0}" -ne 1 ]; then
        log "WARN: task $comment_id was not marked failed; state/attempt count changed or retry budget remains"
        return 1
    fi

    log "FAILED task: $comment_id (attempts=$current_attempt/$DEFAULT_MAX_FAILURES)"
    post_terminal_failure_feedback "$comment_id" "$repo" "$issue_num" "Task exceeded the maximum runtime of ${DEFAULT_MAX_RUNNING_TIME}s after ${current_attempt}/$DEFAULT_MAX_FAILURES attempts." "task_health_check" || true
}

# Function: reset_task_to_queued - reset stuck task to queued state
reset_task_to_queued() {
    local comment_id="$1"
    local current_status="$2"
    sqlite3 "$MANUL_DB" "
        UPDATE processed_comments
        SET status='queued', processedAt=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds')
        WHERE commentId='$comment_id';
    " 2>/dev/null
    log "RESET task: $comment_id from $current_status to QUEUED"
}

# Function: check_running_tasks - detect tasks stuck in 'running' state
check_running_tasks() {
    local running_count
    running_count=$(get_db_query "SELECT COUNT(*) FROM processed_comments WHERE status='running'")
    
    if [ "$running_count" -eq 0 ] || [ -z "$running_count" ]; then
        log "No tasks currently running — OK"
        return 0
    fi
    
    log "WARNING: $running_count task(s) currently running"
    
    # Check each running task
    local running_tasks
    running_tasks=$(get_db_query "
        SELECT commentId, repository, issueNumber, attempts, processedAt
        FROM processed_comments 
        WHERE status='running'
        ORDER BY processedAt;
    ")
    
    if [ -z "$running_tasks" ] || [ "$running_tasks" = "" ]; then
        log "Could not retrieve running tasks from DB"
        return 0
    fi
    
    # Process each task
    while IFS='|' read -r comment_id repo issue_num attempts processed_at; do
        [ -z "$comment_id" ] && continue
        
        # Get current attempts count
        local current_attempts="${attempts:-0}"
        
        # Check if task has been running too long
        if [ -n "$processed_at" ]; then
            # Calculate task age in seconds
            task_start_epoch=$(date -d "$processed_at" +%s 2>/dev/null || echo 0)
            current_epoch=$(date +%s)
            task_age_seconds=$((current_epoch - task_start_epoch))
            
            # Check if exceeded max running time
            if [ "$task_age_seconds" -gt "$DEFAULT_MAX_RUNNING_TIME" ]; then
                log "TASK STUCK: $comment_id ($repo#$issue_num) running for ${task_age_seconds}s (max: ${DEFAULT_MAX_RUNNING_TIME}s)"
                
                # Check if should fail based on attempts
                if [ "$current_attempts" -ge "$DEFAULT_MAX_FAILURES" ]; then
                    mark_task_failed "$comment_id" "$current_attempts"
                else
                    reset_task_to_queued "$comment_id" "running"
                    log "  → Reset to QUEUED, will be retried on next poll"
                fi
            fi
        else
            log "  WARNING: $comment_id ($repo#$issue_num) has no processedAt — likely stuck from crash"
            # Reset tasks with no processedAt (crash scenario)
            if [ "$current_attempts" -lt "$DEFAULT_MAX_FAILURES" ]; then
                reset_task_to_queued "$comment_id" "running (no processedAt)"
            else
                mark_task_failed "$comment_id" "$current_attempts"
            fi
        fi
    done <<< "$running_tasks"
}

# Function: check_queue_health - verify queue.json consistency with DB
check_queue_health() {
    local queue_file="$MANUL_DIR/queue.json"
    local db_count db_queue_count
    
    # Check DB pending count
    db_count=$(get_db_query "SELECT count(*) FROM processed_comments WHERE status='queued'")
    
    # Check queue.json pending count
    if [ -f "$queue_file" ]; then
        jq_count=$(jq 'length' "$queue_file" 2>/dev/null || echo 0)
        # Note: queue.json may have slightly different counts due to polling timing
        log "DB queued: $db_count, queue.json pending: $jq_count"
    else
        log "queue.json not found — DB queued: $db_count"
    fi
}

# Function: log_system_status - overall status snapshot
log_system_status() {
    log "=== Health Check ==="
    local total tasks queued running done failed
    
    tasks=$(get_db_query "
        SELECT status, COUNT(*) as cnt 
        FROM processed_comments 
        GROUP BY status
        ORDER BY status;
    " 2>/dev/null || echo "")
    
    if [ -n "$tasks" ]; then
        while IFS='|' read -r status count; do
            case "$status" in
                running) running=$count ;;
                queued) queued=$count ;;
                done) done=$count ;;
                failed) failed=$count ;;
            esac
        done <<< "$tasks"
    fi
    
    total=$((running + queued + done + failed))
    log "DB Summary: total=$total running=$running queued=$queued done=$done failed=$failed"
}

# Main loop
main() {
    log "=== Task Health Check started ==="
    
    # First, check overall consistency
    check_queue_health
    
    # Check for stuck running tasks
    check_running_tasks
    
    # Log system status
    log_system_status
    
    log "=== Health Check complete ==="
}

# Run main function
main

# Exit code
exit 0