#!/bin/bash
# test_poll_result_parsing.sh — regression tests for daemon poll-result handling.
#
# Guards against the production regression where a literal "\n" was passed to
# printf, causing malformed JSON, multi-value jq output, and a false dispatch gate.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/lifecycle.log"
LAST_POLL_FILE="$MANUL_DIR/last-poll"
export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG LAST_POLL_FILE MANUL_TESTING=true

mkdir -p "$MANUL_DIR/workspaces"
cat >"$CONFIG" <<'EOF'
{
  "pollInterval": 60,
  "repositories": [],
  "automation": {
    "maxConcurrentTasks": 1,
    "maxAttemptsBeforeFail": 3,
    "heartbeatInterval": 60,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900
  },
  "retryConfig": {
    "delaySeconds": 60
  }
}
EOF

# Load only the exact production function bodies under test; do not execute daemon CLI/bootstrap code.
log() { :; }
eval "$(sed -n '/^parse_poll_result() {/,/^}/p' "$SCRIPT_DIR/manul-daemon.sh")"
eval "$(sed -n '/^eligible_queued_count() {/,/^}/p' "$SCRIPT_DIR/manul-daemon.sh")"
eval "$(sed -n '/^has_unresolved_manul_tasks() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
eval "$(sed -n '/^is_manul_owned_pr() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
eval "$(sed -n '/^sql_num() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
eval "$(sed -n '/^sql_escape() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS $name"
  else
    echo "FAIL $name: expected [$expected], got [$actual]" >&2
    exit 1
  fi
}

echo "=== Parser: clean queued result ==="
result="$(parse_poll_result 'diagnostic
MANUL_RESULT {"fire":true,"new":0,"pending":1}')"
assert_eq "clean-fire" "true|0|1" "$result"

echo "=== Parser: two MANUL_RESULT lines, last one wins ==="
result="$(parse_poll_result $'MANUL_RESULT {"fire":true,"new":1,"pending":1}\nMANUL_RESULT {"fire":false,"new":0,"pending":1}')"
assert_eq "multi-line" "false|0|1" "$result"

echo "=== Parser: malformed literal backslash-n suffix is rejected ==="
result="$(parse_poll_result 'MANUL_RESULT {"fire":true,"new":0,"pending":1}\n')"
assert_eq "literal-backslash-n" "false|0|0" "$result"

echo "=== Parser: non-object JSON is rejected ==="
result="$(parse_poll_result 'MANUL_RESULT []')"
assert_eq "non-object" "false|0|0" "$result"

echo "=== Parser: no result defaults safely ==="
result="$(parse_poll_result 'poll diagnostic only')"
assert_eq "empty" "false|0|0" "$result"

echo "=== Queue eligibility: attempts=0 is runnable ==="
sqlite3 "$DB" "CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  nextAttemptAt TEXT,
  repository TEXT DEFAULT 'test/repo',
  issueNumber INTEGER DEFAULT 1,
  prNumber INTEGER,
  prUrl TEXT
);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt) VALUES ('a','queued',0,NULL);"
assert_eq "eligible-attempt-zero" "1" "$(eligible_queued_count)"

echo "=== Queue eligibility: due retry is runnable ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt) VALUES ('b','queued',1,datetime('now','-1 minute'));"
assert_eq "eligible-due-retry" "2" "$(eligible_queued_count)"

echo "=== Queue eligibility: future retry is not runnable ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt) VALUES ('c','queued',1,'2099-01-01 00:00:00');"
assert_eq "future-retry-filtered" "2" "$(eligible_queued_count)"

echo "=== Queue eligibility: retry with NULL deadline is not stranded ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt) VALUES ('d','queued',2,NULL);"
assert_eq "null-retry-deadline-is-eligible" "3" "$(eligible_queued_count)"

echo "=== Queue eligibility: ISO UTC deadlines are normalized before comparison ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt) VALUES ('iso-due','queued',1,'2020-01-01T00:00:00Z');"
assert_eq "iso-due-retry-eligible" "4" "$(eligible_queued_count)"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt) VALUES ('iso-future','queued',1,'2099-01-01T00:00:00Z');"
assert_eq "iso-future-retry-filtered" "4" "$(eligible_queued_count)"


echo "=== Poll CI provenance: arbitrary PRs must not be auto-fixed ==="
if is_manul_owned_pr "test/repo" "93" "https://github.com/test/repo/pull/93"; then
  echo "FAIL: arbitrary PR unexpectedly considered Manul-owned" >&2
  exit 1
fi
echo "PASS: arbitrary PR without a verified task deliverable is rejected"

sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt,repository,issueNumber,prNumber,prUrl) VALUES ('ci_fix:test/repo:93:run-1','completed',1,NULL,'test/repo',93,93,'https://github.com/test/repo/pull/93');"
if is_manul_owned_pr "test/repo" "93" "https://github.com/test/repo/pull/93"; then
  echo "FAIL: synthetic CI task must not establish PR ownership" >&2
  exit 1
fi
echo "PASS: synthetic CI task cannot establish ownership"

sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt,repository,issueNumber,prNumber,prUrl) VALUES ('issue:task-93','completed',1,NULL,'test/repo',12,93,'https://github.com/test/repo/pull/93');"
if ! is_manul_owned_pr "test/repo" "93" "https://github.com/test/repo/pull/93"; then
  echo "FAIL: verified completed Manul deliverable should be eligible" >&2
  exit 1
fi
echo "PASS: exact verified Manul deliverable is eligible"

if is_manul_owned_pr "test/repo" "93" "https://github.com/test/repo/pull/94"; then
  echo "FAIL: mismatched PR URL unexpectedly considered Manul-owned" >&2
  exit 1
fi
echo "PASS: mismatched PR URL is rejected"

echo "=== Poll CI provenance: database errors fail closed ==="
BROKEN_PROVENANCE_DB="$TEST_DIR/broken-provenance.db"
sqlite3 "$BROKEN_PROVENANCE_DB" "CREATE TABLE other(value TEXT);"
DB="$BROKEN_PROVENANCE_DB"
if is_manul_owned_pr "test/repo" "93" "https://github.com/test/repo/pull/93"; then
  echo "FAIL: provenance query error must not authorize CI auto-fix" >&2
  exit 1
fi
DB="$MANUL_DIR/manul.db"
echo "PASS: provenance query errors fail closed"

echo "=== Poll CI guard: no unresolved tasks returns false and emits nothing ==="
if has_unresolved_manul_tasks "test/repo" "99"; then
  echo "FAIL: no-row unresolved query unexpectedly returned true" >&2
  exit 1
fi
echo "=== Poll CI guard: unresolved task returns true without stdout ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,attempts,nextAttemptAt,repository,issueNumber) VALUES ('pending','queued',0,NULL,'test/repo',99);"
if ! has_unresolved_manul_tasks "test/repo" "99"; then
  echo "FAIL: queued task must block duplicate CI auto-fix" >&2
  exit 1
fi
unresolved_output="$(has_unresolved_manul_tasks "test/repo" "99")"
assert_eq "unresolved-query-no-stdout" "" "$unresolved_output"
sqlite3 "$DB" "UPDATE processed_comments SET status='completed' WHERE commentId='pending';"
if has_unresolved_manul_tasks "test/repo" "99"; then
  echo "FAIL: completed task must not block CI auto-fix" >&2
  exit 1
fi

echo "=== Poll CI guard: query error fails closed ==="
BROKEN_DB="$TEST_DIR/broken.db"
sqlite3 "$BROKEN_DB" "CREATE TABLE other(value TEXT);"
DB="$BROKEN_DB"
if ! has_unresolved_manul_tasks "test/repo" "99"; then
  echo "FAIL: DB error should conservatively block CI auto-fix" >&2
  exit 1
fi
DB="$MANUL_DIR/manul.db"

echo "All poll-result parsing tests passed."
