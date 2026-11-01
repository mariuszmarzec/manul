#!/usr/bin/env bash
# opencode-adapter.sh — OpenCode runtime adapter for AgentExecutor.
#
# Independent backend: it does not import, invoke, or configure OpenClaw.
# Uses the documented non-interactive CLI:
#   opencode run [message...] --format json --dir <workspace>
# and resumes a saved session with:
#   opencode run --session <session-id> ...
#
# JSON mode exposes sessionID on events. We persist that ID only when the
# runtime reports a step-limit continuation condition. Text events are
# normalized back to plain task output so Manul control markers remain
# line-oriented and compatible with the existing daemon contract.

set -u

MANUL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/process-runner.sh"
source "$MANUL_SCRIPT_DIR/todo-local-mcp-url.sh"

OPT_TASK_ID=""
OPT_PROMPT=""
OPT_WORKSPACE=""
OPT_AGENT=""
OPT_ATTEMPT=1
OPT_TIMEOUT=0
OPT_SESSION_ID=""
OPT_STDOUT_FILE=""
OPT_STDERR_FILE=""
OPT_AUTO=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id)     OPT_TASK_ID="$2";     shift 2 ;;
        --prompt)      OPT_PROMPT="$2";      shift 2 ;;
        --workspace)   OPT_WORKSPACE="$2";   shift 2 ;;
        --agent)       OPT_AGENT="$2";       shift 2 ;;
        --attempt)     OPT_ATTEMPT="$2";     shift 2 ;;
        --timeout)     OPT_TIMEOUT="$2";     shift 2 ;;
        --session-id)  OPT_SESSION_ID="$2";  shift 2 ;;
        --stdout-file) OPT_STDOUT_FILE="$2"; shift 2 ;;
        --stderr-file) OPT_STDERR_FILE="$2"; shift 2 ;;
        --auto)       OPT_AUTO=true; shift ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$OPT_TASK_ID" ] || [ -z "$OPT_PROMPT" ] || [ -z "$OPT_WORKSPACE" ]; then
    printf '{"status":"FAILED","task_id":"","exit_code":1,"summary":"Missing required args (task-id/prompt/workspace)","session_id":"","duration_s":0}\n'
    exit 1
fi
if [ ! -f "$OPT_PROMPT" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":1,"summary":"Prompt file not found","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 1
fi
if [ ! -d "$OPT_WORKSPACE" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Workspace directory not found","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 66
fi

# Known install locations for the OpenCode CLI, in priority order. The binary
# is commonly installed at $HOME/.opencode/bin (added by the OpenCode installer
# to the interactive shell PATH only), but the daemon worker inherits a
# non-interactive PATH that omits it — exactly the failure mode that already
# bit the OpenClaw adapter. Explicit OPENCODE_BIN always wins; otherwise PATH;
# otherwise these well-known locations are probed before giving up.
OPENCODE_KNOWN_DIRS=(
    "$HOME/.opencode/bin"
    "$HOME/.local/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
)

_resolve_opencode_bin() {
    if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then
        printf '%s' "$OPENCODE_BIN"
        return 0
    fi
    local found
    found="$(command -v opencode 2>/dev/null || true)"
    if [ -n "$found" ] && [ -x "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    local dir bin
    for dir in "${OPENCODE_KNOWN_DIRS[@]}"; do
        bin="$dir/opencode"
        if [ -x "$bin" ]; then
            printf '%s' "$bin"
            return 0
        fi
    done
    return 1
}
OPENCODE_BIN="$(_resolve_opencode_bin)"
if [ -z "$OPENCODE_BIN" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":127,"summary":"OpenCode binary not found (opencode not on PATH or known dirs)","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 127
fi
export OPENCODE_BIN
# Surface the resolution path in diagnostics so a future failure is not a
# silent empty-stderr death like the one this fix addresses.
if [ -n "${OPENCODE_BIN_OVERRIDE:-}" ]; then
    _OC_SOURCE="OPENCODE_BIN override"
elif command -v opencode >/dev/null 2>&1; then
    _OC_SOURCE="PATH"
else
    _OC_SOURCE="known-dir fallback"
fi
export _OC_SOURCE

AGENT_TIMEOUT="${OPT_TIMEOUT:-0}"
if ! [[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TIMEOUT" -lt 1 ]; then
    AGENT_TIMEOUT="${MANUL_OPENCODE_AGENT_TIMEOUT:-43200}"
fi
if ! [[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TIMEOUT" -lt 1 ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":2,"summary":"Invalid OpenCode timeout","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 2
fi

AGENT_IDLE_TIMEOUT="${MANUL_OPENCODE_NO_PROGRESS_TIMEOUT:-$(jq -r '.automation.agentNoProgressTimeoutSeconds // 900' "${MANUL_CONFIG:-/dev/null}" 2>/dev/null || echo 900)}"
if ! [[ "$AGENT_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_IDLE_TIMEOUT" -lt 1 ]; then
    printf '[%s] opencode-adapter: WARN: invalid no-progress timeout; using default 900s\n' "$(date -Is)" >>"$OPT_STDERR_FILE"
    AGENT_IDLE_TIMEOUT=900
fi

# A running JSONL tool_use event is explicit evidence that OpenCode is still
# executing a tool. Allow it up to this bounded interval to return before
# classifying it as a stuck tool call; the overall agent timeout still applies.
AGENT_TOOL_IDLE_TIMEOUT="${MANUL_OPENCODE_TOOL_NO_PROGRESS_TIMEOUT:-$(jq -r '.automation.agentToolNoProgressTimeoutSeconds // 3600' "${MANUL_CONFIG:-/dev/null}" 2>/dev/null || echo 3600)}"
if ! [[ "$AGENT_TOOL_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TOOL_IDLE_TIMEOUT" -lt 1 ]; then
    printf '[%s] opencode-adapter: WARN: invalid active-tool timeout; using default 3600s\n' "$(date -Is)" >>"$OPT_STDERR_FILE"
    AGENT_TOOL_IDLE_TIMEOUT=3600
fi

# CLI JSON does not necessarily emit a tool_use event until that tool finishes.
# Bound a step that started in JSONL but has not yet emitted step_finish separately
# from the shorter generic no-progress timer.
AGENT_STEP_IDLE_TIMEOUT="${MANUL_OPENCODE_STEP_NO_PROGRESS_TIMEOUT:-$(jq -r '.automation.agentStepNoProgressTimeoutSeconds // 3600' "${MANUL_CONFIG:-/dev/null}" 2>/dev/null || echo 3600)}"
if ! [[ "$AGENT_STEP_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_STEP_IDLE_TIMEOUT" -lt 1 ]; then
    printf '[%s] opencode-adapter: WARN: invalid active-step timeout; using default 3600s\n' "$(date -Is)" >>"$OPT_STDERR_FILE"
    AGENT_STEP_IDLE_TIMEOUT=3600
fi

CONTINUATION_PROMPT="Continue exactly where you left off. Do not re-plan or restate the task. Make the next concrete changes in the current workspace, run the relevant checks, and finish the task. When the task is genuinely complete, emit exactly one final line: TASK_DONE"
PERMISSION_RECOVERY_PROMPT="A tool call was rejected by the OpenCode permission policy. Do not repeat the denied operation, rephrase it, split it into smaller calls, or try to reach the same denied resource through another tool, path, symlink, wrapper, subagent, or command. Do not change or bypass permissions. Re-evaluate the original task goal and choose an independent alternative that stays inside the assigned workspace and uses currently allowed capabilities. For build diagnostics, prefer rerunning the repository's documented command with useful flags and save a concise, secret-free log under the task workspace (for example, tmp/diagnostics/). If no safe alternative can provide the required evidence, explain exactly what is missing and why, preserve all completed work, and emit TASK_FAILED with a concise reason. Never claim success without verification."
AGENT_ARGS=()
if [ -n "$OPT_AGENT" ]; then
    AGENT_ARGS=(--agent "$OPT_AGENT")
fi
AUTO_ARGS=()
if [ "$OPT_AUTO" = "true" ]; then
    AUTO_ARGS=(--auto)
fi

RAW_STDOUT_FILE="$(manul_task_file_path "${MANUL_TASK_LOG_DIR:-$(dirname "$OPT_STDOUT_FILE")}" "$OPT_TASK_ID" "attempt-${OPT_ATTEMPT}.opencode.jsonl")"
CURRENT_RUN_STDOUT_FILE="${RAW_STDOUT_FILE%.jsonl}.current.jsonl"
CURRENT_RUN_STDERR_FILE="${RAW_STDOUT_FILE%.jsonl}.current.stderr"
CURRENT_RUN_PROMPT_FILE="${RAW_STDOUT_FILE%.jsonl}.current.prompt"
# Aggregate all runtime events from the initial call and same-session resumes.
mkdir -p "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" "$(dirname "$RAW_STDOUT_FILE")" 2>/dev/null || true

log() {
    echo "[$(date -Is)] opencode-adapter: $*" >>"$OPT_STDERR_FILE"
}

# Keep the provider/global config immutable. OpenCode needs an explicit
# external-directory allow for the active lease only, while shared config
# denies all sibling workspaces under the configured MANUL_WORKSPACE.
OPENCODE_TASK_CONFIG_DIR=""
cleanup_opencode_task_config() {
    if [ -n "${OPENCODE_TASK_CONFIG_DIR:-}" ]; then
        rm -rf -- "$OPENCODE_TASK_CONFIG_DIR"
        OPENCODE_TASK_CONFIG_DIR=""
    fi
}
trap cleanup_opencode_task_config EXIT HUP INT TERM

# Respect a configured provider path, but also cover OpenCode's canonical
# default when OPENCODE_CONFIG is not exported by the unattended launcher.
_OPENCODE_BASE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
_TASK_WORKSPACE_ROOT_INPUT="${MANUL_TASK_WORKSPACE_ROOT:-}"
_TASK_WORKDIR_INPUT="${MANUL_TASK_WORKDIR:-}"
_workspace_real=""
_workdir_real=""
# Runner-supplied paths are authoritative. Validate them before starting the
# model so a stale/wrong home prefix cannot turn into a permission retry loop.
if [ -n "$_TASK_WORKSPACE_ROOT_INPUT" ] || [ -f "$_OPENCODE_BASE_CONFIG" ]; then
    _workspace_real="$(realpath -e -- "$OPT_WORKSPACE" 2>/dev/null || true)"
    _workspace_base_real="$(realpath -e -- "$MANUL_WORKSPACE" 2>/dev/null || true)"
    _assigned_workspace_real="$(realpath -e -- "${_TASK_WORKSPACE_ROOT_INPUT:-$OPT_WORKSPACE}" 2>/dev/null || true)"
    if [ -z "$_workspace_real" ] || [ -z "$_workspace_base_real" ] || [ -z "$_assigned_workspace_real" ]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Cannot resolve runner-assigned task workspace paths","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
        exit 66
    fi
    if [ "$_assigned_workspace_real" != "$_workspace_real" ]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Adapter workspace does not match the runner-assigned task workspace root","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
        exit 66
    fi
    _workspace_parent="$(dirname -- "$_workspace_real")"
    _workspace_name="$(basename -- "$_workspace_real")"
    if [ "$_workspace_parent" != "$_workspace_base_real" ] || [[ "$_workspace_name" != ws-* ]]; then
        printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Runner-assigned workspace is not a direct lease under the configured MANUL_WORKSPACE","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
        exit 66
    fi
    if [ -n "$_TASK_WORKDIR_INPUT" ]; then
        _workdir_real="$(realpath -e -- "$_TASK_WORKDIR_INPUT" 2>/dev/null || true)"
        if [ -z "$_workdir_real" ]; then
            printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Cannot resolve runner-assigned primary checkout path","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
            exit 66
        fi
        case "$_workdir_real" in
            "$_workspace_real"/*) ;;
            *)
                printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Primary checkout is outside the runner-assigned task workspace","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
                exit 66
                ;;
        esac
    fi
else
    _workspace_real="$(realpath -e -- "$OPT_WORKSPACE" 2>/dev/null || true)"
fi

# Caracal is a required capability for Manul's OpenCode runtime. Never start
# a task with a half-configured MCP definition: OpenCode resolves env placeholders
# in the adapter's child process, not from an interactive OpenCode UI session.
# Fallback to the single Caracal provider (~/.caracal/env.sh) for credentials
# when the daemon has not already provided them. The provider loads the token
# from secrets.yaml and resolves the live loopback URL via caracal-rag check.
# Manul-specific context (MANUL_TASK_WORKSPACE_ROOT, etc.) is preserved.
# shellcheck source=~/.caracal/env.sh
if [ -z "${CARACAL_MCP_URL:-}" ] || [ -z "${CARACAL_ACCESS_TOKEN:-}" ] ||
   [[ "${CARACAL_MCP_URL:-}" =~ ^http://127\.0\.0\.1:0/ ]]; then
    # Try the Caracal provider. Use CARACAL_RESOLVE_LIVE=1 to force a fresh
    # healthcheck so a long-running daemon cannot pin a stale port.
    if CARACAL_RESOLVE_LIVE=1 . "$HOME/.caracal/env.sh" 2>/dev/null; then
        log "resolved Caracal MCP from ~/.caracal/env.sh"
    else
        log "required Caracal MCP URL/token is missing or disconnected"
        printf '{"status":"FAILED","task_id":"%s","exit_code":78,"summary":"Required Caracal MCP is not configured for this Manul execution","session_id":"","duration_s":0,"failure_code":"PRE_EXECUTION_FAILURE","diagnostics":{"stage":"caracal_mcp_config","agent_started":false}}\n' "$OPT_TASK_ID"
        exit 78
    fi
fi
export CARACAL_MCP_URL CARACAL_ACCESS_TOKEN

# Read only Todo's token from the runtime env file in a child shell. The daemon
# can live longer than aicode, so refresh this one value per task without
# re-sourcing the file into this shell and overwriting Caracal's live settings.
_TODO_LOCAL_ENV_FILE="$MANUL_DIR/.env"
if [ -f "$_TODO_LOCAL_ENV_FILE" ]; then
    if bash -n "$_TODO_LOCAL_ENV_FILE" >/dev/null 2>&1; then
        _todo_local_runtime_token="$(bash -c 'set -e; . "$1" >/dev/null 2>&1; printf "%s" "${TODO_LOCAL_MCP_TOKEN:-}"' _ "$_TODO_LOCAL_ENV_FILE" 2>/dev/null)" || _todo_local_runtime_token=""
        if [ -n "$_todo_local_runtime_token" ]; then
            TODO_LOCAL_MCP_TOKEN="$_todo_local_runtime_token"
            export TODO_LOCAL_MCP_TOKEN
        else
            unset TODO_LOCAL_MCP_TOKEN 2>/dev/null || true
        fi
    else
        log "Todo local MCP token environment file has invalid shell syntax; Todo MCP will be skipped"
        unset TODO_LOCAL_MCP_TOKEN 2>/dev/null || true
    fi
fi

# The daemon can outlive an aicode launch. Refresh Fiteo credentials from the
# latest runtime file for every task, while leaving unrelated inherited values
# untouched. The endpoint and PAT are stored atomically by manul-env.sh.
_FITEO_RUNTIME_ENV_FILE="$MANUL_DIR/.env"
if [ -f "$_FITEO_RUNTIME_ENV_FILE" ]; then
    _fiteo_runtime_values="$(bash -c 'set -e; . "$1" >/dev/null 2>&1; printf "%s|%s" "${FITEO_BASE_URL:-}" "${FITEO_PAT:-}"' _ "$_FITEO_RUNTIME_ENV_FILE" 2>/dev/null)" || _fiteo_runtime_values=""
    IFS="|" read -r _fiteo_runtime_base_url _fiteo_runtime_pat <<< "$_fiteo_runtime_values"
    if [ -n "$_fiteo_runtime_base_url" ] && [ -n "$_fiteo_runtime_pat" ]; then
        FITEO_BASE_URL="$_fiteo_runtime_base_url"
        FITEO_PAT="$_fiteo_runtime_pat"
        export FITEO_BASE_URL FITEO_PAT
    else
        unset FITEO_BASE_URL FITEO_PAT 2>/dev/null || true
    fi
fi

TODO_LOCAL_MCP_AVAILABLE=0
TODO_LOCAL_MCP_CONNECTED=0
unset TODO_LOCAL_MCP_URL
if [ -n "${TODO_LOCAL_MCP_TOKEN:-}" ] && command -v curl >/dev/null 2>&1; then
    _todo_local_resolved_url="$(todo_local_mcp_resolve_url "")" || _todo_local_resolved_url=""
    if [ -n "$_todo_local_resolved_url" ]; then
        TODO_LOCAL_MCP_URL="$_todo_local_resolved_url"
        TODO_LOCAL_MCP_AVAILABLE=1
        TODO_LOCAL_MCP_CONNECTED=1
        log "Todo local MCP is reachable at $TODO_LOCAL_MCP_URL; adding it to the task-scoped OpenCode config"
    else
        log "Todo local MCP is unavailable on the current host; continuing without this optional MCP"
    fi
fi
export TODO_LOCAL_MCP_URL TODO_LOCAL_MCP_AVAILABLE TODO_LOCAL_MCP_CONNECTED

if [ -n "$_workspace_real" ]; then
    export MANUL_TASK_WORKSPACE_ROOT="$_workspace_real"
fi
if [ -n "$_workdir_real" ]; then
    export MANUL_TASK_WORKDIR="$_workdir_real"
fi

# Build an invocation-local OpenCode config for every task. Merge Caracal into
# it even when the operator's base config has no MCP entry. Use OpenCode's canonical named-server shape (.mcp["caracal-rag"]); do not
# confuse it with OpenClaw's distinct .mcp.servers schema.
# Preserve unrelated settings and keep the operator/global file immutable.
OPENCODE_TASK_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manul-opencode-config.XXXXXX")" || exit 1
_original_opencode_config="$_OPENCODE_BASE_CONFIG"
OPENCODE_CONFIG="$OPENCODE_TASK_CONFIG_DIR/opencode.json"
if [ -f "$_original_opencode_config" ]; then
    _config_input="$_original_opencode_config"
else
    _config_input="/dev/null"
fi
if ! jq -s --arg workspace "$_workspace_real" --arg workspaceBase "${_workspace_base_real:-}" '
    (.[0] // {})
    | .permission.external_directory = (
        if ($workspaceBase | length) > 0 then
          ((.permission.external_directory // {})
           | if type == "object" then . else {} end
           | with_entries(
               ((.key
                 | if startswith("~/") then (env.HOME + .[1:])
                   elif startswith("$HOME/") then (env.HOME + .[5:])
                   else .
                   end) as $path
                | select((($path == $workspaceBase) or ($path | startswith($workspaceBase + "/"))) | not))
             )
           | . + {
               ($workspaceBase + "/**"): "deny",
               ($workspace): "allow",
               ($workspace + "/**"): "allow"
             })
        else
          ((.permission.external_directory // {}) | if type == "object" then . else {} end)
        end
      )
    | .mcp = (
        (.mcp // {}) | if type == "object" then . else {} end
        | . + {
            "caracal-rag": {
              type: "remote",
              url: "{env:CARACAL_MCP_URL}",
              oauth: false,
              enabled: true,
              headers: {Authorization: "Bearer {env:CARACAL_ACCESS_TOKEN}"}
            },
            "fiteo": {
              type: "remote",
              url: "{env:FITEO_BASE_URL}/mcp",
              oauth: false,
              enabled: true,
              headers: {Authorization: "Bearer {env:FITEO_PAT}"}
            }
          }
      )
    | .tools = ((.tools // {}) | if type == "object" then . else {} end | . + {"caracal-rag_*": true, "fiteo_*": true})
    | .agent = (
        (.agent // {})
        | if type == "object" then
            with_entries(
              if .key == "chat" then .
              else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end | . + {"caracal-rag_*": true, "fiteo_*": true})
              end
            )
          else {}
          end
      )
    | if (env.TODO_LOCAL_MCP_AVAILABLE // "0") == "1" then
        .mcp = (
            (.mcp // {}) | if type == "object" then . else {} end
            | . + {
                "todo-local": {
                    type: "remote",
                    url: "{env:TODO_LOCAL_MCP_URL}",
                    oauth: false,
                    enabled: true,
                    headers: {Authorization: "Bearer {env:TODO_LOCAL_MCP_TOKEN}"}
                }
              }
          )
        | .tools = ((.tools // {}) | if type == "object" then . else {} end | . + {"todo-local_*": true})
        | .agent = (
            (.agent // {})
            | if type == "object" then
                with_entries(
                  if .key == "chat" then .
                  else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end | . + {"todo-local_*": true})
                  end
                )
              else {}
              end
          )
      else
        .mcp = ((.mcp // {}) | if type == "object" then . else {} end | del(."todo-local"))
        | .tools = ((.tools // {}) | if type == "object" then . else {} end | del(."todo-local_*"))
        | .agent = (
            (.agent // {})
            | if type == "object" then
                with_entries(
                  if .key == "chat" then .
                  else .value.tools = ((.value.tools // {}) | if type == "object" then . else {} end | del(."todo-local_*"))
                  end
                )
              else {}
              end
          )
      end
' "$_config_input" >"$OPENCODE_CONFIG"; then
    cleanup_opencode_task_config
    printf '{"status":"FAILED","task_id":"%s","exit_code":65,"summary":"Unable to build task-scoped OpenCode config with Caracal MCP","session_id":"","duration_s":0,"failure_code":"PRE_EXECUTION_FAILURE","diagnostics":{"stage":"task_config","agent_started":false}}\n' "$OPT_TASK_ID"
    exit 65
fi
chmod 600 "$OPENCODE_CONFIG"
export OPENCODE_CONFIG
log "using task-scoped OpenCode config with required Caracal MCP; global config unchanged"

# A saved URL/token is not proof that Caracal is reachable and authenticated.
# Check OpenCode's actual MCP registry before running any task tools. The raw
# files live in the task-local config directory and are deleted by the EXIT
# trap, so preserve only a bounded, redacted summary before returning failure.
CARACAL_PREFLIGHT_STDOUT="$OPENCODE_TASK_CONFIG_DIR/caracal-mcp-list.stdout"
CARACAL_PREFLIGHT_STDERR="$OPENCODE_TASK_CONFIG_DIR/caracal-mcp-list.stderr"
: >"$CARACAL_PREFLIGHT_STDOUT"
: >"$CARACAL_PREFLIGHT_STDERR"
ProcessRunner_TmpStdout="$CARACAL_PREFLIGHT_STDOUT"
ProcessRunner_TmpStderr="$CARACAL_PREFLIGHT_STDERR"
_caracal_preflight_result="$(ProcessRunner.run --timeout 45 --cwd "$OPT_WORKSPACE" -- "$OPENCODE_BIN" mcp list)"
_caracal_preflight_rc="$(printf '%s\n' "$_caracal_preflight_result" | head -n 1 | cut -d'|' -f1)"
_mcp_preflight_stage=""
_mcp_preflight_label=""
_mcp_preflight_summary=""
if ! grep -Eiq 'caracal-rag[[:space:]].*connected|connected.*caracal-rag' "$CARACAL_PREFLIGHT_STDOUT"; then
    _mcp_preflight_stage="caracal_mcp_preflight"
    _mcp_preflight_label="Caracal"
    _mcp_preflight_summary="Caracal MCP did not report a live connected status in OpenCode; task was not started"
elif [ "$TODO_LOCAL_MCP_AVAILABLE" = "1" ] &&
     ! grep -Eiq 'todo-local[[:space:]].*connected|connected.*todo-local' "$CARACAL_PREFLIGHT_STDOUT"; then
    _mcp_preflight_stage="todo_local_mcp_preflight"
    _mcp_preflight_label="Todo local"
    _mcp_preflight_summary="Todo local MCP was reachable but did not report connected in OpenCode; task was not started"
fi
# OpenCode may report a non-zero aggregate MCP-list status when an optional
# server such as Fiteo is offline. Caracal's explicit connected status is the
# required gate; a failure from an unrelated MCP must not block this task.

if [ -n "$_mcp_preflight_stage" ]; then
    log "$_mcp_preflight_label MCP preflight failed; OpenCode reported the server disconnected or unavailable"

    log_caracal_preflight_file() {
        local stream="$1" file="$2" redacted_output
        if [ ! -s "$file" ]; then
            log "$_mcp_preflight_label MCP preflight $stream: <empty>"
            return 0
        fi
        redacted_output="$(python3 - "$file" <<'PY'
import os
import re
import sys
from pathlib import Path

try:
    content = Path(sys.argv[1]).read_text(errors="replace")
except OSError as exc:
    print(f"<unable to read captured output: {exc.__class__.__name__}>")
    raise SystemExit(0)

for token_name in ("CARACAL_ACCESS_TOKEN", "TODO_LOCAL_MCP_TOKEN"):
    token = os.environ.get(token_name, "")
    if token:
        content = content.replace(token, "[REDACTED]")
content = re.sub(r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+", r"\1[REDACTED]", content)
content = re.sub(r"(?i)([?&](?:access_token|token|api[_-]?key|secret|password)=)[^&\s]+", r"\1[REDACTED]", content)
content = re.sub(r'(?i)(\b(?:access_token|token|api[_-]?key|secret|password)\b\s*[:=]\s*)[^\s,;"}]+', r"\1[REDACTED]", content)
content = re.sub(r"(?i)(https?://)[^/@\s]+:[^/@\s]+@", r"\1[REDACTED]@", content)
lines = content.splitlines()
for line in lines[:20]:
    print(line[:500])
if len(lines) > 20:
    print(f"... {len(lines) - 20} additional lines omitted")
PY
)" || redacted_output="<unable to redact captured output>"
        while IFS= read -r line; do
            log "$_mcp_preflight_label MCP preflight $stream: $line"
        done <<<"$redacted_output"
    }

    log "$_mcp_preflight_label MCP preflight exit code: ${_caracal_preflight_rc:-unknown}"
    log_caracal_preflight_file stdout "$CARACAL_PREFLIGHT_STDOUT"
    log_caracal_preflight_file stderr "$CARACAL_PREFLIGHT_STDERR"
    printf '{"status":"FAILED","task_id":"%s","exit_code":78,"summary":"%s","session_id":"","duration_s":0,"failure_code":"PRE_EXECUTION_FAILURE","diagnostics":{"stage":"%s","agent_started":false}}\n' \
        "$OPT_TASK_ID" "$_mcp_preflight_summary" "$_mcp_preflight_stage"
    exit 78
fi
log "Caracal MCP preflight passed"
if [ "$TODO_LOCAL_MCP_AVAILABLE" = "1" ]; then
    log "Todo local MCP preflight passed"
fi

# Append a truthful capability snapshot to every initial and resumed prompt.
# It is derived from this invocation's effective OpenCode config (including the
# task-local overlay); it never grants permissions or mutates the config.
write_runtime_capability_context() {
    printf '%s\n' '## Runtime capability snapshot (generated by Manul)'
    printf -- '- Assigned workspace root: %s\n' "${MANUL_TASK_WORKSPACE_ROOT:-$OPT_WORKSPACE}"
    if [ -n "${MANUL_TASK_WORKDIR:-}" ]; then
        printf -- '- Runner-verified primary checkout: %s\n' "$MANUL_TASK_WORKDIR"
    else
        printf '%s\n' '- Primary checkout path is provided by the original task prompt; do not reconstruct it.'
    fi
    printf '%s\n' '- The adapter validates runner-supplied paths against the configured MANUL_WORKSPACE before starting the model. These exact paths are authoritative; never reconstruct or correct them from usernames, task IDs, or assumptions.'
    printf '%s\n' '- For shell commands, prefer cd "$MANUL_TASK_WORKDIR" when that variable is present. If a tool does not inherit it, use the exact primary-checkout path in the original prompt. Prefer "$HOME/..." for home-relative paths; do not assume tilde expansion inside quoted strings or tool arguments.'
    printf '%s\n' '- Only the primary checkout may be edited/delivered by default. Related checkouts explicitly declared read-only remain read-only.'
    printf '%s\n' '- Access is still subject to OpenCode tool-level and path-level decisions. An external-directory allow rule is not a guarantee that every bash command or tool call will be allowed.'
    printf '%s\n' '- Never inspect or modify sibling task workspaces, shared caches, Manul databases/logs/configuration, adapters, or other runtime state. Never try to bypass a denial via another tool, a different path, a symlink, a wrapper, or a reshaped command.'
    printf '%s\n' '' 'Effective permission.external_directory rules (path patterns are JSON-quoted):'
    if [ -n "${OPENCODE_CONFIG:-}" ] && [ -r "$OPENCODE_CONFIG" ]; then
        _runtime_capability_rules="$(jq -r '
            (.permission.external_directory // {})
            | if type == "object" then to_entries[] else empty end
            | select(.value == "allow" or .value == "deny" or .value == "ask")
            | "  - " + (.key | tojson) + " => " + (.value | tostring)
        ' "$OPENCODE_CONFIG" 2>/dev/null || true)"
        if [ -n "$_runtime_capability_rules" ]; then
            printf '%s\n' "$_runtime_capability_rules"
        else
            printf '%s\n' '  - No readable external-directory rules were found; do not infer access.'
        fi
    else
        printf '%s\n' '  - Effective config path is unavailable to the adapter; do not infer external-path access.'
    fi
    cat <<'RUNTIME_CAPABILITY_EOF'
## Required behavior when a capability is missing
- Treat any explicit tool or permission denial as a hard boundary. Do not repeat the denied request, or attempt to reach that same resource indirectly.
- First identify the information or operation the denied call was meant to obtain. Continue with an independent, permitted approach whenever one exists.
- Prefer project-local commands and diagnostics. For example, if a Gradle daemon log is outside the allowed scope, rerun the relevant Gradle task with --stacktrace --info --console=plain and save the output under the assigned workspace, rather than reading the daemon log.
- If an independent alternative cannot solve the problem, stop only that blocked line of investigation, continue any unrelated in-scope work, and report the precise missing evidence and the smallest access/input needed. Do not change permissions yourself and do not claim the whole task is impossible unless no safe path remains.
- Never include credentials or secret values in diagnostics. Keep logs minimal and redact sensitive data before presenting evidence.
RUNTIME_CAPABILITY_EOF
}

STEP_LIMIT_CONTINUATIONS_MAX="$(jq -r '.automation.opencodeMaxStepLimitContinuations // 3' "$MANUL_CONFIG" 2>/dev/null || echo 3)"
if ! [[ "$STEP_LIMIT_CONTINUATIONS_MAX" =~ ^[0-9]+$ ]] || [ "$STEP_LIMIT_CONTINUATIONS_MAX" -gt 20 ]; then
    log "WARN: invalid automation.opencodeMaxStepLimitContinuations=${STEP_LIMIT_CONTINUATIONS_MAX}; using default 3 (valid range 0..20)"
    STEP_LIMIT_CONTINUATIONS_MAX=3
fi

: >"$RAW_STDOUT_FILE"
session_id="$OPT_SESSION_ID"
pr_rc=1
final_step_limit_detected="false"
idle_timeout_detected="false"
tool_idle_timeout_detected="false"
step_idle_timeout_detected="false"
internal_continuations_used=0
run_index=0
permission_recovery_used=0
permission_recovery_pending=false
current_stderr_error_message=""
execution_start_epoch="$(date +%s)"

log "starting task=$OPT_TASK_ID attempt=$OPT_ATTEMPT role=${OPT_AGENT:-<automatic>} auto=$OPT_AUTO session=${session_id:-<new>} timeout=${AGENT_TIMEOUT}s no_progress_timeout=${AGENT_IDLE_TIMEOUT}s active_tool_timeout=${AGENT_TOOL_IDLE_TIMEOUT}s active_step_timeout=${AGENT_STEP_IDLE_TIMEOUT}s opencode=$OPENCODE_BIN source=${_OC_SOURCE:-unknown} workspace=$OPT_WORKSPACE internal_step_limit_continuations=$STEP_LIMIT_CONTINUATIONS_MAX"

# One timeout budget spans the first call and all internal continuations.
# These resumes happen before the adapter returns, so they do not finish or
# increment a Manul attempt.
while true; do
    now_epoch="$(date +%s)"
    remaining_timeout=$((AGENT_TIMEOUT - (now_epoch - execution_start_epoch)))
    if [ "$remaining_timeout" -lt 1 ]; then
        pr_rc=124
        final_step_limit_detected="false"
        log "total execution timeout exhausted task=$OPT_TASK_ID internal_continuations=$internal_continuations_used"
        break
    fi

    # Keep large task prompts out of argv. Linux limits the size of each
    # individual argument, so pass the prompt through OpenCode's documented
    # stdin interface instead of appending it to the command line.
    if [ "$permission_recovery_pending" = "true" ]; then
        printf '%s' "$PERMISSION_RECOVERY_PROMPT" > "$CURRENT_RUN_PROMPT_FILE"
        permission_recovery_pending=false
    elif [ "$run_index" -gt 0 ] || [ -n "$session_id" ]; then
        printf '%s' "$CONTINUATION_PROMPT" > "$CURRENT_RUN_PROMPT_FILE"
    else
        cat "$OPT_PROMPT" > "$CURRENT_RUN_PROMPT_FILE"
    fi
    printf '\n\n' >> "$CURRENT_RUN_PROMPT_FILE"
    write_runtime_capability_context >> "$CURRENT_RUN_PROMPT_FILE"
    SESSION_ARGS=()
    if [ -n "$session_id" ]; then
        SESSION_ARGS=(--session "$session_id")
    fi

    : >"$CURRENT_RUN_STDOUT_FILE"
    : >"$CURRENT_RUN_STDERR_FILE"
    ProcessRunner_TmpStdout="$CURRENT_RUN_STDOUT_FILE"
    ProcessRunner_TmpStderr="$CURRENT_RUN_STDERR_FILE"

    # Keep ProcessRunner's protocol line out of AgentExecutor's JSON result.
    local_runner_result="$(ProcessRunner.run \
        --timeout "$remaining_timeout" \
        --idle-timeout "$AGENT_IDLE_TIMEOUT" \
        --idle-jsonl-file "$CURRENT_RUN_STDOUT_FILE" \
        --idle-tool-timeout "$AGENT_TOOL_IDLE_TIMEOUT" \
        --idle-step-timeout "$AGENT_STEP_IDLE_TIMEOUT" \
        --cwd "$OPT_WORKSPACE" \
        -- env -u PYTHONHOME "PYTHONPATH=$OPT_WORKSPACE/src:$OPT_WORKSPACE" "$OPENCODE_BIN" run \
            "${AUTO_ARGS[@]}" \
            "${SESSION_ARGS[@]}" \
            "${AGENT_ARGS[@]}" \
            --format json \
            --dir "$OPT_WORKSPACE" \
            < "$CURRENT_RUN_PROMPT_FILE")"
    pr_rc=$?
    runner_timeout_reason="$(printf '%s\n' "$local_runner_result" | head -n 1 | cut -d'|' -f5)"
    if [ "$runner_timeout_reason" = "tool_idle_timeout" ]; then
        tool_idle_timeout_detected="true"
        error_type="AGENT_TOOL_NO_PROGRESS_TIMEOUT"
        log "active-tool watchdog fired task=$OPT_TASK_ID attempt=$OPT_ATTEMPT threshold=${AGENT_TOOL_IDLE_TIMEOUT}s; JSONL/stderr artifacts retained"
    elif [ "$runner_timeout_reason" = "step_idle_timeout" ]; then
        step_idle_timeout_detected="true"
        error_type="AGENT_STEP_NO_PROGRESS_TIMEOUT"
        log "active-step watchdog fired task=$OPT_TASK_ID attempt=$OPT_ATTEMPT threshold=${AGENT_STEP_IDLE_TIMEOUT}s; JSONL/stderr artifacts retained"
    elif [ "$runner_timeout_reason" = "idle_timeout" ]; then
        idle_timeout_detected="true"
        error_type="AGENT_NO_PROGRESS_TIMEOUT"
        log "no-progress watchdog fired task=$OPT_TASK_ID attempt=$OPT_ATTEMPT threshold=${AGENT_IDLE_TIMEOUT}s; JSONL/stderr artifacts retained"
    fi

    if [ -s "$CURRENT_RUN_STDOUT_FILE" ]; then
        cat "$CURRENT_RUN_STDOUT_FILE" >>"$RAW_STDOUT_FILE"
    fi
    current_stderr_error_message=""
    if [ -s "$CURRENT_RUN_STDERR_FILE" ]; then
        current_stderr_error_message="$(grep -Eio '.*(permission requested|auto-rejecting|error|failed|denied|refused|timeout).*' "$CURRENT_RUN_STDERR_FILE" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]\+$//' || true)"
        cat "$CURRENT_RUN_STDERR_FILE" >>"$OPT_STDERR_FILE"
    fi

    current_session_id=""
    if [ -s "$CURRENT_RUN_STDOUT_FILE" ]; then
        current_session_id="$(jq -Rr 'try fromjson catch empty | .sessionID // empty' "$CURRENT_RUN_STDOUT_FILE" 2>/dev/null | awk 'length { value=$0 } END { print value }')"
    fi
    if [ -n "$current_session_id" ]; then
        session_id="$current_session_id"
    fi

    current_step_limit_detected="false"
    # A step limit is a runtime control signal only when it comes from a
    # structured error event. Text events and tool payloads are task content
    # and may mention "maximum steps" without exhausting the runtime budget.
    current_step_limit_message=""
    if [ -s "$CURRENT_RUN_STDOUT_FILE" ]; then
        current_step_limit_message="$(jq -Rr '
            try fromjson catch empty
            | select(.type == "error")
            | (.error.message // .error.data.message // .message // empty)
        ' "$CURRENT_RUN_STDOUT_FILE" 2>/dev/null |
            grep -Ei 'max(imum)?[[:space:]_-]+steps|steps?[[:space:]_-]+limit|step[[:space:]_-]+limit' |
            head -n 1 || true)"
    fi
    if [ "$pr_rc" -ne 124 ] && [ -n "$current_step_limit_message" ]; then
        current_step_limit_detected="true"
    fi
    final_step_limit_detected="$current_step_limit_detected"

    current_text_events=""
    if [ -s "$CURRENT_RUN_STDOUT_FILE" ]; then
        current_text_events="$(jq -Rr 'try fromjson catch empty | select(.type == "text") | (.part.text // .text // empty)' "$CURRENT_RUN_STDOUT_FILE" 2>/dev/null || true)"
    fi
    current_has_control_marker="false"
    if printf '%s\n' "$current_text_events" | grep -qE '^TASK_DONE([[:space:]]|$)|^TASK_FAILED([[:space:]:]|$)|^TASK_NEEDS_USER_BEGIN([[:space:]]|$)|^TASK_NEEDS_USER_END([[:space:]]|$)'; then
        current_has_control_marker="true"
    fi

    current_permission_blocked="false"
    if [ -s "$CURRENT_RUN_STDOUT_FILE" ] && \
       jq -s -e 'any(.[]; .type == "tool_use" and .part.state.status == "error" and ((.part.state.error // "" | tostring) | test("permission|rejected|auto-reject"; "i")))' \
          "$CURRENT_RUN_STDOUT_FILE" >/dev/null 2>&1; then
        current_permission_blocked="true"
    elif [ -s "$CURRENT_RUN_STDERR_FILE" ] && \
         grep -Eqi 'permission requested: [^;]+; auto-rejecting|permission denied|auto-rejecting' "$CURRENT_RUN_STDERR_FILE" 2>/dev/null; then
        current_permission_blocked="true"
    fi

    # A permission denial is not permission to bypass policy. If the runtime
    # exposed a resumable session and no task-control marker was emitted, allow
    # one same-session recovery turn so the agent can choose a different,
    # independent in-scope approach. The shared timeout budget still applies.
    if [ "$current_permission_blocked" = "true" ] &&
       [ "$current_has_control_marker" = "false" ] &&
       ! jq -s -e 'any(.[]; .type == "error" and ((.error.name // .error.type // "") as $t | $t != "" and ($t | test("permission|rejected|auto-reject"; "i") | not)))' "$CURRENT_RUN_STDOUT_FILE" >/dev/null 2>&1 &&
       [ "$pr_rc" -ne 124 ] &&
       [ "$idle_timeout_detected" = "false" ] &&
       [ -n "$session_id" ] &&
       [ "$permission_recovery_used" -lt 1 ]; then
        permission_recovery_used=$((permission_recovery_used + 1))
        permission_recovery_pending=true
        run_index=$((run_index + 1))
        log "permission denial detected; resuming the same session once with recovery guidance task=$OPT_TASK_ID attempt=$OPT_ATTEMPT"
        continue
    fi

    # Resume on a step limit only when the runtime exposes a session ID and
    # no completion/failure/user/permission event means we should stop.
    if [ "$current_step_limit_detected" = "true" ] &&
       [ -n "$session_id" ] &&
       [ "$internal_continuations_used" -lt "$STEP_LIMIT_CONTINUATIONS_MAX" ] &&
       [ "$current_has_control_marker" = "false" ] &&
       [ "$current_permission_blocked" = "false" ]; then
        internal_continuations_used=$((internal_continuations_used + 1))
        run_index=$((run_index + 1))
        log "OpenCode reached its step limit; resuming session internally ($internal_continuations_used/$STEP_LIMIT_CONTINUATIONS_MAX) for task=$OPT_TASK_ID attempt=$OPT_ATTEMPT session=$session_id"
        continue
    fi

    break
done

# Keep only the current run's raw artifacts until final classification is done.
# The aggregate attempt log remains the durable diagnostic artifact.
rm -f "$CURRENT_RUN_PROMPT_FILE" 2>/dev/null || true
: >"$OPT_STDOUT_FILE"
if [ -f "$RAW_STDOUT_FILE" ]; then
    jq -Rr 'try fromjson catch empty | select(.type == "text") | (.part.text // .text // empty)' \
        "$RAW_STDOUT_FILE" 2>/dev/null >>"$OPT_STDOUT_FILE" || true
fi

# OpenCode has had versions/environment combinations where text events are
# missing from normalized output. Recover markers only from actual text events:
# arbitrary raw JSONL may contain tokens in tool calls or documentation.
if [ -s "$RAW_STDOUT_FILE" ]; then
    normalized_text_events="$(jq -Rr '
        try fromjson catch empty
        | select(.type == "text")
        | (.part.text // .text // empty)
    ' "$RAW_STDOUT_FILE" 2>/dev/null || true)"

    for marker in TASK_DONE TASK_FAILED TASK_NEEDS_USER_BEGIN TASK_NEEDS_USER_END; do
        if ! grep -qE "^${marker}($|[[:space:]:])" "$OPT_STDOUT_FILE" 2>/dev/null; then
            marker_line="$(printf '%s\n' "$normalized_text_events" |
                grep -E "^${marker}($|[[:space:]:])" | head -n 1 || true)"
            if [ -n "$marker_line" ]; then
                printf '%s\n' "$marker_line" >>"$OPT_STDOUT_FILE"
            fi
        fi
    done
fi

duration="0"
if [ -s "$RAW_STDOUT_FILE" ]; then
    duration="$(awk 'BEGIN { start=0; end=0 } /"timestamp":/ {
        if (match($0, /"timestamp":[0-9]+/)) {
            v=substr($0, RSTART+12, RLENGTH-12)
            if (start == 0) start=v
            end=v
        }
    } END {
        if (start > 0 && end >= start) printf "%.3f", (end-start)/1000
    }' "$RAW_STDOUT_FILE" 2>/dev/null || true)"
fi
: "${duration:=0}"

_status="FAILED"
_exit_code="$pr_rc"
_summary=""

# Extract the most useful structured runtime diagnostics before interpreting the
# result. Keep the full JSONL file on disk; only a compact summary is surfaced
# in GitHub lifecycle comments.
error_message=""
error_type=""
error_source=""
last_event_type=""
if [ -s "$RAW_STDOUT_FILE" ]; then
    error_message="$(jq -Rr 'try fromjson catch empty | select(.type == "error") | (.error.message // .error.data.message // .message // empty)' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { print; exit }')"
    error_type="$(jq -Rr 'try fromjson catch empty | select(.type == "error") | (.error.name // .error.type // empty)' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { print; exit }')"
    last_event_type="$(jq -Rr 'try fromjson catch empty | .type // empty' "$RAW_STDOUT_FILE" 2>/dev/null | awk 'length { value=$0 } END { print value }')"
    if [ -n "$error_message" ]; then
        error_source="runtime_jsonl"
    fi
fi

# A tool call that the runtime itself rejected is not a recoverable continuation:
# the agent hit a hard permission boundary mid-run and exited without a completion
# marker. Surface it as an explicit recoverable failure so the daemon retries with
# a different approach instead of silently treating it as "session can continue".
permission_blocked=0
permission_operation=""
# After a permission-recovery continuation, historical denial events in the
# aggregate attempt log must not override the latest run's actual result.
PERMISSION_STDOUT_FILE="$RAW_STDOUT_FILE"
PERMISSION_STDERR_FILE="$OPT_STDERR_FILE"
if [ "$permission_recovery_used" -gt 0 ]; then
    PERMISSION_STDOUT_FILE="$CURRENT_RUN_STDOUT_FILE"
    PERMISSION_STDERR_FILE="$CURRENT_RUN_STDERR_FILE"
fi
permission_detail=""
permission_tool=""
# Extract a compact description of the denied operation, not the raw event.
# OpenCode event shapes differ across versions; avoid publishing arguments,
# prompt contents, or arbitrary event JSON to GitHub.
if [ -s "$PERMISSION_STDOUT_FILE" ]; then
    permission_event="$(jq -c '
      select(.type == "tool_use")
      | select(.part.state.status == "error")
      | select((.part.state.error // "") | tostring | test("permission|rejected|auto-reject"; "i"))
    ' "$PERMISSION_STDOUT_FILE" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$permission_event" ]; then
        permission_blocked=1
        permission_tool="$(printf '%s' "$permission_event" | jq -r '.part.tool // .part.name // .part.state.tool // .tool // empty' 2>/dev/null)"
        permission_tool="$(printf '%s' "$permission_tool" | tr '\n\r' '  ' | cut -c1-80)"
        permission_detail="$(printf '%s' "$permission_event" | jq -r '.part.state.error // .part.error // .error // empty' 2>/dev/null)"
        permission_detail="$(printf '%s' "$permission_detail" | tr '\n\r' '  ' | sed -E 's/(Bearer|token|api[_ -]?key|password|secret)[=: ]+[^ ]+/\1=[REDACTED]/Ig' | cut -c1-300)"
        permission_operation="$(printf '%s' "$permission_detail" | sed -nE 's/.*permission requested: ([^;]+).*/\1/ip' | head -n1)"
    fi
fi
# Use stderr to enrich a generic structured permission rejection when the
# JSONL event omits the concrete target. Do not let incidental stderr text
# override a specific, structured non-permission error (for example, ProviderError).
stderr_permission_line=""
stderr_permission_operation=""
if [ -s "$PERMISSION_STDERR_FILE" ]; then
    stderr_permission_line="$(grep -Ei 'permission requested: [^;]+; auto-rejecting' "$PERMISSION_STDERR_FILE" 2>/dev/null | tail -n 1 | tr '\n\r' '  ' | cut -c1-400 || true)"
    if [ -n "$stderr_permission_line" ]; then
        stderr_permission_operation="$(printf '%s' "$stderr_permission_line" | sed -nE 's/.*permission requested: ([^;]+); auto-rejecting.*/\1/ip' | head -n 1)"
        if [ "$permission_blocked" -eq 0 ] && [ -z "$error_message" ]; then
            permission_blocked=1
        fi
        if [ "$permission_blocked" -eq 1 ]; then
            [ -n "$permission_operation" ] || permission_operation="$stderr_permission_operation"
            if [ -z "$permission_tool" ] && [ -n "$stderr_permission_operation" ]; then
                permission_tool="$(printf '%s' "$stderr_permission_operation" | awk '{print $1}')"
            fi
        fi
    fi
fi
if [ "$permission_blocked" -eq 1 ]; then
    # A bash permission target can contain the full shell command. Never
    # publish those tool arguments; retain only a recognizable Manul workspace
    # root where present so an out-of-scope workspace access is still actionable.
    if [ "$permission_tool" = "bash" ] || printf '%s' "$permission_operation" | grep -Eq '^bash([[:space:]]|\()'; then
        denied_workspace_path="$(printf '%s' "$permission_operation" | grep -oE '/[^[:space:];()&]*/\.manul/workspace/ws-[^/[:space:]();&]+' | head -n 1 || true)"
        if [ -n "$denied_workspace_path" ]; then
            permission_operation="bash (external workspace: $denied_workspace_path; command redacted)"
        else
            permission_operation="bash (command details redacted)"
        fi
        [ -n "$permission_tool" ] || permission_tool="bash"
    fi
    error_type="RUNTIME_PERMISSION_BLOCKED"
    error_source="runtime_jsonl"
    if [ -n "$permission_operation" ]; then
        error_message="Denied access: $permission_operation"
    elif [ -n "$permission_detail" ]; then
        error_message="$permission_detail"
    else
        error_message="OpenCode tool call rejected by runtime permission policy; operation details were not present in captured diagnostics"
    fi
    if [ -n "$permission_tool" ]; then
        error_message="$error_message (tool: $permission_tool)"
    fi
fi
# A prior denial is historical once the recovery invocation no longer reports
# a permission block. Use only the last invocation's stderr for fallback errors.
if [ "$permission_recovery_used" -gt 0 ] && [ "$current_permission_blocked" = "false" ] &&
   [ "$error_type" = "RUNTIME_PERMISSION_BLOCKED" ]; then
    permission_blocked=0
    permission_operation=""
    permission_detail=""
    permission_tool=""
    error_type=""
    error_source=""
    error_message=""
fi

if [ -z "$error_message" ] && [ -n "$current_stderr_error_message" ]; then
    error_message="$current_stderr_error_message"
    if [ -n "$error_message" ]; then
        error_source="stderr"
        if printf "%s" "$error_message" | grep -Eqi 'permission requested|auto-rejecting|permission denied|denied'; then
            error_type="PermissionError"
        fi
    fi
fi

if [ "$tool_idle_timeout_detected" = "true" ]; then
    _status="TIMEOUT"
    _summary="OpenCode tool call remained active without completion for ${AGENT_TOOL_IDLE_TIMEOUT}s; tool watchdog terminated the runtime"
    error_type="AGENT_TOOL_NO_PROGRESS_TIMEOUT"
    error_message="An OpenCode JSONL tool_use event remained active for ${AGENT_TOOL_IDLE_TIMEOUT}s without completion; isolated runtime process group was terminated"
elif [ "$step_idle_timeout_detected" = "true" ]; then
    _status="TIMEOUT"
    _summary="OpenCode step remained unfinished without JSONL output for ${AGENT_STEP_IDLE_TIMEOUT}s; active-step watchdog terminated the runtime"
    error_type="AGENT_STEP_NO_PROGRESS_TIMEOUT"
    error_message="A JSONL step_start event had no corresponding step_finish or further output for ${AGENT_STEP_IDLE_TIMEOUT}s; isolated runtime process group was terminated"
elif [ "$idle_timeout_detected" = "true" ]; then
    _status="TIMEOUT"
    _summary="OpenCode made no stdout/stderr or recognized active JSONL step/tool progress for ${AGENT_IDLE_TIMEOUT}s; no-progress watchdog terminated the runtime"
    error_type="AGENT_NO_PROGRESS_TIMEOUT"
    error_message="No stdout/stderr or active-tool JSONL progress for ${AGENT_IDLE_TIMEOUT}s; isolated runtime process group was terminated"
elif [ "$pr_rc" -eq 124 ]; then
    _status="TIMEOUT"
    _summary="OpenCode execution timed out after ${AGENT_TIMEOUT}s"
elif grep -qE '^TASK_NEEDS_USER_BEGIN([[:space:]]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="BLOCKED"
    _exit_code=0
    _summary="OpenCode agent needs user input"
elif grep -qE '^TASK_FAILED([[:space:]:]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    _status="FAILED"
    _summary="OpenCode agent reported TASK_FAILED"
elif grep -qE '^TASK_DONE([[:space:]]|$)' "$OPT_STDOUT_FILE" 2>/dev/null; then
    if [ "$pr_rc" -eq 0 ]; then
        _status="COMPLETED"
        _exit_code=0
        _summary="$(grep -oP '(?<=^TASK_DONE\s).+' "$OPT_STDOUT_FILE" 2>/dev/null | head -1 || true)"
        : "${_summary:=Agent completed}"
    else
        _status="FAILED"
        _summary="OpenCode emitted TASK_DONE but exited with code $pr_rc"
    fi
elif [ "$permission_blocked" -eq 1 ]; then
    _status="FAILED"
    _exit_code=1
    _summary="OpenCode permission policy rejected a tool call; the agent could not complete the task as instructed"
    [ -n "$error_message" ] && _summary+="; diagnostic=$error_message"
else
    step_limit_detected="$final_step_limit_detected"

    if [ -n "$session_id" ] && [ "$step_limit_detected" = "true" ]; then
        # Only an explicit runtime step-limit condition is a continuation.
        # A normal step_finish(reason=stop) without TASK_DONE is a real protocol
        # failure and must not consume the same session three times.
        _status="NEEDS_CONTINUATION"
        _exit_code=1
        _summary="OpenCode reached its step limit without a completion marker; existing session can continue"
    elif [ "$pr_rc" -eq 0 ] && [ -n "$session_id" ]; then
        _status="FAILED"
        _exit_code=1
        _summary="OpenCode stopped without a completion marker; starting a fresh retry is required"
        error_type="RUNTIME_FAILURE"
    else
        _status="FAILED"
        if [ "$pr_rc" -eq 127 ]; then
            _summary="OpenCode binary not found"
        else
            _summary="OpenCode agent exited with code $pr_rc"
            [ -n "$error_type" ] && _summary+="; error_type=$error_type"
            [ -n "$error_message" ] && _summary+="; error=$error_message"
            [ -n "$error_source" ] && _summary+="; error_source=$error_source"
            _summary+="; duration_s=$duration"
            [ -n "$session_id" ] && _summary+="; session=$session_id"
            [ -n "$last_event_type" ] && _summary+="; last_event=$last_event_type"
        fi
    fi
fi
# Keep RAW_STDOUT_FILE; Manul task retention is responsible for cleanup.

# Derive a stable, machine-readable failure code from the classified status so
# the daemon and controller can act on the specific failure mode instead of only
# on the generic FAILED status.
failure_code=""
case "$_status" in
    FAILED)
        case "$error_type" in
            RUNTIME_PERMISSION_BLOCKED) failure_code="RUNTIME_PERMISSION_BLOCKED" ;;
            PermissionError)           failure_code="RUNTIME_PERMISSION_BLOCKED" ;;
            ProviderError)             failure_code="PROVIDER_ERROR" ;;
            *)                         failure_code="RUNTIME_FAILURE" ;;
        esac
        ;;
    TIMEOUT)
        if [ "$tool_idle_timeout_detected" = "true" ]; then
            failure_code="AGENT_TOOL_NO_PROGRESS_TIMEOUT"
        elif [ "$step_idle_timeout_detected" = "true" ]; then
            failure_code="AGENT_STEP_NO_PROGRESS_TIMEOUT"
        elif [ "$idle_timeout_detected" = "true" ]; then
            failure_code="AGENT_NO_PROGRESS_TIMEOUT"
        else
            failure_code="RUNTIME_TIMEOUT"
        fi
        ;;
    BLOCKED)            failure_code="TASK_NEEDS_USER" ;;
    NEEDS_CONTINUATION) failure_code="NEEDS_CONTINUATION" ;;
    COMPLETED)          failure_code="" ;;
esac

jq -cn \
    --arg status "$_status" \
    --arg task_id "$OPT_TASK_ID" \
    --arg exit_code "$_exit_code" \
    --arg summary "$_summary" \
    --arg session_id "$session_id" \
    --arg duration_s "$duration" \
    --arg runtime "opencode" \
    --arg error_type "$error_type" \
    --arg error_message "$error_message" \
    --arg error_source "$error_source" \
    --arg last_event_type "$last_event_type" \
    --arg failure_code "$failure_code" \
    --arg raw_log "$RAW_STDOUT_FILE" \
    --arg permission_tool "$permission_tool" \
    --arg permission_operation "$permission_operation" \
    --arg permission_recovery_used "$permission_recovery_used" \
    --arg selected_agent "$OPT_AGENT" \
    '{status:$status, task_id:$task_id, exit_code:($exit_code|tonumber), summary:$summary, session_id:$session_id, duration_s:($duration_s|tonumber), runtime:$runtime, failure_code:$failure_code, diagnostics:{error_type:$error_type,error_message:$error_message,error_source:$error_source,last_event_type:$last_event_type,permission_tool:$permission_tool,permission_operation:$permission_operation,permission_recovery_used:($permission_recovery_used|tonumber),selected_agent:$selected_agent,raw_log:$raw_log}}'

rm -f "$CURRENT_RUN_STDOUT_FILE" "$CURRENT_RUN_STDERR_FILE" "$CURRENT_RUN_PROMPT_FILE" 2>/dev/null || true

if [ "$_status" = "BLOCKED" ]; then
    exit 0
fi
exit "$_exit_code"
