#!/usr/bin/bash
# Hermetic regression tests for Manul source revalidation.
# No GitHub token/network is required: REST and GraphQL are fully mocked.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/logs/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/logs/lifecycle.log"
PID_FILE="$MANUL_DIR/state/locks/daemon.pid"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs"

cat >"$CONFIG" <<'JSON'
{
  "autoCreatePr": false,
  "automation": {
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900
  },
  "retryConfig": {
    "delaySeconds": 1
  },
  "repositories": []
}
JSON

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/openclaw" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN/openclaw"

cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="rest"
url=""
pr_num=""
cursor=""

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    graphql) mode="graphql" ;;
    repos/*) url="${args[$i]}" ;;
    --field)
      i=$((i+1))
      field="${args[$i]}"
      case "$field" in
        num=*) pr_num="${field#num=}" ;;
        c=*) cursor="${field#c=}" ;;
      esac
      ;;
  esac
done

if [[ "$mode" == "graphql" ]]; then
  case "$pr_num:$cursor" in
    4001:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":1101}]}}]}}}}}
JSON
      ;;
    4002:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor1"},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":2100}]}}]}}}}}
JSON
      ;;
    4002:cursor1)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":1202}]}}]}}}}}
JSON
      ;;
    4003:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor1"},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":3100}]}}]}}}}}
JSON
      ;;
    4003:cursor1)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":true,"comments":{"nodes":[{"databaseId":1303}]}}]}}}}}
JSON
      ;;
    4004:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor1"},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":4100}]}}]}}}}}
JSON
      ;;
    4004:cursor1)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"OPEN","reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":4404}]}}]}}}}}
JSON
      ;;
    4005:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"CLOSED","reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":1505}]}}]}}}}}
JSON
      ;;
    4006:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":{"state":"MERGED","reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":1606}]}}]}}}}}
JSON
      ;;
    4999:)
      cat <<'JSON'
{"data":{"repository":{"pullRequest":null}}}
JSON
      ;;
    5000:)
      cat <<'JSON'
{"errors":[{"message":"rate limit"}]}
JSON
      exit 1
      ;;
    *)
      echo "unexpected GraphQL fixture: pr=$pr_num cursor=$cursor" >&2
      exit 1
      ;;
  esac
  exit 0
fi

case "$url" in
  */issues/comments/1001) echo '{"id":1001}' ;;
  */issues/comments/9999) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
  */issues/comments/5000) echo '{"message":"network"}'; exit 7 ;;
  */issues/2001) echo '{"state":"open"}' ;;
  */issues/2002) echo '{"state":"closed"}' ;;
  */issues/35) echo '{"state":"open"}' ;;
  */issues/9999) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
  */issues/5000) echo '{"message":"network"}'; exit 7 ;;
  */pulls/3001|*/pulls/4001|*/pulls/4002|*/pulls/4003|*/pulls/4004|*/pulls/590)
    echo '{"state":"open","merged":false,"head":{"ref":"feature/open-pr","repo":{"full_name":"owner/repo"}}}' ;;
  */pulls/3002|*/pulls/4005) echo '{"state":"closed","merged":false}' ;;
  */pulls/3003|*/pulls/4006|*/pulls/591) echo '{"state":"closed","merged":true}' ;;
  */pulls/3004|*/pulls/592) echo '{"state":"open","merged":false,"head":{"ref":"feature/deleted-pr","repo":{"full_name":"owner/repo"}}}' ;;
  */pulls/3005) echo '{"state":"open","merged":false,"head":{"ref":"feature/no-repo","repo":null}}' ;;
  */pulls/3006) echo '{"state":"open","merged":false,"head":{"ref":"feature/network-pr","repo":{"full_name":"owner/repo"}}}' ;;
  */pulls/3007) echo '{"state":"open"}' ;;
  */pulls/3008) echo '{"merged":false}' ;;
  */pulls/9999|*/pulls/4999) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
  */pulls/5000) echo '{"state":"open","merged":false,"head":{"ref":"feature/graphql-error","repo":{"full_name":"owner/repo"}}}' ;;
  */pulls/5001) echo '{"message":"network"}'; exit 7 ;;
  */branches/feature%2Fopen-pr) echo '{"name":"feature/open-pr"}' ;;
  */branches/feature%2Fdeleted-pr) echo '{"message":"Branch not found","status":"404"}'; exit 1 ;;
  */branches/feature%2Fnetwork-pr) echo '{"message":"network"}'; exit 7 ;;
  */branches/feature%2Fgraphql-error) echo '{"name":"feature/graphql-error"}' ;;
  *) echo "unexpected REST fixture: $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG PID_FILE MANUL_TESTING=true
export PATH="$FAKE_BIN:$PATH"

set +e
source "$SCRIPT_DIR/manul-daemon.sh"
SOURCE_RC=$?
set +e
if [ "$SOURCE_RC" -ne 0 ]; then
  echo "FAIL: sourcing manul-daemon.sh returned rc=$SOURCE_RC" >&2
  exit 1
fi
export PATH="$FAKE_BIN:$PATH"

sqlite3 "$DB" "
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  action TEXT,
  status TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  resultSummary TEXT
);
"

REPO="owner/repo"
GH_API_TIMEOUT=2
PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected rc=$expected, got rc=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== detect_source_kind ==="
assert_eq "issue: -> issue_comment" "issue_comment" "$(detect_source_kind "issue:123")"
assert_eq "issuebody: -> issue_state" "issue_state" "$(detect_source_kind "issuebody:123")"
assert_eq "ci_fix: -> pr_state" "pr_state" "$(detect_source_kind "ci_fix:owner/repo:123:run")"
assert_eq "review: -> pr_review_comment" "pr_review_comment" "$(detect_source_kind "review:123")"
assert_eq "pull URL is not authoritative pr_state" "issue_comment" "$(detect_source_kind "foo/pull/123")"
assert_eq "compare URL is not authoritative pr_state" "issue_comment" "$(detect_source_kind "foo/compare/123")"

echo "=== issue_comment ==="
revalidate_issue_comment "issue:1001" "$REPO"; rc=$?; assert_rc "existing comment fresh" 0 "$rc"
revalidate_issue_comment "issue:9999" "$REPO"; rc=$?; assert_rc "404 comment stale" 1 "$rc"
revalidate_issue_comment "issue:5000" "$REPO"; rc=$?; assert_rc "REST error transient" 2 "$rc"
revalidate_issue_comment "issue:1001" "$REPO" "https://github.com/$REPO/pull/590#issuecomment-1001"; rc=$?; assert_rc "open PR comment with existing head is fresh" 0 "$rc"
revalidate_issue_comment "issue:1001" "$REPO" "https://github.com/$REPO/pull/591#issuecomment-1001"; rc=$?; assert_rc "comment on merged PR is stale" 1 "$rc"
revalidate_issue_comment "issue:1001" "$REPO" "https://github.com/$REPO/pull/592#issuecomment-1001"; rc=$?; assert_rc "comment on PR with deleted head is stale" 1 "$rc"

echo "=== issue_state ==="
revalidate_issue_state "issuebody:2001" "$REPO"; rc=$?; assert_rc "open issue fresh" 0 "$rc"
revalidate_issue_state "issuebody:2002" "$REPO"; rc=$?; assert_rc "closed issue stale" 1 "$rc"
revalidate_issue_state "issuebody:9999" "$REPO"; rc=$?; assert_rc "404 issue stale" 1 "$rc"
revalidate_issue_state "issuebody:5000" "$REPO"; rc=$?; assert_rc "REST error transient" 2 "$rc"
revalidate_issue_state "issuebody:5565498138" "$REPO" "https://github.com/$REPO/issues/35"; rc=$?; assert_rc "legacy API issue ID resolves via source URL" 0 "$rc"

echo "=== pr_state (OPEN only) ==="
revalidate_pr_state "ci_fix:owner/repo:3001:run1" "$REPO"; rc=$?; assert_rc "open PR fresh" 0 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3002:run1" "$REPO"; rc=$?; assert_rc "closed PR stale" 1 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3003:run1" "$REPO"; rc=$?; assert_rc "merged PR stale" 1 "$rc"
revalidate_pr_state "ci_fix:owner/repo:9999:run1" "$REPO"; rc=$?; assert_rc "404 PR stale" 1 "$rc"
revalidate_pr_state "ci_fix:owner/repo:5001:run1" "$REPO"; rc=$?; assert_rc "REST error transient" 2 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3004:run1" "$REPO"; rc=$?; assert_rc "open PR with deleted head branch stale" 1 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3005:run1" "$REPO"; rc=$?; assert_rc "open PR with missing head repo stale" 1 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3006:run1" "$REPO"; rc=$?; assert_rc "head branch API error transient" 2 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3007:run1" "$REPO"; rc=$?; assert_rc "missing head metadata transient" 2 "$rc"
revalidate_pr_state "ci_fix:owner/repo:3008:run1" "$REPO"; rc=$?; assert_rc "missing PR state transient" 2 "$rc"

echo "=== pr_review_comment ==="
revalidate_pr_review_comment "review:1101" "$REPO" 4001; rc=$?; assert_rc "page1 unresolved target fresh" 0 "$rc"
revalidate_pr_review_comment "review:1202" "$REPO" 4002; rc=$?; assert_rc "page2 unresolved target fresh" 0 "$rc"
revalidate_pr_review_comment "review:1303" "$REPO" 4003; rc=$?; assert_rc "page2 resolved target stale" 1 "$rc"
revalidate_pr_review_comment "review:1404" "$REPO" 4004; rc=$?; assert_rc "target absent after all pages stale" 1 "$rc"
revalidate_pr_review_comment "review:1505" "$REPO" 4005; rc=$?; assert_rc "closed PR stale" 1 "$rc"
revalidate_pr_review_comment "review:1606" "$REPO" 4006; rc=$?; assert_rc "merged PR stale" 1 "$rc"
revalidate_pr_review_comment "review:12345" "$REPO" 4999; rc=$?; assert_rc "missing PR stale" 1 "$rc"
revalidate_pr_review_comment "review:12345" "$REPO" 5000; rc=$?; assert_rc "GraphQL error transient" 2 "$rc"

echo "=== revalidate_source ==="
revalidate_source "review:1202" "$REPO" 4002; rc=$?; assert_rc "wrapper passes issueNumber to review" 0 "$rc"
revalidate_source "issue:1001" "$REPO" 591 "https://github.com/$REPO/pull/591#issuecomment-1001"; rc=$?; assert_rc "wrapper routes PR comment sources through PR state validation" 1 "$rc"

echo "=== stale/requeue helpers ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts,claimToken,workerPid,heartbeatAt,leaseExpiresAt) VALUES('stale-test','$REPO',1,'url','IMPLEMENT','running',1,'token1',123,datetime('now'),datetime('now','+900 seconds'));"
mark_task_stale "stale-test" "stale-test" "token1"; rc=$?; assert_rc "mark_task_stale succeeds" 0 "$rc"
assert_eq "stale is terminal" "stale" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='stale-test';")"
assert_eq "stale clears claim token" "" "$(sqlite3 "$DB" "SELECT coalesce(claimToken,'') FROM processed_comments WHERE commentId='stale-test';")"
assert_eq "stale clears heartbeat" "" "$(sqlite3 "$DB" "SELECT coalesce(heartbeatAt,'') FROM processed_comments WHERE commentId='stale-test';")"
assert_eq "stale clears worker pid" "" "$(sqlite3 "$DB" "SELECT coalesce(workerPid,'') FROM processed_comments WHERE commentId='stale-test';")"

sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts,claimToken,workerPid) VALUES('requeue-test','$REPO',2,'url','IMPLEMENT','running',1,'token2',456);"
requeue_task "requeue-test" "requeue-test" "token2"; rc=$?; assert_rc "requeue succeeds" 0 "$rc"
assert_eq "transient returns queued" "queued" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='requeue-test';")"
assert_eq "pre-agent revalidation preserves agent attempt budget" "0" "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='requeue-test';")"
assert_eq "requeue clears claim token" "" "$(sqlite3 "$DB" "SELECT coalesce(claimToken,'') FROM processed_comments WHERE commentId='requeue-test';")"
assert_eq "requeue sets nextAttemptAt" "1" "$(sqlite3 "$DB" "SELECT nextAttemptAt IS NOT NULL FROM processed_comments WHERE commentId='requeue-test';")"

echo "=== claim token guards ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts,claimToken,workerPid) VALUES('guard-test','$REPO',3,'url','IMPLEMENT','running',1,'real-token',789);"
mark_task_stale "guard-test" "guard-test" "wrong-token"; rc=$?; assert_rc "wrong token rejected" 1 "$rc"
assert_eq "wrong token leaves task running" "running" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='guard-test';")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
