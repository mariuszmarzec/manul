#!/usr/bin/env bash
# Regression coverage for the dispatcher lock lifetime.
# The global lock must serialize claim/workspace preparation, but must not be
# held while an isolated task executor is running.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export DB="$MANUL_DIR/manul.db"
export CONFIG="$MANUL_DIR/config.json"
export LOG="$TEST_DIR/daemon.log"
export LIFECYCLE_LOG="$TEST_DIR/lifecycle.log"
export PID_FILE="$MANUL_DIR/daemon.pid"
export MANUL_TESTING=true
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/logs"

cat >"$CONFIG" <<'JSON'
{
  "automation": {
    "maxConcurrentTasks": 2,
    "heartbeatTimeout": 900,
    "leaseTimeout": 900,
    "lockTtl": 1800
  }
}
JSON

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/openclaw" <<'OPENCLAW'
#!/usr/bin/env bash
exit 0
OPENCLAW
chmod +x "$FAKE_BIN/openclaw"
export PATH="$FAKE_BIN:$PATH"

# Load the production lock helpers with an isolated temporary runtime.
source "$SCRIPT_DIR/manul-daemon.sh"
[ "${MANUL_TESTING:-false}" = "true" ] || { echo "FAIL: daemon source did not remain in test mode" >&2; exit 1; }
TASK_LOCK_FILE="$TEST_DIR/task-dispatch.flock"
MANUL_TASK_LOCK_TIMEOUT_SECONDS=5

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

wait_for_file() {
  local file="$1"
  for _ in {1..200}; do
    [ -f "$file" ] && return 0
    sleep 0.025
  done
  fail "timed out waiting for $file"
}

# Static ordering guard: the real dispatcher must retain the global lock
# through shared repo-cache preparation, then release it before SDD/runtime.
positions="$(
  awk '
    /^dispatch_once\(\)/ { in_dispatch=1 }
    in_dispatch && index($0, "release_task_repo_lock \"$REPO\"") > 0 {
      repo_release=NR
      dispatcher_release=0
    }
    in_dispatch && repo_release > 0 && dispatcher_release == 0 &&
      index($0, "release_task_lock") > 0 { dispatcher_release=NR }
    in_dispatch && index($0, "# Apply repository-level SDD policy") > 0 { sdd=NR; exit }
    END { printf "%d %d %d\n", repo_release, dispatcher_release, sdd }
  ' "$SCRIPT_DIR/manul-daemon.sh"
)"
read -r repo_release dispatcher_release sdd_gate <<<"$positions"
[[ "$repo_release" =~ ^[1-9][0-9]*$ ]] || fail "repo-cache lock release not found in dispatch_once"
[[ "$dispatcher_release" =~ ^[1-9][0-9]*$ ]] || fail "dispatcher lock release not found after repo-cache release"
[[ "$sdd_gate" =~ ^[1-9][0-9]*$ ]] || fail "SDD gate not found in dispatch_once"
(( repo_release < dispatcher_release && dispatcher_release < sdd_gate )) ||
  fail "lock release order is unsafe (repo=$repo_release dispatcher=$dispatcher_release sdd=$sdd_gate)"

if ! sed -n "${dispatcher_release}p" "$SCRIPT_DIR/manul-daemon.sh" | grep -q 'release_task_lock'; then
  fail "expected dispatcher lock release at line $dispatcher_release"
fi
if ! sed -n "${dispatcher_release},${sdd_gate}p" "$SCRIPT_DIR/manul-daemon.sh" | grep -q 'DISPATCH_LOCK_RELEASED'; then
  fail "missing structured dispatcher-lock release event"
fi
echo "PASS: dispatcher lock is released after isolated workspace preparation and before SDD"

# Behavioral contract: Worker 2 must wait while Worker 1 is preparing a
# workspace, then must acquire the same global lock while Worker 1's long-lived
# fake executor is still running.
LOCK_HELD="$TEST_DIR/worker-1-lock-held"
RUNTIME_PID_FILE="$TEST_DIR/worker-1-runtime.pid"
WORKER_2_ACQUIRED="$TEST_DIR/worker-2-acquired"
OVERLAP_CONFIRMED="$TEST_DIR/overlap-confirmed"
REUSED_FD="$TEST_DIR/reused-fd"
IDEMPOTENT_RELEASE_CONFIRMED="$TEST_DIR/idempotent-release-confirmed"

(
  acquire_task_lock
  : >"$LOCK_HELD"
  sleep 0.8
  release_task_lock

  # Simulate a later cleanup path calling release_task_lock() after another
  # operation has reused FD 210. The helper must not close that unrelated FD.
  exec 210>"$REUSED_FD"
  release_task_lock
  if [ "$(readlink "/proc/$BASHPID/fd/210" 2>/dev/null || true)" = "$REUSED_FD" ]; then
    : >"$IDEMPOTENT_RELEASE_CONFIRMED"
  fi
  exec 210>&-

  sleep 3 &
  runtime_pid=$!
  printf '%s\n' "$runtime_pid" >"$RUNTIME_PID_FILE"
  wait "$runtime_pid"
) &
worker_1_pid=$!

(
  wait_for_file "$LOCK_HELD"
  sleep 0.15
  acquire_task_lock
  : >"$WORKER_2_ACQUIRED"
  wait_for_file "$RUNTIME_PID_FILE"
  runtime_pid="$(cat "$RUNTIME_PID_FILE")"
  if kill -0 "$runtime_pid" 2>/dev/null; then
    : >"$OVERLAP_CONFIRMED"
  fi
  release_task_lock
) &
worker_2_pid=$!

wait_for_file "$LOCK_HELD"
sleep 0.3
[ ! -e "$WORKER_2_ACQUIRED" ] || fail "second worker entered while first worker still held the preparation lock"

wait "$worker_2_pid" || fail "second worker could not acquire dispatcher lock"
[ -e "$OVERLAP_CONFIRMED" ] || fail "second worker did not acquire the lock while the first executor was running"
wait "$worker_1_pid" || fail "first worker did not finish its fake executor"
[ -e "$IDEMPOTENT_RELEASE_CONFIRMED" ] || fail "a repeated release closed an unrelated descriptor reused as FD 210"

echo "PASS: two workers can overlap execution without overlapping the claim/preparation critical section"
echo "PASS: repeated lock release is a no-op after this worker has relinquished ownership"
