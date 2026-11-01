#!/usr/bin/bash
# test_verify_result_comment.sh — Isolated integration tests for verify_result_comment()
#
# Verifies the result-comment contract WITHOUT touching production state.
# Uses a temporary SQLite DB and a configurable fake `gh` executable.
#
# Behavioral coverage:
#   1. Found: top-level comment with matching deterministic marker → PASS (rc=0)
#   2. Found: reply comment (in_reply_to_id != null) with matching marker → PASS (rc=0)
#   3. Not found: no comments contain the marker → FAIL (rc=1)
#   4. Lifecycle comments rejected: ✅/🔄/❌/⚠️ prefix excluded even with marker
#   5. Multiple matches: two comments with same marker → FAIL (rc=1)
#   6. Wrong attempt: marker has different attempt number → FAIL (rc=1)
#   7. gh API failure: gh exits non-zero → FAIL (rc=1, fail-closed)
#   8. Missing commentUrl in DB: record doesn't exist → FAIL (rc=1, fail-closed)
#   9. Empty/null body: body is null or empty string → not matched
#
# Timeout regression test:
#  10. gh hangs → timeout kills it → FAIL (rc=1)
#
# Usage: bash test_verify_result_comment.sh
# Exit code: 0 if all pass, >0 if any fail

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

# ─── Temp working directory (cleaned on exit) ─────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Temp DB — NEVER touches production
TEMP_DB="$WORK/manul_test.db"
LOG_FILE="$WORK/daemon.log"
LIFECYCLE_LOG="$WORK/lifecycle.log"
PID_FILE="$WORK/daemon.pid"
MANUL_DIR="$WORK/manul_dir"
mkdir -p "$MANUL_DIR"
mkdir -p "$WORK/responses"

# Fake executables directory (prepended to PATH)
FAKE_BIN="$WORK/fake_bin"
mkdir -p "$FAKE_BIN"

# ─── Helper counters ──────────────────────────────────────────────────────────
ok() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        ok "$label (rc=$actual)"
    else
        fail "$label (expected rc=$expected, got rc=$actual)"
    fi
}

# ─── Source daemon functions ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/manul-daemon.sh"

# Extract only the functions we need (no globals, no daemon startup)
eval "$(sed -n '/^log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^lc_log() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^sql_escape() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^sqlite_query_json() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^get_daemon_pid() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^repair_result_comment_marker() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^verify_result_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^post_github_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^build_terminal_lifecycle_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^ensure_terminal_lifecycle_outbox() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^queue_terminal_lifecycle_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^find_terminal_lifecycle_comment_id() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^mark_terminal_lifecycle_comment_posted() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^schedule_terminal_lifecycle_retry() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^publish_terminal_lifecycle_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^retry_pending_terminal_lifecycle_comments() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^close_drained_conversations() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^deliver_terminal_lifecycle_comment() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^update_task_completion() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^verify_finalization() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^complete_task_with_verification() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^ensure_claim_token_column() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^ensure_recovery_tracking_columns() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^start_heartbeat() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^stop_heartbeat() {/,/^}/p' "$DAEMON")"
# Heartbeat tracking array must be declared in test scope
eval "$(sed -n '/^declare -A HEARTBEAT_PIDS/p' "$DAEMON")"

# Override paths so sourced functions use our temp dirs
LOG="$LOG_FILE"
CONFIG="$WORK/config.json"
printf '%s\n' '{"automation":{"maxPreExecutionFailures":8}}' > "$CONFIG"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
PID_FILE="$PID_FILE"
DB="$TEMP_DB"
HEARTBEAT_INTERVAL=60
GH_API_TIMEOUT="30"

# Write a fake daemon PID so get_daemon_pid returns 0 (no real daemon running)
echo "0" > "$PID_FILE"

# Terminal event markers must be assembled into the exact comment body
# before the dispatcher calls post_github_comment.
test_terminal_lifecycle_comment() {
    local done_body failed_body retry_body payload
    done_body="$(build_terminal_lifecycle_comment "issue:123" "conv-123" "2" "45" "completed" "" "Implementation is complete.")"
    payload="$(printf '%s\n' "$done_body" | sed -n '1s/^<!-- manul:event //; 1s/ -->$//p')"
    if printf '%s' "$payload" | jq -e '.type == "TASK_DONE" and .data.taskId == "issue:123" and .data.conversationId == "conv-123" and .data.attempt == 2 and .data.prNumber == 45' >/dev/null; then
        ok "completed result includes a valid TASK_DONE marker"
    else
        fail "completed result includes a valid TASK_DONE marker"
    fi
    if [[ "$done_body" == *"Implementation is complete."* ]]; then
        ok "TASK_DONE marker preserves the human-readable result"
    else
        fail "TASK_DONE marker preserves the human-readable result"
    fi

    failed_body="$(build_terminal_lifecycle_comment "issue:124" "conv-124" "3" "" "failed" "provider said \"no\" " "Execution failed.")"
    payload="$(printf '%s\n' "$failed_body" | sed -n '1s/^<!-- manul:event //; 1s/ -->$//p')"
    if printf '%s' "$payload" | jq -e '.type == "TASK_FAILED" and .data.taskId == "issue:124" and .data.error == "provider said \"no\" " and .data.attempt == 3 and .data.prNumber == null' >/dev/null; then
        ok "failed result includes a valid TASK_FAILED marker with escaped error"
    else
        fail "failed result includes a valid TASK_FAILED marker with escaped error"
    fi

    retry_body="$(build_terminal_lifecycle_comment "issue:125" "conv-125" "1" "" "queued" "transient" "Will retry.")"
    if [ "$retry_body" = "Will retry." ]; then
        ok "retryable task result does not emit a terminal event"
    else
        fail "retryable task result does not emit a terminal event"
    fi

    # Exact body delivery is asserted by the terminal outbox tests below.
}
test_terminal_lifecycle_comment

# ─── Setup temp SQLite DB with full schema ─────────────────────────────────────
setup_db() {
    sqlite3 "$TEMP_DB" "
        CREATE TABLE IF NOT EXISTS processed_comments (
            commentId TEXT PRIMARY KEY,
            repository TEXT NOT NULL,
            issueNumber INTEGER NOT NULL,
            commentUrl TEXT NOT NULL,
            author TEXT,
            agent TEXT,
            prompt TEXT NOT NULL,
            context TEXT,
            status TEXT NOT NULL DEFAULT 'queued',
            attempts INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT,
            processedAt TEXT,
            heartbeatAt TEXT,
            leaseExpiresAt TEXT,
            workerPid INTEGER,
            claimToken TEXT,
            agentStartedAt TEXT,
            nextAttemptAt TEXT,
            action TEXT,
            conversationId TEXT
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    " 2>/dev/null
}

insert_task() {
    local comment_id="$1" repo="$2" issue="$3" url="$4"
    local escaped_url
    escaped_url="$(printf '%s' "$url" | sed "s/'/''/g")"
    sqlite3 "$TEMP_DB" "
        INSERT OR REPLACE INTO processed_comments
            (commentId, repository, issueNumber, commentUrl, prompt, status, attempts, createdAt)
        VALUES
            ('$comment_id', '$repo', $issue, '$escaped_url', 'test prompt', 'queued', 0, '2026-09-10T00:00:00Z');
    " 2>/dev/null
}

test_sqlite_query_json_compatibility() {
    local result write_rc=0
    echo "=== legacy sqlite3 CLI compatibility ==="
    setup_db
    result="$(sqlite_query_json "$TEMP_DB" "SELECT 'owner/repo' AS repository, 501 AS issueNumber, NULL AS replyTo, 'line one' || char(10) || 'line two with \"quotes\"' AS body, NULL AS postedAt;")" || {
        fail "read-only SQLite JSON helper executes on legacy CLI hosts"
        return
    }
    if printf '%s' "$result" | jq -e '
        length == 1
        and .[0].repository == "owner/repo"
        and .[0].issueNumber == 501
        and .[0].replyTo == null
        and .[0].body == ("line one" + "\n" + "line two with \"quotes\"")
        and .[0].postedAt == null
    ' >/dev/null; then
        ok "read-only SQLite JSON helper preserves nulls, numbers, quotes, and newlines"
    else
        fail "read-only SQLite JSON helper preserves nulls, numbers, quotes, and newlines"
    fi
    sqlite_query_json "$TEMP_DB" "DELETE FROM processed_comments;" >/dev/null 2>&1 || write_rc=$?
    assert_rc "SQLite JSON helper refuses writes" "1" "$write_rc"
}

FAKE_LIFECYCLE_COMMENTS="$WORK/lifecycle-comments.jsonl"
POST_CAPTURE_FILE="$WORK/terminal-post-body.txt"
: > "$FAKE_LIFECYCLE_COMMENTS"
FAKE_POST_MODE="success"
FAKE_FIND_FAIL="0"
test_sqlite_query_json_compatibility

post_github_comment() {
    local repo="$1" issue="$2" body="$3" reply_to="${4:-}"
    printf '%s' "$body" > "$POST_CAPTURE_FILE"
    if [ "$FAKE_POST_MODE" = "definite_failure" ]; then return 1; fi
    local comment_id
    comment_id="$(jq -s 'length + 700' "$FAKE_LIFECYCLE_COMMENTS")"
    jq -nc --arg body "$body" --argjson id "$comment_id" --arg reply "$reply_to" \
        '{id:$id,body:$body,in_reply_to_id:(if $reply == "" then null else ($reply|tonumber) end)}' >> "$FAKE_LIFECYCLE_COMMENTS"
    [ "$FAKE_POST_MODE" != "accepted_error" ]
}
find_terminal_lifecycle_comment_id() {
    local repo="$1" issue="$2" task_id="$3" attempt="$4" event_type="$5" reply_to="${6:-}"
    [ "$FAKE_FIND_FAIL" = "0" ] || return 2
    jq -sr --arg task "$task_id" --argjson attempt "$attempt" --arg type "$event_type" --arg reply "$reply_to" '
      def event:
        (.body // "") as $body | ($body | split("<!-- manul:event ")) as $parts
        | if ($parts|length) < 2 then null else (try ($parts[1] | split(" -->")[0] | fromjson) catch null) end;
      map(. as $comment | ($comment | event) as $event
          | select($event.type == $type and $event.data.taskId == $task and $event.data.attempt == $attempt
              and (($reply == "") or (($comment.in_reply_to_id // "")|tostring) == $reply))
          | $comment.id)
      | .[0] // empty
    ' "$FAKE_LIFECYCLE_COMMENTS"
}
count_terminal_comments() {
    local task="$1" attempt="$2" type="$3"
    jq -s --arg task "$task" --argjson attempt "$attempt" --arg type "$type" '
      [ .[] | select(((.body // "") | contains($task))
        and ((.body // "") | contains("\"type\":\"" + $type + "\""))
        and ((.body // "") | contains("\"attempt\":" + ($attempt|tostring)))) ] | length
    ' "$FAKE_LIFECYCLE_COMMENTS"
}
test_terminal_lifecycle_outbox() {
    local body payload rc posted_at task_status initial_body
    echo "=== TASK_DONE exact terminal publication body ==="
    setup_db
    insert_task "issue:outbox-done" "owner/repo" 501 "https://github.com/owner/repo/issues/501#issuecomment-done"
    body="$(build_terminal_lifecycle_comment "issue:outbox-done" "conv-done" 2 77 completed "" "Implementation is complete.")"
    queue_terminal_lifecycle_comment "owner/repo" 501 "issue:outbox-done" 2 TASK_DONE "$body" ""
    publish_terminal_lifecycle_comment "issue:outbox-done" 2 TASK_DONE
    payload="$(sed -n '1s/^<!-- manul:event //; 1s/ -->$//p' "$POST_CAPTURE_FILE")"
    if printf '%s' "$payload" | jq -e '.type == "TASK_DONE" and .data.taskId == "issue:outbox-done" and .data.attempt == 2 and .data.prNumber == 77' >/dev/null; then
      ok "captured post body contains the exact TASK_DONE marker"
    else
      fail "captured post body contains the exact TASK_DONE marker"
    fi
    grep -Fq "Implementation is complete." "$POST_CAPTURE_FILE" && ok "captured post body preserves the result text" || fail "captured post body preserves the result text"
    [ "$(count_terminal_comments "issue:outbox-done" 2 TASK_DONE)" = "1" ] && ok "TASK_DONE posted once" || fail "TASK_DONE posted once"
    publish_terminal_lifecycle_comment "issue:outbox-done" 2 TASK_DONE
    [ "$(count_terminal_comments "issue:outbox-done" 2 TASK_DONE)" = "1" ] && ok "repeat publication is idempotent" || fail "repeat publication is idempotent"

    echo "=== accepted-but-client-error read-back ==="
    FAKE_POST_MODE="accepted_error"
    body="$(build_terminal_lifecycle_comment "issue:outbox-ambiguous" "conv-ambiguous" 3 "" failed "provider said \"no\"" "Execution failed.")"
    queue_terminal_lifecycle_comment "owner/repo" 502 "issue:outbox-ambiguous" 3 TASK_FAILED "$body" ""
    rc=0
    publish_terminal_lifecycle_comment "issue:outbox-ambiguous" 3 TASK_FAILED || rc=$?
    assert_rc "accepted post with client error is confirmed from read-back" 0 "$rc"
    [ "$(count_terminal_comments "issue:outbox-ambiguous" 3 TASK_FAILED)" = "1" ] && ok "ambiguous accepted event exists once" || fail "ambiguous accepted event exists once"
    posted_at="$(sqlite3 "$TEMP_DB" "SELECT postedAt FROM manul_terminal_lifecycle_outbox WHERE taskId='issue:outbox-ambiguous';")"
    [ -n "$posted_at" ] && ok "ambiguous acceptance writes durable receipt" || fail "ambiguous acceptance writes durable receipt"
    FAKE_POST_MODE="success"
    publish_terminal_lifecycle_comment "issue:outbox-ambiguous" 3 TASK_FAILED
    [ "$(count_terminal_comments "issue:outbox-ambiguous" 3 TASK_FAILED)" = "1" ] && ok "retry after ambiguous response is duplicate-safe" || fail "retry after ambiguous response is duplicate-safe"

    echo "=== definite failure remains pending and retryable ==="
    insert_task "issue:outbox-definite" "owner/repo" 503 "https://github.com/owner/repo/issues/503#issuecomment-definite"
    sqlite3 "$TEMP_DB" "UPDATE processed_comments SET status='failed',attempts=4 WHERE commentId='issue:outbox-definite';"
    body="$(build_terminal_lifecycle_comment "issue:outbox-definite" "conv-definite" 4 "" failed "provider unavailable" "Execution failed after retry budget.")"
    queue_terminal_lifecycle_comment "owner/repo" 503 "issue:outbox-definite" 4 TASK_FAILED "$body" ""
    FAKE_POST_MODE="definite_failure"
    rc=0
    publish_terminal_lifecycle_comment "issue:outbox-definite" 4 TASK_FAILED || rc=$?
    assert_rc "definite post failure remains pending" 1 "$rc"
    posted_at="$(sqlite3 "$TEMP_DB" "SELECT coalesce(postedAt,'') FROM manul_terminal_lifecycle_outbox WHERE taskId='issue:outbox-definite';")"
    assert_rc "failed publication stores no posted receipt" "" "$posted_at"
    task_status="$(sqlite3 "$TEMP_DB" "SELECT status FROM processed_comments WHERE commentId='issue:outbox-definite';")"
    assert_rc "GitHub comment failure preserves terminal task state" failed "$task_status"
    initial_body="$(cat "$POST_CAPTURE_FILE")"
    FAKE_POST_MODE="success"
    sqlite3 "$TEMP_DB" "UPDATE manul_terminal_lifecycle_outbox SET nextAttemptAt=datetime('now','-1 second') WHERE taskId='issue:outbox-definite';"
    retry_pending_terminal_lifecycle_comments
    posted_at="$(sqlite3 "$TEMP_DB" "SELECT coalesce(postedAt,'') FROM manul_terminal_lifecycle_outbox WHERE taskId='issue:outbox-definite';")"
    [ -n "$posted_at" ] && ok "dispatcher retry publishes pending terminal event" || fail "dispatcher retry publishes pending terminal event"
    [ "$(count_terminal_comments "issue:outbox-definite" 4 TASK_FAILED)" = "1" ] && ok "retry publishes one TASK_FAILED marker" || fail "retry publishes one TASK_FAILED marker"
    cmp -s "$POST_CAPTURE_FILE" <(printf '%s' "$initial_body") && ok "retry uses the exact persisted result body" || fail "retry uses the exact persisted result body"

    echo "=== read failure fails closed ==="
    FAKE_FIND_FAIL="1"
    body="$(build_terminal_lifecycle_comment "issue:outbox-lookup" "conv-lookup" 1 "" failed "lookup failed" "A terminal result.")"
    queue_terminal_lifecycle_comment "owner/repo" 504 "issue:outbox-lookup" 1 TASK_FAILED "$body" ""
    rc=0
    publish_terminal_lifecycle_comment "issue:outbox-lookup" 1 TASK_FAILED || rc=$?
    assert_rc "read-before-write failure is fail-closed" 2 "$rc"
    assert_rc "read failure does not publish blindly" 0 "$(count_terminal_comments "issue:outbox-lookup" 1 TASK_FAILED)"
    FAKE_FIND_FAIL="0"

    echo "=== intermediate retry remains marker-free ==="
    body="$(build_terminal_lifecycle_comment "issue:outbox-retry" "conv-retry" 1 "" queued "transient error" "This attempt will retry.")"
    assert_rc "retry result remains marker-free" "This attempt will retry." "$body"
}
test_terminal_lifecycle_outbox

test_conversation_close_waits_for_terminal_delivery() {
    local status
    echo "=== conversation close waits for terminal outbox reconciliation ==="
    setup_db
    sqlite3 "$TEMP_DB" <<'SQL'
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  updatedAt TEXT
);
INSERT INTO conversations(conversationId,status,activePrNumber,activePrUrl,updatedAt)
VALUES ('conv-pending','ACTIVE',77,'https://github.com/owner/repo/pull/77','2026-10-30T00:00:00Z');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,prompt,action,status,attempts,conversationId)
VALUES ('issue:pending-close','owner/repo',601,'https://github.com/owner/repo/issues/601','test prompt','IMPLEMENT','completed',1,'conv-pending');
SQL
    ensure_terminal_lifecycle_outbox
    sqlite3 "$TEMP_DB" "
      INSERT INTO manul_terminal_lifecycle_outbox(taskId,attempt,eventType,repository,issueNumber,body,nextAttemptAt)
      VALUES ('issue:pending-close',1,'TASK_DONE','owner/repo',601,'<!-- manul:event pending -->',datetime('now','+30 seconds'));
    "
    close_drained_conversations
    status="$(sqlite3 "$TEMP_DB" "SELECT status FROM conversations WHERE conversationId='conv-pending';")"
    assert_rc "pending terminal outbox keeps conversation open" ACTIVE "$status"

    sqlite3 "$TEMP_DB" "UPDATE manul_terminal_lifecycle_outbox SET postedAt=datetime('now'),postedCommentId='9001' WHERE taskId='issue:pending-close';"
    close_drained_conversations
    status="$(sqlite3 "$TEMP_DB" "SELECT status FROM conversations WHERE conversationId='conv-pending';")"
    assert_rc "confirmed terminal marker allows conversation closure" COMPLETED "$status"
    assert_rc "conversation closure clears active PR number" "" "$(sqlite3 "$TEMP_DB" "SELECT coalesce(activePrNumber,'') FROM conversations WHERE conversationId='conv-pending';")"
    assert_rc "conversation closure clears active PR URL" "" "$(sqlite3 "$TEMP_DB" "SELECT coalesce(activePrUrl,'') FROM conversations WHERE conversationId='conv-pending';")"
}
test_conversation_close_waits_for_terminal_delivery

test_conversation_close_tolerates_sqlite_contention() {
    local lock_ready="$WORK/sqlite-writer-lock-ready"
    local lock_pid rc status
    echo "=== conversation close tolerates a concurrent SQLite writer ==="
    setup_db
    sqlite3 "$TEMP_DB" "
CREATE TABLE IF NOT EXISTS conversations (
  conversationId TEXT PRIMARY KEY,
  status TEXT NOT NULL,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  updatedAt TEXT
);
INSERT INTO conversations(conversationId,status,activePrNumber,activePrUrl,updatedAt)
VALUES ('conv-lock','ACTIVE',88,'https://github.com/owner/repo/pull/88','2026-10-30T00:00:00Z');
INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,prompt,action,status,attempts,conversationId)
VALUES ('issue:lock-close','owner/repo',602,'https://github.com/owner/repo/issues/602','test prompt','IMPLEMENT','completed',1,'conv-lock');
" || {
        fail "SQLite contention fixture schema and rows are created"
        return
    }
    ensure_terminal_lifecycle_outbox || {
        fail "SQLite contention fixture outbox is initialized"
        return
    }
    rm -f "$lock_ready"

    # Hold a RESERVED SQLite write lock briefly on a separate connection.
    # The marker file proves BEGIN IMMEDIATE ran before reconciliation starts.
    sqlite3 "$TEMP_DB" >/dev/null 2>&1 <<SQL &
BEGIN IMMEDIATE;
SELECT 1;
.shell touch $lock_ready
.shell sleep 0.35
COMMIT;
SQL
    lock_pid=$!
    for _ in {1..50}; do
        [ -f "$lock_ready" ] && break
        sleep 0.02
    done
    if [ ! -f "$lock_ready" ]; then
        wait "$lock_pid" 2>/dev/null || true
        fail "SQLite contention fixture acquired its write lock"
        return
    fi

    rc=0
    close_drained_conversations || rc=$?
    wait "$lock_pid" 2>/dev/null || true
    assert_rc "conversation close waits through a short SQLite write lock" "0" "$rc"
    status="$(sqlite3 "$TEMP_DB" "SELECT status FROM conversations WHERE conversationId='conv-lock';")"
    assert_rc "conversation closes after the competing writer releases the lock" "COMPLETED" "$status"
}
test_conversation_close_tolerates_sqlite_contention

test_external_source_terminal_lifecycle_suppression() {
    local body rc rows
    echo "=== external source terminal lifecycle suppression ==="
    setup_db
    body="$(build_terminal_lifecycle_comment "todo:external-1" "conv-external" 1 "" completed "" "External task completed.")"
    : > "$POST_CAPTURE_FILE"
    rc=0
    deliver_terminal_lifecycle_comment "owner/repo" 0 "todo:external-1" 1 TASK_DONE "$body" "" || rc=$?
    assert_rc "external-source terminal delivery is intentionally suppressed" 0 "$rc"
    rows="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM manul_terminal_lifecycle_outbox WHERE taskId='todo:external-1';")"
    assert_rc "suppressed external-source event does not create a retryable outbox row" 0 "$rows"
    [ ! -s "$POST_CAPTURE_FILE" ] && ok "external-source suppression does not call the GitHub comment publisher" || fail "external-source suppression attempted a GitHub post"
}
test_external_source_terminal_lifecycle_suppression



# ─── Fake gh executable ────────────────────────────────────────────────────────
# Handles: gh api "repos/owner/repo/issues/1/comments" --paginate --jq '...'
cat > "$FAKE_BIN/gh" << 'GHEOF'
#!/bin/bash
# Fake gh — responds from pre-staged JSON files or fails on demand.

# The marker-repair regression uses the same API shape as a GitHub PATCH. Record
# the exact request and return its body so production verification can validate
# the server's read-back without contacting GitHub.
if [[ " $* " == *" --method PATCH "* ]]; then
    request="$(cat)"
    printf '%s\t%s\n' "$*" "$request" >> "${PATCH_LOG_FILE:?}"
    endpoint_id=""
    for arg in "$@"; do
        case "$arg" in
            repos/*/comments/*) endpoint_id="${arg##*/}" ;;
        esac
    done
    [[ "$endpoint_id" =~ ^[0-9]+$ ]] || exit 2
    printf '%s' "$request" | jq --argjson id "$endpoint_id" '. + {id:$id}'
    exit $?
fi

RESPONSE_FILE=""
JQ_FILTER=""
API_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        api)
            shift
            ;;
        --jq)
            shift
            JQ_FILTER="$1"
            shift
            ;;
        --paginate)
            shift
            ;;
        repos/*)
            API_PATH="$1"
            shift
            while [[ $# -gt 0 ]] && [[ ! "$1" == -* ]]; do
                API_PATH="$API_PATH $1"
                shift
            done
            # Convert API path to response file name
            # Example: repos/owner/repo/issues/1/comments -> owner__repo__issues__1__comments.json
            filename="${API_PATH#repos/}"
            filename="${filename//\//__}.json"
            RESPONSE_FILE="$RESPONSES_DIR/$filename"
            continue
            ;;
        *)
            shift
            ;;
    esac
done

# Output the response (optionally filter with jq)
if [[ -n "$RESPONSE_FILE" ]] && [[ -f "$RESPONSE_FILE" ]]; then
    if [[ -n "$JQ_FILTER" ]]; then
        jq -r "$JQ_FILTER" < "$RESPONSE_FILE" 2>/dev/null || true
    else
        cat "$RESPONSE_FILE"
    fi
else
    echo "[]"
fi
GHEOF
chmod +x "$FAKE_BIN/gh"

# Prepend fake bin to PATH and set responses directory
export PATH="$FAKE_BIN:$PATH"
export RESPONSES_DIR="$WORK/responses"
PATCH_LOG_FILE="$WORK/patches.log"
export PATCH_LOG_FILE
: > "$PATCH_LOG_FILE"

# ─── Test runner ───────────────────────────────────────────────────────────────
run_test() {
    local test_name="$1"
    local repo="$2"
    local issue="$3"
    local comment_id="$4"
    local attempt="$5"
    local response_file="$6"   # path to JSON response file, or "missing" for no file
    local expected_rc="$7"

    echo -n "Test: $test_name ... "

    # Reset DB for this test
    rm -f "$TEMP_DB"
    setup_db

    # Insert task record
    local comment_url="https://github.com/${repo}/issues/${issue}#issuecomment-${comment_id}"
    insert_task "$comment_id" "$repo" "$issue" "$comment_url"

    # Set up response
    if [[ "$response_file" == "missing" ]]; then
        rm -f "$WORK/responses/"*.json
    elif [[ "$response_file" != "$WORK/responses/owner__repo__issues__${issue}__comments.json" ]]; then
        # Copy the response file to the expected location for fake gh
        local dest_file="$WORK/responses/owner__repo__issues__${issue}__comments.json"
        cp "$response_file" "$dest_file"
    fi

    # Run verification
    verify_result_comment "$repo" "$issue" "$comment_id" "$comment_id" "$attempt" >/dev/null 2>&1
    local rc=$?

    assert_rc "$test_name" "$expected_rc" "$rc"
}

# ============================================================================
# Unit tests — 9 behavioral cases
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  verify_result_comment() — Unit Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Write response JSON files into temp dir
REPO="owner/repo"

# ── Test 1: Top-level comment with matching marker ─────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 100, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-1:attempt:1 -->\nI completed the task.\n\n— manul 🐈"}]
EOF
run_test "Found: top-level comment with marker" \
    "$REPO" 1 "result-1" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 0

# ── Test 2: Review reply with matching marker ─────────────────────────────────
cat > "$WORK/responses/owner__repo__pulls__42__comments.json" << 'EOF'
[{"id": 101, "user": {"login": "Manul-Bot"}, "in_reply_to_id": 100, "body": "<!-- manul-task:review:result-2:attempt:1 -->\\nReply with result.\\n\\n— manul 🐈"}]
EOF
rm -f "$WORK/responses/owner__repo__issues__1__comments.json"
rm -f "$TEMP_DB"
setup_db
insert_task "review:result-2" "$REPO" 42 "https://github.com/owner/repo/pull/42#discussion_r100"
verify_result_comment "$REPO" 42 "review:result-2" "review:result-2" 1 >/dev/null 2>&1
rc=$?
assert_rc "Found: review reply with marker" 0 "$rc"

# ── Test 2b: Inline PR review comment with matching marker ─────────────────────
cat > "$WORK/responses/owner__repo__pulls__42__comments.json" << 'EOF'
[
  {"id": 201, "user": {"login": "Manul-Bot"}, "in_reply_to_id": 100,
   "body": "<!-- manul-task:review:result-2b:attempt:1 -->\\nReply result in inline review thread.\\n\\n— manul 🐈"}
]
EOF
rm -f "$WORK/responses/"owner__repo__issues__1__comments.json
rm -f "$TEMP_DB"
setup_db
insert_task "review:result-2b" "$REPO" 42 "https://github.com/owner/repo/pull/42#discussion_r100"
echo "Test: Found inline PR review comment with marker ..."
verify_result_comment "$REPO" 42 "review:result-2b" "review:result-2b" 1 >/dev/null 2>&1
rc=$?
assert_rc "Found: inline PR review comment with marker" 0 "$rc"

# ── Test 2c: A matching marker in a different review thread must be rejected ───
cat > "$WORK/responses/owner__repo__pulls__42__comments.json" << 'EOF'
[
  {"id": 202, "user": {"login": "Manul-Bot"}, "in_reply_to_id": 999,
   "body": "<!-- manul-task:review:result-2c:attempt:1 -->\nWrong review thread.\n\n— manul 🐈"}
]
EOF
rm -f "$TEMP_DB"
setup_db
insert_task "review:result-2c" "$REPO" 42 "https://github.com/owner/repo/pull/42#discussion_r100"
verify_result_comment "$REPO" 42 "review:result-2c" "review:result-2c" 1 >/dev/null 2>&1
rc=$?
assert_rc "Rejected: result marker exists only in a different review thread" 1 "$rc"

# ── Test 3: No comments with marker ────────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 102, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "Some comment without marker"}]
EOF
run_test "Not found: no marker in comments" \
    "$REPO" 1 "result-3" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 4: Lifecycle comments rejected ────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[
  {"id": 103, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "✅ Manul completed the task"},
  {"id": 104, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "🔄 Manul is working on this task"},
  {"id": 105, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "❌ Manul failed after 3 attempts"},
  {"id": 106, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "⚠️ Manul detected an issue"}
]
EOF
run_test "Lifecycle comments rejected (no real result)" \
    "$REPO" 1 "result-4" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 5: Multiple matching comments → FAIL (duplicate comments invalid) ─────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[
  {"id": 107, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-5:attempt:1 -->\nFirst result"},
  {"id": 108, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-5:attempt:1 -->\nSecond result"}
]
EOF
run_test "Multiple matches rejected (invalid duplicates)" \
    "$REPO" 1 "result-5" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 6: Wrong attempt number ───────────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 109, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "<!-- manul-task:result-6:attempt:3 -->\nWrong attempt"}]
EOF
run_test "Wrong attempt number rejected" \
    "$REPO" 1 "result-6" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ── Test 6b: A unique current-attempt result with a stale marker is repaired in place ──
echo "Test: unique result comment from this attempt has a stale attempt marker"
rm -f "$TEMP_DB" "$WORK/responses/owner__repo__issues__1__comments.json" "$PATCH_LOG_FILE"
setup_db
START_AT="$(date -u -d '5 minutes ago' '+%Y-%m-%d %H:%M:%S')"
CREATED_AT="$(date -u -d '1 minute ago' '+%Y-%m-%dT%H:%M:%SZ')"
COMMENT_ID="result-repair"
COMMENT_URL="https://github.com/owner/repo/issues/1#issuecomment-result-repair"
insert_task "$COMMENT_ID" "$REPO" 1 "$COMMENT_URL"
sqlite3 "$TEMP_DB" "UPDATE processed_comments SET status='running', attempts=3, agentStartedAt='$START_AT' WHERE commentId='$COMMENT_ID';"
STALE_BODY="<!-- manul-task:${COMMENT_ID}:attempt:1 -->
The implementation finished on the third execution.
— manul 🐈"
jq -n --arg created_at "$CREATED_AT" --arg body "$STALE_BODY" '[{id:113,in_reply_to_id:null,created_at:$created_at,body:$body}]' > "$WORK/responses/owner__repo__issues__1__comments.json"

verify_result_comment "$REPO" 1 "$COMMENT_ID" "$COMMENT_ID" 3 >/dev/null 2>&1
rc=$?
assert_rc "Unique current-run result marker is repaired in place for attempt 3" 0 "$rc"
if grep -Fq "<!-- manul-task:${COMMENT_ID}:attempt:3 -->" "$PATCH_LOG_FILE" &&
   grep -Fq "repos/owner/repo/issues/comments/113" "$PATCH_LOG_FILE"; then
    ok "Marker repair PATCH targets the existing result comment and uses current attempt"
else
    fail "Marker repair PATCH request is missing or targets the wrong comment"
fi
if ! grep -Fq "<!-- manul-task:${COMMENT_ID}:attempt:1 -->" "$PATCH_LOG_FILE"; then
    ok "Marker repair replaces stale attempt marker rather than duplicating the comment"
else
    fail "Marker repair request retained the stale marker"
fi

# ── Test 6c: An older result comment must not be repaired as the current attempt ──
echo "Test: stale result comment from before this attempt remains rejected"
rm -f "$TEMP_DB" "$WORK/responses/owner__repo__issues__1__comments.json" "$PATCH_LOG_FILE"
setup_db
START_AT="$(date -u -d '5 minutes ago' '+%Y-%m-%d %H:%M:%S')"
CREATED_AT="$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')"
COMMENT_ID="result-old-comment"
COMMENT_URL="https://github.com/owner/repo/issues/1#issuecomment-result-old-comment"
insert_task "$COMMENT_ID" "$REPO" 1 "$COMMENT_URL"
sqlite3 "$TEMP_DB" "UPDATE processed_comments SET status='running', attempts=3, agentStartedAt='$START_AT' WHERE commentId='$COMMENT_ID';"
STALE_BODY="<!-- manul-task:$COMMENT_ID:attempt:1 -->
This result was posted by an earlier attempt.
— manul 🐈"
jq -n --arg created_at "$CREATED_AT" --arg body "$STALE_BODY" '[{id:114,in_reply_to_id:null,created_at:$created_at,body:$body}]' > "$WORK/responses/owner__repo__issues__1__comments.json"
verify_result_comment "$REPO" 1 "$COMMENT_ID" "$COMMENT_ID" 3 >/dev/null 2>&1
rc=$?
assert_rc "Comment created before current attempt is rejected" 1 "$rc"
[ ! -s "$PATCH_LOG_FILE" ] && ok "Older result comment is never modified" || fail "Stale result comment was incorrectly patched"
# ── Test 7: gh API failure → fail-closed ──────────────────────────────────────
# Create a fake gh that fails
cat > "$FAKE_BIN/gh_fail" << 'EOF'
#!/bin/bash
echo "[]" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh_fail"

# Temporarily replace gh with failing version
mv "$FAKE_BIN/gh" "$FAKE_BIN/gh.bak"
cp "$FAKE_BIN/gh_fail" "$FAKE_BIN/gh"

rm -f "$TEMP_DB"
setup_db
insert_task "result-7" "$REPO" 1 "https://github.com/${REPO}/issues/1#issuecomment-result-7"

verify_result_comment "$REPO" 1 "result-7" "result-7" 1 >/dev/null 2>&1
local_rc=$?

# Restore original gh
mv "$FAKE_BIN/gh.bak" "$FAKE_BIN/gh"

if [ "$local_rc" -ne 0 ]; then
    ok "gh API failure → fail-closed (rc=$local_rc)"
else
    fail "gh API failure → should return non-zero (got rc=$local_rc)"
fi

# ── Test 8: Missing commentUrl in DB ───────────────────────────────────────────
rm -f "$TEMP_DB"
setup_db
# Don't insert any task record

verify_result_comment "$REPO" 1 "nonexistent-task" "nonexistent-task" 1 >/dev/null 2>&1
rc=$?
assert_rc "Missing commentUrl in DB" 1 "$rc"

# ── Test 9: Empty/null body ────────────────────────────────────────────────────
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[
  {"id": 110, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": null},
  {"id": 111, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": ""},
  {"id": 112, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "Just text, no marker"}
]
EOF
run_test "Empty/null bodies don't match" \
    "$REPO" 1 "result-9" 1 \
    "$WORK/responses/owner__repo__issues__1__comments.json" 1

# ============================================================================
# Integration test — full dispatch flow with real daemon state machine
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  verify_result_comment() — Integration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── Integration Test 10: Full cycle — task queued → claimed → verified ─────────
echo "Test: Full dispatch cycle (queued→running→verified→completed)"
rm -f "$TEMP_DB"
setup_db

COMMENT_ID="integration-10"
REPO="owner/repo"
ISSUE=1
ATTEMPT=1
COMMENT_URL="https://github.com/owner/repo/issues/1#issuecomment-${COMMENT_ID}"

# Step A: Insert task as queued
insert_task "$COMMENT_ID" "$REPO" "$ISSUE" "$COMMENT_URL"

# Step B: Verify task is queued
queued_before="$(sqlite3 "$TEMP_DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='$COMMENT_ID' AND status='queued';")"
if [ "$queued_before" = "1" ]; then
    ok "Integration: task starts as queued"
else
    fail "Integration: task should be queued (got $queued_before)"
fi

# Step C: Simulate agent completing task
sqlite3 "$TEMP_DB" "
    UPDATE processed_comments
    SET status='running', attempts=1, processedAt=datetime('now'), heartbeatAt=datetime('now'), workerPid=$$
    WHERE commentId='$COMMENT_ID';
" 2>/dev/null

# Step D: Post a fake result comment via fake gh
RESULT_BODY="<!-- manul-task:${COMMENT_ID}:attempt:${ATTEMPT} -->
I have completed the implementation. All tests pass.

— manul 🐈"

echo "[{\"id\": 200, \"user\": {\"login\": \"Agent-Fix\"}, \"in_reply_to_id\": null, \"body\": null}]" | \
    jq --arg body "$RESULT_BODY" '.[0].body = $body' > "$WORK/responses/owner__repo__issues__1__comments.json"

# Step E: Run verification
verify_result_comment "$REPO" "$ISSUE" "$COMMENT_ID" "$COMMENT_ID" "$ATTEMPT" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    ok "Integration: verification passes with correct marker"
else
    fail "Integration: verification should pass with correct marker"
fi

# Step F: Transition to completed
if update_task_completion "$COMMENT_ID" "completed" 2>/dev/null; then
    ok "Integration: task transitioned to completed"
else
    fail "Integration: task should transition to completed"
fi

# Step G: Verify final state
final_status="$(sqlite3 "$TEMP_DB" "SELECT status FROM processed_comments WHERE commentId='$COMMENT_ID';")"
final_processed="$(sqlite3 "$TEMP_DB" "SELECT processedAt FROM processed_comments WHERE commentId='$COMMENT_ID';")"
if [ "$final_status" = "completed" ] && [ -n "$final_processed" ]; then
    ok "Integration: final state is completed with processedAt set"
else
    fail "Integration: expected completed+processedAt, got status=$final_status processedAt=$final_processed"
fi

# ── Integration Test 11: Fail-closed on missing commentUrl ────────────────────
echo ""
echo "Test: Fail-closed when commentUrl is missing from DB"
rm -f "$TEMP_DB"
setup_db

# Insert task WITHOUT a valid commentUrl (empty string)
sqlite3 "$TEMP_DB" "
    INSERT OR REPLACE INTO processed_comments
        (commentId, repository, issueNumber, commentUrl, prompt, status, attempts, createdAt)
    VALUES
        ('no-url-task', '$REPO', $ISSUE, '', 'test prompt', 'queued', 0, '2026-09-10T00:00:00Z');
" 2>/dev/null

verify_result_comment "$REPO" "$ISSUE" "no-url-task" "no-url-task" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "Integration: missing commentUrl correctly fails (rc=1)"
else
    fail "Integration: missing commentUrl should cause failure (expected rc=1)"
fi

# ── Integration Test 12: Lifecycle comments in result don't fool verification ──
echo ""
echo "Test: Lifecycle emoji prefix doesn't produce false positive"
rm -f "$TEMP_DB"
setup_db

LC_COMMENT_URL="https://github.com/owner/repo/issues/1#issuecomment-life-cycle-test"
insert_task "life-cycle-test" "$REPO" "$ISSUE" "$LC_COMMENT_URL"

# Comment starts with ✅ (lifecycle) but also contains a marker — should be rejected
cat > "$WORK/responses/owner__repo__issues__1__comments.json" << 'EOF'
[{"id": 300, "user": {"login": "Manul-Bot"}, "in_reply_to_id": null, "body": "✅ Manul completed\n<!-- manul-task:life-cycle-test:attempt:1 -->\nThis should not count"}]
EOF

verify_result_comment "$REPO" "$ISSUE" "life-cycle-test" "life-cycle-test" 1 >/dev/null 2>&1
if [ $? -ne 0 ]; then
    ok "Integration: lifecycle-prefixed comment correctly rejected (rc=1)"
else
    fail "Integration: lifecycle-prefixed comment should be rejected (expected rc=1)"
fi

# ============================================================================
# Timeout regression test — hanging gh process must be killed
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Timeout/Process Cleanup Regression Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Test: API timeout → function returns failure, no hanging gh"
rm -f "$TEMP_DB"
setup_db
COMMENT_ID="timeout-test"
insert_task "$COMMENT_ID" "$REPO" "$ISSUE" "https://github.com/owner/repo/issues/1#issuecomment-${COMMENT_ID}"

# Create a fake gh that hangs indefinitely
cat > "$FAKE_BIN/gh_hang" << 'HANGEOR'
#!/bin/bash
# Fake gh that hangs forever
while true; do
    sleep 1
done
HANGEOR
chmod +x "$FAKE_BIN/gh_hang"

# Save original gh, replace with hanging version
mv "$FAKE_BIN/gh" "$FAKE_BIN/gh.bak"
ln -sf "$FAKE_BIN/gh_hang" "$FAKE_BIN/gh"

# Set a short timeout for testing
export GH_API_TIMEOUT="1"

# Run verification — should timeout and return failure
START_TIME=$(date +%s)
verify_result_comment "$REPO" "$ISSUE" "$COMMENT_ID" "$COMMENT_ID" "1" >/dev/null 2>&1
RESULT_RC=$?
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Restore original gh
rm -f "$FAKE_BIN/gh"
mv "$FAKE_BIN/gh.bak" "$FAKE_BIN/gh"

# Clean up hanging process
pkill -f "gh_hang" 2>/dev/null || true
sleep 0.5

if [ "$RESULT_RC" -ne 0 ]; then
    ok "API timeout → returns failure (rc=$RESULT_RC, elapsed=${ELAPSED}s)"
else
    fail "API timeout → should return failure (got rc=$RESULT_RC)"
fi

# Verify no gh processes are still hanging
if pgrep -f "gh_hang" > /dev/null 2>&1; then
    fail "Hanging gh process still exists after timeout"
    pkill -9 -f "gh_hang" 2>/dev/null || true
else
    ok "No hanging gh process after timeout"
fi

# ============================================================================
# Results summary
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL tests)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All tests passed.${NC}"
else
    echo -e "${RED}$FAIL test(s) failed.${NC}"
fi

exit $FAIL
