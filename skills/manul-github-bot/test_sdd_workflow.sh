#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REPO_ROOT="$TEST_DIR/repo"; ROLE_DIR="$TEST_DIR/agents"; SKILLS_DIR="$TEST_DIR/skills"
MANUL_CONFIG="$TEST_DIR/manul-config.json"
mkdir -p "$REPO_ROOT" "$ROLE_DIR" "$SKILLS_DIR/specification-driven-development"
printf '# SDD agent\n' > "$ROLE_DIR/sdd.md"
printf '# Orchestrator\n' > "$ROLE_DIR/orchestrator.md"
printf '# SDD skill\n' > "$SKILLS_DIR/specification-driven-development/SKILL.md"
printf '{"agents":["orchestrator","sdd","coder"]}\n' > "$MANUL_CONFIG"
POLICY="$SCRIPT_DIR/sdd-policy.py"; STATE="$SCRIPT_DIR/workflow-state.py"
PASS=0; FAIL=0; AGENT=""; PROMPT=""; ACTION="IMPLEMENT"; RUNTIME="openclaw"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "agents" ]; then
  case "${MOCK_OPENCODE_MODE:-v2-found}" in
    v2-found) printf '%s\n' '[{"id":"orchestrator"},{"id":"sdd"}]' ;;
    v2-missing-sdd) printf '%s\n' '[{"id":"orchestrator"}]' ;;
    v2-malformed) printf '%s\n' 'not-json' ;;
    v2-error) printf '%s\n' 'OpenCode server unavailable' >&2; exit 7 ;;
    v1-found|v1-missing-sdd) printf '%s\n' 'ERROR: Unknown subcommand "agents" for "opencode debug"' >&2; exit 1 ;;
    *) exit 64 ;;
  esac
fi
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "agent" ]; then
  case "${MOCK_OPENCODE_MODE:-v2-found}:${3:-}" in
    v1-found:sdd|v1-found:orchestrator|v1-missing-sdd:orchestrator) exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 64
MOCK
chmod +x "$TEST_DIR/bin/opencode"
export OPENCODE_BIN="$TEST_DIR/bin/opencode"
export MOCK_OPENCODE_MODE="v2-found"

check_json() {
  python3 "$POLICY" inspect --repo-root "$REPO_ROOT" --agent "$AGENT" --prompt "$PROMPT" \
    --action "$ACTION" --runtime "$RUNTIME" --manul-config "$MANUL_CONFIG" \
    --role-dir "$ROLE_DIR" --skills-dir "$SKILLS_DIR"
}
run_case() {
  local name="$1"; shift
  if "$@"; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name"; FAIL=$((FAIL+1)); fi
}
expect_standard() {
  local out; out="$(check_json)"
  [ "$(jq -r '.ok' <<<"$out")" = "true" ] && [ "$(jq -r '.mode' <<<"$out")" = "standard" ]
}
expect_blocked() { local out; out="$(check_json)"; [ "$(jq -r '.ok' <<<"$out")" = "false" ]; }
expect_bootstrap() {
  local out; out="$(check_json)"
  [ "$(jq -r '.ok' <<<"$out")" = "true" ] && [ "$(jq -r '.mode' <<<"$out")" = "bootstrap" ] && [ "$(jq -r '.route_agent' <<<"$out")" = "sdd" ]
}
expect_sdd_route() {
  local out; out="$(check_json)"
  [ "$(jq -r '.ok' <<<"$out")" = "true" ] && [ "$(jq -r '.mode' <<<"$out")" = "specification-driven" ] && [ "$(jq -r '.route_agent' <<<"$out")" = "orchestrator" ]
}
expect_sdd_agent_route() {
  local out; out="$(check_json)"
  [ "$(jq -r '.ok' <<<"$out")" = "true" ] && [ "$(jq -r '.mode' <<<"$out")" = "specification-driven" ] && [ "$(jq -r '.route_agent' <<<"$out")" = "sdd" ]
}
run_case "repo without config stays on standard workflow" expect_standard
AGENT=sdd; PROMPT="Add a feature"
run_case "SDD agent without config fails instead of bootstrapping" expect_blocked
PROMPT="bootstrap"
RUNTIME="opencode"
run_case "OpenCode V2 debug agents JSON discovers SDD and orchestrator" expect_bootstrap

expect_missing_agent() {
  MOCK_OPENCODE_MODE="v2-missing-sdd"
  local out
  out="$(check_json 2>/dev/null || true)"
  jq -e '.ok == false and (.error | contains("not listed by OpenCode"))' <<<"$out" >/dev/null
}
run_case "missing SDD ID in a valid V2 agent list is reported as missing" expect_missing_agent

expect_invalid_agent_listing() {
  MOCK_OPENCODE_MODE="v2-malformed"
  local out
  out="$(check_json 2>/dev/null || true)"
  jq -e '.ok == false and (.error | contains("could not verify") and contains("invalid JSON"))' <<<"$out" >/dev/null
}
run_case "malformed V2 agent-list JSON is a discovery error, not a missing agent" expect_invalid_agent_listing

expect_agent_listing_error() {
  MOCK_OPENCODE_MODE="v2-error"
  local out
  out="$(check_json 2>/dev/null || true)"
  jq -e '.ok == false and (.error | contains("could not verify") and contains("exit code 7"))' <<<"$out" >/dev/null
}
run_case "V2 agent-list runtime failure is not mislabeled as a missing agent" expect_agent_listing_error

expect_v1_fallback() {
  MOCK_OPENCODE_MODE="v1-found"
  local out
  out="$(check_json 2>/dev/null || true)"
  jq -e '.ok == true and .mode == "bootstrap" and .route_agent == "sdd"' <<<"$out" >/dev/null
}
run_case "OpenCode V1 uses the legacy singular agent probe only when plural command is unsupported" expect_v1_fallback
MOCK_OPENCODE_MODE="v2-found"

mkdir -p "$REPO_ROOT/.specification"
cat > "$REPO_ROOT/.specification/config.yaml" <<'EOF'
version: 1
mode: specification-driven
specification:
  root: .specification
policy:
  functional_changes_require_approved_specification: true
EOF
AGENT=""; PROMPT=""
run_case "ordinary task in SDD repo routes through orchestrator" expect_sdd_route
AGENT=sdd; PROMPT="Change requirement behavior"
run_case "explicit SDD role stays on the SDD agent" expect_sdd_agent_route
ACTION=REVIEW_FIX; AGENT=""; PROMPT="Fix review feedback"
run_case "review-fix in SDD repo stays behind SDD routing" expect_sdd_route
ACTION=IMPLEMENT; AGENT=coder; PROMPT="Implement a feature"
run_case "direct Coder bypass is blocked" expect_blocked
AGENT=sdd; PROMPT="bootstrap"
run_case "bootstrap cannot overwrite initialized baseline" expect_blocked
rm -f "$ROLE_DIR/sdd.md"; AGENT=""; PROMPT=""
run_case "missing SDD agent fails closed" expect_blocked
printf '# SDD agent\n' > "$ROLE_DIR/sdd.md"
printf '{"agents":["sdd","coder"]}\n' > "$MANUL_CONFIG"
run_case "missing orchestrator allow-list entry fails closed" expect_blocked
printf '{"agents":["orchestrator","sdd","coder"]}\n' > "$MANUL_CONFIG"
rm -f "$SKILLS_DIR/specification-driven-development/SKILL.md"
run_case "missing SDD skill fails closed" expect_blocked
printf '# SDD skill\n' > "$SKILLS_DIR/specification-driven-development/SKILL.md"
printf 'version: 2\nmode: specification-driven\n' > "$REPO_ROOT/.specification/config.yaml"
run_case "unsupported config version fails closed" expect_blocked

printf 'version: 1\nmode: specification-driven\n' > "$REPO_ROOT/.specification/config.yaml"
DB="$TEST_DIR/manul.db"; OUTPUT="$TEST_DIR/agent-output.txt"
cat > "$OUTPUT" <<'EOF'
MANUL_WORKFLOW_STATE_BEGIN
{"workflowId":"sdd:test/repo:issue-42","workflowType":"sdd","repository":"test/repo","phase":"specification_pr_ready","status":"waiting_human","data":{"specificationPr":12,"token":"do-not-store"}}
MANUL_WORKFLOW_STATE_END
TASK_DONE
EOF
python3 "$STATE" --db "$DB" record-output --output "$OUTPUT" --repo "test/repo" --task-id "task-1" --conversation-id "conv-1" >/dev/null
status="$(python3 "$STATE" --db "$DB" status --workflow-id "sdd:test/repo:issue-42")"
[ "$(jq -r '.workflow.phase' <<<"$status")" = "specification_pr_ready" ] || { echo "FAIL: workflow phase missing"; FAIL=$((FAIL+1)); }
[ "$(jq -r '.workflow.state.data.token' <<<"$status")" = "[REDACTED]" ] || { echo "FAIL: secret-like field not redacted"; FAIL=$((FAIL+1)); }
events="$(jq -r '.workflow.events | length' <<<"$status")"
if [ "$events" = "1" ]; then echo "PASS: workflow checkpoint persisted"; PASS=$((PASS+1)); else echo "FAIL: event count $events"; FAIL=$((FAIL+1)); fi
context="$(python3 "$STATE" --db "$DB" context --repo "test/repo" --conversation-id "conv-1" --workflow-type sdd)"
[ "$(jq -r '.found' <<<"$context")" = "true" ] && [ "$(jq -r '.workflow.phase' <<<"$context")" = "specification_pr_ready" ] || { echo "FAIL: workflow context could not be restored"; FAIL=$((FAIL+1)); }
if [ "$(jq -r '.found' <<<"$context")" = "true" ]; then echo "PASS: durable workflow context can be resumed by conversation"; PASS=$((PASS+1)); fi
python3 "$STATE" --db "$DB" record-output --output "$OUTPUT" --repo "test/repo" --task-id "task-1" --conversation-id "conv-1" >/dev/null
status="$(python3 "$STATE" --db "$DB" status --workflow-id "sdd:test/repo:issue-42")"
events="$(jq -r '.workflow.events | length' <<<"$status")"
if [ "$events" = "1" ]; then echo "PASS: duplicate checkpoint is idempotent"; PASS=$((PASS+1)); else echo "FAIL: duplicate checkpoint changed event count"; FAIL=$((FAIL+1)); fi
echo "SDD workflow tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
