#!/usr/bin/env bash
# Regression tests for the separate Todo Desktop and Fiteo MCP source adapters.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/manul-todo-sources-XXXXXX)"
BIN="$TEST_DIR/bin"
mkdir -p "$BIN"
trap 'rm -rf "$TEST_DIR"' EXIT
PYTHON_BIN="$(command -v python3)"
unset TODO_LOCAL_MCP_TOKEN

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
if [[ " $* " == *" --probe "* ]]; then
  url=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) url="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$url" in
    http://127.0.0.1:8765/mcp) status="$(printenv TODO_LOCAL_MCP_DIRECT_STATUS 2>/dev/null || printf '200')" ;;
    http://127.0.0.1:8766/mcp) status="$(printenv TODO_LOCAL_MCP_BRIDGE_STATUS 2>/dev/null || printf '000')" ;;
    *) status="000" ;;
  esac
  case "$status" in
    200) exit 0 ;;
    401|403) exit 3 ;;
    *) exit 1 ;;
  esac
fi
if [[ "$*" =~ http://127\.0\.0\.1:876[56]/mcp ]] &&
   [[ " $* " == *" --token-env "* ]]; then
  echo "local Todo MCP unexpectedly received token configuration" >&2
  exit 2
fi
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
    shares="$(if [ "$tool" = "todo_create_task" ]; then jq -c '.task.shares // []' <<<"$arguments"; else printf '[]'; fi)"
    if [ "$tool" = "todo_create_task" ] && [ "${TODO_MCP_DROP_SHARE:-0}" = "1" ]; then
      shares='[]'
    fi
    if [ "$tool" = "todo_create_task" ] && [ "${TODO_MCP_WRONG_SHARE_PERMISSION:-0}" = "1" ]; then
      shares="$(jq -c 'map(.permission = "VIEWER")' <<<"$shares")"
    fi
    response_shares="$shares"
    if [ "$tool" = "todo_create_task" ] && [ "${TODO_MCP_RESPONSE_WITHOUT_SHARE:-0}" = "1" ]; then
      response_shares='[]'
    fi
    if [ "${TODO_MCP_DROP_CHILD:-0}" != "1" ]; then
      jq --argjson parentId "$parent_id" --argjson id "$task_id" --arg description "$description" --argjson shares "$shares" '
        def add_child:
          .subTasks = ((.subTasks // []) + [{
            id:$id, description:$description, parentTaskId:$parentId,
            subTasks:[], isToDo:true, priority:1, scheduler:null, shares:$shares
          }]);
        def walk:
          if .id == $parentId then add_child
          else .subTasks = ((.subTasks // []) | map(walk)) end;
        map(walk)
      ' "$TODO_MCP_FIXTURE" > "$TODO_MCP_FIXTURE.next"
      mv "$TODO_MCP_FIXTURE.next" "$TODO_MCP_FIXTURE"
    fi
    jq -cn --argjson id "$task_id" --arg description "$description" --argjson shares "$response_shares" '{id:$id,description:$description,shares:$shares}'
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

# Optional environment overrides are tested below, but the normal runtime
# resolves its bundled MCP client and endpoint helper from this Manul checkout.
SHARED_TODO_DIR="$TEST_DIR/shared-todo"
mkdir -p "$SHARED_TODO_DIR"
TODO_MCP_CLIENT="$SHARED_TODO_DIR/todo-mcp-client.py"
TODO_LOCAL_MCP_URL_HELPER="$SHARED_TODO_DIR/todo-local-mcp-url.sh"
: > "$TODO_MCP_CLIENT"
cat > "$TODO_LOCAL_MCP_URL_HELPER" <<'SHARED_TODO_HELPER'
todo_local_mcp_url_is_supported() {
  [[ "$1" =~ ^http://(localhost|127\.0\.0\.1|\[::1\]):[0-9]+/mcp$ ]]
}
todo_local_mcp_is_wsl() {
  [ "${TODO_LOCAL_MCP_PLATFORM_OVERRIDE:-}" = "wsl" ]
}
todo_local_mcp_probe_status() {
  local rc=0
  python3 "$TODO_MCP_CLIENT" --url "$1" --probe --timeout 4 >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) printf '200' ;; 3) printf 'AUTH' ;; *) printf '000' ;; esac
}
todo_local_mcp_resolve_url() {
  local preferred="$1" direct="http://127.0.0.1:8765/mcp" bridge="http://127.0.0.1:8766/mcp" status
  if [ -n "$preferred" ] && [ "$preferred" != "$direct" ] && [ "$preferred" != "$bridge" ]; then
    todo_local_mcp_url_is_supported "$preferred" || return 2
    status="$(todo_local_mcp_probe_status "$preferred")"
    [ "$status" = "200" ] && { printf '%s' "$preferred"; return 0; }
  fi
  status="$(todo_local_mcp_probe_status "$direct")"
  [ "$status" = "200" ] && { printf '%s' "$direct"; return 0; }
  if todo_local_mcp_is_wsl; then
    status="$(todo_local_mcp_probe_status "$bridge")"
    [ "$status" = "200" ] && { printf '%s' "$bridge"; return 0; }
  fi
  return 1
}
SHARED_TODO_HELPER
export TODO_MCP_CLIENT TODO_LOCAL_MCP_URL_HELPER
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=native
export TODO_LOCAL_MCP_DIRECT_STATUS=200
export TODO_LOCAL_MCP_BRIDGE_STATUS=000
export PATH="$BIN:$PATH"
export FITEO_MANUL_PAT="remote-test-token"
export FITEO_BASE_URL="https://fiteo.example.test"
export MANUL_USER_ID=77
export FITEO_MANUL_SHARE_USER_ID=88
export FITEO_PAT="operator-only-token"
export TODO_MCP_CALL_LOG="$TEST_DIR/mcp-calls.log"
touch "$TODO_MCP_CALL_LOG"

# Project skill context is read exclusively from the canonical agent skills
# directory. Keep the fixture isolated by assigning HOME at each call site.
SKILLS_HOME="$TEST_DIR/skills-home"
SKILLS_DIR="$SKILLS_HOME/.agents/skills"
mkdir -p "$SKILLS_DIR/fiteo-backend-api"
cat > "$SKILLS_DIR/fiteo-backend-api/SKILL.md" <<'SKILL'
Fiteo API integration guidance. The documentation source is fiteo-docs.
SKILL

cat > "$TEST_DIR/project-repositories.json" <<'JSON'
{
  "version": 1,
  "repositories": [
    {"name":"owner/local","aliases":["local project","local repo"],"description":"Local test project","skills":[]},
    {"name":"owner/remote","aliases":["remote project","remote service"],"description":"Remote test project","skills":["fiteo-backend-api"]},
    {"name":"owner/link-target","aliases":["linked project"],"description":"Explicit link target","skills":[]},
    {"name":"owner/fiteo","aliases":["fiteo"],"description":"Fiteo backend","skills":[]},
    {"name":"owner/fiteo-app","aliases":["fiteo app"],"description":"Fiteo mobile app","skills":[]},
    {"name":"owner/manul","aliases":["manul","manul bot"],"description":"Manul task orchestrator","skills":[]},
    {"name":"owner/test-manul-e2e","aliases":[],"description":"Manul end-to-end test repository","skills":[]},
    {"name":"owner/test-manul-e2e","aliases":[],"description":"Manul end-to-end test repository","skills":[]},
    {"name":"owner/ambiguous-a","aliases":["shared module"],"description":"Ambiguous project A","skills":[]},
    {"name":"owner/ambiguous-b","aliases":["shared module"],"description":"Ambiguous project B","skills":[]}
  ]
}
JSON
# Load the shared resolver before testing its default path.
source "$SCRIPT_DIR/todo-task-source-utils.sh"
source "$SCRIPT_DIR/task-source.sh"
source "$SCRIPT_DIR/task-source-todo-local.sh"

# Verify a standalone installation works with no Globalskills/aicode paths.
SAVED_TODO_MCP_CLIENT="${TODO_MCP_CLIENT:-}"
SAVED_TODO_LOCAL_MCP_URL_HELPER="${TODO_LOCAL_MCP_URL_HELPER:-}"
unset TODO_MCP_CLIENT TODO_LOCAL_MCP_URL_HELPER
assert_eq "standalone Todo MCP client is bundled with Manul" "1" "$([ -r "$SCRIPT_DIR/todo-mcp-client.py" ] && echo 1 || echo 0)"
assert_eq "standalone Todo endpoint resolver is bundled with Manul" "1" "$([ -r "$SCRIPT_DIR/todo-local-mcp-url.sh" ] && echo 1 || echo 0)"
if task_source_shared_todo_client_available; then
  ok "local Todo client is available without external environment variables"
else
  fail "local Todo client should be available without Globalskills/aicode"
fi
default_local_config="$(todo_source_local_config '{"type":"todo_local_mcp"}')"
assert_contains "standalone local Todo resolver probes native loopback without external helper path" "$default_local_config" 'http://127.0.0.1:8765/mcp'

# Startup preflight must report real local MCP readiness without making the
# optional provider a fatal requirement for the Manul daemon.
cat > "$TEST_DIR/local-preflight.json" <<'JSON'
{"repositories":[],"taskSources":[{"type":"todo_local_mcp","enabled":true,"url":"http://127.0.0.1:8765/mcp"}]}
JSON
task_source_preflight "$TEST_DIR/local-preflight.json" "$TEST_DIR/local-preflight.log"
assert_contains "startup preflight records successful local Todo MCP handshake" "$(cat "$TEST_DIR/local-preflight.log")" "todo_local_mcp ready"
export TODO_LOCAL_MCP_DIRECT_STATUS=000
task_source_preflight "$TEST_DIR/local-preflight.json" "$TEST_DIR/local-preflight.log"
assert_contains "startup preflight logs an unreachable enabled local Todo source" "$(cat "$TEST_DIR/local-preflight.log")" "todo_local_mcp is enabled but unavailable"
export TODO_LOCAL_MCP_DIRECT_STATUS=200
TODO_MCP_CLIENT="$SAVED_TODO_MCP_CLIENT"
TODO_LOCAL_MCP_URL_HELPER="$SAVED_TODO_LOCAL_MCP_URL_HELPER"
export TODO_MCP_CLIENT TODO_LOCAL_MCP_URL_HELPER

# The repository catalog and mapped skill files resolve from the same fixed
# ~/.agents/skills root, independently of the calling shell's HOME.
DEFAULT_HOST_HOME="$TEST_DIR/default-host-home"
DEFAULT_HOST_CATALOG="$DEFAULT_HOST_HOME/.agents/skills/globalskills-repository/project-repositories.json"
mkdir -p "$(dirname "$DEFAULT_HOST_CATALOG")"
cp "$TEST_DIR/project-repositories.json" "$DEFAULT_HOST_CATALOG"
ALTERNATE_SKILLS_DIR="$TEST_DIR/alternate-skills"
mkdir -p "$ALTERNATE_SKILLS_DIR/globalskills-repository" "$ALTERNATE_SKILLS_DIR/fiteo-backend-api"
cp "$TEST_DIR/project-repositories.json" "$ALTERNATE_SKILLS_DIR/globalskills-repository/project-repositories.json"
printf '%s\n' "MUST_NOT_BE_LOADED" > "$ALTERNATE_SKILLS_DIR/fiteo-backend-api/SKILL.md"
DEFAULT_CATALOG_RESOLVED="$(HOME="$DEFAULT_HOST_HOME" MANUL_HOST_SKILLS_DIR="$ALTERNATE_SKILLS_DIR" TODO_TASK_REPOSITORY_CATALOG= todo_task_repository_catalog_path)"
assert_eq "repository catalog ignores obsolete alternate skills-root configuration" "$DEFAULT_HOST_CATALOG" "$DEFAULT_CATALOG_RESOLVED"
skill_context="$(HOME="$SKILLS_HOME" MANUL_HOST_SKILLS_DIR="$ALTERNATE_SKILLS_DIR" todo_task_resolved_skill_context '{"skills":["fiteo-backend-api"]}')"
assert_contains "mapped skill context is loaded from ~/.agents/skills" "$skill_context" "Fiteo API integration guidance"
assert_not_contains "mapped skill context ignores an alternate skills root" "$skill_context" "MUST_NOT_BE_LOADED"

export TODO_TASK_REPOSITORY_CATALOG="$TEST_DIR/project-repositories.json"

source "$SCRIPT_DIR/task-source-todo-remote.sh"
source "$SCRIPT_DIR/manul-env.sh"

for auth_status in 401 403; do
  export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=native
  export TODO_LOCAL_MCP_DIRECT_STATUS="$auth_status"
  export TODO_LOCAL_MCP_BRIDGE_STATUS=200
  if todo_local_mcp_resolve_url "" >/dev/null 2>&1; then
    fail "native Todo endpoint HTTP $auth_status is not an unauthenticated MCP connection"
  else
    ok "native Todo endpoint HTTP $auth_status is rejected"
  fi

  export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=wsl
  export TODO_LOCAL_MCP_DIRECT_STATUS=000
  export TODO_LOCAL_MCP_BRIDGE_STATUS="$auth_status"
  if todo_local_mcp_resolve_url "" >/dev/null 2>&1; then
    fail "WSL relay HTTP $auth_status is not an unauthenticated MCP connection"
  else
    ok "WSL relay HTTP $auth_status is rejected"
  fi
done
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=native
export TODO_LOCAL_MCP_DIRECT_STATUS=200
export TODO_LOCAL_MCP_BRIDGE_STATUS=000

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
            "description": "/manul start working on this task\nShared nested step instructions",
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

LOCAL_SOURCE='{"type":"todo_local_mcp","repositories":["owner/local","owner/link-target","owner/fiteo-app","owner/manul","owner/test-manul-e2e","mariuszmarzec/todo"],"tokenEnv":"ignored-legacy-setting"}'
REMOTE_SOURCE='{"type":"todo_remote_mcp","repositories":["owner/remote"],"tokenEnv":"FITEO_MANUL_PAT","manulUserIdEnv":"MANUL_USER_ID","url":"{env:FITEO_BASE_URL}/mcp"}'
remote_resolved_config="$(todo_source_remote_config "$REMOTE_SOURCE")"
assert_eq "remote URL expands the Fiteo base URL environment placeholder" "https://fiteo.example.test/mcp" "$(jq -r '.url' <<<"$remote_resolved_config")"
export FITEO_BASE_URL="http://fiteo.example.test"
remote_http_config="$(todo_source_remote_config "$REMOTE_SOURCE")"
assert_eq "remote Fiteo adapter accepts an HTTP endpoint" "http://fiteo.example.test/mcp" "$(jq -r '.url' <<<"$remote_http_config")"
export FITEO_BASE_URL="https://fiteo.example.test"
export FITEO_BASE_URL="ftp://fiteo.example.test"
invalid_scheme_rc=0
todo_source_remote_config "$REMOTE_SOURCE" >/dev/null 2>"$TEST_DIR/invalid-fiteo-scheme.log" || invalid_scheme_rc=$?
assert_rc "remote Fiteo adapter rejects unsupported URL schemes" "2" "$invalid_scheme_rc"
assert_contains "unsupported URL scheme diagnostic names HTTP(S)" "$(cat "$TEST_DIR/invalid-fiteo-scheme.log")" "HTTP(S)"
export FITEO_BASE_URL="https://fiteo.example.test"
assert_eq "remote Manul user ID is resolved from the configured environment variable" "77" "$(jq -r '.manulUserId' <<<"$remote_resolved_config")"
assert_eq "resolved remote Manul user ID is normalized as a JSON number" "number" "$(jq -r '.manulUserId | type' <<<"$remote_resolved_config")"

missing_user_id_rc=0
unset MANUL_USER_ID
todo_source_remote_config "$REMOTE_SOURCE" >/dev/null 2>"$TEST_DIR/missing-manul-user-id.log" || missing_user_id_rc=$?
assert_rc "remote config rejects a missing Manul user ID environment variable" "2" "$missing_user_id_rc"
assert_contains "missing Manul user ID diagnostic names the variable" "$(cat "$TEST_DIR/missing-manul-user-id.log")" "MANUL_USER_ID"
export MANUL_USER_ID=77

missing_base_url_rc=0
unset FITEO_BASE_URL
todo_source_remote_config "$REMOTE_SOURCE" >/dev/null 2>"$TEST_DIR/missing-fiteo-base-url.log" || missing_base_url_rc=$?
assert_rc "remote config rejects a missing URL environment variable" "2" "$missing_base_url_rc"
assert_contains "missing URL diagnostic names the variable" "$(cat "$TEST_DIR/missing-fiteo-base-url.log")" "FITEO_BASE_URL"
export FITEO_BASE_URL="https://fiteo.example.test"

legacy_remote_config="$(todo_source_remote_config '{"type":"todo_remote_mcp","url":"https://fiteo.example.test/mcp","manulUserId":77}')"
assert_eq "legacy numeric manulUserId remains supported" "77" "$(jq -r '.manulUserId' <<<"$legacy_remote_config")"

# Environment bootstrap must persist URL, PAT and the configured identity for
# the unattended poller, without ever copying the operator's Fiteo PAT.
ENV_RUNTIME="$TEST_DIR/env-runtime"
mkdir -p "$ENV_RUNTIME"
cat > "$ENV_RUNTIME/config.json" <<'JSON'
{"taskSources":[{"type":"todo_remote_mcp","enabled":true,"url":"{env:FITEO_BASE_URL}/mcp","tokenEnv":"FITEO_MANUL_PAT","manulUserIdEnv":"MANUL_USER_ID","shareUserIdEnv":"FITEO_MANUL_SHARE_USER_ID"}]}
JSON
manul_env_bootstrap "$ENV_RUNTIME" >/dev/null 2>"$TEST_DIR/env-bootstrap.log"
env_bootstrap_content="$(cat "$ENV_RUNTIME/.env")"
assert_contains "runtime environment persists the Fiteo base URL" "$env_bootstrap_content" "FITEO_BASE_URL=https://fiteo.example.test"
assert_contains "runtime environment persists the dedicated Manul PAT" "$env_bootstrap_content" "FITEO_MANUL_PAT=remote-test-token"
assert_contains "runtime environment persists configured Manul user ID" "$env_bootstrap_content" "MANUL_USER_ID=77"
assert_contains "runtime environment persists the task-share recipient ID" "$env_bootstrap_content" "FITEO_MANUL_SHARE_USER_ID=88"
assert_not_contains "runtime environment never persists the operator Fiteo PAT" "$env_bootstrap_content" "FITEO_PAT="
assert_eq "runtime environment file remains private" "600" "$(stat -c '%a' "$ENV_RUNTIME/.env")"

# A URL from the login shell must refresh even when its PAT is already stored
# in the runtime .env and is not exported by the current installer process.
ENV_RUNTIME_URL_ONLY="$TEST_DIR/env-runtime-url-only"
mkdir -p "$ENV_RUNTIME_URL_ONLY"
printf 'FITEO_MANUL_PAT=preexisting-manul-pat\n' > "$ENV_RUNTIME_URL_ONLY/.env"
chmod 600 "$ENV_RUNTIME_URL_ONLY/.env"
unset FITEO_MANUL_PAT
manul_env_bootstrap "$ENV_RUNTIME_URL_ONLY" >/dev/null 2>"$TEST_DIR/env-url-only-bootstrap.log"
export FITEO_MANUL_PAT="remote-test-token"
url_only_bootstrap_content="$(cat "$ENV_RUNTIME_URL_ONLY/.env")"
assert_contains "bootstrap persists Fiteo URL without requiring PAT in the current shell" "$url_only_bootstrap_content" "FITEO_BASE_URL=https://fiteo.example.test"
assert_contains "bootstrap preserves the PAT already stored in runtime environment" "$url_only_bootstrap_content" "FITEO_MANUL_PAT=preexisting-manul-pat"

echo "=== Repository routing ==="
local_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":90,"description":"/manul Update local project"}')"
assert_eq "catalog alias resolves the canonical local repository" "owner/local" "$(jq -r '.repository' <<<"$local_resolution")"
assert_eq "catalog alias records its resolution method" "catalog_alias" "$(jq -r '.method' <<<"$local_resolution")"
assert_eq "catalog alias records the matched phrase" "local project" "$(jq -r '.matchedAlias' <<<"$local_resolution")"

team_root='{"id":991,"description":"/manul team add notification center","subTasks":[],"isToDo":true}'
team_resolution='{"repository":"owner/catalog-a","executionKind":"repository","method":"explicit_repository_name"}'
team_source="$(todo_task_to_source_json "$team_root" todo_local_mcp "$team_resolution")"
assert_eq "Todo /manul team retains a dedicated action" "TEAM" "$(jq -r '.action' <<<"$team_source")"
assert_contains "Todo Team prompt retains the requested outcome" "$(jq -r '.prompt' <<<"$team_source")" "team add notification center"

remote_resolution="$(todo_task_resolve_repository "$REMOTE_SOURCE" '{"id":91,"description":"/manul Implement remote project"}')"
assert_eq "remote alias resolves the remote project" "owner/remote" "$(jq -r '.repository' <<<"$remote_resolution")"
remote_skill_prompt="$(HOME="$SKILLS_HOME" todo_task_to_source_json '{"id":91,"description":"/manul Implement remote project","subTasks":[],"isToDo":true}' todo_remote_mcp "$remote_resolution")"
assert_contains "mapped project skill is supplied in task context" "$(jq -r '.prompt' <<<"$remote_skill_prompt")" 'fiteo-docs'

linked_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":92,"description":"/manul Fix this: https://github.com/owner/link-target/issues/42"}')"
assert_eq "explicit GitHub URL has precedence and resolves its repository" "owner/link-target" "$(jq -r '.repository' <<<"$linked_resolution")"
assert_eq "explicit URL is identified as the routing source" "explicit_github_url" "$(jq -r '.method' <<<"$linked_resolution")"

specific_source='{"repositories":["owner/fiteo","owner/fiteo-app"]}'
specific_resolution="$(todo_task_resolve_repository "$specific_source" '{"id":93,"description":"/manul Update the Fiteo App"}')"
assert_eq "longest matching alias distinguishes Fiteo App from Fiteo backend" "owner/fiteo-app" "$(jq -r '.repository' <<<"$specific_resolution")"

e2e_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":96,"description":"/manul zrob w test-manul-e2e repo PR z helloworld w elixir"}')"
assert_eq "hyphenated repository slug wins over embedded Manul alias" "owner/test-manul-e2e" "$(jq -r '.repository' <<<"$e2e_resolution")"
assert_eq "repository slug is available as an implicit matched alias" "test-manul-e2e" "$(jq -r '.matchedAlias' <<<"$e2e_resolution")"

# Configured repository names are routable without a project-catalog entry,
# including the concise "repo <slug>" form and references in nested subtasks.
short_repo_task='{"id":101,"description":"/manul Implement the requested change","subTasks":[{"id":102,"description":"Implementation details","subTasks":[{"id":103,"description":"repo todo."}]}]}'
short_repo_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" "$short_repo_task")"
assert_eq "configured short repository name resolves from a grandchild description" "mariuszmarzec/todo" "$(jq -r '.repository' <<<"$short_repo_resolution")"
assert_eq "configured short repository name records its routing method" "configured_repository_slug" "$(jq -r '.method' <<<"$short_repo_resolution")"
assert_eq "configured short repository name records its slug" "todo" "$(jq -r '.matchedAlias' <<<"$short_repo_resolution")"

full_repo_task='{"id":102,"description":"/manul Implement a change","subTasks":[{"id":104,"description":"Target repository: owner/local"}]}'
full_repo_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" "$full_repo_task")"
assert_eq "explicit owner/repo notation in a subtask resolves from the allowlist" "owner/local" "$(jq -r '.repository' <<<"$full_repo_resolution")"
assert_eq "explicit owner/repo notation has dedicated provenance" "explicit_repository_name" "$(jq -r '.method' <<<"$full_repo_resolution")"

nested_alias_task='{"id":103,"description":"/manul Implement a change","subTasks":[{"id":105,"description":"Use the local project for this change"}]}'
nested_alias_resolution="$(todo_task_resolve_repository "$LOCAL_SOURCE" "$nested_alias_task")"
assert_eq "catalog aliases are also resolved from nested subtask descriptions" "owner/local" "$(jq -r '.repository' <<<"$nested_alias_resolution")"

resolution_rc=0
ambiguous_short_source='{"repositories":["org-one/todo","org-two/todo"]}'
todo_task_resolve_repository "$ambiguous_short_source" '{"id":104,"description":"/manul Implement this in repo todo"}' 2>"$TEST_DIR/ambiguous-short-name.log" >/dev/null || resolution_rc=$?
assert_rc "duplicate configured repository slugs are rejected instead of guessed" "1" "$resolution_rc"
assert_contains "ambiguous short repository name lists the candidates" "$(cat "$TEST_DIR/ambiguous-short-name.log")" "org-one/todo, org-two/todo"

slug_boundary_source='{"repositories":["org/todo","org/todo-app"]}'
slug_boundary_resolution="$(todo_task_resolve_repository "$slug_boundary_source" '{"id":108,"description":"/manul Implement this in repo todo-app"}')"
assert_eq "short repository matching requires a whole slug and does not match a shorter prefix" "org/todo-app" "$(jq -r '.repository' <<<"$slug_boundary_resolution")"

resolution_rc=0
conflicting_tree='{"id":105,"description":"/manul Implement the change in repo todo","subTasks":[{"id":106,"description":"Another target: owner/local"}]}'
todo_task_resolve_repository "$LOCAL_SOURCE" "$conflicting_tree" 2>"$TEST_DIR/conflicting-tree.log" >/dev/null || resolution_rc=$?
assert_rc "conflicting repository references across a task tree fail closed" "1" "$resolution_rc"
assert_contains "conflicting repository references explain the ambiguity" "$(cat "$TEST_DIR/conflicting-tree.log")" "multiple configured repositories"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":94,"description":"/manul Update the shared module"}' 2>"$TEST_DIR/ambiguous.log" >/dev/null || resolution_rc=$?
assert_rc "duplicate alias is rejected instead of guessing" "1" "$resolution_rc"
assert_contains "ambiguous routing explains the candidate projects" "$(cat "$TEST_DIR/ambiguous.log")" "routing is ambiguous"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":95,"description":"/manul Update remote project"}' 2>"$TEST_DIR/global-repositories.log" >/dev/null || resolution_rc=$?
assert_rc "global repository list rejects an otherwise known project" "1" "$resolution_rc"
assert_contains "global repository rejection identifies the denied repository" "$(cat "$TEST_DIR/global-repositories.log")" "owner/remote"

empty_source='{"repositories":[]}'
resolution_rc=0
todo_task_resolve_repository "$empty_source" '{"id":98,"description":"/manul Update local project"}' 2>"$TEST_DIR/empty-global-repositories.log" >/dev/null || resolution_rc=$?
assert_rc "an empty global repositories list denies all catalog targets" "1" "$resolution_rc"
assert_contains "empty global repository rejection is explicit" "$(cat "$TEST_DIR/empty-global-repositories.log")" "excluded by the global .repositories list"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":96,"description":"/manul Fetch weather for Krakow"}' 2>"$TEST_DIR/unmatched.log" >/dev/null || resolution_rc=$?
assert_rc "task without a project reference remains unresolved and cannot be queued" "3" "$resolution_rc"
assert_contains "unmatched task explains why routing was not selected" "$(cat "$TEST_DIR/unmatched.log")" "no project alias matched"

# An explicit GitHub URL does not require a catalog entry, but the
# top-level .repositories list remains the access allowlist.
MISSING_CATALOG_HOME="$TEST_DIR/no-catalog-home"
mkdir -p "$MISSING_CATALOG_HOME"
SAVED_TODO_TASK_REPOSITORY_CATALOG="$TODO_TASK_REPOSITORY_CATALOG"
unset TODO_TASK_REPOSITORY_CATALOG
explicit_no_catalog_source='{"repositories":["owner/unlisted-but-allowed"]}'
explicit_no_catalog="$(HOME="$MISSING_CATALOG_HOME" todo_task_resolve_repository "$explicit_no_catalog_source" '{"id":97,"description":"/manul Work on https://github.com/owner/unlisted-but-allowed"}' 2>"$TEST_DIR/no-catalog-explicit.log")"
assert_eq "explicit allowlisted GitHub URL works without the project catalog" "owner/unlisted-but-allowed" "$(jq -r '.repository' <<<"$explicit_no_catalog")"
assert_eq "explicit no-catalog routing keeps its provenance" "explicit_github_url" "$(jq -r '.method' <<<"$explicit_no_catalog")"

short_no_catalog_source='{"repositories":["mariuszmarzec/todo"]}'
short_no_catalog="$(HOME="$MISSING_CATALOG_HOME" todo_task_resolve_repository "$short_no_catalog_source" '{"id":107,"description":"/manul Implement the fix in repo todo"}' 2>"$TEST_DIR/no-catalog-short.log")"
assert_eq "configured repo slug works without project-repositories.json" "mariuszmarzec/todo" "$(jq -r '.repository' <<<"$short_no_catalog")"
assert_eq "configured repo slug without catalog keeps its provenance" "configured_repository_slug" "$(jq -r '.method' <<<"$short_no_catalog")"

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":98,"description":"/manul Work on https://github.com/other-owner/private-repo"}' 2>"$TEST_DIR/not-allowlisted.log" >/dev/null || resolution_rc=$?
assert_rc "explicit repository outside the global list is rejected" "1" "$resolution_rc"
assert_contains "global allowlist rejection is reported without requiring catalog membership" "$(cat "$TEST_DIR/not-allowlisted.log")" "excluded by the global .repositories list"

resolution_rc=0
HOME="$MISSING_CATALOG_HOME" todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":99,"description":"/manul answer a general question"}' 2>"$TEST_DIR/no-catalog-alias.log" >/dev/null || resolution_rc=$?
assert_rc "missing catalog disables alias routing and leaves the repository unresolved" "3" "$resolution_rc"
assert_contains "missing catalog explains that only alias routing is disabled" "$(cat "$TEST_DIR/no-catalog-alias.log")" "alias routing is disabled"
export TODO_TASK_REPOSITORY_CATALOG="$SAVED_TODO_TASK_REPOSITORY_CATALOG"

echo "=== Local Todo source ==="
export TODO_MCP_FIXTURE="$TEST_DIR/local.json"
local_tasks="$(task_source_todo_local_poll "$LOCAL_SOURCE")"
assert_eq "only local /manul root is enqueued" "1" "$(printf '%s\n' "$local_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
local_task="$(printf '%s\n' "$local_tasks" | jq -c '.')"
assert_contains "local root source type is normalized" "$local_task" '"taskSourceType":"todo_local_mcp"'
assert_eq "local Todo adapter assigns repository from description, not a static default" "owner/local" "$(jq -r '.metadata.repository' <<<"$local_task")"
assert_eq "local source persists repository-resolution provenance" "catalog_alias" "$(jq -r '.metadata.repositoryResolution.method' <<<"$local_task")"

# Plain informational questions without a repository are answered directly.
cat > "$TEST_DIR/local-question.json" <<'JSON'
[
  {"id":490,"description":"/manul Jaki dzisiaj dzień tygodnia?","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
LOCAL_QUESTION_SOURCE="$(todo_source_local_config "$LOCAL_SOURCE")"
export TODO_MCP_FIXTURE="$TEST_DIR/local-question.json"
local_question_tasks="$(task_source_todo_local_poll "$LOCAL_QUESTION_SOURCE")"
assert_eq "local informational question is queued without a repository" "1" "$(printf '%s\n' "$local_question_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "local informational question uses the dedicated ANSWER action" "ANSWER" "$(jq -r '.action' <<<"$local_question_tasks")"
assert_eq "local informational question uses the tool-free answer execution kind" "answer" "$(jq -r '.execution.kind' <<<"$local_question_tasks")"
assert_eq "local informational question has no repository metadata" "true" "$(jq -e '.metadata.repository == null' <<<"$local_question_tasks" >/dev/null && echo true || echo false)"
assert_contains "local informational answer prompt explains that no repository is needed" "$(jq -r '.prompt' <<<"$local_question_tasks")" "No repository is assigned or needed"
assert_contains "local informational answer prompt includes the current Poland date" "$(jq -r '.prompt' <<<"$local_question_tasks")" "Europe/Warsaw"
assert_eq "local informational question does not create a repository blocker" "0" "$(jq '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"

# The answer is saved as a digest-bound child and preserves the original source id.
local_question_root="$(jq -c '.[0]' "$TODO_MCP_FIXTURE")"
local_question_source_id="$(jq -r '.taskSourceId' <<<"$local_question_tasks")"
local_answer_text="Dzisiaj jest wtorek."
local_answer_receipt="$(todo_task_publish_update "$LOCAL_QUESTION_SOURCE" todo_local_mcp "$local_question_source_id" answered "$local_answer_text")"
assert_eq "local answer is saved under the original root" "490" "$(jq -r '.[0].subTasks[0].parentTaskId' "$TODO_MCP_FIXTURE")"
assert_contains "local answer child contains the actual answer" "$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")" "$local_answer_text"
assert_contains "local answer child is marked as an answered result" "$(tail -n 1 <<<"$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")")" "status=answered"
assert_eq "local answer child remains pending until whole-tree completion" "true" "$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "local answer child does not change the queued source identity" "0" "$(todo_task_still_current "$LOCAL_QUESTION_SOURCE" todo_local_mcp "$local_question_source_id"; echo $?)"
: > "$TODO_MCP_CALL_LOG"
local_answer_retry="$(todo_task_publish_update "$LOCAL_QUESTION_SOURCE" todo_local_mcp "$local_question_source_id" answered "Retry must reuse the existing answer.")"
assert_eq "local answer retry reuses its child id" "$(jq -r '.updateTaskId' <<<"$local_answer_receipt")" "$(jq -r '.updateTaskId' <<<"$local_answer_retry")"
assert_eq "local answer retry does not create a duplicate child" "0" "$(grep -c '^create_task' "$TODO_MCP_CALL_LOG" || true)"
# Simulate a remote-style partial completion: the answer child is done but
# the root remains open because a later root update has not yet succeeded.
jq '.[0].subTasks[0].isToDo = false' "$TODO_MCP_FIXTURE" > "$TEST_DIR/local-answer-partial.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-answer-partial.json"
local_answer_partial_retry="$(todo_task_publish_update "$LOCAL_QUESTION_SOURCE" todo_local_mcp "$local_question_source_id" answered "Retry after a partial tree completion.")"
assert_eq "partial answer completion reuses the existing child" "$(jq -r '.updateTaskId' <<<"$local_answer_receipt")" "$(jq -r '.updateTaskId' <<<"$local_answer_partial_retry")"
assert_eq "partial answer completion does not create a duplicate" "0" "$(grep -c '^create_task' "$TODO_MCP_CALL_LOG" || true)"
assert_eq "root remains open until whole-tree completion resumes" "true" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"
todo_task_mark_done "$LOCAL_QUESTION_SOURCE" todo_local_mcp "$local_question_source_id"
assert_eq "local answer child is completed with the task tree" "false" "$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "local root is completed only after the answer child" "false" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"


# An implementation request with no repository remains a visible routing blocker.
cat > "$TEST_DIR/local-implementation-no-repository.json" <<'JSON'
[
  {"id":496,"description":"/manul Implement the requested feature","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/local-implementation-no-repository.json"
local_implementation_tasks="$(task_source_todo_local_poll "$LOCAL_QUESTION_SOURCE")"
assert_eq "local implementation without a repository is not queued as an answer" "0" "$(printf '%s\n' "$local_implementation_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "local implementation without a repository creates an open blocker" "1" "$(jq '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"
assert_contains "local implementation blocker asks for owner/repo" "$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")" "owner/repo"
assert_eq "implementation blocker remains open" "true" "$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"

# Local Todo must still detect a nested trigger, but an unresolved root
# repository creates an OPEN blocker under the parent instead of queueing work.
cat > "$TEST_DIR/local-nested-trigger.json" <<'JSON'
[
  {
    "id": 491,
    "description": "Parent task without a trigger",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 492,
        "description": "/manul Implement the nested step",
        "addedTime": "2026-10-01T10:01:00",
        "modifiedTime": "2026-10-01T10:01:00",
        "parentTaskId": 491,
        "subTasks": [],
        "isToDo": true,
        "priority": 1,
        "scheduler": null,
        "shares": []
      }
    ],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": []
  }
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/local-nested-trigger.json"
nested_trigger_tasks="$(task_source_todo_local_poll "$LOCAL_QUESTION_SOURCE")"
assert_eq "local nested /manul trigger is not queued without a repository" "0" "$(printf '%s\n' "$nested_trigger_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "local nested trigger creates one routing blocker under the parent root" "2" "$(jq '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"
assert_contains "nested trigger blocker explains the missing repository" "$(jq -r '.[0].subTasks[1].description' "$TODO_MCP_FIXTURE")" "owner/repo"
assert_eq "nested trigger blocker is saved without queueing an agent prompt" "" "$nested_trigger_tasks"

# The root trigger and the target repository may live in different nodes:
# Todo routing must inspect the same complete tree that was queued.
cat > "$TEST_DIR/local-configured-repository-in-subtask.json" <<'JSON'
[
  {
    "id": 493,
    "description": "/manul Implement the requested feature",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 494,
        "description": "Implementation target: repo todo",
        "addedTime": "2026-10-01T10:01:00",
        "modifiedTime": "2026-10-01T10:01:00",
        "parentTaskId": 493,
        "subTasks": [],
        "isToDo": true,
        "priority": 1,
        "scheduler": null,
        "shares": []
      }
    ],
    "isToDo": true,
    "priority": 1,
    "scheduler": null,
    "shares": []
  }
]
JSON
LOCAL_SHORT_SOURCE='{"type":"todo_local_mcp","repositories":["mariuszmarzec/todo"]}'
export TODO_MCP_FIXTURE="$TEST_DIR/local-configured-repository-in-subtask.json"
local_short_task="$(task_source_todo_local_poll "$LOCAL_SHORT_SOURCE")"
assert_eq "local adapter routes a root implementation trigger to a repo named only in its subtask" "mariuszmarzec/todo" "$(jq -r '.metadata.repository' <<<"$local_short_task")"
assert_eq "local adapter does not downgrade a configured repo-slug task to report-only" "repository" "$(jq -r '.execution.kind' <<<"$local_short_task")"

export TODO_MCP_FIXTURE="$TEST_DIR/local.json"
assert_contains "local Todo uses the default loopback URL" "$(todo_source_local_config "$LOCAL_SOURCE")" 'http://127.0.0.1:8765/mcp'

# WSL prefers direct loopback but falls back to its reverse bridge when
# Todo Desktop runs on the Windows host and direct loopback is unavailable.
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=wsl
export TODO_LOCAL_MCP_DIRECT_STATUS=000
export TODO_LOCAL_MCP_BRIDGE_STATUS=200
wsl_local_config="$(todo_source_local_config "$LOCAL_SOURCE")"
assert_contains "WSL falls back to the existing Todo bridge when direct loopback is unavailable" "$wsl_local_config" 'http://127.0.0.1:8766/mcp'
export TODO_LOCAL_MCP_PLATFORM_OVERRIDE=native
export TODO_LOCAL_MCP_DIRECT_STATUS=200
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
export FITEO_MANUL_SHARE_USER_ID=88
export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"
remote_tasks="$(task_source_todo_remote_poll "$REMOTE_SOURCE")"
assert_eq "only explicitly editor-shared remote root is enqueued" "1" "$(printf '%s\n' "$remote_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
remote_task="$(printf '%s\n' "$remote_tasks" | jq -c '.')"
assert_contains "remote root source type is normalized" "$remote_task" '"taskSourceType":"todo_remote_mcp"'
assert_eq "remote Fiteo adapter assigns repository from shared task description" "owner/remote" "$(jq -r '.metadata.repository' <<<"$remote_task")"
assert_eq "remote source persists alias provenance" "remote project" "$(jq -r '.metadata.repositoryResolution.matchedAlias' <<<"$remote_task")"

# Shared remote Todo information requests without a repository use direct answers.
cat > "$TEST_DIR/remote-question.json" <<'JSON'
[
  {"id":590,"ownerId":4,"description":"/manul Jaki dzisiaj dzień tygodnia?","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]},
  {"id":591,"ownerId":4,"description":"/manul daj znać czy żyjesz","addedTime":"2026-10-01T10:01:00","modifiedTime":"2026-10-01T10:01:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
REMOTE_QUESTION_SOURCE='{"type":"todo_remote_mcp","repositories":["owner/remote"],"manulUserIdEnv":"MANUL_USER_ID","url":"{env:FITEO_BASE_URL}/mcp","tokenEnv":"FITEO_MANUL_PAT","shareUserIdEnv":"FITEO_MANUL_SHARE_USER_ID"}'

# Exercise the production default: the catalog is read from the canonical
# agent skills tree, not bundled alongside the standalone Manul checkout.
HOST_REPOSITORY_CATALOG="$SKILLS_DIR/globalskills-repository/project-repositories.json"
mkdir -p "$(dirname "$HOST_REPOSITORY_CATALOG")"
cp "$TODO_TASK_REPOSITORY_CATALOG" "$HOST_REPOSITORY_CATALOG"
SAVED_TODO_TASK_REPOSITORY_CATALOG="$TODO_TASK_REPOSITORY_CATALOG"
unset TODO_TASK_REPOSITORY_CATALOG
assert_eq "default Todo repository catalog resolves from ~/.agents/skills" "$HOST_REPOSITORY_CATALOG" "$(HOME="$SKILLS_HOME" todo_task_repository_catalog_path)"

export TODO_MCP_FIXTURE="$TEST_DIR/remote-question.json"
remote_question_tasks="$(HOME="$SKILLS_HOME" task_source_todo_remote_poll "$REMOTE_QUESTION_SOURCE")"
assert_eq "remote informational questions are queued without a repository" "2" "$(printf '%s\n' "$remote_question_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "remote informational questions use ANSWER actions" "[\"ANSWER\",\"ANSWER\"]" "$(jq -c 'map(.action)' <<<"$(printf '%s\n' "$remote_question_tasks" | jq -s '.')")"
assert_eq "remote informational questions use answer execution" "[\"answer\",\"answer\"]" "$(jq -c '[.[].execution.kind]' <<<"$(printf '%s\n' "$remote_question_tasks" | jq -s '.')")"
assert_eq "remote informational questions do not create repository blockers" "[0,0]" "$(jq -c '[.[].subTasks | length]' "$TODO_MCP_FIXTURE")"

# A remote implementation request without a repository still asks for owner/repo.
cat > "$TEST_DIR/remote-implementation-no-repository.json" <<'JSON'
[
  {"id":592,"ownerId":4,"description":"/manul Implement the requested backend change","addedTime":"2026-10-01T10:02:00","modifiedTime":"2026-10-01T10:02:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/remote-implementation-no-repository.json"
remote_implementation_tasks="$(HOME="$SKILLS_HOME" task_source_todo_remote_poll "$REMOTE_QUESTION_SOURCE")"
assert_eq "remote implementation without repository is not queued as an answer" "0" "$(printf '%s\n' "$remote_implementation_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "remote implementation without repository creates a blocker" "1" "$(jq '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"
assert_contains "remote implementation blocker asks for owner/repo" "$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")" "owner/repo"
assert_eq "remote implementation blocker remains OPEN" "true" "$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"
export TODO_TASK_REPOSITORY_CATALOG="$SAVED_TODO_TASK_REPOSITORY_CATALOG"
export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"
assert_contains "a nested /manul command activates the parent task" "$remote_tasks" '"taskSourceId":"21@'
remote_prompt="$(jq -r '.prompt' <<<"$remote_task")"
assert_contains "nested trigger instruction is retained in the parent prompt" "$remote_prompt" 'start working on this task'
assert_contains "nested subtask context is retained in the parent prompt" "$remote_prompt" 'Shared nested step instructions'
assert_not_contains "remote prompt strips the executable /manul marker" "$remote_prompt" '/manul'
assert_not_contains "viewer-only task is excluded" "$remote_tasks" '"taskSourceId":"24@'
assert_not_contains "unshared task is excluded" "$remote_tasks" '"taskSourceId":"25@'
remote_id="$(jq -r '.taskSourceId' <<<"$remote_task")"
assert_eq "remote revalidation accepts unchanged tree" "0" "$(
  task_source_todo_remote_revalidate "$REMOTE_SOURCE" "$remote_id"; echo $?
)"

# A shared remote task without a trigger is visible to the source but must not
# enter the execution queue.
jq '.[0].subTasks[0].subTasks[0].description = "Shared nested step without trigger"' \
  "$TEST_DIR/remote.json" > "$TEST_DIR/remote-no-trigger.json"
export TODO_MCP_FIXTURE="$TEST_DIR/remote-no-trigger.json"
remote_untriggered_tasks="$(task_source_todo_remote_poll "$REMOTE_SOURCE")"
assert_eq "shared remote root without any /manul command is not queued" "0" "$(printf '%s\n' "$remote_untriggered_tasks" | sed '/^$/d' | wc -l | tr -d ' ')"
export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"

# Removing the descendant trigger after queueing invalidates remote revalidation.
jq '.[0].subTasks[0].subTasks[0].description = "Shared nested step without trigger"' \
  "$TEST_DIR/remote.json" > "$TEST_DIR/remote-trigger-removed.json"
export TODO_MCP_FIXTURE="$TEST_DIR/remote-trigger-removed.json"
remote_trigger_removed_rc=0
task_source_todo_remote_revalidate "$REMOTE_SOURCE" "$remote_id" || remote_trigger_removed_rc=$?
assert_rc "remote revalidation rejects a removed nested trigger" "1" "$remote_trigger_removed_rc"

export TODO_MCP_FIXTURE="$TEST_DIR/remote.json"

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

echo "=== Todo status updates ==="
cat > "$TEST_DIR/local-update.json" <<'JSON'
[
  {"id":501,"description":"/manul Implement the local feature","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/local-update.json"
LOCAL_UPDATE_SOURCE="$(todo_source_local_config "$LOCAL_SOURCE")"
local_update_root="$(jq -c '.[0]' "$TODO_MCP_FIXTURE")"
local_update_id="501@$(todo_task_fingerprint "$local_update_root")"
local_update_summary=$'Sprawdziłem opis oraz wszystkie podzadania i nie znalazłem wskazania repozytorium. Potrzebuję dokładnego owner/repo, aby bezpiecznie wybrać checkout.'
local_update_receipt="$(todo_task_publish_update "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id" needs_input "$local_update_summary")"
local_update_task_id="$(jq -r '.updateTaskId' <<<"$local_update_receipt")"
assert_eq "local status update is linked to its root" "501" "$(jq -r '.[0].subTasks[0].parentTaskId' "$TODO_MCP_FIXTURE")"
assert_contains "local status update includes the investigation summary" "$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")" "nie znalazłem wskazania repozytorium"
assert_contains "local status update records its integrity marker" "$(tail -n 1 <<<"$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")")" "MANUL_TASK_UPDATE:v1"
assert_eq "local status update remains OPEN" "true" "$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "local status update leaves root OPEN" "true" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "local status update preserves source fingerprint" "0" "$(todo_task_still_current "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id"; echo $?)"
: > "$TODO_MCP_CALL_LOG"
local_update_retry="$(todo_task_publish_update "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id" needs_input "Retry must reuse the existing child.")"
assert_eq "local status update retry reuses its child id" "$local_update_task_id" "$(jq -r '.updateTaskId' <<<"$local_update_retry")"
assert_eq "local status update retry does not create another task" "0" "$(grep -c '^create_task' "$TODO_MCP_CALL_LOG" || true)"
local_second_receipt="$(todo_task_publish_update "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id" failed "A second status update must remain part of the same source version.")"
local_second_task_id="$(jq -r '.updateTaskId' <<<"$local_second_receipt")"
assert_eq "a second status update is attached as a separate child" "2" "$(jq '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"
assert_eq "multiple generated status children preserve the original source version" "0" "$(todo_task_still_current "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id"; echo $?)"
: > "$TODO_MCP_CALL_LOG"
local_update_retry_again="$(todo_task_publish_update "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id" failed "A retry must reuse both generated statuses.")"
assert_eq "second status update retry reuses its child id" "$local_second_task_id" "$(jq -r '.updateTaskId' <<<"$local_update_retry_again")"
assert_eq "second status update retry does not create a duplicate" "0" "$(grep -c '^create_task' "$TODO_MCP_CALL_LOG" || true)"
jq '.[0].subTasks[0].description |= sub("owner/repo"; "owner/local")' "$TODO_MCP_FIXTURE" > "$TEST_DIR/local-update-edited.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-update-edited.json"
assert_eq "editing a generated status subtask invalidates its old source marker" "1" "$(todo_task_still_current "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$local_update_id"; echo $?)"

# A terminal remote failure is also a verified OPEN child, not a suppressed
# external-source comment. The parent share remains inherited; no child share
# payload is added.
cat > "$TEST_DIR/remote-update.json" <<'JSON'
[
  {"id":601,"ownerId":4,"description":"/manul Implement the remote service change","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/remote-update.json"
REMOTE_UPDATE_SOURCE="$(todo_source_remote_config "$REMOTE_SOURCE")"
remote_update_root="$(jq -c '.[0]' "$TODO_MCP_FIXTURE")"
remote_update_id="601@$(todo_task_fingerprint "$remote_update_root")"
remote_update_receipt="$(todo_task_publish_update "$REMOTE_UPDATE_SOURCE" todo_remote_mcp "$remote_update_id" failed $'Stage: task execution\n\nAgent failed while validating the implementation.')"
remote_update_task_id="$(jq -r '.updateTaskId' <<<"$remote_update_receipt")"
remote_update_description="$(jq -r '.[0].subTasks[0].description' "$TODO_MCP_FIXTURE")"
assert_eq "remote failure update belongs to the source root" "601" "$(jq -r '.[0].subTasks[0].parentTaskId' "$TODO_MCP_FIXTURE")"
assert_contains "remote failure update includes the reason" "$remote_update_description" "Agent failed while validating"
assert_contains "remote failure update has a verifiable marker" "$(tail -n 1 <<<"$remote_update_description")" "status=failed"
assert_eq "remote failure update remains OPEN" "true" "$(jq -r '.[0].subTasks[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "remote root stays OPEN after failure feedback" "true" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "remote failure update preserves source identity" "0" "$(todo_task_still_current "$REMOTE_UPDATE_SOURCE" todo_remote_mcp "$remote_update_id"; echo $?)"
remote_create_arguments="$(awk -F '\t' '$1 == "todo_create_task" {print $2; exit}' "$TODO_MCP_CALL_LOG")"
assert_eq "remote update creation does not duplicate inherited parent shares" "false" "$(jq -r '.task | has("shares")' <<<"$remote_create_arguments")"
: > "$TODO_MCP_CALL_LOG"
remote_update_retry="$(todo_task_publish_update "$REMOTE_UPDATE_SOURCE" todo_remote_mcp "$remote_update_id" failed "A retry must reuse the verified child.")"
assert_eq "remote failure update retry reuses its child" "$remote_update_task_id" "$(jq -r '.updateTaskId' <<<"$remote_update_retry")"
assert_eq "remote failure update does not create a duplicate" "0" "$(grep -c '^todo_create_task' "$TODO_MCP_CALL_LOG" || true)"

cat > "$TEST_DIR/local-update-create-failure.json" <<'JSON'
[
  {"id":502,"description":"/manul Implement local failure feedback","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/local-update-create-failure.json"
failure_root="$(jq -c '.[0]' "$TODO_MCP_FIXTURE")"
failure_source_id="502@$(todo_task_fingerprint "$failure_root")"
export TODO_MCP_FAIL_CREATE=1
local_update_failure_rc=0
todo_task_publish_update "$LOCAL_UPDATE_SOURCE" todo_local_mcp "$failure_source_id" failed "Injected MCP create failure." >/dev/null 2>&1 || local_update_failure_rc=$?
unset TODO_MCP_FAIL_CREATE
assert_rc "local feedback creation failure is surfaced" "2" "$local_update_failure_rc"
assert_eq "local feedback creation failure leaves root open" "true" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "local feedback creation failure writes no fake child" "0" "$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"

cat > "$TEST_DIR/remote-update-unreadable.json" <<'JSON'
[
  {"id":602,"ownerId":4,"description":"/manul Implement remote failure feedback","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/remote-update-unreadable.json"
unreadable_root="$(jq -c '.[0]' "$TODO_MCP_FIXTURE")"
unreadable_source_id="602@$(todo_task_fingerprint "$unreadable_root")"
export TODO_MCP_DROP_CHILD=1
remote_update_unreadable_rc=0
todo_task_publish_update "$REMOTE_UPDATE_SOURCE" todo_remote_mcp "$unreadable_source_id" failed "This update must be readable." >/dev/null 2>&1 || remote_update_unreadable_rc=$?
unset TODO_MCP_DROP_CHILD
assert_rc "remote feedback is rejected when the created child is absent from read-back" "1" "$remote_update_unreadable_rc"
assert_eq "unreadable failure feedback does not complete the remote root" "true" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "unreadable failure feedback is not reported as a verified child" "0" "$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"

# Markdown remains compatible with the Todo UI renderer for multiline feedback.
formatted_markdown="$(todo_task_markdown_format <<'MARKDOWN'
## Summary
First line
Second line

- one
- two

```kotlin
val value = 1
```
MARKDOWN
)"
assert_contains "ordinary line breaks become hard Markdown breaks" "$formatted_markdown" $'First line  \nSecond line'
assert_contains "Markdown list structure remains intact" "$formatted_markdown" $'- one  \n- two'
assert_contains "fenced code block content is preserved" "$formatted_markdown" '```kotlin'
assert_eq "single-line update text has no redundant trailing hard break" "Single-line status update." "$(printf '%s' 'Single-line status update.' | todo_task_markdown_format)"

# ANSWER is a distinct no-repository task kind mapped to the audited operator-query runtime.
agent_executor_source="$(cat "$SCRIPT_DIR/agent-executor.sh")"
poll_source="$(cat "$SCRIPT_DIR/poll.sh")"
assert_contains "agent executor maps ANSWER to tool-free operator_query" "$agent_executor_source" 'adapter_execution_kind="operator_query"'
assert_contains "source poller accepts the explicit ANSWER action" "$poll_source" 'IMPLEMENT|REVIEW_FIX|VERIFY|ANSWER|TEAM)'
assert_contains "source poller accepts answer execution only for Todo and without a repository" "$poll_source" 'execution_kind" = "answer"'

# Normal standalone operation must not need aicode to export helper paths.
source "$SCRIPT_DIR/task-source.sh"
SAVED_TODO_MCP_CLIENT="${TODO_MCP_CLIENT:-}"
SAVED_TODO_LOCAL_MCP_URL_HELPER="${TODO_LOCAL_MCP_URL_HELPER:-}"
unset TODO_MCP_CLIENT TODO_LOCAL_MCP_URL_HELPER
assert_eq "standalone poller resolves its bundled Todo MCP client by default" "$SCRIPT_DIR/todo-mcp-client.py" "$(task_source_todo_client_path)"
assert_eq "standalone poller resolves its bundled endpoint resolver by default" "$SCRIPT_DIR/todo-local-mcp-url.sh" "$(task_source_todo_local_helper_path)"
if task_source_shared_todo_client_available; then
  ok "standalone poller finds the bundled MCP client without aicode"
else
  fail "standalone poller must find the bundled MCP client without aicode"
fi
if task_source_local_helper_available; then
  ok "standalone poller finds the bundled endpoint resolver without aicode"
else
  fail "standalone poller must find the bundled endpoint resolver without aicode"
fi
TODO_MCP_CLIENT="$SAVED_TODO_MCP_CLIENT"
TODO_LOCAL_MCP_URL_HELPER="$SAVED_TODO_LOCAL_MCP_URL_HELPER"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
