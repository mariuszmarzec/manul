#!/usr/bin/env bash
# Controller classification regression tests:
# a timed-out session is not automatically safe to resume.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export MANUL_DIR="$TEST_ROOT/manul"
mkdir -p "$MANUL_DIR/state/tasks" "$MANUL_DIR/logs"
cat >"$MANUL_DIR/config.json" <<'JSON'
{"automation":{"agentRuntime":"opencode"}}
JSON

source "$SCRIPT_DIR/agent-execution-controller.sh"

# Replace only the executor boundary. The production controller and its
# timeout/result classification remain under test.
AgentExecutor.execute() {
  printf '%s\n' "$CONTROLLER_FIXTURE_RESULT"
  return "${CONTROLLER_FIXTURE_RC:-0}"
}

CTX_FILE="$TEST_ROOT/context.json"
STDOUT_FILE="$TEST_ROOT/runtime.stdout"
RESULT_FILE="$TEST_ROOT/result.json"
jq -n --arg taskId "controller-timeout" --arg stdout "$STDOUT_FILE" \
  '{taskId:$taskId,stdout_file:$stdout}' >"$CTX_FILE"
: >"$STDOUT_FILE"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

run_controller() {
  local fixture="$1" rc="$2"
  export CONTROLLER_FIXTURE_RESULT="$fixture"
  export CONTROLLER_FIXTURE_RC="$rc"
  set +e
  AgentExecutionController.execute "$CTX_FILE" >"$RESULT_FILE"
  CONTROLLER_RC=$?
  set -e
}

assert_timeout_does_not_continue() {
  local failure_code="$1" description="$2"
  local fixture
  fixture="$(jq -cn --arg fc "$failure_code" \
    '{status:"TIMEOUT",task_id:"controller-timeout",exit_code:124,summary:"runtime timed out",session_id:"ses-existing",duration_s:10,failure_code:$fc}')"
  : >"$STDOUT_FILE"
  run_controller "$fixture" 124
  if [ "$(jq -r '.status' "$RESULT_FILE")" = "TIMEOUT" ]; then
    ok "$description remains TIMEOUT"
  else
    fail "$description was converted to $(jq -r '.status' "$RESULT_FILE")"
  fi
  if [ "$(jq -r '.failure_code' "$RESULT_FILE")" = "$failure_code" ]; then
    ok "$description preserves its failure code"
  else
    fail "$description failure code was overwritten"
  fi
  if [ -z "$AgentExecutionController_SessionId" ]; then
    ok "$description clears the continuation session pointer"
  else
    fail "$description retained session $AgentExecutionController_SessionId"
  fi
}

assert_timeout_does_not_continue "RUNTIME_TIMEOUT" "overall runtime timeout"
assert_timeout_does_not_continue "AGENT_NO_PROGRESS_TIMEOUT" "no-progress watchdog timeout"
assert_timeout_does_not_continue "AGENT_STEP_NO_PROGRESS_TIMEOUT" "active-step watchdog timeout"
assert_timeout_does_not_continue "AGENT_TOOL_NO_PROGRESS_TIMEOUT" "active-tool watchdog timeout"

# The controller may still accept a completed task when TASK_DONE was already
# emitted before a timeout killed the runtime.
printf '%s\n' 'TASK_DONE completed-before-watchdog' >"$STDOUT_FILE"
fixture="$(jq -cn '{status:"TIMEOUT",task_id:"controller-timeout",exit_code:124,summary:"wrapper timeout",session_id:"ses-done",duration_s:10,failure_code:"RUNTIME_TIMEOUT"}')"
run_controller "$fixture" 124
[ "$(jq -r '.status' "$RESULT_FILE")" = "COMPLETED" ] && ok "TASK_DONE already on disk overrides timeout" || fail "TASK_DONE timeout was not completed"

# Only an adapter's explicit NEEDS_CONTINUATION is resumable.
: >"$STDOUT_FILE"
fixture="$(jq -cn '{status:"NEEDS_CONTINUATION",task_id:"controller-timeout",exit_code:1,summary:"step limit reached",session_id:"ses-step-limit",duration_s:10,failure_code:"NEEDS_CONTINUATION"}')"
run_controller "$fixture" 1
[ "$(jq -r '.status' "$RESULT_FILE")" = "NEEDS_CONTINUATION" ] && ok "explicit adapter continuation status is preserved" || fail "explicit continuation status was changed"
[ "$AgentExecutionController_SessionId" = "ses-step-limit" ] && ok "explicit continuation retains the session ID" || fail "explicit continuation lost the session ID"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
