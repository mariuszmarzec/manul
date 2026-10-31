#!/bin/bash
# test_concurrency.sh: Comprehensive concurrency and multi-conversation tests
# 
# Tests A-V as specified:
# A. maxConcurrentTasks=2 allows parallel execution
# B. Tasks from same conversation share workspace
# C. Tasks from different conversations isolate workspaces
# D. Workspace leased on claim, released on complete/fail
# E. Daemon fails to start if maxConcurrentTasks > available workspaces
# F. Schema migration adds fields without breaking existing DBs
# G. Existing DBs can accept new tasks post-migration
# H. No workspace/conversation fields for legacy tasks
# I. Default behavior unchanged when maxConcurrentTasks absent
# J. conversationId populated for new tasks
# K. CLI: manul-submit enqueues task with conversationId
# L. CLI: manul-status reports per-worker activity
# M. CLI: manul-result reads structured result JSON
# N. TASK_DONE emits structured JSON result
# O. TASK_FAILED emits structured JSON error
# P. Subtask (parentTaskId) inherits conversationId
# Q. Worker processes its own queue independently
# R. Workspace shared within conversation, exclusive across
# S. Stale workspace reclaimed after timeout
# T. Worker pool starts/stops correctly
# U. Backward compatibility with existing tests
# V. Production safety guards remain functional

set -euo pipefail

# Test environment setup
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export DB="$MANUL_DIR/manul.db"
export CONFIG="$MANUL_DIR/config.json"
export LOG="$TEST_DIR/daemon.log"
export PID_FILE="$MANUL_DIR/daemon.pid"
export FLOCK_FILE="$MANUL_DIR/flock"

mkdir -p "$MANUL_DIR/tasks"
mkdir -p "$MANUL_DIR/workspaces"

# Create minimal config
cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect"],
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
CONFIGEOF

# Source required functions
source skills/manul-github-bot/workspace-manager.sh
source skills/manul-github-bot/poll.sh
source skills/manul-github-bot/test_concurrency_impl.sh

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

# Self-check: verify test discovery
self_check() {
  local expected_tests=24
  local actual_tests
  actual_tests=$(grep -c "^test_[a-z]" skills/manul-github-bot/test_concurrency_impl.sh 2>/dev/null || echo 0)

  if [ "$actual_tests" -ne "$expected_tests" ]; then
    echo "  FAIL: Test discovery mismatch: expected $expected_tests, found $actual_tests"
    return 1
  fi

  echo "  PASS: Test discovery verified ($actual_tests tests found)"
  return 0
}

# Wrapper to always call run_test (avoids losing failures under `set -e` or `||`)
# Usage: run_and_test "name" test_func
run_and_test() {
  local name="$1"
  local func="$2"
  set +e
  "$func"
  local rc=$?
  set -e
  run_test "$name" "$rc"
}

# Run self-check before tests
self_check || { echo "Test discovery failed"; exit 1; }

echo "═══════════════════════════════════════════════════════════════"
echo "  Concurrency Multi-Conversation Tests"
echo "═══════════════════════════════════════════════════════════════"

# Test A: maxConcurrentTasks=2 allows parallel execution
echo ""
echo "=== Test A: Parallel execution with maxConcurrentTasks=2 ==="
run_and_test "Test A: maxConcurrentTasks=2 parallel execution" test_a

# Test B: Same conversation shares workspace
echo ""
echo "=== Test B: Same conversation shares workspace ==="
run_and_test "Test B: Same conversation workspace sharing" test_b

# Test C: Different conversations isolate workspaces
echo ""
echo "=== Test C: Different conversation workspace isolation ==="
run_and_test "Test C: Conversation workspace isolation" test_c

# Test D: Workspace lease/release lifecycle
echo ""
echo "=== Test D: Workspace lease/release lifecycle ==="
run_and_test "Test D: Workspace lease/release" test_d

# Test E: Start fails with insufficient workspaces
echo ""
echo "=== Test E: Daemon fails with insufficient workspaces ==="
run_and_test "Test E: Insufficient workspaces guard" test_e

# Test F: Schema migration adds fields
echo ""
echo "=== Test F: Schema migration adds fields ==="
run_and_test "Test F: Schema migration" test_f

# Test G: Existing DB accepts new tasks post-migration
echo ""
echo "=== Test G: Existing DB accepts new tasks ==="
run_and_test "Test G: Existing DB migration" test_g

# Test H: Legacy tasks have no workspace/conversation fields
echo ""
echo "=== Test H: Legacy tasks backward compatibility ==="
run_and_test "Test H: Legacy task compatibility" test_h

# Test I: Default behavior unchanged
echo ""
echo "=== Test I: Default behavior unchanged ==="
run_and_test "Test I: Default single-worker behavior" test_i

# Test J: conversationId populated
echo ""
echo "=== Test J: conversationId populated ==="
run_and_test "Test J: conversationId population" test_j

# Test K: CLI manul-submit
echo ""
echo "=== Test K: CLI manul-submit ==="
run_and_test "Test K: manul-submit CLI" test_k

# Test L: CLI manul-status
echo ""
echo "=== Test L: CLI manul-status ==="
run_and_test "Test L: manul-status CLI" test_l

# Test M: CLI manul-result
echo ""
echo "=== Test M: CLI manul-result ==="
run_and_test "Test M: manul-result CLI" test_m

# Test N: TASK_DONE emits structured JSON
echo ""
echo "=== Test N: TASK_DONE structured result ==="
run_and_test "Test N: TASK_DONE JSON output" test_n

# Test O: TASK_FAILED emits structured JSON
echo ""
echo "=== Test O: TASK_FAILED structured result ==="
run_and_test "Test O: TASK_FAILED JSON output" test_o

# Test P: Subtask inherits conversationId
echo ""
echo "=== Test P: Subtask conversation inheritance ==="
run_and_test "Test P: Subtask conversation inheritance" test_p

# Test Q: Worker queue independence
echo ""
echo "=== Test Q: Worker queue independence ==="
run_and_test "Test Q: Worker queue independence" test_q

# Test R: Workspace sharing rules
echo ""
echo "=== Test R: Workspace sharing rules ==="
run_and_test "Test R: Workspace sharing rules" test_r

# Test S: Stale workspace reclamation
echo ""
echo "=== Test S: Stale workspace reclamation ==="
run_and_test "Test S: Stale workspace reclamation" test_s

# Test T: Worker pool lifecycle
echo ""
echo "=== Test T: Worker pool lifecycle ==="
run_and_test "Test T: Worker pool lifecycle" test_t

# Test U: Backward compatibility
echo ""
echo "=== Test U: Backward compatibility ==="
run_and_test "Test U: Backward compatibility" test_u

# Test V: Production safety guards
echo ""
echo "=== Test V: Production safety guards ==="
run_and_test "Test V: Production safety guards" test_v

# Test W: Real parallel concurrency — R1 invariant
echo ""
echo "=== Test W: Parallel concurrency R1 (same repo, same PR) ==="
run_and_test "Test W: Parallel concurrency R1" test_w

# Test X: Real parallel concurrency — R2 invariant
echo ""
echo "=== Test X: Parallel concurrency R2 (different repos) ==="
run_and_test "Test X: Parallel concurrency R2" test_x

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TESTS_RUN tests)"
echo "═══════════════════════════════════════════════════════════════"

exit "$FAILED"
