#!/bin/bash
# test_manul_cli.sh - Comprehensive tests for manul-submit/status/result/wait CLI
#
# Usage:
#   bash test_manul_cli.sh [--dir DIR]

set -euo pipefail

# Configuration
TEST_DIR="${1:-$(mktemp -d)}"
MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Counters
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Helpers
log() {
  printf "${YELLOW}  %-60s${NC}\n" "$1"
}

pass() {
  PASS=$((PASS + 1))
  printf "${GREEN}  ✓ PASS${NC}: %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "${RED}  ✗ FAIL${NC}: %s\n" "$1"
  if [ -n "${2:-}" ]; then
    printf "    Expected: %s\n" "$2"
    printf "    Got:      %s\n" "$3"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "$expected" "$actual"
  fi
}

assert_json_field() {
  local desc="$1" json="$2" field="$3" expected="$4"
  local actual
  actual="$(printf '%s' "$json" | jq -r ".$field" 2>/dev/null || echo "missing")"
  assert_eq "$desc" "$expected" "$actual"
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "exit $expected" "exit $actual"
  fi
}

init_db() {
  mkdir -p "$MANUL_DIR/state"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT,
    author TEXT,
    agent TEXT,
    prompt TEXT,
    context TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT,
    conversationId TEXT,
    parentTaskId TEXT,
    workspaceId TEXT,
    heartbeatAt TEXT,
    leaseExpiresAt TEXT,
    claimToken TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    workerPid INTEGER,
    nextAttemptAt TEXT,
    baseId TEXT,
    taskSourceType TEXT,
    taskSourceId TEXT
  );"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS submission_claims (
    baseId TEXT PRIMARY KEY,
    commentId TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    createdAt TEXT
  );"
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);"
}

# ============================================================
# Section 1: manul-submit.sh tests
# ============================================================

test_task_recovery_retry() {
  echo ""
  echo "=== task-recovery retry tests ==="

  sqlite3 "$DB" "DELETE FROM processed_comments;"
  sqlite3 "$DB" "INSERT INTO processed_comments (commentId, repository, issueNumber, status, attempts, createdAt, nextAttemptAt) VALUES ('failed-retry','owner/repo',1,'failed',3,datetime('now'),datetime('now','+1 hour'));"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/task-recovery.sh" --retry failed-retry 2>&1)
  STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='failed-retry';")
  ATTEMPTS=$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='failed-retry';")
  NEXT_ATTEMPT=$(sqlite3 "$DB" "SELECT nextAttemptAt FROM processed_comments WHERE commentId='failed-retry';")
  assert_eq "Retry failed task requeues it" "queued" "$STATUS"
  assert_eq "Retry failed task resets attempts" "0" "$ATTEMPTS"
  if [ -n "$NEXT_ATTEMPT" ]; then
    pass "Retry failed task schedules immediate attempt"
  else
    fail "Retry failed task schedules immediate attempt" "timestamp" "$NEXT_ATTEMPT"
  fi

  sqlite3 "$DB" "INSERT INTO processed_comments (commentId, repository, issueNumber, status, attempts, createdAt) VALUES ('failed-retry-2','owner/repo',2,'failed',5,datetime('now'));"
  printf 'yes\n' | MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/task-recovery.sh" --reset-all=failed > /dev/null 2>&1
  STATUS2=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='failed-retry-2';")
  ATTEMPTS2=$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='failed-retry-2';")
  assert_eq "reset-all=failed requeues failed task" "queued" "$STATUS2"
  assert_eq "reset-all=failed resets attempts" "0" "$ATTEMPTS2"
}

test_submit() {
  echo ""
  echo "=== manul-submit.sh tests ==="
  
  # Test 1: Basic submission
  log "Basic submission with --prompt"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 42 --prompt "Fix bug" --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.commentId' > /dev/null 2>&1; then
    pass "Basic submission creates task"
    TASK_ID="$(printf '%s' "$OUTPUT" | jq -r '.commentId')"
  else
    fail "Basic submission creates task" "JSON with commentId" "$OUTPUT"
  fi
  
  # Test 2: Stdin prompt
  log "Submission via stdin"
  OUTPUT=$(printf 'Fix bug from stdin' | MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 43 --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.commentId' > /dev/null 2>&1; then
    pass "Stdin prompt submission"
  else
    fail "Stdin prompt submission" "JSON with commentId" "$OUTPUT"
  fi
  
  # Test 3: Missing --repo
  log "Missing --repo argument"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --issue 1 --prompt "test" > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Missing --repo returns error"
  else
    fail "Missing --repo returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 4: Missing --issue
  log "Missing --issue argument"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --prompt "test" > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Missing --issue returns error"
  else
    fail "Missing --issue returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 5: Invalid repo format
  log "Invalid repo format"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo "invalid" --issue 1 --prompt "test" > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Invalid repo format returns error"
  else
    fail "Invalid repo format returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 6: Idempotency - same params return same task
  log "Idempotent submission"
  OUTPUT1=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 44 --prompt "Idempotent test" --json 2>&1)
  TASK_ID1="$(printf '%s' "$OUTPUT1" | jq -r '.commentId')"

  # Wait a moment to ensure different timestamp would produce different ID
  sleep 1

  OUTPUT2=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 44 --prompt "Idempotent test" --json 2>&1)
  TASK_ID2="$(printf '%s' "$OUTPUT2" | jq -r '.commentId')"

  # Idempotency: same params should return SAME task ID
  if [ -n "$TASK_ID1" ] && [ -n "$TASK_ID2" ] && [ "$TASK_ID1" = "$TASK_ID2" ]; then
    pass "Idempotent submission returns same task ID"
  else
    fail "Idempotent submission returns same task ID" "$TASK_ID1" "$TASK_ID2"
  fi
  
  # Test 7: Custom conversation ID
  log "Custom conversation ID"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 45 --prompt "Conv test" \
    --conversation my-conv-id --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.conversationId == "my-conv-id"' | grep -q true; then
    pass "Custom conversation ID preserved"
  else
    fail "Custom conversation ID preserved" "my-conv-id" "$(printf '%s' "$OUTPUT" | jq -r '.conversationId')"
  fi

  # Test 7b: Deterministic conversation ID format when --conversation omitted
  log "Deterministic conversation ID format (conv-<repo>-issue-<issue>)"
  # Clear previous DB entries
  sqlite3 "$DB" "DELETE FROM processed_comments;"
  # Submit twice with same repo/issue but no --conversation flag
  OUTPUT1=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 45 --prompt "Det conv test" --json 2>&1)
  OUTPUT2=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 45 --prompt "Det conv test" --json 2>&1)
  CONV1="$(printf '%s' "$OUTPUT1" | jq -r '.conversationId')"
  CONV2="$(printf '%s' "$OUTPUT2" | jq -r '.conversationId')"
  # Both should generate the same conv-owner/repo-issue-45 format
  if [ "$CONV1" = "conv-owner/repo-issue-45" ] && [ "$CONV2" = "conv-owner/repo-issue-45" ]; then
    pass "Deterministic conversation ID generated correctly (conv-owner/repo-issue-45)"
  else
    fail "Deterministic conversation ID generated correctly" "conv-owner/repo-issue-45 both" "$CONV1 / $CONV2"
  fi
  # Same conversation ID for same params
  if [ "$CONV1" = "$CONV2" ]; then
    pass "Same params yield same conversation ID"
  else
    fail "Same params yield same conversation ID" "$CONV1" "$CONV2"
  fi
  
  # Test 8: Parent task ID
  log "Parent task ID"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 46 --prompt "Subtask" \
    --parent cli-parent-123 --json 2>&1)
  if [ $? -eq 0 ]; then
    pass "Parent task ID accepted"
  else
    fail "Parent task ID accepted" "exit 0" "exit $?"
  fi
  
  # Test 9: Agent name
  log "Custom agent name"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 47 --prompt "Agent test" \
    --agent custom-agent --json 2>&1)
  if [ $? -eq 0 ]; then
    pass "Custom agent name accepted"
  else
    fail "Custom agent name accepted" "exit 0" "exit $?"
  fi
  
  # Test 10: Text output format
  log "Text output format"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 48 --prompt "Text output test" 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "commentId:" && printf '%s' "$OUTPUT" | grep -q "queued"; then
    pass "Text output format works"
  else
    fail "Text output format works" "commentId and queued in output" "$OUTPUT"
  fi
}

# ============================================================
# Section 2: manul-status.sh tests
# ============================================================
test_status() {
  echo ""
  echo "=== manul-status.sh tests ==="
  
  # Test 1: List all tasks
  log "List all tasks"
  # First create some tasks
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 1 --prompt "Status test 1" > /dev/null 2>&1
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 2 --prompt "Status test 2" > /dev/null 2>&1

  # Provider-backed tasks carry an explicit source type and source identity.
  sqlite3 "$DB" "
    INSERT INTO processed_comments
      (commentId, repository, issueNumber, status, attempts, createdAt, taskSourceType, taskSourceId)
    VALUES
      ('todo-local-status','owner/todo',0,'queued',0,datetime('now'),'todo_local_mcp','420@0123456789abcdef'),
      ('todo-remote-status','owner/fiteo',0,'queued',0,datetime('now'),'todo_remote_mcp','421@fedcba9876543210');
  "

  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e 'type == "array"' > /dev/null 2>&1; then
    COUNT=$(printf '%s' "$OUTPUT" | jq 'length')
    if [ "$COUNT" -ge 2 ]; then
      pass "List returns at least 2 tasks (found $COUNT)"
    else
      fail "List returns at least 2 tasks" ">=2" "$COUNT"
    fi
  else
    fail "List returns JSON array" "JSON array" "$OUTPUT"
  fi

  if printf '%s' "$OUTPUT" | jq -e '
    any(.[]; .taskId == "todo-local-status"
      and .source == "Todo Local"
      and .sourceId == "420"
      and .taskSourceType == "todo_local_mcp"
      and .taskSourceId == "420@0123456789abcdef")
    and any(.[]; .taskId == "todo-remote-status"
      and .source == "Todo Remote"
      and .sourceId == "421"
      and .taskSourceType == "todo_remote_mcp"
      and .taskSourceId == "421@fedcba9876543210")
  ' >/dev/null 2>&1; then
    pass "List JSON exposes local and remote Todo source names and record IDs"
  else
    fail "List JSON exposes local and remote Todo source names and record IDs" "Todo Local/420 and Todo Remote/421" "$OUTPUT"
  fi

  if printf '%s' "$OUTPUT" | jq -e 'all(.[]; has("preExecutionFailures") and .preExecutionFailures == 0 and .agentStartedAt == null)' >/dev/null 2>&1; then
    pass "List JSON defaults recovery diagnostics on a legacy DB without the columns"
  else
    fail "List JSON defaults recovery diagnostics on a legacy DB without the columns" "preExecutionFailures=0 and agentStartedAt=null" "$OUTPUT"
  fi

  # A queued row on the legacy schema has no agent start timestamp. Single-task
  # JSON must still expose the field explicitly as null.
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" todo-local-status --json 2>&1)
  if printf '%s' "$OUTPUT" | jq -e 'has("agentStartedAt") and .agentStartedAt == null' >/dev/null 2>&1; then
    pass "Single-task JSON exposes null agentStartedAt for a legacy queued task"
  else
    fail "Single-task JSON exposes null agentStartedAt for a legacy queued task" "agentStartedAt=null" "$OUTPUT"
  fi

  # Add the recovery columns and populate one task to verify list and single-task
  # output carries real values after migration.
  sqlite3 "$DB" "
    ALTER TABLE processed_comments ADD COLUMN preExecutionFailures INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE processed_comments ADD COLUMN agentStartedAt TEXT;
    UPDATE processed_comments
    SET preExecutionFailures=3, agentStartedAt='2026-10-30T14:00:00Z'
    WHERE commentId='todo-local-status';
  "
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --json 2>&1)
  if printf '%s' "$OUTPUT" | jq -e 'any(.[]; .taskId == "todo-local-status" and .preExecutionFailures == 3 and .agentStartedAt == "2026-10-30T14:00:00Z")' >/dev/null 2>&1; then
    pass "List JSON exposes pre-execution failures and agent start timestamp"
  else
    fail "List JSON exposes pre-execution failures and agent start timestamp" "preExecutionFailures=3 and agentStartedAt timestamp" "$OUTPUT"
  fi

  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" todo-local-status --json 2>&1)
  if printf '%s' "$OUTPUT" | jq -e '.preExecutionFailures == 3 and .agentStartedAt == "2026-10-30T14:00:00Z"' >/dev/null 2>&1; then
    pass "Single-task JSON exposes recovery diagnostics"
  else
    fail "Single-task JSON exposes recovery diagnostics" "preExecutionFailures=3 and agentStartedAt timestamp" "$OUTPUT"
  fi

  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "PRE-EXEC" \
    && printf '%s' "$OUTPUT" | grep -q "AGENT-STARTED" \
    && printf '%s' "$OUTPUT" | grep -q "2026-10-30T14:00:00Z"; then
    pass "Text list displays both recovery diagnostics"
  else
    fail "Text list displays both recovery diagnostics" "PRE-EXEC, AGENT-STARTED and timestamp" "$OUTPUT"
  fi

  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" todo-local-status 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "preExecutionFailures: 3" \
    && printf '%s' "$OUTPUT" | grep -q "agentStartedAt: 2026-10-30T14:00:00Z"; then
    pass "Single-task text displays both recovery diagnostics"
  else
    fail "Single-task text displays both recovery diagnostics" "both diagnostic fields" "$OUTPUT"
  fi

  # Test 2: Filter by status
  log "Filter by status"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --status queued --json 2>&1)
  if [ $? -eq 0 ]; then
    pass "Status filter works"
  else
    fail "Status filter works" "exit 0" "exit $?"
  fi
  
  # Test 3: Single task query
  log "Single task query"
  TASK_ID="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments ORDER BY createdAt DESC LIMIT 1;")"
  if [ -n "$TASK_ID" ]; then
    OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "$TASK_ID" --json 2>&1)
    if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e ".taskId == \"$TASK_ID\"" > /dev/null 2>&1; then
      pass "Single task query returns correct task"
    else
      fail "Single task query returns correct task" "correct taskId" "$OUTPUT"
    fi
  else
    fail "Single task query" "task exists" "no tasks in DB"
  fi
  
  # Test 4: Non-existent task
  log "Non-existent task query"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "nonexistent-task" --json > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Non-existent task returns error"
  else
    fail "Non-existent task returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 5: Empty list
  log "Empty list"
  sqlite3 "$DB" "DELETE FROM processed_comments;"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '. == []' > /dev/null 2>&1; then
    pass "Empty list returns empty array"
  else
    fail "Empty list returns empty array" "[]" "$OUTPUT"
  fi

  # Re-seed provider-backed tasks after the empty-list assertion.
  sqlite3 "$DB" "
    INSERT INTO processed_comments
      (commentId, repository, issueNumber, status, attempts, createdAt, taskSourceType, taskSourceId)
    VALUES
      ('todo-local-text-status','owner/todo',0,'queued',0,datetime('now'),'todo_local_mcp','420@0123456789abcdef'),
      ('todo-remote-text-status','owner/fiteo',0,'queued',0,datetime('now'),'todo_remote_mcp','421@fedcba9876543210');
  "

  # Test 6: Text list includes source type and provider task ID.
  log "Text list source columns"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "Todo Local" \
    && printf '%s' "$OUTPUT" | grep -q "Todo Remote" \
    && printf '%s' "$OUTPUT" | grep -qE '(^|[[:space:]])420([[:space:]]|$)' \
    && printf '%s' "$OUTPUT" | grep -qE '(^|[[:space:]])421([[:space:]]|$)' \
    && printf '%s' "$OUTPUT" | grep -q "owner/todo" \
    && ! printf '%s' "$OUTPUT" | grep -q "owner/todo#0"; then
    pass "Text list shows Todo Local/Remote and their provider task IDs"
  else
    fail "Text list shows Todo Local/Remote and their provider task IDs" "Todo Local 420 and Todo Remote 421" "$OUTPUT"
  fi

  # Regression: long identifiers and repository/source IDs must not shift columns.
  LONG_TASK_ID="review-fix-conv-mariuszmarzec/fiteoApp-issue-22-5712883306"
  LONG_REPO="mariuszmarzec/repository-name-longer-than-twenty-characters"
  LONG_SOURCE_ID="provider-source-record-id-longer-than-twenty-four-characters"
  LONG_CREATED="2026-10-30T13:28:12Z"
  sqlite3 "$DB" "
    INSERT INTO processed_comments
      (commentId, repository, issueNumber, status, attempts, createdAt, taskSourceType, taskSourceId)
    VALUES
      ('$LONG_TASK_ID','$LONG_REPO',42,'stale',3,'$LONG_CREATED','github_issues','$LONG_SOURCE_ID');
  "
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --list 2>&1)
  if printf '%s\n' "$OUTPUT" | awk \
    -v task_id="$LONG_TASK_ID" \
    -v repo_ref="$LONG_REPO#42" \
    -v source_id="$LONG_SOURCE_ID" \
    -v created="$LONG_CREATED" '
      NR == 1 {
        task_col = index($0, "TASK_ID")
        repo_col = index($0, "REPO#ISSUE")
        source_col = index($0, "SOURCE")
        source_id_col = index($0, "SOURCE_ID")
        status_col = index($0, "STATUS")
        attempts_col = index($0, "ATTEMPTS")
        created_col = index($0, "CREATED")
        next
      }
      index($0, task_id) == task_col {
        if (substr($0, repo_col, length(repo_ref)) != repo_ref) exit 1
        if (substr($0, source_col, 6) != "GitHub") exit 1
        if (substr($0, source_id_col, length(source_id)) != source_id) exit 1
        if (substr($0, status_col, 5) != "stale") exit 1
        if (substr($0, attempts_col, 1) != "3") exit 1
        if (substr($0, created_col, length(created)) != created) exit 1
        found = 1
      }
      END { if (!found) exit 1 }
    '; then
    pass "Long task/repository/source IDs keep every text-list column aligned"
  else
    fail "Long task/repository/source IDs keep every text-list column aligned" "all values start under their headers" "$OUTPUT"
  fi

  # Test 7: Text format output for a single task
  log "Text format output"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 100 --prompt "Text test" > /dev/null 2>&1
  TASK_ID="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments ORDER BY createdAt DESC LIMIT 1;")"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "$TASK_ID" 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "taskId:"; then
    pass "Text format works"
  else
    fail "Text format works" "taskId in output" "$OUTPUT"
  fi
}

# ============================================================
# Section 3: manul-result.sh tests
# ============================================================
test_result() {
  echo ""
  echo "=== manul-result.sh tests ==="
  
  # Test 1: Result for completed task
  log "Result for completed task"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 1 --prompt "Result test" > /dev/null 2>&1
  TASK_ID="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE prompt='Result test' ORDER BY createdAt DESC LIMIT 1;")"
  
  # Mark as completed with context
  sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt='now', context='All done' WHERE commentId='$TASK_ID';"
  
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID" --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.success == true' > /dev/null 2>&1; then
    pass "Result shows success=true for completed task"
  else
    fail "Result shows success=true for completed task" "success=true" "$OUTPUT"
  fi
  
  # Test 2: Result for failed task
  log "Result for failed task"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 2 --prompt "Failed test" > /dev/null 2>&1
  TASK_ID2="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE prompt='Failed test' ORDER BY createdAt DESC LIMIT 1;")"
  
  sqlite3 "$DB" "UPDATE processed_comments SET status='failed', processedAt='now', context='Something went wrong' WHERE commentId='$TASK_ID2';"
  
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID2" --json 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$OUTPUT" | jq -e '.success == false' > /dev/null 2>&1; then
    pass "Result shows success=false for failed task"
  else
    fail "Result shows success=false for failed task" "success=false" "$OUTPUT"
  fi
  
  # Test 3: Blocked Todo task exposes the stored user question.
  log "Result for blocked Todo task"
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/todo --issue 0 --prompt "Todo blocker result test" > /dev/null 2>&1
  TASK_ID_BLOCKED="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE prompt='Todo blocker result test' ORDER BY createdAt DESC LIMIT 1;")"
  sqlite3 "$DB" "UPDATE processed_comments SET status='blocked_user', processedAt='now', resultSummary='Which API should be used for this step?' WHERE commentId='$TASK_ID_BLOCKED';"
  OUTPUT="$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID_BLOCKED" --json 2>&1)"
  if printf '%s' "$OUTPUT" | jq -e '.status == "blocked_user" and .success == false and .error == "Which API should be used for this step?"' >/dev/null 2>&1; then
    pass "Blocked Todo task exposes the saved question"
  else
    fail "Blocked Todo task exposes the saved question" "status=blocked_user and saved error" "$OUTPUT"
  fi

  # Test 4: Non-existent task
  log "Result for non-existent task"
  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "nonexistent" --json > /dev/null 2>&1
  EXIT_CODE=$?
  set -e
  if [ "$EXIT_CODE" -ne 0 ]; then
    pass "Non-existent task returns error"
  else
    fail "Non-existent task returns error" "non-zero exit" "exit $EXIT_CODE"
  fi
  
  # Test 4: Queued task (not completed)
  log "Result for queued task"
  TASK_ID3="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE status='queued' LIMIT 1;")"
  if [ -n "$TASK_ID3" ]; then
    set +e
    MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID3" --json > /dev/null 2>&1
    EXIT_CODE=$?
    set -e
    if [ "$EXIT_CODE" -ne 0 ]; then
      pass "Queued task returns error"
    else
      fail "Queued task returns error" "non-zero exit" "exit $EXIT_CODE"
    fi
  else
    fail "Result for queued task" "queued task exists" "no queued tasks"
  fi
  
  # Test 5: Text format
  log "Text format result"
  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID" 2>&1)
  if printf '%s' "$OUTPUT" | grep -q "success:        true"; then
    pass "Text format works"
  else
    fail "Text format works" "success: true in output" "$OUTPUT"
  fi
}

# ============================================================
# Section 4: Integration tests
# ============================================================
test_integration() {
  echo ""
  echo "=== Integration tests ==="
  
  # Test 1: Full lifecycle - submit, check status, get result
  log "Full lifecycle: submit → status → result"
  
  # Submit
  SUBMIT_OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 200 --prompt "Lifecycle test" --json 2>&1)
  TASK_ID="$(printf '%s' "$SUBMIT_OUTPUT" | jq -r '.commentId')"
  
  # Check status (should be queued)
  STATUS_OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" "$TASK_ID" --json 2>&1)
  STATUS="$(printf '%s' "$STATUS_OUTPUT" | jq -r '.status')"
  if [ "$STATUS" = "queued" ]; then
    pass "Status is 'queued' after submission"
  else
    fail "Status is 'queued' after submission" "queued" "$STATUS"
  fi
  
  # Simulate completion
  sqlite3 "$DB" "UPDATE processed_comments SET status='completed', processedAt='now', context='Lifecycle complete' WHERE commentId='$TASK_ID';"
  
  # Get result
  RESULT_OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-result.sh" "$TASK_ID" --json 2>&1)
  SUCCESS="$(printf '%s' "$RESULT_OUTPUT" | jq -r '.success')"
  if [ "$SUCCESS" = "true" ]; then
    pass "Result shows success=true after completion"
  else
    fail "Result shows success=true after completion" "true" "$SUCCESS"
  fi
  
  # Test 2: Conversation grouping
  log "Conversation grouping"
  OUTPUT1=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 201 --prompt "Msg 1" --json 2>&1)
  OUTPUT2=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo owner/repo --issue 201 --prompt "Msg 2" --json 2>&1)
  
  CONV1="$(printf '%s' "$OUTPUT1" | jq -r '.conversationId')"
  CONV2="$(printf '%s' "$OUTPUT2" | jq -r '.conversationId')"
  
  if [ "$CONV1" = "$CONV2" ]; then
    pass "Same issue gets same conversation ID"
  else
    fail "Same issue gets same conversation ID" "$CONV1" "$CONV2"
  fi
  
  # Test 3: Different repos get different conversations
  log "Different repos get different conversations"
  OUTPUT3=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-submit.sh" \
    --repo other/repo --issue 201 --prompt "Other repo" --json 2>&1)
  CONV3="$(printf '%s' "$OUTPUT3" | jq -r '.conversationId')"
  
  if [ "$CONV1" != "$CONV3" ]; then
    pass "Different repos get different conversation IDs"
  else
    fail "Different repos get different conversation IDs" "different" "$CONV1=$CONV3"
  fi
  
  # Test 4: Database has result columns
  log "Database schema has result columns"
  HAS_RESULT_SUMMARY=$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c "resultSummary" || true)
  HAS_RESULT_JSON=$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" | grep -c "resultJson" || true)
  
  if [ "$HAS_RESULT_SUMMARY" -gt 0 ] && [ "$HAS_RESULT_JSON" -gt 0 ]; then
    pass "Database has resultSummary and resultJson columns"
  else
    fail "Database has result columns" "has both" "resultSummary=$HAS_RESULT_SUMMARY resultJson=$HAS_RESULT_JSON"
  fi
}

# ============================================================
# Main
# ============================================================
echo "============================================================"
echo "  Manul Local Interface CLI Tests"
echo "  Test directory: $TEST_DIR"
echo "============================================================"

init_db

# ============================================================
# Section 3: manul-status.sh log mode tests
# ============================================================
test_status_log() {
  echo ""
  echo "=== manul-status.sh log tests ==="
  mkdir -p "$MANUL_DIR/logs"
  printf 'line-1\nline-2\nline-3\n' > "$MANUL_DIR/logs/daemon.log"

  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --log --tail=2 2>&1)
  assert_eq "Log mode --tail=2 returns last two lines" $'line-2\nline-3' "$OUTPUT"

  OUTPUT=$(MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --log --tail 1 2>&1)
  assert_eq "Log mode --tail 1 returns last line" "line-3" "$OUTPUT"

  set +e
  MANUL_DIR="$MANUL_DIR" bash "$SCRIPT_DIR/manul-status.sh" --log --tail=0 > /dev/null 2>&1
  RC=$?
  set -e
  assert_eq "Invalid --tail=0 returns error" "1" "$RC"
}
test_task_recovery_retry
test_submit
test_status
test_status_log
test_result
test_integration

# Summary
echo ""
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
  printf "${GREEN}  All $PASS tests passed!${NC}\n"
else
  printf "${RED}  $PASS passed, $FAIL failed${NC}\n"
fi
echo "============================================================"

exit "$FAIL"
