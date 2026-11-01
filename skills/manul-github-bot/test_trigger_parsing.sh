#!/usr/bin/env bash
# Regression tests for the /manul trigger gate in poll.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL="$SCRIPT_DIR/poll.sh"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name (expected=$expected actual=$actual)"
  fi
}

echo "=== /manul trigger newline regression tests ==="

# The three production jq gates (issue comments, issue bodies, PR review comments)
# must all allow whitespace/newline after the trigger.
gate_count="$(grep -F '([ \\t\\r\\n]|$)' "$POLL" | wc -l | tr -d ' ')"
assert_eq "all three trigger gates accept newline" "3" "$gate_count"

run_gate() {
  local body="$1"
  printf '%s\n' "$body" |
    jq -R -s --arg trig "/manul" '
      ($trig | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) as $trig_re
      | test("(^|\\r?\\n)[ \\t]*" + $trig_re + "([ \\t\\r\\n]|$)")
    '
}

assert_eq "space after trigger matches" "true" "$(run_gate '/manul do this')"
assert_eq "single newline after trigger matches" "true" "$(run_gate $'/manul\nDo this')"
assert_eq "blank line after trigger matches" "true" "$(run_gate $'/manul\n\nDo this')"
assert_eq "bare trigger matches" "true" "$(run_gate '/manul')"
assert_eq "indented trigger matches" "true" "$(run_gate '  /manul do this')"
assert_eq "prefix text does not match" "false" "$(run_gate 'text /manul do this')"
assert_eq "manually does not match" "false" "$(run_gate '/manually do this')"
assert_eq "manulfoo does not match" "false" "$(run_gate '/manulfoo')"

echo
echo "Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
