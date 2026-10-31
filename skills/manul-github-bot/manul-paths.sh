#!/usr/bin/env bash
# manul-paths.sh — Canonical path resolution for Manul runtime.
#
# This library must be sourced by every Manul component. It establishes the
# single source of truth for MANUL_DIR and derived paths.
#
# Default: $HOME/.manul (clean break from the legacy ~/.openclaw/manul layout).
# Override via the MANUL_DIR environment variable at invocation time.
#
# Derived paths (all relative to MANUL_DIR):
#   MANUL_CONFIG       config.json
#   MANUL_STATE_DIR    state/
#   MANUL_DB           state/manul.db
#   MANUL_LOG_DIR      logs/
#   MANUL_LOCKS_DIR    state/locks/
#   MANUL_TASKS_DIR    state/tasks/
#   MANUL_WORKSPACE    workspace/
#
# Intentionally does NOT define:
#   OPENCLAW_MANUL_DIR  — legacy alias, removed
#   Any OpenClaw/OpenCode-specific paths (those live in their adapters)

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
MANUL_CONFIG="${MANUL_CONFIG:-$MANUL_DIR/config.json}"
MANUL_STATE_DIR="${MANUL_STATE_DIR:-$MANUL_DIR/state}"
MANUL_DB="${MANUL_DB:-$MANUL_STATE_DIR/manul.db}"
MANUL_LOG_DIR="${MANUL_LOG_DIR:-$MANUL_DIR/logs}"
MANUL_LOCKS_DIR="${MANUL_LOCKS_DIR:-$MANUL_STATE_DIR/locks}"
MANUL_TASKS_DIR="${MANUL_TASKS_DIR:-$MANUL_STATE_DIR/tasks}"
MANUL_TASK_LOG_DIR="${MANUL_TASK_LOG_DIR:-$MANUL_LOG_DIR/tasks}"
MANUL_WORKSPACE="${MANUL_WORKSPACE:-$MANUL_DIR/workspace}"

# Task IDs are business identifiers, not safe filename components. CI task IDs
# include owner/repository (and therefore "/"), while most comment IDs do not.
# Flatten path separators consistently but preserve existing filenames for IDs
# that are already single path components. The "task-" prefix also prevents a
# leading "." or ".." in a source ID from becoming a traversal segment.
manul_task_file_key() {
    local task_id="${1:-}"
    local flat_key
    flat_key="$(printf '%s' "$task_id" | sed 's|/|_|g')"
    if [[ "$task_id" == *"/"* ]]; then
        # Preserve uniqueness when distinct task IDs flatten to the same text.
        # Existing IDs without "/" keep their legacy filenames.
        local task_hash
        task_hash="$(printf '%s' "$task_id" | sha256sum | cut -c1-16)"
        printf '%s--%s' "$flat_key" "$task_hash"
    else
        printf '%s' "$flat_key"
    fi
}

manul_task_file_path() {
    local directory="$1"
    local task_id="$2"
    local suffix="$3"
    printf '%s/task-%s.%s' "$directory" "$(manul_task_file_key "$task_id")" "$suffix"
}

# Manul operating mode (default: bot). Environment overrides config.
# Config key: .mode
_CONFIG_MODE=""
if [ -f "$MANUL_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    _CONFIG_MODE="$(jq -r '.mode // ""' "$MANUL_CONFIG" 2>/dev/null || true)"
fi
MANUL_MODE="${MANUL_MODE:-${_CONFIG_MODE:-bot}}"
export MANUL_MODE

case "$MANUL_MODE" in
    bot|human) ;;
    "") MANUL_MODE="bot" ;;
    *)
        echo "ERROR: Unknown Manul mode '$MANUL_MODE'. Must be 'bot' or 'human'." >&2
        exit 1
        ;;
esac
# Runtime selection (default: openclaw). Environment overrides config.
# Config key: .automation.agentRuntime
_CONFIG_AGENT_RUNTIME=""
if [ -f "$MANUL_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    _CONFIG_AGENT_RUNTIME="$(jq -r '.automation.agentRuntime // ""' "$MANUL_CONFIG" 2>/dev/null || true)"
fi
AGENT_RUNTIME="${AGENT_RUNTIME:-${MANUL_AGENT_RUNTIME:-${_CONFIG_AGENT_RUNTIME:-openclaw}}}"

# Validate runtime selection early so downstream code can assert it.
case "$AGENT_RUNTIME" in
    openclaw|opencode|codex|claude-code) ;;
    "") AGENT_RUNTIME="openclaw" ;;
    *)
        echo "ERROR: Unknown agent runtime '$AGENT_RUNTIME'. Must be 'openclaw', 'opencode', 'codex', or 'claude-code'." >&2
        exit 1
        ;;
esac

# Role execution is separate from the automatic/default entry-point runtime.
# OpenCode uses its native --agent switch. Codex and Claude Code receive the
# canonical role instructions through their independent adapters.
_CONFIG_ROLE_RUNTIME=""
if [ -f "$MANUL_CONFIG" ] && command -v jq >/dev/null 2>&1; then
    _CONFIG_ROLE_RUNTIME="$(jq -r '.automation.roleRuntime // ""' "$MANUL_CONFIG" 2>/dev/null || true)"
fi
ROLE_RUNTIME="${ROLE_RUNTIME:-${MANUL_ROLE_RUNTIME:-${_CONFIG_ROLE_RUNTIME:-opencode}}}"

case "$ROLE_RUNTIME" in
    openclaw|opencode|codex|claude-code) ;;
    "")
        ROLE_RUNTIME="opencode"
        ;;
    *)
        echo "ERROR: Unknown role runtime '$ROLE_RUNTIME'. Must be 'openclaw', 'opencode', 'codex', or 'claude-code'." >&2
        exit 1
        ;;
esac

# Ensure MANUL_STATE_DIR exists before we need it. Individual components may
# also create subdirs on demand; this is the canonical location guarantee.
mkdir -p "$MANUL_STATE_DIR" \
         "$MANUL_LOG_DIR" \
         "$MANUL_LOCKS_DIR" \
         "$MANUL_TASKS_DIR" \
         "$MANUL_TASK_LOG_DIR" \
         "$MANUL_WORKSPACE" \
         "$MANUL_DIR" \
  2>/dev/null || true
