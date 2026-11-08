#!/usr/bin/env bash
# Independent source adapter for the remote Fiteo backend MCP endpoint.
set -uo pipefail

TODO_REMOTE_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$TODO_REMOTE_SOURCE_DIR/todo-task-source-utils.sh"

todo_source_expand_env_placeholders() {
  local template="$1"
  python3 - "$template" <<'PYTHON'
import os
import re
import sys

template = sys.argv[1]
placeholder = re.compile(r"\{env:([A-Za-z_][A-Za-z0-9_]*)\}")
unparsed = placeholder.sub("", template)
if "{env:" in unparsed:
    print("task-source: invalid environment placeholder in remote Fiteo MCP URL", file=sys.stderr)
    raise SystemExit(2)

def expand(match):
    name = match.group(1)
    value = os.environ.get(name)
    if not value:
        print(
            f"task-source: remote Fiteo MCP URL requires non-empty environment variable {name}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return value

sys.stdout.write(placeholder.sub(expand, template))
PYTHON
}

todo_source_remote_config() {
  local source_json="$1" url_template url manul_user_id_env manul_user_id
  url_template="$(jq -r '.url // empty' <<<"$source_json")"
  url="$(todo_source_expand_env_placeholders "$url_template")" || return $?
  [[ "$url" == https://* || "$url" == http://* ]] || {
    echo "task-source: remote Fiteo MCP requires an HTTP(S) URL after environment expansion" >&2
    return 2
  }

  manul_user_id_env="$(jq -r '.manulUserIdEnv // empty' <<<"$source_json")"
  if [ -n "$manul_user_id_env" ]; then
    [[ "$manul_user_id_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      echo "task-source: manulUserIdEnv must be a valid environment variable name" >&2
      return 2
    }
    manul_user_id="${!manul_user_id_env:-}"
  else
    # Keep backward compatibility with existing numeric manulUserId configs.
    manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
  fi

  [[ "$manul_user_id" =~ ^[1-9][0-9]*$ ]] || {
    if [ -n "$manul_user_id_env" ]; then
      echo "task-source: todo_remote_mcp requires a positive numeric value in $manul_user_id_env" >&2
    else
      echo "task-source: todo_remote_mcp requires a positive numeric manulUserId or manulUserIdEnv" >&2
    fi
    return 2
  }

  jq -c --arg url "$url" --argjson manulUserId "$manul_user_id" '
    .url = $url
    | .manulUserId = $manulUserId
    | .tokenEnv = "FITEO_MANUL_PAT"
    | .shareUserIdEnv = (.shareUserIdEnv // "FITEO_MANUL_SHARE_USER_ID")
  ' <<<"$source_json"
}

task_source_todo_remote_poll() {
  local source_json manul_user_id tasks_json shared_task_json normalized resolution task_id
  if ! todo_mcp_client_available; then
    echo "task-source: Todo Remote source is disabled because globalskills/aicode Todo MCP client is unavailable" >&2
    return 0
  fi
  if ! source_json="$(todo_source_remote_config "$1")"; then
    echo "task-source: Todo Remote credentials/configuration unavailable; skipping optional source" >&2
    return 0
  fi
  manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
  [[ "$manul_user_id" =~ ^[1-9][0-9]*$ ]] || {
    echo "task-source: todo_remote_mcp requires a positive numeric manulUserId" >&2
    return 2
  }

  if ! tasks_json="$(todo_mcp_source_list_tasks "$source_json" todo_remote_mcp)"; then
    echo "task-source: Todo Remote MCP is unavailable; skipping optional source" >&2
    return 0
  fi
  # Fiteo returns both owned roots and tasks shared with the PAT owner. Select
  # only explicitly shared tasks with edit permission. If both an ancestor and
  # descendant are shared, queue the ancestor once and keep the returned tree.
  while IFS= read -r shared_task_json; do
    [ -n "$shared_task_json" ] || continue
    todo_task_is_active "$shared_task_json" || continue
    todo_task_has_remote_share "$shared_task_json" "$manul_user_id" || continue
    # Sharing grants visibility; execution requires an explicit /manul command
    # in the root description or any nested subtask. Queue the root tree once.
    todo_task_has_remote_trigger "$shared_task_json" || continue
    task_id="$(jq -r '.id // "unknown"' <<<"$shared_task_json")"
    if todo_task_is_report_only "$shared_task_json"; then
      # Keep /manul report as a backwards-compatible explicit alias.
      resolution='{"reportOnly":true}'
    else
      local resolution_output resolution_rc
      resolution_output="$(todo_task_resolve_repository "$source_json" "$shared_task_json" 2>&1)"
      resolution_rc=$?
      if [ "$resolution_rc" -eq 0 ]; then
        resolution="$resolution_output"
      elif [ "$resolution_rc" -eq 3 ]; then
        # No project was specified: treat a normal /manul prompt as an
        # informational request and save its answer under the Todo root.
        echo "task-source: remote Todo task $task_id has no repository match; treating it as report-only" >&2
        resolution='{"reportOnly":true}'
      else
        echo "task-source: remote Todo task $task_id was not queued because its repository could not be resolved: ${resolution_output:-unknown routing error}" >&2
        continue
      fi
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
  source_json="$(todo_source_remote_config "$source_json")" || return $?
  todo_task_still_current "$source_json" todo_remote_mcp "$source_id"
}

task_source_todo_remote_complete() {
  local source_json="$1" source_id="$2"
  source_json="$(todo_source_remote_config "$source_json")" || return $?
  todo_task_mark_done "$source_json" todo_remote_mcp "$source_id"
}
