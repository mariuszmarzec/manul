#!/usr/bin/env bash
# Regression: OpenCode's text-event step-limit signal must resume the same session,
# while ordinary task text mentioning the phrase must not trigger a continuation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/workspace" "$tmp/home"
printf '%s\n' 'Perform the task' >"$tmp/prompt"

cat >"$tmp/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
calls_file="$MOCK_CALLS_FILE"
count=0
[ ! -f "$calls_file" ] || count="$(cat "$calls_file")"
count=$((count + 1))
printf '%s' "$count" >"$calls_file"
if [ "$MOCK_SCENARIO" = "step-limit" ] && [ "$count" -eq 1 ]; then
  printf '%s\n' '{"type":"text","sessionID":"ses_step_limit","part":{"type":"text","text":"Maximum steps reached"}}'
elif [ "$MOCK_SCENARIO" = "ordinary-text" ]; then
  printf '%s\n' '{"type":"text","sessionID":"ses_step_limit","part":{"type":"text","text":"The docs explain what Maximum steps reached means."}}'
else
  printf '%s\n' '{"type":"text","sessionID":"ses_step_limit","part":{"type":"text","text":"TASK_DONE completed after continuation"}}'
fi
exit 0
MOCK
chmod +x "$tmp/bin/opencode"

run_adapter() {
  local scenario="$1"
  rm -f "$tmp/calls"
  PATH="$tmp/bin:$PATH" OPENCODE_BIN="$tmp/bin/opencode" \
    MOCK_CALLS_FILE="$tmp/calls" MOCK_SCENARIO="$scenario" \
    AGENT_RUNTIME=opencode MANUL_DIR="$tmp/runtime-$scenario" \
    MANUL_WORKSPACE="$tmp/workspace" MANUL_TASK_WORKSPACE_ROOT="$tmp/workspace" \
    HOME="$tmp/home" OPENCODE_CONFIG="$tmp/home/opencode.json" \
    bash "$SCRIPT_DIR/opencode-adapter.sh" \
      --task-id "step-limit-$scenario" --prompt "$tmp/prompt" --workspace "$tmp/workspace" \
      --attempt 1 --timeout 30 --session-id "" \
      --stdout-file "$tmp/$scenario.stdout" --stderr-file "$tmp/$scenario.stderr" 2>/dev/null
}

out="$(run_adapter step-limit)"
status="$(printf '%s' "$out" | jq -r '.status // empty')"
calls="$(cat "$tmp/calls")"
[ "$status" = "COMPLETED" ] || { echo "FAIL: step-limit continuation status=$status output=$out"; exit 1; }
[ "$calls" -eq 2 ] || { echo "FAIL: expected one same-session continuation (calls=$calls)"; exit 1; }
echo "PASS: exact Maximum steps reached text event triggers same-session continuation"

out="$(run_adapter ordinary-text || true)"
status="$(printf '%s' "$out" | jq -r '.status // empty')"
calls="$(cat "$tmp/calls")"
[ "$status" = "FAILED" ] || { echo "FAIL: ordinary text should not be accepted as completion (status=$status output=$out)"; exit 1; }
[ "$calls" -eq 1 ] || { echo "FAIL: ordinary task text incorrectly triggered continuation (calls=$calls)"; exit 1; }
echo "PASS: ordinary text mentioning step limit does not trigger continuation"
