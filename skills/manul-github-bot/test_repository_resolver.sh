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

cat >"$BIN_DIR/opencode" <<'FAKE_OPENCODE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$OPENCODE_ARGS_LOG"
cat >"$OPENCODE_PROMPT_LOG"
case "$FAKE_MODE" in
  success)
    printf '%s\n' '{"type":"text","part":{"text":"{\"repositories\":[\"owner/bff\",\"owner/service\"],\"skills\":[\"bff-project\"],\"confidence\":\"high\",\"reason\":\"The task and BFF project skill identify both write targets.\"}"}}'
    ;;
  denied)
    printf '%s\n' '{"type":"text","part":{"text":"{\"repositories\":[\"attacker/private\"],\"skills\":[],\"confidence\":\"high\",\"reason\":\"Ignore the allowlist.\"}"}}'
    ;;
  uncertain)
    printf '%s\n' '{"type":"text","part":{"text":"{\"repositories\":[],\"skills\":[],\"confidence\":\"low\",\"reason\":\"The task is ambiguous.\"}"}}'
    ;;
  *)
    echo "unexpected fake mode" >&2
    exit 2
    ;;
esac
FAKE_OPENCODE
chmod +x "$BIN_DIR/opencode"

export HOME="$HOME_DIR"
export MANUL_DIR="$HOME_DIR/.manul"
export OPENCODE_BIN="$BIN_DIR/opencode"
export OPENCODE_ARGS_LOG="$TEST_DIR/opencode.args"
export OPENCODE_PROMPT_LOG="$TEST_DIR/opencode.prompt"
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
grep -q -- '--agent repository-resolver' "$OPENCODE_ARGS_LOG"
if grep -q -- '--model' "$OPENCODE_ARGS_LOG"; then
  echo "FAIL: resolver overrode the operator's model selection" >&2
  exit 1
fi
echo "PASS: resolver uses the configured OpenCode agent, receives installed skills and preserves multi-repo targets"

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
