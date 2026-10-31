#!/usr/bin/env bash
# Regression tests for terminal failure delivery: stage metadata, redaction,
# overlapping-handler deduplication, and preservation of DB failure state.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
export TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export DB="$MANUL_DIR/state/manul.db"
export MANUL_MODE=bot
export GH_COMMENTS_JSONL="$TEST_DIR/github-comments.jsonl"
export GH_CALL_LOG="$TEST_DIR/github-calls.log"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/logs" "$TEST_DIR/bin"
: > "$GH_COMMENTS_JSONL"
: > "$GH_CALL_LOG"

cat > "$MANUL_DIR/config.json" <<'JSON'
{
  "mode": "bot",
  "automation": {
    "maxAttemptsBeforeFail": 1,
    "maxTaskRunningTime": 1,
    "heartbeatTimeout": 1,
    "leaseTimeout": 1
  },
  "retryConfig": { "delaySeconds": 1 }
}
JSON

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT,
  issueNumber INTEGER,
  commentUrl TEXT,
  action TEXT,
  status TEXT,
  attempts INTEGER,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  conversationId TEXT,
  preExecutionFailures INTEGER DEFAULT 0,
  agentStartedAt TEXT
);
SQL

cat > "$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf 'CALL:%s\n' "$*" >> "$GH_CALL_LOG"

if [[ "${1:-}" == "api" ]]; then
  endpoint="${2:-}"
  if [[ " $* " == *" --input - "* ]]; then
    if [ "${GH_FAIL_POST:-0}" = "1" ]; then
      echo "simulated GitHub comment failure" >&2
      exit 1
    fi
    request="$(cat)"
    body="$(printf '%s' "$request" | jq -r '.body // ""')"
    reply_to="$(printf '%s' "$request" | jq -r '.in_reply_to // empty')"
    comment_id="$(jq -s 'length + 1000' "$GH_COMMENTS_JSONL")"
    jq -nc --arg body "$body" --argjson id "$comment_id" --arg reply_to "$reply_to" \
      '{id:$id,body:$body,in_reply_to_id:(if $reply_to == "" then null else ($reply_to|tonumber) end)}' \
      >> "$GH_COMMENTS_JSONL"
    printf '{"id":%s}\n' "$comment_id"
    exit 0
  fi
  if [ "${GH_FAIL_API:-0}" = "1" ]; then
    echo "simulated GitHub list failure" >&2
    exit 1
  fi
  jq -s '.' "$GH_COMMENTS_JSONL"
  exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
  if [ "${GH_FAIL_POST:-0}" = "1" ]; then
    echo "simulated GitHub comment failure" >&2
    exit 1
  fi
  body=""
  while (($#)); do
    if [[ "$1" == "--body" ]]; then body="$2"; shift 2; else shift; fi
  done
  comment_id="$(jq -s 'length + 1000' "$GH_COMMENTS_JSONL")"
  jq -nc --arg body "$body" --argjson id "$comment_id" \
    '{id:$id,body:$body,in_reply_to_id:null}' >> "$GH_COMMENTS_JSONL"
  printf '{"id":%s}\n' "$comment_id"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 2
GH
chmod +x "$TEST_DIR/bin/gh"
export PATH="$TEST_DIR/bin:$PATH"

# Export a small wrapper so child Bash processes use the same deterministic
# fake GitHub transport even when production scripts prepend system paths.
gh() {
  "$TEST_DIR/bin/gh" "$@"
}
export -f gh

DAEMON="$SCRIPT_DIR/manul-daemon.sh"
eval "$(sed -n '/^log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^lc_log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^post_github_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^post_lifecycle_comment() {/,/^}/p' "$DAEMON" | sed 's/^post_lifecycle_comment()/post_lifecycle_comment_original()/')"
eval "$(sed -n '/^find_task_started_comment_id() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^post_task_started_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^publish_task_started_for_claim() {/,/^}/p' "$DAEMON")"
LOG="$MANUL_DIR/logs/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/logs/lifecycle.log"
touch "$LOG" "$LIFECYCLE_LOG"

# Test-only wrapper simulates a client error after GitHub accepted the comment.
GH_AMBIGUOUS_POST=0
post_lifecycle_comment() {
  local repo="$1" issue="$2" body="$3" reply_to="${4:-}"
  post_github_comment "$repo" "$issue" "$body" "$reply_to" >/dev/null || return $?
  if [ "$GH_AMBIGUOUS_POST" = "1" ]; then
    GH_AMBIGUOUS_POST=0
    return 1
  fi
  return 0
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $message (expected=$expected actual=$actual)" >&2
    exit 1
  fi
  echo "PASS: $message"
}

count_for_task() {
  jq -s --arg task "$1" '[.[] | select(((.body // "") | contains("\"type\":\"TASK_FAILED\"")) and ((.body // "") | contains("\"taskId\":\"" + $task + "\"")))] | length' "$GH_COMMENTS_JSONL"
}

count_task_started() {
  jq -s --arg task "$1" --argjson attempt "$2" '
    [
      .[]
      | select(
          ((.body // "") | contains("\"type\":\"TASK_STARTED\""))
          and ((.body // "") | contains("\"taskId\":\"" + $task + "\""))
          and ((.body // "") | contains("\"attempt\":" + ($attempt | tostring)))
        )
    ] | length
  ' "$GH_COMMENTS_JSONL"
}

# Exercise the production pre-agent recovery function with only its
# external side effects stubbed. The SQLite claim/attempt transition itself
# remains the production implementation under test.
CONFIG="$MANUL_DIR/config.json"
RETRY_DELAY_SECONDS=1
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
manul_redact_failure_details() { printf '%s' "$1"; }
ensure_recovery_tracking_columns() { return 0; }
stop_heartbeat() { :; }
workspace_release() { :; }
release_task_repo_lock() { :; }
release_task_lock() { :; }
set_activity() { :; }
post_task_failure_feedback() { :; }
eval "$(sed -n '/^handle_pre_execution_failure() {/,/^}/p' "$DAEMON")"

test_task_started_claim_accounting() {
  local rc status attempts infra_failures body
  echo "=== production TASK_STARTED dispatcher claim accounting ==="

  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts,claimToken) VALUES ('started-ambiguous-claim','test/repo',88,'https://github.com/test/repo/issues/88','IMPLEMENT','running',2,'claim-ambiguous');"
  : >"$GH_COMMENTS_JSONL"
  body='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T16:10:00Z","data":{"taskId":"started-ambiguous-claim","conversationId":"conv-ambiguous","status":"started","attempt":2}} -->

— manul 🐈'
  GH_AMBIGUOUS_POST=1
  rc=0
  publish_task_started_for_claim "started-ambiguous-claim" "claim-ambiguous" "test/repo" 88 "" "" "$body" "" 2 || rc=$?
  assert_eq 0 "$rc" "ambiguous accepted TASK_STARTED is reconciled before dispatcher recovery"
  status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='started-ambiguous-claim';")"
  attempts="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='started-ambiguous-claim';")"
  assert_eq running "$status" "confirmed ambiguous start keeps the claimed task running"
  assert_eq 2 "$attempts" "confirmed ambiguous start preserves the current attempt number"
  assert_eq 1 "$(count_task_started started-ambiguous-claim 2)" "accepted ambiguous start exists exactly once"

  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts,claimToken) VALUES ('started-definite-failure','test/repo',89,'https://github.com/test/repo/issues/89','IMPLEMENT','running',2,'claim-definite');"
  : >"$GH_COMMENTS_JSONL"
  body='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T16:11:00Z","data":{"taskId":"started-definite-failure","conversationId":"conv-definite","status":"started","attempt":2}} -->

— manul 🐈'
  export GH_FAIL_POST=1
  rc=0
  publish_task_started_for_claim "started-definite-failure" "claim-definite" "test/repo" 89 "" "" "$body" "" 2 || rc=$?
  unset GH_FAIL_POST
  assert_eq 1 "$rc" "definite start failure hands control back to dispatcher without launching the agent"
  status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='started-definite-failure';")"
  attempts="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='started-definite-failure';")"
  infra_failures="$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='started-definite-failure';")"
  assert_eq queued "$status" "production recovery requeues after definite start failure"
  assert_eq 1 "$attempts" "production recovery rolls back the unstarted attempt"
  assert_eq 1 "$infra_failures" "production recovery increments preExecutionFailures"
  assert_eq '<NULL>' "$(sqlite3 "$DB" "SELECT COALESCE(agentStartedAt,'<NULL>') FROM processed_comments WHERE commentId='started-definite-failure';")" "production recovery clears agentStartedAt"
  assert_eq '<NULL>' "$(sqlite3 "$DB" "SELECT COALESCE(claimToken,'<NULL>') FROM processed_comments WHERE commentId='started-definite-failure';")" "production recovery releases the claim token"
  assert_eq '<NULL>' "$(sqlite3 "$DB" "SELECT COALESCE(heartbeatAt,'<NULL>') FROM processed_comments WHERE commentId='started-definite-failure';")" "production recovery clears the heartbeat"
  assert_eq '<NULL>' "$(sqlite3 "$DB" "SELECT COALESCE(leaseExpiresAt,'<NULL>') FROM processed_comments WHERE commentId='started-definite-failure';")" "production recovery clears the lease"

  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts,claimToken) VALUES ('started-lookup-failure','test/repo',90,'https://github.com/test/repo/issues/90','IMPLEMENT','running',2,'claim-lookup');"
  : >"$GH_COMMENTS_JSONL"
  body='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T16:12:00Z","data":{"taskId":"started-lookup-failure","conversationId":"conv-lookup","status":"started","attempt":2}} -->

— manul 🐈'
  export GH_FAIL_API=1
  rc=0
  publish_task_started_for_claim "started-lookup-failure" "claim-lookup" "test/repo" 90 "" "" "$body" "" 2 || rc=$?
  unset GH_FAIL_API
  assert_eq 1 "$rc" "failed idempotency lookup stops dispatch after bounded pre-execution recovery"
  status="$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='started-lookup-failure';")"
  attempts="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='started-lookup-failure';")"
  infra_failures="$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='started-lookup-failure';")"
  assert_eq queued "$status" "production recovery requeues after failed idempotency lookup"
  assert_eq 1 "$attempts" "lookup failure preserves the agent attempt budget"
  assert_eq 1 "$infra_failures" "lookup failure increments preExecutionFailures"
  assert_eq '<NULL>' "$(sqlite3 "$DB" "SELECT COALESCE(agentStartedAt,'<NULL>') FROM processed_comments WHERE commentId='started-lookup-failure';")" "lookup recovery clears agentStartedAt"
  assert_eq '<NULL>' "$(sqlite3 "$DB" "SELECT COALESCE(claimToken,'<NULL>') FROM processed_comments WHERE commentId='started-lookup-failure';")" "lookup recovery releases the claim token"
}
test_task_started_claim_accounting

test_dispatch_stops_after_unconfirmed_task_started() {
  local dispatch_body guard_block call_line prompt_line
  dispatch_body="$(sed -n '/^dispatch_once()/,/^run_once()/p' "$DAEMON")"
  guard_block="$(printf '%s\n' "$dispatch_body" | sed -n '/if ! publish_task_started_for_claim/,/^    fi/p')"
  if [[ "$dispatch_body" != *"if ! publish_task_started_for_claim"* ]]; then
    echo "FAIL: dispatcher does not guard an unconfirmed TASK_STARTED publication" >&2
    return 1
  fi
  if [[ "$guard_block" != *"return 0"* ]]; then
    echo "FAIL: dispatcher does not return after TASK_STARTED recovery" >&2
    return 1
  fi
  call_line="$(printf '%s\n' "$dispatch_body" | grep -n "if ! publish_task_started_for_claim" | head -1 | cut -d: -f1)"
  prompt_line="$(printf '%s\n' "$dispatch_body" | grep -n 'Create per-task prompt' | head -1 | cut -d: -f1)"
  if [ -z "$call_line" ] || [ -z "$prompt_line" ] || [ "$prompt_line" -le "$call_line" ]; then
    echo "FAIL: TASK_STARTED guard is missing or appears after prompt creation" >&2
    return 1
  fi
  echo "PASS: TASK_STARTED publication failure exits dispatch before prompt/runtime setup"
}
test_dispatch_stops_after_unconfirmed_task_started

test_task_started_idempotency() {
  local body1 body2 body3 rc
  body1='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T15:00:00Z","data":{"taskId":"issue:started-dedupe","conversationId":"conv-started-dedupe","status":"started","attempt":2}} -->
🔄 Manul is preparing this task...'

  post_task_started_comment "test/repo" 81 "issue:started-dedupe" 2 "$body1" ""
  assert_eq 1 "$(count_task_started issue:started-dedupe 2)" "first TASK_STARTED publication creates one comment"
  post_task_started_comment "test/repo" 81 "issue:started-dedupe" 2 "$body1" ""
  assert_eq 1 "$(count_task_started issue:started-dedupe 2)" "retry suppresses an existing TASK_STARTED for the same attempt"

  # The fake server persists the comment, then makes the publishing client
  # return an error. The helper must confirm the accepted event by reading it
  # back instead of rolling the claim into another same-attempt publication.
  body2='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T15:01:00Z","data":{"taskId":"issue:started-ambiguous","conversationId":"conv-started-ambiguous","status":"started","attempt":3}} -->
🔄 Manul is preparing this task...'
  GH_AMBIGUOUS_POST=1
  post_task_started_comment "test/repo" 82 "issue:started-ambiguous" 3 "$body2" ""
  assert_eq 1 "$(count_task_started issue:started-ambiguous 3)" "ambiguous accepted TASK_STARTED post is confirmed by read-back"
  post_task_started_comment "test/repo" 82 "issue:started-ambiguous" 3 "$body2" ""
  assert_eq 1 "$(count_task_started issue:started-ambiguous 3)" "ambiguous post retry remains idempotent"

  body3='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T15:02:00Z","data":{"taskId":"issue:started-failed","conversationId":"conv-started-failed","status":"started","attempt":4}} -->
🔄 Manul is preparing this task...'
  export GH_FAIL_POST=1
  rc=0
  post_task_started_comment "test/repo" 83 "issue:started-failed" 4 "$body3" "" || rc=$?
  assert_eq 1 "$rc" "definite comment post failure remains retryable"
  assert_eq 0 "$(count_task_started issue:started-failed 4)" "failed start publication leaves no marker"
  unset GH_FAIL_POST

  # If the list-comments API is unavailable, never post blindly: a prior
  # ambiguous success may already have created the marker.
  export GH_FAIL_API=1
  rc=0
  post_task_started_comment "test/repo" 84 "issue:started-api-error" 5 "$body3" "" || rc=$?
  assert_eq 2 "$rc" "failed idempotency lookup is fail-closed"
  assert_eq 0 "$(count_task_started issue:started-api-error 5)" "lookup failure does not create a duplicate comment"
  unset GH_FAIL_API
}

test_task_started_idempotency

test_task_started_concurrent_idempotency() {
  local body pid1 pid2
  body='<!-- manul:event {"type":"TASK_STARTED","timestamp":"2026-10-30T16:00:00Z","data":{"taskId":"issue:started-concurrent","conversationId":"conv-started-concurrent","status":"started","attempt":8}} -->
🔄 Manul is preparing this task...

— manul 🐈'
  : > "$GH_COMMENTS_JSONL"
  : > "$GH_CALL_LOG"
  post_task_started_comment "test/repo" 86 "issue:started-concurrent" 8 "$body" &
  pid1=$!
  post_task_started_comment "test/repo" 86 "issue:started-concurrent" 8 "$body" &
  pid2=$!
  wait "$pid1"
  wait "$pid2"
  assert_eq 1 "$(count_task_started issue:started-concurrent 8)" "concurrent TASK_STARTED publishers create only one comment"
}
test_task_started_concurrent_idempotency

test_task_started_review_thread_idempotency() {
  local target_body other_body only_other_body target_count other_count
  local task_id="issue:started-review-thread"
  local attempt=6
  local target_reply=900
  local other_reply=901

  : > "$GH_COMMENTS_JSONL"
  : > "$GH_CALL_LOG"
  target_body="<!-- manul:event {\"type\":\"TASK_STARTED\",\"timestamp\":\"2026-10-30T15:03:00Z\",\"data\":{\"taskId\":\"$task_id\",\"conversationId\":\"conv-review\",\"status\":\"started\",\"attempt\":$attempt}} -->
🔄 Manul is preparing this task...

— manul 🐈"
  other_body="$target_body"

  # The same event exists in the target thread and a different review thread.
  # Only the comment whose in_reply_to_id matches reply_to may suppress a post.
  jq -nc --arg body "$target_body" --argjson id 200 --argjson reply "$target_reply" \
    '{id:$id,body:$body,in_reply_to_id:$reply}' >> "$GH_COMMENTS_JSONL"
  jq -nc --arg body "$other_body" --argjson id 201 --argjson reply "$other_reply" \
    '{id:$id,body:$body,in_reply_to_id:$reply}' >> "$GH_COMMENTS_JSONL"

  post_task_started_comment "test/repo" 85 "$task_id" "$attempt" "$target_body" "$target_reply"
  target_count="$(jq -s --arg task "$task_id" --argjson attempt "$attempt" --argjson reply "$target_reply" \
    '[.[] | select(.in_reply_to_id == $reply and ((.body // "") | contains($task)) and ((.body // "") | contains("\"attempt\":" + ($attempt|tostring))))] | length' "$GH_COMMENTS_JSONL")"
  other_count="$(jq -s --arg task "$task_id" --argjson attempt "$attempt" --argjson reply "$other_reply" \
    '[.[] | select(.in_reply_to_id == $reply and ((.body // "") | contains($task)) and ((.body // "") | contains("\"attempt\":" + ($attempt|tostring))))] | length' "$GH_COMMENTS_JSONL")"
  assert_eq 1 "$target_count" "existing TASK_STARTED in the requested review thread suppresses duplicate"
  assert_eq 1 "$other_count" "same TASK_STARTED marker in another review thread remains independent"
  grep -Fq 'repos/test/repo/pulls/85/comments' "$GH_CALL_LOG" \
    && echo "PASS: review-thread lookup uses the PR comments endpoint" \
    || { echo "FAIL: review-thread lookup did not use the PR comments endpoint" >&2; exit 1; }

  # A marker only in a different thread must not suppress a reply to this one.
  : > "$GH_COMMENTS_JSONL"
  : > "$GH_CALL_LOG"
  only_other_body="<!-- manul:event {\"type\":\"TASK_STARTED\",\"timestamp\":\"2026-10-30T15:04:00Z\",\"data\":{\"taskId\":\"issue:started-other-thread\",\"conversationId\":\"conv-review\",\"status\":\"started\",\"attempt\":7}} -->
🔄 Manul is preparing this task...

— manul 🐈"
  jq -nc --arg body "$only_other_body" --argjson id 202 --argjson reply "$other_reply" \
    '{id:$id,body:$body,in_reply_to_id:$reply}' >> "$GH_COMMENTS_JSONL"

  post_task_started_comment "test/repo" 85 "issue:started-other-thread" 7 "$only_other_body" "$target_reply"
  target_count="$(jq -s --arg task "issue:started-other-thread" --argjson reply "$target_reply" \
    '[.[] | select(.in_reply_to_id == $reply and ((.body // "") | contains($task)))] | length' "$GH_COMMENTS_JSONL")"
  other_count="$(jq -s --arg task "issue:started-other-thread" --argjson reply "$other_reply" \
    '[.[] | select(.in_reply_to_id == $reply and ((.body // "") | contains($task)))] | length' "$GH_COMMENTS_JSONL")"
  assert_eq 1 "$target_count" "marker in another review thread does not suppress target-thread publication"
  assert_eq 1 "$other_count" "existing marker in another review thread is preserved"
  grep -Fq 'repos/test/repo/pulls/85/comments --input -' "$GH_CALL_LOG" \
    && echo "PASS: review-thread publication uses the PR comments endpoint and request body" \
    || { echo "FAIL: review-thread publication did not use the PR comments endpoint" >&2; exit 1; }
  jq -s -e --arg task "issue:started-other-thread" --argjson reply "$target_reply" \
    'any(.[]; .in_reply_to_id == $reply and ((.body // "") | contains($task)))' "$GH_COMMENTS_JSONL" >/dev/null \
    || { echo "FAIL: posted review reply has the wrong in_reply_to_id" >&2; exit 1; }
  echo "PASS: newly posted review reply is attached to the requested thread"
}

test_task_started_review_thread_idempotency

insert_task() {
  local id="$1" issue="$2" status="$3" attempts="$4" processed="${5:-NULL}"
  local safe_id
  safe_id="$(printf '%s' "$id" | sed "s/'/''/g")"
  sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,processedAt,heartbeatAt,leaseExpiresAt,workerPid,claimToken,conversationId) VALUES ('$safe_id','test/repo',$issue,'https://github.com/test/repo/issues/$issue','$status',$attempts,$processed,datetime('now'),datetime('now','+10 seconds'),$$,'claim-$safe_id','');"
}

# A diagnostic early failure must publish task id, stage and useful context while
# redacting credential-like strings and well-known provider-token formats.
echo "CHECKPOINT: TASK_STARTED publication tests complete"
if ! insert_task "early-failure" 71 failed 3; then
  echo "FAIL: unable to insert early-failure fixture" >&2
  sqlite3 "$DB" ".schema processed_comments" >&2 || true
  exit 1
fi
echo "CHECKPOINT: early-failure fixture inserted"
sensitive_error='workspace lookup failed: password=hunter2 access_token=verysecretvalue Authorization: Bearer BearerSecretValue12345 ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456'
if ! MANUL_DIR="$MANUL_DIR" DB="$DB" bash -x "$SCRIPT_DIR/manul-result-feedback.sh" post-failed \
  --repo test/repo --issue 71 --comment-id early-failure --task-id early-failure \
  --stage workspace_path_validation --error "$sensitive_error" >/dev/null 2>"$TEST_DIR/early-failure-cli.trace"; then
  echo "FAIL: terminal failure feedback CLI failed" >&2
  echo "--- terminal feedback trace ---" >&2
  tail -n 160 "$TEST_DIR/early-failure-cli.trace" >&2 || true
  echo "--- GitHub mock calls ---" >&2
  cat "$GH_CALL_LOG" >&2
  echo "--- GitHub mock comments ---" >&2
  cat "$GH_COMMENTS_JSONL" >&2
  exit 1
fi
echo "CHECKPOINT: early-failure feedback published"
grep -Fq 'CALL:issue comment 71 --repo test/repo --body ' "$GH_CALL_LOG" \
  && echo "PASS: terminal TASK_FAILED comment uses the exported GitHub mock" \
  || { echo "FAIL: terminal TASK_FAILED comment bypassed the GitHub mock" >&2; exit 1; }
assert_eq 1 "$(count_for_task early-failure)" "early workspace failure comment published once"
body="$(jq -s -r '[.[] | select((.body // "") | contains("\"taskId\":\"early-failure\""))][0].body' "$GH_COMMENTS_JSONL")"
grep -q '\*\*Task:\*\* early-failure' <<< "$body" || { echo "FAIL: comment missing task id" >&2; exit 1; }
grep -q '\*\*Stage:\*\* workspace_path_validation' <<< "$body" || { echo "FAIL: comment missing failure stage" >&2; exit 1; }
grep -q '\[REDACTED\]' <<< "$body" || { echo "FAIL: comment does not show redaction" >&2; exit 1; }
if grep -Eq 'hunter2|verysecretvalue|BearerSecretValue12345|ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456' <<< "$body"; then
  echo "FAIL: a credential-like value leaked into the GitHub comment" >&2
  exit 1
fi
echo "PASS: failure comment redacts credential-like details"

# Two overlapping publishers for the same terminal task/attempt must serialize
# and produce one GitHub comment.
insert_task "overlap-failure" 72 failed 2
publish_overlap() {
  MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/manul-result-feedback.sh" post-failed \
    --repo test/repo --issue 72 --comment-id overlap-failure --task-id overlap-failure \
    --stage stale_task_recovery --error 'stale lease recovery exhausted retries' >/dev/null
}
publish_overlap & p1=$!
publish_overlap & p2=$!
wait "$p1"
wait "$p2"
assert_eq 1 "$(count_for_task overlap-failure)" "overlapping failure publishers are deduplicated"

# Exercise the real task-health-check entry point and verify a terminal task
# stays failed even when GitHub rejects the comment publication.
insert_task "health-stuck" 73 running 1 "datetime('now','-30 seconds')"
MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/task-health-check.sh" >"$TEST_DIR/health-ok.log" 2>&1
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='health-stuck';")" "health check persists terminal failure"
health_comment_count="$(count_for_task health-stuck)"
if [ "$health_comment_count" != "1" ]; then
  echo "FAIL: health-check terminal failure comment published (expected=1 actual=$health_comment_count)" >&2
  echo "--- health-check stdout/stderr ---" >&2
  cat "$TEST_DIR/health-ok.log" >&2
  echo "--- health-check runtime log ---" >&2
  cat "$MANUL_DIR/logs/task-health.log" >&2 || true
  echo "--- failure publisher runtime files ---" >&2
  find "$MANUL_DIR" -maxdepth 4 -type f -print >&2
  echo "--- GitHub mock calls ---" >&2
  cat "$GH_CALL_LOG" >&2
  echo "--- recorded GitHub comments ---" >&2
  cat "$GH_COMMENTS_JSONL" >&2
  exit 1
fi
echo "PASS: health-check terminal failure comment published"
health_body="$(jq -s -r '[.[] | select((.body // "") | contains("\"taskId\":\"health-stuck\""))][0].body' "$GH_COMMENTS_JSONL")"
grep -q '\*\*Stage:\*\* task_health_check' <<< "$health_body" || { echo "FAIL: health-check comment missing stage" >&2; exit 1; }

insert_task "health-api-failure" 74 running 1 "datetime('now','-30 seconds')"
export GH_FAIL_POST=1
MANUL_DIR="$MANUL_DIR" DB="$DB" bash "$SCRIPT_DIR/task-health-check.sh" >"$TEST_DIR/health-api-failure.log" 2>&1
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='health-api-failure';")" "GitHub publication error does not roll back task failure"
assert_eq 0 "$(count_for_task health-api-failure)" "failed GitHub publication is not recorded as posted"
grep -q 'terminal failure comment could not be posted for health-api-failure' "$MANUL_DIR/logs/task-health.log" || {
  echo "FAIL: publication failure was not logged separately" >&2
  cat "$TEST_DIR/health-api-failure.log" >&2
  exit 1
}
echo "PASS: GitHub publication failure is logged without hiding task failure"

echo "All terminal failure feedback tests passed."
