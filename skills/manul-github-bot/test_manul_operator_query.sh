#!/usr/bin/env bash
# Hermetic regression for tool-free operator-query execution through AgentExecutor.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

MANUL_DIR="$TMP/manul"
MANUL_WORKSPACE="$MANUL_DIR/workspace"
WORKSPACE="$MANUL_WORKSPACE/operator-query/oq-fixture"
mkdir -p "$MANUL_DIR" "$WORKSPACE" "$TMP/bin"
printf '%s\n' '{"automation":{"agentRuntime":"openclaw"}}' > "$MANUL_DIR/config.json"
printf '%s\n' 'Answer the operator question.' > "$WORKSPACE/prompt.md"
chmod 700 "$WORKSPACE"

cat > "$TMP/bin/openclaw" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = "agent" ] && [ "$2" = "exec" ] || { echo "unexpected OpenClaw invocation: $*" >&2; exit 91; }
shift 2
message_file=""
cwd=""
deny_seen=false
direct_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --message-file) message_file="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    --code-mode) [ "$2" = "direct" ] && direct_seen=true; shift 2 ;;
    --config-override)
      printf '%s' "$2" | jq -e '.tools.deny == ["*"]' >/dev/null
      deny_seen=true
      shift 2 ;;
    *) echo "unexpected OpenClaw argument: $1" >&2; exit 92 ;;
  esac
done
[ -n "$message_file" ] && [ -f "$message_file" ]
[ -n "$cwd" ] && [ -d "$cwd" ]
[ "$deny_seen" = true ]
[ "$direct_seen" = true ]
printf '%s\n' 'Operator status: one running task.' 'TASK_DONE'
FAKE
chmod 700 "$TMP/bin/openclaw"

jq -n \
  --arg taskId "operator-query-fixture" \
  --arg prompt "$WORKSPACE/prompt.md" \
  --arg workspace "$WORKSPACE" \
  --arg stdout "$WORKSPACE/stdout" \
  --arg stderr "$WORKSPACE/stderr" \
  '{taskId:$taskId,prompt:$prompt,workspace:$workspace,workspaceRoot:$workspace,workdir:"",executionKind:"operator_query",agent:"",attempt:1,timeout:30,session_id:"",stdout_file:$stdout,stderr_file:$stderr}' \
  > "$WORKSPACE/context.json"

RESULT="$(
  HOME="$TMP/home" \
  MANUL_DIR="$MANUL_DIR" \
  MANUL_WORKSPACE="$MANUL_WORKSPACE" \
  MANUL_TASKS_DIR="$WORKSPACE/tasks" \
  MANUL_TASK_LOG_DIR="$WORKSPACE/logs" \
  AGENT_RUNTIME=openclaw \
  OPENCLAW_BIN="$TMP/bin/openclaw" \
  PATH="$TMP/bin:$PATH" \
  bash -c 'source "$1/agent-executor.sh"; AgentExecutor.execute "$2"' _ "$SCRIPT_DIR" "$WORKSPACE/context.json"
)"

printf '%s' "$RESULT" | jq -e '.status == "COMPLETED" and .runtime == "openclaw"' >/dev/null
grep -q '^Operator status: one running task\.$' "$WORKSPACE/stdout"
grep -q '^TASK_DONE$' "$WORKSPACE/stdout"

echo "PASS: operator_query routes through AgentExecutor with an embedded deny-all OpenClaw invocation"
