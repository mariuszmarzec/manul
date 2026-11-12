#!/usr/bin/env bash
# watchdog.sh — ONLY automatic recovery mechanism
#
# Run from cron every 5 minutes:
#   */5 * * * * $MANUL_DIR/watchdog.sh
#
# Responsibilities:
#   1. Start the daemon if it is not running.
#   2. Detect a stale lock file (age >= LOCK_TTL) and remove it (WITHOUT resetting tasks).
#   3. Recover tasks based on stale heartbeat/lease ONLY, respecting worker ownership.

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# Cron does not inherit the interactive Homebrew PATH on macOS.
source "$SCRIPT_DIR/manul-platform.sh"
manul_platform_prepare || exit 1
manul_platform_reexec_if_needed "$SCRIPT_DIR/watchdog.sh" "$@"
# Cron does not load ~/.zshrc, so load the runtime-owned environment before
# resolving Manul paths or watchdog operator overrides.
source "$SCRIPT_DIR/manul-env.sh"
if ! manul_env_load "$MANUL_DIR"; then
    echo "ERROR: failed to load $MANUL_DIR/.env" >&2
    exit 1
fi
source "$SCRIPT_DIR/manul-paths.sh"
source "$SCRIPT_DIR/task-process-control.sh"
CONFIG="$MANUL_CONFIG"
LOCK="$MANUL_LOCKS_DIR/watchdog.lock"
PID_FILE="$MANUL_LOCKS_DIR/daemon.pid"
LOG="$MANUL_LOG_DIR/watchdog.log"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="$MANUL_DB"
LOCK_TTL="${MANUL_LOCK_TTL_SECONDS:-1800}"  # 30 minutes
MAX_ATTEMPTS="${MANUL_MAX_ATTEMPTS:-3}"

# Load config overrides
if [ -f "$CONFIG" ]; then
    CFG_MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // empty' "$CONFIG" 2>/dev/null)"
    [ -n "$CFG_MAX_ATTEMPTS" ] && MAX_ATTEMPTS="$CFG_MAX_ATTEMPTS"
    CFG_LOCK_TTL="$(jq -r '.automation.lockTtl // empty' "$CONFIG" 2>/dev/null)"
    [ -n "$CFG_LOCK_TTL" ] && LOCK_TTL="$CFG_LOCK_TTL"
    CFG_HEARTBEAT_TIMEOUT="$(jq -r '.automation.heartbeatTimeout // empty' "$CONFIG" 2>/dev/null)"
    CFG_LEASE_TIMEOUT="$(jq -r '.automation.leaseTimeout // empty' "$CONFIG" 2>/dev/null)"
fi

HEARTBEAT_TIMEOUT="${CFG_HEARTBEAT_TIMEOUT:-900}"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

log() { echo "[$(date -Is)] $*" >> "$LOG"; }

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

# --- .enabled gate --------------------------------------------------------
# The .enabled marker is the lifecycle contract between intentional start/stop
# and the watchdog. It is created by install-manul.sh (fresh install), the `manul`
# alias, and start-manul-automation.sh start; it is removed by
# start-manul-automation.sh stop and manul-daemon.sh stop.
#
# The watchdog ONLY performs recovery when .enabled is present. This is what
# prevents an endless restart loop: if the daemon dies, the watchdog restarts
# it — but it never re-enables automation. A human (or the `manul` alias) must
# intentionally re-enable it. Without this gate, a crash during boot would leave
# the watchdog spinning forever, and a machine that was intentionally stopped
# would silently come back to life.
if [ ! -f "$MANUL_DIR/.enabled" ]; then
    log "Manul not intentionally enabled (no .enabled marker) — skipping recovery"
    exit 0
fi

# Cron can overlap when one recovery run takes longer than five minutes. Keep
# only one watchdog active so two scans cannot concurrently claim the same
# stale row or race over the task-scoped executor PID file.
WATCHDOG_RUN_LOCK="$MANUL_LOCKS_DIR/watchdog-run.flock"
exec 209>"$WATCHDOG_RUN_LOCK"
if ! flock -n 209; then
    log "watchdog already running; skipping overlapping invocation"
    exit 0
fi

# --- 1) daemon liveness ----------------------------------------------------
# Reconcile leases and run the conservative filesystem/cache GC before
# daemon startup. The GC's flock prevents overlap with the daemon's dispatcher.
if [ -f "$DB" ] && [ -x "$MANUL_DIR/workspace-gc.sh" ]; then
    if ! "$MANUL_DIR/workspace-gc.sh" >>"$LOG" 2>&1; then
        log "workspace GC failed"
    fi
elif [ -f "$DB" ] && [ -f "$MANUL_DIR/workspace-manager.sh" ]; then
    # Compatibility fallback for an installation being upgraded before the
    # workspace-gc symlink has been deployed.
    if bash -n "$MANUL_DIR/workspace-manager.sh" 2>/dev/null && source "$MANUL_DIR/workspace-manager.sh"; then
        workspace_cleanup_stale 3600 || log "workspace stale cleanup failed"
    else
        log "ERROR: invalid workspace manager: $MANUL_DIR/workspace-manager.sh"
    fi
fi

if ! [ -f "$PID_FILE" ] || ! kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    log "daemon not running (no pid / pid not alive) → starting through canonical startup wrapper"
    rm -f "$PID_FILE"  # Clear stale PID file before starting

    START_WRAPPER="$MANUL_DIR/start-manul-automation.sh"
    if [ ! -x "$START_WRAPPER" ]; then
        log "ERROR: canonical startup wrapper missing: $START_WRAPPER"
        exit 1
    fi

    # The startup wrapper synchronizes the standalone Manul checkout and
    # refreshes runtime symlinks before launching the daemon. Watchdog uses
    # the same canonical source so recovery cannot resurrect stale scripts.
    if ! "$START_WRAPPER" start 209>&- >>"$LOG" 2>&1; then
        log "ERROR: daemon startup via canonical wrapper failed"
        exit 1
    fi
fi

# --- 2) stale lock recovery ------------------------------------------------
if [ -f "$LOCK" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
    if [ "$age" -ge "$LOCK_TTL" ]; then
        log "stale lock detected (age=${age}s, ttl=${LOCK_TTL}s) → removing"
        rm -f "$LOCK"
        # NO DB reset on stale lock - only heartbeat-based recovery
    fi
fi

# --- 3) heartbeat-based task recovery -------------------------------------
if [ -f "$DB" ]; then
    # Migrate legacy databases before recovery.
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|claimToken|'; then
        sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN claimToken TEXT;" 2>>"$LOG"
        log "migration: added claimToken column"
    fi
    # Find tasks with stale heartbeat or expired lease. A live worker loop
    # is not sufficient: its heartbeat subprocess may have died silently.
    STUCK_TASKS="$(sqlite3 "$DB" "
        SELECT commentId, repository, issueNumber, attempts, heartbeatAt, leaseExpiresAt, workerPid, claimToken,
               COALESCE(agentStartedAt,''),
               CASE
                 WHEN heartbeatAt IS NULL
                   OR datetime(heartbeatAt) < datetime('now', '-${HEARTBEAT_TIMEOUT} seconds')
                   OR leaseExpiresAt IS NULL
                   OR datetime(leaseExpiresAt) < datetime('now')
                 THEN 1 ELSE 0
               END AS lease_stale
        FROM processed_comments
        WHERE status='running';
    " 2>>"$LOG" || true)"
    if [ -n "$STUCK_TASKS" ]; then
        while IFS='|' read -r comment_id repo issue_num attempts heartbeat_at lease_at worker_pid claim_token agent_started_at lease_stale; do
            [ -n "$comment_id" ] || continue

            worker_alive=0
            if task_process_is_running "$worker_pid"; then
                worker_alive=1
            fi
            heartbeat_alive=0
            if task_heartbeat_is_alive "$comment_id" "$worker_pid"; then
                heartbeat_alive=1
            fi

            # A claim may briefly exist before agentStartedAt and its heartbeat
            # child are recorded. Do not recover that healthy pre-execution window.
            if [ "$lease_stale" = "0" ] && [ "$worker_alive" -eq 1 ] && { [ -z "$agent_started_at" ] || [ "$heartbeat_alive" -eq 1 ]; }; then
                continue
            fi

            log "RECOVERY: candidate $comment_id ($repo#$issue_num) (worker=$worker_pid alive=$worker_alive heartbeat_alive=$heartbeat_alive heartbeat=${heartbeat_at:-missing} lease=${lease_at:-missing} stale=$lease_stale attempts=$attempts)"

            # Build an optimistic ownership predicate from the exact row
            # snapshot. If a heartbeat refreshed or a new claim took ownership
            # after SELECT, this UPDATE changes zero rows and no process is
            # signalled.
            safe_comment_id="$(printf '%s' "$comment_id" | sed "s/'/''/g")"
            if [ -n "$claim_token" ]; then
                safe_claim_token="$(printf '%s' "$claim_token" | sed "s/'/''/g")"
                claim_clause="AND claimToken='$safe_claim_token'"
            else
                claim_clause="AND claimToken IS NULL"
            fi
            if [ -n "$heartbeat_at" ]; then
                safe_heartbeat_at="$(printf '%s' "$heartbeat_at" | sed "s/'/''/g")"
                heartbeat_clause="AND heartbeatAt='$safe_heartbeat_at'"
            else
                heartbeat_clause="AND heartbeatAt IS NULL"
            fi
            if [ -n "$lease_at" ]; then
                safe_lease_at="$(printf '%s' "$lease_at" | sed "s/'/''/g")"
                lease_clause="AND leaseExpiresAt='$safe_lease_at'"
            else
                lease_clause="AND leaseExpiresAt IS NULL"
            fi
            if [[ "$worker_pid" =~ ^[1-9][0-9]*$ ]]; then
                worker_clause="AND workerPid=$worker_pid"
            else
                worker_clause="AND workerPid IS NULL"
            fi
            snapshot_clause="$claim_clause $heartbeat_clause $lease_clause $worker_clause"

            recovery_delay="$RETRY_DELAY_SECONDS"
            if ! [[ "$recovery_delay" =~ ^[0-9]+$ ]] || [ "$recovery_delay" -lt 5 ]; then
                recovery_delay=5
            fi

            if [ "${attempts:-0}" -ge "$MAX_ATTEMPTS" ]; then
                target_status="failed"
                transition_sql="
                    UPDATE processed_comments
                    SET status='failed', processedAt=datetime('now'),
                        heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL,
                        claimToken=NULL, agentStartedAt=NULL, nextAttemptAt=NULL
                    WHERE commentId='$safe_comment_id' AND status='running' $snapshot_clause;
                    SELECT changes();"
            else
                target_status="queued"
                transition_sql="
                    UPDATE processed_comments
                    SET status='queued', processedAt=NULL,
                        heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL,
                        claimToken=NULL, agentStartedAt=NULL,
                        nextAttemptAt=datetime('now', '+${recovery_delay} seconds')
                    WHERE commentId='$safe_comment_id' AND status='running' $snapshot_clause;
                    SELECT changes();"
            fi

            if transition_output="$(sqlite3 -bail "$DB" "PRAGMA busy_timeout=5000; $transition_sql" 2>>"$LOG")"; then
                changed="$(printf '%s\n' "$transition_output" | tail -n 1)"
            else
                changed="0"
                log "ERROR: stale recovery SQLite transition failed for $comment_id"
            fi

            if [ "$changed" != "1" ]; then
                log "RECOVERY_SKIPPED: claim changed while recovering $comment_id; executor was not signalled"
                continue
            fi

            # The DB transition wins first. For queued retries, nextAttemptAt
            # leaves a short safety window so a new worker cannot reuse the
            # task PID file before the old executor tree has been terminated.
            terminate_task_heartbeat_for_claim "$comment_id" "$worker_pid" || true
            terminate_task_executor "$comment_id"

            if [ "$target_status" = "failed" ]; then
                log "RECOVERY: marked $comment_id failed after $attempts/$MAX_ATTEMPTS attempts"
                post_terminal_failure_feedback "$comment_id" "$repo" "$issue_num" "Task exhausted $attempts/$MAX_ATTEMPTS attempts; stale heartbeat/lease recovery stopped the worker (heartbeat=${heartbeat_at:-missing}, lease=${lease_at:-missing})." || true
            else
                log "RECOVERY: requeued $comment_id after stale heartbeat/lease (attempts preserved=$attempts, retry delay=${recovery_delay}s)"
            fi
        done <<< "$STUCK_TASKS"
    fi
fi

log "watchdog completed — daemon $(cat "$PID_FILE" 2>/dev/null) alive"