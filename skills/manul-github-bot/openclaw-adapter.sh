#!/usr/bin/env bash
# openclaw-adapter.sh — OpenClaw runtime adapter for AgentExecutor.
#
# This adapter is the DEFAULT backend. It translates Manul ExecutionContext into
# an OpenClaw `agent --agent main` invocation and maps the exit code / output
# to a runtime-neutral ExecutionResult.
#
# CRITICAL: this adapter does NOT depend on or import any other adapter.
# It must work correctly even when `opencode` is absent from PATH.
#
# Exit-code semantics (adapted from manul-agent-wrapper.sh):
#   0  → COMPLETED      (agent explicitly emitted TASK_DONE in stdout)
#   127 → FAILED        (openclaw binary not found)
#   124 → TIMEOUT       (timeout wrapper killed the process)
#   other non-zero → FAILED
#
# The adapter writes captured stdout/stderr to the files supplied via
# --stdout-file and --stderr-file so the daemon can inspect result markers
# (TASK_DONE / TASK_FAILED / TASK_NEEDS_USER) directly.
#
# Usage (called by agent-executor.sh, not directly by the daemon):
#   openclaw-adapter.sh \
#     --task-id <id> \
#     --prompt <path> \
#     --workspace <path> \
#     --agent <name> \
#     --attempt <n> \
#     --timeout <seconds> \
#     --session-id <id-or-empty> \
#     --stdout-file <path> \
#     --stderr-file <path>

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/process-runner.sh"

# --- Parse arguments ---
OPT_TASK_ID=""
OPT_PROMPT=""
OPT_WORKSPACE=""
OPT_AGENT=""
OPT_ATTEMPT=1
OPT_TIMEOUT=0
OPT_SESSION_ID=""
OPT_STDOUT_FILE=""
OPT_STDERR_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)     OPT_TASK_ID="$2";     shift 2 ;;
        --prompt)      OPT_PROMPT="$2";      shift 2 ;;
        --workspace)   OPT_WORKSPACE="$2";   shift 2 ;;
        --agent)       OPT_AGENT="$2";       shift 2 ;;
        --attempt)     OPT_ATTEMPT="$2";     shift 2 ;;
        --timeout)     OPT_TIMEOUT="$2";     shift 2 ;;
        --session-id)  OPT_SESSION_ID="$2";  shift 2 ;;
        --stdout-file) OPT_STDOUT_FILE="$2"; shift 2 ;;
        --stderr-file) OPT_STDERR_FILE="$2"; shift 2 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$OPT_TASK_ID" ] || [ -z "$OPT_PROMPT" ]; then
    printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing required args (task-id/prompt)","session_id":"","duration_s":0}'
    exit 1
fi

mkdir -p "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" 2>/dev/null || true

# --- Resolve OpenClaw binary ---
_resolve_openclaw_bin() {
    if [ -n "${OPENCLAW_BIN:-}" ] && [ -x "$OPENCLAW_BIN" ]; then
        printf '%s' "$OPENCLAW_BIN"
        return 0
    fi
    local found
    found="$(command -v openclaw 2>/dev/null || echo "")"
    if [ -n "$found" ] && [ -x "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    return 1
}

RESOLVED_OPENCLAW_BIN="$(_resolve_openclaw_bin)"
if [ -z "$RESOLVED_OPENCLAW_BIN" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":127,"summary":"OpenClaw binary not found (openclaw not on PATH)","session_id":"","duration_s":0}' "$OPT_TASK_ID"
    exit 127
fi
OPENCLAW_BIN="$RESOLVED_OPENCLAW_BIN"
export OPENCLAW_BIN

# --- Session key derivation ---
_TASK_NAME="$(basename "$OPT_PROMPT")"
_TASK_NAME="${_TASK_NAME//[^a-zA-Z0-9_.-]/-}"
if [ -n "$OPT_SESSION_ID" ]; then
    SESSION_KEY="$OPT_SESSION_ID"
else
    SESSION_KEY="manul-${_TASK_NAME}"
fi

# --- Timeout ---
OPENCLAW_AGENT_TIMEOUT="${OPT_TIMEOUT:-${MANUL_OPENCLAW_AGENT_TIMEOUT:-43200}}"
if ! [[ "$OPENCLAW_AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$OPENCLAW_AGENT_TIMEOUT" -lt 1 ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":2,"summary":"Invalid MANUL_OPENCLAW_AGENT_TIMEOUT=%s","session_id":"","duration_s":0}' \
        "$OPT_TASK_ID" "$OPENCLAW_AGENT_TIMEOUT"
    exit 2
fi

# --- Build environment for the invocation ---
export OPENCLAW_BIN
export OPENCLAW_AGENT_TIMEOUT
export MANUL_TASK_ID="$OPT_TASK_ID"
export MANUL_ATTEMPT="$OPT_ATTEMPT"
# workspace: let the agent know where it should work
export WORKSPACE="$OPT_WORKSPACE"

# --- Launch ---
log() {
    echo "[$(date -Is)] openclaw-adapter: $*" >>"$OPT_STDERR_FILE"
}

log "starting task=$OPT_TASK_ID session=$SESSION_KEY timeout=${OPENCLAW_AGENT_TIMEOUT}s openclaw=$OPENCLAW_BIN prompt=$OPT_PROMPT workspace=$OPT_WORKSPACE"

# Run the agent through the ProcessRunner boundary. This is the ONLY way an
# adapter may spawn a subprocess: it guarantees timeout enforcement (124),
# testability (mock mode), and consistent result capture.
# Keep OpenClaw output in normal text form so TASK_DONE remains directly
# observable in the captured stdout file.

# --- Execute with ProcessRunner boundary ---
# Caller-supplied stdout/stderr files are preserved so the daemon can inspect
# result markers (TASK_DONE / TASK_FAILED / TASK_NEEDS_USER) afterwards.
ProcessRunner_TmpStdout="$OPT_STDOUT_FILE"
ProcessRunner_TmpStderr="$OPT_STDERR_FILE"

_pr_result="$(ProcessRunner.run \
    --timeout "$OPENCLAW_AGENT_TIMEOUT" \
    --cwd "$OPT_WORKSPACE" \
    -- "$OPENCLAW_BIN" agent \
        --agent "${OPT_AGENT:-main}" \
        --session-key "$SESSION_KEY" \
        --timeout "$OPENCLAW_AGENT_TIMEOUT" \
        --message-file "$OPT_PROMPT")"
_pr_header="$(printf '%s\n' "$_pr_result" | head -1)"
_pr_rc="$(printf '%s' "$_pr_header" | cut -d'|' -f1)"
_pr_dur="$(printf '%s' "$_pr_header" | cut -d'|' -f2)"
_pr_int="$(printf '%s' "$_pr_header" | cut -d'|' -f3)"
_pr_to="$(printf '%s' "$_pr_header" | cut -d'|' -f4)"

# Fallback if ProcessRunner produced no header (e.g. a sourcing failure).
: "${_pr_rc:=127}"
: "${_pr_dur:=0}"
: "${_pr_int:=false}"
: "${_pr_to:=false}"

rc="$_pr_rc"
_duration="$_pr_dur"

log "exit code=$rc duration=${_duration}s"

# --- Map exit code to ExecutionResult ---
_exit_code="$rc"
_status="FAILED"
_summary=""
_session_id="$SESSION_KEY"

if [ "$rc" -eq 0 ] && grep -qE '^TASK_NEEDS_USER_BEGIN([[:space:]]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="BLOCKED"
    _exit_code=0
    _summary="OpenClaw agent needs user input"
elif [ "$rc" -eq 0 ] && grep -qE '^TASK_FAILED([[:space:]:]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="FAILED"
    _summary="OpenClaw agent reported TASK_FAILED"
elif [ "$rc" -eq 0 ] && grep -qE '^TASK_DONE([[:space:]]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="COMPLETED"
    _exit_code=0
    _summary="$(awk '/^TASK_DONE[[:space:]]/ {sub(/^TASK_DONE[[:space:]]+/, ""); print; exit}' "$OPT_STDOUT_FILE" 2>/dev/null || true)"
    : "${_summary:=Agent completed}"
elif [ "$rc" -eq 0 ]; then
    # A clean OpenClaw process exit is NOT a successful Manul task completion.
    # TASK_DONE is part of the agent protocol and must be emitted explicitly by
    # the agent. Synthesizing it here masks broken/empty agent turns and can make
    # the daemon validate a task that was never actually completed.
    _status="FAILED"
    _exit_code=1
    _summary="OpenClaw agent exited successfully without explicit TASK_DONE"
elif [ "$rc" -eq 124 ]; then
    _status="TIMEOUT"
    _summary="OpenClaw agent execution timed out after ${OPENCLAW_AGENT_TIMEOUT}s"
elif [ "$rc" -eq 127 ]; then
    _status="FAILED"
    _summary="OpenClaw binary not found"
else
    _status="FAILED"
    _summary="OpenClaw agent exited with code $rc"
fi

# Generate valid JSON even when the agent summary contains JSON-significant
# characters such as quotes, newlines, or backslashes.
jq -cn \
    --arg status "$_status" \
    --arg task_id "$OPT_TASK_ID" \
    --arg exit_code "$_exit_code" \
    --arg summary "$_summary" \
    --arg session_id "$_session_id" \
    --arg duration_s "$_duration" \
    '{status:$status, task_id:$task_id, exit_code:($exit_code|tonumber), summary:$summary, session_id:$session_id, duration_s:($duration_s|tonumber)}'

exit "$_exit_code" 
