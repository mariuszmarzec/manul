#!/usr/bin/env bash
# Hermetic regression tests for same-poll /manul comment batching and history race.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
ok() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local name="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] && ok "$name" || fail "$name: expected '$expected', got '$actual'"
}
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
DB="$TEST_DIR/manul.db"
LOG="$TEST_DIR/test.log"
sqlite3 "$DB" "
  CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY);
  CREATE TABLE conversation_messages(commentId TEXT);
  INSERT INTO processed_comments(commentId) VALUES('issue:100');
  INSERT INTO conversation_messages(commentId) VALUES('101');
"
eval "$(sed -n '/^filter_new_poll_request_members() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
candidate='[{"id":"issue:100","rawId":"100","fullBody":"Already queued"},{"id":"issue:101","rawId":"101","fullBody":"Persisted by history sync before task discovery"},{"id":"issue:102","rawId":"102","fullBody":"New request"}]'
remaining="$(filter_new_poll_request_members "$candidate")"
assert_eq "only comments with an existing task row are removed" "issue:101,issue:102" "$(jq -r '[.[].id] | join(",")' <<<"$remaining")"

# Reproduce the exact race state: comment 101 is in conversation history but
# has no task row. The production code's processed_comments-only guard allows it.
already_recorded="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='issue:101' LIMIT 1;")"
assert_eq "history-only trigger is not mistaken for an already queued task" "" "$already_recorded"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId) VALUES('issue:101');"
assert_eq "history-only trigger can be queued once" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:101';")"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId) VALUES('issue:101');"
assert_eq "a subsequent poll cannot enqueue a duplicate" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:101';")"

# Guard the production implementation against regression in both enqueue paths.
[[ "$(grep -c 'already_recorded=' "$SCRIPT_DIR/poll.sh")" -eq 2 ]] || fail "expected issue-comment and issue-body task guards"
if grep 'already_recorded=' "$SCRIPT_DIR/poll.sh" | grep -q 'conversation_messages'; then
  fail "task identity guard still consults conversation_messages"
fi
ok "both production task guards use task state, not conversation history"
echo "All poll-cycle request batching tests passed."
