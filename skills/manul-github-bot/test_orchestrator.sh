#!/bin/bash
# test_orchestrator.sh — Comprehensive tests for Manul external orchestrator
set -uo pipefail

# Resolve script directory portably
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export MANUL_DIR="$TEST_DIR/manul"
export ORCHESTRATOR_DIR="$TEST_DIR/orchestrator"
DB="$MANUL_DIR/manul.db"
ORCH_DB="$ORCHESTRATOR_DIR/orchestrator.db"
export CONFIG="$TEST_DIR/config.json"
RESULTS_DIR="$TEST_DIR/results"
mkdir -p "$MANUL_DIR" "$ORCHESTRATOR_DIR" "$RESULTS_DIR"

# Create symlinks to the actual scripts
ln -s "$SCRIPT_DIR/manul-conversation.sh" "$ORCHESTRATOR_DIR/manul-conversation.sh"
ln -s "$SCRIPT_DIR/manul-paths.sh" "$ORCHESTRATOR_DIR/manul-paths.sh"
ln -s "$SCRIPT_DIR/manul-wait.sh" "$ORCHESTRATOR_DIR/manul-wait.sh" 2>/dev/null || true

# Create mock gh for tests (no real GitHub required)
MOCK_GH_DIR="$TEST_DIR/mock-gh"
mkdir -p "$MOCK_GH_DIR"
cat > "$MOCK_GH_DIR/gh" <<'MOCK_EOF'
#!/bin/bash
case "$1" in
  issue)
    case "$2" in
      create)
        echo '{"url": "https://github.com/test/test/issues/1", "number": 1}'
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

ORCHESTRATOR="$SCRIPT_DIR/manul-orchestrator.sh"
REVIEWER="$SCRIPT_DIR/orchestrator-reviewer.sh"
PROMPT="$SCRIPT_DIR/orchestrator.prompt.md"
CONTRACTS="$SCRIPT_DIR/CONTRACTS.md"
SKILL="$SCRIPT_DIR/SKILL.md"

PASSED=0
FAILED=0
TESTS_RUN=0

pass_test() { PASSED=$((PASSED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  PASS: $1"; }
fail_test() { FAILED=$((FAILED + 1)); TESTS_RUN=$((TESTS_RUN + 1)); echo "  FAIL: $1"; }
run_test() { local name="$1"; local func="$2"; set +e; "$func"; local rc=$?; set -e; [ $rc -eq 0 ] && pass_test "$name" || fail_test "$name"; }

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# Helper: run orchestrator with test env
orch() {
  local effective_db="${MANUL_DB:-$MANUL_DIR/state/manul.db}"
  ORCHESTRATOR_DIR="$ORCHESTRATOR_DIR" \
  MANUL_DIR="$MANUL_DIR" \
  MANUL_DB="$effective_db" \
  DB="$effective_db" \
  bash "$ORCHESTRATOR" "$@"
}

# Helper: mark all tasks for conversation as completed
complete_all_tasks() {
  local conv_id="$1"
  sqlite3 "$ORCH_DB" "UPDATE task_history SET status='completed', completedAt='$(date -u +%Y-%m-%dT%H:%M:%SZ)' WHERE conversationId='$(sql_escape "$conv_id")';"
}

# Test 1: Create conversation
test_create() {
  local output conv_id
  output="$(orch create --repo "test/test" --title "Test" --prompt "Implement feature" --json 2>/dev/null)" || return 1
  echo "$output" | jq empty 2>/dev/null || return 1
  conv_id="$(echo "$output" | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
}

# Test 2: Submit task
test_submit() {
  local conv_id output task_id
  conv_id="$(orch create --repo "test/test" --title "Test" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
  output="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --json 2>/dev/null)" || return 1
  echo "$output" | jq empty 2>/dev/null || return 1
  task_id="$(echo "$output" | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1
}

# Test 3: Approved review
test_approve() {
  local conv_id task_id output decision
  conv_id="$(orch create --repo "test/test" --title "Test" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
  task_id="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1
  output="$(orch review --task-id "$task_id" --decision APPROVE --json 2>/dev/null)" || return 1
  decision="$(echo "$output" | jq -r '.decision // empty')"
  [ "$decision" = "APPROVE" ] || return 1
}

# Test 4: Request changes
test_request_changes() {
  local conv_id task_id output decision
  conv_id="$(orch create --repo "test/test" --title "Test" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
  task_id="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1
  output="$(orch review --task-id "$task_id" --decision REQUEST_CHANGES --json 2>/dev/null)" || return 1
  decision="$(echo "$output" | jq -r '.decision // empty')"
  [ "$decision" = "REQUEST_CHANGES" ] || return 1
}

# Test 5: Submit review-fix
test_review_fix() {
  local conv_id task_id output fix_task_id
  conv_id="$(orch create --repo "test/test" --title "Test" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
  task_id="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1
  output="$(orch fix --conversation-id "$conv_id" --prompt "Fix issues" --task-id "$task_id" --pr-number 100 --json 2>/dev/null)" || return 1
  fix_task_id="$(echo "$output" | jq -r '.taskId // empty')"
  [ -n "$fix_task_id" ] || return 1
}

# Test 6: Close conversation
test_close() {
  local conv_id task_id output
  conv_id="$(orch create --repo "test/test" --title "Test" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
  task_id="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1
  # Mark all tasks as completed so close can succeed
  complete_all_tasks "$conv_id"
  output="$(orch close --conversation-id "$conv_id" --json 2>/dev/null)" || return 1
  echo "$output" | jq empty 2>/dev/null || return 1
}

# Test 7: JSON purity
test_json_purity() {
  local output
  output="$(orch create --repo "test/test" --title "JSON" --prompt "Test" --json 2>/dev/null)" || true
  [ -n "$output" ] && echo "$output" | jq empty 2>/dev/null
}

# Test 8: Exit codes
test_exit_codes() {
  orch create --repo "test/test" 2>/dev/null && return 1
  [ $? -eq 3 ] || return 1
}

# Test 9: Dry-run
test_dry_run() {
  local output dry_run
  output="$(orch create --repo "test/test" --title "Dry" --prompt "Test" --dry-run --json 2>/dev/null)" || return 1
  dry_run="$(echo "$output" | jq -r '.dryRun // false')"
  [ "$dry_run" = "true" ] || return 1
}

# Test 10: Mock reviewer
test_mock_reviewer() {
  local output decision
  output="$(bash "$REVIEWER" approve --task-id "test-123" --json 2>/dev/null)" || return 1
  decision="$(echo "$output" | jq -r '.decision // empty')"
  [ "$decision" = "APPROVE" ] || return 1
}

# Test 11: Production safety
test_production_safety() {
  [ "$MANUL_DIR" != "${HOME}/.manul" ] || return 1
  [ "$ORCHESTRATOR_DIR" != "${HOME}/.manul" ] || return 1
}

# Test 12: End-to-end mock scenario
test_end_to_end() {
  local conv_id task_id fix_task_id
  conv_id="$(orch create --repo "test/test" --title "E2E" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1

  task_id="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --pr-number 100 --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1

  # Mark all tasks as completed
  complete_all_tasks "$conv_id"

  # Submit review-fix
  fix_task_id="$(orch fix --conversation-id "$conv_id" --prompt "Fix" --task-id "$task_id" --pr-number 100 --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$fix_task_id" ] || return 1
  case "$fix_task_id" in
    "review-fix-${conv_id}-orchestrator-fix-"*) ;;
    *) echo "fix task id is not deterministic from the parent task: $fix_task_id" >&2; return 1 ;;
  esac

  # Mark fix task as completed too
  complete_all_tasks "$conv_id"

  # Verify same PR in orchestrator DB
  local fix_pr
  fix_pr="$(sqlite3 "$ORCH_DB" "SELECT prNumber FROM task_history WHERE taskId='$(sql_escape "$fix_task_id")';" 2>/dev/null)"
  [ "$fix_pr" = "100" ] || return 1

  # Verify conversationId
  local fix_conv
  fix_conv="$(sqlite3 "$ORCH_DB" "SELECT conversationId FROM task_history WHERE taskId='$(sql_escape "$fix_task_id")';" 2>/dev/null)"
  [ "$fix_conv" = "$conv_id" ] || return 1

  # Verify parentTaskId
  local fix_parent
  fix_parent="$(sqlite3 "$ORCH_DB" "SELECT parentTaskId FROM task_history WHERE taskId='$(sql_escape "$fix_task_id")';" 2>/dev/null)"
  [ "$fix_parent" = "$task_id" ] || return 1
}

# Test 13: Wait command handles missing DB
test_wait_missing_db() {
  local output rc=0
  output="$(MANUL_DB="$TEST_DIR/missing-manul.db" orch wait --task-id "nonexistent" --timeout 1 --json 2>/dev/null)" || rc=$?
  [ "$rc" -eq 2 ] || {
    echo "expected wait to return exit code 2 for a missing database, got $rc" >&2
    return 1
  }
  printf '%s\n' "$output" | jq -e '.status == "not_found"' >/dev/null 2>&1 || {
    echo "expected a machine-readable not_found result, got: $output" >&2
    return 1
  }
  [ ! -e "$TEST_DIR/missing-manul.db" ] || {
    echo "wait lookup unexpectedly created the missing Manul database" >&2
    return 1
  }
}

# Test 14: Max review cycles enforced
test_max_review_cycles() {
  local conv_id task_id fix1 fix2 output
  conv_id="$(orch create --repo "test/test" --title "MaxCycles" --prompt "Implement" --json 2>/dev/null | jq -r '.conversationId // empty')"
  [ -n "$conv_id" ] || return 1
  task_id="$(orch submit --conversation-id "$conv_id" --prompt "Implement" --action IMPLEMENT --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$task_id" ] || return 1
  orch review --task-id "$task_id" --decision REQUEST_CHANGES --json 2>/dev/null >/dev/null
  fix1="$(orch fix --conversation-id "$conv_id" --prompt "Fix" --task-id "$task_id" --pr-number 100 --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$fix1" ] || return 1
  orch review --task-id "$fix1" --decision REQUEST_CHANGES --json 2>/dev/null >/dev/null
  fix2="$(orch fix --conversation-id "$conv_id" --prompt "Fix2" --task-id "$fix1" --pr-number 100 --json 2>/dev/null | jq -r '.taskId // empty')"
  [ -n "$fix2" ] || return 1
  orch review --task-id "$fix2" --decision REQUEST_CHANGES --json 2>/dev/null >/dev/null
  # 4th fix should fail
  if orch fix --conversation-id "$conv_id" --prompt "Fix3" --task-id "$fix2" --pr-number 100 --json 2>/dev/null; then return 1; fi
}

# Test 15: manul-wait.sh exists and is executable
test_wait_script_exists() {
  [ -f "$SCRIPT_DIR/manul-wait.sh" ]
  [ -x "$SCRIPT_DIR/manul-wait.sh" ]
}


# Test 16: Non-trivial task checkpoint/delivery protocol
test_checkpoint_protocol() {
  grep -q 'Mandatory progress checkpoint protocol' "$PROMPT" || return 1
  grep -q 'create a checkpoint' "$PROMPT" || return 1
  grep -q 'commit and push it before starting the next high-risk' "$PROMPT" || return 1
  grep -q 'verify the remote branch/PR head SHA' "$PROMPT" || return 1
  grep -q 'On a retry or resumed execution' "$PROMPT" || return 1
  grep -q 'stop making further repository changes' "$PROMPT" || return 1
  grep -q "existing PR review/fix task" "$PROMPT" || return 1

  grep -q 'agent MUST NOT accumulate all' "$CONTRACTS" || return 1
  grep -q 'the agent MUST commit and' "$CONTRACTS" || return 1
  grep -q 'Runtime/LLM failure is not evidence' "$CONTRACTS" || return 1

  grep -q 'MUST create a checkpoint commit and push it' "$SKILL" || return 1
  grep -q 'checkpoints MUST be pushed to the PR' "$SKILL" || return 1
  grep -q 'verify the remote/PR head SHA' "$SKILL" || return 1
}

echo "═══════════════════════════════════════════════════════════════"
echo "  Orchestrator Tests"
echo "═══════════════════════════════════════════════════════════════"

run_test "create conversation" test_create
run_test "submit task" test_submit
run_test "approved review" test_approve
run_test "request changes review" test_request_changes
run_test "submit review-fix" test_review_fix
run_test "close conversation" test_close
run_test "JSON purity" test_json_purity
run_test "exit codes" test_exit_codes
run_test "dry-run mode" test_dry_run
run_test "mock reviewer" test_mock_reviewer
run_test "production safety" test_production_safety
run_test "full end-to-end mock scenario" test_end_to_end
run_test "wait handles missing DB" test_wait_missing_db
run_test "max review cycles enforced" test_max_review_cycles
run_test "wait script exists" test_wait_script_exists
run_test "checkpoint and delivery protocol" test_checkpoint_protocol

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed (out of $TESTS_RUN tests)"
echo "═══════════════════════════════════════════════════════════════"
[ "$FAILED" -eq 0 ]
