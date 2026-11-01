#!/usr/bin/env bash
# test_manul_environment.sh — provider environment/bootstrap and lifecycle tests.
#
# These tests use isolated temporary runtimes only. No production ~/.manul,
# OpenClaw state, cron, or GitHub state is touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_file_mode_600() {
  local file="$1"
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
  [ "$mode" = "600" ] && ok "Environment file is mode 600" || fail "Environment file mode is $mode (expected 600)"
}

echo "=== Manul Environment Tests ==="
echo "Canonical source: $SCRIPT_DIR"
echo

# ---------------------------------------------------------------------------
# 0. Integration wiring.
# ---------------------------------------------------------------------------
grep -q 'manul-env.sh' "$SCRIPT_DIR/install-manul-symlinks.sh"   && ok "Symlink installer deploys manul-env.sh"   || fail "Symlink installer does not deploy manul-env.sh"
grep -q '"manul-failure-utils.sh"' "$SCRIPT_DIR/install-manul-symlinks.sh" && ok "Symlink installer deploys failure sanitization helper" || fail "Symlink installer does not deploy failure sanitization helper"

grep -q 'manul-env.sh" --bootstrap' "$SCRIPT_DIR/install-manul.sh"   && ok "Installer bootstraps the operator environment"   || fail "Installer does not bootstrap the operator environment"

grep -q 'manul_env_load' "$SCRIPT_DIR/manul-daemon.sh"   && ok "Daemon loads the runtime operator environment"   || fail "Daemon does not load the runtime operator environment"

grep -q 'manul_env_load' "$SCRIPT_DIR/watchdog.sh"   && ok "Watchdog loads the runtime operator environment"   || fail "Watchdog does not load the runtime operator environment"

grep -q 'manul_env_load' "$SCRIPT_DIR/install-manul.sh"   && ok "Installer reloads persisted provider environment before configuring OpenCode"   || fail "Installer skips persisted provider environment"
grep -q 'manul_env_load' "$SCRIPT_DIR/repair-manul-runtime.sh"   && ok "Repair reloads persisted provider environment before configuring OpenCode"   || fail "Repair skips persisted provider environment"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RUNTIME="$TMP/runtime"
mkdir -p "$RUNTIME"
OPENCLAW_STATE_DIR="$TMP/openclaw state"
OPENCLAW_CONFIG_PATH="$TMP/openclaw/config with spaces.json"
OPENCLAW_BIN="$TMP/bin/openclaw-custom"
OPENCODE_BIN="$TMP/bin/opencode-custom"
OPENCODE_CONFIG="$TMP/custom opencode config.json"
CODEX_HOME="$TMP/codex home"
CODEX_BIN="$TMP/bin/codex-custom"
CODEX_MODEL="codex-test-model"
CLAUDE_CONFIG_DIR="$TMP/claude config"
CLAUDE_BIN="$TMP/bin/claude-custom"
CLAUDE_MODEL="claude-test-model"
CARACAL_MCP_URL="http://127.0.0.1:3400/mcp"
CARACAL_ACCESS_TOKEN="caracal-test-token"
FITEO_BASE_URL="https://fiteo-test.example"
FITEO_PAT="fiteo-test-pat"
UNSAFE_SECRET="must-not-be-copied"
CUSTOM_JIRA_USER="custom-jira-user"
CUSTOM_JIRA_PASSWORD="custom-jira-password"

cat > "$RUNTIME/config.json" <<'EOF'
{"taskSources":[{"type":"jira_tasks","enabled":true,"userEnv":"CUSTOM_JIRA_USER","passwordEnv":"CUSTOM_JIRA_PASSWORD"}]}
EOF

export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_BIN OPENCODE_BIN OPENCODE_CONFIG CODEX_HOME CODEX_BIN CODEX_MODEL CLAUDE_CONFIG_DIR CLAUDE_BIN CLAUDE_MODEL CARACAL_MCP_URL CARACAL_ACCESS_TOKEN FITEO_BASE_URL FITEO_PAT UNSAFE_SECRET CUSTOM_JIRA_USER CUSTOM_JIRA_PASSWORD

ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$RUNTIME")"

[ -f "$ENV_FILE" ] && ok "Bootstrap creates ~/.manul/.env equivalent" || fail "Bootstrap did not create environment file"
assert_file_mode_600 "$ENV_FILE"

if ! grep -q '^OPENCLAW_STATE_DIR=' "$ENV_FILE" ||
   ! grep -q '^OPENCLAW_CONFIG_PATH=' "$ENV_FILE" ||
   ! grep -q '^OPENCLAW_BIN=' "$ENV_FILE" ||
   ! grep -q '^OPENCODE_BIN=' "$ENV_FILE" ||
   ! grep -q '^OPENCODE_CONFIG=' "$ENV_FILE" ||
   ! grep -q '^CODEX_HOME=' "$ENV_FILE" ||
   ! grep -q '^CODEX_BIN=' "$ENV_FILE" ||
   ! grep -q '^CODEX_MODEL=' "$ENV_FILE" ||
   ! grep -q '^CLAUDE_CONFIG_DIR=' "$ENV_FILE" ||
   ! grep -q '^CLAUDE_BIN=' "$ENV_FILE" ||
   ! grep -q '^CLAUDE_MODEL=' "$ENV_FILE" ||
   ! grep -q '^CARACAL_MCP_URL=' "$ENV_FILE" ||
   ! grep -q '^CARACAL_ACCESS_TOKEN=' "$ENV_FILE" ||
   ! grep -q '^FITEO_BASE_URL=' "$ENV_FILE" ||
   ! grep -q '^FITEO_PAT=' "$ENV_FILE" ||
   ! grep -q '^CUSTOM_JIRA_USER=' "$ENV_FILE" ||
   ! grep -q '^CUSTOM_JIRA_PASSWORD=' "$ENV_FILE"; then
  fail "Bootstrap did not persist all supported provider variables"
else
  ok "Bootstrap persists supported provider variables"
fi

if grep -q 'UNSAFE_SECRET' "$ENV_FILE"; then
  fail "Bootstrap copied an arbitrary environment variable"
else
  ok "Bootstrap does not copy arbitrary environment variables"
fi

if (
  unset OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_BIN OPENCODE_BIN OPENCODE_CONFIG CODEX_HOME CODEX_BIN CODEX_MODEL CLAUDE_CONFIG_DIR CLAUDE_BIN CLAUDE_MODEL CARACAL_MCP_URL CARACAL_ACCESS_TOKEN FITEO_BASE_URL FITEO_PAT
  source "$ENV_FILE"
  [ "$OPENCLAW_STATE_DIR" = "$TMP/openclaw state" ] &&
  [ "$OPENCLAW_CONFIG_PATH" = "$TMP/openclaw/config with spaces.json" ] &&
  [ "$OPENCLAW_BIN" = "$TMP/bin/openclaw-custom" ] &&
  [ "$OPENCODE_BIN" = "$TMP/bin/opencode-custom" ] &&
  [ "$OPENCODE_CONFIG" = "$TMP/custom opencode config.json" ] &&
  [ "$CODEX_HOME" = "$TMP/codex home" ] &&
  [ "$CODEX_BIN" = "$TMP/bin/codex-custom" ] &&
  [ "$CODEX_MODEL" = "codex-test-model" ] &&
  [ "$CLAUDE_CONFIG_DIR" = "$TMP/claude config" ] &&
  [ "$CLAUDE_BIN" = "$TMP/bin/claude-custom" ] &&
  [ "$CLAUDE_MODEL" = "claude-test-model" ] &&
  [ "$CARACAL_MCP_URL" = "http://127.0.0.1:3400/mcp" ] &&
  [ "$CARACAL_ACCESS_TOKEN" = "caracal-test-token" ] &&
  [ "$FITEO_BASE_URL" = "https://fiteo-test.example" ] &&
  [ "$FITEO_PAT" = "fiteo-test-pat" ] &&
  [ "$CUSTOM_JIRA_USER" = "custom-jira-user" ] &&
  [ "$CUSTOM_JIRA_PASSWORD" = "custom-jira-password" ]
); then
  ok "Bootstrap shell-quotes provider values correctly"
else
  fail "Bootstrap did not preserve provider values when reloaded"
fi

PRESERVE="$TMP/preserve"
mkdir -p "$PRESERVE"
cat > "$PRESERVE/.env" <<'EOF'
OPENCLAW_STATE_DIR=/operator/chosen/state
OPENCODE_CONFIG=/operator/chosen/opencode.json
EOF
chmod 600 "$PRESERVE/.env"

OPENCLAW_STATE_DIR="/installer/current/state"
OPENCLAW_CONFIG_PATH="/installer/current/config.json"
OPENCODE_CONFIG="/installer/current/opencode.json"
export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCODE_CONFIG
ENV_FILE2="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$PRESERVE")"

if (
  unset OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCODE_CONFIG
  source "$ENV_FILE2"
  [ "$OPENCLAW_STATE_DIR" = "/operator/chosen/state" ] &&
  [ "$OPENCLAW_CONFIG_PATH" = "/installer/current/config.json" ] &&
  [ "$OPENCODE_CONFIG" = "/operator/chosen/opencode.json" ]
); then
  ok "Existing operator provider configuration is preserved"
else
  fail "Bootstrap overwrote or failed to append provider configuration"
fi

# Caracal runtime values are the exception to general preservation: the launcher
# refreshes these two allowlisted keys so background task runners do not keep a
# stale endpoint or bearer token after Caracal config changes.
PRESERVE_CARACAL="$TMP/preserve-caracal"
mkdir -p "$PRESERVE_CARACAL"
cat > "$PRESERVE_CARACAL/.env" <<'EOF'
OPENCLAW_STATE_DIR=/operator/chosen/state
OPENCODE_CONFIG=/operator/chosen/opencode.json
CARACAL_MCP_URL=http://127.0.0.1:1234/old
CARACAL_ACCESS_TOKEN=old-token
EOF
chmod 600 "$PRESERVE_CARACAL/.env"
CARACAL_MCP_URL="http://127.0.0.1:3400/mcp"
CARACAL_ACCESS_TOKEN="new-caracal-test-token"
export CARACAL_MCP_URL CARACAL_ACCESS_TOKEN
ENV_FILE3="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$PRESERVE_CARACAL")"
if (
  unset CARACAL_MCP_URL CARACAL_ACCESS_TOKEN OPENCLAW_STATE_DIR OPENCODE_CONFIG
  source "$ENV_FILE3"
  [ "$CARACAL_MCP_URL" = "http://127.0.0.1:3400/mcp" ] &&
  [ "$CARACAL_ACCESS_TOKEN" = "new-caracal-test-token" ] &&
  [ "$OPENCLAW_STATE_DIR" = "/operator/chosen/state" ] &&
  [ "$OPENCODE_CONFIG" = "/operator/chosen/opencode.json" ]
); then
  ok "Bootstrap refreshes Caracal URL/token while preserving unrelated operator settings"
else
  fail "Bootstrap did not refresh Caracal runtime credentials correctly"
fi

# Fiteo MCP credentials are refreshed as one pair even when no Todo remote
# task source is configured, preventing a long-lived daemon from keeping a
# previously issued PAT after the operator updates opencode.env.
PRESERVE_FITEO="$TMP/preserve-fiteo"
mkdir -p "$PRESERVE_FITEO"
cat > "$PRESERVE_FITEO/.env" <<'EOF'
FITEO_BASE_URL=https://old-fiteo.example
FITEO_PAT=old-fiteo-pat
EOF
chmod 600 "$PRESERVE_FITEO/.env"
FITEO_BASE_URL="https://new-fiteo.example"
FITEO_PAT="new-fiteo-pat"
export FITEO_BASE_URL FITEO_PAT
FITEO_ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$PRESERVE_FITEO")"
if (
  unset FITEO_BASE_URL FITEO_PAT
  source "$FITEO_ENV_FILE"
  [ "$FITEO_BASE_URL" = "https://new-fiteo.example" ] &&
  [ "$FITEO_PAT" = "new-fiteo-pat" ]
); then
  ok "Bootstrap refreshes the Fiteo endpoint/PAT pair for unattended MCP sessions"
else
  fail "Bootstrap did not refresh the Fiteo MCP credentials correctly"
fi
assert_file_mode_600 "$FITEO_ENV_FILE"

# Todo's token comes from aicode's inherited exported environment (e.g. .zshrc)
# and must refresh in the runtime file even when a prior token already exists.
TODO_RUNTIME="$TMP/todo-token-runtime"
mkdir -p "$TODO_RUNTIME"
cat > "$TODO_RUNTIME/.env" <<'EOF'
OPENCODE_CONFIG=/operator/chosen/opencode.json
TODO_LOCAL_MCP_TOKEN=old-todo-token
EOF
chmod 600 "$TODO_RUNTIME/.env"
TODO_LOCAL_MCP_TOKEN="new-todo-token"
export TODO_LOCAL_MCP_TOKEN
TODO_ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$TODO_RUNTIME")"
if (
  unset TODO_LOCAL_MCP_TOKEN OPENCODE_CONFIG
  source "$TODO_ENV_FILE"
  [ "$TODO_LOCAL_MCP_TOKEN" = "new-todo-token" ] &&
  [ "$OPENCODE_CONFIG" = "/operator/chosen/opencode.json" ]
); then
  ok "Bootstrap refreshes Todo local MCP token while preserving unrelated operator settings"
else
  fail "Bootstrap did not refresh the Todo local MCP token correctly"
fi
assert_file_mode_600 "$TODO_ENV_FILE"

INVALID="$TMP/invalid"
mkdir -p "$INVALID"
printf "OPENCLAW_STATE_DIR='unterminated\n" > "$INVALID/.env"

set +e
INVALID_RC=0
bash -c 'source "$1/manul-env.sh"; manul_env_load "$2"' _ "$SCRIPT_DIR" "$INVALID" >/dev/null 2>&1
INVALID_RC=$?
set -e

[ "$INVALID_RC" -ne 0 ] && ok "Invalid operator environment fails closed" || fail "Invalid operator environment was accepted"

START_RUNTIME="$TMP/start-runtime"
CANONICAL_RUNTIME="$TMP/canonical-runtime"
FAKE_BIN="$TMP/fake-bin"
CRONTAB_FILE="$TMP/crontab"
mkdir -p "$START_RUNTIME" "$CANONICAL_RUNTIME" "$FAKE_BIN"

# The startup wrapper now refreshes runtime symlinks from the canonical source.
# Isolate that source in the test instead of relying on ~/.globalskills.
# The installer validates the complete canonical script set. Populate an
# isolated canonical tree with the same files as the real skill source so this
# test exercises startup/symlink behavior rather than a deliberately incomplete
# fixture.
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py "$CANONICAL_RUNTIME/"
cp "$SCRIPT_DIR/orchestrator.prompt.md" "$CANONICAL_RUNTIME/orchestrator.prompt.md"
chmod +x "$CANONICAL_RUNTIME"/*.sh

cat > "$CANONICAL_RUNTIME/manul-daemon.sh" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  start)
    echo "$" > "$MANUL_FAKE_PID_FILE"
    exit 0
    ;;
  status)
    exit 0
    ;;
  stop)
    rm -f "$MANUL_FAKE_PID_FILE"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod +x "$CANONICAL_RUNTIME/manul-daemon.sh"

cat > "$CANONICAL_RUNTIME/watchdog.sh" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$CANONICAL_RUNTIME/watchdog.sh"

cat > "$FAKE_BIN/setsid" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$FAKE_BIN/setsid"

cat > "$FAKE_BIN/nohup" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$FAKE_BIN/nohup"

cat > "$FAKE_BIN/crontab" <<'MOCK'
#!/usr/bin/env bash
set -e
case "$1" in
  -l)
    cat "$MANUL_FAKE_CRONTAB_FILE" 2>/dev/null || true
    ;;
  -)
    cat > "$MANUL_FAKE_CRONTAB_FILE"
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod +x "$FAKE_BIN/crontab"

export MANUL_FAKE_PID_FILE="$START_RUNTIME/fake.pid"
export MANUL_FAKE_CRONTAB_FILE="$CRONTAB_FILE"

set +e
PATH="$FAKE_BIN:$PATH" MANUL_DIR="$START_RUNTIME" \
  MANUL_CANONICAL_ROOT="$CANONICAL_RUNTIME" MANUL_CANONICAL_DIR="$CANONICAL_RUNTIME" \
  "$SCRIPT_DIR/start-manul-automation.sh" start >/dev/null 2>&1
START_RC=$?
set -e

if [ "$START_RC" -eq 0 ] && [ -f "$START_RUNTIME/.enabled" ]; then
  ok "start-manul-automation.sh returns 0 on successful standalone start"
else
  fail "start-manul-automation.sh returned $START_RC or did not enable runtime"
fi

if grep -qF "$START_RUNTIME/watchdog.sh" "$CRONTAB_FILE" 2>/dev/null; then
  ok "Startup wrapper installs its runtime watchdog"
else
  fail "Startup wrapper did not install its runtime watchdog"
fi

set +e
PATH="$FAKE_BIN:$PATH" MANUL_DIR="$START_RUNTIME" \
  "$SCRIPT_DIR/start-manul-automation.sh" stop >/dev/null 2>&1
STOP_RC=$?
set -e

if [ "$STOP_RC" -eq 0 ] && [ ! -f "$START_RUNTIME/.enabled" ]; then
  ok "start-manul-automation.sh stop returns 0 and disables runtime"
else
  fail "start-manul-automation.sh stop returned $STOP_RC or left .enabled behind"
fi

if [ ! -s "$CRONTAB_FILE" ] || ! grep -qF "$START_RUNTIME/watchdog.sh" "$CRONTAB_FILE"; then
  ok "Startup wrapper removes its watchdog on stop"
else
  fail "Startup wrapper left its watchdog installed after stop"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
