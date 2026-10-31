#!/usr/bin/env bash
# manul-queue-reset.sh — Reset Manul task state.
#
# Default mode rebuilds replayable unfinished tasks and polls configured
# sources. --all-tasks stops automation/workers, backs up SQLite, wipes task
# and conversation state, and leaves it empty unless --poll-after is supplied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"

DB="${DB:-$MANUL_DB}"
POLL_SCRIPT="${MANUL_POLL_SCRIPT:-$MANUL_DIR/poll.sh}"
MODE="dry-run"
SCOPE="replayable"
POLL_LOCK_WAIT_SECONDS="${MANUL_QUEUE_RESET_LOCK_WAIT_SECONDS:-300}"
POLL_AFTER_FULL_RESET=0

usage() {
  cat <<'USAGE'
Usage: manul-queue-reset.sh [--dry-run|--execute] [--all-tasks] [--poll-after]

  --dry-run    Preview replayable queued/failed/stale tasks (default)
  --execute    Require confirmation, back up the DB, apply the selected reset,
               and poll once (replayable mode only)
  --all-tasks  Preview or wipe ALL task/conversation state. Execute mode stops
               Manul automation and workers, then leaves the task DB empty.
  --poll-after With --all-tasks --execute, explicitly poll configured sources
               once after the wipe. Automation remains stopped.

  MANUL_QUEUE_RESET_LOCK_WAIT_SECONDS  Max seconds to wait for poll/dispatch locks (default: 300)

The full reset creates a verified backup, stops the daemon/watchdog and recorded
task executors, waits for poll/dispatch locks, and deletes all task rows plus
conversation message/context and routing rows. By default it does NOT poll
afterward, so the database stays empty. --poll-after is an explicit opt-in.
The install baseline, config, logs, workspace state and unrelated runtime state
are preserved; any optional poll still obeys existing baselines/source filters.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --execute) MODE="execute"; shift ;;
    --all-tasks) SCOPE="all-tasks"; shift ;;
    --poll-after) POLL_AFTER_FULL_RESET=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$POLL_LOCK_WAIT_SECONDS" =~ ^[0-9]+$ ]] && [ "$POLL_LOCK_WAIT_SECONDS" -ge 1 ] || {
  echo "ERROR: MANUL_QUEUE_RESET_LOCK_WAIT_SECONDS must be a positive integer" >&2
  exit 2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if [ "$POLL_AFTER_FULL_RESET" -eq 1 ] && [ "$SCOPE" != "all-tasks" ]; then
  fail "--poll-after is supported only with --all-tasks"
fi

# Terminate detached agent executors left behind after the daemon stops. Only
# signal a PID when its current command line still identifies our task runner;
# stale PID files must never cause an unrelated, reused PID to be killed.
stop_recorded_task_executors() {
  local pid_file executor_pid process_args attempt
  local -a pid_files=()
  shopt -s nullglob
  pid_files=( "$MANUL_DIR"/task-*.executor.pid )
  shopt -u nullglob

  for pid_file in "${pid_files[@]}"; do
    executor_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ "$executor_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$executor_pid" 2>/dev/null; then
      process_args="$(ps -p "$executor_pid" -o args= 2>/dev/null || true)"
      if [[ "$process_args" == *agent-task-runner.sh* ]]; then
        echo "Stopping detached task executor (pid=$executor_pid)..."
        kill -TERM -- "-$executor_pid" 2>/dev/null || kill -TERM "$executor_pid" 2>/dev/null || true
        for attempt in {1..30}; do
          process_args="$(ps -p "$executor_pid" -o args= 2>/dev/null || true)"
          [[ "$process_args" == *agent-task-runner.sh* ]] || break
          sleep 0.1
        done
        if [[ "$process_args" == *agent-task-runner.sh* ]]; then
          kill -KILL -- "-$executor_pid" 2>/dev/null || kill -KILL "$executor_pid" 2>/dev/null || true
          sleep 0.1
          process_args="$(ps -p "$executor_pid" -o args= 2>/dev/null || true)"
        fi
        [[ "$process_args" != *agent-task-runner.sh* ]] || fail "task executor $executor_pid did not stop; no task rows were deleted"
      else
        echo "WARN: ignoring stale executor PID file (PID $executor_pid is not agent-task-runner.sh): $pid_file" >&2
      fi
    fi
    rm -f "$pid_file"
  done
}

for cmd in sqlite3 flock ps; do
  command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
done

[ -f "$DB" ] || fail "Manul database not found: $DB"
sqlite3 "$DB" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok" || fail "database integrity check failed: $DB"
sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='processed_comments';" 2>/dev/null | grep -qx "1" || fail "processed_comments table is missing"
[ -f "$POLL_SCRIPT" ] || fail "poll script not found: $POLL_SCRIPT"

has_column() {
  local table="$1" column="$2"
  sqlite3 "$DB" "PRAGMA table_info($table);" 2>/dev/null |
    awk -F'|' -v wanted="$column" '$2 == wanted { found=1 } END { exit !found }'
}

has_table() {
  sqlite3 "$DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$1';" 2>/dev/null | grep -qx "1"
}

SOURCE_PREDICATE="0"
if has_column processed_comments taskSourceType && has_column processed_comments taskSourceId; then
  SOURCE_PREDICATE="(taskSourceType IN ('github_issues','jira_tasks','todo_local_mcp','todo_remote_mcp') AND COALESCE(taskSourceId,'') <> '')"
fi

# Only include GitHub comment IDs that poll.sh can rediscover. Never delete
# arbitrary comment-like IDs or user-submitted tasks that have no source trigger.
GITHUB_COMMENT_PREDICATE="(
  COALESCE(taskSourceType,'') = '' AND (
    (
      commentId <> '' AND commentId NOT GLOB '*[^0-9]*' AND
      (commentUrl LIKE 'https://github.com/%#issuecomment-%' OR commentUrl LIKE 'https://github.com/%#discussion_r%')
    ) OR (
      commentId LIKE 'issue:%' AND substr(commentId,7) <> '' AND
      substr(commentId,7) NOT GLOB '*[^0-9]*' AND
      commentUrl LIKE 'https://github.com/%#issuecomment-%'
    ) OR (
      commentId LIKE 'issuebody:%' AND substr(commentId,11) <> '' AND
      substr(commentId,11) NOT GLOB '*[^0-9]*' AND
      (commentUrl LIKE 'https://github.com/%/issues/%' OR commentUrl LIKE 'https://github.com/%/pull/%')
    ) OR (
      commentId LIKE 'review:%' AND substr(commentId,8) <> '' AND
      substr(commentId,8) NOT GLOB '*[^0-9]*' AND
      commentUrl LIKE 'https://github.com/%#discussion_r%'
    )
  )
)"
if ! has_column processed_comments taskSourceType; then
  GITHUB_COMMENT_PREDICATE="(
    (
      commentId <> '' AND commentId NOT GLOB '*[^0-9]*' AND
      (commentUrl LIKE 'https://github.com/%#issuecomment-%' OR commentUrl LIKE 'https://github.com/%#discussion_r%')
    ) OR (
      commentId LIKE 'issue:%' AND substr(commentId,7) <> '' AND
      substr(commentId,7) NOT GLOB '*[^0-9]*' AND
      commentUrl LIKE 'https://github.com/%#issuecomment-%'
    ) OR (
      commentId LIKE 'issuebody:%' AND substr(commentId,11) <> '' AND
      substr(commentId,11) NOT GLOB '*[^0-9]*' AND
      (commentUrl LIKE 'https://github.com/%/issues/%' OR commentUrl LIKE 'https://github.com/%/pull/%')
    ) OR (
      commentId LIKE 'review:%' AND substr(commentId,8) <> '' AND
      substr(commentId,8) NOT GLOB '*[^0-9]*' AND
      commentUrl LIKE 'https://github.com/%#discussion_r%'
    )
  )"
fi

WORKER_PREDICATE="1"
WORKER_PRESERVE_PREDICATE="0"
ACTIVE_TASK_PREDICATE="status='running'"
if has_column processed_comments workerPid; then
  # Fail closed for any row that still carries worker ownership metadata,
  # including stale/queued rows left behind by a crashed or lagging worker.
  WORKER_PREDICATE="COALESCE(workerPid,0)=0"
  WORKER_PRESERVE_PREDICATE="COALESCE(workerPid,0)<>0"
  ACTIVE_TASK_PREDICATE="$ACTIVE_TASK_PREDICATE OR COALESCE(workerPid,0)<>0"
fi
if has_column processed_comments claimToken; then
  ACTIVE_TASK_PREDICATE="$ACTIVE_TASK_PREDICATE OR COALESCE(claimToken,'')<>''"
fi

CANDIDATE_PREDICATE="status IN ('queued','failed','stale') AND $WORKER_PREDICATE AND (($SOURCE_PREDICATE) OR $GITHUB_COMMENT_PREDICATE)"

show_counts() {
  echo "$1"
  sqlite3 "$DB" "
    SELECT '  replayable_' || status || '=' || COUNT(*)
    FROM processed_comments
    WHERE $CANDIDATE_PREDICATE
    GROUP BY status
    ORDER BY status;
    SELECT '  replayable_total=' || COUNT(*)
    FROM processed_comments WHERE $CANDIDATE_PREDICATE;
    SELECT '  running_preserved=' || COUNT(*)
    FROM processed_comments WHERE status='running';
    SELECT '  completed_preserved=' || COUNT(*)
    FROM processed_comments WHERE status IN ('done','completed');
    SELECT '  blocked_user_preserved=' || COUNT(*)
    FROM processed_comments WHERE status='blocked_user';
    SELECT '  worker_assigned_preserved=' || COUNT(*)
    FROM processed_comments
    WHERE status IN ('queued','failed','stale') AND $WORKER_PRESERVE_PREDICATE;
    SELECT '  manual_or_unreplayable_preserved=' || COUNT(*)
    FROM processed_comments WHERE status IN ('queued','failed','stale')
      AND $WORKER_PREDICATE
      AND NOT ($SOURCE_PREDICATE OR $GITHUB_COMMENT_PREDICATE);
  " 2>/dev/null
}

show_full_counts() {
  echo "Manul FULL task reset preview (read-only):"
  sqlite3 "$DB" "
    SELECT '  all_task_rows=' || COUNT(*) FROM processed_comments;
    SELECT '  running=' || COUNT(*) FROM processed_comments WHERE status='running';
    SELECT '  worker_owned_rows=' || COUNT(*) FROM processed_comments
      WHERE $ACTIVE_TASK_PREDICATE;
  " 2>/dev/null
  if has_table conversation_messages; then
    echo "  conversation_messages=$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages;" 2>/dev/null)"
  fi
  if has_table conversations; then
    echo "  conversations=$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations;" 2>/dev/null)"
  fi
  if has_table conversation_links; then
    echo "  conversation_links=$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_links;" 2>/dev/null)"
  fi
  echo "  install_baseline=preserved"
  echo "  workspace_state=preserved"
}

if [ "$MODE" = "dry-run" ]; then
  if [ "$SCOPE" = "all-tasks" ]; then
    show_full_counts
    echo "No changes made. Run with --all-tasks --execute to stop automation and leave task state empty; add --poll-after only if rediscovery is wanted immediately."
  else
    show_counts "Manul queue reset preview (read-only):"
    echo "No changes made. Run with --execute to rebuild the replayable queue."
  fi
  exit 0
fi

if [ "$SCOPE" = "all-tasks" ]; then
  read -r -p "This deletes ALL task rows and conversation routing/dedupe state. Type DELETE ALL TASKS to continue: " CONFIRMATION
  [ "$CONFIRMATION" = "DELETE ALL TASKS" ] || fail "confirmation did not match; no changes made"
else
  read -r -p "This replays unfinished externally-sourced tasks. Type RESET QUEUE to continue: " CONFIRMATION
  [ "$CONFIRMATION" = "RESET QUEUE" ] || fail "confirmation did not match; no changes made"
fi

if [ "$SCOPE" = "all-tasks" ]; then
  AUTOMATION_CONTROL="$MANUL_DIR/start-manul-automation.sh"
  DAEMON_CONTROL="$MANUL_DIR/manul-daemon.sh"
  if [ -x "$AUTOMATION_CONTROL" ]; then
    echo "Stopping Manul automation and watchdog..."
    "$AUTOMATION_CONTROL" stop || fail "could not stop Manul automation; no task data was deleted"
  elif [ -x "$DAEMON_CONTROL" ]; then
    echo "Stopping Manul daemon..."
    rm -f "$MANUL_DIR/.enabled"
    "$DAEMON_CONTROL" stop || fail "could not stop Manul daemon; no task data was deleted"
  else
    fail "could not find Manul automation/daemon stop command; no task data was deleted"
  fi

  [ -x "$DAEMON_CONTROL" ] || fail "cannot verify daemon shutdown; no task data was deleted"
  DAEMON_STATUS="$("$DAEMON_CONTROL" status 2>/dev/null || true)"
  [ "$DAEMON_STATUS" = "not running" ] || fail "Manul daemon is not confirmed stopped (status: ${DAEMON_STATUS:-unknown}); no task data was deleted"

  stop_recorded_task_executors
fi

mkdir -p "$MANUL_LOCKS_DIR" "$MANUL_STATE_DIR/backups"
POLL_LOCK_FILE="$MANUL_LOCKS_DIR/poll.flock"
exec 200>"$POLL_LOCK_FILE"
echo "Waiting up to ${POLL_LOCK_WAIT_SECONDS}s for the current poll to finish..."
flock -w "$POLL_LOCK_WAIT_SECONDS" 200 || fail "poll.sh still holds the poll lock after ${POLL_LOCK_WAIT_SECONDS}s; no queue changes were made. Inspect the holder with: lslocks -o PID,COMMAND,TYPE,MODE,PATH | grep poll.flock"

if [ "$SCOPE" = "all-tasks" ]; then
  DISPATCH_LOCK_FILE="$MANUL_LOCKS_DIR/task-dispatch.flock"
  exec 201>"$DISPATCH_LOCK_FILE"
  echo "Waiting up to ${POLL_LOCK_WAIT_SECONDS}s for task dispatch to finish..."
  flock -w "$POLL_LOCK_WAIT_SECONDS" 201 || fail "task dispatcher still holds its lock after ${POLL_LOCK_WAIT_SECONDS}s; no task data was deleted"
fi

BACKUP_SCOPE="replayable"
[ "$SCOPE" = "all-tasks" ] && BACKUP_SCOPE="all-tasks"
BACKUP_FILE="$MANUL_STATE_DIR/backups/manul-queue-reset-${BACKUP_SCOPE}-$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}.db"
backup_database() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$DB" "$BACKUP_FILE" <<'PY'
import sqlite3
import sys

source_path, backup_path = sys.argv[1], sys.argv[2]
with sqlite3.connect(source_path, timeout=30) as source:
    with sqlite3.connect(backup_path, timeout=30) as destination:
        source.backup(destination)
        result = destination.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise SystemExit(f"backup integrity check failed: {result}")
PY
  else
    local quoted
    quoted="$(printf '%s' "$BACKUP_FILE" | sed "s/'/''/g")"
    sqlite3 "$DB" ".backup '$quoted'"
    sqlite3 "$BACKUP_FILE" "PRAGMA integrity_check;" | grep -qx "ok"
  fi
}
backup_database || fail "could not create a verified database backup"
echo "Backup: $BACKUP_FILE"

if [ "$SCOPE" = "all-tasks" ]; then
  # Automation is stopped and both poll/dispatch locks are held. Wipe the
  # task/conversation tables unconditionally; stale worker metadata is exactly
  # what this administrative reset is intended to remove.
  FULL_RESET_SQL="BEGIN IMMEDIATE;
"
  if has_table conversation_links; then
    FULL_RESET_SQL+=$'DELETE FROM conversation_links;\n'
    FULL_RESET_SQL+=$'SELECT \'deleted_conversation_links=\' || changes();\n'
  fi
  if has_table conversation_messages; then
    FULL_RESET_SQL+=$'DELETE FROM conversation_messages;\n'
    FULL_RESET_SQL+=$'SELECT \'deleted_conversation_messages=\' || changes();\n'
  fi
  FULL_RESET_SQL+=$'DELETE FROM processed_comments;\n'
  FULL_RESET_SQL+=$'SELECT \'deleted_tasks=\' || changes();\n'
  if has_table conversations; then
    FULL_RESET_SQL+=$'DELETE FROM conversations;\n'
    FULL_RESET_SQL+=$'SELECT \'deleted_conversations=\' || changes();\n'
  fi
  FULL_RESET_SQL+=$'COMMIT;'
  SQL_OUTPUT="$(sqlite3 -bail "$DB" <<<"$FULL_RESET_SQL")" || fail "could not perform full task reset"
  DELETED_TASKS="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^deleted_tasks=//p' | tail -n1)"
  DELETED_MESSAGES="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^deleted_conversation_messages=//p' | tail -n1)"
  DELETED_LINKS="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^deleted_conversation_links=//p' | tail -n1)"
  DELETED_CONVERSATIONS="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^deleted_conversations=//p' | tail -n1)"
  DELETED_TASKS="${DELETED_TASKS:-0}"
  DELETED_MESSAGES="${DELETED_MESSAGES:-0}"
  DELETED_LINKS="${DELETED_LINKS:-0}"
  DELETED_CONVERSATIONS="${DELETED_CONVERSATIONS:-0}"
  [[ "$DELETED_TASKS" =~ ^[0-9]+$ ]] || fail "could not read deleted task count"

  for table in processed_comments conversation_messages conversation_links conversations; do
    if has_table "$table"; then
      REMAINING="$(sqlite3 "$DB" "SELECT COUNT(*) FROM \"$table\";" 2>/dev/null)"
      [ "$REMAINING" = "0" ] || fail "full reset verification failed: $table still contains $REMAINING rows"
    fi
  done

else
  BASE_EXPR="NULL"
  has_column processed_comments baseId && BASE_EXPR="baseId"
  TYPE_EXPR="''"
  has_column processed_comments taskSourceType && TYPE_EXPR="COALESCE(taskSourceType,'')"
  HAS_MESSAGES=0
  has_table conversation_messages && HAS_MESSAGES=1

  MESSAGE_DELETE_SQL=""
  if [ "$HAS_MESSAGES" -eq 1 ]; then
    MESSAGE_DELETE_SQL="DELETE FROM conversation_messages
WHERE commentId IN (SELECT commentId FROM queue_reset_candidates)
   OR commentId IN (SELECT baseId FROM queue_reset_candidates WHERE baseId IS NOT NULL)
   OR commentId IN (SELECT substr(commentId,7) FROM queue_reset_candidates WHERE commentId LIKE 'issue:%')
   OR commentId IN (SELECT substr(commentId,11) FROM queue_reset_candidates WHERE commentId LIKE 'issuebody:%')
   OR commentId IN (SELECT substr(commentId,8) FROM queue_reset_candidates WHERE commentId LIKE 'review:%');"
  fi

  # Selection and deletion share one write transaction. If a worker claimed a
  # queued item before BEGIN IMMEDIATE, the task is now running and is not selected.
  SQL_OUTPUT="$(sqlite3 -bail "$DB" <<SQL
BEGIN IMMEDIATE;
CREATE TEMP TABLE queue_reset_candidates AS
  SELECT commentId, $BASE_EXPR AS baseId, $TYPE_EXPR AS taskSourceType
  FROM processed_comments
  WHERE $CANDIDATE_PREDICATE;
SELECT 'candidate_count=' || COUNT(*) FROM queue_reset_candidates;
$MESSAGE_DELETE_SQL
DELETE FROM processed_comments
WHERE commentId IN (SELECT commentId FROM queue_reset_candidates)
  AND status IN ('queued','failed','stale');
SELECT 'deleted_tasks=' || changes();
DROP TABLE queue_reset_candidates;
COMMIT;
SQL
  )" || fail "could not reset replayable tasks"

  CANDIDATE_COUNT="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^candidate_count=//p' | tail -n1)"
  DELETED_TASKS="$(printf '%s\n' "$SQL_OUTPUT" | sed -n 's/^deleted_tasks=//p' | tail -n1)"
  CANDIDATE_COUNT="${CANDIDATE_COUNT:-0}"
  DELETED_TASKS="${DELETED_TASKS:-0}"
  [[ "$CANDIDATE_COUNT" =~ ^[0-9]+$ ]] || fail "could not read candidate count"
  [[ "$DELETED_TASKS" =~ ^[0-9]+$ ]] || fail "could not read deleted task count"
fi

if [ "$SCOPE" = "all-tasks" ]; then
  flock -u 201 || true
  exec 201>&-
fi
flock -u 200 || true
exec 200>&-

if [ "$SCOPE" = "all-tasks" ]; then
  echo "Removed task rows: $DELETED_TASKS"
  echo "Removed conversation-message rows: $DELETED_MESSAGES"
  echo "Removed conversation-link rows: $DELETED_LINKS"
  echo "Removed conversation rows: $DELETED_CONVERSATIONS"
  echo "Preserved install baseline, configuration, workspace state and unrelated runtime state."
  echo "Manul automation and its watchdog remain stopped."
else
  echo "Replayable tasks found: $CANDIDATE_COUNT"
  echo "Removed replayable tasks: $DELETED_TASKS"
  echo "Preserved running workers, completed tasks, blocked-user tasks, worker-assigned rows, manual submissions, conversations, workspace state, and baseline."
fi
if [ "$SCOPE" = "all-tasks" ] && [ "$POLL_AFTER_FULL_RESET" -eq 0 ]; then
  echo "Polling intentionally skipped; task and conversation state remains empty."
  echo "Manul automation remains stopped. Start it explicitly when ready: $MANUL_DIR/start-manul-automation.sh start"
  echo "Full reset complete. Backup retained at: $BACKUP_FILE"
  exit 0
fi

echo "Running the configured poller now..."

POLL_OUTPUT=""
POLL_EXIT=0
POLL_OUTPUT="$(MANUL_DIR="$MANUL_DIR" MANUL_DB="$DB" DB="$DB" bash "$POLL_SCRIPT" 2>&1)" || POLL_EXIT=$?
printf '%s\n' "$POLL_OUTPUT"

if [ "$POLL_EXIT" -ne 0 ]; then
  echo "ERROR: poll.sh exited with status $POLL_EXIT. Backup: $BACKUP_FILE" >&2
  exit "$POLL_EXIT"
fi

RESULT_JSON="$(printf '%s\n' "$POLL_OUTPUT" | sed -n 's/^MANUL_RESULT //p' | tail -n1)"
if [ -n "$RESULT_JSON" ] && printf '%s' "$RESULT_JSON" | jq -e '.error != null' >/dev/null 2>&1; then
  echo "ERROR: poller reported an error. Backup: $BACKUP_FILE" >&2
  exit 1
fi

echo
echo "Queue after poll:"
sqlite3 "$DB" "
  SELECT '  queued=' || COUNT(*) FROM processed_comments WHERE status='queued';
  SELECT '  running=' || COUNT(*) FROM processed_comments WHERE status='running';
  SELECT '  failed=' || COUNT(*) FROM processed_comments WHERE status='failed';
"
echo "Reset/re-poll complete. Backup retained at: $BACKUP_FILE"
