#!/usr/bin/env bash
# Regression tests for task-recovery.sh --retry on terminal infrastructure failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
MANUL_DIR="$HOME/.manul"
mkdir -p "$MANUL_DIR/state" "$MANUL_DIR/logs" "$MANUL_DIR/workspace"
cat >"$MANUL_DIR/config.json" <<'JSON'
{"retryConfig":{"delaySeconds":1}}
JSON
DB="$MANUL_DIR/state/manul.db"

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  preExecutionFailures INTEGER NOT NULL DEFAULT 0,
  agentStartedAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  workerPid INTEGER,
  leaseExpiresAt TEXT,
  claimToken TEXT,
  nextAttemptAt TEXT
);
INSERT INTO processed_comments(
  commentId,status,attempts,preExecutionFailures,agentStartedAt,processedAt,
  heartbeatAt,workerPid,leaseExpiresAt,claimToken,nextAttemptAt
) VALUES(
  'source:github_issues:owner/repo#34','failed',0,9,NULL,datetime('now'),
  '2026-11-07 20:00:00',12345,'2026-11-07 20:15:00','old-claim',NULL
);
INSERT INTO processed_comments(commentId,status,attempts,preExecutionFailures)
VALUES('running-task','running',1,4);
SQL

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label (expected=$expected got=$actual)"
  pass "$label"
}

MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/task-recovery.sh" --retry 'source:github_issues:owner/repo#34' >"$TEST_DIR/retry.log" 2>&1

row="$(sqlite3 -separator '|' "$DB" "
  SELECT status,attempts,preExecutionFailures,COALESCE(agentStartedAt,''),
         COALESCE(processedAt,''),COALESCE(heartbeatAt,''),
         COALESCE(workerPid,''),COALESCE(leaseExpiresAt,''),
         COALESCE(claimToken,''),COALESCE(nextAttemptAt,'')
  FROM processed_comments WHERE commentId='source:github_issues:owner/repo#34';
")"
IFS='|' read -r status attempts preexec agent_started processed heartbeat worker lease claim next_attempt <<<"$row"
assert_eq "failed task becomes queued" "queued" "$status"
assert_eq "agent attempt budget resets" "0" "$attempts"
assert_eq "pre-execution failure budget resets" "0" "$preexec"
assert_eq "agent start marker clears" "" "$agent_started"
assert_eq "processed timestamp clears" "" "$processed"
assert_eq "heartbeat clears" "" "$heartbeat"
assert_eq "worker PID clears" "" "$worker"
assert_eq "lease clears" "" "$lease"
assert_eq "claim token clears" "" "$claim"
[ -n "$next_attempt" ] || fail "nextAttemptAt is scheduled immediately"
pass "nextAttemptAt is scheduled immediately"

# A concurrent or already-running task must never be reset or have its executor
# PID file touched by the failed-task retry command.
RC=0
MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/task-recovery.sh" --retry 'running-task' >"$TEST_DIR/running.log" 2>&1 || RC=$?
assert_eq "non-failed task retry is rejected" "1" "$RC"
assert_eq "running task remains running" "running" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='running-task';")"
assert_eq "running task retains infra counter" "4" "$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='running-task';")"

echo "All failed-task retry tests passed."
