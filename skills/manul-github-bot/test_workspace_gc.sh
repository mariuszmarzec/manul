#!/usr/bin/env bash
# Hermetic regression tests for workspace-gc.sh. Uses a temporary runtime and
# a fake GitHub CLI; it never reads or mutates an installed Manul environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export MANUL_WORKSPACE_GC_INTERVAL_SECONDS=1
export MANUL_WORKSPACE_GC_IDLE_HOURS=1
export MANUL_WORKSPACE_GC_CONTEXT_DAYS=30
export MANUL_WORKSPACE_GC_CLOSED_PR_DAYS=7
export MANUL_WORKSPACE_GC_RECOVERY_DAYS=30
export MANUL_WORKSPACE_GC_REPO_DAYS=30
export MANUL_WORKSPACE_GC_PR_CACHE_TTL_SECONDS=21600
export PATH="$TEST_DIR/bin:$PATH"

mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/workspace" "$MANUL_DIR/logs" "$TEST_DIR/bin"

source "$SCRIPT_DIR/manul-paths.sh"
export DB="$MANUL_DB"
source "$SCRIPT_DIR/workspace-manager.sh"
source "$SCRIPT_DIR/workspace-gc.sh"

workspace_init
workspace_gc_init

sqlite3 "$DB" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT,
  issueNumber INTEGER,
  status TEXT,
  workspaceId TEXT,
  conversationId TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER
);
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  status TEXT NOT NULL,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE TABLE conversation_links (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversationId TEXT NOT NULL,
  repo TEXT NOT NULL,
  issueNumber INTEGER,
  prNumber INTEGER,
  commentId TEXT,
  taskCommentId TEXT,
  linkType TEXT NOT NULL,
  createdAt TEXT NOT NULL
);
SQL

CLOSED_8_DAYS="$(date -u -d '8 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
CLOSED_2_DAYS="$(date -u -d '2 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
export CLOSED_8_DAYS CLOSED_2_DAYS

cat >"$TEST_DIR/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "${1:-}" = "api" ] || exit 2
case "${2:-}" in
  repos/example/repo/pulls/101) printf 'open\t\n' ;;
  repos/example/repo/pulls/102) printf 'closed\t%s\n' "$CLOSED_8_DAYS" ;;
  repos/example/repo/pulls/103) printf 'closed\t%s\n' "$CLOSED_2_DAYS" ;;
  # A cached old "closed" result must be revalidated before deletion.
  repos/example/repo/pulls/104) printf 'open\t\n' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$TEST_DIR/bin/gh"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

add_workspace() {
  local workspace_id="$1" context_id="$2" age="$3" pr_number="${4:-}"
  local workspace_path="$MANUL_WORKSPACE/$workspace_id"
  mkdir -p "$workspace_path"
  sqlite3 "$DB" "
    INSERT INTO workspaces(workspaceId,workspacePath,status,currentTaskId,lastUsedAt)
    VALUES('$workspace_id','$workspace_path','IDLE',NULL,datetime('now','-$age'));
    INSERT INTO workspace_contexts(contextId,parentContextId,workspaceId,repository,prNumber,createdAt,lastUsedAt)
    VALUES('$context_id',NULL,'$workspace_id','example/repo',NULLIF('$pr_number',''),datetime('now','-$age'),datetime('now','-$age'));
    INSERT INTO conversations(conversationId,repository,issueNumber,activePrNumber,activePrUrl,status,createdAt,updatedAt)
    VALUES('$context_id','example/repo',1,NULLIF('$pr_number',''),NULL,'COMPLETED',datetime('now','-$age'),datetime('now','-$age'));
  "
  if [ -n "$pr_number" ]; then
    sqlite3 "$DB" "INSERT INTO conversation_links(conversationId,repo,prNumber,linkType,createdAt) VALUES('$context_id','example/repo',$pr_number,'PR',datetime('now','-$age'));"
  fi
}

workspace_row_exists() {
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$1';")" = "1" ]
}

workspace_dir_exists() {
  [ -d "$MANUL_WORKSPACE/$1" ]
}

# 1. Unbound IDLE workspaces are deleted by lastUsedAt, not directory mtime.
mkdir -p "$MANUL_WORKSPACE/ws-unbound-old"
sqlite3 "$DB" "INSERT INTO workspaces(workspaceId,workspacePath,status,lastUsedAt) VALUES('ws-unbound-old','$MANUL_WORKSPACE/ws-unbound-old','IDLE',datetime('now','-2 hours'));"
mkdir -p "$MANUL_WORKSPACE/ws-orphan-old"
touch -d '2 hours ago' "$MANUL_WORKSPACE/ws-orphan-old"
workspace_gc_run true
! workspace_row_exists ws-unbound-old && ! workspace_dir_exists ws-unbound-old || fail "expired unbound workspace removed"
[ ! -d "$MANUL_WORKSPACE/ws-orphan-old" ] || fail "old unregistered directory moved out of active workspace"
orphan_archive="$(find "$MANUL_STATE_DIR/recovery/workspaces" -mindepth 1 -maxdepth 1 -type d -name 'ws-orphan-old-gc-orphan-*' -print -quit)"
[ -n "$orphan_archive" ] || fail "old unregistered directory preserved in recovery"
pass "expired unbound workspace rows are pruned and orphan directories are archived"

# 2. A fresh unbound pool slot is not pruned.
mkdir -p "$MANUL_WORKSPACE/ws-unbound-fresh"
sqlite3 "$DB" "INSERT INTO workspaces(workspaceId,workspacePath,status,lastUsedAt) VALUES('ws-unbound-fresh','$MANUL_WORKSPACE/ws-unbound-fresh','IDLE',datetime('now'));"
workspace_gc_run true
workspace_row_exists ws-unbound-fresh && workspace_dir_exists ws-unbound-fresh || fail "fresh pool slot retained"
pass "fresh IDLE pool workspace is retained"

# 3. An inactive non-PR conversation expires after 30 days.
add_workspace ws-old-issue conv-example-repo-issue-1 '31 days'
workspace_gc_run true
! workspace_row_exists ws-old-issue && ! workspace_dir_exists ws-old-issue || fail "old inactive issue workspace removed"
expired_context_archive="$(find "$MANUL_STATE_DIR/recovery/workspaces" -mindepth 1 -maxdepth 1 -type d -name 'ws-old-issue-gc-expired-context-*' -print -quit)"
[ -n "$expired_context_archive" ] || fail "expired issue workspace preserved in recovery"
pass "inactive issue/review context expires after the configured retention and is archived"

# 4. Open PRs are never removed, even when the workspace is very old.
add_workspace ws-open-pr conv-example-repo-issue-101 '180 days' 101
workspace_gc_run true
workspace_row_exists ws-open-pr && workspace_dir_exists ws-open-pr || fail "open PR workspace retained"
pass "open PR workspace is retained"

# 5. A PR closed more than seven days ago can be removed.
add_workspace ws-closed-pr conv-example-repo-issue-102 '180 days' 102
workspace_gc_run true
! workspace_row_exists ws-closed-pr && ! workspace_dir_exists ws-closed-pr || fail "expired closed PR workspace removed"
pass "closed PR workspace expires after the seven-day grace period"

# 6. A recently closed PR remains available during its grace period.
add_workspace ws-recently-closed-pr conv-example-repo-issue-103 '180 days' 103
workspace_gc_run true
workspace_row_exists ws-recently-closed-pr && workspace_dir_exists ws-recently-closed-pr || fail "recently closed PR workspace retained"
pass "recently closed PR workspace is retained during its grace period"

# 7. A stale cached closed state cannot delete a PR that has since reopened.
add_workspace ws-reopened-pr conv-example-repo-issue-104 '180 days' 104
sqlite3 "$DB" "
  INSERT INTO manul_workspace_gc_pr_cache(repository,prNumber,state,closedAt,checkedAt)
  VALUES('example/repo',104,'closed','$CLOSED_8_DAYS',datetime('now'));
"
workspace_gc_run true
workspace_row_exists ws-reopened-pr && workspace_dir_exists ws-reopened-pr || fail "reopened PR workspace retained"
pass "cached closed PR status is revalidated before deletion"

# 8. A queued task protects its workspace even if the context is old.
add_workspace ws-active-queued conv-example-repo-issue-200 '180 days'
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,workspaceId,conversationId) VALUES('task-queued','example/repo',200,'queued','ws-active-queued','conv-example-repo-issue-200');"
workspace_gc_run true
workspace_row_exists ws-active-queued && workspace_dir_exists ws-active-queued || fail "queued task workspace retained"
pass "queued task protects its workspace"

# 9. Recovery snapshots are retained for active tasks, then expire after 30 days.
RECOVERY_ROOT="$MANUL_STATE_DIR/recovery/workspaces"
mkdir -p "$RECOVERY_ROOT/ws-recover-active-task-a-1" "$RECOVERY_ROOT/ws-recover-expired-task-b-1"
touch -d '31 days ago' "$RECOVERY_ROOT/ws-recover-active-task-a-1" "$RECOVERY_ROOT/ws-recover-expired-task-b-1"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId,repository,issueNumber,status,workspaceId,conversationId) VALUES('recovery-active-task','example/repo',300,'queued','ws-recover-active','conv-recovery');"
workspace_gc_run true
[ -d "$RECOVERY_ROOT/ws-recover-active-task-a-1" ] || fail "active recovery snapshot retained"
[ ! -d "$RECOVERY_ROOT/ws-recover-expired-task-b-1" ] || fail "expired recovery snapshot removed"
pass "recovery snapshots respect active-task ownership and 30-day retention"

# 10. Shared repository cache is retained until 30 days without use, then pruned.
create_cache() {
  local repository="$1" slug path
  slug="${repository//\//-}"
  path="$MANUL_WORKSPACE/$slug"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" remote add origin "https://github.com/$repository"
}
create_cache example/expired-repo
create_cache example/locked-repo
sqlite3 "$DB" "
  INSERT INTO manul_repo_cache_usage(repository,lastUsedAt) VALUES
    ('example/expired-repo',datetime('now','-31 days')),
    ('example/locked-repo',datetime('now','-31 days'));
"
mkdir -p "$MANUL_LOCKS_DIR/repo/example-locked-repo.lock"
workspace_gc_run true
[ ! -d "$MANUL_WORKSPACE/example-expired-repo" ] || fail "expired shared repository cache removed"
[ -d "$MANUL_WORKSPACE/example-locked-repo/.git" ] || fail "cache with active repo lock retained"
pass "shared cache retention prunes old unused repos and respects repo locks"

# 11. Successful cache use refreshes the retention timestamp.
workspace_gc_touch_repo example/locked-repo
latest_used="$(sqlite3 "$DB" "SELECT lastUsedAt FROM manul_repo_cache_usage WHERE repository='example/locked-repo';")"
[ -n "$latest_used" ] || fail "cache usage timestamp recorded"
sqlite3 "$DB" "SELECT CASE WHEN datetime('$latest_used') >= datetime('now','-1 minute') THEN 1 ELSE 0 END;" | grep -qx 1 || fail "cache usage timestamp refreshed"
pass "repository cache usage timestamp is refreshed"

# 12. A crash after setting status=GC is finalized before the interval gate.
mkdir -p "$MANUL_WORKSPACE/ws-interrupted-gc"
sqlite3 "$DB" "
  INSERT INTO workspaces(workspaceId,workspacePath,status,lastUsedAt)
  VALUES('ws-interrupted-gc','$MANUL_WORKSPACE/ws-interrupted-gc','GC',datetime('now'));
  INSERT INTO manul_workspace_gc_state(stateKey,stateValue)
  VALUES('lastRunAt',datetime('now'))
  ON CONFLICT(stateKey) DO UPDATE SET stateValue=excluded.stateValue;
"
workspace_gc_run false
! workspace_row_exists ws-interrupted-gc && ! workspace_dir_exists ws-interrupted-gc || fail "interrupted GC transaction finalized before interval return"
interrupted_archive="$(find "$MANUL_STATE_DIR/recovery/workspaces" -mindepth 1 -maxdepth 1 -type d -name 'ws-interrupted-gc-gc-interrupted-*' -print -quit)"
[ -n "$interrupted_archive" ] || fail "interrupted GC workspace preserved in recovery"
pass "interrupted workspace GC lease is safely archived and finalized inside the scheduled interval"

echo "All workspace GC tests passed."
