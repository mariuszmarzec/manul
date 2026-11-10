#!/usr/bin/env bash
# task-source.sh — runtime-neutral Manul task source contracts and registry.
#
# A task source owns the ROOT work item Manul executes.
# Pull requests and review artifacts are related context, never root sources.

set -uo pipefail
TASK_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

task_source_types() { printf '%s\n' github_issues jira_tasks todo_local_mcp todo_remote_mcp; }

task_source_type_is_supported() {
  case "$1" in github_issues|jira_tasks|todo_local_mcp|todo_remote_mcp) return 0 ;; *) return 1 ;; esac
}

task_source_enabled() { jq -e '(.enabled != false)' <<<"$1" >/dev/null 2>&1; }
task_source_name() { jq -r '.type // empty' <<<"$1"; }

task_source_todo_client_path() {
  printf '%s\\n' "${TODO_MCP_CLIENT:-$TASK_SOURCE_DIR/todo-mcp-client.py}"
}

task_source_todo_local_helper_path() {
  printf '%s\\n' "${TODO_LOCAL_MCP_URL_HELPER:-$TASK_SOURCE_DIR/todo-local-mcp-url.sh}"
}

task_source_shared_todo_client_available() {
  local client
  client="$(task_source_todo_client_path)"
  [ -r "$client" ] && command -v python3 >/dev/null 2>&1
}

task_source_local_helper_available() {
  local helper
  helper="$(task_source_todo_local_helper_path)"
  [ -r "$helper" ]
}

task_source_poll() {
  local source_json="$1" type
  type="$(task_source_name "$source_json")"
  case "$type" in
    github_issues)
      source "$TASK_SOURCE_DIR/task-source-github-issues.sh"
      task_source_github_issues_poll "$source_json" ;;
    jira_tasks)
      source "$TASK_SOURCE_DIR/task-source-jira-tasks.sh"
      task_source_jira_tasks_poll "$source_json" ;;
    todo_local_mcp)
      if ! task_source_shared_todo_client_available || ! task_source_local_helper_available; then
        echo "ERROR: task-source: standalone Todo MCP client or endpoint resolver is missing from $TASK_SOURCE_DIR" >&2
        return 2
      fi
      source "$TASK_SOURCE_DIR/task-source-todo-local.sh"
      task_source_todo_local_poll "$source_json" ;;
    todo_remote_mcp)
      if ! task_source_shared_todo_client_available; then
        echo "ERROR: task-source: standalone Todo MCP client is missing or Python 3 is unavailable" >&2
        return 2
      fi
      source "$TASK_SOURCE_DIR/task-source-todo-remote.sh"
      task_source_todo_remote_poll "$source_json" ;;
    *)
      echo "task-source: unsupported provider type: $type" >&2
      return 2 ;;
  esac
}

task_source_normalize_id() { printf "%s:%s" "$1" "$2"; }

# Stable logical workspace identity for a provider-owned root task. Todo source
# IDs include a structural fingerprint, which must not split one root task into
# a different workspace context when its task tree changes.
task_source_workspace_context_id() {
  local source_type="$1" source_id="$2" stable_source_id="$2"
  task_source_type_is_supported "$source_type" || return 1
  [ -n "$source_id" ] || return 1

  case "$source_type" in
    todo_local_mcp|todo_remote_mcp)
      stable_source_id="${source_id%%@*}"
      [[ "$stable_source_id" =~ ^[0-9]+$ ]] || return 1
      ;;
  esac

  printf 'conv-source-%s-%s' "$source_type" "$stable_source_id"
}

task_source_sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Return the existing context, or atomically backfill it for a legacy queued
# source task created before conversation IDs were persisted by the poller.
task_source_ensure_workspace_context() {
  local db="$1" task_id="$2" source_type="$3" source_id="$4"
  [ -n "$db" ] && [ -n "$task_id" ] || return 1

  local safe_task_id current_context context_id changed
  safe_task_id="$(task_source_sql_escape "$task_id")"
  current_context="$(sqlite3 "$db" "SELECT COALESCE(conversationId,'') FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)" || return 1
  if [ -n "$current_context" ]; then
    printf '%s' "$current_context"
    return 0
  fi

  context_id="$(task_source_workspace_context_id "$source_type" "$source_id")" || return 1
  changed="$(sqlite3 "$db" "
    UPDATE processed_comments
    SET conversationId='$(task_source_sql_escape "$context_id")'
    WHERE commentId='$safe_task_id'
      AND (conversationId IS NULL OR conversationId='');
    SELECT changes();
  " 2>/dev/null | tail -n 1)" || return 1

  # changes=0 is valid only when another writer has already repaired the row.
  case "$changed" in 0|1) ;; *) return 1 ;; esac

  # Re-read the persisted value instead of assuming our candidate won.
  current_context="$(sqlite3 "$db" "SELECT COALESCE(conversationId,'') FROM processed_comments WHERE commentId='$safe_task_id' LIMIT 1;" 2>/dev/null)" || return 1
  [ -n "$current_context" ] || return 1
  printf '%s' "$current_context"
}

task_source_configured_sources() {
  local config="$1"
  local trigger allowed_users repositories_json

  trigger="$(jq -r '.trigger // "/manul"' "$config")"
  allowed_users="$(jq -c '.allowedUsers // []' "$config")"
  # The operator config has exactly one repository list. Provider-local legacy
  # lists are ignored; this canonical list is projected into provider payloads.
  repositories_json="$(jq -c '.repositories // [] | if type == "array" then map(select(type == "string")) | unique else [] end' "$config")" || return 1

  if jq -e '(.taskSources // []) | length > 0' "$config" >/dev/null 2>&1; then
    jq -c \
      --arg trigger "$trigger" \
      --argjson allowedUsers "$allowed_users" \
      --argjson repositories "$repositories_json" '
        .taskSources[]
        | select((.enabled != false))
        | if .type == "github_issues"
          then .trigger = (.trigger // $trigger)
             | .allowedUsers = (.allowedUsers // $allowedUsers)
             | .repositories = $repositories
          elif (.type == "todo_local_mcp" or .type == "todo_remote_mcp")
          then (if .type == "todo_local_mcp" then del(.tokenEnv) else . end)
             | .repositories = $repositories
             | del(.repositoryAllowlist, .repositoryAllowlistEnforced)
          else .
          end
      ' "$config"
    return 0
  fi

  # Backward-compatible default: GitHub Issues only, using the same global list.
  jq -cn \
    --argjson repositories "$repositories_json" \
    --arg trigger "$trigger" \
    --argjson allowedUsers "$allowed_users" '
      {
        type:"github_issues",
        enabled:true,
        repositories:$repositories,
        trigger:$trigger,
        allowedUsers:$allowedUsers
      }
    '
}

task_source_identity() {
  jq -r '.taskSourceType as $t | .taskSourceId as $i
    | if ($t // "") == "" or ($i // "") == "" then empty
      else ($t + ":" + $i)
      end' <<<"$1"
}


task_source_is_todo_type() {
  case "$1" in todo_local_mcp|todo_remote_mcp) return 0 ;; *) return 1 ;; esac
}

task_source_config_by_type() {
  local config="$1" type="$2" configured_sources
  [ -f "$config" ] || return 1
  configured_sources="$(task_source_configured_sources "$config")" || return 1
  jq -sce --arg type "$type" '
    [.[] | select(.type == $type and (.enabled != false))]
    | first // empty
  ' <<<"$configured_sources" 2>/dev/null
}

# Revalidation is claim-scoped and deliberately distinguishes stale source
# state (1) from unavailable MCP/config/network (2), matching GitHub providers.
task_source_revalidate() {
  local config="$1" type="$2" source_id="$3" expected_repo="${4:-}" expected_issue="${5:-}" source_json
  source_json="$(task_source_config_by_type "$config" "$type")" || return 2
  case "$type" in
    github_issues)
      source "$TASK_SOURCE_DIR/task-source-github-issues.sh"
      task_source_github_issues_revalidate "$source_json" "$source_id" "$expected_repo" "$expected_issue" ;;
    todo_local_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-local.sh"
      task_source_todo_local_revalidate "$source_json" "$source_id" ;;
    todo_remote_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-remote.sh"
      task_source_todo_remote_revalidate "$source_json" "$source_id" ;;
    *)
      return 2 ;;
  esac
}

# Completion is an explicit provider side effect. It marks the root task and
# its ordered subtask tree done only after Manul has verified repository delivery.
task_source_complete() {
  local config="$1" type="$2" source_id="$3" source_json
  task_source_is_todo_type "$type" || return 2
  source_json="$(task_source_config_by_type "$config" "$type")" || return 2
  case "$type" in
    todo_local_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-local.sh"
      task_source_todo_local_complete "$source_json" "$source_id" ;;
    todo_remote_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-remote.sh"
      task_source_todo_remote_complete "$source_json" "$source_id" ;;
    *)
      return 2 ;;
  esac
}

# Persist and verify a report-only Todo result without changing root status.
task_source_report_deliver() {
  local config="$1" type="$2" source_id="$3" answer="$4" source_json
  task_source_is_todo_type "$type" || return 2
  source_json="$(task_source_config_by_type "$config" "$type")" || return 2
  case "$type" in
    todo_local_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-local.sh"
      source_json="$(todo_source_local_config "$source_json")" || return $?
      todo_task_report_deliver "$source_json" "$type" "$source_id" "$answer" ;;
    todo_remote_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-remote.sh"
      source_json="$(todo_source_remote_config "$source_json")" || return $?
      todo_task_report_deliver "$source_json" "$type" "$source_id" "$answer" ;;
    *)
      return 2 ;;
  esac
}


# Startup diagnostics are deliberately non-fatal: the daemon remains useful for
# other providers, but every enabled source must explain whether it can poll.
# Local Todo preflight performs the same unauthenticated initialize/tools/list
# handshake as the resolver; actual list_tasks errors are reported by poll.sh.
task_source_preflight() {
  local config="$1" log_file="${2:-/dev/stderr}"
  local configured_sources source_json type status detail failures=0 enabled=0

  _task_source_preflight_log() {
    printf '[%s] %s\n' "$(date -Is)" "$*" >>"$log_file" 2>/dev/null ||
      printf '%s\\n' "$*" >&2
  }

  if [ ! -r "$config" ] || ! jq -e 'type == "object"' "$config" >/dev/null 2>&1; then
    _task_source_preflight_log "ERROR: task-source preflight: config is missing, unreadable, or invalid ($config)"
    return 0
  fi

  configured_sources="$(task_source_configured_sources "$config" 2>/dev/null)" || configured_sources=""
  if [ -z "$configured_sources" ]; then
    _task_source_preflight_log "WARN: task-source preflight: no enabled task sources are configured"
    return 0
  fi

  while IFS= read -r source_json; do
    [ -n "$source_json" ] || continue
    enabled=$((enabled + 1))
    type="$(task_source_name "$source_json")"
    case "$type" in
      todo_local_mcp)
        local client helper resolved rc
        client="$(task_source_todo_client_path)"
        helper="$(task_source_todo_local_helper_path)"
        if [ ! -r "$client" ]; then
          _task_source_preflight_log "ERROR: task-source preflight: todo_local_mcp is enabled but client is missing/unreadable ($client)"
          failures=$((failures + 1))
          continue
        fi
        if [ ! -r "$helper" ]; then
          _task_source_preflight_log "ERROR: task-source preflight: todo_local_mcp is enabled but endpoint resolver is missing/unreadable ($helper)"
          failures=$((failures + 1))
          continue
        fi
        if ! command -v python3 >/dev/null 2>&1; then
          _task_source_preflight_log "ERROR: task-source preflight: todo_local_mcp requires python3 on PATH"
          failures=$((failures + 1))
          continue
        fi
        source "$TASK_SOURCE_DIR/task-source-todo-local.sh"
        resolved="$(todo_source_local_config "$source_json" 2>&1)" && rc=0 || rc=$?
        if [ "$rc" -eq 0 ]; then
          status="$(jq -r '.url // "unknown"' <<<"$resolved" 2>/dev/null)"
          _task_source_preflight_log "INFO: task-source preflight: todo_local_mcp ready; MCP initialize/tools/list handshake succeeded (endpoint=$status)"
        else
          detail="$(printf '%s' "$resolved" | tail -n 1 | cut -c1-240)"
          _task_source_preflight_log "ERROR: task-source preflight: todo_local_mcp is enabled but unavailable (rc=$rc): ${detail:-endpoint handshake failed}"
          failures=$((failures + 1))
        fi
        ;;
      todo_remote_mcp)
        local client remote_config rc token_env
        client="$(task_source_todo_client_path)"
        if [ ! -r "$client" ] || ! command -v python3 >/dev/null 2>&1; then
          _task_source_preflight_log "ERROR: task-source preflight: todo_remote_mcp is enabled but the Todo MCP client or python3 is unavailable"
          failures=$((failures + 1))
          continue
        fi
        source "$TASK_SOURCE_DIR/task-source-todo-remote.sh"
        remote_config="$(todo_source_remote_config "$source_json" 2>&1)" && rc=0 || rc=$?
        if [ "$rc" -ne 0 ]; then
          detail="$(printf '%s' "$remote_config" | tail -n 1 | cut -c1-240)"
          _task_source_preflight_log "ERROR: task-source preflight: todo_remote_mcp configuration is invalid (rc=$rc): ${detail:-configuration validation failed}"
          failures=$((failures + 1))
          continue
        fi
        token_env="$(jq -r '.tokenEnv // empty' <<<"$remote_config")"
        if [ -z "$token_env" ] || [ -z "${!token_env:-}" ]; then
          _task_source_preflight_log "ERROR: task-source preflight: todo_remote_mcp requires a non-empty token environment variable (${token_env:-missing tokenEnv})"
          failures=$((failures + 1))
        else
          _task_source_preflight_log "INFO: task-source preflight: todo_remote_mcp configuration and credentials are available"
        fi
        ;;
      github_issues)
        if ! command -v gh >/dev/null 2>&1; then
          _task_source_preflight_log "ERROR: task-source preflight: github_issues is enabled but gh CLI is missing from PATH"
          failures=$((failures + 1))
        elif [ "$(jq -r '.repositories | length' <<<"$source_json" 2>/dev/null || echo 0)" -eq 0 ]; then
          _task_source_preflight_log "WARN: task-source preflight: github_issues is enabled but no repositories are configured"
          failures=$((failures + 1))
        else
          _task_source_preflight_log "INFO: task-source preflight: github_issues ready"
        fi
        ;;
      jira_tasks)
        if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
          _task_source_preflight_log "ERROR: task-source preflight: jira_tasks is enabled but curl or python3 is missing"
          failures=$((failures + 1))
        else
          _task_source_preflight_log "INFO: task-source preflight: jira_tasks runtime dependencies are available"
        fi
        ;;
      *)
        _task_source_preflight_log "ERROR: task-source preflight: unsupported enabled provider type '$type'"
        failures=$((failures + 1))
        ;;
    esac
  done <<<"$configured_sources"

  if [ "$failures" -gt 0 ]; then
    _task_source_preflight_log "WARN: task-source preflight completed with $failures problem(s) across $enabled enabled provider(s); daemon will continue and poller will retry"
  else
    _task_source_preflight_log "INFO: task-source preflight passed for $enabled enabled provider(s)"
  fi
  return 0
}
