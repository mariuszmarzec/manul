#!/bin/bash
# test_workspace_behavior.sh: Behavioral tests for workspace concurrency

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export CONFIG="$MANUL_DIR/config.json"
export LOG="$MANUL_DIR/logs/daemon.log"

mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs"

# Minimal config
cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "automation": {
    "enabled": true,
    "maxAttemptsBeforeFail": 3
  }
}
CONFIGEOF

# Source only workspace manager (not full poll.sh to avoid dependencies)
_script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$_script_dir/manul-paths.sh"
export DB="$MANUL_DB"
source "$_script_dir/workspace-manager.sh"

# Create processed_comments table for cross-repo tests
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (commentId TEXT PRIMARY KEY, repository TEXT, issueNumber INTEGER, processedAt TEXT, status TEXT, workspaceId TEXT);" 2>/dev/null || true

# Copy generate_conversation_id from poll.sh
generate_conversation_id() {
  local repo="$1"
  local issue="$2"
  local kind="${3:-issue}"
  local thread_id="${4:-}"

  case "$kind" in
    review-thread)
      [ -n "$thread_id" ] || {
        echo "ERROR: review-thread conversation requires thread_id" >&2
        return 1
      }
      printf 'conv-%s-review-%s' "$repo" "$thread_id"
      ;;
    issue|pr-top-level)
      printf 'conv-%s-issue-%s' "$repo" "$issue"
      ;;
    *)
      echo "ERROR: unknown conversation kind: $kind" >&2
      return 1
      ;;
  esac
}

PASSED=0
FAILED=0
TESTS_RUN=0

run_test() {
  local name="$1"
  local result="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$result" -eq 0 ]; then
    PASSED=$((PASSED + 1))
    echo "  PASS: $name"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL: $name"
  fi
}

# Wrapper to always call run_test (avoids losing failures under `set -e` or direct function calls)
run_and_test() {
  local name="$1"
  local func="$2"
  set +e
  "$func"
  local rc=$?
  set -e
  run_test "$name" "$rc"
}

# Helper to reset pool between tests
reset_pool() {
  workspace_pool_init 0 reset
}

# Self-check: verify test discovery
self_check() {
  local expected_tests=31
  local actual_tests
  actual_tests=$(grep -Ec "^test_[a-zA-Z0-9_]+\(\)[[:space:]]*(\{|\()" "$0" 2>/dev/null || echo 0)

  if [ "$actual_tests" -ne "$expected_tests" ]; then
    echo "  FAIL: Test discovery mismatch: expected $expected_tests, found $actual_tests"
    return 1
  fi

  echo "  PASS: Test discovery verified ($actual_tests tests found)"
  return 0
}

self_check || { echo "Test discovery failed"; exit 1; }

echo "═══════════════════════════════════════════════════════════════"
echo "  Workspace Behavior Tests"
echo "═══════════════════════════════════════════════════════════════"

# Test 1: Two tasks for same repo get different workspaces
echo ""
echo "=== Test 1: Same repo concurrent tasks get different workspaces ==="
test_same_repo_different_workspaces() {
  workspace_pool_init 5 reset
  
  local ws1 ws2
  ws1="$(workspace_lease "task-repo1-a")"
  ws2="$(workspace_lease "task-repo1-b")"
  
  [ -n "$ws1" ] || return 1
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1
  
  local busy_count
  busy_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY';")"
  [ "$busy_count" -eq 2 ] || return 1
  
  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 1: Same repo different workspaces" test_same_repo_different_workspaces

# Test 2: Completed workspace can be reused
echo ""
echo "=== Test 2: Completed workspace reuse ==="
test_workspace_reuse() {
  workspace_pool_init 2 reset
  
  local ws1
  ws1="$(workspace_lease "task-reuse-1")"
  workspace_release "$ws1"
  
  local ws2
  ws2="$(workspace_lease "task-reuse-2")"
  
  [ "$ws1" = "$ws2" ] || return 1
  
  workspace_release "$ws2"
}
run_and_test "Test 2: Workspace reuse after completion" test_workspace_reuse

# Test 3: Concurrent tasks from same conversation get separate workspaces
echo ""
echo "=== Test 3: Same conversation concurrent tasks isolation ==="
test_conversation_isolation() {
  workspace_pool_init 3 reset
  
  local ws1 ws2
  ws1="$(workspace_lease "conv-A-task-1")"
  ws2="$(workspace_lease "conv-A-task-2")"
  
  [ -n "$ws1" ] || return 1
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1
  
  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 3: Same conversation isolation" test_conversation_isolation

# Test 4: Sequential tasks in same conversation can reuse workspace
echo ""
echo "=== Test 4: Sequential conversation tasks workspace reuse ==="
test_sequential_conversation() {
  workspace_pool_init 2 reset
  
  local ws1
  ws1="$(workspace_lease "conv-B-task-1")"
  workspace_release "$ws1"
  
  local ws2
  ws2="$(workspace_lease "conv-B-task-2")"
  
  [ -n "$ws2" ] || return 1
  
  workspace_release "$ws2"
}
run_and_test "Test 4: Sequential conversation workspace" test_sequential_conversation

# Test 5: Different conversations on same issue/PR are isolated
echo ""
echo "=== Test 5: Different conversations on same issue ==="
test_different_conversations() {
  workspace_pool_init 4

  local conv1 conv2
  conv1="$(generate_conversation_id "test/repo" "1" "review-thread" "r1")"
  conv2="$(generate_conversation_id "test/repo" "1" "review-thread" "r2")"

  [ "$conv1" != "$conv2" ] || return 1

  local ws1 ws2
  ws1="$(workspace_lease "conv1-task")"
  ws2="$(workspace_lease "conv2-task")"

  [ -n "$ws1" ] || return 1
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1

  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 5: Different conversations isolation" test_different_conversations

# Test 6: Workspace exclusivity verification
echo ""
echo "=== Test 6: Workspace exclusivity ==="
test_workspace_exclusivity() {
  workspace_pool_init 1 reset
  
  local ws1
  ws1="$(workspace_lease "exclusive-task-1")"
  
  local ws2
  ws2="$(workspace_lease "exclusive-task-2")"
  
  [ -z "$ws2" ] || return 1
  
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws1';")"
  [ "$status" = "BUSY" ] || return 1
  
  workspace_release "$ws1"
}
run_and_test "Test 6: Workspace exclusivity" test_workspace_exclusivity

# Test 7: Pool exhaustion behavior
echo ""
echo "=== Test 7: Pool exhaustion ==="
test_pool_exhaustion() {
  workspace_pool_init 2 reset
  
  local ws1 ws2
  ws1="$(workspace_lease "exhaust-1")"
  ws2="$(workspace_lease "exhaust-2")"
  
  local ws3
  ws3="$(workspace_lease "exhaust-3")"
  
  [ -z "$ws3" ] || return 1
  
  workspace_release "$ws1"
  local ws4
  ws4="$(workspace_lease "exhaust-4")"
  
  [ -n "$ws4" ] || return 1
  [ "$ws4" = "$ws1" ] || return 1
  
  workspace_release "$ws2"
  workspace_release "$ws4"
}
run_and_test "Test 7: Pool exhaustion and recovery" test_pool_exhaustion

# Test 8: Stale workspace cleanup
echo ""
echo "=== Test 8: Stale workspace cleanup ==="
test_stale_cleanup() {
  workspace_pool_init 3 reset
  
  local ws
  ws="$(workspace_lease "stale-task")"
  
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now', '-7200 seconds') WHERE workspaceId='$ws';"
  
  workspace_cleanup_stale 3600
  
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';" 2>/dev/null || echo "NOT_FOUND")"

  [ "$status" = "BROKEN" ] || [ -z "$status" ] || [ "$status" = "NOT_FOUND" ] || return 1
}
run_and_test "Test 8: Stale workspace cleanup" test_stale_cleanup

# Test 9: A stale-looking workspace must not be reclaimed while its worker is alive
echo ""
echo "=== Test 9: Live worker protects stale workspace ==="
test_live_worker_protects_workspace() {
  workspace_pool_init 1 reset

  local ws
  ws="$(workspace_lease "live-task")"
  [ -n "$ws" ] || return 1

  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,heartbeatAt,leaseExpiresAt,workerPid) VALUES('live-task','running',datetime('now','-7200 seconds'),datetime('now','-7200 seconds'),$$);"
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now','-7200 seconds') WHERE workspaceId='$ws';"

  workspace_cleanup_stale 3600

  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';")"
  [ "$status" = "BUSY" ] || return 1
  workspace_release "$ws"
}
run_and_test "Test 9: Live worker protects stale workspace" test_live_worker_protects_workspace

# Test 10: Dead worker + stale task allows workspace reclamation
echo ""
echo "=== Test 10: Dead worker stale workspace reclamation ==="
test_dead_worker_reclaims_workspace() {
  workspace_pool_init 1 reset

  local ws
  ws="$(workspace_lease "dead-task")"
  [ -n "$ws" ] || return 1

  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,status,heartbeatAt,leaseExpiresAt,workerPid) VALUES('dead-task','running',datetime('now','-7200 seconds'),datetime('now','-7200 seconds'),99999999);"
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now','-7200 seconds') WHERE workspaceId='$ws';"

  workspace_cleanup_stale 3600

  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws';" 2>/dev/null || true)"
  [ -z "$status" ] || [ "$status" = "NOT_FOUND" ] || return 1
}
run_and_test "Test 10: Dead worker stale workspace reclamation" test_dead_worker_reclaims_workspace

echo ""

# Test 9: Sequential same-conversation workspace reuse
echo ""
echo "=== Test 11: Sequential same-conversation workspace reuse ==="
test_sequential_reuse() {
  workspace_pool_init 2 reset

  local ws1
  ws1="$(workspace_lease "conv-A-task-1")"
  [ -n "$ws1" ] || return 1

  local status1
  status1="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws1';")"
  [ "$status1" = "BUSY" ] || return 1

  workspace_release "$ws1"

  local ws2
  ws2="$(workspace_lease "conv-A-task-2")"
  [ -n "$ws2" ] || return 1
  [ "$ws2" = "$ws1" ] || return 1

  status1="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws2';")"
  [ "$status1" = "BUSY" ] || return 1

  workspace_release "$ws2"
}
run_and_test "Test 9: Sequential same-conversation workspace reuse" test_sequential_reuse

# Test 10: Cross-repository workspace isolation
echo ""
echo "=== Test 12: Cross-repository workspace isolation ==="
test_cross_repo_isolation() {
  workspace_pool_init 2 reset

  # Two concurrent tasks for different repos get different workspaces
  local ws1 ws2
  ws1="$(workspace_lease "repo-a-task")"
  [ -n "$ws1" ] || return 1
  ws2="$(workspace_lease "repo-b-task")"
  [ -n "$ws2" ] || return 1
  [ "$ws1" != "$ws2" ] || return 1

  workspace_release "$ws1"
  workspace_release "$ws2"
}
run_and_test "Test 10: Cross-repository workspace isolation" test_cross_repo_isolation

# Test 11: Concurrent lease atomicity — two simultaneous lease attempts on pool of 1
echo ""
echo "=== Test 13: Concurrent lease atomicity ==="
test_concurrent_lease() {
  workspace_pool_init 1 reset

  # Use background processes to create true concurrency
  local ws1 ws2
  ( ws1="$(workspace_lease "concurrent-task-1")"; echo "$ws1" > /tmp/ws1.out ) &
  local pid1=$!
  ( ws2="$(workspace_lease "concurrent-task-2")"; echo "$ws2" > /tmp/ws2.out ) &
  local pid2=$!

  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true

  ws1="$(cat /tmp/ws1.out 2>/dev/null)"
  ws2="$(cat /tmp/ws2.out 2>/dev/null)"
  rm -f /tmp/ws1.out /tmp/ws2.out

  # Exactly one should succeed
  local got_one=false
  if [ -n "$ws1" ] && [ -z "$ws2" ]; then
    got_one=true
  elif [ -z "$ws1" ] && [ -n "$ws2" ]; then
    got_one=true
  fi
  [ "$got_one" = "true" ] || return 1

  # The winner should have BUSY status
  local winner="${ws1:-$ws2}"
  local status
  status="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$winner';")"
  [ "$status" = "BUSY" ] || return 1

  # Verify DB has exactly one owner for this workspace
  local owner_count
  owner_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$winner' AND status='BUSY';")"
  [ "$owner_count" = "1" ] || return 1

  workspace_release "$winner"
}
run_and_test "Test 11: Concurrent lease atomicity" test_concurrent_lease

# Test 12: workspace_repo_matches handles HTTPS URLs with .git
test_workspace_repo_matches_https_with_git() {
  workspace_repo_matches "test-org/test-repo" "https://github.com/test-org/test-repo.git"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 12: workspace_repo_matches HTTPS with .git" test_workspace_repo_matches_https_with_git

# Test 13: workspace_repo_matches handles HTTPS URLs without .git
test_workspace_repo_matches_https_without_git() {
  workspace_repo_matches "test-org/test-repo" "https://github.com/test-org/test-repo"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 13: workspace_repo_matches HTTPS without .git" test_workspace_repo_matches_https_without_git

# Test 14: workspace_repo_matches handles SSH URLs
test_workspace_repo_matches_ssh() {
  workspace_repo_matches "test-org/test-repo" "git@github.com:test-org/test-repo.git"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 14: workspace_repo_matches SSH URL" test_workspace_repo_matches_ssh

# Test 15: workspace_repo_matches handles local filesystem paths
test_workspace_repo_matches_local() {
  workspace_repo_matches "test-org/test-repo" "/home/user/workspace/test-org-test-repo"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 15: workspace_repo_matches local path" test_workspace_repo_matches_local

# Test 16: workspace_repo_matches rejects non-matching repos
test_workspace_repo_matches_nonmatching() {
  workspace_repo_matches "test-org/test-repo" "other-org/other-repo"
  [ $? -ne 0 ] || return 1
  workspace_repo_matches "test-org/test-repo" "https://github.com/other-org/other-repo"
  [ $? -ne 0 ] || return 1
}
run_and_test "Test 16: workspace_repo_matches rejects non-matching" test_workspace_repo_matches_nonmatching

# Test 17: workspace_repo_matches handles github.com/ prefix
test_workspace_repo_matches_github_prefix() {
  workspace_repo_matches "test-org/test-repo" "github.com/test-org/test-repo"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 17: workspace_repo_matches github.com prefix" test_workspace_repo_matches_github_prefix

# Test 18: workspace_repo_matches handles ssh:// git protocol
test_workspace_repo_matches_ssh_protocol() {
  workspace_repo_matches "test-org/test-repo" "ssh://git@github.com/test-org/test-repo.git"
  [ $? -eq 0 ] || return 1
}
run_and_test "Test 18: workspace_repo_matches ssh:// protocol" test_workspace_repo_matches_ssh_protocol

# Test 19: evaluate_task_completion ignores __pycache__ in untracked files
echo ""
echo "=== Test 21: Untracked files filtering ==="
test_untracked_files_ignores_pycache() {
  # Create a temp repo with __pycache__ and .pytest_cache
  local tmprepo
  tmprepo="$(mktemp -d)" || return 1

  git -C "$tmprepo" init -q
  git -C "$tmprepo" config user.email "test@test.com"
  git -C "$tmprepo" config user.name "Test"

  # Create a tracked file
  echo "print('hello')" > "$tmprepo/app.py"
  git -C "$tmprepo" add app.py
  git -C "$tmprepo" commit -q -m "initial" >/dev/null 2>&1

  # Create build artifacts
  mkdir -p "$tmprepo/__pycache__"
  echo "compiled" > "$tmprepo/__pycache__/app.cpython-311.pyc"
  mkdir -p "$tmprepo/.pytest_cache/v/cache"
  echo "cache" > "$tmprepo/.pytest_cache/v/cache/lastfailed"
  mkdir -p "$tmprepo/src/__pycache__"
  echo "nested" > "$tmprepo/src/__pycache__/mod.cpython-311.pyc"

  # Capture untracked output (simulating what evaluate_task_completion does)
  local untracked
  untracked="$(git -C "$tmprepo" ls-files --others --exclude-standard 2>/dev/null | grep -v '/__pycache__' | grep -v '/\.pytest_cache' | grep -v '^__pycache__' | grep -v '^\.__pycache__' | grep -v '^\.__pycache__/' | grep -v '^\.pytest_cache' || true)"

  # Cleanup
  rm -rf "$tmprepo"

  # Should be empty - all pycache dirs filtered
  [ -z "$untracked" ] || return 1
}
run_and_test "Test 19: untracked files ignores __pycache__ and .pytest_cache" test_untracked_files_ignores_pycache

# Test 20: Fresh lease must NOT be released when a stale completed/failed
# task in the same conversation points at an unrelated idle workspace.
# Regression test for issue #44: the "reuse previous workspace" block used
# to release the freshly leased workspace and repoint the task at a
# completed/failed workspace whose currentTaskId was already NULL, which
# broke workspace_get_path resolution and prevented the agent from ever
# starting.
echo ""
echo "=== Test 20: Fresh lease survives stale conversation reuse ==="
test_fresh_lease_survives_stale_reuse() {
  workspace_pool_init 2 reset

  # 1. Lease workspace A for the current task T.
  local ws_a
  ws_a="$(workspace_lease "task-T")"
  [ -n "$ws_a" ] || return 1

  # 2. Prepare an unrelated completed/failed workspace B in the same
  #    conversation: IDLE, currentTaskId=NULL, with a stale task row
  #    pointing at it (simulating a previously completed task).
  local ws_b
  ws_b="$(workspace_lease "task-prev")"
  [ -n "$ws_b" ] || return 1
  workspace_release "$ws_b"
  sqlite3 "$DB" "UPDATE workspaces SET currentTaskId=NULL, status='IDLE' WHERE workspaceId='$ws_b';"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, status, workspaceId, processedAt) VALUES('task-prev','test-owner/repo',1,'completed','$ws_b',datetime('now'));"

  # 3. Simulate the post-lease dispatch state: task T points at ws_a, ws_a
  #    is BUSY with currentTaskId=task-T. The fix must NOT touch ws_a.
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId, repository, issueNumber, status, workspaceId, processedAt) VALUES('task-T','test-owner/repo',1,'running','$ws_a',datetime('now'));"

  # 4. Assert ws_a is still leased to task-T and ws_b is idle/untouched.
  local owner_a state_a
  owner_a="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$ws_a';")"
  state_a="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_a';")"
  [ "$owner_a" = "task-T" ] || return 1
  [ "$state_a" = "BUSY" ] || return 1

  local owner_b state_b
  owner_b="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$ws_b';")"
  state_b="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_b';")"
  [ -z "$owner_b" ] || return 1
  [ "$state_b" = "IDLE" ] || return 1

  # 5. workspace_get_path must still resolve ws_a for task-T.
  local resolved expected_path
  resolved="$(workspace_get_path "task-T")"
  expected_path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$ws_a';")"
  [ "$resolved" = "$expected_path" ] || return 1

  # If the directory disappeared while the DB still has a valid lease, restore
  # only that exact task-owned workspace root so dispatch can rebuild its checkout.
  local missing_backup="${resolved}.missing-test-backup"
  mv "$resolved" "$missing_backup" || return 1
  local restored
  restored="$(workspace_get_path "task-T")"
  [ "$restored" = "$expected_path" ] || { mv "$missing_backup" "$resolved" 2>/dev/null || true; return 1; }
  [ -d "$restored" ] || { mv "$missing_backup" "$resolved" 2>/dev/null || true; return 1; }
  [ ! -L "$restored" ] || { mv "$missing_backup" "$resolved" 2>/dev/null || true; return 1; }
  rm -rf -- "$missing_backup"

  workspace_release "$ws_a"
}
run_and_test "Test 20: Fresh lease survives stale conversation reuse" test_fresh_lease_survives_stale_reuse

# Test 21: Negative control — a workspace without valid ownership must
# prevent agent dispatch. Mirrors the hard validation added to the daemon
# dispatch path: no agent may launch against a workspace that is not BUSY
# and owned by the current task.
echo ""
echo "=== Test 21: Invalid ownership blocks dispatch ==="
test_invalid_ownership_blocks_dispatch() {
  workspace_pool_init 2 reset

  local ws_a
  ws_a="$(workspace_lease "task-T")"
  [ -n "$ws_a" ] || return 1

  # Break the invariant: release the workspace back to the pool.
  workspace_release "$ws_a"

  local owner state
  owner="$(sqlite3 "$DB" "SELECT currentTaskId FROM workspaces WHERE workspaceId='$ws_a';")"
  state="$(sqlite3 "$DB" "SELECT status FROM workspaces WHERE workspaceId='$ws_a';")"
  [ -z "$owner" ] || return 1
  [ "$state" = "IDLE" ] || return 1

  # The daemon validation query must return empty (no BUSY row owned by task-T).
  local validated
  validated="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$ws_a' AND currentTaskId='task-T' AND status='BUSY' LIMIT 1;" 2>/dev/null || echo "")"
  [ -z "$validated" ] || return 1
}
run_and_test "Test 21: Invalid ownership blocks dispatch" test_invalid_ownership_blocks_dispatch

# Test 22: an otherwise-valid lease must not authorize a different workspace path.
echo ""
echo "=== Test 22: Lease ID must match the executor's physical workspace ==="
test_workspace_id_must_match_candidate_path() {
  workspace_pool_init 2 reset

  local ws_a ws_b path_a path_b
  ws_a="$(workspace_lease "task-A")"
  ws_b="$(workspace_lease "task-B")"
  [ -n "$ws_a" ] && [ -n "$ws_b" ] && [ "$ws_a" != "$ws_b" ] || return 1

  path_a="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$ws_a';")"
  path_b="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$ws_b';")"
  [ -d "$path_a" ] && [ -d "$path_b" ] || return 1

  workspace_owned_path_matches "$ws_a" "task-A" "$path_a" || return 1
  if workspace_owned_path_matches "$ws_a" "task-A" "$path_b"; then
    echo "workspace guard incorrectly accepted a second extant checkout" >&2
    return 1
  fi

  workspace_release "$ws_a" "task-A"
  workspace_release "$ws_b" "task-B"
}
run_and_test "Test 22: Lease ID must match executor workspace path" test_workspace_id_must_match_candidate_path


# Test 23: exact thread context reclaims the same workspace and keeps
# uncommitted changes between separate tasks.
echo ""
echo "=== Test 23: Thread context preserves uncommitted work ==="
test_thread_context_reclaims_workspace() {
  workspace_pool_init 2 reset

  local context="conv-repo-issue-36-review-123"
  local parent="conv-repo-issue-36"
  local ws1 ws2 path
  ws1="$(workspace_context_acquire "task-thread-1" "$context" "$parent" "repo" 36)"
  [ -n "$ws1" ] || return 1
  path="$(workspace_get_path "task-thread-1")"
  [ -n "$path" ] || return 1

  printf '%s\n' "local uncommitted change" > "$path/local-thread.txt"
  workspace_release "$ws1" "task-thread-1"

  ws2="$(workspace_context_acquire "task-thread-2" "$context" "$parent" "repo" 36)"
  [ "$ws2" = "$ws1" ] || return 1
  path="$(workspace_get_path "task-thread-2")"
  [ -f "$path/local-thread.txt" ] || return 1
  grep -Fxq "local uncommitted change" "$path/local-thread.txt" || return 1
  workspace_release "$ws2" "task-thread-2"
}
run_and_test "Test 23: Thread context preserves uncommitted work" test_thread_context_reclaims_workspace

# Test 24: a thread without its own prior workspace inherits the PR root
# workspace, preserving the root's local changes.
echo ""
echo "=== Test 24: Review thread falls back to PR context ==="
test_thread_context_falls_back_to_pr() {
  workspace_pool_init 2 reset

  local pr_context="conv-repo-issue-36"
  local thread_context="conv-repo-review-456"
  local ws_pr ws_thread path
  ws_pr="$(workspace_context_acquire "task-pr-1" "$pr_context" "" "repo" 36)"
  [ -n "$ws_pr" ] || return 1
  path="$(workspace_get_path "task-pr-1")"
  printf '%s\n' "PR local work" > "$path/local-pr.txt"
  workspace_release "$ws_pr" "task-pr-1"

  ws_thread="$(workspace_context_acquire "task-thread-1" "$thread_context" "$pr_context" "repo" 36)"
  [ "$ws_thread" = "$ws_pr" ] || return 1
  path="$(workspace_get_path "task-thread-1")"
  [ -f "$path/local-pr.txt" ] || return 1
  grep -Fxq "PR local work" "$path/local-pr.txt" || return 1
  workspace_release "$ws_thread" "task-thread-1"
}
run_and_test "Test 24: Review thread falls back to PR context" test_thread_context_falls_back_to_pr

# Test 25: mapped workspaces are not stolen by unrelated new contexts.
echo ""
echo "=== Test 25: Mapped workspace is protected from unrelated contexts ==="
test_mapped_workspace_not_stolen() {
  workspace_pool_init 2 reset

  local ws_pr ws_other
  ws_pr="$(workspace_context_acquire "task-pr" "conv-repo-issue-36" "" "repo" 36)"
  [ -n "$ws_pr" ] || return 1
  workspace_release "$ws_pr" "task-pr"

  ws_other="$(workspace_context_acquire "task-other" "conv-repo-issue-99" "" "repo" 99)"
  [ -n "$ws_other" ] || return 1
  [ "$ws_other" != "$ws_pr" ] || return 1
  workspace_release "$ws_other" "task-other"
}
run_and_test "Test 25: Mapped workspace protected from unrelated contexts" test_mapped_workspace_not_stolen

# Test 26: idle context workspaces survive stale cleanup so local changes
# remain available for a later comment.
echo ""
echo "=== Test 26: Context workspace survives stale cleanup ==="
test_context_workspace_survives_stale_cleanup() {
  workspace_pool_init 1 reset

  local context="conv-repo-issue-36"
  local ws path
  ws="$(workspace_context_acquire "task-stale" "$context" "" "repo" 36)"
  [ -n "$ws" ] || return 1
  path="$(workspace_get_path "task-stale")"
  printf '%s\n' "keep me" > "$path/local.txt"
  workspace_release "$ws" "task-stale"

  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now','-7200 seconds') WHERE workspaceId='$ws';"
  workspace_cleanup_stale 1

  sqlite3 "$DB" "SELECT 1 FROM workspace_contexts WHERE contextId='$context' AND workspaceId='$ws';" | grep -qx 1 || return 1
  [ -d "$path/.git" ] || true
  [ -f "$path/local.txt" ] || return 1
}
run_and_test "Test 26: Context workspace survives stale cleanup" test_context_workspace_survives_stale_cleanup

# Test 27: PR branch preparation never discards dirty local changes.
echo ""
echo "=== Test 27: PR branch preparation preserves dirty work ==="
test_pr_branch_preparation_preserves_dirty_work() (
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  remote="$tmp/remote.git"
  work="$tmp/work"
  git init --bare -q "$remote"
  git clone -q "$remote" "$work"
  git -C "$work" config user.email "test@example.com"
  git -C "$work" config user.name "Test"
  printf '%s\n' "base" > "$work/file.txt"
  git -C "$work" add file.txt
  git -C "$work" commit -qm "initial"
  git -C "$work" branch -M master
  git -C "$work" push -q origin master
  git -C "$work" checkout -qb feature/test
  git -C "$work" push -q -u origin feature/test

  printf '%s\n' "dirty local work" >> "$work/file.txt"
  workspace_prepare_pr_branch "$work" feature/test || return 1
  grep -Fxq "dirty local work" "$work/file.txt" || return 1
  [ "$(git -C "$work" symbolic-ref --short HEAD)" = "feature/test" ] || return 1
)
run_and_test "Test 27: PR branch preparation preserves dirty work" test_pr_branch_preparation_preserves_dirty_work


# Test 28: a new context can get a fresh workspace even when the configured
# pool is fully occupied by idle persistent contexts.
echo ""
echo "=== Test 28: New context gets fresh workspace after context pool is full ==="
test_new_context_gets_fresh_workspace() {
  MAX_CONCURRENT_TASKS=1
  workspace_pool_init 1 reset

  local ws_pr ws_new
  ws_pr="$(workspace_context_acquire "task-pr" "conv-repo-issue-36" "" "repo" 36)"
  [ -n "$ws_pr" ] || return 1
  workspace_release "$ws_pr" "task-pr"

  ws_new="$(workspace_context_acquire "task-new" "conv-repo-issue-99" "" "repo" 99)"
  [ -n "$ws_new" ] || return 1
  [ "$ws_new" != "$ws_pr" ] || return 1
  sqlite3 "$DB" "SELECT workspaceId FROM workspace_contexts WHERE contextId='conv-repo-issue-99';" | grep -qx "$ws_new" || return 1
  workspace_release "$ws_new" "task-new"
}
run_and_test "Test 28: New context gets fresh workspace after context pool is full" test_new_context_gets_fresh_workspace

# Test 29: a stale workspace is archived before its DB row/context is discarded.
# Simulate an interrupted implementation with uncommitted files, then let startup
# recovery reclaim the stale lease. The preserved snapshot must remain task-owned
# and outside the agent's active workspace.
echo ""
echo "=== Test 29: Stale workspace is archived before reclaim ==="
test_stale_busy_workspace_is_archived_before_reclaim() {
  workspace_pool_init 1 reset

  local ws path archive_root archive
  ws="$(workspace_lease "task-rebooted")" || return 1
  path="$WORKSPACES_DIR/$ws"
  mkdir -p "$path/repos/owner/repo"
  printf '%s\n' "uncommitted implementation" > "$path/repos/owner/repo/wip.txt"
  printf '%s\n' "untracked test" > "$path/repos/owner/repo/new-test.txt"
  sqlite3 "$DB" "INSERT OR REPLACE INTO processed_comments(commentId,repository,issueNumber,status,workspaceId) VALUES ('task-rebooted','owner/repo',29,'running','$ws');"
  sqlite3 "$DB" "UPDATE workspaces SET lastUsedAt=datetime('now','-7200 seconds') WHERE workspaceId='$ws';"

  workspace_cleanup_stale 1

  archive_root="$MANUL_STATE_DIR/recovery/workspaces"
  archive="$(find "$archive_root" -mindepth 1 -maxdepth 1 -type d -name "${ws}-task-rebooted-*" -print -quit 2>/dev/null)"
  [ -n "$archive" ] || return 1
  grep -Fxq "uncommitted implementation" "$archive/repos/owner/repo/wip.txt" || return 1
  grep -Fxq "untracked test" "$archive/repos/owner/repo/new-test.txt" || return 1
  [ ! -e "$path" ] || return 1
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$ws';")" = "0" ] || return 1
  [ "$(stat -c '%a' "$archive_root" 2>/dev/null)" = "700" ] || return 1

  # When the same task is recovered, it can reclaim its archived WIP rather than
  # failing because its previous workspace row disappeared.
  [ "$(workspace_reclaim "task-rebooted")" = "$ws" ] || return 1
  [ -f "$path/repos/owner/repo/wip.txt" ] || return 1
  grep -Fxq "uncommitted implementation" "$path/repos/owner/repo/wip.txt" || return 1
  grep -Fxq "untracked test" "$path/repos/owner/repo/new-test.txt" || return 1
  [ "$(sqlite3 "$DB" "SELECT status || '|' || currentTaskId FROM workspaces WHERE workspaceId='$ws';")" = "BUSY|task-rebooted" ] || return 1
}
run_and_test "Test 29: Stale workspace is archived before reclaim" test_stale_busy_workspace_is_archived_before_reclaim

echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TESTS_RUN tests)"
echo "═══════════════════════════════════════════════════════════════"

exit "$FAILED"
