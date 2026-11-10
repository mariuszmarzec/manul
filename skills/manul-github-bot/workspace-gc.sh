#!/usr/bin/env bash
# workspace-gc.sh — conservative garbage collection for Manul runtime workspaces.
#
# Safe defaults:
#   unbound workspace directories: 1 hour
#   inactive issue/review contexts: 30 days
#   closed PR contexts:             7 days after GitHub closed_at
#   recovery snapshots:              30 days
#   shared repository caches:        30 days since last successful use
#
# This file is sourceable by the daemon (workspace_gc_touch_repo) and can also
# run as a standalone maintenance command. All destructive operations validate
# canonical direct-child paths and re-check SQLite ownership before deletion.

WORKSPACE_GC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$WORKSPACE_GC_SCRIPT_DIR/manul-paths.sh"

WORKSPACE_GC_DB="${DB:-$MANUL_DB}"
WORKSPACE_GC_ROOT="$MANUL_WORKSPACE"
WORKSPACE_GC_LOCK="$MANUL_LOCKS_DIR/workspace-gc.flock"
WORKSPACE_GC_LOG="${MANUL_WORKSPACE_GC_LOG:-$MANUL_LOG_DIR/workspace-gc.log}"

: "${MANUL_WORKSPACE_GC_INTERVAL_SECONDS:=3600}"
: "${MANUL_WORKSPACE_GC_IDLE_HOURS:=1}"
: "${MANUL_WORKSPACE_GC_CONTEXT_DAYS:=30}"
: "${MANUL_WORKSPACE_GC_CLOSED_PR_DAYS:=7}"
: "${MANUL_WORKSPACE_GC_RECOVERY_DAYS:=30}"
: "${MANUL_WORKSPACE_GC_REPO_DAYS:=30}"
: "${MANUL_WORKSPACE_GC_PR_CACHE_TTL_SECONDS:=21600}"

workspace_gc_sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

workspace_gc_log() {
  mkdir -p "$(dirname "$WORKSPACE_GC_LOG")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$WORKSPACE_GC_LOG" 2>/dev/null || true
}

workspace_gc_valid_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

workspace_gc_init() {
  mkdir -p "$WORKSPACE_GC_ROOT" "$MANUL_STATE_DIR" "$MANUL_LOCKS_DIR" "$MANUL_LOCKS_DIR/repo" || return 1
  sqlite3 "$WORKSPACE_GC_DB" "
    CREATE TABLE IF NOT EXISTS manul_repo_cache_usage (
      repository TEXT PRIMARY KEY,
      lastUsedAt TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS manul_workspace_gc_pr_cache (
      repository TEXT NOT NULL,
      prNumber INTEGER NOT NULL,
      state TEXT NOT NULL,
      closedAt TEXT,
      checkedAt TEXT NOT NULL,
      PRIMARY KEY(repository, prNumber)
    );
    CREATE TABLE IF NOT EXISTS manul_workspace_gc_state (
      stateKey TEXT PRIMARY KEY,
      stateValue TEXT NOT NULL
    );
  " >/dev/null 2>&1
}

# Called by ensure_repo after a successful fetch/reuse or clone. This timestamp
# is the authority for cache retention; cache directory mtimes are not reliable
# because Git updates files below .git rather than the cache root itself.
workspace_gc_touch_repo() {
  local repository="${1:-}"
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  workspace_gc_init || return 1
  local safe_repo
  safe_repo="$(workspace_gc_sql_escape "$repository")"
  sqlite3 "$WORKSPACE_GC_DB" "
    INSERT INTO manul_repo_cache_usage(repository,lastUsedAt)
    VALUES('$safe_repo',datetime('now'))
    ON CONFLICT(repository) DO UPDATE SET lastUsedAt=excluded.lastUsedAt;
  " >/dev/null 2>&1
}

workspace_gc_table_exists() {
  local table="$1"
  sqlite3 "$WORKSPACE_GC_DB" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$(workspace_gc_sql_escape "$table")' LIMIT 1;" 2>/dev/null | grep -qx 1
}

workspace_gc_safe_direct_child() {
  local root="$1" child="$2" expected_name="$3"
  [ -n "$root" ] && [ -n "$child" ] && [ -n "$expected_name" ] || return 1
  [ ! -L "$root" ] && [ -d "$root" ] || return 1
  [ ! -L "$child" ] && [ -d "$child" ] || return 1
  local root_real child_real
  root_real="$(realpath -e -- "$root" 2>/dev/null)" || return 1
  child_real="$(realpath -e -- "$child" 2>/dev/null)" || return 1
  [ "$child_real" = "$root_real/$expected_name" ] || return 1
  [ "$(dirname -- "$child_real")" = "$root_real" ]
}

workspace_gc_path_age_seconds() {
  local path="$1" mtime now
  mtime="$(date -r "$path" +%s 2>/dev/null || true)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  printf '%s\n' "$((now - mtime))"
}

workspace_gc_active_task_count() {
  local workspace_id="$1" safe_id
  safe_id="$(workspace_gc_sql_escape "$workspace_id")"
  workspace_gc_table_exists processed_comments || { printf '0\n'; return 0; }
  if ! sqlite3 "$WORKSPACE_GC_DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|workspaceId|'; then
    printf '0\n'
    return 0
  fi
  sqlite3 "$WORKSPACE_GC_DB" "
    SELECT COUNT(*)
    FROM processed_comments
    WHERE workspaceId='$safe_id'
      AND status IN ('queued','running','blocked_user');
  " 2>/dev/null
}

workspace_gc_context_last_used_epoch() {
  local safe_id
  safe_id="$(workspace_gc_sql_escape "$1")"
  sqlite3 "$WORKSPACE_GC_DB" "
    SELECT COALESCE(MAX(strftime('%s', COALESCE(w.lastUsedAt, wc.lastUsedAt, wc.createdAt))), 0)
    FROM workspaces w
    LEFT JOIN workspace_contexts wc ON wc.workspaceId=w.workspaceId
    WHERE w.workspaceId='$safe_id';
  " 2>/dev/null
}

# Return all PRs attached to a workspace's context tree. Review-thread child
# contexts inherit the root PR context through parentContextId.
workspace_gc_workspace_prs() {
  local safe_id
  safe_id="$(workspace_gc_sql_escape "$1")"
  local query=""
  if workspace_gc_table_exists conversation_links; then
    query="
      SELECT DISTINCT repo, prNumber
      FROM (
        SELECT l.repo AS repo, l.prNumber AS prNumber
        FROM workspace_contexts wc
        JOIN conversation_links l
          ON l.conversationId=wc.contextId
          OR l.conversationId=wc.parentContextId
        WHERE wc.workspaceId='$safe_id'
          AND l.linkType='PR'
          AND l.prNumber IS NOT NULL
        UNION
        SELECT c.repository AS repo, c.activePrNumber AS prNumber
        FROM workspace_contexts wc
        JOIN conversations c
          ON c.conversationId=wc.contextId
          OR c.conversationId=wc.parentContextId
        WHERE wc.workspaceId='$safe_id'
          AND c.activePrNumber IS NOT NULL
      )
      WHERE repo IS NOT NULL AND prNumber IS NOT NULL
      ORDER BY repo, prNumber;
    "
  elif workspace_gc_table_exists conversations; then
    query="
      SELECT DISTINCT c.repository, c.activePrNumber
      FROM workspace_contexts wc
      JOIN conversations c
        ON c.conversationId=wc.contextId
        OR c.conversationId=wc.parentContextId
      WHERE wc.workspaceId='$safe_id'
        AND c.activePrNumber IS NOT NULL
      ORDER BY c.repository, c.activePrNumber;
    "
  fi
  [ -n "$query" ] || return 0
  sqlite3 -separator $'\t' "$WORKSPACE_GC_DB" "$query" 2>/dev/null || true
}

workspace_gc_fetch_pr_state() {
  local repository="$1" pr_number="$2" force_refresh="${3:-false}"
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1

  local safe_repo cached_state cached_closed cached_checked now_epoch cache_age
  safe_repo="$(workspace_gc_sql_escape "$repository")"
  now_epoch="$(date +%s)"
  cached_state=""
  cached_closed=""
  cached_checked="0"
  if workspace_gc_table_exists manul_workspace_gc_pr_cache; then
    IFS='|' read -r cached_state cached_closed cached_checked < <(
      sqlite3 "$WORKSPACE_GC_DB" "
        SELECT state || '|' || COALESCE(closedAt,'') || '|' || COALESCE(strftime('%s',checkedAt),'0')
        FROM manul_workspace_gc_pr_cache
        WHERE repository='$safe_repo' AND prNumber=$pr_number LIMIT 1;
      " 2>/dev/null || true
    ) || true
  fi

  cache_age=$((now_epoch - ${cached_checked:-0}))
  # A cached "closed" result is always revalidated immediately before deletion
  # once its grace period may have elapsed, so a reopened PR is never discarded
  # solely because of an old cache entry.
  local closed_candidate=false
  if [ "$cached_state" = "closed" ] && [ -n "$cached_closed" ]; then
    if sqlite3 "$WORKSPACE_GC_DB" "SELECT CASE WHEN datetime('$(workspace_gc_sql_escape "$cached_closed")') <= datetime('now','-${MANUL_WORKSPACE_GC_CLOSED_PR_DAYS} days') THEN 1 ELSE 0 END;" 2>/dev/null | grep -qx 1; then
      closed_candidate=true
    fi
  fi

  if [ "$force_refresh" != "true" ] && [ "$closed_candidate" != "true" ] &&
     [ "$cache_age" -ge 0 ] && [ "$cache_age" -lt "$MANUL_WORKSPACE_GC_PR_CACHE_TTL_SECONDS" ] &&
     { [ "$cached_state" = "open" ] || [ "$cached_state" = "closed" ]; }; then
    printf '%s\t%s\n' "$cached_state" "$cached_closed"
    return 0
  fi

  command -v gh >/dev/null 2>&1 || return 1
  local response state closed_at
  response="$(gh api "repos/$repository/pulls/$pr_number" --jq '[.state, (.closed_at // "")] | @tsv' 2>/dev/null)" || return 1
  state="$(printf '%s\n' "$response" | cut -f1)"
  closed_at="$(printf '%s\n' "$response" | cut -f2-)"
  case "$state" in open|closed) ;; *) return 1 ;; esac
  [ "$state" != "closed" ] || [ -n "$closed_at" ] || return 1

  sqlite3 "$WORKSPACE_GC_DB" "
    INSERT INTO manul_workspace_gc_pr_cache(repository,prNumber,state,closedAt,checkedAt)
    VALUES('$safe_repo',$pr_number,'$state',NULLIF('$(workspace_gc_sql_escape "$closed_at")',''),datetime('now'))
    ON CONFLICT(repository,prNumber) DO UPDATE SET
      state=excluded.state, closedAt=excluded.closedAt, checkedAt=excluded.checkedAt;
  " >/dev/null 2>&1 || return 1

  printf '%s\t%s\n' "$state" "$closed_at"
}

workspace_gc_pr_expired() {
  local repository="$1" pr_number="$2" response state closed_at
  # The closed-state cache is a performance hint only. Force a live read before
  # returning "expired", protecting PRs that were reopened after the cache read.
  response="$(workspace_gc_fetch_pr_state "$repository" "$pr_number" false)" || return 1
  IFS=$'\t' read -r state closed_at <<< "$response"
  [ "$state" = "closed" ] && [ -n "$closed_at" ] || return 1

  local expired
  expired="$(sqlite3 "$WORKSPACE_GC_DB" "
    SELECT CASE
      WHEN datetime('$(workspace_gc_sql_escape "$closed_at")') <= datetime('now','-${MANUL_WORKSPACE_GC_CLOSED_PR_DAYS} days')
      THEN 1 ELSE 0 END;
  " 2>/dev/null || echo 0)"
  [ "$expired" = "1" ]
}

workspace_gc_context_expired() {
  local workspace_id="$1" prs last_used now_epoch threshold
  prs="$(workspace_gc_workspace_prs "$workspace_id")"
  if [ -n "$prs" ]; then
    local repo pr_number all_expired=true
    while IFS=$'\t' read -r repo pr_number; do
      [ -n "$repo" ] && [ -n "$pr_number" ] || { all_expired=false; break; }
      if ! workspace_gc_pr_expired "$repo" "$pr_number"; then
        all_expired=false
        break
      fi
    done <<< "$prs"
    [ "$all_expired" = true ]
    return
  fi

  last_used="$(workspace_gc_context_last_used_epoch "$workspace_id")"
  [[ "$last_used" =~ ^[0-9]+$ ]] || return 1
  [ "$last_used" -gt 0 ] || return 1
  now_epoch="$(date +%s)"
  threshold=$((MANUL_WORKSPACE_GC_CONTEXT_DAYS * 86400))
  [ $((now_epoch - last_used)) -ge "$threshold" ]
}

workspace_gc_remove_workspace() {
  local workspace_id="$1" safe_id changed path root_real
  [[ "$workspace_id" =~ ^ws-[A-Za-z0-9._-]+$ ]] || return 1
  safe_id="$(workspace_gc_sql_escape "$workspace_id")"

  # GC is a lease state: new workers only claim IDLE workspaces, so the
  # compare-and-set prevents a concurrent acquire from racing filesystem removal.
  local active_task_guard=""
  if workspace_gc_table_exists processed_comments &&
     sqlite3 "$WORKSPACE_GC_DB" "PRAGMA table_info(processed_comments);" 2>/dev/null | grep -q '|workspaceId|'; then
    active_task_guard="
      AND NOT EXISTS (
        SELECT 1 FROM processed_comments pc
        WHERE pc.workspaceId=workspaces.workspaceId
          AND pc.status IN ('queued','running','blocked_user')
      )"
  fi
  changed="$(sqlite3 "$WORKSPACE_GC_DB" "
    BEGIN IMMEDIATE;
    UPDATE workspaces
    SET status='GC'
    WHERE workspaceId='$safe_id'
      AND status='IDLE'
      $active_task_guard;
    SELECT changes();
    COMMIT;
  " 2>/dev/null | tail -n 1)" || return 1
  [ "$changed" = "1" ] || return 1

  path="$(sqlite3 "$WORKSPACE_GC_DB" "SELECT workspacePath FROM workspaces WHERE workspaceId='$safe_id' AND status='GC' LIMIT 1;" 2>/dev/null || true)"
  root_real="$(realpath -e -- "$WORKSPACE_GC_ROOT" 2>/dev/null)" || {
    sqlite3 "$WORKSPACE_GC_DB" "UPDATE workspaces SET status='IDLE' WHERE workspaceId='$safe_id' AND status='GC';" >/dev/null 2>&1 || true
    return 1
  }

  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -L "$path" ] || [ ! -d "$path" ] ||
       [ "$(realpath -e -- "$path" 2>/dev/null || true)" != "$root_real/$workspace_id" ] ||
       [ "$(dirname -- "$(realpath -e -- "$path" 2>/dev/null || true)")" != "$root_real" ]; then
      workspace_gc_log "WARN refusing unsafe workspace path for $workspace_id: $path"
      sqlite3 "$WORKSPACE_GC_DB" "UPDATE workspaces SET status='IDLE' WHERE workspaceId='$safe_id' AND status='GC';" >/dev/null 2>&1 || true
      return 1
    fi
    # Expiring a context removes it from the active pool, but preserve one
    # operator-recoverable snapshot before deleting the original directory.
    if ! workspace_preserve_recovery_snapshot "$workspace_id" "gc-expired-context" >/dev/null 2>&1; then
      workspace_gc_log "WARN could not archive expired workspace $workspace_id; retaining it"
      sqlite3 "$WORKSPACE_GC_DB" "UPDATE workspaces SET status='IDLE' WHERE workspaceId='$safe_id' AND status='GC';" >/dev/null 2>&1 || true
      return 1
    fi
  fi

  sqlite3 "$WORKSPACE_GC_DB" "
    BEGIN IMMEDIATE;
    DELETE FROM workspace_contexts WHERE workspaceId='$safe_id';
    DELETE FROM workspaces WHERE workspaceId='$safe_id' AND status='GC';
    COMMIT;
  " >/dev/null 2>&1 || return 1
  workspace_gc_log "removed expired workspace $workspace_id"
}

workspace_gc_context_workspaces() {
  local rows workspace_id safe_id context_count
  rows="$(sqlite3 -separator '|' "$WORKSPACE_GC_DB" "
    SELECT w.workspaceId, COUNT(wc.contextId)
    FROM workspaces w
    JOIN workspace_contexts wc ON wc.workspaceId=w.workspaceId
    WHERE w.status='IDLE'
    GROUP BY w.workspaceId
    ORDER BY w.workspaceId;
  " 2>/dev/null || true)"

  while IFS='|' read -r workspace_id context_count; do
    [ -n "$workspace_id" ] || continue
    [ "${context_count:-0}" -gt 0 ] || continue
    [ "$(workspace_gc_active_task_count "$workspace_id")" = "0" ] || continue
    if workspace_gc_context_expired "$workspace_id"; then
      workspace_gc_remove_workspace "$workspace_id" || workspace_gc_log "INFO workspace $workspace_id became busy or failed safe removal; retained"
    fi
  done <<< "$rows"
}

workspace_gc_orphan_directories() {
  local root_real candidate name age registered
  root_real="$(realpath -e -- "$WORKSPACE_GC_ROOT" 2>/dev/null)" || return 1
  local min_age=$((MANUL_WORKSPACE_GC_IDLE_HOURS * 3600))
  while IFS= read -r -d '' candidate; do
    [ ! -L "$candidate" ] && [ -d "$candidate" ] || continue
    name="$(basename -- "$candidate")"
    [[ "$name" =~ ^ws-[A-Za-z0-9._-]+$ ]] || continue
    [ "$(realpath -e -- "$candidate" 2>/dev/null || true)" = "$root_real/$name" ] || continue
    registered="$(sqlite3 "$WORKSPACE_GC_DB" "SELECT COUNT(*) FROM workspaces WHERE workspaceId='$(workspace_gc_sql_escape "$name")';" 2>/dev/null || echo 1)"
    [ "$registered" = "0" ] || continue
    age="$(workspace_gc_path_age_seconds "$candidate" 2>/dev/null || echo 0)"
    [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -ge "$min_age" ] || continue
    if workspace_preserve_recovery_snapshot "$name" "gc-orphan" >/dev/null 2>&1; then
      workspace_gc_log "moved unregistered workspace directory $name to recovery (age=${age}s)"
    else
      workspace_gc_log "WARN could not archive unregistered workspace directory $name; retained"
    fi
  done < <(find "$WORKSPACE_GC_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'ws-*' -print0 2>/dev/null)
}

workspace_gc_active_recovery_workspace_ids() {
  workspace_gc_table_exists processed_comments || return 0
  sqlite3 "$WORKSPACE_GC_DB" "
    SELECT DISTINCT workspaceId
    FROM processed_comments
    WHERE workspaceId IS NOT NULL AND workspaceId != ''
      AND status IN ('queued','running','blocked_user');
  " 2>/dev/null || true
}

workspace_gc_recovery_snapshots() {
  local recovery_root expected_root root_real candidate name age active_ids active_id protected
  recovery_root="$MANUL_STATE_DIR/recovery/workspaces"
  [ -d "$recovery_root" ] && [ ! -L "$recovery_root" ] || return 0
  root_real="$(realpath -e -- "$recovery_root" 2>/dev/null)" || return 1
  expected_root="$(realpath -m -- "$MANUL_STATE_DIR/recovery/workspaces" 2>/dev/null)" || return 1
  [ "$root_real" = "$expected_root" ] || return 1

  active_ids="$(workspace_gc_active_recovery_workspace_ids)"
  local min_age=$((MANUL_WORKSPACE_GC_RECOVERY_DAYS * 86400))
  while IFS= read -r -d '' candidate; do
    [ ! -L "$candidate" ] && [ -d "$candidate" ] || continue
    name="$(basename -- "$candidate")"
    [ "$(realpath -e -- "$candidate" 2>/dev/null || true)" = "$root_real/$name" ] || continue
    protected=false
    while IFS= read -r active_id; do
      [ -n "$active_id" ] || continue
      if [[ "$name" == "$active_id"-* ]]; then protected=true; break; fi
    done <<< "$active_ids"
    [ "$protected" = false ] || continue
    age="$(workspace_gc_path_age_seconds "$candidate" 2>/dev/null || echo 0)"
    [[ "$age" =~ ^[0-9]+$ ]] && [ "$age" -ge "$min_age" ] || continue
    rm -rf -- "$candidate" && workspace_gc_log "removed expired recovery snapshot $name (age=${age}s)"
  done < <(find "$recovery_root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

workspace_gc_seed_untracked_caches() {
  local candidate name origin repository
  while IFS= read -r -d '' candidate; do
    [ ! -L "$candidate" ] && [ -d "$candidate/.git" ] || continue
    name="$(basename -- "$candidate")"
    origin="$(git -C "$candidate" remote get-url origin 2>/dev/null || true)"
    [[ "$origin" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(\.git)?$ ]] || continue
    repository="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    [ "${repository//\//-}" = "$name" ] || continue
    local safe_repo existing
    safe_repo="$(workspace_gc_sql_escape "$repository")"
    existing="$(sqlite3 "$WORKSPACE_GC_DB" "SELECT COUNT(*) FROM manul_repo_cache_usage WHERE repository='$safe_repo';" 2>/dev/null || echo 1)"
    if [ "$existing" = "0" ]; then
      workspace_gc_touch_repo "$repository" || true
      workspace_gc_log "registered existing repository cache $repository for retention tracking"
    fi
  done < <(find "$WORKSPACE_GC_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

workspace_gc_remove_repo_cache() {
  local repository="$1" last_used="$2" slug cache_path lock_dir lock_path safe_repo
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  slug="${repository//\//-}"
  cache_path="$WORKSPACE_GC_ROOT/$slug"
  lock_dir="$MANUL_LOCKS_DIR/repo"
  lock_path="$lock_dir/$slug.lock"
  safe_repo="$(workspace_gc_sql_escape "$repository")"

  [ ! -L "$cache_path" ] && [ -d "$cache_path/.git" ] || return 1
  [ ! -e "$lock_path" ] && [ ! -L "$lock_path" ] || return 1
  mkdir -p "$lock_dir" || return 1
  # Use the same atomic directory-lock path as ensure_repo. A task that wins
  # the lock first prevents GC; while GC owns it, a new task will retry later.
  mkdir "$lock_path" 2>/dev/null || return 1
  date +%s >"$lock_path/acquiredAt"
  printf '%s\n' "$$" >"$lock_path/pid"

  local cleanup_ok=true latest_used running_count root_real origin expected_origin
  latest_used="$(sqlite3 "$WORKSPACE_GC_DB" "SELECT lastUsedAt FROM manul_repo_cache_usage WHERE repository='$safe_repo' LIMIT 1;" 2>/dev/null || true)"
  local safe_last_used
  safe_last_used="$(workspace_gc_sql_escape "$last_used")"
  if [ -z "$latest_used" ] || [ "$latest_used" != "$last_used" ] ||
     [ "$(sqlite3 "$WORKSPACE_GC_DB" "SELECT CASE WHEN datetime('$safe_last_used') <= datetime('now','-${MANUL_WORKSPACE_GC_REPO_DAYS} days') THEN 1 ELSE 0 END;" 2>/dev/null)" != "1" ]; then
    cleanup_ok=false
  fi
  running_count="$(sqlite3 "$WORKSPACE_GC_DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$safe_repo' AND status='running';" 2>/dev/null || echo 0)"
  [ "${running_count:-0}" = "0" ] || cleanup_ok=false

  root_real="$(realpath -e -- "$WORKSPACE_GC_ROOT" 2>/dev/null || true)"
  origin="$(git -C "$cache_path" remote get-url origin 2>/dev/null || true)"
  expected_origin="https://github.com/$repository"
  if [ -z "$root_real" ] || [ "$(realpath -e -- "$cache_path" 2>/dev/null || true)" != "$root_real/$slug" ] || [ "$origin" != "$expected_origin" ]; then
    cleanup_ok=false
  fi

  if [ "$cleanup_ok" = true ]; then
    if rm -rf -- "$cache_path"; then
      sqlite3 "$WORKSPACE_GC_DB" "DELETE FROM manul_repo_cache_usage WHERE repository='$safe_repo';" >/dev/null 2>&1 || true
      workspace_gc_log "removed unused shared repository cache $repository (lastUsedAt=$last_used)"
    else
      workspace_gc_log "WARN failed to remove shared repository cache $repository"
    fi
  fi
  rm -rf -- "$lock_path" 2>/dev/null || true
  [ "$cleanup_ok" = true ]
}

workspace_gc_repository_caches() {
  workspace_gc_seed_untracked_caches
  local rows repository last_used
  rows="$(sqlite3 -separator '|' "$WORKSPACE_GC_DB" "
    SELECT repository,lastUsedAt
    FROM manul_repo_cache_usage
    WHERE lastUsedAt <= datetime('now','-${MANUL_WORKSPACE_GC_REPO_DAYS} days')
    ORDER BY lastUsedAt;
  " 2>/dev/null || true)"
  while IFS='|' read -r repository last_used; do
    [ -n "$repository" ] || continue
    workspace_gc_remove_repo_cache "$repository" "$last_used" || true
  done <<< "$rows"
}

workspace_gc_finalize_marked_workspaces() {
  local rows workspace_id safe_id path root_real
  rows="$(sqlite3 -separator '|' "$WORKSPACE_GC_DB" "SELECT workspaceId,workspacePath FROM workspaces WHERE status='GC';" 2>/dev/null || true)"
  while IFS='|' read -r workspace_id path; do
    [ -n "$workspace_id" ] || continue
    [[ "$workspace_id" =~ ^ws-[A-Za-z0-9._-]+$ ]] || continue
    root_real="$(realpath -e -- "$WORKSPACE_GC_ROOT" 2>/dev/null)" || continue
    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ -L "$path" ] || [ ! -d "$path" ] ||
         [ "$(realpath -e -- "$path" 2>/dev/null || true)" != "$root_real/$workspace_id" ]; then
        workspace_gc_log "WARN refusing unsafe recovery of GC workspace path $workspace_id"
        continue
      fi
      # If the process stopped after claiming status=GC but before archiving,
      # complete the archive now. Never interpret the marker alone as proof
      # that the physical workspace was already preserved.
      if ! workspace_preserve_recovery_snapshot "$workspace_id" "gc-interrupted" >/dev/null 2>&1; then
        workspace_gc_log "WARN could not preserve interrupted GC workspace $workspace_id; retaining its row"
        continue
      fi
    fi
    safe_id="$(workspace_gc_sql_escape "$workspace_id")"
    sqlite3 "$WORKSPACE_GC_DB" "
      BEGIN IMMEDIATE;
      DELETE FROM workspace_contexts WHERE workspaceId='$safe_id';
      DELETE FROM workspaces WHERE workspaceId='$safe_id' AND status='GC';
      COMMIT;
    " >/dev/null 2>&1 || continue
    workspace_gc_log "finalized interrupted workspace cleanup $workspace_id"
  done <<< "$rows"
}

workspace_gc_validate_config() {
  local name value default
  for name in \
    MANUL_WORKSPACE_GC_INTERVAL_SECONDS \
    MANUL_WORKSPACE_GC_IDLE_HOURS \
    MANUL_WORKSPACE_GC_CONTEXT_DAYS \
    MANUL_WORKSPACE_GC_CLOSED_PR_DAYS \
    MANUL_WORKSPACE_GC_RECOVERY_DAYS \
    MANUL_WORKSPACE_GC_REPO_DAYS \
    MANUL_WORKSPACE_GC_PR_CACHE_TTL_SECONDS; do
    value="${!name:-}"
    if ! workspace_gc_valid_positive_integer "$value"; then
      case "$name" in
        MANUL_WORKSPACE_GC_INTERVAL_SECONDS) default=3600 ;;
        MANUL_WORKSPACE_GC_IDLE_HOURS) default=1 ;;
        MANUL_WORKSPACE_GC_CONTEXT_DAYS) default=30 ;;
        MANUL_WORKSPACE_GC_CLOSED_PR_DAYS) default=7 ;;
        MANUL_WORKSPACE_GC_RECOVERY_DAYS) default=30 ;;
        MANUL_WORKSPACE_GC_REPO_DAYS) default=30 ;;
        MANUL_WORKSPACE_GC_PR_CACHE_TTL_SECONDS) default=21600 ;;
      esac
      printf -v "$name" '%s' "$default"
      export "$name"
      workspace_gc_log "WARN invalid $name; using $default"
    fi
  done
}

workspace_gc_run() {
  local force="${1:-false}" lock_fd now_epoch last_run last_run_epoch elapsed
  workspace_gc_validate_config
  workspace_gc_init || { workspace_gc_log "ERROR unable to initialize GC state"; return 1; }

  # Daemon dispatch and watchdog may invoke GC at the same time. flock is
  # released automatically if the process exits or crashes.
  [ ! -L "$WORKSPACE_GC_LOCK" ] || { workspace_gc_log "ERROR refusing symlinked GC lock path"; return 1; }
  exec {lock_fd}>"$WORKSPACE_GC_LOCK" || return 1
  if ! flock -n "$lock_fd"; then
    exec {lock_fd}>&-
    return 0
  fi

  # Finish an interrupted two-phase removal even when the normal GC interval
  # has not elapsed. Otherwise a crash after status=GC could temporarily
  # shrink the pool until the next scheduled sweep.
  source "$WORKSPACE_GC_SCRIPT_DIR/workspace-manager.sh"
  workspace_init || workspace_gc_log "WARN workspace schema initialization failed"
  workspace_gc_finalize_marked_workspaces

  now_epoch="$(date +%s)"
  last_run_epoch="$(sqlite3 "$WORKSPACE_GC_DB" "SELECT COALESCE(strftime('%s',stateValue),'0') FROM manul_workspace_gc_state WHERE stateKey='lastRunAt' LIMIT 1;" 2>/dev/null || echo 0)"
  elapsed=$((now_epoch - ${last_run_epoch:-0}))
  if [ "$force" != "true" ] && [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$MANUL_WORKSPACE_GC_INTERVAL_SECONDS" ]; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi

  sqlite3 "$WORKSPACE_GC_DB" "
    INSERT INTO manul_workspace_gc_state(stateKey,stateValue)
    VALUES('lastRunAt',datetime('now'))
    ON CONFLICT(stateKey) DO UPDATE SET stateValue=excluded.stateValue;
  " >/dev/null 2>&1 || true

  # Reconcile stale BUSY leases first. The workspace manager moves recoverable
  # working trees to recovery storage before marking/removing stale DB rows.
  workspace_cleanup_stale 3600 || workspace_gc_log "WARN workspace stale-lease reconciliation failed"
  workspace_gc_context_workspaces
  workspace_gc_orphan_directories || workspace_gc_log "WARN orphan workspace scan failed"
  workspace_gc_recovery_snapshots || workspace_gc_log "WARN recovery snapshot scan failed"
  workspace_gc_repository_caches || workspace_gc_log "WARN repository cache scan failed"

  workspace_gc_log "GC pass completed"
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  force=false
  for arg in "$@"; do
    case "$arg" in
      --force) force=true ;;
      --help|-h)
        cat <<'USAGE'
Usage: workspace-gc.sh [--force]

Run the conservative Manul workspace/cache garbage collector.
Default retention:
  unbound workspace directories: 1 hour
  inactive issue/review contexts: 30 days
  closed PR contexts:             7 days after GitHub closed_at
  recovery snapshots:              30 days
  shared repository caches:        30 days since last successful use

Set MANUL_WORKSPACE_GC_* environment variables to override retention values.
USAGE
        exit 0
        ;;
      *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  workspace_gc_run "$force"
fi
