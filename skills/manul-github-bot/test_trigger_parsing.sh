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
echo "=== /manul team command classification in all GitHub poll paths ==="

team_branch_count="$(grep -F 'then' "$POLL" | grep -F '{action: "TEAM", prompt:' | wc -l | tr -d ' ')"
assert_eq "all three GitHub poll paths classify team explicitly" "3" "$team_branch_count"

team_prompt_count="$(grep -F 'or $actx.action == "TEAM" then $actx.prompt' "$POLL" | wc -l | tr -d ' ')"
assert_eq "issue and inline-review comments keep the parsed Team goal as the prompt" "2" "$team_prompt_count"

# Execute the exact jq classifier fragment extracted from each production path.
# This catches regressions where the shared helper parser works but poll.sh's
# duplicated inline parser silently falls back to IMPLEMENT.
extract_classifier() {
  local target="$1"
  awk -v target="$target" '
    /^[[:space:]]*\| \(if \(\$rest \| test\("\\\^team/ {
      seen++
      if (seen == target) {
        active=1
        sub(/^[[:space:]]*\|[[:space:]]*/, "")
        print
        next
      }
    }
    active {
      print
      if ($0 ~ /end\) as \$actx/) exit
    }
  ' "$POLL"
}

for classifier_index in 1 2 3; do
  classifier="$(extract_classifier "$classifier_index")"
  if [ -z "$classifier" ] || ! grep -q 'end) as \$actx' <<<"$classifier"; then
    fail "poll classifier $classifier_index can be extracted for executable regression coverage"
    continue
  fi
  executable_filter="$(printf '%s\n' "$classifier" | sed 's/end) as \$actx$/end) as $actx | $actx/')"
  team_result="$(jq -nc \
    --arg rest "team Build the Team workflow" \
    --arg tok "team" \
    --arg agent "team" \
    --arg prompt_no_agent "Build the Team workflow" \
    "$executable_filter" 2>/dev/null)" || team_result=""
  assert_eq "poll classifier $classifier_index returns TEAM action" "TEAM" "$(jq -r '.action // empty' <<<"$team_result" 2>/dev/null || true)"
  assert_eq "poll classifier $classifier_index strips command token from Team prompt" "Build the Team workflow" "$(jq -r '.prompt // empty' <<<"$team_result" 2>/dev/null || true)"
  assert_eq "poll classifier $classifier_index clears implicit team role selection" "" "$(jq -r '.agent // empty' <<<"$team_result" 2>/dev/null || true)"

  run_result="$(jq -nc \
    --arg rest "run Keep ordinary implementation behavior" \
    --arg tok "run" \
    --arg agent "" \
    --arg prompt_no_agent "run Keep ordinary implementation behavior" \
    "$executable_filter" 2>/dev/null)" || run_result=""
  assert_eq "poll classifier $classifier_index keeps /manul run as IMPLEMENT" "IMPLEMENT" "$(jq -r '.action // empty' <<<"$run_result" 2>/dev/null || true)"
  assert_eq "poll classifier $classifier_index strips /manul run token" "Keep ordinary implementation behavior" "$(jq -r '.prompt // empty' <<<"$run_result" 2>/dev/null || true)"
done

echo
echo "Results: $PASS passed, $FAIL failed"

[ "$FAIL" -eq 0 ]
