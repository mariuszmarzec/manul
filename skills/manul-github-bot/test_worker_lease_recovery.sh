#!/usr/bin/bash
# Focused regression tests for worker ownership, heartbeat/lease and recovery.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/logs/daemon.log"
LIFECYCLE_LOG="$MANUL_DIR/logs/lifecycle.log"
PID_FILE="$MANUL_DIR/state/locks/daemon.pid"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/logs"

cat >"$CONFIG" <<'JSON'
{
  "autoCreatePr": false,
  "automation": {
    "maxAttemptsBeforeFail": 3,
    "maxPreExecutionFailures": 2,
    "lockTtl": 1800,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900
  },
  "retryConfig": {
    "delaySeconds": 1
  }
}
JSON

export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG PID_FILE MANUL_TESTING=true
# The daemon resolves OPENCLAW_BIN from PATH while sourcing. This focused unit
# test never invokes OpenClaw, so provide a hermetic stub for that lookup.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
printf "#!/usr/bin/env bash\\nexit 0\\n" > "$FAKE_BIN/openclaw"
chmod +x "$FAKE_BIN/openclaw"
GH_LOG="$TEST_DIR/gh.log"
export GH_LOG
cat >"$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf 'COMMAND:%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "comment" ]; then
  exit 0
fi
exit 1
GH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"
# Source under a controlled errexit boundary so a future daemon initialization
# regression is reported in this test instead of terminating the shell silently.
set +e
source "$SCRIPT_DIR/manul-daemon.sh"
SOURCE_RC=$?
set -e
if [ "$SOURCE_RC" -ne 0 ]; then
  echo "FAIL: sourcing manul-daemon.sh returned rc=$SOURCE_RC" >&2
  cat "$LIFECYCLE_LOG" 2>/dev/null || true
  exit 1
fi
# manul-daemon.sh prepends its runtime PATH while sourcing, so restore the
# fake-bin precedence for the gh calls used by this hermetic test.
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
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  resultSummary TEXT,
  preExecutionFailures INTEGER NOT NULL DEFAULT 0,
  agentStartedAt TEXT
);
"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $label (expected=$expected actual=$actual)" >&2
    exit 1
  fi
  echo "PASS: $label"
}

REPO="owner/repo"
CURRENT_TEST_PID="$BASHPID"

# 0) The isolated task runner and descendants in a separate session must be
# terminated together. Also simulate the old stop path having deleted its PID
# file: recovery must rediscover the live runner from its task-specific argv.
EXECUTOR_PID_FILE="$MANUL_DIR/task-test-executor.executor.pid"
EXECUTOR_CTX_FILE="$MANUL_DIR/state/tasks/task-test-executor.ctx.json"
EXECUTOR_CHILD_PID_FILE="$MANUL_DIR/task-test-executor.child.pid"
FAKE_TASK_RUNNER="$TEST_DIR/agent-task-runner.sh"
mkdir -p "$MANUL_DIR/state/tasks"
touch "$EXECUTOR_CTX_FILE"
cat >"$FAKE_TASK_RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
ctx_file="$1"
pid_file="$2"
child_pid_file="$3"
printf '%s\n' "$BASHPID" >"$pid_file"
setsid --wait bash -c 'sleep 30' &
child_pid=$!
printf '%s\n' "$child_pid" >"$child_pid_file"
wait "$child_pid"
RUNNER
chmod +x "$FAKE_TASK_RUNNER"
rm -f "$EXECUTOR_PID_FILE" "$EXECUTOR_CHILD_PID_FILE"
setsid --wait "$FAKE_TASK_RUNNER" "$EXECUTOR_CTX_FILE" "$EXECUTOR_PID_FILE" "$EXECUTOR_CHILD_PID_FILE" &
EXECUTOR_LAUNCHER_PID=$!
for _ in {1..40}; do
  [ -s "$EXECUTOR_PID_FILE" ] && [ -s "$EXECUTOR_CHILD_PID_FILE" ] && break
  sleep 0.05
done
EXECUTOR_PID="$(cat "$EXECUTOR_PID_FILE" 2>/dev/null || true)"
EXECUTOR_CHILD_PID="$(cat "$EXECUTOR_CHILD_PID_FILE" 2>/dev/null || true)"
if ! [[ "$EXECUTOR_PID" =~ ^[0-9]+$ ]] || [ "$EXECUTOR_PID" -le 0 ] ||
   ! [[ "$EXECUTOR_CHILD_PID" =~ ^[0-9]+$ ]] || [ "$EXECUTOR_CHILD_PID" -le 0 ]; then
  echo "FAIL: isolated executor or detached child did not publish a valid PID" >&2
  kill "$EXECUTOR_LAUNCHER_PID" 2>/dev/null || true
  wait "$EXECUTOR_LAUNCHER_PID" 2>/dev/null || true
  exit 1
fi
if ! kill -0 "$EXECUTOR_PID" 2>/dev/null || ! kill -0 "$EXECUTOR_CHILD_PID" 2>/dev/null; then
  echo "FAIL: isolated executor tree exited before recovery test" >&2
  exit 1
fi
rm -f "$EXECUTOR_PID_FILE"
terminate_task_executor "test-executor"
wait "$EXECUTOR_LAUNCHER_PID" 2>/dev/null || true
if task_process_is_running "$EXECUTOR_PID" || task_process_is_running "$EXECUTOR_CHILD_PID"; then
  echo "FAIL: terminate_task_executor left an executor descendant alive" >&2
  kill -KILL "$EXECUTOR_CHILD_PID" "$EXECUTOR_PID" 2>/dev/null || true
  exit 1
fi
if [ -f "$EXECUTOR_PID_FILE" ]; then
  echo "FAIL: terminate_task_executor left PID file behind" >&2
  exit 1
fi
echo "PASS: executor recovery kills the runner tree, including a detached child, without a PID file"

# 0b) A queued task must not retain a detached executor after startup recovery.
QUEUED_EXECUTOR_PID_FILE="$MANUL_DIR/task-queued-orphan.executor.pid"
QUEUED_EXECUTOR_CTX="$MANUL_DIR/state/tasks/task-queued-orphan.ctx.json"
QUEUED_CHILD_PID_FILE="$MANUL_DIR/task-queued-orphan.child.pid"
touch "$QUEUED_EXECUTOR_CTX"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status) VALUES ('queued-orphan','$REPO',77,'https://github.com/$REPO/issues/77','queued');"
rm -f "$QUEUED_EXECUTOR_PID_FILE" "$QUEUED_CHILD_PID_FILE"
setsid --wait "$FAKE_TASK_RUNNER" "$QUEUED_EXECUTOR_CTX" "$QUEUED_EXECUTOR_PID_FILE" "$QUEUED_CHILD_PID_FILE" &
QUEUED_EXECUTOR_LAUNCHER_PID=$!
for _ in {1..40}; do
  [ -s "$QUEUED_EXECUTOR_PID_FILE" ] && [ -s "$QUEUED_CHILD_PID_FILE" ] && break
  sleep 0.05
done
QUEUED_EXECUTOR_PID="$(cat "$QUEUED_EXECUTOR_PID_FILE" 2>/dev/null || true)"
QUEUED_CHILD_PID="$(cat "$QUEUED_CHILD_PID_FILE" 2>/dev/null || true)"
if ! [[ "$QUEUED_EXECUTOR_PID" =~ ^[0-9]+$ ]] || ! [[ "$QUEUED_CHILD_PID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: queued orphan fixture did not start" >&2
  exit 1
fi
cleanup_orphaned_task_executors
wait "$QUEUED_EXECUTOR_LAUNCHER_PID" 2>/dev/null || true
if task_process_is_running "$QUEUED_EXECUTOR_PID" || task_process_is_running "$QUEUED_CHILD_PID"; then
  echo "FAIL: startup cleanup left an executor for a queued task alive" >&2
  kill -KILL "$QUEUED_CHILD_PID" "$QUEUED_EXECUTOR_PID" 2>/dev/null || true
  exit 1
fi
echo "PASS: startup cleanup terminates executors for queued tasks"

# 0c) The heartbeat is a long-lived background child and must not inherit the
# dispatcher flock, otherwise it can prevent a new worker from dispatching.
HEARTBEAT_LOCK_FILE="$MANUL_DIR/state/locks/task-dispatch.flock"
exec 210>"$HEARTBEAT_LOCK_FILE"
flock -n 210 || { echo "FAIL: could not acquire lock for heartbeat FD test" >&2; exit 1; }
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,workerPid,claimToken) VALUES ('heartbeat-fd-test','$REPO',78,'https://github.com/$REPO/issues/78','running',1,$CURRENT_TEST_PID,'heartbeat-fd-token');"
HEARTBEAT_INTERVAL=60
start_heartbeat "heartbeat-fd-test" "$CURRENT_TEST_PID" "heartbeat-fd-token"
HEARTBEAT_PID="${HEARTBEAT_PIDS[heartbeat-fd-test]:-}"
if ! [[ "$HEARTBEAT_PID" =~ ^[0-9]+$ ]] || [ "$HEARTBEAT_PID" -le 0 ] || ! kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
  echo "FAIL: heartbeat process did not start" >&2
  exit 1
fi
if [ -e "/proc/$HEARTBEAT_PID/fd/210" ]; then
  echo "FAIL: heartbeat inherited task-dispatch lock FD 210" >&2
  ls -l "/proc/$HEARTBEAT_PID/fd/210" >&2 || true
  stop_heartbeat "heartbeat-fd-test"
  exit 1
fi
if flock -n "$HEARTBEAT_LOCK_FILE" -c true 2>/dev/null; then
  echo "FAIL: parent lost dispatcher lock during heartbeat test" >&2
  stop_heartbeat "heartbeat-fd-test"
  exit 1
fi
stop_heartbeat "heartbeat-fd-test"
flock -u 210
exec 210>&-
echo "PASS: heartbeat does not inherit FD 210 and parent retains dispatcher lock"

# 0d) Startup cleanup must reap a legacy orphan heartbeat and all of its
# descendants when an earlier version inherited FD 210 into that process tree.
ORPHAN_LOCK_FILE="$MANUL_DIR/state/locks/task-dispatch.flock"
exec 210>"$ORPHAN_LOCK_FILE"
flock -n 210 || { echo "FAIL: could not acquire lock for orphan-heartbeat test" >&2; exit 1; }
ORPHAN_HEARTBEAT_PID_FILE="$MANUL_DIR/task-orphan-heartbeat.heartbeat.pid"
ORPHAN_HEARTBEAT_CHILD_FILE="$TEST_DIR/orphan-heartbeat-child.pid"
FAKE_HEARTBEAT_SCRIPT="$TEST_DIR/manul-daemon.sh"
cat >"$FAKE_HEARTBEAT_SCRIPT" <<'HEARTBEAT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$BASHPID" >"$2"
sleep 30 &
child_pid=$!
printf '%s\n' "$child_pid" >"$3"
wait "$child_pid"
HEARTBEAT
chmod +x "$FAKE_HEARTBEAT_SCRIPT"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts) VALUES ('orphan-heartbeat','$REPO',79,'https://github.com/$REPO/issues/79','queued',1);"
bash "$FAKE_HEARTBEAT_SCRIPT" loop "$ORPHAN_HEARTBEAT_PID_FILE" "$ORPHAN_HEARTBEAT_CHILD_FILE" &
ORPHAN_HEARTBEAT_LAUNCHER_PID=$!
for _ in {1..40}; do
  [ -s "$ORPHAN_HEARTBEAT_PID_FILE" ] && [ -s "$ORPHAN_HEARTBEAT_CHILD_FILE" ] && break
  sleep 0.05
done
ORPHAN_HEARTBEAT_PID="$(cat "$ORPHAN_HEARTBEAT_PID_FILE" 2>/dev/null || true)"
ORPHAN_HEARTBEAT_CHILD_PID="$(cat "$ORPHAN_HEARTBEAT_CHILD_FILE" 2>/dev/null || true)"
if ! [[ "$ORPHAN_HEARTBEAT_PID" =~ ^[0-9]+$ ]] || ! [[ "$ORPHAN_HEARTBEAT_CHILD_PID" =~ ^[0-9]+$ ]]; then
  echo "FAIL: orphan heartbeat test process tree did not start" >&2
  kill "$ORPHAN_HEARTBEAT_LAUNCHER_PID" 2>/dev/null || true
  wait "$ORPHAN_HEARTBEAT_LAUNCHER_PID" 2>/dev/null || true
  exit 1
fi
cleanup_orphaned_task_heartbeats
wait "$ORPHAN_HEARTBEAT_LAUNCHER_PID" 2>/dev/null || true
if task_process_is_running "$ORPHAN_HEARTBEAT_PID" || task_process_is_running "$ORPHAN_HEARTBEAT_CHILD_PID"; then
  echo "FAIL: orphan heartbeat cleanup left a process alive" >&2
  kill -KILL "$ORPHAN_HEARTBEAT_PID" "$ORPHAN_HEARTBEAT_CHILD_PID" 2>/dev/null || true
  exit 1
fi
if flock -n "$ORPHAN_LOCK_FILE" -c true 2>/dev/null; then
  echo "FAIL: orphan cleanup released the parent's dispatcher lock" >&2
  exit 1
fi
flock -u 210
exec 210>&-
echo "PASS: startup cleanup reaps orphan heartbeat trees without releasing another owner's lock"

# 1) Completion succeeds only for the worker owning the lease.
sqlite3 "$DB" "
INSERT INTO processed_comments VALUES
('owner','$REPO',1,'https://github.com/$REPO/issues/1','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),12345,'owner-token',NULL,NULL,0,NULL);
INSERT INTO processed_comments VALUES
('other','$REPO',2,'https://github.com/$REPO/issues/2','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),999999,'other-token',NULL,NULL,0,NULL);
"
update_task_completion owner completed "" owner-token
assert_eq completed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='owner';")" "owner can complete"
if update_task_completion other completed "" wrong-token; then
  echo "FAIL: non-owner completion unexpectedly succeeded" >&2
  exit 1
fi
echo "PASS: non-owner completion rejected"

# 2) Heartbeat refresh updates both heartbeatAt and leaseExpiresAt.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('123','$REPO',3,'https://github.com/$REPO/issues/3','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),123,'123-token',NULL,NULL,0,datetime('now'))"
HEARTBEAT_PIDS[123]=1
CURRENT_WORKER_PID=123
LEASE_TIMEOUT=900
refresh_heartbeat 123
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN heartbeatAt > datetime('now','-5 seconds') THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='123';")" "heartbeat timestamp refreshed"
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN leaseExpiresAt > datetime('now') THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='123';")" "lease expiry extended"

# 3) Dead worker + expired lease is requeued.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('dead','$REPO',4,'https://github.com/$REPO/issues/4','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),999999,'dead-token',NULL,NULL,0,datetime('now','-1 hour'))"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='dead';")" "dead worker task requeued"

# 3b) Dead worker + fresh lease is still recovered immediately.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('dead-fresh','$REPO',41,'https://github.com/$REPO/issues/41','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),999997,'dead-fresh-token',NULL,NULL,0,datetime('now'))"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='dead-fresh';")" "dead worker with fresh lease requeued"

# 3c) Live worker + fresh lease is left alone.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('live-fresh','$REPO',42,'https://github.com/$REPO/issues/42','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),$CURRENT_TEST_PID,'live-fresh-token',NULL,NULL,0,datetime('now'))"
recover_stale_tasks
assert_eq running "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live-fresh';")" "live worker with fresh lease preserved"

# 3c.1) ISO-8601 UTC timestamps must be parsed as dates, not compared as strings.
# The worker is alive, so recovery depends on recognizing its expired lease.
ISO_OLD="$(date -u -d '2 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"
ISO_EXPIRED="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('iso-stale-live','$REPO',421,'https://github.com/$REPO/issues/421','IMPLEMENT','running',1,'$ISO_OLD','$ISO_OLD','$ISO_EXPIRED',$CURRENT_TEST_PID,'iso-stale-live-token',NULL,NULL,0,'$ISO_OLD')"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='iso-stale-live';")" "live worker with expired ISO-format lease is recovered"

if ! grep -Fq "datetime(nextAttemptAt) <= datetime('now')" "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: dispatcher scheduler does not normalize nextAttemptAt before comparison" >&2
  exit 1
fi
if ! grep -Fq "datetime(heartbeatAt) < datetime('now', '-\${HEARTBEAT_TIMEOUT} seconds')" "$SCRIPT_DIR/watchdog.sh"; then
  echo "FAIL: watchdog does not normalize heartbeatAt before comparison" >&2
  exit 1
fi
if ! grep -Fq "datetime(leaseExpiresAt) < datetime('now')" "$SCRIPT_DIR/watchdog.sh"; then
  echo "FAIL: watchdog does not normalize leaseExpiresAt before comparison" >&2
  exit 1
fi
echo "PASS: scheduler and watchdog timestamp comparisons are normalized"

# 3d) Recovery does not report success when its conditional SQLite transition fails.
sqlite3 "$DB" "
INSERT INTO processed_comments VALUES ('recovery-race','$REPO',43,'https://github.com/$REPO/issues/43','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),999996,'recovery-race-token',NULL,NULL,0,datetime('now','-1 hour'));
CREATE TRIGGER reject_recovery_requeue
BEFORE UPDATE OF status ON processed_comments
WHEN OLD.commentId='recovery-race' AND NEW.status='queued'
BEGIN SELECT RAISE(ABORT, 'simulated conditional update failure'); END;
"
recover_stale_tasks
assert_eq running "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='recovery-race';")" "failed recovery update leaves task state unchanged"
if grep -q 'TASK_REQUEUED task=recovery-race ' "$LIFECYCLE_LOG" 2>/dev/null; then
  echo "FAIL: stale recovery logged TASK_REQUEUED despite a failed SQLite update" >&2
  exit 1
fi
grep -q 'task recovery-race was not requeued' "$LOG" \
  && echo "PASS: failed stale-recovery transition is explicitly logged" \
  || { echo "FAIL: failed stale-recovery transition was not logged" >&2; exit 1; }
sqlite3 "$DB" "DROP TRIGGER reject_recovery_requeue;"
echo "PASS: failed stale-recovery transition does not emit a false success event"

# 4) Live worker + expired lease is recovered; worker PID alone is not task ownership.
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('live','$REPO',5,'https://github.com/$REPO/issues/5','IMPLEMENT','running',1,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),1,'live-token',NULL,NULL,0,datetime('now','-1 hour'))"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live';")" "live worker task recovered by expired lease"
# Simulate the same long-lived worker claiming the retry with a new token. The old execution must not finalize it.
sqlite3 "$DB" "UPDATE processed_comments SET status='running', heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now','+900 seconds'), workerPid=1, claimToken='new-token', agentStartedAt=datetime('now') WHERE commentId='live';"
if update_task_completion live completed "" live-token; then
  echo "FAIL: stale claim unexpectedly finalized a newer execution" >&2
  exit 1
fi
assert_eq running "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live';")" "stale claim cannot finalize newer execution"
update_task_completion live completed "" new-token
assert_eq completed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='live';")" "current claim can finalize"

# 5) Max attempts on dead worker becomes failed.
: > "$GH_LOG"
sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('maxed','$REPO',6,'https://github.com/$REPO/issues/6','IMPLEMENT','running',3,datetime('now','-1 hour'),datetime('now','-1 hour'),datetime('now','-1 second'),999998,'maxed-token',NULL,NULL,0,datetime('now','-1 hour'))"
recover_stale_tasks
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='maxed';")" "max-attempt task failed"
if grep -q 'Task Failed' "$GH_LOG" && grep -q 'stale heartbeat/lease recovery' "$GH_LOG" && grep -q '\*\*Stage:\*\* stale_task_recovery' "$GH_LOG"; then
  echo "PASS: stale-lease terminal failure is posted to GitHub with its cause"
else
  echo "FAIL: stale-lease terminal failure comment missing or lacks its cause" >&2
  cat "$GH_LOG" >&2
  exit 1
fi

# 5a) An early failure below the retry limit must be requeued with nextAttemptAt,
# otherwise the scheduler's NULL comparison can strand the task forever.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,workerPid,claimToken) VALUES ('early-retry','$REPO',80,'https://github.com/$REPO/issues/80','running',1,$CURRENT_TEST_PID,'early-retry-token');"
handle_pre_execution_failure "early-retry" "early-retry-token" "$REPO" 80 "" "" "Workspace unavailable on first attempt." "" 1
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='early-retry';")" "pre-agent recoverable failure transitions to queued"
assert_eq 0 "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='early-retry';")" "pre-agent failure does not consume an agent execution attempt"
assert_eq 1 "$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='early-retry';")" "pre-agent failure increments separate infrastructure counter"
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN nextAttemptAt IS NOT NULL THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='early-retry';")" "pre-agent retry has nextAttemptAt"
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN nextAttemptAt >= datetime('now','-2 seconds') THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='early-retry';")" "pre-agent retry is scheduled"

# 5a.1) An adapter preflight failure after the dispatcher has bumped attempts
# must roll that bump back and use the separate infrastructure failure counter.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,preExecutionFailures,workerPid,claimToken,agentStartedAt) VALUES ('adapter-preflight','$REPO',801,'https://github.com/$REPO/issues/801','running',3,0,$CURRENT_TEST_PID,'adapter-preflight-token',datetime('now'));"
handle_pre_execution_failure "adapter-preflight" "adapter-preflight-token" "$REPO" 801 "" "" "Caracal MCP preflight failed before OpenCode task startup." "" 3 "caracal_mcp_preflight"
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='adapter-preflight';")" "adapter preflight failure is requeued"
assert_eq 2 "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='adapter-preflight';")" "adapter preflight failure rolls back the claimed agent attempt"
assert_eq 1 "$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='adapter-preflight';")" "adapter preflight failure consumes infrastructure budget only"
assert_eq 1 "$(sqlite3 "$DB" "SELECT CASE WHEN nextAttemptAt IS NOT NULL THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='adapter-preflight';")" "adapter preflight retry is scheduled"

# 5b) Early workspace failures use the same attempt limit and publish a final
# failure comment instead of leaving the task running for the watchdog to guess.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,preExecutionFailures,workerPid,claimToken) VALUES ('early-fail','$REPO',81,'https://github.com/$REPO/issues/81','running',3,1,$CURRENT_TEST_PID,'early-fail-token');"
handle_pre_execution_failure "early-fail" "early-fail-token" "$REPO" 81 "" "" "Workspace path is missing or failed ownership/path validation." "" 3 "workspace_path_validation"
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='early-fail';")" "pre-agent failure transitions to failed"
assert_eq 2 "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='early-fail';")" "pre-agent recovery removes the claim-time agent-attempt bump"
assert_eq 2 "$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='early-fail';")" "repeated infrastructure failure reaches separate infra budget"
if grep -q 'Workspace path is missing or failed ownership/path validation.' "$GH_LOG" && grep -q '\*\*Stage:\*\* workspace_path_validation' "$GH_LOG"; then
  echo "PASS: pre-agent terminal failure comment contains the concrete cause"
else
  echo "FAIL: pre-agent terminal failure comment missing the concrete cause" >&2
  cat "$GH_LOG" >&2
  exit 1
fi

# 5c) Primary-checkout preparation failures publish their own explicit stage.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,preExecutionFailures,workerPid,claimToken) VALUES ('checkout-fail','$REPO',82,'https://github.com/$REPO/issues/82','running',3,1,$CURRENT_TEST_PID,'checkout-fail-token');"
handle_pre_execution_failure "checkout-fail" "checkout-fail-token" "$REPO" 82 "" "" "Could not prepare the primary checkout for $REPO (rc=1). Existing workspace data was preserved." "" 3 "primary_checkout_preparation"
assert_eq failed "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='checkout-fail';")" "primary-checkout failure transitions to failed"
assert_eq 2 "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='checkout-fail';")" "checkout failure leaves the agent-attempt budget intact"
if grep -q 'Could not prepare the primary checkout for' "$GH_LOG" && grep -q '\*\*Stage:\*\* primary_checkout_preparation' "$GH_LOG"; then
  echo "PASS: primary-checkout failure comment includes stage and cause"
else
  echo "FAIL: primary-checkout failure comment missing stage/cause" >&2
  cat "$GH_LOG" >&2
  exit 1
fi

# 5d) Crash window between agentStartedAt and TASK_STARTED comment post must
# be classified as a genuine agent attempt, not a pre-execution failure.
# This prevents the duplicate-TASK_STARTED regression where recovery rolls back
# the attempt bump, requeues, and the retry reuses the same attempt number.
#
# Scenario: worker records agentStartedAt, then crashes before posting the
# in-progress comment. Recovery sees agentStartedAt set → preserves attempts.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,status,attempts,preExecutionFailures,workerPid,claimToken,agentStartedAt) VALUES ('crash-window','$REPO',83,'https://github.com/$REPO/issues/83','running',2,0,999999,'crash-window-token',datetime('now'));"
recover_stale_tasks
assert_eq queued "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='crash-window';")" "crash-window task requeued after agentStartedAt was set"
assert_eq 2 "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='crash-window';")" "crash-window preserves agent attempt count (no rollback)"
assert_eq 0 "$(sqlite3 "$DB" "SELECT preExecutionFailures FROM processed_comments WHERE commentId='crash-window';")" "crash-window does not inflate preExecutionFailures"
if grep -q 'TASK_REQUEUED task=crash-window' "$LIFECYCLE_LOG" 2>/dev/null; then
  echo "PASS: crash-window recovery emits TASK_REQUEUED (agent attempt, not pre-execution)"
else
  echo "FAIL: crash-window recovery did not emit TASK_REQUEUED" >&2
  exit 1
fi

# 5e) Double-crash-window: after requeue, next dispatch re-claims with
# attempts+1 (not attempts-1). The attempt budget must not be double-counted.
sqlite3 "$DB" "UPDATE processed_comments SET status='queued', workerPid=NULL, claimToken=NULL, leaseExpiresAt=NULL, heartbeatAt=NULL, nextAttemptAt=NULL WHERE commentId='crash-window';"
# Simulate claim: the dispatcher bumps attempts on claim
sqlite3 "$DB" "UPDATE processed_comments SET status='running', attempts=attempts+1, processedAt=datetime('now'), heartbeatAt=datetime('now'), leaseExpiresAt=datetime('now','+900 seconds'), workerPid=$CURRENT_TEST_PID, claimToken='crash-window-reclaim-token', agentStartedAt=NULL WHERE commentId='crash-window' AND status='queued';"
assert_eq 3 "$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='crash-window';")" "re-claim after crash-window adds attempt normally"
# 6) PR verification rejects a missing PR and accepts a real PR.
WORKTREE="$TEST_DIR/repo"
mkdir -p "$WORKTREE"
git -C "$WORKTREE" init -q
git -C "$WORKTREE" config user.email test@example.com
git -C "$WORKTREE" config user.name test
printf 'test\n' >"$WORKTREE/README.md"
git -C "$WORKTREE" add README.md
git -C "$WORKTREE" commit -qm initial
git -C "$WORKTREE" checkout -qb manul-task-test

sqlite3 "$DB" "INSERT INTO processed_comments VALUES ('pr','$REPO',7,'https://github.com/$REPO/issues/7','IMPLEMENT','running',1,datetime('now'),datetime('now'),datetime('now','+900 seconds'),12345,'pr-token',NULL,NULL,0,NULL);"

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$*" == *"pr list"* ]]; then
  if [ "${FAKE_PR_EXISTS:-0}" = "1" ]; then
    printf '[{"number":123,"url":"https://github.com/example/repo/pull/123","state":"OPEN","baseRefName":"master","headRefName":"manul-task-test"}]\n'
  else
    printf '[]\n'
  fi
  exit 0
fi
exit 1
GH
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"
GH_API_TIMEOUT=2

if verify_required_pr "$REPO" pr "$WORKTREE" master; then
  echo "FAIL: missing PR was accepted" >&2
  exit 1
fi
echo "PASS: missing PR rejected"

export FAKE_PR_EXISTS=1
verify_required_pr "$REPO" pr "$WORKTREE" master
echo "PASS: real PR accepted"


# 7) Task dispatcher lock is resilient to the historical self-referential stale lock.
# Simulate the exact failure: a legacy .daemon-lock survives a stop/restart while
# daemon.pid contains the CURRENT process PID. The flock implementation must
# ignore the legacy directory and acquire successfully.
TASK_LOCK_DIR="$MANUL_DIR/.daemon-lock"
TASK_LOCK_FILE="$MANUL_DIR/task-dispatch.flock"
mkdir -p "$TASK_LOCK_DIR"
printf '%s\n' "$CURRENT_TEST_PID" >"$PID_FILE"
TASK_LOCK_FD=210

if ! acquire_task_lock; then
  echo "FAIL: task lock acquisition was blocked by a legacy stale .daemon-lock" >&2
  exit 1
fi
if ! flock -n 210; then
  echo "FAIL: task lock was not actually held after acquire_task_lock" >&2
  exit 1
fi
release_task_lock

# Release must make the lock immediately acquirable again.
if ! acquire_task_lock; then
  echo "FAIL: task lock could not be reacquired after release" >&2
  exit 1
fi
release_task_lock

if [ -d "$TASK_LOCK_DIR" ]; then
  echo "FAIL: legacy .daemon-lock directory was not cleaned during release" >&2
  exit 1
fi
echo "PASS: stale legacy .daemon-lock cannot self-deadlock the dispatcher"

# 7b) The supervisor lifetime lock rejects a second owner and is acquired
# before daemon.pid is published; worker processes must not inherit the lock.
echo ""
echo "=== Test 7b: daemon supervisor is a singleton ==="
OWNER_LOCK_FILE="$MANUL_DIR/state/locks/daemon-owner.flock"
mkdir -p "$(dirname "$OWNER_LOCK_FILE")"
if ! grep -Fq 'exec 220>"$DAEMON_OWNER_LOCK_FILE"' "$SCRIPT_DIR/manul-daemon.sh" \
  || ! grep -Fq 'if ! flock -n 220;' "$SCRIPT_DIR/manul-daemon.sh" \
  || ! grep -Fq '220>&-' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon startup is missing lifetime ownership or worker lock isolation" >&2
  exit 1
fi
exec 230>"$OWNER_LOCK_FILE"
flock -n 230 || { echo "FAIL: test could not acquire daemon owner lock" >&2; exit 1; }
if ( exec 231>"$OWNER_LOCK_FILE"; flock -n 231 ) 2>/dev/null; then
  echo "FAIL: a second supervisor could acquire the lifetime lock" >&2
  exit 1
fi
flock -u 230
exec 230>&-
if ! ( exec 231>"$OWNER_LOCK_FILE"; flock -n 231 ); then
  echo "FAIL: owner lock stayed unavailable after the owner released it" >&2
  exit 1
fi
echo "PASS: daemon lifetime lock prevents overlapping supervisors"

# 8) A worker started by an older daemon must exit rather than join a new pool.
loop --worker=orphan-regression --parent-pid=2147483647
grep -q 'worker startup aborted: owning daemon is not alive' "$LOG" \
  && echo "PASS: orphan worker refuses to start without its owning daemon" \
  || { echo "FAIL: orphan worker startup was not rejected" >&2; exit 1; }

# 8b) CI-fix task IDs contain the owner/repository slash, but filesystem paths
# must remain flat and recovery must recover the exact original ID from SQLite.
echo ""
echo "=== Test 8b: CI-fix task artifact paths are flat and recoverable ==="
CI_TASK_ID="ci_fix:mariuszmarzec/fiteoApp:14:40488568269"
CI_TASK_KEY="$(manul_task_file_key "$CI_TASK_ID")"
CI_TASK_HASH="$(printf '%s' "$CI_TASK_ID" | sha256sum | cut -c1-16)"
assert_eq "ci_fix:mariuszmarzec_fiteoApp:14:40488568269--$CI_TASK_HASH" "$CI_TASK_KEY" "CI task path key flattens repository slash and remains unique"
assert_eq "issue:123" "$(manul_task_file_key "issue:123")" "existing single-component task IDs keep their legacy path key"

CI_PROMPT_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$CI_TASK_ID" "md")"
CI_STDOUT_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$CI_TASK_ID" "stdout")"
CI_STDERR_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$CI_TASK_ID" "stderr")"
CI_CTX_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$CI_TASK_ID" "ctx.json")"
CI_RESULT_FILE="$(manul_task_file_path "$MANUL_TASKS_DIR" "$CI_TASK_ID" "executor-result")"
CI_EXECUTOR_PID_FILE="$(manul_task_file_path "$MANUL_DIR" "$CI_TASK_ID" "executor.pid")"
CI_HEARTBEAT_PID_FILE="$(manul_task_file_path "$MANUL_DIR" "$CI_TASK_ID" "heartbeat.pid")"

for artifact_path in "$CI_PROMPT_FILE" "$CI_STDOUT_FILE" "$CI_STDERR_FILE" "$CI_CTX_FILE" "$CI_RESULT_FILE"; do
  assert_eq "$MANUL_TASKS_DIR" "$(dirname "$artifact_path")" "task artifact path has no task-ID-created nested directory"
done
assert_eq "$MANUL_DIR" "$(dirname "$CI_EXECUTOR_PID_FILE")" "executor PID path stays flat under MANUL_DIR"
assert_eq "$MANUL_DIR" "$(dirname "$CI_HEARTBEAT_PID_FILE")" "heartbeat PID path stays flat under MANUL_DIR"
assert_eq "$MANUL_TASKS_DIR/task-$CI_TASK_KEY.ctx.json" "$CI_CTX_FILE" "context path uses the canonical task key"
assert_eq "$MANUL_DIR/task-$CI_TASK_KEY.executor.pid" "$CI_EXECUTOR_PID_FILE" "executor PID path uses the same canonical task key"
assert_eq "$MANUL_DIR/task-$CI_TASK_KEY.heartbeat.pid" "$CI_HEARTBEAT_PID_FILE" "heartbeat PID path uses the same canonical task key"

sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,action,status,attempts) VALUES('$CI_TASK_ID','mariuszmarzec/fiteoApp',14,'https://github.com/mariuszmarzec/fiteoApp/pull/14','IMPLEMENT','failed',3);"
printf '%s\n' '{}' >"$CI_CTX_FILE"
printf '%s\n' "$CURRENT_TEST_PID" >"$CI_EXECUTOR_PID_FILE"
assert_eq "$CI_TASK_ID" "$(task_id_from_file_key "$CI_TASK_KEY")" "safe filename maps back to original database task ID"
if list_task_executor_ids | grep -Fxq "$CI_TASK_ID"; then
  echo "PASS: orphan-executor enumeration preserves the original CI task ID"
else
  echo "FAIL: orphan-executor enumeration lost the original CI task ID" >&2
  list_task_executor_ids >&2
  exit 1
fi

echo "All focused worker lifecycle tests passed."
exit 0
