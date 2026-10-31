#!/usr/bin/env bash
# Regression tests for the additive OpenCode permissions helper.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
unset MANUL_DIR MANUL_WORKSPACE
mkdir -p "$HOME/.config/opencode" "$TMP/bin"
CONFIG="$TMP/custom opencode config.json"
MOCK_BIN="$TMP/bin/opencode"

cat >"$CONFIG" <<'JSON'
{
  "model": "provider/model",
  "theme": "preserve-me",
  "permission": {
    "external_directory": {
      "/operator/custom/**": "allow",
      "~/.manul/**": "allow",
      "~/.manul/workspace/ws-explicit/**": "allow",
      "$HOME/.manul/workspace/ws-absolute/**": "allow"
    },
    "read": "allow",
    "edit": "ask",
    "list": "ask",
    "glob": "ask",
    "grep": "ask"
  }
}
JSON
chmod 640 "$CONFIG"

cat >"$MOCK_BIN" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "config" ]; then
  cat "$OPENCODE_CONFIG"
  exit 0
fi
echo "unexpected OpenCode command: $*" >&2
exit 2
MOCK
chmod +x "$MOCK_BIN"

export OPENCODE_CONFIG="$CONFIG" OPENCODE_BIN="$MOCK_BIN"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_jq() {
  local description="$1" expression="$2"
  jq -e "$expression" "$CONFIG" >/dev/null || fail "$description"
  echo "PASS: $description"
}

bash "$SCRIPT_DIR/opencode-permissions.sh"

assert_jq "non-Manul provider fields are preserved" '.model == "provider/model" and .theme == "preserve-me"'
assert_jq "existing unrelated external-directory rule is preserved" '.permission.external_directory["/operator/custom/**"] == "allow"'
assert_jq "broad Manul path rule is preserved while the narrower workspace deny overrides it" '.permission.external_directory["~/.manul/**"] == "allow" and .permission.external_directory["~/.manul/workspace/**"] == "deny"'
assert_jq "specific tilde-based workspace allows are changed to deny" '.permission.external_directory["~/.manul/workspace/ws-explicit/**"] == "deny"'
assert_jq "specific HOME-based workspace allows are changed to deny" '.permission.external_directory["$HOME/.manul/workspace/ws-absolute/**"] == "deny"'
assert_jq "the final workspace deny follows the broader allow rule" '.permission.external_directory as $rules | ($rules | keys_unsorted | index("~/.manul/**")) < ($rules | keys_unsorted | index("~/.manul/workspace/**"))'
assert_jq "temporary workspace scratch access remains allowlisted" '.permission.external_directory["/tmp/**"] == "allow"'
assert_jq "diagnostic scratch access remains allowlisted" '.permission.external_directory["/tmp/manul-diagnostics/**"] == "allow"'
assert_jq "Manul logs are externally reachable only under the narrow logs path" '.permission.external_directory["~/.manul/logs/**"] == "allow"'
assert_jq "log read/list/search are allowed" '.permission.read["~/.manul/logs/**"] == "allow" and .permission.list["~/.manul/logs/**"] == "allow" and .permission.glob["~/.manul/logs/**"] == "allow" and .permission.grep["~/.manul/logs/**"] == "allow"'
assert_jq "log edits remain denied" '.permission.edit["~/.manul/logs/**"] == "deny"'
assert_jq "Gradle artifact access remains narrowly scoped" '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] == "allow"'
[ "$(stat -c '%a' "$CONFIG")" = "640" ] || fail "custom provider config file mode was not preserved"
echo "PASS: provider configuration file mode is preserved"

FIRST_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"
bash "$SCRIPT_DIR/opencode-permissions.sh"
SECOND_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"
[ "$FIRST_HASH" = "$SECOND_HASH" ] || fail "permissions helper is not idempotent"
echo "PASS: repeated permission setup is idempotent"

assert_jq "global blanket workspace deny remains active" '.permission.external_directory["~/.manul/workspace/**"] == "deny"'

# A custom workspace base must have its own absolute global deny. Pre-existing
# allows under the configured base are rewritten to deny, even with spaces.
CUSTOM_RUNTIME="$TMP/custom Manul runtime"
CUSTOM_WORKSPACE="$TMP/custom task workspaces"
mkdir -p "$CUSTOM_WORKSPACE/ws-stale"
jq --arg stale "$CUSTOM_WORKSPACE/ws-stale/**" '.permission.external_directory[$stale] = "allow"' "$CONFIG" >"$TMP/custom-config.json"
mv "$TMP/custom-config.json" "$CONFIG"
export MANUL_DIR="$CUSTOM_RUNTIME" MANUL_WORKSPACE="$CUSTOM_WORKSPACE"
bash "$SCRIPT_DIR/opencode-permissions.sh"
CUSTOM_DENY="$CUSTOM_WORKSPACE/**"
jq -e --arg path "$CUSTOM_DENY" '.permission.external_directory[$path] == "deny"' "$CONFIG" >/dev/null || fail "configured custom workspace root is not blanket-denied"
echo "PASS: configured custom workspace root is blanket-denied"
jq -e --arg path "$CUSTOM_WORKSPACE/ws-stale/**" '.permission.external_directory[$path] == "deny"' "$CONFIG" >/dev/null || fail "custom-workspace allow was not rewritten to deny"
echo "PASS: custom-workspace allow is rewritten to deny"
echo "All OpenCode permission helper tests passed."
