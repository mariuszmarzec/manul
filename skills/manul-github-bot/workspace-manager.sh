#!/bin/bash
# workspace-manager.sh: Manages workspace leasing for concurrency
#
# Provides functions for:
# - Creating and managing a pool of isolated workspaces
# - Leasing workspaces to tasks for exclusive access
# - Releasing workspaces back to the pool
# - Cleaning up broken workspaces

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
WORKSPACES_DIR="$MANUL_WORKSPACE"

: "${PID_FILE:=/dev/null}"
get_daemon_pid() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)"
  if [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "$pid"
  else
    echo "0"
  fi
}

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

workspace_init() {
  mkdir -p "$WORKSPACES_DIR"
  sqlite3 "$DB" "
    CREATE TABLE IF NOT EXISTS workspaces (
      workspaceId TEXT PRIMARY KEY,
      workspacePath TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'IDLE',
      currentTaskId TEXT,
      lastUsedAt TEXT
    );
    CREATE TABLE IF NOT EXISTS workspace_contexts (
      contextId TEXT PRIMARY KEY,
      parentContextId TEXT,
      workspaceId TEXT NOT NULL,
      repository TEXT,
      prNumber INTEGER,
      createdAt TEXT NOT NULL DEFAULT (datetime('now')),
      lastUsedAt TEXT NOT NULL DEFAULT (datetime('now'))
    );
  "
}

workspace_pool_init() {
  local pool_size="${1:-$((MAX_CONCURRENT_TASKS / 1))}"
  local reset="${2:-}"
  workspace_init
  if [ "$reset" = "reset" ]; then
    sqlite3 "$DB" "DELETE FROM workspace_contexts; DELETE FROM workspaces;" 2>/dev/null || true
  fi
  local current_size
  current_size="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces;" 2>/dev/null || echo 0)"
  local i
  for ((i = current_size; i < pool_size; i++)); do
    local ws_id="ws-$i-$(date +%s%N)-$$"
    local ws_path="$WORKSPACES_DIR/$ws_id"
    mkdir -p "$ws_path"
    sqlite3 "$DB" "INSERT OR IGNORE INTO workspaces(workspaceId, workspacePath, status, lastUsedAt) VALUES('$ws_id', '$ws_path', 'IDLE', datetime('now'));"
  done
}

workspace_lease() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local result
  result="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId IN (SELECT w.workspaceId FROM workspaces w WHERE w.status='IDLE' AND NOT EXISTS (SELECT 1 FROM workspace_contexts wc WHERE wc.workspaceId=w.workspaceId) LIMIT 1); SELECT changes(); COMMIT;" 2>/dev/null)"
  result="$(printf '%s\n' "$result" | tail -n1)"
  if [ "${result:-0}" -eq 0 ] || [ -z "$result" ]; then
    return 1
  fi
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}

workspace_release() {
  local ws_id="$1"
  local task_id="${2:-}"
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  local owns
  owns="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$safe_ws_id' AND status='BUSY';" 2>/dev/null)"
  if [ "${owns:-0}" -eq 0 ]; then
    return 1
  fi
  if [ -n "$task_id" ]; then
    local safe_task_id
    safe_task_id="$(sql_escape "$task_id")"
    local correct_owner
    correct_owner="$(sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id';" 2>/dev/null)"
    if [ "${correct_owner:-0}" -eq 0 ]; then
      return 1
    fi
  fi
  # Refresh the idle timestamp on every release so a legitimately reused
  # workspace is not mistaken for an abandoned idle workspace by stale cleanup.
  sqlite3 "$DB" "UPDATE workspaces SET status='IDLE', currentTaskId=NULL, lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id';"
}

# Restore the latest preserved snapshot for this exact workspace/task pair.
# It only runs for a task with an existing workspace mapping; it never scans
# or opens another task's recovery material.
workspace_restore_recovery_snapshot() {
  local ws_id="$1" task_id="$2"
  [[ "$ws_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [ -n "$task_id" ] || return 1
  local safe_task_id
  safe_task_id="$(printf '%s' "$task_id" | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-100)"

  local workspace_root archive_root root_real candidate_name candidate target row_owner row_status
  workspace_root="$WORKSPACES_DIR"
  [ ! -L "$workspace_root" ] || return 1
  root_real="$(realpath -e "$workspace_root" 2>/dev/null)" || return 1
  archive_root="$MANUL_STATE_DIR/recovery/workspaces"
  [ -d "$archive_root" ] && [ ! -L "$archive_root" ] || return 1
  archive_root="$(realpath -e "$archive_root" 2>/dev/null)" || return 1
  local expected_archive_root
  expected_archive_root="$(realpath -m "$MANUL_STATE_DIR/recovery/workspaces" 2>/dev/null)" || return 1
  [ "$archive_root" = "$expected_archive_root" ] || return 1

  candidate_name="$(find "$archive_root" -mindepth 1 -maxdepth 1 -type d -name "${ws_id}-${safe_task_id}-*" -printf '%f\n' 2>/dev/null | sort | tail -n 1)"
  [ -n "$candidate_name" ] || return 1
  candidate="$archive_root/$candidate_name"
  [ ! -L "$candidate" ] && [ -d "$candidate" ] || return 1
  target="$root_real/$ws_id"
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 1

  local row
  row="$(sqlite3 "$DB" "SELECT COALESCE(status,'') || '|' || COALESCE(currentTaskId,'') FROM workspaces WHERE workspaceId='$(sql_escape "$ws_id")' LIMIT 1;" 2>/dev/null || true)"
  if [ -n "$row" ]; then
    IFS='|' read -r row_status row_owner <<< "$row"
    case "$row_status:$row_owner" in
      BROKEN:*|IDLE:*|BUSY:"$task_id") ;;
      *) echo "workspace recovery: refusing to restore $ws_id; database row has another owner" >&2; return 1 ;;
    esac
  fi

  if ! mv -T -- "$candidate" "$target"; then
    echo "workspace recovery: failed to restore snapshot for $ws_id/$task_id" >&2
    return 1
  fi

  local safe_ws_id safe_task_id_sql safe_path upsert
  safe_ws_id="$(sql_escape "$ws_id")"
  safe_task_id_sql="$(sql_escape "$task_id")"
  safe_path="$(sql_escape "$target")"
  upsert="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000;
    BEGIN IMMEDIATE;
    INSERT INTO workspaces(workspaceId,workspacePath,status,currentTaskId,lastUsedAt)
      VALUES('$safe_ws_id','$safe_path','BUSY','$safe_task_id_sql',datetime('now'))
      ON CONFLICT(workspaceId) DO UPDATE SET workspacePath=excluded.workspacePath,status='BUSY',currentTaskId=excluded.currentTaskId,lastUsedAt=datetime('now')
      WHERE workspaces.status='BROKEN' OR workspaces.status='IDLE' OR (workspaces.status='BUSY' AND workspaces.currentTaskId=excluded.currentTaskId);
    SELECT changes();
    COMMIT;" 2>/dev/null | tail -n 1)" || upsert="0"
  if [ "$upsert" != "1" ]; then
    echo "workspace recovery: restored files but could not reclaim DB ownership; data remains at $target" >&2
    return 1
  fi

  local context_id repository issue_number
  context_id="$(sqlite3 "$DB" "SELECT COALESCE(conversationId,'') FROM processed_comments WHERE commentId='$safe_task_id_sql' LIMIT 1;" 2>/dev/null || true)"
  repository="$(sqlite3 "$DB" "SELECT COALESCE(repository,'') FROM processed_comments WHERE commentId='$safe_task_id_sql' LIMIT 1;" 2>/dev/null || true)"
  issue_number="$(sqlite3 "$DB" "SELECT COALESCE(issueNumber,'') FROM processed_comments WHERE commentId='$safe_task_id_sql' LIMIT 1;" 2>/dev/null || true)"
  if [ -n "$context_id" ]; then
    sqlite3 "$DB" "INSERT OR IGNORE INTO workspace_contexts(contextId,workspaceId,repository,prNumber,createdAt,lastUsedAt) VALUES('$(sql_escape "$context_id")','$safe_ws_id','$(sql_escape "$repository")',NULLIF('$(sql_escape "$issue_number")',''),datetime('now'),datetime('now'));" 2>/dev/null || true
  fi
  echo "workspace recovery: restored snapshot workspace=$ws_id task=$task_id path=$target" >&2
  printf '%s\n' "$ws_id"
}

# Atomically reclaim a previously-used workspace for a task whose processed_comments row points to it.
workspace_reclaim() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local ws_id
  ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
  [ -n "$ws_id" ] || return 1
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  local result
  result="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id' AND (status='IDLE' OR (status='BUSY' AND currentTaskId='$safe_task_id')); SELECT changes(); COMMIT;" 2>/dev/null)"
  result="$(printf '%s\n' "$result" | tail -n1)"
  if [ "${result:-0}" -ne 1 ] || [ -z "$result" ]; then
    local restored_ws
    restored_ws="$(workspace_restore_recovery_snapshot "$ws_id" "$task_id")" || return 1
    [ "$restored_ws" = "$ws_id" ] || return 1
    printf '%s\n' "$restored_ws"
    return 0
  fi

  # A cleanup DB transaction may fail after the directory was moved to recovery.
  # Never return a leased workspace path that does not exist on disk.
  if [ ! -d "$WORKSPACES_DIR/$ws_id" ] || [ -L "$WORKSPACES_DIR/$ws_id" ]; then
    local restored_ws
    restored_ws="$(workspace_restore_recovery_snapshot "$ws_id" "$task_id")" || return 1
    [ "$restored_ws" = "$ws_id" ] || return 1
    printf '%s\n' "$restored_ws"
    return 0
  fi
  sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null
}


workspace_claim_id() {
  local ws_id="$1"
  local task_id="$2"
  local safe_ws_id safe_task_id
  safe_ws_id="$(sql_escape "$ws_id")"
  safe_task_id="$(sql_escape "$task_id")"
  local result
  result="$(sqlite3 "$DB" "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; UPDATE workspaces SET status='BUSY', currentTaskId='$safe_task_id', lastUsedAt=datetime('now') WHERE workspaceId='$safe_ws_id' AND (status='IDLE' OR (status='BUSY' AND currentTaskId='$safe_task_id')); SELECT changes(); COMMIT;" 2>/dev/null)"
  result="$(printf '%s\n' "$result" | tail -n1)"
  [ "${result:-0}" -eq 1 ] || return 1
}

# Acquire a workspace for a logical context (PR or review thread).
#
# Resolution order:
#   1. Exact context mapping (same thread / same PR)
#   2. Parent context mapping (review thread -> PR)
#   3. A fresh unbound workspace
#
# Return codes:
#   0 = acquired, stdout contains workspaceId
#   1 = no workspace currently available
#   2 = context workspace exists but is busy with another task
workspace_context_acquire() {
  local task_id="$1"
  local context_id="$2"
  local parent_context_id="${3:-}"
  local repository="${4:-}"
  local pr_number="${5:-}"

  [ -n "$task_id" ] || return 1
  [ -n "$context_id" ] || return 1

  local safe_context_id safe_parent_id safe_repo
  safe_context_id="$(sql_escape "$context_id")"
  safe_parent_id="$(sql_escape "$parent_context_id")"
  safe_repo="$(sql_escape "$repository")"

  local mapped_ws
  mapped_ws="$(sqlite3 "$DB" "SELECT workspaceId FROM workspace_contexts WHERE contextId='$safe_context_id' LIMIT 1;" 2>/dev/null || true)"

  if [ -n "$mapped_ws" ]; then
    if workspace_claim_id "$mapped_ws" "$task_id"; then
      sqlite3 "$DB" "UPDATE workspace_contexts SET lastUsedAt=datetime('now') WHERE contextId='$safe_context_id';" 2>/dev/null || true
      printf '%s\n' "$mapped_ws"
      return 0
    fi
    return 2
  fi

  if [ -n "$parent_context_id" ]; then
    local parent_ws
    parent_ws="$(sqlite3 "$DB" "SELECT workspaceId FROM workspace_contexts WHERE contextId='$safe_parent_id' LIMIT 1;" 2>/dev/null || true)"
    if [ -n "$parent_ws" ]; then
      if workspace_claim_id "$parent_ws" "$task_id"; then
        sqlite3 "$DB" "
          INSERT OR IGNORE INTO workspace_contexts(contextId,parentContextId,workspaceId,repository,prNumber,createdAt,lastUsedAt)
          VALUES('$safe_context_id','$safe_parent_id','$(sql_escape "$parent_ws")','$safe_repo',${pr_number:-NULL},datetime('now'),datetime('now'));
        " 2>/dev/null || true
        printf '%s\n' "$parent_ws"
        return 0
      fi
      return 2
    fi
  fi

  local ws_id
  ws_id="$(workspace_lease "$task_id" 2>/dev/null || true)"
  if [ -z "$ws_id" ]; then
    # Context persistence is independent from the concurrency pool size.
    # When there is concurrency capacity but every idle workspace already
    # belongs to another context, create a fresh workspace for this new leaf.
    local busy_count max_concurrent
    busy_count="$(workspace_busy_count)"
    max_concurrent="${MAX_CONCURRENT_TASKS:-1}"
    if [ "${busy_count:-0}" -ge "${max_concurrent:-1}" ]; then
      return 1
    fi

    local new_index ws_id ws_path
    new_index="$(sqlite3 "$DB" "SELECT COALESCE(MAX(CAST(substr(workspaceId,4,instr(substr(workspaceId,4),'-')-1) AS INTEGER)), -1) + 1 FROM workspaces WHERE workspaceId LIKE 'ws-%';" 2>/dev/null || echo 0)"
    ws_id="ws-${new_index}-$(date +%s)"
    ws_path="$WORKSPACES_DIR/$ws_id"
    mkdir -p "$ws_path" || return 1
    if ! sqlite3 "$DB" "INSERT INTO workspaces(workspaceId,workspacePath,status,currentTaskId,lastUsedAt) VALUES('$(sql_escape "$ws_id")','$(sql_escape "$ws_path")','BUSY','$(sql_escape "$task_id")',datetime('now'));" 2>/dev/null; then
      rm -rf "$ws_path"
      return 1
    fi
  fi

  if ! sqlite3 "$DB" "
    INSERT OR REPLACE INTO workspace_contexts(
      contextId,parentContextId,workspaceId,repository,prNumber,createdAt,lastUsedAt
    )
    VALUES(
      '$safe_context_id',
      NULLIF('$safe_parent_id',''),
      '$(sql_escape "$ws_id")',
      '$safe_repo',
      ${pr_number:-NULL},
      datetime('now'),
      datetime('now')
    );
  " 2>/dev/null; then
    workspace_release "$ws_id" "$task_id" >/dev/null 2>&1 || true
    return 1
  fi

  printf '%s\n' "$ws_id"
}

# Prepare the explicitly requested PR head branch. If a branch switch is
# blocked by stale/dirty checkout state, build a fresh checkout at that PR branch
# and keep the old checkout in task-local recovery storage. Never assume master.
workspace_prepare_pr_branch() {
  local workdir="$1"
  local branch="$2"
  local workspace_root="" repository=""
  if [ "$#" -ge 4 ]; then
    workspace_root="$3"
    repository="$4"
  fi

  [ -n "$branch" ] || return 1
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1

  if [ ! -d "$workdir/.git" ] || [ -L "$workdir/.git" ]; then
    echo "workspace_prepare_pr_branch: checkout Git metadata is invalid" >&2
    if [ -n "$workspace_root" ] && [ -n "$repository" ] &&
       workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
      return 0
    fi
    return 1
  fi

  if ! git -C "$workdir" fetch origin "$branch" >/dev/null 2>&1; then
    echo "workspace_prepare_pr_branch: fetch of PR head '$branch' failed; attempting a fresh clone of that exact branch" >&2
    if [ -n "$workspace_root" ] && [ -n "$repository" ] &&
       workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
      return 0
    fi
    return 1
  fi

  local current_branch
  current_branch="$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null || true)"
  local dirty
  dirty="$(git -C "$workdir" status --porcelain 2>/dev/null || true)"

  if [ "$current_branch" != "$branch" ]; then
    if [ -n "$dirty" ]; then
      echo "workspace_prepare_pr_branch: checkout of PR head '$branch' is blocked by a dirty checkout" >&2
      if [ -n "$workspace_root" ] && [ -n "$repository" ] &&
         workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
        return 0
      fi
      return 2
    fi

    if git -C "$workdir" show-ref --verify --quiet "refs/heads/$branch"; then
      if ! git -C "$workdir" checkout "$branch" >/dev/null 2>&1; then
        echo "workspace_prepare_pr_branch: checkout of local PR head '$branch' failed" >&2
        if [ -n "$workspace_root" ] && [ -n "$repository" ] &&
           workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
          return 0
        fi
        return 1
      fi
    else
      if ! git -C "$workdir" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1; then
        echo "workspace_prepare_pr_branch: checkout of remote PR head '$branch' failed" >&2
        if [ -n "$workspace_root" ] && [ -n "$repository" ] &&
           workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
          return 0
        fi
        return 1
      fi
    fi
  fi

  dirty="$(git -C "$workdir" status --porcelain 2>/dev/null || true)"
  if [ -z "$dirty" ]; then
    local local_head remote_head
    local_head="$(git -C "$workdir" rev-parse HEAD 2>/dev/null || true)"
    remote_head="$(git -C "$workdir" rev-parse "origin/$branch" 2>/dev/null || true)"
    if [ -n "$local_head" ] && [ -n "$remote_head" ] && [ "$local_head" != "$remote_head" ]; then
      if git -C "$workdir" merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
        if ! git -C "$workdir" merge --ff-only "$remote_head" >/dev/null 2>&1; then
          echo "workspace_prepare_pr_branch: fast-forward to PR head '$branch' failed" >&2
          if [ -n "$workspace_root" ] && [ -n "$repository" ] &&
             workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
            return 0
          fi
          return 1
        fi
      else
        echo "workspace_prepare_pr_branch: preserving local commits (local=$local_head remote=$remote_head)" >&2
      fi
    fi
  else
    echo "workspace_prepare_pr_branch: preserving dirty checkout already on PR head '$branch' at $workdir" >&2
  fi

  if ! workspace_sync_submodules "$workdir"; then
    echo "workspace_prepare_pr_branch: submodule initialization failed for '$branch'" >&2
    return 1
  fi
  [ "$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)" = "$branch" ]
}

# Move a workspace that is about to be discarded into a private recovery
# area. This is a rename (not a copy), so large working trees and uncommitted
# files survive host/worker recovery without leaving two writable checkouts.
# The recovery area is under runtime state, never under another task workspace
# and never included in the OpenCode workspace allowlist.
workspace_preserve_recovery_snapshot() {
  local ws_id="$1" requested_task_id="${2:-}"
  [[ "$ws_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "workspace recovery: invalid workspace id; refusing to discard it" >&2
    return 1
  }

  local workspace_path="$WORKSPACES_DIR/$ws_id"
  if [ ! -e "$workspace_path" ] && [ ! -L "$workspace_path" ]; then
    return 0
  fi
  if [ -L "$workspace_path" ] || [ ! -d "$workspace_path" ]; then
    echo "workspace recovery: refusing unsafe workspace path: $workspace_path" >&2
    return 1
  fi

  local workspaces_real workspace_real manul_real state_real recovery_root task_id safe_task_id destination
  workspaces_real="$(realpath -e "$WORKSPACES_DIR" 2>/dev/null)" || return 1
  workspace_real="$(realpath -e "$workspace_path" 2>/dev/null)" || return 1
  case "$workspace_real" in
    "$workspaces_real"/*) ;;
    *) echo "workspace recovery: workspace path escaped its root; preserving in place" >&2; return 1 ;;
  esac

  task_id="$requested_task_id"
  if [ -z "$task_id" ]; then
    task_id="$(sqlite3 "$DB" "SELECT COALESCE(currentTaskId,'') FROM workspaces WHERE workspaceId='$(sql_escape "$ws_id")' LIMIT 1;" 2>/dev/null || true)"
  fi
  safe_task_id="$(printf '%s' "${task_id:-unmapped}" | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-100)"
  manul_real="$(realpath -e "$MANUL_DIR" 2>/dev/null)" || return 1
  mkdir -p "$MANUL_STATE_DIR/recovery/workspaces" || return 1
  state_real="$(realpath -e "$MANUL_STATE_DIR" 2>/dev/null)" || return 1
  case "$state_real" in
    "$manul_real"/state) ;;
    *) echo "workspace recovery: runtime state path escaped MANUL_DIR; preserving in place" >&2; return 1 ;;
  esac
  recovery_root="$(realpath -e "$state_real/recovery/workspaces" 2>/dev/null)" || return 1
  case "$recovery_root" in
    "$state_real"/recovery/workspaces) ;;
    *) echo "workspace recovery: recovery path is not canonical; preserving in place" >&2; return 1 ;;
  esac
  chmod 700 "$state_real/recovery" "$recovery_root" 2>/dev/null || return 1

  destination="$recovery_root/${ws_id}-${safe_task_id}-$(date -u +%Y%m%dT%H%M%S%N)-$"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || {
    echo "workspace recovery: destination already exists; preserving in place" >&2
    return 1
  }
  if ! mv -T -- "$workspace_real" "$destination"; then
    echo "workspace recovery: failed to preserve $workspace_path; refusing deletion" >&2
    return 1
  fi
  chmod 700 "$destination" 2>/dev/null || true
  echo "workspace recovery: preserved workspace=$ws_id task=${task_id:-unmapped} path=$destination" >&2
}

workspace_mark_broken() {
  local ws_id="$1"
  local safe_ws_id
  safe_ws_id="$(sql_escape "$ws_id")"
  if ! workspace_preserve_recovery_snapshot "$ws_id"; then
    echo "workspace_mark_broken: recovery snapshot failed; workspace remains registered and on disk" >&2
    return 1
  fi
  sqlite3 "$DB" "BEGIN IMMEDIATE; DELETE FROM workspace_contexts WHERE workspaceId='$safe_ws_id'; UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$safe_ws_id'; COMMIT;" 2>/dev/null
}

workspace_repo_matches() {
  local task_repo="$1"
  local actual_repo="$2"

  # Normalize GitHub HTTPS/SSH URLs to owner/repo.
  local normalized_actual="${actual_repo#https://github.com/}"
  normalized_actual="${normalized_actual#http://github.com/}"
  normalized_actual="${normalized_actual#git@github.com:}"
  normalized_actual="${normalized_actual#ssh://git@github.com/}"
  normalized_actual="${normalized_actual#github.com/}"
  normalized_actual="${normalized_actual%.git}"
  normalized_actual="${normalized_actual%/}"
  [ "$normalized_actual" = "$task_repo" ] && return 0

  # `git clone --local` can leave a local filesystem path as origin.
  # The workspace directory structure is $MANUL_DIR/workspace/<slug>
  # where <slug> is derived from owner/repo by replacing '/' with '-'.
  if [[ "$actual_repo" == /* ]]; then
    local resolved_path="${actual_repo%.git}"

    # Check if this is a known workspace path pattern
    if [[ "$resolved_path" == */workspace/* ]]; then
      local slug="${resolved_path##*/workspace/}"
      # Compute expected slug from task_repo (replaces '/' with '-')
      local expected_slug
      expected_slug="$(printf '%s' "$task_repo" | sed 's/\//-/g')"
      [ "$slug" = "$expected_slug" ] && return 0
    fi

    # Fallback: compare path components for arbitrary local paths
    local owner repo_name
    owner="$(basename "$(dirname "$actual_repo")")"
    repo_name="$(basename "$actual_repo")"
    repo_name="${repo_name%.git}"
    [ "${owner}/${repo_name}" = "$task_repo" ] && return 0

    local resolved_origin
    if resolved_origin="$(realpath -e "$actual_repo" 2>/dev/null)"; then
      owner="$(basename "$(dirname "$resolved_origin")")"
      repo_name="$(basename "$resolved_origin")"
      repo_name="${repo_name%.git}"
      [ "${owner}/${repo_name}" = "$task_repo" ] && return 0
    fi
  fi

  return 1
}


# Convert a GitHub owner/repository identifier to a safe workspace-relative path.
workspace_repo_relative_path() {
  local repository="${1:-}" owner repo_name
  [[ "$repository" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] || return 1
  owner="$(printf '%s' "$repository" | cut -d/ -f1)"
  repo_name="$(printf '%s' "$repository" | cut -d/ -f2)"
  [ "$owner" != "." ] && [ "$owner" != ".." ] || return 1
  [ "$repo_name" != "." ] && [ "$repo_name" != ".." ] || return 1
  printf 'repos/%s/%s\n' "$owner" "$repo_name"
}

# Resolve a nested checkout path strictly inside the leased workspace root.
# Symlinked path components are rejected to prevent path traversal.
workspace_primary_repo_path() {
  local workspace_root="$1" repository="$2"
  local relative root_real owner repo_name repos_path owner_path checkout_path resolved
  relative="$(workspace_repo_relative_path "$repository")" || return 1
  root_real="$(realpath -e "$workspace_root" 2>/dev/null)" || return 1
  [ -d "$root_real" ] || return 1
  repos_path="$root_real/repos"
  [ ! -L "$repos_path" ] || return 1
  mkdir -p "$repos_path" || return 1
  [ "$(realpath -e "$repos_path" 2>/dev/null)" = "$root_real/repos" ] || return 1
  owner="$(printf '%s' "$relative" | cut -d/ -f2)"
  repo_name="$(basename "$relative")"
  owner_path="$repos_path/$owner"
  [ ! -L "$owner_path" ] || return 1
  mkdir -p "$owner_path" || return 1
  [ "$(realpath -e "$owner_path" 2>/dev/null)" = "$repos_path/$owner" ] || return 1
  checkout_path="$owner_path/$repo_name"
  [ ! -L "$checkout_path" ] || return 1
  resolved="$(realpath -m "$checkout_path" 2>/dev/null)" || return 1
  case "$resolved" in "$root_real"/*) ;; *) return 1 ;; esac
  [ "$resolved" = "$checkout_path" ] || return 1
  printf '%s\n' "$checkout_path"
}

# Move an existing legacy root checkout as one unit. This preserves .git,
# ignored files, local commits, and dirty PR work across the layout migration.
workspace_migrate_legacy_checkout() {
  local workspace_root="$1" repository="$2"
  local relative root_real actual_root actual_origin workspace_parent workspace_name staging owner repo_name
  root_real="$(realpath -e "$workspace_root" 2>/dev/null)" || return 1
  [ -e "$root_real/.git" ] || return 0
  [ ! -L "$root_real/.git" ] || return 1
  actual_root="$(git -C "$root_real" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$actual_root" ] && [ "$(realpath -e "$actual_root" 2>/dev/null)" = "$root_real" ] || return 1
  actual_origin="$(git -C "$root_real" remote get-url origin 2>/dev/null || true)"
  workspace_repo_matches "$repository" "$actual_origin" || return 2
  relative="$(workspace_repo_relative_path "$repository")" || return 1
  owner="$(printf '%s' "$relative" | cut -d/ -f2)"
  repo_name="$(basename "$relative")"
  workspace_parent="$(dirname "$root_real")"
  workspace_name="$(basename "$root_real")"
  staging="$workspace_parent/.${workspace_name}.migration.$$"
  [ ! -e "$staging" ] || return 1
  mv "$root_real" "$staging" || return 1
  if ! mkdir -p "$root_real/repos/$owner"; then
    rmdir "$root_real" 2>/dev/null || true
    mv "$staging" "$root_real" 2>/dev/null || true
    return 1
  fi
  if ! mv "$staging" "$root_real/repos/$owner/$repo_name"; then
    rmdir "$root_real/repos/$owner" "$root_real/repos" "$root_real" 2>/dev/null || true
    mv "$staging" "$root_real" 2>/dev/null || true
    return 1
  fi
  return 0
}

# Prepare the primary checkout inside the task root. Never erase an existing
# mismatched checkout because it may hold unpushed commits or user changes.
# Initialize nested repositories after every branch change. The shared
# repository cache is intentionally only a bare source; it does not guarantee
# that nested Git submodules have been initialized in task-local checkouts.
workspace_sync_submodules() {
  local workdir="$1"
  [ -f "$workdir/.gitmodules" ] || return 0

  if ! git -C "$workdir" submodule sync --recursive >&2; then
    echo "workspace_sync_submodules: failed to synchronize submodule URLs in $workdir" >&2
    return 1
  fi
  if ! git -C "$workdir" submodule update --init --recursive >&2; then
    echo "workspace_sync_submodules: failed to initialize nested repositories in $workdir" >&2
    return 1
  fi
}

workspace_prepare_primary_checkout() {
  local workspace_root="$1" repository="$2" repo_cache="$3"
  local checkout actual_origin
  workspace_migrate_legacy_checkout "$workspace_root" "$repository" || return $?
  checkout="$(workspace_primary_repo_path "$workspace_root" "$repository")" || return 1
  if [ -e "$checkout" ]; then
    if [ ! -e "$checkout/.git" ] || [ -L "$checkout/.git" ]; then
      return 2
    fi
    actual_origin="$(git -C "$checkout" remote get-url origin 2>/dev/null || true)"
    workspace_repo_matches "$repository" "$actual_origin" || return 2
  else
    [ -d "$repo_cache/.git" ] || return 1
    if ! git clone --local --no-hardlinks "$repo_cache" "$checkout" 2>/dev/null; then
      [ ! -e "$checkout" ] || rm -rf -- "$checkout"
      return 1
    fi
    git -C "$checkout" remote set-url origin "https://github.com/$repository" || return 1
  fi
  if ! workspace_sync_submodules "$checkout"; then
    echo "workspace_prepare_primary_checkout: nested repository initialization failed for '$repository'" >&2
    return 1
  fi
  mkdir -p "$(realpath -e "$workspace_root")/tmp" || return 1
  printf '%s\n' "$checkout"
}



# Rebuild a broken checkout by cloning the exact requested branch from its
# remote. The old checkout is preserved under this task's tmp directory before
# replacement; the shared repository cache is never changed by this fallback.
workspace_recover_primary_checkout() {
  local workspace_root="$1" repository="$2" source_checkout="$3" branch="$4"
  [ -n "$workspace_root" ] && [ -n "$repository" ] && [ -n "$source_checkout" ] && [ -n "$branch" ] || return 1
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || {
    echo "workspace_recover_primary_checkout: invalid target branch '$branch'" >&2
    return 1
  }

  local root_real checkout checkout_parent source_checkout_real repo_name origin_url
  root_real="$(realpath -e "$workspace_root" 2>/dev/null)" || return 1
  checkout="$(workspace_primary_repo_path "$root_real" "$repository" 2>/dev/null)" || return 1
  checkout_parent="$(dirname "$checkout")"
  repo_name="$(basename "$checkout")"
  source_checkout_real="$(realpath -e "$source_checkout" 2>/dev/null || true)"
  origin_url=""

  # Only reuse an origin URL from the exact expected primary checkout and only
  # when it still identifies the requested repository. Otherwise use its
  # canonical GitHub URL; no sibling checkout or shared cache is consulted.
  if [ -n "$source_checkout_real" ] && [ "$source_checkout_real" = "$checkout" ] &&
     [ -e "$source_checkout_real/.git" ] && [ ! -L "$source_checkout_real/.git" ]; then
    origin_url="$(git -C "$source_checkout_real" remote get-url origin 2>/dev/null || true)"
    if [ -n "$origin_url" ] && ! workspace_repo_matches "$repository" "$origin_url"; then
      echo "workspace_recover_primary_checkout: origin did not match '$repository'; using its canonical remote URL" >&2
      origin_url=""
    fi
  fi
  if [ -z "$origin_url" ]; then
    origin_url="https://github.com/$repository"
  fi

  local temp_checkout="$checkout_parent/.$repo_name.recovery-$(date +%s%N)"
  if [ -e "$temp_checkout" ] || [ -L "$temp_checkout" ]; then
    echo "workspace_recover_primary_checkout: temporary checkout path already exists; refusing to overwrite it" >&2
    return 1
  fi

  local tmp_root="$root_real/tmp"
  [ ! -L "$tmp_root" ] || {
    echo "workspace_recover_primary_checkout: task tmp path is a symlink" >&2
    return 1
  }
  mkdir -p "$tmp_root" || return 1
  [ "$(realpath -e "$tmp_root" 2>/dev/null)" = "$tmp_root" ] || return 1
  local recovery_root="$tmp_root/checkout-recovery"
  [ ! -L "$recovery_root" ] || {
    echo "workspace_recover_primary_checkout: recovery path is a symlink" >&2
    return 1
  }
  mkdir -p "$recovery_root" || return 1
  recovery_root="$(realpath -e "$recovery_root" 2>/dev/null)" || return 1
  case "$recovery_root" in "$root_real"/*) ;; *)
    echo "workspace_recover_primary_checkout: recovery path escaped the task workspace" >&2
    return 1
    ;;
  esac

  # Clone exactly the requested branch from the repository remote. This also
  # repairs a checkout whose local Git metadata is unusable, without guessing a
  # default branch. If the requested branch cannot be fetched, leave the old
  # checkout at its original path and report the blocker.
  if ! git clone --quiet --recurse-submodules --single-branch --branch "$branch" --no-hardlinks "$origin_url" "$temp_checkout"; then
    [ ! -e "$temp_checkout" ] || rm -rf -- "$temp_checkout"
    echo "workspace_recover_primary_checkout: could not clone remote branch '$branch' from '$origin_url'" >&2
    return 1
  fi
  local expected_head
  expected_head="$(git -C "$temp_checkout" rev-parse "refs/remotes/origin/$branch^{commit}" 2>/dev/null)" || {
    rm -rf -- "$temp_checkout"
    echo "workspace_recover_primary_checkout: remote tracking ref for '$branch' is missing after clone" >&2
    return 1
  }
  if [ "$(git -C "$temp_checkout" symbolic-ref --short HEAD 2>/dev/null)" != "$branch" ] ||
     [ "$(git -C "$temp_checkout" rev-parse HEAD 2>/dev/null)" != "$expected_head" ] ||
     [ -n "$(git -C "$temp_checkout" status --porcelain 2>/dev/null)" ]; then
    rm -rf -- "$temp_checkout"
    echo "workspace_recover_primary_checkout: fresh checkout verification failed for '$branch'" >&2
    return 1
  fi

  local backup="" branch_slug recovery_stamp suffix=0 existing_real
  branch_slug="$(printf '%s' "$branch" | sed 's#[^A-Za-z0-9._-]#_#g')"
  recovery_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$(date +%s%N)"
  backup="$recovery_root/$repo_name-$branch_slug-$recovery_stamp"
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    suffix=$((suffix + 1))
    backup="$recovery_root/$repo_name-$branch_slug-$recovery_stamp-$suffix"
  done

  if [ -e "$checkout" ] || [ -L "$checkout" ]; then
    if [ ! -d "$checkout" ] || [ -L "$checkout" ]; then
      rm -rf -- "$temp_checkout"
      echo "workspace_recover_primary_checkout: existing checkout path is not a safe directory; it was left untouched" >&2
      return 1
    fi
    existing_real="$(realpath -e "$checkout" 2>/dev/null || true)"
    if [ -z "$existing_real" ] || [ "$existing_real" != "$checkout" ]; then
      rm -rf -- "$temp_checkout"
      echo "workspace_recover_primary_checkout: existing checkout path is invalid; it was left untouched" >&2
      return 1
    fi
    if ! mv -- "$checkout" "$backup"; then
      rm -rf -- "$temp_checkout"
      echo "workspace_recover_primary_checkout: could not archive existing checkout; it was left untouched" >&2
      return 1
    fi
  fi

  if ! mv -- "$temp_checkout" "$checkout"; then
    if [ -d "$backup" ] && [ ! -e "$checkout" ] && [ ! -L "$checkout" ]; then
      mv -- "$backup" "$checkout" 2>/dev/null || true
    fi
    echo "workspace_recover_primary_checkout: could not install fresh checkout; previous data remains in recovery storage at '$backup'" >&2
    return 1
  fi

  if [ -d "$backup" ]; then
    echo "workspace_recover_primary_checkout: rebuilt '$repository' at '$branch' ($expected_head); previous checkout preserved at '$backup'" >&2
  else
    echo "workspace_recover_primary_checkout: created '$repository' at '$branch' ($expected_head)" >&2
  fi
  return 0
}

# Prepare an issue-task checkout at the resolved base branch. The caller fetches
# origin and chooses the base branch first. Failures trigger a fresh clone at
# that same branch, never a fallback to an assumed default.
workspace_prepare_task_base_branch() {
  local workdir="$1" branch="$2" workspace_root="$3" repository="$4"
  [ -n "$branch" ] || return 1
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1

  if [ ! -d "$workdir/.git" ] ||
     ! git -C "$workdir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    echo "workspace_prepare_task_base_branch: Git metadata or origin ref for '$branch' is unavailable; attempting branch-specific recovery" >&2
    if workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
      return 0
    fi
    return 1
  fi

  local failed_step=""
  if ! git -C "$workdir" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1; then
    failed_step="checkout"
  elif ! git -C "$workdir" reset --hard "origin/$branch" --quiet 2>/dev/null; then
    failed_step="reset"
  elif ! git -C "$workdir" clean -fd --quiet 2>/dev/null; then
    failed_step="clean"
  elif [ "$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)" != "$branch" ] ||
       [ "$(git -C "$workdir" rev-parse HEAD 2>/dev/null)" != "$(git -C "$workdir" rev-parse "origin/$branch" 2>/dev/null)" ]; then
    failed_step="verification"
  fi

  if [ -z "$failed_step" ]; then
    if ! workspace_sync_submodules "$workdir"; then
      echo "workspace_prepare_task_base_branch: submodule initialization failed for '$branch'" >&2
      return 1
    fi
    return 0
  fi

  echo "workspace_prepare_task_base_branch: ordinary '$failed_step' failed for target '$branch'; trying a fresh clone at the same target" >&2
  if workspace_recover_primary_checkout "$workspace_root" "$repository" "$workdir" "$branch"; then
    if [ "$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)" = "$branch" ] &&
       [ "$(git -C "$workdir" rev-parse HEAD 2>/dev/null)" = "$(git -C "$workdir" rev-parse "origin/$branch" 2>/dev/null)" ]; then
      echo "workspace_prepare_task_base_branch: recovered checkout at '$branch'" >&2
      return 0
    fi
  fi
  echo "workspace_prepare_task_base_branch: recovery failed for target '$branch'; original checkout remains preserved when possible" >&2
  return 1
}

# Clone configured related repositories into this task's workspace. The shared
# cache is a source only. Related repos are read-only by default; dirty/diverged
# prior checkouts are preserved and reported instead of destructively reset.
workspace_prepare_related_checkouts() {
  local workspace_root="$1" primary_repository="$2"
  shift 2
  WORKSPACE_RELATED_PATHS=""
  WORKSPACE_RELATED_UNAVAILABLE=""
  local repository cache cache_rc checkout relative actual_origin branch local_head cache_head
  for repository in "$@"; do
    [ -n "$repository" ] || continue
    if [ "$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$primary_repository" | tr '[:upper:]' '[:lower:]')" ]; then
      continue
    fi
    relative="$(workspace_repo_relative_path "$repository" 2>/dev/null || true)"
    if [ -z "$relative" ]; then
      [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
      WORKSPACE_RELATED_UNAVAILABLE+="- $repository: invalid repository identifier"
      continue
    fi
    checkout="$(workspace_primary_repo_path "$workspace_root" "$repository" 2>/dev/null || true)"
    if [ -z "$checkout" ]; then
      [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
      WORKSPACE_RELATED_UNAVAILABLE+="- $repository: unsafe checkout path"
      continue
    fi
    cache_rc=0
    cache="$(ensure_repo "$repository")" || cache_rc=$?
    if [ "$cache_rc" -ne 0 ] || [ -z "$cache" ] || [ ! -d "$cache/.git" ]; then
      [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
      WORKSPACE_RELATED_UNAVAILABLE+="- $repository: shared cache unavailable (status $cache_rc)"
      continue
    fi

    if [ ! -e "$checkout" ]; then
      if git clone --local --no-hardlinks "$cache" "$checkout" >/dev/null 2>&1; then
        if ! git -C "$checkout" remote set-url origin "https://github.com/$repository" >/dev/null 2>&1; then
          rm -rf -- "$checkout"
          [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
          WORKSPACE_RELATED_UNAVAILABLE+="- $repository: failed to configure origin"
          release_repo_lock "$repository"
          continue
        fi
      else
        [ ! -e "$checkout" ] || rm -rf -- "$checkout"
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: clone failed"
        release_repo_lock "$repository"
        continue
      fi
    else
      if [ ! -e "$checkout/.git" ] || [ -L "$checkout/.git" ]; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout is not a Git repository; preserved"
        release_repo_lock "$repository"
        continue
      fi
      actual_origin="$(git -C "$checkout" remote get-url origin 2>/dev/null || true)"
      if ! workspace_repo_matches "$repository" "$actual_origin"; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout origin mismatch; preserved"
        release_repo_lock "$repository"
        continue
      fi
      if ! git -C "$checkout" diff --quiet 2>/dev/null || ! git -C "$checkout" diff --cached --quiet 2>/dev/null; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout has tracked changes; preserved"
        release_repo_lock "$repository"
        continue
      fi
      branch="$(git -C "$cache" symbolic-ref --short HEAD 2>/dev/null || git -C "$cache" branch --show-current 2>/dev/null || true)"
      if [ -z "$branch" ] || [ "$(git -C "$checkout" symbolic-ref --short HEAD 2>/dev/null || true)" != "$branch" ]; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: existing checkout is on a different/detached branch; preserved"
        release_repo_lock "$repository"
        continue
      fi
      if ! git -C "$checkout" fetch --quiet "$cache" "+refs/heads/$branch:refs/remotes/manul-cache/$branch" 2>/dev/null; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: could not refresh from the current cache"
        release_repo_lock "$repository"
        continue
      fi
      local_head="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
      cache_head="$(git -C "$checkout" rev-parse "refs/remotes/manul-cache/$branch" 2>/dev/null || true)"
      if [ -z "$cache_head" ]; then
        [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
        WORKSPACE_RELATED_UNAVAILABLE+="- $repository: refreshed branch ref is missing"
        release_repo_lock "$repository"
        continue
      elif [ "$local_head" != "$cache_head" ]; then
        if git -C "$checkout" merge-base --is-ancestor "$local_head" "$cache_head" 2>/dev/null; then
          if ! git -C "$checkout" merge --ff-only "$cache_head" >/dev/null 2>&1; then
            [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
            WORKSPACE_RELATED_UNAVAILABLE+="- $repository: fast-forward refresh failed; preserved"
            release_repo_lock "$repository"
            continue
          fi
        else
          [ -z "$WORKSPACE_RELATED_UNAVAILABLE" ] || WORKSPACE_RELATED_UNAVAILABLE+=$'\n'
          WORKSPACE_RELATED_UNAVAILABLE+="- $repository: local commits would be overwritten by refresh; preserved"
          release_repo_lock "$repository"
          continue
        fi
      fi
    fi
    release_repo_lock "$repository"
    [ -z "$WORKSPACE_RELATED_PATHS" ] || WORKSPACE_RELATED_PATHS+=$'\n'
    WORKSPACE_RELATED_PATHS+="- $repository: $relative (read-only)"
  done
  return 0
}

workspace_get_path() {
  local task_id="$1"
  local safe_task_id
  safe_task_id="$(sql_escape "$task_id")"
  local expected_ws_id="${2:-}"
  local safe_ws_id=""
  local mapped_ws_id=""
  local path

  # Prefer an explicit lease ID from dispatch. For helper callers that do not
  # pass one, follow the task's persisted mapping before using the legacy
  # currentTaskId lookup used by context-only test fixtures.
  if [ -z "$expected_ws_id" ]; then
    expected_ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null || true)"
  fi
  if [ -n "$expected_ws_id" ]; then
    safe_ws_id="$(sql_escape "$expected_ws_id")"
    path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  else
    path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
  fi

  if [ -z "$path" ]; then
    mapped_ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null || true)"
    # Reclaim only if the task's persisted mapping agrees with the explicit
    # lease, otherwise fail closed instead of reclaiming another workspace.
    if [ -z "$expected_ws_id" ] || [ "$mapped_ws_id" = "$expected_ws_id" ]; then
      workspace_reclaim "$task_id" >/dev/null 2>&1 || true
      if [ -n "$expected_ws_id" ]; then
        path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
      else
        path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null)"
      fi
    fi
  fi

  # Resolve and validate the workspace root before probing any checkout.
  # A DB value or symlink must never make this helper inspect another workspace.
  if [ -n "$path" ]; then
    local root_real expected_path expected_real registered_real
    if [ -z "$expected_ws_id" ]; then
      expected_ws_id="$(sqlite3 "$DB" "SELECT workspaceId FROM workspaces WHERE currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null || true)"
    fi
    root_real="$(realpath -e "$WORKSPACES_DIR" 2>/dev/null || true)"
    expected_path="$WORKSPACES_DIR/$expected_ws_id"
    expected_real="$(realpath -e "$expected_path" 2>/dev/null || true)"
    registered_real="$(realpath -e "$path" 2>/dev/null || true)"

    # A persisted BUSY lease may outlive the physical workspace directory (for
    # example after a runtime cleanup or host restart). Recreate only the exact
    # canonical directory owned by this task; never follow a symlink or trust a
    # path supplied only by the database. The repository checkout is rebuilt
    # later from its shared cache, while all ownership checks remain fail-closed.
    if [ -n "$root_real" ] &&
       [[ "$expected_ws_id" =~ ^ws-[A-Za-z0-9._-]+$ ]] &&
       [ "$path" = "$expected_path" ] &&
       [ -z "$expected_real" ] &&
       [ ! -e "$expected_path" ] &&
       [ ! -L "$expected_path" ] &&
       [ "$(realpath -e "$(dirname "$expected_path")" 2>/dev/null || true)" = "$root_real" ]; then
      if mkdir -- "$expected_path" 2>/dev/null; then
        expected_real="$(realpath -e "$expected_path" 2>/dev/null || true)"
        registered_real="$(realpath -e "$path" 2>/dev/null || true)"
      fi
    fi

    if [ -z "$root_real" ] || [ -z "$expected_ws_id" ] || [ -L "$expected_path" ] || [ -L "$path" ] || [ -z "$expected_real" ] || [ "$expected_real" != "$root_real/$expected_ws_id" ] || [ "$registered_real" != "$expected_real" ]; then
      path=""
    fi
  fi
  [ -n "$path" ] || { printf '\n'; return 0; }

  # Validate root and nested primary checkouts. Preserve mismatched checkout
  # state because it may contain unpushed PR commits or uncommitted changes.
  if [ -n "$path" ]; then
    local task_repo actual_repo candidate_checkout relative
    task_repo="$(sqlite3 "$DB" "SELECT repository FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)"
    candidate_checkout="$path"
    if [ -n "$task_repo" ] && [ ! -e "$path/.git" ]; then
      relative="$(workspace_repo_relative_path "$task_repo" 2>/dev/null || true)"
      if [ -z "$relative" ]; then
        path=""
      else
        local owner_component
        owner_component="$(printf '%s' "$relative" | cut -d/ -f2)"
        if [ -L "$path/repos" ] || [ -L "$path/repos/$owner_component" ] || [ -L "$path/$relative" ]; then
          path=""
        else
          candidate_checkout="$path/$relative"
        fi
      fi
    fi
    if [ -n "$path" ] && [ -L "$candidate_checkout/.git" ]; then
      path=""
    fi
    if [ -n "$path" ] && [ -e "$candidate_checkout/.git" ] && [ -n "$task_repo" ]; then
      actual_repo="$(git -C "$candidate_checkout" remote get-url origin 2>/dev/null || true)"
      if [ -n "$actual_repo" ] && ! workspace_repo_matches "$task_repo" "$actual_repo"; then
        path=""
      fi
    fi
  fi
  printf '%s\n' "$path"
}

# Validate both lease ownership and the exact physical checkout path before
# dispatch. A valid BUSY row is not enough if the executor is pointed at a
# different workspace (for example, a stale checkout from an earlier task).
workspace_owned_path_matches() {
  local ws_id="$1"
  local task_id="$2"
  local candidate_path="$3"
  [ -n "$ws_id" ] && [ -n "$task_id" ] && [ -n "$candidate_path" ] || return 1

  local safe_ws_id safe_task_id registered_path workspace_root registered_real candidate_real
  safe_ws_id="$(sql_escape "$ws_id")"
  safe_task_id="$(sql_escape "$task_id")"
  registered_path="$(sqlite3 "$DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_ws_id' AND currentTaskId='$safe_task_id' AND status='BUSY' LIMIT 1;" 2>/dev/null || true)"
  [ -n "$registered_path" ] && [ -d "$registered_path" ] && [ -d "$candidate_path" ] || return 1

  workspace_root="$(realpath -e "$WORKSPACES_DIR" 2>/dev/null)" || return 1
  registered_real="$(realpath -e "$registered_path" 2>/dev/null)" || return 1
  candidate_real="$(realpath -e "$candidate_path" 2>/dev/null)" || return 1

  case "$registered_real" in
    "$workspace_root"/*) ;;
    *) return 1 ;;
  esac
  [ "$registered_real" = "$candidate_real" ]
}

workspace_cleanup_stale() {
  local stale_threshold="${1:-3600}"

  # Reclaim BUSY workspaces that are not owned by a live running task.
  # Queued/completed/failed tasks must never pin a workspace across daemon restarts.
  # lastUsedAt is only a coarse staleness signal for a running task.
  local has_liveness_columns
  has_liveness_columns="$(sqlite3 "$DB" "SELECT COUNT(*) FROM pragma_table_info('processed_comments') WHERE name IN ('heartbeatAt','leaseExpiresAt','workerPid');" 2>/dev/null || echo 0)"

  if [ "${has_liveness_columns:-0}" -eq 3 ]; then
    local rows
    rows="$(sqlite3 -separator '|' "$DB" "
      SELECT w.workspaceId,
             COALESCE(w.currentTaskId,''),
             COALESCE(pc.status,''),
             COALESCE(pc.heartbeatAt,''),
             COALESCE(pc.leaseExpiresAt,''),
             COALESCE(pc.workerPid,'')
      FROM workspaces w
      LEFT JOIN processed_comments pc ON pc.commentId=w.currentTaskId
      WHERE w.status='BUSY';
    " 2>/dev/null || true)"

    while IFS='|' read -r ws_id task_id task_status heartbeat_at lease_at worker_pid; do
      [ -n "$ws_id" ] || continue
      local stale=true

      if [ "$task_status" = "running" ]; then
        # A live worker owns the workspace even if its timestamps are old.
        if [ -n "$worker_pid" ] && [ "$worker_pid" != "0" ] && kill -0 "$worker_pid" 2>/dev/null; then
          stale=false
        elif [ -n "$heartbeat_at" ] && [ "$heartbeat_at" > "$(date -d "-${stale_threshold} seconds" '+%Y-%m-%d %H:%M:%S')" ] 2>/dev/null ]; then
          stale=false
        elif [ -n "$lease_at" ] && [ "$lease_at" > "$(date '+%Y-%m-%d %H:%M:%S')" ] 2>/dev/null ]; then
          stale=false
        fi
      fi

      if [ "$stale" = true ]; then
        if workspace_preserve_recovery_snapshot "$ws_id" "$task_id"; then
          sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$(sql_escape "$ws_id")' AND status='BUSY';" 2>/dev/null || true
        else
          # A failed snapshot must keep the old workspace registered: cleanup
          # must never convert a recovery error into silent data loss.
          echo "workspace_cleanup_stale: could not preserve workspace=$ws_id task=$task_id; leaving it BUSY for operator recovery" >&2
        fi
      fi
    done <<< "$rows"
  else
    # Backward-compatible fallback for databases predating liveness columns.
    # Iterate one workspace at a time so the filesystem can be preserved before
    # a stale BUSY row becomes disposable.
    local legacy_rows
    legacy_rows="$(sqlite3 -separator '|' "$DB" "SELECT workspaceId, COALESCE(currentTaskId,'') FROM workspaces WHERE status='BUSY' AND lastUsedAt < datetime('now', '-${stale_threshold} seconds');" 2>/dev/null || true)"
    while IFS='|' read -r ws_id task_id; do
      [ -n "$ws_id" ] || continue
      if workspace_preserve_recovery_snapshot "$ws_id" "$task_id"; then
        sqlite3 "$DB" "UPDATE workspaces SET status='BROKEN' WHERE workspaceId='$(sql_escape "$ws_id")' AND status='BUSY';" 2>/dev/null || true
      else
        echo "workspace_cleanup_stale: could not preserve workspace=$ws_id task=$task_id; leaving it BUSY for operator recovery" >&2
      fi
    done <<< "$legacy_rows"
  fi

  # Broken workspaces are disposable. Idle context-bound workspaces are
  # intentionally persistent so uncommitted PR/thread work survives between
  # comments and daemon restarts.
  sqlite3 "$DB" "
    DELETE FROM workspace_contexts
    WHERE workspaceId IN (SELECT workspaceId FROM workspaces WHERE status='BROKEN');

    DELETE FROM workspaces
    WHERE status='BROKEN'
       OR (
         lastUsedAt < datetime('now', '-${stale_threshold} seconds')
         AND status='IDLE'
         AND NOT EXISTS (
           SELECT 1 FROM workspace_contexts wc
           WHERE wc.workspaceId=workspaces.workspaceId
         )
       );
  " 2>/dev/null || true
}

workspace_available_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='IDLE'"
}

workspace_busy_count() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM workspaces WHERE status='BUSY'"
}

export -f workspace_preserve_recovery_snapshot workspace_restore_recovery_snapshot workspace_init workspace_pool_init workspace_lease workspace_release workspace_reclaim workspace_context_acquire workspace_claim_id workspace_prepare_pr_branch workspace_mark_broken workspace_repo_matches workspace_repo_relative_path workspace_primary_repo_path workspace_migrate_legacy_checkout workspace_prepare_primary_checkout workspace_prepare_related_checkouts workspace_get_path workspace_owned_path_matches workspace_cleanup_stale workspace_available_count workspace_busy_count 2>/dev/null