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
      source "$TASK_SOURCE_DIR/task-source-todo-local.sh"
      task_source_todo_local_poll "$source_json" ;;
    todo_remote_mcp)
      source "$TASK_SOURCE_DIR/task-source-todo-remote.sh"
      task_source_todo_remote_poll "$source_json" ;;
    *)
      echo "task-source: unsupported provider type: $type" >&2
      return 2 ;;
  esac
}

task_source_normalize_id() { printf "%s:%s" "$1" "$2"; }

task_source_configured_sources() {
  local config="$1"

  # Explicit taskSources are independent provider configurations. Only
  # GitHub-specific defaults are inherited from the top-level configuration.
  if jq -e '(.taskSources // []) | length > 0' "$config" >/dev/null 2>&1; then
    local trigger allowed_users repository_allowlist repository_allowlist_enforced
    trigger="$(jq -r '.trigger // "/manul"' "$config")"
    allowed_users="$(jq -c '.allowedUsers // []' "$config")"
    repository_allowlist="$(jq -c '.repositoryAllowlist // [] | if type == "array" then map(select(type == "string")) | unique else [] end' "$config")"
    repository_allowlist_enforced="$(jq -r 'has("repositoryAllowlist")' "$config")"
    jq -c --arg trigger "$trigger" --argjson allowedUsers "$allowed_users" --argjson repositoryAllowlist "$repository_allowlist" --argjson repositoryAllowlistEnforced "$repository_allowlist_enforced" '
      .taskSources[]
      | select((.enabled != false))
      | if .type == "github_issues"
        then .trigger = (.trigger // $trigger)
           | .allowedUsers = (.allowedUsers // $allowedUsers)
        elif (.type == "todo_local_mcp" or .type == "todo_remote_mcp")
        then . as $source
           | .repositoryAllowlist = (
               if ($source | has("repositoryAllowlist")) then
                 if ($source.repositoryAllowlist | type) != "array" then []
                 elif $repositoryAllowlistEnforced then
                   $source.repositoryAllowlist
                   | map(select(type == "string"))
                   | map(select(. as $candidate | any($repositoryAllowlist[]; ascii_downcase == ($candidate | ascii_downcase))))
                   | unique
                 else
                   $source.repositoryAllowlist | map(select(type == "string")) | unique
                 end
               else $repositoryAllowlist
               end
             )
           | .repositoryAllowlistEnforced = (
               $repositoryAllowlistEnforced or ($source | has("repositoryAllowlist"))
             )
        else .
        end
    ' "$config"
    return 0
  fi

  # Backward-compatible default: GitHub Issues only.
  jq -c     --arg trigger "$(jq -r '.trigger // "/manul"' "$config")"     --argjson allowedUsers "$(jq -c '.allowedUsers // []' "$config")" '
      {
        type:"github_issues",
        enabled:true,
        repositories:(.repositories // []),
        trigger:$trigger,
        allowedUsers:$allowedUsers
      }
    ' "$config"
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
  local config="$1" type="$2"
  [ -f "$config" ] || return 1
  jq -ce --arg type "$type" '
    [.taskSources[]? | select(.type == $type and (.enabled != false))]
    | first // empty
  ' "$config" 2>/dev/null
}

# Revalidation is claim-scoped and deliberately distinguishes stale source
# state (1) from unavailable MCP/config/network (2), matching GitHub providers.
task_source_revalidate() {
  local config="$1" type="$2" source_id="$3" source_json
  task_source_is_todo_type "$type" || return 2
  source_json="$(task_source_config_by_type "$config" "$type")" || return 2
  case "$type" in
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
