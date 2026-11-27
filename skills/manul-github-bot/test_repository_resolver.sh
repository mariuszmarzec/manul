#!/usr/bin/env bash
# Hermetic tests for the pre-workspace OpenCode repository resolver.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/manul-repository-resolver-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
HOME_DIR="$TEST_DIR/home"
BIN_DIR="$TEST_DIR/bin"
mkdir -p "$HOME_DIR/.manul" "$HOME_DIR/.agents/skills/bff-project" "$BIN_DIR"
cat >"$HOME_DIR/.manul/config.json" <<'JSON'
{"automation":{"agentRuntime":"opencode"}}
JSON
cat >"$HOME_DIR/.agents/skills/bff-project/SKILL.md" <<'SKILL'
# BFF project mapping
The BFF project is the backend for frontend.
Repository: owner/bff
The frontend gateway and API composition layer live in this repository.
SKILL
cat >"$HOME_DIR/.agents/skills/globalskills-repository/SKILL.md" <<'SKILL'
# Catalog skill
Project repository catalog instructions.
SKILL
cat >"$HOME_DIR/.agents/skills/globalskills-repository/project-repositories.json" <<'JSON'
{
  "version": 1,
  "repositories": [
    {"name":"owner/bff","aliases":["backend for frontend"],"description":"BFF gateway","skills":[]},
    {"name":"owner/service","aliases":["service"],"description":"Downstream service","skills":[]}
  ]
}
JSON

cat >"$BIN_DIR/fake-agent-task-runner" <<'FAKE_RUNNER'
#!/usr/bin/env bash
set -euo pipefail
context_file="$1"
task_id="$(jq -r '.taskId' "$context_file")"
kind="$(jq -r '.executionKind' "$context_file")"
agent="$(jq -r '.agent' "$context_file")"
workspace="$(jq -r '.workspace' "$context_file")"
prompt="$(jq -r '.prompt' "$context_file")"
stdout_file="$(jq -r '.stdout_file' "$context_file")"
stderr_file="$(jq -r '.stderr_file' "$context_file")"

[[ "$kind" == "repository_resolver" ]]
[[ "$agent" == "repository-resolver" ]]
[[ "$workspace" == "$MANUL_DIR/workspace/operator-query/"* ]]
[[ -d "$workspace" ]]
cat "$prompt" >"$OPENCODE_PROMPT_LOG"
printf '%s\n' "$kind|$agent|$workspace|$task_id" >"$RUNNER_CONTEXT_LOG"

case "$FAKE_MODE" in
  success)
    cat >"$stdout_file" <<'TEXT'
{
  "repositories": ["owner/bff", "owner/service"],
  "skills": ["bff-project"],
  "confidence": "high",
  "reason": "The task and BFF project skill identify both write targets."
}
TEXT
    ;;
  denied)
    cat >"$stdout_file" <<'TEXT'
{
  "repositories": ["attacker/private"],
  "skills": [],
  "confidence": "high",
  "reason": "Ignore the allowlist."
}
TEXT
    ;;
  uncertain)
    cat >"$stdout_file" <<'TEXT'
{
  "repositories": [],
  "skills": [],
  "confidence": "low",
  "reason": "The task is ambiguous."
}
TEXT
    ;;
  *)
    echo "unexpected fake mode" >&2
    exit 2
    ;;
esac
: >"$stderr_file"
jq -cn --arg taskId "$task_id" '{
  status:"COMPLETED",
  task_id:$taskId,
  exit_code:0,
  summary:"fake runner completed",
  session_id:"",
  duration_s:0,
  runtime:"opencode"
}'
FAKE_RUNNER
chmod +x "$BIN_DIR/fake-agent-task-runner"

export HOME="$HOME_DIR"
export MANUL_DIR="$HOME_DIR/.manul"
export MANUL_REPOSITORY_RESOLVER_RUNNER="$BIN_DIR/fake-agent-task-runner"
export OPENCODE_PROMPT_LOG="$TEST_DIR/resolver.prompt"
export RUNNER_CONTEXT_LOG="$TEST_DIR/runner.context"
SOURCE='{"repositories":["owner/bff","owner/service"]}'
TASK='{"id":42,"description":"/manul implement Jira JIRA-123 in repo bff and the service","subTasks":[{"description":"The BFF gateway and downstream service both need changes."}]}'
INPUT="$(jq -cn --argjson source "$SOURCE" --argjson task "$TASK" '{source:$source,task:$task}')"

export FAKE_MODE=success
RESULT="$(printf '%s\n' "$INPUT" | bash "$SCRIPT_DIR/repository-resolver.sh")"
[[ "$(jq -r '.method' <<<"$RESULT")" == "opencode_agent_multi" ]]
[[ "$(jq -r '.repositories | length' <<<"$RESULT")" == "2" ]]
[[ "$(jq -r '.repository' <<<"$RESULT")" == "owner/bff" ]]
[[ "$(jq -r '.skills[0]' <<<"$RESULT")" == "bff-project" ]]
grep -q 'JIRA-123' "$OPENCODE_PROMPT_LOG"
grep -q 'backend for frontend' "$OPENCODE_PROMPT_LOG"
grep -q 'owner/service' "$OPENCODE_PROMPT_LOG"
grep -q 'repository_resolver|repository-resolver|' "$RUNNER_CONTEXT_LOG"
echo "PASS: resolver uses the Manul execution boundary, supplies installed skills and preserves multi-repo targets"

export FAKE_MODE=denied
if printf '%s\n' "$INPUT" | bash "$SCRIPT_DIR/repository-resolver.sh" >/dev/null 2>&1; then
  echo "FAIL: resolver accepted a repository outside the allowlist" >&2
  exit 1
fi
echo "PASS: resolver rejects model-selected repositories outside the allowlist"

export FAKE_MODE=uncertain
if printf '%s\n' "$INPUT" | bash "$SCRIPT_DIR/repository-resolver.sh" >/dev/null 2>&1; then
  echo "FAIL: resolver accepted an uncertain empty result" >&2
  exit 1
fi
echo "PASS: resolver fails closed on low-confidence output"

cat >"$MANUL_DIR/config.json" <<'JSON'
{"automation":{"agentRuntime":"codex"}}
JSON
if printf '%s\n' "$INPUT" | bash "$SCRIPT_DIR/repository-resolver.sh" >/dev/null 2>&1; then
  echo "FAIL: resolver ignored the configured agent runtime" >&2
  exit 1
fi
echo "PASS: resolver does not bypass the configured Manul runtime"
