#!/usr/bin/env bash
# Regression tests for manul-comments-remove.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPROOT="$(mktemp -d /tmp/manul-comments-remove-test-XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
FAKE_BIN="$TMPROOT/bin"
LOG="$TMPROOT/curl.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -e
case "$*" in
  "auth token")
    echo token
    ;;
  *"pr view"*"--json number"*)
    case "$*" in
      *" --number "*) echo "unexpected legacy --number flag" >&2; exit 9 ;;
    esac
    echo '{"number":34}'
    ;;
  *"pr view"*"--json body"*)
    case "$*" in
      *" --number "*) echo "unexpected legacy --number flag" >&2; exit 9 ;;
    esac
    echo '{"body":""}'
    ;;
  *"api --paginate --slurp repos/test-owner/test-repo/pulls/34/comments?per_page=100"*)
    if [ "${FAIL_REVIEW_API:-0}" = "1" ]; then
      echo "simulated review API failure" >&2
      exit 7
    fi
    printf '%s
' '[
      [
        {"id":4098362711,"body":"/manul original user request","in_reply_to_id":null},
        {"id":4126334268,"body":"/manul do this","in_reply_to_id":4098362711},
        {"id":4126396380,"body":"working\n\n— manul 🐈","in_reply_to_id":4126334268},
        {"id":4164153672,"body":"result\n\n— manul 🐈","in_reply_to_id":4126396380},
        {"id":500,"body":"unrelated Manul thread\n\n— manul 🐈","in_reply_to_id":null}
      ]
    ]'
    ;;
  *"api --paginate repos/test-owner/test-repo/issues/34/comments"*)
    echo '[]'
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
GH
chmod +x "$FAKE_BIN/gh"

cat > "$FAKE_BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -e
printf "%s\n" "$*" >> "$CURL_LOG"
out_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -z "$out_file" ] || : > "$out_file"
printf "204"
CURL
chmod +x "$FAKE_BIN/curl"

run_remove() {
  local url="$1"
  local output="$2"
  : > "$LOG"
  CURL_LOG="$LOG" PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" "$url" > "$output"
}

run_remove_expect_failure() {
  local url="$1"
  local output="$2"
  local env_name="${3:-}"
  : > "$LOG"
  set +e
  if [ "$env_name" = "FAIL_REVIEW_API" ]; then
    FAIL_REVIEW_API=1 CURL_LOG="$LOG" PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" "$url" > "$output" 2>&1
  else
    CURL_LOG="$LOG" PATH="$FAKE_BIN:$PATH" "$SCRIPT_DIR/manul-comments-remove.sh" "$url" > "$output" 2>&1
  fi
  local rc=$?
  set -e
  [ "$rc" -ne 0 ] || {
    echo "FAIL: expected command to fail"
    cat "$output"
    exit 1
  }
}

echo "Test 1: root #discussion_r URL removes only Manul comments in that thread"
run_remove   "https://github.com/test-owner/test-repo/pull/34#discussion_r4098362711"   "$TMPROOT/out1"

cat "$TMPROOT/out1"
grep -q "Target: test-owner/test-repo# 34" "$TMPROOT/out1"
grep -q "Review thread filter: #discussion_r4098362711" "$TMPROOT/out1"
grep -q "Deleted:  2" "$TMPROOT/out1"
grep -q "PR review comments: 2" "$TMPROOT/out1"
grep -q "pulls/comments/4126396380" "$LOG"
grep -q "pulls/comments/4164153672" "$LOG"
if grep -qE 'pulls/comments/(4098362711|4126334268|500)' "$LOG"; then
  echo "FAIL: root/intermediate/unrelated comment was deleted"
  exit 1
fi
echo "PASS"

echo "Test 2: nested #discussion_r URL still resolves the same thread"
run_remove   "https://github.com/test-owner/test-repo/pull/34#discussion_r4126334268"   "$TMPROOT/out2"

cat "$TMPROOT/out2"
grep -q "Review thread filter: #discussion_r4126334268" "$TMPROOT/out2"
grep -q "Deleted:  2" "$TMPROOT/out2"
grep -q "pulls/comments/4126396380" "$LOG"
grep -q "pulls/comments/4164153672" "$LOG"
if grep -qE 'pulls/comments/(4098362711|4126334268|500)' "$LOG"; then
  echo "FAIL: nested selective cleanup touched non-Manul comment"
  exit 1
fi
echo "PASS"

echo "Test 3: plain PR URL still removes all Manul review comments"
run_remove   "https://github.com/test-owner/test-repo/pull/34"   "$TMPROOT/out3"

cat "$TMPROOT/out3"
grep -q "Deleted:  3" "$TMPROOT/out3"
grep -q "pulls/comments/4126396380" "$LOG"
grep -q "pulls/comments/4164153672" "$LOG"
grep -q "pulls/comments/500" "$LOG"
if grep -qE 'pulls/comments/(4098362711|4126334268)' "$LOG"; then
  echo "FAIL: plain cleanup deleted non-Manul comments"
  exit 1
fi
echo "PASS"

echo "Test 4: missing review comment fails explicitly"
run_remove_expect_failure   "https://github.com/test-owner/test-repo/pull/34#discussion_r99999999999"   "$TMPROOT/out4"
cat "$TMPROOT/out4"
grep -q "was not found" "$TMPROOT/out4"
if grep -q "No matching Manul comments found" "$TMPROOT/out4"; then
  echo "FAIL: missing review comment was reported as empty match"
  exit 1
fi
echo "PASS"

echo "Test 5: review API failure fails explicitly"
run_remove_expect_failure   "https://github.com/test-owner/test-repo/pull/34#discussion_r4098362711"   "$TMPROOT/out5"   "FAIL_REVIEW_API"
cat "$TMPROOT/out5"
grep -q "Error: failed to fetch PR review comments" "$TMPROOT/out5"
if grep -q "No matching Manul comments found" "$TMPROOT/out5"; then
  echo "FAIL: API failure was reported as empty match"
  exit 1
fi
echo "PASS"

echo "=== Results: 5 passed, 0 failed ==="
