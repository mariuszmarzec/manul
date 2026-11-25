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
grep -q '"manul-zsh-bootstrap.sh"' "$SCRIPT_DIR/install-manul-symlinks.sh" && ok "Symlink installer deploys Zsh bootstrap" || fail "Symlink installer does not deploy Zsh bootstrap"
grep -q 'MANUL_ZSH_ENV_READY=1' "$SCRIPT_DIR/manul-shell.zsh" && ok "Interactive shell marks its initialized Zsh environment" || fail "Shell integration does not export the Zsh environment marker"
grep -q 'manul-zsh-bootstrap.sh' "$SCRIPT_DIR/watchdog.sh" && ok "Watchdog bootstraps ~/.zshrc from cron" || fail "Watchdog bypasses Zsh bootstrap"
grep -Fq '"$OPENCODE_BIN" mcp list)' "$SCRIPT_DIR/opencode-adapter.sh" && ok "Caracal MCP preflight uses the shared OpenCode server" || fail "Caracal MCP preflight does not use the shared OpenCode server"
grep -Fq '"$OPENCODE_BIN" debug agents)' "$SCRIPT_DIR/opencode-adapter.sh" && ok "OpenCode agent discovery uses the shared server" || fail "OpenCode agent discovery does not use the shared server"
grep -Fq '"$OPENCODE_BIN" run' "$SCRIPT_DIR/opencode-adapter.sh" && ok "OpenCode task runs use the shared server" || fail "OpenCode task run does not use the shared server"
grep -q '"manul-failure-utils.sh"' "$SCRIPT_DIR/install-manul-symlinks.sh" && ok "Symlink installer deploys failure sanitization helper" || fail "Symlink installer does not deploy failure sanitization helper"

grep -q 'manul-env.sh" --bootstrap' "$SCRIPT_DIR/install-manul.sh"   && ok "Installer bootstraps the operator environment"   || fail "Installer does not bootstrap the operator environment"

grep -q 'manul_env_load' "$SCRIPT_DIR/manul-daemon.sh"   && ok "Daemon loads Manul-specific integration fallbacks"   || fail "Daemon does not load Manul-specific integration fallbacks"

grep -q 'manul_env_load' "$SCRIPT_DIR/watchdog.sh"   && ok "Watchdog loads Manul-specific integration fallbacks"   || fail "Watchdog does not load Manul-specific integration fallbacks"

grep -q 'manul_env_load' "$SCRIPT_DIR/install-manul.sh"   && ok "Installer loads Manul-specific integration fallbacks"   || fail "Installer skips Manul integration fallbacks"
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
FITEO_BASE_URL="https://fiteo-test.example"
FITEO_MANUL_PAT="fiteo-test-pat"
FITEO_MANUL_SHARE_USER_ID="1"
FITEO_PAT="operator-pat-must-not-be-copied"
UNSAFE_SECRET="must-not-be-copied"
CUSTOM_JIRA_USER="custom-jira-user"
CUSTOM_JIRA_PASSWORD="custom-jira-password"
MANUL_HOST_SKILLS_DIR="$TMP/obsolete-skill-root"

cat > "$RUNTIME/config.json" <<'EOF'
{"taskSources":[{"type":"jira_tasks","enabled":true,"userEnv":"CUSTOM_JIRA_USER","passwordEnv":"CUSTOM_JIRA_PASSWORD"},{"type":"todo_remote_mcp","enabled":true,"tokenEnv":"FITEO_MANUL_PAT","shareUserIdEnv":"FITEO_MANUL_SHARE_USER_ID"}]}
EOF

export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_BIN OPENCODE_BIN OPENCODE_CONFIG CODEX_HOME CODEX_BIN CODEX_MODEL CLAUDE_CONFIG_DIR CLAUDE_BIN CLAUDE_MODEL FITEO_BASE_URL FITEO_MANUL_PAT FITEO_MANUL_SHARE_USER_ID FITEO_PAT UNSAFE_SECRET CUSTOM_JIRA_USER CUSTOM_JIRA_PASSWORD MANUL_HOST_SKILLS_DIR

ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$RUNTIME")"

[ -f "$ENV_FILE" ] && ok "Bootstrap creates ~/.manul/.env equivalent" || fail "Bootstrap did not create environment file"
assert_file_mode_600 "$ENV_FILE"

if grep -qE '^(OPENCLAW_STATE_DIR|OPENCLAW_CONFIG_PATH|OPENCLAW_HOME|OPENCLAW_GATEWAY_PORT|OPENCLAW_BIN|OPENCODE_BIN|CODEX_HOME|CODEX_BIN|CODEX_MODEL|CLAUDE_CONFIG_DIR|CLAUDE_BIN|CLAUDE_MODEL|MANUL_CANONICAL_DIR|MANUL_CANONICAL_ROOT|MANUL_CANONICAL_BRANCH)=' "$ENV_FILE"; then
  fail "Bootstrap duplicated shell-owned provider/path configuration in ~/.manul/.env"
else
  ok "Bootstrap leaves provider binaries/configuration and source paths to ~/.zshrc"
fi

if grep -qE '^(FITEO_BASE_URL|FITEO_MANUL_PAT|FITEO_MANUL_SHARE_USER_ID|CUSTOM_JIRA_USER|CUSTOM_JIRA_PASSWORD)=' "$ENV_FILE"; then
  fail "Bootstrap duplicated environment variables already supplied by the operator's Zsh"
else
  ok "Bootstrap does not duplicate Zsh-owned integration credentials"
fi

if grep -q 'UNSAFE_SECRET' "$ENV_FILE"; then
  fail "Bootstrap copied an arbitrary environment variable"
else
  ok "Bootstrap does not copy arbitrary environment variables"
fi

if grep -q '^MANUL_HOST_SKILLS_DIR=' "$ENV_FILE"; then
  fail "Bootstrap persisted an alternate skills root"
else
  ok "Bootstrap does not persist an alternate skills root"
fi

if (
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$RUNTIME"
  [ "$FITEO_BASE_URL" = "https://fiteo-test.example" ] &&
  [ "$FITEO_MANUL_PAT" = "fiteo-test-pat" ] &&
  [ "$FITEO_MANUL_SHARE_USER_ID" = "1" ] &&
  [ "$CUSTOM_JIRA_USER" = "custom-jira-user" ] &&
  [ "$CUSTOM_JIRA_PASSWORD" = "custom-jira-password" ]
); then
  ok "Zsh-exported integration credentials remain available after Manul environment loading"
else
  fail "Manul environment loading lost exported integration credentials"
fi

# Zsh exports win over legacy values in ~/.manul/.env, and PATH is never
# sourced from the runtime file.
PRECEDENCE="$TMP/precedence"
mkdir -p "$PRECEDENCE"
cat > "$PRECEDENCE/.env" <<'EOF'
PATH=/legacy/manul/path
OPENCODE_CONFIG=/legacy/opencode.json
OPENCODE_BIN=/legacy/bin/opencode
OPENCODE_API_KEY=legacy-console-key
LITELLM_MASTER_KEY=legacy-litellm-key
FITEO_BASE_URL=https://legacy-fiteo.example
EOF
chmod 600 "$PRECEDENCE/.env"
if (
  export PATH="$TMP/operator-zsh-bin:/usr/bin:/bin"
  export OPENCODE_CONFIG="$TMP/operator-opencode.json"
  export OPENCODE_BIN="$TMP/operator-bin/opencode"
  export OPENCODE_API_KEY="operator-console-key"
  export LITELLM_MASTER_KEY="operator-litellm-key"
  export FITEO_BASE_URL="https://operator-zsh.example"
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$PRECEDENCE"
  [ "$PATH" = "$TMP/operator-zsh-bin:/usr/bin:/bin" ] &&
  [ "$OPENCODE_CONFIG" = "$TMP/operator-opencode.json" ] &&
  [ "$OPENCODE_BIN" = "$TMP/operator-bin/opencode" ] &&
  [ "$OPENCODE_API_KEY" = "operator-console-key" ] &&
  [ "$LITELLM_MASTER_KEY" = "operator-litellm-key" ] &&
  [ "$FITEO_BASE_URL" = "https://operator-zsh.example" ]
); then
  ok "Exported ~/.zshrc environment takes precedence over legacy Manul values"
else
  fail "Manul environment loader overrode the operator's exported Zsh settings"
fi

if (
  unset OPENCODE_CONFIG OPENCODE_API_KEY LITELLM_MASTER_KEY
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$PRECEDENCE"
  [ "$OPENCODE_CONFIG" = "/legacy/opencode.json" ] &&
  [ -z "${OPENCODE_API_KEY:-}" ] &&
  [ -z "${LITELLM_MASTER_KEY:-}" ]
); then
  ok "Manul retains the non-secret OpenCode config path, but never loads legacy provider API keys"
else
  fail "Legacy provider API keys leaked from ~/.manul/.env"
fi

# Legacy Manul-owned values remain as fallbacks, but a current Zsh export wins.
SHARE_ONLY="$TMP/share-only"
mkdir -p "$SHARE_ONLY"
cat > "$SHARE_ONLY/.env" <<'MANUL_SHARE_ENV'
EXISTING_OPERATOR_SETTING=preserve-me
FITEO_PAT=old-operator-pat
FITEO_MANUL_SHARE_USER_ID=99
MANUL_SHARE_ENV
chmod 600 "$SHARE_ONLY/.env"
SHARE_ONLY_ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$SHARE_ONLY")"
if grep -qx 'FITEO_MANUL_SHARE_USER_ID=99' "$SHARE_ONLY_ENV_FILE" &&
   grep -qx 'EXISTING_OPERATOR_SETTING=preserve-me' "$SHARE_ONLY_ENV_FILE" &&
   ! grep -q '^FITEO_PAT=' "$SHARE_ONLY_ENV_FILE"; then
  ok "Bootstrap preserves Manul-owned fallbacks and removes retired operator credentials"
else
  fail "Bootstrap changed existing Manul fallbacks unexpectedly"
fi
if (
  export FITEO_MANUL_SHARE_USER_ID=1
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$SHARE_ONLY"
  [ "$FITEO_MANUL_SHARE_USER_ID" = "1" ]
); then
  ok "Current Zsh recipient ID overrides the stored Manul fallback"
else
  fail "Stored recipient ID overrode the current Zsh environment"
fi

PRESERVE="$TMP/preserve"
mkdir -p "$PRESERVE"
cat > "$PRESERVE/.env" <<'EOF'
OPENCLAW_STATE_DIR=/operator/chosen/state
OPENCODE_CONFIG=/operator/chosen/opencode.json
OPENCODE_API_KEY=legacy-console-key
LITELLM_MASTER_KEY=legacy-litellm-key
FITEO_MANUL_PAT=legacy-manul-token
FITEO_BASE_URL=https://legacy-fiteo.example
EOF
chmod 600 "$PRESERVE/.env"

OPENCLAW_STATE_DIR="/installer/current/state"
OPENCLAW_CONFIG_PATH="/installer/current/config.json"
OPENCODE_CONFIG="/installer/current/opencode.json"
export OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCODE_CONFIG
ENV_FILE2="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$PRESERVE")"

if (
  ! grep -qE '^(OPENCLAW_STATE_DIR|OPENCODE_API_KEY|LITELLM_MASTER_KEY)=' "$ENV_FILE2" &&
  grep -qx 'OPENCODE_CONFIG=/operator/chosen/opencode.json' "$ENV_FILE2" &&
  grep -qx 'FITEO_MANUL_PAT=legacy-manul-token' "$ENV_FILE2" &&
  grep -qx 'FITEO_BASE_URL=https://legacy-fiteo.example' "$ENV_FILE2"
); then
  ok "Bootstrap preserves the explicit OpenCode config path and Manul-specific credential fallbacks"
else
  fail "Bootstrap retained provider settings or removed Manul integration fallbacks"
fi
if (
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$PRESERVE"
  [ "$OPENCLAW_STATE_DIR" = "/installer/current/state" ] &&
  [ "$OPENCLAW_CONFIG_PATH" = "/installer/current/config.json" ] &&
  [ "$OPENCODE_CONFIG" = "/installer/current/opencode.json" ] &&
  [ "$FITEO_MANUL_PAT" = "legacy-manul-token" ] &&
  [ "$FITEO_BASE_URL" = "https://legacy-fiteo.example" ]
); then
  ok "Zsh provider exports win while Manul-specific fallback credentials remain available"
else
  fail "Provider exports or Manul integration fallbacks were not loaded correctly"
fi
if (
  unset OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCODE_CONFIG
  source "$ENV_FILE2"
  [ -z "${OPENCLAW_STATE_DIR:-}" ] &&
  [ "$OPENCODE_CONFIG" = "/operator/chosen/opencode.json" ] &&
  [ "$FITEO_MANUL_PAT" = "legacy-manul-token" ] &&
  [ "$FITEO_BASE_URL" = "https://legacy-fiteo.example" ]
); then
  ok "Explicit OpenCode config path remains a Manul fallback; API keys remain excluded"
else
  fail "Legacy provider configuration leaked from the Manul environment file"
fi

# Legacy Caracal variables are neither loaded nor retained by Manul.
LEGACY_CARACAL="$TMP/legacy-caracal"
mkdir -p "$LEGACY_CARACAL"
cat > "$LEGACY_CARACAL/.env" <<'EOF'
OPENCLAW_STATE_DIR=/operator/chosen/state
CARACAL_MCP_URL=http://127.0.0.1:1234/legacy
CARACAL_ACCESS_TOKEN=legacy-token
EOF
chmod 600 "$LEGACY_CARACAL/.env"
(
  unset CARACAL_MCP_URL CARACAL_ACCESS_TOKEN
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$LEGACY_CARACAL"
  if [ -z "${CARACAL_MCP_URL:-}" ] && [ -z "${CARACAL_ACCESS_TOKEN:-}" ]; then
    ok "Manul does not load legacy Caracal environment values"
  else
    fail "Manul loaded legacy Caracal environment values"
  fi
)
LEGACY_ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$LEGACY_CARACAL")"
if ! grep -qE '^[[:space:]]*(export[[:space:]]+)?(CARACAL_MCP_URL|CARACAL_ACCESS_TOKEN)=' "$LEGACY_ENV_FILE"; then
  ok "Bootstrap removes obsolete Caracal endpoint and token values"
else
  fail "Bootstrap retained obsolete Caracal credentials"
fi


# Existing Manul Fiteo fallback credentials are preserved; the live Zsh
# environment supersedes them for this invocation without writing duplicates.
PRESERVE_FITEO="$TMP/preserve-fiteo"
mkdir -p "$PRESERVE_FITEO"
cat > "$PRESERVE_FITEO/.env" <<'EOF'
FITEO_BASE_URL=https://old-fiteo.example
FITEO_PAT=old-operator-pat
FITEO_MANUL_PAT=old-manul-pat
EOF
chmod 600 "$PRESERVE_FITEO/.env"
FITEO_BASE_URL="https://new-fiteo.example"
FITEO_MANUL_PAT="new-manul-fiteo-pat"
FITEO_MANUL_SHARE_USER_ID="1"
export FITEO_BASE_URL FITEO_MANUL_PAT FITEO_MANUL_SHARE_USER_ID
FITEO_ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$PRESERVE_FITEO")"
if (
  grep -qx 'FITEO_BASE_URL=https://old-fiteo.example' "$FITEO_ENV_FILE" &&
  grep -qx 'FITEO_MANUL_PAT=old-manul-pat' "$FITEO_ENV_FILE" &&
  ! grep -q '^FITEO_PAT=' "$FITEO_ENV_FILE" &&
  ! grep -q 'new-fiteo.example' "$FITEO_ENV_FILE"
); then
  ok "Bootstrap retains only the manually-managed Fiteo fallback"
else
  fail "Bootstrap duplicated Zsh Fiteo values or retained the operator PAT"
fi
if (
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$PRESERVE_FITEO"
  [ "$FITEO_BASE_URL" = "https://new-fiteo.example" ] &&
  [ "$FITEO_MANUL_PAT" = "new-manul-fiteo-pat" ] &&
  [ "$FITEO_MANUL_SHARE_USER_ID" = "1" ]
); then
  ok "Current Zsh Fiteo credentials supersede Manul fallback values"
else
  fail "Manul fallback credentials overrode the operator's Zsh environment"
fi
assert_file_mode_600 "$FITEO_ENV_FILE"

# Legacy Todo credentials and obsolete host/provider settings are discarded
# without being loaded; Manul-specific integration fallbacks remain intact.
TODO_RUNTIME="$TMP/todo-legacy-credential-runtime"
mkdir -p "$TODO_RUNTIME"
cat > "$TODO_RUNTIME/.env" <<'EOF'
OPENCODE_CONFIG=/operator/chosen/opencode.json
TODO_LOCAL_MCP_TOKEN=legacy-fixture-value
EOF
chmod 600 "$TODO_RUNTIME/.env"
TODO_ENV_FILE="$(bash -c 'source "$1/manul-env.sh"; manul_env_bootstrap "$2"' _ "$SCRIPT_DIR" "$TODO_RUNTIME")"
if (
  ! grep -q 'TODO_LOCAL_MCP_TOKEN' "$TODO_ENV_FILE" &&
  grep -qx 'OPENCODE_CONFIG=/operator/chosen/opencode.json' "$TODO_ENV_FILE"
); then
  ok "Bootstrap discards retired Todo credentials while retaining the OpenCode config path"
else
  fail "Bootstrap retained retired credentials or host/provider configuration"
fi
assert_file_mode_600 "$TODO_ENV_FILE"

TODO_LOAD_RUNTIME="$TMP/todo-legacy-load-runtime"
mkdir -p "$TODO_LOAD_RUNTIME"
cat > "$TODO_LOAD_RUNTIME/.env" <<'EOF'
TODO_LOCAL_MCP_TOKEN=legacy-fixture-value
EOF
chmod 600 "$TODO_LOAD_RUNTIME/.env"
if (
  unset TODO_LOCAL_MCP_TOKEN
  source "$SCRIPT_DIR/manul-env.sh"
  manul_env_load "$TODO_LOAD_RUNTIME"
  [ -z "${TODO_LOCAL_MCP_TOKEN:-}" ]
); then
  ok "Environment loader never imports a legacy Todo credential"
else
  fail "Environment loader imported a legacy Todo credential"
fi

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
# Isolate that source in the test instead of relying on a global skill path.
# The installer validates the complete canonical script set. Populate an
# isolated canonical tree with the same files as the real skill source so this
# test exercises startup/symlink behavior rather than a deliberately incomplete
# fixture.
cp "$SCRIPT_DIR"/*.sh "$CANONICAL_RUNTIME/"
cp "$SCRIPT_DIR"/*.py "$CANONICAL_RUNTIME/"
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
MANUL_ZSH_ENV_READY=1 PATH="$FAKE_BIN:$PATH" MANUL_DIR="$START_RUNTIME" \
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
MANUL_ZSH_ENV_READY=1 PATH="$FAKE_BIN:$PATH" MANUL_DIR="$START_RUNTIME" \
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
