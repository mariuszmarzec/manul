#!/usr/bin/env bash
# Verify Caracal provider refresh and MCP readiness in Manul's OpenCode adapter.
# This fixture is hermetic: it never reads the operator's live provider or config.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

HOME_DIR="$TMP/home"
CONFIG="$HOME_DIR/.config/opencode/opencode.jsonc"
PROVIDER="$HOME_DIR/.caracal/env.sh"
BIN_DIR="$TMP/bin"
PROOF="$TMP/opencode-proof.txt"
PROMPT="$TMP/prompt.md"
mkdir -p "$HOME_DIR/.config/opencode" "$HOME_DIR/.caracal" "$BIN_DIR" "$TMP/runtime/workspace/ws-caracal"
cat >"$CONFIG" <<'JSONC'
{
  // Operator-owned static MCP entry; Manul must not rewrite this file.
  "mcp": {
    "servers": {
      "caracal-rag": {
        "type": "remote",
        "url": "{env:CARACAL_MCP_URL}",
        "oauth": false,
        "disabled": false,
        "headers": {
          "Authorization": "Bearer {env:CARACAL_ACCESS_TOKEN}"
        }
      }
    }
  }
}
JSONC
cat >"$PROVIDER" <<'PROVIDER'
if [ "${CARACAL_RESOLVE_LIVE:-}" != "1" ]; then
  echo "CARACAL_RESOLVE_LIVE was not set by the runtime loader" >&2
  return 1
fi
export CARACAL_MCP_URL="http://127.0.0.1:3500/mcp"
export CARACAL_ACCESS_TOKEN="fixture-caracal-token"
PROVIDER
cat >"$BIN_DIR/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'command=%s\n' "$*" >>"$MOCK_CARACAL_PROOF_FILE"
printf 'url=%s\n' "${CARACAL_MCP_URL:-<unset>}" >>"$MOCK_CARACAL_PROOF_FILE"
printf 'token=%s\n' "${CARACAL_ACCESS_TOKEN:-<unset>}" >>"$MOCK_CARACAL_PROOF_FILE"
printf 'resolve_live=%s\n' "${CARACAL_RESOLVE_LIVE:-unset}" >>"$MOCK_CARACAL_PROOF_FILE"
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  if [ "${MOCK_CARACAL_MODE:-connected}" = "connected" ]; then
    echo "caracal-rag connected"
    echo "manul-fiteo disconnected"
  else
    echo "caracal-rag disconnected"
  fi
  # OpenCode mcp list may return non-zero for an unrelated optional MCP.
  exit 1
fi
if [ "${1:-}" = "run" ]; then
  printf '%s' "${OPENCODE_CONFIG_CONTENT:-}" >"${MOCK_CARACAL_PROOF_FILE}.overlay"
  printf 'fiteo_pat=%s\n' "${FITEO_MANUL_PAT:-<unset>}" >>"$MOCK_CARACAL_PROOF_FILE"
  if [ "${MOCK_CARACAL_MODE:-connected}" = "connected" ]; then
    if [ "${CARACAL_MCP_URL:-}" != "http://127.0.0.1:3500/mcp" ] ||
       [ "${CARACAL_ACCESS_TOKEN:-}" != "fixture-caracal-token" ]; then
      echo "Caracal provider values did not reach the model process" >&2
      exit 66
    fi
  elif [ -n "${CARACAL_MCP_URL:-}" ] || [ -n "${CARACAL_ACCESS_TOKEN:-}" ]; then
    echo "disabled Caracal credentials leaked into the model process" >&2
    exit 66
  fi
  printf '%s\n' '{"type":"text","timestamp":1,"sessionID":"ses-caracal","part":{"type":"text","text":"TASK_DONE caracal runtime verified"}}'
  exit 0
fi
echo "unexpected OpenCode command: $*" >&2
exit 64
MOCK
chmod +x "$BIN_DIR/opencode"
printf '%s\n' "Verify Caracal integration" >"$PROMPT"
CONFIG_HASH="$(sha256sum "$CONFIG" | awk '{print $1}')"

run_adapter() {
  local task_id="$1" mode="$2"
  local stdout="$TMP/$task_id.stdout" stderr="$TMP/$task_id.stderr"
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:/usr/bin:/bin" \
  OPENCODE_BIN="$BIN_DIR/opencode" \
  MANUL_DIR="$TMP/runtime" \
  MANUL_WORKSPACE="$TMP/runtime/workspace" \
  MANUL_TASK_WORKSPACE_ROOT="$TMP/runtime/workspace/ws-caracal" \
  MOCK_CARACAL_PROOF_FILE="$PROOF" \
  MOCK_CARACAL_MODE="$mode" \
  bash "$SCRIPT_DIR/opencode-adapter.sh" \
    --task-id "$task_id" --prompt "$PROMPT" --workspace "$TMP/runtime/workspace/ws-caracal" \
    --attempt 1 --timeout 30 --session-id "" \
    --stdout-file "$stdout" --stderr-file "$stderr" 2>/dev/null
}

out="$(run_adapter caracal-connected connected)"
[ "$(printf '%s' "$out" | jq -r '.status')" = "COMPLETED" ] || fail "connected Caracal task did not complete: $out"
grep -Fq 'command=mcp list' "$PROOF" || fail "adapter did not probe the effective OpenCode MCP registry"
grep -Fq 'command=run' "$PROOF" || fail "adapter did not start the model after Caracal passed"
[ "$(grep -c '^url=http://127.0.0.1:3500/mcp$' "$PROOF")" -ge 2 ] || fail "Caracal URL did not reach both MCP preflight and agent process"
[ "$(grep -c '^token=fixture-caracal-token$' "$PROOF")" -ge 2 ] || fail "Caracal token did not reach both MCP preflight and agent process"
! grep -q '^resolve_live=1$' "$PROOF" || fail "provider's one-shot live-resolution flag leaked into OpenCode"
[ ! -e "$TMP/runtime/.env" ] || ! grep -Fq 'fixture-caracal-token' "$TMP/runtime/.env" || fail "Caracal token was persisted in Manul runtime environment"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$CONFIG_HASH" ] || fail "operator's static OpenCode config was modified"
! printf '%s' "$out" | grep -Fq 'fixture-caracal-token' || fail "Caracal token leaked into adapter result"
pass "Manul refreshes Caracal provider env per task, verifies connection, and keeps credentials process-scoped"

: >"$PROOF"
out="$(run_adapter caracal-disconnected disconnected)"
[ "$(printf '%s' "$out" | jq -r '.status')" = "COMPLETED" ] || fail "agent did not continue without disconnected Caracal: $out"
[ "$(printf '%s' "$out" | jq -r '.failure_code // empty')" = "" ] || fail "disconnected optional Caracal left a failure code: $out"
grep -Eq '^command=mcp list([[:space:]]|$)' "$PROOF" || fail "adapter did not perform OpenCode MCP reachability check"
grep -Eq '^command=run([[:space:]]|$)' "$PROOF" || fail "agent did not start after Caracal was disabled"
jq -e '.mcp.servers["caracal-rag"].disabled == true' "${PROOF}.overlay" >/dev/null || fail "Caracal was not disabled in task overlay"
[ "$(grep -c '^token=<unset>$' "$PROOF")" -eq 1 ] || fail "Caracal token was not cleared before agent process"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$CONFIG_HASH" ] || fail "operator OpenCode config changed after disconnected preflight"
pass "Manul disables disconnected Caracal only in task overlay and continues agent startup"

: >"$PROOF"
cat >"${TMP}/runtime/.env" <<'FITEO'
FITEO_BASE_URL=http://127.0.0.1:4600
FITEO_MANUL_PAT=fixture-fiteo-pat
FITEO
out="$(run_adapter manul-mcp-disconnected connected)"
[ "$(printf '%s' "$out" | jq -r '.status')" = "COMPLETED" ] || fail "unreachable Manul MCP blocked agent startup: $out"
grep -Eq '^command=mcp list([[:space:]]|$)' "$PROOF" || fail "adapter did not check generated MCP connectivity"
grep -Eq '^command=run([[:space:]]|$)' "$PROOF" || fail "agent did not start after pruning unreachable Manul MCP"
jq -e '.mcp.servers["manul-fiteo"] == null' "$PROOF.overlay" >/dev/null || fail "unreachable Manul Fiteo MCP was not removed from task overlay"
! printf '%s' "$out" | grep -Fq 'fixture-fiteo-pat' || fail "Fiteo PAT leaked into adapter result"
[ "$(grep -c '^fiteo_pat=<unset>
pass "Manul removes unreachable Manul-owned MCP entries without changing operator config"

: >"$PROOF"
mv "$PROVIDER" "$PROVIDER.disabled"
out="$(run_adapter caracal-provider-missing provider-missing)" || true
[ "$(printf '%s' "$out" | jq -r '.status')" = "COMPLETED" ] || fail "missing optional Caracal provider blocked agent startup: $out"
[ "$(grep -c '^command=run([[:space:]]|$)' "$PROOF")" -eq 1 ] || fail "OpenCode should run without probing unavailable Caracal provider"
jq -e '.mcp.servers["caracal-rag"].disabled == true' "$PROOF.overlay" >/dev/null || fail "missing Caracal provider did not disable it in task overlay"
pass "Manul continues safely when configured Caracal provider is unavailable"
echo "Caracal/OpenCode MCP preflight tests: passed"
 "$PROOF")" -eq 1 ] || fail "unreachable Manul Fiteo token remained in the agent environment"
rm -f "${TMP}/runtime/.env"
pass "Manul removes unreachable Manul-owned MCP entries without changing operator config"

: >"$PROOF"
mv "$PROVIDER" "$PROVIDER.disabled"
out="$(run_adapter caracal-provider-missing provider-missing)" || true
[ "$(printf '%s' "$out" | jq -r '.status')" = "COMPLETED" ] || fail "missing optional Caracal provider blocked agent startup: $out"
[ "$(grep -c '^command=run([[:space:]]|$)' "$PROOF")" -eq 1 ] || fail "OpenCode should run without probing unavailable Caracal provider"
jq -e '.mcp.servers["caracal-rag"].disabled == true' "$PROOF.overlay" >/dev/null || fail "missing Caracal provider did not disable it in task overlay"
pass "Manul continues safely when configured Caracal provider is unavailable"
echo "Caracal/OpenCode MCP preflight tests: passed"
