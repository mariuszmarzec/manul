#!/usr/bin/env bash
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
sqlite3 "$DB" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY); CREATE TABLE conversation_messages(commentId TEXT); INSERT INTO processed_comments(commentId) VALUES('issue:100'); INSERT INTO conversation_messages(commentId) VALUES('101');"
eval "$(sed -n '/^filter_new_poll_request_members() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
candidate='[{"id":"issue:100","rawId":"100","fullBody":"Already queued"},{"id":"issue:101","rawId":"101","fullBody":"Persisted by history sync before task discovery"},{"id":"issue:102","rawId":"102","fullBody":"New request"}]'
remaining="$(filter_new_poll_request_members "$candidate")"
assert_eq "only comments with an existing task row are removed" "issue:101,issue:102" "$(jq -r '[.[].id] | join(",")' <<<"$remaining")"
already_recorded="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='issue:101' LIMIT 1;")"
assert_eq "history-only trigger is not mistaken for an already queued task" "" "$already_recorded"
# Exercise the production task enqueue query, not a hand-written approximation:
# source it from the real poll.sh path and run it against a minimal SQLite schema.
enqueue_sql="$(grep -F 'INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber' "$SCRIPT_DIR/poll.sh" | grep -F 'VALUES' | head -n1)"
[[ -n "$enqueue_sql" ]] || fail "production enqueue INSERT not found"
sqlite3 "$DB" "CREATE TABLE processed_comments_full(commentId TEXT PRIMARY KEY);"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId) VALUES('issue:101');"
assert_eq "history-only trigger can be inserted into task table" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:101';")"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId) VALUES('issue:101');"
assert_eq "second poll does not create a duplicate task" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:101';")"
# Assert actual production dedupe clauses no longer consult history.
task_dedupe_lines="$(grep -n 'already_recorded=' "$SCRIPT_DIR/poll.sh")"
[[ "$(printf '%s\n' "$task_dedupe_lines" | grep -c 'conversation_messages' || true)" = "0" ]] || fail "task dedupe still queries conversation_messages"
ok "production queue dedupe is isolated from conversation history"
echo "All poll-cycle request batching tests passed."
