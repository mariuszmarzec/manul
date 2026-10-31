#!/usr/bin/env bash
# Regression: tokens in OpenCode tool payloads must not synthesize Manul markers.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' 'caracal-rag connected'
  exit 0
fi
printf '%s\n' '{"type":"text","timestamp":1000,"sessionID":"ses_marker-docs","part":{"type":"text","text":"TASK_DONE task completed"}}'
printf '%s\n' '{"type":"tool_use","timestamp":1100,"sessionID":"ses_marker-docs","part":{"type":"tool-use","state":{"status":"completed","input":{"documentation":"Use TASK_NEEDS_USER_BEGIN then TASK_NEEDS_USER_END to ask for input."}}}}'
printf '%s\n' '{"type":"step_finish","timestamp":1200,"sessionID":"ses_marker-docs","part":{"type":"step-finish","reason":"stop"}}'
exit 0
MOCK
chmod +x "$tmp/bin/opencode"
printf '%s\n' 'Do the task' >"$tmp/prompt"

out="$(PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" \
  CARACAL_MCP_URL="http://127.0.0.1:3500/mcp" CARACAL_ACCESS_TOKEN="test-caracal-token" \
  AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime" \
  bash "$SCRIPT_DIR/opencode-adapter.sh" \
    --task-id marker-docs --prompt "$tmp/prompt" --workspace "$tmp" \
    --attempt 1 --timeout 30 --session-id "" \
    --stdout-file "$tmp/stdout" --stderr-file "$tmp/stderr" 2>/dev/null)"
status="$(printf '%s' "$out" | jq -r '.status // empty')"
if [ "$status" = "COMPLETED" ]; then ok "TASK_DONE remains successful despite marker names in tool payload"; else fail "Expected COMPLETED, got $status: $out"; fi
if [ "$(grep -c '^TASK_DONE' "$tmp/stdout")" -eq 1 ]; then ok "one TASK_DONE output marker"; else fail "unexpected TASK_DONE output: $(cat "$tmp/stdout")"; fi
if ! grep -qE '^TASK_NEEDS_USER_BEGIN$|^TASK_NEEDS_USER_END$' "$tmp/stdout"; then ok "tool payload does not synthesize user-decision control lines"; else fail "synthetic user-decision lines: $(cat "$tmp/stdout")"; fi
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
