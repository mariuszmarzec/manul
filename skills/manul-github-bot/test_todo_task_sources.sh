#!/usr/bin/env bash
# Regression tests for the separate Todo Desktop and Fiteo MCP source adapters.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/manul-todo-sources-XXXXXX)"
BIN="$TEST_DIR/bin"
mkdir -p "$BIN"
trap 'rm -rf "$TEST_DIR"' EXIT
PYTHON_BIN="$(command -v python3)"

PASS=0
FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains() { [[ "$2" == *"$3"* ]] && ok "$1" || fail "$1"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && ok "$1" || fail "$1"; }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (expected '$2', got '$3')"; }
assert_rc() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (expected rc=$2, got rc=$3)"; }

cat > "$BIN/python3" <<'PYTHON'
#!/usr/bin/env bash
set -uo pipefail
if [[ " $* " != *" --tool "* ]]; then
  exec "$REAL_PYTHON_BIN" "$@"
fi
tool=""
arguments="{}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool) tool="$2"; shift 2 ;;
    --arguments) arguments="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$tool" in
  list_tasks|todo_list_tasks)
    cat "$TODO_MCP_FIXTURE"
    ;;
  create_task|todo_create_task)
    printf '%s\t%s\n' "$tool" "$arguments" >> "$TODO_MCP_CALL_LOG"
    if [ "${TODO_MCP_FAIL_CREATE:-0}" = "1" ]; then
      echo "injected create failure" >&2
      exit 2
    fi
    if [ "$tool" = "create_task" ]; then
      description="$(jq -r '.description' <<<"$arguments")"
      parent_id="$(jq -r '.parentTaskId' <<<"$arguments")"
    else
      description="$(jq -r '.task.description' <<<"$arguments")"
      parent_id="$(jq -r '.task.parentTaskId' <<<"$arguments")"
    fi
    task_id="$(jq '[.. | objects | .id? // empty] | max + 1' "$TODO_MCP_FIXTURE")"
    jq --argjson parentId "$parent_id" --argjson id "$task_id" --arg description "$description" '
      map(if .id == $parentId then
        .subTasks = ((.subTasks // []) + [{
          id:$id, description:$description, parentTaskId:$parentId,
          subTasks:[], isToDo:true, priority:1, scheduler:null, shares:[]
        }])
      else . end)
    ' "$TODO_MCP_FIXTURE" > "$TODO_MCP_FIXTURE.next"
    mv "$TODO_MCP_FIXTURE.next" "$TODO_MCP_FIXTURE"
    jq -cn --argjson id "$task_id" --arg description "$description" '{id:$id,description:$description}'
    ;;
  mark_tasks_done|todo_mark_tasks)
    printf '%s\t%s\n' "$tool" "$arguments" >> "$TODO_MCP_CALL_LOG"
    if [ "${TODO_MCP_FAIL_MARK:-0}" = "1" ]; then
      echo "injected mark failure" >&2
      exit 2
    fi
    ids="$(jq -c '.taskIds // []' <<<"$arguments")"
    jq --argjson ids "$ids" '
      def mark:
        if (.id as $id | ($ids | index($id)) != null) then .isToDo=false else . end
        | .subTasks |= map(mark);
      map(mark)
    ' "$TODO_MCP_FIXTURE" > "$TODO_MCP_FIXTURE.next"
    mv "$TODO_MCP_FIXTURE.next" "$TODO_MCP_FIXTURE"
    printf '{"success":true}\n'
    ;;
  todo_update_task)
    printf '%s\t%s\n' "$tool" "$arguments" >> "$TODO_MCP_CALL_LOG"
    if [ "${TODO_MCP_FAIL_MARK:-0}" = "1" ]; then
      echo "injected mark failure" >&2
      exit 2
    fi
    task_id="$(jq -r '.id' <<<"$arguments")"
    jq --argjson taskId "$task_id" '
      def mark:
        if .id == $taskId then .isToDo=false else . end
        | .subTasks |= map(mark);
      map(mark)
    ' "$TODO_MCP_FIXTURE" > "$TODO_MCP_FIXTURE.next"
    mv "$TODO_MCP_FIXTURE.next" "$TODO_MCP_FIXTURE"
    printf '{"success":true}\n'
    ;;
  *)
    echo "unexpected fake MCP tool: $tool" >&2
    exit 2
    ;;
esac
PYTHON
chmod +x "$BIN/python3"
export REAL_PYTHON_BIN="$PYTHON_BIN"
cat > "$BIN/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
url=""
for arg in "$@"; do url="$arg"; done
case "$url" in
  http://127.0.0.1:8765/mcp)
    status="$(printenv TODO_LOCAL_MCP_DIRECT_STATUS 2>/dev/null || printf '401')"
    ;;
  http://127.0.0.1:8766/mcp)
    status="$(printenv TODO_LOCAL_MCP_BRIDGE_STATUS 2>/dev/null || printf '000')"
    ;;
  *)
    status="000"
    ;;
esac
printf '%s' "$status"
[ "$status" = "401" ] && exit 0
exit 7
CURL
chmod +x "$BIN/curl"
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=native
export TODO_LOCAL_MCP_DIRECT_STATUS=401
export TODO_LOCAL_MCP_BRIDGE_STATUS=000
export PATH="$BIN:$PATH"
export TODO_LOCAL_MCP_TOKEN="local-test-token"
export FITEO_PAT="remote-test-token"
export TODO_MCP_CALL_LOG="$TEST_DIR/mcp-calls.log"
touch "$TODO_MCP_CALL_LOG"

cat > "$TEST_DIR/project-repositories.json" <<'JSON'
{
  "version": 1,
  "repositories": [
    {"name":"owner/local","aliases":["local project","local repo"],"description":"Local test project","skills":[]},
    {"name":"owner/remote","aliases":["remote project","remote service"],"description":"Remote test project","skills":["fiteo-backend-api"]},
    {"name":"owner/link-target","aliases":["linked project"],"description":"Explicit link target","skills":[]},
    {"name":"owner/fiteo","aliases":["fiteo"],"description":"Fiteo backend","skills":[]},
    {"name":"owner/fiteo-app","aliases":["fiteo app"],"description":"Fiteo mobile app","skills":[]},
    {"name":"owner/ambiguous-a","aliases":["shared module"],"description":"Ambiguous project A","skills":[]},
    {"name":"owner/ambiguous-b","aliases":["shared module"],"description":"Ambiguous project B","skills":[]}
  ]
}
JSON
export TODO_TASK_REPOSITORY_CATALOG="$TEST_DIR/project-repositories.json"

source "$SCRIPT_DIR/task-source-todo-local.sh"
source "$SCRIPT_DIR/task-source-todo-remote.sh"

cat > "$TEST_DIR/local.json" <<'JSON'
[
  {
    "id": 1,
    "description": "/manul Implement local project task",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 10,
        "description": "First step",
        "addedTime": "2026-10-01T10:01:00",
        "modifiedTime": "2026-10-01T10:01:00",
        "parentTaskId": 1,
        "subTasks": [
          {
            "id": 11,
            "description": "Nested step",
            "addedTime": "2026-10-01T10:02:00",
            "modifiedTime": "2026-10-01T10:02:00",
            "parentTaskId": 10,
            "subTasks": [],
            "isToDo": true,
            "priority": 3,
            "scheduler": null,
            "shares": []
          }
        ],
        "isToDo": true,
        "priority": 4,
        "scheduler": null,
        "shares": []
      },
      {
        "id": 12,
        "description": "Second step",
        "addedTime": "2026-10-01T10:03:00",
        "modifiedTime": "2026-10-01T10:03:00",
        "parentTaskId": 1,
        "subTasks": [],
        "isToDo": false,
        "priority": 9,
        "scheduler": null,
        "shares": []
      }
    ],
    "isToDo": true,
    "priority": 2,
    "scheduler": null,
    "shares": []
  },
  {
    "id": 2,
    "description": "No trigger",
    "addedTime": "2026-10-01T11:00:00",
    "modifiedTime": "2026-10-01T11:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": []
  },
  {
    "id": 3,
    "description": "/manul Scheduled root",
    "addedTime": "2026-10-01T12:00:00",
    "modifiedTime": "2026-10-01T12:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": {"type":"OneShot"},
    "shares": []
  },
  {
    "id": 4,
    "description": "/manul Already done",
    "addedTime": "2026-10-01T13:00:00",
    "modifiedTime": "2026-10-01T13:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": false,
    "priority": 1,
    "scheduler": null,
    "shares": []
  }
]
JSON

cat > "$TEST_DIR/remote.json" <<'JSON'
[
  {
    "id": 21,
    "ownerId": 4,
    "description": "Implement remote project task",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 22,
        "ownerId": 4,
        "description": "Shared child step",
        "addedTime": "2026-10-01T10:01:00",
        "modifiedTime": "2026-10-01T10:01:00",
        "parentTaskId": 21,
        "subTasks": [
          {
            "id": 23,
            "ownerId": 4,
            "description": "Shared nested step",
            "addedTime": "2026-10-01T10:02:00",
            "modifiedTime": "2026-10-01T10:02:00",
            "parentTaskId": 22,
            "subTasks": [],
            "isToDo": true,
            "priority": 7,
            "scheduler": null,
            "shares": []
          },
          {
            "id": 26,
            "ownerId": 4,
            "description": "Previously completed sibling",
            "addedTime": "2026-10-01T10:02:30",
            "modifiedTime": "2026-10-01T10:02:30",
            "parentTaskId": 22,
            "subTasks": [],
            "isToDo": false,
            "priority": 9,
            "scheduler": null,
            "shares": []
          }
        ],
        "isToDo": true,
        "priority": 8,
        "scheduler": null,
        "shares": []
      }
    ],
    "isToDo": true,
    "priority": 2,
    "scheduler": null,
    "shares": [
      {"userId":"77","permission":"EDITOR_AND_VIEWER"}
    ]
  },
  {
    "id": 24,
    "ownerId": 4,
    "description": "Viewer-only task",
    "addedTime": "2026-10-01T11:00:00",
    "modifiedTime": "2026-10-01T11:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": [
      {"userId":"77","permission":"VIEWER"}
    ]
  },
  {
    "id": 25,
    "ownerId": 4,
    "description": "Not shared",
    "addedTime": "2026-10-01T12:00:00",
    "modifiedTime": "2026-10-01T12:00:00",
    "parentTaskId": null,
    "subTasks": [],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": []
  }
]
JSON

LOCAL_SOURCE='{"type":"todo_local_mcp","repositoryAllowlist":["owner/local","owner/link-target","owner/fiteo-app"],"tokenEnv":"TODO_LOCAL_MCP_TOKEN"}'
REMOTE_SOURCE='{"type":"todo_remote_mcp","repositoryAllowlist":["owner/remote"],"tokenEnv":"FITEO_PAT","manulUserId":77,"url":"https://fiteo.example.test/mcp"}'

echo "=== Repository routing ==="
local_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":90,"description":"/manul Update local project"}')"
assert_eq "catalog alias resolves the canonical local repository" "owner/local" "$(jq -r '.repository' <<<"$local_resolution")"
assert_eq "catalog alias records its resolution method" "catalog_alias" "$(jq -r '.method' <<<"$local_resolution")"
assert_eq "catalog alias records the matched phrase" "local project" "$(jq -r '.matchedAlias' <<<"$local_resolution")"

remote_resolution="$(todo_task_resolve_repository "$REMOTE_SOURCE" '{"id":91,"description":"/manul Implement remote project"}')"
assert_eq "remote alias resolves the remote project" "owner/remote" "$(jq -r '.repository' <<<"$remote_resolution")"
remote_skill_prompt="$(todo_task_to_source_json '{"id":91,"description":"/manul Implement remote project","subTasks":[],"isToDo":true}' todo_remote_mcp "$remote_resolution")"
assert_contains "mapped project skill is supplied in task context" "$(jq -r '.prompt' <<<"$remote_skill_prompt")" 'fiteo-docs'

linked_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":92,"description":"/manul Fix this: https://github.com/owner/link-target/issues/42"}')"
assert_eq "explicit GitHub URL has precedence and resolves its repository" "owner/link-target" "$(jq -r '.repository' <<<"$linked_resolution")"
assert_eq "explicit URL is identified as the routing source" "explicit_github_url" "$(jq -r '.method' <<<"$linked_resolution")"

specific_source='{"repositoryAllowlist":["owner/fiteo","owner/fiteo-app"]}'
specific_resolution="$(todo_task_resolve_repository "$specific_source" '{"id":93,"description":"/manul Update the Fiteo App"}')"
assert_eq "longest matching alias distinguishes Fiteo App from Fiteo backend" "owner/fiteo-app" "$(jq -r '.repository' <<<"$specific_resolution")"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":94,"description":"/manul Update the shared module"}' 2>"$TEST_DIR/ambiguous.log" >/dev/null || resolution_rc=$?
assert_rc "duplicate alias is rejected instead of guessing" "1" "$resolution_rc"
assert_contains "ambiguous routing explains the candidate projects" "$(cat "$TEST_DIR/ambiguous.log")" "routing is ambiguous"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":95,"description":"/manul Update remote project"}' 2>"$TEST_DIR/allowlist.log" >/dev/null || resolution_rc=$?
assert_rc "source allowlist rejects an otherwise known project" "1" "$resolution_rc"
assert_contains "allowlist rejection identifies the denied repository" "$(cat "$TEST_DIR/allowlist.log")" "owner/remote"

empty_source='{"repositoryAllowlist":[],"repositoryAllowlistEnforced":true}'
resolution_rc=0
todo_task_resolve_repository "$empty_source" '{"id":98,"description":"/manul Update local project"}' 2>"$TEST_DIR/empty-allowlist.log" >/dev/null || resolution_rc=$?
assert_rc "explicit empty repository allowlist denies all catalog targets" "1" "$resolution_rc"
assert_contains "empty allowlist rejection is explicit" "$(cat "$TEST_DIR/empty-allowlist.log")" "excluded by this Todo source allowlist"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":96,"description":"/manul Fetch weather for Krakow"}' 2>"$TEST_DIR/unmatched.log" >/dev/null || resolution_rc=$?
assert_rc "task without a project reference remains unresolved" "1" "$resolution_rc"
assert_contains "unmatched task explains why routing was not selected" "$(cat "$TEST_DIR/unmatched.log")" "no project alias matched"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":97,"description":"/manul Work on https://github.com/other-owner/private-repo"}' 2>"$TEST_DIR/uncatalogued.log" >/dev/null || resolution_rc=$?
assert_rc "explicit repository outside the curated catalog is rejected" "1" "$resolution_rc"
assert_contains "uncatalogued repository is reported" "$(cat "$TEST_DIR/uncatalogued.log")" "not in the curated project catalog"

echo "=== Local Todo source ==="
export TODO_MCP_FIXTURE="$TEST_DIR/local.json"
local_tasks="$(task_source_todo_local_poll "$LOCAL_SOURCE")"
assert_eq "only local /manul root is enqueued" "1" "$(printf '%s\n' "$local_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
local_task="$(printf '%s\n' "$local_tasks" | jq -c '.')"
assert_contains "local root source type is normalized" "$local_task" '"taskSourceType":"todo_local_mcp"'
assert_eq "local Todo adapter assigns repository from description, not a static default" "owner/local" "$(jq -r '.metadata.repository' <<<"$local_task")"
assert_eq "local source persists repository-resolution provenance" "catalog_alias" "$(jq -r '.metadata.repositoryResolution.method' <<<"$local_task")"
assert_contains "local Todo uses the default loopback URL" "$(todo_source_local_config "$LOCAL_SOURCE")" 'http://127.0.0.1:8765/mcp'

# WSL prefers direct loopback but falls back to its authenticated bridge when
# Todo Desktop runs on the Windows host and direct loopback is unavailable.
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=wsl
export TODO_LOCAL_MCP_DIRECT_STATUS=000
export TODO_LOCAL_MCP_BRIDGE_STATUS=401
wsl_local_config="$(todo_source_local_config "$LOCAL_SOURCE")"
assert_contains "WSL falls back to the existing Todo bridge when direct loopback is unavailable" "$wsl_local_config" 'http://127.0.0.1:8766/mcp'
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=native
export TODO_LOCAL_MCP_DIRECT_STATUS=401
export TODO_LOCAL_MCP_BRIDGE_STATUS=000
assert_contains "local Todo accepts localhost on another port" "$(todo_source_local_config '{"type":"todo_local_mcp","url":"http://localhost:9876/mcp"}')" 'http://localhost:9876/mcp'
assert_contains "local Todo accepts IPv6 loopback" "$(todo_source_local_config '{"type":"todo_local_mcp","url":"http://[::1]:8766/mcp"}')" 'http://[::1]:8766/mcp'
if todo_source_local_config '{"type":"todo_local_mcp","url":"http://todo.example.test:8766/mcp"}' >/dev/null 2>&1; then
  fail "local Todo rejects non-loopback MCP hosts"
else
  ok "local Todo rejects non-loopback MCP hosts"
fi
local_prompt="$(jq -r '.prompt' <<<"$local_task")"
assert_contains "local prompt preserves first subtask before nested and sibling steps" "$local_prompt" '1. [TODO] First step'
assert_contains "nested step immediately follows its parent in the supplied tree order" "$local_prompt" '2. [TODO] Nested step'
assert_contains "later sibling remains after nested child" "$local_prompt" '3. [DONE] Second step'
assert_not_contains "local subtask is not enqueued as an independent root" "$local_tasks" '"taskSourceId":"10@'
assert_eq "local revalidation accepts unchanged task tree" "0" "$(
  task_source_todo_local_revalidate "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")"; echo $?
)"

local_fingerprint="$(todo_task_version_from_source_id "$(jq -r '.taskSourceId' <<<"$local_task")")"
jq '.[0].subTasks[0].description = "Externally changed step"' "$TEST_DIR/local.json" > "$TEST_DIR/local-changed.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-changed.json"
rc=0
task_source_todo_local_revalidate "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")" || rc=$?
assert_rc "local revalidation rejects a changed task tree" "1" "$rc"

# Completing a previously-active child changes Fiteo's isToDo-first sort and
# modifiedTime tie-breaker. This provider reorder must not invalidate the tree.
jq '.[0].subTasks[0].isToDo = false
    | .[0].subTasks[0].modifiedTime = "2026-10-02T10:00:00"
    | .[0].subTasks |= reverse' "$TEST_DIR/local.json" > "$TEST_DIR/local-progress-reordered.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-progress-reordered.json"
assert_eq "local revalidation accepts provider reordering caused by completed steps" "0" "$(
  task_source_todo_local_revalidate "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")"; echo $?
)"

export TODO_MCP_FIXTURE="$TEST_DIR/local.json"
: > "$TODO_MCP_CALL_LOG"
task_source_todo_local_complete "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")"
local_call="$(cat "$TODO_MCP_CALL_LOG")"
assert_contains "local completion uses local bulk mark tool" "$local_call" 'mark_tasks_done'
assert_contains "local completion includes root and all descendants with root last" "$local_call" '"taskIds":[12,11,10,1]'

jq '.[0].isToDo = false | .[0].subTasks[0].isToDo = false | .[0].subTasks[0].subTasks[0].isToDo = false | .[0].subTasks[1].isToDo = false' "$TEST_DIR/local.json" > "$TEST_DIR/local-done.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-done.json"
: > "$TODO_MCP_CALL_LOG"
task_source_todo_local_complete "$LOCAL_SOURCE" "$(jq -r '.taskSourceId' <<<"$local_task")"
assert_eq "local completion retry confirms an already-done tree without another MCP mutation" "0" "$(wc -l < "$TODO_MCP_CALL_LOG" | tr -d ' ')"

echo "=== Remote Fiteo source ==="
export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"
remote_tasks="$(task_source_todo_remote_poll "$REMOTE_SOURCE")"
assert_eq "only explicitly editor-shared remote root is enqueued" "1" "$(printf '%s\n' "$remote_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
remote_task="$(printf '%s\n' "$remote_tasks" | jq -c '.')"
assert_contains "remote root source type is normalized" "$remote_task" '"taskSourceType":"todo_remote_mcp"'
assert_eq "remote Fiteo adapter assigns repository from shared task description" "owner/remote" "$(jq -r '.metadata.repository' <<<"$remote_task")"
assert_eq "remote source persists alias provenance" "remote project" "$(jq -r '.metadata.repositoryResolution.matchedAlias' <<<"$remote_task")"
assert_not_contains "viewer-only task is excluded" "$remote_tasks" '"taskSourceId":"24@'
assert_not_contains "unshared task is excluded" "$remote_tasks" '"taskSourceId":"25@'
remote_id="$(jq -r '.taskSourceId' <<<"$remote_task")"
assert_eq "remote revalidation accepts unchanged tree" "0" "$(
  task_source_todo_remote_revalidate "$REMOTE_SOURCE" "$remote_id"; echo $?
)"

# A completed child and changed modifiedTime must not invalidate a retry while
# the root remains active; the structural fingerprint deliberately ignores
# progress flags/timestamps but still detects topology/content changes.
jq '.[0].subTasks[0].subTasks[0].isToDo = false
    | .[0].subTasks[0].subTasks[0].modifiedTime = "2026-10-02T10:00:00"
    | .[0].subTasks[0].subTasks |= reverse' \
  "$TEST_DIR/remote.json" > "$TEST_DIR/remote-progress.json"
export TODO_MCP_FIXTURE="$TEST_DIR/remote-progress.json"
assert_eq "partial subtask completion does not invalidate source identity" "0" "$(
  task_source_todo_remote_revalidate "$REMOTE_SOURCE" "$remote_id"; echo $?
)"

export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"
: > "$TODO_MCP_CALL_LOG"
task_source_todo_remote_complete "$REMOTE_SOURCE" "$remote_id"
remote_calls="$(cat "$TODO_MCP_CALL_LOG")"
assert_eq "remote marks each descendant and root individually" "4" "$(printf '%s\n' "$remote_calls" | wc -l | tr -d ' ')"
assert_contains "remote completion uses Fiteo partial update tool" "$remote_calls" 'todo_update_task'
assert_contains "remote completion updates nested child before its parent" "$remote_calls" '"id":23'
first_remote_id="$(head -1 "$TODO_MCP_CALL_LOG" | cut -f2- | jq -r '.id')"
last_remote_id="$(tail -1 "$TODO_MCP_CALL_LOG" | cut -f2- | jq -r '.id')"
assert_eq "remote completion marks the root last for retry safety" "21" "$last_remote_id"
assert_eq "remote completion starts with the last ordered sibling" "26" "$first_remote_id"
remote_order="$(cut -f2- "$TODO_MCP_CALL_LOG" | jq -cs '[.[].id]')"
assert_eq "remote completion reverses the original ordered tree" "[26,23,22,21]" "$remote_order"

echo "=== Report-only Todo delivery ==="
cat > "$TEST_DIR/local-report.json" <<'JSON'
[
  {"id":501,"description":"/manul report Summarize local report delivery","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
LOCAL_REPORT_SOURCE='{"type":"todo_local_mcp","url":"http://127.0.0.1:8766/mcp","tokenEnv":"TODO_LOCAL_MCP_TOKEN","allowReportOnly":true,"repositoryAllowlist":[],"repositoryAllowlistEnforced":true}'
export TODO_MCP_FIXTURE="$TEST_DIR/local-report.json"
local_report_task="$(task_source_todo_local_poll "$LOCAL_REPORT_SOURCE")"
assert_eq "local report-only task is discovered without repository routing" "report_only" "$(jq -r '.execution.kind' <<<"$local_report_task")"
assert_eq "local report-only task carries no repository metadata" "null" "$(jq -r '.metadata.repository // null' <<<"$local_report_task")"
local_report_id="$(jq -r '.taskSourceId' <<<"$local_report_task")"
assert_eq "local report source is current before execution" "0" "$(todo_task_still_current "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id"; echo $?)"
: > "$TODO_MCP_CALL_LOG"
export TODO_MCP_FAIL_MARK=1
local_report_rc=0
todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" "Local report answer with exact content." >/dev/null || local_report_rc=$?
assert_rc "failed completion mutation leaves the report task retryable" "2" "$local_report_rc"
partial_local_root_status=$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "partial local write leaves root task active" "true" "$partial_local_root_status"
partial_local_child_count=$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")
assert_eq "partial local write keeps one result subtask" "1" "$partial_local_child_count"
partial_local_child_status=$(jq -r .[0].subTasks[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "partial local write leaves result subtask pending" "true" "$partial_local_child_status"
unset TODO_MCP_FAIL_MARK
local_report_receipt="$(todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" "Local report answer with exact content.")"
assert_eq "local report receipt preserves the exact answer" "Local report answer with exact content." "$(jq -r '.answer' <<<"$local_report_receipt")"
local_report_result_id="$(jq -r '.resultTaskId' <<<"$local_report_receipt")"
jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE" > "$TEST_DIR/local-report-child-status"
IFS= read -r local_report_child_status < "$TEST_DIR/local-report-child-status"
assert_eq "local result child is marked completed after read-back" "false" "$local_report_child_status"
jq -r '.[0].subTasks[0].parentTaskId' "$TODO_MCP_FIXTURE" > "$TEST_DIR/local-report-child-parent"
IFS= read -r local_report_child_parent < "$TEST_DIR/local-report-child-parent"
assert_eq "local result retains parent relationship" "501" "$local_report_child_parent"
local_report_root_status=$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "local result output leaves root active until tree completion" "true" "$local_report_root_status"
local_verified_source_rc=0
todo_task_still_current "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" || local_verified_source_rc=$?
assert_eq "verified local report child does not invalidate structural source identity" "0" "$local_verified_source_rc"
todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" "A regenerated retry answer must not create a duplicate child." > "$TEST_DIR/local-retry-receipt.json"
jq -r .resultTaskId "$TEST_DIR/local-retry-receipt.json" > "$TEST_DIR/local-retry-result-id"
IFS= read -r local_retry_result_id < "$TEST_DIR/local-retry-result-id"
assert_eq "local report retry reuses the existing child" "$local_report_result_id" "$local_retry_result_id"
jq -r .answer "$TEST_DIR/local-retry-receipt.json" > "$TEST_DIR/local-retry-answer"
IFS= read -r local_retry_answer < "$TEST_DIR/local-retry-answer"
assert_eq "local report retry returns the exact previously persisted answer" "Local report answer with exact content." "$local_retry_answer"
grep -Fc "create_task" "$TODO_MCP_CALL_LOG" > "$TEST_DIR/local-create-count"
IFS= read -r local_create_count < "$TEST_DIR/local-create-count"
assert_eq "local report creates only one output child across retry" "1" "$local_create_count"
jq --arg desc "/manul report User changed source after delivery" '.[0].description = $desc' "$TODO_MCP_FIXTURE" > "$TEST_DIR/local-report-edited.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-report-edited.json"
local_report_reval_rc=0
todo_task_still_current "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" || local_report_reval_rc=$?
assert_rc "user edits remain visible to source fingerprint after output child is excluded" "1" "$local_report_reval_rc"

# A new /manul report version must retain the previous result as history
# while excluding only the output child bound to the newly polled source version.
jq '.[0].description = "/manul report Updated request after initial report"' "$TEST_DIR/local-report.json" > "$TEST_DIR/local-report-second-version.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-report-second-version.json"
local_second_report_task="$(task_source_todo_local_poll "$LOCAL_REPORT_SOURCE")"
local_second_report_id="$(jq -r '.taskSourceId' <<<"$local_second_report_task")"
assert_not_contains "second report version receives a new source identity" "$local_second_report_id" "$local_report_id"
local_second_report_receipt="$(todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_second_report_id" "Second report answer.")"
assert_eq "second report version persists its exact answer" "Second report answer." "$(jq -r '.answer' <<<"$local_second_report_receipt")"
jq -r .[0].subTasks[].description "$TODO_MCP_FIXTURE" > "$TEST_DIR/historical-report-descriptions"
grep -Fc "Local report answer with exact content." "$TEST_DIR/historical-report-descriptions" > "$TEST_DIR/historical-report-count" || true
IFS= read -r historical_report_count < "$TEST_DIR/historical-report-count"
assert_eq "previous report remains in the source tree as history" "1" "$historical_report_count"
assert_eq "second report is excluded without hiding the historical output" "0" "$(todo_task_still_current "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_second_report_id"; echo $?)"

cat > "$TEST_DIR/local-report-create-failure.json" <<'JSON'
[
  {"id":502,"description":"/manul report Create failure fixture","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/local-report-create-failure.json"
local_create_failure_task="$(task_source_todo_local_poll "$LOCAL_REPORT_SOURCE")"
local_create_failure_id="$(jq -r '.taskSourceId' <<<"$local_create_failure_task")"
export TODO_MCP_FAIL_CREATE=1
local_create_failure_rc=0
todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_create_failure_id" "Must not be lost." >/dev/null || local_create_failure_rc=$?
unset TODO_MCP_FAIL_CREATE
assert_rc "local result creation failure is surfaced" "2" "$local_create_failure_rc"
local_create_failure_root_status=$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "local result creation failure leaves root active" "true" "$local_create_failure_root_status"
local_create_failure_child_count=$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")
assert_eq "local result creation failure writes no child" "0" "$local_create_failure_child_count"

cat > "$TEST_DIR/remote-report.json" <<'JSON'
[
  {"id":601,"ownerId":4,"description":"/manul report Summarize remote report delivery","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
REMOTE_REPORT_SOURCE='{"type":"todo_remote_mcp","allowReportOnly":true,"repositoryAllowlist":[],"repositoryAllowlistEnforced":true,"manulUserId":77,"url":"https://fiteo.example.test/mcp","tokenEnv":"FITEO_PAT"}'
export TODO_MCP_FIXTURE="$TEST_DIR/remote-report.json"
remote_report_task="$(task_source_todo_remote_poll "$REMOTE_REPORT_SOURCE")"
assert_eq "remote report-only task is discovered without repository routing" "report_only" "$(jq -r '.execution.kind' <<<"$remote_report_task")"
remote_report_id="$(jq -r '.taskSourceId' <<<"$remote_report_task")"
: > "$TODO_MCP_CALL_LOG"
export TODO_MCP_FAIL_MARK=1
remote_report_rc=0
todo_task_report_deliver "$REMOTE_REPORT_SOURCE" todo_remote_mcp "$remote_report_id" "Remote Fiteo report answer." >/dev/null || remote_report_rc=$?
assert_rc "remote partial completion failure remains retryable" "2" "$remote_report_rc"
remote_partial_root_status=$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "remote partial write leaves root active" "true" "$remote_partial_root_status"
remote_partial_child_count=$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")
assert_eq "remote partial write keeps exactly one result child" "1" "$remote_partial_child_count"
remote_pending_status="$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "remote result child stays pending when completion update fails" "true" "$remote_pending_status"
unset TODO_MCP_FAIL_MARK
remote_report_receipt="$(todo_task_report_deliver "$REMOTE_REPORT_SOURCE" todo_remote_mcp "$remote_report_id" "A regenerated retry answer must reuse the persisted result.")"
assert_eq "remote retry returns the exact previously persisted answer" "Remote Fiteo report answer." "$(jq -r '.answer' <<<"$remote_report_receipt")"
remote_result_id="$(jq -r '.resultTaskId' <<<"$remote_report_receipt")"
remote_create_call_count=$(grep -c todo_create_task "$TODO_MCP_CALL_LOG")
assert_eq "remote report uses Fiteo create tool only once across retry" "1" "$remote_create_call_count"
remote_update_call_count=$(grep -c todo_update_task "$TODO_MCP_CALL_LOG")
assert_eq "remote report retries Fiteo completion update" "2" "$remote_update_call_count"
remote_report_child_status=$(jq -r .[0].subTasks[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "remote result child is completed after verified retry read-back" "false" "$remote_report_child_status"
remote_root_todo="$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")"
assert_eq "remote root remains active until the task tree completion step" "true" "$remote_root_todo"
assert_eq "remote output result does not invalidate source identity" "0" "$(todo_task_still_current "$REMOTE_REPORT_SOURCE" todo_remote_mcp "$remote_report_id"; echo $?)"

# The common completion operation must still mark the report child and all
# original descendants first, then the source root last.
task_source_todo_remote_complete "$REMOTE_REPORT_SOURCE" "$remote_report_id"
remote_report_root_status="$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")"
assert_eq "remote report tree completion marks the root last" "false" "$remote_report_root_status"

cat > "$TEST_DIR/remote-report-create-failure.json" <<'JSON'
[
  {"id":602,"ownerId":4,"description":"/manul report Remote create failure fixture","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/remote-report-create-failure.json"
task_source_todo_remote_poll "$REMOTE_REPORT_SOURCE" > "$TEST_DIR/remote-create-failure-task.json"
jq -r .taskSourceId "$TEST_DIR/remote-create-failure-task.json" > "$TEST_DIR/remote-create-failure-id"
IFS= read -r remote_create_failure_id < "$TEST_DIR/remote-create-failure-id"
export TODO_MCP_FAIL_CREATE=1
remote_create_failure_rc=0
todo_task_report_deliver "$REMOTE_REPORT_SOURCE" todo_remote_mcp "$remote_create_failure_id" "Must remain active." >/dev/null || remote_create_failure_rc=$?
unset TODO_MCP_FAIL_CREATE
assert_rc "remote result creation failure is surfaced" "2" "$remote_create_failure_rc"
remote_create_failure_root_status=$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "remote result creation failure leaves root active" "true" "$remote_create_failure_root_status"
remote_create_failure_child_count=$(jq -r ".[0].subTasks | length" "$TODO_MCP_FIXTURE")
assert_eq "remote result creation failure writes no child" "0" "$remote_create_failure_child_count"


echo
if "$PYTHON_BIN" "$SCRIPT_DIR/test_todo_mcp_client.py"; then
  ok "Streamable HTTP MCP client tests passed"
else
  fail "Streamable HTTP MCP client tests failed"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
