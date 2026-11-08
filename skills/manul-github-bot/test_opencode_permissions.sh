#!/usr/bin/env bash
# Verify that the legacy permissions installer never mutates operator config.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.config/opencode"
CONFIG="$HOME/.config/opencode/opencode.jsonc"
cat >"$CONFIG" <<'JSONC'
{
  "$schema": "https://opencode.ai/config.json",
  // Keep operator comments and formatting exactly as written.
  "model": "provider/model",
  "mcp": {
    "servers": {
      "operator-server": { "type": "remote", "url": "https://example.invalid/mcp", },
    },
  },
}
JSONC
export OPENCODE_CONFIG="$CONFIG"
BEFORE="$(sha256sum "$CONFIG" | awk '{print $1}')"
bash "$SCRIPT_DIR/opencode-permissions.sh"
AFTER="$(sha256sum "$CONFIG" | awk '{print $1}')"
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: operator JSONC changed" >&2; exit 1; }
grep -q 'Keep operator comments' "$CONFIG" || { echo "FAIL: operator JSONC comments were lost" >&2; exit 1; }
grep -q '"operator-server"' "$CONFIG" || { echo "FAIL: operator MCP disappeared" >&2; exit 1; }
echo "PASS: OpenCode permissions setup leaves operator JSONC unchanged"
