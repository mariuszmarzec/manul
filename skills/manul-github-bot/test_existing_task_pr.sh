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
if [ -z "$verifier_source" ] || [ -z "$merged_verifier_source" ] || [ -z "$pr_check_source" ] || [ -z "$pr_auto_source" ] || [ -z "$required_pr_source" ] || [ -z "$base_infer_source" ]; then
  echo "FAIL: existing-task/required-PR verifier functions were not found in manul-daemon.sh" >&2
  exit 1
fi
eval "$verifier_source"
eval "$merged_verifier_source"
eval "$pr_check_source"
eval "$pr_auto_source"
eval "$base_infer_source"
eval "$required_pr_source"

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
git init --quiet --initial-branch=main "$WORKDIR"
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
  cat "$FAKE_RESULT_COMMENTS_JSON"
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

# Assert that the real IMPLEMENT evaluator allows a no-op retry only after one
# of the verified-existing-PR paths succeeds and always validates the result URL.
evaluator_block="$(grep -F -A 65 'elif [ "$TASK_ACTION" = "IMPLEMENT" ]; then' "$SCRIPT_DIR/manul-daemon.sh")"
grep -q 'verify_existing_task_pr' <<<"$evaluator_block"
grep -q 'verify_merged_result_pr' <<<"$evaluator_block"
grep -q 'already_satisfied="true"' <<<"$evaluator_block"
grep -q 'already_satisfied" != "true"' <<<"$evaluator_block"
grep -q 'VERIFIED_MERGED_RESULT_PR_BASE' <<<"$evaluator_block"
grep -Fq 'local VERIFIED_MERGED_RESULT_PR_BASE=""' "$SCRIPT_DIR/manul-daemon.sh"
grep -q 'verify_result_comment_pr_url' <<<"$evaluator_block"
echo "PASS: IMPLEMENT evaluator recognizes independently verified merged PRs and retains result URL verification"

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
