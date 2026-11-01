#!/usr/bin/env bash
# Hermetic contract tests for Codex CLI and Claude Code adapters.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
assert_json() {
  if jq -e "$2" "$1" >/dev/null; then ok "$3"; else no "$3"; cat "$1" >&2; fi
}
mkdir -p "$TMP/bin" "$TMP/workspace" "$TMP/runtime" "$TMP/logs"
printf 'Task prompt input\n' > "$TMP/prompt"

cat > "$TMP/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$MOCK_ARGS_FILE"
cat > "$MOCK_PROMPT_FILE"
printf '%s\n' '{"type":"thread.started","thread_id":"codex-test-session"}'
if [ "$MOCK_MODE" = "missing-marker" ]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"finished without lifecycle marker"}}'
elif [ "$MOCK_MODE" = "stale-marker" ]; then
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"TASK_DONE old turn"}}'
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Still working; no completion marker yet"}}'
else
  printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"TASK_DONE codex-adapter-test"}}'
fi
printf '%s\n' '{"type":"turn.completed"}'
MOCK
chmod +x "$TMP/bin/codex"

cat > "$TMP/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$MOCK_ARGS_FILE"
cat > "$MOCK_PROMPT_FILE"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"claude-test-session"}'
if [ "$MOCK_MODE" = "missing-marker" ]; then
  printf '%s\n' '{"type":"result","subtype":"success","result":"finished without lifecycle marker","session_id":"claude-test-session","is_error":false}'
else
  printf '%s\n' '{"type":"result","subtype":"success","result":"TASK_DONE claude-code-adapter-test","session_id":"claude-test-session","is_error":false}'
fi
MOCK
chmod +x "$TMP/bin/claude"

run_adapter() {
  runtime="$1"
  mode="$2"
  adapter="$SCRIPT_DIR/$runtime-adapter.sh"
  if [ "$runtime" = "claude-code" ]; then adapter="$SCRIPT_DIR/claude-code-adapter.sh"; fi
  if [ "$runtime" = "codex" ]; then adapter="$SCRIPT_DIR/codex-adapter.sh"; fi
  output="$TMP/$runtime-$mode.result.json"
  stdout="$TMP/$runtime-$mode.stdout"
  stderr="$TMP/$runtime-$mode.stderr"
  args="$TMP/$runtime-$mode.args"
  received="$TMP/$runtime-$mode.prompt"
  session_id="${3:-}"
  set +e
  if [ "$runtime" = "codex" ]; then
    CODEX_BIN="$TMP/bin/codex" CODEX_MODEL="mock-model" MOCK_MODE="$mode" MOCK_ARGS_FILE="$args" MOCK_PROMPT_FILE="$received" \
      MANUL_DIR="$TMP/runtime" MANUL_TASK_LOG_DIR="$TMP/logs" AGENT_RUNTIME=codex \
      bash "$adapter" --task-id "$runtime-$mode" --prompt "$TMP/prompt" --workspace "$TMP/workspace" --attempt 1 --timeout 10 --session-id "$session_id" --stdout-file "$stdout" --stderr-file "$stderr" > "$output"
  else
    CLAUDE_BIN="$TMP/bin/claude" CLAUDE_MODEL="mock-model" MOCK_MODE="$mode" MOCK_ARGS_FILE="$args" MOCK_PROMPT_FILE="$received" \
      MANUL_DIR="$TMP/runtime" MANUL_TASK_LOG_DIR="$TMP/logs" AGENT_RUNTIME=claude-code \
      bash "$adapter" --task-id "$runtime-$mode" --prompt "$TMP/prompt" --workspace "$TMP/workspace" --attempt 1 --timeout 10 --session-id "$session_id" --stdout-file "$stdout" --stderr-file "$stderr" > "$output"
  fi
  rc=$?
  set -e
  if [ "$mode" = "missing-marker" ] || [ "$mode" = "stale-marker" ]; then
    [ "$rc" -ne 0 ] && jq -e '.status == "FAILED" and .diagnostics.cause == "MISSING_TASK_MARKER"' "$output" >/dev/null \
      && ok "$runtime rejects a clean exit without TASK_DONE" || no "$runtime missing-marker handling (rc=$rc)"
    return
  fi
  [ "$rc" -eq 0 ] || { no "$runtime adapter exits successfully (rc=$rc)"; cat "$output" >&2; return; }
  assert_json "$output" '.status == "COMPLETED" and .exit_code == 0' "$runtime maps TASK_DONE to COMPLETED"
  if [ "$runtime" = "codex" ]; then
    assert_json "$output" '.session_id == "codex-test-session" and .diagnostics.runtime == "codex"' "$runtime returns session ID and runtime diagnostics"
    grep -Fq -- '--json' "$args" && ok "Codex CLI is called in JSONL mode" || no "Codex JSONL flag missing"
    grep -Fq -- '--sandbox workspace-write' "$args" && ok "Codex uses workspace-write sandbox" || no "Codex sandbox not set"
    grep -Fq -- '--ask-for-approval never' "$args" && ok "Codex uses explicit noninteractive approval policy" || no "Codex approval policy missing"
    grep -Fq -- '--model mock-model' "$args" && ok "Codex forwards configured model" || no "Codex model missing"
    if [ "$mode" = "resume" ]; then
      grep -Eq 'exec --json --cd .* --sandbox workspace-write --ask-for-approval never --model mock-model resume codex-test-session -' "$args" \
        && ok "Codex resume preserves exec-level sandbox/approval flags before the subcommand" \
        || no "Codex resume argument ordering is invalid"
    fi
  else
    assert_json "$output" '.session_id == "claude-test-session" and .diagnostics.runtime == "claude-code"' "$runtime returns session ID and runtime diagnostics"
    grep -Fq -- '--print' "$args" && ok "Claude Code uses noninteractive print mode" || no "Claude print flag missing"
    grep -Fq -- '--output-format stream-json' "$args" && ok "Claude Code emits stream-json events" || no "Claude stream-json flag missing"
    grep -Fq -- '--permission-mode acceptEdits' "$args" && ok "Claude Code uses an explicit non-bypass permission mode" || no "Claude permission mode missing"
    ! grep -Eq -- '--dangerously-skip-permissions|bypassPermissions' "$args" && ok "Claude Code adapter does not bypass permissions" || no "Claude permission bypass found"
    if [ "$mode" = "resume" ]; then
      grep -Fq -- "--resume claude-test-session" "$args" && ok "Claude Code resumes the supplied session" || no "Claude session resume flag missing"
    fi
  fi
  cmp -s "$TMP/prompt" "$received" && ok "$runtime receives the exact prompt via stdin" || no "$runtime prompt stdin mismatch"
  grep -Fq "TASK_DONE $runtime-adapter-test" "$stdout" && ok "$runtime preserves the Manul completion marker" || no "$runtime lost TASK_DONE"
}

bash -n "$SCRIPT_DIR/codex-adapter.sh" && ok "Codex adapter syntax is valid" || no "Codex adapter syntax invalid"
bash -n "$SCRIPT_DIR/claude-code-adapter.sh" && ok "Claude Code adapter syntax is valid" || no "Claude Code adapter syntax invalid"
run_adapter codex success
run_adapter codex missing-marker
run_adapter codex stale-marker
run_adapter codex resume codex-test-session
run_adapter claude-code success
run_adapter claude-code missing-marker
run_adapter claude-code resume claude-test-session

# An active tool call must pause the generic idle watchdog, but remain covered
# by the bounded tool-idle and total execution timeouts.
source "$SCRIPT_DIR/process-runner.sh"
for runtime in codex claude-code; do
  tool_stdout="$TMP/$runtime-active-tool.jsonl"
  tool_stderr="$TMP/$runtime-active-tool.stderr"
  if [ "$runtime" = "codex" ]; then
    tool_started='{"type":"item.started","item":{"id":"command-1","type":"command_execution","status":"in_progress"}}'
    tool_completed='{"type":"item.completed","item":{"id":"command-1","type":"command_execution","status":"completed","exit_code":0}}'
  else
    tool_started='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"sleep 3"}}]}}'
    tool_completed='{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"finished"}]}}'
  fi
  ProcessRunner_TmpStdout="$tool_stdout"
  ProcessRunner_TmpStderr="$tool_stderr"
  result="$(ProcessRunner.run --timeout 10 --idle-timeout 1 --idle-jsonl-file "$tool_stdout" --idle-tool-timeout 5 --cwd "$TMP/workspace" -- bash -c 'printf "%s\n" "$1"; sleep 3; printf "%s\n" "$2"' _ "$tool_started" "$tool_completed")"
  rc=$?
  header="$(printf '%s\n' "$result" | head -n 1)"
  header_rc="$(printf '%s' "$header" | cut -d'|' -f1)"
  timeout_flag="$(printf '%s' "$header" | cut -d'|' -f4)"
  [ "$rc" -eq 0 ] && [ "$header_rc" = "0" ] && [ "$timeout_flag" = "false" ] \
    && ok "$runtime active tool calls exceed the generic idle threshold without a false timeout" \
    || no "$runtime active tool call was incorrectly timed out (rc=$rc header=$header)"
done

# Route through the production AgentExecutor, not only direct adapter calls.
for runtime in codex claude-code; do
  route_runtime="$TMP/route-$runtime"
  mkdir -p "$route_runtime"
  ctx="$TMP/route-$runtime.context.json"
  route_result="$TMP/route-$runtime.result.json"
  route_stdout="$TMP/route-$runtime.stdout"
  route_stderr="$TMP/route-$runtime.stderr"
  jq -n --arg id "route-$runtime" --arg prompt "$TMP/prompt" --arg workspace "$TMP/workspace" --arg stdout "$route_stdout" --arg stderr "$route_stderr" \
    '{taskId:$id,prompt:$prompt,workspace:$workspace,workspaceRoot:$workspace,workdir:$workspace,agent:"main",attempt:1,timeout:10,session_id:"",stdout_file:$stdout,stderr_file:$stderr}' > "$ctx"
  set +e
  if [ "$runtime" = "codex" ]; then
    CODEX_BIN="$TMP/bin/codex" CODEX_MODEL="mock-model" MOCK_MODE="success" MOCK_ARGS_FILE="$TMP/route-codex.args" MOCK_PROMPT_FILE="$TMP/route-codex.prompt" MANUL_DIR="$route_runtime" AGENT_RUNTIME=codex \
      bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" > "$route_result"
  else
    CLAUDE_BIN="$TMP/bin/claude" CLAUDE_MODEL="mock-model" MOCK_MODE="success" MOCK_ARGS_FILE="$TMP/route-claude-code.args" MOCK_PROMPT_FILE="$TMP/route-claude-code.prompt" MANUL_DIR="$route_runtime" AGENT_RUNTIME=claude-code \
      bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" > "$route_result"
  fi
  route_rc=$?
  set -e
  [ "$route_rc" -eq 0 ] && jq -e '.status == "COMPLETED" and .exit_code == 0' "$route_result" >/dev/null \
    && ok "AgentExecutor dispatches tasks to $runtime" || no "AgentExecutor failed to dispatch $runtime (rc=$route_rc)"
done

# Explicit canonical roles route through ROLE_RUNTIME and receive canonical role text.
mkdir -p "$TMP/rolehome/.globalskills/agents"
cat > "$TMP/rolehome/.globalskills/agents/coder.md" <<'ROLE'
---
name: coder
description: adapter test role
---
CODER_ROLE_INSTRUCTIONS_FOR_TEST
ROLE
for runtime in codex claude-code; do
  role_runtime="$TMP/role-route-$runtime"
  mkdir -p "$role_runtime"
  ctx="$TMP/role-route-$runtime.context.json"
  result="$TMP/role-route-$runtime.result.json"
  route_stdout="$TMP/role-route-$runtime.stdout"
  route_stderr="$TMP/role-route-$runtime.stderr"
  jq -n --arg id "role-route-$runtime" --arg prompt "$TMP/prompt" --arg workspace "$TMP/workspace" --arg stdout "$route_stdout" --arg stderr "$route_stderr" \
    '{taskId:$id,prompt:$prompt,workspace:$workspace,workspaceRoot:$workspace,workdir:$workspace,agent:"coder",attempt:1,timeout:10,session_id:"",stdout_file:$stdout,stderr_file:$stderr}' > "$ctx"
  set +e
  if [ "$runtime" = "codex" ]; then
    HOME="$TMP/rolehome" CODEX_BIN="$TMP/bin/codex" CODEX_MODEL="mock-model" MOCK_MODE="success" MOCK_ARGS_FILE="$TMP/role-route-codex.args" MOCK_PROMPT_FILE="$TMP/role-route-codex.prompt" MANUL_DIR="$role_runtime" ROLE_RUNTIME=codex \
      bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" > "$result"
  else
    HOME="$TMP/rolehome" CLAUDE_BIN="$TMP/bin/claude" CLAUDE_MODEL="mock-model" MOCK_MODE="success" MOCK_ARGS_FILE="$TMP/role-route-claude-code.args" MOCK_PROMPT_FILE="$TMP/role-route-claude-code.prompt" MANUL_DIR="$role_runtime" ROLE_RUNTIME=claude-code \
      bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$ctx" > "$result"
  fi
  role_rc=$?
  set -e
  [ "$role_rc" -eq 0 ] && jq -e '.status == "COMPLETED" and .exit_code == 0' "$result" >/dev/null \
    && grep -Fq "CODER_ROLE_INSTRUCTIONS_FOR_TEST" "$TMP/role-route-$runtime.prompt" \
    && ok "AgentExecutor routes canonical coder role through $runtime" || no "Canonical role routing failed for $runtime (rc=$role_rc)"
done

# Exercise runtime validation via the shared production path resolver.
printf '%s\n' '{"automation":{"agentRuntime":"codex","roleRuntime":"claude-code"}}' > "$TMP/runtime/config.json"
selection="$(MANUL_DIR="$TMP/runtime" bash -c 'source "$1/manul-paths.sh"; printf "%s|%s" "$AGENT_RUNTIME" "$ROLE_RUNTIME"' _ "$SCRIPT_DIR")"
[ "$selection" = "codex|claude-code" ] && ok "manul-paths accepts Codex automatic and Claude role runtimes" || no "runtime selection returned $selection"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
