#!/usr/bin/env bash
# opencode-permissions.sh — ensure provider permissions required by Manul.
#
# OpenCode configuration remains provider-owned. This helper only applies the
# minimum permissions needed for unattended Manul execution and preserves all
# unrelated user configuration.
#
# Required rules (idempotent, additive):
#   /tmp/**                                  - existing task workspace scratch space
#   /tmp/manul-diagnostics/**                - local operator diagnostic artifacts
#   ~/.manul/logs/**                         - read/search-only operator diagnostics
#   ~/.gradle/caches/modules-2/files-2.1/**  - dependency artifacts (JARs), scoped
#                                              to this cache only (not all Gradle
#                                              state, which may contain credentials).
#
# The log rule enables an explicitly authorized LOCAL operator diagnostic run.
# It does not override Manul's generated task contract, which prohibits worker
# tasks from inspecting Manul runtime state/logs.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
MANUL_WORKSPACE_CANONICAL="$(realpath -m -- "$MANUL_WORKSPACE")"
[ "$MANUL_WORKSPACE_CANONICAL" != "/" ] || { echo "ERROR: MANUL_WORKSPACE must not resolve to /" >&2; exit 1; }
MANUL_WORKSPACE_RULE="${MANUL_WORKSPACE_CANONICAL%/}/**"
export MANUL_WORKSPACE_CANONICAL MANUL_WORKSPACE_RULE

# Required permission rules. Most entries add narrow capabilities. The workspace
# deny is intentionally stronger: any existing external_directory allow rules
# under the configured workspace base are changed to deny, and both default and
# absolute canonical workspace denies are appended after broader allow rules.
REQUIRED_PERMISSION_RULES=(
  '.permission.external_directory["/tmp/**"] = "allow"'
  '.permission.external_directory["/tmp/manul-diagnostics/**"] = "allow"'
  '.permission.read |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.read["/tmp/manul-diagnostics/**"] = "allow"'
  '.permission.edit |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.edit["/tmp/manul-diagnostics/**"] = "allow"'
  '.permission.external_directory["~/.manul/logs/**"] = "allow"'
  '.permission.read |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.read["~/.manul/logs/**"] = "allow"'
  '.permission.glob |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.glob["~/.manul/logs/**"] = "allow"'
  '.permission.grep |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.grep["~/.manul/logs/**"] = "allow"'
  '.permission.list |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.list["~/.manul/logs/**"] = "allow"'
  '.permission.edit |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.edit["~/.manul/logs/**"] = "deny"'
  '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] = "allow"'
  '.permission.external_directory |= (if type == "object" then . elif type == "string" then {"*": .} else {} end) | .permission.external_directory |= (with_entries((.key | if startswith("~/") then (env.HOME + .[1:]) elif startswith("$HOME/") then (env.HOME + .[5:]) else . end) as $path | if ($path == $manulWorkspace or ($path | startswith($manulWorkspace + "/"))) then .value = "deny" else . end) | del(.[$defaultWorkspaceDeny]) | del(.[$workspaceDeny]) | . + {($defaultWorkspaceDeny):"deny",($workspaceDeny):"deny"})'
)

# Paths verified against the effective OpenCode configuration, kept in lockstep
# with REQUIRED_PERMISSION_RULES above.
REQUIRED_PERMISSION_PATHS=(
  '/tmp/**'
  '/tmp/manul-diagnostics/**'
  '~/.manul/logs/**'
  '~/.gradle/caches/modules-2/files-2.1/**'
)
REQUIRED_PERMISSION_DENY_PATHS=(
  '~/.manul/workspace/**'
  "$MANUL_WORKSPACE_RULE"
)

resolve_opencode_bin() {
  if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
    printf '%s' "$OPENCODE_BIN"
    return 0
  fi
  local found=""
  found="$(command -v opencode 2>/dev/null || true)"
  if [ -n "$found" ] && [ -x "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    printf '%s' "$HOME/.opencode/bin/opencode"
    return 0
  fi
  return 1
}

OPENCODE_BIN_RESOLVED="$(resolve_opencode_bin || true)"
[ -n "$OPENCODE_BIN_RESOLVED" ] || exit 0

# Provider configuration is owned by OpenCode/the operator. Respect an
# explicitly configured OPENCODE_CONFIG; fall back to the canonical default.
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

# Provider configuration is owned by OpenCode/the operator. Manul must not
# invent a new provider config just to add its permission rule; a missing
# provider config is a safe no-op.
[ -f "$OPENCODE_CONFIG" ] || exit 0

CONFIG_DIR="$(dirname "$OPENCODE_CONFIG")"
if ! jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1; then
  echo "ERROR: invalid OpenCode configuration: $OPENCODE_CONFIG" >&2
  exit 1
fi

TMP_FILE="$(mktemp "$CONFIG_DIR/.opencode.manul.XXXXXX")"
cleanup() { rm -f "$TMP_FILE"; }
trap cleanup EXIT

# Build the jq expression once so the rule set lives in one place and stays in
# sync with REQUIRED_PERMISSION_RULES. Assignment is idempotent: re-running on
# an existing rule is a no-op, so unrelated settings are never touched.
JQ_EXPR='.'
for rule in "${REQUIRED_PERMISSION_RULES[@]}"; do
  JQ_EXPR="$JQ_EXPR | $rule"
done

# shellcheck disable=SC2086
jq --arg manulWorkspace "$MANUL_WORKSPACE_CANONICAL" --arg workspaceDeny "$MANUL_WORKSPACE_RULE" --arg defaultWorkspaceDeny '~/.manul/workspace/**' "$JQ_EXPR" "$OPENCODE_CONFIG" >"$TMP_FILE"
MODE="$(stat -c '%a' "$OPENCODE_CONFIG" 2>/dev/null || true)"
[ -n "$MODE" ] && chmod "$MODE" "$TMP_FILE" 2>/dev/null || true

if ! jq empty "$TMP_FILE" >/dev/null 2>&1; then
  echo "ERROR: generated OpenCode configuration is invalid" >&2
  exit 1
fi

if ! cmp -s "$OPENCODE_CONFIG" "$TMP_FILE"; then
  mv -f "$TMP_FILE" "$OPENCODE_CONFIG"
fi

# Confirm the effective provider configuration agrees with every required rule.
for i in "${!REQUIRED_PERMISSION_PATHS[@]}"; do
  path="${REQUIRED_PERMISSION_PATHS[$i]}"
  if ! "$OPENCODE_BIN_RESOLVED" debug config 2>/dev/null |
    jq -e --arg p "$path" '.permission.external_directory[$p] == "allow"' >/dev/null 2>&1; then
    echo "ERROR: OpenCode effective configuration does not allow $path" >&2
    exit 1
  fi
done

for path in "${REQUIRED_PERMISSION_DENY_PATHS[@]}"; do
  if ! "$OPENCODE_BIN_RESOLVED" debug config 2>/dev/null |
    jq -e --arg p "$path" '.permission.external_directory[$p] == "deny"' >/dev/null 2>&1; then
    echo "ERROR: OpenCode effective configuration does not deny access to other Manul workspaces ($path)" >&2
    exit 1
  fi
done

# Verify tool-level permissions against the EFFECTIVE config too. The external
# directory rule grants access outside the workspace; edit deny keeps logs
# read-only for OpenCode file tools.
if ! "$OPENCODE_BIN_RESOLVED" debug config 2>/dev/null | jq -e '
  .permission.read["~/.manul/logs/**"] == "allow" and
  .permission.glob["~/.manul/logs/**"] == "allow" and
  .permission.grep["~/.manul/logs/**"] == "allow" and
  .permission.list["~/.manul/logs/**"] == "allow" and
  .permission.edit["~/.manul/logs/**"] == "deny" and
  .permission.read["/tmp/manul-diagnostics/**"] == "allow" and
  .permission.edit["/tmp/manul-diagnostics/**"] == "allow"
' >/dev/null 2>&1; then
  echo "ERROR: OpenCode effective config lacks the required read-only log/diagnostic permissions" >&2
  exit 1
fi
