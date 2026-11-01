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
  # Legacy issue:9001 → gh itself is missing (rc=127): fail-closed must refuse
  */issues/comments/9001) echo "gh: command not found"; exit 127 ;;
  # Legacy issue:flip-status → models the dispatcher claiming the row between
  # our snapshot and our CAS: flip status to 'running', then report fresh.
  */issues/comments/flip-status) [ -n "${DB:-}" ] && sqlite3 "$DB" "UPDATE processed_comments SET status='running' WHERE commentId='issue:flip-status';" 2>/dev/null || true; echo '{"id":9002}' ;;
  # Source issue:9999 → models source-identity drift between snapshot and CAS:
  # change taskSourceId, then report fresh.
  */issues/9999) [ -n "${DB:-}" ] && sqlite3 "$DB" "UPDATE processed_comments SET taskSourceId='owner/repo#1111' WHERE commentId='source:github_issues:owner/repo#9999';" 2>/dev/null || true; echo '{"state":"open","body":"/manul x","user":{"login":"alice"}}' ;;
  # Legacy issue:7777 → fresh comment, used for the deferred-executor-cleanup test
  */issues/comments/7777) echo '{"id":7777}' ;;
  # Legacy issue:race-live → fresh comment, live-PID core-safety test
  */issues/comments/race-live) echo '{"id":10001}' ;;
  # Legacy issue:retry-race → fresh comment, post-CAS dispatcher-claim race test
  */issues/comments/retry-race) echo '{"id":10002}' ;;
  # Legacy issue:8888 → fresh comment, used for the production-CLI test (MANUL_TESTING unset)
  */issues/comments/8888) echo '{"id":8888}' ;;
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
# Resolve the executor pid file exactly as the daemon/recovery do, so the
# race/cleanup tests can seed and inspect the same file.
source "$SCRIPT_DIR/manul-paths.sh"
pid_file() { manul_task_file_path "$MANUL_DIR" "$1" "executor.pid"; }

# Build a stripped copy of task-recovery.sh in a temp dir so we can control
# which sibling libraries are present (missing module / missing function).
make_recovery_copy() {
  local dest_dir="$1"
  mkdir -p "$dest_dir"
  cp "$SCRIPT_DIR/manul-paths.sh" "$dest_dir/"
  cp "$SCRIPT_DIR/task-recovery.sh" "$dest_dir/"
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

# =============================================================================
# Regression scenarios (BLOCKER + fail-closed + race protection)
# =============================================================================

# ---------------------------------------------------------------------------
# Test 9: UNKNOWN revalidation rc (127) → fail-closed refuse.
# A stripped recovery dir whose revalidate_source deliberately returns 127
# (command-not-found / crash) must NOT requeue the task.
# ---------------------------------------------------------------------------
COPY_RC127="$TEST_DIR/copy-rc127"
make_recovery_copy "$COPY_RC127"
cat >"$COPY_RC127/task-source-revalidate.sh" <<'EOF'
GH_API_TIMEOUT="${GH_API_TIMEOUT:-30}"
revalidate_source() { return 127; }
EOF
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:rc127','owner/repo',1,'stale',1,datetime('now'));"
OUTPUT=$(bash "$COPY_RC127/task-recovery.sh" --retry-stale 'issue:rc127' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:rc127';")
assert_eq "Unknown reval rc=127 stays stale (fail-closed)" "stale" "$STATUS"
echo "$OUTPUT" | grep -qi "unexpected rc=127" && pass "Unknown rc=127 fail-closed logged" || fail "Unknown rc=127 fail-closed logged"

# ---------------------------------------------------------------------------
# Test 10: MISSING revalidation module (task-source-revalidate.sh absent) →
# refuse without crashing.
# ---------------------------------------------------------------------------
COPY_NOLIB="$TEST_DIR/copy-nolib"
make_recovery_copy "$COPY_NOLIB"   # copies manul-paths.sh + task-recovery.sh only
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:nolib','owner/repo',1,'stale',1,datetime('now'));"
OUTPUT=$(bash "$COPY_NOLIB/task-recovery.sh" --retry-stale 'issue:nolib' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:nolib';")
assert_eq "Missing revalidation module stays stale" "stale" "$STATUS"
echo "$OUTPUT" | grep -qi "revalidate_source unavailable" && pass "Missing module refusal logged" || fail "Missing module refusal logged"

# ---------------------------------------------------------------------------
# Test 11: Module present but revalidate_source UNDEFINED → refuse.
# ---------------------------------------------------------------------------
COPY_NOFN="$TEST_DIR/copy-nofn"
make_recovery_copy "$COPY_NOFN"
cat >"$COPY_NOFN/task-source-revalidate.sh" <<'EOF'
# Present but intentionally defines no revalidate_source()
GH_API_TIMEOUT="${GH_API_TIMEOUT:-30}"
EOF
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:nofn','owner/repo',1,'stale',1,datetime('now'));"
OUTPUT=$(bash "$COPY_NOFN/task-recovery.sh" --retry-stale 'issue:nofn' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:nofn';")
assert_eq "Undefined revalidate_source stays stale" "stale" "$STATUS"
echo "$OUTPUT" | grep -qi "revalidate_source unavailable" && pass "Missing function refusal logged" || fail "Missing function refusal logged"

# ---------------------------------------------------------------------------
# Test 12: PRODUCTION CLI (MANUL_TESTING unset) legacy retry — the BLOCKER.
# The old code sourced the daemon; its trailing CLI dispatcher `exit 2`'d and
# printed usage when MANUL_TESTING != true. The fixed recovery must requeue a
# legacy stale task with no usage text and exit 0 under the production default.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:8888','owner/repo',1,'stale',2,datetime('now'));"
RC=0
OUTPUT=$(env -u MANUL_TESTING bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'issue:8888' 2>&1) || RC=$?
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:8888';")
ATTEMPTS=$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='issue:8888';")
assert_eq "Production CLI (no MANUL_TESTING) legacy retry exit 0" "0" "$RC"
assert_eq "Production CLI (no MANUL_TESTING) legacy task requeued" "queued" "$STATUS"
assert_eq "Production CLI (no MANUL_TESTING) attempts reset" "0" "$ATTEMPTS"
if echo "$OUTPUT" | grep -qi "usage"; then
  fail "Production CLI must not print daemon usage text"
else
  pass "Production CLI (no MANUL_TESTING) no usage text"
fi

# ---------------------------------------------------------------------------
# Test 13: STATUS-FLIP RACE — dispatcher claims the row (stale→running) between
# our snapshot and our CAS. The CAS must abort and MUST NOT clobber the fresh
# 'running' row or kill the fresh executor.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:flip-status','owner/repo',1,'stale',1,datetime('now'));"
# Seed an executor pid file; the aborted path must leave it untouched.
FLIP_PID_FILE="$(pid_file 'issue:flip-status')"
mkdir -p "$(dirname "$FLIP_PID_FILE")"
printf '1' >"$FLIP_PID_FILE"
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'issue:flip-status' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:flip-status';")
assert_eq "Status-flip race: row left at running (not clobbered)" "running" "$STATUS"
echo "$OUTPUT" | grep -qi "changed during revalidation" && pass "Race CAS abort logged" || fail "Race CAS abort logged"
[ -f "$FLIP_PID_FILE" ] && pass "Race: fresh executor pid file preserved" || fail "Race: fresh executor pid file preserved"

# ---------------------------------------------------------------------------
# Test 14: EXECUTOR PID-FILE OWNERSHIP — retry-stale must leave even a dead
# marker untouched. Removing it after a liveness check is still racy because
# the dispatcher can replace it with a fresh PID before unlink.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:7777','owner/repo',1,'stale',1,datetime('now'));"
CLEAN_PID_FILE="$(pid_file 'issue:7777')"
mkdir -p "$(dirname "$CLEAN_PID_FILE")"
sleep 0.1 & _DEAD_PID=$!; wait "$_DEAD_PID" 2>/dev/null || true
printf '%s' "$_DEAD_PID" >"$CLEAN_PID_FILE"
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'issue:7777' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:7777';")
assert_eq "PID-file ownership: stale task requeued" "queued" "$STATUS"
[ -f "$CLEAN_PID_FILE" ] && pass "PID-file ownership: dead marker left for daemon cleanup" || fail "PID-file ownership: retry removed executor pid file"
[ "$(cat "$CLEAN_PID_FILE" 2>/dev/null)" = "$_DEAD_PID" ] && pass "PID-file ownership: marker content unchanged" || fail "PID-file ownership: marker content changed"

# ---------------------------------------------------------------------------
# Test 15 (NEW): POST-CAS DISPATCHER-CLAIM RACE — deterministic regression
# for the window immediately after the recovery CAS. The sqlite3 wrapper
# executes the real stale->queued CAS, then models the dispatcher claiming the
# task and writing a fresh live PID + claim token before the CLI continues.
# retry-stale must not inspect or mutate that PID file at all.
# ---------------------------------------------------------------------------
RACE_BIN="$TEST_DIR/race-bin"
mkdir -p "$RACE_BIN"
cat >"$RACE_BIN/sqlite3" <<'EOF'
#!/usr/bin/env bash
# Intercept only this task's stale->queued CAS. Execute it against the real
# temporary DB first, then atomically model a dispatcher claim before returning
# to task-recovery.sh. All other SQL is passed through unchanged.
sql=""
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) sql="$a" ;;
  esac
done
if printf '%s' "$sql" | grep -qF "UPDATE processed_comments" &&
   printf '%s' "$sql" | grep -qF "SET status='queued'" &&
   printf '%s' "$sql" | grep -qF "commentId='issue:retry-race'"; then
  output="$(/usr/bin/sqlite3 "$@")"
  rc=$?
  if [ "$rc" -eq 0 ] && [ -n "${RACE_LIVE_PID:-}" ]; then
    /usr/bin/sqlite3 "$DB" "UPDATE processed_comments SET status='running', claimToken='tok-race-42', workerPid=$RACE_LIVE_PID, attempts=1, nextAttemptAt=NULL, processedAt=datetime('now') WHERE commentId='issue:retry-race';"
    printf '%s' "$RACE_LIVE_PID" >"$RACE_PID_FILE"
  fi
  printf '%s\n' "$output"
  exit "$rc"
fi
exec /usr/bin/sqlite3 "$@"
EOF
chmod +x "$RACE_BIN/sqlite3"

sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:retry-race','owner/repo',1,'stale',1,datetime('now'));"
sleep 60 & _RACE_LIVE_PID=$!
RACE_PID_FILE="$(pid_file 'issue:retry-race')"
mkdir -p "$(dirname "$RACE_PID_FILE")"
OUTPUT=$(RACE_LIVE_PID="$_RACE_LIVE_PID" RACE_PID_FILE="$RACE_PID_FILE" DB="$DB" PATH="$RACE_BIN:$PATH" bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'issue:retry-race' 2>&1) || true
RACE_STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:retry-race';")
RACE_CLAIM=$(sqlite3 "$DB" "SELECT COALESCE(claimToken,'') FROM processed_comments WHERE commentId='issue:retry-race';")
assert_eq "Post-CAS race: dispatcher claim preserved" "running" "$RACE_STATUS"
assert_eq "Post-CAS race: dispatcher claim token preserved" "tok-race-42" "$RACE_CLAIM"
kill -0 "$_RACE_LIVE_PID" 2>/dev/null && pass "Post-CAS race: fresh executor NOT killed" || fail "Post-CAS race: fresh executor was killed"
[ -f "$RACE_PID_FILE" ] && pass "Post-CAS race: fresh executor pid file preserved" || fail "Post-CAS race: fresh executor pid file removed"
[ "$(cat "$RACE_PID_FILE")" = "$_RACE_LIVE_PID" ] && pass "Post-CAS race: pid file content untouched" || fail "Post-CAS race: pid file content changed"
if echo "$OUTPUT" | grep -qi "terminate_task_executor"; then
  fail "Post-CAS race: retry must never call executor cleanup"
else
  pass "Post-CAS race: retry never calls executor cleanup"
fi
kill "$_RACE_LIVE_PID" 2>/dev/null || true; wait "$_RACE_LIVE_PID" 2>/dev/null || true

# Test 16 (NEW): LIVE-PID CORE SAFETY — a stale row whose pid file points at a
# LIVE process must leave that process and the pid file untouched, even though
# the row ends up queued. This is the invariant that makes the post-CAS race
# harmless: retry-stale never signals a process and never removes a pid file
# that points at something alive.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt) VALUES('issue:race-live','owner/repo',1,'stale',1,datetime('now'));"
sleep 60 & _LIVE_PID=$!
LIVE_PID_FILE="$(pid_file 'issue:race-live')"
mkdir -p "$(dirname "$LIVE_PID_FILE")"
printf '%s' "$_LIVE_PID" >"$LIVE_PID_FILE"
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'issue:race-live' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='issue:race-live';")
assert_eq "Live-pid safety: task requeued" "queued" "$STATUS"
kill -0 "$_LIVE_PID" 2>/dev/null && pass "Live-pid safety: live process NOT killed" || fail "Live-pid safety: live process was killed"
[ -f "$LIVE_PID_FILE" ] && pass "Live-pid safety: live pid file preserved" || fail "Live-pid safety: live pid file removed"
[ "$(cat "$LIVE_PID_FILE" 2>/dev/null)" = "$_LIVE_PID" ] && pass "Live-pid safety: pid file content untouched" || fail "Live-pid safety: pid file content untouched"
kill "$_LIVE_PID" 2>/dev/null || true; wait "$_LIVE_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 17: SOURCE-IDENTITY DRIFT — taskSourceId changes between snapshot and CAS.
# Revalidation of the SNAPSHOT id still passes (rc=0), but the CAS re-asserts
# the snapshot identity and must abort on 0 changed rows.
# ---------------------------------------------------------------------------
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,createdAt,taskSourceType,taskSourceId) VALUES('source:github_issues:owner/repo#9999','owner/repo',9999,'stale',1,datetime('now'),'github_issues','owner/repo#9999');"
OUTPUT=$(bash "$SCRIPT_DIR/task-recovery.sh" --retry-stale 'source:github_issues:owner/repo#9999' 2>&1) || true
STATUS=$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='source:github_issues:owner/repo#9999';")
assert_eq "Source-identity drift: row stays stale (CAS abort)" "stale" "$STATUS"
echo "$OUTPUT" | grep -qi "changed during revalidation" && pass "Source-identity drift CAS abort logged" || fail "Source-identity drift CAS abort logged"

echo ""
echo "All retry-stale tests passed."
