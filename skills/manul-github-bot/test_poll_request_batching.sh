#!/usr/bin/env bash
# Hermetic regression tests for same-poll /manul comment batching.
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

# Load only production helper functions; do not invoke poll.sh or GitHub APIs.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
eval "$(sed -n '/^group_poll_request_comments() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
eval "$(sed -n '/^filter_new_poll_request_members() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
eval "$(sed -n '/^render_poll_request_batch() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"

cat >"$TEST_DIR/comments.json" <<'JSON'
[
  {"id":"issue:101","rawId":"101","issueNumber":42,"action":"IMPLEMENT","agent":"","autoAccept":false,"created":"2026-11-19T10:02:00Z","author":"alice","url":"https://github.com/acme/repo/issues/42#issuecomment-101","fullBody":"Second request","prompt":"Second request"},
  {"id":"issue:100","rawId":"100","issueNumber":42,"action":"IMPLEMENT","agent":"","autoAccept":false,"created":"2026-11-19T10:01:00Z","author":"bob","url":"https://github.com/acme/repo/issues/42#issuecomment-100","fullBody":"First request","prompt":"First request"},
  {"id":"issue:102","rawId":"102","issueNumber":42,"action":"VERIFY","agent":"","autoAccept":false,"created":"2026-11-19T10:03:00Z","author":"alice","url":"https://github.com/acme/repo/issues/42#issuecomment-102","fullBody":"Verify only","prompt":"Verify only"},
  {"id":"issue:103","rawId":"103","issueNumber":42,"action":"IMPLEMENT","agent":"coder","autoAccept":false,"created":"2026-11-19T10:04:00Z","author":"alice","url":"https://github.com/acme/repo/issues/42#issuecomment-103","fullBody":"Explicit coder","prompt":"Explicit coder"},
  {"id":"issue:104","rawId":"104","issueNumber":42,"action":"IMPLEMENT","agent":"","autoAccept":true,"created":"2026-11-19T10:05:00Z","author":"alice","url":"https://github.com/acme/repo/issues/42#issuecomment-104","fullBody":"Auto accepted","prompt":"Auto accepted"},
  {"id":"issue:105","rawId":"105","issueNumber":43,"action":"IMPLEMENT","agent":"","autoAccept":false,"created":"2026-11-19T10:06:00Z","author":"alice","url":"https://github.com/acme/repo/issues/43#issuecomment-105","fullBody":"Different issue","prompt":"Different issue"},
  {"id":"issue:106","rawId":"106","issueNumber":42,"action":"CONTINUE","agent":"","autoAccept":false,"created":"2026-11-19T10:07:00Z","author":"alice","url":"https://github.com/acme/repo/issues/42#issuecomment-106","fullBody":"Continue one","prompt":"Continue one"},
  {"id":"issue:107","rawId":"107","issueNumber":42,"action":"CONTINUE","agent":"","autoAccept":false,"created":"2026-11-19T10:08:00Z","author":"alice","url":"https://github.com/acme/repo/issues/42#issuecomment-107","fullBody":"Continue two","prompt":"Continue two"}
]
JSON

grouped="$(jq -c '.[]' "$TEST_DIR/comments.json" | group_poll_request_comments)"
groups_json="$(printf '%s\n' "$grouped" | jq -s '.')"
assert_eq "one group for compatible comments" "7" "$(jq 'length' <<<"$groups_json")"
assert_eq "actions, roles, auto policy, Issue/PR and continue commands stay isolated" "1,1,1,1,1,1,2" "$(jq -r 'map(length) | sort | join(",")' <<<"$groups_json")"

batch_members="$(jq -c '.[] | select(length == 2 and .[0].issueNumber == 42 and .[0].action == "IMPLEMENT" and .[0].agent == "")' <<<"$groups_json")"
batch="$(printf '%s\n' "$batch_members" | render_poll_request_batch)"
assert_eq "earliest unprocessed comment anchors the task" "issue:100" "$(jq -r '.id' <<<"$batch")"
assert_eq "batch retains each original comment identity" "100,101" "$(jq -r '[.batchMembers[].rawId] | join(",")' <<<"$batch")"
jq -e '.batchSize == 2 and (.prompt | contains("comment: #100") and contains("comment: #101") and contains("First request") and contains("Second request") and contains("most efficient safe plan"))' <<<"$batch" >/dev/null \
  && ok "agent receives all requests plus autonomous planning instructions" \
  || fail "combined prompt omitted a request or planning instructions"

single_group="$(jq -c '.[] | select(length == 1 and .[0].id == "issue:102")' <<<"$groups_json")"
single="$(printf '%s\n' "$single_group" | render_poll_request_batch)"
assert_eq "singleton retains the current prompt unchanged" "Verify only" "$(jq -r '.prompt' <<<"$single")"
assert_eq "singleton metadata remains one comment" "1" "$(jq -r '.batchSize' <<<"$single")"

empty_body_group='[{"id":"issue:108","prompt":"Fallback prompt","fullBody":""}]'
empty_body="$(printf '%s\n' "$empty_body_group" | render_poll_request_batch)"
assert_eq "singleton falls back to parsed prompt when fullBody is empty" "Fallback prompt" "$(jq -r '.prompt' <<<"$empty_body")"

DB="$TEST_DIR/manul.db"
LOG="$TEST_DIR/test.log"
sqlite3 "$DB" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY); CREATE TABLE conversation_messages(commentId TEXT, messageType TEXT); INSERT INTO processed_comments(commentId) VALUES('issue:100'); INSERT INTO conversation_messages(commentId,messageType) VALUES('101','task-trigger');"
candidate='[{"id":"issue:100","rawId":"100","fullBody":"Already queued"},{"id":"issue:101","rawId":"101","fullBody":"Already persisted"},{"id":"issue:102","rawId":"102","fullBody":"New request"},{"id":"issue:103","rawId":"103","fullBody":"New sibling"}]'
remaining="$(filter_new_poll_request_members "$candidate")"
assert_eq "previously queued and persisted comments are removed individually" "issue:102,issue:103" "$(jq -r '[.[].id] | join(",")' <<<"$remaining")"
filtered_batch="$(printf '%s\n' "$remaining" | render_poll_request_batch)"
assert_eq "remaining comments are re-anchored to the earliest new comment" "issue:102" "$(jq -r '.id' <<<"$filtered_batch")"
assert_eq "only unprocessed source comments remain in the batch" "2" "$(jq -r '.batchSize' <<<"$filtered_batch")"

echo "All poll-cycle request batching tests passed."
