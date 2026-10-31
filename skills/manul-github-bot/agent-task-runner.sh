#!/usr/bin/env bash
# agent-task-runner.sh — isolated process boundary for one Manul agent task.
#
# The daemon invokes this script through setsid so the executor gets its own
# process group. The PID is written to a task-local state file, allowing the
# watchdog to terminate a hung executor without killing the long-lived worker.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
PID_FILE="${2:-}"

source "$SCRIPT_DIR/manul-env.sh"
if ! manul_env_load "$MANUL_DIR"; then
  echo "ERROR: failed to load $MANUL_DIR/.env" >&2
  exit 1
fi
source "$SCRIPT_DIR/manul-paths.sh"
source "$SCRIPT_DIR/process-runner.sh"
source "$SCRIPT_DIR/agent-executor.sh"
source "$SCRIPT_DIR/agent-execution-controller.sh"

CTX_FILE="${1:-}"
if [ -z "$CTX_FILE" ] || [ ! -f "$CTX_FILE" ]; then
  echo "ERROR: missing execution context file" >&2
  exit 2
fi

if [ -n "$PID_FILE" ]; then
  mkdir -p "$(dirname "$PID_FILE")"
  printf '%s\n' "$BASHPID" > "$PID_FILE"
fi

AgentExecutionController.execute "$CTX_FILE"
exit $?
