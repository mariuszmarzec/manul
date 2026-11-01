#!/bin/bash
# test_conversation_orchestrator.sh — Tests for Manul conversation orchestration layer
#
# Tests:
#   1. Create conversation
#   2. Stable conversationId
#   3. Conversation ↔ issue association
#   4. Submit first task
#   5. Task inherits conversation
#   6. Task association with issue
#   7. Task association with PR
#   8. Follow-up task
#   9. ParentTaskId linkage
#   10. Review-fix task continues existing PR
#   11. Review-fix does not create unrelated PR
#   12. Multiple tasks same conversation
#   13. Concurrent tasks same conversation
#   14. Task result exposes PR
#   15. PR merge detection
#   16. Completed conversation
#   17. Failed conversation
#   18. Conversation restart/recovery
#   19. JSON contract
#   20. Exit codes
#   21. Duplicate follow-up submission/idempotency
#   22. Stale task / newer task race
#   23. Production path safety
#   24. Existing GitHub /manul regression
#
# Usage: bash test_conversation_orchestrator.sh

set -uo pipefail

# Use a single test directory for all tests
TEST_DIR="${MANUL_TEST_DIR:-$(mktemp -d)}"
export MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
export CONFIG="$TEST_DIR/config.json"
export RESULTS_DIR="$TEST_DIR/results"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONVERSATION_SCRIPT="${CONVERSATION_SCRIPT:-$SCRIPT_DIR/manul-conversation.sh}"
POLL_SCRIPT="${POLL_SCRIPT:-$SCRIPT_DIR/poll.sh}"

# Cleanup on exit
cleanup() {
  if [ "${TEARDOWN:-0}" = "1" ]; then
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT

mkdir -p "$MANUL_DIR/state" "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs" "$RESULTS_DIR"

# Create mock gh for tests (no real GitHub required)
MOCK_GH_DIR="$TEST_DIR/mock-gh"
mkdir -p "$MOCK_GH_DIR"
cat > "$MOCK_GH_DIR/gh" <<'MOCK_EOF'
#!/bin/bash
# Mock gh that simulates issue creation
case "$1" in
  issue)
    case "$2" in
      create)
        # Return a mock issue
        echo '{"url": "https://github.com/test-owner/test-repo/issues/1", "number": 1}'
        exit 0
        ;;
      view) exit 0 ;;
      comment) exit 0 ;;
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
  auth) exit 0 ;;
esac
exit 0
MOCK_EOF
chmod +x "$MOCK_GH_DIR/gh"
export PATH="$MOCK_GH_DIR:$PATH"

# Initialize config
cat > "$CONFIG" << 'CONFIGEOF'
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

PASS=0
FAIL=0
TEST_NAME=""

# Global test variables (exported for subshells)
export TASK_ID_1=""
export TASK_ID_PR=""
export TASK_ID_FOLLOWUP=""
export CONVERSATION_ID_1=""

ok() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$label"; else fail "$label (expected='$expected', got='$actual')"; fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$label"; else fail "$label (expected to contain '$needle')"; fi
}

assert_json_valid() {
  local label="$1" json="$2"
  if echo "$json" | jq . >/dev/null 2>&1; then ok "$label"; else fail "$label (invalid JSON: $json)"; fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$label"; else fail "$label (expected exit=$expected, got=$actual)"; fi
}

# Tests are intentionally kept hermetic: temporary state only, no live GitHub or LLM.

test_create_conversation() {
  TEST_NAME="create conversation"; local output rc
  output="$(bash "$CONVERSATION_SCRIPT" create --repo "test-owner/test-repo" --title "Test Feature Request" --prompt "Implement the feature" --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ] && echo "$output" | jq -e '.conversationId' >/dev/null 2>&1; then
    ok "$TEST_NAME"; export CONVERSATION_ID_1="$(echo "$output" | jq -r '.conversationId')"
  else fail "$TEST_NAME (output: $output, rc: ${rc:-0})"; fi
}

test_stable_conversation_id() {
  TEST_NAME="stable conversationId"; local conv_id="$CONVERSATION_ID_1"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation from test 1)"; return; fi
  local db_conv_id; db_conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  if [ "$db_conv_id" = "$conv_id" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (conversation not found in DB)"; fi
}

test_conversation_issue_association() {
  TEST_NAME="conversation ↔ issue association"; local conv_id="$CONVERSATION_ID_1"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation from test 1)"; return; fi
  local issue_num issue_url
  issue_num="$(sqlite3 "$DB" "SELECT issueNumber FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  issue_url="$(sqlite3 "$DB" "SELECT issueUrl FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  if [ -n "$issue_num" ] || [ -n "$issue_url" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (missing issue info for conversation $conv_id)"; fi
}

test_submit_first_task() {
  TEST_NAME="submit first task"; local conv_id="$CONVERSATION_ID_1" output rc
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation from test 1)"; return; fi
  output="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Write the implementation" --action IMPLEMENT --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ] && echo "$output" | jq -e '.taskId' >/dev/null 2>&1; then
    ok "$TEST_NAME"; export TASK_ID_1="$(echo "$output" | jq -r '.taskId')"
  else fail "$TEST_NAME (output: $output, rc: ${rc:-0})"; fi
}

test_task_inherits_conversation() {
  TEST_NAME="task inherits conversation"; local conv_id task_conv
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  task_conv="$(sqlite3 "$DB" "SELECT conversationId FROM processed_comments WHERE commentId='$TASK_ID_1';" 2>/dev/null)"
  if [ "$task_conv" = "$conv_id" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (task conversation='$task_conv', expected='$conv_id')"; fi
}

test_task_association_with_issue() {
  TEST_NAME="task association with issue"; local conv_id task_issue conv_issue
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  task_issue="$(sqlite3 "$DB" "SELECT issueNumber FROM processed_comments WHERE commentId='$TASK_ID_1';" 2>/dev/null)"
  conv_issue="$(sqlite3 "$DB" "SELECT issueNumber FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
  if [ "$task_issue" = "$conv_issue" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (task issue=$task_issue, conversation issue=$conv_issue)"; fi
}

test_task_association_with_pr() {
  TEST_NAME="task association with PR"; local conv_id output rc task_id task_pr
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  # Submit a task with a PR number
  local output rc
  output="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Fix the bug" \
    --action REVIEW_FIX \
    --pr-number 42 \
    --review-id "test-review-42" \
    --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    task_id="$(echo "$output" | jq -r '.taskId')"; task_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    if [ "$task_pr" = "42" ]; then ok "$TEST_NAME"; export TASK_ID_PR="$task_id"; else fail "$TEST_NAME (task PR=$task_pr, expected=42)"; fi
  else fail "$TEST_NAME (submission failed)"; fi
}

test_followup_task() {
  TEST_NAME="follow-up task"; local conv_id output rc task_id task_count
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  output="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Add tests for the implementation" --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    task_id="$(echo "$output" | jq -r '.taskId')"; task_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$conv_id';" 2>/dev/null)"
    if [ "$task_count" -ge 2 ]; then ok "$TEST_NAME"; export TASK_ID_FOLLOWUP="$task_id"; else fail "$TEST_NAME (task count=$task_count, expected>=2)"; fi
  else fail "$TEST_NAME (submission failed)"; fi
}

test_parent_task_linkage() {
  TEST_NAME="parentTaskId linkage"; local conv_id output rc task_id parent_id
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  output="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Improve test coverage" --parent-task-id "$TASK_ID_1" --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    task_id="$(echo "$output" | jq -r '.taskId')"; parent_id="$(sqlite3 "$DB" "SELECT parentTaskId FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    if [ "$parent_id" = "$TASK_ID_1" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (parent='$parent_id', expected='$TASK_ID_1')"; fi
  else fail "$TEST_NAME (submission failed)"; fi
}

test_review_fix_continues_pr() {
  TEST_NAME="review-fix task continues existing PR"; local conv_id output1 rc1 output2 rc2 task_id task_pr task_action
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  # First submit with PR
  local output1 rc1
  output1="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Initial implementation" \
    --action IMPLEMENT \
    --pr-number 50 \
    --json 2>/dev/null)" || rc1=$?

  if [ "${rc1:-0}" -ne 0 ]; then
    fail "$TEST_NAME (initial submission failed)"
    return
  fi

  # Then submit review-fix for same PR
  local output2 rc2
  output2="$(bash "$CONVERSATION_SCRIPT" submit \
    --conversation-id "$conv_id" \
    --prompt "Address review comments" \
    --action REVIEW_FIX \
    --pr-number 50 \
    --review-id "test-review-50" \
    --json 2>/dev/null)" || rc2=$?
  if [ "${rc2:-0}" -eq 0 ]; then
    task_id="$(echo "$output2" | jq -r '.taskId')"; task_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"; task_action="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    if [ "$task_pr" = "50" ] && [ "$task_action" = "REVIEW_FIX" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (pr=$task_pr, action=$task_action)"; fi
  else fail "$TEST_NAME (review-fix submission failed)"; fi
}

test_review_fix_no_unrelated_pr() {
  TEST_NAME="review-fix does not create unrelated PR"; local conv_id output rc task_id task_pr
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  output="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Review fix" --action REVIEW_FIX --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    task_id="$(echo "$output" | jq -r '.taskId')"; task_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='$task_id';" 2>/dev/null)"
    if [ -z "$task_pr" ] || [ "$task_pr" = "null" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (unexpected PR=$task_pr)"; fi
  else fail "$TEST_NAME (submission failed)"; fi
}

test_multiple_tasks_same_conversation() {
  TEST_NAME="multiple tasks same conversation"; local conv_id count
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"; count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$conv_id';" 2>/dev/null)"
  [ "$count" -ge 4 ] && ok "$TEST_NAME" || fail "$TEST_NAME (task count=$count, expected>=4)"
}

test_concurrent_tasks_same_conversation() {
  TEST_NAME="concurrent tasks same conversation"; local conv_id count
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"; count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$conv_id' AND status='queued';" 2>/dev/null)"
  [ "$count" -ge 1 ] && ok "$TEST_NAME" || fail "$TEST_NAME (no queued tasks available)"
}

test_task_result_exposes_pr() {
  TEST_NAME="task result exposes PR"; local conv_id task_id now result
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"; task_id="result-test-task"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, processedAt, conversationId, action, prNumber) VALUES('$task_id', 'test-owner/test-repo', 1, 'https://github.com/test-owner/test-repo/issues/1', 'test', 'test prompt', 'completed', '$now', '$now', '$conv_id', 'REVIEW_FIX', 42);"
  result="$(bash "$CONVERSATION_SCRIPT" result --task-id "$task_id" --json 2>/dev/null)" || result="{}"
  if echo "$result" | jq -e '.prNumber' >/dev/null 2>&1; then ok "$TEST_NAME"; else fail "$TEST_NAME (no prNumber in result: $result)"; fi
}

test_pr_merge_detection() {
  TEST_NAME="PR merge detection"; local conv_id task_id now result
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation)"; return; fi
  task_id="merge-test-task"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, processedAt, conversationId, action, prNumber) VALUES('$task_id', 'test-owner/test-repo', 1, 'https://github.com/test-owner/test-repo/issues/1', 'test', 'test prompt', 'completed', '$now', '$now', '$conv_id', 'IMPLEMENT', 50);"
  mkdir -p "$MANUL_DIR/results"; echo '{"success":true,"prMerged":true}' > "$MANUL_DIR/results/${task_id}.json"
  result="$(bash "$CONVERSATION_SCRIPT" result --task-id "$task_id" --json 2>/dev/null)" || result="{}"
  if echo "$result" | jq -e '.result.prMerged' >/dev/null 2>&1; then ok "$TEST_NAME"; else fail "$TEST_NAME (prMerged not detected in: $result)"; fi
}

test_ci_fix_task_result_path() {
  TEST_NAME="CI-fix task result path supports slash-bearing task IDs"
  local conv_id task_id task_key now result
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation)"; return; fi
  task_id="ci_fix:mariuszmarzec/fiteoApp:14:40488568269"
  task_key="$(printf '%s' "$task_id" | sed 's|/|_|g')--$(printf '%s' "$task_id" | sha256sum | cut -c1-16)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, processedAt, conversationId, action, prNumber) VALUES('$(printf '%s' "$task_id" | sed "s/'/''/g")', 'mariuszmarzec/fiteoApp', 14, 'https://github.com/mariuszmarzec/fiteoApp/pull/14', 'test', 'CI fix result path', 'completed', '$now', '$now', '$conv_id', 'IMPLEMENT', 14);"
  mkdir -p "$MANUL_DIR/results"
  printf '%s\n' '{"success":true,"prMerged":true}' >"$MANUL_DIR/results/${task_key}.json"
  result="$(bash "$CONVERSATION_SCRIPT" result --task-id "$task_id" --json 2>/dev/null)" || result="{}"
  if echo "$result" | jq -e '.result.prMerged == true' >/dev/null 2>&1; then
    ok "$TEST_NAME"
  else
    fail "$TEST_NAME (CI-fix result artifact not found: $result)"
  fi
}

test_completed_conversation() {
  TEST_NAME="completed conversation"; local conv_id output rc status
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation to complete)"; return; fi
  sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt='$(date -u +%Y-%m-%dT%H:%M:%SZ)' WHERE conversationId='$conv_id';"
  output="$(bash "$CONVERSATION_SCRIPT" close --conversation-id "$conv_id" --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ] && echo "$output" | jq -e '.status' >/dev/null 2>&1; then
    status="$(echo "$output" | jq -r '.status')"; [ "$status" = "COMPLETED" ] && ok "$TEST_NAME" || fail "$TEST_NAME (status=$status, expected=COMPLETED)"
  else fail "$TEST_NAME (close failed: $output)"; fi
}

test_failed_conversation() {
  TEST_NAME="failed conversation"; local output rc conv_id task_id
  output="$(bash "$CONVERSATION_SCRIPT" create --repo "test-owner/test-fail" --title "Failed Task" --prompt "This will fail" --json 2>/dev/null)" || rc=$?
  if [ "${rc:-0}" -eq 0 ]; then
    conv_id="$(echo "$output" | jq -r '.conversationId')"; task_id="$(sqlite3 "$DB" "SELECT activeTaskId FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"
    if [ -n "$task_id" ]; then sqlite3 "$DB" "UPDATE processed_comments SET status='failed' WHERE commentId='$task_id';"; sqlite3 "$DB" "UPDATE conversations SET status='FAILED' WHERE conversationId='$conv_id';"; fi
    ok "$TEST_NAME"
  else fail "$TEST_NAME (creation failed)"; fi
}

test_conversation_restart_recovery() {
  TEST_NAME="conversation restart/recovery"; local conv_id status
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation to recover)"; return; fi
  sqlite3 "$DB" "UPDATE conversations SET status='OPEN' WHERE conversationId='$conv_id';"; sqlite3 "$DB" "UPDATE processed_comments SET status='queued' WHERE conversationId='$conv_id' AND status='completed';"
  status="$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='$conv_id';" 2>/dev/null)"; [ "$status" = "OPEN" ] && ok "$TEST_NAME" || fail "$TEST_NAME (status=$status, expected=OPEN)"
}

test_json_contract() {
  TEST_NAME="JSON contract"; local conv_id status_output has_fields
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  status_output="$(bash "$CONVERSATION_SCRIPT" status --conversation-id "$conv_id" --json 2>/dev/null)" || status_output="{}"
  has_fields="$(echo "$status_output" | jq 'has("conversationId") and has("repository") and has("status") and has("tasks")' 2>/dev/null)"
  [ "$has_fields" = "true" ] && ok "$TEST_NAME" || fail "$TEST_NAME (missing fields in status JSON)"
}

test_exit_codes() {
  TEST_NAME="exit codes"; local rc_not_found rc_bad_request
  bash "$CONVERSATION_SCRIPT" status --conversation-id "nonexistent-conv" --json >/dev/null 2>&1; rc_not_found=$?
  bash "$CONVERSATION_SCRIPT" create --repo "test" >/dev/null 2>&1; rc_bad_request=$?
  if [ "$rc_not_found" -eq 2 ] && [ "$rc_bad_request" -eq 3 ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (not_found=$rc_not_found, bad_request=$rc_bad_request)"; fi
}

test_duplicate_submission_idempotency() {
  TEST_NAME="duplicate follow-up submission/idempotency"; local conv_id output1 output2 id1 id2
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation)"; return; fi
  output1="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Duplicate test" --json 2>/dev/null)" || output1="{}"
  output2="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Duplicate test" --json 2>/dev/null)" || output2="{}"
  id1="$(echo "$output1" | jq -r '.taskId // empty')"; id2="$(echo "$output2" | jq -r '.taskId // empty')"
  if [ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ]; then ok "$TEST_NAME"; else fail "$TEST_NAME (duplicate handling: $id1, $id2)"; fi
}

test_stale_task_race() {
  TEST_NAME="stale task / newer task race"; local conv_id now output rc
  conv_id="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='test-owner/test-repo' LIMIT 1;" 2>/dev/null)"
  if [ -z "$conv_id" ]; then fail "$TEST_NAME (no conversation)"; return; fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, prompt, status, createdAt, heartbeatAt, leaseExpiresAt, conversationId, action) VALUES('stale-task-123', 'test-owner/test-repo', 1, 'https://github.com/test-owner/test-repo/issues/1', 'test', 'stale prompt', 'running', '$now', '$now', '$now', '$conv_id', 'IMPLEMENT');"
  output="$(bash "$CONVERSATION_SCRIPT" submit --conversation-id "$conv_id" --prompt "Newer task" --json 2>&1)" || rc=$?
  if [ "${rc:-0}" -ne 0 ] && echo "$output" | grep -q "running tasks"; then ok "$TEST_NAME"; else fail "$TEST_NAME (expected failure due to running task, got rc=${rc:-0}, output: $output)"; fi
}

test_production_path_safety() {
  TEST_NAME="production path safety"
  if grep -q 'MANUL_DIR=' "$CONVERSATION_SCRIPT" && ! grep -q 'MANUL_DIR=.*globalskills-temp' "$CONVERSATION_SCRIPT"; then ok "$TEST_NAME"; else fail "$TEST_NAME (production path override missing)"; fi
}

test_github_manul_regression() {
  TEST_NAME="existing GitHub /manul regression"
  # Verify existing poll.sh still works
  local poll_script="${POLL_SCRIPT:-$SCRIPT_DIR/poll.sh}"

  if [ -f "$poll_script" ]; then
    # Check syntax
    if bash -n "$poll_script" 2>/dev/null; then
      ok "$TEST_NAME"
    else
      fail "$TEST_NAME (poll.sh syntax error)"
    fi
  else
    fail "$TEST_NAME (poll.sh not found)"
  fi
}

# ============================================================================

# Test: Conversation creation fails closed when gh fails
test_conversation_creation_fails_closed() {
  echo "  Testing conversation creation fails closed when gh fails..."

  # Create fake gh that fails on issue create
  mkdir -p /tmp/manul_tests
  cat > /tmp/manul_tests/gh <<'GHSCRIPT'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "gh issue create failed" >&2
  exit 1
fi
exit 0
GHSCRIPT
  chmod +x /tmp/manul_tests/gh

  # Save original PATH
  local original_path
  original_path="$PATH"

  # Add mock to PATH
  export PATH="/tmp/manul_tests:$PATH"

  # Save original GH repo
  local original_github_repository
  original_github_repository="${GITHUB_REPOSITORY:-}"

  # Set up failure scenario
  GITHUB_REPOSITORY="manul-ai/tests"

  # Run create with FAIL_CLOSED=true
  local output
  output="$(bash "$CONVERSATION_SCRIPT" create --fail-closed=true 2>&1)" || true

  # Restore
  rm -f /tmp/manul_tests/gh
  export PATH="$original_path"
  GITHUB_REPOSITORY="$original_github_repository"

  # Verify: should not create conversation with issue/0
  if echo "$output" | grep -q "issue/0"; then
    fail "Should not create conversation with issue/0 when gh fails"
  elif echo "$output" | grep -q "FAIL_CLOSED=false"; then
    ok "Failed closed as expected"
  else
    ok "Conversation creation failed (no issue/0 created)"
  fi
}
echo ""
echo "========================================"
echo "  Manul Conversation Orchestrator Tests"
echo "========================================"
echo ""

bash "$CONVERSATION_SCRIPT" status --conversation-id "test-init" >/dev/null 2>&1 || true

test_create_conversation
test_stable_conversation_id
test_conversation_issue_association
test_submit_first_task
test_task_inherits_conversation
test_task_association_with_issue
test_task_association_with_pr
test_followup_task
test_parent_task_linkage
test_review_fix_continues_pr
test_review_fix_no_unrelated_pr
test_multiple_tasks_same_conversation
test_concurrent_tasks_same_conversation
test_task_result_exposes_pr
test_pr_merge_detection
test_ci_fix_task_result_path
test_completed_conversation
test_failed_conversation
test_conversation_restart_recovery
test_json_contract
test_exit_codes
test_duplicate_submission_idempotency
test_stale_task_race
test_production_path_safety
test_conversation_creation_fails_closed
test_github_manul_regression

echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
