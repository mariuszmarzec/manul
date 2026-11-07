#!/usr/bin/env bash
# agent-executor.sh — Runtime-neutral dispatcher for Manul agent execution.
#
# Selects the correct adapter based on AGENT_RUNTIME (set in manul-paths.sh)
# and delegates execution. Core Manul never calls adapters directly; it always
# goes through this dispatcher.
#
# Public API:
#   AgentExecutor.execute <execution_context_json_file>
#     → writes ExecutionResult JSON to stdout
#
# execution_context fields (required):
#   taskId     — unique Manul task identifier (commentId)
#   prompt     — absolute path to the prompt file
#   workspace  — absolute path to the workspace directory
#   agent      — agent name / session key (optional, adapter-specific)
#   attempt    — current attempt number
#   timeout    — max wall-clock seconds for this execution
#
# ExecutionResult fields (JSON on stdout):
#   status     — COMPLETED | FAILED | TIMEOUT | INTERRUPTED | BLOCKED | NEEDS_CONTINUATION
#   task_id    — echoed back
#   exit_code  — integer (0 if status=COMPLETED)
#   summary    — human-readable summary
#   session_id — adapter-specific session identifier (for continuation)
#   duration_s — wall-clock duration
#
# The dispatcher is intentionally thin. Adapter selection and result mapping
# happen inside each adapter; the executor merely wires them together.

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/process-runner.sh"

AgentExecutor_ExitCode=0

AgentExecutor.execute() {
    local ctx_file="$1"
    if [ -z "$ctx_file" ] || [ ! -f "$ctx_file" ]; then
        printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing or unreadable execution context file","session_id":"","duration_s":0}\n'
        AgentExecutor_ExitCode=1
        return 1
    fi

    local task_id prompt workspace workspace_root workdir agent attempt timeout session_id stdout_file stderr_file
    task_id="$(jq -r '.taskId // ""' "$ctx_file" 2>/dev/null)"
    prompt="$(jq -r '.prompt // ""' "$ctx_file" 2>/dev/null)"
    workspace="$(jq -r '.workspace // ""' "$ctx_file" 2>/dev/null)"
    workspace_root="$(jq -r '.workspaceRoot // ""' "$ctx_file" 2>/dev/null)"
    workdir="$(jq -r '.workdir // ""' "$ctx_file" 2>/dev/null)"
    agent="$(jq -r '.agent // ""' "$ctx_file" 2>/dev/null)"
    attempt="$(jq -r '.attempt // 1' "$ctx_file" 2>/dev/null)"
    timeout="$(jq -r '.timeout // 0' "$ctx_file" 2>/dev/null)"
    session_id="$(jq -r '.session_id // ""' "$ctx_file" 2>/dev/null)"
    auto_accept="$(jq -r '.autoAccept // false' "$ctx_file" 2>/dev/null)"
    preflight_only="$(jq -r '.preflight_only // false' "$ctx_file" 2>/dev/null)"

    # Derive stdout/stderr files. The caller (daemon) may supply explicit paths
    # in the context JSON; otherwise fall back to MANUL_TASKS_DIR. The daemon
    # inspects these exact files for result markers, so they MUST be honoured.
    stdout_file="$(jq -r '.stdout_file // ""' "$ctx_file" 2>/dev/null)"
    stderr_file="$(jq -r '.stderr_file // ""' "$ctx_file" 2>/dev/null)"
    if [ -z "$stdout_file" ] || [ "$stdout_file" = "null" ]; then
        stdout_file="$(manul_task_file_path "$MANUL_TASKS_DIR" "$task_id" "stdout")"
    fi
    if [ -z "$stderr_file" ] || [ "$stderr_file" = "null" ]; then
        stderr_file="$(manul_task_file_path "$MANUL_TASKS_DIR" "$task_id" "stderr")"
    fi
    mkdir -p "$(dirname "$stdout_file")" "$(dirname "$stderr_file")" 2>/dev/null || true
    mkdir -p "$MANUL_TASKS_DIR" 2>/dev/null || true

    # Validate inputs before dispatching
    if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Missing taskId in execution context","session_id":"","duration_s":0}\n' "$task_id"
        AgentExecutor_ExitCode=1
        return 1
    fi
    if [ -z "$prompt" ] || [ "$prompt" = "null" ]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Missing prompt file path","session_id":"","duration_s":0}\n' "$task_id"
        AgentExecutor_ExitCode=1
        return 1
    fi
    if [ ! -f "$prompt" ]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Prompt file not found: %s","session_id":"","duration_s":0}\n' "$task_id" "$prompt"
        AgentExecutor_ExitCode=1
        return 1
    fi

    # "main" is a legacy runtime entry-point label, not a canonical OpenCode role.
    # When used with OpenCode, translate it to automatic selection so the default
    # primary agent configured by OpenCode (normally orchestrator) is selected.
    if [ "$agent" = "main" ] && [ "$AGENT_RUNTIME" != "openclaw" ]; then
        agent=""
    fi

    # Every task uses the same configured backend. A selected role changes the
    # adapter's role handling, never the runtime chosen for execution.
    local execution_runtime="$AGENT_RUNTIME"
    if [ -n "$agent" ] && [ "$agent" != "main" ]; then
        local allowed_agents_json
        allowed_agents_json="$(jq -c '.agents // []' "$MANUL_CONFIG" 2>/dev/null || printf '[]')"
        if ! jq -e 'type == "array" and length > 0' <<<"$allowed_agents_json" >/dev/null 2>&1; then
            allowed_agents_json='["architect","coder","coder-cheap","coder-strong","coder-expert","reviewer","reviewer-expert","reviewer-adversarial","debugger","debugger-expert","researcher","tester","security","performance","refactorer"]'
        fi
        if ! jq -e --arg agent "$agent" 'type == "array" and index($agent) != null' <<<"$allowed_agents_json" >/dev/null 2>&1; then
            local routing_error
            routing_error="Unknown or unconfigured agent role: $agent"
            jq -cn --arg taskId "$task_id" --arg summary "$routing_error" \
              '{status:"FAILED",task_id:$taskId,exit_code:1,summary:$summary,session_id:"",duration_s:0}'
            AgentExecutor_ExitCode=1
            return 1
        fi
    fi

    # --auto is an explicit per-task OpenCode override. It does not introduce
    # another configured runtime and is never passed to the OpenClaw adapter.
    if [ "$auto_accept" = "true" ]; then
        execution_runtime="opencode"
    fi

    # Route through the single configured runtime (or explicit task override).
    local adapter_script
    case "$execution_runtime" in
        openclaw)
            adapter_script="$MANUL_SCRIPT_DIR/openclaw-adapter.sh"
            ;;
        opencode)
            adapter_script="$MANUL_SCRIPT_DIR/opencode-adapter.sh"
            ;;
        codex)
            adapter_script="$MANUL_SCRIPT_DIR/codex-adapter.sh"
            ;;
        claude-code)
            adapter_script="$MANUL_SCRIPT_DIR/claude-code-adapter.sh"
            ;;
        *)
            printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Unknown execution runtime: %s","session_id":"","duration_s":0}\n' "$task_id" "$execution_runtime"
            AgentExecutor_ExitCode=1
            return 1
            ;;
    esac

    if [ ! -f "$adapter_script" ]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Adapter script not found: %s","session_id":"","duration_s":0}\n' "$task_id" "$adapter_script"
        AgentExecutor_ExitCode=1
        return 1
    fi

    if [ "$preflight_only" = "true" ] && [ "$execution_runtime" != "opencode" ]; then
        # Only OpenCode currently has a separate live MCP preflight. Other
        # runtimes retain their existing startup behavior.
        jq -cn --arg task_id "$task_id" \
            '{status:"READY",task_id:$task_id,exit_code:0,summary:"Runtime has no separate preflight phase",session_id:"",duration_s:0,diagnostics:{stage:"runtime_preflight",agent_started:false,preflight:"not_required"}}'
        AgentExecutor_ExitCode=0
        return 0
    fi

    local -a adapter_auto_args=() adapter_preflight_args=()
    if [ "$auto_accept" = "true" ]; then
        adapter_auto_args=(--auto)
    fi
    if [ "$preflight_only" = "true" ]; then
        adapter_preflight_args=(--preflight-only)
    fi
    # Execute the adapter; it writes its ExecutionResult JSON to stdout.
    local adapter_output
    adapter_output="$( \
        MANUL_DIR="$MANUL_DIR" \
        MANUL_WORKSPACE="$MANUL_WORKSPACE" \
        MANUL_TASK_WORKSPACE_ROOT="$workspace_root" \
        MANUL_TASK_WORKDIR="$workdir" \
        bash "$adapter_script" \
        --task-id "$task_id" \
        --prompt "$prompt" \
        --workspace "$workspace" \
        --agent "$agent" \
        --attempt "$attempt" \
        --timeout "$timeout" \
        --session-id "$session_id" \
        --stdout-file "$stdout_file" \
        --stderr-file "$stderr_file" \
        "${adapter_auto_args[@]}" \
        "${adapter_preflight_args[@]}" \
        2>"$stderr_file")"

    local rc=$?
    printf '%s\n' "$adapter_output"
    AgentExecutor_ExitCode="$rc"
    return "$rc"
}

# Allow sourcing for testing
if [ "${1:-}" = "--test" ]; then
    echo "AgentExecutor loaded successfully"
fi
