#!/bin/bash
# Regression test for the "unresolved <GITHUB_LOGIN> placeholder blocks all polling"
# bug.
#
# Root cause: config.json.example ships `"allowedUsers": ["<GITHUB_LOGIN>"]`.
# The installer copies config.json.example -> config.json but never substitutes
# the placeholder with the real GitHub login. poll.sh then used the literal
# string "<GITHUB_LOGIN>" as the allow-list, which can never match a real
# GitHub login (login names cannot contain '<' or '>'), so EVERY comment was
# filtered out and no task ever reached SQLite. A second comment such as
# "/manul retry this task" was silently ignored.
#
# Expected: when allowedUsers still contains an unresolved "<GITHUB_LOGIN>"
# placeholder, poll.sh must fall back to the repo owner allow-list (the
# documented default) and queue the comment — NOT silently drop it.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

cleanup() { [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $label ($actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected='$expected', got='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# A schema that matches poll.sh's init + migrations (incl. prUrl/claimToken).
new_db() {
  sqlite3 "$1" "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);"
  sqlite3 "$1" "INSERT INTO meta VALUES('baseline','2019-01-01T00:00:00Z');"
  sqlite3 "$1" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, author TEXT, agent TEXT, prompt TEXT NOT NULL, context TEXT, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT, processedAt TEXT);"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;"
  sqlite3 "$1" "ALTER TABLE processed_comments ADD COLUMN action TEXT;"
  sqlite3 "$1" "CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);"
  sqlite3 "$1" "CREATE TABLE conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);"
  sqlite3 "$1" "CREATE TABLE conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);"
  sqlite3 "$1" "CREATE TABLE workspaces(id TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, taskCommentId TEXT, status TEXT, createdAt TEXT, updatedAt TEXT);"
}

# setup_manul <dir> <allowed_users_json>
# allowed_users_json is the raw value emitted for "allowedUsers" in config.json.
setup_manul() {
  export TEST_DIR="$1"
  local allowed="$2"
  MANUL_DIR="$TEST_DIR/manul"
  MANUL_DB="$MANUL_DIR/state/manul.db"
  MANUL_LOCKS_DIR="$MANUL_DIR/state/locks"
  MOCK_GH="$TEST_DIR/mock-gh"
  export MANUL_DIR MANUL_DB MANUL_LOCKS_DIR MOCK_GH
  mkdir -p "$MANUL_LOCKS_DIR" "$MOCK_GH"
  cat > "$MANUL_DIR/config.json" <<EOF
{"trigger":"/manul","allowedUsers":$allowed,"repositories":["mariuszmarzec/shoppingListGenerator"],"automation":{"enabled":true,"leaseTimeout":900,"maxAttemptsBeforeFail":3,"lockTtl":1800}}
EOF
  new_db "$MANUL_DB"
}

# Comments fixture: A is a normal task; B is the "retry" follow-up. Both created
# after the baseline, both posted by the repo owner "mariuszmarzec".
make_comments_json() {
  cat > "$MOCK_GH/comments.json" <<'EOF'
[
  {
    "id":5791362918,
    "body":"/manul do this",
    "user":{"login":"mariuszmarzec","type":"User"},
    "created_at":"2026-09-23T12:00:00Z",
    "html_url":"https://github.com/mariuszmarzec/shoppingListGenerator/issues/27#issuecomment-5791362918",
    "url":"https://api.github.com/repos/mariuszmarzec/shoppingListGenerator/issues/comments/5791362918"
  },
  {
    "id":5794445678,
    "body":"/manul retry this task",
    "user":{"login":"mariuszmarzec","type":"User"},
    "created_at":"2026-09-23T12:05:00Z",
    "html_url":"https://github.com/mariuszmarzec/shoppingListGenerator/issues/27#issuecomment-5794445678",
    "url":"https://api.github.com/repos/mariuszmarzec/shoppingListGenerator/issues/comments/5794445678"
  }
]
EOF
}

make_mock_gh() {
  cat > "$MOCK_GH/gh" <<'EOF'
#!/bin/bash
set -u
args="${@/--paginate/}"
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then echo '[]'; exit 0; fi
if [[ "${1:-}" == "api" ]]; then
  if [[ "$args" == *"api/user"* ]] || [[ "$args" == "api user"* ]]; then
    echo '{"login":"mariuszmarzec","id":1,"type":"User"}'; exit 0
  fi
  if [[ "$args" == *"issues/comments?per_page=100"* ]]; then cat "$MOCK_GH/comments.json"; exit 0; fi
  if [[ "$args" == *"issues/27/comments"* ]]; then cat "$MOCK_GH/comments.json"; exit 0; fi
  echo '[]'; exit 0
fi
echo '{}'
EOF
  chmod +x "$MOCK_GH/gh"
}

extract_new_count() {
  echo "$1" | grep -o '"new":[0-9]*' | cut -d: -f2
}

# ============================================================================
# Test 1: A comment with a "/manul retry" follow-up must be queued even when the
# runtime config still contains the unresolved "<GITHUB_LOGIN>" placeholder.
# On the buggy code this produces 0 queued tasks (placeholder never matches).
# ============================================================================
test_placeholder_does_not_block_retry() {
  echo "=== Test 1: unresolved <GITHUB_LOGIN> placeholder must not block polling ==="
  TEST_DIR="$(mktemp -d /tmp/manul-placeholder-XXXXXX)"
  # Use the literal placeholder that config.json.example ships with.
  setup_manul "$TEST_DIR" '["<GITHUB_LOGIN>"]'
  make_comments_json
  make_mock_gh

  # Baseline is 2019 (so 2026 comments are all "new"), matching test conventions.
  local result
  result="$(MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" \
            bash "$SCRIPT_DIR/poll.sh" mariuszmarzec/shoppingListGenerator 2>&1)"

  local retry_queued
  retry_queued="$(sqlite3 "$MANUL_DB" \
    "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5794445678' AND status='queued';")"
  assert_eq "retry comment queued" "1" "$retry_queued"

  local owner_queued
  owner_queued="$(sqlite3 "$MANUL_DB" \
    "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5791362918' AND status='queued';")"
  assert_eq "first comment queued" "1" "$owner_queued"

  cleanup
  unset TEST_DIR
}

# ============================================================================
# Test 2: A resolved (real) allow-list still works and a placeholder entry is not
# enough to drop comments when real users are also present.
# ============================================================================
test_mixed_placeholder_and_real_user() {
  echo "=== Test 2: mixed placeholder+real user keeps the real user ==="
  TEST_DIR="$(mktemp -d /tmp/manul-placeholder-XXXXXX)"
  setup_manul "$TEST_DIR" '["<GITHUB_LOGIN>","mariuszmarzec"]'
  make_comments_json
  make_mock_gh

  local result
  result="$(MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" \
            bash "$SCRIPT_DIR/poll.sh" mariuszmarzec/shoppingListGenerator 2>&1)"

  local retry_queued
  retry_queued="$(sqlite3 "$MANUL_DB" \
    "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5794445678' AND status='queued';")"
  assert_eq "retry comment queued (mixed)" "1" "$retry_queued"

  local owner_queued
  owner_queued="$(sqlite3 "$MANUL_DB" \
    "SELECT COUNT(*) FROM processed_comments WHERE commentId='issue:5791362918' AND status='queued';")"
  assert_eq "first comment queued (mixed)" "1" "$owner_queued"

  cleanup
  unset TEST_DIR
}

# ============================================================================
# Test 3: Re-polling the same comments must not duplicate them (dedup still
# holds even when the placeholder fallback is active).
# ============================================================================
test_placeholder_no_duplicates_on_repoll() {
  echo "=== Test 3: placeholder fallback still deduplicates ==="
  TEST_DIR="$(mktemp -d /tmp/manul-placeholder-XXXXXX)"
  setup_manul "$TEST_DIR" '["<GITHUB_LOGIN>"]'
  make_comments_json
  make_mock_gh

  MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" \
    bash "$SCRIPT_DIR/poll.sh" mariuszmarzec/shoppingListGenerator >/dev/null 2>&1 || true
  local first
  first="$(sqlite3 "$MANUL_DB" "SELECT COUNT(*) FROM processed_comments;") "
  first="$(sqlite3 "$MANUL_DB" "SELECT COUNT(*) FROM processed_comments;")"

  local result
  result="$(MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" \
            bash "$SCRIPT_DIR/poll.sh" mariuszmarzec/shoppingListGenerator 2>&1)"
  local new_count
  new_count="$(extract_new_count "$result")"
  assert_eq "$TEST_NAME (second poll new=0)" "0" "$new_count"
  local second
  second="$(sqlite3 "$MANUL_DB" "SELECT COUNT(*) FROM processed_comments;")"
  assert_eq "$TEST_NAME (count unchanged)" "$first" "$second"

  cleanup
  unset TEST_DIR
}

# ============================================================================
# Test 4: The poll.flock must not be left held after the per-repo subprocess
# exits — otherwise every following poll cycle is skipped ("poll already in
# progress") and no new task ever reaches SQLite.
# ============================================================================
test_poll_flock_released_after_run() {
  echo "=== Test 4: poll.flock released after run ==="
  TEST_DIR="$(mktemp -d /tmp/manul-flock-XXXXXX)"
  MANUL_DIR="$TEST_DIR/manul"
  MANUL_DB="$MANUL_DIR/state/manul.db"
  MANUL_LOCKS_DIR="$MANUL_DIR/state/locks"
  MOCK_GH="$TEST_DIR/mock-gh"
  export MANUL_DIR MANUL_DB MANUL_LOCKS_DIR MOCK_GH
  mkdir -p "$MANUL_LOCKS_DIR" "$MOCK_GH"
  cat > "$MANUL_DIR/config.json" <<'EOF'
{"trigger":"/manul","allowedUsers":["mariuszmarzec"],"repositories":["mariuszmarzec/shoppingListGenerator"],"automation":{"enabled":true,"leaseTimeout":900,"maxAttemptsBeforeFail":3,"lockTtl":1800}}
EOF
  new_db "$MANUL_DB"
  make_comments_json
  make_mock_gh

  MANUL_DIR="$MANUL_DIR" TEST_DIR="$TEST_DIR" PATH="$MOCK_GH:$PATH" \
    bash "$SCRIPT_DIR/poll.sh" mariuszmarzec/shoppingListGenerator >/dev/null 2>&1 || true

  # No lingering worker process should hold the flock: re-acquire should succeed.
  exec 9>"$MANUL_LOCKS_DIR/poll.flock"
  if flock -n 9; then
    ok="1"
    flock -u 9
  else
    ok="0"
  fi
  exec 9>&-
  assert_eq "poll.flock acquirable after run" "1" "$ok"

  cleanup
  unset TEST_DIR
}

run_test() {
  local name="$1"; shift
  TEST_NAME="$name"
  "$@"
}

echo ""
echo "============================================"
echo "  Manul Allowed-users Placeholder Regression"
echo "============================================"
run_test "placeholder does not block retry" test_placeholder_does_not_block_retry
run_test "mixed placeholder+real user"     test_mixed_placeholder_and_real_user
run_test "placeholder fallback deduplicates" test_placeholder_no_duplicates_on_repoll
run_test "poll.flock released after run"   test_poll_flock_released_after_run
echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"
exit "$FAIL"
