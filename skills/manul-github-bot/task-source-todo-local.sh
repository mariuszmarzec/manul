#!/usr/bin/env bash
# Independent source adapter for Todo Desktop's local MCP endpoint.
set -uo pipefail

TODO_LOCAL_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$TODO_LOCAL_SOURCE_DIR/todo-task-source-utils.sh"
todo_source_local_load_endpoint_helper() {
  local helper="${TODO_LOCAL_MCP_URL_HELPER:-$TODO_LOCAL_SOURCE_DIR/todo-local-mcp-url.sh}"
  local client="${TODO_MCP_CLIENT:-$TODO_LOCAL_SOURCE_DIR/todo-mcp-client.py}"
  if [ ! -r "$helper" ]; then
    echo "ERROR: task-source: bundled Todo endpoint resolver is missing or unreadable ($helper)" >&2
    return 2
  fi
  if [ ! -r "$client" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: task-source: bundled Todo MCP client is missing or Python 3 is unavailable ($client)" >&2
    return 2
  fi
  TODO_MCP_CLIENT="$client"
  export TODO_MCP_CLIENT
  if ! declare -F todo_local_mcp_resolve_url >/dev/null 2>&1; then
    source "$helper" || return 2
  fi
  declare -F todo_local_mcp_resolve_url >/dev/null 2>&1
}

todo_source_local_config() {
  local source_json="$1" url configured_url resolved_url
  todo_source_local_load_endpoint_helper || return 2
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
  source_json="$(todo_source_local_config "$1")" || return $?

  tasks_json="$(todo_mcp_source_list_tasks "$source_json" todo_local_mcp)" || return $?
  while IFS= read -r task_json; do
    [ -n "$task_json" ] || continue
    todo_task_is_active "$task_json" || continue
    todo_task_has_local_trigger "$task_json" || continue
    task_id="$(jq -r '.id // "unknown"' <<<"$task_json")"
    local resolution_output resolution_rc task_fingerprint source_id update_status update_summary update_receipt
    resolution_output="$(todo_task_resolve_repository "$source_json" "$task_json" 2>&1)"
    resolution_rc=$?
    if [ "$resolution_rc" -eq 0 ]; then
      resolution="$resolution_output"
    else
      task_fingerprint="$(todo_task_fingerprint "$task_json")" || continue
      source_id="${task_id}@${task_fingerprint}"
      if [ "$resolution_rc" -eq 1 ] || [ "$resolution_rc" -eq 3 ]; then
        update_status="needs_input"
        update_summary="$(cat <<'TODO_ROUTING_BLOCKER'
Manul nie uruchomił zadania, ponieważ nie może jednoznacznie ustalić repozytorium docelowego.

Sprawdzone zostały opis zadania, podzadania oraz skonfigurowana lista repozytoriów. Uzupełnij to podzadanie o dokładne owner/repo (lub adres repozytorium GitHub) albo jednoznaczny alias projektu z katalogu projektów. Repozytorium musi znajdować się na globalnej liście .repositories.

Szczegóły routingu:
TODO_ROUTING_BLOCKER
)"
      else
        update_status="failed"
        update_summary="Routing repozytorium zakończył się błędem przed uruchomieniem agenta (rc=$resolution_rc). Szczegóły: ${resolution_output:-brak diagnostyki}. Sprawdź konfigurację repozytoriów i katalog projektów, a następnie zaktualizuj to podzadanie, aby wznowić pracę."
      fi
      local task_description
      task_description="$(jq -r '.description // empty' <<<"$task_json")"
      if [ -n "$task_description" ]; then
        update_summary="Zadanie: $task_description"$'\n\n'"$update_summary"
      fi
      if [ -n "$resolution_output" ]; then
        update_summary+=$'\n\n'
        update_summary+="$resolution_output"
      fi
      if update_receipt="$(todo_task_publish_update "$source_json" todo_local_mcp "$source_id" "$update_status" "$update_summary" 2>&1)"; then
        echo "task-source: local Todo task $task_id was not queued; a verified $update_status subtask was saved" >&2
      else
        echo "ERROR: task-source: local Todo task $task_id could not be queued and its routing update could not be saved: ${update_receipt:-unknown error}" >&2
      fi
      continue
    fi
    normalized="$(todo_task_to_source_json "$task_json" todo_local_mcp "$resolution")" || continue
    printf '%s\n' "$normalized"
  done < <(
    jq -c '.[] | select(.parentTaskId == null) | select(.isToDo == true) | select(.scheduler == null)' <<<"$tasks_json"
  )
}

task_source_todo_local_revalidate() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_local_config "$source_json")" || return $?
  todo_task_still_current "$source_json" todo_local_mcp "$source_id"
}

task_source_todo_local_complete() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_local_config "$source_json")" || return $?
  todo_task_mark_done "$source_json" todo_local_mcp "$source_id"
}
