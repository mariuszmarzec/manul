#!/usr/bin/env bash
# test_feedback_routing.sh — regression tests for lifecycle feedback routing.
#
# Verifies that review tasks post lifecycle feedback inside the originating
# review thread, while ordinary issue/PR conversation tasks remain top-level.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPROOT="$(mktemp -d /tmp/manul-feedback-routing-XXXXXX)"
MANUL_DIR="$TMPROOT/manul"
FAKE_BIN="$TMPROOT/bin"
DB="$MANUL_DIR/state/manul.db"
GH_LOG="$TMPROOT/gh.log"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label (expected '$needle')"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label (unexpected '$needle')"
  fi
}

assert_matches() {
  local label="$1" haystack="$2" pattern="$3"
  if printf '%s\n' "$haystack" | grep -Eq "$pattern"; then
    ok "$label"
  else
    fail "$label (expected pattern '$pattern')"
  fi
}

mkdir -p "$MANUL_DIR/state" "$MANUL_DIR/logs" "$FAKE_BIN"

cat > "$MANUL_DIR/config.json" <<'EOF'
{
  "automation": {
    "maxAttemptsBeforeFail": 3
  }
}
EOF

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  prompt TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  conversationId TEXT
);

INSERT INTO processed_comments
  (commentId, repository, issueNumber, commentUrl, prompt, status, attempts, conversationId)
VALUES
  ('review:4103894743', 'mariuszmarzec/shoppingListGenerator', 43,
   'https://github.com/mariuszmarzec/shoppingListGenerator/pull/43#discussion_r4103894743',
   'add !', 'running', 1, 'conv-review-4103894743');

INSERT INTO processed_comments
  (commentId, repository, issueNumber, commentUrl, prompt, status, attempts, conversationId)
VALUES
  ('issue:5831560162', 'mariuszmarzec/shoppingListGenerator', 43,
   'https://github.com/mariuszmarzec/shoppingListGenerator/pull/43#issuecomment-5831560162',
   'top level', 'running', 1, 'conv-pr-43');
SQL

cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -u
for arg in "$@"; do printf 'ARG:%q\n' "$arg"; done >> "$GH_LOG"
if [[ "${1:-}" == "api" ]]; then
  has_input=false
  for arg in "$@"; do
    if [ "$arg" = "--input" ]; then has_input=true; fi
  done
  if [ "$has_input" = true ]; then
    printf 'BODY:%s\n' "$(cat)" >> "$GH_LOG"
  fi
fi
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

export MANUL_DIR PATH="$FAKE_BIN:$PATH" GH_LOG DB

echo "=== Feedback routing regression tests ==="

review_out="$(bash "$SCRIPT_DIR/manul-result-feedback.sh" post-started   --repo mariuszmarzec/shoppingListGenerator   --issue 43   --comment-id review:4103894743   --task-id review:4103894743   --pr-number 43   --json 2>&1)"
review_cmd="$(cat "$GH_LOG" 2>/dev/null || true)"

assert_contains "Review lifecycle invokes gh api" "$review_cmd" "ARG:api"
assert_contains "Review lifecycle targets the PR review-comments endpoint" "$review_cmd" "ARG:repos/mariuszmarzec/shoppingListGenerator/pulls/43/comments"
assert_contains "Review lifecycle payload contains in_reply_to field" "$review_cmd" '"in_reply_to"'
assert_contains "Review lifecycle payload contains source review id" "$review_cmd" '4103894743'

# Safe request-body regression: review lifecycle must send JSON through --input,
# not -F/--field body, so shell-sensitive Markdown is never reinterpreted.
assert_contains "Review lifecycle uses JSON input" "$review_cmd" "ARG:--input"
assert_not_contains "Review lifecycle does not use -F body" "$review_cmd" "ARG:body="
assert_not_contains "Review lifecycle does not use top-level issue comment API" "$review_cmd" "issue comment 43"

: > "$GH_LOG"

top_out="$(bash "$SCRIPT_DIR/manul-result-feedback.sh" post-started   --repo mariuszmarzec/shoppingListGenerator   --issue 43   --comment-id issue:5831560162   --task-id issue:5831560162   --pr-number 43   --json 2>&1)"
top_cmd="$(cat "$GH_LOG" 2>/dev/null || true)"

assert_contains "Top-level lifecycle invokes gh issue comment" "$top_cmd" "ARG:issue"
assert_contains "Top-level lifecycle targets PR #43 conversation" "$top_cmd" "ARG:43"
assert_not_contains "Top-level lifecycle does not use review reply endpoint" "$top_cmd" "pulls/43/comments"
assert_not_contains "Top-level lifecycle has no in_reply_to routing" "$top_cmd" "in_reply_to="

# Terminal failures must use the same correct routing and expose the actual
# failure reason; Markdown newlines must be real newlines before JSON encoding.
: > "$GH_LOG"
review_failed_out="$(bash "$SCRIPT_DIR/manul-result-feedback.sh" post-failed \
  --repo mariuszmarzec/shoppingListGenerator \
  --issue 43 \
  --comment-id review:4103894743 \
  --task-id review:4103894743 \
  --pr-number 43 \
  --error "workspace path missing" \
  --json 2>&1)"
review_failed_cmd="$(cat "$GH_LOG" 2>/dev/null || true)"
assert_contains "Terminal review failure uses the review-thread endpoint" "$review_failed_cmd" "ARG:repos/mariuszmarzec/shoppingListGenerator/pulls/43/comments"
assert_contains "Terminal review failure retains TASK_FAILED marker" "$review_failed_cmd" "TASK_FAILED"
assert_contains "Terminal review failure includes its concrete reason" "$review_failed_cmd" "workspace path missing"
assert_contains "Terminal review failure formats the error block with Markdown newlines" "$review_failed_cmd" '**Error:**\n```text\nworkspace path missing\n```'
assert_matches "Terminal review failure JSON routes to original review comment" "$review_failed_cmd" '"in_reply_to"[[:space:]]*:[[:space:]]*4103894743'

: > "$GH_LOG"
top_failed_out="$(bash "$SCRIPT_DIR/manul-result-feedback.sh" post-failed \
  --repo mariuszmarzec/shoppingListGenerator \
  --issue 43 \
  --comment-id issue:5831560162 \
  --task-id issue:5831560162 \
  --pr-number 43 \
  --error "checkout failed" \
  --json 2>&1)"
top_failed_cmd="$(cat "$GH_LOG" 2>/dev/null || true)"
assert_contains "Terminal issue failure invokes gh issue comment" "$top_failed_cmd" "ARG:issue"
assert_contains "Terminal issue failure uses the comment subcommand" "$top_failed_cmd" "ARG:comment"
assert_contains "Terminal issue failure targets issue #43" "$top_failed_cmd" "ARG:43"
assert_not_contains "Terminal issue failure does not use review-thread endpoint" "$top_failed_cmd" "pulls/43/comments"
assert_contains "Terminal issue failure includes its concrete reason" "$top_failed_cmd" "checkout failed"

if [ "$FAIL" -eq 0 ]; then
  echo "All $PASS tests passed."
else
  echo "$PASS passed, $FAIL failed."
fi

exit "$FAIL"
