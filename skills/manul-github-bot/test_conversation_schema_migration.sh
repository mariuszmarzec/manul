#!/usr/bin/env bash
# test_conversation_schema_migration.sh — Regression tests for the
# conversations.activePrUrl schema migration (manul-daemon.sh).
#
# Background: the conversations table schema is not uniform across Manul entry
# points. manul-conversation.sh creates it WITHOUT activePrUrl, while poll.sh
# and manul-conversation-linker.sh create it WITH the column. The daemon's
# close_drained_conversations() writes activePrUrl=NULL, so databases seeded
# by conversation.sh must be migrated before those writes run (see
# ensure_conversations_activeprurl_column in manul-daemon.sh).
#
# This test exercises the real production function (extracted from
# manul-daemon.sh) against a temporary SQLite database only.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG="$TMP/migration.log"
: >"$LOG"

log() { echo "[$(date -Is)] $*" >>"$LOG"; }

# Extract the actual production migration function from manul-daemon.sh.
migrator_source="$(sed -n '/^ensure_conversations_activeprurl_column() {/,/^}/p' "$SCRIPT_DIR/manul-daemon.sh")"
if [ -z "$migrator_source" ]; then
  echo "FAIL: ensure_conversations_activeprurl_column() not found in manul-daemon.sh" >&2
  exit 1
fi
eval "$migrator_source"
if ! type ensure_conversations_activeprurl_column >/dev/null 2>&1; then
  echo "FAIL: extracted migration function is not defined" >&2
  exit 1
fi

TOTAL=0
PASSED=0
FAILED=0
run_test() {
  local name="$1"
  local func="$2"
  TOTAL=$((TOTAL + 1))
  if "$func"; then
    PASSED=$((PASSED + 1))
    echo "PASS: $name"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL: $name"
  fi
}

column_count() {
  local db="$1"
  sqlite3 "$db" "PRAGMA table_info(conversations);" | grep -c '|activePrUrl|' || true
}

record_columns() {
  local db="$1"
  sqlite3 "$db" "SELECT repository, issueNumber, issueUrl, status, activeTaskId, activePrNumber, createdAt, updatedAt FROM conversations WHERE conversationId='conv-a';"
}

# Test 1: conversation.sh schema (no activePrUrl) is migrated, the pre-existing
# record keeps every value, and the new column is NULL for it.
test_migrates_missing_column() {
  local db="$TMP/db-missing.sqlite"
  DB="$db"
  # Exact schema created by manul-conversation.sh (without activePrUrl).
  sqlite3 "$db" "
    CREATE TABLE conversations (
      conversationId TEXT PRIMARY KEY,
      repository TEXT NOT NULL,
      issueNumber INTEGER NOT NULL,
      issueUrl TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'OPEN',
      activeTaskId TEXT,
      activePrNumber TEXT,
      createdAt TEXT NOT NULL,
      updatedAt TEXT NOT NULL
    );
    INSERT INTO conversations (conversationId, repository, issueNumber, issueUrl, status, activeTaskId, activePrNumber, createdAt, updatedAt)
    VALUES ('conv-a', 'test-org/test-repo', 7, 'https://github.com/test-org/test-repo/issues/7', 'OPEN', 'task-a', '42', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z');
  " || return 1
  if sqlite3 "$db" "PRAGMA table_info(conversations);" | grep -q '|activePrUrl|'; then
    echo "fixture wrongly created with activePrUrl" >&2
    return 1
  fi

  ensure_conversations_activeprurl_column
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "migration returned $rc" >&2
    return 1
  fi
  if ! sqlite3 "$db" "PRAGMA table_info(conversations);" | grep -q '|activePrUrl|'; then
    echo "activePrUrl column was not added" >&2
    return 1
  fi
  local expected got
  expected="test-org/test-repo|7|https://github.com/test-org/test-repo/issues/7|OPEN|task-a|42|2026-01-01T00:00:00Z|2026-01-02T00:00:00Z"
  got="$(record_columns "$db")"
  if [ "$got" != "$expected" ]; then
    echo "existing record was altered: $got" >&2
    return 1
  fi
  local null_check
  null_check="$(sqlite3 "$db" "SELECT activePrUrl IS NULL FROM conversations WHERE conversationId='conv-a';")"
  if [ "$null_check" != "1" ]; then
    echo "activePrUrl should be NULL for the pre-existing record, got: $null_check" >&2
    return 1
  fi
  return 0
}

# Test 2: re-running the migration on an already-migrated database is a
# no-op: no error, exactly one activePrUrl column, record still intact.
test_repeated_migration_is_idempotent() {
  local db="$TMP/db-missing.sqlite"
  DB="$db"
  ensure_conversations_activeprurl_column
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "re-run returned $rc" >&2
    return 1
  fi
  local count
  count="$(column_count "$db")"
  if [ "$count" != "1" ]; then
    echo "expected exactly 1 activePrUrl column after re-run, got $count" >&2
    return 1
  fi
  local expected got
  expected="test-org/test-repo|7|https://github.com/test-org/test-repo/issues/7|OPEN|task-a|42|2026-01-01T00:00:00Z|2026-01-02T00:00:00Z"
  got="$(record_columns "$db")"
  if [ "$got" != "$expected" ]; then
    echo "existing record was altered by re-run: $got" >&2
    return 1
  fi
  local null_check
  null_check="$(sqlite3 "$db" "SELECT activePrUrl IS NULL FROM conversations WHERE conversationId='conv-a';")"
  if [ "$null_check" != "1" ]; then
    echo "activePrUrl changed after re-run: $null_check" >&2
    return 1
  fi
  return 0
}

# Test 3: a database whose schema already includes activePrUrl (poll.sh /
# manul-conversation-linker.sh layout) passes the migration without error and
# keeps existing values, including a non-NULL activePrUrl.
test_migration_with_existing_column() {
  local db="$TMP/db-existing.sqlite"
  DB="$db"
  sqlite3 "$db" "
    CREATE TABLE conversations(
      conversationId TEXT PRIMARY KEY,
      repository TEXT NOT NULL,
      issueNumber INTEGER,
      issueUrl TEXT,
      activePrNumber INTEGER,
      activePrUrl TEXT,
      activeTaskId TEXT,
      status TEXT NOT NULL DEFAULT 'OPEN',
      createdAt TEXT NOT NULL,
      updatedAt TEXT NOT NULL
    );
    INSERT INTO conversations (conversationId, repository, issueNumber, issueUrl, activePrNumber, activePrUrl, activeTaskId, status, createdAt, updatedAt)
    VALUES ('conv-b', 'test-org/test-repo', 8, 'https://github.com/test-org/test-repo/issues/8', '9', 'https://github.com/test-org/test-repo/pull/9', 'task-b', 'OPEN', '2026-02-01T00:00:00Z', '2026-02-02T00:00:00Z');
  " || return 1

  ensure_conversations_activeprurl_column
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "migration returned $rc on a database that already has activePrUrl" >&2
    return 1
  fi
  local count
  count="$(column_count "$db")"
  if [ "$count" != "1" ]; then
    echo "expected exactly 1 activePrUrl column, got $count" >&2
    return 1
  fi
  local got
  got="$(sqlite3 "$db" "SELECT repository, activePrUrl, status FROM conversations WHERE conversationId='conv-b';")"
  if [ "$got" != "test-org/test-repo|https://github.com/test-org/test-repo/pull/9|OPEN" ]; then
    echo "existing record was altered: $got" >&2
    return 1
  fi
  if grep -q "ERROR: failed to add activePrUrl column" "$LOG"; then
    echo "migration logged an error on an already-migrated database" >&2
    return 1
  fi
  return 0
}

run_test "conversation.sh schema is migrated with the existing record intact" test_migrates_missing_column
run_test "repeated migration is idempotent (no error, no duplicate column)" test_repeated_migration_is_idempotent
run_test "database with existing activePrUrl column passes migration" test_migration_with_existing_column

echo "conversation schema migration: $PASSED passed, $FAILED failed, $TOTAL total"
if [ "$FAILED" -gt 0 ]; then
  cat "$LOG" >&2
  exit 1
fi
exit 0
