#!/usr/bin/env bash
# Hermetic regression tests for proactive PR monitoring.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$TEST_DIR/manul.db"
CONFIG="$TEST_DIR/config.json"
LOG="$TEST_DIR/poll.log"
MOCK_BIN="$TEST_DIR/bin"
MOCK_HANDLER_LOG="$TEST_DIR/handler.log"
export MANUL_DIR DB CONFIG LOG MOCK_HANDLER_LOG
SIG="— manul 🐈"
mkdir -p "$MANUL_DIR" "$MOCK_BIN"

log() { :; }
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
generate_conversation_id() { printf 'conv-%s-issue-%s' "$1" "$2"; }
MANUL_OWNED_TEST=false
is_manul_owned_pr() { [ "$MANUL_OWNED_TEST" = "true" ]; }
get_review_thread_root_id() {
  local comments="$1" comment_id="$2" parent=""
  parent="$(jq -r --arg id "$comment_id" '.[] | select((.id | tostring) == $id) | (.in_reply_to_id // empty)' <<<"$comments" | head -n1)"
  if [ -n "$parent" ] && [ "$parent" != "null" ]; then printf '%s' "$parent"; else printf '%s' "$comment_id"; fi
}

cat >"$CONFIG" <<'JSON'
{
  "proactivity": {
    "fixAndAnswerComments": {
      "enabled": true,
      "prScope": "AllUserAuthoredPr"
    },
    "prAuthorAllowed": []
  }
}
JSON

sqlite3 "$DB" "
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
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
CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY);
CREATE TABLE conversation_messages(commentId TEXT);
"

cat >"$MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  cat "$MOCK_PRS"
  exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "--paginate" ]; then
  case "${3:-}" in
    repos/test/repo/issues/comments?*) cat "$MOCK_ISSUE_COMMENTS" ;;
    repos/test/repo/pulls/comments?*) cat "$MOCK_INLINE_COMMENTS" ;;
    *) echo "unexpected gh api path: ${3:-}" >&2; exit 2 ;;
  esac
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
GH
export MOCK_PRS="$TEST_DIR/prs.json" MOCK_ISSUE_COMMENTS="$TEST_DIR/issue-comments.json" MOCK_INLINE_COMMENTS="$TEST_DIR/inline-comments.json"

chmod +x "$MOCK_BIN/gh"
export PATH="$MOCK_BIN:$PATH"

cat >"$MANUL_DIR/manul-pr-review.sh" <<'HANDLER'
#!/usr/bin/env bash
set -euo pipefail
review_id=""
pr_number=""
body=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --review-id) review_id="$2"; shift 2 ;;
    --pr-number) pr_number="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$review_id" ] && [ -n "$pr_number" ]
printf '%s\n' "$review_id" >>"$MOCK_HANDLER_LOG"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId) VALUES('review:$review_id');"
HANDLER
chmod +x "$MANUL_DIR/manul-pr-review.sh"

# Test the allow-list fallback, explicit override, and placeholder fallback.
ALLOWED_JSON='["allowed-user"]'
actual="$(pr_watcher_author_allowlist_json)"
[ "$actual" = '["allowed-user"]' ] || { echo "FAIL allowUsers fallback: $actual" >&2; exit 1; }
cat >"$CONFIG" <<'JSON'
{"proactivity":{"prAuthorAllowed":["explicit-user"]}}
JSON
actual="$(pr_watcher_author_allowlist_json)"
[ "$actual" = '["explicit-user"]' ] || { echo "FAIL explicit allow-list: $actual" >&2; exit 1; }
cat >"$CONFIG" <<'JSON'
{"proactivity":{"prAuthorAllowed":["<GITHUB_LOGIN>"]}}
JSON
actual="$(pr_watcher_author_allowlist_json)"
[ "$actual" = '["allowed-user"]' ] || { echo "FAIL placeholder fallback: $actual" >&2; exit 1; }

# Scope checks: OnlyManulPr requires verified Manul provenance; all-user mode
# requires the PR author (not merely the commenter) to be allow-listed.
MANUL_OWNED_TEST=false
if pr_watcher_pr_in_scope "test/repo" "42" "https://github.com/test/repo/pull/42" "allowed-user" "OnlyManulPr"; then
  echo "FAIL arbitrary PR passed OnlyManulPr" >&2; exit 1
fi
MANUL_OWNED_TEST=true
pr_watcher_pr_in_scope "test/repo" "42" "https://github.com/test/repo/pull/42" "allowed-user" "OnlyManulPr"
pr_watcher_pr_in_scope "test/repo" "42" "https://github.com/test/repo/pull/42" "allowed-user" "AllUserAuthoredPr"
if pr_watcher_pr_in_scope "test/repo" "42" "https://github.com/test/repo/pull/42" "other-user" "AllUserAuthoredPr"; then
  echo "FAIL unapproved PR author passed AllUserAuthoredPr" >&2; exit 1
fi

# A configured empty allow-list inherits allowedUsers.
cat >"$CONFIG" <<'JSON'
{
  "proactivity": {
    "prAuthorAllowed": [],
    "fixAndAnswerComments": {"enabled": true, "prScope": "AllUserAuthoredPr"}
  }
}
JSON
cat >"$MOCK_PRS" <<'JSON'
[
  {
    "number": 42,
    "author": {"login": "allowed-user"},
    "url": "https://github.com/test/repo/pull/42",
    "title": "Example PR"
  }
]
JSON
cat >"$MOCK_ISSUE_COMMENTS" <<'JSON'
[
  {
    "id": 401,
    "html_url": "https://github.com/test/repo/pull/42#issuecomment-401",
    "body": "Please handle this regression",
    "created_at": "2999-01-01T00:00:00Z",
    "user": {"login": "reviewer", "type": "User"}
  },
  {
    "id": 402,
    "html_url": "https://github.com/test/repo/pull/42#issuecomment-402",
    "body": "Bot noise",
    "created_at": "2999-01-01T00:00:00Z",
    "user": {"login": "some-bot", "type": "Bot"}
  },
  {
    "id": 403,
    "html_url": "https://github.com/test/repo/pull/42#issuecomment-403",
    "body": "Result — manul 🐈",
    "created_at": "2999-01-01T00:00:00Z",
    "user": {"login": "manul", "type": "User"}
  }
]
JSON
cat >"$MOCK_INLINE_COMMENTS" <<'JSON'
[
  {
    "id": 501,
    "html_url": "https://github.com/test/repo/pull/42#discussion_r501",
    "body": "The new path can return null",
    "created_at": "2999-01-01T00:00:00Z",
    "pull_request_review_id": null,
    "in_reply_to_id": null,
    "user": {"login": "reviewer", "type": "User"}
  },
  {
    "id": 502,
    "html_url": "https://github.com/test/repo/pull/42#discussion_r502",
    "body": "I can reproduce this on Android too",
    "created_at": "2999-01-01T00:01:00Z",
    "pull_request_review_id": 88,
    "in_reply_to_id": 501,
    "user": {"login": "reviewer", "type": "User"}
  },
  {
    "id": 503,
    "html_url": "https://github.com/test/repo/pull/42#discussion_r503",
    "body": "This root comment belongs to a submitted review",
    "created_at": "2999-01-01T00:02:00Z",
    "pull_request_review_id": 88,
    "in_reply_to_id": null,
    "user": {"login": "reviewer", "type": "User"}
  },
  {
    "id": 504,
    "html_url": "https://github.com/test/repo/pull/42#discussion_r504",
    "body": "Bot inline noise",
    "created_at": "2999-01-01T00:00:00Z",
    "pull_request_review_id": null,
    "in_reply_to_id": null,
    "user": {"login": "some-bot", "type": "Bot"}
  },
  {
    "id": 505,
    "html_url": "https://github.com/test/repo/pull/42#discussion_r505",
    "body": "Already replied — manul 🐈",
    "created_at": "2999-01-01T00:00:00Z",
    "pull_request_review_id": null,
    "in_reply_to_id": null,
    "user": {"login": "manul", "type": "User"}
  }
]
JSON

source "$SCRIPT_DIR/manul-pr-watcher.sh"
scan_proactive_pr_comments "test/repo"
expected="$(printf '%s\n' proactive-comment-401 proactive-inline-501 proactive-inline-502)"
actual="$(cat "$MOCK_HANDLER_LOG")"
[ "$actual" = "$expected" ] || {
  echo "FAIL proactive events: expected [$expected], got [$actual]" >&2
  exit 1
}
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations WHERE activePrNumber=42;")" = "1" ] || {
  echo "FAIL PR conversation was not created without a source task" >&2; exit 1;
}
[ "$(sqlite3 "$DB" "SELECT value FROM meta WHERE key='pr_watcher_baseline';")" != "" ] || {
  echo "FAIL proactive baseline was not persisted" >&2; exit 1;
}

# A second poll must not submit any of the same events again.
scan_proactive_pr_comments "test/repo"
actual="$(cat "$MOCK_HANDLER_LOG")"
[ "$actual" = "$expected" ] || {
  echo "FAIL duplicate proactive events after second poll: [$actual]" >&2
  exit 1
}

echo "All proactive PR watcher tests passed."
