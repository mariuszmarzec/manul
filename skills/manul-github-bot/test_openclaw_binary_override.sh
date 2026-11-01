#!/usr/bin/env bash
# test_openclaw_binary_override.sh — verify OpenClawAdapter honors OPENCLAW_BIN.
#
# Uses an isolated fake executable that is deliberately outside PATH.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/custom-openclaw" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "--json" ]; then
    echo "FAIL: adapter unexpectedly passed --json" >&2
    exit 90
  fi
done
printf '%s\n' 'TASK_DONE custom-binary'
exit 0
MOCK
chmod +x "$tmp/bin/custom-openclaw"
printf '%s\n' 'Do the task' >"$tmp/prompt"
: >"$tmp/stdout"
: >"$tmp/stderr"

set +e
out="$(PATH="/usr/bin:/bin" \
  OPENCLAW_BIN="$tmp/bin/custom-openclaw" \
  AGENT_RUNTIME=openclaw \
  MANUL_DIR="$tmp/runtime" \
  bash "$SCRIPT_DIR/openclaw-adapter.sh" \
    --task-id oc-custom \
    --prompt "$tmp/prompt" \
    --workspace "$tmp" \
    --attempt 1 \
    --timeout 30 \
    --session-id "" \
    --stdout-file "$tmp/stdout" \
    --stderr-file "$tmp/stderr" 2>/dev/null)"
rc=$?
set -e

status="$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null || true)"

if [ "$rc" -eq 0 ] && [ "$status" = "COMPLETED" ]; then
  echo "PASS: OpenClawAdapter honors explicit OPENCLAW_BIN outside PATH"
else
  echo "FAIL: custom OpenClaw binary was not executed (rc=$rc status=$status output=$out)"
  exit 1
fi

if grep -qx 'TASK_DONE custom-binary' "$tmp/stdout"; then
  echo "PASS: explicit custom OpenClaw binary produced the expected task output"
else
  echo "FAIL: expected TASK_DONE marker was not produced"
  exit 1
fi


# The adapter must not convert a clean process exit without an explicit
# TASK_DONE marker into a successful Manul completion.
mkdir -p "$tmp/bin/plain"
cat >"$tmp/bin/plain-openclaw" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' 'plain agent output without lifecycle marker'
exit 0
MOCK
chmod +x "$tmp/bin/plain-openclaw"
: >"$tmp/stdout-plain"
: >"$tmp/stderr-plain"

set +e
plain_out="$(PATH="/usr/bin:/bin"   OPENCLAW_BIN="$tmp/bin/plain-openclaw"   AGENT_RUNTIME=openclaw   MANUL_DIR="$tmp/runtime"   bash "$SCRIPT_DIR/openclaw-adapter.sh"     --task-id oc-plain     --prompt "$tmp/prompt"     --workspace "$tmp"     --attempt 1     --timeout 30     --session-id ""     --stdout-file "$tmp/stdout-plain"     --stderr-file "$tmp/stderr-plain" 2>/dev/null)"
plain_rc=$?
set -e

plain_status="$(printf '%s' "$plain_out" | jq -r '.status // empty' 2>/dev/null || true)"
plain_exit_code="$(printf '%s' "$plain_out" | jq -r '.exit_code // empty' 2>/dev/null || true)"

if [ "$plain_rc" -ne 0 ] && [ "$plain_status" = "FAILED" ] && [ "$plain_exit_code" = "1" ]; then
  echo "PASS: clean agent exit without TASK_DONE is treated as failure"
else
  echo "FAIL: clean agent exit without TASK_DONE was accepted (rc=$plain_rc status=$plain_status exit_code=$plain_exit_code output=$plain_out)"
  exit 1
fi

if grep -qE '^TASK_DONE([[:space:]]|$)' "$tmp/stdout-plain"; then
  echo "FAIL: adapter synthesized TASK_DONE for a clean exit"
  exit 1
else
  echo "PASS: adapter did not synthesize TASK_DONE"
fi

echo "All OpenClaw binary override tests passed."
