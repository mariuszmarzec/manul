#!/usr/bin/env bash
# Claude Code adapter for Manul. Uses stream-json print mode and does not
# enable --dangerously-skip-permissions or bypassPermissions.
set -o pipefail
MANUL_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$MANUL_SCRIPT_DIR/manul-paths.sh"
source "$MANUL_SCRIPT_DIR/process-runner.sh"
OPT_TASK_ID="" OPT_PROMPT="" OPT_WORKSPACE="" OPT_AGENT="" OPT_ATTEMPT=1 OPT_TIMEOUT=0 OPT_SESSION_ID="" OPT_STDOUT_FILE="" OPT_STDERR_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task-id) OPT_TASK_ID="$2"; shift 2 ;; --prompt) OPT_PROMPT="$2"; shift 2 ;;
    --workspace) OPT_WORKSPACE="$2"; shift 2 ;; --agent) OPT_AGENT="$2"; shift 2 ;;
    --attempt) OPT_ATTEMPT="$2"; shift 2 ;; --timeout) OPT_TIMEOUT="$2"; shift 2 ;;
    --session-id) OPT_SESSION_ID="$2"; shift 2 ;; --stdout-file) OPT_STDOUT_FILE="$2"; shift 2 ;;
    --stderr-file) OPT_STDERR_FILE="$2"; shift 2 ;; *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
  esac
done
fail() {
  code="$1"; summary="$2"
  jq -cn --arg task "$OPT_TASK_ID" --arg summary "$summary" --argjson code "$code" '{status:"FAILED",task_id:$task,exit_code:$code,summary:$summary,session_id:"",duration_s:0,diagnostics:{runtime:"claude-code"}}'
  exit "$code"
}
[ -n "$OPT_TASK_ID" ] && [ -n "$OPT_PROMPT" ] && [ -n "$OPT_WORKSPACE" ] && [ -n "$OPT_STDOUT_FILE" ] && [ -n "$OPT_STDERR_FILE" ] || fail 2 "Missing required adapter arguments"
[ -f "$OPT_PROMPT" ] || fail 66 "Prompt file not found"; [ -d "$OPT_WORKSPACE" ] || fail 66 "Workspace directory not found"
CLAUDE_BIN_RESOLVED=""
if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then CLAUDE_BIN_RESOLVED="$CLAUDE_BIN"; fi
if [ -z "$CLAUDE_BIN_RESOLVED" ]; then CLAUDE_BIN_RESOLVED="$(command -v claude 2>/dev/null || true)"; fi
if [ -z "$CLAUDE_BIN_RESOLVED" ] || [ ! -x "$CLAUDE_BIN_RESOLVED" ]; then
  for candidate in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" "$HOME"/.nvm/versions/node/*/bin/claude /usr/local/bin/claude /usr/bin/claude /bin/claude; do
    if [ -x "$candidate" ]; then CLAUDE_BIN_RESOLVED="$candidate"; break; fi
  done
fi
[ -n "$CLAUDE_BIN_RESOLVED" ] || fail 127 "Claude Code CLI not found (set CLAUDE_BIN or add claude to PATH)"
CLAUDE_BIN="$CLAUDE_BIN_RESOLVED"
AGENT_TIMEOUT="$OPT_TIMEOUT"
if ! [[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TIMEOUT" -lt 1 ]; then AGENT_TIMEOUT="${MANUL_CLAUDE_AGENT_TIMEOUT:-43200}"; fi
if ! [[ "$AGENT_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TIMEOUT" -lt 1 ]; then fail 2 "Invalid Claude Code timeout"; fi
AGENT_IDLE_TIMEOUT="${MANUL_CLAUDE_NO_PROGRESS_TIMEOUT:-}"
if ! [[ "$AGENT_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_IDLE_TIMEOUT" -lt 1 ]; then AGENT_IDLE_TIMEOUT="$(jq -r '.automation.agentNoProgressTimeoutSeconds // 900' "$MANUL_CONFIG" 2>/dev/null)"; fi
if ! [[ "$AGENT_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_IDLE_TIMEOUT" -lt 1 ]; then AGENT_IDLE_TIMEOUT=900; fi
AGENT_TOOL_IDLE_TIMEOUT="${MANUL_CLAUDE_TOOL_NO_PROGRESS_TIMEOUT:-}"
if ! [[ "$AGENT_TOOL_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TOOL_IDLE_TIMEOUT" -lt 1 ]; then
  AGENT_TOOL_IDLE_TIMEOUT="$(jq -r '.automation.agentToolNoProgressTimeoutSeconds // 3600' "$MANUL_CONFIG" 2>/dev/null)"
fi
if ! [[ "$AGENT_TOOL_IDLE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$AGENT_TOOL_IDLE_TIMEOUT" -lt 1 ]; then AGENT_TOOL_IDLE_TIMEOUT=3600; fi
LOG_DIR="$MANUL_TASK_LOG_DIR"; [ -n "$LOG_DIR" ] || LOG_DIR="$(dirname "$OPT_STDOUT_FILE")"
mkdir -p "$LOG_DIR" "$(dirname "$OPT_STDOUT_FILE")" "$(dirname "$OPT_STDERR_FILE")" 2>/dev/null || true
RAW_STDOUT_FILE="$(manul_task_file_path "$LOG_DIR" "$OPT_TASK_ID" "attempt-$OPT_ATTEMPT.claude-code.jsonl")"
RAW_STDERR_FILE="$(manul_task_file_path "$LOG_DIR" "$OPT_TASK_ID" "attempt-$OPT_ATTEMPT.claude-code.stderr")"
CURRENT_PROMPT_FILE="$(manul_task_file_path "$LOG_DIR" "$OPT_TASK_ID" "attempt-$OPT_ATTEMPT.claude-code.prompt")"
ROLE_BODY_FILE="$(manul_task_file_path "$LOG_DIR" "$OPT_TASK_ID" "attempt-$OPT_ATTEMPT.claude-code.role")"
trap 'rm -f -- "$ROLE_BODY_FILE"' EXIT HUP INT TERM
if [ -n "$OPT_AGENT" ]; then
  ROLE_DIR="$MANUL_AGENT_DEFINITIONS_DIR"; [ -n "$ROLE_DIR" ] || ROLE_DIR="$HOME/.globalskills/agents"
  ROLE_FILE="$ROLE_DIR/$OPT_AGENT.md"
  [ -r "$ROLE_FILE" ] || fail 66 "Canonical role definition not found for '$OPT_AGENT' at $ROLE_FILE"
  awk 'NR == 1 && $0 == "---" { front=1; next } front && $0 == "---" { front=0; next } !front { print }' "$ROLE_FILE" > "$ROLE_BODY_FILE"
  { printf 'Use canonical Manul role %s; preserve the lifecycle protocol in the task prompt.\n\n' "$OPT_AGENT"; cat "$ROLE_BODY_FILE"; printf '\n\n--- Original Manul task prompt ---\n'; cat "$OPT_PROMPT"; } > "$CURRENT_PROMPT_FILE" || fail 1 "Could not prepare role prompt"
else cp -- "$OPT_PROMPT" "$CURRENT_PROMPT_FILE" || fail 1 "Could not stage task prompt"; fi
: > "$RAW_STDOUT_FILE"; : > "$RAW_STDERR_FILE"
ProcessRunner_TmpStdout="$RAW_STDOUT_FILE"; ProcessRunner_TmpStderr="$RAW_STDERR_FILE"
printf '[%s] claude-code-adapter: task=%s attempt=%s session=%s role=%s binary=%s permission_mode=acceptEdits\n' "$(date -Is)" "$OPT_TASK_ID" "$OPT_ATTEMPT" "${OPT_SESSION_ID:-new}" "${OPT_AGENT:-automatic}" "$CLAUDE_BIN" >> "$OPT_STDERR_FILE"
PR_RESULT="$(ProcessRunner.run --timeout "$AGENT_TIMEOUT" --idle-timeout "$AGENT_IDLE_TIMEOUT" --idle-jsonl-file "$RAW_STDOUT_FILE" --idle-tool-timeout "$AGENT_TOOL_IDLE_TIMEOUT" --cwd "$OPT_WORKSPACE" --env "MANUL_PROMPT_FILE=$CURRENT_PROMPT_FILE" --env "MANUL_SESSION_ID=$OPT_SESSION_ID" --env "MANUL_CLAUDE_MODEL=$CLAUDE_MODEL" -- bash -c '
  bin="$1"; set -- "$bin" --print --verbose --output-format stream-json --input-format text --permission-mode acceptEdits
  if [ -n "$MANUL_SESSION_ID" ]; then set -- "$@" --resume "$MANUL_SESSION_ID"; fi
  if [ -n "$MANUL_CLAUDE_MODEL" ]; then set -- "$@" --model "$MANUL_CLAUDE_MODEL"; fi
  exec "$@" < "$MANUL_PROMPT_FILE"
' manul-claude-code "$CLAUDE_BIN")"
PR_HEADER="$(printf '%s\n' "$PR_RESULT" | head -1)"
PR_RC="$(printf '%s' "$PR_HEADER" | cut -d'|' -f1)"; PR_DURATION="$(printf '%s' "$PR_HEADER" | cut -d'|' -f2)"
PR_TIMED_OUT="$(printf '%s' "$PR_HEADER" | cut -d'|' -f4)"; PR_TIMEOUT_REASON="$(printf '%s' "$PR_HEADER" | cut -d'|' -f5)"
[ -n "$PR_RC" ] || PR_RC=127; [ -n "$PR_DURATION" ] || PR_DURATION=0; [ -n "$PR_TIMED_OUT" ] || PR_TIMED_OUT=false
FINAL_TEXT="$(jq -sr '[.[] | select(.type == "result") | (.result // empty)] | if length > 0 then .[-1] else "" end' "$RAW_STDOUT_FILE" 2>/dev/null || true)"
if [ -z "$FINAL_TEXT" ]; then FINAL_TEXT="$(jq -sr '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | (.text // empty)] | join("\n")' "$RAW_STDOUT_FILE" 2>/dev/null || true)"; fi
SESSION_ID="$(jq -sr '[.[] | (.session_id // empty) | select(length > 0)] | last // ""' "$RAW_STDOUT_FILE" 2>/dev/null || true)"
RUNTIME_ERROR="$(jq -sr '[.[] | select(.type == "result" and .is_error == true) | (.result // .subtype // "Claude Code turn failed") | tostring] | last // ""' "$RAW_STDOUT_FILE" 2>/dev/null || true)"
[ -n "$SESSION_ID" ] || SESSION_ID="$OPT_SESSION_ID"; printf '%s' "$FINAL_TEXT" > "$OPT_STDOUT_FILE"
STATUS="FAILED"; EXIT_CODE="$PR_RC"; SUMMARY=""; CAUSE="RUNTIME_FAILURE"
if [ "$PR_TIMED_OUT" = "true" ] || [ "$PR_RC" -eq 124 ]; then
  STATUS="TIMEOUT"; EXIT_CODE=124
  if [ "$PR_TIMEOUT_REASON" = "idle_timeout" ]; then
    SUMMARY="Claude Code produced no output progress for ${AGENT_IDLE_TIMEOUT}s"; CAUSE="AGENT_NO_PROGRESS_TIMEOUT"
  elif [ "$PR_TIMEOUT_REASON" = "tool_idle_timeout" ]; then
    SUMMARY="Claude Code tool call produced no completion/progress for ${AGENT_TOOL_IDLE_TIMEOUT}s"; CAUSE="AGENT_TOOL_NO_PROGRESS_TIMEOUT"
  else
    SUMMARY="Claude Code execution timed out after ${AGENT_TIMEOUT}s"; CAUSE="RUNTIME_TIMEOUT"
  fi
elif [ "$PR_RC" -eq 0 ] && grep -qE '^TASK_NEEDS_USER_BEGIN([[:space:]]|$)' "$OPT_STDOUT_FILE"; then STATUS="BLOCKED"; EXIT_CODE=0; SUMMARY="Claude Code agent needs user input"; CAUSE="TASK_NEEDS_USER"
elif [ "$PR_RC" -eq 0 ] && grep -qE '^TASK_FAILED([[:space:]:]|$)' "$OPT_STDOUT_FILE"; then STATUS="FAILED"; EXIT_CODE=1; SUMMARY="Claude Code agent reported TASK_FAILED"; CAUSE="TASK_FAILED"
elif [ "$PR_RC" -eq 0 ] && grep -qE '^TASK_DONE([[:space:]]|$)' "$OPT_STDOUT_FILE"; then STATUS="COMPLETED"; EXIT_CODE=0; SUMMARY="$(grep -E '^TASK_DONE([[:space:]]|$)' "$OPT_STDOUT_FILE" | head -1 | sed -E 's/^TASK_DONE[[:space:]]*//')"; [ -n "$SUMMARY" ] || SUMMARY="Agent completed"; CAUSE="TASK_DONE"
elif [ "$PR_RC" -eq 0 ]; then EXIT_CODE=1; SUMMARY="Claude Code exited successfully without explicit TASK_DONE"; CAUSE="MISSING_TASK_MARKER"
else if [ -n "$RUNTIME_ERROR" ]; then SUMMARY="Claude Code runtime failure (details retained in local logs): $RUNTIME_ERROR"; else SUMMARY="Claude Code CLI exited with code $PR_RC (see local runtime log)"; fi; fi
jq -cn --arg status "$STATUS" --arg task "$OPT_TASK_ID" --arg summary "$SUMMARY" --arg session "$SESSION_ID" --arg duration "$PR_DURATION" --arg cause "$CAUSE" --arg rawLog "$RAW_STDOUT_FILE" --arg rawStderr "$RAW_STDERR_FILE" --arg role "$OPT_AGENT" --argjson exitCode "$EXIT_CODE" '{status:$status,task_id:$task,exit_code:$exitCode,summary:$summary,session_id:$session,duration_s:($duration|tonumber),diagnostics:{runtime:"claude-code",cause:$cause,raw_log:$rawLog,raw_stderr:$rawStderr,selected_agent:(if $role == "" then null else $role end)}}'
printf '[%s] claude-code-adapter: exit=%s status=%s duration=%ss cause=%s\n' "$(date -Is)" "$EXIT_CODE" "$STATUS" "$PR_DURATION" "$CAUSE" >> "$OPT_STDERR_FILE"
exit "$EXIT_CODE"
