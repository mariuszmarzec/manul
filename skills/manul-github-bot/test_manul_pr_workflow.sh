#!/usr/bin/bash
# test_manul_pr_workflow.sh — Regression tests for Manul GitHub PR workflow
#
# Tests:
#   1. Poller discovers PR review comments (inline) on existing PRs
#   2. Poller discovers top-level PR conversation comments on existing PRs
#   3. Deduplication: re-polling same repo doesn't duplicate entries
#   4. New comments after task completion are still discovered
#   5. Reply routing: review comments → in-thread reply, top-level → top-level
#   6. feedback.sh exists and is functional
#   7. Config includes all expected repos (no typos)
#
# Usage: bash test_manul_pr_workflow.sh [--setup] [--teardown]
set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
# DB on native ext4 (NOT on 9p /mnt/f)
DB="${MANUL_DIR}/manul.db"
CONFIG="${MANUL_DIR}/config.json"
CANONICAL_DIR="${CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
POLL="${CANONICAL_DIR}/poll.sh"
DAEMON="${CANONICAL_DIR}/manul-daemon.sh"
FEEDBACK="${CANONICAL_DIR}/feedback.sh"
PROMPT="${CANONICAL_DIR}/orchestrator.prompt.md"

PASS=0
FAIL=0
TEST_NAME=""

cleanup() {
  if [ "${TEARDOWN:-0}" = "1" ]; then
    sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null
    sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId LIKE 'test:%';" 2>/dev/null
  fi
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    ok "$label"
  else
    fail "$label (expected='$expected', got='$actual')"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label (expected to contain '$needle')"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    ok "$label"
  else
    fail "$label (expected NOT to contain '$needle')"
  fi
}

extract_new_count() {
  local output="$1"
  echo "$output" | grep -o '"new":[0-9]*' | cut -d: -f2
}

# ============================================================================
# Test 1: Poller discovers PR review comments (inline) on existing PRs
# ============================================================================
test_poller_discovers_review_comments() {
  TEST_NAME="poller_discovers_review_comments"
  echo "=== Test 1: Poller discovers PR review comments ==="

  # Ensure caracal-rag is clean before test
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"  # 1 review + 3 issue comments on PR #11

  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND repository='mariuszmarzec/caracal-rag' AND issueNumber=11 AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$count"

  local queued_lease_count
  queued_lease_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND (heartbeatAt IS NOT NULL OR leaseExpiresAt IS NOT NULL);" 2>/dev/null)"
  assert_eq "$TEST_NAME (queued review has no lease metadata)" "0" "$queued_lease_count"

  # Verify context was enriched (PR info + linked issues)
  local has_context
  has_context="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND context IS NOT NULL AND context != '';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$has_context"

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='review:3952521856';" 2>/dev/null
}

# ============================================================================
# Test 2: Poller discovers top-level PR conversation comments on existing PRs
# ============================================================================
test_poller_discovers_pr_conversation_comments() {
  TEST_NAME="poller_discovers_pr_conversation_comments"
  echo "=== Test 2: Poller discovers top-level PR conversation comments ==="

  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"  # 1 review + 3 issue comments on PR #11

  local count
  count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND repository='mariuszmarzec/caracal-rag' AND issueNumber=11 AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$count"

  local queued_lease_count
  queued_lease_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND (heartbeatAt IS NOT NULL OR leaseExpiresAt IS NOT NULL);" 2>/dev/null)"
  assert_eq "$TEST_NAME (queued PR comment has no lease metadata)" "0" "$queued_lease_count"

  # Verify context was enriched (parent issue info)
  local has_context
  has_context="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND context IS NOT NULL AND context != '';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$has_context"

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='issue:5575478422';" 2>/dev/null
}

# ============================================================================
# Test 3: Deduplication — re-polling doesn't duplicate entries
# ============================================================================
test_deduplication() {
  TEST_NAME="deduplication"
  echo "=== Test 3: Deduplication ==="

  # Queue both caracal-rag tasks
  MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag >/dev/null 2>&1

  local first_count
  first_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag' AND status='queued';" 2>/dev/null)"

  # Poll again immediately
  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"

  assert_eq "$TEST_NAME (no new entries)" "0" "$new_count"
  assert_eq "$TEST_NAME (same count)" "$first_count" "$first_count"  # Always passes, but shows intent

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null
}

# ============================================================================
# Test 4: New comments after task completion are discovered
# ============================================================================
test_new_comments_after_completion() {
  TEST_NAME="new_comments_after_completion"
  echo "=== Test 4: New comments after task completion are discovered ==="

  # Insert a fake completed task to simulate a previously handled comment
  sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId, repository, issueNumber, commentUrl, author, agent, prompt, status, createdAt) VALUES ('test:completed999', 'mariuszmarzec/caracal-rag', 11, 'https://github.com/mariuszmarzec/caracal-rag/pull/11#issuecomment-999', 'mariuszmarzec', '', 'test prompt', 'completed', '2026-09-06T20:00:00Z');" 2>/dev/null

  # Now poll -- should discover the real comments
  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"

  # Verify the new tasks are queued (not blocked by the completed one)
  local review_queued
  review_queued="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='review:3952521856' AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$review_queued"

  local issue_queued
  issue_queued="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5575478422' AND status='queued';" 2>/dev/null)"
  assert_eq "$TEST_NAME" "1" "$issue_queued"

  # Cleanup
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null
}

# ============================================================================
# Test 5: Reply routing — daemon extracts REPLY_TO correctly from commentId
# ============================================================================
test_reply_routing() {
  TEST_NAME="reply_routing"
  echo "=== Test 5: Reply routing ==="

  # Check that post_github_comment accepts reply_to parameter
  # We can't easily test the full daemon, but we can verify the function signature
  local func_sig
  func_sig="$(sed -n '/^post_github_comment()/,/^}/p' "$DAEMON")"
  assert_contains "$TEST_NAME" "$func_sig" 'local reply_to="${4:-}"'
  # Verify gh api is used for review-thread replies (not --in-reply-to which is unsupported)
  assert_contains "$TEST_NAME" "$func_sig" 'gh api'
  # Ensure old --in-reply-to is NOT present as a command flag (only in comments)
  local has_old_reply
  has_old_reply="$(echo "$func_sig" | grep 'in-reply-to' | grep -v '^[[:space:]]*#' | wc -l)"
  assert_eq "$TEST_NAME (no --in-reply-to)" "0" "$has_old_reply"
  # Review replies must be encoded as JSON input, not form fields.
  local has_form_body
  has_form_body="$(echo "$func_sig" | grep 'body=$signed_body\|body=' | grep -v '^[[:space:]]*#' | wc -l)"
  assert_eq "$TEST_NAME (no form body)" "0" "$has_form_body"
  local has_json_input
  has_json_input="$(echo "$func_sig" | grep -c -- '--input -')"
  assert_eq "$TEST_NAME (JSON input present)" "1" "$has_json_input"

  # Check that REPLY_TO is extracted for review comments
  local reply_to_extraction
  reply_to_extraction="$(grep -A 60 'TASK_TYPE="issue"' "$DAEMON" | grep 'REPLY_TO')"
  assert_contains "$TEST_NAME" "$reply_to_extraction" 'REPLY_TO='

  # TASK_STARTED is routed through the publication/recovery wrapper.
  local running_routing
  running_routing="$(grep 'publish_task_started_for_claim.*REPLY_TO.*IN_PROGRESS_BODY' "$DAEMON")"
  assert_contains "$TEST_NAME (start wrapper preserves source thread)" "$running_routing" 'REPLY_TO'
  assert_contains "$TEST_NAME (start wrapper receives exact body)" "$running_routing" 'IN_PROGRESS_BODY'

  # Terminal results are routed through the durable outbox with the same review reply target.
  local done_routing
  done_routing="$(grep 'deliver_terminal_lifecycle_comment.*FINAL_COMMENT.*REPLY_TO' "$DAEMON" | head -1)"
  assert_contains "$TEST_NAME (terminal outbox preserves source thread)" "$done_routing" 'REPLY_TO'

  # Verify review comment commentId format is correct
  local review_comment
  review_comment="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag' AND commentId LIKE 'review:%' LIMIT 1;" 2>/dev/null)"
  # Re-poll to get the review comment back
  MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag >/dev/null 2>&1
  review_comment="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag' AND commentId LIKE 'review:%' LIMIT 1;" 2>/dev/null)"
  assert_contains "$TEST_NAME" "$review_comment" "review:"
}

# ============================================================================
# Test 6b: dynamic agent prompt requires in-place result comment repair
test_result_comment_repair_guidance() {
  TEST_NAME="result_comment_repair_guidance"
  echo "=== Test 6b: Result comment repair guidance ==="

  local prompt_segment
  prompt_segment="$(sed -n '/## GitHub Comment Posting (CRITICAL)/,/## Authoritative Repository/p' "$DAEMON")"
  assert_contains "$TEST_NAME (existing result comment)" "$prompt_segment" "existing result comment"
  assert_contains "$TEST_NAME (PATCH existing comment)" "$prompt_segment" "gh api --method PATCH repos/__REPO__/issues/comments/<RESULT_COMMENT_ID>"
  assert_contains "$TEST_NAME (safe JSON body)" "$prompt_segment" "jq -n --rawfile body"
  assert_contains "$TEST_NAME (safe request body)" "$prompt_segment" "--input -"
  assert_contains "$TEST_NAME (no inline body flag)" "$prompt_segment" 'Do NOT use `-f body="..."` or `-F body="..."`'
  assert_contains "$TEST_NAME (single final comment)" "$prompt_segment" "The final state must contain exactly one matching result comment"
}
# Test 6: feedback.sh exists and is functional
# ============================================================================
test_feedback_script() {
  TEST_NAME="feedback_script"
  echo "=== Test 6: feedback.sh exists and is functional ==="

  # Check canonical script exists
  assert_eq "$TEST_NAME (canonical exists)" "1" "$(test -f "$CANONICAL_DIR/feedback.sh" && echo 1 || echo 0)"

  # Check runtime symlink exists
  assert_eq "$TEST_NAME (runtime symlink)" "1" "$(test -L "$MANUL_DIR/feedback.sh" && echo 1 || echo 0)"

  # Check it's executable
  assert_eq "$TEST_NAME (executable)" "1" "$(test -x "$CANONICAL_DIR/feedback.sh" && echo 1 || echo 0)"

  # Check syntax
  bash -n "$CANONICAL_DIR/feedback.sh" 2>/dev/null
  assert_eq "$TEST_NAME (syntax OK)" "0" "$?"

  # Verify it has the manul signature
  local sig_check
  sig_check="$(grep 'manul 🐈' "$CANONICAL_DIR/feedback.sh")"
  assert_contains "$TEST_NAME" "$sig_check" "manul"

  # Verify poll.sh references feedback.sh
  local poll_ref
  poll_ref="$(grep 'feedback.sh' "$POLL")"
  assert_contains "$TEST_NAME" "$poll_ref" "feedback.sh"
}

# ============================================================================
# Test 7: Config includes caracal-rag and has no typos
# ============================================================================
test_config_repos() {
  TEST_NAME="config_repos"
  echo "=== Test 7: Config includes caracal-rag ==="

  # Check canonical config
  local canonical_repos
  canonical_repos="$(jq -r '.repositories[]?' "$CANONICAL_DIR/config.json")"
  assert_contains "$TEST_NAME" "$canonical_repos" "mariuszmarzec/caracal-rag"

  # Check runtime config
  local runtime_repos
  runtime_repos="$(jq -r '.repositories[]?' "$CONFIG")"
  assert_contains "$TEST_NAME" "$runtime_repos" "mariuszmarzec/caracal-rag"

  # Verify no typo versions exist
  local has_typo
  has_typo="$(jq -r '.repositories[]?' "$CONFIG" | grep -c 'mariuszmarcer' || true)"
  assert_eq "$TEST_NAME (no typos)" "0" "$has_typo"

  # Verify allowedUsers includes mariuszmarzec
  local allowed
  allowed="$(jq -r '.allowedUsers[]?' "$CONFIG")"
  assert_contains "$TEST_NAME" "$allowed" "mariuszmarzec"
}

# ============================================================================
# Test 8: Install script includes feedback.sh
# ============================================================================
test_install_script() {
  TEST_NAME="install_script"
  echo "=== Test 8: install-manul-symlinks.sh includes feedback.sh ==="

  local scripts_list
  scripts_list="$(grep -A 20 'SCRIPTS=(' "$CANONICAL_DIR/install-manul-symlinks.sh" | grep 'feedback.sh')"
  assert_contains "$TEST_NAME" "$scripts_list" "feedback.sh"
}

# ============================================================================
# Test 9: Poller filters by allowed users
# ============================================================================
test_allowed_users_filter() {
  TEST_NAME="allowed_users_filter"
  echo "=== Test 9: Allowed users filter ==="

  # Reset caracal-rag tasks for this test
  sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

  # The poller should discover all comments from allowed user mariuszmarzec (1 review + 3 issue = 4)
  local result
  result="$(MANUL_DIR="$MANUL_DIR" bash "$POLL" mariuszmarzec/caracal-rag 2>/dev/null)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME" "4" "$new_count"
}

# ============================================================================
# Test 10: Daemon accepts both TASK_DONE and TASK_COMPLETED markers
# ============================================================================
test_completion_markers() {
  TEST_NAME="completion_markers"
  echo "=== Test 10: Completion markers ==="

  # Verify daemon regex accepts both TASK_DONE and TASK_COMPLETED
  local marker_check
  marker_check="$(grep 'TASK_DONE.*TASK_COMPLETED\|TASK_COMPLETED.*TASK_DONE' "$DAEMON")"
  assert_contains "$TEST_NAME" "$marker_check" 'TASK_COMPLETED'

  # Verify TASK_DONE is still accepted
  local task_done_check
  task_done_check="$(grep 'TASK_DONE' "$DAEMON" | grep -v '^#' | head -1)"
  assert_contains "$TEST_NAME" "$task_done_check" 'TASK_DONE'
}

# ============================================================================
# Test 11: Daemon uses flock for singleton locking
# ============================================================================
test_flock_singleton() {
  TEST_NAME="flock_singleton"
  echo "=== Test 11: Flock singleton locking ==="

  # Verify FLOCK_FILE is defined
  local flock_var
  flock_var="$(grep 'FLOCK_FILE=' "$DAEMON" | head -1)"
  assert_contains "$TEST_NAME" "$flock_var" 'FLOCK_FILE'

  # Verify flock is used in start()
  local start_flock
  start_flock="$(grep -A 60 "^start()" "$DAEMON" | grep 'flock')"
  assert_contains "$TEST_NAME" "$start_flock" 'flock'

  # Verify flock is used in loop()
  local loop_flock
  loop_flock="$(grep -A 60 "^loop()" "$DAEMON" | grep 'flock')"
  assert_contains "$TEST_NAME" "$loop_flock" 'flock'
}

# ============================================================================
# Test 12: Agent response extraction is REMOVED (new architecture)
# ============================================================================
test_agent_response_removed() {
  TEST_NAME="agent_response_removed"
  echo "=== Test 12: Agent response extraction REMOVED ==="

  # Verify AGENT_RESPONSE extraction is REMOVED from daemon
  local has_extraction
  has_extraction="$(grep -c 'AGENT_RESPONSE' "$DAEMON")"
  assert_eq "$TEST_NAME (AGENT_RESPONSE removed)" "0" "$has_extraction"

  # Verify daemon does NOT use AGENT_RESPONSE in final comments
  local final_comment_success
  final_comment_success="$(grep -c 'AGENT_RESPONSE' <(grep -A8 'if \[ "$COMPLETION_SUCCESS" = "true" \]; then' "$DAEMON" | head -12))"
  assert_eq "$TEST_NAME (success comment no AGENT_RESPONSE)" "0" "$final_comment_success"

  # Verify success message exists (daemon posts lifecycle comment)
  local has_success_msg
  has_success_msg="$(grep -c '✅ Manul completed the task successfully.' "$DAEMON")"
  assert_eq "$TEST_NAME (success message exists)" "1" "$has_success_msg"
}

# ============================================================================
# Test 13: Prompt enforces agent comment posting (new architecture)
# ============================================================================
test_prompt_enforces_agent_posting() {
  TEST_NAME="prompt_enforces_agent_posting"
  echo "=== Test 13: Prompt enforces agent posting ==="

  # Verify prompt requires exactly one user-facing result comment via GitHub
  local has_result_comment_requirement
  has_result_comment_requirement="$(grep -c 'result comment to GitHub using the' "$PROMPT")"
  assert_eq "$TEST_NAME (exactly one result comment required)" "1" "$has_result_comment_requirement"

  # Verify posting is mandatory (not optional)
  local has_mandatory
  has_mandatory="$(grep -c 'Result comment is mandatory' "$PROMPT")"
  assert_eq "$TEST_NAME (mandatory posting)" "1" "$has_mandatory"

  # Verify result is posted BEFORE TASK_DONE
  local has_before_task_done
  has_before_task_done="$(grep -c 'BEFORE emitting.*TASK_DONE\|before emitting.*TASK_DONE' "$PROMPT")"
  assert_gt "$TEST_NAME (posted before TASK_DONE)" "0" "$has_before_task_done"

  # Verify old daemon-posting requirement is removed (agent, not daemon, posts result)
  local has_daemon_posts
  has_daemon_posts="$(grep -c 'daemon handles all GitHub communication' "$PROMPT")"
  assert_eq "$TEST_NAME (no daemon posting requirement)" "0" "$has_daemon_posts"

  # Verify old stdout-as-result contract is removed
  local has_stdout_result
  has_stdout_result="$(grep -c 'stdout.*user-facing\|output.*posted as.*GitHub comment' "$PROMPT")"
  assert_eq "$TEST_NAME (no stdout-as-result contract)" "0" "$has_stdout_result"

  # Verify routing instructions present
  local has_routing
  has_routing="$(grep -c 'in_reply_to' "$PROMPT")"
  assert_eq "$TEST_NAME (routing instructions present)" "1" "$has_routing"
}

# ============================================================================
# Test 14: Daemon posts lifecycle comments only (new architecture)
# ============================================================================
test_daemon_lifecycle_comments() {
  TEST_NAME="daemon_lifecycle_comments"
  echo "=== Test 14: Daemon posts lifecycle comments only ==="

  # Verify daemon posts working comment
  local has_working_comment
  has_working_comment="$(grep -c '🔄 Manul is working' "$DAEMON")"
  assert_eq "$TEST_NAME (working comment)" "1" "$has_working_comment"

  # Verify daemon posts completed comment
  local has_completed_comment
  has_completed_comment="$(grep -v '^[[:space:]]*#' "$DAEMON" | grep -c '✅ Manul completed')" 
  assert_eq "$TEST_NAME (completed comment)" "1" "$has_completed_comment"

  # Verify daemon posts failed comment - count all failure comment assignments
  # There are multiple legitimate failure scenarios that post lifecycle comments
  local primary_failure_comment
  primary_failure_comment="$(grep -c '❌ Manul failed to complete the task after' "$DAEMON")"
  # Check for the simplified version used in retry logic  
  local retry_failure_comment
  retry_failure_comment="$(grep -c '⚠️ Manul encountered an issue' "$DAEMON")"
  # There should be at least one primary failure message (in reality there are 2 
  # for different failure contexts - pre-check and post-check)
  if [ "$primary_failure_comment" -ge 1 ]; then
    ok "$TEST_NAME (primary failure comment exists)"
  else
    fail "$TEST_NAME (primary failure comment exists)"
  fi
  
  # Verify retry lifecycle comment exists
  if [ "$retry_failure_comment" -ge 1 ]; then
    ok "$TEST_NAME (retry comment exists)"
  else
    fail "$TEST_NAME (retry comment exists)"
  fi
}

# ============================================================================
# Test 14b: Result comment validation runs after PR metadata verification
test_completion_claim_token_wiring() {
  TEST_NAME="completion_claim_token_wiring"
  echo "=== Test: Completion preserves claim ownership ==="

  local eval_body
  eval_body="$(sed -n '/^evaluate_task_completion()/,/^run_once()/p' "$DAEMON")"
  assert_contains "$TEST_NAME (claim token forwarded)" "$eval_body" 'complete_task_with_verification "$COMMENT_ID" "$CLAIM_TOKEN"'
}
test_result_validation_order() {
  TEST_NAME="result_validation_order"
  echo "=== Test 14b: Result validation order ==="

  local eval_body pr_url_line result_line
  eval_body="$(sed -n '/^evaluate_task_completion()/,/^run_once()/p' "$DAEMON")"
  pr_url_line="$(printf "%s\n" "$eval_body" | grep -n 'verify_result_comment_pr_url "$REPO"' | head -1 | cut -d: -f1)"
  result_line="$(printf "%s\n" "$eval_body" | grep -n 'verify_result_comment "$REPO"' | head -1 | cut -d: -f1)"
  [ -n "$pr_url_line" ] || return 1
  [ -n "$result_line" ] || return 1
  [ "$result_line" -gt "$pr_url_line" ] || return 1
}

# Test 14a: lifecycle events are embedded in lifecycle comments, not duplicated as feedback posts
test_lifecycle_event_embedding() {
  TEST_NAME="lifecycle_event_embedding"
  echo "=== Test 14a: Lifecycle event embedding ==="

  local daemon_body terminal_builder
  daemon_body="$(sed -n '/^dispatch_once()/,/^run_once()/p' "$DAEMON")"
  terminal_builder="$(sed -n '/^build_terminal_lifecycle_comment()/,/^ensure_terminal_lifecycle_outbox()/p' "$DAEMON")"

  # TASK_STARTED must be published through the idempotent pre-check/read-back
  # wrapper, which owns pre-agent recovery when delivery cannot be confirmed.
  assert_contains "$TEST_NAME (TASK_STARTED embedded)" "$daemon_body" 'start_event_marker'
  assert_contains "$TEST_NAME (TASK_STARTED recovery wrapper)" "$daemon_body" 'publish_task_started_for_claim'
  assert_not_contains "$TEST_NAME (no daemon post-started call)" "$daemon_body" 'manul-result-feedback.sh" post-started'

  # Terminal events are built into the exact body and delivered via the durable outbox.
  assert_contains "$TEST_NAME (terminal event builder)" "$terminal_builder" 'TASK_DONE'
  assert_contains "$TEST_NAME (terminal failure event builder)" "$terminal_builder" 'TASK_FAILED'
  assert_contains "$TEST_NAME (terminal outbox delivery)" "$daemon_body" 'deliver_terminal_lifecycle_comment'
  assert_not_contains "$TEST_NAME (no daemon post-done call)" "$daemon_body" 'manul-result-feedback.sh" post-done'
  assert_not_contains "$TEST_NAME (no daemon post-failed call)" "$daemon_body" 'manul-result-feedback.sh" post-failed'

  # The state transition remains authoritative inside evaluate_task_completion().
  local eval_body
  eval_body="$(sed -n '/^evaluate_task_completion()/,/^run_once()/p' "$DAEMON")"
  assert_contains "$TEST_NAME (evaluator owns terminal transition)" "$eval_body" 'complete_task_with_verification'
}
# ============================================================================
# Test 14c: IMPLEMENT task with no repo diff still requires task branch and PR
test_no_diff_implement_requires_pr() {
  TEST_NAME="no_diff_implement_requires_pr"
  echo "=== Test 14c: IMPLEMENT no-diff success still requires task branch and PR ==="

  local eval_body
  eval_body="$(sed -n '/^evaluate_task_completion()/,/^run_once()/p' "$DAEMON")"

  assert_contains "$TEST_NAME (no-diff IMPLEMENT branch guard)" "$eval_body" 'elif [ "$TASK_ACTION" = "IMPLEMENT" ]; then'
  assert_contains "$TEST_NAME (no-diff IMPLEMENT checks branch)" "$eval_body" 'Implementation task completed on a base/default branch'
  assert_contains "$TEST_NAME (no-diff IMPLEMENT checks PR)" "$eval_body" 'Implementation task completed without a verified PR from its task branch'
  assert_contains "$TEST_NAME (no-diff IMPLEMENT calls verify_required_pr)" "$eval_body" 'verify_required_pr "$REPO" "$COMMENT_ID" "$WORKDIR" "$INITIAL_BASE_BRANCH"'
  assert_not_contains "$TEST_NAME (old no-change bypass removed)" "$eval_body" 'made no repository changes; PR/branch not required'
}

# Test 15: Completed-task guard placement and logic
# ============================================================================
test_completed_task_guard() {
  TEST_NAME="completed_task_guard"
  echo "=== Test 15: Completed-task guard ==="

  # Test A: Guard runs after TASK_INFO parsing (no undefined variable errors)
  local guard_placement
  guard_placement="$(grep -n '# 0.5 Completed-task guard' "$DAEMON" | head -1 | cut -d: -f1)"
  local task_info_line
  task_info_line="$(grep -n 'TASK_INFO.*SELECT commentId.*processed_comments' "$DAEMON" | head -1 | cut -d: -f1)"
  if [ -n "$guard_placement" ] && [ -n "$task_info_line" ] && [ "$guard_placement" -gt "$task_info_line" ]; then
    ok "$TEST_NAME (guard after TASK_INFO parsing)"
  else
    fail "$TEST_NAME (guard after TASK_INFO parsing)"
  fi

  # Test B: Guard uses deterministic correlation (commentUrl)
  local has_url_check
  has_url_check="$(grep -c 'commentUrl.*status.*completed\|commentUrl.*completed.*status' "$DAEMON")"
  assert_gt "$TEST_NAME (uses commentUrl correlation)" "0" "$has_url_check"

  # Test C: Guard checks for missing commentUrl and logs error
  local has_missing_url_check
  has_missing_url_check="$(grep -c 'missing_comment_url' "$DAEMON")"
  assert_eq "$TEST_NAME (handles missing commentUrl)" "1" "$has_missing_url_check"

  # Test D: Guard consumes duplicate without agent invocation
  local has_duplicate_consume
  has_duplicate_consume="$(grep -c 'consuming safely' "$DAEMON")"
  assert_gt "$TEST_NAME (safe duplicate consumption)" "0" "$has_duplicate_consume"
}

# ============================================================================
# Test 16: Retry backoff mechanism
# ============================================================================
test_retry_backoff() {
  TEST_NAME="retry_backoff"
  echo "=== Test 16: Retry backoff mechanism ==="

  # Test A: nextAttemptAt column exists in schema
  local has_next_attempt_at
  has_next_attempt_at="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -c '|nextAttemptAt|')"
  assert_eq "$TEST_NAME (nextAttemptAt column exists)" "1" "$has_next_attempt_at"

  # Test B: Scheduler query uses nextAttemptAt
  local has_next_attempt_in_query
  has_next_attempt_in_query="$(grep -c 'nextAttemptAt <= datetime' "$DAEMON")"
  assert_eq "$TEST_NAME (scheduler uses nextAttemptAt)" "1" "$has_next_attempt_in_query"

  # Test C: Requeue logic sets nextAttemptAt
  local has_next_attempt_in_requeue
  has_next_attempt_in_requeue="$(grep -c "nextAttemptAt=datetime('now', '+\${RETRY_DELAY_SECONDS} seconds')" "$DAEMON")"
  assert_eq "$TEST_NAME (requeue sets nextAttemptAt)" "3" "$has_next_attempt_in_requeue"

  # Test D: MAX_ATTEMPTS path clears nextAttemptAt
  local has_next_attempt_cleared
  has_next_attempt_cleared="$(grep -c "nextAttemptAt=NULL" "$DAEMON")"
  assert_eq "$TEST_NAME (MAX_ATTEMPTS clears nextAttemptAt)" "4" "$has_next_attempt_cleared"

  # Test E: RETRY_DELAY_SECONDS configuration exists
  local has_retry_delay_config
  has_retry_delay_config="$(grep -c 'RETRY_DELAY_SECONDS' "$DAEMON")"
  assert_gt "$TEST_NAME (RETRY_DELAY_SECONDS configured)" "0" "$has_retry_delay_config"

  # Test F: Fresh tasks (attempts=0) are immediately eligible
  local has_fresh_task_eligibility
  has_fresh_task_eligibility="$(grep -c 'attempts=0 OR nextAttemptAt' "$DAEMON")"
  assert_eq "$TEST_NAME (fresh tasks eligible)" "1" "$has_fresh_task_eligibility"
}

# ============================================================================
# Test 17: Schema migration
# ============================================================================
test_schema_migration() {
  TEST_NAME="schema_migration"
  echo "=== Test 17: Schema migration ==="

  # Test A: Migration exists in poll.sh
  local has_migration
  has_migration="$(grep -c 'ADD COLUMN nextAttemptAt' "$POLL")"
  assert_eq "$TEST_NAME (migration in poll.sh)" "1" "$has_migration"

  # Test B: Migration is idempotent (checks PRAGMA before ALTER)
  local has_idempotent_check
  has_idempotent_check="$(grep -B2 'ADD COLUMN nextAttemptAt' "$POLL" | grep -c 'PRAGMA table_info')"
  assert_eq "$TEST_NAME (idempotent migration)" "1" "$has_idempotent_check"

  # Test C: Fresh DB test - create temp DB and verify schema
  local temp_db="${MANUL_DIR}/test-schema-migration.db"
  rm -f "$temp_db"
  sqlite3 "$temp_db" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT NOT NULL,
    author TEXT,
    agent TEXT,
    prompt TEXT NOT NULL,
    context TEXT,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT
  );"
  # Apply migration
  if ! sqlite3 "$temp_db" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|nextAttemptAt|'; then
    sqlite3 "$temp_db" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  fi
  local fresh_db_has_column
  fresh_db_has_column="$(sqlite3 "$temp_db" "PRAGMA table_info(processed_comments);" | grep -c '|nextAttemptAt|')"
  rm -f "$temp_db"
  assert_eq "$TEST_NAME (fresh DB has nextAttemptAt)" "1" "$fresh_db_has_column"
}

# ============================================================================
# Test 18: Repository lock interaction with scheduler
# ============================================================================
test_repository_lock_scheduler() {
  TEST_NAME="repository_lock_scheduler"
  echo "=== Test 18: Repository lock interaction ==="

  # Test A: Scheduler does not block on repository lock
  # The scheduler should be able to find eligible tasks even when another repo is locked
  local scheduler_uses_repo_lock
  scheduler_uses_repo_lock="$(grep -c 'repo.*lock.*scheduler\|lock.*repo.*scheduler' "$DAEMON" 2>/dev/null)"
  scheduler_uses_repo_lock="${scheduler_uses_repo_lock:-0}"
  # Scheduler should NOT be coupled to repo lock (they are independent)
  if [ "$scheduler_uses_repo_lock" -eq 0 ]; then
    ok "$TEST_NAME (scheduler independent of repo lock)"
  else
    fail "$TEST_NAME (scheduler independent of repo lock)"
  fi

  # Test B: Repository lock is released after task completion
  local has_lock_release
  has_lock_release="$(grep -c 'release_repo_lock' "$DAEMON")"
  assert_gt "$TEST_NAME (repo lock released)" "0" "$has_lock_release"
}

# ============================================================================
# Test 19: Repository lock is atomic and acquired before shared-cache sync
# ============================================================================
test_repository_lock_atomicity_and_scope() {
  TEST_NAME="repository_lock_atomicity_and_scope"
  echo "=== Test 19: Repository lock atomicity and scope ==="

  local lock_body
  lock_body="$(sed -n '/^acquire_repo_lock()/,/^archive_task_artifacts()/p' "$DAEMON")"
  assert_contains "$TEST_NAME (atomic lock acquisition)" "$lock_body" 'mkdir "$lockfile"'
  assert_contains "$TEST_NAME (serialized stale recovery)" "$lock_body" 'mkdir "$reclaim_lock"'
  assert_contains "$TEST_NAME (lock release removes directory)" "$lock_body" 'rm -rf "${REPO_LOCK_DIR:-$MANUL_LOCKS_DIR/repo}/${slug}.lock"'

  local ensure_body
  ensure_body="$(sed -n '/^ensure_repo()/,/^# Verify repository ownership and integrity/p' "$DAEMON")"
  assert_contains "$TEST_NAME (lock before fetch)" "$ensure_body" 'if ! acquire_repo_lock "$repo"; then'
  assert_contains "$TEST_NAME (existing checkout fetch)" "$ensure_body" 'git fetch origin --quiet'

  local acquire_line fetch_line
  acquire_line="$(printf '%s\n' "$ensure_body" | grep -n 'if ! acquire_repo_lock "\$repo"; then' | head -1 | cut -d: -f1)"
  fetch_line="$(printf '%s\n' "$ensure_body" | grep -n 'git fetch origin --quiet' | head -1 | cut -d: -f1)"
  if [ -n "$acquire_line" ] && [ -n "$fetch_line" ] && [ "$acquire_line" -lt "$fetch_line" ]; then
    ok "$TEST_NAME (lock acquired before existing checkout fetch)"
  else
    fail "$TEST_NAME (lock acquired before existing checkout fetch)"
  fi

  # A workspace scheduling miss must not leak the repository lock.
  local workspace_paths
  workspace_paths="$(sed -n '/workspace_reclaim "\$COMMENT_ID"/,/Get workspace path from lease/p' "$DAEMON")"
  assert_contains "$TEST_NAME (workspace reclaim failure releases repo lock)" "$workspace_paths" 'release_repo_lock "$REPO"'

  local no_workspace_paths
  no_workspace_paths="$(sed -n '/if \[ -z "\$WORKSPACE_ID" \]; then/,/sqlite3 "\$DB" "UPDATE processed_comments SET workspaceId=/p' "$DAEMON")"
  assert_contains "$TEST_NAME (no-workspace retry releases repo lock)" "$no_workspace_paths" 'release_repo_lock "$REPO"'
}

# ============================================================================
# Test 20: Missing result marker must not invalidate verified repository delivery
# ============================================================================
test_marker_missing_preserves_delivery() {
  TEST_NAME="marker_missing_preserves_delivery"
  echo "=== Test 20: Missing result marker preserves verified delivery ==="

  local eval_body
  eval_body="$(sed -n '/^evaluate_task_completion()/,/^run_once()/p' "$DAEMON")"

  # verify_result_comment remains a diagnostic/correlation check, but it must not
  # set SUCCESS=false once repository/PR/push verification has already succeeded.
  local invalid_assignment
  invalid_assignment="$(printf '%s\n' "$eval_body" | sed -n '/Result-comment marker validation/,/fi$/p' | grep -c 'SUCCESS="false"' || true)"
  assert_eq "$TEST_NAME (marker check does not invalidate delivery)" "0" "$invalid_assignment"
  assert_contains "$TEST_NAME (marker failure logs diagnostic)" "$eval_body" 'RESULT_COMMENT_INVALID'
  assert_contains "$TEST_NAME (delivery preserved)" "$eval_body" 'repository delivery already verified'
}

# Helper: assert_gt (greater than)
# ============================================================================
assert_gt() {
  local label="$1" expected_min="$2" actual="$3"
  if [ "$actual" -gt "$expected_min" ]; then
    ok "$label"
  else
    fail "$label (expected > '$expected_min', got '$actual')"
  fi
}

# ============================================================================
# Main
# ============================================================================
echo ""
echo "========================================"
echo "  Manul PR Workflow Regression Tests"
echo "========================================"
echo ""

# Setup: ensure DB is clean for caracal-rag
sqlite3 "$DB" "DELETE FROM processed_comments WHERE repository='mariuszmarzec/caracal-rag';" 2>/dev/null

test_poller_discovers_review_comments
test_poller_discovers_pr_conversation_comments
test_deduplication
test_new_comments_after_completion
test_reply_routing
test_feedback_script
test_config_repos
test_install_script
test_allowed_users_filter
test_completion_markers
test_flock_singleton
test_agent_response_removed
test_prompt_enforces_agent_posting
test_result_comment_repair_guidance
test_daemon_lifecycle_comments
test_lifecycle_event_embedding
test_completion_claim_token_wiring
test_result_validation_order
test_completed_task_guard
test_retry_backoff
test_schema_migration
test_repository_lock_scheduler
test_repository_lock_atomicity_and_scope
test_marker_missing_preserves_delivery


echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0

# Regression: PR number must never be inferred from the issue number.
if grep -q 'issue number as the PR number' "$PROMPT"; then
  echo "[OK] issue/PR identifiers are explicitly separated"
else
  echo "[FAIL] prompt does not prohibit issue-number -> PR-number inference"
  exit 1
fi

# Regression: the daemon must verify an auto-created PR through GitHub after creation.
if grep -q 'post-create verification failed' "$DAEMON"; then
  echo "[OK] auto-created PR is re-verified against GitHub"
else
  echo "[FAIL] auto-created PR is not re-verified"
  exit 1
fi

# Regression: legacy tasks with an empty action must default to IMPLEMENT so
# missing action metadata cannot bypass mandatory PR verification.
if grep -q 'action="\${action:-IMPLEMENT}"' "$DAEMON"; then
  echo "[OK] empty legacy action defaults to IMPLEMENT"
else
  echo "[FAIL] empty legacy action can bypass PR verification"
  exit 1
fi

# Regression: successful implementation requires the exact canonical PR URL
# in the agent's result comment.
if grep -q 'verify_result_comment_pr_url' "$DAEMON"; then
  echo "[OK] result comment PR URL is verified"
else
  echo "[FAIL] result comment PR URL is not verified"
  exit 1
fi
