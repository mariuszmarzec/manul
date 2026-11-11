#!/usr/bin/env bash
# opencode-adapter.sh — OpenCode runtime adapter for AgentExecutor.
#
# Independent backend: it does not import, invoke, or configure OpenClaw.
# Uses the documented OpenCode 2.x non-interactive CLI:
#   opencode run [message...] --format json
# ProcessRunner changes to the exact task workspace before launching OpenCode;
# OpenCode 2.x does not accept --dir on the run subcommand.
# Saved sessions are resumed with:
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
unset TODO_LOCAL_MCP_TOKEN

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
OPT_PREFLIGHT_ONLY=false

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
        --preflight-only) OPT_PREFLIGHT_ONLY=true; shift ;;
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
AUTO_ARGS=()
if [ "$OPT_AUTO" = "true" ]; then
    AUTO_ARGS=(--auto)
fi

RAW_STDOUT_FILE="$(manul_task_file_path "${MANUL_TASK_LOG_DIR:-$(dirname "$OPT_STDOUT_FILE")}" "$OPT_TASK_ID" "attempt-${OPT_ATTEMPT}.opencode.jsonl")"
RAW_STDERR_FILE="$(manul_task_file_path "${MANUL_TASK_LOG_DIR:-$(dirname "$OPT_STDERR_FILE")}" "$OPT_TASK_ID" "attempt-${OPT_ATTEMPT}.opencode.stderr")"
CURRENT_RUN_STDOUT_FILE="${RAW_STDOUT_FILE%.jsonl}.current.jsonl"
CURRENT_RUN_STDERR_FILE="${RAW_STDOUT_FILE%.jsonl}.current.stderr"
CURRENT_RUN_PROMPT_FILE="${RAW_STDOUT_FILE%.jsonl}.current.prompt"
# Aggregate all runtime events from the initial call and same-session resumes.
mkdir -p "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" "$(dirname "$RAW_STDOUT_FILE")" "$(dirname "$RAW_STDERR_FILE")" 2>/dev/null || true

log() {
    echo "[$(date -Is)] opencode-adapter: $*" >>"$OPT_STDERR_FILE"
}

append_redacted_stderr() {
    local source_file="$1"
    [ -s "$source_file" ] || return 0
    python3 - "$source_file" "$RAW_STDERR_FILE" <<'PY'
import os
import re
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
try:
    content = source_path.read_text(errors="replace")
except OSError as exc:
    print(f"<unable to read stderr artifact: {exc.__class__.__name__}>")
    raise SystemExit(0)

# Redact values injected through secret-bearing environment variables before
# retaining a durable copy of runtime stderr.
for name, value in os.environ.items():
    if value and re.search(r"(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|PAT|CREDENTIAL|AUTH)", name, re.I):
        content = content.replace(value, "[REDACTED]")
content = re.sub(r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+", r"\1[REDACTED]", content)
content = re.sub(r"(?i)([?&](?:access_token|token|api[_-]?key|secret|password)=)[^&\s]+", r"\1[REDACTED]", content)
content = re.sub(r'(?i)(\b(?:access_token|token|api[_-]?key|secret|password)\b\s*[:=]\s*)["\']?[^"\s,;}&]+', r"\1[REDACTED]", content)
content = re.sub(r"(?i)(https?://)[^/@\s]+:[^/@\s]+@", r"\1[REDACTED]@", content)
try:
    with target_path.open("a") as output:
        output.write(content)
except OSError as exc:
    print(f"<unable to retain redacted stderr: {exc.__class__.__name__}>")
PY
}


# OpenCode reads the operator's JSON/JSONC files itself. Manul contributes
# only a temporary runtime overlay through OPENCODE_CONFIG_CONTENT; it never
# replaces OPENCODE_CONFIG or writes to an operator-owned configuration file.
OPENCODE_TASK_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/manul-opencode-config.XXXXXX")" || exit 1
cleanup_opencode_task_config() {
    if [ -n "${OPENCODE_TASK_CONFIG_DIR:-}" ]; then
        rm -rf -- "$OPENCODE_TASK_CONFIG_DIR"
        OPENCODE_TASK_CONFIG_DIR=""
    fi
}
trap cleanup_opencode_task_config EXIT HUP INT TERM

# Respect custom JSON or JSONC paths. If no explicit config was supplied,
# recognise either default filename; OpenCode remains responsible for loading it.
_OPENCODE_BASE_CONFIG="${OPENCODE_CONFIG:-}"
if [ -z "$_OPENCODE_BASE_CONFIG" ]; then
    for _candidate in "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"; do
        if [ -f "$_candidate" ]; then _OPENCODE_BASE_CONFIG="$_candidate"; break; fi
    done
fi
_TASK_WORKSPACE_ROOT_INPUT="${MANUL_TASK_WORKSPACE_ROOT:-}"
_TASK_WORKDIR_INPUT="${MANUL_TASK_WORKDIR:-}"
_TASK_EXECUTION_KIND_INPUT="${MANUL_TASK_EXECUTION_KIND:-repository}"
_workspace_real=""
_workdir_real=""
# Runner-supplied paths are authoritative. Validate them before starting the
# model so a stale/wrong home prefix cannot turn into a permission retry loop.
if [ -n "$_TASK_WORKSPACE_ROOT_INPUT" ] || [ -n "$_OPENCODE_BASE_CONFIG" ]; then
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
    if [ "$_TASK_EXECUTION_KIND_INPUT" = "report_only" ]; then
        _report_only_root="$_workspace_base_real/report-only"
        _report_only_root_real=""
        if [ ! -L "$_report_only_root" ] && [ -d "$_report_only_root" ]; then
            _report_only_root_real="$(realpath -e -- "$_report_only_root" 2>/dev/null || true)"
        fi
        if [ -z "$_report_only_root_real" ] ||
           [ "$_report_only_root_real" != "$_report_only_root" ] ||
           [ "$_workspace_parent" != "$_report_only_root_real" ] ||
           [[ "$_workspace_name" != ws-* ]]; then
            printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Runner-assigned report-only workspace is not a direct scratch directory under MANUL_WORKSPACE/report-only","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
            exit 66
        fi
    elif [ "$_TASK_EXECUTION_KIND_INPUT" = "operator_query" ]; then
        _operator_query_root="$_workspace_base_real/operator-query"
        _operator_query_root_real=""
        if [ ! -L "$_operator_query_root" ] && [ -d "$_operator_query_root" ]; then
            _operator_query_root_real="$(realpath -e -- "$_operator_query_root" 2>/dev/null || true)"
        fi
        if [ -z "$_operator_query_root_real" ] ||
           [ "$_operator_query_root_real" != "$_operator_query_root" ] ||
           [ "$_workspace_parent" != "$_operator_query_root_real" ] ||
           [[ "$_workspace_name" != oq-* ]]; then
            printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Runner-assigned operator query workspace is not a direct scratch directory under MANUL_WORKSPACE/operator-query","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
            exit 66
        fi
    elif [ "$_workspace_parent" != "$_workspace_base_real" ] || [[ "$_workspace_name" != ws-* ]]; then
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
if [ -z "$_workspace_real" ] || [ ! -d "$_workspace_real" ]; then
    printf '{"status":"FAILED","task_id":"%s","exit_code":66,"summary":"Cannot resolve OpenCode task workspace","session_id":"","duration_s":0}\n' "$OPT_TASK_ID"
    exit 66
fi
if [ -z "${_workspace_base_real:-}" ]; then
    _workspace_base_real="$(realpath -m -- "$MANUL_WORKSPACE")"
fi
export MANUL_TASK_WORKSPACE_ROOT="$_workspace_real"
if [ -n "$_workdir_real" ]; then export MANUL_TASK_WORKDIR="$_workdir_real"; fi

# A daemon can outlive the aicode launcher. Refresh Manul's dedicated Fiteo
# identity from the runtime-owned environment file for each task. This is
# independent of the operator's own Fiteo MCP and PAT.
_FITEO_RUNTIME_ENV_FILE="$MANUL_DIR/.env"
if [ -f "$_FITEO_RUNTIME_ENV_FILE" ]; then
    _fiteo_runtime_values="$(bash -c 'set -e; . "$1" >/dev/null 2>&1; printf "%s|%s|%s" "${FITEO_BASE_URL:-}" "${FITEO_MANUL_PAT:-}" "${FITEO_MANUL_SHARE_USER_ID:-}"' _ "$_FITEO_RUNTIME_ENV_FILE" 2>/dev/null)" || _fiteo_runtime_values=""
    IFS="|" read -r _fiteo_runtime_base_url _fiteo_runtime_pat _fiteo_runtime_share_user_id <<< "$_fiteo_runtime_values"
    if [ -n "$_fiteo_runtime_base_url" ] && [ -n "$_fiteo_runtime_pat" ]; then
        FITEO_BASE_URL="$_fiteo_runtime_base_url"
        FITEO_MANUL_PAT="$_fiteo_runtime_pat"
        export FITEO_BASE_URL FITEO_MANUL_PAT
        if [[ "$_fiteo_runtime_share_user_id" =~ ^[1-9][0-9]*$ ]]; then
            FITEO_MANUL_SHARE_USER_ID="$_fiteo_runtime_share_user_id"
            export FITEO_MANUL_SHARE_USER_ID
        fi
    else
        unset FITEO_BASE_URL FITEO_MANUL_PAT 2>/dev/null || true
    fi
fi

TODO_LOCAL_MCP_AVAILABLE=0
TODO_LOCAL_MCP_CONNECTED=0
unset TODO_LOCAL_MCP_URL
# Standalone Manul owns the local Todo transport. Environment overrides remain
# useful for isolated fixtures, but normal installs resolve both helpers from
# Manul's own runtime directory and never require globalskills/aicode.
TODO_LOCAL_MCP_URL_HELPER="${TODO_LOCAL_MCP_URL_HELPER:-$MANUL_DIR/todo-local-mcp-url.sh}"
TODO_MCP_CLIENT="${TODO_MCP_CLIENT:-$MANUL_DIR/todo-mcp-client.py}"
if [ -r "$TODO_LOCAL_MCP_URL_HELPER" ] &&
   [ -r "$TODO_MCP_CLIENT" ] &&
   command -v python3 >/dev/null 2>&1; then
    if ! declare -F todo_local_mcp_resolve_url >/dev/null 2>&1; then
        source "$TODO_LOCAL_MCP_URL_HELPER" || true
    fi
    if declare -F todo_local_mcp_resolve_url >/dev/null 2>&1; then
        _todo_local_resolved_url="$(todo_local_mcp_resolve_url "")" || _todo_local_resolved_url=""
        if [ -n "$_todo_local_resolved_url" ]; then
            TODO_LOCAL_MCP_URL="$_todo_local_resolved_url"
            TODO_LOCAL_MCP_AVAILABLE=1
            TODO_LOCAL_MCP_CONNECTED=1
            log "Manul local Todo MCP handshake succeeded; adding optional Manul Todo MCP"
        else
            log "Todo local MCP is unavailable; continuing without this optional MCP"
        fi
    else
        log "Manul Todo endpoint helper has no resolver; continuing without optional Todo MCP"
    fi
else
    log "ERROR: Manul Todo MCP client/resolver is missing or Python 3 is unavailable; continuing without optional Todo MCP"
fi
export TODO_LOCAL_MCP_URL TODO_LOCAL_MCP_AVAILABLE TODO_LOCAL_MCP_CONNECTED

# Inspect known operator config layers read-only before using Manul-owned MCP
# names. If any existing file is malformed, skip optional injection rather
# than risk shadowing an MCP entry whose name could not be inspected.
_OVERLAY_JSON_FILE="$OPENCODE_TASK_CONFIG_DIR/opencode-manul-overlay.json"
_OPENCODE_SCAN_ROOT="${_workdir_real:-$_workspace_real}"
_OVERLAY_ERROR_FILE="$OPENCODE_TASK_CONFIG_DIR/overlay.stderr"
if ! env -u PYTHONHOME -u PYTHONPATH python3 - "$_OVERLAY_JSON_FILE" "$_workspace_real" "$_workspace_base_real" \
    "${FITEO_BASE_URL:-}" "${FITEO_MANUL_PAT:-}" "${TODO_LOCAL_MCP_URL:-}" \
    "${OPENCODE_CONFIG:-}" "${OPENCODE_CONFIG_DIR:-}" "$HOME" "${XDG_CONFIG_HOME:-$HOME/.config}" \
    "$_OPENCODE_SCAN_ROOT" "${OPENCODE_CONFIG_CONTENT:-}" "$_TASK_EXECUTION_KIND_INPUT" 2>"$_OVERLAY_ERROR_FILE" <<'PY_MANUL_OVERLAY'
import fnmatch
import json
import os
import re
import sys
from pathlib import Path

output, workspace, workspace_base, fiteo_url, fiteo_pat, todo_url, custom_config, custom_dir, home, xdg_home, project_root, inline_content, execution_kind = sys.argv[1:]

def parse_jsonc(text):
    # Remove line/block comments while preserving strings and newlines.
    cleaned = []
    i = 0
    in_string = False
    escaped = False
    line_comment = False
    block_comment = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
                cleaned.append(ch)
            else:
                cleaned.append(" ")
        elif block_comment:
            if ch == "*" and nxt == "/":
                cleaned.extend("  ")
                i += 1
                block_comment = False
            else:
                cleaned.append("\n" if ch == "\n" else " ")
        elif in_string:
            cleaned.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            cleaned.append(ch)
        elif ch == "/" and nxt == "/":
            cleaned.extend("  ")
            i += 1
            line_comment = True
        elif ch == "/" and nxt == "*":
            cleaned.extend("  ")
            i += 1
            block_comment = True
        else:
            cleaned.append(ch)
        i += 1
    if in_string or block_comment:
        raise ValueError("unterminated JSONC string/comment")

    # Strip trailing commas outside quoted strings.
    source = "".join(cleaned)
    result = []
    i = 0
    in_string = False
    escaped = False
    while i < len(source):
        ch = source[i]
        if in_string:
            result.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
        elif ch == '"':
            in_string = True
            result.append(ch)
        elif ch == ",":
            j = i + 1
            while j < len(source) and source[j].isspace():
                j += 1
            if j < len(source) and source[j] in "]}":
                pass
            else:
                result.append(ch)
        else:
            result.append(ch)
        i += 1
    return json.loads("".join(result))

def deep_merge(left, right):
    if isinstance(left, dict) and isinstance(right, dict):
        out = dict(left)
        for key, value in right.items():
            out[key] = deep_merge(out[key], value) if key in out else value
        return out
    if isinstance(left, list) and isinstance(right, list):
        return left + right
    return right

global_config_dir = Path(xdg_home) / "opencode"
paths = [
    global_config_dir / "config.json",
    global_config_dir / "opencode.json",
    global_config_dir / "opencode.jsonc",
    Path(home) / ".config/opencode/config.json",
    Path(home) / ".config/opencode/opencode.json",
    Path(home) / ".config/opencode/opencode.jsonc",
]
if custom_config:
    paths.append(Path(custom_config))
paths.extend([
    Path(project_root) / "opencode.json",
    Path(project_root) / "opencode.jsonc",
    Path(project_root) / ".opencode/opencode.json",
    Path(project_root) / ".opencode/opencode.jsonc",
    Path(home) / ".opencode/opencode.json",
    Path(home) / ".opencode/opencode.jsonc",
    Path(home) / "Library/Application Support/opencode/config.json",
    Path(home) / "Library/Application Support/opencode/opencode.json",
    Path(home) / "Library/Application Support/opencode/opencode.jsonc",
])
if custom_dir:
    paths.extend([Path(custom_dir) / "config.json", Path(custom_dir) / "opencode.json", Path(custom_dir) / "opencode.jsonc"])
managed_paths = {
    Path("/etc/opencode/config.json"),
    Path("/etc/opencode/opencode.json"),
    Path("/etc/opencode/opencode.jsonc"),
    Path("/Library/Application Support/opencode/config.json"),
    Path("/Library/Application Support/opencode/opencode.json"),
    Path("/Library/Application Support/opencode/opencode.jsonc"),
}
paths.extend(managed_paths)

def canonical_action(action):
    return {"bash": "shell", "task": "subagent", "write": "edit", "patch": "edit"}.get(action, action)

def collect_legacy_permission_rules(obj):
    rules = []
    legacy = obj.get("permission")
    if isinstance(legacy, dict):
        for action, value in legacy.items():
            action = canonical_action(action)
            if isinstance(value, str):
                rules.append({"action": action, "resource": "*", "effect": value})
            elif isinstance(value, dict):
                for resource, effect in value.items():
                    if isinstance(effect, str):
                        rules.append({"action": action, "resource": resource, "effect": effect})
    return rules

def collect_permission_rules(obj):
    rules = collect_legacy_permission_rules(obj)
    native = obj.get("permissions")
    if isinstance(native, list):
        for rule in native:
            if isinstance(rule, dict) and all(key in rule for key in ("action", "resource", "effect")):
                rules.append(rule)
    return rules

names = set()
agent_names = set()
tool_rule_patterns = set()
operator_permissions = []
scan_ok = True
managed_permission_policy = False
for path in dict.fromkeys(paths):
    if not path.is_file():
        continue
    try:
        obj = parse_jsonc(path.read_text(encoding="utf-8"))
    except Exception as exc:
        scan_ok = False
        print(f"could not inspect OpenCode config {path}: {exc}", file=sys.stderr)
        continue
    if not isinstance(obj, dict):
        scan_ok = False
        print(f"OpenCode config {path} is not a JSON object", file=sys.stderr)
        continue
    # Existing tool selectors are operator policy too. The overlay may add
    # its wildcard only when no existing rule already matches that concrete
    # tool name; this preserves both explicit allows and explicit denials.
    tools_obj = obj.get("tools")
    if isinstance(tools_obj, dict):
        tool_rule_patterns.update(k for k, v in tools_obj.items() if isinstance(k, str))

    agents_obj = obj.get("agent") or {}
    if isinstance(agents_obj, dict):
        agent_names.update(agents_obj.keys())
    mcp = obj.get("mcp") or {}
    if isinstance(mcp, dict):
        servers = mcp.get("servers")
        if isinstance(servers, dict):
            names.update(servers.keys())
        # Older Manul/OpenCode configs may still use named entries directly
        # under mcp. Treat them as occupied too.
        names.update(k for k, v in mcp.items() if k not in {"servers", "timeout"} and isinstance(v, dict))
    # Managed settings are applied by OpenCode after inline config and must
    # retain their higher priority. They may intentionally deny task access;
    # do not override or silently discard an administrator permission policy.
    if path in managed_paths:
        if "permissions" in obj or "permission" in obj:
            managed_permission_policy = True
    else:
        operator_permissions.extend(collect_permission_rules(obj))

existing_inline = {}
if inline_content:
    try:
        parsed = parse_jsonc(inline_content)
        if isinstance(parsed, dict):
            existing_inline = parsed
            tools_obj = parsed.get("tools")
            if isinstance(tools_obj, dict):
                tool_rule_patterns.update(k for k, v in tools_obj.items() if isinstance(k, str))
            agents_obj = parsed.get("agent") or {}
            if isinstance(agents_obj, dict):
                agent_names.update(agents_obj.keys())
            mcp = parsed.get("mcp") or {}
            if isinstance(mcp, dict) and isinstance(mcp.get("servers"), dict):
                names.update(mcp["servers"].keys())
            operator_permissions.extend(collect_legacy_permission_rules(parsed))
    except Exception as exc:
        print(f"invalid inherited OPENCODE_CONFIG_CONTENT: {exc}", file=sys.stderr)
        raise SystemExit(2)

# If a local config layer cannot be parsed, fail rather than replacing an
# operator permission array we could not preserve.
if not scan_ok:
    raise SystemExit(2)
if managed_permission_policy:
    print("managed OpenCode permission policy is present; refusing to override administrator rules with a task overlay", file=sys.stderr)
    raise SystemExit(2)

# Keep stable, Manul-specific names. Any collision means the operator owns the
# existing entry; never replace it with Manul's credentials or endpoint.
servers = {}
permissions = operator_permissions + [
    {"action": "external_directory", "resource": workspace_base.rstrip("/") + "/*", "effect": "deny"},
    {"action": "external_directory", "resource": workspace, "effect": "allow"},
    {"action": "external_directory", "resource": workspace.rstrip("/") + "/*", "effect": "allow"},
]
# Never permit the raw operator Fiteo create tool inside a Manul task.
# Task creation is only available through the dedicated Manul-authenticated
# MCP connection below; the user's global Fiteo server remains untouched.
if execution_kind == "operator_query":
    # No optional Manul MCP is injected for this turn, even if the daemon
    # inherited credentials/endpoints from its long-lived environment.
    fiteo_url = ""
    fiteo_pat = ""
    todo_url = ""

operator_agent_config = {}
if execution_kind == "operator_query":
    operator_agent_name = "manul-operator-query"
    if operator_agent_name in agent_names:
        print("reserved OpenCode agent 'manul-operator-query' already exists; refusing operator query to preserve isolation", file=sys.stderr)
        raise SystemExit(2)
    operator_agent_config = {
        operator_agent_name: {
            "mode": "primary",
            "description": "Tool-free Manul operator query. Answer only from the supplied snapshot.",
            "tools": {"*": False},
        }
    }
    tools = {pattern: False for pattern in tool_rule_patterns}
    tools["*"] = False
else:
    tools = {"fiteo_todo_create_task": False}
if fiteo_url and fiteo_pat:
    if "manul-fiteo" in names:
        print("operator MCP 'manul-fiteo' already exists; disabling that reserved tool namespace for this task", file=sys.stderr)
        tools["manul_fiteo_*"] = False
    elif any(fnmatch.fnmatchcase("manul_fiteo_todo_create_task", pattern) for pattern in tool_rule_patterns):
        print("an operator tool rule already matches the Manul Fiteo tool; preserving it without adding an override", file=sys.stderr)
        servers["manul-fiteo"] = {
            "type": "remote",
            "url": "{env:FITEO_BASE_URL}/mcp",
            "oauth": False,
            "disabled": False,
            "headers": {"Authorization": "Bearer {env:FITEO_MANUL_PAT}"},
        }
        permissions.append({"action": "manul_fiteo_*", "resource": "*", "effect": "allow"})
    elif scan_ok:
        servers["manul-fiteo"] = {
            "type": "remote",
            "url": "{env:FITEO_BASE_URL}/mcp",
            "oauth": False,
            "disabled": False,
            "headers": {"Authorization": "Bearer {env:FITEO_MANUL_PAT}"},
        }
        permissions.append({"action": "manul_fiteo_*", "resource": "*", "effect": "allow"})
        tools["manul_fiteo_*"] = True
    else:
        print("could not safely inspect all OpenCode config layers; skipping optional Manul Fiteo MCP", file=sys.stderr)
if todo_url:
    if "manul-todo-local" in names:
        print("operator MCP 'manul-todo-local' already exists; leaving it untouched", file=sys.stderr)
    elif any(fnmatch.fnmatchcase("manul_todo_local_todo_list_tasks", pattern) for pattern in tool_rule_patterns):
        print("an operator tool rule already matches the Manul local Todo tools; preserving it without adding an override", file=sys.stderr)
        servers["manul-todo-local"] = {
            "type": "remote",
            "url": todo_url,
            "oauth": False,
            "disabled": False,
        }
        permissions.append({"action": "manul_todo_local_*", "resource": "*", "effect": "allow"})
    elif scan_ok:
        servers["manul-todo-local"] = {
            "type": "remote",
            "url": todo_url,
            "oauth": False,
            "disabled": False,
        }
        permissions.append({"action": "manul_todo_local_*", "resource": "*", "effect": "allow"})
        tools["manul_todo_local_*"] = True
    else:
        print("could not safely inspect all OpenCode config layers; skipping optional Manul Todo MCP", file=sys.stderr)

overlay = {
    "permissions": permissions,
}
if servers:
    overlay["mcp"] = {"servers": servers}
if operator_agent_config:
    overlay["agent"] = operator_agent_config
if tools:
    overlay["tools"] = tools
combined = deep_merge(existing_inline, overlay)
Path(output).write_text(json.dumps(combined, separators=(",", ":")) + "\n", encoding="utf-8")
PY_MANUL_OVERLAY
then
    _overlay_error="$(head -n 2 "$_OVERLAY_ERROR_FILE" 2>/dev/null | tr '\n' ' ' | cut -c 1-220)"
    [ -n "$_overlay_error" ] || _overlay_error="unknown overlay generation error"
    printf '%s\n' "OpenCode overlay generation failed: $_overlay_error" >> "$RAW_STDERR_FILE"
    log "unable to build safe JSONC-compatible OpenCode runtime overlay: $_overlay_error"
    jq -cn --arg task_id "$OPT_TASK_ID" --arg detail "$_overlay_error" \
      '{status:"FAILED",task_id:$task_id,exit_code:65,summary:("Unable to build task-scoped OpenCode runtime overlay: " + $detail),session_id:"",duration_s:0,failure_code:"PRE_EXECUTION_FAILURE",diagnostics:{stage:"task_config",agent_started:false}}'
    exit 65
fi
chmod 600 "$_OVERLAY_JSON_FILE"
OPENCODE_CONFIG_CONTENT="$(cat "$_OVERLAY_JSON_FILE")"
export OPENCODE_CONFIG_CONTENT
if [ "$_TASK_EXECUTION_KIND_INPUT" = "operator_query" ]; then
    # Keep variables defined for nounset-safe diagnostics below, but blank
    # their exported values so OpenCode cannot inherit operator credentials.
    FITEO_BASE_URL=""
    FITEO_MANUL_PAT=""
    FITEO_MANUL_SHARE_USER_ID=""
    TODO_LOCAL_MCP_URL=""
    TODO_LOCAL_MCP_AVAILABLE=""
    TODO_LOCAL_MCP_CONNECTED=""
    export FITEO_BASE_URL FITEO_MANUL_PAT FITEO_MANUL_SHARE_USER_ID TODO_LOCAL_MCP_URL
    export TODO_LOCAL_MCP_AVAILABLE TODO_LOCAL_MCP_CONNECTED
fi
log "using a temporary OpenCode runtime overlay; operator JSON/JSONC files and OPENCODE_CONFIG remain unchanged"

if [ -n "${FITEO_BASE_URL:-}" ] && [ -n "${FITEO_MANUL_PAT:-}" ]; then
    log "optional Manul Fiteo MCP is configured when its reserved server name is free"
fi
if [ "$TODO_LOCAL_MCP_AVAILABLE" = "1" ]; then
    log "optional Manul local Todo MCP is configured when its reserved server name is free"
fi

# The preflight contract checks that the selected OpenCode binary and the
# task-scoped config can start. Optional MCP servers never gate agent startup.
if [ "$OPT_PREFLIGHT_ONLY" = "true" ]; then
    jq -cn --arg task_id "$OPT_TASK_ID" \
        '{status:"READY",task_id:$task_id,exit_code:0,summary:"OpenCode runtime preflight passed",session_id:"",duration_s:0,runtime:"opencode",diagnostics:{stage:"runtime_preflight",agent_started:false}}'
    exit 0
fi

# Operator queries always use a reserved, task-local agent whose tool set is empty.
if [ "$_TASK_EXECUTION_KIND_INPUT" = "operator_query" ]; then
    OPT_AGENT="manul-operator-query"
fi

# A missing native OpenCode agent definition is optional. Let OpenCode use the
# operator's default_agent setting, or its built-in build agent when unset.
if [ -n "$OPT_AGENT" ]; then
    _agent_check_stdout="$OPENCODE_TASK_CONFIG_DIR/agent-check.stdout"
    _agent_check_stderr="$OPENCODE_TASK_CONFIG_DIR/agent-check.stderr"
    ProcessRunner_TmpStdout="$_agent_check_stdout"
    ProcessRunner_TmpStderr="$_agent_check_stderr"
    _agent_check_result="$(ProcessRunner.run --timeout 15 --cwd "$_workspace_real" -- "$OPENCODE_BIN" debug agent "$OPT_AGENT")"
    _agent_check_header="$(printf '%s\n' "$_agent_check_result" | head -n 1)"
    _agent_check_rc="${_agent_check_header%%|*}"
    ProcessRunner_TmpStdout=""
    ProcessRunner_TmpStderr=""
    if [ "$_agent_check_rc" != "0" ]; then
        log "OpenCode agent '$OPT_AGENT' is unavailable; using configured default_agent or built-in build"
        OPT_AGENT=""
    fi
fi
AGENT_ARGS=()
if [ -n "$OPT_AGENT" ]; then AGENT_ARGS=(--agent "$OPT_AGENT"); fi

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
    if [ "$_TASK_EXECUTION_KIND_INPUT" = "operator_query" ]; then
        printf '%s\n' '- Operator query mode is tool-free. Use only the read-only snapshot embedded in the prompt; do not access local files or invoke tools.'
    fi
    printf '%s\n' '- Access is still subject to OpenCode tool-level and path-level decisions. An external-directory allow rule is not a guarantee that every bash command or tool call will be allowed.'
    printf '%s\n' '- Never inspect or modify sibling task workspaces, shared caches, Manul databases/logs/configuration, adapters, or other runtime state. Never try to bypass a denial via another tool, a different path, a symlink, a wrapper, or a reshaped command.'
    printf '%s\n' '' 'Effective V2 external_directory permission rules (path patterns are JSON-quoted):'
    if [ -n "${OPENCODE_CONFIG_CONTENT:-}" ]; then
        _runtime_capability_rules="$(jq -r '
            (.permissions // [])[]?
            | select(.action == "external_directory")
            | "  - " + (.resource | tojson) + " => " + (.effect | tostring)
        ' <<<"$OPENCODE_CONFIG_CONTENT" 2>/dev/null || true)"
    elif [ -n "${OPENCODE_CONFIG:-}" ] && [ -r "$OPENCODE_CONFIG" ]; then
        _runtime_capability_rules="$(jq -r '
            (.permissions // [])[]?
            | select(.action == "external_directory")
            | "  - " + (.resource | tojson) + " => " + (.effect | tostring)
        ' "$OPENCODE_CONFIG" 2>/dev/null || true)"
    else
        _runtime_capability_rules=""
    fi
    if [ -n "$_runtime_capability_rules" ]; then
        printf '%s\n' "$_runtime_capability_rules"
    else
        printf '%s\n' '  - No readable external-directory rules were found; do not infer access.'
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
: >"$RAW_STDERR_FILE"
chmod 600 "$RAW_STDERR_FILE" 2>/dev/null || true
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
        current_stderr_error_message="$(grep -Ei '.*(permission requested|auto-rejecting|error|failed|denied|refused|timeout).*' "$CURRENT_RUN_STDERR_FILE" 2>/dev/null | grep -Eiv '^[[:space:]]*ERROR[[:space:]]*$' | tail -n 1 | sed 's/[[:space:]]\+$//' || true)"
        cat "$CURRENT_RUN_STDERR_FILE" >>"$OPT_STDERR_FILE"
        append_redacted_stderr "$CURRENT_RUN_STDERR_FILE" || log "WARN: could not retain redacted OpenCode stderr artifact"
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
        # TASK_DONE is not enough to override a failing runtime process. Keep
        # the failure fail-closed, but do not discard structured diagnostics
        # that explain why OpenCode exited non-zero after emitting the marker.
        [ -n "$error_type" ] && _summary+="; error_type=$error_type"
        [ -n "$error_source" ] && _summary+="; error_source=$error_source"
        [ -n "$last_event_type" ] && _summary+="; last_event=$last_event_type"
        _summary+="; duration_s=$duration"
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
    --arg raw_stderr "$RAW_STDERR_FILE" \
    --arg permission_tool "$permission_tool" \
    --arg permission_operation "$permission_operation" \
    --arg permission_recovery_used "$permission_recovery_used" \
    --arg selected_agent "$OPT_AGENT" \
    '{status:$status, task_id:$task_id, exit_code:($exit_code|tonumber), summary:$summary, session_id:$session_id, duration_s:($duration_s|tonumber), runtime:$runtime, failure_code:$failure_code, diagnostics:{error_type:$error_type,error_message:$error_message,error_source:$error_source,last_event_type:$last_event_type,permission_tool:$permission_tool,permission_operation:$permission_operation,permission_recovery_used:($permission_recovery_used|tonumber),selected_agent:$selected_agent,raw_log:$raw_log,raw_stderr:$raw_stderr}}'

rm -f "$CURRENT_RUN_STDOUT_FILE" "$CURRENT_RUN_STDERR_FILE" "$CURRENT_RUN_PROMPT_FILE" 2>/dev/null || true

if [ "$_status" = "BLOCKED" ]; then
    exit 0
fi
exit "$_exit_code"
