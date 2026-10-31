#!/usr/bin/env bash
# Regression tests for independent GitHub polling and SQLite queue consumption.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/manul-daemon.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

function_body() {
  local name="$1"
  awk -v start="$name() {" '
    $0 == start { active=1 }
    active && $0 ~ /^[[:alpha:]_][[:alnum:]_]*\(\) \{$/ && $0 != start { exit }
    active { print }
  ' "$DAEMON"
}

poll_body="$(function_body poll_once)"
dispatch_body="$(function_body dispatch_once)"
manual_body="$(function_body run_once)"
loop_body="$(function_body loop)"

[[ -n "$poll_body" ]] || fail "poll_once function is missing"
[[ -n "$dispatch_body" ]] || fail "dispatch_once function is missing"
[[ -n "$manual_body" ]] || fail "run_once compatibility wrapper is missing"

grep -Fq 'timeout "$poll_timeout" "$POLL"' <<<"$poll_body" || fail "poll_once must own the bounded poll.sh invocation"
grep -Fq 'record_poll "$poll_fire" "$poll_new" "$poll_pending"' <<<"$poll_body" || fail "poll results must remain observable"
! grep -Eq '\$POLL|parse_poll_result|record_poll|poll_fire' <<<"$dispatch_body" || fail "dispatch_once must not depend on polling"
lock_line="$(grep -n -m1 'if ! acquire_task_lock' <<<"$dispatch_body" | cut -d: -f1)"
pool_line="$(grep -n -m1 'if ! ensure_workspace_pool' <<<"$dispatch_body" | cut -d: -f1)"
[[ -n "$lock_line" && -n "$pool_line" && "$lock_line" -lt "$pool_line" ]] || fail "workspace reconciliation must happen under the dispatcher lock"
grep -Fq 'poll_once' <<<"$manual_body" || fail "manual run-once must still poll once"
grep -Fq 'dispatch_once' <<<"$manual_body" || fail "manual run-once must still dispatch once"

grep -Fq -- '--poller' <<<"$loop_body" || fail "loop must support the dedicated producer role"
grep -Fq 'poll_once ||' <<<"$loop_body" || fail "poller loop must call poll_once"
grep -Fq 'dispatch_once' <<<"$loop_body" || fail "consumer loop must dispatch directly from SQLite"
grep -Fq 'sleep "$DISPATCH_INTERVAL"' <<<"$loop_body" || fail "consumer cadence must be independent of poll interval"

grep -Fq 'loop --poller --parent-pid=' "$DAEMON" || fail "supervisor must spawn and restart a dedicated poller"
grep -Fq 'wait -n "${WORKER_PIDS[@]}" "$poller_pid"' "$DAEMON" || fail "supervisor must detect poller exits independently"
grep -Fq 'rm -f "$PID_FILE" "$POLLER_PID_FILE"' "$DAEMON" || fail "supervisor shutdown must clear the poller PID marker"

echo "All producer/consumer separation checks passed."
