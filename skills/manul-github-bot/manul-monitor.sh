#!/usr/bin/env bash
# Public monitor-management command; the runtime logic lives in Python.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: python3 is required for manul-monitor" >&2
  exit 1
}
exec python3 "$SCRIPT_DIR/manul-monitor.py" "$@"
