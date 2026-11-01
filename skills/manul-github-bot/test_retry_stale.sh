#!/usr/bin/env bash
# test_retry_stale.sh — Hermetic regression tests for task-recovery.sh --retry-stale
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/logs/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/logs/lifecycle.log"
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
  "repositories": [],
  "taskSources": [
    {"type":"github_issues","enabled":true,"repositories":["owner/repo"],"trigger":"/manul","allowedUsers":[]}
  ]
}
JSON

# manul-daemon.sh line 35 rewrites PATH to
# "$HOME/.opencode/bin:$HOME/.local/bin:...:/usr/bin:/bin:$PATH". To win that
# race hermetically we point HOME at a temp dir and place the gh/timeout stubs
# in $HOME/.local/bin, which the rewrite keeps ahead of /usr/bin.
export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.local/bin" "$HOME/.opencode/bin"
FAKE_BIN="$HOME/.local/bin"

# Stub gh to control revalidation outcomes without network access
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  case "$arg" in
    repos/*) url="$arg" ;;
  esac
done

case "$url" in
  # Legacy issue:6558057571 → comment exists (fresh)
  */issues/comments/6558057571) echo '{"id":6558057571}' ;;
  # source:github_issues:owner/repo#2011 → open issue with trigger (fresh)
  */issues/2011) echo '{"state":"open","body":"/manul implement the task","user":{"login":"alice"}}' ;;
  # source:github_issues:owner/repo#2012 → closed issue (stale)
  */issues/2012) echo '{"state":"closed","body":"/manul implement the task","user":{"login":"alice"}}' ;;
  # source:github_issues:owner/repo#2013 → open but no trigger (stale)
  */issues/2013) echo '{"state":"open","body":"No trigger here","user":{"login":"alice"}}' ;;
  # source:github_issues:owner/repo#2014 → transient API error (rc=2)
  */issues/2014) echo '{"message":"network"}'; exit 7 ;;
  # source:github_issues:owner/repo#2015 → not found (stale)
  */issues/2015) echo '{"message":"Not Found","status":"404"}'; exit 1 ;;
  *) echo "unexpected gh fixture: $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"

# Stub timeout so the gh stub (invoked as `timeout "$GH_API_TIMEOUT" gh api ...`)
# is reached without invoking the real /usr/bin/timeout. The stub drops the
# leading duration argument and execs the remainder verbatim.
cat >"$FAKE_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
# Usage: timeout [DURATION] COMMAND [ARGS...]
# Hermetic test stub: drop the duration, exec the command.
shift
exec "$@"
EOF
chmod +x "$FAKE_BIN/timeout"

export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG MANUL_TESTING=true
export PATH="$FAKE_BIN:$PATH"

init_db() {
  sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT,
  author TEXT,
  agent TEXT,
  prompt TEXT,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  claimToken TEXT,
  resultSummary TEXT,
  resultJson TEXT,
  workerPid INTEGER,
  nextAttemptAt TEXT,
  baseId TEXT,
  taskSourceType TEXT,
  taskSourceId TEXT,
  taskSourceUrl TEXT,
  taskSourceTitle TEXT,
  taskSourceUpdatedAt TEXT,
  preExecutionFailures INTEGER NOT NULL DEFAULT 0,
  agentStartedAt TEXT
);
SQL
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$desc: expected=$expected actual=$actual"
  pass "$desc"
}

init_db

# ---------------------------------------------------------------------------
# Test 1: Legacy issue: task with valid comment → retry allowed
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,nextAttemptAt) VALUES('issue:6558057571','owner/repo',1,'stale',2,datetime('now'),NULL);"
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'issue:6558057571' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:6558057571';")
ATTEMPTS=$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='issue:6558057571';")
NEXT_ATTEMPT=$(sqlite3 "$DB" "SELECT COALESCE(nextAttemptAt,'') FROM processed_comments WHERE commentId='issue:6558057571';")
assert_eq "Legacy stale task retried successfully" "queued" "$STATUS"
assert_eq "Legacy stale task attempts reset" "0" "$ATTEMPTS"
if [ -n "$NEXT_ATTEMPT" ]; then
  pass "Legacy stale task has immediate nextAttemptAt"
else
  fail "Legacy stale task has immediate nextAttemptAt"
fi

# ---------------------------------------------------------------------------
# Test 2: Source github_issues with open valid issue → retry allowed
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,taskSourceType,taskSourceId) VALUES('source:github_issues:owner/repo#2011','owner/repo',2011,'stale',1,datetime('now'),'github_issues','owner/repo#2011');"
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'source:github_issues:owner/repo#2011' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2011';")
assert_eq "Valid source task retried" "queued" "$STATUS"

# ---------------------------------------------------------------------------
# Test 3: Source github_issues with closed issue → retry refused, no change
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,taskSourceType,taskSourceId) VALUES('source:github_issues:owner/repo#2012','owner/repo',2012,'stale',1,datetime('now'),'github_issues','owner/repo#2012');"
BEFORE_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2012';")
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'source:github_issues:owner/repo#2012' 2>&1) || true
AFTER_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2012';")
assert_eq "Closed source task stays stale" "$BEFORE_STATUS" "$AFTER_STATUS"
echo "$OUTPUT" | grep -qi "refusing\|terminal" && pass "Closed source rejection logged" || fail "Closed source rejection logged"

# ---------------------------------------------------------------------------
# Test 4: Source github_issues missing trigger → retry refused
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,taskSourceType,taskSourceId) VALUES('source:github_issues:owner/repo#2013','owner/repo',2013,'stale',1,datetime('now'),'github_issues','owner/repo#2013');"
BEFORE_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2013';")
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'source:github_issues:owner/repo#2013' 2>&1) || true
AFTER_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2013';")
assert_eq "Triggerless source task stays stale" "$BEFORE_STATUS" "$AFTER_STATUS"

# ---------------------------------------------------------------------------
# Test 5: Transient API error (rc=2) → retry refused
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,taskSourceType,taskSourceId) VALUES('source:github_issues:owner/repo#2014','owner/repo',2014,'stale',1,datetime('now'),'github_issues','owner/repo#2014');"
BEFORE_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2014';")
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'source:github_issues:owner/repo#2014' 2>&1) || true
AFTER_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#2014';")
assert_eq "Transient-error source task stays stale" "$BEFORE_STATUS" "$AFTER_STATUS"
echo "$OUTPUT" | grep -qi "transient\|retry later" && pass "Transient rejection logged" || fail "Transient rejection logged"

# ---------------------------------------------------------------------------
# Test 6: Non-stale status → no mutation
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('failed-task','owner/repo',99,'failed',3,datetime('now'));"
BEFORE_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='failed-task';")
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'failed-task' 2>&1) || true
AFTER_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='failed-task';")
assert_eq "Failed task unaffected by --retry-stale" "$BEFORE_STATUS" "$AFTER_STATUS"

# ---------------------------------------------------------------------------
# Test 7: Missing record → safe error, no crash
# ---------------------------------------------------------------------------
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'nonexistent-id' 2>&1) || true
echo "$OUTPUT" | grep -qi "error\|cannot\|not found" && pass "Missing record handled safely" || fail "Missing record handled safely"

# ---------------------------------------------------------------------------
# Test 8: CLI argument validation
# ---------------------------------------------------------------------------
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 2>&1) || true
echo "$OUTPUT" | grep -qi "requires a task id" && pass "--retry-stale requires task id" || fail "--retry-stale requires task id"

echo ""
echo "All retry-stale tests passed."
