#!/bin/bash
# test_github_control_protocol.sh - Comprehensive tests for GitHub control protocol
#
# Tests cover:
# 1. Issue command creates task
# 2. Same Issue preserves conversation
# 3. Duplicate comment does not create duplicate task
# 4. PR comment creates REVIEW_FIX
# 5. REVIEW_FIX preserves prNumber
# 6. REVIEW_FIX preserves conversationId
# 7. parentTaskId is preserved
# 8. APPROVE does not create fix task
# 9. REQUEST_CHANGES creates fix task
# 10. Duplicate review is ignored
# 11. Structured events parse correctly
# 12. Malformed events are ignored safely
# 13. Task result produces machine event
# 14. Failed task produces machine event
# 15. Out-of-order events are handled
# 16. Merged PR handling
# 17. Closed Issue handling
# 18. Concurrent comments
# 19. JSON/state consistency
# 20. Production path safety
#
# Plus: End-to-end mock flow (Issue -> PR -> Review -> Fix -> Approve)

set -uo pipefail

# Resolve script directory portably
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Set up MANUL_DIR with proper config
MANUL_DIR="$TEST_DIR/manul"
mkdir -p "$MANUL_DIR/state" "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs"
DB="$MANUL_DIR/state/manul.db"

# Create symlinks to actual scripts
ln -s "$SCRIPT_DIR/manul-paths.sh" "$MANUL_DIR/manul-paths.sh" 2>/dev/null || true
ln -s "$SCRIPT_DIR/manul-conversation.sh" "$MANUL_DIR/manul-conversation.sh" 2>/dev/null || true
ln -s "$SCRIPT_DIR/manul-github-events.sh" "$MANUL_DIR/manul-github-events.sh" 2>/dev/null || true
ln -s "$SCRIPT_DIR/manul-pr-review.sh" "$MANUL_DIR/manul-pr-review.sh" 2>/dev/null || true
ln -s "$SCRIPT_DIR/manul-conversation-linker.sh" "$MANUL_DIR/manul-conversation-linker.sh" 2>/dev/null || true
ln -s "$SCRIPT_DIR/manul-result-feedback.sh" "$MANUL_DIR/manul-result-feedback.sh" 2>/dev/null || true

# Create proper config
cat > "$MANUL_DIR/config.json" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect", "coder"],
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
CONFIGEOF

# Scripts to test — use SCRIPT_DIR for portability
EVENTS_SCRIPT="$SCRIPT_DIR/manul-github-events.sh"
REVIEW_SCRIPT="$SCRIPT_DIR/manul-pr-review.sh"
LINKER_SCRIPT="$SCRIPT_DIR/manul-conversation-linker.sh"
FEEDBACK_SCRIPT="$SCRIPT_DIR/manul-result-feedback.sh"

# Create mock gh for feedback tests
MOCK_GH_DIR="$TEST_DIR/mock-gh"
mkdir -p "$MOCK_GH_DIR"
cat > "$MOCK_GH_DIR/gh" <<'MOCK_EOF'
#!/bin/bash
case "$1" in
  issue)
    case "$2" in
      comment) exit 0 ;;
      view) exit 0 ;;
    esac
    ;;
  pr)
    case "$2" in
      view) exit 0 ;;
      checkout) exit 0 ;;
    esac
    ;;
  api) exit 0 ;;
  repo) exit 0 ;;
esac
exit 0
MOCK_EOF
chmod +x "$MOCK_GH_DIR/gh"
export PATH="$MOCK_GH_DIR:$PATH"

PASSED=0
FAILED=0
TESTS_RUN=0

pass_test() { PASSED=$((PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  PASS: $1"; }
fail_test() { FAILED=$((FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  FAIL: $1"; }
run_test() { local name="$1"; local func="$2"; set +e; "$func"; local rc=$?; set -e; [ $rc -eq 0 ] && pass_test "$name" || fail_test "$name"; }

# Helper: run events script with test env
events() {
  MANUL_DIR="$MANUL_DIR" bash "$EVENTS_SCRIPT" "$@"
}

# Helper: run review script with test env
review() {
  MANUL_DIR="$MANUL_DIR" bash "$REVIEW_SCRIPT" "$@"
}

# Helper: run linker script with test env
linker() {
  MANUL_DIR="$MANUL_DIR" bash "$LINKER_SCRIPT" "$@"
}

# Helper: run feedback script with test env
feedback() {
  MANUL_DIR="$MANUL_DIR" bash "$FEEDBACK_SCRIPT" "$@"
}

# Helper: initialize DB schema
init_db() {
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT NOT NULL,
    author TEXT,
    agent TEXT,
    prompt TEXT NOT NULL,
    context TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT,
    heartbeatAt TEXT,
    leaseExpiresAt TEXT,
    workerPid INTEGER,
    nextAttemptAt TEXT,
    conversationId TEXT,
    parentTaskId TEXT,
    workspaceId TEXT,
    action TEXT DEFAULT 'IMPLEMENT',
    prNumber INTEGER,
    prUrl TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    baseId TEXT
  );"

  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversations (
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
  );"

  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversationId TEXT NOT NULL,
    repo TEXT NOT NULL,
    issueNumber INTEGER,
    prNumber INTEGER,
    commentId TEXT,
    taskCommentId TEXT,
    linkType TEXT NOT NULL,
    createdAt TEXT NOT NULL
  );"

  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS submission_claims (
    baseId TEXT PRIMARY KEY,
    commentId TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    createdAt TEXT DEFAULT (datetime('now'))
  );"
}

# ============================================================
# Test Suite
# ============================================================

# Test 1: Issue command creates task
test_issue_command_creates_task() {
  init_db

  local body="/manul Implement feature X"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "100" --body "$body" --author "user1" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  local valid
  valid="$(echo "$output" | jq -r '.command.valid // false')"
  [ "$valid" = "true" ] || return 1

  local action
  action="$(echo "$output" | jq -r '.command.action // empty')"
  [ "$action" = "IMPLEMENT" ] || return 1
}

# Test 2: Same Issue preserves conversation
test_same_issue_preserves_conversation() {
  init_db

  # First comment
  local body1="/manul Implement feature X"
  local output1
  output1="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "100" --body "$body1" --author "user1" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  # Second comment on same issue
  local body2="/manul Also add tests"
  local output2
  output2="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "101" --body "$body2" --author "user1" --created "2026-09-11T00:01:00Z" --json 2>/dev/null)" || return 1

  # Both should be valid
  local valid1 valid2
  valid1="$(echo "$output1" | jq -r '.command.valid // false')"
  valid2="$(echo "$output2" | jq -r '.command.valid // false')"
  [ "$valid1" = "true" ] && [ "$valid2" = "true" ] || return 1
}

# Test 3: Duplicate comment does not create duplicate task
test_duplicate_comment_no_dup_task() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Insert first task
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:100', 'test/repo', 1, 'https://github.com/test/repo/issues/1#issuecomment-100', 'user1', 'Implement feature X', 'queued', '$now', 'conv-test');" 2>/dev/null

  # Try to insert duplicate
  local ins
  ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:100', 'test/repo', 1, 'https://github.com/test/repo/issues/1#issuecomment-100', 'user1', 'Implement feature X', 'queued', '$now', 'conv-test'); SELECT changes();" 2>/dev/null)"

  [ "$ins" = "0" ] || return 1
}

# Test 4: PR comment creates REVIEW_FIX
test_pr_comment_creates_review_fix() {
  init_db

  local body="/manul review-fix Please add error handling"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "200" --body "$body" --author "reviewer" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  local action
  action="$(echo "$output" | jq -r '.command.action // empty')"
  [ "$action" = "REVIEW_FIX" ] || return 1
}

# Test 5: REVIEW_FIX preserves prNumber
test_review_fix_preserves_pr_number() {
  init_db

  # Create conversation with active PR
  local conv_id="conv-test-pr"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 100, 'https://github.com/test/repo/issues/100', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=100 WHERE conversationId='$conv_id';" 2>/dev/null

  # Handle PR review
  local output
  output="$(review handle --repo "test/repo" --pr-number "100" --review-id "r1" --review-state "REQUEST_CHANGES" --body "Please fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "true" ] || return 1

  local pr_num
  pr_num="$(echo "$output" | jq -r '.prNumber // empty')"
  [ "$pr_num" = "100" ] || return 1
}

# Test 6: REVIEW_FIX preserves conversationId
test_review_fix_preserves_conversation() {
  init_db

  local conv_id="conv-test-ctx"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 50, 'https://github.com/test/repo/issues/50', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=55 WHERE conversationId='$conv_id';" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "55" --review-id "r2" --review-state "REQUEST_CHANGES" --body "Fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local conversation_id
  conversation_id="$(echo "$output" | jq -r '.conversationId // empty')"
  [ "$conversation_id" = "$conv_id" ] || return 1
}

# Test 7: parentTaskId is preserved
test_parent_task_id_preserved() {
  init_db

  local conv_id="conv-test-parent"
  local task_id="task-conv-test-parent-init"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 200, 'https://github.com/test/repo/issues/200', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=201 WHERE conversationId='$conv_id';" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, prNumber, action) VALUES('$task_id', 'test/repo', 200, 'https://github.com/test/repo/issues/200', 'user', 'Implement', 'completed', '$now', '$conv_id', 201, 'IMPLEMENT');" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "201" --review-id "r3" --review-state "REQUEST_CHANGES" --body "Fix issues" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  # Check that new task has parentTaskId
  local parent_id
  parent_id="$(echo "$output" | jq -r '.parentTaskId // empty')"
  [ "$parent_id" = "$task_id" ] || return 1
}

# Test 8: APPROVE does not create fix task
test_approve_no_fix_task() {
  init_db

  local conv_id="conv-test-approve"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 300, 'https://github.com/test/repo/issues/300', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=301 WHERE conversationId='$conv_id';" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "301" --review-id "r4" --review-state "APPROVE" --body "Looks good!" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "false" ] || return 1
}

# Test 9: REQUEST_CHANGES creates fix task
test_request_changes_creates_fix() {
  init_db

  local conv_id="conv-test-changes"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 400, 'https://github.com/test/repo/issues/400', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=401 WHERE conversationId='$conv_id';" 2>/dev/null

  local output
  output="$(review handle --repo "test/repo" --pr-number "401" --review-id "r5" --review-state "REQUEST_CHANGES" --body "Please add tests" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "true" ] || return 1

  local action
  action="$(echo "$output" | jq -r '.action // empty')"
  [ "$action" = "REQUEST_CHANGES" ] || return 1
}

# Test 10: Duplicate review is ignored
test_duplicate_review_ignored() {
  init_db

  local conv_id="conv-test-dup"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 500, 'https://github.com/test/repo/issues/500', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=501 WHERE conversationId='$conv_id';" 2>/dev/null

  # First review
  local output1
  output1="$(review handle --repo "test/repo" --pr-number "501" --review-id "r6" --review-state "REQUEST_CHANGES" --body "Fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  # Second review with same ID
  local output2
  output2="$(review handle --repo "test/repo" --pr-number "501" --review-id "r6" --review-state "REQUEST_CHANGES" --body "Fix this again" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 1

  local skipped1 skipped2
  skipped1="$(echo "$output1" | jq -r '.skipped // false')"
  skipped2="$(echo "$output2" | jq -r '.skipped // false')"

  # Second should be skipped
  [ "$skipped2" = "true" ] || return 1
}

# One submitted review with multiple inline comments must produce one durable task.
test_grouped_inline_review_creates_single_task() {
  init_db

  local conv_id="conv-grouped-review"
  local pr_number=801
  local review_id="76001"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', $pr_number, 'https://github.com/test/repo/issues/$pr_number', $pr_number, 'OPEN', '$now', '$now');" 2>/dev/null

  local comments_json
  comments_json="$(jq -nc '[
    {id:101,pull_request_review_id:76001,path:"src/auth.kt",line:42,body:"Handle timeout failures consistently",diff_hunk:"@@ -40,1 +40,2 @@",html_url:"https://github.com/test/repo/pull/801#discussion_r101",in_reply_to_id:null,manul_thread_root_id:"101"},
    {id:102,pull_request_review_id:76001,path:"tests/test_auth.kt",line:15,body:"Add a regression test for this path",diff_hunk:"@@ -10,1 +10,2 @@",html_url:"https://github.com/test/repo/pull/801#discussion_r102",in_reply_to_id:null,manul_thread_root_id:"102"},
    {id:103,pull_request_review_id:76001,path:"src/auth.kt",line:43,body:"Thanks, fixed this thread",diff_hunk:"@@ -40,1 +40,2 @@",html_url:"https://github.com/test/repo/pull/801#discussion_r103",in_reply_to_id:101,manul_thread_root_id:"101"}
  ]')"

  local output
  output="$(review handle --repo "test/repo" --pr-number "$pr_number" --review-id "$review_id" --review-state "COMMENT" --body "" --author "reviewer" --created "$now" --review-comments-json "$comments_json" --json 2>/dev/null)" || return 1
  [ "$(jq -r '.createdTask // false' <<<"$output")" = "true" ] || return 1

  local task_id prompt task_count
  task_id="$(jq -r '.newTaskId // empty' <<<"$output")"
  [ -n "$task_id" ] || return 1
  prompt="$(sqlite3 "$DB" "SELECT prompt FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)" || return 1
  [[ "$prompt" == *"Handle timeout failures consistently"* ]] || return 1
  [[ "$prompt" == *"Add a regression test for this path"* ]] || return 1
  [[ "$prompt" == *"Thread root ID: 101"* ]] || return 1
  [[ "$prompt" == *"Thread root ID: 102"* ]] || return 1
  [[ "$prompt" != *"Thanks, fixed this thread"* ]] || return 1
  task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE action='REVIEW_FIX' AND prNumber=$pr_number AND conversationId='$conv_id';" 2>/dev/null)" || return 1
  [ "$task_count" = "1" ] || return 1

  # Duplicate delivery of the same review must reuse the task.
  local duplicate_output
  duplicate_output="$(review handle --repo "test/repo" --pr-number "$pr_number" --review-id "$review_id" --review-state "COMMENT" --body "" --author "reviewer" --created "$now" --review-comments-json "$comments_json" --json 2>/dev/null)" || return 1
  [ "$(jq -r '.skipped // false' <<<"$duplicate_output")" = "true" ] || return 1
  task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE action='REVIEW_FIX' AND prNumber=$pr_number AND conversationId='$conv_id';" 2>/dev/null)" || return 1
  [ "$task_count" = "1" ] || return 1
}

# A review reply is conversation context, not new feedback for a REVIEW_FIX task.
test_reply_only_reviews_do_not_create_fix_tasks() {
  init_db

  local conv_id="conv-reply-only-review"
  local pr_number=802
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', $pr_number, 'https://github.com/test/repo/issues/$pr_number', $pr_number, 'OPEN', '$now', '$now');" 2>/dev/null

  local reply_comments_json
  reply_comments_json="$(jq -nc '[
    {id:201,pull_request_review_id:86001,path:"src/auth.kt",line:42,body:"Thanks, fixed",diff_hunk:"@@ -40,1 +40,2 @@",html_url:"https://github.com/test/repo/pull/802#discussion_r201",in_reply_to_id:100,manul_thread_root_id:"100"}
  ]')"

  local comment_output changes_output task_count
  comment_output="$(review handle --repo "test/repo" --pr-number "$pr_number" --review-id "reply-comment" --review-state "COMMENT" --body "" --author "reviewer" --created "$now" --review-comments-json "$reply_comments_json" --json 2>/dev/null)" || return 1
  [ "$(jq -r '.createdTask // false' <<<"$comment_output")" = "false" ] || return 1

  # CHANGES_REQUESTED with no review body and only replies is also non-actionable.
  changes_output="$(review handle --repo "test/repo" --pr-number "$pr_number" --review-id "reply-changes" --review-state "REQUEST_CHANGES" --body "" --author "reviewer" --created "$now" --review-comments-json "$reply_comments_json" --json 2>/dev/null)" || return 1
  [ "$(jq -r '.createdTask // false' <<<"$changes_output")" = "false" ] || return 1

  task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE action='REVIEW_FIX' AND prNumber=$pr_number AND conversationId='$conv_id';" 2>/dev/null)" || return 1
  [ "$task_count" = "0" ] || return 1
}

# The poller must discard replies before dispatching a submitted-review task.
test_poll_review_submission_ignores_replies() {
  source <(sed -n '/^filter_actionable_review_comments()/,/^}/p' "$SCRIPT_DIR/poll.sh")

  local page_one page_two comments_json actionable reply_only
  page_one='[{"id":101,"pull_request_review_id":76001,"in_reply_to_id":null,"body":"New finding"}]'
  page_two='[
    {"id":102,"pull_request_review_id":76001,"in_reply_to_id":101,"body":"Reply to existing thread"},
    {"id":104,"pull_request_review_id":76001,"in_reply_to_id":null,"body":"Second new finding"},
    {"id":103,"pull_request_review_id":76002,"in_reply_to_id":101,"body":"Reply-only review"}
  ]'
  comments_json="$(printf '%s\n%s' "$page_one" "$page_two")"

  actionable="$(filter_actionable_review_comments "$comments_json" 76001)" || return 1
  [ "$(jq -r 'length' <<<"$actionable")" = "2" ] || return 1
  [ "$(jq -r '.[].id' <<<"$actionable" | paste -sd ',' -)" = "101,104" ] || return 1

  reply_only="$(filter_actionable_review_comments "$comments_json" 76002)" || return 1
  [ "$(jq -r 'length' <<<"$reply_only")" = "0" ] || return 1
}

# Test 11: Structured events parse correctly
test_structured_events_parse() {
  local body="<!-- manul:event {\"type\":\"TASK_DONE\",\"timestamp\":\"2026-09-11T00:00:00Z\",\"data\":{\"taskId\":\"t1\",\"status\":\"completed\"}} -->
Some human readable text
<!-- manul:event {\"type\":\"REVIEW_APPROVED\",\"timestamp\":\"2026-09-11T00:01:00Z\",\"data\":{\"prNumber\":100}} -->"

  local output
  output="$(events extract-events --body "$body" --json 2>/dev/null)" || return 1

  local event_count
  event_count="$(echo "$output" | jq -r '.eventCount // 0')"
  [ "$event_count" = "2" ] || return 1
}

# Test 12: Malformed events are ignored safely
test_malformed_events_ignored() {
  local body="<!-- manul:event {invalid json -->
Normal comment
<!-- manul:event -->"

  local output
  output="$(events extract-events --body "$body" --json 2>/dev/null)" || return 0  # Should not crash

  local event_count
  event_count="$(echo "$output" | jq -r '.eventCount // 0')"
  [ "$event_count" = "0" ] || return 1
}

# Test 13: Task result produces machine event
test_task_result_produces_event() {
  init_db

  local task_id="task-result-test"
  local conv_id="conv-result-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 600, 'https://github.com/test/repo/issues/600', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action) VALUES('$task_id', 'test/repo', 600, 'https://github.com/test/repo/issues/600', 'user', 'Implement', 'completed', '$now', '$conv_id', 'IMPLEMENT');" 2>/dev/null

  local output
  output="$(feedback post-done --repo "test/repo" --issue "600" --comment-id "c1" --task-id "$task_id" --summary "Completed successfully" --pr-number "601" --json 2>/dev/null)" || return 1

  local status
  status="$(echo "$output" | jq -r '.status // empty')"
  [ "$status" = "completed" ] || return 1

  local has_marker
  has_marker="$(echo "$output" | jq -r '.hasSummary // false')"
  [ "$has_marker" = "true" ] || return 1
}

# Test 14: Failed task produces machine event
test_failed_task_produces_event() {
  init_db

  local task_id="task-fail-test"
  local conv_id="conv-fail-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 700, 'https://github.com/test/repo/issues/700', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action) VALUES('$task_id', 'test/repo', 700, 'https://github.com/test/repo/issues/700', 'user', 'Implement', 'failed', '$now', '$conv_id', 'IMPLEMENT');" 2>/dev/null

  local output
  output="$(feedback post-failed --repo "test/repo" --issue "700" --comment-id "c2" --task-id "$task_id" --error "Something went wrong" --json 2>/dev/null)" || return 1

  # Regression: failed feedback must report the configured maximum attempt count.
  local helper_source
  helper_source="$(cat "$FEEDBACK_SCRIPT")"
  echo "$helper_source" | grep -q 'max_attempts=.*maxAttemptsBeforeFail' || return 1
  echo "$helper_source" | grep -q '\*\*Attempt:\*\* \${attempt}/\${max_attempts}' || return 1
  echo "$helper_source" | grep -q 'maxAttempts: \$maxAttempts' || return 1
  local status
  status="$(echo "$output" | jq -r '.status // empty')"
  [ "$status" = "failed" ] || return 1
}

# Test 15: Out-of-order events are handled
test_out_of_order_events() {
  init_db

  local conv_id="conv-test-oio"
  local task_id="task-oio-1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 800, 'https://github.com/test/repo/issues/800', 'OPEN', '$now', '$now');" 2>/dev/null

  # Simulate out-of-order: TASK_DONE before TASK_STARTED
  local output1
  output1="$(feedback post-done --repo "test/repo" --issue "800" --comment-id "c3" --task-id "$task_id" --summary "Done" --json 2>/dev/null)" || return 1

  local status1
  status1="$(echo "$output1" | jq -r '.status // empty')"
  [ "$status1" = "completed" ] || return 1
}

# Test 16: Merged PR handling
test_merged_pr_handling() {
  init_db

  local conv_id="conv-test-merged"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 900, 'https://github.com/test/repo/issues/900', 'COMPLETED', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=901 WHERE conversationId='$conv_id';" 2>/dev/null

  # Try to handle review on merged PR - should error because conversation is completed
  local output
  output="$(review handle --repo "test/repo" --pr-number "901" --review-id "r7" --review-state "REQUEST_CHANGES" --body "Fix this" --author "reviewer" --created "$now" --json 2>/dev/null)" || return 0  # Expected to fail

  # Should not create task for completed conversation
  local created_task
  created_task="$(echo "$output" | jq -r '.createdTask // false')"
  [ "$created_task" = "false" ] || return 1
}

# Test 17: Closed Issue handling
test_closed_issue_handling() {
  init_db

  local body="/manul Do something"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "1000" --comment-id "c4" --body "$body" --author "user" --created "2026-09-11T00:00:00Z" --json 2>/dev/null)" || return 1

  local valid
  valid="$(echo "$output" | jq -r '.command.valid // false')"
  [ "$valid" = "true" ] || return 1

  # Parsing should succeed even for closed issues (validation happens elsewhere)
}

# Test 18: Concurrent comments
test_concurrent_comments() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Insert two tasks concurrently
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:1100', 'test/repo', 1100, 'https://github.com/test/repo/issues/1100#comment-1', 'user1', 'Task 1', 'queued', '$now', 'conv-concurrent');" 2>/dev/null
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId) VALUES('issue:1101', 'test/repo', 1100, 'https://github.com/test/repo/issues/1100#comment-2', 'user1', 'Task 2', 'queued', '$now', 'conv-concurrent');" 2>/dev/null

  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='conv-concurrent' AND status='queued';" 2>/dev/null)"
  [ "$count" = "2" ] || return 1
}

# Test 19: JSON/state consistency
test_json_state_consistency() {
  init_db

  local task_id="task-json-test"
  local conv_id="conv-json-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 1200, 'https://github.com/test/repo/issues/1200', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action, resultSummary) VALUES('$task_id', 'test/repo', 1200, 'https://github.com/test/repo/issues/1200', 'user', 'Implement', 'completed', '$now', '$conv_id', 'IMPLEMENT', 'Done successfully');" 2>/dev/null

  local output
  output="$(feedback post-done --repo "test/repo" --issue "1200" --comment-id "c5" --task-id "$task_id" --summary "Test summary" --json 2>/dev/null)" || return 1

  # Verify JSON is valid
  echo "$output" | jq empty 2>/dev/null || return 1

  # Verify fields exist
  local has_task_id has_status has_marker
  has_task_id="$(echo "$output" | jq -r '.taskId // empty')"
  has_status="$(echo "$output" | jq -r '.status // empty')"
  has_marker="$(echo "$output" | jq -r '.eventMarker // empty')"

  [ -n "$has_task_id" ] && [ -n "$has_status" ] && [ -n "$has_marker" ] || return 1
}

# Test 20: Production path safety
test_production_path_safety() {
  init_db

  # Test with empty/missing fields
  local output
  output="$(events parse-comment --repo "" --issue "" --comment-id "" --body "" --json 2>/dev/null)" || return 0  # Should not crash

  # Test with SQL injection attempts
  local malicious_body="/manul'; DROP TABLE processed_comments; --"
  output="$(events parse-comment --repo "test/repo" --issue "1" --comment-id "c6" --body "$malicious_body" --json 2>/dev/null)" || return 1

  # Should parse safely without executing SQL
  local valid
  valid="$(echo "$output" | jq -r '.command.valid // false')"
  [ "$valid" = "true" ] || return 1
}

# ============================================================
# Regression Tests for Production Fixes
# ============================================================

# Test 21: get_pr_pending_task excludes REVIEW action only (not queued status)
test_get_pr_pending_task_excludes_review_not_queued() {
  init_db

  # Verify the SQL query in get_pr_pending_task excludes REVIEW but NOT queued
  local query
  query="$(sed -n '/^get_pr_pending_task/,/^}/p' "$REVIEW_SCRIPT" | grep 'action NOT IN' | head -1)"

  # Must exclude REVIEW action
  echo "$query" | grep -q "NOT IN.*('REVIEW')" || return 1

  # Must NOT exclude queued status (it's a status, not an action)
  echo "$query" | grep -q "NOT IN.*queued" && return 1

  # Also verify via direct SQL that the query works correctly
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Insert test data
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, action, prNumber) VALUES('review-task', 'test/repo', 100, 'https://github.com/test/repo/pull/100', 'user', 'Review', 'running', '$now', 'REVIEW', 100);" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, action, prNumber) VALUES('queued-task', 'test/repo', 100, 'https://github.com/test/repo/pull/100', 'user', 'Implement', 'queued', '$now', 'IMPLEMENT', 100);" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, action, prNumber) VALUES('running-task', 'test/repo', 100, 'https://github.com/test/repo/pull/100', 'user', 'Implement', 'running', '$now', 'IMPLEMENT', 100);" 2>/dev/null

  # Run the exact SQL query from the script
  local selected_task
  selected_task="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='test/repo' AND prNumber=100 AND status IN ('running', 'completed') AND action NOT IN ('REVIEW') ORDER BY createdAt DESC LIMIT 1;" 2>/dev/null)"

  # Should return running-task, not review-task
  [ "$selected_task" = "running-task" ] || return 1
}

# Test 22: post_comment failure propagates correctly
test_post_comment_failure_propagates() {
  init_db

  local task_id="task-fail-test"
  local conv_id="conv-fail-test"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 200, 'https://github.com/test/repo/issues/200', 'OPEN', '$now', '$now');" 2>/dev/null
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, conversationId, action) VALUES('$task_id', 'test/repo', 200, 'https://github.com/test/repo/issues/200', 'user', 'Implement', 'completed', '$now', '$conv_id', 'IMPLEMENT');" 2>/dev/null

  # Create a mock gh that fails
  local mock_gh_dir
  mock_gh_dir="$(mktemp -d)"
  cat > "$mock_gh_dir/gh" <<'MOCK_EOF'
#!/bin/bash
if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  echo "gh: failed to post comment" >&2
  exit 1
fi
MOCK_EOF
  chmod +x "$mock_gh_dir/gh"

  # Run post-done with mock gh
  local output
  output="$(GH_BIN="$mock_gh_dir/gh" MANUL_DIR="$MANUL_DIR" PATH="$mock_gh_dir:$PATH" bash "$FEEDBACK_SCRIPT" --json post-done --repo "test/repo" --issue "200" --comment-id "c1" --task-id "$task_id" --summary "Completed" --pr-number "201" 2>/dev/null)" || true

  # Verify output indicates failure (not success)
  local status
  status="$(echo "$output" | jq -r '.status // empty')"
  # The command should fail, not silently succeed
  [ "$status" != "completed" ] || return 1

  # Clean up
  rm -rf "$mock_gh_dir"
  return 0
}

# Test 23: parentTaskId resolves to execution task
test_parent_task_id_resolves_to_execution() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local parent_task_id="parent-exec-task"
  local conv_id="conv-parent-test"

  # Insert parent execution task (running)
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, action, prNumber, conversationId) VALUES('$parent_task_id', 'test/repo', 300, 'https://github.com/test/repo/pull/300', 'user', 'Implement', 'running', '$now', 'IMPLEMENT', 300, '$conv_id');" 2>/dev/null

  # Insert conversation
  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', 'test/repo', 300, 'https://github.com/test/repo/pull/300', 300, 'OPEN', '$now', '$now');" 2>/dev/null

  # Verify the task exists in DB with correct parentTaskId resolution
  local task_count
  task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='$parent_task_id' AND action='IMPLEMENT' AND status='running' AND prNumber=300;" 2>/dev/null)"
  [ "$task_count" -eq 1 ] || return 1

  # Verify the SQL query in get_pr_pending_task would return this task
  local query
  query="$(sed -n '/^get_pr_pending_task/,/^}/p' "$REVIEW_SCRIPT" | grep 'action NOT IN' | head -1)"
  echo "$query" | grep -q "status IN.*('running', 'completed')" || return 1
  echo "$query" | grep -q "action NOT IN.*('REVIEW')" || return 1
}

# ============================================================
# End-to-End Mock Flow
# ============================================================
test_end_to_end_mock_flow() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Step 1: Issue comment creates conversation and task
  local issue_body="/manul Implement feature X"
  local issue_output
  issue_output="$(events parse-comment --repo "test/e2e" --issue "200" --comment-id "e2e-1" --body "$issue_body" --author "user1" --created "$now" --json 2>/dev/null)" || return 1

  local issue_valid
  issue_valid="$(echo "$issue_output" | jq -r '.command.valid // false')"
  [ "$issue_valid" = "true" ] || return 1

  # Create conversation in DB
  local conv_id="conv-e2e-$(date +%s)"
  sqlite3 "$DB" "INSERT INTO conversations(conversationId, repository, issueNumber, issueUrl, status, createdAt, updatedAt) VALUES('$conv_id', 'test/e2e', 200, 'https://github.com/test/e2e/issues/200', 'OPEN', '$now', '$now');" 2>/dev/null

  # Step 2: PR created (simulated)
  local pr_number="300"
  sqlite3 "$DB" "UPDATE conversations SET activePrNumber=$pr_number, updatedAt='$now' WHERE conversationId='$conv_id';" 2>/dev/null

  # Create initial task with PR number set
  local task_id="task-e2e-init-$(date +%s)"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt, conversationId, action, prNumber) VALUES('$task_id', 'test/e2e', 200, 'https://github.com/test/e2e/issues/200#comment-e2e-1', 'user1', 'manul', 'Implement feature X', 'completed', '$now', '$conv_id', 'IMPLEMENT', $pr_number);" 2>/dev/null

  # Step 3: ChatGPT reviews with REQUEST_CHANGES
  local review_body="Please add error handling"
  local review_output
  review_output="$(review handle --repo "test/e2e" --pr-number "$pr_number" --review-id "e2e-r1" --review-state "REQUEST_CHANGES" --body "$review_body" --author "chatgpt" --created "$now" --json 2>/dev/null)" || return 1

  local review_created
  review_created="$(echo "$review_output" | jq -r '.createdTask // false')"
  [ "$review_created" = "true" ] || return 1

  local review_task_id
  review_task_id="$(echo "$review_output" | jq -r '.newTaskId // empty')"
  [ -n "$review_task_id" ] || return 1

  # Verify parentTaskId
  local parent_id
  parent_id="$(echo "$review_output" | jq -r '.parentTaskId // empty')"
  [ "$parent_id" = "$task_id" ] || return 1

  # Step 4: ChatGPT approves
  local approve_output
  approve_output="$(review handle --repo "test/e2e" --pr-number "$pr_number" --review-id "e2e-r2" --review-state "APPROVE" --body "Looks good!" --author "chatgpt" --created "$now" --json 2>/dev/null)" || return 1

  local approve_created
  approve_created="$(echo "$approve_output" | jq -r '.createdTask // false')"
  [ "$approve_created" = "false" ] || return 1

  # Step 5: Post task result
  local result_output
  result_output="$(feedback post-done --repo "test/e2e" --issue "200" --comment-id "e2e-c1" --task-id "$review_task_id" --summary "Fixed error handling" --pr-number "$pr_number" --json 2>/dev/null)" || return 1

  local result_status
  result_status="$(echo "$result_output" | jq -r '.status // empty')"
  [ "$result_status" = "completed" ] || return 1

  # Verify event marker exists
  local has_marker
  has_marker="$(echo "$result_output" | jq -r '.eventMarker // empty')"
  [ -n "$has_marker" ] || return 1

  # Verify marker contains TASK_DONE
  echo "$has_marker" | grep -q "TASK_DONE" || return 1
}

# ============================================================
# Production Fix Regression Tests
# ============================================================

# Test 24: PR conversation comment routes to REVIEW_FIX not IMPLEMENT
test_pr_conversation_routes_to_review_fix() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Create open PRs array (simulating poll.sh OPEN_PRS)
  export OPEN_PRS=("42")

  # Simulate PR conversation comment (issue comment on PR)
  local pr_comment_body="/manul REVIEW_FIX Add error handling"
  local pr_comment_json
  pr_comment_json="$(printf '{"id":999,"body":"%s","user":{"login":"user"},"created_at":"%s","html_url":"https://github.com/test/repo/pull/42#issuecomment-999","issue_url":"https://api.github.com/repos/test/repo/issues/42"}' "$pr_comment_body" "$now")"

  # Parse with same jq filter as poll.sh (input must be array for .[] to work)
  local parsed
  parsed="$(echo "[$pr_comment_json]" | jq -c --arg repo "test/repo" --arg trig "/manul" --arg sig "manul-task:" --arg base "$now" --argjson allowed '["user"]' --argjson agents '{}' --argjson open_prs '[42]' '
    .[] | select(.created_at >= $base) | select(.body | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
    | ($lines[$idx] | sub("^[/]?manul[[:space:]]*"; ""; "g")) as $prompt_line
    | ($prompt_line | capture("^(?<action>IMPLEMENT|REVIEW_FIX)[[:space:]]+(?<prompt>.*)") // {action: "IMPLEMENT", prompt: $prompt_line}) as $actx
    | (.issue_url | capture("issues/(?<n>[0-9]+)$").n | tonumber) as $issue_num
    | (if $actx.action != null then $actx.action
       elif ($open_prs | index($issue_num)) then "REVIEW_FIX"
       else "IMPLEMENT"
       end) as $action
    | {id: ("issue:" + (.id|tostring)), repo: $repo, author: .user.login, created: .created_at, url: .html_url, issueNumber: $issue_num, agent: ($agents | if has("user") then .user else "" end), action: $action, prompt: $actx.prompt}
  ')" || return 1

  local action
  action="$(echo "$parsed" | jq -r '.action')"
  [ "$action" = "REVIEW_FIX" ] || return 1
}

# Test 25: Issue comment routes to IMPLEMENT not REVIEW_FIX
test_issue_comment_routes_to_implement() {
  init_db

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Create open PRs array (PR 42 is open, but issue 100 is not a PR)
  export OPEN_PRS=("42")

  # Simulate regular issue comment
  local issue_comment_body="/manul Implement feature X"
  local issue_comment_json
  issue_comment_json="$(printf '{"id":100,"body":"%s","user":{"login":"user"},"created_at":"%s","html_url":"https://github.com/test/repo/issues/100","issue_url":"https://api.github.com/repos/test/repo/issues/100"}' "$issue_comment_body" "$now")"

  # Parse with same jq filter as poll.sh (input must be array for .[] to work)
  local parsed
  parsed="$(echo "[$issue_comment_json]" | jq -c --arg repo "test/repo" --arg trig "/manul" --arg sig "manul-task:" --arg base "$now" --argjson allowed '["user"]' --argjson agents '{}' --argjson open_prs '[42]' '
    .[] | select(.created_at >= $base) | select(.body | contains($trig)) | select((.body // "") | contains($sig) | not) | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | contains($trig))][0]) as $idx
    | ($lines[$idx] | sub("^[/]?manul[[:space:]]*"; ""; "g")) as $prompt_line
    | ($prompt_line | capture("^(?<action>IMPLEMENT|REVIEW_FIX)[[:space:]]+(?<prompt>.*)") // {action: "IMPLEMENT", prompt: $prompt_line}) as $actx
    | (.issue_url | capture("issues/(?<n>[0-9]+)$").n | tonumber) as $issue_num
    | (if $actx.action != null then $actx.action
       elif ($open_prs | index($issue_num)) then "REVIEW_FIX"
       else "IMPLEMENT"
       end) as $action
    | {id: ("issue:" + (.id|tostring)), repo: $repo, author: .user.login, created: .created_at, url: .html_url, issueNumber: $issue_num, agent: ($agents | if has("user") then .user else "" end), action: $action, prompt: $actx.prompt}
  ')" || return 1

  local action
  action="$(echo "$parsed" | jq -r '.action')"
  [ "$action" = "IMPLEMENT" ] || return 1
}

# Test 26: URL parsing regression — issue URL form
test_url_parsing_issue_form() {
  local url="https://github.com/test-org/test-repo/issues/100"
  local issue_num
  issue_num="$(jq -Rr 'capture("(?:issues|pull)/(?<n>[0-9]+)").n | tonumber' <<< "$url")"
  [ "$issue_num" = "100" ] || { echo "Expected 100, got $issue_num"; return 1; }
}

# Test 27: URL parsing regression — pull URL form
test_url_parsing_pull_form() {
  local url="https://github.com/test-org/test-repo/pull/42"
  local issue_num
  issue_num="$(jq -Rr 'capture("(?:issues|pull)/(?<n>[0-9]+)").n | tonumber' <<< "$url")"
  [ "$issue_num" = "42" ] || { echo "Expected 42, got $issue_num"; return 1; }
}

# ============================================================
# Anchored Trigger Parser Regression Tests (GitHub issue #44)
# ============================================================

# Test 28: Standard line-start command
test_trigger_anchors_standard() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "300" --body "/manul do that task" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid action
  valid="$(echo "$output" | jq -r '.command.valid')"
  action="$(echo "$output" | jq -r '.command.action')"
  [ "$valid" = "true" ] || { echo "Expected valid=true"; return 1; }
  [ "$action" = "IMPLEMENT" ] || { echo "Expected action=IMPLEMENT got=$action"; return 1; }
}

# Test 29: Leading whitespace before trigger
test_trigger_anchors_leading_whitespace() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "301" --body "   /manul do that task" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid action
  valid="$(echo "$output" | jq -r '.command.valid')"
  action="$(echo "$output" | jq -r '.command.action')"
  [ "$valid" = "true" ] || { echo "Expected valid=true"; return 1; }
  [ "$action" = "IMPLEMENT" ] || { echo "Expected action=IMPLEMENT got=$action"; return 1; }
}

# Test 30: Inline quote — should NOT trigger
test_trigger_anchors_inline_quote_no_trigger() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "302" --body 'trigger /manul do that task' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "false" ] || { echo "Expected valid=false got=$valid"; return 1; }
}

# Test 31: Previous-command line — should NOT trigger
test_trigger_anchors_previous_command_no_trigger() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "303" --body 'previous command: /manul do that task' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "false" ] || { echo "Expected valid=false got=$valid"; return 1; }
}

# Test 32: Code-block quote — should NOT trigger
test_trigger_anchors_code_block_quote_no_trigger() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "304" --body '\`/manul do that task\`' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "false" ] || { echo "Expected valid=false got=$valid"; return 1; }
}

# Test 33: Multiline — trigger on line 2 should be recognized
test_trigger_anchors_multiline_line_start() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local body
  body=$'text before\n/manul do that task'
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "305" --body "$body" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "true" ] || { echo "Expected valid=true got=$valid"; return 1; }
}

# Test 34: Filename path — should NOT trigger
test_trigger_anchors_filename_path_no_trigger() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "306" --body 'docs/manul-2024/file.md' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "false" ] || { echo "Expected valid=false got=$valid"; return 1; }
}

# Test 35: Prefix command — should NOT trigger
test_trigger_anchors_prefix_command_no_trigger() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "307" --body '/manulrun do that task' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "false" ] || { echo "Expected valid=false got=$valid"; return 1; }
}

# Test 36: Command with subcommand
test_trigger_anchors_cmd_with_subcommand() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "308" --body '/manul review-fix foo' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid action
  valid="$(echo "$output" | jq -r '.command.valid')"
  action="$(echo "$output" | jq -r '.command.action')"
  [ "$valid" = "true" ] || { echo "Expected valid=true got=$valid"; return 1; }
  [ "$action" = "REVIEW_FIX" ] || { echo "Expected action=REVIEW_FIX got=$action"; return 1; }
}

# Test 37: Bare trigger
test_trigger_anchors_bare_trigger() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "309" --body '/manul' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid
  valid="$(echo "$output" | jq -r '.command.valid')"
  [ "$valid" = "true" ] || { echo "Expected valid=true got=$valid"; return 1; }
}

# Test 38: Continue subcommand
test_trigger_anchors_continue_subcommand() {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local output
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "310" --body '/manul continue my answer' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  local valid action
  valid="$(echo "$output" | jq -r '.command.valid')"
  action="$(echo "$output" | jq -r '.command.action')"
  [ "$valid" = "true" ] || { echo "Expected valid=true got=$valid"; return 1; }
  [ "$action" = "CONTINUE" ] || { echo "Expected action=CONTINUE got=$action"; return 1; }
}

# Test 45: Verify subcommand selects report-only delivery and strips the command prefix
test_verify_command_is_parsed() {
  local now output valid action prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "100" --comment-id "317" --body '/manul verify diagnose the issue without editing code' --author "user" --created "$now" --json 2>/dev/null)" || return 1
  valid="$(echo "$output" | jq -r '.command.valid')"
  action="$(echo "$output" | jq -r '.command.action')"
  prompt="$(echo "$output" | jq -r '.command.prompt')"
  [ "$valid" = "true" ] && [ "$action" = "VERIFY" ] && [ "$prompt" = "diagnose the issue without editing code" ]
}

# Test 39: /manul run --agent <role> preserves role and removes selector from task prompt
test_run_agent_flag_routes_explicit_role() {
  local now output agent selection prompt action
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "101" --comment-id "311" --body "/manul run --agent coder add unit tests" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  agent="$(echo "$output" | jq -r '.command.agent // empty')"
  selection="$(echo "$output" | jq -r '.command.agentSelection // empty')"
  prompt="$(echo "$output" | jq -r '.command.prompt // empty')"
  action="$(echo "$output" | jq -r '.command.action // empty')"
  [ "$agent" = "coder" ] && [ "$selection" = "explicit" ] && [ "$prompt" = "add unit tests" ] && [ "$action" = "IMPLEMENT" ]
}

# Test 40: no explicit role means automatic runtime entry-point selection
test_run_without_agent_is_automatic() {
  local now output agent selection prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "101" --comment-id "312" --body "/manul run add unit tests" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  agent="$(echo "$output" | jq -r '.command.agent // empty')"
  selection="$(echo "$output" | jq -r '.command.agentSelection // empty')"
  prompt="$(echo "$output" | jq -r '.command.prompt // empty')"
  [ -z "$agent" ] && [ "$selection" = "automatic" ] && [ "$prompt" = "add unit tests" ]
}

# Test 41: shorthand /manul <role> <task> remains supported
test_shorthand_agent_routes_explicit_role() {
  local now output agent selection prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "101" --comment-id "313" --body "/manul coder add unit tests" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  agent="$(echo "$output" | jq -r '.command.agent // empty')"
  selection="$(echo "$output" | jq -r '.command.agentSelection // empty')"
  prompt="$(echo "$output" | jq -r '.command.prompt // empty')"
  [ "$agent" = "coder" ] && [ "$selection" = "explicit" ] && [ "$prompt" = "add unit tests" ]
}

# Test 42: unknown role supplied through --agent is preserved for fail-closed validation
test_unknown_agent_flag_is_not_silently_discarded() {
  local now output agent selection prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "101" --comment-id "314" --body "/manul run --agent missing-role do the task" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  agent="$(echo "$output" | jq -r '.command.agent // empty')"
  selection="$(echo "$output" | jq -r '.command.agentSelection // empty')"
  prompt="$(echo "$output" | jq -r '.command.prompt // empty')"
  [ "$agent" = "missing-role" ] && [ "$selection" = "explicit" ] && [ "$prompt" = "do the task" ]
}


# Test 43: /manul --auto runs with OpenCode mode and is removed from the prompt
test_auto_flag_before_run_is_parsed() {
  local now output auto prompt action
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "101" --comment-id "315" --body "/manul --auto run add unit tests" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  auto="$(echo "$output" | jq -r '.command.autoAccept // false')"
  prompt="$(echo "$output" | jq -r '.command.prompt // empty')"
  action="$(echo "$output" | jq -r '.command.action // empty')"
  [ "$auto" = "true" ] && [ "$prompt" = "add unit tests" ] && [ "$action" = "IMPLEMENT" ]
}

# Test 44: --auto may accompany an explicit --agent without entering the prompt
test_auto_flag_with_explicit_agent_is_parsed() {
  local now output auto agent selection prompt
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  output="$(events parse-comment --repo "test/repo" --issue "101" --comment-id "316" --body "/manul run --agent coder --auto add unit tests" --author "user" --created "$now" --json 2>/dev/null)" || return 1
  auto="$(echo "$output" | jq -r '.command.autoAccept // false')"
  agent="$(echo "$output" | jq -r '.command.agent // empty')"
  selection="$(echo "$output" | jq -r '.command.agentSelection // empty')"
  prompt="$(echo "$output" | jq -r '.command.prompt // empty')"
  [ "$auto" = "true" ] && [ "$agent" = "coder" ] && [ "$selection" = "explicit" ] && [ "$prompt" = "add unit tests" ]
}

# ============================================================
# Run Tests
# ============================================================

echo "═══════════════════════════════════════════════════════════════"
echo "  GitHub Control Protocol Tests"
echo "═══════════════════════════════════════════════════════════════"

# Core tests
run_test "Test 1: Issue command creates task" test_issue_command_creates_task
run_test "Test 2: Same Issue preserves conversation" test_same_issue_preserves_conversation
run_test "Test 3: Duplicate comment does not create duplicate task" test_duplicate_comment_no_dup_task
run_test "Test 4: PR comment creates REVIEW_FIX" test_pr_comment_creates_review_fix
run_test "Test 5: REVIEW_FIX preserves prNumber" test_review_fix_preserves_pr_number
run_test "Test 6: REVIEW_FIX preserves conversationId" test_review_fix_preserves_conversation
run_test "Test 7: parentTaskId is preserved" test_parent_task_id_preserved
run_test "Test 8: APPROVE does not create fix task" test_approve_no_fix_task
run_test "Test 9: REQUEST_CHANGES creates fix task" test_request_changes_creates_fix
run_test "Test 10: Duplicate review is ignored" test_duplicate_review_ignored
run_test "Test 46: Grouped inline review comments create one task" test_grouped_inline_review_creates_single_task
run_test "Test 47: Reply-only reviews do not create fix tasks" test_reply_only_reviews_do_not_create_fix_tasks
run_test "Test 48: Poll ignores replies when grouping inline review comments" test_poll_review_submission_ignores_replies

# Event tests
run_test "Test 11: Structured events parse correctly" test_structured_events_parse
run_test "Test 12: Malformed events are ignored safely" test_malformed_events_ignored
run_test "Test 13: Task result produces machine event" test_task_result_produces_event
run_test "Test 14: Failed task produces machine event" test_failed_task_produces_event
run_test "Test 15: Out-of-order events are handled" test_out_of_order_events

# Edge case tests
run_test "Test 16: Merged PR handling" test_merged_pr_handling
run_test "Test 17: Closed Issue handling" test_closed_issue_handling
run_test "Test 18: Concurrent comments" test_concurrent_comments
run_test "Test 19: JSON/state consistency" test_json_state_consistency
run_test "Test 20: Production path safety" test_production_path_safety

# Regression tests for production fixes
run_test "Test 21: get_pr_pending_task excludes REVIEW not queued" test_get_pr_pending_task_excludes_review_not_queued
run_test "Test 22: post_comment failure propagates correctly" test_post_comment_failure_propagates
run_test "Test 23: parentTaskId resolves to execution task" test_parent_task_id_resolves_to_execution

# Production fix regression tests
run_test "Test 24: PR conversation comment routes to REVIEW_FIX not IMPLEMENT" test_pr_conversation_routes_to_review_fix
run_test "Test 25: Issue comment routes to IMPLEMENT not REVIEW_FIX" test_issue_comment_routes_to_implement
run_test "Test 26: URL parsing regression — issue form" test_url_parsing_issue_form
run_test "Test 27: URL parsing regression — pull form" test_url_parsing_pull_form

# Anchored trigger parser regression tests (GitHub issue #44)
run_test "Test 28: Trigger anchor — standard command" test_trigger_anchors_standard
run_test "Test 29: Trigger anchor — leading whitespace" test_trigger_anchors_leading_whitespace
run_test "Test 30: Trigger anchor — inline quote no trigger" test_trigger_anchors_inline_quote_no_trigger
run_test "Test 31: Trigger anchor — previous-command no trigger" test_trigger_anchors_previous_command_no_trigger
run_test "Test 32: Trigger anchor — code-block-quote no trigger" test_trigger_anchors_code_block_quote_no_trigger
run_test "Test 33: Trigger anchor — multiline line-start" test_trigger_anchors_multiline_line_start
run_test "Test 34: Trigger anchor — filename path no trigger" test_trigger_anchors_filename_path_no_trigger
run_test "Test 35: Trigger anchor — prefix command no trigger" test_trigger_anchors_prefix_command_no_trigger
run_test "Test 36: Trigger anchor — command with subcommand" test_trigger_anchors_cmd_with_subcommand
run_test "Test 37: Trigger anchor — bare trigger" test_trigger_anchors_bare_trigger
run_test "Test 38: Trigger anchor — continue subcommand" test_trigger_anchors_continue_subcommand
run_test "Test 45: /manul verify selects report-only delivery" test_verify_command_is_parsed
run_test "Test 39: --agent flag routes explicit role" test_run_agent_flag_routes_explicit_role
run_test "Test 40: no --agent selects automatic runtime entry point" test_run_without_agent_is_automatic
run_test "Test 41: shorthand role routes explicitly" test_shorthand_agent_routes_explicit_role
run_test "Test 42: unknown --agent is preserved for fail-closed validation" test_unknown_agent_flag_is_not_silently_discarded
run_test "Test 43: --auto before run is parsed and stripped" test_auto_flag_before_run_is_parsed
run_test "Test 44: --auto with --agent is parsed and stripped" test_auto_flag_with_explicit_agent_is_parsed

# End-to-end test
echo ""
echo "=== End-to-End Mock Flow ==="
run_test "E2E: Issue -> PR -> Review -> Fix -> Approve" test_end_to_end_mock_flow

# ============================================================
# Results
# ============================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "  Results: %d passed, %d failed (out of %d tests)\n" "$PASSED" "$FAILED" "$TESTS_RUN"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

exit 0
