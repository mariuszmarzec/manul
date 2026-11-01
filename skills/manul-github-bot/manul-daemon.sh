#!/usr/bin/env bash
set -uo pipefail  # 'u' causes errors on unbound variables, 'o pipefail' catches pipeline errors
# manul-daemon.sh — background poll loop for the manul GitHub bot.
#
# Usage:
#   manul-daemon.sh start      — start the poll loop (setsid, survives gateway restarts)
#   manul-daemon.sh stop       — stop it
#   manul-daemon.sh status     — is it running?
#   manul-daemon.sh run-once   — single poll + dispatch (for testing)
#
# Loop: every $MANUL_INTERVAL (default from config pollInterval, else 60s) run
# poll.sh; when it reports fire:true, claim one queued task atomically in SQLite,
# post an in-progress comment, invoke the implementation agent with a per-task
# prompt, validate the result via explicit markers, update SQLite, and post the
# final result comment.
# ERR trap: log any unhandled command failure with context
trap 'if [[ $BASH_COMMAND != "return "* ]] && [[ $BASH_COMMAND != *"|| true"* ]]; then echo "[$(date -Is)] FATAL_ERR line=$LINENO cmd=$BASH_COMMAND rc=$?" >> "${LIFECYCLE_LOG:-/dev/null}" 2>/dev/null; fi' ERR

# Ensure standard PATH is available when running via setsid/nohup.
# ~/.local/bin is required: the OpenClaw CLI is installed there and the daemon
# (often started by cron/watchdog) inherits a PATH that omits it, which made
# `command -v openclaw` fail and every agent invocation die instantly.
# The OpenClaw CLI itself is a wrapper that execs `npx`, so the nvm node bin
# must also be reachable or the agent dies with "npx: not found".
# NOTE: the nvm glob must be expanded BEFORE assignment (unquoted), otherwise
# the literal string "*.bin" ends up on PATH and `npx` is still not found.
#
# The OpenCode CLI is installed at $HOME/.opencode/bin by its installer, which
# only appends that directory to the interactive shell PATH (~/.zshrc). The
# daemon worker inherits a non-interactive PATH that omits it, so
# `command -v opencode` returned nothing and every opencode agent died with
# exit 127 before logging a single line. Add the OpenCode bin dir here so the
# OpenCode adapter (and any other tool installed there) is reachable.
_NVM_NODE_BIN="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | head -n1)"
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:${_NVM_NODE_BIN:-$HOME/.nvm/versions/node/current/bin}:/usr/local/bin:/usr/bin:/bin:$PATH"

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
# Absolute path to this script (the daemon is invoked via a symlink, so $0 may
# be relative). Workers are spawned with nohup/setsid and need a stable path.
DAEMON_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
while [ -L "$DAEMON_SCRIPT_PATH" ]; do
  DAEMON_SCRIPT_PARENT="$(cd -P "$(dirname "$DAEMON_SCRIPT_PATH")" && pwd)"
  DAEMON_SCRIPT_TARGET="$(readlink "$DAEMON_SCRIPT_PATH")"
  case "$DAEMON_SCRIPT_TARGET" in
    /*) DAEMON_SCRIPT_PATH="$DAEMON_SCRIPT_TARGET" ;;
    *)  DAEMON_SCRIPT_PATH="$DAEMON_SCRIPT_PARENT/$DAEMON_SCRIPT_TARGET" ;;
  esac
done
DAEMON_SCRIPT_DIR="$(cd -P "$(dirname "$DAEMON_SCRIPT_PATH")" && pwd)"
DAEMON_SCRIPT_ABS="$DAEMON_SCRIPT_DIR/$(basename "$DAEMON_SCRIPT_PATH")"

# On macOS load Homebrew Bash/coreutils/util-linux before executing any runtime
# code. Cron/watchdog launches do not inherit interactive shell PATH settings.
source "$DAEMON_SCRIPT_DIR/manul-platform.sh"
manul_platform_prepare || exit 1
manul_platform_reexec_if_needed "$DAEMON_SCRIPT_ABS" "$@"


# Load operator/provider overrides from the runtime-owned environment file.
# This is required for unattended cron/watchdog execution because ~/.zshrc is
# not loaded there.
source "$DAEMON_SCRIPT_DIR/manul-env.sh"
if ! manul_env_load "$MANUL_DIR"; then
  echo "ERROR: failed to load $MANUL_DIR/.env" >&2
  exit 1
fi

# --- Agent execution runtime abstraction ---
# Source the runtime-neutral execution path before consuming derived paths.
# The daemon never invokes adapter scripts directly; it goes through
# AgentExecutor / AgentExecutionController.
source "$DAEMON_SCRIPT_DIR/manul-paths.sh"
source "$DAEMON_SCRIPT_DIR/manul-failure-utils.sh"
source "$DAEMON_SCRIPT_DIR/process-runner.sh"
source "$DAEMON_SCRIPT_DIR/agent-executor.sh"
source "$DAEMON_SCRIPT_DIR/agent-execution-controller.sh"
source "$DAEMON_SCRIPT_DIR/agent-session-state.sh"
source "$DAEMON_SCRIPT_DIR/task-source.sh"

CONFIG="$MANUL_CONFIG"
POLL="$MANUL_DIR/poll.sh"
PROMPT_FILE="$MANUL_DIR/orchestrator.prompt.md"
PID_FILE="$MANUL_LOCKS_DIR/daemon.pid"
POLLER_PID_FILE="$MANUL_DIR/poller.pid"
LOG="$MANUL_LOG_DIR/daemon.log"
LIFECYCLE_LOG="$MANUL_LOG_DIR/lifecycle.log"
LAST_POLL_FILE="$MANUL_STATE_DIR/last-poll"
CURRENT_ACTIVITY_FILE="$MANUL_STATE_DIR/current_activity"
LOCK="$MANUL_LOCKS_DIR/daemon.lock"
FLOCK_FILE="$MANUL_LOCKS_DIR/daemon.flock"
# Held by the long-lived daemon supervisor, independently of the short startup lock.
DAEMON_OWNER_LOCK_FILE="$MANUL_LOCKS_DIR/daemon-owner.flock"
# OS-level lock for the singleton task dispatcher. Unlike the legacy .daemon-lock
# directory, flock is automatically released when the owning worker process dies.
TASK_LOCK_FILE="$MANUL_LOCKS_DIR/task-dispatch.flock"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="$MANUL_DB"
CFG_INTERVAL="$(jq -r '.pollInterval // empty' "$CONFIG" 2>/dev/null)"
# Human-mode result comment presentation is configurable but intentionally
# defaults to concise, teammate-like comments.
CFG_HUMAN_COMMENT_CONCISE="$(jq -r '.commentStyle.human.concise // true' "$CONFIG" 2>/dev/null || echo true)"
CFG_HUMAN_COMMENT_MAX_LINES="$(jq -r '.commentStyle.human.maxLines // 6' "$CONFIG" 2>/dev/null || echo 6)"
if [ "$CFG_HUMAN_COMMENT_CONCISE" != "true" ] && [ "$CFG_HUMAN_COMMENT_CONCISE" != "false" ]; then
  CFG_HUMAN_COMMENT_CONCISE=true
fi
if ! [[ "$CFG_HUMAN_COMMENT_MAX_LINES" =~ ^[0-9]+$ ]] || [ "$CFG_HUMAN_COMMENT_MAX_LINES" -lt 1 ] || [ "$CFG_HUMAN_COMMENT_MAX_LINES" -gt 20 ]; then
  CFG_HUMAN_COMMENT_MAX_LINES=6
fi
INTERVAL="${MANUL_INTERVAL:-${CFG_INTERVAL:-60}}"
# Consumers scan the durable SQLite queue independently of GitHub polling.
DISPATCH_INTERVAL="${MANUL_DISPATCH_INTERVAL:-1}"
CFG_AGENT_TIMEOUT="$(jq -r '.automation.agentTimeoutSeconds // 43500' "$CONFIG" 2>/dev/null)"
AGENT_TIMEOUT="${MANUL_AGENT_TIMEOUT:-${CFG_AGENT_TIMEOUT:-43500}}"   # full Manul agent turn; keep longer than OpenClaw's explicit inner timeout
POLL_TIMEOUT="${MANUL_POLL_TIMEOUT:-120}"      # seconds timeout for poll.sh
GH_API_TIMEOUT="${MANUL_GH_API_TIMEOUT:-30}"   # seconds timeout for gh api calls

# Read heartbeat configuration from config.json
CFG_HEARTBEAT_INTERVAL="$(jq -r '.automation.heartbeatInterval // 60' "$CONFIG" 2>/dev/null)"
HEARTBEAT_INTERVAL="${MANUL_HEARTBEAT_INTERVAL:-${CFG_HEARTBEAT_INTERVAL:-60}}"
CFG_HEARTBEAT_TIMEOUT="$(jq -r '.automation.heartbeatTimeout // 900' "$CONFIG" 2>/dev/null)"
HEARTBEAT_TIMEOUT="${MANUL_HEARTBEAT_TIMEOUT:-${CFG_HEARTBEAT_TIMEOUT:-900}}"
CFG_LEASE_TIMEOUT="$(jq -r '.automation.leaseTimeout // 900' "$CONFIG" 2>/dev/null)"
LEASE_TIMEOUT="${MANUL_LEASE_TIMEOUT:-${CFG_LEASE_TIMEOUT:-900}}"
# Read concurrency configuration from config.json
CFG_MAX_CONCURRENT="$(jq -r '.automation.maxConcurrentTasks // 1' "$CONFIG" 2>/dev/null || echo 1)"
MAX_CONCURRENT_TASKS="${MANUL_MAX_CONCURRENT_TASKS:-${CFG_MAX_CONCURRENT:-1}}"
# Validate maxConcurrentTasks is a positive integer
if ! [[ "$MAX_CONCURRENT_TASKS" =~ ^[0-9]+$ ]] || [ "$MAX_CONCURRENT_TASKS" -lt 1 ]; then
  log "WARN: invalid maxConcurrentTasks ($MAX_CONCURRENT_TASKS), defaulting to 1"
  MAX_CONCURRENT_TASKS=1
fi
CFG_LOCK_TTL="$(jq -r '.automation.lockTtl // empty' "$CONFIG" 2>/dev/null)"
LOCK_TTL="${MANUL_LOCK_TTL_SECONDS:-${CFG_LOCK_TTL:-1800}}"
REPO_LOCK_TTL="${MANUL_REPO_LOCK_TTL_SECONDS:-${LOCK_TTL:-1800}}"
CFG_RETRY_DELAY="$(jq -r '.retryConfig.delaySeconds // 60' "$CONFIG" 2>/dev/null || echo "60")"
RETRY_DELAY_SECONDS="${MANUL_RETRY_DELAY_SECONDS:-${CFG_RETRY_DELAY:-60}}"

TASK_RETENTION_DEFAULT_LIST_DAYS=7
TASK_RETENTION_DEFAULT_HISTORY_DAYS=14
TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"

  # Per-repo timeout, mirrored from poll.sh's default so the daemon's
  # scaled global poll timeout matches what poll.sh actually enforces.
  REPO_POLL_TIMEOUT="${MANUL_REPO_POLL_TIMEOUT:-60}"
  # Repository list, mirrored from poll.sh so run_once can size the global
  # poll timeout dynamically instead of assuming a fixed 120s.
  mapfile -t REPOS < <(jq -r '.repositories[]?' "$CONFIG" 2>/dev/null)

log() { echo "[$(date -Is)] $*" >>"$LOG"; }
validate_dispatch_interval() {
  if ! [[ "$DISPATCH_INTERVAL" =~ ^[0-9]+$ ]] || [ "$DISPATCH_INTERVAL" -lt 1 ]; then
    log "WARN: invalid MANUL_DISPATCH_INTERVAL ($DISPATCH_INTERVAL); defaulting to 1s"
    DISPATCH_INTERVAL=1
  fi
}
  configure_task_retention() {
    local list_days history_days
    list_days="$(jq -r '.retention.listDays // empty' "$CONFIG" 2>/dev/null || true)"
    history_days="$(jq -r '.retention.historyDays // empty' "$CONFIG" 2>/dev/null || true)"

    if ! [[ "$list_days" =~ ^[0-9]+$ ]] || [ "$list_days" -lt 1 ] || \
       ! [[ "$history_days" =~ ^[0-9]+$ ]] || [ "$history_days" -lt 1 ] || \
       [ "$history_days" -lt $((list_days * 2)) ]; then
      TASK_LIST_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_LIST_DAYS"
      TASK_HISTORY_RETENTION_DAYS="$TASK_RETENTION_DEFAULT_HISTORY_DAYS"
      TASK_RETENTION_CONFIG_MESSAGE="WARN: invalid retention config (listDays=${list_days:-missing}, historyDays=${history_days:-missing}); using defaults listDays=$TASK_RETENTION_DEFAULT_LIST_DAYS, historyDays=$TASK_RETENTION_DEFAULT_HISTORY_DAYS"
    else
      TASK_LIST_RETENTION_DAYS="$list_days"
      TASK_HISTORY_RETENTION_DAYS="$history_days"
      TASK_RETENTION_CONFIG_MESSAGE="INFO: task retention configured (listDays=$TASK_LIST_RETENTION_DAYS, historyDays=$TASK_HISTORY_RETENTION_DAYS)"
    fi
  }


# Lifecycle event logger — structured, machine-parsable, human-readable
lc_log() {
  local event="$1"
  shift
  echo "[$(date -Is)] $event ${*:-}" >>"$LIFECYCLE_LOG"
}

# Update current activity state file
set_activity() {
  local task_id="${1:-none}"
  local activity="${2:-idle}"
  echo "${task_id}|${activity}|$(date -Is)" >"$CURRENT_ACTIVITY_FILE" 2>/dev/null || true
}

# Record last poll timestamp and result
record_poll() {
  local fire="${1:-false}"
  local new="${2:-0}"
  local pending="${3:-0}"
  printf '{"fire":%s,"new":%s,"pending":%s,"timestamp":"%s"}\n' \
    "$fire" "$new" "$pending" "$(date -Is)" >"$LAST_POLL_FILE" 2>/dev/null || true
  echo "${fire}|${new}|${pending}|$(date -Is)" >>"$LIFECYCLE_LOG"
}


# Parse poll.sh output into exactly one normalized result.
# Never let malformed/multi-value jq output reach the dispatch gate.
parse_poll_result() {
  local out="${1:-}"
  local result_line json_out validated_json
  result_line="$(printf '%s\n' "$out" | grep '^MANUL_RESULT ' | tail -n 1 || true)"
  if [ -z "$result_line" ]; then
    printf 'false|0|0\n'
    return 0
  fi

  json_out="${result_line#MANUL_RESULT }"
  validated_json="$(printf '%s' "$json_out" | jq -e -c -s 'if length == 1 then .[0] | select(type == "object") else empty end' 2>/dev/null || true)"
  if [ -z "$validated_json" ]; then
    log "WARN: invalid MANUL_RESULT ignored"
    printf 'false|0|0\n'
    return 0
  fi

  local fire new pending
  fire="$(printf '%s' "$validated_json" | jq -r 'if .fire == true then "true" else "false" end')"
  new="$(printf '%s' "$validated_json" | jq -r 'if (.new|type) == "number" then .new else 0 end')"
  pending="$(printf '%s' "$validated_json" | jq -r 'if (.pending|type) == "number" then .pending else 0 end')"
  printf '%s|%s|%s\n' "$fire" "$new" "$pending"
}

# Get daemon PID as a function (handles empty file safely)
get_daemon_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "$pid"
  else
    echo "0"
  fi
}

# Repository management functions for manul-daemon.sh

# Ensure target repository exists in Manul workspace. The shared repo cache is
# protected for the whole task: the lock is acquired before any fetch/reset
# and is released by the task finalization/error paths.
ensure_repo() {
  local repo="$1"
  local repo_slug
  repo_slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  local repo_dir="$MANUL_WORKSPACE/$repo_slug"

  # Acquire before touching the shared checkout. This closes the race where
  # two workers fetched/reset the same repo cache concurrently.
  if ! acquire_repo_lock "$repo"; then
    log "repo $repo is locked or stale, retrying later"
    return 2
  fi

  # Check if repo already exists and is up-to-date
  if [ -d "$repo_dir" ] && [ -d "$repo_dir/.git" ]; then
    # Verify this is the correct repository
    local actual_repo
    actual_repo="$(cd "$repo_dir" && git remote get-url origin 2>/dev/null || true)"
    if [[ "$actual_repo" == "https://github.com/${repo}" ]]; then
      # Synchronize with remote while holding the repo lock.
      if ! (cd "$repo_dir" && git fetch origin --quiet); then
        log "FAILED to fetch repo $repo"
        release_repo_lock "$repo"
        return 1
      fi

      local head
      local remote_head
      head="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
      remote_head="$(git -C "$repo_dir" rev-parse "origin/$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$repo_dir" branch --show-current)" 2>/dev/null || git -C "$repo_dir" rev-parse "origin/master" 2>/dev/null || true)"

      if [ -n "$remote_head" ] && [ "$head" != "$remote_head" ]; then
        log "repo $repo needs update, pulling"
        if ! (cd "$repo_dir" && { git reset --hard "origin/$(git symbolic-ref --short HEAD 2>/dev/null || git branch --show-current)" --quiet 2>/dev/null || git reset --hard origin/master --quiet 2>/dev/null; }); then
          log "FAILED to update repo $repo"
          release_repo_lock "$repo"
          return 1
        fi
      fi

      log "repo $repo is ready at $repo_dir"
      echo "$repo_dir"
      return 0
    else
      log "repo $repo origin mismatch, expected https://github.com/${repo}, got $actual_repo"
      rm -rf "$repo_dir"
    fi
  fi

  # Lock is already held from the start of ensure_repo().
  log "cloning repo $repo to $repo_dir"
  rm -rf "$repo_dir"
  mkdir -p "$repo_dir"
  cd "$repo_dir"

  # Clone with minimal fetch
  if ! git clone --depth 1 "https://github.com/${repo}" . 2>/dev/null; then
    log "FAILED to clone repo $repo"
    rm -rf "$repo_dir"
    release_repo_lock "$repo"
    return 1
  fi

  log "repo $repo cloned successfully to $repo_dir"
  echo "$repo_dir"
  return 0
}

# Verify repository ownership and integrity
verify_repo() {
  local repo="$1"
  local repo_dir="$2"

  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir" ] || [ ! -d "$repo_dir/.git" ]; then
    log "ERROR: repo_dir $repo_dir is not a valid git repository"
    return 1
  fi

  # Verify this is the correct repository
  local actual_repo
  actual_repo="$(cd "$repo_dir" && git remote get-url origin 2>/dev/null)"
  local expected_repo="https://github.com/${repo}"

  if [ "$actual_repo" != "$expected_repo" ]; then
    log "ERROR: repo_dir $repo_dir has wrong origin: $actual_repo, expected $expected_repo"
    return 1
  fi


  log "repo $repo verified at $repo_dir"
  return 0
}

# Acquire repository lock (same atomic implementation as in poll.sh)
acquire_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  local lockfile="${REPO_LOCK_DIR:-$MANUL_LOCKS_DIR/repo}/${slug}.lock"
  local reclaim_lock="${lockfile}.reclaim"
  local lock_dir="${REPO_LOCK_DIR:-$MANUL_LOCKS_DIR/repo}"

  mkdir -p "$lock_dir"

  if mkdir "$lockfile" 2>/dev/null; then
    date +%s >"$lockfile/acquiredAt"
    printf '%s\n' "$$" >"$lockfile/pid"
    return 0
  fi

  local age
  age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$REPO_LOCK_TTL" ]; then
    log "repo $repo is locked by another task (age=${age}s, ttl=${REPO_LOCK_TTL}s); skipping"
    return 1
  fi

  if [ -d "$reclaim_lock" ]; then
    local reclaim_age
    reclaim_age=$(( $(date +%s) - $(stat -c %Y "$reclaim_lock" 2>/dev/null || echo 0) ))
    if [ "$reclaim_age" -ge "$REPO_LOCK_TTL" ]; then
      rm -rf "$reclaim_lock"
    fi
  fi
  if ! mkdir "$reclaim_lock" 2>/dev/null; then
    log "repo $repo stale-lock recovery is already in progress; skipping"
    return 1
  fi

  local safe_repo
  safe_repo="$(sql_escape "$repo")"
  local running_count
  running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$safe_repo' AND status='running';" 2>/dev/null || echo 0)"

  age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
  if [ -e "$lockfile" ] && [ "$age" -ge "$REPO_LOCK_TTL" ] && [ "${running_count:-0}" -eq 0 ]; then
    log "stale repo lock for $repo removed (age=${age}s, no running tasks)"
    rm -rf "$lockfile"
  elif [ "${running_count:-0}" -gt 0 ]; then
    log "stale repo lock for $repo ignored because task is still running in DB (running=$running_count); skipping"
  fi

  rmdir "$reclaim_lock" 2>/dev/null || true

  if [ ! -e "$lockfile" ] && mkdir "$lockfile" 2>/dev/null; then
    date +%s >"$lockfile/acquiredAt"
    printf '%s\n' "$$" >"$lockfile/pid"
    return 0
  fi

  return 1
}

release_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  rm -rf "${REPO_LOCK_DIR:-$MANUL_LOCKS_DIR/repo}/${slug}.lock"
}

# Release the repository lock only when this task successfully acquired it.
# Bash function scope is dynamic, so REPO_LOCK_HELD is the task-local owner
# flag visible here.
release_task_repo_lock() {
  local repo="$1"
  if [ "${REPO_LOCK_HELD:-false}" = "true" ]; then
    release_repo_lock "$repo"
    REPO_LOCK_HELD=false
  fi
}

archive_task_artifacts() {
  local comment_id="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  local prompt_file="$4"

  local attempt
  attempt="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null || echo "1")"
  attempt="${attempt:-1}"

  local safe_id
  safe_id="$(printf '%s' "$comment_id" | sed 's/[^A-Za-z0-9._-]/_/g')"
  local archive_dir="$MANUL_TASK_LOG_DIR/$safe_id"
  mkdir -p "$archive_dir" 2>/dev/null || {
    log "WARN: failed to create task log archive directory: $archive_dir"
    return 1
  }

  if [ -f "$stdout_file" ]; then
    cp -f "$stdout_file" "$archive_dir/attempt-${attempt}.stdout" 2>/dev/null || \
      log "WARN: failed to archive stdout for task $comment_id attempt $attempt"
  fi
  if [ -f "$stderr_file" ]; then
    cp -f "$stderr_file" "$archive_dir/attempt-${attempt}.stderr" 2>/dev/null || \
      log "WARN: failed to archive stderr for task $comment_id attempt $attempt"
  fi
  if [ -f "$prompt_file" ]; then
    cp -f "$prompt_file" "$archive_dir/attempt-${attempt}.prompt" 2>/dev/null || \
      log "WARN: failed to archive prompt for task $comment_id attempt $attempt"
  fi

  log "dispatch: archived diagnostics for task $comment_id attempt $attempt in $archive_dir"
  lc_log "DIAGNOSTICS_ARCHIVED" "task=$comment_id attempt=$attempt dir=$archive_dir"
  return 0
}

# Enhanced SQLite UPDATE with verification and error handling
update_task_completion() {
  ensure_claim_token_column || return 1
  ensure_recovery_tracking_columns || return 1
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"
  local status="$2"
  local error_message="${3:-}"
  local claim_token="${4:-}"

  local task_exists
  task_exists="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
  if [ -z "$task_exists" ]; then
    log "ERROR: Task $comment_id does not exist in database"
    return 1
  fi

  local current_status
  current_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  case "$status" in
    completed|failed)
      if [ "$current_status" = "$status" ]; then
        log "SUCCESS: Task $comment_id already $status (idempotent)"
        return 0
      fi
      if [ "$current_status" != "running" ]; then
        log "ERROR: Cannot $status task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
    queued)
      if [ "$current_status" != "running" ]; then
        log "ERROR: Cannot requeue task $comment_id from current status: $current_status"
        return 1
      fi
      ;;
    *)
      log "ERROR: Unsupported task completion status: $status"
      return 1
      ;;
  esac

  local where_clause="WHERE commentId='$safe_comment_id' AND status='running'"
  if [ -n "$claim_token" ]; then
    local safe_claim_token
    safe_claim_token="$(sql_escape "$claim_token")"
    where_clause+=" AND claimToken='$safe_claim_token'"
  else
    # Backward compatibility for rows created before claimToken existed.
    # Once a new claim has a token, an old execution without one cannot finalize it.
    local legacy_worker_pid="${BASHPID}"
    local db_claim_token
    db_claim_token="$(sqlite3 "$DB" "SELECT claimToken FROM processed_comments WHERE commentId='$safe_comment_id' AND status='running' LIMIT 1;" 2>/dev/null)"
    if [ -n "$db_claim_token" ]; then
      log "ERROR: Refusing legacy finalization for $comment_id because current claim has a token"
      return 1
    fi
    where_clause+=" AND workerPid=$legacy_worker_pid AND claimToken IS NULL"
  fi

  local update_sql="UPDATE processed_comments SET status='$status'"
  case "$status" in
    completed|failed)
      update_sql+=" , processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, agentStartedAt=NULL"
      ;;
    queued)
      # A retry must become schedulable again. Without nextAttemptAt, the
      # scheduler's "attempts > 0 AND nextAttemptAt <= now" predicate ignores
      # NULL forever, silently stranding early-failure retries.
      update_sql+=" , processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, agentStartedAt=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds')"
      ;;
  esac

  local update_result
  update_result="$(sqlite3 "$DB" "$update_sql $where_clause; SELECT changes();" 2>/dev/null)"
  local changes
  changes="$(echo "$update_result" | tail -n 1)"

  if [ "${changes:-0}" -eq 1 ]; then
    log "SUCCESS: Task $comment_id transitioned to $status (previous: $current_status)"
    return 0
  fi
  log "ERROR: Task $comment_id update failed (changes=$changes, previous=$current_status)"
  return 1
}
# Finalization verification: ensure heartbeat and locks don't revert completion
# FIX: Stop any lingering heartbeat BEFORE verifying finalization.
# The old code compared heartbeat PID vs daemon PID and could fail when
# daemon.pid was missing (daemon started directly) or when the daemon's
# own heartbeat was still recorded.  Here we explicitly reap the heartbeat
# so finalization is never blocked by a still-running timer process.
verify_finalization() {
  local comment_id="$1"
  local safe_comment_id="$(sql_escape "$comment_id")"

  # ── Step 0: synchronously stop any heartbeat for this task ─────────────────
  # This must happen BEFORE we touch finalization state; the task must not
  # reach terminal status while its heartbeat is still alive.
  local heartbeat_pid
  heartbeat_pid="$(cat "$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")" 2>/dev/null)"

  if [ -n "$heartbeat_pid" ]; then
    if kill -0 "$heartbeat_pid" 2>/dev/null; then
      # Heartbeat is still running — terminate it and reap the exit status.
      # kill is idempotent for already-dead processes; kill -0 above confirmed liveness.
      kill "$heartbeat_pid" 2>/dev/null || true
      wait "$heartbeat_pid" 2>/dev/null || true
    fi
    # Remove the PID file unconditionally (idempotent; no-op if already gone).
    rm -f "$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")" 2>/dev/null || true
  fi

  # ── Step 1: verify task is completed in SQLite ─────────────────────────────
  local task_status
  task_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ "$task_status" != "completed" ]; then
    log "ERROR: Task $comment_id is not completed in SQLite (status: $task_status)"
    return 1
  fi

  # ── Step 2: verify processedAt is set ──────────────────────────────────────
  local processed_at
  processed_at="$(sqlite3 "$DB" "SELECT processedAt FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -z "$processed_at" ] || [ "$processed_at" = "null" ]; then
    log "ERROR: Task $comment_id has no processedAt timestamp"
    return 1
  fi

  # ── Step 3: verify heartbeat PID file is gone (confirm we reaped it) ────────
  if [ -f "$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")" ]; then
    log "ERROR: Task $comment_id heartbeat PID file still present after shutdown"
    return 1
  fi

  # ── Step 4: verify workerPid is cleared ────────────────────────────────────
  local worker_pid
  worker_pid="$(sqlite3 "$DB" "SELECT workerPid FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -n "$worker_pid" ] && [ "$worker_pid" != "0" ]; then
    log "ERROR: Task $comment_id still has workerPid: $worker_pid"
    return 1
  fi

  log "SUCCESS: Task $comment_id finalization verified"
  return 0
}

# Enhanced task completion with verification
complete_task_with_verification() {
  local comment_id="$1"
  local claim_token="${2:-}"

  # Mark task as completed with verification
  if ! update_task_completion "$comment_id" "completed" "" "$claim_token"; then
    log "ERROR: Failed to complete task $comment_id"
    return 1
  fi

  # Verify finalization
  if ! verify_finalization "$comment_id"; then
    # Path C: DB is already updated to 'completed' (the correct terminal state).
    # Verification failure is non-fatal — the task is done, we just couldn't
    # confirm all post-conditions. Report success so the daemon doesn't get
    # stuck retrying an already-completed task.
    log "WARNING: Finalization verification failed for task $comment_id but status is completed"
    return 0
  fi

  log "SUCCESS: Task $comment_id fully completed and verified"
  return 0
}

# Acquire singleton lock BEFORE claiming a task to prevent concurrent daemon races.
#
# The task dispatcher used to coordinate ownership through $MANUL_DIR/.daemon-lock
# plus daemon.pid. That protocol is unsafe after a restart: the old directory can
# survive while daemon.pid is overwritten by the new daemon, making the new daemon
# mistake itself for the old lock owner forever.
#
# Use an OS-level flock instead. Kernel lock ownership follows the open file
# description/process lifetime, so a killed/crashed worker releases the lock
# automatically and PID reuse cannot create a false owner.
acquire_task_lock() {
  local max_wait=${MANUL_TASK_LOCK_TIMEOUT_SECONDS:-30}
  if ! [[ "$max_wait" =~ ^[0-9]+$ ]] || [ "$max_wait" -lt 1 ]; then
    log "WARN: invalid task lock timeout ($max_wait), defaulting to 30s"
    max_wait=30
  fi

  local sleep_interval=0.1
  local attempts=0
  local max_attempts=$((max_wait * 10))

  # Open the shared lock file in this process. The kernel owns the flock,
  # so process death releases it automatically.
  exec 210>"$TASK_LOCK_FILE"
  while ! flock -n 210; do
    sleep "$sleep_interval"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      log "WARN: could not acquire task lock after ${max_wait}s"
      exec 210>&-
      return 1
    fi
  done
  return 0
}

release_task_lock() {
  flock -u 210 2>/dev/null || true
  exec 210>&- 2>/dev/null || true
  # Remove the legacy directory if a previous Manul revision left it behind.
  # It is no longer authoritative for task-lock ownership.
  rmdir "$MANUL_DIR/.daemon-lock" 2>/dev/null || true
}

# Recover tasks stuck in 'running' state due to daemon crash, deadlock, or process death.
# This handles cases where:
# 1. Worker process died but task still marked 'running'
# 2. Lease expired but task not finalized
# 3. Deadlocked pipe in verify_result_comment or similar
recover_stale_tasks() {
  ensure_claim_token_column || return 1
  ensure_recovery_tracking_columns || return 1
  log "recover_stale_tasks: checking for stuck tasks"
  lc_log "RECOVERY_START" ""

  local stale_tasks
  stale_tasks="$(sqlite3 "$DB" "
    SELECT commentId, repository, issueNumber, workerPid, leaseExpiresAt, attempts, claimToken,
           COALESCE(agentStartedAt,''), COALESCE(preExecutionFailures,0),
           CASE
             WHEN heartbeatAt IS NULL
               OR datetime(heartbeatAt) < datetime('now', '-${HEARTBEAT_TIMEOUT} seconds')
               OR leaseExpiresAt IS NULL
               OR datetime(leaseExpiresAt) < datetime('now')
             THEN 1 ELSE 0
           END AS lease_stale
    FROM processed_comments
    WHERE status='running'
    LIMIT 100;" 2>/dev/null)"
  if [ -z "$stale_tasks" ]; then
    log "recover_stale_tasks: no stale tasks found"
    return 0
  fi

  local recovered=0
  while IFS='|' read -r comment_id repo issue_num worker_pid lease_expires attempts claim_token agent_started_at pre_execution_failures lease_stale; do
    [ -n "$comment_id" ] || continue

    local worker_alive=0
    if [ -n "$worker_pid" ] && [ "$worker_pid" -gt 0 ] 2>/dev/null && kill -0 "$worker_pid" 2>/dev/null; then
      worker_alive=1
    fi

    # A dead worker is sufficient proof that the running claim cannot progress,
    # even when the last heartbeat/lease update was recent.
    if [ "$lease_stale" = "0" ] && [ "$worker_alive" -eq 1 ]; then
      continue
    fi

    log "recover_stale_tasks: recovering task $comment_id (worker=$worker_pid alive=$worker_alive lease=$lease_expires stale=$lease_stale agent_started=${agent_started_at:-no} attempts=$attempts pre_execution_failures=$pre_execution_failures)"
    terminate_task_executor "$comment_id"

    local safe_comment_id safe_claim_token ownership_clause changed
    safe_comment_id="$(sql_escape "$comment_id")"
    if [ -n "$claim_token" ]; then
      safe_claim_token="$(sql_escape "$claim_token")"
      ownership_clause="AND claimToken='$safe_claim_token'"
    else
      ownership_clause="AND claimToken IS NULL"
    fi

    # The claim attempt is incremented before workspace preparation. If the
    # runtime was never started, classify this as infrastructure failure, roll
    # back that attempt bump, and use a separate finite budget.
    if [ -z "$agent_started_at" ]; then
      local max_pre_execution_failures next_pre_execution_failures target_status
      max_pre_execution_failures="$(jq -r '.automation.maxPreExecutionFailures // 8' "$CONFIG" 2>/dev/null || echo 8)"
      if ! [[ "$max_pre_execution_failures" =~ ^[0-9]+$ ]] || [ "$max_pre_execution_failures" -lt 1 ]; then max_pre_execution_failures=8; fi
      [[ "${pre_execution_failures:-0}" =~ ^[0-9]+$ ]] || pre_execution_failures=0
      next_pre_execution_failures=$((pre_execution_failures + 1))
      if [ "$next_pre_execution_failures" -ge "$max_pre_execution_failures" ]; then target_status="failed"; else target_status="queued"; fi

      changed="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000;
        UPDATE processed_comments
        SET status='$target_status',
            attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,
            preExecutionFailures=$next_pre_execution_failures,
            agentStartedAt=NULL,
            processedAt=CASE WHEN '$target_status'='failed' THEN datetime('now') ELSE NULL END,
            heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL,
            nextAttemptAt=CASE WHEN '$target_status'='queued' THEN datetime('now','+${RETRY_DELAY_SECONDS} seconds') ELSE NULL END
        WHERE commentId='$safe_comment_id' AND status='running' $ownership_clause;
        SELECT changes();" 2>>"$LOG" | tail -n 1)" || changed="0"

      if [ "$changed" = "1" ]; then
        recovered=$((recovered + 1))
        if [ "$target_status" = "failed" ]; then
          log "recover_stale_tasks: task $comment_id exhausted pre-execution failures $next_pre_execution_failures/$max_pre_execution_failures; no agent attempt was started"
          lc_log "TASK_FAILED" "task=$comment_id repo=$repo issue=$issue_num reason=stale_pre_execution_max_failures infra_failures=$next_pre_execution_failures max_infra_failures=$max_pre_execution_failures"
          post_task_failure_feedback "$repo" "$issue_num" "$comment_id" "Task exhausted $next_pre_execution_failures/$max_pre_execution_failures pre-execution infrastructure failures before the agent started. Agent execution attempts are tracked separately." "" "stale_task_recovery_pre_execution" || true
        else
          log "recover_stale_tasks: requeued task $comment_id after pre-execution worker loss (infra_failures=$next_pre_execution_failures/$max_pre_execution_failures; agent attempts preserved)"
          lc_log "TASK_REQUEUED" "task=$comment_id repo=$repo issue=$issue_num reason=stale_pre_execution infra_failures=$next_pre_execution_failures max_infra_failures=$max_pre_execution_failures"
          post_lifecycle_comment "$repo" "$issue_num" "⚠️ Manul recovered a worker lost before agent startup (infrastructure failure $next_pre_execution_failures/$max_pre_execution_failures). The agent execution attempt budget was not consumed." || log "WARN: failed to post pre-execution recovery comment for $comment_id"
        fi
      else
        log "WARN: recover_stale_tasks: pre-execution task $comment_id was not transitioned (changes=${changed:-unknown}); claim ownership may have changed"
        lc_log "RECOVERY_SKIPPED" "task=$comment_id reason=stale_pre_execution_transition_not_applied"
      fi
      continue
    fi

    # Once agentStartedAt is recorded, the retry budget represents a real
    # runtime execution. Keep the existing bounded agent-attempt recovery path.
    local max_attempts
    max_attempts="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"
    if [ "${attempts:-0}" -ge "$max_attempts" ]; then
      log "recover_stale_tasks: marking stale agent execution as failed: $comment_id"
      changed="$(sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, agentStartedAt=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' $ownership_clause; SELECT changes();" 2>>"$LOG" | tail -n 1)" || changed="0"
      if [ "${changed:-0}" -eq 1 ]; then
        recovered=$((recovered + 1))
        lc_log "TASK_FAILED" "task=$comment_id repo=$repo issue=$issue_num reason=stale_lease_max_attempts"
        post_task_failure_feedback "$repo" "$issue_num" "$comment_id" "Task exhausted $attempts/$max_attempts agent execution attempts; stale heartbeat/lease recovery stopped the worker (lease=${lease_expires:-missing})." "" "stale_task_recovery" || true
      else
        log "WARN: stale task $comment_id was not marked failed (changes=${changed:-unknown}); task state or claim ownership changed"
        lc_log "RECOVERY_SKIPPED" "task=$comment_id reason=failed_transition_not_applied"
      fi
    else
      changed="$(sqlite3 "$DB" "
        UPDATE processed_comments
        SET status='queued', processedAt=NULL, heartbeatAt=NULL, workerPid=NULL,
            leaseExpiresAt=NULL, claimToken=NULL, agentStartedAt=NULL,
            nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds')
        WHERE commentId='$safe_comment_id' AND status='running' $ownership_clause;
        SELECT changes();
      " 2>>"$LOG" | tail -n 1)" || changed="0"
      if [ "${changed:-0}" -eq 1 ]; then
        log "recover_stale_tasks: requeued task $comment_id after lost agent execution (agent attempts preserved=$attempts)"
        lc_log "TASK_REQUEUED" "task=$comment_id repo=$repo issue=$issue_num attempts=$attempts reason=stale_lease"
        recovered=$((recovered + 1))
      else
        log "WARN: recover_stale_tasks: agent task $comment_id was not requeued (changes=${changed:-unknown}); task state or claim ownership changed"
        lc_log "RECOVERY_SKIPPED" "task=$comment_id reason=requeue_transition_not_applied"
      fi
    fi
  done <<<"$stale_tasks"

  log "recover_stale_tasks: recovered $recovered stale task(s)"
  lc_log "RECOVERY_COMPLETE" "recovered=$recovered"
  return 0
}
# Per-task heartbeat child processes, keyed by comment/task id.
declare -A HEARTBEAT_PIDS

# Determine the base branch that a standalone task should start from.
# This mirrors feature-branching-strategy's preferred order for the initial
# workspace: develop -> master -> repository default branch. The agent may
# later choose a different, explicitly required base branch before branching.
determine_task_base_branch() {
  local workdir="$1"
  local default_branch="$2"
  if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/develop"; then echo "develop"; return 0; fi
  if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/master"; then echo "master"; return 0; fi
  if [ -n "$default_branch" ]; then echo "$default_branch"; return 0; fi
  default_branch="$(git -C "$workdir" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' || true)"
  [ -n "$default_branch" ] && { echo "$default_branch"; return 0; }
  echo "master"
}

repository_changed_since() {
  local workdir="$1" initial_head="$2"
  [ -n "$initial_head" ] || return 1
  local current_head
  current_head="$(git -C "$workdir" rev-parse HEAD 2>/dev/null || echo "")"
  [ -n "$current_head" ] && [ "$current_head" != "$initial_head" ] && return 0
  ! git -C "$workdir" diff --quiet 2>/dev/null && return 0
  ! git -C "$workdir" diff --cached --quiet 2>/dev/null && return 0
  local untracked
  untracked="$(git -C "$workdir" ls-files --others --exclude-standard 2>/dev/null || true)"
  [ -n "$untracked" ] && return 0
  return 1
}

infer_task_base_branch() {
  local workdir="$1" branch="$2" fallback="$3"
  local message created_from

  # Git's branch reflog usually records "branch: Created from HEAD", which
  # does not preserve the actual source branch. Prefer explicit reset/create
  # entries when available, then inspect the HEAD reflog for the checkout
  # transition that created/entered this branch.
  while IFS= read -r message; do
    case "$message" in
      "branch: Created from "*) created_from="${message#branch: Created from }" ;;
      "branch: Reset to "*) created_from="${message#branch: Reset to }" ;;
      *) continue ;;
    esac
    case "$created_from" in
      HEAD|""|refs/remotes/origin/HEAD|refs/heads/"$branch"|"${branch}") continue ;;
    esac
    created_from="${created_from#refs/remotes/origin/}"
    created_from="${created_from#origin/}"
    created_from="${created_from#refs/heads/}"
    if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/$created_from" || git -C "$workdir" show-ref --verify --quiet "refs/heads/$created_from"; then
      echo "$created_from"
      return 0
    fi
  done < <(git -C "$workdir" reflog show --format="%gs" "$branch" 2>/dev/null || true)

  while IFS= read -r message; do
    case "$message" in
      "checkout: moving from "*)
        created_from="${message#checkout: moving from }"
        case "$created_from" in
          *" to $branch") created_from="${created_from% to $branch}" ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    case "$created_from" in
      HEAD|""|refs/remotes/origin/HEAD|refs/heads/"$branch"|"${branch}") continue ;;
    esac
    created_from="${created_from#refs/remotes/origin/}"
    created_from="${created_from#origin/}"
    created_from="${created_from#refs/heads/}"
    if git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/$created_from" || git -C "$workdir" show-ref --verify --quiet "refs/heads/$created_from"; then
      echo "$created_from"
      return 0
    fi
  done < <(git -C "$workdir" reflog show --format="%gs" HEAD 2>/dev/null || true)

  echo "$fallback"
}

start_heartbeat() {
  ensure_claim_token_column || return 1
  local comment_id="$1"
  local worker_pid="${2:-$BASHPID}"
  local claim_token="${3:-}"
  local pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")"

  local ownership_sql
  if [ -n "$claim_token" ]; then
    local safe_claim_token
    safe_claim_token="$(sql_escape "$claim_token")"
    ownership_sql="AND claimToken='$safe_claim_token'"
  else
    # Legacy rows created before claimToken used workerPid only.
    ownership_sql="AND claimToken IS NULL"
  fi
  (
    while true; do
      # Heartbeat belongs to this worker process and this exact claim.
      if ! kill -0 "$worker_pid" 2>/dev/null; then
        exit 0
      fi
      local changed
      changed="$(sqlite3 "$DB" "UPDATE processed_comments SET heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds') WHERE commentId='$(sql_escape "$comment_id")' AND status='running' AND workerPid=$worker_pid $ownership_sql; SELECT changes();" 2>/dev/null | tail -n 1)"
      if [ "${changed:-0}" -ne 1 ]; then
        # A transient SQLite lock/error must not permanently kill the heartbeat.
        # Exit only when ownership was actually lost or the task became terminal.
        local db_state
        db_state="$(sqlite3 -cmd '.timeout 5000' "$DB" "SELECT status || '|' || COALESCE(workerPid,0) || '|' || COALESCE(claimToken,'') FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null || true)"
        if [ -n "$db_state" ] && [ "$db_state" != "running|${worker_pid}|${claim_token}" ]; then
          exit 0
        fi
        sleep "$HEARTBEAT_INTERVAL"
        continue
      fi
      sleep "$HEARTBEAT_INTERVAL"
    done
  # The dispatcher owns FD 210 until dispatch() finishes. This helper
  # may outlive the worker during shutdown/recovery, so never inherit the lock.
  ) 210>&- &
  local heartbeat_pid=$!
  echo "$heartbeat_pid" > "$pid_file" 2>/dev/null || true
  HEARTBEAT_PIDS["$comment_id"]=$heartbeat_pid
  log "started heartbeat for task $comment_id (pid $heartbeat_pid)"
  lc_log "HEARTBEAT_START" "task=$comment_id pid=$heartbeat_pid interval=${HEARTBEAT_INTERVAL}s claim=${claim_token}"
}
task_process_is_running() {
  local pid="$1"
  local process_state
  process_state="$(ps -o stat= -p "$pid" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [ -n "$process_state" ] && [[ "$process_state" != Z* ]]
}

# Print every live descendant of a PID from one process-table snapshot. This
# includes tools such as GNU timeout that put their own children into a
# different process group, which a group-only signal cannot terminate.
task_descendant_pids() {
  local root_pid="$1"
  ps -axo pid=,ppid= | awk -v root="$root_pid" '
    {
      pids[NR] = $1
      parents[$1] = $2
      total = NR
    }
    END {
      descendants[root] = 1
      do {
        changed = 0
        for (i = 1; i <= total; i++) {
          pid = pids[i]
          if (pid != root && descendants[parents[pid]] && !descendants[pid]) {
            descendants[pid] = 1
            changed = 1
          }
        }
      } while (changed)
      for (i = 1; i <= total; i++) {
        if (pids[i] != root && descendants[pids[i]]) print pids[i]
      }
    }'
}

# Find a task runner by its explicit context/PID-file arguments when a prior
# stop removed the PID marker before the isolated process had actually exited.
find_task_executor_pid() {
  local comment_id="$1"
  local expected_context="$(manul_task_file_path "$MANUL_STATE_DIR/tasks" "$comment_id" "ctx.json")"
  local expected_pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "executor.pid")"
  local pid cmdline

  while read -r pid cmdline; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$cmdline" == *agent-task-runner.sh*"$expected_context"*"$expected_pid_file"* ]] || continue
    printf '%s\n' "$pid"
    return 0
  done < <(ps -ww -axo pid=,command= 2>/dev/null)
  return 1
}

terminate_task_executor() {
  local comment_id="$1"
  local pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "executor.pid")"
  local executor_pid="" executor_args="" executor_pgid=""
  local descendants=() process_pid wait_attempt alive forced=0

  if [ -f "$pid_file" ]; then
    executor_pid="$(cat "$pid_file" 2>/dev/null || true)"
  fi

  # Older stop paths removed PID files even though setsid-created executors
  # survived. Recover the root PID from its task-specific command line.
  if ! [[ "$executor_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$executor_pid" 2>/dev/null; then
    executor_pid="$(find_task_executor_pid "$comment_id" 2>/dev/null || true)"
  fi

  if [[ "$executor_pid" =~ ^[0-9]+$ ]] && [ "$executor_pid" -gt 0 ] && kill -0 "$executor_pid" 2>/dev/null; then
    executor_args="$(ps -o args= -p "$executor_pid" 2>/dev/null || true)"
    # A PID file can outlive its process and the OS can reuse the numeric PID.
    # Never signal a process unless it still identifies the expected task runner.
    if [[ "$executor_args" != *agent-task-runner.sh* || "$executor_args" != *"$pid_file"* ]]; then
      local discovered_pid
      discovered_pid="$(find_task_executor_pid "$comment_id" 2>/dev/null || true)"
      if [[ "$discovered_pid" =~ ^[0-9]+$ ]] && [ "$discovered_pid" -gt 0 ] && kill -0 "$discovered_pid" 2>/dev/null; then
        executor_pid="$discovered_pid"
        executor_args="$(ps -o args= -p "$executor_pid" 2>/dev/null || true)"
      fi
    fi

    if [[ "$executor_args" == *agent-task-runner.sh* && "$executor_args" == *"$pid_file"* ]]; then
      executor_pgid="$(ps -o pgid= -p "$executor_pid" 2>/dev/null | tr -d '[:space:]')"
      mapfile -t descendants < <(task_descendant_pids "$executor_pid")
      log "terminating task executor tree for $comment_id (pid=$executor_pid descendants=${#descendants[@]})"

      # Signal descendants before their parents so a child that created a new
      # session (e.g. timeout -> opencode) cannot survive when its parent exits.
      for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
        kill -TERM "${descendants[$wait_attempt]}" 2>/dev/null || true
      done
      if [[ "$executor_pgid" =~ ^[0-9]+$ ]] && [ "$executor_pgid" -eq "$executor_pid" ]; then
        kill -TERM -- "-$executor_pgid" 2>/dev/null || true
      fi
      kill -TERM "$executor_pid" 2>/dev/null || true

      alive=1
      for ((wait_attempt=0; wait_attempt<30; wait_attempt++)); do
        alive=0
        for process_pid in "${descendants[@]}" "$executor_pid"; do
          if task_process_is_running "$process_pid"; then
            alive=1
            break
          fi
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.1
      done

      if [ "$alive" -eq 1 ]; then
        forced=1
        log "WARN: task executor tree for $comment_id did not stop after TERM; sending KILL"
        for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
          process_pid="${descendants[$wait_attempt]}"
          task_process_is_running "$process_pid" && kill -KILL "$process_pid" 2>/dev/null || true
        done
        if [[ "$executor_pgid" =~ ^[0-9]+$ ]] && [ "$executor_pgid" -eq "$executor_pid" ]; then
          kill -KILL -- "-$executor_pgid" 2>/dev/null || true
        fi
        kill -KILL "$executor_pid" 2>/dev/null || true
      fi
      lc_log "EXECUTOR_KILLED" "task=$comment_id pid=$executor_pid descendants=${#descendants[@]} forced=$forced"
    else
      log "WARN: refusing to terminate PID $executor_pid for task $comment_id because it no longer matches the task runner"
    fi
  fi

  rm -f "$pid_file" 2>/dev/null || true
}

# Resolve a flattened artifact filename back to the canonical task ID through
# SQLite. Never infer the DB identity from a filename because "/" is mapped to
# "_" for CI task IDs.
task_id_from_file_key() {
  local file_key="$1"
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ "$(manul_task_file_key "$candidate")" = "$file_key" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(sqlite3 "$DB" "SELECT commentId FROM processed_comments;" 2>/dev/null || true)
  return 1
}

# Return unique task IDs for executors still represented by PID files or live
# agent-task-runner processes. The latter recovers from legacy stop paths that
# removed PID markers before their process tree exited.
list_task_executor_ids() {
  local pid_file base task_id file_key resolved_task_id cmdline_file cmdline remainder
  local context_prefix="$MANUL_STATE_DIR/tasks/task-"
  declare -A seen_task_ids=()

  for pid_file in "$MANUL_DIR"/task-*.executor.pid; do
    [ -f "$pid_file" ] || continue
    base="${pid_file##*/}"
    file_key="${base#task-}"
    file_key="${file_key%.executor.pid}"
    [ -n "$file_key" ] || continue
    resolved_task_id="$(task_id_from_file_key "$file_key" 2>/dev/null || true)"
    task_id="${resolved_task_id:-$file_key}"
    seen_task_ids["$task_id"]=1
  done

  local process_pid
  while read -r process_pid cmdline; do
    [[ "$process_pid" =~ ^[0-9]+$ ]] || continue
    [[ "$cmdline" == *agent-task-runner.sh*"$context_prefix"*".ctx.json"* ]] || continue
    remainder="${cmdline#*"$context_prefix"}"
    file_key="${remainder%%.ctx.json*}"
    [ -n "$file_key" ] && [ "$file_key" != "$remainder" ] || continue
    resolved_task_id="$(task_id_from_file_key "$file_key" 2>/dev/null || true)"
    task_id="${resolved_task_id:-$file_key}"
    seen_task_ids["$task_id"]=1
  done < <(ps -ww -axo pid=,command= 2>/dev/null)

  for task_id in "${!seen_task_ids[@]}"; do
    printf '%s\n' "$task_id"
  done
}

terminate_all_task_executors() {
  local task_id
  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue
    terminate_task_executor "$task_id"
  done < <(list_task_executor_ids)
}

# Validate that a recorded heartbeat PID still belongs to a Manul loop or is
# explicitly holding the dispatcher lock. This prevents killing an unrelated
# process if the PID from an old PID file has been reused by the OS.
is_manul_heartbeat_process() {
  local pid="$1" cmdline fd_target daemon_pid worker_file worker_pid
  cmdline="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$cmdline" ] || return 1

  daemon_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ "$pid" = "$daemon_pid" ] && return 1
  for worker_file in "$MANUL_DIR"/worker-*.pid; do
    [ -f "$worker_file" ] || continue
    worker_pid="$(cat "$worker_file" 2>/dev/null || true)"
    [ "$pid" = "$worker_pid" ] && return 1
  done

  if [[ "$cmdline" == *manul-daemon.sh* && "$cmdline" == *loop* ]]; then
    return 0
  fi
  if [ -r "/proc/$pid/fd/210" ]; then
    fd_target="$(readlink "/proc/$pid/fd/210" 2>/dev/null || true)"
  elif command -v lsof >/dev/null 2>&1; then
    fd_target="$(lsof -a -p "$pid" -d 210 -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
  else
    fd_target=""
  fi
  [ "$fd_target" = "$TASK_LOCK_FILE" ]
}

terminate_task_heartbeat() {
  local comment_id="$1"
  local pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")"
  local heartbeat_pid="" args="" process_pid wait_attempt alive forced=0
  local descendants=()

  [ -f "$pid_file" ] || return 0
  heartbeat_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if ! [[ "$heartbeat_pid" =~ ^[0-9]+$ ]] || [ "$heartbeat_pid" -le 1 ] || ! kill -0 "$heartbeat_pid" 2>/dev/null; then
    rm -f "$pid_file" 2>/dev/null || true
    return 0
  fi

  if ! is_manul_heartbeat_process "$heartbeat_pid"; then
    log "WARN: refusing to terminate PID $heartbeat_pid from heartbeat file for task $comment_id; process identity does not match"
    return 1
  fi

  mapfile -t descendants < <(task_descendant_pids "$heartbeat_pid")
  args="$(ps -o args= -p "$heartbeat_pid" 2>/dev/null || true)"
  log "terminating heartbeat process tree for task $comment_id (pid=$heartbeat_pid descendants=${#descendants[@]})"

  for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
    kill -TERM "${descendants[$wait_attempt]}" 2>/dev/null || true
  done
  kill -TERM "$heartbeat_pid" 2>/dev/null || true

  alive=1
  for ((wait_attempt=0; wait_attempt<20; wait_attempt++)); do
    alive=0
    for process_pid in "${descendants[@]}" "$heartbeat_pid"; do
      if task_process_is_running "$process_pid"; then
        alive=1
        break
      fi
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.1
  done

  if [ "$alive" -eq 1 ]; then
    forced=1
    log "WARN: heartbeat process tree for $comment_id did not stop after TERM; sending KILL"
    for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
      process_pid="${descendants[$wait_attempt]}"
      task_process_is_running "$process_pid" && kill -KILL "$process_pid" 2>/dev/null || true
    done
    kill -KILL "$heartbeat_pid" 2>/dev/null || true
  fi

  rm -f "$pid_file" 2>/dev/null || true
  lc_log "HEARTBEAT_REAPED" "task=$comment_id pid=$heartbeat_pid descendants=${#descendants[@]} forced=$forced"
}

terminate_all_task_heartbeats() {
  local pid_file base file_key task_id resolved_task_id
  for pid_file in "$MANUL_DIR"/task-*.heartbeat.pid; do
    [ -f "$pid_file" ] || continue
    base="${pid_file##*/}"
    file_key="${base#task-}"
    file_key="${file_key%.heartbeat.pid}"
    [ -n "$file_key" ] || continue
    resolved_task_id="$(task_id_from_file_key "$file_key" 2>/dev/null || true)"
    task_id="${resolved_task_id:-$file_key}"
    terminate_task_heartbeat "$task_id"
  done
}
# A queued/terminal task must not retain a detached executor or heartbeat from
# an earlier attempt. Running tasks are left alone unless recovery claimed them.
cleanup_orphaned_task_executors() {
  local task_id safe_task_id task_status
  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue
    safe_task_id="$(sql_escape "$task_id")"
    task_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null || true)"
    if [ "$task_status" != "running" ]; then
      log "cleanup_orphaned_task_executors: terminating executor for task $task_id (status=${task_status:-missing})"
      terminate_task_executor "$task_id"
    fi
  done < <(list_task_executor_ids)
}

cleanup_orphaned_task_heartbeats() {
  local pid_file base file_key task_id resolved_task_id safe_task_id task_state
  for pid_file in "$MANUL_DIR"/task-*.heartbeat.pid; do
    [ -f "$pid_file" ] || continue
    base="${pid_file##*/}"
    file_key="${base#task-}"
    file_key="${file_key%.heartbeat.pid}"
    [ -n "$file_key" ] || continue
    resolved_task_id="$(task_id_from_file_key "$file_key" 2>/dev/null || true)"
    task_id="${resolved_task_id:-$file_key}"
    safe_task_id="$(sql_escape "$task_id")"
    task_state="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null || true)"
    if [ "$task_state" != "running" ]; then
      log "cleanup_orphaned_task_heartbeats: terminating heartbeat for task $task_id (status=${task_state:-missing})"
      terminate_task_heartbeat "$task_id" || true
    fi
  done
}

stop_heartbeat() {
  local comment_id="$1"
  local pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")"
  local pid="${HEARTBEAT_PIDS[$comment_id]:-}"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    unset HEARTBEAT_PIDS["$comment_id"]
  fi
  rm -f "$pid_file" 2>/dev/null || true
  log "stopped heartbeat for task $comment_id"
  lc_log "HEARTBEAT_STOP" "task=$comment_id"
}
# Refresh heartbeatAt in database to prevent watchdog timeout
refresh_heartbeat() {
  local comment_id="$1"
  if [ -n "${HEARTBEAT_PIDS[$comment_id]:-}" ]; then
    local worker_pid="${CURRENT_WORKER_PID:-$BASHPID}"
    local claim_token
    claim_token="$(sqlite3 "$DB" "SELECT claimToken FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' AND status='running' AND workerPid=$worker_pid LIMIT 1;" 2>/dev/null)"
    [ -n "$claim_token" ] || return 0
    local safe_claim_token
    safe_claim_token="$(sql_escape "$claim_token")"
    sqlite3 "$DB" "UPDATE processed_comments SET heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds') WHERE commentId='$(sql_escape "$comment_id")' AND status='running' AND workerPid=$worker_pid AND claimToken='$safe_claim_token';" 2>/dev/null || true
  fi
}

start() {
  validate_dispatch_interval
  configure_task_retention

  # Serialize the whole preparation/start path, including stale-workspace cleanup.
  # Otherwise two concurrent startup wrappers could both mutate pool state before
  # reaching the old late lock acquisition.
  mkdir -p "$(dirname "$FLOCK_FILE")"
  exec 200>"$FLOCK_FILE"
  flock -n 200 || { echo "cannot acquire lock (another start in progress)" >&2; exec 200>&-; return 1; }
  if [ -f "$PID_FILE" ]; then
    local initial_pid initial_cmdline
    initial_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ "$initial_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$initial_pid" 2>/dev/null; then
      initial_cmdline="$(ps -ww -p "$initial_pid" -o command= 2>/dev/null || true)"
      if [[ "$initial_cmdline" == *"manul-daemon.sh"* ]]; then
        flock -u 200
        exec 200>&-
        echo "already running (pid $initial_pid)"
        return 0
      fi
      log "WARN: daemon PID file points to a live unrelated/reused PID ($initial_pid); removing stale PID file"
    fi
    rm -f "$PID_FILE"
  fi

  # Reclaim workspaces left BUSY by dead/stale workers before creating the pool.
  # This must happen before workspace_pool_init: a stale BUSY row otherwise
  # makes available_ws=0 and prevents the daemon from starting at all.
  local workspace_manager="$MANUL_DIR/workspace-manager.sh"
  if [ ! -f "$workspace_manager" ] || ! bash -n "$workspace_manager" 2>/dev/null; then
    log "ERROR: invalid workspace manager: $workspace_manager"
    return 1
  fi
  if ! source "$workspace_manager"; then
    log "ERROR: failed to source workspace manager: $workspace_manager"
    return 1
  fi
  if ! workspace_cleanup_stale 3600; then
    log "ERROR: workspace stale cleanup failed"
    return 1
  fi
  workspace_pool_init "$MAX_CONCURRENT_TASKS"

  # Clean up the legacy directory lock left by pre-flock Manul versions.
  if [ -d "$MANUL_DIR/.daemon-lock" ]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$MANUL_DIR/.daemon-lock" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -ge "$LOCK_TTL" ]; then
      log "stale .daemon-lock detected (age=${lock_age}s, ttl=${LOCK_TTL}s) → removing"
      rm -rf "$MANUL_DIR/.daemon-lock" 2>/dev/null
    else
      log ".daemon-lock is fresh (age=${lock_age}s); skipping cleanup"
    fi
  fi

  # Check workspace availability
  local available_ws
  available_ws="$(workspace_available_count)"
  if [ "$available_ws" -lt "$MAX_CONCURRENT_TASKS" ]; then
    log "ERROR: insufficient workspaces for concurrency (have=$available_ws, need=$MAX_CONCURRENT_TASKS)"
    return 1
  fi

  # Lifecycle marker: this is an INTENTIONAL start. The .enabled marker is the
  # contract between intentional start/stop and the watchdog: the watchdog only
  # restarts the daemon when it is present, so crash recovery never re-enables
  # automation. Direct callers (aicode, the `manul` alias) reach this point
  # via start-manul-automation.sh, which also touches the marker; this touch is
  # the safety net for any path that invokes manul-daemon.sh start directly.
  touch "$MANUL_DIR/.enabled"

  # The start lock acquired at function entry remains held until after the supervisor is forked.

  # Fork the daemon to run in background.
  (
    # Child process: claim an OS-level owner lock for the supervisor's full lifetime.
    # Workers and isolated executors close this descriptor so they cannot pin the
    # singleton lock after the supervisor exits or a replacement starts.
    mkdir -p "$(dirname "$DAEMON_OWNER_LOCK_FILE")"
    exec 220>"$DAEMON_OWNER_LOCK_FILE"
    if ! flock -n 220; then
      log "ERROR: another daemon supervisor owns the lifetime lock; refusing duplicate start"
      exit 1
    fi
    # Write PID only after owning the singleton lock.
    echo "$BASHPID" >"$PID_FILE"

    # Start one independent producer. It polls GitHub and writes new tasks to
    # SQLite; consumer workers never run poll.sh themselves.
    local master_pid=$BASHPID
    local poller_pid
    setsid nohup "$DAEMON_SCRIPT_ABS" loop --poller --parent-pid="$master_pid" 220>&- >>"$LOG" 2>&1 &
    poller_pid=$!
    echo "$poller_pid" >"$POLLER_PID_FILE"
    log "spawned poller (pid=$poller_pid interval=${INTERVAL}s)"

    # Spawn independent queue consumers/executors.
    local i worker_pid
    declare -a WORKER_PIDS=()
    for ((i = 0; i < MAX_CONCURRENT_TASKS; i++)); do
      # Use an absolute path so the worker survives even if the daemon's cwd
      # changes (nohup otherwise resolves a bare $0 against an unknown cwd).
      setsid nohup "$DAEMON_SCRIPT_ABS" loop --worker="$i" --parent-pid="$master_pid" 220>&- >>"$LOG" 2>&1 &
      worker_pid=$!
      echo "$worker_pid" >"$MANUL_DIR/worker-$i.pid"
      WORKER_PIDS+=("$worker_pid")
      log "spawned consumer worker $i (pid=$worker_pid)"
    done

    flock -u 200
    exec 200>&-
    log "$TASK_RETENTION_CONFIG_MESSAGE"
    lc_log "DAEMON_START" "pid=$master_pid interval=${INTERVAL}s dispatchInterval=${DISPATCH_INTERVAL}s workers=$MAX_CONCURRENT_TASKS poller=$poller_pid"
    echo "manul daemon started (pid $master_pid, pollInterval ${INTERVAL}s, dispatchInterval ${DISPATCH_INTERVAL}s, workers=$MAX_CONCURRENT_TASKS, poller=$poller_pid)"

    # Signal handler: stop all workers on termination
    local stopping=0
    handle_stop() {
      if [ "$stopping" -eq 1 ]; then
        return
      fi
      stopping=1
      log "daemon received stop signal, terminating workers"
      for wp in "${WORKER_PIDS[@]}"; do
        kill -- "-$wp" 2>/dev/null || kill "$wp" 2>/dev/null || true
      done
      if [[ "${poller_pid:-}" =~ ^[1-9][0-9]*$ ]]; then
        kill -- "-$poller_pid" 2>/dev/null || kill "$poller_pid" 2>/dev/null || true
      fi
      wait 2>/dev/null || true
      rm -f "$PID_FILE" "$POLLER_PID_FILE"
      flock -u 220 2>/dev/null || true
      exec 220>&- 2>/dev/null || true
      lc_log "DAEMON_STOP" "pid=$BASHPID"
      exit 0
    }
    trap handle_stop TERM INT

    # Stay alive as the long-lived daemon process, watching over workers
    while true; do
      # Wait for any consumer or the producer to exit so either can be recovered.
      if [ ${#WORKER_PIDS[@]} -gt 0 ]; then
        wait -n "${WORKER_PIDS[@]}" "$poller_pid" 2>/dev/null || true
      else
        wait "$poller_pid" 2>/dev/null || true
      fi
      # Check if we should stop
      if [ "$stopping" -eq 1 ]; then
        break
      fi
      # Restart any dead workers
      local new_pids=()
      for i in "${!WORKER_PIDS[@]}"; do
if ! kill -0 "${WORKER_PIDS[$i]}" 2>/dev/null; then
           log "worker $i died (pid=${WORKER_PIDS[$i]}), restarting"
           setsid nohup "$DAEMON_SCRIPT_ABS" loop --worker="$i" --parent-pid="$master_pid" 220>&- >>"$LOG" 2>&1 &
          worker_pid=$!
          echo "$worker_pid" >"$MANUL_DIR/worker-$i.pid"
          new_pids+=("$worker_pid")
        else
          new_pids+=("${WORKER_PIDS[$i]}")
        fi
      done
      WORKER_PIDS=("${new_pids[@]}")

      # The poller is supervised independently from the consumer pool.
      if ! kill -0 "$poller_pid" 2>/dev/null; then
        log "poller died (pid=$poller_pid), restarting"
        lc_log "POLLER_RESTART" "previousPid=$poller_pid"
        setsid nohup "$DAEMON_SCRIPT_ABS" loop --poller --parent-pid="$master_pid" 220>&- >>"$LOG" 2>&1 &
        poller_pid=$!
        echo "$poller_pid" >"$POLLER_PID_FILE"
        log "restarted poller (pid=$poller_pid)"
      fi
    done
  ) &
  local daemon_pid=$!

  # Parent: we release the lock and return.
  flock -u 200
  return 0
}
stop() {
  # Lifecycle marker: this is an INTENTIONAL stop. Remove .enabled so the
  # watchdog stops trying to restart the daemon (crash recovery never
  # re-enables automation). Done before the early return so a "not running"
  # answer still clears a stale marker left by a previous crash.
  rm -f "$MANUL_DIR/.enabled"

  # Helpers can survive an old worker even if its PID marker has been removed.
  # Reap heartbeat subtrees and isolated agent executors before stopping workers.
  terminate_all_task_heartbeats
  terminate_all_task_executors

  if [ ! -f "$PID_FILE" ]; then
    # A crashed supervisor may have left its producer PID marker behind.
    if [ -f "$POLLER_PID_FILE" ]; then
      local orphan_poller_pid orphan_poller_cmdline
      orphan_poller_pid="$(cat "$POLLER_PID_FILE" 2>/dev/null || true)"
      if [[ "$orphan_poller_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$orphan_poller_pid" 2>/dev/null; then
        orphan_poller_cmdline="$(ps -ww -p "$orphan_poller_pid" -o command= 2>/dev/null || true)"
        if [[ "$orphan_poller_cmdline" == *"manul-daemon.sh"* && "$orphan_poller_cmdline" == *"--poller"* ]]; then
          kill -- "-$orphan_poller_pid" 2>/dev/null || kill "$orphan_poller_pid" 2>/dev/null || true
        fi
      fi
      rm -f "$POLLER_PID_FILE"
    fi
    echo "not running"
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  # Kill all worker processes
  for pf in "$MANUL_DIR"/worker-*.pid; do
    [ -f "$pf" ] || continue
    local wpid
    wpid="$(cat "$pf" 2>/dev/null)"
    if [ -n "$wpid" ]; then
      # Worker is a setsid process-group leader. Terminate the whole group so
      # an in-flight AgentExecutionController/OpenClaw process cannot survive
      # a daemon restart and keep the singleton task lock occupied.
      kill -- "-$wpid" 2>/dev/null || kill "$wpid" 2>/dev/null || true
    fi
    rm -f "$pf"
  done
  kill "$pid" 2>/dev/null
  # The supervisor normally terminates the poller in its signal handler. Also
  # reap its process group here in case shutdown races with supervisor exit.
  if [ -f "$POLLER_PID_FILE" ]; then
    local poller_pid
    poller_pid="$(cat "$POLLER_PID_FILE" 2>/dev/null || true)"
    if [[ "$poller_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$poller_pid" 2>/dev/null; then
      local poller_cmdline
      poller_cmdline="$(ps -ww -p "$poller_pid" -o command= 2>/dev/null || true)"
      if [[ "$poller_cmdline" == *"manul-daemon.sh"* && "$poller_cmdline" == *"--poller"* ]]; then
        kill -- "-$poller_pid" 2>/dev/null || kill "$poller_pid" 2>/dev/null || true
      fi
    fi
    rm -f "$POLLER_PID_FILE"
  fi
  wait 2>/dev/null || true
  rm -f "$PID_FILE"
  lc_log "DAEMON_STOP" "pid=$pid"
  echo "manul daemon stopped (pid $pid)"
}

status() {
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "running (pid $(cat "$PID_FILE"))"
  else
    echo "not running"
  fi
}


# Return the number of queued tasks that are eligible to run now.
# SQLite is the authoritative scheduler state; poll.sh only provides a wake-up hint.
eligible_queued_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued' AND (nextAttemptAt IS NULL OR datetime(nextAttemptAt) <= datetime('now'));" 2>/dev/null || echo 0
}

# Read selected SQLite rows as JSON without depending on the sqlite3 CLI's
# version-specific -json flag. Python's stdlib driver is available on supported
# Manul hosts and opens this connection read-only, so this helper cannot mutate
# task state.
sqlite_query_json() {
  local database="${1:-}" query="${2:-}"
  [ -n "$database" ] && [ -n "$query" ] || return 2
  python3 - "$database" "$query" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

database_path, query = sys.argv[1:3]
connection = None
try:
    database_uri = Path(database_path).resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(database_uri, uri=True, timeout=5.0)
    cursor = connection.execute(query)
    if cursor.description is None:
        raise ValueError("query did not return rows")
    columns = [column[0] for column in cursor.description]
    rows = [
        {column: value for column, value in zip(columns, row)}
        for row in cursor.fetchall()
    ]
    sys.stdout.write(json.dumps(rows, ensure_ascii=False, separators=(",", ":")))
except Exception as error:
    print("sqlite_query_json: {}: {}".format(type(error).__name__, error), file=sys.stderr)
    raise SystemExit(1)
finally:
    if connection is not None:
        connection.close()
PY
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}
# Remove terminal task rows older than the configured history retention.
# Only processed_comments task data is removed; conversation_messages keeps
# message IDs so an old GitHub trigger cannot be rediscovered and requeued.
cleanup_expired_tasks() {
  [ -f "$DB" ] || return 0

  local deleted
  deleted="$(sqlite3 "$DB" "
    DELETE FROM processed_comments
    WHERE status IN ('completed', 'failed', 'stale')
      AND COALESCE(processedAt, createdAt) < datetime('now', '-${TASK_HISTORY_RETENTION_DAYS} days');
    SELECT changes();
  " 2>>"$LOG" | tail -n 1)"

  if [[ "$deleted" =~ ^[0-9]+$ ]] && [ "$deleted" -gt 0 ]; then
    log "task retention cleanup: removed $deleted terminal task(s) older than ${TASK_HISTORY_RETENTION_DAYS} days"
  elif [ -n "$deleted" ] && ! [[ "$deleted" =~ ^[0-9]+$ ]]; then
    log "WARN: task retention cleanup returned unexpected result: $deleted"
  fi


}


# Remove stale files from the entire Manul log tree, independently from task-row
# retention. File age is based on last modification so currently active log files
# remain in place while old task archives and inactive log files are deleted.
cleanup_expired_logs() {
  [ -n "${MANUL_LOG_DIR:-}" ] && [ -d "$MANUL_LOG_DIR" ] || return 0

  local retention_minutes=$((7 * 24 * 60))
  local deleted_logs
  deleted_logs="$(
    {
      find "$MANUL_LOG_DIR" -type f -mmin "+${retention_minutes}" -print -delete 2>/dev/null
      # The startup wrapper's redirected output log is beside the canonical
      # logs/ directory rather than inside it, so include that one legacy path.
      if [ -f "$MANUL_DIR/daemon.log" ]; then
        find "$MANUL_DIR/daemon.log" -type f -mmin "+${retention_minutes}" -print -delete 2>/dev/null
      fi
    } | wc -l | tr -d '[:space:]'
  )"

  if [[ "$deleted_logs" =~ ^[0-9]+$ ]] && [ "$deleted_logs" -gt 0 ]; then
    log "log retention cleanup: removed $deleted_logs file(s) older than 7 days"
  fi

  # Avoid leaving one empty directory per expired task archive behind.
  if [ "$MANUL_TASK_LOG_DIR" = "$MANUL_LOG_DIR/tasks" ] && [ -d "$MANUL_TASK_LOG_DIR" ]; then
    find "$MANUL_TASK_LOG_DIR" -depth -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
}


# Ensure the workspace pool is healthy for long-lived daemons.
# The watchdog may remove stale idle workspaces while this daemon remains alive;
# replenish the pool before every dispatch cycle instead of waiting for start().
ensure_workspace_pool() {
  local workspace_manager="$MANUL_DIR/workspace-manager.sh"
  if [ ! -f "$workspace_manager" ]; then
    log "ERROR: workspace manager not found: $workspace_manager"
    return 1
  fi

  # Source here as well as in loop() so direct run-once invocations get the
  # same workspace-pool lifecycle guarantees as the long-running daemon.
  if ! source "$workspace_manager"; then
    log "ERROR: failed to source workspace manager: $workspace_manager"
    return 1
  fi
  if ! workspace_cleanup_stale 3600; then
    log "ERROR: workspace stale cleanup failed"
    return 1
  fi
  if ! workspace_pool_init "$MAX_CONCURRENT_TASKS"; then
    log "ERROR: workspace pool initialization failed (size=$MAX_CONCURRENT_TASKS)"
    return 1
  fi

  local total
  total="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status IN ('IDLE','BUSY');" 2>/dev/null || echo 0)"
  if [ "${total:-0}" -lt "$MAX_CONCURRENT_TASKS" ]; then
    log "ERROR: workspace pool below requested capacity after reconciliation (have=${total:-0}, need=$MAX_CONCURRENT_TASKS)"
    return 1
  fi
  return 0
}

# Ensure nextAttemptAt column exists in processed_comments
# Idempotent: safe to call multiple times, works on fresh and existing DBs
# Uses BEGIN IMMEDIATE to prevent race when multiple workers start concurrently
ensure_nextattemptat_column() {
  local has_column
  has_column="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -c '|nextAttemptAt|' || echo "0")"
  if [ "$has_column" -eq 0 ]; then
    log "migration: adding nextAttemptAt column to processed_comments"
    # Use BEGIN IMMEDIATE to serialize concurrent migration attempts
    sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT; UPDATE processed_comments SET nextAttemptAt = datetime('now', '+60 seconds') WHERE status='queued' AND attempts > 0 AND nextAttemptAt IS NULL; COMMIT;" 2>>"$LOG" || {
      log "ERROR: failed to add nextAttemptAt column"
      return 1
    }
    log "migration: nextAttemptAt column added and initialized"
  fi
  return 0
}

# Add recovery bookkeeping to existing installations without replacing the user's DB.
# agentStartedAt distinguishes an execution that actually reached the runtime from
# a claim that failed during checkout/workspace preparation. Existing running rows
# are conservatively classified as started during the one-time migration.
ensure_recovery_tracking_columns() {
  local columns
  columns="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG")" || return 1
  if ! printf '%s\n' "$columns" | grep -q '|preExecutionFailures|'; then
    local alter_failures
    alter_failures="$(sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN preExecutionFailures INTEGER NOT NULL DEFAULT 0; COMMIT;" 2>&1)" || {
      if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|preExecutionFailures|'; then
        log "ERROR: failed to add preExecutionFailures column: $alter_failures"
        return 1
      fi
    }
    log "migration: preExecutionFailures column added or already present"
  fi

  columns="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG")" || return 1
  if ! printf '%s\n' "$columns" | grep -q '|agentStartedAt|'; then
    local alter_started
    alter_started="$(sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN agentStartedAt TEXT; UPDATE processed_comments SET agentStartedAt=COALESCE(processedAt,datetime('now')) WHERE status='running' AND agentStartedAt IS NULL; COMMIT;" 2>&1)" || {
      if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|agentStartedAt|'; then
        log "ERROR: failed to add agentStartedAt column: $alter_started"
        return 1
      fi
    }
    log "migration: agentStartedAt column added; legacy running claims preserved as execution attempts"
  fi
  return 0
}

# Ensure each task claim has a unique ownership token. workerPid identifies a long-lived worker loop, not one specific task execution.
ensure_claim_token_column() {
  if sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|claimToken|'; then
    return 0
  fi
  log "migration: adding claimToken column to processed_comments"
  local alter_err
  alter_err="$(sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE processed_comments ADD COLUMN claimToken TEXT; COMMIT;" 2>&1)" || {
    # Another worker may have won the migration race.
    if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|claimToken|'; then
      log "ERROR: failed to add claimToken column: $alter_err"
      return 1
    fi
  }
  log "migration: claimToken column added or already present"
  return 0
}

# The conversations table schema is not uniform across Manul entry points:
# manul-conversation.sh creates it without activePrUrl, while poll.sh and
# manul-conversation-linker.sh create it with the column. close_drained_conversations()
# and poll.sh both write activePrUrl, so existing databases that were seeded by
# conversation.sh must be migrated before those writes run. The column is
# nullable, so adding it is safe on empty and populated tables alike.
ensure_conversations_activeprurl_column() {
  if sqlite3 "$DB" "PRAGMA table_info(conversations);" 2>>"$LOG" | grep -q '|activePrUrl|'; then
    return 0
  fi
  log "migration: adding activePrUrl column to conversations"
  local alter_err
  alter_err="$(sqlite3 "$DB" "BEGIN IMMEDIATE; ALTER TABLE conversations ADD COLUMN activePrUrl TEXT; COMMIT;" 2>&1)" || {
    # Another worker may have won the migration race.
    if ! sqlite3 "$DB" "PRAGMA table_info(conversations);" 2>/dev/null | grep -q '|activePrUrl|'; then
      log "ERROR: failed to add activePrUrl column: $alter_err"
      return 1
    fi
  }
  log "migration: activePrUrl column added or already present"
  return 0
}
post_github_comment() {
  local repo="$1"
  local issue="$2"
  local body="$3"
  local reply_to="${4:-}"

  # Bot mode identifies automated comments; human mode deliberately does not.
  local signed_body
  if [ "$MANUL_MODE" = "human" ]; then
    signed_body="$body"
  else
    local signature="— manul 🐈"
    if [[ "$body" == *"$signature" ]]; then
      signed_body="$body"
    else
      signed_body="${body}"$'\n\n'"$signature"
    fi
  fi

  if [ -n "$reply_to" ]; then
    # Review-thread task: reply inside the review thread via gh api.
    # Build the request as JSON on stdin so comment content is never interpreted
    # as a form value by the gh CLI.
    printf '%s' "$signed_body" |
      jq -Rs --argjson reply_id "$reply_to" '{body:., in_reply_to:$reply_id}' |
      gh api "repos/$repo/pulls/$issue/comments" --input - 2>>"$LOG"
  else
    # Top-level issue/PR-conversation task: post as a regular comment
    gh issue comment "$issue" --repo "$repo" --body "$signed_body" 2>>"$LOG"
  fi
}

# Add the machine-readable terminal event to the exact result body that will
# be posted. Keeping this in one helper makes it testable and prevents a
# post-before-marker ordering regression in the dispatcher.
build_terminal_lifecycle_comment() {
  local task_id="$1"
  local conversation_id="$2"
  local attempt="$3"
  local pr_number="$4"
  local task_status="$5"
  local error_message="$6"
  local body="$7"
  local event_type event_data event_marker

  case "$task_status" in
    completed)
      event_type="TASK_DONE"
      event_data="$(jq -nc \
        --arg taskId "$task_id" \
        --arg conversationId "$conversation_id" \
        --arg attempt "$attempt" \
        --arg prNumber "$pr_number" \
        '{taskId:$taskId,conversationId:$conversationId,status:"completed",attempt:($attempt|tonumber),prNumber:($prNumber|tonumber? // null)}')"
      ;;
    failed)
      event_type="TASK_FAILED"
      event_data="$(jq -nc \
        --arg taskId "$task_id" \
        --arg conversationId "$conversation_id" \
        --arg error "$error_message" \
        --arg attempt "$attempt" \
        --arg prNumber "$pr_number" \
        '{taskId:$taskId,conversationId:$conversationId,error:$error,attempt:($attempt|tonumber),prNumber:($prNumber|tonumber? // null)}')"
      ;;
    *)
      # Intermediate retries and non-terminal states must not emit a terminal
      # event. In particular, do not turn a retryable failure into TASK_FAILED.
      printf '%s' "$body"
      return 0
      ;;
  esac

  event_marker="<!-- manul:event $(printf '%s' "$event_data" | jq -c --arg type "$event_type" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{type:$type,timestamp:$timestamp,data:.}') -->"
  if [ -n "$body" ]; then
    printf '%s\n\n%s' "$event_marker" "$body"
  else
    printf '%s' "$event_marker"
  fi
}

ensure_terminal_lifecycle_outbox() {
  sqlite3 "$DB" <<'SQL' >/dev/null 2>>"$LOG"
CREATE TABLE IF NOT EXISTS manul_terminal_lifecycle_outbox (
  taskId TEXT NOT NULL,
  attempt INTEGER NOT NULL,
  eventType TEXT NOT NULL CHECK(eventType IN ('TASK_DONE', 'TASK_FAILED')),
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  replyTo TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  createdAt TEXT NOT NULL DEFAULT (datetime('now')),
  postedAt TEXT,
  postedCommentId TEXT,
  retryCount INTEGER NOT NULL DEFAULT 0,
  nextAttemptAt TEXT,
  lastError TEXT,
  PRIMARY KEY(taskId, attempt, eventType)
);
SQL
}
queue_terminal_lifecycle_comment() {
  local repo="$1" issue_num="$2" task_id="$3" attempt="$4" event_type="$5" body="$6" reply_to="${7:-}"
  local safe_repo safe_task_id safe_event safe_reply safe_body
  if [[ "$issue_num" =~ ^0+$ ]]; then
    lc_log "EXTERNAL_SOURCE_TERMINAL_COMMENT_SUPPRESSED" "task=$task_id event=$event_type"
    return 0
  fi
  if ! [[ "$issue_num" =~ ^[0-9]+$ && "$attempt" =~ ^[0-9]+$ ]] ||
     ! [[ "$event_type" == "TASK_DONE" || "$event_type" == "TASK_FAILED" ]] ||
     [ -z "$repo" ] || [ -z "$task_id" ] || [ -z "$body" ]; then
    log "ERROR: invalid terminal lifecycle outbox input for task $task_id"
    return 1
  fi
  if [ -n "$reply_to" ] && ! [[ "$reply_to" =~ ^[0-9]+$ ]]; then
    log "ERROR: invalid terminal lifecycle reply target for task $task_id"
    return 1
  fi
  ensure_terminal_lifecycle_outbox || return 1
  safe_repo="$(sql_escape "$repo")"
  safe_task_id="$(sql_escape "$task_id")"
  safe_event="$(sql_escape "$event_type")"
  safe_reply="$(sql_escape "$reply_to")"
  safe_body="$(sql_escape "$body")"
  sqlite3 "$DB" "
    INSERT OR IGNORE INTO manul_terminal_lifecycle_outbox
      (taskId, attempt, eventType, repository, issueNumber, replyTo, body, nextAttemptAt)
    VALUES
      ('$safe_task_id', $attempt, '$safe_event', '$safe_repo', $issue_num, '$safe_reply', '$safe_body', datetime('now'));
  " 2>>"$LOG"
}
find_terminal_lifecycle_comment_id() {
  local repo="$1" issue_num="$2" task_id="$3" attempt="$4" event_type="$5" reply_to="${6:-}"
  local endpoint comments_json existing_id
  if ! [[ "$attempt" =~ ^[0-9]+$ ]] ||
     ! [[ "$event_type" == "TASK_DONE" || "$event_type" == "TASK_FAILED" ]]; then
    log "ERROR: invalid terminal lifecycle lookup for task $task_id"
    return 2
  fi
  if [ -n "$reply_to" ]; then
    endpoint="repos/$repo/pulls/$issue_num/comments"
  else
    endpoint="repos/$repo/issues/$issue_num/comments"
  fi
  comments_json="$(gh api "$endpoint" --paginate 2>>"$LOG")" || {
    log "WARN: unable to read terminal lifecycle comments for $task_id attempt $attempt"
    return 2
  }
  existing_id="$(printf '%s\n' "$comments_json" | jq -rs \
    --arg task_id "$task_id" --argjson attempt "$attempt" \
    --arg event_type "$event_type" --arg reply_to "$reply_to" '
      def lifecycle_event:
        (.body // "") as $body
        | ($body | split("<!-- manul:event ")) as $parts
        | if ($parts | length) < 2 then null
          else (try ($parts[1] | split(" -->")[0] | fromjson) catch null)
          end;
      (add // [])
      | map(. as $comment
          | ($comment | lifecycle_event) as $event
          | select($event != null
              and $event.type == $event_type
              and $event.data.taskId == $task_id
              and $event.data.attempt == $attempt
              and (($reply_to == "") or (($comment.in_reply_to_id // "") | tostring) == $reply_to))
          | $comment.id)
      | .[0] // empty
    ' 2>>"$LOG")" || {
    log "WARN: unable to parse terminal lifecycle comments for $task_id attempt $attempt"
    return 2
  }
  printf '%s' "$existing_id"
  return 0
}
mark_terminal_lifecycle_comment_posted() {
  local task_id="$1" attempt="$2" event_type="$3" comment_id="${4:-}"
  local safe_task_id safe_event comment_id_sql
  safe_task_id="$(sql_escape "$task_id")"
  safe_event="$(sql_escape "$event_type")"
  if [[ "$comment_id" =~ ^[0-9]+$ ]]; then comment_id_sql="'$comment_id'"; else comment_id_sql="NULL"; fi
  sqlite3 "$DB" "
    UPDATE manul_terminal_lifecycle_outbox
    SET postedAt=datetime('now'), postedCommentId=$comment_id_sql,
        nextAttemptAt=NULL, lastError=NULL
    WHERE taskId='$safe_task_id' AND attempt=$attempt AND eventType='$safe_event';
  " 2>>"$LOG"
}
schedule_terminal_lifecycle_retry() {
  local task_id="$1" attempt="$2" event_type="$3" error="$4"
  local safe_task_id safe_event safe_error
  safe_task_id="$(sql_escape "$task_id")"
  safe_event="$(sql_escape "$event_type")"
  safe_error="$(sql_escape "$error")"
  sqlite3 "$DB" "
    UPDATE manul_terminal_lifecycle_outbox
    SET retryCount=retryCount+1, nextAttemptAt=datetime('now', '+30 seconds'),
        lastError='$safe_error'
    WHERE taskId='$safe_task_id' AND attempt=$attempt AND eventType='$safe_event' AND postedAt IS NULL;
  " 2>>"$LOG"
}
publish_terminal_lifecycle_comment() {
  local task_id="$1" attempt="$2" event_type="$3"
  local safe_task_id safe_event row repo issue_num reply_to body posted_at
  local lock_dir lock_file lock_key lock_fd lookup_rc post_rc existing_id
  if ! [[ "$attempt" =~ ^[0-9]+$ ]] ||
     ! [[ "$event_type" == "TASK_DONE" || "$event_type" == "TASK_FAILED" ]]; then return 1; fi
  ensure_terminal_lifecycle_outbox || return 1
  safe_task_id="$(sql_escape "$task_id")"
  safe_event="$(sql_escape "$event_type")"
  row="$(sqlite_query_json "$DB" "SELECT repository,issueNumber,replyTo,body,postedAt FROM manul_terminal_lifecycle_outbox WHERE taskId='$safe_task_id' AND attempt=$attempt AND eventType='$safe_event' LIMIT 1;" 2>>"$LOG")" || return 1
  if [ -z "$row" ] || [ "$(printf '%s' "$row" | jq 'length' 2>/dev/null)" != "1" ]; then
    log "ERROR: terminal lifecycle outbox row missing for $task_id attempt $attempt event $event_type"
    return 1
  fi
  repo="$(printf '%s' "$row" | jq -r '.[0].repository')"
  issue_num="$(printf '%s' "$row" | jq -r '.[0].issueNumber')"
  reply_to="$(printf '%s' "$row" | jq -r '.[0].replyTo // ""')"
  body="$(printf '%s' "$row" | jq -r '.[0].body')"
  posted_at="$(printf '%s' "$row" | jq -r '.[0].postedAt // ""')"
  if [ -n "$posted_at" ] || [[ "$issue_num" =~ ^0+$ ]]; then return 0; fi
  lock_dir="$MANUL_DIR/state/locks"
  mkdir -p "$lock_dir" 2>>"$LOG" || return 1
  lock_key="$(printf '%s\0%s\0%s' "$task_id" "$attempt" "$event_type" | sha256sum | cut -c1-24)"
  lock_file="$lock_dir/terminal-comment-$lock_key.lock"
  exec {lock_fd}>"$lock_file" || return 1
  flock "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  row="$(sqlite_query_json "$DB" "SELECT postedAt FROM manul_terminal_lifecycle_outbox WHERE taskId='$safe_task_id' AND attempt=$attempt AND eventType='$safe_event' LIMIT 1;" 2>>"$LOG")" || row="[]"
  posted_at="$(printf '%s' "$row" | jq -r '.[0].postedAt // ""' 2>/dev/null || true)"
  if [ -n "$posted_at" ]; then flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 0; fi
  existing_id=""
  lookup_rc=0
  existing_id="$(find_terminal_lifecycle_comment_id "$repo" "$issue_num" "$task_id" "$attempt" "$event_type" "$reply_to")" || lookup_rc=$?
  if [ "$lookup_rc" -ne 0 ]; then
    schedule_terminal_lifecycle_retry "$task_id" "$attempt" "$event_type" "pre-publication GitHub lookup failed (rc=$lookup_rc)" || true
    flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 2
  fi
  if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    mark_terminal_lifecycle_comment_posted "$task_id" "$attempt" "$event_type" "$existing_id" || true
    flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 0
  fi
  post_rc=0
  post_github_comment "$repo" "$issue_num" "$body" "$reply_to" >/dev/null 2>>"$LOG" || post_rc=$?
  if [ "$post_rc" -eq 0 ]; then
    mark_terminal_lifecycle_comment_posted "$task_id" "$attempt" "$event_type" "" || {
      schedule_terminal_lifecycle_retry "$task_id" "$attempt" "$event_type" "GitHub accepted comment but local receipt update failed" || true
      flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 2
    }
    flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 0
  fi
  existing_id=""
  lookup_rc=0
  existing_id="$(find_terminal_lifecycle_comment_id "$repo" "$issue_num" "$task_id" "$attempt" "$event_type" "$reply_to")" || lookup_rc=$?
  if [ "$lookup_rc" -eq 0 ] && [[ "$existing_id" =~ ^[0-9]+$ ]]; then
    mark_terminal_lifecycle_comment_posted "$task_id" "$attempt" "$event_type" "$existing_id" || true
    lc_log "TERMINAL_COMMENT_POST_CONFIRMED" "task=$task_id attempt=$attempt event=$event_type comment=$existing_id client_rc=$post_rc"
    flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 0
  fi
  if [ "$lookup_rc" -ne 0 ]; then
    schedule_terminal_lifecycle_retry "$task_id" "$attempt" "$event_type" "comment post rc=$post_rc; verification lookup failed rc=$lookup_rc" || true
  else
    schedule_terminal_lifecycle_retry "$task_id" "$attempt" "$event_type" "comment post failed rc=$post_rc; marker not found" || true
  fi
  flock -u "$lock_fd" || true; exec {lock_fd}>&-; return 1
}
close_drained_conversations() {
  ensure_terminal_lifecycle_outbox || return 1
  local changed
  changed="$(sqlite3 "$DB" "
    -- The poller and dispatcher share this database. A concurrent short write
    -- must not turn an otherwise safe conversation-close reconciliation into
    -- a one-off error; match the timeout used by other daemon write paths.
    PRAGMA busy_timeout=5000;
    UPDATE conversations
    SET status='COMPLETED',
        activePrNumber=NULL,
        activePrUrl=NULL,
        updatedAt=strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE status != 'COMPLETED'
      AND EXISTS (
        SELECT 1 FROM processed_comments task
        WHERE task.conversationId=conversations.conversationId
      )
      AND NOT EXISTS (
        SELECT 1 FROM processed_comments active_task
        WHERE active_task.conversationId=conversations.conversationId
          AND active_task.status IN ('queued','running','blocked_user')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM manul_terminal_lifecycle_outbox pending
        JOIN processed_comments pending_task ON pending_task.commentId=pending.taskId
        WHERE pending_task.conversationId=conversations.conversationId
          AND pending.postedAt IS NULL
      );
    SELECT changes();
  " 2>>"$LOG" | tail -n 1)" || {
    log "ERROR: could not reconcile conversation closure against pending terminal lifecycle events"
    return 1
  }
  if [[ "$changed" =~ ^[1-9][0-9]*$ ]]; then
    log "closed $changed drained conversation(s) after terminal lifecycle delivery was reconciled"
  fi
  return 0
}

retry_pending_terminal_lifecycle_comments() {
  ensure_terminal_lifecycle_outbox || return 1
  local rows row task_id attempt event_type
  rows="$(sqlite_query_json "$DB" "SELECT taskId,attempt,eventType FROM manul_terminal_lifecycle_outbox WHERE postedAt IS NULL AND (nextAttemptAt IS NULL OR nextAttemptAt <= datetime('now')) ORDER BY createdAt LIMIT 10;" 2>>"$LOG")" || return 1
  if [ -n "$rows" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      task_id="$(printf '%s' "$row" | jq -r '.taskId')"
      attempt="$(printf '%s' "$row" | jq -r '.attempt')"
      event_type="$(printf '%s' "$row" | jq -r '.eventType')"
      publish_terminal_lifecycle_comment "$task_id" "$attempt" "$event_type" || \
        log "WARN: terminal lifecycle comment remains pending for $task_id attempt $attempt event $event_type"
    done < <(printf '%s' "$rows" | jq -c '.[]')
  fi
  # A completed task may have finished while its result comment was pending.
  # Close conversations only after every terminal lifecycle outbox entry in
  # that conversation has been reconciled by a confirmed GitHub read-back/post.
  close_drained_conversations || log "WARN: deferred conversation-close reconciliation failed"
}

# Queue a terminal event and publish it when it has a GitHub destination.
# External-source tasks use issue number 0 as a sentinel: their result is
# delivered by the source adapter, so there is no GitHub comment/outbox row.
deliver_terminal_lifecycle_comment() {
  local repo="$1" issue_num="$2" task_id="$3" attempt="$4" event_type="$5" body="$6" reply_to="${7:-}"
  queue_terminal_lifecycle_comment "$repo" "$issue_num" "$task_id" "$attempt" "$event_type" "$body" "$reply_to" || return 1
  if [[ "$issue_num" =~ ^0+$ ]]; then
    return 0
  fi
  publish_terminal_lifecycle_comment "$task_id" "$attempt" "$event_type"
}



# Lifecycle/status/error comments are bot-only. Human mode remains silent
# about orchestration state on GitHub; the agent result comment is verified
# separately via the deterministic task/attempt marker.
post_lifecycle_comment() {
  if [[ "${2:-}" =~ ^0+$ ]]; then
    lc_log "EXTERNAL_SOURCE_LIFECYCLE_SUPPRESSED" "issue=0"
    return 0
  fi
  if [ "$MANUL_MODE" = "human" ]; then
    return 0
  fi
  post_github_comment "$@"
}

# Return the id of an existing TASK_STARTED comment for this task/attempt.
# A successful lookup with no match returns an empty string. API or parsing
# errors return 2 so the caller fails closed instead of publishing blindly.
find_task_started_comment_id() {
  local repo="$1" issue="$2" task_id="$3" attempt="$4" reply_to="${5:-}"
  local endpoint comments_json existing_id

  if ! [[ "$attempt" =~ ^[0-9]+$ ]]; then
    log "ERROR: invalid TASK_STARTED attempt for $task_id: $attempt"
    return 2
  fi

  if [ -n "$reply_to" ]; then
    endpoint="repos/$repo/pulls/$issue/comments"
  else
    endpoint="repos/$repo/issues/$issue/comments"
  fi

  comments_json="$(gh api "$endpoint" --paginate 2>>"$LOG")" || {
    log "WARN: unable to check existing TASK_STARTED comments for $task_id attempt $attempt"
    return 2
  }

  existing_id="$(printf '%s\n' "$comments_json" | jq -rs \
    --arg task_id "$task_id" \
    --argjson attempt "$attempt" \
    --arg reply_to "$reply_to" '
      def lifecycle_event:
        (.body // "") as $body
        | ($body | split("<!-- manul:event ")) as $parts
        | if ($parts | length) < 2 then null
          else (try ($parts[1] | split(" -->")[0] | fromjson) catch null)
          end;

      (add // [])
      | map(
          . as $comment
          | ($comment | lifecycle_event) as $event
          | select(
              $event != null
              and $event.type == "TASK_STARTED"
              and $event.data.taskId == $task_id
              and $event.data.attempt == $attempt
              and (($reply_to == "") or (($comment.in_reply_to_id // "") | tostring) == $reply_to)
              and (($comment.body // "") | contains("— manul 🐈"))
            )
          | $comment.id
        )
      | .[0] // empty
    ' 2>>"$LOG")" || {
      log "WARN: unable to parse existing TASK_STARTED comments for $task_id attempt $attempt"
      return 2
    }

  printf '%s' "$existing_id"
  return 0
}

# Publish TASK_STARTED once per task execution attempt. The post-confirmation
# lookup handles the ambiguous case where GitHub accepts a comment but gh
# returns a transport/response error. A later retry reuses the existing event
# rather than publishing a second visible comment for the same attempt.
post_task_started_comment() {
  local repo="$1" issue="$2" task_id="$3" attempt="$4" body="$5" reply_to="${6:-}"
  local existing_id post_rc lock_dir lock_file lock_key lock_fd

  # External-source and human modes intentionally suppress GitHub lifecycle
  # comments, so there is nothing to deduplicate in those modes.
  if [[ "$issue" =~ ^0+$ ]] || [ "$MANUL_MODE" = "human" ]; then
    post_lifecycle_comment "$repo" "$issue" "$body" "$reply_to"
    return $?
  fi

  if ! [[ "$attempt" =~ ^[0-9]+$ ]]; then
    log "ERROR: invalid TASK_STARTED attempt for $task_id: $attempt"
    return 2
  fi
  # Serialize publication for this task/attempt even if multiple consumers
  # reach this helper concurrently. The global dispatcher lock is an additional
  # protection, not the only idempotency boundary.
  lock_dir="$MANUL_DIR/state/locks"
  mkdir -p "$lock_dir" 2>>"$LOG" || return 2
  lock_key="$(printf '%s\0%s' "$task_id" "$attempt" | sha256sum | cut -c1-24)"
  lock_file="$lock_dir/task-started-$lock_key.lock"
  exec {lock_fd}>"$lock_file" || return 2
  if ! flock "$lock_fd"; then
    exec {lock_fd}>&-
    return 2
  fi

  if existing_id="$(find_task_started_comment_id "$repo" "$issue" "$task_id" "$attempt" "$reply_to")"; then
    if [ -n "$existing_id" ]; then
      log "INFO: TASK_STARTED already published for $task_id attempt $attempt (comment=$existing_id); suppressing duplicate"
      lc_log "TASK_STARTED_DEDUP" "task=$task_id attempt=$attempt comment=$existing_id"
      flock -u "$lock_fd" || true
      exec {lock_fd}>&-
      return 0
    fi
  else
    log "WARN: TASK_STARTED lookup failed for task $task_id attempt $attempt; not publishing without an idempotency check"
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 2
  fi

  post_rc=0
  post_lifecycle_comment "$repo" "$issue" "$body" "$reply_to" || post_rc=$?
  if [ "$post_rc" -eq 0 ]; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi

  # gh may report a transport error after GitHub has committed the comment.
  # Read back the exact task/attempt marker before classifying this as a
  # pre-execution publication failure.
  if existing_id="$(find_task_started_comment_id "$repo" "$issue" "$task_id" "$attempt" "$reply_to")"; then
    if [ -n "$existing_id" ]; then
      log "INFO: GitHub accepted TASK_STARTED for $task_id attempt $attempt despite the client error (comment=$existing_id)"
      lc_log "TASK_STARTED_POST_CONFIRMED" "task=$task_id attempt=$attempt comment=$existing_id client_rc=$post_rc"
      flock -u "$lock_fd" || true
      exec {lock_fd}>&-
      return 0
    fi
  else
    log "WARN: could not verify ambiguous TASK_STARTED post for task $task_id attempt $attempt"
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 2
  fi

  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return 1
}

# Publish TASK_STARTED for the claimed attempt and apply pre-agent recovery
# only when the comment cannot be confirmed. This keeps attempt accounting
# coupled to the publication result and makes the boundary directly testable.
publish_task_started_for_claim() {
  local comment_id="$1" claim_token="$2" repo="$3" issue_num="$4"
  local workspace_id="$5" reply_to="$6" body="$7" pr_number="${8:-}"
  local attempt="$9" start_post_rc=0 start_post_reason start_post_stage

  post_task_started_comment "$repo" "$issue_num" "$comment_id" "$attempt" "$body" "$reply_to" || start_post_rc=$?
  if [ "$start_post_rc" -ne 0 ]; then
    if [ "$start_post_rc" -eq 2 ]; then
      start_post_reason="Could not verify whether the TASK_STARTED lifecycle comment already exists; refusing to publish a possibly duplicate start event."
      start_post_stage="in_progress_comment_idempotency_check"
    else
      start_post_reason="Could not publish the in-progress lifecycle comment before starting the agent."
      start_post_stage="in_progress_comment"
    fi
    log "dispatch: TASK_STARTED publication did not complete for $comment_id (rc=$start_post_rc); releasing the claim as a pre-agent infrastructure failure"
    lc_log "TASK_ERROR" "task=$comment_id reason=task_started_publication_failed rc=$start_post_rc"
    if ! handle_pre_execution_failure "$comment_id" "$claim_token" "$repo" "$issue_num" "$workspace_id" "$reply_to" "$start_post_reason" "$pr_number" "$attempt" "$start_post_stage"; then
      log "ERROR: pre-agent recovery did not complete after TASK_STARTED publication failure for $comment_id; dispatch must stop and leave watchdog/recovery to reconcile the claim"
      return 2
    fi
    # Tell dispatch_once to stop this attempt. Returning success here would
    # continue prompt creation and launch an agent after the claim was requeued.
    return 1
  fi

  log "dispatch: posted in-progress comment for $comment_id"
  log "dispatch: TASK_STARTED embedded in in-progress comment for $comment_id"
  return 0
}



# Publish terminal failures through the shared feedback handler so all failure
# paths produce the same TASK_FAILED event and preserve issue/review-thread routing.
post_task_failure_feedback() {
  local repo="$1" issue_num="$2" comment_id="$3" error="$4" pr_number="${5:-}" stage="${6:-task_execution}"
  if [[ "$issue_num" =~ ^0+$ ]]; then
    lc_log "EXTERNAL_SOURCE_FAILURE_FEEDBACK_SUPPRESSED" "task=$comment_id stage=$stage"
    return 0
  fi
  error="$(manul_redact_failure_details "$error")"
  local args=(post-failed --repo "$repo" --issue "$issue_num" --comment-id "$comment_id" --task-id "$comment_id" --error "$error" --stage "$stage")

  if [[ "$comment_id" =~ ^review:[0-9]+$ ]] && ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pr_number="$issue_num"
  fi
  if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    args+=(--pr-number "$pr_number")
  fi

  if [ "$MANUL_MODE" = "human" ]; then
    lc_log "TASK_FAILURE_COMMENT_SUPPRESSED" "task=$comment_id repo=$repo issue=$issue_num mode=human"
    return 0
  fi

  local post_attempt
  for post_attempt in 1 2 3; do
    if MANUL_DIR="$MANUL_DIR" bash "$DAEMON_SCRIPT_DIR/manul-result-feedback.sh" "${args[@]}" >>"$LOG" 2>&1; then
      lc_log "TASK_FAILURE_COMMENT_CONFIRMED" "task=$comment_id repo=$repo issue=$issue_num stage=$stage try=$post_attempt outcome=posted_or_deduplicated"
      return 0
    fi
    log "WARN: failed to post terminal failure comment for $comment_id (try=$post_attempt/3)"
    if [ "$post_attempt" -lt 3 ]; then sleep "$post_attempt"; fi
  done
  lc_log "TASK_FAILURE_COMMENT_FAILED" "task=$comment_id repo=$repo issue=$issue_num reason=github_post_failed"
  return 1
}

# Finish a pre-execution failure through the same attempt/ownership state machine
# as agent failures. This prevents early workspace/repository errors from leaving
# tasks running until the watchdog silently marks them failed.
handle_pre_execution_failure() {
  local comment_id="$1" claim_token="$2" repo="$3" issue_num="$4"
  local workspace_id="${5:-}" reply_to="${6:-}" reason="$7" pr_number="${8:-}" attempt_fallback="${9:-1}" failure_stage="${10:-pre_execution}"
  local attempts infra_failures max_infra_failures target_status safe_id safe_token
  reason="$(manul_redact_failure_details "$reason")"
  ensure_recovery_tracking_columns || {
    log "ERROR: cannot migrate recovery counters while handling pre-agent failure for $comment_id"
    release_task_lock
    return 1
  }

  safe_id="$(sql_escape "$comment_id")"
  safe_token="$(sql_escape "$claim_token")"
  local row
  row="$(sqlite3 "$DB" "SELECT COALESCE(attempts,0) || '|' || COALESCE(preExecutionFailures,0) FROM processed_comments WHERE commentId='$safe_id' AND status='running' AND claimToken='$safe_token' LIMIT 1;" 2>/dev/null || true)"
  if [ -z "$row" ]; then
    log "ERROR: pre-agent recovery refused for $comment_id because this claim no longer owns the running row"
    lc_log "RECOVERY_SKIPPED" "task=$comment_id reason=pre_execution_claim_mismatch"
    release_task_lock
    return 1
  fi
  IFS='|' read -r attempts infra_failures <<< "$row"
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts="$attempt_fallback"
  [[ "$infra_failures" =~ ^[0-9]+$ ]] || infra_failures=0

  max_infra_failures="$(jq -r '.automation.maxPreExecutionFailures // 8' "$CONFIG" 2>/dev/null || echo 8)"
  if ! [[ "$max_infra_failures" =~ ^[0-9]+$ ]] || [ "$max_infra_failures" -lt 1 ]; then max_infra_failures=8; fi
  infra_failures=$((infra_failures + 1))
  if [ "$infra_failures" -ge "$max_infra_failures" ]; then target_status="failed"; else target_status="queued"; fi

  # Preparation failures are not agent executions. Atomically release the claim,
  # decrement the claim-time attempt bump, and charge the separate bounded infra
  # counter so repeated checkout/runtime setup failures cannot consume agent budget.
  local changed
  changed="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000;
    UPDATE processed_comments
    SET status='$target_status',
        attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END,
        preExecutionFailures=$infra_failures,
        agentStartedAt=NULL,
        processedAt=CASE WHEN '$target_status'='failed' THEN datetime('now') ELSE NULL END,
        heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL,
        nextAttemptAt=CASE WHEN '$target_status'='queued' THEN datetime('now','+${RETRY_DELAY_SECONDS} seconds') ELSE NULL END
    WHERE commentId='$safe_id' AND status='running' AND claimToken='$safe_token';
    SELECT changes();" 2>>"$LOG" | tail -n 1)" || changed="0"
  if [ "$changed" != "1" ]; then
    log "ERROR: could not finalize pre-execution infrastructure failure for $comment_id (changes=${changed:-unknown})"
    lc_log "TASK_ERROR" "task=$comment_id reason=pre_execution_finalization_failed"
    release_task_lock
    return 1
  fi

  stop_heartbeat "$comment_id"
  if [ -n "$workspace_id" ]; then
    workspace_release "$workspace_id" "$comment_id" || log "WARN: workspace release after pre-execution failure did not match task $comment_id"
  fi
  release_task_repo_lock "$repo"
  release_task_lock
  set_activity "none" "idle"

  local execution_attempts="$(( attempts > 0 ? attempts - 1 : 0 ))"
  if [ "$target_status" = "failed" ]; then
    log "dispatch: task $comment_id failed before agent startup after $infra_failures/$max_infra_failures infrastructure failures (agent attempts remain $execution_attempts): $reason"
    lc_log "TASK_FAILED" "task=$comment_id repo=$repo issue=$issue_num infra_failures=$infra_failures max_infra_failures=$max_infra_failures agent_attempts=$execution_attempts reason=$reason"
    post_task_failure_feedback "$repo" "$issue_num" "$comment_id" "Task exhausted $infra_failures/$max_infra_failures pre-execution infrastructure failures before the agent started. Agent execution attempts are tracked separately. Reason: $reason" "$pr_number" "$failure_stage" || true
  else
    local retry_comment="⚠️ Manul could not start the agent; infrastructure preparation failure $infra_failures/$max_infra_failures. Agent execution attempt budget is unchanged. Reason: $reason"
    log "dispatch: task $comment_id requeued after pre-execution infrastructure failure ($infra_failures/$max_infra_failures); agent attempt count unchanged at $execution_attempts: $reason"
    lc_log "TASK_REQUEUED" "task=$comment_id repo=$repo issue=$issue_num infra_failures=$infra_failures max_infra_failures=$max_infra_failures agent_attempts=$execution_attempts reason=$reason"
    post_lifecycle_comment "$repo" "$issue_num" "$retry_comment" "$reply_to" || log "WARN: failed to post retry comment for $comment_id"
  fi
  return 0
}

# Repair the invisible attempt marker only when one unique result comment for this
# exact task was created after the current attempt started. Agents occasionally copy
# a stale attempt number from a previous GitHub comment; editing that marker in place
# preserves the one-result-comment contract while keeping stale earlier-attempt
# comments ineligible for success.
repair_result_comment_marker() {
  local repo="$1" issue="$2" comment_id="$3" safe_comment_id="$4" attempt="$5"
  local safe_key comment_url agent_started_at url_issue_num started_epoch
  local marker marker_prefix result_endpoint result_filter patch_collection reply_to_id
  local tmpdir comments_file candidate response_file candidate_count
  local body created_at candidate_epoch marker_tail candidate_attempt candidate_id
  local selected_body selected_id selected_attempt old_marker repaired_body request_file

  [[ "$attempt" =~ ^[0-9]+$ ]] || return 1
  safe_key="$(sql_escape "$safe_comment_id")"
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_key';" 2>/dev/null)"
  agent_started_at="$(sqlite3 "$DB" "SELECT COALESCE(agentStartedAt,'') FROM processed_comments WHERE commentId='$safe_key';" 2>/dev/null)"
  [ -n "$comment_url" ] && [ -n "$agent_started_at" ] || return 1
  url_issue_num="$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || true)"
  [ -n "$url_issue_num" ] || return 1
  started_epoch="$(date -u -d "$agent_started_at" +%s 2>/dev/null || true)"
  [[ "$started_epoch" =~ ^[0-9]+$ ]] || return 1

  marker="<!-- manul-task:${comment_id}:attempt:${attempt} -->"
  marker_prefix="<!-- manul-task:${comment_id}:attempt:"
  if [[ "$comment_url" == *"/pull/"*"#discussion_r"* ]] || [[ "$comment_id" =~ ^review:[0-9]+$ ]]; then
    reply_to_id="$(printf '%s' "$comment_url" | sed -nE 's/.*#discussion_r([0-9]+).*/\1/p')"
    [[ "$reply_to_id" =~ ^[0-9]+$ ]] || return 1
    result_endpoint="repos/$repo/pulls/$url_issue_num/comments"
    result_filter=".[] | select(.in_reply_to_id == $reply_to_id) | {id,created_at,body:(.body // \"\")} | tojson"
    patch_collection="pulls/comments"
  else
    result_endpoint="repos/$repo/issues/$url_issue_num/comments"
    result_filter='.[] | {id,created_at,body:(.body // "")} | tojson'
    patch_collection="issues/comments"
  fi

  tmpdir="$(mktemp -d)" || return 1
  comments_file="$tmpdir/comments.jsonl"
  response_file="$tmpdir/patch-response.json"
  request_file="$tmpdir/patch-request.json"
  if ! timeout "${GH_API_TIMEOUT:-30}" gh api "$result_endpoint" --paginate --jq "$result_filter" 2>>"$LOG" >"$comments_file"; then
    log "WARN: result-marker repair could not list comments for task $comment_id attempt $attempt"
    rm -rf "$tmpdir"
    return 1
  fi

  candidate_count=0
  selected_body=""
  selected_id=""
  selected_attempt=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    body="$(printf '%s' "$candidate" | jq -r '.body // ""' 2>/dev/null)"
    [[ "$body" == '🔄'* || "$body" == '✅'* || "$body" == '❌'* || "$body" == '⚠️'* ]] && continue
    # Only repair a comment that follows the established Manul result-signature
    # contract; never rewrite a user's arbitrary prose even if it quotes a marker.
    [[ "$body" == *"— manul 🐈"* ]] || continue
    [[ "$body" == *"$marker_prefix"* ]] || continue

    marker_tail="${body#*"$marker_prefix"}"
    candidate_attempt="${marker_tail%% -->*}"
    [[ "$candidate_attempt" =~ ^[0-9]+$ ]] || continue
    [ "$candidate_attempt" -lt "$attempt" ] || continue

    created_at="$(printf '%s' "$candidate" | jq -r '.created_at // ""' 2>/dev/null)"
    candidate_epoch="$(date -u -d "$created_at" +%s 2>/dev/null || true)"
    [[ "$candidate_epoch" =~ ^[0-9]+$ ]] || continue
    # The timestamp guard prevents a previous attempt's legitimate result from
    # being mistaken for the current agent's comment.
    [ "$candidate_epoch" -gt "$started_epoch" ] || continue

    candidate_id="$(printf '%s' "$candidate" | jq -r '.id // empty' 2>/dev/null)"
    [[ "$candidate_id" =~ ^[0-9]+$ ]] || continue
    candidate_count=$((candidate_count + 1))
    selected_body="$body"
    selected_id="$candidate_id"
    selected_attempt="$candidate_attempt"
  done < "$comments_file"

  if [ "$candidate_count" -ne 1 ]; then
    rm -rf "$tmpdir"
    return 1
  fi

  old_marker="<!-- manul-task:${comment_id}:attempt:${selected_attempt} -->"
  [[ "$selected_body" == *"$old_marker"* ]] || { rm -rf "$tmpdir"; return 1; }
  repaired_body="${selected_body/"$old_marker"/"$marker"}"
  printf '%s' "$repaired_body" | jq -Rs '{body:.}' >"$request_file"

  if ! timeout "${GH_API_TIMEOUT:-30}" gh api "repos/$repo/$patch_collection/$selected_id" --method PATCH --input - <"$request_file" >"$response_file" 2>>"$LOG"; then
    log "ERROR: result-marker repair failed to update comment $selected_id for task $comment_id"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! jq -e --arg marker "$marker" '(.body // "") | contains($marker)' "$response_file" >/dev/null 2>&1; then
    log "ERROR: result-marker repair response did not confirm marker for task $comment_id attempt $attempt"
    rm -rf "$tmpdir"
    return 1
  fi

  log "verify_result_comment: repaired stale marker attempt=$selected_attempt to current attempt=$attempt in existing comment $selected_id for task $comment_id"
  lc_log "RESULT_MARKER_REPAIRED" "task=$comment_id repo=$repo issue=$url_issue_num previous_attempt=$selected_attempt attempt=$attempt comment_id=$selected_id"
  rm -rf "$tmpdir"
  return 0
}

# Verify the agent posted a result comment to GitHub for THIS exact task/attempt.
# Uses deterministic task/attempt marker: <!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->
# Fails closed on any error (missing commentUrl, API failure, no matching comment).
# Rejects lifecycle comments (🔄, ✅, ❌, ⚠️) — they share the signature but lack the marker.
verify_result_comment() {
  local repo="$1"
  local issue="$2"
  local comment_id="$3"
  local safe_comment_id="$4"
  local attempt="$5"

  # Get the task's commentUrl for correlation
  local comment_url
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"

  if [ -z "$comment_url" ]; then
    log "ERROR: verify_result_comment: missing commentUrl for task $comment_id — fail-closed"
    lc_log "RESULT_VERIFY_ERROR" "task=$comment_id reason=missing_commentUrl"
    return 1
  fi

  # Extract issue/PR number from commentUrl
  local url_issue_num
  url_issue_num="$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || echo "")"
  if [ -z "$url_issue_num" ]; then
    log "ERROR: verify_result_comment: could not extract issue number from commentUrl=$comment_url — fail-closed"
    lc_log "RESULT_VERIFY_ERROR" "task=$comment_id reason=unextractable_issue_number"
    return 1
  fi

  # Deterministic task/attempt marker
  local marker
  marker="<!-- manul-task:${comment_id}:attempt:${attempt} -->"

  # Use temp files to avoid pipe deadlock (gh api --paginate can block indefinitely)
  local tmpdir
  tmpdir="$(mktemp -d)"

   local comments_file="$tmpdir/comments.json"
  local bodies_file="$tmpdir/bodies.txt"
  local result_count=0

  # Result comments for inline PR review tasks live in the PR review-comments
  # endpoint, not the Issue/PR conversation endpoint. Use the same source
  # collection for verification that is used for posting the result.
  local result_endpoint
  local result_filter
  local result_scope
  local result_reply_to_id=""
  if [[ "$comment_url" == *"/pull/"*"#discussion_r"* ]] || [[ "$comment_id" =~ ^review:[0-9]+$ ]]; then
    result_reply_to_id="$(printf '%s' "$comment_url" | sed -nE 's/.*#discussion_r([0-9]+).*/\1/p')"
    if [ -z "$result_reply_to_id" ] && [[ "$comment_id" =~ ^review:([0-9]+)$ ]]; then
      result_reply_to_id="${BASH_REMATCH[1]}"
    fi
    if ! [[ "$result_reply_to_id" =~ ^[0-9]+$ ]]; then
      log "ERROR: verify_result_comment: review task $comment_id has no numeric source-thread ID — fail-closed"
      lc_log "RESULT_VERIFY_ERROR" "task=$comment_id reason=missing_review_thread_id"
      rm -rf "$tmpdir"
      return 1
    fi
    result_endpoint="repos/$repo/pulls/$url_issue_num/comments"
    result_filter=".[] | select((.in_reply_to_id // \"\") | tostring == \"$result_reply_to_id\") | .body // \"\" | gsub(\"\\n\"; \"\\\\n\")"
    result_scope="review-thread:$result_reply_to_id"
  else
    result_endpoint="repos/$repo/issues/$url_issue_num/comments"
    result_filter='.[] | select(.in_reply_to_id == null) | .body // "" | gsub("\n"; "\\n")'
    result_scope="top-level"
  fi

  log "verify_result_comment: checking $result_scope result collection for task $comment_id"

  timeout "${GH_API_TIMEOUT}" gh api "$result_endpoint" \
    --paginate \
    --jq "$result_filter" \
    2>>"$LOG" > "$bodies_file" || {
      local api_rc=$?
      if [ "$api_rc" -eq 124 ]; then
        log "ERROR: verify_result_comment: gh api timed out after ${GH_API_TIMEOUT}s — fail-closed"
        lc_log "API_TIMEOUT" "task=$comment_id repo=$repo endpoint=$result_endpoint timeout=${GH_API_TIMEOUT}s"
      else
        log "ERROR: verify_result_comment: gh api failed with exit code $api_rc — fail-closed"
        lc_log "API_FAILURE" "task=$comment_id repo=$repo endpoint=$result_endpoint exit_code=$api_rc"
      fi
      rm -rf "$tmpdir"
      return 1
    }

  while IFS= read -r body; do
    if [[ "$body" == '🔄'* ]] || [[ "$body" == '✅'* ]] || [[ "$body" == '❌'* ]] || [[ "$body" == '⚠️'* ]]; then
      continue
    fi
    if [[ "$body" == *"$marker"* ]]; then
      result_count=$((result_count + 1))
    fi
  done < "$bodies_file"

  if [ "$result_count" -gt 1 ]; then
    log "ERROR: verify_result_comment: multiple result comments with same marker for task $comment_id attempt $attempt on $repo#$url_issue_num — reject duplicates"
    lc_log "DUPLICATE_RESULT_COMMENT" "task=$comment_id repo=$repo issue=$url_issue_num attempt=$attempt count=$result_count scope=$result_scope"
    rm -rf "$tmpdir"
    return 1
  fi

  if [ "$result_count" -gt 0 ]; then
    log "verify_result_comment: found result comment for task $comment_id attempt $attempt on $repo#$url_issue_num scope=$result_scope"
    rm -rf "$tmpdir"
    return 0
  fi

  rm -rf "$tmpdir"

  # Last-resort recovery for the known LLM failure mode: a unique result comment
  # for this task was posted by the current execution but copied an older attempt
  # number. The helper repairs the invisible marker in-place only after checking
  # task identity, unique candidate count, and the current agentStartedAt window.
  if repair_result_comment_marker "$repo" "$issue" "$comment_id" "$safe_comment_id" "$attempt"; then
    log "verify_result_comment: recovered result comment with stale attempt marker for task $comment_id attempt $attempt"
    return 0
  fi

  log "ERROR: verify_result_comment: no result comment with marker '$marker' found for task $comment_id attempt $attempt on $repo#$url_issue_num"
  return 1
}

# Verify a task-correlated result comment contains meaningful user-facing content.
# The exact task/attempt marker is checked independently by verify_result_comment().
verify_nonempty_result_comment() {
  local repo="$1" issue="$2" comment_id="$3" safe_comment_id="$4" attempt="$5"
  local comment_url url_issue_num endpoint marker tmpdir bodies_file body clean result_filter
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$(sql_escape "$safe_comment_id")';" 2>/dev/null)"
  [ -n "$comment_url" ] || return 1
  url_issue_num="$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || true)"
  [ -n "$url_issue_num" ] || return 1
  marker="<!-- manul-task:${comment_id}:attempt:${attempt} -->"
  if [[ "$comment_url" == *"/pull/"*"#discussion_r"* ]] || [[ "$comment_id" =~ ^review:[0-9]+$ ]]; then
    local result_reply_to_id
    result_reply_to_id="$(printf '%s' "$comment_url" | sed -nE 's/.*#discussion_r([0-9]+).*/\1/p')"
    if [ -z "$result_reply_to_id" ] && [[ "$comment_id" =~ ^review:([0-9]+)$ ]]; then
      result_reply_to_id="${BASH_REMATCH[1]}"
    fi
    [[ "$result_reply_to_id" =~ ^[0-9]+$ ]] || return 1
    endpoint="repos/$repo/pulls/$url_issue_num/comments"
    result_filter=".[] | select((.in_reply_to_id // \"\") | tostring == \"$result_reply_to_id\") | .body // \"\" | gsub(\"\\n\"; \" \")"
  else
    endpoint="repos/$repo/issues/$url_issue_num/comments"
    result_filter='.[] | select(.in_reply_to_id == null) | .body // "" | gsub("\n"; " ")'
  fi
  tmpdir="$(mktemp -d)" || return 1
  bodies_file="$tmpdir/result-bodies.txt"
  if ! timeout "${GH_API_TIMEOUT}" gh api "$endpoint" --paginate --jq "$result_filter" >"$bodies_file" 2>>"$LOG"; then
    rm -rf "$tmpdir"
    return 1
  fi
  body="$(grep -F "$marker" "$bodies_file" | head -n 1 || true)"
  clean="$(printf '%s\n' "$body" | sed "s|$marker||g; s/— manul 🐈//g" | sed '/^[[:space:]]*$/d')"
  rm -rf "$tmpdir"
  [ -n "$clean" ]
}

# Check whether a concrete GitHub PR exists for the given branch against base.
# Returns 0 if a real PR exists, 1 otherwise.
# A /pull/new/... or /compare/... URL returned by the agent is NOT a concrete PR.
pr_check_existing() {
  local repo="$1" branch="$2" expected_base="${3:-}"
  local pr_json api_rc
  pr_json="$(timeout "$GH_API_TIMEOUT" gh pr list --repo "$repo" --state all --head "$branch" --json number,url,state,baseRefName,headRefName --limit 10 2>>"$LOG")"
  api_rc=$?
  if [ "$api_rc" -ne 0 ]; then
    if [ "$api_rc" -eq 124 ]; then
      log "ERROR: pr_check_existing: gh pr list timed out after ${GH_API_TIMEOUT}s"
      lc_log "PR_VERIFY_ERROR" "repo=$repo reason=api_timeout timeout=${GH_API_TIMEOUT}s"
    else
      log "ERROR: pr_check_existing: gh pr list failed with exit code $api_rc"
      lc_log "PR_VERIFY_ERROR" "repo=$repo reason=api_failure exit_code=$api_rc"
    fi
    return 1
  fi
  if [ -n "$expected_base" ]; then
    if [ -n "$pr_json" ] && printf '%s' "$pr_json" | jq -e --arg expected "$expected_base" 'type == "array" and length > 0 and any(.[]; .baseRefName == $expected)' >/dev/null 2>&1; then return 0; fi
    log "WARN: pr_check_existing: PR found for $repo/$branch but none targets expected base '$expected_base'"
    return 1
  fi
  [ -n "$pr_json" ] && jq -e 'type == "array" and length > 0' <<<"$pr_json" >/dev/null 2>&1
}

# Auto-create a GitHub PR for the given branch against the default branch.
# Used when autoCreatePr is enabled and the agent pushed its branch but did not
# itself open a PR (e.g. it only returned a /compare/... URL).
# Returns 0 on success, 1 on failure.
pr_auto_create() {
  local repo="$1" branch="$2" base_branch="$3" comment_id="$4" workdir="$5"
  local title body pr_url api_rc remote

  # Best-effort: ensure the branch is present on the remote before creating a PR.
  remote="$(git -C "$workdir" remote 2>/dev/null | head -1 || echo "")"
  if [ -n "$remote" ]; then
    if ! git -C "$workdir" ls-remote --heads "$remote" "$branch" 2>/dev/null | grep -q "$branch"; then
      log "pr_auto_create: pushing branch $branch to remote $remote before PR creation"
      if ! git -C "$workdir" push "$remote" "$branch" 2>>"$LOG"; then
        log "WARN: pr_auto_create: failed to push branch $branch to $remote (continuing to gh pr create)"
      fi
    fi
  fi

  # Derive a sensible PR title from the latest commit, falling back to the branch name.
  title="$(git -C "$workdir" log -1 --pretty=%s 2>/dev/null || echo "$branch")"
  title="${title:0:120}"
  [ -n "$title" ] || title="$branch"

  body="Automatically created by Manul for task $comment_id."

  local pr_create_output
  pr_create_output="$(timeout "$GH_API_TIMEOUT" gh pr create --repo "$repo" --base "$base_branch" --head "$branch" --title "$title" --body "$body" 2>>"$LOG")"
  api_rc=$?
  if [ "$api_rc" -ne 0 ]; then
    if [ "$api_rc" -eq 124 ]; then
      log "ERROR: pr_auto_create: gh pr create timed out after ${GH_API_TIMEOUT}s for branch $branch"
      lc_log "PR_CREATE_ERROR" "task=$comment_id repo=$repo branch=$branch reason=timeout timeout=${GH_API_TIMEOUT}s"
    else
      log "ERROR: pr_auto_create: gh pr create failed with exit code $api_rc for branch $branch"
      lc_log "PR_CREATE_ERROR" "task=$comment_id repo=$repo branch=$branch reason=exit_code exit_code=$api_rc"
    fi
    return 1
  fi

  pr_url="$(printf '%s' "$pr_create_output" | tr -d '[:space:]')"
  # gh pr create returning 0 is not sufficient: the output can be malformed,
  # stale, or a create/compare URL. Re-query GitHub and require a real PR with
  # the expected head and base before treating creation as successful.
  if ! pr_check_existing "$repo" "$branch" "$base_branch"; then
    log "ERROR: pr_auto_create: gh pr create returned success but GitHub has no verified PR for $branch -> $pr_url"
    lc_log "PR_CREATE_ERROR" "task=$comment_id repo=$repo branch=$branch base=$base_branch reason=post_create_verification_failed"
    return 1
  fi
  log "pr_auto_create: verified created PR for branch $branch against $base_branch -> $pr_url"
  lc_log "PR_CREATE_SUCCESS" "task=$comment_id repo=$repo branch=$branch base=$base_branch url=$pr_url"
  return 0
}

# Verify that a repository-change task has a real PR against the branch that
# the agent actually based its task branch on. A /pull/new/... or /compare/...
# URL is NOT a concrete PR — only a real PR (verified via the GitHub API) counts.
#
# autoCreatePr controls ONLY whether the daemon creates the PR itself when the
# agent pushed its branch but did not open a PR (e.g. it returned a
# /compare/... URL instead of a PR). It must NOT mask the requirement: when no
# PR exists and autoCreatePr is false, the task still fails.
# Verify an already-existing implementation PR when a retry's agent has
# returned to the base branch without creating new commits. Do not trust the
# agent's report comment alone: require a real GitHub PR against the expected
# base, a live remote head matching the PR SHA, and task/issue correlation.
# Correlation is either the exact current task ID in the PR body or a previously
# completed task for the same repository/issue whose persisted verified PR URL
# matches this candidate. This supports retries that reach an existing deliverable
# through a different trigger comment without weakening the normal branch guard.
VERIFIED_EXISTING_PR_BRANCH=""
VERIFIED_EXISTING_PR_URL=""
verify_existing_task_pr() {
  local repo="$1" comment_id="$2" workdir="$3" initial_base_branch="$4"
  local safe_comment_id comment_url issue_num safe_repo prior_urls prior_urls_json
  local pr_json verified verified_head_sha remote_head

  VERIFIED_EXISTING_PR_BRANCH=""
  VERIFIED_EXISTING_PR_URL=""
  safe_comment_id="$(sql_escape "$comment_id")"
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null)"
  issue_num="$(printf '%s' "$comment_url" | grep -oE '/(issues|pull)/[0-9]+' | grep -oE '[0-9]+' | head -n 1)"
  prior_urls_json='[]'
  if [[ "$issue_num" =~ ^[0-9]+$ ]]; then
    safe_repo="$(sql_escape "$repo")"
    prior_urls="$(sqlite3 "$DB" "SELECT prUrl FROM processed_comments WHERE repository='$safe_repo' AND status='completed' AND commentId!='$safe_comment_id' AND COALESCE(prUrl,'')!='' AND (issueNumber=$issue_num OR commentUrl LIKE '%/issues/$issue_num#%' OR commentUrl LIKE '%/pull/$issue_num#%' OR commentUrl LIKE '%/issues/$issue_num' OR commentUrl LIKE '%/pull/$issue_num');" 2>/dev/null || true)"
    prior_urls_json="$(printf '%s\n' "$prior_urls" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"
  fi

  pr_json="$(timeout "$GH_API_TIMEOUT" gh pr list --repo "$repo" --state all --json number,url,state,baseRefName,headRefName,body,headRefOid --limit 100 2>>"$LOG")" || {
    log "ERROR: verify_existing_task_pr: GitHub PR query failed for $repo task=$comment_id"
    lc_log "PR_VERIFY_ERROR" "task=$comment_id repo=$repo reason=api_failure"
    return 1
  }

  # A candidate must identify the current task explicitly, or match the PR URL
  # persisted by an earlier completed task for this exact repository/issue.
  verified="$(printf '%s' "$pr_json" | jq -c --arg task "$comment_id" --arg base "$initial_base_branch" --argjson priorUrls "$prior_urls_json" '
    if type != "array" then empty else
      map(select(.baseRefName == $base)
          | select(.headRefName != $base)
          | select((.headRefOid // "") != "")
          | select((.url // "") != "")
          | (.url) as $candidateUrl
          | select(((.body // "") | contains("task " + $task)) or (($priorUrls | index($candidateUrl)) != null)))
      | .[0] // empty
    end' 2>/dev/null)"
  [ -n "$verified" ] || {
    log "verify_existing_task_pr: no PR correlated to task=$comment_id issue=${issue_num:-unknown} base=$initial_base_branch"
    return 1
  }

  VERIFIED_EXISTING_PR_BRANCH="$(printf '%s' "$verified" | jq -r '.headRefName // empty')"
  VERIFIED_EXISTING_PR_URL="$(printf '%s' "$verified" | jq -r '.url // empty')"
  verified_head_sha="$(printf '%s' "$verified" | jq -r '.headRefOid // empty')"
  [ -n "$VERIFIED_EXISTING_PR_BRANCH" ] && [ -n "$VERIFIED_EXISTING_PR_URL" ] && [ -n "$verified_head_sha" ] || return 1

  remote_head="$(git -C "$workdir" ls-remote --heads origin "$VERIFIED_EXISTING_PR_BRANCH" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [ -z "$remote_head" ] || [ "$remote_head" != "$verified_head_sha" ]; then
    log "verify_existing_task_pr: remote head mismatch for $VERIFIED_EXISTING_PR_BRANCH (remote=${remote_head:-missing} pr=$verified_head_sha)"
    VERIFIED_EXISTING_PR_BRANCH=""
    VERIFIED_EXISTING_PR_URL=""
    return 1
  fi

  log "verify_existing_task_pr: verified existing PR $VERIFIED_EXISTING_PR_URL for task=$comment_id branch=$VERIFIED_EXISTING_PR_BRANCH base=$initial_base_branch"
  return 0
}

# Verify a previously reported, now-merged task PR when a retry ends on a base
# branch. Only accept this recovery path when the source issue is closed and
# the current attempt's own result comment links to a real merged PR in the
# initial or repository-default base. A deleted remote head branch is expected
# after merge and is not required as evidence.
VERIFIED_MERGED_RESULT_PR_BASE=""
verify_merged_result_pr() {
  local repo="$1" issue_num="$2" comment_id="$3" attempt="$4"
  local initial_base="$5" default_branch="$6"
  local issue_state comments_json marker matching_comments match_count result_body
  local candidate_urls candidate_url pr_number pr_json verified_pr

  VERIFIED_EXISTING_PR_BRANCH=""
  VERIFIED_EXISTING_PR_URL=""
  VERIFIED_MERGED_RESULT_PR_BASE=""

  [[ "$issue_num" =~ ^[0-9]+$ ]] || return 1
  [ -n "$comment_id" ] && [[ "$attempt" =~ ^[0-9]+$ ]] || return 1

  issue_state="$(timeout "$GH_API_TIMEOUT" gh api "repos/$repo/issues/$issue_num" --jq '.state' 2>>"$LOG")" || {
    log "WARN: verify_merged_result_pr: source issue state query failed for $repo#$issue_num"
    return 1
  }
  if [ "$issue_state" != "closed" ]; then
    log "verify_merged_result_pr: source issue $repo#$issue_num is not closed; merged-result recovery declined"
    return 1
  fi

  comments_json="$(timeout "$GH_API_TIMEOUT" gh api "repos/$repo/issues/$issue_num/comments" --paginate --slurp 2>>"$LOG")" || {
    log "WARN: verify_merged_result_pr: result-comment query failed for $repo#$issue_num"
    return 1
  }

  marker="<!-- manul-task:${comment_id}:attempt:${attempt} -->"
  matching_comments="$(printf '%s' "$comments_json" | jq -c --arg marker "$marker" '[.[][] | select(.body != null and (.body | contains($marker)))]' 2>/dev/null || echo '[]')"
  match_count="$(printf '%s' "$matching_comments" | jq -r 'length' 2>/dev/null || echo 0)"
  if [ "$match_count" != "1" ]; then
    log "verify_merged_result_pr: expected exactly one result comment for task=$comment_id attempt=$attempt, found ${match_count:-0}"
    return 1
  fi

  result_body="$(printf '%s' "$matching_comments" | jq -r '.[0].body // ""' 2>/dev/null || true)"
  candidate_urls="$(printf '%s' "$result_body" | grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | sort -u || true)"
  [ -n "$candidate_urls" ] || {
    log "verify_merged_result_pr: current result comment has no canonical PR URL for task=$comment_id attempt=$attempt"
    return 1
  }

  while IFS= read -r candidate_url; do
    [ -n "$candidate_url" ] || continue
    case "$candidate_url" in
      "https://github.com/$repo/pull/"*) ;;
      *) continue ;;
    esac
    pr_number="${candidate_url##*/}"
    [[ "$pr_number" =~ ^[0-9]+$ ]] || continue

    pr_json="$(timeout "$GH_API_TIMEOUT" gh pr view "$pr_number" --repo "$repo" --json url,state,baseRefName,headRefName,headRefOid,mergedAt 2>>"$LOG")" || {
      log "WARN: verify_merged_result_pr: could not verify PR #$pr_number for task=$comment_id"
      continue
    }
    verified_pr="$(printf '%s' "$pr_json" | jq -c       --arg url "$candidate_url"       --arg initial "$initial_base"       --arg default "$default_branch" '
        select(.url == $url and .state == "MERGED"
          and ((.baseRefName // "") == $initial or (.baseRefName // "") == $default)
          and (.headRefName // "") != ""
          and (.headRefName != .baseRefName)
          and (.headRefOid // "") != ""
          and (.mergedAt // "") != "")
      ' 2>/dev/null || true)"
    [ -n "$verified_pr" ] || continue

    VERIFIED_EXISTING_PR_BRANCH="$(printf '%s' "$verified_pr" | jq -r '.headRefName')"
    VERIFIED_EXISTING_PR_URL="$(printf '%s' "$verified_pr" | jq -r '.url')"
    VERIFIED_MERGED_RESULT_PR_BASE="$(printf '%s' "$verified_pr" | jq -r '.baseRefName')"
    log "verify_merged_result_pr: verified merged PR $VERIFIED_EXISTING_PR_URL for closed issue $repo#$issue_num task=$comment_id base=$VERIFIED_MERGED_RESULT_PR_BASE"
    lc_log "MERGED_RESULT_PR_VERIFIED" "task=$comment_id repo=$repo issue=$issue_num url=$VERIFIED_EXISTING_PR_URL base=$VERIFIED_MERGED_RESULT_PR_BASE"
    return 0
  done <<< "$candidate_urls"

  log "verify_merged_result_pr: no merged PR in current task result matched repository and allowed base for $repo#$issue_num"
  return 1
}

verify_required_pr() {
  local repo="$1" comment_id="$2" workdir="$3" initial_base_branch="$4"
  local auto_create_pr
  auto_create_pr="$(jq -r '.autoCreatePr // false' "$CONFIG" 2>/dev/null || echo false)"
  local safe_comment_id="$(sql_escape "$comment_id")"
  local action
  action="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null)"
  # Legacy tasks may have a NULL/empty action because the action column was
  # introduced after the task was queued. Standalone issue/comment tasks are
  # implementation tasks by default; only an explicit non-IMPLEMENT action
  # (e.g. REVIEW_FIX) opts out of standalone PR verification.
  action="${action:-IMPLEMENT}"
  [ "$action" = "IMPLEMENT" ] || return 0
  local comment_url
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null)"
  [[ "$comment_url" == *"/pull/"* ]] && return 0
  local branch
  branch="$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)"
  if [ -z "$branch" ] || [ "$branch" = "$initial_base_branch" ]; then
    log "ERROR: verify_required_pr: invalid task branch for $comment_id (branch=$branch initial_base=$initial_base_branch)"
    lc_log "PR_VERIFY_ERROR" "task=$comment_id repo=$repo reason=invalid_task_branch branch=$branch base=$initial_base_branch"
    return 1
  fi
  local expected_base
  expected_base="$(infer_task_base_branch "$workdir" "$branch" "$initial_base_branch")"
  log "verify_required_pr: task $comment_id branch=$branch expected_base=$expected_base"
  if pr_check_existing "$repo" "$branch" "$expected_base"; then
    log "verify_required_pr: found PR for task $comment_id branch=$branch base=$expected_base"
    return 0
  fi
  if [ "$auto_create_pr" = "true" ]; then
    log "verify_required_pr: no PR for branch $branch; auto-creating PR against $expected_base"
    lc_log "PR_CREATE_ATTEMPT" "task=$comment_id repo=$repo branch=$branch base=$expected_base"
    if pr_auto_create "$repo" "$branch" "$expected_base" "$comment_id" "$workdir"; then
      log "verify_required_pr: PR auto-created for task $comment_id branch=$branch base=$expected_base"
      return 0
    fi
  fi
  log "ERROR: verify_required_pr: no PR found for branch $branch against expected base $expected_base"
  lc_log "MISSING_PR" "task=$comment_id repo=$repo branch=$branch base=$expected_base"
  return 1
}

# Persist the canonical PR identity once the daemon has verified that the PR
# belongs to this task's branch/base. Issue tasks initially use the issue number
# in prNumber for backward-compatible queue ingestion, so this correction must
# happen before TASK_DONE feedback is emitted.
persist_verified_pr_metadata() {
  local comment_id="$1" pr_number="$2" pr_url="$3"
  local safe_comment_id safe_pr_url changes

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]] || [ "$pr_number" -lt 1 ]; then
    log "ERROR: persist_verified_pr_metadata: invalid PR number '$pr_number' for task $comment_id"
    lc_log "PR_METADATA_ERROR" "task=$comment_id reason=invalid_pr_number pr_number=$pr_number"
    return 1
  fi
  if [[ "$pr_url" != https://github.com/*/pull/* ]]; then
    log "ERROR: persist_verified_pr_metadata: invalid canonical PR URL '$pr_url' for task $comment_id"
    lc_log "PR_METADATA_ERROR" "task=$comment_id reason=invalid_pr_url"
    return 1
  fi

  safe_comment_id="$(sql_escape "$comment_id")"
  safe_pr_url="$(sql_escape "$pr_url")"
  changes="$(sqlite3 "$DB" "UPDATE processed_comments SET prNumber=$pr_number, prUrl='$safe_pr_url' WHERE commentId='$safe_comment_id'; SELECT changes();" 2>>"$LOG" | tail -n 1)"
  if [ "${changes:-0}" -ne 1 ]; then
    log "ERROR: persist_verified_pr_metadata: failed to persist PR #$pr_number for task $comment_id (changes=${changes:-0})"
    lc_log "PR_METADATA_ERROR" "task=$comment_id reason=database_update_failed pr_number=$pr_number"
    return 1
  fi

  log "persist_verified_pr_metadata: task $comment_id -> PR #$pr_number $pr_url"
  lc_log "PR_METADATA_PERSISTED" "task=$comment_id pr_number=$pr_number url=$pr_url"
  return 0
}

# Verify that the agent's result comment contains the exact canonical URL
# of the real PR belonging to this task branch. This prevents an issue URL,
# an issue number masquerading as a PR number, /compare links, or stale PR links
# from being reported as the task result.
verify_result_comment_pr_url() {
  local repo="$1" issue_num="$2" comment_id="$3" safe_comment_id="$4" attempt="$5" workdir="$6" expected_base="$7"
  local branch="$8"

  local pr_json
  pr_json="$(timeout "$GH_API_TIMEOUT" gh pr list --repo "$repo" --state all --head "$branch" --json number,url,baseRefName,headRefName --limit 10 2>>"$LOG")" || {
    log "ERROR: verify_result_comment_pr_url: failed to query PR for $repo/$branch"
    lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=$comment_id repo=$repo branch=$branch reason=api_failure"
    return 1
  }

  local pr_url pr_number
  pr_url="$(printf '%s' "$pr_json" | jq -r --arg base "$expected_base" --arg head "$branch" 'map(select(.baseRefName == $base and .headRefName == $head and (.state == null or .state != "closed"))) | .[0].url // empty' 2>/dev/null)"
  pr_number="$(printf '%s' "$pr_json" | jq -r --arg base "$expected_base" --arg head "$branch" 'map(select(.baseRefName == $base and .headRefName == $head and (.state == null or .state != "closed"))) | .[0].number // empty' 2>/dev/null)"
  # The PR may be closed; for the task result we still accept the concrete PR
  # that belongs to this branch/base, so retry without the state assumption.
  if [ -z "$pr_url" ] || [ -z "$pr_number" ]; then
    pr_url="$(printf '%s' "$pr_json" | jq -r --arg base "$expected_base" --arg head "$branch" 'map(select(.baseRefName == $base and .headRefName == $head)) | .[0].url // empty' 2>/dev/null)"
    pr_number="$(printf '%s' "$pr_json" | jq -r --arg base "$expected_base" --arg head "$branch" 'map(select(.baseRefName == $base and .headRefName == $head)) | .[0].number // empty' 2>/dev/null)"
  fi
  if [ -z "$pr_url" ] || [ -z "$pr_number" ]; then
    log "ERROR: verify_result_comment_pr_url: no verified PR URL for $repo/$branch base=$expected_base"
    lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=$comment_id repo=$repo branch=$branch base=$expected_base reason=no_verified_pr"
    return 1
  fi

  # Keep the canonical PR identity in SQLite before emitting TASK_DONE. This
  # prevents an issue task's initial prNumber (which may equal the issue number)
  # from leaking into result feedback after a real PR has been verified.
  if ! persist_verified_pr_metadata "$comment_id" "$pr_number" "$pr_url"; then
    return 1
  fi

  local comment_url
  comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null)"
  local target_issue
  target_issue="$(printf '%s' "$comment_url" | grep -oE '(issues|pull)/[0-9]+' | grep -oE '[0-9]+' || echo "$issue_num")"

  # Result comments for inline review tasks live on the PR review-comments
  # endpoint; top-level issue/PR conversation results live on the issue-comments
  # endpoint. Use the same collection for URL verification and self-healing.
  local result_endpoint
  local result_comment_get_endpoint
  local result_comment_patch_endpoint
  local result_reply_to_id=""
  local result_body_filter
  local marker="<!-- manul-task:${comment_id}:attempt:${attempt} -->"
  if [[ "$comment_url" == *"/pull/"*"#discussion_r"* ]] || [[ "$comment_id" =~ ^review:[0-9]+$ ]]; then
    result_reply_to_id="$(printf '%s' "$comment_url" | sed -nE 's/.*#discussion_r([0-9]+).*/\1/p')"
    if [ -z "$result_reply_to_id" ] && [[ "$comment_id" =~ ^review:([0-9]+)$ ]]; then
      result_reply_to_id="${BASH_REMATCH[1]}"
    fi
    if ! [[ "$result_reply_to_id" =~ ^[0-9]+$ ]]; then
      log "ERROR: verify_result_comment_pr_url: review task $comment_id has no numeric source-thread ID"
      lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=$comment_id reason=missing_review_thread_id"
      return 1
    fi
    result_endpoint="repos/$repo/pulls/$target_issue/comments"
    result_body_filter=".[] | select((.in_reply_to_id // \"\") | tostring == \"$result_reply_to_id\") | select((.body // \"\") | contains(\"$marker\")) | .body // \"\""
    # Individual review-comment GET/PATCH endpoints are not nested under the PR number.
    result_comment_get_endpoint="repos/$repo/pulls/comments"
    result_comment_patch_endpoint="repos/$repo/pulls/comments"
  else
    result_endpoint="repos/$repo/issues/$target_issue/comments"
    result_body_filter=".[] | select(.in_reply_to_id == null) | select((.body // \"\") | contains(\"$marker\")) | .body // \"\""
    result_comment_get_endpoint="repos/$repo/issues/comments"
    result_comment_patch_endpoint="repos/$repo/issues/comments"
  fi

  local bodies
  bodies="$(timeout "$GH_API_TIMEOUT" gh api "$result_endpoint" --paginate --jq "$result_body_filter" 2>>"$LOG")" || {
    log "ERROR: verify_result_comment_pr_url: failed to fetch the task result comment from $result_endpoint"
    lc_log "PR_RESULT_LINK_VERIFY_ERROR" "task=${comment_id} repo=$repo reason=comment_api_failure endpoint=$result_endpoint"
    return 1
  }

  if printf '%s
' "$bodies" | grep -Fq -- "$pr_url"; then
    log "verify_result_comment_pr_url: exact PR URL present for task $comment_id -> $pr_url"
    return 0
  fi

  # Self-healing: the agent may have completed the implementation and opened a
  # verified PR but omitted the canonical URL from its result comment. Do not
  # discard completed work for that presentation-only defect. Locate the exact
  # result comment by deterministic task/attempt marker and append the verified
  # canonical PR URL to it. The daemon then re-checks the comment before success.
  local target_comment_id=""
  if [ -n "$result_reply_to_id" ]; then
    target_comment_id="$(timeout "$GH_API_TIMEOUT" gh api "$result_endpoint" --paginate 2>>"$LOG" | jq -r --arg marker "$marker" --arg reply "$result_reply_to_id" '.[] | select((.in_reply_to_id // "") | tostring == $reply) | select(.body != null and (.body | contains($marker))) | .id' 2>>"$LOG" | head -1 || true)"
  else
    target_comment_id="$(timeout "$GH_API_TIMEOUT" gh api "$result_endpoint" --paginate 2>>"$LOG" | jq -r --arg marker "$marker" '.[] | select(.in_reply_to_id == null) | select(.body != null and (.body | contains($marker))) | .id' 2>>"$LOG" | head -1 || true)"
  fi

  if [ -n "$target_comment_id" ]; then
    local repaired_body
    repaired_body="$(timeout "$GH_API_TIMEOUT" gh api "$result_comment_get_endpoint/$target_comment_id"       --jq '.body // ""' 2>>"$LOG" || true)"
    if [ -n "$repaired_body" ] && [[ "$repaired_body" != *"$pr_url"* ]]; then
      repaired_body="${repaired_body}"$'\n\n'"PR: ${pr_url}"
      if timeout "$GH_API_TIMEOUT" gh api --method PATCH "$result_comment_patch_endpoint/$target_comment_id"         -f "body=$repaired_body" >/dev/null 2>>"$LOG"; then
        log "verify_result_comment_pr_url: repaired result comment $target_comment_id with canonical PR URL $pr_url"
        lc_log "PR_RESULT_LINK_REPAIRED" "task=${comment_id} repo=$repo branch=$branch base=$expected_base comment_id=$target_comment_id url=$pr_url"
        local verified_repaired_body
        verified_repaired_body="$(timeout "$GH_API_TIMEOUT" gh api "$result_comment_get_endpoint/$target_comment_id" --jq '.body // ""' 2>>"$LOG" || true)"
        if [[ "$verified_repaired_body" == *"$pr_url"* ]]; then
          return 0
        fi
      fi
    fi
  fi

  log "ERROR: verify_result_comment_pr_url: result comment does not contain canonical PR URL $pr_url and self-healing failed"
  lc_log "PR_RESULT_LINK_MISSING" "task=$comment_id repo=$repo branch=$branch base=$expected_base expected_url=$pr_url"
  return 1
}

# ── Source revalidation ────────────────────────────────────────────────────────
# Pre-flight check before dispatching a claimed task.  Ensures the GitHub source
# (issue, PR, or review thread) still exists and is in an active state.
# Returns: 0=fresh (proceed), 1=stale (terminal), 2=transient (requeue).

# Detect the source kind from a comment_id prefix.
# Prefixes are authoritative:
#   issue:     -> issue comment
#   issuebody: -> issue/PR state
#   ci_fix:    -> PR state
#   review:    -> PR review thread/comment
detect_source_kind() {
  local comment_id="$1"
  case "$comment_id" in
    review:*)    echo "pr_review_comment" ;;
    issuebody:*) echo "issue_state" ;;
    ci_fix:*)    echo "pr_state" ;;
    issue:*)     echo "issue_comment" ;;
    *)           echo "issue_comment" ;;
  esac
}

# Revalidate a single source. Returns:
#   0 = fresh
#   1 = stale (terminal)
#   2 = transient (requeue)
# The issue/PR number is passed separately because review:<id> contains only
# the review comment database ID.
revalidate_source() {
  local comment_id="$1"
  local repo="$2"
  local issue_num="${3:-}"
  local source_url="${4:-}"
  local kind
  kind="$(detect_source_kind "$comment_id")"
  case "$kind" in
    issue_comment)      revalidate_issue_comment "$comment_id" "$repo" "$source_url" ;;
    issue_state)        revalidate_issue_state "$comment_id" "$repo" "$source_url" ;;
    pr_state)           revalidate_pr_state "$comment_id" "$repo" ;;
    pr_review_comment)  revalidate_pr_review_comment "$comment_id" "$repo" "$issue_num" ;;
    *)                  return 2 ;;
  esac
}

# ── issue_comment ─────────────────────────────────────────────────────────────
# Matched by prefix issue:<id>. Verifies the comment still exists on GitHub.
revalidate_issue_comment() {
  local comment_id="$1" repo="$2" source_url="${3:-}"
  local num="${comment_id#issue:}"
  local owner name
  IFS='/' read -r owner name _ <<<"$repo"

  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/issues/comments/$num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: issue comment $num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_comment reason=not_found"
      return 1
    fi
    log "revalidate_source: issue comment API error for $comment_id (rc=$rc)"
    return 2
  fi

  local returned_id
  returned_id="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
  if [ -n "$returned_id" ]; then
    if [[ "$source_url" =~ /pull/([0-9]+)([/#?]|$) ]]; then
      local source_pr_num="${BASH_REMATCH[1]}"
      revalidate_pr_target "$comment_id" "$repo" "$source_pr_num" "issue_comment"
      return $?
    fi
    log "revalidate_source: issue comment $num still exists on $repo — fresh"
    return 0
  fi
  log "revalidate_source: issue comment $num returned no id — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_comment reason=missing_id"
  return 1
}

# ── issue_state ───────────────────────────────────────────────────────────────
revalidate_issue_state() {
  local comment_id="$1" repo="$2" source_url="${3:-}"
  local num="${comment_id#issuebody:}"

  # issuebody task IDs are GitHub API object IDs, while /issues/<N> expects
  # the human-facing issue number. The stored issue URL is authoritative for
  # legacy queue rows created with the wrong numeric identifier.
  if [[ "$source_url" =~ /issues/([0-9]+)(/|#|$) ]]; then
    local source_num="${BASH_REMATCH[1]}"
    if [ "$source_num" != "$num" ]; then
      log "revalidate_source: correcting issuebody source id $num to issue number $source_num from $source_url"
      num="$source_num"
    fi
  fi

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"

  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/issues/$num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: issue $num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_state reason=not_found"
      return 1
    fi
    log "revalidate_source: issue state API error for $comment_id (rc=$rc)"
    return 2
  fi
  local state
  state="$(printf '%s' "$resp" | jq -r '.state // empty' 2>/dev/null || true)"
  if [ "$state" = "open" ]; then
    log "revalidate_source: issue $num is still open on $repo — fresh"
    return 0
  fi
  log "revalidate_source: issue $num is ${state:-unknown} on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_state reason=closed state=${state:-unknown}"
  return 1
}

revalidate_pr_target() {
  local comment_id="$1" repo="$2" pr_num="$3" source_kind="${4:-pr_state}"
  [[ "$pr_num" =~ ^[0-9]+$ ]] || return 2

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"
  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/pulls/$pr_num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      log "revalidate_source: PR $pr_num lookup timed out for $repo"
      return 2
    fi
    if printf '%s' "$resp" | jq -e '(.message // "" | strings | ascii_downcase | contains("not found"))' >/dev/null 2>&1; then
      log "revalidate_source: PR $pr_num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=pr_not_found"
      return 1
    fi
    log "revalidate_source: PR state API error for $comment_id (rc=$rc)"
    return 2
  fi

  local state merged head_ref head_repo
  state="$(printf '%s' "$resp" | jq -r '.state // empty' 2>/dev/null || true)"
  merged="$(printf '%s' "$resp" | jq -r '.merged // false' 2>/dev/null || echo false)"
  if [ -z "$state" ]; then
    log "revalidate_source: PR $pr_num response omitted state for $repo; treating as transient"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=missing_pr_state"
    return 2
  fi
  if [ "$state" != "open" ] || [ "$merged" = "true" ]; then
    local reason="pr_${state:-unknown}"
    [ "$merged" = "true" ] && reason="pr_merged"
    log "revalidate_source: PR $pr_num is ${state:-unknown} on $repo — stale"
    lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=$reason"
    return 1
  fi

  head_ref="$(printf '%s' "$resp" | jq -r '.head.ref // empty' 2>/dev/null || true)"
  head_repo="$(printf '%s' "$resp" | jq -r '.head.repo.full_name // empty' 2>/dev/null || true)"
  if [ -z "$head_ref" ]; then
    log "revalidate_source: open PR $pr_num omitted head.ref for $repo; treating as transient"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=missing_head_ref"
    return 2
  fi
  if [ -z "$head_repo" ]; then
    log "revalidate_source: open PR $pr_num has no accessible head repository on $repo — stale"
    lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=head_repo_missing"
    return 1
  fi
  if [[ ! "$head_repo" =~ ^[^/]+/[^/]+$ ]]; then
    log "revalidate_source: invalid head repository metadata for PR $pr_num on $repo"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=invalid_head_repo"
    return 2
  fi

  local encoded_head_ref branch_resp branch_rc
  encoded_head_ref="$(printf '%s' "$head_ref" | jq -sRr '@uri' 2>/dev/null)" || return 2
  branch_resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$head_repo/branches/$encoded_head_ref" 2>/dev/null)" && branch_rc=0 || branch_rc=$?
  if [ "$branch_rc" -ne 0 ]; then
    if [ "$branch_rc" -eq 124 ]; then
      log "revalidate_source: head branch lookup timed out for PR $pr_num ($head_repo/$head_ref)"
      return 2
    fi
    if printf '%s' "$branch_resp" | jq -e '(.message // "" | strings | ascii_downcase | contains("not found"))' >/dev/null 2>&1; then
      log "revalidate_source: head branch $head_repo/$head_ref missing for PR $pr_num — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=head_branch_missing"
      return 1
    fi
    log "revalidate_source: head branch API error for PR $pr_num ($head_repo/$head_ref, rc=$branch_rc)"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=head_branch_api_error rc=$branch_rc"
    return 2
  fi

  local returned_branch
  returned_branch="$(printf '%s' "$branch_resp" | jq -r '.name // empty' 2>/dev/null || true)"
  if [ "$returned_branch" != "$head_ref" ]; then
    log "revalidate_source: head branch response did not match PR $pr_num ($head_repo/$head_ref) — treating as transient"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=head_branch_mismatch"
    return 2
  fi

  log "revalidate_source: PR $pr_num and head branch $head_repo/$head_ref are open and available on $repo — fresh"
  return 0
}

# ── pr_state ──────────────────────────────────────────────────────────────────
# Matched by prefix ci_fix:<repo>:<pr_num>:<run_id>. OPEN only.
revalidate_pr_state() {
  local comment_id="$1" repo="$2"
  local pr_num
  case "$comment_id" in
    ci_fix:*) pr_num="$(printf '%s' "$comment_id" | awk -F: '{print $3}')" ;;
    *) return 2 ;;
  esac
  revalidate_pr_target "$comment_id" "$repo" "$pr_num" "pr_state"
}

# ── pr_review_comment ─────────────────────────────────────────────────────────
# review:<id> uses issueNumber as the PR number. Verifies PR OPEN, thread
# unresolved, and paginates reviewThreads until found/exhausted.
revalidate_pr_review_comment() {
  local comment_id="$1" repo="$2" pr_num="$3"
  local tid="${comment_id#review:}"
  [[ "$tid" =~ ^[0-9]+$ ]] || return 2
  [[ "$pr_num" =~ ^[0-9]+$ ]] || return 2

  local target_rc=0
  revalidate_pr_target "$comment_id" "$repo" "$pr_num" "pr_review_comment" || target_rc=$?
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"
  local tmp_cursor="" has_more=true
  local q_base='query($o:String!,$n:String!,$num:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$num){state reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor}nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'
  local q_no_cursor='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){state reviewThreads(first:100){pageInfo{hasNextPage endCursor}nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'

  while $has_more; do
    local resp rc
    if [ -n "$tmp_cursor" ]; then
      resp="$(timeout "$GH_API_TIMEOUT" gh api graphql --field query="$q_base" --field o="$owner" --field n="$name" --field num="$pr_num" --field c="$tmp_cursor" 2>/dev/null)" && rc=0 || rc=$?
    else
      resp="$(timeout "$GH_API_TIMEOUT" gh api graphql --field query="$q_no_cursor" --field o="$owner" --field n="$name" --field num="$pr_num" 2>/dev/null)" && rc=0 || rc=$?
    fi
    if [ "$rc" -eq 124 ]; then
      log "revalidate_source: review GraphQL timeout for $comment_id"
      return 2
    fi
    if [ "$rc" -ne 0 ]; then
      log "revalidate_source: review GraphQL error for $comment_id (rc=$rc)"
      return 2
    fi

    local pr_null
    pr_null="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest == null' 2>/dev/null || true)"
    if [ "$pr_null" = "true" ]; then
      log "revalidate_source: PR $pr_num not found for review $comment_id — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=pr_not_found"
      return 1
    fi

    local pr_state
    pr_state="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.state // empty' 2>/dev/null || true)"
    if [ "$pr_state" != "OPEN" ]; then
      log "revalidate_source: PR $pr_num is ${pr_state:-unknown} on $repo — stale for review task"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=pr_${pr_state:-unknown}"
      return 1
    fi

    local thread_info
    thread_info="$(printf '%s' "$resp" | jq -r --argjson tid "$tid" '.data.repository.pullRequest.reviewThreads.nodes[]? | select((.comments.nodes // []) | map(.databaseId) | index($tid) != null) | "\(.isResolved)"' 2>/dev/null || true)"
    if [ -n "$thread_info" ]; then
      if [ "$(printf '%s' "$thread_info" | head -1)" = "true" ]; then
        log "revalidate_source: review thread $tid is resolved on $repo — stale"
        lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=resolved"
        return 1
      fi
      log "revalidate_source: review thread $tid is unresolved on $repo — fresh"
      return 0
    fi

    local has_next next_cursor
    has_next="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null || echo false)"
    next_cursor="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null || true)"
    if [ "$has_next" != "true" ] || [ -z "$next_cursor" ]; then
      has_more=false
    else
      tmp_cursor="$next_cursor"
    fi
  done

  log "revalidate_source: review thread $tid not found after pagination on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=thread_not_found"
  return 1
}

# Mark a running task as blocked on explicit user input.
# This is not a failure and is not retryable. A later /manul continue resumes
# this exact task.
mark_task_blocked_user() {
  local comment_id="$1" safe_comment_id="$2" claim_token="$3" question="${4:-}"
  local safe_claim_token safe_question
  safe_claim_token="$(sql_escape "$claim_token")"
  safe_question="$(sql_escape "$question")"
  local result changes
  result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='blocked_user', resultSummary=CASE WHEN '$safe_question' <> '' THEN '$safe_question' ELSE resultSummary END, processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>/dev/null)"
  changes="$(printf '%s\n' "$result" | tail -1)"
  if [ "$changes" = "1" ]; then
    log "mark_task_blocked_user: task $comment_id is waiting for user input"
    lc_log "TASK_NEEDS_USER" "task=$comment_id"
    return 0
  fi
  log "ERROR: mark_task_blocked_user did not update task $comment_id (changes=$changes)"
  lc_log "TASK_ERROR" "task=$comment_id reason=mark_blocked_failed"
  return 1
}

# Extract and validate the complete structured user-decision request emitted by
# the agent. A user block is valid only when it contains exactly one BEGIN and
# one END marker, in the correct order, with non-empty content between them.
#
# This is intentionally strict: a malformed or partial block must never pause
# a task indefinitely. It falls through to ordinary failure handling instead.
extract_user_decision_request() {
  local stdout_file="$1"
  USER_QUESTION=""

  [ -f "$stdout_file" ] || return 1

  local begin_count end_count begin_line end_line question
  begin_count="$(grep -c '^TASK_NEEDS_USER_BEGIN$' "$stdout_file" 2>/dev/null || true)"
  end_count="$(grep -c '^TASK_NEEDS_USER_END$' "$stdout_file" 2>/dev/null || true)"

  [ "$begin_count" = "1" ] || return 1
  [ "$end_count" = "1" ] || return 1

  begin_line="$(grep -n '^TASK_NEEDS_USER_BEGIN$' "$stdout_file" | cut -d: -f1 | head -1)"
  end_line="$(grep -n '^TASK_NEEDS_USER_END$' "$stdout_file" | cut -d: -f1 | head -1)"
  [ -n "$begin_line" ] && [ -n "$end_line" ] || return 1
  [ "$begin_line" -lt "$end_line" ] || return 1

  # A user decision is mutually exclusive with completion/failure markers.
  if grep -qE '^TASK_(DONE|COMPLETED)([[:space:]]|$)|^TASK_FAILED([[:space:]:]|$)' "$stdout_file" 2>/dev/null; then
    return 1
  fi

  question="$(awk '/^TASK_NEEDS_USER_BEGIN$/{inside=1; next} /^TASK_NEEDS_USER_END$/{inside=0; exit} inside{print}' "$stdout_file" 2>/dev/null || true)"
  [ -n "$question" ] || return 1
  [ -n "$(printf '%s' "$question" | tr -d '[:space:]')" ] || return 1

  USER_QUESTION="$question"
  return 0
}

post_task_needs_user_comment() {
  local repo="$1" issue="$2" comment_id="$3" question="$4" reply_to="${5:-}"
  local task_attempt conversation_id
  task_attempt="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null || echo "1")"
  conversation_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$(sql_escape "$comment_id")' LIMIT 1;" 2>/dev/null || echo "")"

  local event_json
  event_json="$(jq -nc --arg taskId "$comment_id" --arg conversationId "$conversation_id" --arg question "$question" --argjson attempt "$task_attempt" '{type:"TASK_NEEDS_USER",timestamp:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),data:{taskId:$taskId,conversationId:$conversationId,attempt:$attempt,question:$question}}')"

  local body
  if [ "$MANUL_MODE" = "human" ]; then
    body="<!-- manul:event $event_json -->

I need your input to continue.

$question

Reply with:

\`/manul continue <your answer>\`

This will resume the same task and conversation."
  else
    body="<!-- manul:event $event_json -->

❓ **Manul needs your input to continue**

$question

Reply with:

\`/manul continue <your answer>\`

The answer will resume this same task and conversation.

— manul 🐈"
  fi

  # The task is already marked blocked_user when this notification runs.
  # Retry transient GitHub API failures so a user decision is not silently lost.
  local post_attempt=1
  local max_post_attempts=3
  while [ "$post_attempt" -le "$max_post_attempts" ]; do
    if post_github_comment "$repo" "$issue" "$body" "$reply_to"; then
      return 0
    fi
    log "WARN: failed to post TASK_NEEDS_USER comment for $comment_id (attempt=$post_attempt/$max_post_attempts)"
    if [ "$post_attempt" -lt "$max_post_attempts" ]; then
      sleep "$post_attempt"
    fi
    post_attempt=$((post_attempt + 1))
  done
  return 1
}
# Mark a running task as stale (terminal).
mark_task_stale() {
  local comment_id="$1" safe_comment_id="$2" claim_token="$3"
  local safe_claim_token
  safe_claim_token="$(sql_escape "$claim_token")"
  local result changes
  result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='stale', processedAt=datetime('now'), heartbeatAt=NULL, workerPid=NULL, leaseExpiresAt=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>/dev/null)"
  changes="$(printf '%s\n' "$result" | tail -1)"
  if [ "$changes" = "1" ]; then
    log "mark_task_stale: task $comment_id marked stale"
    lc_log "TASK_STALE" "task=$comment_id"
    return 0
  fi
  log "ERROR: mark_task_stale did not update task $comment_id (changes=$changes)"
  lc_log "TASK_ERROR" "task=$comment_id reason=mark_stale_failed"
  return 1
}

# Route transient pre-agent source failures through the same bounded recovery
# path as checkout/workspace errors. Infrastructure retries get their own budget
# and do not silently churn queued/running forever.
requeue_task() {
  ensure_recovery_tracking_columns || return 1
  local comment_id="$1" safe_comment_id="$2" claim_token="$3"
  local repo="${4:-}" issue_num="${5:-}" reply_to="${6:-}" attempt_fallback="${7:-1}"
  if [ -z "$repo" ]; then repo="$(sqlite3 "$DB" "SELECT COALESCE(repository,'') FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || true)"; fi
  if [ -z "$issue_num" ]; then issue_num="$(sqlite3 "$DB" "SELECT COALESCE(issueNumber,'') FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || true)"; fi
  if [ -z "$attempt_fallback" ] || ! [[ "$attempt_fallback" =~ ^[0-9]+$ ]]; then
    attempt_fallback="$(sqlite3 "$DB" "SELECT COALESCE(attempts,1) FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo 1)"
  fi
  handle_pre_execution_failure "$comment_id" "$claim_token" "$repo" "$issue_num" "" "$reply_to" "Source revalidation encountered a transient infrastructure error before agent startup." "" "$attempt_fallback" "source_transient_revalidation"
}

# Evaluate task completion decision based on wrapper output and verification
# Sets: COMPLETION_SUCCESS, FAIL_REASON, FINAL_COMMENT
# Args: repo issue_num comment_id safe_comment_id attempt rc stdout_file db [repo_dir] [workdir] [claim_token] [initial_head] [initial_branch] [initial_base_branch]
evaluate_task_completion() {
  local REPO="$1"
  local ISSUE_NUM="$2"
  local COMMENT_ID="$3"
  local safe_comment_id="$4"
  local current_attempt="$5"
  local rc="$6"
  local STDOUT_FILE="$7"
  local DB="$8"
  local REPO_DIR="${9:-}"
  local WORKDIR="${10:-$REPO_DIR}"
  local CLAIM_TOKEN="${11:-}"
  local INITIAL_HEAD="${12:-}"
  local INITIAL_BRANCH="${13:-}"
  local INITIAL_BASE_BRANCH="${14:-${INITIAL_BRANCH:-$DEFAULT_BRANCH}}"
  local EXECUTION_SUMMARY="${15:-}"
  local EXECUTION_FAILURE_CODE="${16:-}"
  local PR_HEAD_BRANCH="${17:-}"
  local DELIVERY_MODE="${19:-implementation}"
  local TASK_SOURCE_TYPE="${20:-}"
  local TASK_EXECUTION_KIND="${21:-repository}"
  # Reset per-evaluation output so a prior task cannot leak its verified merged PR base.
  local VERIFIED_MERGED_RESULT_PR_BASE=""

  COMPLETION_SUCCESS="false"
  FAIL_REASON=""
  FINAL_COMMENT=""
  NEEDS_USER_INPUT="false"
  USER_QUESTION=""
  USER_DECISION_INVALID="false"
  FAILURE_CODE=""

  # Preserve the adapter's machine-readable failure code so retry/failure
  # comments and lifecycle logs distinguish e.g. a runtime permission block
  # from a generic provider error.
  if [ -n "$EXECUTION_FAILURE_CODE" ]; then
    FAILURE_CODE="$EXECUTION_FAILURE_CODE"
  fi
  
  # Preserve the runtime/controller summary so user-facing retry/failure
  # comments explain the actual execution failure instead of collapsing it to
  # the generic "Task failed".
  if [ -n "$EXECUTION_SUMMARY" ]; then
    FAIL_REASON="$EXECUTION_SUMMARY"
  fi
  if [ -n "$FAILURE_CODE" ]; then
    FAIL_REASON="${FAILURE_CODE}: ${FAIL_REASON}"
  fi
  
  local SUCCESS="false"

  # A user-input request is a deliberate pause, not task failure.
  # Detect and validate the complete structured block before any success/failure
  # verification. Malformed/partial blocks intentionally remain failures.
  if [ "$TASK_EXECUTION_KIND" = "report_only" ] && [ -f "$STDOUT_FILE" ] && {
    grep -q "^TASK_NEEDS_USER_BEGIN$" "$STDOUT_FILE" 2>/dev/null ||
    grep -q "^TASK_NEEDS_USER_END$" "$STDOUT_FILE" 2>/dev/null
  }; then
    FAIL_REASON="Report-only Todo tasks cannot pause for user input; return a complete answer or TASK_FAILED"
    FAILURE_CODE="REPORT_ONLY_USER_INPUT_UNSUPPORTED"
    USER_DECISION_INVALID="true"
  elif [ -f "$STDOUT_FILE" ] && {
    grep -q "^TASK_NEEDS_USER_BEGIN$" "$STDOUT_FILE" 2>/dev/null ||
    grep -q "^TASK_NEEDS_USER_END$" "$STDOUT_FILE" 2>/dev/null
  }; then
    if extract_user_decision_request "$STDOUT_FILE"; then
      NEEDS_USER_INPUT="true"
      log "dispatch: task $COMMENT_ID requested user input"
      lc_log "TASK_NEEDS_USER" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM source=$TASK_SOURCE_TYPE"
      return 0
    fi
    log "WARN: task $COMMENT_ID emitted a malformed user-decision block; treating as failure"
    FAIL_REASON="Malformed TASK_NEEDS_USER block"
    USER_DECISION_INVALID="true"
  fi
  # 7. Determine success using BOTH exit status AND explicit completion marker.
  # A malformed/contradictory user-decision block must not be resurrected as
  # success merely because TASK_DONE/TASK_COMPLETED also appeared in stdout.
  if [ "$USER_DECISION_INVALID" != "true" ] && [ "$rc" -eq 0 ]; then
    if [ -f "$STDOUT_FILE" ] && grep -qE 'TASK_DONE|TASK_COMPLETED' "$STDOUT_FILE"; then
      SUCCESS="true"
    elif [ -f "$STDOUT_FILE" ] && grep -qE 'TASK_FAILED:' "$STDOUT_FILE"; then
      FAIL_REASON="$(grep -E 'TASK_FAILED:' "$STDOUT_FILE" | head -1 | sed -E 's/.*TASK_FAILED: //')"
    fi
  fi
  
  # Result-comment verification runs after repository/PR verification below.
  # This ordering is intentional: if the agent created a real PR but its result
  # comment is malformed, the verified PR metadata is still persisted before the
  # task is rejected for violating the exactly-one-result-comment contract.

  # Explicit report-only delivery path for VERIFY tasks.
  # A report-only task is successful only with TASK_DONE, no repository changes,
  # and one verified non-empty result comment correlated to this task attempt.
  if [ "$DELIVERY_MODE" = "comment_only" ]; then
    if [ "$SUCCESS" != "true" ]; then
      : # Preserve the original non-success reason.
    elif repository_changed_since "$WORKDIR" "$INITIAL_HEAD"; then
      SUCCESS="false"
      FAILURE_CODE="VERIFICATION_FAILED"
      FAIL_REASON="Comment-only task modified the repository; report-only delivery must leave code unchanged"
      log "dispatch: task $COMMENT_ID report-only validation failed: repository changed"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=comment_only_repository_changed"
    elif ! verify_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt"; then
      SUCCESS="false"
      FAILURE_CODE="DELIVERY_COMMENT_MISSING"
      FAIL_REASON="Report-only task did not publish a verified result comment"
      log "dispatch: task $COMMENT_ID report-only validation failed: requested report comment missing or invalid"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=comment_only_comment_invalid"
    elif ! verify_nonempty_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt"; then
      SUCCESS="false"
      FAILURE_CODE="DELIVERY_COMMENT_EMPTY"
      FAIL_REASON="Report-only task result comment is empty or contains only the marker/signature"
      log "dispatch: task $COMMENT_ID report-only validation failed: empty report"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=comment_only_comment_empty"
    else
      log "dispatch: task $COMMENT_ID verified comment-only/report delivery"
      lc_log "COMMENT_ONLY_DELIVERY_VERIFIED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$current_attempt"
    fi
  fi


  if [ "$TASK_EXECUTION_KIND" != "report_only" ]; then
  # 7.5. Verify repository state is clean (no staged/unstaged/untracked changes)
  if [ "$SUCCESS" = "true" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR/.git" ]; then
    local repo_state_clean="true"
    local repo_state_issues=""

    # Check for staged changes
    if ! git -C "$WORKDIR" diff --cached --quiet 2>/dev/null; then
      repo_state_clean="false"
      repo_state_issues+="staged_changes "
    fi

    # Check for unstaged changes
    if ! git -C "$WORKDIR" diff --quiet 2>/dev/null; then
      repo_state_clean="false"
      repo_state_issues+="unstaged_changes "
    fi

    # Check for untracked files (ignoring build artifacts like __pycache__)
    local untracked
    untracked="$(git -C "$WORKDIR" ls-files --others --exclude-standard 2>/dev/null | grep -v '/__pycache__' | grep -v '/\.pytest_cache' | grep -v '^__pycache__' | grep -v '^\.__pycache__' | grep -v '^\.__pycache__/' | grep -v '^\.pytest_cache' || true)"
    if [ -n "$untracked" ]; then
      repo_state_clean="false"
      repo_state_issues+="untracked_files "
    fi

    if [ "$repo_state_clean" = "false" ]; then
      # Preserve the dirty checkout for diagnosis. It is never evidence of
      # successful delivery, even when HEAD happens to equal the remote SHA.
      log "dispatch: task $COMMENT_ID repository state is dirty (${repo_state_issues% })"
      lc_log "WORKTREE_DIRTY" "task=$COMMENT_ID repo=$REPO state=${repo_state_issues% }"
    fi
  fi
  
  # 7.6 Determine whether the agent actually changed repository state.
  # Informational tasks may legitimately finish without a branch or PR.
  # Every repository change must be verified through the full PR/result pipeline,
  # including issue-body tasks (issuebody:*). The task identifier format must
  # never weaken the implementation PR requirement.
  if [ "$SUCCESS" = "true" ] && [ "$DELIVERY_MODE" != "comment_only" ]; then
    local repo_changed="false"
    if repository_changed_since "$WORKDIR" "$INITIAL_HEAD"; then repo_changed="true"; fi
    if [ "$repo_changed" = "true" ]; then
      local current_branch
      current_branch="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null || echo "")"
      if [ -z "$current_branch" ]; then
        SUCCESS="false"
        FAILURE_CODE="VERIFICATION_FAILED"
        FAIL_REASON="Repository changed but the agent is not on a named branch"
        log "dispatch: task $COMMENT_ID changed repository state from detached HEAD"
      elif [ -n "$PR_HEAD_BRANCH" ]; then
        # PR-tied tasks are intentionally executed on the existing PR head branch.
        # That branch equals the prepared INITIAL_BRANCH, so it is valid by design.
        if [ "$current_branch" != "$PR_HEAD_BRANCH" ]; then
          SUCCESS="false"
          FAILURE_CODE="VERIFICATION_FAILED"
          FAIL_REASON="PR review task changed repository on unexpected branch ($current_branch, expected $PR_HEAD_BRANCH)"
          log "dispatch: task $COMMENT_ID changed repository on unexpected PR branch $current_branch (expected $PR_HEAD_BRANCH)"
          lc_log "TASK_ERROR" "task=$COMMENT_ID reason=unexpected_pr_branch branch=$current_branch expected=$PR_HEAD_BRANCH"
        elif [ "$repo_state_clean" != "true" ]; then
          SUCCESS="false"
          FAILURE_CODE="DELIVERY_NOT_COMMITTED"
          FAIL_REASON="Delivery rejected: TASK_DONE left uncommitted repository changes on PR head branch $current_branch (${repo_state_issues% })"
          log "dispatch: task $COMMENT_ID delivery verification failed: uncommitted changes on PR head branch $current_branch (${repo_state_issues% })"
          lc_log "DELIVERY_NOT_COMMITTED" "task=$COMMENT_ID repo=$REPO branch=$current_branch state=${repo_state_issues% }"
        else
          log "dispatch: task $COMMENT_ID changed repository on expected PR head branch $current_branch"
        fi
      elif [ "$current_branch" = "$DEFAULT_BRANCH" ] || [ "$current_branch" = "$INITIAL_BASE_BRANCH" ]; then
        SUCCESS="false"
        FAILURE_CODE="VERIFICATION_FAILED"
        FAIL_REASON="Repository changes were made directly on a base/default branch ($current_branch)"
        log "dispatch: task $COMMENT_ID changed repository on forbidden base branch $current_branch"
        lc_log "TASK_ERROR" "task=$COMMENT_ID reason=changes_on_base_branch branch=$current_branch"
      elif [ "$repo_state_clean" != "true" ]; then
        SUCCESS="false"
        FAILURE_CODE="DELIVERY_NOT_COMMITTED"
        FAIL_REASON="Delivery rejected: the agent reported TASK_DONE but the repository has uncommitted changes on branch $current_branch (${repo_state_issues% })"
        log "dispatch: task $COMMENT_ID delivery verification failed: uncommitted changes on branch $current_branch (${repo_state_issues% })"
        lc_log "DELIVERY_NOT_COMMITTED" "task=$COMMENT_ID repo=$REPO branch=$current_branch state=${repo_state_issues% }"
      elif ! verify_required_pr "$REPO" "$COMMENT_ID" "$WORKDIR" "$INITIAL_BASE_BRANCH"; then
        SUCCESS="false"
        FAILURE_CODE="VERIFICATION_FAILED"
        FAIL_REASON="Implementation task did not produce a real PR against its branch base"
        log "dispatch: task $COMMENT_ID PR verification failed"
else
         local verified_base
         verified_base="$(infer_task_base_branch "$WORKDIR" "$current_branch" "$INITIAL_BASE_BRANCH")"
         if ! task_source_is_todo_type "$TASK_SOURCE_TYPE" && ! verify_result_comment_pr_url "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt" "$WORKDIR" "$verified_base" "$current_branch"; then
           SUCCESS="false"
           FAILURE_CODE="VERIFICATION_FAILED"
           FAIL_REASON="Result comment did not contain the exact canonical URL of the verified PR"
           log "dispatch: task $COMMENT_ID result comment PR URL verification failed"
         else
           log "dispatch: task $COMMENT_ID has repository changes on branch $current_branch; PR and result URL verified"
         fi
       fi

       # 7.7. Delivery push verification. A task that reports TASK_DONE with a real
       # repository change must have committed AND pushed its work. Distinguish the
       # concrete delivery states so retry/failure comments explain exactly what is
       # missing instead of collapsing everything to a generic verification failure.
       # Only runs when the repository actually changed; informational tasks with no
       # diff have nothing to deliver and must not be rejected here.
       if [ "$SUCCESS" = "true" ]; then
         local has_origin_remote="false"
         local remote_branch_sha=""
         if git -C "$WORKDIR" remote get-url origin >/dev/null 2>&1; then
           has_origin_remote="true"
           remote_branch_sha="$(git -C "$WORKDIR" ls-remote --heads origin "$current_branch" 2>/dev/null | awk '{print $1}')"
         fi

         if [ "$has_origin_remote" = "true" ] && [ -z "$remote_branch_sha" ]; then
           SUCCESS="false"
           FAILURE_CODE="DELIVERY_NOT_PUSHED"
           FAIL_REASON="Delivery rejected: the agent reported TASK_DONE but branch $current_branch was never pushed to the origin remote"
           log "dispatch: task $COMMENT_ID delivery verification failed: branch $current_branch not pushed to origin"
         elif [ "$has_origin_remote" = "true" ] && [ -n "$remote_branch_sha" ] \
           && [ "$remote_branch_sha" != "$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null)" ]; then
           SUCCESS="false"
           FAILURE_CODE="DELIVERY_NOT_PUSHED"
           FAIL_REASON="Delivery rejected: the agent reported TASK_DONE but branch $current_branch diverged from the pushed origin/$current_branch"
           log "dispatch: task $COMMENT_ID delivery verification failed: branch $current_branch diverges from origin"
         else
           log "dispatch: task $COMMENT_ID delivery push state verified for branch $current_branch"
         fi
       fi
     elif [ "$TASK_ACTION" = "IMPLEMENT" ]; then
      # IMPLEMENT work normally must finish on its own feature branch. A no-op
      # on the base branch is accepted only when an existing PR for this same
      # issue has been independently re-verified.
      local already_satisfied="false"
      current_branch="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null || echo "")"
      if [ -z "$current_branch" ] || [ "$current_branch" = "$INITIAL_BASE_BRANCH" ] || [ "$current_branch" = "$DEFAULT_BRANCH" ]; then
        if task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
          already_satisfied="true"
          log "dispatch: Todo task $TASK_SOURCE_ID completed without repository changes"
          lc_log "TODO_TASK_NO_REPO_CHANGE" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE"
        elif verify_existing_task_pr "$REPO" "$COMMENT_ID" "$WORKDIR" "$INITIAL_BASE_BRANCH"; then
          already_satisfied="true"
          current_branch="$VERIFIED_EXISTING_PR_BRANCH"
          log "dispatch: task $COMMENT_ID accepted as already satisfied by verified PR $VERIFIED_EXISTING_PR_URL"
          lc_log "IMPLEMENT_ALREADY_SATISFIED" "task=$COMMENT_ID repo=$REPO branch=$current_branch base=$INITIAL_BASE_BRANCH url=$VERIFIED_EXISTING_PR_URL"
        elif verify_merged_result_pr "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$current_attempt" "$INITIAL_BASE_BRANCH" "$DEFAULT_BRANCH"; then
          # A prior attempt may have completed and merged its PR, then a retry
          # can start from the updated base and produce no new repository diff.
          # Accept this only when this attempt's exact result marker points to a
          # real merged PR and the source issue is closed.
          already_satisfied="true"
          current_branch="$VERIFIED_EXISTING_PR_BRANCH"
          log "dispatch: task $COMMENT_ID accepted as already delivered through verified merged PR $VERIFIED_EXISTING_PR_URL"
          lc_log "IMPLEMENT_ALREADY_SATISFIED_MERGED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM branch=$current_branch base=$VERIFIED_MERGED_RESULT_PR_BASE url=$VERIFIED_EXISTING_PR_URL"
        else
          SUCCESS="false"
          FAILURE_CODE="VERIFICATION_FAILED"
          FAIL_REASON="Implementation task completed on a base/default branch ($current_branch) without a verified pre-existing or merged task PR"
          log "dispatch: task $COMMENT_ID reported success on forbidden branch $current_branch; no pre-existing or merged task PR was verified"
          lc_log "TASK_ERROR" "task=$COMMENT_ID reason=success_on_base_branch branch=$current_branch base=$INITIAL_BASE_BRANCH"
        fi
      fi

      if [ "$SUCCESS" = "true" ] && [ "$already_satisfied" != "true" ]; then
        if ! verify_required_pr "$REPO" "$COMMENT_ID" "$WORKDIR" "$INITIAL_BASE_BRANCH"; then
          SUCCESS="false"
          FAILURE_CODE="VERIFICATION_FAILED"
          FAIL_REASON="Implementation task completed without a verified PR from its task branch"
          log "dispatch: task $COMMENT_ID has no verified PR despite reporting success without repository diff"
          lc_log "MISSING_PR" "task=$COMMENT_ID repo=$REPO branch=$current_branch base=$INITIAL_BASE_BRANCH"
        fi
      fi
      if [ "$SUCCESS" = "true" ]; then
        local verified_base
        if [ -n "$VERIFIED_MERGED_RESULT_PR_BASE" ]; then
          verified_base="$VERIFIED_MERGED_RESULT_PR_BASE"
        elif [ "$already_satisfied" = "true" ]; then
          verified_base="$INITIAL_BASE_BRANCH"
        else
          verified_base="$(infer_task_base_branch "$WORKDIR" "$current_branch" "$INITIAL_BASE_BRANCH")"
        fi
        if ! task_source_is_todo_type "$TASK_SOURCE_TYPE" && ! verify_result_comment_pr_url "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt" "$WORKDIR" "$verified_base" "$current_branch"; then
          SUCCESS="false"
          FAILURE_CODE="VERIFICATION_FAILED"
          FAIL_REASON="Result comment did not contain the exact canonical URL of the verified PR"
          log "dispatch: task $COMMENT_ID result comment PR URL verification failed"
        fi
      fi
    else
      # A TASK_DONE from an IMPLEMENT task is only informational when the agent
      # genuinely made no repository changes. Keep this explicit so issuebody:*
      # tasks cannot accidentally bypass the repository/PR verification above.
      log "dispatch: task $COMMENT_ID made no repository changes; PR/branch not required"
      lc_log "NO_REPO_CHANGE" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM"
    fi
  fi

  fi

  # Report-only Todo tasks persist their final answer before any source-tree
  # completion. The adapter returns a source-bound receipt only after read-back.
  if [ "$SUCCESS" = "true" ] && [ "$TASK_EXECUTION_KIND" = "report_only" ]; then
    if ! task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
      SUCCESS="false"
      FAILURE_CODE="REPORT_ONLY_SOURCE_INVALID"
      FAIL_REASON="Report-only execution is supported only for Todo task sources"
    elif [ ! -s "$STDOUT_FILE" ]; then
      SUCCESS="false"
      FAILURE_CODE="REPORT_ONLY_ANSWER_EMPTY"
      FAIL_REASON="Report-only agent returned no answer to persist"
    else
      local REPORT_ANSWER REPORT_RECEIPT REPORT_DELIVERY_RC REPORT_ROOT_ID REPORT_RESULT_ID REPORT_DIGEST
      REPORT_ANSWER="$(python3 - "$STDOUT_FILE" <<'PY_REPORT_ANSWER'
import re
import sys
from pathlib import Path

output = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
lines = [line for line in output.splitlines() if not re.match(r"^TASK_(?:DONE|COMPLETED)(?:\s|$)", line)]
print("\n".join(lines).strip())
PY_REPORT_ANSWER
)" || REPORT_ANSWER=""
      if [ -z "$(printf '%s' "$REPORT_ANSWER" | tr -d '[:space:]')" ]; then
        SUCCESS="false"
        FAILURE_CODE="REPORT_ONLY_ANSWER_EMPTY"
        FAIL_REASON="Report-only agent emitted TASK_DONE without a non-empty answer"
      else
        REPORT_DELIVERY_RC=0
        REPORT_RECEIPT="$(task_source_report_deliver "$CONFIG" "$TASK_SOURCE_TYPE" "$TASK_SOURCE_ID" "$REPORT_ANSWER")" || REPORT_DELIVERY_RC=$?
        REPORT_ROOT_ID="${TASK_SOURCE_ID%%@*}"
        if [ "$REPORT_DELIVERY_RC" -ne 0 ] || ! jq -e --arg sourceId "$TASK_SOURCE_ID" --argjson rootId "$REPORT_ROOT_ID" '
          .sourceId == $sourceId
          and .rootTaskId == $rootId
          and (.answer | type == "string" and length > 0)
          and (.resultTaskId | type == "number" and . > 0)
          and (.answerSha256 | type == "string" and test("^[0-9a-f]{64}$"))
        ' <<<"$REPORT_RECEIPT" >/dev/null 2>&1; then
          SUCCESS="false"
          FAILURE_CODE="TODO_REPORT_DELIVERY_FAILED"
          FAIL_REASON="The report answer could not be persisted and verified as a Todo subtask; the Todo root remains active"
          log "ERROR: report-only delivery failed for Todo source $TASK_SOURCE_ID (rc=$REPORT_DELIVERY_RC)"
          lc_log "TODO_REPORT_DELIVERY_FAILED" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE rc=$REPORT_DELIVERY_RC"
        else
          REPORT_RESULT_ID="$(jq -r '.resultTaskId' <<<"$REPORT_RECEIPT")"
          REPORT_DIGEST="$(jq -r '.answerSha256' <<<"$REPORT_RECEIPT")"
          local safe_report_receipt safe_report_summary report_update_result report_update_changes
          safe_report_receipt="$(sql_escape "$REPORT_RECEIPT")"
          safe_report_summary="$(sql_escape "Verified Todo report subtask #$REPORT_RESULT_ID (sha256 $REPORT_DIGEST)")"
          report_update_result="$(sqlite3 "$DB" "UPDATE processed_comments SET resultJson='$safe_report_receipt', resultSummary='$safe_report_summary' WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>>"$LOG")" || report_update_result=""
          report_update_changes="$(printf '%s\n' "$report_update_result" | tail -n 1)"
          if [ "$report_update_changes" != "1" ]; then
            SUCCESS="false"
            FAILURE_CODE="TODO_REPORT_RECEIPT_PERSIST_FAILED"
            FAIL_REASON="Todo contains the verified report subtask, but Manul could not persist its local delivery receipt; retry will safely reuse the same subtask"
            log "ERROR: could not persist report-only receipt for task $COMMENT_ID (changes=${report_update_changes:-unknown})"
            lc_log "TODO_REPORT_RECEIPT_PERSIST_FAILED" "task=$COMMENT_ID result=$REPORT_RESULT_ID"
          else
            log "dispatch: report-only answer verified in Todo subtask #$REPORT_RESULT_ID (sha256=$REPORT_DIGEST)"
            lc_log "TODO_REPORT_DELIVERY_VERIFIED" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE result=$REPORT_RESULT_ID sha256=$REPORT_DIGEST"
            FINAL_COMMENT="Report saved as Todo subtask #$REPORT_RESULT_ID."
          fi
        fi
      fi
    fi
  fi
  # GitHub-rooted tasks require a deterministic result-comment receipt.
  # Todo tasks instead use the source MCP and do not have a GitHub issue thread.
  if [ "$SUCCESS" = "true" ] && ! task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
    if ! verify_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt"; then
      SUCCESS="false"
      FAILURE_CODE="DELIVERY_COMMENT_MISSING"
      FAIL_REASON="Delivery rejected: no result comment with the required task/attempt marker was verified"
      log "ERROR: task $COMMENT_ID attempt $current_attempt missing required result marker; refusing success"
      lc_log "RESULT_COMMENT_INVALID" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$current_attempt action=fail"
    else
      log "dispatch: task $COMMENT_ID attempt $current_attempt result comment marker verified"
    fi
  fi

  # Mark the root Todo task and its complete ordered subtask tree done only
  # after implementation delivery has been independently verified above.
  if [ "$SUCCESS" = "true" ] && task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
    if task_source_complete "$CONFIG" "$TASK_SOURCE_TYPE" "$TASK_SOURCE_ID"; then
      log "dispatch: Todo task tree $TASK_SOURCE_ID marked done"
      lc_log "TODO_SOURCE_COMPLETED" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE"
    else
      SUCCESS="false"
      FAILURE_CODE="TODO_SOURCE_UPDATE_FAILED"
      if [ "$TASK_EXECUTION_KIND" = "report_only" ]; then
        FAIL_REASON="The Todo report was saved, but the task tree could not be marked done. The Todo root remains open and the result subtask can be safely reused on retry."
      else
        FAIL_REASON="Repository delivery was verified, but the Todo task tree could not be marked done. The Todo source remains open."
      fi
      log "ERROR: Todo source completion failed for task $TASK_SOURCE_ID"
      lc_log "TODO_SOURCE_COMPLETION_FAILED" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE"
    fi
  fi

  # 8. Update SQLite using enhanced finalization with verification
  if [ "$SUCCESS" = "true" ]; then
    # Enhanced task completion with verification
    if complete_task_with_verification "$COMMENT_ID" "$CLAIM_TOKEN"; then
      COMPLETION_SUCCESS="true"
    else
      log "ERROR: Enhanced task completion failed for $COMMENT_ID, falling back to basic completion"
      # Fallback: attempt direct completion with ownership verification
      local fallback_worker_pid
      fallback_worker_pid="$BASHPID"
      local fallback_claim_token
      fallback_claim_token="$(sql_escape "$CLAIM_TOKEN")"
      local fallback_result
      fallback_result="$(sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL WHERE commentId='$safe_comment_id' AND status='running' AND workerPid=$fallback_worker_pid AND claimToken='$fallback_claim_token'; SELECT changes();" 2>/dev/null)"
      local fallback_changes
      fallback_changes="$(echo "$fallback_result" | tail -n 1)"
      if [ "${fallback_changes:-0}" -eq 1 ]; then
        # Verify the row is actually completed
        local verify_status
        verify_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
        if [ "$verify_status" = "completed" ]; then
          COMPLETION_SUCCESS="true"
          log "SUCCESS: Task $COMMENT_ID completed via fallback path"
        else
          log "ERROR: Fallback completion failed verification (status=$verify_status)"
        fi
      else
        log "ERROR: Fallback completion failed (changes=$fallback_changes)"
      fi
    fi
    
    if [ "$COMPLETION_SUCCESS" = "true" ]; then
      FINAL_COMMENT="✅ Manul completed the task successfully."
      log "dispatch: task $COMMENT_ID completed successfully"
    else
      FINAL_COMMENT="❌ Manul completed the work but failed to update task state."
      log "ERROR: task $COMMENT_ID finalization failed - SQLite update did not succeed"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=finalization_failed"
    fi
  else
    # Re-read attempts from DB to ensure accuracy
    local NEW_ATTEMPTS
    NEW_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null || echo "0")"
    local MAX_ATTEMPTS
    MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"
    
    if [ "$FAILURE_CODE" = "RUNTIME_PERMISSION_BLOCKED" ]; then
      # Permission denials are deterministic until the operator/policy changes.
      # Do not burn the remaining attempts re-running the same blocked tool call.
      if update_task_completion "$COMMENT_ID" "failed" "$FAIL_REASON" "$CLAIM_TOKEN"; then
        log "dispatch: task $COMMENT_ID stopped after an OpenCode permission-policy rejection"
      else
        log "ERROR: task $COMMENT_ID could not transition to failed after permission-policy rejection"
      fi
      FINAL_COMMENT="⛔ Manul stopped this task because OpenCode's permission policy rejected a tool call. Automatic retries will not change that policy; fix the specific permission/path and trigger the task again.${FAIL_REASON:+ Reason: $FAIL_REASON}"
      lc_log "TASK_FAILED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempts=$NEW_ATTEMPTS reason=permission_policy_blocked${FAIL_REASON:+ detail=$FAIL_REASON}"
    elif [ "${NEW_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
      # Persist the terminal state before posting the final lifecycle comment.
      # A max-attempt failure is terminal; leaving the row as running causes
      # watchdog/recovery churn and can make a failed workspace look active.
      if update_task_completion "$COMMENT_ID" "failed" "$FAIL_REASON" "$CLAIM_TOKEN"; then
        log "dispatch: task $COMMENT_ID transitioned to failed after max attempts"
      else
        log "ERROR: task $COMMENT_ID could not transition to failed after max attempts"
      fi
      FINAL_COMMENT="❌ Manul failed to complete the task after $NEW_ATTEMPTS attempts.${FAIL_REASON:+ Reason: $FAIL_REASON}"
      log "dispatch: task $COMMENT_ID failed (max attempts reached)"
      lc_log "TASK_FAILED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempts=$NEW_ATTEMPTS max=$MAX_ATTEMPTS${FAIL_REASON:+ reason=$FAIL_REASON}${FAILURE_CODE:+ failure_code=$FAILURE_CODE}"
    else
      # Persist running -> queued under the current claim token before saying
      # that the task will retry. Leaving this row running strands retries and
      # makes the watchdog recover it as a stale worker later.
      if update_task_completion "$COMMENT_ID" "queued" "$FAIL_REASON" "$CLAIM_TOKEN"; then
        FINAL_COMMENT="⚠️ Manul encountered an issue and will retry (attempt $NEW_ATTEMPTS/$MAX_ATTEMPTS)."
        if [ -n "$FAIL_REASON" ]; then FINAL_COMMENT+=" Reason: $FAIL_REASON"; fi
        log "dispatch: task $COMMENT_ID requeued for retry (attempt $NEW_ATTEMPTS)"
        lc_log "TASK_REQUEUED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$NEW_ATTEMPTS max=$MAX_ATTEMPTS reason=$FAIL_REASON failure_code=$FAILURE_CODE"
      else
        # Ownership may have changed; never claim it was requeued when the
        # conditional state transition did not succeed.
        FINAL_COMMENT="⚠️ Manul could not safely schedule the retry for this task. The daemon will need to recover it before another attempt."
        log "ERROR: task $COMMENT_ID retry transition failed; status was not confirmed as queued"
        lc_log "TASK_REQUEUE_FAILED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempt=$NEW_ATTEMPTS reason=$FAIL_REASON failure_code=$FAILURE_CODE"
      fi
    fi
  fi
}

# Poll GitHub and enqueue source events. This path never claims or executes tasks.
poll_once() {
  # Use timeout to prevent daemon deadlock if poll.sh hangs
  # This can happen if gh API is unresponsive or network is blocked.
  # The default scales with the number of configured repositories so one
  # slow repo (per-repo timeout) cannot starve the whole cycle: each repo
  # gets REPO_POLL_TIMEOUT + 10s buffer, with a 60s floor.
  local poll_timeout="${MANUL_POLL_TIMEOUT:-$(( ${#REPOS[@]} * (REPO_POLL_TIMEOUT + 10) + 60 ))}"
  # Capture poll.sh output to a file so a partial result emitted by poll.sh's
  # signal trap (when the global timeout kills it mid-cycle) is NOT lost.
  # Poll results remain useful for observability even though consumers now read
  # SQLite independently and never gate dispatch on the poller's result.
  local poll_out_file
  poll_out_file="$(mktemp)"
  local poll_rc=0
  timeout "$poll_timeout" "$POLL" >"$poll_out_file" 2>&1 || poll_rc=$?
  local out
  out="$(cat "$poll_out_file" 2>/dev/null)"
  rm -f "$poll_out_file"

  if [ "$poll_rc" -ne 0 ]; then
    if [ "$poll_rc" -eq 124 ]; then
      log "WARN: poll.sh hit global timeout after ${poll_timeout}s; using any partial result it emitted before dying"
      lc_log "POLL_TIMEOUT" "timeout=${poll_timeout}s"
      pkill -f "bash.*$POLL" 2>/dev/null || true
    else
      log "ERROR: poll.sh failed with rc=$poll_rc"
      lc_log "POLL_ERROR" "rc=$poll_rc"
    fi
  fi

  # Record poll result for observability. poll.sh writes diagnostics to stderr,
  # so stdout+stderr can contain arbitrary lines around the final MANUL_RESULT.
  # Parse exactly one complete MANUL_RESULT line and validate it before reading fields.
  local poll_fire poll_new poll_pending
  IFS='|' read -r poll_fire poll_new poll_pending < <(parse_poll_result "$out")
  record_poll "$poll_fire" "$poll_new" "$poll_pending"

  if [ "$poll_fire" = "true" ]; then
    log "poller: $out"
    lc_log "POLL" "fire=true new=$poll_new pending=$poll_pending"
  else
    lc_log "POLL" "fire=false new=$poll_new pending=$poll_pending"
  fi

}

dispatch_once() {
  retry_pending_terminal_lifecycle_comments || log "WARN: terminal lifecycle outbox scan failed"

  # SQLite is the sole input to the consumer. Polling is handled by a
  # separate producer process and can never block this queue check.
  local eligible_queued
  eligible_queued="$(eligible_queued_count)"
  if [ "${eligible_queued:-0}" -eq 0 ]; then
    return 0
  fi
  log "dispatch: SQLite has eligible queued task(s); attempting dispatch"
  lc_log "QUEUE_WAKEUP" "eligible=$eligible_queued"

  # Serialize shared workspace reconciliation with task claiming. With a
  # short consumer interval, several workers can see the same queued row at once.
  if ! acquire_task_lock; then
    log "dispatch: could not acquire lock, skipping"
    lc_log "LOCK_FAIL" "could_not_acquire"
    return 0
  fi

  # Report-only Todo tasks do not need a repository workspace pool. Inspect
  # the same oldest eligible row the claim query below will select.
  local next_task_id next_task_context next_execution_kind
  next_task_id="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE status='queued' AND (nextAttemptAt IS NULL OR datetime(nextAttemptAt) <= datetime('now')) ORDER BY createdAt ASC, nextAttemptAt ASC NULLS FIRST LIMIT 1;" 2>/dev/null)"
  next_task_context="$(sqlite3 "$DB" "SELECT context FROM processed_comments WHERE commentId='$(sql_escape "$next_task_id")' LIMIT 1;" 2>/dev/null)"
  next_execution_kind="$(printf '%s' "$next_task_context" | jq -r '.execution.kind // "repository"' 2>/dev/null || echo "repository")"
  if [ "$next_execution_kind" != "report_only" ]; then
    if ! ensure_workspace_pool; then
      log "dispatch: workspace pool reconciliation failed"
      lc_log "WORKSPACE_POOL_ERROR" "need=$MAX_CONCURRENT_TASKS"
      release_task_lock
      return 0
    fi
  else
    log "dispatch: report-only Todo task $next_task_id skips repository workspace pool"
    lc_log "REPORT_ONLY_DISPATCH" "task=$next_task_id phase=workspace_pool_skipped"
  fi

    # 1. Find next eligible task using proper SQLite query with retry backoff
    # Query only the fields we need, not the prompt (which may contain |)
    local TASK_INFO
    # Select the oldest task that is actually eligible now. A retry with a
    # future nextAttemptAt must never monopolize the singleton dispatcher and
    # starve a fresh task that is ready to run.
    TASK_INFO="$(sqlite3 "$DB" "SELECT commentId, repository, issueNumber, attempts FROM processed_comments WHERE status='queued' AND (nextAttemptAt IS NULL OR datetime(nextAttemptAt) <= datetime('now')) ORDER BY createdAt ASC, nextAttemptAt ASC NULLS FIRST LIMIT 1;" 2>/dev/null)"

    if [ -z "$TASK_INFO" ]; then
      log "dispatch: queued task was no longer eligible at claim time"
      lc_log "NO_TASK" "reason=queue_empty"
      release_task_lock
      return 0
    fi

    # Safe parsing: only three simple fields separated by |
    local COMMENT_ID REPO ISSUE_NUM ATTEMPTS
    IFS='|' read -r COMMENT_ID REPO ISSUE_NUM ATTEMPTS <<< "$TASK_INFO"
    [ -n "$COMMENT_ID" ] || { release_task_lock; return 0; }

    # 0.5 Completed-task guard - check if GitHub trigger is already completed
    # This must run AFTER TASK_INFO parsing so COMMENT_ID, REPO, ISSUE_NUM are available
    # Uses deterministic correlation via commentUrl to identify exact task completion
    local safe_comment_id_for_guard
    safe_comment_id_for_guard="$(sql_escape "$COMMENT_ID")"
    local safe_comment_url_for_guard
    safe_comment_url_for_guard="$(sql_escape "$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id_for_guard';" 2>/dev/null)")"

    if [ -n "$safe_comment_url_for_guard" ]; then
      # Check if this exact task is already completed by commentId
      local already_completed
      already_completed="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='$safe_comment_id_for_guard' AND status='completed';" 2>/dev/null || echo "0")"

      if [ "$already_completed" -gt 0 ]; then
        log "dispatch: task $COMMENT_ID already completed (duplicate detected via commentId), consuming safely"
        lc_log "DUPLICATE_COMPLETE" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM reason=already_completed"
        # Mark as completed to consume the duplicate without losing history
        sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now') WHERE commentId='$safe_comment_id_for_guard' AND status='queued';" 2>/dev/null
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi

      # Also check if an equivalent task with same commentUrl was completed
      # This handles cases where the trigger was re-issued with a new commentId but same source
      local duplicate_by_url
      duplicate_by_url="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentUrl='$safe_comment_url_for_guard' AND status='completed';" 2>/dev/null || echo "0")"

      if [ "$duplicate_by_url" -gt 0 ]; then
        log "dispatch: task $COMMENT_ID already completed (duplicate detected via commentUrl), consuming safely"
        lc_log "DUPLICATE_COMPLETE" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM reason=by_url"
        sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt=datetime('now') WHERE commentId='$safe_comment_id_for_guard' AND status='queued';" 2>/dev/null
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi
    else
      # GitHub lookup failed or commentUrl is empty - leave task queued and log error
      log "WARN: dispatch: could not retrieve commentUrl for task $COMMENT_ID, leaving queued"
      lc_log "GUARD_ERROR" "task=$COMMENT_ID reason=missing_comment_url"
    fi

    # Escape for SQL
    local safe_comment_id
    safe_comment_id="$(sql_escape "$COMMENT_ID")"
    local safe_repo
    safe_repo="$(sql_escape "$REPO")"
    # Derive the reply target before any lifecycle comment is posted.
    # Review-thread tasks must keep every daemon lifecycle message in the same
    # inline review thread; top-level PR comments are reserved for PR conversation tasks.
    local REPLY_TO=""
    if [[ "$COMMENT_ID" =~ ^review:([0-9]+)$ ]]; then
      REPLY_TO="${BASH_REMATCH[1]}"
    elif [[ "$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$(sql_escape "$COMMENT_ID")' LIMIT 1;" 2>/dev/null)" == *"/pull/"*"#discussion_r"* ]]; then
      local source_comment_url
      source_comment_url="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$(sql_escape "$COMMENT_ID")' LIMIT 1;" 2>/dev/null)"
      REPLY_TO="$(printf '%s' "$source_comment_url" | sed -n 's|.*#discussion_r\([0-9][0-9]*\).*|\1|p')"
    fi

    # Read actual attempts from database (authoritative source)
    local ACTUAL_ATTEMPTS
    ACTUAL_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id' AND status='queued';" 2>/dev/null || echo "0")"

    # Check max attempts BEFORE claiming (guard against watchdog recovery resetting attempts)
    local MAX_ATTEMPTS
    MAX_ATTEMPTS="$(jq -r '.automation.maxAttemptsBeforeFail // 3' "$CONFIG" 2>/dev/null || echo 3)"
    if [ "${ACTUAL_ATTEMPTS:-0}" -ge "$MAX_ATTEMPTS" ]; then
      log "dispatch: task $COMMENT_ID already at max attempts ($ACTUAL_ATTEMPTS >= $MAX_ATTEMPTS), marking as failed"
      lc_log "TASK_MAX_ATTEMPTS" "task=$COMMENT_ID repo=$REPO attempts=$ACTUAL_ATTEMPTS max=$MAX_ATTEMPTS"
      sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt=datetime('now'), heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=NULL WHERE commentId='$safe_comment_id' AND status='queued' AND attempts >= $MAX_ATTEMPTS;" 2>/dev/null
      local FINAL_COMMENT="❌ Manul failed to complete the task after $ACTUAL_ATTEMPTS attempts (max reached)."
      post_lifecycle_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO" || log "WARN: failed to post lifecycle comment for $COMMENT_ID"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    if ! ensure_recovery_tracking_columns; then
      log "dispatch: recovery tracking schema unavailable; leaving queued tasks untouched"
      lc_log "TASK_SCHEMA_ERROR" "phase=pre_claim"
      release_task_lock
      return 0
    fi

    # 2. Atomically claim the task (queued -> running, attempts+1)
    # Prevent claiming if another worker already owns this task
    local CURRENT_WORKER_PID
    CURRENT_WORKER_PID="$BASHPID"
    local CLAIM_TOKEN
    CLAIM_TOKEN="$(printf '%s-%s-%s' "$(date +%s%N)" "$CURRENT_WORKER_PID" "$RANDOM")"
    local safe_claim_token
    safe_claim_token="$(sql_escape "$CLAIM_TOKEN")"
    local CLAIM_RESULT
    CLAIM_RESULT="$(sqlite3 "$DB" "UPDATE processed_comments SET status='running', attempts=attempts+1, processedAt=datetime('now'), heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now', '+${LEASE_TIMEOUT} seconds'), workerPid=$CURRENT_WORKER_PID, claimToken='$safe_claim_token', agentStartedAt=NULL WHERE commentId='$safe_comment_id' AND status='queued' AND (workerPid IS NULL OR workerPid=0); SELECT changes();" 2>/dev/null)"

    local CHANGED
    CHANGED="$(echo "$CLAIM_RESULT" | tail -n 1)"

    if [ "${CHANGED:-0}" -ne 1 ]; then
      log "dispatch: task $COMMENT_ID not claimed (changed=$CHANGED)"
      lc_log "CLAIM_FAIL" "task=$COMMENT_ID changed=$CHANGED"
      release_task_lock
      return 0
    fi

    # 3. Read task details after claiming — query each field separately
    # to avoid pipe-delimited parsing issues with prompt containing |
    local COMMENT_URL AUTHOR AGENT TASK_PROMPT TASK_CONTEXT TASK_ACTION CONVERSATION_ID
    COMMENT_URL="$(sqlite3 "$DB" "SELECT commentUrl FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    CONVERSATION_ID="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    AUTHOR="$(sqlite3 "$DB" "SELECT author FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    AGENT="$(sqlite3 "$DB" "SELECT agent FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_PROMPT="$(sqlite3 "$DB" "SELECT prompt FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_CONTEXT="$(sqlite3 "$DB" "SELECT context FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_ACTION="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_ACTION="${TASK_ACTION:-IMPLEMENT}"
    local TASK_EXECUTION_KIND
    TASK_EXECUTION_KIND="$(printf '%s' "$TASK_CONTEXT" | jq -r '.execution.kind // "repository"' 2>/dev/null || echo "repository")"
    case "$TASK_EXECUTION_KIND" in
      repository|report_only) ;;
      *)
        log "dispatch: refusing unsupported execution kind '$TASK_EXECUTION_KIND' for task $COMMENT_ID"
        mark_task_stale "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN"
        release_task_lock
        set_activity "none" "idle"
        return 0
        ;;
    esac
    local TASK_SOURCE_TYPE TASK_SOURCE_ID
    TASK_SOURCE_TYPE="$(sqlite3 "$DB" "SELECT COALESCE(taskSourceType,'') FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    TASK_SOURCE_ID="$(sqlite3 "$DB" "SELECT COALESCE(taskSourceId,'') FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    if [ "$TASK_EXECUTION_KIND" = "report_only" ] && ! task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
      log "dispatch: refusing report-only execution for non-Todo source $TASK_SOURCE_TYPE"
      mark_task_stale "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN"
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi
    local TASK_AUTO_ACCEPT
    TASK_AUTO_ACCEPT="$(sqlite3 "$DB" "SELECT autoAccept FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    case "$TASK_AUTO_ACCEPT" in 1|true|TRUE) TASK_AUTO_ACCEPT=1 ;; *) TASK_AUTO_ACCEPT=0 ;; esac

    # Self-heal legacy issuebody tasks whose issueNumber contains the GitHub
    # API object ID instead of the human-facing issue number.
    if [[ "$COMMENT_ID" == issuebody:* && "$COMMENT_URL" =~ /issues/([0-9]+)(/|#|$) ]]; then
      local source_issue_num="${BASH_REMATCH[1]}"
      if [ "$ISSUE_NUM" != "$source_issue_num" ]; then
        log "dispatch: correcting issuebody $COMMENT_ID issueNumber $ISSUE_NUM -> $source_issue_num from source URL"
        ISSUE_NUM="$source_issue_num"
      fi
    fi

    log "dispatch: claimed task $COMMENT_ID ($REPO#$ISSUE_NUM), attempts now $((ACTUAL_ATTEMPTS + 1))"
    lc_log "CLAIMED" "task=$COMMENT_ID repo=$REPO issue=$ISSUE_NUM attempts=$((ACTUAL_ATTEMPTS + 1))"
    local current_attempt=$((ACTUAL_ATTEMPTS + 1))
    set_activity "$COMMENT_ID" "claimed"

    # 3.5 Pre-flight source revalidation — terminal if source no longer valid
    local reval_rc=0
    if task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
      task_source_revalidate "$CONFIG" "$TASK_SOURCE_TYPE" "$TASK_SOURCE_ID" || reval_rc=$?
    else
      revalidate_source "$COMMENT_ID" "$REPO" "$ISSUE_NUM" "$COMMENT_URL" || reval_rc=$?
    fi
    if [ "$reval_rc" -eq 1 ]; then
      log "dispatch: source stale for task $COMMENT_ID, marking terminal"
      lc_log "SOURCE_STALE_REVAL" "task=$COMMENT_ID repo=$REPO rc=$reval_rc"
      mark_task_stale "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN"
      stop_heartbeat "$COMMENT_ID"
      if [ "$TASK_EXECUTION_KIND" != "report_only" ]; then
        release_repo_lock "$REPO"
      fi
      release_task_lock
      set_activity "none" "idle"
      return 0
    elif [ "$reval_rc" -eq 2 ]; then
      log "dispatch: source transient error for task $COMMENT_ID, requeuing with bounded pre-agent infrastructure budget"
      lc_log "SOURCE_TRANSIENT_REVAL" "task=$COMMENT_ID repo=$REPO rc=$reval_rc"
      requeue_task "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$REPLY_TO" "$current_attempt"
      return 0
    fi

    # Start heartbeat for long-running task
    start_heartbeat "$COMMENT_ID" "$CURRENT_WORKER_PID" "$CLAIM_TOKEN"
    # Refresh heartbeat immediately so watchdog doesn't see stale timestamp
    refresh_heartbeat "$COMMENT_ID"

    # Mark the transition to actual agent execution BEFORE posting the
    # in-progress comment that embeds the TASK_STARTED event marker. This
    # ordering prevents stale recovery from reusing an attempt number after
    # the comment is already visible to the user.
    local agent_start_changed
    agent_start_changed="$(sqlite3 "$DB" "UPDATE processed_comments SET agentStartedAt=datetime('now') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token'; SELECT changes();" 2>>"$LOG" | tail -n 1)" || agent_start_changed="0"
    if [ "$agent_start_changed" != "1" ]; then
      log "ERROR: could not record the agent-start marker for task $COMMENT_ID (changes=${agent_start_changed:-unknown})"
      lc_log "TASK_ERROR" "task=$COMMENT_ID reason=agent_start_marker_failed"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Could not record the agent-start marker before posting the lifecycle comment." "${PR_NUM_FROM_URL:-}" "$current_attempt" "agent_start_marker"
      return 0
    fi

    # 4. Post "in progress" comment BEFORE invoking the LLM
    # Gather task metadata for an informative status comment
    local TRIGGERER="$AUTHOR"
    local SOURCE_LINK="$COMMENT_URL"
    local TASK_SUMMARY
    TASK_SUMMARY="$(printf '%s' "$TASK_PROMPT" | head -1 | cut -c1-80)"

    local start_conv_id
    start_conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
    local start_event_data
    start_event_data="$(jq -nc --arg taskId "$COMMENT_ID" --arg conversationId "$start_conv_id" --arg attempt "$current_attempt" '{taskId:$taskId,conversationId:$conversationId,status:"started",attempt:($attempt|tonumber)}')"
    local start_event_marker
    start_event_marker="<!-- manul:event $(printf '%s' "$start_event_data" | jq -c --arg type "TASK_STARTED" --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{type:$type,timestamp:$timestamp,data:.}') -->"

    local IN_PROGRESS_BODY="$start_event_marker

🔄 Manul is working on this task...

**Summary:** $TASK_SUMMARY
**Triggered by:** $TRIGGERER
**Source:** $SOURCE_LINK"

    if ! publish_task_started_for_claim "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "" "$REPLY_TO" "$IN_PROGRESS_BODY" "${PR_NUM_FROM_URL:-}" "$current_attempt"; then
      # The wrapper has either requeued the claim as a pre-agent failure or
      # left it for watchdog recovery. Never continue to prompt/runtime launch.
      return 0
    fi

    # 5. Create per-task prompt containing the actual task payload
    local TASK_PROMPT_DIR="$MANUL_TASKS_DIR"
    mkdir -p "$TASK_PROMPT_DIR"
    local TASK_PROMPT_FILE
    TASK_PROMPT_FILE="$(manul_task_file_path "$TASK_PROMPT_DIR" "$COMMENT_ID" "md")"

    # Determine task type from commentUrl metadata (do NOT call gh pr view)
    local TASK_TYPE="issue"
    local PR_HEAD_BRANCH=""
    if [[ "$COMMENT_URL" == *"/pull/"* ]]; then
      if [[ "$COMMENT_URL" == *"#discussion_r"* ]]; then
        TASK_TYPE="pr_review_comment"
        # Extract numeric review comment ID from commentId prefix (review:<id>)
        REPLY_TO="${COMMENT_ID#review:}"
      else
        TASK_TYPE="pr_conversation_comment"
      fi
      # Extract PR number from URL for branch resolution
      PR_NUM_FROM_URL="$(printf '%s' "$COMMENT_URL" | grep -oE 'pull/[0-9]+' | grep -oE '[0-9]+' || echo "")"
      if [ -n "$PR_NUM_FROM_URL" ] && [ "$PR_NUM_FROM_URL" != "$ISSUE_NUM" ]; then
        ISSUE_NUM="$PR_NUM_FROM_URL"
      fi
      # Fetch PR head branch for PR-tied tasks
      if [ -n "$PR_NUM_FROM_URL" ]; then
        PR_HEAD_BRANCH="$(gh pr view "$ISSUE_NUM" --repo "$REPO" --json headRefName --jq '.headRefName // ""' 2>>"$LOG" || echo "")"
      fi
    fi

    cat > "$TASK_PROMPT_FILE" <<'PROMPT_EOF'
# Manul Task:

You are the Manul implementation agent. Complete ONE task and then emit exactly one of the completion markers.

## Task
- Repository: __REPO__
- Issue/PR: #__ISSUE_NUM__
- Comment ID: __COMMENT_ID__
- Comment URL: __COMMENT_URL__
- Task Type: __TASK_TYPE__
- Task Action: __TASK_ACTION__
- PR Number: __PR_NUMBER__
- Original Review Comment ID: __REPLY_TO__
- Manul Mode: __MANUL_MODE__

## User Request
PROMPT_EOF

    # Append multiline task prompt (literal, no shell expansion)
    printf '%s\n' "$TASK_PROMPT" >> "$TASK_PROMPT_FILE"

    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_EOF'

## Context
PROMPT_EOF

    # Append multiline task context (literal, no shell expansion)
    printf '%s\n' "$TASK_CONTEXT" >> "$TASK_PROMPT_FILE"

    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_EOF'
## Command Intent Guidance
Before taking any action, determine whether this task is:
- **Informational**: The user is asking a question, requesting an explanation, or seeking advice. Reply with a thoughtful answer via GitHub comment. Do NOT modify any repository files.
- **Repository Change**: The user wants code changes, fixes, features, or other modifications. Proceed with implementation on the appropriate branch.

If the task is informational, you MUST post a thoughtful answer as a GitHub comment using the `run` tool (see GitHub Comment Posting section below), then emit `TASK_DONE`. Do NOT modify any repository files.

## User interaction and decision points
1. Behave like a competent human teammate.
2. Make straightforward, low-risk decisions autonomously.
3. You may proactively propose a concrete solution, improvement, trade-off, or next step when you have enough information.
4. Do not ask the user merely because two equivalent implementations exist.
5. When multiple materially different valid approaches would change architecture, behavior, scope, compatibility, data model, UX, or another important outcome, involve the user.
6. When more than two materially different viable directions remain, briefly present the options and ask what to do next.
7. You may recommend one option and explain why, but leave the final choice to the user.
8. Before asking, inspect the repository, relevant skills/docs, configuration, and conversation context.
9. Do not guess when missing information materially affects correctness.
10. The user-facing decision request must summarize what you checked, explain why the uncertainty is material, and present the concrete options or decision required.
11. Once user input is required, avoid further irreversible repository changes and emit exactly one complete block:
`TASK_NEEDS_USER_BEGIN`
<findings, options, recommendation if useful, and explicit question/decision>
`TASK_NEEDS_USER_END`
12. Do not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same run as `TASK_NEEDS_USER_BEGIN/END`.
13. A partial or malformed user-decision block is not a valid pause; do not rely on it to stop execution.

## Operating mode
- `__MANUL_MODE__` is the configured Manul mode.
- In `bot` mode, follow the normal Manul attribution rules below.
- In `human` mode, behave like a human developer using GitHub: do not sign comments with "— manul 🐈", do not add any `Co-authored-by` trailer to commits, and do not post orchestration/status/error comments. Only post the actual user-facing result when the task requires a comment.
- In `human` mode, do not add Manul/OpenCode attribution merely because an AI skill normally asks for it. The human developer remains the sole visible author of commits.

## Result comment style
- The visible result comment is a GitHub teammate reply, not an automation report.
- The deterministic `<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->` marker is required, but it must remain invisible metadata.
- In `human` mode, keep the visible result concise and natural when `Human concise comments` is enabled:
  - lead with what was done or found;
  - normally keep it to at most `__HUMAN_COMMENT_MAX_LINES__` visible lines;
  - use roughly 1–3 short sentences when that is enough;
  - mention the PR/commit/test only when useful;
  - do not repeat the user's request;
  - do not use automation headings or fields such as `Task Completed`, `Task`, `Conversation`, `Attempt`, or `Summary`;
  - avoid boilerplate, tables, and unnecessary markdown;
  - write like a developer replying directly to a teammate.
- In `bot` mode, preserve the normal structured result-comment format and attribution rules.

## Rules
1. Inspect the local repository and implement the requested change.
2. Run appropriate tests/validation.
3. Make the requested code changes.
4. When finished, output exactly: `TASK_DONE`
5. If the task is blocked on a user decision, emit the TASK_NEEDS_USER block above.
6. If you cannot complete the task for a non-user-input failure, output exactly: `TASK_FAILED: <brief reason>`
7. Do NOT modify `manul.db`.
8. Do NOT manage Manul task state.

## Completion-marker protocol (mandatory)

The completion marker is a protocol message, not progress narration.
- Do not end a turn after describing the next action or saying you will make a change. Execute the next concrete step in the current turn, or emit the appropriate failure/user-input marker.
- Only after all requested work, validation, delivery checks, and the single result comment are complete, make the final assistant output exactly one line: `TASK_DONE` or `TASK_DONE <one-sentence summary>`.
- Do not emit `TASK_DONE` early, and do not append prose after the completion-marker line.

## PR Description Freshness (MANDATORY DELIVERY CONTRACT)

A pushed commit is not fully delivered until the GitHub PR description reflects the complete current PR and has been read back from GitHub.

- For a standalone task, immediately after the first successful push, create a real PR with a meaningful, non-empty description. Do not wait for the final implementation phase if the first push is a checkpoint.
- After EVERY later push to a branch with an open PR—including checkpoint, review-fix, and CI-fix pushes—update the description of that same PR before continuing the task or reporting the push as delivered.
- Rebuild the body from the cumulative PR diff and current verification results, not just the latest commit. Keep Summary, Changes, Testing, and related-issue references accurate; preserve still-valid issue-closing links. Do not blindly append bullets, which can leave stale or duplicated content.
- Write the full Markdown body to a temporary file and use `gh pr edit <PR_NUMBER> --body-file "$BODY_FILE"` (or the equivalent safe `--body-file` option for PR creation); never interpolate a body directly into a double-quoted shell argument.
- Read back with `gh pr view <PR_NUMBER> --json body,url,headRefName,baseRefName,headRefOid`. Verify the body is non-empty and accurate, the URL is the expected PR, the head/base are correct, and the head SHA matches the pushed commit.
- For an existing-PR task, update the original PR, never create a second PR. If creating/updating or read-back verification fails, report the precise blocker and do NOT emit `TASK_DONE`.

## GitHub Comment Posting (CRITICAL)
You MUST post exactly one user-facing result comment to GitHub using the `run` tool.

Before posting, query the source issue/PR for an existing result comment
containing the exact marker
`<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`.
If a result comment with that marker already exists, do NOT create another comment.
Update the existing comment in place with the final verified content using the safe
request-body method below. Only create a new comment when no result comment with that
marker exists. The final state must contain exactly one matching result comment for
this task/attempt.

### Safe request-body handling (MANDATORY)
Never put `YOUR_RESULT_COMMENT` or `YOUR_REPLY` directly inside shell quotes such as `-f body="..."`.
Markdown backticks, `$(...)`, quotes, and other shell metacharacters in the comment body
can then be interpreted by the shell.

Build the complete comment body as literal file content, then send JSON through
`--input`. Use a quoted heredoc (or an equivalent non-evaluating file/stdin method):

```bash
RESULT_FILE="$(mktemp)"
cat >"$RESULT_FILE" <<'RESULT_EOF'
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Summary: [brief summary]

[detailed result]

— manul 🐈
RESULT_EOF

jq -n --rawfile body "$RESULT_FILE" '{body:$body}' |
  gh api repos/__REPO__/issues/__ISSUE_NUM__/comments --input - --jq .id

rm -f "$RESULT_FILE"
```

For an existing top-level result comment:
```bash
jq -n --rawfile body "$RESULT_FILE" '{body:$body}' |
  gh api --method PATCH repos/__REPO__/issues/comments/<RESULT_COMMENT_ID> --input -
```

For a PR review-thread reply:
```bash
jq -n --rawfile body "$RESULT_FILE" --argjson reply_id __REPLY_TO__ '{body:$body, in_reply_to:$reply_id}' |
  gh api repos/__REPO__/pulls/__PR_NUMBER__/comments --input - --jq .id
```

Do NOT use `-f body="..."` or `-F body="..."` for a user-facing result/reply comment.

### Routing
Use the task metadata above and choose the endpoint that matches `Task Type`:

- For `pr_review_comment`: reply to the existing inline review thread using the PR review-comments endpoint and the original review comment ID.
- For `pr_conversation_comment` or an issue task: post a top-level conversation comment.

Do NOT use `/issues/__ISSUE_NUM__/comments` with `in_reply_to`: that endpoint does not create replies to inline PR review threads.
Replace REPO, PR_NUMBER, ISSUE_NUM, and the result body with the actual values from this prompt.

Your comment MUST:
- Start with the task summary
- Include the deterministic task/attempt marker: `<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`
- Include your actual work/output
- In `bot` mode, end with: "— manul 🐈".
- In `human` mode, do NOT add a Manul signature or AI attribution.
- Be posted BEFORE emitting TASK_DONE

Example informational task response:
```
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Available Skills

[Your skill listing here]

— manul 🐈
```

The daemon handles lifecycle comments (🔄 working, ✅ completed, ❌ failed, ❓ needs user).
For a normal task, you handle the result comment. When you emit TASK_NEEDS_USER_BEGIN/END, do NOT post a normal result comment; the daemon will post the question and resume the same task after the user replies.
PROMPT_EOF

    if task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
      cat >> "$TASK_PROMPT_FILE" <<'TODO_SOURCE_PROMPT'

## Todo Source Delivery Override — takes precedence over the generic GitHub comment instructions above

This task originates from a Todo task tree, not a GitHub issue or comment.
- Do NOT post a GitHub issue comment, PR conversation comment, PR review comment, or a Manul result-marker comment. The source URL is a Todo MCP identifier, not a GitHub URL.
- Do NOT call `gh issue comment` or GitHub comment APIs for this task.
- The task root and its ordered subtask tree are supplied above. Treat the subtasks as the implementation plan: execute pending steps in the exact order shown; keep nested children immediately after their parent; [DONE] steps are context and must not be repeated.
- Preserve the order from Todo; do not sort or parallelize steps by priority, title, or perceived complexity.
- Make repository changes using the normal Manul branch/commit/push/PR workflow. A real PR and its updated description remain required whenever repository files change. Include the Todo task ID in the branch name, PR title, and PR body so the work can be traced to the source task.
- A task that is informational or genuinely requires no repository change may finish without a PR, but must still give a concrete result in the final agent response.
- Do NOT change Todo task completion state yourself. After delivery verification, Manul will re-read the source tree and mark the root and every descendant subtask done through the same MCP source adapter. Do not mark a step done early.
- Do NOT emit a TASK_NEEDS_USER block: Todo sources have no GitHub conversation or /manul continue reply channel. Resolve routine ambiguity autonomously. If a material decision truly requires the user, stop and emit TASK_FAILED: with the exact missing input, what you checked, and the available choices; leave the Todo task open. The user can update the Todo description/subtasks with that input, producing a new structural source version.
- Finish with the existing TASK_DONE / TASK_FAILED protocol. Do not emit a GitHub result comment as part of that protocol.

TODO_SOURCE_PROMPT
    fi

    local REPO_DIR="" WORKDIR="" WORKSPACE_ID="" workspace_path=""
    local CURRENT_BRANCH="report-only" INITIAL_BRANCH="report-only" INITIAL_HEAD="" DEFAULT_BRANCH="" INITIAL_BASE_BRANCH=""
    local RELATED_REPOSITORIES="" RELATED_UNAVAILABLE="" REPORT_ONLY_DIR=""
    if [ "$TASK_EXECUTION_KIND" = "report_only" ]; then
      REPORT_ONLY_DIR="$(mktemp -d /tmp/manul-report-only.XXXXXX)" || {
        handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "" "$REPLY_TO" "Could not create an isolated scratch directory for the report-only task." "" "$current_attempt" "report_only_workspace"
        return 0
      }
      workspace_path="$REPORT_ONLY_DIR"
      WORKDIR="$REPORT_ONLY_DIR"
      TASK_TYPE="todo_report"
      PR_HEAD_BRANCH=""
      REPLY_TO=""
      cat >> "$TASK_PROMPT_FILE" <<'REPORT_ONLY_PROMPT'

## Report-only execution contract — overrides every generic repository/GitHub instruction above

This is a report-only Todo task. No repository is assigned and no repository checkout exists.
- Do not run git, gh, repository commands, create/edit files outside the isolated scratch directory below, create branches, commit, push, or open a pull request.
- Do not post GitHub comments or invoke GitHub write APIs.
- Use the Todo task description and ordered subtask context already included above. For current or externally changing facts, use authorized web/search tools and cite trustworthy sources in your answer.
- The scratch directory below exists only as the agent working directory; it is not a repository and must not be populated with cloned repositories.
- Return a complete, directly useful answer in plain text/Markdown. Do not output TASK_NEEDS_USER blocks. When the answer is complete, emit TASK_DONE on its own final line.
- If the request cannot be answered safely or required evidence is unavailable, emit TASK_FAILED: followed by the concrete reason. Never claim success without a complete answer.

## Isolated scratch directory
__WORKDIR__
REPORT_ONLY_PROMPT
      local prompt_content
      prompt_content="$(cat "$TASK_PROMPT_FILE")"
      prompt_content="${prompt_content//__REPO__/No repository (report-only)}"
      prompt_content="${prompt_content//__ISSUE_NUM__/N\/A}"
      prompt_content="${prompt_content//__COMMENT_ID__/$COMMENT_ID}"
      prompt_content="${prompt_content//__COMMENT_URL__/$COMMENT_URL}"
      prompt_content="${prompt_content//__TASK_TYPE__/todo_report}"
      prompt_content="${prompt_content//__TASK_ACTION__/REPORT}"
      prompt_content="${prompt_content//__PR_NUMBER__/N\/A}"
      prompt_content="${prompt_content//__REPLY_TO__/N\/A}"
      prompt_content="${prompt_content//__MANUL_MODE__/$MANUL_MODE}"
      prompt_content="${prompt_content//__HUMAN_COMMENT_MAX_LINES__/$CFG_HUMAN_COMMENT_MAX_LINES}"
      prompt_content="${prompt_content//__CURRENT_ATTEMPT__/$current_attempt}"
      prompt_content="${prompt_content//__WORKDIR__/$WORKDIR}"
      prompt_content="${prompt_content//__WORKSPACE_ROOT__/$workspace_path}"
      prompt_content="${prompt_content//__RELATED_REPOSITORIES__/None}"
      prompt_content="${prompt_content//__RELATED_UNAVAILABLE__/None}"
      prompt_content="${prompt_content//__PR_HEAD_BRANCH__/None}"
      prompt_content="${prompt_content//__CURRENT_BRANCH__/report-only}"
      prompt_content="${prompt_content//__DEFAULT_BRANCH__/None}"
      prompt_content="${prompt_content//__INITIAL_BASE_BRANCH__/None}"
      printf '%s' "$prompt_content" > "$TASK_PROMPT_FILE"
      log "dispatch: report-only Todo task $COMMENT_ID uses isolated scratch; no repository checkout or repo lock"
      lc_log "TODO_REPORT_ONLY_START" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE scratch=$REPORT_ONLY_DIR"
    else
    # Repository Management: Ensure target repository exists and is authoritative
    local REPO_DIR
    local ensure_repo_rc=0
    REPO_DIR="$(ensure_repo "$REPO")" || ensure_repo_rc=$?

    if [ "$ensure_repo_rc" -eq 2 ]; then
      log "dispatch: repository $REPO is busy, requeueing task $COMMENT_ID"
      lc_log "REPO_BUSY" "task=$COMMENT_ID repo=$REPO"
      sqlite3 "$DB" "UPDATE processed_comments SET status='queued', attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END, agentStartedAt=NULL, processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
      release_task_lock
      set_activity "none" "idle"
      return 0
    fi

    if [ "$ensure_repo_rc" -ne 0 ]; then
      log "dispatch: FAILED to ensure repository $REPO (rc=$ensure_repo_rc)"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "" "$REPLY_TO" "Could not prepare the shared repository checkout (ensure_repo rc=$ensure_repo_rc)." "${PR_NUM_FROM_URL:-}" "$current_attempt"
      return 0
    fi

    # ensure_repo() succeeded, so the task owns the repo lock until the shared
    # repo cache has been cloned/reused by its workspace.
    local REPO_LOCK_HELD=true

    # Verify repository integrity
    if ! verify_repo "$REPO" "$REPO_DIR"; then
      log "dispatch: REPOSITORY VERIFICATION FAILED for $REPO"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "" "$REPLY_TO" "Repository verification failed for the prepared shared checkout." "${PR_NUM_FROM_URL:-}" "$current_attempt"
      return 0
    fi

    # 6. Set working directory to the repository root
    local WORKDIR="$REPO_DIR"

    # 6.5. Acquire workspace through the logical conversation tree.
    #
    # PR conversation is the root. Each review thread is a child context,
    # and replies are leaves that stay inside that thread context.
    # Resolution is exact thread -> parent PR -> fresh unbound workspace.
    source "$MANUL_DIR/workspace-manager.sh"
    local WORKSPACE_ID
    local EXISTING_SESSION_ID EXISTING_WORKSPACE_ID
    EXISTING_SESSION_ID="$(sqlite3 "$DB" "SELECT session_id FROM processed_comments WHERE commentId='$(sql_escape "$COMMENT_ID")' LIMIT 1;" 2>/dev/null || echo "")"
    EXISTING_WORKSPACE_ID="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$(sql_escape "$COMMENT_ID")' LIMIT 1;" 2>/dev/null || echo "")"

    local PARENT_WORKSPACE_CONTEXT_ID=""
    if [ -n "$PR_HEAD_BRANCH" ] && [ -n "${PR_NUM_FROM_URL:-}" ] && [[ "$COMMENT_URL" == *"#discussion_r"* ]]; then
      PARENT_WORKSPACE_CONTEXT_ID="conv-${REPO}-issue-${PR_NUM_FROM_URL}"
    fi

    local workspace_acquire_rc=0
    if [ -n "$EXISTING_SESSION_ID" ] && [ -n "$EXISTING_WORKSPACE_ID" ]; then
      WORKSPACE_ID="$(workspace_reclaim "$COMMENT_ID" 2>/dev/null || true)"
      if [ -z "$WORKSPACE_ID" ]; then
        log "dispatch: continuation session has no reclaimable workspace for task $COMMENT_ID"
        handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "" "$REPLY_TO" "Continuation session has no reclaimable workspace; the previous execution cannot be resumed." "${PR_NUM_FROM_URL:-}" "$current_attempt"
        return 0
      fi
      log "dispatch: reclaimed exact workspace $WORKSPACE_ID for continuation task $COMMENT_ID"
    else
      WORKSPACE_ID="$(workspace_context_acquire "$COMMENT_ID" "$CONVERSATION_ID" "$PARENT_WORKSPACE_CONTEXT_ID" "$REPO" "${PR_NUM_FROM_URL:-$ISSUE_NUM}")" || workspace_acquire_rc=$?
      if [ "$workspace_acquire_rc" -eq 2 ]; then
        log "dispatch: logical workspace context is busy for task $COMMENT_ID; requeueing"
        lc_log "WORKSPACE_CONTEXT_BUSY" "task=$COMMENT_ID context=$CONVERSATION_ID parent=${PARENT_WORKSPACE_CONTEXT_ID:-none}"
        sqlite3 "$DB" "UPDATE processed_comments SET status='queued', attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END, agentStartedAt=NULL, processedAt=NULL, heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL, nextAttemptAt=datetime('now', '+${RETRY_DELAY_SECONDS} seconds') WHERE commentId='$safe_comment_id' AND status='running' AND claimToken='$safe_claim_token';" 2>/dev/null
        release_task_repo_lock "$REPO"
        release_task_lock
        set_activity "none" "idle"
        return 0
      fi
    fi

    if [ -z "$WORKSPACE_ID" ]; then
      log "dispatch: no workspace available for task $COMMENT_ID; consuming bounded pre-agent infrastructure retry"
      lc_log "NO_WORKSPACE" "task=$COMMENT_ID repo=$REPO context=$CONVERSATION_ID parent=${PARENT_WORKSPACE_CONTEXT_ID:-none}"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "" "$REPLY_TO" "No task-owned workspace could be acquired before agent startup." "${PR_NUM_FROM_URL:-}" "$current_attempt" "workspace_acquisition"
      return 0
    fi

    sqlite3 "$DB" "UPDATE processed_comments SET workspaceId='$WORKSPACE_ID' WHERE commentId='$safe_comment_id';" 2>/dev/null || true
    log "dispatch: task $COMMENT_ID bound to workspace context $CONVERSATION_ID -> $WORKSPACE_ID${PARENT_WORKSPACE_CONTEXT_ID:+ (parent=$PARENT_WORKSPACE_CONTEXT_ID)}"


    # Get workspace path from lease
    local workspace_path
    workspace_path="$(workspace_get_path "$COMMENT_ID" "$WORKSPACE_ID")"
    if [ -z "$workspace_path" ]; then
      log "dispatch: could not get a safe path for workspace $WORKSPACE_ID owned by task $COMMENT_ID"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Workspace path is missing or failed ownership/path validation (workspace=$WORKSPACE_ID)." "${PR_NUM_FROM_URL:-}" "$current_attempt" "workspace_path_validation"
      return 0
    fi

    # Validate the lease/root before migrating or creating any checkout beneath
    # it. This prevents a corrupt DB path or symlink from steering filesystem
    # changes outside the exact task-owned workspace.
    local early_ws_owner early_ws_state early_ws_path
    early_ws_owner="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$(sql_escape "$WORKSPACE_ID")' LIMIT 1;" 2>/dev/null || echo "")"
    early_ws_state="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$(sql_escape "$WORKSPACE_ID")' LIMIT 1;" 2>/dev/null || echo "")"
    early_ws_path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$(sql_escape "$WORKSPACE_ID")' AND currentTaskId='$(sql_escape "$COMMENT_ID")' AND status='BUSY' LIMIT 1;" 2>/dev/null || echo "")"
    if [ -z "$early_ws_path" ] || [ "$early_ws_owner" != "$COMMENT_ID" ] || [ "$early_ws_state" != "BUSY" ] || ! workspace_owned_path_matches "$WORKSPACE_ID" "$COMMENT_ID" "$workspace_path"; then
      log "ERROR: refused checkout preparation for unowned workspace root (task=$COMMENT_ID workspace=$WORKSPACE_ID registered_path=${early_ws_path:-none} candidate_path=$workspace_path)"
      lc_log "WORKSPACE_INVALID" "task=$COMMENT_ID workspace=$WORKSPACE_ID phase=preparation"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Workspace lease ownership or canonical path validation failed (workspace=$WORKSPACE_ID)." "${PR_NUM_FROM_URL:-}" "$current_attempt"
      return 0
    fi

    # The lease owns a workspace root, not a single repository checkout.
    # Migrate legacy root checkouts without discarding changes, then prepare the
    # primary repository below repos/<owner>/<name>.
    local primary_checkout_rc=0
    WORKDIR="$(workspace_prepare_primary_checkout "$workspace_path" "$REPO" "$REPO_DIR")" || primary_checkout_rc=$?
    if [ "$primary_checkout_rc" -ne 0 ] || [ -z "$WORKDIR" ]; then
      log "dispatch: failed to prepare primary checkout for $REPO in task workspace $workspace_path (rc=$primary_checkout_rc); preserving existing data"
      lc_log "WORKSPACE_PRIMARY_CHECKOUT_FAILED" "task=$COMMENT_ID repo=$REPO workspace=$WORKSPACE_ID rc=$primary_checkout_rc"
      handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Could not prepare the primary checkout for $REPO (rc=$primary_checkout_rc). Existing workspace data was preserved." "${PR_NUM_FROM_URL:-}" "$current_attempt" "primary_checkout_preparation"
      return 0
    fi

    # Prepare related repos only inside this lease. Shared caches are internal
    # clone sources and are never exposed as working directories to the agent.
    workspace_prepare_related_checkouts "$workspace_path" "$REPO" "${REPOS[@]}"
    local RELATED_REPOSITORIES="${WORKSPACE_RELATED_PATHS:-}"
    local RELATED_UNAVAILABLE="${WORKSPACE_RELATED_UNAVAILABLE:-}"

    # Agent operates from the workspace root. Git branch/PR setup and delivery
    # below intentionally continue to target WORKDIR (the primary checkout).
    release_task_repo_lock "$REPO"

     # PR tasks use the PR's explicit head branch. If checkout fails because of
     # stale/dirty state, rebuild from the remote at that same branch and archive
     # the old checkout; never silently fall back to master/default.
     if [ -n "$PR_HEAD_BRANCH" ]; then
      log "dispatch: preparing PR head branch $PR_HEAD_BRANCH in workspace $WORKDIR"
      if ! workspace_prepare_pr_branch "$WORKDIR" "$PR_HEAD_BRANCH" "$workspace_path" "$REPO" 2>>"$LOG"; then
        log "dispatch: failed to prepare PR head branch $PR_HEAD_BRANCH; see Git recovery diagnostics"
        handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Could not prepare PR head branch '$PR_HEAD_BRANCH' from remote state. Manul attempted branch-specific checkout recovery where possible; see daemon diagnostics for the exact blocker." "${PR_NUM_FROM_URL:-}" "$current_attempt"
        return 0
      fi
      local verify_branch
      verify_branch="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null)"
      if [ "$verify_branch" != "$PR_HEAD_BRANCH" ]; then
        local verify_branch_display="$verify_branch"
        [ -n "$verify_branch_display" ] || verify_branch_display="detached"
        log "dispatch: PR branch verification failed (expected=$PR_HEAD_BRANCH, got=$verify_branch_display), releasing and failing"
        handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "PR workspace branch mismatch: expected $PR_HEAD_BRANCH, got $verify_branch_display." "${PR_NUM_FROM_URL:-}" "$current_attempt"
        return 0
      fi
      log "dispatch: verified PR head branch $verify_branch in workspace"
     else
       # Issue / standalone task: target the resolved repository/base branch, not
       # whichever branch happens to be checked out in the task workspace.
       local default_branch
       default_branch="$(git -C "$WORKDIR" remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' || echo "")"
       local base_branch
       base_branch="$(determine_task_base_branch "$WORKDIR" "$default_branch")"
       log "dispatch: preparing workspace $WORKDIR from base branch '$base_branch' for task $COMMENT_ID"
       local base_recovered=0
       if ! git -C "$WORKDIR" fetch origin --quiet 2>>"$LOG"; then
         log "ERROR: fetch origin failed before task setup on $REPO; trying a fresh clone at selected branch '$base_branch'"
         if workspace_recover_primary_checkout "$workspace_path" "$REPO" "$WORKDIR" "$base_branch" 2>>"$LOG"; then
           base_recovered=1
           log "dispatch: recovered checkout directly from remote at selected base branch '$base_branch'"
         else
           handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Could not fetch origin or rebuild a fresh checkout at selected base branch '$base_branch'. See daemon diagnostics for the exact Git/recovery blocker; the prior checkout was preserved whenever possible." "${PR_NUM_FROM_URL:-}" "$current_attempt"
           return 0
         fi
       fi
       if [ "$base_recovered" -eq 0 ]; then
         base_branch="$(determine_task_base_branch "$WORKDIR" "$default_branch")"
         if ! workspace_prepare_task_base_branch "$WORKDIR" "$base_branch" "$workspace_path" "$REPO" 2>>"$LOG"; then
           log "ERROR: failed to prepare checkout for selected base branch '$base_branch' in task $COMMENT_ID"
           handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Could not prepare the selected base branch '$base_branch'. Manul attempted a fresh clone at that same branch; see daemon diagnostics for the exact Git/recovery blocker. The prior checkout was preserved whenever recovery could safely archive it." "${PR_NUM_FROM_URL:-}" "$current_attempt"
           return 0
         fi
       fi
     fi
log "dispatch: task $COMMENT_ID repository located at $REPO_DIR, workspace=$WORKSPACE_ID ($WORKDIR)"

     # Hard workspace validation before agent dispatch. The workspace lease
     # (workspace_lease) is the single authoritative source of ownership;
     # if the invariant is broken here, the agent must never be launched.
     local ws_owner ws_state ws_path_check
     ws_owner="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$(sql_escape "$WORKSPACE_ID")' LIMIT 1;" 2>/dev/null || echo "")"
     ws_state="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$(sql_escape "$WORKSPACE_ID")' LIMIT 1;" 2>/dev/null || echo "")"
     ws_path_check="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$(sql_escape "$WORKSPACE_ID")' AND currentTaskId='$(sql_escape "$COMMENT_ID")' AND status='BUSY' LIMIT 1;" 2>/dev/null || echo "")"
     if [ -z "$WORKSPACE_ID" ] || [ -z "$ws_path_check" ] || [ "$ws_owner" != "$COMMENT_ID" ] || [ "$ws_state" != "BUSY" ] || [ ! -d "$workspace_path" ] || ! workspace_owned_path_matches "$WORKSPACE_ID" "$COMMENT_ID" "$workspace_path"; then
       log "ERROR: workspace ownership/path invalid for task $COMMENT_ID (workspace=$WORKSPACE_ID owner=${ws_owner:-none} state=${ws_state:-none} registered_path=${ws_path_check:-none} candidate_path=$workspace_path)"
       lc_log "WORKSPACE_INVALID" "task=$COMMENT_ID workspace=$WORKSPACE_ID owner=${ws_owner:-none} state=${ws_state:-none}"
       handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "Workspace lease or checkout path validation failed before agent startup." "${PR_NUM_FROM_URL:-}" "$current_attempt"
       return 0
     fi
     log "dispatch: workspace validated for task $COMMENT_ID (workspace=$WORKSPACE_ID owner=$ws_owner state=$ws_state path=$WORKDIR)"

     # Capture the exact repository state we hand to the agent.
    local CURRENT_BRANCH
    CURRENT_BRANCH="$(git -C "$WORKDIR" symbolic-ref --short HEAD 2>/dev/null || echo "UNKNOWN")"
    local INITIAL_BRANCH="$CURRENT_BRANCH"
    local INITIAL_HEAD
    INITIAL_HEAD="$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || echo "")"
    local DEFAULT_BRANCH
    DEFAULT_BRANCH="$(git -C "$WORKDIR" remote show origin 2>/dev/null | grep "HEAD" | awk '{print $3}' || echo "")"
    local INITIAL_BASE_BRANCH="${base_branch:-$CURRENT_BRANCH}"
    log "dispatch: task $COMMENT_ID starts on branch=$INITIAL_BRANCH head=$INITIAL_HEAD initialBase=$INITIAL_BASE_BRANCH default=$DEFAULT_BRANCH"

    # Update prompt to include authoritative repository path and branch policy
    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'

## Task Workspace and Local-Access Boundary
The leased task workspace root (your only permitted repository-access boundary) is:
__WORKSPACE_ROOT__

The primary repository checkout is the only repository that may be edited, committed, pushed, or delivered by default:
__WORKDIR__

## Canonical Path Handling — Mandatory
The absolute paths supplied by Manul above are authoritative. Treat the leased workspace root as the task boundary and the primary checkout as the working repository. Never reconstruct paths from usernames, task IDs, previous attempts, logs, or assumptions about the machine.

- The execution runner provides `MANUL_TASK_WORKSPACE_ROOT` and `MANUL_TASK_WORKDIR` to local command processes when supported. Prefer `cd "$MANUL_TASK_WORKDIR"` for shell commands and verify the repository root with `git rev-parse --show-toplevel`.
- If a tool does not inherit those variables, use the exact literal primary-checkout path printed above. Do not invent or “correct” an absolute path.
- Prefer `"$HOME/…"` for home-relative shell paths. Do not assume `~` expands inside quoted strings, tool arguments, configuration values, or file APIs.
- If the supplied paths and the actual filesystem disagree, stop path-dependent operations and report the observed `HOME`, `PWD`, supplied path values, and the exact failed check. Never try alternate username/home prefixes.
- A path or permission failure is not permission to search another workspace, guess a replacement, use a symlink, or broaden access.

Additional repositories prepared inside this workspace for READ-ONLY inspection:
__RELATED_REPOSITORIES__

Configured related repositories unavailable in this attempt:
__RELATED_UNAVAILABLE__

All repository file access must stay inside the exact task workspace root above. Run primary-repository build, test, git, commit, push, and PR commands from the primary checkout at `__WORKDIR__`. Related checkouts, if listed, are read-only context. Do not edit, commit, branch, or push a related checkout by default. If the task genuinely requires changing another repository, stop and request an explicit delivery policy for that repository/branch/PR before changing it. If a required related repository is unavailable, report the exact repository and blocker; do not search for its shared cache or another task's checkout.

Treat local Manul/OpenCode/operator state as outside the task boundary. The configured Manul workspace tree is private runtime state: only the exact task workspace root shown above and its descendants are permitted. Every sibling workspace is forbidden, even read-only, as are shared repository caches, databases, prompts, logs, runtime artifacts, adapters, and symlink targets outside this task root. Do NOT read, list, search, probe, enumerate, or follow them through shell commands, file tools, skill tools, subagents, or indirect access. Also do NOT read, list, search, probe, or follow paths in:
- ~/.config/opencode/** (provider configuration and permissions)
- ~/.agents/** or other global agent/skill directories
- daemon logs, process environments, agent runtime internals, or other tasks' workspaces

Do not use shell commands, file tools, skill tools, symlinks, or indirect access to bypass this boundary. Do not attempt to diagnose or prove runtime routing from inside the implementation session. Manul/operator diagnostics must gather that evidence separately, outside this agent run.

If information is missing, first seek it through authorized sources: the assigned workspace, related repositories explicitly checked out INSIDE that workspace, the authoritative GitHub issue/PR and its comments/history, repository history, or approved public documentation. If the required information still cannot be obtained, ask the user for the specific missing input using the structured TASK_NEEDS_USER flow; summarize what you checked and why the answer matters. Do NOT search another task's workspace or request broader filesystem permissions as a workaround. Do not change runtime configuration or access permissions to get around this boundary.

## Scope-First Investigation and Host-System Boundary
Start with the task request and the smallest relevant evidence set inside `WORKDIR`: repository docs, source, tests, build/dependency declarations, and documented project commands. Search narrowly and expand only when a concrete finding proves it is needed. Do not perform broad host/environment reconnaissance just to understand an ordinary repository task.

For ordinary implementation, PR review, and test tasks, do NOT inspect host OS/service configuration outside the authorized workspace, including `/etc/**`, `/var/**`, `/run/**`, `/proc/**`, `/sys/**`, host database configuration (for example `/etc/mysql/**`), other users' home directories, or unrelated host process/service/container state. The exception is a task that explicitly targets host/system administration and expressly authorizes that access; do not infer such authorization from a generic coding task or a dependency failing to start.

You may run repository-declared build/test/dependency commands (including the repository's documented Docker Compose setup) when required by the task. This does NOT authorize reading host configuration, probing unrelated services, or starting/stopping host-level services. If a documented project command fails because a dependency is unavailable, capture the exact error and report the blocker instead of diagnosing the host installation.

Keep shell/tool calls focused on one diagnostic purpose. Avoid compound commands that mix repository work with unrelated filesystem or system probes.

If a tool call is denied by the permission policy, do not retry the same restricted operation through another tool, path, symlink, or reshaped command, and do not ask for broader permissions just to continue routine work. Record the exact denied operation and continue only with independent in-scope work; otherwise report the blocker.

These limits apply to all delegated/subagents too. Pass the same scope boundary into every delegated task prompt.

## Branch Policy
PROMPT_APPEND

    if [ -n "$PR_HEAD_BRANCH" ]; then
      # PR-tied task: operate on the PR's head branch
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- This task is tied to PR #__ISSUE_NUM__
- PR head branch: `__PR_HEAD_BRANCH__`
- PR head branch `__PR_HEAD_BRANCH__` is already checked out and ready for work
- Commit and push changes to the same PR head branch
- Do NOT create a new branch for this task
PROMPT_APPEND
    else
      # Standalone issue task: daemon prepares the base; the agent owns the
      # repository-change branch decision and follows feature-branching-strategy.
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- This is a standalone task (not tied to an existing PR)
- Current branch: __CURRENT_BRANCH__
- Repository default branch: __DEFAULT_BRANCH__
- Initial prepared base branch: __INITIAL_BASE_BRANCH__
- The daemon does NOT create your task branch for you
- First determine whether this is informational or requires repository changes
- For informational tasks: do NOT modify the repository and do NOT create a branch; post the answer to GitHub and finish
- For repository changes, **branch preparation is a mandatory precondition to every edit**: do not edit, patch, generate, format, or otherwise modify repository files until the branch preflight below has succeeded.
- First run `git -C "__WORKDIR__" status --short` and `git -C "__WORKDIR__" branch --show-current`. Preserve any existing changes; never use `git reset --hard`, `git clean`, or discard/revert unknown work. If the checkout is dirty or its branch cannot be established safely, stop before editing and report the exact blocker.
- Create the branch yourself before committing or pushing changes, and before the first repository edit.
- For this standalone issue, use the initial prepared base branch `__INITIAL_BASE_BRANCH__` unless the task explicitly requires another base. The base branch must be updated from origin before you create the task branch.
- Example preflight (replace `<short-description>` with a lowercase kebab-case summary):
  ```bash
  WORKDIR="__WORKDIR__"
  BASE_BRANCH="__INITIAL_BASE_BRANCH__"
  TASK_SUFFIX="$(printf '%s' '__COMMENT_ID__-attempt-__CURRENT_ATTEMPT__' | tr -cs '[:alnum:]-' '-')"
  TASK_BRANCH="feature/__ISSUE_NUM__-manul-<short-description>-$TASK_SUFFIX"
  git -C "$WORKDIR" fetch origin "$BASE_BRANCH" &&
    git -C "$WORKDIR" switch --create "$TASK_BRANCH" "origin/$BASE_BRANCH"
  ```
- Verify `git -C "$WORKDIR" branch --show-current` equals the new task branch before modifying files. If fetching or branch creation fails, do not continue with edits or commits; report the cause. Never overwrite/reuse a stale branch from an earlier attempt; use a unique task/attempt suffix.
- For repository changes: follow repository-local branching guidance or skill content explicitly supplied in the task context; do not inspect global skill directories. Do not read `~/.agents/**` or any global skill directory; the task-access boundary above takes precedence.
- If the task explicitly requires another branch as the base, including another feature branch, update that exact remote base before creating your branch and reflect that base in the PR.
- Never commit or push repository changes directly to the prepared/base/default branch
PROMPT_APPEND
    fi

    if [ "$MANUL_MODE" = "human" ] && [ "$CFG_HUMAN_COMMENT_CONCISE" = "true" ]; then
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- Human concise comments: enabled (`__HUMAN_COMMENT_MAX_LINES__` visible lines maximum).
PROMPT_APPEND
    elif [ "$MANUL_MODE" = "human" ]; then
      cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'
- Human concise comments: disabled; use a natural human tone but do not enforce the concise line limit.
PROMPT_APPEND
    fi

    cat >> "$TASK_PROMPT_FILE" <<'PROMPT_APPEND'

## Skills
Use relevant repository-local instructions and skills available within the assigned workspace. Do not browse or load global skills from `~/.agents/**`; only use externally provided skill content if it is explicitly included in this task prompt/context. If an unavailable external skill is essential, report the missing input rather than searching outside the workspace.
PROMPT_APPEND

    # Substitute all single-line placeholders with actual runtime values
    # Using bash parameter expansion (safe: replacement is literal, no command substitution)
    local prompt_content
    prompt_content="$(cat "$TASK_PROMPT_FILE")"
    prompt_content="${prompt_content//__REPO__/$REPO}"
    prompt_content="${prompt_content//__ISSUE_NUM__/$ISSUE_NUM}"
    prompt_content="${prompt_content//__COMMENT_ID__/$COMMENT_ID}"
    prompt_content="${prompt_content//__COMMENT_URL__/$COMMENT_URL}"
    prompt_content="${prompt_content//__TASK_TYPE__/$TASK_TYPE}"
    prompt_content="${prompt_content//__TASK_ACTION__/$TASK_ACTION}"
    prompt_content="${prompt_content//__MANUL_MODE__/$MANUL_MODE}"
    prompt_content="${prompt_content//__HUMAN_COMMENT_MAX_LINES__/$CFG_HUMAN_COMMENT_MAX_LINES}"
    prompt_content="${prompt_content//__PR_NUMBER__/$ISSUE_NUM}"
    prompt_content="${prompt_content//__REPLY_TO__/$REPLY_TO}"
    prompt_content="${prompt_content//__CURRENT_ATTEMPT__/$current_attempt}"
    prompt_content="${prompt_content//__WORKDIR__/$WORKDIR}"
    prompt_content="${prompt_content//__WORKSPACE_ROOT__/$workspace_path}"
    prompt_content="${prompt_content//__RELATED_REPOSITORIES__/$RELATED_REPOSITORIES}"
    prompt_content="${prompt_content//__RELATED_UNAVAILABLE__/$RELATED_UNAVAILABLE}"
    prompt_content="${prompt_content//__PR_HEAD_BRANCH__/$PR_HEAD_BRANCH}"
    prompt_content="${prompt_content//__CURRENT_BRANCH__/$CURRENT_BRANCH}"
    prompt_content="${prompt_content//__DEFAULT_BRANCH__/$DEFAULT_BRANCH}"
    prompt_content="${prompt_content//__INITIAL_BASE_BRANCH__/$INITIAL_BASE_BRANCH}"
    printf '%s' "$prompt_content" > "$TASK_PROMPT_FILE"

    fi

# 6. Invoke implementation agent via AgentExecutor / AgentExecutionController.
     # The daemon never calls adapter scripts directly; the controller owns
     # timeout enforcement, session continuation, and result mapping.
     local STDOUT_FILE STDERR_FILE EXEC_CTX_FILE
     STDOUT_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$COMMENT_ID" "stdout")"
     STDERR_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$COMMENT_ID" "stderr")"
     EXEC_CTX_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$COMMENT_ID" "ctx.json")"

     log "dispatch: invoking agent via AgentExecutor for task $COMMENT_ID"
     lc_log "WORKER_START" "task=$COMMENT_ID repo=$REPO timeout=${AGENT_TIMEOUT}s"
     set_activity "$COMMENT_ID" "working"

     # Build the execution context JSON file consumed by AgentExecutor.
     local AGENT_SELECTION="automatic"
     if [ -n "${AGENT:-}" ] && [ "$AGENT" != "null" ]; then
       AGENT_SELECTION="explicit"
     fi

     local prev_dir
     prev_dir="$(pwd)"
     cd "$workspace_path" || {
       log "ERROR: cannot enter working directory $WORKDIR, failing task"
       handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "The validated task workspace could not be entered by the daemon." "${PR_NUM_FROM_URL:-}" "$current_attempt"
       return 0
     }

     # Ensure skill visibility for agent runtimes that read it
     export OPENCODE_SKILLS_PATH="$HOME/.agents/skills"

     # Refresh heartbeat before agent to prevent timeout during long runs
     refresh_heartbeat "$COMMENT_ID"

     # Persist the previous session id if this is a continuation attempt.
     local prev_session_id=""
     prev_session_id="$(sqlite3 "$DB" "SELECT session_id FROM processed_comments WHERE commentId='$(sql_escape "$COMMENT_ID")' AND session_id IS NOT NULL AND session_id != '' LIMIT 1;" 2>/dev/null || echo "")"

     jq -n \
       --arg taskId "$COMMENT_ID" \
       --arg prompt "$TASK_PROMPT_FILE" \
       --arg workspace "$workspace_path" \
       --arg workspaceRoot "$workspace_path" \
       --arg workdir "$WORKDIR" \
       --arg agent "${AGENT:-}" \
       --arg agentSelection "$AGENT_SELECTION" \
       --argjson autoAccept "$TASK_AUTO_ACCEPT" \
       --argjson attempt "$current_attempt" \
       --argjson timeout "$AGENT_TIMEOUT" \
       --arg sessionId "$prev_session_id" \
       --arg stdoutFile "$STDOUT_FILE" \
       --arg stderrFile "$STDERR_FILE" \
       '{taskId: $taskId, prompt: $prompt, workspace: $workspace, workspaceRoot: $workspaceRoot, workdir: $workdir, agent: $agent, agentSelection: $agentSelection, autoAccept: $autoAccept, attempt: $attempt, timeout: $timeout, session_id: $sessionId, stdout_file: $stdoutFile, stderr_file: $stderrFile}' \
       > "$EXEC_CTX_FILE"

     local executor_output
     local executor_result_file executor_pid_file
     executor_result_file="$(manul_task_file_path "$MANUL_TASKS_DIR" "$COMMENT_ID" "executor-result")"
     executor_pid_file="$(manul_task_file_path "$MANUL_DIR" "$COMMENT_ID" "executor.pid")"
     rm -f "$executor_result_file" "$executor_pid_file"

     # Run the controller in a dedicated process group. The task-local PID file
     # lets watchdog/recovery terminate a hung executor without killing the worker.
     # FD 210 owns task-dispatch.flock in this worker. Do not let the isolated
     # executor or any descendants inherit it: their lifetime may outlive the
     # worker and would keep the dispatcher lock held across a restart.
     setsid --wait "$DAEMON_SCRIPT_DIR/agent-task-runner.sh" "$EXEC_CTX_FILE" "$executor_pid_file" 210>&- >"$executor_result_file" 2>>"$STDERR_FILE" &
     local executor_launcher_pid=$!
     local rc=0
     wait "$executor_launcher_pid" || rc=$?
     executor_output="$(cat "$executor_result_file" 2>/dev/null || true)"
     rm -f "$executor_pid_file" "$executor_result_file"

     cd "$prev_dir" 2>/dev/null || log "WARN: failed to restore working directory"

# Persist session id for continuation attempts
      local exec_status exec_summary exec_session_id exec_failure_code exec_failure_stage
      exec_status="$(printf '%s' "$executor_output" | jq -r '.status // "FAILED"' 2>/dev/null)"
      exec_summary="$(printf '%s' "$executor_output" | jq -r '.summary // ""' 2>/dev/null)"
      exec_session_id="$(printf '%s' "$executor_output" | jq -r '.session_id // ""' 2>/dev/null)"
      exec_failure_code="$(printf '%s' "$executor_output" | jq -r '.failure_code // ""' 2>/dev/null)"
      exec_failure_stage="$(printf '%s' "$executor_output" | jq -r '.diagnostics.stage // ""' 2>/dev/null)"
     # Retain a runtime session only when the adapter explicitly requests
     # continuation. Completion, ordinary failures, and malformed continuation
     # results clear stale session state while preserving the workspace mapping.
     # The helper scopes writes to the current claim so an expired worker cannot
     # overwrite the session pointer owned by a newer attempt.
     if ! manul_record_execution_session_state "$DB" "$COMMENT_ID" "$CLAIM_TOKEN" "$exec_status" "$exec_session_id"; then
       log "WARN: could not update runtime session state for task $COMMENT_ID (status=$exec_status)"
     fi

     # Preserve launcher diagnostics in daemon.log before task artifacts are cleaned
     # up. This is especially important for fast launch failures where the worker
     # can exit before producing a GitHub-visible result.
     if [ -n "$exec_summary" ]; then
       log "dispatch: agent executor summary for task $COMMENT_ID: $exec_summary"
     fi
     if [ "$rc" -ne 0 ]; then
       log "dispatch: agent executor exited rc=$rc for task $COMMENT_ID (status=$exec_status)"
       if [ -s "$STDERR_FILE" ]; then
         log "dispatch: agent stderr for task $COMMENT_ID (tail 80):"
         tail -n 80 "$STDERR_FILE" >>"$LOG" 2>/dev/null || true
       else
         log "dispatch: agent stderr file is empty for task $COMMENT_ID"
       fi
     fi

     # Map executor status onto the daemon's rc/NEEDS_USER_INPUT contract.
     case "$exec_status" in
       BLOCKED|TASK_NEEDS_USER_BEGIN)
         # Do not trust adapter status alone. evaluate_task_completion validates
         # the exact structured block and extracts the complete multi-line question.
         rc=0
         ;;
       NEEDS_CONTINUATION)
         # Surface as a retryable state; daemon handles via attempt counting.
         rc=1
         ;;
       TIMEOUT)
         rc=124
         ;;
       COMPLETED)
         rc=0
         ;;
       *)
         rc="${rc:-1}"
         ;;
     esac

     # Adapter preflight/config failures happen before the LLM task starts.
     # They must use the bounded infrastructure-failure budget, not consume an
     # agent execution attempt just because the dispatcher already wrote
     # agentStartedAt before entering the adapter.
     if [ "$exec_failure_code" = "PRE_EXECUTION_FAILURE" ]; then
       [ -n "$exec_failure_stage" ] || exec_failure_stage="runtime_preflight"
       log "dispatch: adapter failed before agent startup for task $COMMENT_ID (stage=$exec_failure_stage): $exec_summary"
       handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN" "$REPO" "$ISSUE_NUM" "$WORKSPACE_ID" "$REPLY_TO" "$exec_summary" "${PR_NUM_FROM_URL:-}" "$current_attempt" "$exec_failure_stage"
       return 0
     fi

     # Call production completion evaluation function
          local delivery_mode="implementation"
     if [ "$TASK_ACTION" = "VERIFY" ]; then delivery_mode="comment_only"; fi
     evaluate_task_completion "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$safe_comment_id" "$current_attempt" "$rc" "$STDOUT_FILE" "$DB" "$REPO_DIR" "$WORKDIR" "$CLAIM_TOKEN" "$INITIAL_HEAD" "$INITIAL_BRANCH" "$INITIAL_BASE_BRANCH" "$exec_summary" "$exec_failure_code" "$PR_HEAD_BRANCH" "" "$delivery_mode" "$TASK_SOURCE_TYPE" "$TASK_EXECUTION_KIND"

    # A structured TASK_NEEDS_USER result pauses this task without entering the
    # worker failure/retry path. The daemon asks the user and then waits for an
    # explicit /manul continue response.
    if [ "\${NEEDS_USER_INPUT:-false}" = "true" ]; then
      if mark_task_blocked_user "$COMMENT_ID" "$safe_comment_id" "$CLAIM_TOKEN" "$USER_QUESTION"; then
        if [ -n "\${WORKSPACE_ID:-}" ]; then
          workspace_release "$WORKSPACE_ID" "$COMMENT_ID" || log "WARN: failed to release workspace after user-blocked task $COMMENT_ID"
        fi
        if task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
          log "Todo task $TASK_SOURCE_ID blocked for user input; question saved in resultSummary. Edit the Todo task to create a new source version."
          lc_log "TODO_SOURCE_BLOCKED_USER" "task=$COMMENT_ID source=$TASK_SOURCE_TYPE"
        elif ! post_task_needs_user_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$USER_QUESTION" "$REPLY_TO"; then
          log "WARN: failed to post TASK_NEEDS_USER comment for $COMMENT_ID"
        fi
        stop_heartbeat "$COMMENT_ID"
        release_task_repo_lock "$REPO"
        release_task_lock
        set_activity "$COMMENT_ID" "blocked_user"
        return 0
      fi
      log "ERROR: could not transition $COMMENT_ID to blocked_user; falling through to failure handling"
      NEEDS_USER_INPUT="false"
    fi

    # Map local variables (set by evaluate_task_completion)
    COMPLETION_SUCCESS="${COMPLETION_SUCCESS:-false}"
    FINAL_COMMENT="${FINAL_COMMENT:-}"
    FAIL_REASON="${FAIL_REASON:-}"

    # Determine terminal state and assemble its machine event BEFORE posting.
    # The marker must be part of the exact body sent to GitHub; adding it after
    # post_github_comment only mutates a local variable and loses the event.
    local task_final_status
    task_final_status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
    local lifecycle_conv_id
    lifecycle_conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
    local lifecycle_pr_num
    lifecycle_pr_num="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "")"
    local lifecycle_attempt="$current_attempt"
    if [ "$task_final_status" = "failed" ]; then
      lifecycle_attempt="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='$safe_comment_id' LIMIT 1;" 2>/dev/null || echo "$current_attempt")"
    fi
    FINAL_COMMENT="$(build_terminal_lifecycle_comment "$COMMENT_ID" "$lifecycle_conv_id" "$lifecycle_attempt" "$lifecycle_pr_num" "$task_final_status" "$FAIL_REASON" "$FINAL_COMMENT")"

    # 9. Persist terminal result comments before attempting GitHub publication.
    # Non-terminal retry comments remain ordinary result text without machine markers.
    local COMMENT_POST_SUCCESS="false"
    if [ -n "$FINAL_COMMENT" ] && ! task_source_is_todo_type "$TASK_SOURCE_TYPE"; then
      # Todo has no GitHub comment protocol; its answer is saved as a verified
      # child task and the local receipt is stored in processed_comments.
      if [ "$task_final_status" = "completed" ] || [ "$task_final_status" = "failed" ]; then
        local terminal_event_type="TASK_DONE"
        [ "$task_final_status" = "failed" ] && terminal_event_type="TASK_FAILED"
        if deliver_terminal_lifecycle_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID" "$lifecycle_attempt" "$terminal_event_type" "$FINAL_COMMENT" "$REPLY_TO"; then
          COMMENT_POST_SUCCESS="true"
        else
          log "ERROR: terminal result comment queued for retry for $COMMENT_ID (event=$terminal_event_type attempt=$lifecycle_attempt)"
        fi
      elif post_github_comment "$REPO" "$ISSUE_NUM" "$FINAL_COMMENT" "$REPLY_TO"; then
        COMMENT_POST_SUCCESS="true"
      else
        log "ERROR: failed to post non-terminal result comment for $COMMENT_ID"
      fi
    fi

    # The evaluator is the single authority for running→completed/queued/failed.
    # Never perform a second state transition here after evaluation.
    if [ "$COMPLETION_SUCCESS" = "true" ]; then
      set_activity "$COMMENT_ID" "completed"
    fi

    # Auto-close only when all tasks are terminal AND every terminal
    # lifecycle event in the conversation has been reconciled. A pending
    # outbox row keeps the conversation open until a later dispatcher retry
    # confirms the marker with GitHub.
    if [ "$task_final_status" = "completed" ] || [ "$task_final_status" = "failed" ]; then
      if [ "$COMMENT_POST_SUCCESS" = "true" ]; then
        close_drained_conversations || log "WARN: conversation close deferred until terminal lifecycle delivery is reconciled"
      else
        log "INFO: conversation close deferred; terminal lifecycle result remains pending for $COMMENT_ID"
      fi
    fi

    # Stop heartbeat after task completion/failure
    stop_heartbeat "$COMMENT_ID"
    lc_log "HEARTBEAT_STOP" "task=$COMMENT_ID"

    # Release workspace back to pool
    local task_workspace_id
    task_workspace_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_comment_id';" 2>/dev/null)"
    if [ -n "$task_workspace_id" ]; then
      workspace_release "$task_workspace_id" "$COMMENT_ID"
      log "dispatch: released workspace $task_workspace_id for task $COMMENT_ID"
      lc_log "WORKSPACE_RELEASE" "task=$COMMENT_ID workspace=$task_workspace_id"
    fi

    # Release repository lock
    release_task_repo_lock "$REPO"

    # Persist task diagnostics before removing transient worker artifacts.
    archive_task_artifacts "$COMMENT_ID" "$STDOUT_FILE" "$STDERR_FILE" "$TASK_PROMPT_FILE" || true

    # Cleanup task artifacts. Report-only tasks own a disposable scratch
    # directory rather than a leased repository workspace.
    rm -f "$TASK_PROMPT_FILE" "$STDOUT_FILE" "$STDERR_FILE"
    if [ "$TASK_EXECUTION_KIND" = "report_only" ] && [[ "${REPORT_ONLY_DIR:-}" == /tmp/manul-report-only.* ]] && [ -d "$REPORT_ONLY_DIR" ] && [ ! -L "$REPORT_ONLY_DIR" ]; then
      rm -rf -- "$REPORT_ONLY_DIR"
    fi

    release_task_lock
    set_activity "none" "idle"
}

# Compatibility entry point for explicit one-shot/manual runs: poll once, then dispatch.
# The long-lived daemon does NOT use this combined path; its poller and consumers
# are supervised independently below.
run_once() {
  configure_task_retention
  ensure_recovery_tracking_columns || {
    log "ERROR: recovery tracking schema unavailable; refusing to dispatch without retry bookkeeping"
    return 1
  }
  cleanup_expired_tasks
  cleanup_expired_logs
  poll_once
  dispatch_once
}

loop() {
  validate_dispatch_interval
  # Parse worker mode and the daemon master that owns this worker. An orphaned
  # worker must exit after its master dies instead of competing with a
  # replacement daemon and repeatedly contending for the task-dispatch lock.
  local worker_id="" parent_pid="" poller_mode=false
  for arg in "$@"; do
    case "$arg" in
      --worker=*) worker_id="${arg#--worker=}" ;;
      --parent-pid=*) parent_pid="${arg#--parent-pid=}" ;;
      --poller) poller_mode=true ;;
    esac
  done
  if [ -n "$parent_pid" ] && { ! [[ "$parent_pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$parent_pid" 2>/dev/null; }; then
    if [ "$poller_mode" = "true" ]; then
      log "poller startup aborted: owning daemon is not alive (parent=$parent_pid)"
    else
      log "worker startup aborted: owning daemon is not alive (parent=$parent_pid worker=$worker_id)"
    fi
    return 0
  fi

  # The producer has a deliberately small lifecycle: poll, persist, sleep.
  # It never performs worker recovery, workspace management, or task execution.
  if [ "$poller_mode" = "true" ]; then
    log "poller loop started (interval ${INTERVAL}s parent=${parent_pid:-legacy})"
    lc_log "POLLER_LOOP_START" "interval=${INTERVAL}s parent=${parent_pid:-legacy}"
    while true; do
      if [ -n "$parent_pid" ] && ! kill -0 "$parent_pid" 2>/dev/null; then
        log "poller stopping because owning daemon $parent_pid exited"
        lc_log "POLLER_STOP" "reason=parent_exited parent=$parent_pid"
        break
      fi
      configure_task_retention
      cleanup_expired_tasks
      cleanup_expired_logs
      poll_once || log "WARN: poller cycle returned non-zero"
      sleep "$INTERVAL"
    done
    return 0
  fi

  # Ensure nextAttemptAt column exists before any scheduler query
  if ! ensure_nextattemptat_column; then
    log "FATAL: schema migration failed, cannot start loop"
    exit 1
  fi

  # Ensure task claim ownership support before any claim/recovery.
  if ! ensure_claim_token_column; then
    log "FATAL: claimToken schema migration failed, cannot start loop"
    exit 1
  fi
  if ! ensure_recovery_tracking_columns; then
    log "FATAL: recovery tracking schema unavailable, cannot start consumer"
    exit 1
  fi
  if ! ensure_conversations_activeprurl_column; then
    log "FATAL: activePrUrl schema migration failed, cannot start consumer"
    exit 1
  fi

  # Recover any stale tasks from previous crashes/deadlocks.
  recover_stale_tasks
  # A recovered task can already be queued while detached children remain
  # alive from a prior worker, including heartbeats/executors from older versions.
  cleanup_orphaned_task_executors
  cleanup_orphaned_task_heartbeats

  # Source workspace manager
  source "$MANUL_DIR/workspace-manager.sh"

  # In worker mode, skip flock (each worker has its own lock)
  if [ -n "$worker_id" ]; then
    log "consumer loop started as worker $worker_id (dispatch interval ${DISPATCH_INTERVAL}s parent=${parent_pid:-legacy})"
    lc_log "LOOP_START" "worker=$worker_id role=consumer dispatchInterval=${DISPATCH_INTERVAL}s parent=${parent_pid:-legacy}"
    while true; do
      if [ -n "$parent_pid" ] && ! kill -0 "$parent_pid" 2>/dev/null; then
        log "worker $worker_id stopping because owning daemon $parent_pid exited"
        lc_log "WORKER_STOP" "worker=$worker_id reason=parent_exited parent=$parent_pid"
        break
      fi
      dispatch_once
      sleep "$DISPATCH_INTERVAL"
    done
  else
    # Singleton enforcement: try to acquire flock; if another daemon holds it, exit
    exec 200>"$FLOCK_FILE"
    if ! flock -n 200; then
      log "daemon already running (flock held); exiting"
      exit 1
    fi
    # Lock held for lifetime of daemon process

    log "daemon loop started (interval ${INTERVAL}s)"
    lc_log "LOOP_START" "interval=${INTERVAL}s"
    while true; do
      run_once
      sleep "$INTERVAL"
    done
  fi
}

# Source guard: prevent CLI execution when sourced for testing
MANUL_TESTING="${MANUL_TESTING:-false}"
if [[ "${MANUL_TESTING}" == "true" ]]; then
  return 0
fi

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  run-once) run_once ;;
  loop) shift; loop "$@" ;;
  *) echo "usage: $0 start|stop|status|run-once [loop]" >&2; exit 2 ;;
esac
