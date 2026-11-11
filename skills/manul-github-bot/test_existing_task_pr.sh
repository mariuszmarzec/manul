#!/usr/bin/env bash
# Regression tests for already-satisfied IMPLEMENT retries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MANUL_DIR="$TMP/manul"
mkdir -p "$MANUL_DIR"
cat >"$MANUL_DIR/config.json" <<'JSON'
{"automation":{"heartbeatInterval":60,"heartbeatTimeout":900,"leaseTimeout":900,"maxAttemptsBeforeFail":3,"lockTtl":1800}}
JSON
# Isolate the production verifier without starting the daemon CLI loop.
# Extract the actual function body from manul-daemon.sh so the regression test
# exercises production logic while keeping runtime bootstrap outside the fixture.
DB="$TMP/processed-comments.sqlite"
LOG="$TMP/daemon.log"
LIFECYCLE_LOG="$TMP/lifecycle.log"
CONFIG="$SCRIPT_DIR/config.json"
GH_API_TIMEOUT=5
export DB LOG LIFECYCLE_LOG CONFIG GH_API_TIMEOUT
mkdir -p "$(dirname "$DB")"
: >"$LOG"
: >"$LIFECYCLE_LOG"

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}
log() { echo "$*" >>"$LOG"; }
lc_log() { echo "$*" >>"$LIFECYCLE_LOG"; }

verifier_source="$(sed -n '/^verify_existing_task_pr() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
merged_verifier_source="$(sed -n '/^verify_merged_result_pr() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
pr_check_source="$(sed -n '/^pr_check_existing() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
pr_auto_source="$(sed -n '/^pr_auto_create() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
required_pr_source="$(sed -n '/^verify_required_pr() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
base_infer_source="$(sed -n '/^infer_task_base_branch() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
result_comment_source="$(sed -n '/^verify_result_comment() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
nonempty_result_comment_source="$(sed -n '/^verify_nonempty_result_comment() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
repo_changed_source="$(sed -n '/^repository_changed_since() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
comment_only_delivery_source="$(sed -n '/^verify_implement_comment_only_delivery() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
pr_url_required_source="$(sed -n '/^verify_result_comment_pr_url_if_required() {$/,/^}$/p' "$SCRIPT_DIR/manul-daemon.sh")"
task_source_type_source="$(sed -n '/^task_source_is_todo_type() {$/,/^}$/p' "$SCRIPT_DIR/task-source.sh")"
if [ -z "$verifier_source" ] || [ -z "$merged_verifier_source" ] || [ -z "$pr_check_source" ] || [ -z "$pr_auto_source" ] || [ -z "$required_pr_source" ] || [ -z "$base_infer_source" ] || [ -z "$result_comment_source" ] || [ -z "$nonempty_result_comment_source" ] || [ -z "$repo_changed_source" ] || [ -z "$comment_only_delivery_source" ] || [ -z "$pr_url_required_source" ] || [ -z "$task_source_type_source" ]; then
  echo "FAIL: required production verifier functions were not found" >&2
  exit 1
fi
eval "$verifier_source"
eval "$merged_verifier_source"
eval "$pr_check_source"
eval "$pr_auto_source"
eval "$base_infer_source"
eval "$required_pr_source"
eval "$result_comment_source"
eval "$nonempty_result_comment_source"
eval "$repo_changed_source"
eval "$comment_only_delivery_source"
eval "$pr_url_required_source"
eval "$task_source_type_source"
# The repair path is covered elsewhere; this test asserts fail-closed behavior
# when neither the exact current-attempt marker nor a repair candidate exists.
repair_result_comment_marker() { return 1; }

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  status TEXT NOT NULL,
  action TEXT,
  prUrl TEXT
);
SQL

# Build a clean base checkout and a feature branch that is pushed to origin.
WORKDIR="$TMP/workdir"
ORIGIN="$TMP/origin.git"
mkdir -p "$WORKDIR"
# Git 2.25 does not support git init --initial-branch (added in 2.28).
git init --quiet "$WORKDIR"
git -C "$WORKDIR" symbolic-ref HEAD refs/heads/main
git -C "$WORKDIR" config user.name test
git -C "$WORKDIR" config user.email test@example.com
printf 'base\n' >"$WORKDIR/README.md"
git -C "$WORKDIR" add README.md
git -C "$WORKDIR" commit -qm "initial base"
INITIAL_BASE_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"
git init --quiet --bare "$ORIGIN"
git -C "$WORKDIR" remote add origin "$ORIGIN"
git -C "$WORKDIR" push -q --set-upstream origin main
git -C "$WORKDIR" checkout -qb feature/17-helloworld-java
printf 'class HelloWorld {}\n' >"$WORKDIR/helloworld.java"
git -C "$WORKDIR" add helloworld.java
git -C "$WORKDIR" commit -qm "Add HelloWorld"
PR_HEAD_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"
git -C "$WORKDIR" push -q --set-upstream origin feature/17-helloworld-java
git -C "$WORKDIR" checkout -q main

# Fake GitHub's PR-list response while using real Git and SQLite checks.
# Set all helper globals normally supplied by the daemon's dispatch path.
DEFAULT_BRANCH="main"
MANUL_TESTING=true

export FAKE_GH_PR_LIST="$TMP/pr-list.json"
export FAKE_RESULT_COMMENTS_JSON="$TMP/result-comments.json"
export FAKE_PR_VIEW_JSON="$TMP/pr-view.json"
export PR_CREATE_COUNT_FILE="$TMP/pr-create-count"
export FAKE_ISSUE_STATE="closed"
cat >"$TMP/bin-gh" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  cat "$FAKE_GH_PR_LIST"
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "create" ]]; then
  count="$(cat "$PR_CREATE_COUNT_FILE" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" >"$PR_CREATE_COUNT_FILE"
  base=""
  head=""
  while (($#)); do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  jq -cn --arg base "$base" --arg head "$head" \
    '[{number:19,url:"https://github.com/test/repo/pull/19",state:"OPEN",baseRefName:$base,headRefName:$head,body:"Automatically created by Manul for task issue:6127115709."}]' \
    >"$FAKE_GH_PR_LIST"
  # Simulate GitHub accepting the PR but the client losing the response.
  exit 1
fi
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  cat "$FAKE_PR_VIEW_JSON"
  exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/test/repo/issues/17/comments" ]]; then
  shift 2
  jq_filter=""
  while (($#)); do
    case "$1" in
      --jq) jq_filter="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$jq_filter" ]; then
    jq -r "$jq_filter" "$FAKE_RESULT_COMMENTS_JSON"
  else
    cat "$FAKE_RESULT_COMMENTS_JSON"
  fi
  exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/test/repo/issues/17" ]]; then
  printf '%s\n' "$FAKE_ISSUE_STATE"
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
MOCK
chmod +x "$TMP/bin-gh"
mkdir -p "$TMP/bin"
mv "$TMP/bin-gh" "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

PR_URL="https://github.com/test/repo/pull/18"
PREVIOUS_TASK="issuebody:5816053678"
CURRENT_TASK="issue:6127115709"
write_pr_fixture() {
  local base="${1:-main}" head_sha="${2:-$PR_HEAD_SHA}" body_task="${3:-$PREVIOUS_TASK}"
  jq -cn --arg url "$PR_URL" --arg base "$base" \
    --arg head "feature/17-helloworld-java" --arg sha "$head_sha" \
    --arg body "Automatically created by Manul for task $body_task." \
    '[{number:18,url:$url,state:"OPEN",baseRefName:$base,headRefName:$head,headRefOid:$sha,body:$body}]' \
    >"$FAKE_GH_PR_LIST"
}

# Historical issuebody rows can contain the GitHub object ID in issueNumber;
# the human issue number must be derived from commentUrl.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,action,prUrl) VALUES ('$PREVIOUS_TASK','test/repo',5816053678,'https://github.com/test/repo/issues/17','completed','IMPLEMENT','$PR_URL');"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,action,prUrl) VALUES ('$CURRENT_TASK','test/repo',17,'https://github.com/test/repo/issues/17#issuecomment-6127115709','running','IMPLEMENT',NULL);"

# Case 1: the workspace is back on main, but the same issue has a previous
# completed task with a verified PR URL and the PR head still matches origin.
write_pr_fixture
VERIFIED_EXISTING_PR_BRANCH=""
VERIFIED_EXISTING_PR_URL=""
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  [ "$VERIFIED_EXISTING_PR_BRANCH" = "feature/17-helloworld-java" ]
  [ "$VERIFIED_EXISTING_PR_URL" = "$PR_URL" ]
  echo "PASS: accepts existing PR verified for a completed task on the same issue"
else
  echo "FAIL: expected the previously verified same-issue PR to qualify" >&2
  exit 1
fi

# Case 2: don't accept a PR if its head SHA no longer matches the remote branch.
write_pr_fixture "main" "0000000000000000000000000000000000000000"
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "FAIL: accepted PR whose head SHA does not match origin" >&2
  exit 1
else
  echo "PASS: rejects a stale/mismatched remote PR head"
fi

# Case 3: a PR targeting the wrong base cannot satisfy the task.
write_pr_fixture "develop" "$PR_HEAD_SHA"
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "FAIL: accepted a PR targeting the wrong base branch" >&2
  exit 1
else
  echo "PASS: rejects a PR targeting the wrong base"
fi

# Case 4: a task with no same-issue completed PR and no exact task ID in its
# PR body must fail closed.
sqlite3 "$DB" "UPDATE processed_comments SET status='failed' WHERE commentId='$PREVIOUS_TASK';"
write_pr_fixture
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "FAIL: accepted a PR without valid current/prior-task correlation" >&2
  exit 1
else
  echo "PASS: rejects unrelated or non-completed prior task evidence"
fi

# Case 5: a fresh task explicitly named in the PR body can pass without a prior
# completed task, provided base and remote head checks still pass.
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='$PREVIOUS_TASK';"
write_pr_fixture "main" "$PR_HEAD_SHA" "$CURRENT_TASK"
if verify_existing_task_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main"; then
  echo "PASS: accepts PR explicitly correlated to the current task"
else
  echo "FAIL: expected explicitly task-bound PR to qualify" >&2
  exit 1
fi

# Case 6: a prior attempt's result comment can independently prove that work
# was delivered by a merged PR, even if the feature branch was deleted.
MERGED_MARKER="<!-- manul-task:${CURRENT_TASK}:attempt:3 -->"
jq -cn --arg marker "$MERGED_MARKER" --arg url "$PR_URL"   '[[{id:987,body:($marker + "\n# Task completed\nPR: " + $url)}]]' >"$FAKE_RESULT_COMMENTS_JSON"
jq -cn --arg url "$PR_URL" --arg sha "$PR_HEAD_SHA"   '{url:$url,state:"MERGED",baseRefName:"main",headRefName:"feature/17-helloworld-java",headRefOid:$sha,mergedAt:"2026-10-28T00:00:00Z"}' >"$FAKE_PR_VIEW_JSON"
git --git-dir="$ORIGIN" branch -D feature/17-helloworld-java >/dev/null
if verify_merged_result_pr "test/repo" 17 "$CURRENT_TASK" 3 "main" "main"; then
  [ "$VERIFIED_EXISTING_PR_BRANCH" = "feature/17-helloworld-java" ]
  [ "$VERIFIED_EXISTING_PR_URL" = "$PR_URL" ]
  [ "$VERIFIED_MERGED_RESULT_PR_BASE" = "main" ]
  echo "PASS: accepts exact current-attempt result pointing to merged PR after remote head deletion"
else
  echo "FAIL: expected current attempt's merged PR result to qualify" >&2
  exit 1
fi

# A still-open source issue must not be treated as already delivered.
FAKE_ISSUE_STATE="open"
if verify_merged_result_pr "test/repo" 17 "$CURRENT_TASK" 3 "main" "main"; then
  echo "FAIL: accepted merged-result recovery for an open source issue" >&2
  exit 1
else
  echo "PASS: rejects merged-result recovery while the source issue remains open"
fi
FAKE_ISSUE_STATE="closed"

# An unmerged PR is not proof of delivered work.
jq -cn --arg url "$PR_URL" --arg sha "$PR_HEAD_SHA"   '{url:$url,state:"OPEN",baseRefName:"main",headRefName:"feature/17-helloworld-java",headRefOid:$sha,mergedAt:null}' >"$FAKE_PR_VIEW_JSON"
if verify_merged_result_pr "test/repo" 17 "$CURRENT_TASK" 3 "main" "main"; then
  echo "FAIL: accepted a non-merged PR as completed delivery" >&2
  exit 1
else
  echo "PASS: rejects a PR that has not been merged"
fi

# A PR targeting neither the initial nor repository-default base is invalid.
jq -cn --arg url "$PR_URL" --arg sha "$PR_HEAD_SHA"   '{url:$url,state:"MERGED",baseRefName:"develop",headRefName:"feature/17-helloworld-java",headRefOid:$sha,mergedAt:"2026-10-28T00:00:00Z"}' >"$FAKE_PR_VIEW_JSON"
if verify_merged_result_pr "test/repo" 17 "$CURRENT_TASK" 3 "main" "main"; then
  echo "FAIL: accepted a merged PR against an unexpected base" >&2
  exit 1
else
  echo "PASS: rejects merged PRs targeting an unexpected base"
fi

# Assert that the real IMPLEMENT evaluator preserves strict PR validation,
# while routing only the verified comment-only exception through its dedicated
# finalization gate.
evaluator_block="$(grep -F -A 95 'elif [ "$TASK_ACTION" = "IMPLEMENT" ]; then' "$SCRIPT_DIR/manul-daemon.sh")"
grep -q 'verify_existing_task_pr' <<<"$evaluator_block"
grep -q 'verify_merged_result_pr' <<<"$evaluator_block"
grep -q 'already_satisfied="true"' <<<"$evaluator_block"
grep -q 'already_satisfied" != "true"' <<<"$evaluator_block"
grep -q 'VERIFIED_MERGED_RESULT_PR_BASE' <<<"$evaluator_block"
grep -Fq 'local VERIFIED_MERGED_RESULT_PR_BASE=""' "$SCRIPT_DIR/manul-daemon.sh"
grep -q 'verify_implement_comment_only_delivery "$REPO" "$ISSUE_NUM" "$COMMENT_ID"' <<<"$evaluator_block"
grep -q 'verify_result_comment_pr_url_if_required "$COMMENT_ONLY_DELIVERY" "$TASK_SOURCE_TYPE"' <<<"$evaluator_block"
final_marker_gate="$(grep -F -A 7 '# The comment-only base-branch verifier already checked this exact marker' "$SCRIPT_DIR/manul-daemon.sh")"
grep -Fq '[ "$COMMENT_ONLY_DELIVERY" != "true" ]' <<<"$final_marker_gate"
grep -Fq 'verify_result_comment "$REPO" "$ISSUE_NUM" "$COMMENT_ID"' <<<"$final_marker_gate"
echo "PASS: comment-only delivery skips only redundant final marker read; normal GitHub tasks retain it"

# Case 9: a clean base checkout with a verified, non-empty current-attempt
# result comment is accepted as comment-only delivery without requiring a PR.
CURRENT_RESULT_MARKER="<!-- manul-task:${CURRENT_TASK}:attempt:1 -->"
jq -cn --arg marker "$CURRENT_RESULT_MARKER" \
  '[{id:999,in_reply_to_id:null,body:($marker + "\\n# Task completed\\nAnswer: yes, it is possible.")}]' \
  >"$FAKE_RESULT_COMMENTS_JSON"
git -C "$WORKDIR" checkout -q main
git -C "$WORKDIR" reset -q --hard "$INITIAL_BASE_SHA"
if verify_implement_comment_only_delivery "test/repo" 17 "$CURRENT_TASK" "$CURRENT_TASK" 1 "$WORKDIR" "$INITIAL_BASE_SHA" "main"; then
  [ "$COMMENT_ONLY_DELIVERY" = "true" ]
  echo "PASS: clean base checkout plus verified non-empty result comment is accepted"
else
  echo "FAIL: expected clean base checkout plus verified non-empty result comment to be accepted (code=$IMPLEMENT_COMMENT_ONLY_FAILURE_CODE reason=$IMPLEMENT_COMMENT_ONLY_FAILURE_REASON)" >&2
  exit 1
fi

# A dirty base checkout remains forbidden even if a valid result comment exists.
printf 'forbidden direct edit\\n' >"$WORKDIR/forbidden.txt"
if verify_implement_comment_only_delivery "test/repo" 17 "$CURRENT_TASK" "$CURRENT_TASK" 1 "$WORKDIR" "$INITIAL_BASE_SHA" "main"; then
  echo "FAIL: accepted comment-only delivery after a direct base-branch edit" >&2
  exit 1
else
  [ "$COMMENT_ONLY_DELIVERY" = "false" ]
  [ "$IMPLEMENT_COMMENT_ONLY_FAILURE_CODE" = "VERIFICATION_FAILED" ]
  echo "PASS: direct edits on the base branch are still rejected"
fi
rm -f "$WORKDIR/forbidden.txt"

# A marker without meaningful user-facing content is not a completed delivery.
jq -cn --arg marker "$CURRENT_RESULT_MARKER" \
  '[{id:1000,in_reply_to_id:null,body:$marker}]' >"$FAKE_RESULT_COMMENTS_JSON"
if verify_implement_comment_only_delivery "test/repo" 17 "$CURRENT_TASK" "$CURRENT_TASK" 1 "$WORKDIR" "$INITIAL_BASE_SHA" "main"; then
  echo "FAIL: accepted an empty comment-only result" >&2
  exit 1
else
  [ "$COMMENT_ONLY_DELIVERY" = "false" ]
  [ "$IMPLEMENT_COMMENT_ONLY_FAILURE_CODE" = "DELIVERY_COMMENT_EMPTY" ]
  echo "PASS: marker-only result comments are rejected"
fi

# An absent current-attempt marker is also fail-closed.
jq -cn '[{id:1001,in_reply_to_id:null,body:"stale result from another attempt"}]' >"$FAKE_RESULT_COMMENTS_JSON"
if verify_implement_comment_only_delivery "test/repo" 17 "$CURRENT_TASK" "$CURRENT_TASK" 1 "$WORKDIR" "$INITIAL_BASE_SHA" "main"; then
  echo "FAIL: accepted a result without the exact current-attempt marker" >&2
  exit 1
else
  [ "$COMMENT_ONLY_DELIVERY" = "false" ]
  [ "$IMPLEMENT_COMMENT_ONLY_FAILURE_CODE" = "DELIVERY_COMMENT_MISSING" ]
  echo "PASS: missing current-attempt markers are rejected"
fi

# The final PR-URL gate is skipped only for verified comment-only delivery.
# Ordinary GitHub IMPLEMENT tasks still invoke it, and Todo sources preserve
# their independent receipt-based completion path.
PR_URL_VERIFY_CALLS=0
verify_result_comment_pr_url() { PR_URL_VERIFY_CALLS=$((PR_URL_VERIFY_CALLS + 1)); return 0; }
if ! verify_result_comment_pr_url_if_required true github_issues test/repo 17 task task 1 "$WORKDIR" main feature; then
  echo "FAIL: verified comment-only delivery unexpectedly failed PR URL finalization" >&2
  exit 1
fi
[ "$PR_URL_VERIFY_CALLS" -eq 0 ]
if ! verify_result_comment_pr_url_if_required false github_issues test/repo 17 task task 1 "$WORKDIR" main feature; then
  echo "FAIL: normal GitHub task PR URL validation unexpectedly failed" >&2
  exit 1
fi
[ "$PR_URL_VERIFY_CALLS" -eq 1 ]
if ! verify_result_comment_pr_url_if_required false todo_remote_mcp test/repo 17 task task 1 "$WORKDIR" main feature; then
  echo "FAIL: Todo source receipt path unexpectedly failed PR URL finalization" >&2
  exit 1
fi
[ "$PR_URL_VERIFY_CALLS" -eq 1 ]
echo "PASS: only verified comment-only delivery bypasses PR URL validation"

# Ambiguous PR creation: GitHub creates the PR, but the gh client reports a
# transport failure. The following retry must discover and reuse that PR rather
# than issuing a second create request for the same head/base.
RETRY_BRANCH="feature/task-pr-ambiguous-create"
git -C "$WORKDIR" checkout -qb "$RETRY_BRANCH" main
printf 'retry-safe delivery\n' >"$WORKDIR/retry-safe.txt"
git -C "$WORKDIR" add retry-safe.txt
git -C "$WORKDIR" commit -qm "Add retry-safe delivery"
# Simulate an ambiguous git push: the remote accepts the branch, but the
# client reports a transport failure. Retry should observe the remote head and
# must not push or create the same PR again.
REAL_GIT="$(command -v git)"
PUSH_BIN="$TMP/push-bin"
mkdir -p "$PUSH_BIN"
export REAL_GIT
export PUSH_COUNT_FILE="$TMP/push-count"
cat >"$PUSH_BIN/git" <<'GITMOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "push" ]; then
  count="$(cat "$PUSH_COUNT_FILE" 2>/dev/null || echo 0)"
  count=$((count + 1))
  printf '%s\n' "$count" >"$PUSH_COUNT_FILE"
  "$REAL_GIT" "$@"
  git_rc=$?
  [ "$git_rc" -eq 0 ] || exit "$git_rc"
  exit 1
fi
exec "$REAL_GIT" "$@"
GITMOCK
chmod +x "$PUSH_BIN/git"
PATH="$PUSH_BIN:$PATH"
printf '0\n' >"$PUSH_COUNT_FILE"
printf '0\n' >"$PR_CREATE_COUNT_FILE"
printf '[]\n' >"$FAKE_GH_PR_LIST"
printf '{"autoCreatePr":true,"automation":{"maxAttemptsBeforeFail":3}}\n' >"$TMP/auto-create-config.json"
CONFIG="$TMP/auto-create-config.json"

first_rc=0
verify_required_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main" || first_rc=$?
[ "$first_rc" -eq 1 ] || { echo "FAIL: expected first ambiguous PR creation attempt to report failure (rc=$first_rc)" >&2; exit 1; }
[ "$(cat "$PR_CREATE_COUNT_FILE")" = "1" ] || { echo "FAIL: expected one PR create request after ambiguous acceptance" >&2; exit 1; }
[ "$(cat "$PUSH_COUNT_FILE")" = "1" ] || { echo "FAIL: expected one accepted-but-client-error branch push" >&2; exit 1; }
[ -n "$("$REAL_GIT" -C "$WORKDIR" ls-remote --heads origin "$RETRY_BRANCH" | awk 'NR==1 {print $1}')" ] || { echo "FAIL: ambiguous push did not leave the branch on origin" >&2; exit 1; }
second_rc=0
verify_required_pr "test/repo" "$CURRENT_TASK" "$WORKDIR" "main" || second_rc=$?
[ "$second_rc" -eq 0 ] || { echo "FAIL: retry did not discover the PR accepted by GitHub (rc=$second_rc)" >&2; exit 1; }
[ "$(cat "$PR_CREATE_COUNT_FILE")" = "1" ] || { echo "FAIL: retry issued a duplicate PR create request" >&2; exit 1; }
[ "$(cat "$PUSH_COUNT_FILE")" = "1" ] || { echo "FAIL: retry re-pushed a branch already accepted by origin" >&2; exit 1; }
jq -e 'length == 1 and .[0].headRefName == "feature/task-pr-ambiguous-create"' "$FAKE_GH_PR_LIST" >/dev/null
echo "PASS: retry after accepted-but-client-error push/PR reuses remote branch and existing PR without duplicates"

echo "All existing-task PR regression tests passed."
