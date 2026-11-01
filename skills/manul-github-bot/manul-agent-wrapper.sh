#!/bin/bash
# manul-agent-wrapper.sh - Wrapper to ensure TASK_DONE is emitted by the agent
#
# Usage: manul-agent-wrapper.sh <prompt-file> <stdout-file> <stderr-file>
#
# Runs the OpenClaw orchestrator with a dedicated per-task session, then appends
# TASK_DONE (if exit code 0) or TASK_FAILED (if exit code non-zero) to the stdout file.
# The orchestrator's stdout and stderr are appended to the respective files.
#
# =============================================================================
# DEPRECATED (2026-09-24) — DO NOT USE IN NEW CODE.
# =============================================================================
# This wrapper is superseded by the AgentExecutor runtime abstraction:
#
#   manul-daemon.sh → AgentExecutionController.execute()
#     → AgentExecutor.execute()  (agent-executor.sh)
#       → openclaw-adapter.sh / opencode-adapter.sh
#
# It remains in the repository only as a historical reference for the original
# OpenClaw-only invocation path. It is NOT installed by install-manul-symlinks.sh
# and is NOT called by the daemon. Do not add new callers here.
# =============================================================================

set -uo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 <prompt-file> <stdout-file> <stderr-file>" >&2
    exit 1
fi

PROMPT_FILE="$1"
STDOUT_FILE="$2"
STDERR_FILE="$3"

# Resolve the OpenClaw binary.
# The daemon exports OPENCLAW_BIN, but it may be empty if openclaw was not on
# PATH at daemon startup. Falling back to PATH lookup keeps the wrapper usable
# and fails loudly when the runtime is genuinely unavailable.
if [ -z "${OPENCLAW_BIN:-}" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  OPENCLAW_BIN="$(command -v openclaw 2>/dev/null || echo "")"
fi
if [ -z "${OPENCLAW_BIN:-}" ] || [ ! -x "$OPENCLAW_BIN" ]; then
  echo "ERROR: OpenClaw binary not found (OPENCLAW_BIN='${OPENCLAW_BIN:- unset}') and 'openclaw' is not on PATH" >&2
  exit 127
fi
export OPENCLAW_BIN

# OpenClaw's main session can already be busy. In that case an invocation
# without --session-key queues behind the main turn and Manul can observe an
# immediate/short-lived worker failure instead of getting an independent agent
# turn. Give every Manul task its own stable session key so retries reuse the
# same task session without competing for the main session.
TASK_NAME="$(basename "$PROMPT_FILE")"
TASK_NAME="${TASK_NAME//[^a-zA-Z0-9_.-]/-}"
SESSION_KEY="${MANUL_SESSION_KEY:-manul-${TASK_NAME}}"

# Local logging function. Keep launcher diagnostics in the task stderr file so
# daemon.log remains concise while the exact launch failure is retained.
log() {
  echo "$@" >>"$STDERR_FILE"
}

log "manul-agent-wrapper: starting"
log "manul-agent-wrapper: openclaw=$OPENCLAW_BIN"
log "manul-agent-wrapper: cwd=$(pwd)"
log "manul-agent-wrapper: prompt=$PROMPT_FILE"
OPENCLAW_AGENT_TIMEOUT="${MANUL_OPENCLAW_AGENT_TIMEOUT:-43200}"
if ! [[ "$OPENCLAW_AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$OPENCLAW_AGENT_TIMEOUT" -lt 1 ]; then
    log "ERROR: invalid MANUL_OPENCLAW_AGENT_TIMEOUT=$OPENCLAW_AGENT_TIMEOUT"
    exit 2
fi

log "manul-agent-wrapper: session-key=$SESSION_KEY"
log "manul-agent-wrapper: openclaw-timeout=${OPENCLAW_AGENT_TIMEOUT}s"

# Flag to track if we're receiving a termination signal.
TERMINATING=0

cleanup() {
    if [ "$TERMINATING" -eq 0 ]; then
        TERMINATING=1
        if [ -n "${ORCHESTRATOR_PID:-}" ] && kill -0 "$ORCHESTRATOR_PID" 2>/dev/null; then
            kill -TERM "$ORCHESTRATOR_PID" 2>/dev/null || true
            wait "$ORCHESTRATOR_PID" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT INT TERM

# Run the orchestrator in the background. The dedicated session key is
# intentional: do not route Manul work through an already-busy main session.
"$OPENCLAW_BIN" agent --agent main --session-key "$SESSION_KEY" --timeout "$OPENCLAW_AGENT_TIMEOUT" --message-file "$PROMPT_FILE" >>"$STDOUT_FILE" 2>>"$STDERR_FILE" &
ORCHESTRATOR_PID=$!
log "manul-agent-wrapper: orchestrator-pid=$ORCHESTRATOR_PID"

wait "$ORCHESTRATOR_PID"
rc=$?
log "manul-agent-wrapper: orchestrator-exit=$rc"

# If we were interrupted by a signal, don't emit TASK_DONE/TASK_FAILED.
if [ "$TERMINATING" -eq 1 ]; then
    log "WARNING: Agent wrapper interrupted by signal, not emitting task status"
    exit 1
fi

if [ "$rc" -eq 0 ]; then
    echo "TASK_DONE" >>"$STDOUT_FILE"
else
    echo "TASK_FAILED: Orchestrator exited with non-zero status (rc=$rc)" >>"$STDOUT_FILE"
fi

exit "$rc"
