#!/usr/bin/env bash
# Regression tests for Manul mode=human.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MANUL_DIR="$TMP_ROOT/manul"
FAKE_BIN="$TMP_ROOT/.local/bin"
mkdir -p "$MANUL_DIR/state/locks" "$MANUL_DIR/state/tasks" "$MANUL_DIR/logs" "$MANUL_DIR/workspace" "$FAKE_BIN"

cat > "$MANUL_DIR/config.json" <<'JSON'
{
  "mode": "human",
  "commentStyle": {
    "human": {
      "concise": true,
      "maxLines": 4
    }
  },
  "automation": {
    "agentRuntime": "openclaw"
  }
}
JSON

GH_LOG="$TMP_ROOT/gh.log"
export GH_LOG
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/gh"

# Use a shell-function mock for the production comment helper. This avoids
# coupling the regression test to executable lookup while still exercising the
# real post_github_comment implementation.
gh() {
  printf '%s\n' "$*" >> "$GH_LOG"
  return 0
}

export HOME="$TMP_ROOT"
export PATH="$FAKE_BIN:$PATH"
export MANUL_DIR

# Production path loader must resolve and validate the configured mode.
source "$SCRIPT_DIR/manul-paths.sh"

if [ "$MANUL_MODE" != "human" ]; then
  echo "FAIL: expected configured mode=human, got '$MANUL_MODE'"
  exit 1
fi

# Source the production daemon in test mode so its real comment functions are used.
export MANUL_TESTING=true
source "$SCRIPT_DIR/manul-daemon.sh"

: > "$GH_LOG"
post_github_comment "owner/repo" "123" "human result"
if ! grep -qF 'human result' "$GH_LOG"; then
  echo "FAIL: human result was not posted"
  exit 1
fi
if grep -qF 'manul 🐈' "$GH_LOG"; then
  echo "FAIL: human mode added Manul signature"
  exit 1
fi

: > "$GH_LOG"
post_lifecycle_comment "owner/repo" "123" "🔄 working"
if [ -s "$GH_LOG" ]; then
  echo "FAIL: human mode published lifecycle/status comment"
  exit 1
fi

if ! grep -q 'mode: "human"' "$SCRIPT_DIR/../ai-commit-attribution/SKILL.md"; then
  echo "FAIL: commit attribution skill has no human-mode exception"
  exit 1
fi

# Default remains bot when mode is omitted.
sed '/"mode": "human",/d' "$MANUL_DIR/config.json" > "$MANUL_DIR/config-bot.json"
cp "$MANUL_DIR/config-bot.json" "$MANUL_DIR/config.json"
unset MANUL_MODE
source "$SCRIPT_DIR/manul-paths.sh"
if [ "$MANUL_MODE" != "bot" ]; then
  echo "FAIL: omitted mode did not default to bot"
  exit 1
fi

: > "$GH_LOG"
post_github_comment "owner/repo" "123" "bot result"
if ! grep -qF 'bot result' "$GH_LOG" || ! grep -qF 'manul 🐈' "$GH_LOG"; then
  echo "FAIL: bot mode did not retain Manul signature"
  exit 1
fi

# Production prompt must include the configured human comment-style guidance.
if ! grep -qF -- '## Result comment style' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon prompt has no result comment style section"
  exit 1
fi
if ! grep -qF -- 'lead with what was done or found' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon prompt lacks concise human guidance"
  exit 1
fi
if ! grep -qF -- 'do not use automation headings or fields' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon prompt does not discourage automation boilerplate"
  exit 1
fi
if ! grep -qF -- '__HUMAN_COMMENT_MAX_LINES__' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon prompt has no configurable human comment line limit"
  exit 1
fi
if ! grep -qF -- '.commentStyle.human.concise' "$SCRIPT_DIR/manul-daemon.sh"; then
  echo "FAIL: daemon does not read human comment style configuration"
  exit 1
fi

echo "PASS: human mode suppresses orchestration comments/signature and bot remains the default"
