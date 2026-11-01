#!/usr/bin/env bash
# test_agent_execution_smoke.sh — production executor-boundary smoke test.
#
# Exercises the exact process boundary used by manul-daemon.sh:
#
#   daemon dispatch line
#     -> setsid
#     -> agent-task-runner
#     -> AgentExecutionController
#     -> AgentExecutor
#     -> OpenClawAdapter
#     -> ProcessRunner
#     -> fake OpenClaw executable
#
# GitHub, SQLite state, OpenClaw gateway state, and the production ~/.manul
# runtime are never touched. Control-plane scheduling is intentionally outside
# this test; the execution boundary itself is real.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT="$(mktemp -d /tmp/manul-exec-smoke-XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MANUL_DIR="$TEST_ROOT/manul"
mkdir -p "$MANUL_DIR/state/tasks" "$MANUL_DIR/state/locks" "$MANUL_DIR/logs"

cat >"$MANUL_DIR/config.json" <<'JSON'
{
  "agents": ["coder", "coder-cheap"],
  "automation": {
    "agentRuntime": "openclaw"
  }
}
JSON

WORKSPACE="$MANUL_DIR/workspace/ws-smoke"
WORKDIR="$WORKSPACE/repos/test-owner/test-repo"
mkdir -p "$WORKDIR"

PROMPT_FILE="$MANUL_DIR/state/tasks/smoke.prompt.md"
printf '%s\n' 'Execute the executor-boundary smoke test.' >"$PROMPT_FILE"

# Regression guard: the prompt contract must keep implementation agents inside
# their task workspace and must not direct them to read private/global paths.
if ! grep -Fq '## Task Workspace and Local-Access Boundary' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: generated task prompt is missing the local-access boundary" >&2
  exit 1
fi
if grep -Fq 'read and follow `~/.agents/skills/feature-branching-strategy/SKILL.md`' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: generated task prompt still directs agents to read a global skill path" >&2
  exit 1
fi
if grep -Fq 'Your skills are available at: ~/.agents/skills' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: generated task prompt still advertises the global skills directory" >&2
  exit 1
fi
for protected_path in 'configured Manul workspace tree' '~/.agents/**' '~/.config/opencode/**'; do
  if ! grep -Fq "$protected_path" "$SCRIPT_DIR/manul-daemon.sh"; then
    echo "FAIL: generated task prompt does not protect $protected_path" >&2
    exit 1
  fi
done

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
PROOF_FILE="$TEST_ROOT/openclaw-proof"

cat >"$FAKE_BIN/openclaw" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' >>"$SMOKE_PROOF_FILE"
printf 'args=%s\n' "$*" >>"$SMOKE_PROOF_FILE"
printf 'task_id=%s\n' "$(printenv MANUL_TASK_ID)" >>"$SMOKE_PROOF_FILE"
printf 'workspace=%s\n' "$(printenv WORKSPACE)" >>"$SMOKE_PROOF_FILE"
if [ -e "/proc/$$/fd/210" ]; then
  printf 'lock_fd=present\n' >>"$SMOKE_PROOF_FILE"
else
  printf 'lock_fd=absent\n' >>"$SMOKE_PROOF_FILE"
fi
printf 'TASK_DONE smoke-agent-completed\n'
MOCK
chmod +x "$FAKE_BIN/openclaw"

CTX_FILE="$MANUL_DIR/state/tasks/smoke.ctx.json"
RESULT_FILE="$MANUL_DIR/state/tasks/smoke.executor-result"
STDOUT_FILE="$MANUL_DIR/state/tasks/smoke.stdout"
STDERR_FILE="$MANUL_DIR/state/tasks/smoke.stderr"
EXECUTOR_PID_FILE="$MANUL_DIR/smoke-execution-1.executor.pid"

jq -n \
  --arg taskId "smoke-execution-1" \
  --arg prompt "$PROMPT_FILE" \
  --arg workspace "$WORKSPACE" \
  --arg workspaceRoot "$WORKSPACE" \
  --arg workdir "$WORKDIR" \
  --arg stdoutFile "$STDOUT_FILE" \
  --arg stderrFile "$STDERR_FILE" \
  '{
    taskId: $taskId,
    prompt: $prompt,
    workspace: $workspace,
    workspaceRoot: $workspaceRoot,
    workdir: $workdir,
    agent: "",
    attempt: 1,
    timeout: 30,
    session_id: "",
    stdout_file: $stdoutFile,
    stderr_file: $stderrFile
  }' >"$CTX_FILE"

export MANUL_DIR
export AGENT_RUNTIME=openclaw
export OPENCLAW_BIN="$FAKE_BIN/openclaw"
export SMOKE_PROOF_FILE="$PROOF_FILE"
export PATH="$FAKE_BIN:$PATH"

# Require the production daemon to close its dispatcher-lock descriptor before
# launching the isolated executor.
if ! grep -Fq 'setsid --wait "$DAEMON_SCRIPT_DIR/agent-task-runner.sh" "$EXEC_CTX_FILE" "$executor_pid_file" 210>&-' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon must close dispatcher lock FD 210 before launching the isolated executor" >&2
  exit 1
fi
if ! grep -Fq -- '--arg agent "${AGENT:-}"' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon must propagate the persisted agent into the execution context" >&2
  exit 1
fi

# Hold the dispatcher lock in this test process. The production executor must
# not inherit descriptor 210 or it could keep the lock alive after this process
# dies/restarts.
LOCK_FILE="$MANUL_DIR/state/locks/task-dispatch.flock"
exec 210>"$LOCK_FILE"
flock -n 210 || { echo "FAIL: could not acquire test dispatcher lock" >&2; exit 1; }

set +e
setsid --wait "$SCRIPT_DIR/agent-task-runner.sh" \
  "$CTX_FILE" \
  "$EXECUTOR_PID_FILE" \
  210>&- \
  >"$RESULT_FILE" \
  2>"$TEST_ROOT/launcher.stderr"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "FAIL: production executor boundary returned rc=$RC" >&2
  echo "--- launcher stderr ---" >&2
  cat "$TEST_ROOT/launcher.stderr" >&2 || true
  echo "--- adapter stderr ---" >&2
  cat "$STDERR_FILE" >&2 || true
  echo "--- executor result ---" >&2
  cat "$RESULT_FILE" >&2 || true
  exit 1
fi

if [ ! -f "$EXECUTOR_PID_FILE" ]; then
  echo "FAIL: agent-task-runner did not publish its task-local PID" >&2
  exit 1
fi
rm -f "$EXECUTOR_PID_FILE"

if [ ! -s "$RESULT_FILE" ]; then
  echo "FAIL: agent-task-runner produced no controller result" >&2
  exit 1
fi

jq -e \
  --arg taskId "smoke-execution-1" \
  '.status == "COMPLETED" and .task_id == $taskId and .exit_code == 0 and (.summary | contains("smoke-agent-completed"))' \
  "$RESULT_FILE" >/dev/null || {
    echo "FAIL: controller/executor returned unexpected result:" >&2
    cat "$RESULT_FILE" >&2
    exit 1
  }

if [ ! -s "$PROOF_FILE" ]; then
  echo "FAIL: fake OpenClaw was never invoked" >&2
  exit 1
fi

grep -q '^called$' "$PROOF_FILE" || { echo "FAIL: fake OpenClaw call marker missing" >&2; exit 1; }
grep -q -- 'agent' "$PROOF_FILE" || { echo "FAIL: OpenClawAdapter did not invoke the agent command" >&2; exit 1; }
grep -q -- '--agent main' "$PROOF_FILE" || { echo "FAIL: OpenClawAdapter lost the default main agent" >&2; exit 1; }
grep -q 'task_id=smoke-execution-1' "$PROOF_FILE" || { echo "FAIL: task ID was not propagated to OpenClaw" >&2; exit 1; }
grep -q "workspace=$WORKSPACE" "$PROOF_FILE" || { echo "FAIL: workspace was not propagated to OpenClaw" >&2; exit 1; }
grep -q '^lock_fd=absent$' "$PROOF_FILE" || {
  echo "FAIL: agent runtime inherited task-dispatch lock FD 210" >&2
  cat "$PROOF_FILE" >&2
  exit 1
}

if flock -n "$LOCK_FILE" -c true 2>/dev/null; then
  echo "FAIL: parent lost its dispatcher lock while the executor was running" >&2
  exit 1
fi
flock -u 210
exec 210>&-

grep -q '^TASK_DONE smoke-agent-completed$' "$STDOUT_FILE" || {
  echo "FAIL: TASK_DONE was not preserved through ProcessRunner" >&2
  exit 1
}

if [ -s "$STDERR_FILE" ]; then
  if grep -qiE 'error|failed|permission denied|not found' "$STDERR_FILE"; then
    echo "FAIL: execution produced unexpected adapter stderr:" >&2
    cat "$STDERR_FILE" >&2
    exit 1
  fi
fi

echo "PASS: daemon dispatch -> agent-task-runner -> controller -> executor -> OpenClawAdapter -> ProcessRunner -> fake OpenClaw"
echo "PASS: execution result JSON, task metadata, dispatcher lock isolation and TASK_DONE crossed the boundary"
echo "PASS: task-local executor PID was created and cleaned up"

# Validate explicit OpenCode role routing with a fake CLI.
OPENCODE_PROOF_FILE="$TEST_ROOT/opencode-proof"
cat >"$FAKE_BIN/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' 'caracal-rag connected'
  exit 0
fi
printf 'called\n' >>"$OPENCODE_PROOF_FILE"
printf 'args=%s\n' "$*" >>"$OPENCODE_PROOF_FILE"
printf '%s\n' '{"type":"text","part":{"text":"TASK_DONE opencode-role-routing"}}'
MOCK
chmod +x "$FAKE_BIN/opencode"
export OPENCODE_PROOF_FILE
export AGENT_RUNTIME=opencode
export OPENCODE_BIN="$FAKE_BIN/opencode"
export CARACAL_MCP_URL="http://127.0.0.1:3500/mcp"
export CARACAL_ACCESS_TOKEN="test-caracal-token"

OPENCODE_CTX_FILE="$MANUL_DIR/state/tasks/opencode-role.ctx.json"
OPENCODE_RESULT_FILE="$MANUL_DIR/state/tasks/opencode-role.executor-result"
OPENCODE_STDOUT_FILE="$MANUL_DIR/state/tasks/opencode-role.stdout"
OPENCODE_STDERR_FILE="$MANUL_DIR/state/tasks/opencode-role.stderr"
OPENCODE_PID_FILE="$MANUL_DIR/opencode-role.executor.pid"
jq -n \
  --arg taskId "smoke-opencode-role" \
  --arg prompt "$PROMPT_FILE" \
  --arg workspace "$WORKSPACE" \
  --arg workspaceRoot "$WORKSPACE" \
  --arg workdir "$WORKDIR" \
  --arg stdoutFile "$OPENCODE_STDOUT_FILE" \
  --arg stderrFile "$OPENCODE_STDERR_FILE" \
  --arg agent "coder-cheap" \
  '{
    taskId: $taskId,
    prompt: $prompt,
    workspace: $workspace,
    workspaceRoot: $workspaceRoot,
    workdir: $workdir,
    agent: $agent,
    agentSelection: "explicit",
    attempt: 1,
    timeout: 30,
    session_id: "",
    stdout_file: $stdoutFile,
    stderr_file: $stderrFile
  }' >"$OPENCODE_CTX_FILE"

set +e
setsid --wait "$SCRIPT_DIR/agent-task-runner.sh" \
  "$OPENCODE_CTX_FILE" "$OPENCODE_PID_FILE" 210>&- \
  >"$OPENCODE_RESULT_FILE" 2>"$TEST_ROOT/opencode-launcher.stderr"
OPENCODE_RC=$?
set -e
if [ "$OPENCODE_RC" -ne 0 ]; then
  echo "FAIL: explicit OpenCode role execution returned rc=$OPENCODE_RC" >&2
  cat "$TEST_ROOT/opencode-launcher.stderr" "$OPENCODE_STDERR_FILE" "$OPENCODE_RESULT_FILE" >&2 || true
  exit 1
fi
jq -e --arg taskId "smoke-opencode-role" \
  '.status == "COMPLETED" and .task_id == $taskId and (.summary | contains("opencode-role-routing"))' \
  "$OPENCODE_RESULT_FILE" >/dev/null || {
    echo "FAIL: explicit OpenCode role execution did not complete:" >&2
    cat "$OPENCODE_RESULT_FILE" >&2
    exit 1
  }
grep -q '^called$' "$OPENCODE_PROOF_FILE" || { echo "FAIL: fake OpenCode was not invoked" >&2; exit 1; }
grep -q '^args=.*--agent coder-cheap' "$OPENCODE_PROOF_FILE" || {
  echo "FAIL: selected coder role did not reach OpenCode CLI" >&2
  cat "$OPENCODE_PROOF_FILE" >&2
  exit 1
}

# --auto is OpenCode-only: it overrides both OpenClaw runtime settings.
export AGENT_RUNTIME=openclaw
export ROLE_RUNTIME=openclaw
ROLE_CTX_FILE="$MANUL_DIR/state/tasks/openclaw-role.ctx.json"
ROLE_RESULT_FILE="$MANUL_DIR/state/tasks/openclaw-role.executor-result"
ROLE_STDOUT_FILE="$MANUL_DIR/state/tasks/openclaw-role.stdout"
ROLE_STDERR_FILE="$MANUL_DIR/state/tasks/openclaw-role.stderr"
ROLE_PID_FILE="$MANUL_DIR/openclaw-role.executor.pid"
jq -n \
  --arg taskId "smoke-openclaw-role" \
  --arg prompt "$PROMPT_FILE" \
  --arg workspace "$WORKSPACE" \
  --arg workspaceRoot "$WORKSPACE" \
  --arg workdir "$WORKDIR" \
  --arg stdoutFile "$ROLE_STDOUT_FILE" \
  --arg stderrFile "$ROLE_STDERR_FILE" \
  --arg agent "coder-cheap" \
  '{
    taskId: $taskId,
    prompt: $prompt,
    workspace: $workspace,
    workspaceRoot: $workspaceRoot,
    workdir: $workdir,
    agent: $agent,
    agentSelection: "explicit",
    autoAccept: true,
    attempt: 1,
    timeout: 30,
    session_id: "",
    stdout_file: $stdoutFile,
    stderr_file: $stderrFile
  }' >"$ROLE_CTX_FILE"

set +e
setsid --wait "$SCRIPT_DIR/agent-task-runner.sh" \
  "$ROLE_CTX_FILE" "$ROLE_PID_FILE" 210>&- \
  >"$ROLE_RESULT_FILE" 2>"$TEST_ROOT/role-launcher.stderr"
ROLE_RC=$?
set -e
if [ "$ROLE_RC" -ne 0 ]; then
  echo "FAIL: role routing from OpenClaw runtime returned rc=$ROLE_RC" >&2
  cat "$TEST_ROOT/role-launcher.stderr" "$ROLE_STDERR_FILE" "$ROLE_RESULT_FILE" >&2 || true
  exit 1
fi
jq -e --arg taskId "smoke-openclaw-role" \
  '.status == "COMPLETED" and .task_id == $taskId and (.summary | contains("opencode-role-routing"))' \
  "$ROLE_RESULT_FILE" >/dev/null || {
    echo "FAIL: explicit role routed from OpenClaw runtime did not complete:" >&2
    cat "$ROLE_RESULT_FILE" >&2
    exit 1
  }
if [ "$(grep -c '^called$' "$PROOF_FILE")" -ne 1 ]; then
  echo "FAIL: an explicit role must not run OpenClaw main" >&2
  cat "$PROOF_FILE" >&2
  exit 1
fi
if [ "$(grep -c '^called$' "$OPENCODE_PROOF_FILE")" -ne 2 ]; then
  echo "FAIL: explicit role was not routed through OpenCode exactly once" >&2
  cat "$OPENCODE_PROOF_FILE" >&2
  exit 1
fi
grep -q '^args=.*--auto' "$OPENCODE_PROOF_FILE" || {
  echo "FAIL: --auto was not forwarded to OpenCode for the auto task" >&2
  cat "$OPENCODE_PROOF_FILE" >&2
  exit 1
}
if [ "$(grep -c '^args=.*--auto' "$OPENCODE_PROOF_FILE")" -ne 1 ]; then
  echo "FAIL: --auto must reach exactly the task that requested it" >&2
  cat "$OPENCODE_PROOF_FILE" >&2
  exit 1
fi
grep -q '^args=.*--agent coder-cheap' "$OPENCODE_PROOF_FILE" || {
  echo "FAIL: selected coder role did not reach OpenCode CLI" >&2
  cat "$OPENCODE_PROOF_FILE" >&2
  exit 1
}

echo "PASS: --auto overrides OpenClaw routing and reaches OpenCode's native CLI flag"
