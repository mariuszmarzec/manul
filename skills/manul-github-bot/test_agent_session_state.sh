#!/usr/bin/env bash
# Verify claim-scoped runtime session persistence and stale-session cleanup.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=agent-session-state.sh
source "$SCRIPT_DIR/agent-session-state.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
DB="$tmp/manul-test.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  claimToken TEXT,
  session_id TEXT
);
INSERT INTO processed_comments VALUES ('task-retry', 'running', 'claim-1', 'old-session');
INSERT INTO processed_comments VALUES ('task-cont', 'running', 'claim-2', 'old-session');
INSERT INTO processed_comments VALUES ('task-no-session', 'running', 'claim-3', 'old-session');
INSERT INTO processed_comments VALUES ('task-completed', 'running', 'claim-6', 'old-session');
INSERT INTO processed_comments VALUES ('task-timeout', 'running', 'claim-7', 'old-session');
INSERT INTO processed_comments VALUES ('task-blocked', 'running', 'claim-8', 'old-session');
INSERT INTO processed_comments VALUES ('task-interrupted', 'running', 'claim-9', 'old-session');
INSERT INTO processed_comments VALUES ('task-stale-claim', 'running', 'current-claim', 'current-session');
INSERT INTO processed_comments VALUES ('task''quoted', 'running', 'claim-5', 'old-session');
SQL

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
session_for() { sqlite3 "$DB" "SELECT COALESCE(session_id, '<NULL>') FROM processed_comments WHERE commentId='$(manul_session_sql_escape "$1")';"; }

if manul_record_execution_session_state "$DB" task-retry claim-1 FAILED ""; then
  [ "$(session_for task-retry)" = "<NULL>" ] && ok "ordinary failure clears a previously persisted session" || fail "ordinary failure left a stale session"
else
  fail "ordinary failure session cleanup update failed"
fi

if manul_record_execution_session_state "$DB" task-cont claim-2 NEEDS_CONTINUATION ses-next; then
  [ "$(session_for task-cont)" = "ses-next" ] && ok "NEEDS_CONTINUATION persists its session ID" || fail "continuation session ID was not persisted"
else
  fail "continuation session persistence update failed"
fi

if manul_record_execution_session_state "$DB" task-no-session claim-3 NEEDS_CONTINUATION ""; then
  [ "$(session_for task-no-session)" = "<NULL>" ] && ok "continuation without a session ID clears stale session state" || fail "blank continuation retained stale session state"
else
  fail "blank continuation cleanup update failed"
fi


for status_case in "task-completed|claim-6|COMPLETED" "task-timeout|claim-7|TIMEOUT" "task-blocked|claim-8|BLOCKED" "task-interrupted|claim-9|INTERRUPTED"; do
  IFS='|' read -r task_id claim status <<<"$status_case"
  if manul_record_execution_session_state "$DB" "$task_id" "$claim" "$status" "unused-session"; then
    [ "$(session_for "$task_id")" = "<NULL>" ] && ok "$status clears the old runtime session" || fail "$status retained a stale runtime session"
  else
    fail "$status session cleanup update failed"
  fi
done

if manul_record_execution_session_state "$DB" task-stale-claim stale-claim FAILED ""; then
  fail "stale claim unexpectedly updated the current session"
else
  [ "$(session_for task-stale-claim)" = "current-session" ] && ok "stale claim cannot overwrite or clear a newer claim's session" || fail "stale claim changed current session state"
fi

if manul_record_execution_session_state "$DB" "task'quoted" claim-5 FAILED ""; then
  [ "$(session_for "task'quoted")" = "<NULL>" ] && ok "task IDs with SQL quotes are escaped safely" || fail "quoted task ID session was not cleared"
else
  fail "quoted task ID session cleanup failed"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
