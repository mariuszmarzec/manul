#!/usr/bin/env bash
# Independent source adapter for the remote Fiteo backend MCP endpoint.
set -uo pipefail

TODO_REMOTE_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$TODO_REMOTE_SOURCE_DIR/todo-task-source-utils.sh"

todo_source_remote_config() {
  local source_json="$1" url
  url="$(jq -r '.url // empty' <<<"$source_json")"
  [[ "$url" == https://* ]] || {
    echo "task-source: remote Fiteo MCP requires an HTTPS URL" >&2
    return 2
  }
  jq -c '.tokenEnv = (.tokenEnv // "FITEO_PAT")' <<<"$source_json"
}

task_source_todo_remote_poll() {
  local source_json manul_user_id tasks_json shared_task_json normalized resolution task_id
  source_json="$(todo_source_remote_config "$1")"
  manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
  [[ "$manul_user_id" =~ ^[1-9][0-9]*$ ]] || {
    echo "task-source: todo_remote_mcp requires a positive numeric manulUserId" >&2
    return 2
  }

  tasks_json="$(todo_mcp_source_list_tasks "$source_json" todo_remote_mcp)" || return $?
  # Fiteo returns both owned roots and tasks shared with the PAT owner. Select
  # only explicitly shared tasks with edit permission. If both an ancestor and
  # descendant are shared, queue the ancestor once and keep the returned tree.
  while IFS= read -r shared_task_json; do
    [ -n "$shared_task_json" ] || continue
    todo_task_is_active "$shared_task_json" || continue
    todo_task_has_remote_share "$shared_task_json" "$manul_user_id" || continue
    task_id="$(jq -r '.id // "unknown"' <<<"$shared_task_json")"
    if todo_task_is_report_only "$shared_task_json"; then
      if [ "$(jq -r '.allowReportOnly // false' <<<"$source_json")" != "true" ]; then
        echo "task-source: remote Todo report-only task $task_id is disabled by allowReportOnly" >&2
        continue
      fi
      resolution='{"reportOnly":true}'
    else
      resolution="$(todo_task_resolve_repository "$source_json" "$shared_task_json")" || {
        echo "task-source: remote Todo task $task_id was not queued because its repository could not be resolved" >&2
        continue
      }
    fi
    normalized="$(todo_task_to_source_json "$shared_task_json" todo_remote_mcp "$resolution")" || continue
    printf '%s\n' "$normalized"
  done < <(
    jq -c --arg userId "$manul_user_id" '
      [
        .[]
        | select(.isToDo == true)
        | select(.scheduler == null)
        | select(any(.shares[]?;
            ((.userId | tostring) == $userId)
            and .permission == "EDITOR_AND_VIEWER"
          ))
      ] as $shared
      | $shared[]
      | . as $task
      | select(
          $task.parentTaskId == null
          or all($shared[]; .id != $task.parentTaskId)
        )
    ' <<<"$tasks_json"
  )
}

task_source_todo_remote_revalidate() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_remote_config "$source_json")"
  todo_task_still_current "$source_json" todo_remote_mcp "$source_id"
}

task_source_todo_remote_complete() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_remote_config "$source_json")"
  todo_task_mark_done "$source_json" todo_remote_mcp "$source_id"
}
