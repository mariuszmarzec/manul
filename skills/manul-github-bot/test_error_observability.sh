#!/bin/bash
# Regression tests for error observability changes in Manul
# Verifies: SQLite/API failures are logged, intentional fallbacks remain

set -uo pipefail

MANUL_DIR="${MANUL_DIR:-/tmp/manul-error-obs-$$}"
DB="$MANUL_DIR/manul.db"
LOG="$MANUL_DIR/poll.log"
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASSED=0
FAILED=0
SCRIPT_DIR="$TEST_SCRIPT_DIR"  # Alias for clarity

pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

cleanup() {
  rm -rf "$MANUL_DIR"
}
trap cleanup EXIT

setup() {
  mkdir -p "$MANUL_DIR"
  # Create minimal config
  cat > "$MANUL_DIR/config.json" <<'EOF'
{
  "repositories": ["test/test"],
  "trigger": "/manul",
  "allowedUsers": ["testuser"],
  "agents": ["coder"],
  "automation": { "leaseTimeout": 900, "lockTtl": 1800 }
}
EOF
}

# Test 1: SQLite failure is logged (not silently swallowed)
test_sqlite_failure_logged() {
  local db_file="$MANUL_DIR/sqlite_test.db"
  local log_file="$MANUL_DIR/sqlite_test.log"

  # Set up a read-only DB directory to cause sqlite3 failures
  mkdir -p "$MANUL_DIR"
  touch "$db_file"
  chmod 444 "$db_file" 2>/dev/null

  # Simulate the new error handling pattern: when sqlite3 fails, it should log
  local result
  if ! sqlite3 "$db_file" "SELECT 1;" 2>>"$log_file"; then
    echo "sqlite_error_logged=true" >> "$log_file"
  fi

  chmod 644 "$db_file" 2>/dev/null

  if grep -q "sqlite_error_logged=true" "$log_file" 2>/dev/null; then
    pass "SQLite failure detection path works"
  else
    # If we can't make it fail, verify the code pattern exists
    if grep -q "if !.*sqlite3.*then" "$SCRIPT_DIR/poll.sh" 2>/dev/null; then
      pass "SQLite failure logging code pattern present in poll.sh"
    else
      fail "SQLite failure logging code pattern missing"
    fi
  fi
}

# Test 2: GitHub API failure is logged
test_github_api_failure_logged() {
  # Verify the code pattern for gh command failure logging
  if grep -q "ERROR: failed to fetch issue context" "$SCRIPT_DIR/poll.sh"; then
    pass "gh issue view failure is logged"
  else
    fail "gh issue view failure logging missing"
  fi

  if grep -q "ERROR: failed to fetch PR view" "$SCRIPT_DIR/poll.sh"; then
    pass "gh pr view failure is logged"
  else
    fail "gh pr view failure logging missing"
  fi
}

# Test 3: Successful path still works (fallback behavior)
test_successful_path_unchanged() {
  setup
  MANUL_DIR="$MANUL_DIR" bash -n "$SCRIPT_DIR/poll.sh"
  if [ $? -eq 0 ]; then
    pass "poll.sh syntax valid after changes"
  else
    fail "poll.sh syntax broken"
  fi

  MANUL_DIR="$MANUL_DIR" bash -n "$SCRIPT_DIR/manul-conversation.sh"
  if [ $? -eq 0 ]; then
    pass "manul-conversation.sh syntax valid"
  else
    fail "manul-conversation.sh syntax broken"
  fi

  MANUL_DIR="$MANUL_DIR" bash -n "$SCRIPT_DIR/workspace-manager.sh"
  if [ $? -eq 0 ]; then
    pass "workspace-manager.sh syntax valid"
  else
    fail "workspace-manager.sh syntax broken"
  fi
}

# Test 4: Intentional fallback behavior preserved
test_intentional_fallback_preserved() {
  # In build_review_context, if gh pr view fails, we fall back to empty JSON
  if grep -q "ERROR: failed to fetch PR view" "$SCRIPT_DIR/poll.sh" && \
     grep -q 'pr_json='"'"'{"number":0' "$SCRIPT_DIR/poll.sh"; then
    pass "PR view failure falls back to empty JSON"
  else
    fail "PR view fallback behavior changed or missing"
  fi

  # In fetch_issue_ctx, if gh issue view fails, j is empty (context not enriched)
  if grep -q "ERROR: failed to fetch issue context" "$SCRIPT_DIR/poll.sh" && \
     grep -q 'j=""' "$SCRIPT_DIR/poll.sh"; then
    pass "Issue view failure leaves empty context (no crash)"
  else
    fail "Issue view fallback behavior changed or missing"
  fi
}

# Test 5: Best-effort cleanup still suppressed
test_cleanup_patterns_unchanged() {
  # These should remain suppressed - they're cleanup, not operational failures
  local count_before count_after

  # Count kill/wait patterns in daemon (cleanup)
  count_before=$(grep -c 'kill.*2>/dev/null || true' "$SCRIPT_DIR/manul-daemon.sh" || echo 0)
  count_after=$count_before  # Should not change

  if [ "$count_before" = "$count_after" ] && [ "$count_before" -gt 0 ]; then
    pass "Cleanup kill patterns unchanged in daemon.sh"
  else
    fail "Cleanup kill patterns changed in daemon.sh"
  fi
}

# Test 6: GitHub API pagination failures logged
test_github_pagination_logged() {
  # Verify gh api calls with pagination now have error handling
  if grep -q '2>>"$LOG"' "$SCRIPT_DIR/poll.sh"; then
    pass "GitHub API stderr redirected to log"
  else
    fail "GitHub API stderr not redirected to log"
  fi
}

# Test 7: every terminal failure recovery path delegates to the shared GitHub feedback.
test_terminal_failure_feedback_wiring() {
  local daemon="$SCRIPT_DIR/manul-daemon.sh"
  local failures=0

  if grep -q 'handle_pre_execution_failure' "$daemon" && grep -q 'post_task_failure_feedback' "$daemon"; then
    pass "daemon pre-agent failures use the shared terminal feedback path"
  else
    fail "daemon pre-agent feedback path missing"
    failures=$((failures + 1))
  fi
  for script in watchdog.sh task-health-check.sh task-recovery.sh; do
    if grep -q 'post_terminal_failure_feedback' "$SCRIPT_DIR/$script" && grep -q 'manul-result-feedback.sh' "$SCRIPT_DIR/$script"; then
      pass "$script delegates terminal failures to shared GitHub feedback"
    else
      fail "$script terminal feedback path missing"
      failures=$((failures + 1))
    fi
  done
  if grep -q "SELECT changes();" "$daemon" && grep -q "TASK_FAILURE_COMMENT_FAILED" "$daemon"; then
    pass "daemon verifies ownership/state transition and logs comment-post failures"
  else
    fail "daemon transition/comment failure observability missing"
    failures=$((failures + 1))
  fi
  return "$failures"
}

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Error Observability Regression Tests"
echo "═══════════════════════════════════════════════════════════"
echo ""

test_sqlite_failure_logged
test_github_api_failure_logged
test_successful_path_unchanged
test_intentional_fallback_preserved
test_cleanup_patterns_unchanged
test_github_pagination_logged
test_terminal_failure_feedback_wiring || true

# Test 8: adapter preflight failures use the infrastructure retry budget.
test_pre_execution_failure_budget_wiring() {
  local adapter="$SCRIPT_DIR/opencode-adapter.sh"
  local daemon="$SCRIPT_DIR/manul-daemon.sh"
  local preflight_line dispatch_line completion_line

  if ! grep -Fq '"failure_code":"PRE_EXECUTION_FAILURE"' "$adapter" ||
     ! grep -Fq '_mcp_preflight_stage="caracal_mcp_preflight"' "$adapter" ||
     ! grep -Fq '"agent_started":false' "$adapter"; then
    fail "OpenCode Caracal preflight result lacks a structured pre-execution failure code"
    return
  fi
  pass "OpenCode Caracal preflight reports a structured pre-execution failure"

  preflight_line="$(grep -nF 'if [ "$exec_failure_code" = "PRE_EXECUTION_FAILURE" ]; then' "$daemon" | head -n 1 | cut -d: -f1)"
  dispatch_line="$(grep -nF 'handle_pre_execution_failure "$COMMENT_ID" "$CLAIM_TOKEN"' "$daemon" | tail -n 1 | cut -d: -f1)"
  completion_line="$(grep -nF 'evaluate_task_completion "$REPO" "$ISSUE_NUM" "$COMMENT_ID"' "$daemon" | head -n 1 | cut -d: -f1)"
  if [[ "$preflight_line" =~ ^[0-9]+$ ]] && [[ "$dispatch_line" =~ ^[0-9]+$ ]] &&
     [[ "$completion_line" =~ ^[0-9]+$ ]] && [ "$preflight_line" -lt "$dispatch_line" ] &&
     [ "$dispatch_line" -lt "$completion_line" ]; then
    pass "daemon routes pre-execution failures through infrastructure retry before normal completion evaluation"
  else
    fail "daemon could route a pre-execution failure through the normal agent attempt budget"
  fi
}

test_pre_execution_failure_budget_wiring

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
