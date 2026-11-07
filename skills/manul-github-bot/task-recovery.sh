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
  local safe_comment_id changed
  safe_comment_id="$(printf '%s' "$comment_id" | sed "s/'/''/g")"

  # A failed row is terminal and must not own a live executor. Do not touch a
  # PID file here: a concurrent dispatcher may already have claimed a newer
  # task after a state transition. The guarded UPDATE is the only mutation.
  changed="$(sqlite3 "$DB" "
    UPDATE processed_comments
    SET status='queued',
        attempts=0,
        preExecutionFailures=0,
        agentStartedAt=NULL,
        processedAt=NULL,
        heartbeatAt=NULL,
        workerPid=NULL,
        leaseExpiresAt=NULL,
        claimToken=NULL,
        nextAttemptAt=datetime('now')
    WHERE commentId='$safe_comment_id' AND status='failed';
    SELECT changes();
  " 2>>"$LOG" | tail -n 1)" || changed="0"

  if [ "${changed:-0}" -ne 1 ]; then
    log "ERROR: failed task $comment_id was not retried because it no longer exists or is not failed"
    return 1
  fi

  log "Failed task $comment_id requeued from scratch (agent attempts and infrastructure failures reset)"
}

# Retry a task that was marked terminal 'stale'. A stale row blocks re-polling
# because poll.sh keys processed_comments on commentId (INSERT OR IGNORE), so a
# blind delete+re-poll would silently drop the task. Instead this resets the
# row to queued with a cleared lease and an immediate nextAttemptAt.
#
# Safety contract (fail-closed):
#   * The row MUST still be status='stale' before we do anything — a task that
#     has already moved on (queued/running/done/failed) is left untouched.
#   * Source revalidation is MANDATORY and read-only. It is the only thing that
#     distinguishes a recoverable stale task from one whose source is gone.
#     Only a positive rc=0 (source fresh) proceeds. rc=1 (terminal stale),
#     rc=2 (transient), and ANY other rc (127 command-not-found, 130 timeout,
#     a crash, a missing revalidation function) all refuse — we never requeue a
#     task we could not positively confirm is still valid.
#   * The state reset is an atomic compare-and-swap guarded by the full source
#     identity we just revalidated. If the row (or its source identity) changed
#     between the pre-check and the write, the CAS matches 0 rows and we abort.
#   * We NEVER kill an executor from this path and we NEVER remove a pid file
   #     that points at a live process. A stale task has no live executor by
   #     construction (mark_task_stale runs only pre-flight, before any executor
   #     is launched), so the only artifact left behind is a dead pid file. We
   #     remove that dead pid file only when its recorded PID is not alive, which
   #     is safe even if the dispatcher claimed the row and launched a fresh
   #     executor in the window between our status read and the cleanup: the
   #     fresh executor writes its own PID, and our alive-check refuses to touch
   #     a pid file pointing at a live process. Orphan cleanup in the daemon is
   #     the designated owner for any executor that really needs terminating.
retry_stale_task() {
  local comment_id="$1"
  local safe_comment_id
  safe_comment_id="$(printf '%s' "$comment_id" | sed "s/'/''/g")"
  # SQL-quote a value so it can be embedded in a literal safely.
  esc() { printf '%s' "$1" | sed "s/'/''/g"; }

  # --- 1. Pre-flight: require the row to exist, be 'stale', and have identity.
  # Snapshot the full source identity now; the CAS re-asserts every field.
  local row
  row="$(sqlite3 -separator $'\x1f' "$DB" "
    SELECT COALESCE(repository,''), COALESCE(issueNumber,''),
           COALESCE(taskSourceType,''), COALESCE(taskSourceId,''),
           COALESCE(taskSourceUrl,''), COALESCE(status,'')
    FROM processed_comments
    WHERE commentId='$safe_comment_id' LIMIT 1;
  " 2>>"$LOG" || true)"
  if [ -z "$row" ]; then
    log "ERROR: stale task $comment_id not found; nothing to retry"
    return 1
  fi
  local repo issue_num source_type source_id source_url status
  IFS=$'\x1f' read -r repo issue_num source_type source_id source_url status <<< "$row"
  if [ "$status" != "stale" ]; then
    log "ERROR: task $comment_id is not stale (status=${status:-empty}); refusing to retry"
    return 1
  fi
  if [ -z "$repo" ]; then
    log "ERROR: cannot retry stale task $comment_id — no repository found"
    return 1
  fi

  # --- 2. MANDATORY read-only source revalidation (fail-closed). ---
  local reval_rc
  if [ -n "$source_type" ]; then
    # Source-task rows carry a taskSourceType; revalidate through the provider
    # contract so Todo/GitHub-Issues sources are checked the same way the
    # dispatcher would check them at claim time.
    if ! declare -f task_source_revalidate >/dev/null 2>&1; then
      source "$SCRIPT_DIR/task-source.sh" 2>>"$LOG" || true
    fi
    if ! declare -f task_source_revalidate >/dev/null 2>&1; then
      log "ERROR: task_source_revalidate unavailable for $comment_id; refusing to retry without source check"
      return 1
    fi
    task_source_revalidate "$MANUL_CONFIG" "$source_type" "$source_id" "$repo" "$issue_num"
    reval_rc=$?
  else
    # Legacy comment-derived task: revalidate the comment/issue/PR itself. We
    # source the SAFE revalidation library (not the daemon) so that a normal
    # CLI invocation never falls through the daemon's CLI dispatcher, which
    # would exit 2 and kill the whole recovery process.
    if ! declare -f revalidate_source >/dev/null 2>&1; then
      source "$SCRIPT_DIR/task-source-revalidate.sh" 2>>"$LOG" || true
    fi
    if ! declare -f revalidate_source >/dev/null 2>&1; then
      log "ERROR: revalidate_source unavailable for legacy task $comment_id; refusing to retry without source check"
      return 1
    fi
    revalidate_source "$comment_id" "$repo" "$issue_num" "$source_url"
    reval_rc=$?
  fi

  # Fail-closed: ONLY rc=0 (source fresh) may proceed. Every other outcome —
  # terminal stale (1), transient (2), or unexpected (127, 130, crash, ...) —
  # refuses, so we never manufacture a zombie from an unverifiable source.
  if [ "$reval_rc" -ne 0 ]; then
    case "$reval_rc" in
      1) log "Refusing to retry stale task $comment_id — source no longer valid (terminal, rc=1)" ;;
      2) log "Refusing to retry stale task $comment_id — source revalidation transient failure (rc=2); retry later via the daemon" ;;
      *) log "ERROR: refusing to retry stale task $comment_id — source revalidation returned unexpected rc=$reval_rc (fail-closed)" ;;
    esac
    return 1
  fi

  # --- 3. Atomic compare-and-swap: stale -> queued, guarded by identity. ---
  # The WHERE clause re-asserts status AND the full source identity we
  # revalidated. A concurrent dispatcher/worker that changed the row, or any
  # drift in source identity, makes the CAS match 0 rows and we abort cleanly.
  log "Retrying stale task $comment_id from scratch (source revalidated, rc=0)"
  local repo_sql issue_num_sql source_type_sql source_id_sql source_url_sql
  repo_sql="$(esc "$repo")"; issue_num_sql="$(esc "$issue_num")"
  source_type_sql="$(esc "$source_type")"; source_id_sql="$(esc "$source_id")"
  source_url_sql="$(esc "$source_url")"
  local changed
  changed="$(sqlite3 "$DB" "
    UPDATE processed_comments
    SET status='queued', attempts=0, processedAt=NULL, heartbeatAt=NULL, workerPid=NULL,
        leaseExpiresAt=NULL, claimToken=NULL, agentStartedAt=NULL,
        preExecutionFailures=0, nextAttemptAt=datetime('now')
    WHERE commentId='$safe_comment_id'
      AND status='stale'
      AND COALESCE(repository,'')='$repo_sql'
      AND COALESCE(CAST(issueNumber AS TEXT),'')='$issue_num_sql'
      AND COALESCE(taskSourceType,'')='$source_type_sql'
      AND COALESCE(taskSourceId,'')='$source_id_sql'
      AND COALESCE(taskSourceUrl,'')='$source_url_sql';
    SELECT changes();
  " 2>>"$LOG" | tail -n 1)" || changed="0"
  if [ "${changed:-0}" -ne 1 ]; then
    log "ERROR: stale task $comment_id changed during revalidation (changes=${changed:-0}); refusing to retry"
    return 1
  fi

  # --- 4. Executor/PID-file lifecycle remains daemon-owned. ---
  # Do not inspect, signal, unlink, or otherwise mutate executor.pid here.
  # Even a kill -0 check followed by rm has a TOCTOU window: the dispatcher
  # can replace the dead PID marker with a fresh executor PID between those
  # operations. The queued task's executor marker is exclusively owned by the
  # dispatcher/runner; daemon orphan cleanup remains the only cleanup owner.
  log "Stale task $comment_id requeued as queued with immediate nextAttemptAt; executor PID-file lifecycle remains daemon-owned"
  return 0
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
    --retry-stale)
        shift
        if [ -z "${1:-}" ]; then
            echo "Error: --retry-stale requires a task id" >&2
            exit 1
        fi
        retry_stale_task "$1"
        ;;
    --health-check)
        health_check
        ;;
    *)
        echo "Usage: $0 [--list-stuck|--reset <id>|--mark-failed <id>|--reset-all[=running|failed]|--retry <id>|--retry-stale <id>|--health-check]"
        exit 1
        ;;
esac
