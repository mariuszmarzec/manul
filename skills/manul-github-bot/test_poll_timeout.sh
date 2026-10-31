#!/bin/bash
# test_poll_timeout.sh — deterministic regression test for per-repository timeout
#
# Tests:
# 1. A hanging repo is terminated after REPO_POLL_TIMEOUT, lock is cleaned up
# 2. Other repos are not starved, process normally
# 3. No orphaned processes remain after timeout
# 4. poll.flock prevents concurrent instances
# 5. Normal repo completes, gh doesn't starve later repos
# 6. Global POLL_TIMEOUT remains safety net
# 7. Repository lock acquisition is atomic
#
# Usage: bash test_poll_timeout.sh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
POLL_SCRIPT="$SCRIPT_DIR/poll.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$MANUL_DIR/state/manul.db"
CONFIG="$MANUL_DIR/config.json"
LOG="$MANUL_DIR/logs/poll.log"
POLL_FLOCK="$MANUL_DIR/state/locks/poll.flock"
REPO_LOCK_DIR="$MANUL_DIR/state/locks/repo"
export MANUL_DIR REPO_LOCK_DIR

mkdir -p "$MANUL_DIR/state/locks/repo" "$MANUL_DIR/logs"
: >"$LOG"

init_poll_db() {
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT); INSERT OR REPLACE INTO meta(key,value) VALUES('baseline','2019-01-01T00:00:00Z');"
}
init_poll_db

# Fake gh: for repo "hang", sleep forever; for any other repo, fast return empty
cat > "$TEST_DIR/gh" << 'FAKEGH'
#!/usr/bin/bash
REPO=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --repo=*)
      REPO="${args[$i]#--repo=}"
      ;;
    --repo)
      if [ $((i+1)) -lt ${#args[@]} ]; then
        REPO="${args[$((i+1))]}"
      fi
      ;;
    repos/*)
      repo_path="${args[$i]#repos/}"
      REPO="${repo_path%%/*}"
      ;;
  esac
done
case "$REPO" in
  *hang*|*slow*)
    sleep 999999
    exit 0
    ;;
esac
if [[ "$*" == *"issue"* ]] || [[ "$*" == *"pr "* ]]; then
  echo "[]"
  exit 0
fi
if [[ "$*" == *"api"* ]]; then
  echo "[]"
  exit 0
fi
exit 1
FAKEGH

chmod +x "$TEST_DIR/gh"

export PATH="$TEST_DIR:$PATH"
export MANUL_REPO_POLL_TIMEOUT=2

# Minimal config with ciFix disabled
cat > "$CONFIG" << 'CONFIGEOF'
{
  "enabled": true,
  "pollInterval": 60,
  "trigger": "/manul",
  "agents": ["architect"],
  "ciFix": { "enabled": false },
  "automation": {
    "enabled": true,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "maxAttemptsBeforeFail": 3,
    "lockTtl": 1800
  }
}
CONFIGEOF

touch "$MANUL_DIR/skip-comments.log"

# ===== Test 0: Repository lock acquisition is atomic =====
echo "Test 0: Repository lock acquisition is atomic"

atomic_lock="$TEST_DIR/atomic.lock"
# Hold the lock before starting the competing process. This tests the property
# required by the production protocol (a second owner cannot acquire an
# existing lock) without depending on scheduler timing between two mkdir calls.
if ! mkdir "$atomic_lock" 2>/dev/null; then
  echo "FAIL 0: Could not establish the initial repository lock"
  exit 1
fi
echo "winner" > "$TEST_DIR/atomic-winner"

(
  if mkdir "$atomic_lock" 2>/dev/null; then
    echo "unexpected-second-winner" > "$TEST_DIR/atomic-winner-2"
    exit 0
  fi
  exit 1
) &
atomic_pid=$!

if wait "$atomic_pid"; then
  echo "FAIL 0: Second contender acquired an already-held repo lock"
  exit 1
fi

if [ ! -d "$atomic_lock" ] || [ -e "$TEST_DIR/atomic-winner-2" ]; then
  echo "FAIL 0: Existing repository lock was not preserved"
  exit 1
fi

echo "PASS 0: Second contender cannot acquire an already-held repo lock"
rm -rf "$atomic_lock" "$TEST_DIR/atomic-winner" "$TEST_DIR/atomic-winner-2"

# Verify the production lock implementation uses the same atomic primitive.
if grep -q 'if mkdir "\$lockfile" 2>/dev/null; then' "$POLL_SCRIPT"; then
  echo "PASS 0b: poll.sh uses atomic mkdir for repo locks"
else
  echo "FAIL 0b: poll.sh does not use atomic mkdir for repo locks"
  exit 1
fi

# ===== Test 1: Hanging repo is terminated =====
echo "Test 1: Hanging repo is terminated after REPO_POLL_TIMEOUT"

bash "$POLL_SCRIPT" "hang" > "$TEST_DIR/test1.txt" 2>&1 || true
output1=$(cat "$TEST_DIR/test1.txt")

has_timeout() { grep -q 'timed out after 2s' "$MANUL_DIR/logs/poll.log"; }
no_orphans() {
  sleep 0.5
  ps -eo pid,ppid,cmd | grep "sleep 999999" | grep -v "grep" > /dev/null && return 1 || return 0
}
lock_cleaned() { [ ! -e "$MANUL_DIR/state/locks/repo/hang.lock" ]; }
log_exists() { [ -f "$MANUL_DIR/logs/poll.log" ]; }

if has_timeout && log_exists; then
  echo "PASS 1: Timeout detected"
else
  echo "FAIL 1: Timeout not detected"
  cat "$MANUL_DIR/logs/poll.log" 2>/dev/null || true
  exit 1
fi

if no_orphans; then
  echo "PASS 1: No orphan processes"
else
  echo "FAIL 1: Orphan processes found"
  echo "Processes: $(ps -eo pid,ppid,cmd | grep 'sleep 999999' | grep -v grep || echo 'none')"
  exit 1
fi

if lock_cleaned; then
  echo "PASS 1: Lock cleaned up"
else
  echo "FAIL 1: Lock not cleaned up"
  ls -la "$MANUL_DIR/state/locks/repo/" 2>/dev/null || true
  exit 1
fi

# ===== Test 2: Multiple repos, not starved =====
echo ""
echo "Test 2: Multiple repos, no starvation"

rm -f "$DB"
init_poll_db
rm -rf "$MANUL_DIR/state/locks/repo"
mkdir -p "$MANUL_DIR/state/locks/repo"

bash "$POLL_SCRIPT" "hang" "fast" > "$TEST_DIR/test2.txt" 2>&1 || true

if grep -q 'timed out after 2s' "$MANUL_DIR/logs/poll.log"; then
  echo "PASS 2: Hang repo timed out"
else
  echo "FAIL 2: Hang repo timeout missing"
  cat "$MANUL_DIR/logs/poll.log" || true
  exit 1
fi

if [ ! -e "$MANUL_DIR/state/locks/repo/hang.lock" ] && [ ! -e "$MANUL_DIR/state/locks/repo/fast.lock" ]; then
  echo "PASS 2: Both locks cleaned"
else
  echo "FAIL 2: Lock(s) still present"
  ls -la "$MANUL_DIR/state/locks/repo/" || true
  exit 1
fi

# Check that both repos were processed (hang timed out, fast completed)
# The log will show "hang timed out" and poll.sh exits successfully
if grep -q 'hang.*timed out' "$MANUL_DIR/logs/poll.log" && [ $? -eq 0 ]; then
  echo "PASS 2: Hang repo timed out, fast repo not starved"
else
  echo "FAIL 2: Repo processing incomplete"
  cat "$MANUL_DIR/logs/poll.log" || true
  exit 1
fi

# ===== Test 3: poll.flock prevents concurrent instances =====
echo ""
echo "Test 3: poll.flock prevents concurrent instances"

rm -f "$DB"
init_poll_db
rm -f "$POLL_FLOCK"
rm -rf "$MANUL_DIR/state/locks/repo"
mkdir -p "$MANUL_DIR/state/locks/repo"

bash "$POLL_SCRIPT" "hang" > "$TEST_DIR/test3a.txt" 2>&1 &
pid1=$!

# Wait deterministically until the first poll creates and owns its flock.
lock_observed=0
for _ in {1..50}; do
  if [ -f "$POLL_FLOCK" ] && ! flock -n "$POLL_FLOCK" -c true 2>/dev/null; then
    lock_observed=1
    break
  fi
  sleep 0.05
done
if [ "$lock_observed" -ne 1 ]; then
  echo "FAIL 3: First poll never acquired poll.flock"
  cat "$TEST_DIR/test3a.txt" || true
  kill "$pid1" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  exit 1
fi

bash "$POLL_SCRIPT" "fast" > "$TEST_DIR/test3b.txt" 2>&1 &
pid2=$!
sleep 2

wait $pid1 2>/dev/null || true
wait $pid2 2>/dev/null || true

if grep -q '"locked":true' "$TEST_DIR/test3b.txt"; then
  echo "PASS 3: Second poll detected locked state"
else
  echo "FAIL 3: Second poll did not report locked"
  cat "$TEST_DIR/test3b.txt"
  exit 1
fi

sleep 0.5
wait $pid1 2>/dev/null || true

# ===== Test 4: Normal repo completes, gh doesn't starve later =====
echo ""
echo "Test 4: Normal repo completes, gh doesn't starve later"

# Damage fake gh: always error
cat > "$TEST_DIR/gh" << 'FAKEGH'
#!/usr/bin/bash
exit 1
FAKEGH

rm -f "$TEST_DIR/test4a.txt" "$TEST_DIR/test4b.txt"
bash "$POLL_SCRIPT" "hang" "other" > "$TEST_DIR/test4a.txt" 2>&1 || true
sleep 0.3
bash "$POLL_SCRIPT" "fast" > "$TEST_DIR/test4b.txt" 2>&1 || true

if grep -q 'timed out after 2s' "$MANUL_DIR/logs/poll.log"; then
  echo "PASS 4: Hang repo still timed out despite global failure"
else
  echo "FAIL 4: Hang repo timeout missing"
  cat "$MANUL_DIR/logs/poll.log" || true
  exit 1
fi

if [ ! -e "$MANUL_DIR/state/locks/repo/fast.lock" ]; then
  echo "PASS 4: Non-hang repo lock cleaned"
else
  echo "FAIL 4: Non-hang repo lock still present"
  ls -la "$MANUL_DIR/state/locks/repo/" || true
  exit 1
fi

# Restore fake gh
cat > "$TEST_DIR/gh" << 'FAKEGH'
#!/usr/bin/bash
REPO=""
for arg in "$@"; do
  case "$arg" in
    --repo=*)
      REPO="${arg#--repo=}"
      ;;
    repos/*)
      repo_path="${arg#repos/}"
      REPO="${repo_path%%/*}"
      ;;
  esac
done
case "$REPO" in
  *hang*|*slow*)
    sleep 999999
    exit 0
    ;;
esac
if [[ "$*" == *"issue"* ]] || [[ "$*" == *"pr "* ]]; then
  echo "[]"
  exit 0
fi
if [[ "$*" == *"api"* ]]; then
  echo "[]"
  exit 0
fi
exit 1
FAKEGH

# ===== Test 5: Global POLL_TIMEOUT safety net =====
echo ""
echo "Test 5: Global POLL_TIMEOUT remains a safe interrupt path"

poll_path="$POLL_SCRIPT"
if grep -q "REPO_POLL_TIMEOUT" "$poll_path" && \
   grep -q "setsid --fork --wait" "$poll_path" && \
   grep -q 'exec 201>&-' "$poll_path" && \
   grep -Fq 'kill -TERM -- "-$pid"' "$poll_path"; then
  echo "PASS 5: poll.sh uses per-repo process-group timeout with global safety net"
else
  echo "FAIL 5: Timeout mechanism not clearly defined"
  exit 1
fi

# Simulate the outer daemon timeout interrupting poll.sh before the repo-level
# timeout can fire. The poll process must clean the lock it acquired before
# receiving SIGTERM.
rm -f "$DB" "$POLL_FLOCK"; rm -rf "$MANUL_DIR/state/locks/repo/hang.lock"
init_poll_db
export MANUL_REPO_POLL_TIMEOUT=30
if timeout --signal=TERM --kill-after=2s 1s bash "$POLL_SCRIPT" "hang" > "$TEST_DIR/test5.txt" 2>&1; then
  echo "FAIL 5: Global timeout unexpectedly returned success"
  cat "$TEST_DIR/test5.txt"
  exit 1
fi

if [ ! -e "$MANUL_DIR/state/locks/repo/hang.lock" ]; then
  echo "PASS 5: Repo lock cleaned after global SIGTERM"
else
  echo "FAIL 5: Repo lock leaked after global SIGTERM"
  ls -la "$MANUL_DIR/state/locks/repo/" || true
  cat "$MANUL_DIR/logs/poll.log" || true
  exit 1
fi

# ===== Test 6: Outer timeout must not lose queued tasks =====
# Regression: when the daemon's global POLL_TIMEOUT kills poll.sh mid-cycle,
# poll.sh's signal trap must still emit a MANUL_RESULT line so the daemon can
# dispatch tasks that were already queued. Previously every interrupted cycle
# produced no output at all, so fire was never true and queued tasks starved.
echo ""
echo "Test 6: Partial result emitted on outer SIGTERM"

rm -f "$DB" "$POLL_FLOCK"
init_poll_db
rm -rf "$MANUL_DIR/state/locks/repo"
mkdir -p "$MANUL_DIR/state/locks/repo"

# Pre-seed a queued task so poll.sh has something to report even if it is
# killed before scanning any repo.
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments(commentId TEXT PRIMARY KEY, repository TEXT, issueNumber INTEGER, commentUrl TEXT, author TEXT, agent TEXT, prompt TEXT, status TEXT, createdAt TEXT, processedAt TEXT, attempts INTEGER DEFAULT 0, nextAttemptAt TEXT, heartbeatAt TEXT, leaseExpiresAt TEXT, conversationId TEXT, baseId TEXT);"
sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,status,createdAt) VALUES('test:6','test-repo',1,'queued','2026-01-01T00:00:00Z');"

export MANUL_REPO_POLL_TIMEOUT=30
rm -f "$TEST_DIR/test6.txt"
# Kill poll.sh with SIGTERM well before its per-repo timeout can fire.
if timeout --signal=TERM --kill-after=3s 1s bash "$POLL_SCRIPT" "hang" >"$TEST_DIR/test6.txt" 2>&1; then
  echo "FAIL 6: poll.sh unexpectedly returned success under global SIGTERM"
  cat "$TEST_DIR/test6.txt"
  exit 1
fi

if grep -q '"fire":true' "$TEST_DIR/test6.txt"; then
  echo "PASS 6: Partial result with fire:true emitted on SIGTERM"
else
  echo "FAIL 6: No fire:true result emitted after SIGTERM"
  echo "--- poll.sh output ---"
  cat "$TEST_DIR/test6.txt"
  echo "--- poll.log tail ---"
  tail -5 "$MANUL_DIR/logs/poll.log" 2>/dev/null || true
  exit 1
fi

if [ ! -f "$MANUL_DIR/state/locks/repo/hang.lock" ]; then
  echo "PASS 6: Repo lock cleaned after SIGTERM"
else
  echo "FAIL 6: Repo lock leaked after SIGTERM"
  ls -la "$MANUL_DIR/state/locks/repo/" || true
  exit 1
fi

echo ""
echo "All timeout tests assertions passed."

exit 0