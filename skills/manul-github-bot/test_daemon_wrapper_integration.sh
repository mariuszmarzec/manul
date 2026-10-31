#!/bin/bash
# test_daemon_wrapper_integration.sh - Integration test for evaluate_task_completion()
# Tests the production completion decision function directly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create a temporary directory for test files
TEST_TMPDIR="${DEBUG_TMPDIR:-$(mktemp -d)}"
# Keep tmpdir for debugging when DEBUG_TEST=1 or DEBUG_TMPDIR is set
trap "if [ \"${DEBUG_TEST:-0}\" != \"1\" ] && [ -z \"${DEBUG_TMPDIR:-}\" ]; then rm -rf $TEST_TMPDIR; fi" EXIT
echo "TEST_TMPDIR=$TEST_TMPDIR" >&2

# Create fake executables for external dependencies
FAKE_BIN="$TEST_TMPDIR/fake_bin"
mkdir -p "$FAKE_BIN"

# Fake gh executable for GitHub API mocking
FAKE_GH="$FAKE_BIN/gh"
# State files for the fake gh to persist auto-created PRs and PATCHed comment
# bodies across separate gh invocations.
export FAKE_GH_STATE="$FAKE_BIN/pr_state"
export FAKE_GH_COMMENT_STATE="$FAKE_BIN/comment_state"
: > "$FAKE_GH_STATE"
mkdir -p "$FAKE_GH_COMMENT_STATE"
cat > "$FAKE_GH" << 'GH_EOF'
#!/bin/bash
# Fake gh: handles api (result-comment verification), pr list (PR existence),
# and pr create (auto-PR creation). No real PRs exist in tests, so the daemon
# must auto-create one for the autoCreatePr path to succeed.
if [[ "$1" == "pr" && "$2" == "create" ]]; then
    # gh pr create --repo R --base B --head H --title T --body B
    base=""
    head=""
    for ((i=1; i<=$#; i++)); do
        case "${!i}" in
            --base) i=$((i+1)); base="${!i}" ;;
            --head) i=$((i+1)); head="${!i}" ;;
        esac
    done
    if [ -n "$head" ] && [ -n "$base" ]; then
        printf '%s %s\n' "$head" "$base" >> "$FAKE_GH_STATE"
    fi
    echo "https://github.com/test/repo/pull/999"
    exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    # gh pr list --repo R --state all --head H --json ... --limit 10
    head=""
    for ((i=1; i<=$#; i++)); do
        case "${!i}" in
            --head) i=$((i+1)); head="${!i}" ;;
        esac
    done
    if [ -n "$head" ] && [ -f "$FAKE_GH_STATE" ]; then
        printf '['
        first=1
        while read -r h b; do
            if [ "$h" = "$head" ]; then
                [ "$first" = 1 ] || printf ','
                first=0
                printf '{"number":999,"url":"https://github.com/test/repo/pull/999","state":"OPEN","baseRefName":"%s","headRefName":"%s"}' "$b" "$h"
            fi
        done < "$FAKE_GH_STATE"
        printf ']\n'
    else
        echo '[]'
    fi
    exit 0
fi
if [[ "$1" == "api" ]]; then
    has_jq=false
    method_patch=false
    body_value=""
    for arg in "$@"; do
        if [[ "$arg" == "--method" ]]; then
            method_patch=true
        elif [[ "$arg" == body=* ]]; then
            body_value="${arg#body=}"
        fi
    done
    jq_filter=""
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "--jq" ]]; then
            has_jq=true
            i=$((i+1))
            jq_filter="${!i}"
            break
        fi
    done
    for arg in "$@"; do
        if [[ "$arg" == "repos/test/repo/pulls/60/comments" ]]; then
            if [ "$has_jq" = "true" ]; then
                printf '"<!-- manul-task:review:PR_REVIEW:attempt:1 -->\\nReview fix result"\n'
            else
                printf '[{"id":1060,"body":"<!-- manul-task:review:PR_REVIEW:attempt:1 -->\\nReview fix result","in_reply_to_id":null}]\n'
            fi
            exit 0
        fi
        if [[ "$arg" == repos/* ]]; then
            path="$arg"
            path="${path#repos/}"
            remainder="${path#*/issues/}"
            remainder="${remainder#*/}"
            if [[ "$path" =~ ^[^/]+/[^/]+/(issues|pulls)/comments/[0-9]+$ ]]; then
                target_comment_id="${path##*/}"
                comment_state_file="$FAKE_GH_COMMENT_STATE/$target_comment_id"
                if [ "$method_patch" = "true" ]; then
                    printf '%s' "$body_value" >"$comment_state_file"
                    printf '{}\\n'
                elif [ -f "$comment_state_file" ]; then
                    if [ "$has_jq" = "true" ]; then
                        cat "$comment_state_file"
                        printf '\\n'
                    else
                        jq -cn --arg body "$(cat "$comment_state_file")" '{body:$body}'
                    fi
                else
                    if [ "$has_jq" = "true" ]; then
                        printf '\\n'
                    else
                        printf '{"body":""}\\n'
                    fi
                fi
                exit 0
            fi
            if [[ "$remainder" == "comments" ]]; then
                # Extract issue number from path like test/repo/issues/42/comments
                issue_num="${path#*/issues/}"
                issue_num="${issue_num%%/*}"
                case "$issue_num" in
                    42)
                        # Test A and Q: verified task reports for explicit report-only paths
                        json_output='[{"id":1001,"body":"<!-- manul-task:COMMENT_1:attempt:1 -->\\ntest result — manul 🐈","in_reply_to_id":null}]'
                        ;;
                    43)
                        # Test B: no result comment (missing result)
                        json_output='[]'
                        ;;
                    44)
                        # Test C: unrelated result (COMMENT_1, not COMMENT_3)
                        json_output='[{"id":1001,"body":"<!-- manul-task:COMMENT_1:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    45)
                        # Test D: valid result for COMMENT_4 (but no TASK_DONE in stdout)
                        json_output='[{"id":1004,"body":"<!-- manul-task:COMMENT_4:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    46|47)
                        # Tests E/F: rc!=0, verification skipped; return anything
                        json_output='[{"id":1005,"body":"<!-- manul-task:COMMENT_5:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    48)
                        # Test G: agent pushed branch + /compare URL, daemon auto-creates PR
                        json_output='[{"id":1007,"body":"<!-- manul-task:COMMENT_G:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    49)
                        # Test H: autoCreatePr disabled, no PR -> task fails
                        json_output='[{"id":1008,"body":"<!-- manul-task:COMMENT_H:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    50)
                        # Test I: agent left on default branch -> verify_required_pr must fail
                        json_output='[{"id":1009,"body":"<!-- manul-task:COMMENT_I:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    51)
                        # Test J: agent on real task branch -> verify_required_pr accepts
                        json_output='[{"id":1010,"body":"<!-- manul-task:COMMENT_J:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    52)
                        # Test K: informational task makes no repository changes; PR/branch is not required
                        json_output='[{"id":1011,"body":"<!-- manul-task:COMMENT_K:attempt:1 -->\\ntest result","in_reply_to_id":null}]'
                        ;;
                    56)
                        json_output='[{"id":1015,"body":"<!-- manul-task:COMMENT_Q:attempt:1 -->\nDiagnostic report with concrete findings — manul 🐈","in_reply_to_id":null}]'
                        ;;
                    57)
                        json_output='[]'
                        ;;
                    58)
                        json_output='[{"id":1017,"body":"✅ Manul completed the task successfully.","in_reply_to_id":null}]'
                        ;;
                    59)
                        json_output='[{"id":1018,"body":"<!-- manul-task:COMMENT_T:attempt:1 -->\n\n— manul 🐈","in_reply_to_id":null}]'
                        ;;
                    60)
                        # Test PR: valid task/attempt result marker in the review thread.
                        json_output='[{"id":1060,"body":"<!-- manul-task:review:PR_REVIEW:attempt:1 -->\\nReview fix result","in_reply_to_id":null}]'
                        ;;
                    55)
                        # Test O: existing PR is verified but the task branch was never pushed.
                        json_output='[{"id":1014,"body":"<!-- manul-task:COMMENT_O:attempt:1 -->\\nPR: https://github.com/test/repo/pull/999","in_reply_to_id":null}]'
                        ;;
                    64)
                        # Test Y: pushed commit with canonical PR URL and task marker.
                        json_output='[{"id":1064,"body":"<!-- manul-task:COMMENT_Y:attempt:1 -->\\nPR: https://github.com/test/repo/pull/999","in_reply_to_id":null}]'
                        ;;
                    *)
                        json_output='[]'
                        ;;
                esac
                if [[ "$has_jq" == "true" ]]; then
                    echo "$json_output" | jq -r "$jq_filter"
                else
                    echo "$json_output"
                fi
                exit 0
            fi
        fi
    done
fi
# gh pr list: return fixture PRs when requested by the no-op retry regression.
if [[ "$1" == "pr" && "$2" == "list" ]]; then
    if [[ -n "${FAKE_GH_PR_LIST:-}" && -f "$FAKE_GH_PR_LIST" ]]; then
        cat "$FAKE_GH_PR_LIST"
    else
        echo '[]'
    fi
    exit 0
fi
# gh pr create: synthesize a PR URL
if [[ "$1" == "pr" && "$2" == "create" ]]; then
    echo "https://github.com/test/repo/pull/999"
    exit 0
fi
if [[ "$has_jq" == "true" ]]; then
    echo '[]'
else
    echo '{}'
fi
GH_EOF
chmod +x "$FAKE_GH"

# Source manul-daemon.sh with testing guard enabled.
# MANUL_DIR MUST be the tmpdir: poll.sh creates the real schema (25 columns) at
# $MANUL_DIR/manul.db on source, and the daemon's LOG/DB/CONFIG all derive from it.
MANUL_DIR="$TEST_TMPDIR/manul"
mkdir -p "$MANUL_DIR"
MANUL_TESTING=true source "$SCRIPT_DIR/manul-daemon.sh"
export PATH="$FAKE_BIN:$PATH"

# Setup test environment
LOG_FILE="$TEST_TMPDIR/daemon.log"
LIFECYCLE_LOG="$TEST_TMPDIR/lifecycle.log"
PID_FILE="$TEST_TMPDIR/daemon.pid"
DB="$TEST_TMPDIR/manul_test.db"
HEARTBEAT_INTERVAL=60
LOG="$LOG_FILE"
LIFECYCLE_LOG="$LIFECYCLE_LOG"
export PID_FILE DB HEARTBEAT_INTERVAL LOG LIFECYCLE_LOG CONFIG="$SCRIPT_DIR/config.json" MANUL_DIR GH_API_TIMEOUT

# DEFAULT_BRANCH is a global set by the production dispatch path; tests must set it.
DEFAULT_BRANCH="master"
# Completion evaluation also branches on the claimed task action; default fixtures emulate IMPLEMENT.
TASK_ACTION="IMPLEMENT"

# Real git workdir so verify_required_pr can resolve the task branch and (when
# autoCreatePr is enabled) auto-create a PR. The daemon's autoCreatePr path
# pushes/creates a PR from the checked-out branch.
WORKDIR="$TEST_TMPDIR/workdir"
mkdir -p "$WORKDIR"
git -C "$WORKDIR" init -q
git -C "$WORKDIR" config user.email test@example.com
git -C "$WORKDIR" config user.name test
printf 'test\n' >"$WORKDIR/README.md"
git -C "$WORKDIR" add README.md
git -C "$WORKDIR" commit -qm initial
INITIAL_HEAD_A="$(git -C "$WORKDIR" rev-parse HEAD)"
git -C "$WORKDIR" checkout -qb manul-task-COMMENT_1
echo "implementation change" >> "$WORKDIR/README.md"
git -C "$WORKDIR" add README.md
git -C "$WORKDIR" commit -qm "implementation change"

# Create test database with the SAME 25-column schema as poll.sh's real DB so
# update_task_completion() (which sets heartbeatAt/leaseExpiresAt) and
# verify_required_pr() (which reads action/prNumber/prUrl) operate on columns
# that actually exist.
sqlite3 "$DB" "CREATE TABLE processed_comments (
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
    nextAttemptAt TEXT,
    conversationId TEXT,
    parentTaskId TEXT,
    workspaceId TEXT,
    resultSummary TEXT,
    resultJson TEXT,
    baseId TEXT,
    action TEXT DEFAULT 'IMPLEMENT',
    prNumber INTEGER,
    prUrl TEXT
);"
# workerPid must match the test process PID ($$) so the completion path's
# ownership check (WHERE ... AND workerPid=$$) succeeds. The production
# claim path sets workerPid to the worker PID; the test inserts rows directly.
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_1','test/repo',42,'https://github.com/test/repo/issues/42#issuecomment-1001','user','test','task','running',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_2','test/repo',43,'https://github.com/test/repo/issues/43#issuecomment-1002','user','test','task','running',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_3','test/repo',44,'https://github.com/test/repo/issues/44#issuecomment-1003','user','test','task','running',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_4','test/repo',45,'https://github.com/test/repo/issues/45#issuecomment-1004','user','test','task','running',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_5','test/repo',46,'https://github.com/test/repo/issues/46#issuecomment-1005','user','test','task','running',1,$$);"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid) VALUES ('COMMENT_6','test/repo',47,'https://github.com/test/repo/issues/47#issuecomment-1006','user','test','task','running',1,$$);;"
echo "0" > "$PID_FILE"

# ─── Test A: rc=0 + TASK_DONE + valid result comment -> COMPLETION_SUCCESS=true ─
echo "=== Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutA.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "42" "COMMENT_1" "COMMENT_1" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR" "" "$INITIAL_HEAD_A" "manul-task-COMMENT_1" "master" "" "" "" ""
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test A - expected COMPLETION_SUCCESS=true, got '$COMPLETION_SUCCESS'" >&2
    echo "  failure_code=${FAILURE_CODE:-<unset>} reason=${FAIL_REASON:-<empty>}" >&2
    echo "  daemon log:" >&2
    tail -n 60 "$LOG_FILE" >&2 || true
    exit 1
fi
if [ -z "$FINAL_COMMENT" ]; then
    echo "FAIL: Test A - expected non-empty FINAL_COMMENT"
    exit 1
fi
echo "[OK] Test A: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test B: rc=0 + TASK_DONE + missing result comment -> COMPLETION_SUCCESS=false ─
echo "=== Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutB.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "43" "COMMENT_2" "COMMENT_2" "1" "0" "$STDOUT_FILE" "$DB" "" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test B - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -z "$FAIL_REASON" ]; then
    echo "FAIL: Test B - expected non-empty FAIL_REASON"
    exit 1
fi
echo "[OK] Test B: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test C: rc=0 + TASK_DONE + invalid/unrelated result -> COMPLETION_SUCCESS=false ─
echo "=== Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutC.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
echo "some unrelated output" >> "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "44" "COMMENT_3" "COMMENT_3" "1" "0" "$STDOUT_FILE" "$DB" "" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test C - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test C: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ─
echo "=== Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutD.txt"
echo "some output without marker" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "45" "COMMENT_4" "COMMENT_4" "1" "0" "$STDOUT_FILE" "$DB" "" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test D - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test D: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ─
echo "=== Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutE.txt"
echo "TASK_FAILED: orchestration error" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "46" "COMMENT_5" "COMMENT_5" "1" "42" "$STDOUT_FILE" "$DB" "" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test E - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
# When rc!=0, FAIL_REASON may or may not be set depending on implementation
echo "[OK] Test E: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test F: timeout/signal + no TASK_DONE -> COMPLETION_SUCCESS=false ─
echo "=== Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutF.txt"
echo "timeout occurred" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "47" "COMMENT_6" "COMMENT_6" "1" "124" "$STDOUT_FILE" "$DB" "" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test F - expected COMPLETION_SUCCESS=false, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test F: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test F2: executor summary survives into FAIL_REASON ─────────────────────
# Regression for runtime failures that previously surfaced only as generic
# "Task failed" in GitHub feedback even though the controller returned a useful
# execution summary.
echo ""
echo "=== Test F2: executor summary is preserved as FAIL_REASON ==="
STDOUT_FILE="$TEST_TMPDIR/stdoutF2.txt"
echo "runtime output" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "47" "COMMENT_6B" "COMMENT_6B" "1" "1" "$STDOUT_FILE" "$DB" "" "" "" "" "master" "master" "OpenClaw exited with code 1: authentication failed"
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test F2 - expected COMPLETION_SUCCESS=false"
    exit 1
fi
if [ "$FAIL_REASON" != "OpenClaw exited with code 1: authentication failed" ]; then
    echo "FAIL: Test F2 - expected executor summary to survive, got '$FAIL_REASON'"
    exit 1
fi
echo "[OK] Test F2: PASSED (FAIL_REASON preserves executor summary)"

# ─── Test G: agent pushed branch + returned /compare/... URL (no PR) ─────────
# The exact problem case from shoppingListGenerator#28: the agent committed,
# pushed its branch, and returned a /compare/... "create PR" link instead of an
# actual PR. With autoCreatePr enabled the daemon must create the PR itself so
# the task succeeds instead of failing.
echo ""
echo "=== Test G: agent pushed branch + /compare URL, daemon auto-creates PR -> COMPLETION_SUCCESS=true ==="
# The fake gh returns NO pr list results (no PR exists) but a successful
# pr create (synthesized PR URL). The workdir is checked out on the task branch.
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_G';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_G','test/repo',48,'https://github.com/test/repo/issues/48#issuecomment-1007','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null

WORKDIR_G="$TEST_TMPDIR/workdir-g"
mkdir -p "$WORKDIR_G"
git -C "$WORKDIR_G" init -q
git -C "$WORKDIR_G" config user.email test@example.com
git -C "$WORKDIR_G" config user.name test
printf 'test\n' >"$WORKDIR_G/README.md"
git -C "$WORKDIR_G" add README.md
git -C "$WORKDIR_G" commit -qm initial
INITIAL_HEAD_G="$(git -C "$WORKDIR_G" rev-parse HEAD)"
git -C "$WORKDIR_G" checkout -qb manul-task-COMMENT_G
echo "implementation change" >> "$WORKDIR_G/README.md"
git -C "$WORKDIR_G" add README.md
git -C "$WORKDIR_G" commit -qm "implementation change"

STDOUT_FILE="$TEST_TMPDIR/stdoutG.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "48" "COMMENT_G" "COMMENT_G" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_G" "" "$INITIAL_HEAD_G" "manul-task-COMMENT_G" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test G - expected COMPLETION_SUCCESS=true (daemon should auto-create PR), got '$COMPLETION_SUCCESS'"
    exit 1
fi
if [ -n "$FAIL_REASON" ]; then
    echo "FAIL: Test G - expected empty FAIL_REASON on success, got '$FAIL_REASON'"
    exit 1
fi
# Confirm the daemon actually invoked gh pr create (not just gh pr list)
if ! grep -q "pr_auto_create\|gh pr create" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL: Test G - expected daemon to invoke gh pr create"
    exit 1
fi
echo "[OK] Test G: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test H: autoCreatePr disabled + no PR -> task fails ──────────────────────
# When autoCreatePr is false, a missing PR must still fail the task (no masking).
echo ""
echo "=== Test H: autoCreatePr disabled + no PR -> COMPLETION_SUCCESS=false ==="
CONFIG_DISABLED="$TEST_TMPDIR/config-disabled.json"
jq '.autoCreatePr = false' "$SCRIPT_DIR/config.json" > "$CONFIG_DISABLED"
export CONFIG="$CONFIG_DISABLED"

sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_H';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_H','test/repo',49,'https://github.com/test/repo/issues/49#issuecomment-1008','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null

WORKDIR_H="$TEST_TMPDIR/workdir-h"
mkdir -p "$WORKDIR_H"
git -C "$WORKDIR_H" init -q
git -C "$WORKDIR_H" config user.email test@example.com
git -C "$WORKDIR_H" config user.name test
printf 'test\n' >"$WORKDIR_H/README.md"
git -C "$WORKDIR_H" add README.md
git -C "$WORKDIR_H" commit -qm initial
INITIAL_HEAD_H="$(git -C "$WORKDIR_H" rev-parse HEAD)"
git -C "$WORKDIR_H" checkout -qb manul-task-COMMENT_H
echo "implementation change" >> "$WORKDIR_H/README.md"
git -C "$WORKDIR_H" add README.md
git -C "$WORKDIR_H" commit -qm "implementation change"

STDOUT_FILE="$TEST_TMPDIR/stdoutH.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "49" "COMMENT_H" "COMMENT_H" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_H" "" "$INITIAL_HEAD_H" "manul-task-COMMENT_H" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test H - expected COMPLETION_SUCCESS=false when autoCreatePr disabled, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if ! printf '%s' "$FAIL_REASON" | grep -q "did not produce a real PR"; then
    echo "FAIL: Test H - expected FAIL_REASON about missing PR, got '$FAIL_REASON'"
    exit 1
fi
if ! grep -q "MISSING_PR\|no PR found" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL: Test H - expected MISSING_PR log entry (no PR, autoCreatePr disabled)"
    exit 1
fi
# Restore the canonical config for any remaining tests
export CONFIG="$SCRIPT_DIR/config.json"
echo "[OK] Test H: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test I: issue task left on default branch -> verify_required_pr must FAIL ─
# Regression for the branch-lifecycle contract: Manul owns branch creation for
# standalone (issue) tasks. If the checked-out branch is the default branch,
# verify_required_pr() must reject the task rather than silently accept it.
echo ""
echo "=== Test I: agent left on default branch -> verify_required_pr fails ==="
WORKDIR_I="$TEST_TMPDIR/workdir-i"
mkdir -p "$WORKDIR_I"
git -C "$WORKDIR_I" init -q
git -C "$WORKDIR_I" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_I" config user.email test@example.com
git -C "$WORKDIR_I" config user.name test
printf 'test\n' >"$WORKDIR_I/README.md"
git -C "$WORKDIR_I" add README.md
git -C "$WORKDIR_I" commit -qm initial
# Intentionally stay on the default branch (agent did NOT create a task branch)
git -C "$WORKDIR_I" checkout -q master
INITIAL_HEAD_I="$(git -C "$WORKDIR_I" rev-parse HEAD)"
echo "forbidden direct base change" >> "$WORKDIR_I/README.md"
git -C "$WORKDIR_I" add README.md
git -C "$WORKDIR_I" commit -qm "forbidden direct base change"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_I';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_I','test/repo',50,'https://github.com/test/repo/issues/50#issuecomment-1009','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutI.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "50" "COMMENT_I" "COMMENT_I" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_I" "" "$INITIAL_HEAD_I" "master" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test I - expected COMPLETION_SUCCESS=false when checked-out branch is the default branch, got '$COMPLETION_SUCCESS'"
    exit 1
fi
if ! printf '%s' "$FAIL_REASON" | grep -q "base/default branch"; then
    echo "FAIL: Test I - expected rejection for a direct base/default-branch change, got '$FAIL_REASON'"
    exit 1
fi
if ! grep -q "invalid_task_branch\|MISSING_PR\|no PR found" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL: Test I - expected verify_required_pr to log invalid_task_branch / MISSING_PR"
    exit 1
fi
echo "[OK] Test I: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test PR: PR-tied task may modify the existing PR head branch ─────────────
# Regression for PR review tasks: their prepared INITIAL_BRANCH is the PR head
# branch, so changing it must not be rejected as a base/default-branch change.
echo ""
echo "=== Test PR: PR-tied task on expected PR head branch -> COMPLETION_SUCCESS=true ==="
WORKDIR_PR="$TEST_TMPDIR/workdir-pr"
mkdir -p "$WORKDIR_PR"
git -C "$WORKDIR_PR" init -q
git -C "$WORKDIR_PR" config user.email test@example.com
git -C "$WORKDIR_PR" config user.name test
printf 'test\\n' >"$WORKDIR_PR/README.md"
git -C "$WORKDIR_PR" add README.md
git -C "$WORKDIR_PR" commit -qm initial
INITIAL_HEAD_PR="$(git -C "$WORKDIR_PR" rev-parse HEAD)"
git -C "$WORKDIR_PR" checkout -qb feature/44-manul-e2e-fixture
# The PR head branch is intentionally the same as INITIAL_BRANCH.
echo "review change" >>"$WORKDIR_PR/README.md"
git -C "$WORKDIR_PR" add README.md
git -C "$WORKDIR_PR" commit -qm "review change"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='PR_REVIEW';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('review:PR_REVIEW','test/repo',60,'https://github.com/test/repo/pull/60#discussion_r1234','user','test','task','running',1,$$,'REVIEW_FIX');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutPR.txt"
echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "60" "review:PR_REVIEW" "review:PR_REVIEW" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_PR" "" "$INITIAL_HEAD_PR" "feature/44-manul-e2e-fixture" "master" "" "" "feature/44-manul-e2e-fixture"
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: PR-tied task on expected head branch was rejected: $FAIL_REASON"
    exit 1
fi
echo "[OK] Test PR: PASSED (PR head branch is valid for PR-tied task)"

# Include the PR-head regression in the test summary.
# (The test body is defined above and runs during the main sequence.)

# ─── Test J: agent on a real task branch with autoCreatePr -> verify_required_pr accepts ─
# Confirms the positive half of the contract: a dedicated task branch (not the
# default) is accepted by verify_required_pr when autoCreatePr can create the PR.
echo ""
echo "=== Test J: agent on task branch + autoCreatePr -> verify_required_pr accepts ==="
WORKDIR_J="$TEST_TMPDIR/workdir-j"
mkdir -p "$WORKDIR_J"
git -C "$WORKDIR_J" init -q
git -C "$WORKDIR_J" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_J" config user.email test@example.com
git -C "$WORKDIR_J" config user.name test
printf 'test\n' >"$WORKDIR_J/README.md"
git -C "$WORKDIR_J" add README.md
git -C "$WORKDIR_J" commit -qm initial
INITIAL_HEAD_J="$(git -C "$WORKDIR_J" rev-parse HEAD)"
git -C "$WORKDIR_J" checkout -qb manul-task-COMMENT_J
echo "implementation change" >> "$WORKDIR_J/README.md"
git -C "$WORKDIR_J" add README.md
git -C "$WORKDIR_J" commit -qm "implementation change"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_J';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_J','test/repo',51,'https://github.com/test/repo/issues/51#issuecomment-1010','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutJ.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
evaluate_task_completion "test/repo" "51" "COMMENT_J" "COMMENT_J" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_J" "" "$INITIAL_HEAD_J" "manul-task-COMMENT_J" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test J - expected COMPLETION_SUCCESS=true on a real task branch, got '$COMPLETION_SUCCESS'"
    exit 1
fi
echo "[OK] Test J: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"

# ─── Test K: informational task with no repo changes -> success without PR ─
echo ""
echo "=== Test K: informational task + no repository changes -> COMPLETION_SUCCESS=true ==="
WORKDIR_K="$TEST_TMPDIR/workdir-k"
mkdir -p "$WORKDIR_K"
git -C "$WORKDIR_K" init -q
git -C "$WORKDIR_K" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_K" config user.email test@example.com
git -C "$WORKDIR_K" config user.name test
printf "test\n" >"$WORKDIR_K/README.md"
git -C "$WORKDIR_K" add README.md
git -C "$WORKDIR_K" commit -qm initial
INITIAL_HEAD_K="$(git -C "$WORKDIR_K" rev-parse HEAD)"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_K';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_K','test/repo',52,'https://github.com/test/repo/issues/52#issuecomment-1011','user','test','answer question','running',1,$$,'REVIEW_FIX');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutK.txt"
echo "TASK_DONE" > "$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
TASK_ACTION="REVIEW_FIX"
evaluate_task_completion "test/repo" "52" "COMMENT_K" "COMMENT_K" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_K" "" "$INITIAL_HEAD_K" "master" "master"
if [ "$COMPLETION_SUCCESS" != "true" ]; then
    echo "FAIL: Test K - expected informational task with no repo changes to succeed, got $COMPLETION_SUCCESS ($FAIL_REASON)" >&2
    echo "  failure_code=${FAILURE_CODE:-<unset>} action=${TASK_ACTION:-<unset>} db_row=$(sqlite3 "$DB" "SELECT status || ':' || COALESCE(workerPid,'') || ':' || COALESCE(action,'') FROM processed_comments WHERE commentId='COMMENT_K';" 2>/dev/null)" >&2
    echo "  daemon log:" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    exit 1
fi
if printf "%s" "$FAIL_REASON" | grep -q "real PR"; then
    echo "FAIL: Test K - informational task should not require a PR"
    exit 1
fi
echo "[OK] Test K: PASSED (COMPLETION_SUCCESS=$COMPLETION_SUCCESS)"
TASK_ACTION="IMPLEMENT"

# ─── Test N: TASK_DONE with uncommitted repository changes is rejected as delivery failure
echo ""
echo "=== Test N: TASK_DONE + dirty workspace -> DELIVERY_NOT_COMMITTED ==="
WORKDIR_N="$TEST_TMPDIR/workdir-n"
mkdir -p "$WORKDIR_N"
git -C "$WORKDIR_N" init -q
git -C "$WORKDIR_N" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_N" config user.email test@example.com
git -C "$WORKDIR_N" config user.name test
printf "test
" >"$WORKDIR_N/README.md"
git -C "$WORKDIR_N" add README.md
git -C "$WORKDIR_N" commit -qm initial
INITIAL_HEAD_N="$(git -C "$WORKDIR_N" rev-parse HEAD)"
git -C "$WORKDIR_N" checkout -qb manul-task-COMMENT_N
echo "uncommitted implementation" >>"$WORKDIR_N/README.md"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_N';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_N','test/repo',55,'https://github.com/test/repo/issues/55#issuecomment-1013','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutN.txt"
echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
FAILURE_CODE=""
evaluate_task_completion "test/repo" "55" "COMMENT_N" "COMMENT_N" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_N" "" "$INITIAL_HEAD_N" "manul-task-COMMENT_N" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test N - dirty workspace must not be accepted"
    exit 1
fi
if [ "$FAILURE_CODE" != "DELIVERY_NOT_COMMITTED" ]; then
    echo "FAIL: Test N - expected FAILURE_CODE=DELIVERY_NOT_COMMITTED, got '$FAILURE_CODE' ($FAIL_REASON)"
    exit 1
fi
echo "[OK] Test N: PASSED (FAILURE_CODE=$FAILURE_CODE)"

# ─── Test W: remote SHA equals HEAD but dirty requested edits are not delivered
echo ""
echo "=== Test W: remote SHA equals HEAD + dirty changes -> DELIVERY_NOT_COMMITTED ==="
WORKDIR_W="$TEST_TMPDIR/workdir-w"
mkdir -p "$WORKDIR_W"
git -C "$WORKDIR_W" init -q
git -C "$WORKDIR_W" config user.email test@example.com
git -C "$WORKDIR_W" config user.name test
printf "baseline\\n" >"$WORKDIR_W/README.md"
git -C "$WORKDIR_W" add README.md
git -C "$WORKDIR_W" commit -qm initial
INITIAL_HEAD_W="$(git -C "$WORKDIR_W" rev-parse HEAD)"
git -C "$WORKDIR_W" checkout -qb manul-task-COMMENT_W
ORIGIN_W="$TEST_TMPDIR/origin-w.git"
git init --bare -q "$ORIGIN_W"
git -C "$WORKDIR_W" remote add origin "$ORIGIN_W"
git -C "$WORKDIR_W" push -q -u origin manul-task-COMMENT_W
echo "uncommitted requested edit" >>"$WORKDIR_W/README.md"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='review:COMMENT_W';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('review:COMMENT_W','test/repo',62,'https://github.com/test/repo/pull/62#discussion_r1062','user','test','task','running',1,${BASHPID},'REVIEW_FIX');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutW.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""
TASK_ACTION="REVIEW_FIX"
evaluate_task_completion "test/repo" "62" "review:COMMENT_W" "review:COMMENT_W" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_W" "" "$INITIAL_HEAD_W" "manul-task-COMMENT_W" "master" "" "" "manul-task-COMMENT_W" "" ""
TASK_ACTION="IMPLEMENT"
if [ "$COMPLETION_SUCCESS" = "true" ] || [ "$FAILURE_CODE" != "DELIVERY_NOT_COMMITTED" ]; then
  echo "FAIL: Test W - REVIEW_FIX must reject dirty edits even when origin SHA equals HEAD, got $COMPLETION_SUCCESS / $FAILURE_CODE / $FAIL_REASON" >&2
  exit 1
fi
if ! grep -q "DELIVERY_NOT_COMMITTED.*COMMENT_W" "$LIFECYCLE_LOG"; then
  echo "FAIL: Test W - expected concrete lifecycle delivery failure log" >&2
  exit 1
fi
if ! grep -q "uncommitted requested edit" "$WORKDIR_W/README.md"; then
  echo "FAIL: Test W - undelivered edit must remain in the worktree for diagnosis" >&2
  exit 1
fi
echo "[OK] Test W: dirty REVIEW_FIX is rejected and the edit remains available for diagnosis"

# ─── Test X: missing result marker cannot be reported as successful delivery
echo ""
echo "=== Test X: missing result marker -> DELIVERY_COMMENT_MISSING ==="
WORKDIR_X="$TEST_TMPDIR/workdir-x"
mkdir -p "$WORKDIR_X"
git -C "$WORKDIR_X" init -q
git -C "$WORKDIR_X" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_X" config user.email test@example.com
git -C "$WORKDIR_X" config user.name test
printf "baseline\\n" >"$WORKDIR_X/README.md"
git -C "$WORKDIR_X" add README.md
git -C "$WORKDIR_X" commit -qm initial
INITIAL_HEAD_X="$(git -C "$WORKDIR_X" rev-parse HEAD)"
# No repository change is intentional here: exercise the required marker
# check independently of the implementation PR verification pipeline.
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_X';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_X','test/repo',63,'https://github.com/test/repo/issues/63#issuecomment-1063','user','test','task','running',1,$$,'REVIEW_FIX');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutX.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""
TASK_ACTION="REVIEW_FIX"
evaluate_task_completion "test/repo" "63" "COMMENT_X" "COMMENT_X" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_X" "" "$INITIAL_HEAD_X" "master" "master" "" "" "" "" ""
TASK_ACTION="IMPLEMENT"
if [ "$COMPLETION_SUCCESS" = "true" ] || [ "$FAILURE_CODE" != "DELIVERY_COMMENT_MISSING" ]; then
  echo "FAIL: Test X - missing result marker must reject success, got $COMPLETION_SUCCESS / $FAILURE_CODE / $FAIL_REASON" >&2
  exit 1
fi
echo "[OK] Test X: missing result marker fails closed"


# ─── Test Y: committed and pushed changes with verified PR are accepted
echo ""
echo "=== Test Y: commit pushed to origin + verified PR/result -> COMPLETION_SUCCESS=true ==="
WORKDIR_Y="$TEST_TMPDIR/workdir-y"
mkdir -p "$WORKDIR_Y"
git -C "$WORKDIR_Y" init -q
git -C "$WORKDIR_Y" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_Y" config user.email test@example.com
git -C "$WORKDIR_Y" config user.name test
printf "baseline\\n" >"$WORKDIR_Y/README.md"
git -C "$WORKDIR_Y" add README.md
git -C "$WORKDIR_Y" commit -qm initial
INITIAL_HEAD_Y="$(git -C "$WORKDIR_Y" rev-parse HEAD)"
ORIGIN_Y="$TEST_TMPDIR/origin-y.git"
git init --bare -q "$ORIGIN_Y"
git -C "$WORKDIR_Y" remote add origin "$ORIGIN_Y"
git -C "$WORKDIR_Y" push -q -u origin master
git -C "$WORKDIR_Y" checkout -qb manul-task-COMMENT_Y
echo "verified implementation" >>"$WORKDIR_Y/README.md"
git -C "$WORKDIR_Y" add README.md
git -C "$WORKDIR_Y" commit -qm "verified implementation"
git -C "$WORKDIR_Y" push -q -u origin manul-task-COMMENT_Y
# Simulate the real PR discovered by gh pr list for this exact branch/base.
printf '%s %s\n' "manul-task-COMMENT_Y" "master" >>"$FAKE_GH_STATE"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_Y';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_Y','test/repo',64,'https://github.com/test/repo/issues/64#issuecomment-1064','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutY.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""
TASK_ACTION="IMPLEMENT"
evaluate_task_completion "test/repo" "64" "COMMENT_Y" "COMMENT_Y" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_Y" "" "$INITIAL_HEAD_Y" "manul-task-COMMENT_Y" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" != "true" ]; then
  echo "FAIL: Test Y - pushed commit with verified PR/result should succeed, got $COMPLETION_SUCCESS / $FAILURE_CODE / $FAIL_REASON" >&2
  exit 1
fi
if [ "$(git -C "$WORKDIR_Y" ls-remote --heads origin manul-task-COMMENT_Y | awk '{print $1}')" != "$(git -C "$WORKDIR_Y" rev-parse HEAD)" ]; then
  echo "FAIL: Test Y - expected remote branch SHA to equal delivered HEAD" >&2
  exit 1
fi
echo "[OK] Test Y: committed work is pushed and verified remotely before success"


# ─── Test O: clean local commit with origin but no remote branch is not delivered
echo ""
echo "=== Test O: local commit + unpushed origin -> DELIVERY_NOT_PUSHED ==="
WORKDIR_O="$TEST_TMPDIR/workdir-o"
mkdir -p "$WORKDIR_O"
git -C "$WORKDIR_O" init -q
git -C "$WORKDIR_O" config user.email test@example.com
git -C "$WORKDIR_O" config user.name test
printf "test
" >"$WORKDIR_O/README.md"
git -C "$WORKDIR_O" add README.md
git -C "$WORKDIR_O" commit -qm initial
INITIAL_HEAD_O="$(git -C "$WORKDIR_O" rev-parse HEAD)"
git -C "$WORKDIR_O" checkout -qb manul-task-COMMENT_O
echo "committed implementation" >>"$WORKDIR_O/README.md"
git -C "$WORKDIR_O" add README.md
git -C "$WORKDIR_O" commit -qm "implementation change"
ORIGIN_O="$TEST_TMPDIR/origin-o.git"
git init --bare -q "$ORIGIN_O"
git -C "$WORKDIR_O" remote add origin "$ORIGIN_O"
printf '%s %s
' "manul-task-COMMENT_O" "master" >>"$FAKE_GH_STATE"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_O';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_O','test/repo',55,'https://github.com/test/repo/issues/55#issuecomment-1014','user','test','task','running',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutO.txt"
echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
FAILURE_CODE=""
evaluate_task_completion "test/repo" "55" "COMMENT_O" "COMMENT_O" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_O" "" "$INITIAL_HEAD_O" "manul-task-COMMENT_O" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test O - unpushed branch must not be accepted"
    exit 1
fi
if [ "$FAILURE_CODE" != "DELIVERY_NOT_PUSHED" ]; then
    echo "FAIL: Test O - expected FAILURE_CODE=DELIVERY_NOT_PUSHED, got '$FAILURE_CODE' ($FAIL_REASON)"
    exit 1
fi
echo "[OK] Test O: PASSED (FAILURE_CODE=$FAILURE_CODE)"

# ─── Test P: PR-tied task on the wrong branch is rejected
echo ""
echo "=== Test P: PR-tied task + unexpected branch -> VERIFICATION_FAILED ==="
WORKDIR_P="$TEST_TMPDIR/workdir-p"
mkdir -p "$WORKDIR_P"
git -C "$WORKDIR_P" init -q
git -C "$WORKDIR_P" config user.email test@example.com
git -C "$WORKDIR_P" config user.name test
printf "test
" >"$WORKDIR_P/README.md"
git -C "$WORKDIR_P" add README.md
git -C "$WORKDIR_P" commit -qm initial
INITIAL_HEAD_P="$(git -C "$WORKDIR_P" rev-parse HEAD)"
git -C "$WORKDIR_P" checkout -qb unexpected-branch
echo "wrong branch change" >>"$WORKDIR_P/README.md"
git -C "$WORKDIR_P" add README.md
git -C "$WORKDIR_P" commit -qm "wrong branch change"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='PR_WRONG';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('review:PR_WRONG','test/repo',61,'https://github.com/test/repo/pull/61#discussion_r5678','user','test','task','running',1,$$,'REVIEW_FIX');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutP.txt"
echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
FAILURE_CODE=""
evaluate_task_completion "test/repo" "61" "review:PR_WRONG" "review:PR_WRONG" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_P" "" "$INITIAL_HEAD_P" "unexpected-branch" "master" "" "" "feature/expected-pr" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test P - unexpected PR branch must not be accepted"
    exit 1
fi
if [ "$FAILURE_CODE" != "VERIFICATION_FAILED" ]; then
    echo "FAIL: Test P - expected FAILURE_CODE=VERIFICATION_FAILED, got '$FAILURE_CODE' ($FAIL_REASON)"
    exit 1
fi
echo "[OK] Test P: PASSED (FAILURE_CODE=$FAILURE_CODE)"

# ─── Test L: verified PR metadata must replace the issue number ───────────────
# Regression for issue-task feedback: queue ingestion may initialize prNumber
# with the issue number, but once the daemon verifies the real PR it must store
# the actual PR number/URL before TASK_DONE feedback is emitted.
echo ""
echo "=== Test L: verified PR metadata replaces issue number ==="
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_L';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,prNumber,prUrl) VALUES ('COMMENT_L','test/repo',53,'https://github.com/test/repo/issues/53#issuecomment-1012','user','test','task','completed',1,$$,53,NULL);" 2>/dev/null
if ! persist_verified_pr_metadata "COMMENT_L" "37" "https://github.com/test/repo/pull/37"; then
    echo "FAIL: Test L - persist_verified_pr_metadata returned failure"
    exit 1
fi
actual_pr="$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments WHERE commentId='COMMENT_L';")"
actual_url="$(sqlite3 "$DB" "SELECT prUrl FROM processed_comments WHERE commentId='COMMENT_L';")"
if [ "$actual_pr" != "37" ]; then
    echo "FAIL: Test L - expected prNumber=37, got '$actual_pr'"
    exit 1
fi
if [ "$actual_url" != "https://github.com/test/repo/pull/37" ]; then
    echo "FAIL: Test L - expected canonical PR URL, got '$actual_url'"
    exit 1
fi
echo "[OK] Test L: PASSED (issue number replaced with verified PR #37)"

# ─── Test M: issuebody task with repository changes must require a real PR ──
echo ""
echo "=== Test M: issuebody task with repository changes requires real PR ==="
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_M';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action,prNumber) VALUES ('issuebody:COMMENT_M','test/repo',54,'https://github.com/test/repo/issues/54','user','test','task','running',1,$$,'IMPLEMENT',54);" 2>/dev/null

WORKDIR_M="$TEST_TMPDIR/workdir-m"
mkdir -p "$WORKDIR_M"
git -C "$WORKDIR_M" init -q
git -C "$WORKDIR_M" config user.email test@example.com
git -C "$WORKDIR_M" config user.name test
printf 'test\n' >"$WORKDIR_M/README.md"
git -C "$WORKDIR_M" add README.md
git -C "$WORKDIR_M" commit -qm initial
INITIAL_HEAD_M="$(git -C "$WORKDIR_M" rev-parse HEAD)"
git -C "$WORKDIR_M" checkout -qb manul-task-COMMENT_M
echo "implementation change" >>"$WORKDIR_M/README.md"
git -C "$WORKDIR_M" add README.md
git -C "$WORKDIR_M" commit -qm "implementation change"

STDOUT_FILE="$TEST_TMPDIR/stdoutM.txt"
echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
export CONFIG="$CONFIG_DISABLED"
evaluate_task_completion "test/repo" "54" "issuebody:COMMENT_M" "issuebody:COMMENT_M" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_M" "" "$INITIAL_HEAD_M" "manul-task-COMMENT_M" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ]; then
    echo "FAIL: Test M - issuebody task with repository changes must not succeed without a real PR"
    exit 1
fi
if ! printf '%s' "$FAIL_REASON" | grep -q "real PR"; then
    echo "FAIL: Test M - expected missing real PR failure, got '$FAIL_REASON'"
    exit 1
fi
echo "[OK] Test M: PASSED (issuebody repository change cannot bypass PR verification)"
export CONFIG="$SCRIPT_DIR/config.json"


# Test Q/R/S: report-only delivery and implementation guards.
echo ""
echo "=== Test Q: comment-only diagnostic delivery succeeds without PR ==="
WORKDIR_Q="$TEST_TMPDIR/workdir-q"; mkdir -p "$WORKDIR_Q"
git -C "$WORKDIR_Q" init -q; git -C "$WORKDIR_Q" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_Q" config user.email test@example.com; git -C "$WORKDIR_Q" config user.name test
printf "baseline\\n" >"$WORKDIR_Q/README.md"; git -C "$WORKDIR_Q" add README.md; git -C "$WORKDIR_Q" commit -qm initial
INITIAL_HEAD_Q="$(git -C "$WORKDIR_Q" rev-parse HEAD)"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_Q';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_Q','test/repo',56,'https://github.com/test/repo/issues/56#issuecomment-1015','user','test','diagnostics only; do not change code','running',1,$$,'VERIFY');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutQ.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""; TASK_ACTION="VERIFY"
evaluate_task_completion "test/repo" "56" "COMMENT_Q" "COMMENT_Q" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_Q" "" "$INITIAL_HEAD_Q" "master" "master" "" "" "" "" "comment_only"
if [ "$COMPLETION_SUCCESS" != "true" ]; then echo "FAIL: report-only should succeed ($FAIL_REASON)"; exit 1; fi
echo "[OK] Test Q: PASSED"

echo "=== Test R: report-only task without a verified result fails ==="
WORKDIR_R="$TEST_TMPDIR/workdir-r"; mkdir -p "$WORKDIR_R"
git -C "$WORKDIR_R" init -q; git -C "$WORKDIR_R" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_R" config user.email test@example.com; git -C "$WORKDIR_R" config user.name test
printf "baseline\\n" >"$WORKDIR_R/README.md"; git -C "$WORKDIR_R" add README.md; git -C "$WORKDIR_R" commit -qm initial
INITIAL_HEAD_R="$(git -C "$WORKDIR_R" rev-parse HEAD)"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_R';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_R','test/repo',57,'https://github.com/test/repo/issues/57#issuecomment-1016','user','test','diagnostics only; do not change code','running',1,$$,'VERIFY');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutR.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""; TASK_ACTION="VERIFY"
evaluate_task_completion "test/repo" "57" "COMMENT_R" "COMMENT_R" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_R" "" "$INITIAL_HEAD_R" "master" "master" "" "" "" "" "comment_only"
if [ "$COMPLETION_SUCCESS" = "true" ] || [ "$FAILURE_CODE" != "DELIVERY_COMMENT_MISSING" ]; then echo "FAIL: absent report must fail ($FAILURE_CODE $FAIL_REASON)"; exit 1; fi
echo "[OK] Test R: PASSED"

echo "=== Test T: empty report result is rejected ==="
WORKDIR_T="$TEST_TMPDIR/workdir-t"; mkdir -p "$WORKDIR_T"
git -C "$WORKDIR_T" init -q; git -C "$WORKDIR_T" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_T" config user.email test@example.com; git -C "$WORKDIR_T" config user.name test
printf "baseline\\n" >"$WORKDIR_T/README.md"; git -C "$WORKDIR_T" add README.md; git -C "$WORKDIR_T" commit -qm initial
INITIAL_HEAD_T="$(git -C "$WORKDIR_T" rev-parse HEAD)"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_T';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_T','test/repo',59,'https://github.com/test/repo/issues/59#issuecomment-1018','user','test','diagnostics only; do not change code','running',1,$$,'VERIFY');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutT.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""; TASK_ACTION="VERIFY"
evaluate_task_completion "test/repo" "59" "COMMENT_T" "COMMENT_T" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_T" "" "$INITIAL_HEAD_T" "master" "master" "" "" "" "" "comment_only"
if [ "$COMPLETION_SUCCESS" = "true" ] || [ "$FAILURE_CODE" != "DELIVERY_COMMENT_EMPTY" ]; then
  echo "FAIL: empty report must fail ($FAILURE_CODE $FAIL_REASON)" >&2
  echo "DEBUG: result endpoint fixture:" >&2
  gh api repos/test/repo/issues/59/comments --paginate --jq '.[] | .body // ""' >&2 || true
  echo "DEBUG: task row: $(sqlite3 "$DB" "SELECT commentUrl || ':' || action || ':' || status FROM processed_comments WHERE commentId='COMMENT_T';" 2>/dev/null)" >&2
  echo "DEBUG: daemon log:" >&2
  tail -n 50 "$LOG_FILE" >&2 || true
  exit 1
fi
echo "[OK] Test T: PASSED"

echo "=== Test S: implementation without PR is still rejected ==="
WORKDIR_S="$TEST_TMPDIR/workdir-s"; mkdir -p "$WORKDIR_S"
git -C "$WORKDIR_S" init -q; git -C "$WORKDIR_S" symbolic-ref HEAD refs/heads/master
git -C "$WORKDIR_S" config user.email test@example.com; git -C "$WORKDIR_S" config user.name test
printf "baseline\\n" >"$WORKDIR_S/README.md"; git -C "$WORKDIR_S" add README.md; git -C "$WORKDIR_S" commit -qm initial
INITIAL_HEAD_S="$(git -C "$WORKDIR_S" rev-parse HEAD)"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_S';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,workerPid,action) VALUES ('COMMENT_S','test/repo',58,'https://github.com/test/repo/issues/58#issuecomment-1017','user','test','implement the requested change','running',1,$$,'IMPLEMENT');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdoutS.txt"; echo "TASK_DONE" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""; FINAL_COMMENT=""; FAIL_REASON=""; FAILURE_CODE=""; TASK_ACTION="IMPLEMENT"
evaluate_task_completion "test/repo" "58" "COMMENT_S" "COMMENT_S" "1" "0" "$STDOUT_FILE" "$DB" "" "$WORKDIR_S" "" "$INITIAL_HEAD_S" "master" "master" "" "" "" "" ""
if [ "$COMPLETION_SUCCESS" = "true" ] || [ "$FAILURE_CODE" != "VERIFICATION_FAILED" ]; then echo "FAIL: implementation without PR must fail ($FAILURE_CODE $FAIL_REASON)"; exit 1; fi
echo "[OK] Test S: PASSED"

# ─── Test U: failed agent attempts must transition running -> queued ──────────
echo ""
echo "=== Test U: failed agent attempt is atomically requeued ==="
ensure_claim_token_column
CLAIM_TOKEN_RETRY="test-claim-retry"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_RETRY';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,heartbeatAt,leaseExpiresAt,workerPid,action,claimToken) VALUES ('COMMENT_RETRY','test/repo',60,'https://github.com/test/repo/issues/60#issuecomment-1060','user','test','retry transition test','running',1,datetime('now'),datetime('now'),datetime('now','+15 minutes'),$$,'IMPLEMENT','$CLAIM_TOKEN_RETRY');" 2>/dev/null
RETRY_DELAY_SECONDS=2
STDOUT_FILE="$TEST_TMPDIR/stdout-retry.txt"
echo "runtime stopped without completion marker" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
FAILURE_CODE=""
TASK_ACTION="IMPLEMENT"
evaluate_task_completion "test/repo" "60" "COMMENT_RETRY" "COMMENT_RETRY" "1" "42" "$STDOUT_FILE" "$DB" "" "" "$CLAIM_TOKEN_RETRY" "" "master" "master" "transient runtime failure" "RUNTIME_FAILURE" "" "" ""
RETRY_STATE="$(sqlite3 "$DB" "SELECT status || '|' || COALESCE(claimToken,'') || '|' || COALESCE(workerPid,'') || '|' || COALESCE(heartbeatAt,'') || '|' || COALESCE(leaseExpiresAt,'') || '|' || CASE WHEN nextAttemptAt IS NULL THEN 'NULL' ELSE 'SET' END FROM processed_comments WHERE commentId='COMMENT_RETRY';" 2>/dev/null)"
if [ "$RETRY_STATE" != "queued|||||SET" ]; then
  echo "FAIL: expected queued status with ownership/heartbeat/lease cleared and retry deadline set; got '$RETRY_STATE'" >&2
  tail -n 60 "$LOG_FILE" >&2 || true
  exit 1
fi
RETRY_IS_FUTURE="$(sqlite3 "$DB" "SELECT CASE WHEN nextAttemptAt > datetime('now') THEN 1 ELSE 0 END FROM processed_comments WHERE commentId='COMMENT_RETRY';" 2>/dev/null)"
if [ "$RETRY_IS_FUTURE" != "1" ]; then
  echo "FAIL: retry deadline must be in the future" >&2
  exit 1
fi
RETRY_ATTEMPTS="$(sqlite3 "$DB" "SELECT attempts FROM processed_comments WHERE commentId='COMMENT_RETRY';" 2>/dev/null)"
if [ "$RETRY_ATTEMPTS" != "1" ]; then
  echo "FAIL: retry transition must preserve attempts, got '$RETRY_ATTEMPTS'" >&2
  exit 1
fi
if ! printf '%s' "$FINAL_COMMENT" | grep -q "will retry"; then
  echo "FAIL: successful retry transition should announce a retry" >&2
  exit 1
fi
echo "[OK] Test U: retry is queued with token/lease cleared and backoff preserved"

# ─── Test V: deterministic permission blocks stop without wasting retries ────
echo ""
echo "=== Test V: permission-policy rejection is terminal ==="
ensure_claim_token_column
CLAIM_TOKEN_PERMISSION="test-claim-permission"
sqlite3 "$DB" "DELETE FROM processed_comments WHERE commentId='COMMENT_PERMISSION';" 2>/dev/null
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,attempts,createdAt,heartbeatAt,leaseExpiresAt,workerPid,action,claimToken) VALUES ('COMMENT_PERMISSION','test/repo',61,'https://github.com/test/repo/issues/61#issuecomment-1061','user','test','permission block test','running',1,datetime('now'),datetime('now','+1 minute'),datetime('now','+15 minutes'),$$,'IMPLEMENT','$CLAIM_TOKEN_PERMISSION');" 2>/dev/null
STDOUT_FILE="$TEST_TMPDIR/stdout-permission.txt"
echo "permission requested: bash outside configured workspace; auto-rejecting" >"$STDOUT_FILE"
COMPLETION_SUCCESS=""
FINAL_COMMENT=""
FAIL_REASON=""
FAILURE_CODE=""
TASK_ACTION="IMPLEMENT"
evaluate_task_completion "test/repo" "61" "COMMENT_PERMISSION" "COMMENT_PERMISSION" "1" "1" "$STDOUT_FILE" "$DB" "" "" "$CLAIM_TOKEN_PERMISSION" "" "master" "master" "OpenCode denied an external directory access" "RUNTIME_PERMISSION_BLOCKED" "" "" ""
PERMISSION_STATE="$(sqlite3 "$DB" "SELECT status || '|' || COALESCE(claimToken,'') || '|' || COALESCE(workerPid,'') || '|' || COALESCE(heartbeatAt,'') || '|' || COALESCE(leaseExpiresAt,'') || '|' || CASE WHEN nextAttemptAt IS NULL THEN 'NULL' ELSE 'SET' END FROM processed_comments WHERE commentId='COMMENT_PERMISSION';" 2>/dev/null)"
if [ "$PERMISSION_STATE" != "failed|||||NULL" ]; then
  echo "FAIL: permission block should fail terminally with claim/lease cleared and no retry deadline; got '$PERMISSION_STATE'" >&2
  tail -n 60 "$LOG_FILE" >&2 || true
  exit 1
fi
if ! printf '%s' "$FINAL_COMMENT" | grep -qi "permission policy"; then
  echo "FAIL: permission failure comment must explain the required policy change" >&2
  exit 1
fi
echo "[OK] Test V: permission failure stops after first block and reports remediation"

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo "=== INTEGRATION TEST SUMMARY ==="
echo "[OK] Test A: rc=0 + TASK_DONE + valid result -> COMPLETION_SUCCESS=true"
echo "[OK] Test B: rc=0 + TASK_DONE + missing result -> COMPLETION_SUCCESS=false"
echo "[OK] Test C: rc=0 + TASK_DONE + unrelated result -> COMPLETION_SUCCESS=false"
echo "[OK] Test D: rc=0 + no TASK_DONE + valid result -> COMPLETION_SUCCESS=false"
echo "[OK] Test E: rc=42 + TASK_FAILED -> COMPLETION_SUCCESS=false"
echo "[OK] Test F: non-zero rc + no TASK_DONE -> COMPLETION_SUCCESS=false"
echo "[OK] Test F2: executor summary is preserved as FAIL_REASON"
echo "[OK] Test G: agent pushed branch + /compare URL, daemon auto-creates PR -> COMPLETION_SUCCESS=true"
echo "[OK] Test H: autoCreatePr disabled + no PR -> COMPLETION_SUCCESS=false"
echo "[OK] Test I: agent left on default branch -> verify_required_pr FAILS (regression)"
echo "[OK] Test J: agent on real task branch -> verify_required_pr ACCEPTS"
echo "[OK] All tests call real evaluate_task_completion() from manul-daemon.sh"
echo "=== ALL INTEGRATION TESTS PASSED ==="
