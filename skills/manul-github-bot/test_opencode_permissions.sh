#!/usr/bin/env bash
# Regression tests for OpenCode V2's ordered permissions array.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
unset MANUL_DIR MANUL_WORKSPACE
mkdir -p "$HOME/.config/opencode" "$TMP/bin"
CONFIG="$TMP/custom opencode config.json"
MOCK_BIN="$TMP/bin/opencode"
cat >"$CONFIG" <<'JSON'
{
  "model":"provider/model",
  "theme":"preserve-me",
  "permission":{"external_directory":{"/operator/custom/*":"allow","~/.manul/*":"allow","~/.manul/workspace/ws-explicit/*":"allow"},"read":"allow","edit":"ask"},
  "permissions":[{"action":"external_directory","resource":"/operator/native/*","effect":"allow"},{"action":"read","resource":"*.env","effect":"ask"}]
}
JSON
chmod 640 "$CONFIG"
cat >"$MOCK_BIN" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "config" ]; then
  jq -n --arg path "$OPENCODE_CONFIG" '[{type:"document",path:$path}]'
  exit 0
fi
exit 2
MOCK
chmod +x "$MOCK_BIN"
export OPENCODE_CONFIG="$CONFIG" OPENCODE_BIN="$MOCK_BIN"
fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_jq(){ local d="$1" q="$2"; jq -e "$q" "$CONFIG" >/dev/null || fail "$d"; echo "PASS: $d"; }
assert_rule(){ local d="$1" a="$2" r="$3" e="$4"; jq -e --arg a "$a" --arg r "$r" --arg e "$e" 'any(.permissions[]?;.action==$a and .resource==$r and .effect==$e)' "$CONFIG" >/dev/null || fail "$d"; echo "PASS: $d"; }
bash "$SCRIPT_DIR/opencode-permissions.sh"
assert_jq "provider settings and V1 source fields are preserved" '.model=="provider/model" and .theme=="preserve-me" and .permission.read=="allow" and .permission.edit=="ask"'
assert_rule "legacy explicit path allow is preserved" external_directory "/operator/custom/*" allow
assert_rule "native explicit path allow is preserved" external_directory "/operator/native/*" allow
assert_rule "external directory access asks by default" external_directory "*" ask
assert_rule "temporary scratch is allowlisted" external_directory "/tmp/*" allow
assert_rule "diagnostics directory is allowlisted" external_directory "/tmp/manul-diagnostics/*" allow
assert_rule "diagnostics can be read" read "/tmp/manul-diagnostics/*" allow
assert_rule "diagnostics can be edited" edit "/tmp/manul-diagnostics/*" allow
assert_rule "Manul logs are externally reachable under a narrow path" external_directory "~/.manul/logs/*" allow
assert_rule "Manul logs can be read" read "~/.manul/logs/*" allow
assert_rule "Manul logs can be globbed" glob "~/.manul/logs/*" allow
assert_rule "Manul logs cannot be edited" edit "~/.manul/logs/*" deny
assert_rule "Gradle module cache is narrowly allowlisted" external_directory "~/.gradle/caches/modules-2/files-2.1/*" allow
assert_rule "global Manul task workspace is denied" external_directory "$HOME/.manul/workspace/*" deny
assert_jq "stale workspace-specific allows are removed" '([.permissions[]|select(.action=="external_directory" and .resource=="~/.manul/workspace/ws-explicit/*" and .effect=="allow")]|length)==0'
assert_jq "no broad Gradle cache grant is added" '([.permissions[]|select(.action=="external_directory" and .resource=="~/.gradle/*" and .effect=="allow")]|length)==0'
BEFORE="$(sha256sum "$CONFIG"|awk '{print $1}')"
bash "$SCRIPT_DIR/opencode-permissions.sh"
AFTER="$(sha256sum "$CONFIG"|awk '{print $1}')"
[ "$BEFORE" = "$AFTER" ] || fail "permissions setup is not idempotent"
echo "PASS: V2 permissions setup is idempotent"
CUSTOM_RUNTIME="$TMP/custom Manul runtime"
CUSTOM_WORKSPACE="$TMP/custom task workspaces"
mkdir -p "$CUSTOM_WORKSPACE/ws-stale"
export MANUL_DIR="$CUSTOM_RUNTIME" MANUL_WORKSPACE="$CUSTOM_WORKSPACE"
bash "$SCRIPT_DIR/opencode-permissions.sh"
assert_rule "configured task workspace root is denied" external_directory "$CUSTOM_WORKSPACE/*" deny
echo "All V2 permission tests passed."
