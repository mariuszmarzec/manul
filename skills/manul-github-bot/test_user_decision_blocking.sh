#!/usr/bin/bash
# Regression tests for Manul user-decision blocking/resume flow.
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
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs"

cat >"$CONFIG" <<'JSON'
{
  "automation": {
    "maxAttemptsBeforeFail": 3,
    "leaseTimeout": 900,
    "lockTtl": 1800
  }
}
JSON

FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/openclaw"
chmod +x "$FAKE_BIN/openclaw"

export MANUL_DIR DB CONFIG LOG LIFECYCLE_LOG PID_FILE MANUL_TESTING=true
# Production dispatch always provides TASK_ACTION; keep the isolated evaluator fixture explicit too.
TASK_ACTION="IMPLEMENT"
export TASK_ACTION
export PATH="$FAKE_BIN:$PATH"

set +e
source "$SCRIPT_DIR/manul-daemon.sh"
SOURCE_RC=$?
set -e
[ "$SOURCE_RC" -eq 0 ] || { echo "FAIL: daemon source rc=$SOURCE_RC"; exit 1; }
export PATH="$FAKE_BIN:$PATH"

sqlite3 "$DB" "
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  agent TEXT,
  prompt TEXT NOT NULL,
  context TEXT,
  resultSummary TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  action TEXT DEFAULT 'IMPLEMENT',
  prNumber INTEGER,
  prUrl TEXT
);
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER,
  issueUrl TEXT,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  status TEXT NOT NULL DEFAULT 'OPEN',
  activeTaskId TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE TABLE conversation_messages (
  messageId TEXT PRIMARY KEY,
  conversationId TEXT NOT NULL,
  commentId TEXT,
  repo TEXT,
  issueNumber INTEGER,
  author TEXT,
  body TEXT,
  commentUrl TEXT,
  createdAt TEXT,
  messageType TEXT
);
"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || { echo "FAIL: $label (expected=$expected actual=$actual)"; exit 1; }
  echo "PASS: $label"
}

echo "=== TASK_NEEDS_USER parsing ==="
STDOUT_FILE="$TEST_DIR/needs-user.stdout"
cat >"$STDOUT_FILE" <<'EOF'
TASK_NEEDS_USER_BEGIN
We have three materially different architecture choices.
I recommend option B because it matches the existing orchestration model.
Please choose A, B, or C.
TASK_NEEDS_USER_END
EOF

evaluate_task_completion   "owner/repo" "1" "issue:123" "issue:123" "1" "0"   "$STDOUT_FILE" "$DB" "" "" "" "" "" "main" "main"

assert_eq "needs-user flag set" "true" "$NEEDS_USER_INPUT"
assert_eq "question extracted"   $'We have three materially different architecture choices.
I recommend option B because it matches the existing orchestration model.
Please choose A, B, or C.'   "$USER_QUESTION"
assert_eq "needs-user is not success" "false" "$COMPLETION_SUCCESS"

echo "=== malformed user-decision blocks are rejected ==="
cat >"$STDOUT_FILE" <<'EOF'
TASK_NEEDS_USER_BEGIN
The decision is unclear.
EOF
evaluate_task_completion "owner/repo" "1" "issue:malformed" "issue:malformed" "1" "0" "$STDOUT_FILE" "$DB" "" "" "" "" "" "main" "main"
assert_eq "partial block is not user-blocked" "false" "$NEEDS_USER_INPUT"
assert_eq "partial block has explicit failure reason" "Malformed TASK_NEEDS_USER block" "$FAIL_REASON"

cat >"$STDOUT_FILE" <<'EOF'
TASK_NEEDS_USER_BEGIN
Choose the API shape before implementation.
TASK_NEEDS_USER_END
TASK_DONE
EOF
evaluate_task_completion "owner/repo" "1" "issue:conflict-done" "issue:conflict-done" "1" "0" "$STDOUT_FILE" "$DB" "" "" "" "" "" "main" "main"
assert_eq "decision block plus TASK_DONE is not user-blocked" "false" "$NEEDS_USER_INPUT"

cat >"$STDOUT_FILE" <<'EOF'
TASK_NEEDS_USER_BEGIN
Choose the API shape before implementation.
TASK_NEEDS_USER_END
TASK_FAILED: gave up
EOF
evaluate_task_completion "owner/repo" "1" "issue:conflict-failed" "issue:conflict-failed" "1" "0" "$STDOUT_FILE" "$DB" "" "" "" "" "" "main" "main"
assert_eq "decision block plus TASK_FAILED is not user-blocked" "false" "$NEEDS_USER_INPUT"

echo "=== running -> blocked_user ==="
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,prompt,status,attempts,claimToken,heartbeatAt,leaseExpiresAt,workerPid) VALUES('task-1','owner/repo',1,'https://github.com/owner/repo/issues/1','original prompt','running',1,'token-1',datetime('now'),datetime('now','+900 seconds'),1234);"
mark_task_blocked_user "task-1" "task-1" "token-1"
assert_eq "task becomes blocked_user" "blocked_user" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='task-1';")"
assert_eq "blocked task clears claim token" "" "$(sqlite3 "$DB" "SELECT coalesce(claimToken,'') FROM processed_comments WHERE commentId='task-1';")"
assert_eq "blocked task clears worker pid" "" "$(sqlite3 "$DB" "SELECT coalesce(workerPid,'') FROM processed_comments WHERE commentId='task-1';")"
assert_eq "blocked task clears lease" "" "$(sqlite3 "$DB" "SELECT coalesce(leaseExpiresAt,'') FROM processed_comments WHERE commentId='task-1';")"

QUESTION_CAPTURE="$TEST_DIR/question.txt"
post_github_comment() {
  printf '%s' "$3" >"$QUESTION_CAPTURE"
  return 0
}
sqlite3 "$DB" "UPDATE processed_comments SET conversationId='conv-1', attempts=1 WHERE commentId='task-1';"
post_task_needs_user_comment "owner/repo" "1" "task-1" "$USER_QUESTION"
assert_eq "question contains response instruction" "1" "$(grep -c '/manul continue' "$QUESTION_CAPTURE")"
assert_eq "question contains TASK_NEEDS_USER marker" "1" "$(grep -c 'TASK_NEEDS_USER' "$QUESTION_CAPTURE")"

echo "=== /manul continue parser ==="
EVENT_JSON="$("$SCRIPT_DIR/manul-github-events.sh" parse-comment --repo owner/repo --issue 1 --comment-id 900 --author mariuszmarzec --created 2026-09-23T20:00:00Z --body '/manul continue choose option B')"
assert_eq "continue action parsed" "CONTINUE" "$(printf '%s' "$EVENT_JSON" | jq -r '.command.action')"
assert_eq "continue answer parsed" "choose option B" "$(printf '%s' "$EVENT_JSON" | jq -r '.command.prompt')"

echo "=== blocked_user -> queued resume ==="
sqlite3 "$DB" "UPDATE processed_comments SET status='blocked_user', prompt='Original task', processedAt=datetime('now'), conversationId='conv-1' WHERE commentId='task-1';"
sqlite3 "$DB" "INSERT OR REPLACE INTO conversations(conversationId,repository,issueNumber,issueUrl,status,createdAt,updatedAt) VALUES('conv-1','owner/repo',1,'https://github.com/owner/repo/issues/1','COMPLETED','2026-09-23T19:00:00Z','2026-09-23T19:00:00Z');"

# poll.sh is safe to source: its main loop is guarded by BASH_SOURCE == $0.
source "$SCRIPT_DIR/poll.sh"

resume_blocked_user_task   "conv-1" "owner/repo" "1" "900" "mariuszmarzec"   "choose option B" "2026-09-23T20:00:00Z"   "https://github.com/owner/repo/issues/1#issuecomment-900"

assert_eq "blocked task resumes as queued" "queued" "$(sqlite3 "$DB" "SELECT status FROM processed_comments WHERE commentId='task-1';")"
assert_eq "resume appends clarification to prompt" "1" "$(sqlite3 "$DB" "SELECT prompt LIKE '%choose option B%' FROM processed_comments WHERE commentId='task-1';")"
assert_eq "resume stores clarification in context" "1" "$(sqlite3 "$DB" "SELECT context LIKE '%choose option B%' FROM processed_comments WHERE commentId='task-1';")"
assert_eq "conversation reopens" "OPEN" "$(sqlite3 "$DB" "SELECT status FROM conversations WHERE conversationId='conv-1';")"
assert_eq "user reply is conversation message" "1" "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversation_messages WHERE conversationId='conv-1' AND messageType='user-clarification';")"

echo "All user decision blocking tests passed."
