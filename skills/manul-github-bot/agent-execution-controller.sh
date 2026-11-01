#!/usr/bin/env bash
# agent-execution-controller.sh — Thin lifecycle controller for agent execution.
#
# This layer sits between the daemon and AgentExecutor. It owns:
#   • timeout enforcement (outer watchdog + inner adapter timeout)
#   • interruption / cancellation support
#   • continuation of an existing session (session_id forwarded to adapter)
#   • interpretation of ExecutionResult into daemon-state transitions
#
# The controller does NOT implement an LLM/tool loop — that belongs to each
# adapter and its underlying runtime.
#
# Public API:
#   AgentExecutionController.execute <context_json_file>
#     → writes ExecutionResult JSON to stdout
#
# Public API:
#   AgentExecutionController.continue_session <context_json_file> <session_id>
#     → like execute but sets session_id in context and sets continuation=true
#
# Mapping from ExecutionResult.status to daemon action:
#   COMPLETED        → transition task to completed
#   FAILED           → transition task to failed (or retry, see max_attempts)
#   TIMEOUT          → treat as FAILED (same daemon path)
#   INTERRUPTED      → requeue for retry (same as recovery)
#   BLOCKED          → transition to blocked_user
#   NEEDS_CONTINUATION → requeue with same session_id (same logical task)
#

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/agent-executor.sh"

AgentExecutionController_ExitCode=0
AgentExecutionController_SessionId=""

AgentExecutionController.execute() {
    local ctx_file="$1"
    if [ -z "$ctx_file" ] || [ ! -f "$ctx_file" ]; then
        printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing or unreadable execution context file","session_id":"","duration_s":0,"failure_code":"CONTROLLER_ERROR"}\n'
        AgentExecutionController_ExitCode=1
        AgentExecutionController_SessionId=""
        return 1
    fi

    local task_id stdout_file
    task_id="$(jq -r '.taskId // ""' "$ctx_file" 2>/dev/null)"
    stdout_file="$(jq -r '.stdout_file // ""' "$ctx_file" 2>/dev/null)"

    AgentExecutionController_SessionId=""

    # Delegate to AgentExecutor
    local result
    result="$(AgentExecutor.execute "$ctx_file")"
    local rc=$?

    if [ $rc -ne 0 ] && [ -z "$result" ]; then
        # Adapter crashed before producing structured output — fabricate FAILED.
        result="$(printf '{"status":"FAILED","task_id":"%s","exit_code":%d,"summary":"Adapter process exited with code %d","session_id":"","duration_s":0}' \
            "$task_id" "$rc" "$rc")"
    fi

    # If adapter reported a timeout but the result file already has TASK_DONE,
    # override to COMPLETED (daemon verifies result file, not just exit code).
    local status
    status="$(printf '%s' "$result" | jq -r '.status // "FAILED"' 2>/dev/null)"
    local exit_code
    exit_code="$(printf '%s' "$result" | jq -r '.exit_code // 1' 2>/dev/null)"
    local session_id
    session_id="$(printf '%s' "$result" | jq -r '.session_id // ""' 2>/dev/null)"
    local failure_code
    failure_code="$(printf '%s' "$result" | jq -r '.failure_code // ""' 2>/dev/null)"

    if [ "$status" = "TIMEOUT" ] || { [ "$exit_code" -eq 124 ] 2>/dev/null && [ "$status" != "COMPLETED" ]; }; then
        # Check if TASK_DONE was already emitted before the timeout killed us.
        if [ -z "$stdout_file" ] || [ "$stdout_file" = "null" ]; then
            stdout_file="$(manul_task_file_path "$MANUL_TASKS_DIR" "$task_id" "stdout")"
        fi
        local check_file="$stdout_file"
        if [ -f "$check_file" ] && grep -qE '^TASK_DONE' "$check_file" 2>/dev/null; then
            # The agent posted TASK_DONE before the outer timeout — treat as success.
            result="$(printf '%s' "$result" | jq -c '. + {status: "COMPLETED", exit_code: 0, summary: "Completed despite timeout wrapper (TASK_DONE already present)"}')"
            AgentExecutionController_SessionId="$session_id"
        else
            # A session ID alone does not make a timeout resumable. Watchdog,
            # tool-idle, step-idle and overall runtime timeouts are terminal for
            # this execution attempt. Adapters must explicitly return
            # NEEDS_CONTINUATION for a bounded continuation condition (for
            # example, an OpenCode step-limit event). That explicit status is
            # handled by the non-timeout branch below.
            AgentExecutionController_SessionId=""
        fi
    else
        AgentExecutionController_SessionId="$session_id"
    fi

    # Preserve the adapter's machine-readable failure code so the daemon can
    # distinguish e.g. a runtime permission block from a generic provider error.
    if [ -n "$failure_code" ]; then
        result="$(printf '%s' "$result" | jq -c --arg fc "$failure_code" '. + {failure_code: $fc}')"
    fi

    printf '%s\n' "$result"
    AgentExecutionController_ExitCode="$rc"
    return "$rc"
}

AgentExecutionController.continue_session() {
    local ctx_file="$1"
    local session_id="$2"
    if [ -z "$ctx_file" ] || [ ! -f "$ctx_file" ]; then
        printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing context file for session continuation","session_id":"","duration_s":0}\n'
        AgentExecutionController_ExitCode=1
        AgentExecutionController_SessionId=""
        return 1
    fi
    # Inject session_id and continuation flag into context
    local modified_ctx
    modified_ctx="$(printf '%s' "$(cat "$ctx_file")" | jq -c \
        --arg sid "$session_id" \
        '. + {session_id: $sid, continuation: true}')"
    local tmp_ctx
    mkdir -p "$MANUL_TASKS_DIR"
    tmp_ctx="$(mktemp "$MANUL_TASKS_DIR/ctx-XXXXXX.json")"
    printf '%s\n' "$modified_ctx" > "$tmp_ctx"
    local result
    result="$(AgentExecutionController.execute "$tmp_ctx")"
    local rc=$?
    rm -f "$tmp_ctx" 2>/dev/null || true
    printf '%s\n' "$result"
    AgentExecutionController_ExitCode="$rc"
    return "$rc"
}

# Allow sourcing for testing
if [ "${1:-}" = "--test" ]; then
    echo "AgentExecutionController loaded successfully"
fi
