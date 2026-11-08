#!/usr/bin/env bash
# Manul never writes to the operator OpenCode configuration.
# Workspace isolation and Manul-specific grants are applied only in the
# invocation-local V2 overlay assembled by opencode-adapter.sh.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${OPENCODE_CONFIG:-}"
if [ -z "$CONFIG" ]; then
  OPENCODE_CONFIG_DIR="\${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  if [ -f "$OPENCODE_CONFIG_DIR/opencode.json" ]; then
    CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
  elif [ -f "$OPENCODE_CONFIG_DIR/opencode.jsonc" ]; then
    CONFIG="$OPENCODE_CONFIG_DIR/opencode.jsonc"
  fi
fi

if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "OpenCode operator config not found; no global permissions changed."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: Python 3 is required to validate OpenCode JSONC without rewriting it." >&2
  exit 1
fi
if ! python3 "$SCRIPT_DIR/jsonc-to-json.py" "$CONFIG" >/dev/null; then
  echo "ERROR: invalid OpenCode JSON/JSONC configuration: $CONFIG" >&2
  exit 1
fi

echo "OpenCode operator config validated and left unchanged; Manul permissions are task-scoped."
