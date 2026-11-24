#!/usr/bin/env bash
# Regression: a clean, non-empty tool-free OpenCode operator answer may omit
# TASK_DONE; repository implementation work must still fail closed.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

MANUL_DIR="$TMP/manul"
MANUL_WORKSPACE="$MANUL_DIR/workspace"
HOME_DIR="$TMP/home"
FAKE_BIN="$TMP/bin"
mkdir -p "$MANUL_DIR" "$MANUL_WORKSPACE/operator-query/oq-fixture" \
  "$MANUL_WORKSPACE/ws-fixture" "$HOME_DIR/.config" "$FAKE_BIN"

cat >"$MANUL_DIR/config.json" <<'JSON'
{
  "automation": {
    "agentRuntime": "opencode",
    "agentTimeoutSeconds": 60,
    "agentNoProgressTimeoutSeconds": 10,
    "agentToolNoProgressTimeoutSeconds": 10,
    "agentStepNoProgressTimeoutSeconds": 10
  }
}
JSON

cat >"$FAKE_BIN/opencode" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  debug)
    [ "${2:-}" = "agents" ] || { echo "unexpected OpenCode debug invocation" >&2; exit 91; }
    printf '%s\n' '[{"id":"manul-operator-query"}]'
    ;;
  run)
    # Operator-query must remain tool-free even when this adapter accepts a
    # clean response without its optional TASK_DONE marker.
    if [ "${MANUL_TASK_EXECUTION_KIND:-}" = "operator_query" ]; then
      printf '%s' "${OPENCODE_CONFIG_CONTENT:-}" |
        jq -e '.model == null and .provider == null and .tools["*"] == false and .agent["manul-operator-query"].tools["*"] == false' >/dev/null
    fi
    # Deliberately return a useful text event and session ID, but no TASK_DONE.
    printf '%s\n' '{"type":"text","timestamp":1,"sessionID":"ses-no-marker","part":{"type":"text","text":"Operator answer: one task is running."}}'
    ;;
  *)
    echo "unexpected OpenCode invocation" >&2
    exit 91
    ;;
esac
FAKE
chmod 700 "$FAKE_BIN/opencode"

run_case() {
  local task_id="$1" execution_kind="$2" workspace="$3"
  local prompt="$workspace/prompt.md" context="$workspace/context.json"
  local stdout="$workspace/stdout" stderr="$workspace/stderr"
  mkdir -p "$workspace"
  printf '%s\n' 'Answer using the provided context.' >"$prompt"
  chmod 700 "$workspace"

  jq -n \
    --arg taskId "$task_id" \
    --arg prompt "$prompt" \
    --arg workspace "$workspace" \
    --arg stdout "$stdout" \
    --arg stderr "$stderr" \
    --arg executionKind "$execution_kind" \
    '{taskId:$taskId,prompt:$prompt,workspace:$workspace,workspaceRoot:$workspace,workdir:"",executionKind:$executionKind,agent:"",attempt:1,timeout:30,session_id:"",stdout_file:$stdout,stderr_file:$stderr}' \
    >"$context"

  local result rc=0
  result="$(
    HOME="$HOME_DIR" \
    XDG_CONFIG_HOME="$HOME_DIR/.config" \
    MANUL_DIR="$MANUL_DIR" \
    MANUL_WORKSPACE="$MANUL_WORKSPACE" \
    MANUL_TASKS_DIR="$workspace/tasks" \
    MANUL_TASK_LOG_DIR="$workspace/logs" \
    AGENT_RUNTIME=opencode \
    OPENCODE_BIN="$FAKE_BIN/opencode" \
    PATH="$FAKE_BIN:$PATH" \
    bash -c 'source "$1/agent-execution-controller.sh"; AgentExecutionController.execute "$2"' \
      _ "$SCRIPT_DIR" "$context"
  )" || rc=$?
  printf '%s\n' "$result" >"$workspace/result.json"
  printf '%s\n' "$rc" >"$workspace/controller-exit-code"
}

OPERATOR_WORKSPACE="$MANUL_WORKSPACE/operator-query/oq-fixture"
run_case operator-query-fixture operator_query "$OPERATOR_WORKSPACE"

jq -e '
  .status == "COMPLETED"
  and .runtime == "opencode"
  and .exit_code == 0
  and (.summary | contains("operator-query answer"))
' "$OPERATOR_WORKSPACE/result.json" >/dev/null
grep -Fxq 'Operator answer: one task is running.' "$OPERATOR_WORKSPACE/stdout"
! grep -q '^TASK_DONE$' "$OPERATOR_WORKSPACE/stdout"
[ "$(cat "$OPERATOR_WORKSPACE/controller-exit-code")" = "0" ]
echo "PASS: clean non-empty tool-free operator answer completes without TASK_DONE"

REPOSITORY_WORKSPACE="$MANUL_WORKSPACE/ws-fixture"
run_case repository-fixture repository "$REPOSITORY_WORKSPACE"

jq -e '
  .status == "FAILED"
  and .failure_code == "RUNTIME_FAILURE"
  and (.summary | contains("without a completion marker"))
' "$REPOSITORY_WORKSPACE/result.json" >/dev/null
[ "$(cat "$REPOSITORY_WORKSPACE/controller-exit-code")" -ne 0 ]
echo "PASS: repository execution still fails closed when TASK_DONE is missing"
