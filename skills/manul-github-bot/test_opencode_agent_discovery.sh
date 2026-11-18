#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }
assert_json_status() {
    local output="$1" expected="$2" label="$3" actual
    actual="$(printf '%s' "$output" | jq -r '.status // empty' 2>/dev/null || true)"
    if [ "$actual" = "$expected" ]; then ok "$label"; else fail "$label (expected=$expected actual=$actual output=$output)"; fi
}

run_case() {
    local mode="$1" case_dir="$TMP_ROOT/$1" output rc
    mkdir -p "$case_dir/bin" "$case_dir/workspace" "$case_dir/home"
    mkdir -p "$case_dir/runtime/workspace"
    mkdir -p "$case_dir/runtime/workspace/ws-$mode"
    printf '%s\n' 'Execute the SDD task' >"$case_dir/prompt"
    cat >"$case_dir/bin/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "agents" ]; then
    printf '%s\n' "$*" >>"$MOCK_DISCOVERY_CALLS"
    case "$MOCK_AGENT_MODE" in
        v2-found) printf '%s\n' '[{"id":"orchestrator"},{"id":"sdd"}]'; exit 0 ;;
        v2-missing) printf '%s\n' '[{"id":"orchestrator"}]'; exit 0 ;;
        v2-error) printf '%s\n' 'OpenCode server unavailable' >&2; exit 7 ;;
        v1-found|v1-missing) printf '%s\n' 'ERROR: Unknown subcommand "agents" for "opencode debug"' >&2; exit 1 ;;
        *) exit 64 ;;
    esac
fi
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "agent" ]; then
    printf '%s\n' "$*" >>"$MOCK_DISCOVERY_CALLS"
    if [ "$MOCK_AGENT_MODE" = "v1-found" ] && [ "${3:-}" = "sdd" ]; then exit 0; fi
    exit 1
fi
printf '%s\n' "$*" >"$MOCK_RUN_ARGS"
cat >/dev/null
printf '%s\n' '{"type":"text","timestamp":1,"sessionID":"ses-sdd-discovery","part":{"type":"text","text":"TASK_DONE SDD agent discovery test"}}'
exit 0
MOCK
    chmod +x "$case_dir/bin/opencode"
    set +e
    output="$(HOME="$case_dir/home" PATH="$case_dir/bin:$PATH" OPENCODE_BIN="$case_dir/bin/opencode" \
        MOCK_AGENT_MODE="$mode" MOCK_DISCOVERY_CALLS="$case_dir/discovery.calls" \
        MOCK_RUN_ARGS="$case_dir/run.args" AGENT_RUNTIME=opencode MANUL_DIR="$case_dir/runtime" \
        MANUL_WORKSPACE="$case_dir/runtime/workspace" MANUL_TASK_WORKSPACE_ROOT="$case_dir/runtime/workspace/ws-$mode" \
        bash "$SCRIPT_DIR/opencode-adapter.sh" --task-id "sdd-discovery-$mode" \
        --prompt "$case_dir/prompt" --workspace "$case_dir/runtime/workspace/ws-$mode" --agent sdd \
        --attempt 1 --timeout 30 --session-id "" --stdout-file "$case_dir/stdout" \
        --stderr-file "$case_dir/stderr" 2>/dev/null)"
    rc=$?
    set -e
    printf '%s' "$output" >"$case_dir/result.json"
    printf '%s' "$rc" >"$case_dir/exit-code"
}

run_case v2-found
result="$TMP_ROOT/v2-found/result.json"
assert_json_status "$(cat "$result")" "COMPLETED" "OpenCode V2 native SDD agent is accepted"
[ "$(cat "$TMP_ROOT/v2-found/exit-code")" = "0" ] && ok "OpenCode V2 SDD task returns success" || fail "OpenCode V2 SDD task exit code was $(cat "$TMP_ROOT/v2-found/exit-code")"
grep -Fxq 'debug agents' "$TMP_ROOT/v2-found/discovery.calls" && ok "OpenCode V2 uses the plural agent-list command" || fail "OpenCode V2 agent-list command was not called"
grep -q -- '--agent sdd' "$TMP_ROOT/v2-found/run.args" && ok "OpenCode V2 receives the native --agent sdd flag" || fail "OpenCode V2 did not receive --agent sdd"
! grep -q 'debug agent sdd' "$TMP_ROOT/v2-found/discovery.calls" && ok "OpenCode V2 never invokes the removed singular probe" || fail "OpenCode V2 invoked the removed singular probe"

run_case v2-missing
result="$TMP_ROOT/v2-missing/result.json"
assert_json_status "$(cat "$result")" "FAILED" "Missing SDD agent fails closed"
[ "$(cat "$TMP_ROOT/v2-missing/exit-code")" = "66" ] && ok "Missing SDD agent returns prerequisite exit code 66" || fail "Missing SDD agent exit code was $(cat "$TMP_ROOT/v2-missing/exit-code")"
jq -e '.failure_code == "SDD_PREREQUISITE_MISSING" and (.summary | contains("was not listed"))' "$result" >/dev/null 2>&1 && ok "Missing SDD agent has an accurate prerequisite diagnostic" || fail "Missing SDD diagnostic was inaccurate"
[ ! -s "$TMP_ROOT/v2-missing/run.args" ] && ok "Missing SDD agent is rejected before model execution" || fail "Model execution started despite missing SDD agent"

run_case v2-error
result="$TMP_ROOT/v2-error/result.json"
assert_json_status "$(cat "$result")" "FAILED" "OpenCode V2 discovery errors fail closed"
[ "$(cat "$TMP_ROOT/v2-error/exit-code")" = "66" ] && ok "Discovery error returns exit code 66" || fail "Discovery error exit code was $(cat "$TMP_ROOT/v2-error/exit-code")"
jq -e '.failure_code == "SDD_AGENT_DISCOVERY_FAILED" and (.summary | contains("Could not verify"))' "$result" >/dev/null 2>&1 && ok "Discovery error is not mislabeled as a missing agent" || fail "Discovery error was mislabeled"
[ ! -s "$TMP_ROOT/v2-error/run.args" ] && ok "Discovery error blocks model execution" || fail "Model execution started after discovery error"

run_case v1-found
result="$TMP_ROOT/v1-found/result.json"
assert_json_status "$(cat "$result")" "COMPLETED" "OpenCode V1 legacy agent probe remains supported"
[ "$(cat "$TMP_ROOT/v1-found/exit-code")" = "0" ] && ok "OpenCode V1 SDD task returns success" || fail "OpenCode V1 SDD task exit code was $(cat "$TMP_ROOT/v1-found/exit-code")"
grep -Fxq 'debug agents' "$TMP_ROOT/v1-found/discovery.calls" && ok "OpenCode V1 plural command is probed first" || fail "OpenCode V1 plural command was not probed"
grep -Fxq 'debug agent sdd' "$TMP_ROOT/v1-found/discovery.calls" && ok "OpenCode V1 falls back to the singular agent command" || fail "OpenCode V1 legacy fallback was not called"
grep -q -- '--agent sdd' "$TMP_ROOT/v1-found/run.args" && ok "OpenCode V1 receives --agent sdd after successful legacy discovery" || fail "OpenCode V1 did not receive --agent sdd"

printf '\nOpenCode agent discovery tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
