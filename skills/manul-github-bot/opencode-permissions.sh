#!/usr/bin/env bash
# Compatibility shim retained for existing installer/update entry points.
# Manul must never rewrite an operator-owned OpenCode JSON/JSONC file. The
# OpenCode adapter adds the workspace boundary to a temporary runtime overlay
# for the exact task lease instead.
set -euo pipefail
echo "OpenCode operator configuration left untouched; Manul permissions are task-scoped."
