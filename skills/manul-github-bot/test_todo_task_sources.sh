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

LOCAL_SOURCE='{"type":"todo_local_mcp","repositories":["owner/local","owner/link-target","owner/fiteo-app"],"tokenEnv":"ignored-legacy-setting"}'
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
assert_rc "task without a project reference signals report-only fallback" "3" "$resolution_rc"
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

resolution_rc=0
todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":98,"description":"/manul Work on https://github.com/other-owner/private-repo"}' 2>"$TEST_DIR/not-allowlisted.log" >/dev/null || resolution_rc=$?
assert_rc "explicit repository outside the global list is rejected" "1" "$resolution_rc"
assert_contains "global allowlist rejection is reported without requiring catalog membership" "$(cat "$TEST_DIR/not-allowlisted.log")" "excluded by the global .repositories list"

resolution_rc=0
HOME="$MISSING_CATALOG_HOME" todo_task_resolve_repository "$LOCAL_SOURCE" '{"id":99,"description":"/manul answer a general question"}' 2>"$TEST_DIR/no-catalog-alias.log" >/dev/null || resolution_rc=$?
assert_rc "missing catalog disables alias routing without blocking report-only tasks" "3" "$resolution_rc"
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

# An ordinary /manul information request with no project alias is automatically
# report-only even when the legacy allowReportOnly setting is false.
cat > "$TEST_DIR/local-question.json" <<'JSON'
[
  {"id":490,"description":"/manul what day is today?","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
LOCAL_QUESTION_SOURCE='{"type":"todo_local_mcp","allowReportOnly":false,"repositories":[]}'

export TODO_MCP_FIXTURE="$TEST_DIR/local-question.json"
local_question_task="$(task_source_todo_local_poll "$LOCAL_QUESTION_SOURCE")"
assert_eq "plain local /manul question is auto-classified as report-only without report keyword" "report_only" "$(jq -r '.execution.kind' <<<"$local_question_task")"
assert_contains "plain local /manul question keeps its prompt" "$(jq -r '.prompt' <<<"$local_question_task")" "what day is today?"
assert_eq "plain local /manul question does not require repository metadata" "null" "$(jq -r '.metadata.repository // null' <<<"$local_question_task")"

# Local Todo must match the same root-trigger semantics as remote Todo: a
# /manul command in any descendant queues the parent tree exactly once.
cat > "$TEST_DIR/local-nested-trigger.json" <<'JSON'
[
  {
    "id": 491,
    "description": "Parent task without a local trigger",
    "addedTime": "2026-10-01T10:00:00",
    "modifiedTime": "2026-10-01T10:00:00",
    "parentTaskId": null,
    "subTasks": [
      {
        "id": 492,
        "description": "/manul answer a nested question",
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
nested_trigger_task="$(task_source_todo_local_poll "$LOCAL_QUESTION_SOURCE")"
assert_eq "local nested /manul trigger queues the parent root once" "491" "$(jq -r '.taskSourceId | split("@")[0]' <<<"$nested_trigger_task")"
assert_eq "local nested trigger uses report-only when the parent has no repository route" "report_only" "$(jq -r '.execution.kind' <<<"$nested_trigger_task")"
assert_contains "nested /manul command is removed from the ordered step text" "$(jq -r '.prompt' <<<"$nested_trigger_task")" "answer a nested question"
assert_not_contains "nested /manul command itself is not forwarded as prompt content" "$(jq -r '.prompt' <<<"$nested_trigger_task")" "/manul"

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

# A plain /manul information request is report-only by default; no explicit
# report keyword or allowReportOnly opt-in is required.
cat > "$TEST_DIR/remote-question.json" <<'JSON'
[
  {"id":590,"ownerId":4,"description":"/manul jak wyglada helloworld w kotlinie? tylko odpowiedz bez kodzenia","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]},
  {"id":591,"ownerId":4,"description":"/manul daj znać czy żyjesz","addedTime":"2026-10-01T10:01:00","modifiedTime":"2026-10-01T10:01:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
REMOTE_QUESTION_SOURCE='{"type":"todo_remote_mcp","allowReportOnly":false,"repositories":[],"manulUserIdEnv":"MANUL_USER_ID","url":"{env:FITEO_BASE_URL}/mcp","tokenEnv":"FITEO_MANUL_PAT","shareUserIdEnv":"FITEO_MANUL_SHARE_USER_ID"}'

# Exercise the production default: the catalog is read from the canonical
# agent skills tree, not bundled alongside the standalone Manul checkout.
HOST_REPOSITORY_CATALOG="$SKILLS_DIR/globalskills-repository/project-repositories.json"
mkdir -p "$(dirname "$HOST_REPOSITORY_CATALOG")"
cp "$TODO_TASK_REPOSITORY_CATALOG" "$HOST_REPOSITORY_CATALOG"
SAVED_TODO_TASK_REPOSITORY_CATALOG="$TODO_TASK_REPOSITORY_CATALOG"
unset TODO_TASK_REPOSITORY_CATALOG
assert_eq "default Todo repository catalog resolves from ~/.agents/skills" "$HOST_REPOSITORY_CATALOG" "$(HOME="$SKILLS_HOME" todo_task_repository_catalog_path)"

export TODO_MCP_FIXTURE="$TEST_DIR/remote-question.json"
remote_question_tasks="$(HOME="$SKILLS_HOME" task_source_todo_remote_poll "$REMOTE_QUESTION_SOURCE" | jq -sc '.')"
assert_eq "both ordinary remote /manul prompts are discovered" "2" "$(jq 'length' <<<"$remote_question_tasks")"
assert_eq "remote questions stay report-only even when the catalog has a manul alias" "[\"report_only\",\"report_only\"]" "$(jq -c '[.[].execution.kind]' <<<"$remote_question_tasks")"
assert_contains "remote Kotlin question keeps its original prompt" "$(jq -r '.[].prompt' <<<"$remote_question_tasks")" "jak wyglada helloworld w kotlinie? tylko odpowiedz bez kodzenia"
assert_contains "remote liveness question keeps its original prompt" "$(jq -r '.[].prompt' <<<"$remote_question_tasks")" "daj znać czy żyjesz"
assert_eq "remote questions do not require repository metadata" "2" "$(jq '[.[] | select((.metadata.repository // null) == null)] | length' <<<"$remote_question_tasks")"
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

echo "=== Report-only Todo delivery ==="
cat > "$TEST_DIR/local-report.json" <<'JSON'
[
  {"id":501,"description":"/manul report Summarize local report delivery","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[]}
]
JSON
LOCAL_REPORT_SOURCE='{"type":"todo_local_mcp","url":"http://127.0.0.1:8766/mcp","allowReportOnly":false,"repositories":[]}'
export TODO_MCP_FIXTURE="$TEST_DIR/local-report.json"
local_report_task="$(task_source_todo_local_poll "$LOCAL_REPORT_SOURCE")"
local_report_prompt="$(jq -r '.prompt' <<<"$local_report_task")"
assert_contains "local report-only prompt requires a plain standalone completion marker" "$local_report_prompt" "without Markdown backticks or code fences"
assert_contains "local report-only prompt requires a one-line answer summary first" "$local_report_prompt" "FIRST line must be one concise plain-text sentence"
assert_contains "local report-only prompt requires a Markdown document" "$local_report_prompt" "polished, self-contained Markdown document"
assert_contains "local report-only prompt delegates source metadata to Manul" "$local_report_prompt" "append a short task-context section"
assert_eq "local report-only task is discovered without repository routing" "report_only" "$(jq -r '.execution.kind' <<<"$local_report_task")"
assert_eq "local report-only task carries no repository metadata" "null" "$(jq -r '.metadata.repository // null' <<<"$local_report_task")"
local_report_id="$(jq -r '.taskSourceId' <<<"$local_report_task")"
assert_eq "local report source is current before execution" "0" "$(todo_task_still_current "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id"; echo $?)"
: > "$TODO_MCP_CALL_LOG"
export TODO_MCP_FAIL_MARK=1
local_report_rc=0
local_report_answer=$'Local report answer with exact content.\nSecond line must remain byte-for-byte unchanged.'
todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" "$local_report_answer" >/dev/null || local_report_rc=$?
assert_rc "failed completion mutation leaves the report task retryable" "2" "$local_report_rc"
partial_local_root_status=$(jq -r .[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "partial local write leaves root task active" "true" "$partial_local_root_status"
partial_local_child_count=$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")
assert_eq "partial local write keeps one result subtask" "1" "$partial_local_child_count"
partial_local_child_status=$(jq -r .[0].subTasks[0].isToDo "$TODO_MCP_FIXTURE")
assert_eq "partial local write leaves result subtask pending" "true" "$partial_local_child_status"
partial_local_description="$(jq -r .[0].subTasks[0].description "$TODO_MCP_FIXTURE")"
assert_eq "local report's first line is the user-facing short answer" "Local report answer with exact content." "$(head -n 1 <<<"$partial_local_description")"
assert_not_contains "local report marker is not the first description line" "$(head -n 1 <<<"$partial_local_description")" "<!-- MANUL_REPORT_RESULT"
assert_contains "local report includes a task-context section" "$partial_local_description" "## Kontekst zadania"
assert_contains "local report identifies Todo Local as its source" "$partial_local_description" "**Źródło:** Todo Local"
assert_contains "local report includes the original task description without the trigger" "$partial_local_description" "**Zadanie:** Summarize local report delivery"
assert_contains "local report keeps its integrity marker as the final line" "$(tail -n 1 <<<"$partial_local_description")" "<!-- MANUL_REPORT_RESULT"
unset TODO_MCP_FAIL_MARK
local_report_receipt="$(todo_task_report_deliver "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" "$local_report_answer")"
assert_eq "local report receipt preserves the exact unformatted multi-line answer" "$local_report_answer" "$(jq -r '.answer' <<<"$local_report_receipt")"

# Legacy report records used the same integrity marker at the start of the
# description. Keep them readable while new records place the marker at EOF.
legacy_answer="Legacy report answer."
legacy_payload="$(todo_task_markdown_format <<<"$legacy_answer")"
legacy_payload_digest="$(printf '%s' "$legacy_payload" | sha256sum | awk '{print $1}')"
legacy_answer_digest="$(printf '%s' "$legacy_answer" | sha256sum | awk '{print $1}')"
legacy_answer_base64="$(printf '%s' "$legacy_answer" | "$PYTHON_BIN" -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"), end="")')"
legacy_description="<!-- MANUL_REPORT_RESULT:v1;root=501;source=501@0123456789abcdef;sha256=${legacy_payload_digest};answerSha256=${legacy_answer_digest};answerBase64=${legacy_answer_base64} -->"$'\n'"$legacy_payload"
assert_eq "legacy leading-marker report still restores the exact original answer" "$legacy_answer" "$(todo_task_report_receipt_answer "$legacy_description")"
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
local_retry_answer="$(jq -r .answer "$TEST_DIR/local-retry-receipt.json")"
assert_eq "local report retry returns the exact previously persisted multi-line answer" "$local_report_answer" "$local_retry_answer"
grep -Fc "create_task" "$TODO_MCP_CALL_LOG" > "$TEST_DIR/local-create-count"
IFS= read -r local_create_count < "$TEST_DIR/local-create-count"
assert_eq "local report creates only one output child across retry" "1" "$local_create_count"
jq --arg desc "/manul report User changed source after delivery" '.[0].description = $desc' "$TODO_MCP_FIXTURE" > "$TEST_DIR/local-report-edited.json"
export TODO_MCP_FIXTURE="$TEST_DIR/local-report-edited.json"
local_report_reval_rc=0
todo_task_still_current "$LOCAL_REPORT_SOURCE" todo_local_mcp "$local_report_id" || local_report_reval_rc=$?
assert_rc "user edits remain visible to source fingerprint after output child is excluded" "1" "$local_report_reval_rc"

# Markdown output follows the syntax supported by the Todo UI renderer.
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
assert_contains "fenced code block content is preserved" "$formatted_markdown" $'```kotlin\nval value = 1\n```'
assert_eq "single-line report text has no redundant trailing hard break" "Single-line report answer." "$(printf '%s' 'Single-line report answer.' | todo_task_markdown_format)"
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
REMOTE_REPORT_SOURCE='{"type":"todo_remote_mcp","allowReportOnly":false,"repositories":[],"manulUserIdEnv":"MANUL_USER_ID","url":"{env:FITEO_BASE_URL}/mcp","tokenEnv":"FITEO_MANUL_PAT","shareUserIdEnv":"FITEO_MANUL_SHARE_USER_ID"}'
# The lower-level delivery helper expects the source config to be normalized,
# just as task_source_report_deliver does in the production dispatch path.
REMOTE_REPORT_SOURCE="$(todo_source_remote_config "$REMOTE_REPORT_SOURCE")"
export TODO_MCP_FIXTURE="$TEST_DIR/remote-report.json"
remote_report_task="$(task_source_todo_remote_poll "$REMOTE_REPORT_SOURCE")"
remote_report_prompt="$(jq -r '.prompt' <<<"$remote_report_task")"
assert_contains "remote report-only prompt requires a plain standalone completion marker" "$remote_report_prompt" "without Markdown backticks or code fences"
assert_contains "remote report-only prompt requires a one-line answer summary first" "$remote_report_prompt" "FIRST line must be one concise plain-text sentence"
assert_contains "remote report-only prompt requires a Markdown document" "$remote_report_prompt" "polished, self-contained Markdown document"
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
remote_partial_description="$(jq -r .[0].subTasks[0].description "$TODO_MCP_FIXTURE")"
assert_eq "remote report's first line is the user-facing short answer" "Remote Fiteo report answer." "$(head -n 1 <<<"$remote_partial_description")"
assert_not_contains "remote report marker is not the first description line" "$(head -n 1 <<<"$remote_partial_description")" "<!-- MANUL_REPORT_RESULT"
assert_contains "remote report identifies Fiteo Backend as its source" "$remote_partial_description" "**Źródło:** Fiteo Backend"
assert_contains "remote report includes the original task description without the trigger" "$remote_partial_description" "**Zadanie:** Summarize remote report delivery"
assert_contains "remote report keeps its integrity marker as the final line" "$(tail -n 1 <<<"$remote_partial_description")" "<!-- MANUL_REPORT_RESULT"
unset TODO_MCP_FAIL_MARK
remote_report_receipt="$(todo_task_report_deliver "$REMOTE_REPORT_SOURCE" todo_remote_mcp "$remote_report_id" "A regenerated retry answer must reuse the persisted result.")"
assert_eq "remote retry returns the exact previously persisted answer" "Remote Fiteo report answer." "$(jq -r '.answer' <<<"$remote_report_receipt")"
remote_result_id="$(jq -r '.resultTaskId' <<<"$remote_report_receipt")"
remote_result_parent="$(jq -r '.[0].subTasks[0].parentTaskId' "$TODO_MCP_FIXTURE")"
assert_eq "Manul report result is persisted under the shared parent task" "601" "$remote_result_parent"
remote_child_direct_share_count="$(jq -r '.[0].subTasks[0].shares // [] | length' "$TODO_MCP_FIXTURE")"
assert_eq "Manul report subtask does not create a duplicate direct share" "0" "$remote_child_direct_share_count"
remote_parent_share_verified="$(jq -r '.[0].shares | any(.[]; .userId == "77" and .permission == "EDITOR_AND_VIEWER")' "$TODO_MCP_FIXTURE")"
assert_eq "existing direct share on the parent is preserved" "true" "$remote_parent_share_verified"
remote_create_arguments="$(awk -F '\t' '$1 == "todo_create_task" {print $2; exit}' "$TODO_MCP_CALL_LOG")"
remote_create_has_shares="$(jq -r '.task | has("shares")' <<<"$remote_create_arguments")"
assert_eq "Fiteo create request uses parentTaskId without a child shares payload" "false" "$remote_create_has_shares"
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



# A successful create response without a child in the parent's tree is not
# enough: Manul must confirm the exact parent/child relationship on read-back.
cat > "$TEST_DIR/remote-report-child-not-readable.json" <<'JSON'
[
  {"id":605,"ownerId":4,"description":"/manul report Child read-back fixture","addedTime":"2026-10-01T10:00:00","modifiedTime":"2026-10-01T10:00:00","parentTaskId":null,"subTasks":[],"isToDo":true,"priority":1,"scheduler":null,"shares":[{"userId":"77","permission":"EDITOR_AND_VIEWER"}]}
]
JSON
export TODO_MCP_FIXTURE="$TEST_DIR/remote-report-child-not-readable.json"
remote_unreadable_task="$(task_source_todo_remote_poll "$REMOTE_REPORT_SOURCE")"
remote_unreadable_id="$(jq -r '.taskSourceId' <<<"$remote_unreadable_task")"
export TODO_MCP_DROP_CHILD=1
remote_unreadable_rc=0
todo_task_report_deliver "$REMOTE_REPORT_SOURCE" todo_remote_mcp "$remote_unreadable_id" "Must be readable under parent." >/dev/null 2>"$TEST_DIR/remote-child-readback.log" || remote_unreadable_rc=$?
unset TODO_MCP_DROP_CHILD
assert_rc "remote child missing from parent read-back fails delivery" "1" "$remote_unreadable_rc"
assert_eq "unreadable remote child does not complete the root" "true" "$(jq -r '.[0].isToDo' "$TODO_MCP_FIXTURE")"
assert_eq "unreadable remote child is not falsely marked complete" "0" "$(jq -r '.[0].subTasks | length' "$TODO_MCP_FIXTURE")"

echo
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
