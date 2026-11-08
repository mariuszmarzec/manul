#!/usr/bin/env bash
# Independent source adapter for Todo Desktop's local MCP endpoint.
set -uo pipefail

TODO_LOCAL_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$TODO_LOCAL_SOURCE_DIR/todo-task-source-utils.sh"

TODO_AICODE_DIR="${AICODE_SOURCE_DIR:-$HOME/.globalskills/aicode}"
TODO_LOCAL_URL_HELPER="$TODO_AICODE_DIR/todo-local-mcp-url.sh"
TODO_LOCAL_URL_HELPER_AVAILABLE=false
if [ -r "$TODO_LOCAL_URL_HELPER" ]; then
  # Shared endpoint discovery is owned by globalskills/aicode.
  # shellcheck source=~/.globalskills/aicode/todo-local-mcp-url.sh
  source "$TODO_LOCAL_URL_HELPER"
  TODO_LOCAL_URL_HELPER_AVAILABLE=true
else
  todo_local_mcp_url_is_supported() { return 1; }
  todo_local_mcp_resolve_url() { return 1; }
fi

todo_source_local_config() {
  local source_json="$1" url configured_url resolved_url
  configured_url="$(jq -r '.url // empty' <<<"$source_json")" || return 2

  # Preserve explicitly configured custom loopback ports. The two standard
  # endpoints are resolved dynamically so an old 8766 config migrates to
  # native 8765 where possible while WSL can still select its relay.
  if [ -n "$configured_url" ] &&
     [ "$configured_url" != "http://127.0.0.1:8765/mcp" ] &&
     [ "$configured_url" != "http://127.0.0.1:8766/mcp" ]; then
    url="$configured_url"
    if ! todo_local_mcp_url_is_supported "$url"; then
      echo "task-source: local Todo MCP URL must use HTTP loopback and the /mcp path" >&2
      return 2
    fi
  else
    url="$(todo_local_mcp_resolve_url "$configured_url")" || {
      echo "task-source: Todo Desktop MCP is not reachable on a supported local endpoint" >&2
      return 2
    }
  fi

  jq -c --arg url "$url" '
    .url = $url
    | del(.tokenEnv)
  ' <<<"$source_json"
}
task_source_todo_local_poll() {
  local source_json tasks_json task_json normalized resolution task_id
  if ! todo_mcp_client_available || [ "$TODO_LOCAL_URL_HELPER_AVAILABLE" != "true" ]; then
    echo "task-source: Todo Local source is disabled because globalskills/aicode Todo MCP helpers are unavailable" >&2
    return 0
  fi
  if ! source_json="$(todo_source_local_config "$1")"; then
    echo "task-source: Todo Local endpoint is unavailable or invalid; skipping optional source" >&2
    return 0
  fi

  if ! tasks_json="$(todo_mcp_source_list_tasks "$source_json" todo_local_mcp)"; then
    echo "task-source: Todo Local MCP is unavailable; skipping optional source" >&2
    return 0
  fi
  while IFS= read -r task_json; do
    [ -n "$task_json" ] || continue
    todo_task_is_active "$task_json" || continue
    todo_task_has_local_trigger "$task_json" || continue
    task_id="$(jq -r '.id // "unknown"' <<<"$task_json")"
    if todo_task_is_report_only "$task_json"; then
      # Keep /manul report as a backwards-compatible explicit alias.
      resolution='{"reportOnly":true}'
    else
      local resolution_output resolution_rc
      resolution_output="$(todo_task_resolve_repository "$source_json" "$task_json" 2>&1)"
      resolution_rc=$?
      if [ "$resolution_rc" -eq 0 ]; then
        resolution="$resolution_output"
      elif [ "$resolution_rc" -eq 3 ]; then
        # No project was specified: treat a normal /manul prompt as an
        # informational request and save its answer under the Todo root.
        echo "task-source: local Todo task $task_id has no repository match; treating it as report-only" >&2
        resolution='{"reportOnly":true}'
      else
        echo "task-source: local Todo task $task_id was not queued because its repository could not be resolved: ${resolution_output:-unknown routing error}" >&2
        continue
      fi
    fi
    normalized="$(todo_task_to_source_json "$task_json" todo_local_mcp "$resolution")" || continue
    printf '%s\n' "$normalized"
  done < <(
    jq -c '.[] | select(.parentTaskId == null) | select(.isToDo == true) | select(.scheduler == null)' <<<"$tasks_json"
  )
}

task_source_todo_local_revalidate() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_local_config "$source_json")"
  todo_task_still_current "$source_json" todo_local_mcp "$source_id"
}

task_source_todo_local_complete() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_local_config "$source_json")"
  todo_task_mark_done "$source_json" todo_local_mcp "$source_id"
}
