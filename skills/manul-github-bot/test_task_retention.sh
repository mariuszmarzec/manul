#!/bin/bash
# test_task_retention.sh - Task retention, status windows and cleanup tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
mkdir -p "$MANUL_DIR/state"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

write_config() {
  local list_days="$1" history_days="$2"
  cat >"$MANUL_DIR/config.json" <<EOF
{
  "retention": {
    "listDays": $list_days,
    "historyDays": $history_days
  }
}
EOF
}

init_db() {
  sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT,
  author TEXT,
  agent TEXT,
  prompt TEXT,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  claimToken TEXT,
  resultSummary TEXT,
  resultJson TEXT,
  workerPid INTEGER,
  nextAttemptAt TEXT,
  baseId TEXT
);
SQL
}

assert_contains() {
  local desc="$1" text="$2" needle="$3"
  printf '%s' "$text" | grep -F -- "$needle" >/dev/null || fail "$desc"
  pass "$desc"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$desc: expected=$expected actual=$actual"
  pass "$desc"
}

init_db

# ---------------------------------------------------------------------------
# 1. Status windows
# ---------------------------------------------------------------------------
write_config 7 14
sqlite3 "$DB" <<'SQL'
INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,processedAt)
VALUES
('queued-old','repo/a',1,'queued',0,datetime('now','-30 days'),NULL),
('running-old','repo/a',2,'running',1,datetime('now','-30 days'),datetime('now','-30 days')),
('completed-recent','repo/a',3,'completed',1,datetime('now','-8 days'),datetime('now','-2 days')),
('completed-history','repo/a',4,'completed',1,datetime('now','-20 days'),datetime('now','-10 days')),
('failed-expired','repo/a',5,'failed',3,datetime('now','-20 days'),datetime('now','-15 days')),
('stale-recent','repo/a',6,'stale',1,datetime('now','-9 days'),datetime('now','-5 days'));
SQL

LIST_JSON="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --json)"
printf '%s' "$LIST_JSON" | jq -e 'map(.taskId) | sort == ["completed-recent","queued-old","running-old","stale-recent"]' >/dev/null || fail "--list keeps active + terminal tasks within listDays"
pass "--list keeps active + terminal tasks within listDays"

HISTORY_JSON="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --history --json)"
printf '%s' "$HISTORY_JSON" | jq -e 'map(.taskId) | sort == ["completed-history","completed-recent","stale-recent"]' >/dev/null || fail "--history keeps terminal tasks within historyDays"
pass "--history keeps terminal tasks within historyDays"

# ---------------------------------------------------------------------------
# 2. Daemon cleanup removes only terminal tasks older than historyDays
# ---------------------------------------------------------------------------
MANUL_TESTING=true MANUL_DIR="$MANUL_DIR" bash -c   'source "$1"; configure_task_retention; cleanup_expired_tasks' _ "$SCRIPT_DIR/manul-daemon.sh"

assert_eq "cleanup keeps active tasks" "2"   "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status IN ('queued','running');")"
assert_eq "cleanup keeps recent terminal tasks" "2"   "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId IN ('completed-recent','stale-recent');")"
assert_eq "expired terminal rows deleted" "0"   "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='failed-expired';")"
assert_eq "history-window terminal row is retained" "1"   "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='completed-history';")"

# ---------------------------------------------------------------------------
# 3. Log cleanup removes every stale log file after seven days only
# ---------------------------------------------------------------------------
LOG_DIR="$MANUL_DIR/logs"
mkdir -p "$LOG_DIR/tasks/old-comment" "$LOG_DIR/tasks/recent-comment"
printf 'old log\n' >"$LOG_DIR/old-general.log"
printf 'old wrapper log\n' >"$MANUL_DIR/daemon.log"
printf 'old task diagnostic\n' >"$LOG_DIR/tasks/old-comment/attempt-1.stdout"
printf 'recent task diagnostic\n' >"$LOG_DIR/tasks/recent-comment/attempt-1.stdout"
printf 'old state, not a log\n' >"$MANUL_DIR/state/old-state.log"
touch -d '8 days ago' \
  "$LOG_DIR/old-general.log" \
  "$MANUL_DIR/daemon.log" \
  "$LOG_DIR/tasks/old-comment/attempt-1.stdout" \
  "$MANUL_DIR/state/old-state.log"

MANUL_TESTING=true MANUL_DIR="$MANUL_DIR" bash -c \
  'source "$1"; cleanup_expired_logs' _ "$SCRIPT_DIR/manul-daemon.sh"

assert_eq "expired root log is deleted" "0" "$(if [ -e "$LOG_DIR/old-general.log" ]; then echo 1; else echo 0; fi)"
assert_eq "expired startup wrapper log is deleted" "0" "$(if [ -e "$MANUL_DIR/daemon.log" ]; then echo 1; else echo 0; fi)"
assert_eq "expired nested task diagnostic is deleted" "0" "$(if [ -e "$LOG_DIR/tasks/old-comment/attempt-1.stdout" ]; then echo 1; else echo 0; fi)"
assert_eq "recent nested task diagnostic is retained" "1" "$(if [ -e "$LOG_DIR/tasks/recent-comment/attempt-1.stdout" ]; then echo 1; else echo 0; fi)"
assert_eq "files outside the log directory are retained" "1" "$(if [ -e "$MANUL_DIR/state/old-state.log" ]; then echo 1; else echo 0; fi)"
assert_eq "empty expired task archive directory is pruned" "0" "$(if [ -d "$LOG_DIR/tasks/old-comment" ]; then echo 1; else echo 0; fi)"

EXTERNAL_TASK_LOG_DIR="$MANUL_DIR/state/task-archives"
mkdir -p "$EXTERNAL_TASK_LOG_DIR/empty"
MANUL_TESTING=true MANUL_DIR="$MANUL_DIR" MANUL_TASK_LOG_DIR="$EXTERNAL_TASK_LOG_DIR" bash -c \
  'source "$1"; cleanup_expired_logs' _ "$SCRIPT_DIR/manul-daemon.sh"
assert_eq "custom task archives outside the log tree are not pruned" "1" "$(if [ -d "$EXTERNAL_TASK_LOG_DIR/empty" ]; then echo 1; else echo 0; fi)"

# ---------------------------------------------------------------------------
# 4. Invalid retention config falls back to 7/14 without failing
# ---------------------------------------------------------------------------
write_config 10 19
RETENTION_OUT="$(
  MANUL_TESTING=true MANUL_DIR="$MANUL_DIR" bash -c     'source "$1"; configure_task_retention; printf "%s|%s|%s" "$TASK_LIST_RETENTION_DAYS" "$TASK_HISTORY_RETENTION_DAYS" "$TASK_RETENTION_CONFIG_MESSAGE"'     _ "$SCRIPT_DIR/manul-daemon.sh"
)"

assert_eq "invalid config falls back to listDays=7" "7" "$(printf '%s' "$RETENTION_OUT" | cut -d'|' -f1)"
assert_eq "invalid config falls back to historyDays=14" "14" "$(printf '%s' "$RETENTION_OUT" | cut -d'|' -f2)"
assert_contains "invalid config produces WARN message" "$(printf '%s' "$RETENTION_OUT" | cut -d'|' -f3-)" "WARN: invalid retention config"

# Also verify missing config values are non-fatal.
cat >"$MANUL_DIR/config.json" <<'EOF'
{}
EOF
RETENTION_OUT="$(
  MANUL_TESTING=true MANUL_DIR="$MANUL_DIR" bash -c     'source "$1"; configure_task_retention; printf "%s|%s|%s" "$TASK_LIST_RETENTION_DAYS" "$TASK_HISTORY_RETENTION_DAYS" "$TASK_RETENTION_CONFIG_MESSAGE"'     _ "$SCRIPT_DIR/manul-daemon.sh"
)"
assert_eq "missing config falls back to listDays=7" "7" "$(printf '%s' "$RETENTION_OUT" | cut -d'|' -f1)"
assert_eq "missing config falls back to historyDays=14" "14" "$(printf '%s' "$RETENTION_OUT" | cut -d'|' -f2)"

echo "All task retention tests passed."
