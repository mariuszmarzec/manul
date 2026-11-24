#!/usr/bin/env bash
# Regression coverage for the shared operator Zsh environment bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="$SCRIPT_DIR/manul-zsh-bootstrap.sh"
TEST_ROOT="$(mktemp -d /tmp/manul-zsh-bootstrap.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/bin"
cat > "$TEST_ROOT/home/.zshrc" <<'ZSHRC'
export MANUL_TEST_ZSHRC_LOADED="from-user-zshrc"
export OPENCODE_API_KEY="console-key-from-user-zshrc"
export PATH="$MANUL_TEST_PATH_PREFIX:$PATH"
ZSHRC

cat > "$TEST_ROOT/target.sh" <<'TARGET'
#!/usr/bin/env bash
set -euo pipefail
[ "${MANUL_ZSH_ENV_READY:-}" = "1" ] || exit 31
[ "${MANUL_TEST_ZSHRC_LOADED:-}" = "from-user-zshrc" ] || exit 32
[ "${OPENCODE_API_KEY:-}" = "console-key-from-user-zshrc" ] || exit 33
case "$PATH" in
  "$MANUL_TEST_PATH_PREFIX":*) ;;
  *) exit 34 ;;
esac
[ "$#" -eq 2 ] || exit 35
[ "$1" = "argument with spaces" ] || exit 36
[ "$2" = "second" ] || exit 37
printf 'TARGET_OK:%s:%s\n' "$MANUL_TEST_ZSHRC_LOADED" "$OPENCODE_API_KEY"
TARGET
chmod +x "$TEST_ROOT/target.sh"

# A deterministic fake Zsh lets this test run even in a minimal environment
# without a Zsh package. It sources the fixture .zshrc and executes the exact
# command script passed by the bootstrap.
cat > "$TEST_ROOT/bin/fake-zsh" <<'FAKE_ZSH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "-ic" ] || exit 41
shift
command_script="${1:-}"
shift
[ "${1:-}" = "manul-zsh-bootstrap" ] || exit 42
shift
[ -r "$HOME/.zshrc" ] || exit 43
# The fixture uses POSIX-compatible export statements, matching the relevant
# environment behavior of Zsh's .zshrc.
. "$HOME/.zshrc"
eval "$command_script"
FAKE_ZSH
chmod +x "$TEST_ROOT/bin/fake-zsh"

OUTPUT="$(
  HOME="$TEST_ROOT/home" \
  MANUL_TEST_PATH_PREFIX="$TEST_ROOT/operator-bin" \
  ZSH_BIN="$TEST_ROOT/bin/fake-zsh" \
  bash "$BOOTSTRAP" "$TEST_ROOT/target.sh" "argument with spaces" second
)"
[ "$OUTPUT" = "TARGET_OK:from-user-zshrc:console-key-from-user-zshrc" ] \
  && ok "Bootstrap loads the operator .zshrc and preserves argument boundaries" \
  || fail "Bootstrap did not pass the Zsh environment/arguments correctly: $OUTPUT"

# When Zsh is installed, also exercise the real interactive startup path. The
# minimal temporary .zshrc proves exported PATH/auth values reach the target.
if command -v zsh >/dev/null 2>&1; then
  REAL_OUTPUT="$(
    env -u ZDOTDIR HOME="$TEST_ROOT/home" \
      MANUL_TEST_PATH_PREFIX="$TEST_ROOT/real-operator-bin" \
      ZSH_BIN="$(command -v zsh)" \
      bash "$BOOTSTRAP" "$TEST_ROOT/target.sh" "argument with spaces" second
  )"
  [ "$REAL_OUTPUT" = "TARGET_OK:from-user-zshrc:console-key-from-user-zshrc" ] \
    && ok "Real Zsh -i startup sources ~/.zshrc and exports the operator environment" \
    || fail "Real Zsh bootstrap failed: $REAL_OUTPUT"
else
  echo "SKIP: real Zsh integration (zsh is not installed in this test environment)"
fi

# The marker prevents nested shells for commands already launched from
# manul-shell.zsh. Use a deliberately invalid ZSH_BIN to prove it is bypassed.
BYPASS_OUTPUT="$(
  HOME="$TEST_ROOT/home" \
  MANUL_ZSH_ENV_READY=1 \
  ZSH_BIN="$TEST_ROOT/bin/does-not-exist" \
  MANUL_TEST_ZSHRC_LOADED="already-loaded" \
  OPENCODE_API_KEY="already-exported-console-key" \
  bash "$BOOTSTRAP" bash -c 'printf "BYPASS:%s:%s\n" "$MANUL_TEST_ZSHRC_LOADED" "$OPENCODE_API_KEY"'
)"
[ "$BYPASS_OUTPUT" = "BYPASS:already-loaded:already-exported-console-key" ] \
  && ok "Initialized interactive sessions do not spawn a nested Zsh" \
  || fail "Initialized environment bootstrap did not bypass Zsh: $BYPASS_OUTPUT"

# Public entrypoints all share the same bootstrap contract.
grep -q 'manul-zsh-bootstrap.sh' "$SCRIPT_DIR/start-manul-automation.sh" || fail "Startup wrapper does not bootstrap Zsh"
grep -q 'manul-zsh-bootstrap.sh' "$SCRIPT_DIR/watchdog.sh" || fail "Watchdog does not bootstrap Zsh"
grep -q 'manul-zsh-bootstrap.sh' "$SCRIPT_DIR/manul-query.sh" || fail "Operator query does not bootstrap Zsh"
grep -q 'manul-zsh-bootstrap.sh' "$SCRIPT_DIR/manul-daemon.sh" || fail "Direct daemon execution does not bootstrap Zsh"
grep -q 'export MANUL_ZSH_ENV_READY=1' "$SCRIPT_DIR/manul-shell.zsh" || fail "Interactive shell does not export the readiness marker"
grep -q '"manul-zsh-bootstrap.sh"' "$SCRIPT_DIR/install-manul-symlinks.sh" || fail "Runtime installer does not deploy the bootstrap helper"
ok "Interactive, daemon, watchdog, query, and install paths use the common bootstrap"

echo "Results: $PASS passed"
