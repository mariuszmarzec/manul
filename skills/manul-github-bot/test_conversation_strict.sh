#!/bin/bash
# Strict conversation regression tests.
# These tests exercise poll.sh itself and assert the persisted task context
# and exact review-thread conversation mapping, not just message counts.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

cleanup() { [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"; }
run_test() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

new_db() {
  sqlite3 "$1" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$1" "INSERT INTO meta VALUES('baseline','2019-01-01T00:00:00Z');"
  sqlite3 "$1" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, author TEXT, agent TEXT, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT, processedAt TEXT);"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN action TEXT;"
  sqlite3 "$1" "CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);"
  sqlite3 "$1" "CREATE TABLE conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);"
  sqlite3 "$1" "CREATE TABLE conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);"
}

setup_manul() {
  TEST_DIR="$1"
  MANUL_DIR="$TEST_DIR/manul"
  MOCK_GH="$TEST_DIR/mock-gh"
  mkdir -p "$MANUL_DIR/state" "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs" "$MOCK_GH"
  cat > "$MANUL_DIR/config.json" <<'EOF'
{"automation":{"maxAttemptsBeforeFail":3,"leaseTimeout":900},"reviewers":["mock-reviewer"],"allowedUsers":["test-user","reviewer","author"],"triggers":{"issueCommentTrigger":"/manul","prReviewCommentTrigger":"/manul","issueBodyTrigger":"/manul","fallbackTrigger":"manul"},"signature":"— manul 🐈"}
EOF
  cp "$SCRIPT_DIR/manul-paths.sh" "$MANUL_DIR/manul-paths.sh"
   cp "$SCRIPT_DIR/manul-pr-review.sh" "$MANUL_DIR/manul-pr-review.sh"
  cp "$SCRIPT_DIR/manul-conversation.sh" "$MANUL_DIR/manul-conversation.sh"
  cp "$SCRIPT_DIR/manul-github-events.sh" "$MANUL_DIR/manul-github-events.sh"
  new_db "$MANUL_DIR/state/manul.db"
}

test_follow_up_context_is_persisted() {
  TEST_DIR="$(mktemp -d /tmp/manul-strict-issue-XXXXXX)"
  setup_manul "$TEST_DIR"

  cat > "$TEST_DIR/comments_1.json" <<'EOF'
[{"id":"c1","body":"/manul Add a test for multiply(2, 3) == 6","user":{"login":"test-user"},"created_at":"2026-09-16T00:00:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#c1","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"}]
EOF
  cat > "$TEST_DIR/comments_2.json" <<'EOF'
[{"id":"c1","body":"/manul Add a test for multiply(2, 3) == 6","user":{"login":"test-user"},"created_at":"2026-09-16T00:00:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#c1","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"},{"id":"c2","body":"Also make sure the assertion uses float comparison.","user":{"login":"test-user"},"created_at":"2026-09-16T00:05:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#c2","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"}]
EOF
  cat > "$TEST_DIR/comments_3.json" <<'EOF'
[{"id":"c1","body":"/manul Add a test for multiply(2, 3) == 6","user":{"login":"test-user"},"created_at":"2026-09-16T00:00:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#c1","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"},{"id":"c2","body":"Also make sure the assertion uses float comparison.","user":{"login":"test-user"},"created_at":"2026-09-16T00:05:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#c2","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"},{"id":"c3","body":"/manul Now implement the change according to my previous feedback.","user":{"login":"test-user"},"created_at":"2026-09-16T00:10:00Z","html_url":"https://github.com/test-org/test-repo/issues/1#c3","issue_url":"https://api.github.com/repos/test-org/test-repo/issues/1"}]
EOF

  cat > "$MOCK_GH/gh" <<'EOF'
#!/bin/bash
set -u
args="${@/--paginate/}"
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
  if [[ "$*" == *"--state open"* ]]; then echo '[]'; else echo '[]'; fi
  exit 0
fi
if [[ "${1:-}" == "api" ]]; then
  poll="$(cat "${TEST_DIR}/poll_number" 2>/dev/null || echo 1)"
  case "$poll" in
    1) file="$TEST_DIR/comments_1.json";;
    2) file="$TEST_DIR/comments_2.json";;
    *) file="$TEST_DIR/comments_3.json";;
  esac
  if [[ "$args" == *"/issues/comments?per_page=100"* ]]; then cat "$file"; exit 0; fi
  if [[ "$args" == *"/issues/1/comments"* ]]; then cat "$file"; exit 0; fi
  echo '[]'; exit 0
fi
echo '{}'
EOF
  chmod +x "$MOCK_GH/gh"

  for i in 1 2 3; do
    echo "$i" > "$TEST_DIR/poll_number"
    MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo >/dev/null 2>&1 || true
  done

  local tasks context conversation messages
  tasks="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT COUNT(*) FROM processed_comments WHERE repository='test-org/test-repo' AND issueNumber=1;")"
  conversation="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT DISTINCT conversationId FROM processed_comments WHERE repository='test-org/test-repo' AND issueNumber=1;")"
  messages="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT COUNT(*) FROM conversation_messages WHERE conversationId='conv-test-org/test-repo-issue-1';")"
  context="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT context FROM processed_comments WHERE commentId='issue:c3';")"

  [ "$tasks" -eq 2 ] || { echo "expected 2 tasks, got $tasks"; cleanup; return 1; }
  [ "$conversation" = "conv-test-org/test-repo-issue-1" ] || { echo "wrong conversation: $conversation"; cleanup; return 1; }
  [ "$messages" -eq 3 ] || { echo "expected 3 messages, got $messages"; cleanup; return 1; }
  grep -Fq 'Also make sure the assertion uses float comparison.' <<<"$context" || { echo 'follow-up context missing ordinary feedback'; cleanup; return 1; }

  cleanup
  unset TEST_DIR
}

test_review_thread_mapping_is_exact() {
  TEST_DIR="$(mktemp -d /tmp/manul-strict-review-XXXXXX)"
  setup_manul "$TEST_DIR"
  sqlite3 "$MANUL_DIR/state/manul.db" "DELETE FROM processed_comments; DELETE FROM conversations; DELETE FROM conversation_messages;"

  cat > "$TEST_DIR/reviews.json" <<'EOF'
[{"id":101,"user":{"login":"test-user"},"body":"/manul Fix auth","html_url":"https://github.com/test-org/test-repo/pull/50#r101","created_at":"2026-09-16T00:00:00Z","in_reply_to_id":null},{"id":102,"user":{"login":"test-user"},"body":"Can you handle timeout?","html_url":"https://github.com/test-org/test-repo/pull/50#r102","created_at":"2026-09-16T00:01:00Z","in_reply_to_id":101},{"id":103,"user":{"login":"test-user"},"body":"Done","html_url":"https://github.com/test-org/test-repo/pull/50#r103","created_at":"2026-09-16T00:02:00Z","in_reply_to_id":102},{"id":201,"user":{"login":"test-user"},"body":"/manul Fix docs","html_url":"https://github.com/test-org/test-repo/pull/50#r201","created_at":"2026-09-16T00:03:00Z","in_reply_to_id":null}]
EOF
  cat > "$MOCK_GH/gh" <<'EOF'
#!/bin/bash
set -u
args="${@/--paginate/}"
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  if [[ "$*" == *"--state merged"* ]]; then echo '[]'; exit 0
  elif [[ "$*" == *"--state closed"* ]]; then echo '[]'; exit 0
  elif [[ "$*" == *"--state open"* ]]; then echo '[{"number":50,"headRefName":"feature","baseRefName":"main","title":"Test","url":"https://github.com/test-org/test-repo/pull/50"}]'; exit 0
  elif [[ "$*" == *"--json number"* ]]; then printf '50\n'; exit 0
  else echo '[{"number":50,"headRefName":"feature","baseRefName":"main","title":"Test","url":"https://github.com/test-org/test-repo/pull/50"}]'; fi
  exit 0
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
if [[ "${1:-}" == "api" ]]; then
  if [[ "$args" == */pulls/*comments* ]]; then
    if [ -f "$TEST_DIR/reviews.json" ]; then cat "$TEST_DIR/reviews.json"; else echo '[]'; fi
    exit 0
  fi
  echo '[]'; exit 0
fi
echo '{}'
EOF
  chmod +x "$MOCK_GH/gh"
  MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" bash "$SCRIPT_DIR/poll.sh" test-org/test-repo >/dev/null 2>&1 || true

  local mapping count_root1 count_root2
  mapping="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT commentId || '=' || conversationId FROM conversation_messages WHERE repo='test-org/test-repo' AND issueNumber=50 ORDER BY CAST(commentId AS INTEGER);")"
  count_root1="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT COUNT(*) FROM conversation_messages WHERE conversationId='conv-test-org/test-repo-review-101';")"
  count_root2="$(sqlite3 "$MANUL_DIR/state/manul.db" "SELECT COUNT(*) FROM conversation_messages WHERE conversationId='conv-test-org/test-repo-review-201';")"

  grep -Fxq '101=conv-test-org/test-repo-review-101' <<<"$mapping" || { echo "$mapping"; cleanup; return 1; }
  grep -Fxq '102=conv-test-org/test-repo-review-101' <<<"$mapping" || { echo "$mapping"; cleanup; return 1; }
  grep -Fxq '103=conv-test-org/test-repo-review-101' <<<"$mapping" || { echo "$mapping"; cleanup; return 1; }
  grep -Fxq '201=conv-test-org/test-repo-review-201' <<<"$mapping" || { echo "$mapping"; cleanup; return 1; }
  [ "$count_root1" -eq 3 ] || { echo "root 101 count=$count_root1"; cleanup; return 1; }
  [ "$count_root2" -eq 1 ] || { echo "root 201 count=$count_root2"; cleanup; return 1; }

  cleanup
  unset TEST_DIR
}

run_test "follow-up task context contains ordinary feedback" test_follow_up_context_is_persisted
run_test "every review comment maps to its exact root thread" test_review_thread_mapping_is_exact

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
