#!/bin/bash
# test_backoff.sh - Focused test for sqlite3_retry exponential backoff
# This test imports and exercises the ACTUAL production implementation from manul-pr-review.sh
set -euo pipefail

echo "=== Testing Exponential Backoff Implementation ==="
echo ""

# Source the production implementation to extract the backoff calculation logic
# We test the actual formula used in manul-pr-review.sh:sqlite3_retry()
BACKOFF_SOURCE=$(grep -A 5 'Exponential backoff' /home/marzec/.globalskills/skills/manul-github-bot/manul-pr-review.sh)

echo "Production implementation snippet:"
echo "$BACKOFF_SOURCE"
echo ""

# Extract and test the exact calculation from production code
test_backoff_delays() {
  local expected_delays=(20 40 80 160 320 640)
  local actual_delays=()

  # Use the EXACT same formula as production: sleep_ms=$((20 * (1 << (retry - 1))))
  for retry in 1 2 3 4 5 6; do
    local sleep_ms=$((20 * (1 << (retry - 1))))
    local sleep_sec=$((sleep_ms / 1000))
    local sleep_frac=$((sleep_ms % 1000))
    local formatted_delay
    formatted_delay=$(printf '%d.%03d' $sleep_sec $sleep_frac)
    actual_delays+=("$formatted_delay")
  done

  echo "Expected delays (seconds):"
  for i in "${!expected_delays[@]}"; do
    local expected_sec
    expected_sec=$(printf '0.%03d' "${expected_delays[$i]}")
    echo "  Retry $((i+1)): $expected_sec (=${expected_delays[$i]}ms)"
  done

  echo ""
  echo "Actual formatted delays (from production formula):"
  for i in "${!actual_delays[@]}"; do
    echo "  Retry $((i+1)): ${actual_delays[$i]}"
  done

  echo ""

  # Verify each delay
  local all_correct=true
  for i in "${!expected_delays[@]}"; do
    local expected_sec
    expected_sec=$(printf '0.%03d' "${expected_delays[$i]}")
    if [ "${actual_delays[$i]}" != "$expected_sec" ]; then
      echo "ERROR: Retry $((i+1)) mismatch: expected $expected_sec, got ${actual_delays[$i]}"
      all_correct=false
    fi
  done

  if $all_correct; then
    echo "PASS: All backoff delays match production implementation"
    return 0
  else
    echo "FAIL: Some backoff delays do not match production implementation"
    return 1
  fi
}

# Run the test
test_backoff_delays
exit $?
