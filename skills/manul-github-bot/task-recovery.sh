#!/bin/bash
# task-recovery.sh — Manual recovery for stuck tasks
#
# This script provides manual intervention capabilities.
#
# Usage: task-recovery.sh [options]
#   --list-stuck      List all tasks stuck in 'running'
#   --reset <id>      Reset a specific task commentId to 'queued'
#   --mark-failed <id> Mark a specific task commentId as 'failed'
#   --reset-all       Reset all stuck tasks (dangerous - confirm)
#   --health-check    Run comprehensive health check

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="$MANUL_DB"
LOG="$MANUL_LOG_DIR/task-recovery.log"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$MANUL_CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

log() { echo "[$(date -Is)] $*"; }

post_terminal_failure_feedback() {
    if [ "${MANUL_MODE:-bot}" = "human" ]; then
        log "terminal failure status comment suppressed in human mode for $1"
        return 0
    fi
    local comment_id="$1" repo="$2" issue_num="$3" error="$4"
    local args=(post-failed --repo "$repo" --issue "$issue_num" --comment-id "$comment_id" --task-id "$comment_id" --error "$error")
    if [[ "$comment_id" =~ ^review:[0-9]+$ ]]; then args+=(--pr-number "$issue_num"); fi
    local try
    for try in 1 2 3; do
        if MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result-feedback.sh" "${args[@]}" >>"$LOG" 2>&1; then
            log "terminal failure comment posted for $comment_id (try=$try)"
            return 0
        fi
        log "WARN: terminal failure comment failed for $comment_id (try=$try/3)"
        [ "$try" -lt 3 ] && sleep "$try"
    done
    log "ERROR: terminal failure comment could not be posted for $comment_id"
    return 1
}

terminate_task_executor() {
    local comment_id="$1"
    local pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "executor.pid")"
    local executor_pid=""
    if [ -f "$pid_file" ]; then executor_pid="$(cat "$pid_file" 2>/dev/null || true)"; fi
    if [[ "$executor_pid" =~ ^[0-9]+$ ]] && [ "$executor_pid" -gt 0 ] && kill -0 "$executor_pid" 2>/dev/null; then
        log "Terminating isolated executor for task $comment_id (pid=$executor_pid)"
        kill -- "-$executor_pid" 2>/dev/null || kill "$executor_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file" 2>/dev/null || true
}
list_stuck_tasks() {
    log "=== LISTING STUCK TASKS ==="
    if [ ! -f "$DB" ]; then
        log "ERROR: manul.db not found"
        return 1
    fi
    sqlite3 "$DB" "
        SELECT commentId, repository, issueNumber, status, attempts, heartbeatAt, workerPid
        FROM processed_comments
        WHERE status='running'
        ORDER BY createdAt DESC;
    " 2>/dev/null
}

reset_task() {
    local comment_id="$1"
    log "Resetting task $comment_id to queued"
    terminate_task_executor "$comment_id"
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds')
        WHERE commentId='$comment_id' AND status='running';
    " 2>/dev/null
}

mark_task_failed() {
    local comment_id="$1"
    local safe_comment_id repo issue_num attempts row changed
    safe_comment_id="$(printf '%s' "$comment_id" | sed "s/'/''/g")"
    row="$(sqlite3 "$DB" "SELECT repository || '|' || issueNumber || '|' || attempts FROM processed_comments WHERE commentId='$safe_comment_id' AND status='running' LIMIT 1;" 2>>"$LOG" || true)"
    if [ -z "$row" ]; then
        log "Refusing to mark task $comment_id failed because it is no longer running"
        return 1
    fi
    IFS='|' read -r repo issue_num attempts <<< "$row"
    log "Marking task $comment_id as failed"
    terminate_task_executor "$comment_id"
    changed="$(sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL
        WHERE commentId='$safe_comment_id' AND status='running';
        SELECT changes();
    " 2>>"$LOG" | tail -n 1)"
    if [ "${changed:-0}" -ne 1 ]; then
        log "WARN: task $comment_id was not marked failed because its state changed"
        return 1
    fi
    post_terminal_failure_feedback "$comment_id" "$repo" "$issue_num" "Task was manually marked failed by task-recovery.sh after ${attempts:-unknown} execution attempt(s)." || true
}

retry_failed_task() {
    local comment_id="$1"
    log "Retrying failed task $comment_id from scratch"
    terminate_task_executor "$comment_id"
    sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', attempts=0, processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now')
        WHERE commentId='$comment_id' AND status='failed';
    " 2>/dev/null
}

reset_all_tasks() {
    local status_filter="${1:-running}"
    case "$status_filter" in
        running|failed) ;;
        *)
            echo "Error: --reset-all supports only running or failed" >&2
            return 1
            ;;
    esac

    log "WARNING: Resetting ALL $status_filter tasks to queued (DANGEROUS)"
    read -p "Are you sure? (yes/no): " -r confirm
    if [ "$confirm" != "yes" ]; then
        log "Aborted"
        return
    fi

    if [ "$status_filter" = "failed" ]; then
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', attempts=0, processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now') WHERE status='failed';" 2>/dev/null
    else
        local running_tasks
        running_tasks="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE status='running';" 2>/dev/null || true)"
        while IFS= read -r comment_id; do
            [ -n "$comment_id" ] || continue
            terminate_task_executor "$comment_id"
        done <<< "$running_tasks"
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE status='running';" 2>/dev/null
    fi

    log "All $status_filter tasks reset"
}

health_check() {
    log "=== HEALTH CHECK ==="
    if [ ! -f "$DB" ]; then
        log "ERROR: manul.db not found"
        return 1
    fi
    
    local total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;" 2>/dev/null || echo 0)
    local queued=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued';" 2>/dev/null || echo 0)
    local running=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='running';" 2>/dev/null || echo 0)
    local done=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='done';" 2>/dev/null || echo 0)
    local failed=$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='failed';" 2>/dev/null || echo 0)
    
    log "Total tasks: $total"
    log "Queued: $queued"
    log "Running: $running"
    log "Done: $done"
    log "Failed: $failed"
    
    if [ "$running" -gt 0 ]; then
        log "WARNING: $running tasks are still running"
        list_stuck_tasks
    fi
}

# Parse arguments
case "${1:-}" in
    --list-stuck)
        list_stuck_tasks
        ;;
    --reset)
        shift
        reset_task "$1"
        ;;
    --mark-failed)
        shift
        mark_task_failed "$1"
        ;;
    --reset-all)
        reset_all_tasks "running"
        ;;
    --reset-all=*)
        reset_all_tasks "${1#--reset-all=}"
        ;;
    --retry)
        shift
        if [ -z "${1:-}" ]; then
            echo "Error: --retry requires a task id" >&2
            exit 1
        fi
        retry_failed_task "$1"
        ;;
    --health-check)
        health_check
        ;;
    *)
        echo "Usage: $0 [--list-stuck|--reset <id>|--mark-failed <id>|--reset-all[=running|failed]|--retry <id>|--health-check]"
        exit 1
        ;;
esac
