#!/usr/bin/env bash
# Verify every sqlite3 CLI connection opened after manul-paths.sh is sourced
# uses the configured connection-local busy timeout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/manul-sqlite-timeout-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export MANUL_SQLITE_BUSY_TIMEOUT_MS=5000
mkdir -p "$MANUL_DIR"

# Invalid overrides fail closed to the safe default rather than disabling waits.
(
  export MANUL_DIR="$TEST_DIR/invalid-config"
  export MANUL_SQLITE_BUSY_TIMEOUT_MS=not-a-number
  source "$SCRIPT_DIR/manul-paths.sh"
  [[ "$MANUL_SQLITE_BUSY_TIMEOUT_MS" == "5000" ]]
)

source "$SCRIPT_DIR/manul-paths.sh"
declare -F sqlite3 >/dev/null

DB="$TEST_DIR/contention.db"
sqlite3 "$DB" "CREATE TABLE counters(id INTEGER PRIMARY KEY, value INTEGER NOT NULL); INSERT INTO counters VALUES(1,0);"

LOCK_READY="$TEST_DIR/writer-ready"
# Hold a RESERVED write lock from a separate sqlite3 process/connection.
{
  printf 'BEGIN IMMEDIATE;\n'
  printf '.shell touch "%s"\n' "$LOCK_READY"
  sleep 1
  printf 'UPDATE counters SET value=value+1 WHERE id=1;\nCOMMIT;\n'
} | command sqlite3 "$DB" >/dev/null &
HOLDER_PID=$!

for _ in $(seq 1 100); do
  [ -f "$LOCK_READY" ] && break
  sleep 0.05
done
if [ ! -f "$LOCK_READY" ]; then
  echo "FAIL: writer did not acquire the SQLite lock" >&2
  wait "$HOLDER_PID" || true
  exit 1
fi

# This call uses the manul-paths.sh wrapper and must wait for the other writer.
UPDATE_RESULT="$(sqlite3 "$DB" "UPDATE counters SET value=value+1 WHERE id=1; SELECT value FROM counters WHERE id=1;")"
wait "$HOLDER_PID"

[[ "$UPDATE_RESULT" == "2" ]] || {
  echo "FAIL: second writer did not complete after waiting (result=$UPDATE_RESULT)" >&2
  exit 1
}
[[ "$(sqlite3 "$DB" "SELECT value FROM counters WHERE id=1;")" == "2" ]] || {
  echo "FAIL: concurrent updates were not both persisted" >&2
  exit 1
}

echo "PASS: shared sqlite3 wrapper waits for a concurrent writer and preserves both updates"
echo "PASS: invalid MANUL_SQLITE_BUSY_TIMEOUT_MS falls back to 5000ms"
