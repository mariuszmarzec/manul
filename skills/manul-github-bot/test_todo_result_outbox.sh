#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/manul-daemon.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
DB="$TEST_DIR/manul.db"
MANUL_DIR="$TEST_DIR/manul"
CONFIG="$TEST_DIR/config.json"
LOG="$TEST_DIR/daemon.log"
mkdir -p "$MANUL_DIR/state"
: > "$LOG"
printf '{}' > "$CONFIG"
export DB MANUL_DIR CONFIG LOG
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
log() { printf '%s\n' "$*" >>"$LOG"; }
lc_log() { :; }

for function_name in ensure_todo_result_outbox_table queue_todo_result_update todo_result_outbox_is_delivered retry_pending_todo_result_updates publish_todo_task_result; do
  eval "$(sed -n "/^${function_name}() {/,/^}/p" "$DAEMON")"
done
PUBLISH_RC=0
COMPLETE_RC=0
CALLS="$TEST_DIR/provider-calls.log"
: > "$CALLS"
task_source_is_todo_type() { case "$1" in todo_local_mcp|todo_remote_mcp) return 0 ;; *) return 1 ;; esac; }
task_source_publish_update() {
  printf 'publish|%s|%s\n' "$3" "$4" >>"$CALLS"
  if [ "$PUBLISH_RC" -ne 0 ]; then echo "injected Todo MCP outage" >&2; return "$PUBLISH_RC"; fi
  printf '{"status":"%s","updateTaskId":7001}\n' "$4"
}
task_source_complete() { printf 'complete|%s|%s\n' "$2" "$3" >>"$CALLS"; return "$COMPLETE_RC"; }
sqlite3 "$DB" "
  CREATE TABLE processed_comments(
    commentId TEXT PRIMARY KEY, status TEXT NOT NULL, processedAt TEXT,
    heartbeatAt TEXT, leaseExpiresAt TEXT, workerPid INTEGER,
    claimToken TEXT, agentStartedAt TEXT, nextAttemptAt TEXT
  );
  INSERT INTO processed_comments(commentId,status) VALUES('completed-task','running');
  INSERT INTO processed_comments(commentId,status) VALUES('failed-task','failed');
"
assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" = "$actual" ]; then echo "PASS: $message"
  else echo "FAIL: $message (expected=$expected actual=$actual)" >&2; exit 1; fi
}

echo "=== completed result survives a Todo outage ==="
PUBLISH_RC=1
publish_rc=0
publish_todo_task_result "completed-task" "todo_local_mcp" "503@aaaaaaaaaaaaaaaa" "Review result: REQUEST_CHANGES" || publish_rc=$?
assert_eq "10" "$publish_rc" "delivery failure is distinguished from outbox persistence failure"
assert_eq "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manul_todo_result_outbox WHERE taskId='completed-task' AND deliveredAt IS NULL;")" "completed report is durably queued"
assert_eq "1" "$(sqlite3 "$DB" "SELECT attempts FROM manul_todo_result_outbox WHERE taskId='completed-task';")" "failed delivery increments retry count"
queue_todo_result_update "completed-task" "todo_local_mcp" "503@aaaaaaaaaaaaaaaa" completed "Retry must preserve original report." >/dev/null
assert_eq "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manul_todo_result_outbox WHERE taskId='completed-task';")" "outbox enqueue is idempotent"

sqlite3 "$DB" "
  UPDATE processed_comments SET status='delivery_pending' WHERE commentId='completed-task';
  UPDATE manul_todo_result_outbox SET nextAttemptAt=datetime('now','-1 second') WHERE taskId='completed-task';
"
PUBLISH_RC=0
COMPLETE_RC=0
retry_pending_todo_result_updates
assert_eq "completed" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='completed-task';")" "successful retry finalizes pending Manul state"
assert_eq "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manul_todo_result_outbox WHERE taskId='completed-task' AND deliveredAt IS NOT NULL;")" "completed result receives durable delivery receipt"
assert_eq "publish|503@aaaaaaaaaaaaaaaa|completed" "$(sed -n '2p' "$CALLS")" "retry publishes the completed report"
assert_eq "complete|todo_local_mcp|503@aaaaaaaaaaaaaaaa" "$(sed -n '3p' "$CALLS")" "Todo tree is completed only after its report"

echo "=== failed report retries ==="
PUBLISH_RC=1
queue_todo_result_update "failed-task" "todo_local_mcp" "601@bbbbbbbbbbbbbbbb" failed "Stage: review; reason: MCP unavailable." >/dev/null
retry_pending_todo_result_updates "failed-task" "todo_local_mcp" "601@bbbbbbbbbbbbbbbb" failed
assert_eq "failed" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='failed-task';")" "failed task remains terminal while report is pending"
assert_eq "1" "$(sqlite3 "$DB" "SELECT attempts FROM manul_todo_result_outbox WHERE taskId='failed-task';")" "failed result outage increments retry count"
sqlite3 "$DB" "UPDATE manul_todo_result_outbox SET nextAttemptAt=datetime('now','-1 second') WHERE taskId='failed-task';"
PUBLISH_RC=0
retry_pending_todo_result_updates
assert_eq "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM manul_todo_result_outbox WHERE taskId='failed-task' AND deliveredAt IS NOT NULL;")" "failed report is eventually acknowledged"
assert_eq "1" "$(grep -c '^complete|' "$CALLS" || true)" "failed report never completes its Todo root"
echo "All Todo result outbox tests passed."
