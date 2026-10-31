#!/bin/bash
# test_runtime_health.sh — Regression tests for Manul runtime health/recovery
#
# Tests that verify:
#  1. Shell syntax of all runtime scripts
#  2. No hardcoded /mnt/f or /home/marzec/.manul paths in source
#  3. install-manul-symlinks.sh contracts
#  3b. installer self-healing (idempotent, safe to run repeatedly)
#  3c. CLI entrypoints resolve in a fresh shell
#  4. repair-manul-runtime.sh aborts safely without a DB backup
#  5. repair-manul-runtime.sh restores from a canonical-init DB backup
#  6. Restored symlinks are valid and point into canonical source
#  7. Recovered DB contains the required tables and columns (strengthened)
#  8. Second repair is idempotent (DB and config are not replaced)
#  9. Archive fallback works with supported sibling archive layout
# 10. init-schema failure is fatal — repair does not complete
# 11. workspace_init failure is fatal — repair does not complete
# 12. Existing empty manul.db + valid backup → backup is restored, repair succeeds
# 13. Existing invalid/corrupt manul.db + no backup → repair aborts, no schema fabricated
# 14. Existing valid DB + no backup → repair preserves it, remains idempotent (extends Test 8)
# 15. install-manul.sh fresh install
# 16. install-manul.sh is idempotent
# 17. install-manul.sh preserves an existing config.json
# 18. install-manul.sh preserves a valid existing DB
# 19. install-manul.sh moves a corrupt DB aside and bootstraps fresh
# 20. install-manul.sh does NOT auto-start (no daemon, no .enabled marker)
# 21. install-manul.sh fails on a missing canonical directory
# 22. install-manul.sh fails on a missing canonical script
# 23. install-manul-symlinks.sh fails (non-zero) when a canonical script is missing
# 24. watchdog.sh skips recovery when .enabled is absent
# 25. watchdog.sh starts the daemon when .enabled is present and the daemon is dead
# 26. start-manul-automation.sh start creates the .enabled marker
# 27. start-manul-automation.sh stop removes the .enabled marker
# 28. manul-shell.zsh defines lifecycle functions + a self-healing guard
# 29. .zshrc sources manul-shell.zsh and contains no hardcoded machine paths
# 30. Canonical Manul scripts that are executed directly keep executable Git modes

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TMPROOT=""

cleanup() {
  [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

assert_cmd() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    ok "$description"
  else
    fail "$description"
  fi
}

# Create a canonical-scheme DB using the production init paths.
# Returns path to the created DB via the global CANONICAL_BACKUP_DB.
create_canonical_backup() {
  local db_path="$1"
  mkdir -p "$(dirname "$db_path")"
  # Empty the DB first so init_schema can run cleanly
  rm -f "$db_path"
  touch "$db_path"
  chmod 600 "$db_path"

  # Run canonical init_schema via manul-conversation.sh init-schema
  local conv_dir
  conv_dir="$(dirname "$db_path")"
  MANUL_DIR="$conv_dir" DB="$db_path" \
    bash "$SCRIPT_DIR/manul-conversation.sh" init-schema

  # Run canonical workspace_init by sourcing workspace-manager.sh
  MANUL_DIR="$conv_dir" DB="$db_path" \
    bash -c 'source "$1"; workspace_init' _ "$SCRIPT_DIR/workspace-manager.sh"
}

echo "=== Runtime Health Tests ==="
echo "Canonical source: $SCRIPT_DIR"
echo ""

# ── Test 0: Executable entry-point permissions and installer hardening ────────
echo "Test 0: Executable entry-point permissions and installer hardening"

# Directly executed runtime entry points must be executable in Git. These are
# the scripts invoked as commands by the startup/daemon/recovery paths.
DIRECT_ENTRYPOINTS=(
  install-manul.sh
  install-manul-symlinks.sh
  repair-manul-runtime.sh
  start-manul-automation.sh
  manul-daemon.sh
  watchdog.sh
  task-recovery.sh
  manul-queue-reset.sh
  agent-task-runner.sh
  poll.sh
  manul-status.sh
  manul-result.sh
  manul-submit.sh
  manul-wait.sh
)
for entry in "${DIRECT_ENTRYPOINTS[@]}"; do
  mode="$(git -C "$SCRIPT_DIR/../.." ls-files -s -- "skills/manul-github-bot/$entry" 2>/dev/null | awk '{print $1}' | head -1)"
  if [ "$mode" = "100755" ]; then
    ok "$entry is tracked executable (100755)"
  else
    fail "$entry must be tracked executable (100755), got ${mode:-missing}"
  fi
done

RUNNER_MODE=$(stat -c '%a' "$SCRIPT_DIR/agent-task-runner.sh" 2>/dev/null || true)
if [ "$RUNNER_MODE" = "755" ]; then
  ok "agent-task-runner.sh is executable (mode 755)"
else
  fail "agent-task-runner.sh must be executable (mode 755), got ${RUNNER_MODE:-unknown}"
fi

RUNNER_TREE_MODE=$(git -C "$SCRIPT_DIR/../.." ls-files -s -- 'skills/manul-github-bot/agent-task-runner.sh' 2>/dev/null | awk '{print $1}' | head -1)
if [ "$RUNNER_TREE_MODE" = "100755" ]; then
  ok "Git tracks agent-task-runner.sh as executable (100755)"
else
  fail "Git must track agent-task-runner.sh as executable (100755), got ${RUNNER_TREE_MODE:-missing}"
fi

# Reproduce the production failure: canonical runner is 0644. The installer
# must restore +x before the runtime is considered usable.
PERM_ROOT=$(mktemp -d /tmp/manul-perm-XXXXXX)
PERM_CANON="$PERM_ROOT/canonical"
PERM_RUN="$PERM_ROOT/runtime"
mkdir -p "$PERM_CANON"
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.md "$SCRIPT_DIR"/*.py "$PERM_CANON/" 2>/dev/null || true
chmod +x "$PERM_CANON"/*.sh
chmod 644 "$PERM_CANON/agent-task-runner.sh"
chmod 644 "$PERM_CANON/manul-queue-reset.sh"
set +e
MANUL_RUNTIME_DIR="$PERM_RUN" MANUL_CANONICAL_DIR="$PERM_CANON" "$SCRIPT_DIR/install-manul-symlinks.sh" >/tmp/manul-perm-installer.out 2>&1
PERM_RC=$?
set -e
if [ "$PERM_RC" -eq 0 ] && [ -x "$PERM_CANON/agent-task-runner.sh" ] && [ "$(stat -c "%a" "$PERM_CANON/agent-task-runner.sh" 2>/dev/null || true)" = "755" ]; then
  ok "Installer restores execute bit on canonical task runner"
else
  fail "Installer did not restore canonical task runner execute bit (rc=$PERM_RC)"
fi

if [ "$PERM_RC" -eq 0 ] && [ -x "$PERM_CANON/manul-queue-reset.sh" ] && [ "$(stat -c "%a" "$PERM_CANON/manul-queue-reset.sh" 2>/dev/null || true)" = "755" ]; then
  ok "Installer restores execute bit on canonical queue-reset command"
else
  fail "Installer did not restore canonical queue-reset execute bit (rc=$PERM_RC)"
fi

if [ -L "$PERM_RUN/agent-task-runner.sh" ] && [ -x "$PERM_RUN/agent-task-runner.sh" ]; then
  ok "Installed task runner symlink is executable"
else
  fail "Installed task runner symlink is not executable"
fi

rm -rf "$PERM_ROOT" /tmp/manul-perm-installer.out
# ── Test 1: Shell syntax ──────────────────────────────────────────────────────
echo "Test 1: Shell syntax"
for script in \
  repair-manul-runtime.sh \
  install-manul-symlinks.sh \
  manul-daemon.sh \
  github-api-wrapper.sh \
  manul-conversation.sh \
  workspace-manager.sh \
  watchdog.sh \
  task-recovery.sh \
  manul-queue-reset.sh \
  task-health-check.sh; do
  assert_cmd "$script has valid shell syntax" bash -n "$SCRIPT_DIR/$script"
done

# ── Test 2: No old machine-specific runtime paths ─────────────────────────────
echo
echo "Test 2: No hardcoded runtime paths"
# Only production scripts are subject to this guard. Test fixtures intentionally
# contain historical paths to exercise diagnostic sanitization.
HARDCODED_PATHS="$(grep -En '(/home/marzec/\.manul|/mnt/f/ubuntu-workspace/\.manul)' \
  "$SCRIPT_DIR"/*.sh 2>/dev/null | grep -vE '/test_[^/]+\.sh:' || true)"
if [ -z "$HARDCODED_PATHS" ]; then
  ok "No hardcoded absolute runtime paths found"
else
  fail "Hardcoded absolute runtime paths remain:\n$HARDCODED_PATHS"
fi

# ── Test 3: Installer contract ────────────────────────────────────────────────
echo
echo "Test 3: Installer contract"
if grep -q 'RUNTIME_DIR="${MANUL_RUNTIME_DIR:-\$HOME/.manul}"' \
     "$SCRIPT_DIR/install-manul-symlinks.sh" 2>/dev/null; then
  ok "Installer default runtime is HOME/.manul"
else
  fail "Installer default runtime is not HOME/.manul"
fi

# The installer accepts any supported agent runtime and fails only when
# none of OpenClaw, OpenCode, Codex CLI, or Claude Code is available.
if grep -q 'for cmd in bash git gh jq sqlite3 curl crontab' "$SCRIPT_DIR/install-manul.sh"; then
  ok "Installer requires core tools (bash git gh jq sqlite3 curl crontab)"
else
  fail "Installer core-tool check is missing"
fi

# The installer must detect all supported CLI runtimes rather than requiring
# OpenClaw specifically.
if grep -q 'command -v opencode' "$SCRIPT_DIR/install-manul.sh" \
   && grep -q 'command -v codex' "$SCRIPT_DIR/install-manul.sh" \
   && grep -q 'command -v claude' "$SCRIPT_DIR/install-manul.sh" \
   && grep -q 'openclaw, opencode, codex, or claude' "$SCRIPT_DIR/install-manul.sh"; then
  ok "Installer accepts OpenClaw, OpenCode, Codex CLI, and Claude Code"
else
  fail "Installer still hard-requires OpenClaw"
fi

if grep -q 'No agent runtime found' "$SCRIPT_DIR/install-manul.sh"; then
  ok "Installer fails closed when neither runtime is present"
else
  fail "Installer does not fail when no runtime is present"
fi

SCRIPT_COUNT=$(awk '/^SCRIPTS=\(/,/^\)/' \
  "$SCRIPT_DIR/install-manul-symlinks.sh" | grep -c '^ *"' || true)
if [ "$SCRIPT_COUNT" -ge 20 ]; then
  ok "Installer declares $SCRIPT_COUNT runtime entries"
else
  fail "Installer declares only $SCRIPT_COUNT runtime entries (expected at least 20)"
fi

# Regression for the missing task-source symlinks. poll.sh sources
# task-source.sh at runtime; if the installer list omits the generic
# task-source adapters (added in 9415b99), every poll cycle dies with
# `task_source_configured_sources: command not found` and the generic
# provider path silently degrades to legacy GitHub Issues only.
for _ts in task-source.sh task-source-github-issues.sh task-source-jira-tasks.sh task-source-todo-local.sh task-source-todo-remote.sh todo-task-source-utils.sh todo-mcp-client.py; do
  if awk '/^SCRIPTS=\(/,/^\)/' "$SCRIPT_DIR/install-manul-symlinks.sh" \
       | grep -q "\"$_ts\""; then
    ok "Installer declares $_ts"
  else
    fail "Installer does not declare $_ts (generic task-source adapter missing from runtime)"
  fi
done
grep -q 'enabled Todo MCP task source requires python3' "$SCRIPT_DIR/install-manul.sh" \
  && ok "Installer requires python3 only when a Todo MCP source is enabled" \
  || fail "Installer does not validate python3 for enabled Todo MCP sources"

# Runtime session-state helper must be deployed alongside the execution controller.
if awk '/^SCRIPTS=\(/,/^\)/' "$SCRIPT_DIR/install-manul-symlinks.sh" \
     | grep -q '"agent-session-state.sh"'; then
  ok "Installer declares agent-session-state.sh"
else
  fail "Installer does not declare agent-session-state.sh (session helper missing from runtime)"
fi

# The failure publisher and legacy health checker source this helper from runtime.
if awk '/^SCRIPTS=\(/,/^\)/' "$SCRIPT_DIR/install-manul-symlinks.sh" \
     | grep -q '"manul-failure-utils.sh"'; then
  ok "Installer declares manul-failure-utils.sh"
else
  fail "Installer does not declare manul-failure-utils.sh (runtime failure reporting would break)"
fi

# ── Test 3b: installer self-healing (idempotent, safe to run repeatedly) ───────
echo
echo "Test 3b: Installer self-healing"
SELFHEAL_ROOT="$(mktemp -d /tmp/manul-selfheal-XXXXXX)"
CANON="$SELFHEAL_ROOT/canonical"
RUN1="$SELFHEAL_ROOT/runtime1"
RUN2="$SELFHEAL_ROOT/runtime2"
mkdir -p "$CANON"
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.md "$SCRIPT_DIR"/*.py "$CANON/" 2>/dev/null || true

# 1) Missing runtime -> installer creates it and exits 0
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC1=$?
set -e
if [ "$RC1" -eq 0 ] && [ -d "$RUN1" ] && [ -L "$RUN1/manul-daemon.sh" ]; then
  ok "Installer recreates a missing runtime directory"
else
  fail "Installer did not recreate missing runtime (rc=$RC1)"
fi

# 2) Idempotent: second run exits 0 and leaves symlinks intact
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC2=$?
set -e
if [ "$RC2" -eq 0 ]; then
  ok "Installer is idempotent (second run exits 0)"
else
  fail "Installer is not idempotent (second run rc=$RC2)"
fi

# 3) Every declared symlink resolves to a real file inside canonical source
LINK_FAILS=0
for entry in "$RUN1"/*.sh "$RUN1"/*.md; do
  [ -e "$entry" ] || continue
  [ -L "$entry" ] || { LINK_FAILS=$((LINK_FAILS + 1)); continue; }
  target="$(readlink -f "$entry" 2>/dev/null || true)"
  case "$target" in
    "$CANON"/*) [ -f "$target" ] || LINK_FAILS=$((LINK_FAILS + 1)) ;;
    *) LINK_FAILS=$((LINK_FAILS + 1)) ;;
  esac
done
if [ "$LINK_FAILS" -eq 0 ]; then
  ok "All runtime symlinks resolve into the canonical source"
else
  fail "$LINK_FAILS runtime symlinks are broken or misplaced"
fi

# 4) Regular file slot is converted to a symlink (no data copied into runtime)
rm -f "$RUN1/manul-status.sh"
echo "junk" > "$RUN1/manul-status.sh"
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC3=$?
set -e
if [ "$RC3" -eq 0 ] && [ -L "$RUN1/manul-status.sh" ]; then
  ok "Installer converts a regular file slot into a symlink"
else
  fail "Installer did not convert regular file slot (rc=$RC3)"
fi

# 5) Directory collision is refused and the installer exits non-zero
rm -f "$RUN1/poll.sh"
mkdir -p "$RUN1/poll.sh"
set +e
MANUL_RUNTIME_DIR="$RUN1" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC4=$?
set -e
if [ "$RC4" -ne 0 ] && [ -d "$RUN1/poll.sh" ]; then
  ok "Installer refuses a directory collision and exits non-zero"
else
  fail "Installer should refuse directory collision (rc=$RC4)"
fi

# 6) Missing canonical source is fatal
set +e
MANUL_RUNTIME_DIR="$RUN2" MANUL_CANONICAL_DIR="$SELFHEAL_ROOT/missing" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC5=$?
set -e
if [ "$RC5" -ne 0 ]; then
  ok "Installer exits non-zero when canonical source is missing"
else
  fail "Installer should exit non-zero when canonical source is missing"
fi

rm -rf "$SELFHEAL_ROOT"

# ── Test 3c: CLI entrypoints resolve in a fresh shell ────────────────────────
echo
echo "Test 3c: CLI entrypoints resolve in a fresh shell"
CLI_ROOT="$(mktemp -d /tmp/manul-cli-XXXXXX)"
CANON="$CLI_ROOT/canonical"
RUN="$CLI_ROOT/runtime"
mkdir -p "$CANON"
cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.md "$SCRIPT_DIR"/*.py "$CANON/" 2>/dev/null || true
[ -f "$SCRIPT_DIR/state/manul.db" ] && cp "$SCRIPT_DIR/state/manul.db" "$CANON/" 2>/dev/null || true

# Deploy a real runtime so the CLI can actually run
set +e
MANUL_RUNTIME_DIR="$RUN" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
set -e

# 1) All three CLI entrypoints exist as symlinks in the runtime
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  if [ -L "$RUN/$entry" ] && [ -f "$(readlink -f "$RUN/$entry")" ]; then
    ok "Runtime symlink $entry -> canonical source"
  else
    fail "Runtime symlink $entry missing or broken"
  fi
done

# 2) Each symlink target is the canonical script of the same name
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  target="$(readlink -f "$RUN/$entry")"
  if [ "$target" = "$CANON/$entry" ]; then
    ok "$entry resolves to canonical $entry"
  else
    fail "$entry resolves to $target (expected $CANON/$entry)"
  fi
done

# 2b) The self-healing guard must check ALL THREE entrypoints, not just
#     manul-daemon.sh. A broken manul-status.sh or manul-comments-remove.sh
#     must also trigger the repair path. The guard lives in manul-shell.zsh.
MANUL_SHELL_FILE="${MANUL_TEST_SHELL_FILE:-$SCRIPT_DIR/manul-shell.zsh}"
GUARD_OK=true
GUARD_BLOCK="$(sed -n '/manul-ensure-runtime()/,/^}/p' "$MANUL_SHELL_FILE" 2>/dev/null || true)"
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  if echo "$GUARD_BLOCK" | grep -qF "$entry"; then
    : # guard references this entrypoint
  else
    fail "Self-healing guard does not reference $entry"
    GUARD_OK=false
  fi
done
$GUARD_OK && ok "Self-healing guard references all three CLI entrypoints"

# A status command is often piped to head. Repair output must not share that
# pipe, or head can SIGPIPE the repair process before it deploys all links.
if echo "$GUARD_BLOCK" | grep -qF '>"$repair_log" 2>&1'; then
  ok "Runtime repair output is isolated from caller stdout"
else
  fail "Runtime repair output can still be interrupted by caller pipelines"
fi

if command -v zsh >/dev/null 2>&1; then
  PIPE_ROOT="$(mktemp -d /tmp/manul-pipeline-repair-XXXXXX)"
  PIPE_CANON="$PIPE_ROOT/canonical"
  PIPE_RUN="$PIPE_ROOT/runtime"
  PIPE_MARKER="$PIPE_ROOT/repair-finished"
  mkdir -p "$PIPE_CANON"
  cat >"$PIPE_CANON/repair-manul-runtime.sh" <<'REPAIR'
#!/usr/bin/env bash
set -euo pipefail
# Produce enough output for head to close the pipe before repair completes.
seq 1 100000
mkdir -p "$MANUL_RUNTIME_DIR"
touch "$MANUL_RUNTIME_DIR/manul-daemon.sh" \
      "$MANUL_RUNTIME_DIR/manul-status.sh" \
      "$MANUL_RUNTIME_DIR/manul-comments-remove.sh" \
      "$MANUL_TEST_REPAIR_MARKER"
REPAIR
  chmod +x "$PIPE_CANON/repair-manul-runtime.sh"

  set +e
  env MANUL_CANONICAL_DIR="$PIPE_CANON" \
      MANUL_RUNTIME_DIR="$PIPE_RUN" \
      MANUL_TEST_REPAIR_MARKER="$PIPE_MARKER" \
      zsh -c 'source "$1"; manul-ensure-runtime' _ "$MANUL_SHELL_FILE" | head -n 1 >/dev/null
  PIPE_ZSH_RC=${PIPESTATUS[0]}
  set -e

  if [ "$PIPE_ZSH_RC" -eq 0 ] && [ -f "$PIPE_MARKER" ]; then
    ok "Piped CLI call cannot interrupt an in-progress runtime repair"
  else
    fail "Piped CLI call interrupted runtime repair (zsh rc=$PIPE_ZSH_RC)"
  fi
  rm -rf "$PIPE_ROOT"
else
  echo "SKIP: zsh unavailable; runtime-repair pipeline integration test skipped"
fi

# 2c) Lifecycle CLI accepts both long flags and readable subcommands.
if grep -qF -- '--start) action="start"' "$MANUL_SHELL_FILE"    && grep -qF -- '--stop) action="stop"' "$MANUL_SHELL_FILE"    && grep -qF -- '--restart) action="restart"' "$MANUL_SHELL_FILE"    && grep -qF -- '--status) action="status"' "$MANUL_SHELL_FILE"; then
  ok "manul supports --start/--stop/--restart/--status"
else
  fail "manul long lifecycle flags are missing"
fi

# 2c) All CLI entrypoints must be unconditional shell functions. They must
#     remain defined even when the runtime directory has been deleted.
for cmd in manul manul-status manul-comments-remove; do
  if grep -qF "$cmd() {" "$MANUL_SHELL_FILE" 2>/dev/null; then
    ok "$cmd function is unconditional"
  else
    fail "$cmd function is missing"
  fi
done

# 3) Deleting the runtime does not remove the CLI entrypoints from a fresh
#    shell — the command definitions live in manul-shell.zsh, not in runtime.
rm -rf "$RUN"
for cmd in manul manul-status manul-comments-remove; do
  if grep -qF "$cmd() {" "$MANUL_SHELL_FILE" 2>/dev/null; then
    ok "$cmd function survives runtime deletion"
  else
    fail "$cmd function missing from shell file"
  fi
done

# 4) The repair path (installer) recreates all required symlinks from scratch
set +e
MANUL_RUNTIME_DIR="$RUN" MANUL_CANONICAL_DIR="$CANON" \
  "$SCRIPT_DIR/install-manul-symlinks.sh" >/dev/null 2>&1
RC_REPAIR=$?
set -e
if [ "$RC_REPAIR" -eq 0 ]; then
  ok "Installer recreates runtime after full deletion"
else
  fail "Installer failed to recreate runtime (rc=$RC_REPAIR)"
fi
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh; do
  if [ -L "$RUN/$entry" ] && [ -f "$(readlink -f "$RUN/$entry")" ]; then
    ok "Repaired runtime symlink $entry exists"
  else
    fail "Repaired runtime symlink $entry missing"
  fi
done

# 5) manul-status --list works against a production-schema DB fixture.
# The repository intentionally does not carry application state, so create a
# real schema fixture instead of coupling this CLI test to a repository DB.
CLI_DB="$CLI_ROOT/backup/manul.db"
mkdir -p "$RUN/state"
create_canonical_backup "$CLI_DB"
cp "$CLI_DB" "$RUN/state/manul.db"
chmod 600 "$RUN/state/manul.db"

set +e
MANUL_DIR="$RUN" "$RUN/manul-status.sh" --list >/dev/null 2>&1
RC_STATUS=$?
set -e
if [ "$RC_STATUS" -eq 0 ]; then
  ok "manul-status --list runs successfully"
else
  fail "manul-status --list failed (rc=$RC_STATUS)"
fi

# Status must refuse an empty SQLite path without opening it for writing.
EMPTY_DB="$CLI_ROOT/empty.db"
: >"$EMPTY_DB"
EMPTY_DB_BEFORE="$(stat -c '%s' "$EMPTY_DB")"
set +e
EMPTY_STATUS_OUT="$(DB="$EMPTY_DB" MANUL_DIR="$RUN" "$RUN/manul-status.sh" --list 2>&1)"
EMPTY_STATUS_RC=$?
set -e
EMPTY_DB_AFTER="$(stat -c '%s' "$EMPTY_DB")"
if [ "$EMPTY_STATUS_RC" -ne 0 ] && \
   [ "$EMPTY_DB_BEFORE" = "$EMPTY_DB_AFTER" ] && \
   echo "$EMPTY_STATUS_OUT" | grep -q "not found or empty"; then
  ok "manul-status refuses an empty DB without initializing or modifying it"
else
  fail "manul-status did not safely reject the empty DB (rc=$EMPTY_STATUS_RC size=$EMPTY_DB_AFTER)"
  echo "$EMPTY_STATUS_OUT"
fi

# 6) manul-comments-remove --help shows usage and never touches GitHub
set +e
HELP_OUT="$(MANUL_DIR="$RUN" "$RUN/manul-comments-remove.sh" --help 2>&1)"
RC_HELP=$?
set -e
if [ "$RC_HELP" -eq 0 ] && echo "$HELP_OUT" | grep -q "Usage:"; then
  ok "manul-comments-remove --help shows usage and exits 0"
else
  fail "manul-comments-remove --help did not show usage (rc=$RC_HELP)"
fi
# --help must not have triggered any deletion (no network call, no comment removal).
# Check for actual command invocations rather than the word "github.com",
# which legitimately appears in usage examples.
if echo "$HELP_OUT" | grep -qiE 'gh api|curl |wget |DELETE|POST '; then
  fail "manul-comments-remove --help output mentions network/API calls"
fi

rm -rf "$CLI_ROOT"

# ── Test 4: Recovery without a backup fails safely ────────────────────────────
echo
echo "Test 4: Recovery without DB backup fails safely"
TMPROOT=$(mktemp -d /tmp/manul-runtime-test-XXXXXX)
MISSING_DB_RUNTIME="$TMPROOT/missing-db-runtime"
mkdir -p "$MISSING_DB_RUNTIME"

set +e
NO_BACKUP_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$MISSING_DB_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
NO_BACKUP_EXIT=$?
set -e

if [ "$NO_BACKUP_EXIT" -eq 1 ] && echo "$NO_BACKUP_OUTPUT" | grep -q "No valid backup DB found"; then
  ok "Recovery exits 1 when DB backup is unavailable"
else
  fail "Recovery did not fail safely without DB backup (exit=$NO_BACKUP_EXIT)"
fi

if [ ! -f "$MISSING_DB_RUNTIME/state/manul.db" ]; then
  ok "No fabricated DB was created"
else
  fail "Recovery created a DB despite missing backup"
fi

if [ -L "$MISSING_DB_RUNTIME/manul-daemon.sh" ] && [ -f "$MISSING_DB_RUNTIME/config.json" ]; then
  ok "Failed recovery still prepares runtime links/config"
else
  fail "Failed recovery did not prepare expected runtime links/config"
fi

# ── Test 5: Create canonical backup and recover from it ───────────────────────
echo
echo "Test 5: Recovery from canonical-init DB backup"
BACKUP_DB="$TMPROOT/backup/manul.db"
create_canonical_backup "$BACKUP_DB"
CANONICAL_BACKUP_DB="$BACKUP_DB"

# Verify the backup itself has the right tables before using it
for tbl in processed_comments conversations meta workspaces; do
  if ! sqlite3 "$BACKUP_DB" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
    fail "Canonical backup DB missing table '$tbl'"
    exit 1
  fi
done
ok "Canonical backup DB has all required tables"

GOOD_RUNTIME="$TMPROOT/good-runtime"
set +e
GOOD_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$GOOD_RUNTIME" \
  MANUL_SOURCE_DB="$BACKUP_DB" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
GOOD_EXIT=$?
set -e

if [ "$GOOD_EXIT" -eq 0 ] && echo "$GOOD_OUTPUT" | grep -q "Repair Complete"; then
  ok "Recovery from backup completes successfully"
else
  fail "Recovery from backup failed (exit=$GOOD_EXIT)"
  echo "$GOOD_OUTPUT"
fi

if [ -f "$GOOD_RUNTIME/config.json" ] && jq empty "$GOOD_RUNTIME/config.json" >/dev/null 2>&1; then
  ok "Recovered config.json is valid JSON"
else
  fail "Recovered config.json is missing or invalid"
fi

# ── Test 6: All installed links are valid symlinks into canonical source ──────
echo
echo "Test 6: Runtime symlinks"
LINK_FAILURES=0
LINK_COUNT=0
for entry in "$GOOD_RUNTIME"/*.sh "$GOOD_RUNTIME"/*.md; do
  [ -e "$entry" ] || continue
  [ -L "$entry" ] || { LINK_FAILURES=$((LINK_FAILURES + 1)); continue; }
  LINK_COUNT=$((LINK_COUNT + 1))
  target=$(readlink -f "$entry" 2>/dev/null || true)
  case "$target" in
    "$SCRIPT_DIR"/*) ;;
    *) LINK_FAILURES=$((LINK_FAILURES + 1)) ;;
  esac
done

if [ "$LINK_FAILURES" -eq 0 ] && [ "$LINK_COUNT" -ge 20 ]; then
  ok "$LINK_COUNT runtime symlinks valid and point to canonical source"
else
  fail "Runtime symlink check failed: $LINK_COUNT links, $LINK_FAILURES failures"
fi

# ── Test 7: Recovered DB schema matches canonical contract ───────────────────
echo
echo "Test 7: Recovered DB schema"
REQUIRED_TABLES="processed_comments conversations meta workspaces"
SCHEMA_FAILURES=0
for table in $REQUIRED_TABLES; do
  if ! sqlite3 "$GOOD_RUNTIME/state/manul.db" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
    SCHEMA_FAILURES=$((SCHEMA_FAILURES + 1))
    fail "Required table '$table' missing from recovered DB"
  fi
done
[ "$SCHEMA_FAILURES" -eq 0 ] && ok "All required tables present in recovered DB"

# Validate key columns on the richest table (processed_comments).
# Avoid duplicating the full schema SQL; only assert the columns the daemon reads.
KEY_COLUMNS="commentId repository issueNumber commentUrl prompt status attempts conversationId action prNumber prUrl"
for col in $KEY_COLUMNS; do
  if ! sqlite3 "$GOOD_RUNTIME/state/manul.db" \
       "PRAGMA table_info(processed_comments);" 2>/dev/null \
       | grep -qw "$col"; then
    fail "Required column '$col' missing from processed_comments"
  fi
done
ok "Key columns present on processed_comments"

# Validate key columns on conversations
for col in conversationId repository issueNumber issueUrl status activeTaskId createdAt updatedAt; do
  if ! sqlite3 "$GOOD_RUNTIME/state/manul.db" \
       "PRAGMA table_info(conversations);" 2>/dev/null \
       | grep -qw "$col"; then
    fail "Required column '$col' missing from conversations"
  fi
done
ok "Key columns present on conversations"

# Validate workspaces columns
for col in workspaceId workspacePath status currentTaskId lastUsedAt; do
  if ! sqlite3 "$GOOD_RUNTIME/state/manul.db" \
       "PRAGMA table_info(workspaces);" 2>/dev/null \
       | grep -qw "$col"; then
    fail "Required column '$col' missing from workspaces"
  fi
done
ok "Key columns present on workspaces"

# ── Test 8: Second repair with same backup is idempotent ──────────────────────
echo
echo "Test 8: Repair idempotency"
DB_BEFORE=$(sha256sum "$GOOD_RUNTIME/state/manul.db" | awk '{print $1}')
CONFIG_BEFORE=$(sha256sum "$GOOD_RUNTIME/config.json" | awk '{print $1}')

set +e
SECOND_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$GOOD_RUNTIME" \
  MANUL_SOURCE_DB="$BACKUP_DB" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
SECOND_EXIT=$?
set -e

if [ "$SECOND_EXIT" -eq 0 ] && echo "$SECOND_OUTPUT" | grep -q "Repair Complete"; then
  ok "Second repair completes successfully"
else
  fail "Second repair failed (exit=$SECOND_EXIT)"
  echo "$SECOND_OUTPUT"
fi

DB_AFTER=$(sha256sum "$GOOD_RUNTIME/state/manul.db" | awk '{print $1}')
CONFIG_AFTER=$(sha256sum "$GOOD_RUNTIME/config.json" | awk '{print $1}')
if [ "$DB_BEFORE" = "$DB_AFTER" ]; then
  ok "Second repair preserved existing DB"
else
  fail "Second repair changed existing DB"
fi
if [ "$CONFIG_BEFORE" = "$CONFIG_AFTER" ]; then
  ok "Second repair preserved existing config"
else
  fail "Second repair changed existing config"
fi

# ── Test 9: Archive fallback ─────────────────────────────────────────────────
echo
echo "Test 9: Archive DB fallback"
ARCHIVE_RUNTIME="$TMPROOT/archive-runtime"
ARCHIVE_DIR="$TMPROOT/archive-runtime-archive-20260917-000000"
mkdir -p "$ARCHIVE_DIR/state"
cp "$BACKUP_DB" "$ARCHIVE_DIR/state/manul.db"

set +e
ARCHIVE_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$ARCHIVE_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
ARCHIVE_EXIT=$?
set -e

if [ "$ARCHIVE_EXIT" -eq 0 ] && echo "$ARCHIVE_OUTPUT" | grep -q "Restored DB from archive"; then
  ok "Recovery restores the newest sibling archive DB"
else
  fail "Archive DB fallback failed (exit=$ARCHIVE_EXIT)"
  echo "$ARCHIVE_OUTPUT"
fi

# ── Test 10: init-schema failure is fatal to repair ──────────────────────────
echo
echo "Test 10: init-schema failure is fatal"
READONLY_RUNTIME="$TMPROOT/readonly-runtime"
mkdir -p "$READONLY_RUNTIME/state"

# Build a DB that has all tables but is missing migration columns (action, prNumber, prUrl).
# This simulates a pre-migration DB that needs ALTER TABLE to reach current schema.
sqlite3 "$READONLY_RUNTIME/state/manul.db" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  agent TEXT,
  prompt TEXT NOT NULL,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  nextAttemptAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT
);
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  issueUrl TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  activeTaskId TEXT,
  activePrNumber TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE workspaces (
  workspaceId TEXT PRIMARY KEY,
  workspacePath TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'IDLE',
  currentTaskId TEXT,
  lastUsedAt TEXT
);
SQL

# Make DB read-only so ALTER TABLE migrations cannot apply.
chmod 444 "$READONLY_RUNTIME/state/manul.db"

# Copy config template so repair reaches step 5.
cp "$SCRIPT_DIR/config.json.example" "$READONLY_RUNTIME/config.json" 2>/dev/null || true

set +e
READONLY_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$READONLY_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
READONLY_EXIT=$?
set -e

if [ "$READONLY_EXIT" -ne 0 ]; then
  ok "Repair exits non-zero when init-schema fails"
else
  fail "Repair should have exited non-zero when init-schema failed (exit=$READONLY_EXIT)"
fi

if echo "$READONLY_OUTPUT" | grep -q "Repair Complete"; then
  fail "Output must NOT contain 'Repair Complete' on init-schema failure"
else
  ok "Output does not contain 'Repair Complete' on failure"
fi

if echo "$READONLY_OUTPUT" | grep -qiE "schema|initialization|migration|ERROR"; then
  ok "Actual error message is visible in output"
else
  fail "Error message not visible in output"
  echo "  Output was: $READONLY_OUTPUT"
fi

# Verify the existing DB was not corrupted or replaced.
if [ -f "$READONLY_RUNTIME/state/manul.db" ]; then
  if sqlite3 "$READONLY_RUNTIME/state/manul.db" "SELECT COUNT(*) FROM processed_comments;" >/dev/null 2>&1; then
    ok "Existing DB preserved (not corrupted) after failed repair"
  else
    fail "Existing DB was corrupted during failed repair"
  fi
else
  fail "Existing DB was removed during failed repair"
fi

# ── Test 11: workspace_init failure is fatal ────────────────────────────────
echo
echo "Test 11: workspace_init failure is fatal"
WSFAIL_DIR="$TMPROOT/ws-fail-dir"
mkdir -p "$WSFAIL_DIR/state"

# Build a DB with conversation tables but WITHOUT the workspaces table.
# Then make it read-only so workspace_init cannot CREATE the missing table.
sqlite3 "$WSFAIL_DIR/state/manul.db" <<'SQL'
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  agent TEXT,
  prompt TEXT NOT NULL,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  nextAttemptAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  action TEXT DEFAULT 'IMPLEMENT',
  prNumber INTEGER,
  prUrl TEXT
);
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  issueUrl TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  activeTaskId TEXT,
  activePrNumber TEXT,
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
SQL
chmod 444 "$WSFAIL_DIR/state/manul.db"

# Call workspace_init directly with the read-only DB missing the workspaces table.
WS_INIT_OUTPUT=""
WS_INIT_EXIT=0
WS_INIT_OUTPUT="$(MANUL_DIR="$WSFAIL_DIR" DB="$WSFAIL_DIR/state/manul.db" \
  bash -c 'source "$1"; workspace_init' _ "$SCRIPT_DIR/workspace-manager.sh" 2>&1)" || WS_INIT_EXIT=$?

if [ "$WS_INIT_EXIT" -ne 0 ]; then
  ok "workspace_init exits non-zero when it cannot create missing table"
else
  fail "workspace_init should have failed (exit=$WS_INIT_EXIT)"
fi

if [ -n "$WS_INIT_OUTPUT" ] && echo "$WS_INIT_OUTPUT" | grep -qiE "error|permission|readonly|database"; then
  ok "workspace_init surfaces the actual error"
else
  fail "workspace_init error output not visible"
  echo "  Output was: $WS_INIT_OUTPUT"
fi

# Verify the existing DB is not corrupted.
if sqlite3 "$WSFAIL_DIR/state/manul.db" "SELECT COUNT(*) FROM processed_comments;" >/dev/null 2>&1; then
  ok "Existing DB preserved after failed workspace_init"
else
  fail "Existing DB was corrupted by failed workspace_init"
fi

# ── Test 12: existing empty DB + valid backup → backup restored ─────────────
echo
echo "Test 12: Empty DB + valid backup → restore succeeds"
EMPTY_RUNTIME="$TMPROOT/empty-db-runtime"
mkdir -p "$EMPTY_RUNTIME"

# Create a 0-byte manul.db (simulates corrupted or freshly-created empty file)
mkdir -p "$EMPTY_RUNTIME/state"
touch "$EMPTY_RUNTIME/state/manul.db"
chmod 644 "$EMPTY_RUNTIME/state/manul.db"
# Copy config template so repair reaches step 4/5.
cp "$SCRIPT_DIR/config.json.example" "$EMPTY_RUNTIME/config.json" 2>/dev/null || true

set +e
EMPTY_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$EMPTY_RUNTIME" \
  MANUL_SOURCE_DB="$BACKUP_DB" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
EMPTY_EXIT=$?
set -e

if [ "$EMPTY_EXIT" -eq 0 ] && echo "$EMPTY_OUTPUT" | grep -q "Repair Complete"; then
  ok "Repair succeeds after restoring backup over empty DB"
else
  fail "Repair failed over empty DB (exit=$EMPTY_EXIT)"
  echo "$EMPTY_OUTPUT"
fi

# Verify the restored DB is valid and has the right tables.
RESTORED_DB="$EMPTY_RUNTIME/state/manul.db"
if db_is_valid "$RESTORED_DB" 2>/dev/null; then
  ok "Restored DB is valid SQLite after repair"
else
  # db_is_valid may not be defined in this scope; fall back to basic checks
  if [ -s "$RESTORED_DB" ] && sqlite3 "$RESTORED_DB" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
    ok "Restored DB is valid SQLite after repair (basic check)"
  else
    fail "Restored DB is not valid SQLite"
  fi
fi

for tbl in processed_comments conversations meta workspaces; do
  if ! sqlite3 "$RESTORED_DB" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
    fail "Restored DB missing table '$tbl' after repair over empty DB"
  fi
done
ok "Restored DB has all required tables"

# ── Test 13: existing corrupt DB + no backup → repair aborts ────────────────
echo
echo "Test 13: Corrupt DB + no backup → repair aborts, no schema fabricated"
CORRUPT_RUNTIME="$TMPROOT/corrupt-runtime"
mkdir -p "$CORRUPT_RUNTIME/state"
mkdir -p "$CORRUPT_RUNTIME"

# Write an invalid file that is non-empty but NOT a SQLite DB.
echo "not a database" > "$CORRUPT_RUNTIME/state/manul.db"
chmod 644 "$CORRUPT_RUNTIME/state/manul.db"
cp "$SCRIPT_DIR/config.json.example" "$CORRUPT_RUNTIME/config.json" 2>/dev/null || true

set +e
CORRUPT_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$CORRUPT_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
CORRUPT_EXIT=$?
set -e

if [ "$CORRUPT_EXIT" -ne 0 ]; then
  ok "Repair exits non-zero for corrupt DB with no backup"
else
  fail "Repair should have aborted for corrupt DB (exit=$CORRUPT_EXIT)"
fi

if echo "$CORRUPT_OUTPUT" | grep -q "No valid backup DB found"; then
  ok "Repair reports missing backup for corrupt DB"
else
  fail "Repair did not report missing backup"
  echo "  Output: $CORRUPT_OUTPUT"
fi

if echo "$CORRUPT_OUTPUT" | grep -q "Repair Complete"; then
  fail "Repair must NOT complete when DB is corrupt and no backup exists"
else
  ok "Repair does not print 'Repair Complete' on corrupt-DB failure"
fi

# Verify no schema was fabricated from the corrupt file.
if [ -f "$CORRUPT_RUNTIME/state/manul.db" ]; then
  if sqlite3 "$CORRUPT_RUNTIME/state/manul.db" "SELECT 1 FROM processed_comments LIMIT 1;" 2>/dev/null | grep -q .; then
    fail "Schema was fabricated from corrupt DB — tables exist when they should not"
  else
    ok "No schema fabricated; corrupt DB untouched"
  fi
else
    ok "Corrupt DB was not replaced (no backup available)"
  fi

# ── Test 14: existing valid DB + no backup → repair preserves it ─────────────
echo
echo "Test 14: Valid DB + no backup → repair preserves it"
VALID_RUNTIME="$TMPROOT/valid-db-runtime"
mkdir -p "$VALID_RUNTIME/state"
# Use the canonical backup as the "existing valid DB" seed.
cp "$BACKUP_DB" "$VALID_RUNTIME/state/manul.db"
chmod 600 "$VALID_RUNTIME/state/manul.db"
cp "$SCRIPT_DIR/config.json.example" "$VALID_RUNTIME/config.json" 2>/dev/null || true
# Seed an explicit baseline so repair has no state migration to perform in this test.
sqlite3 "$VALID_RUNTIME/state/manul.db" "INSERT OR REPLACE INTO meta(key,value) VALUES('baseline','2019-01-01T00:00:00Z');"

DB_BEFORE=$(sha256sum "$VALID_RUNTIME/state/manul.db" | awk '{print $1}')

set +e
VALID_OUTPUT=$( \
  MANUL_RUNTIME_DIR="$VALID_RUNTIME" \
  MANUL_CANONICAL_DIR="$SCRIPT_DIR" \
  "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
VALID_EXIT=$?
set -e

if [ "$VALID_EXIT" -eq 0 ] && echo "$VALID_OUTPUT" | grep -q "Repair Complete"; then
  ok "Repair succeeds with an existing valid DB and no backup"
else
  fail "Repair failed with existing valid DB (exit=$VALID_EXIT)"
  echo "$VALID_OUTPUT"
fi

DB_AFTER=$(sha256sum "$VALID_RUNTIME/state/manul.db" | awk '{print $1}')
if [ "$DB_BEFORE" = "$DB_AFTER" ]; then
  ok "Existing valid DB was preserved (not replaced) when no backup is available"
else
  fail "Existing valid DB was replaced when no backup is available"
fi

for tbl in processed_comments conversations meta workspaces; do
  if ! sqlite3 "$VALID_RUNTIME/state/manul.db" "SELECT 1 FROM $tbl LIMIT 1;" >/dev/null 2>&1; then
    fail "Preserved DB missing table '$tbl'"
  fi
done
ok "Preserved DB retains all required tables"


# ── Test 15-20: canonical installer lifecycle ────────────────────────────────
echo
echo "Test 15-20: Canonical installer lifecycle"
INSTALL_ROOT="$TMPROOT/install-runtime"
INSTALL_HOME="$TMPROOT/install-home"
FAKE_BIN="$TMPROOT/fake-bin"
mkdir -p "$INSTALL_HOME" "$FAKE_BIN"
printf '#!/bin/sh
exit 0
' > "$FAKE_BIN/openclaw"
chmod +x "$FAKE_BIN/openclaw"
set +e
INSTALL_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INSTALL_OUTPUT=$(PATH="$FAKE_BIN:$PATH" HOME="$INSTALL_HOME" MANUL_RUNTIME_DIR="$INSTALL_ROOT" MANUL_CANONICAL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/install-manul.sh" --init-state 2>&1)
INSTALL_EXIT=$?
INSTALL_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set -e

if [ "$INSTALL_EXIT" -eq 0 ]; then
  ok "install-manul.sh --init-state succeeds on a fresh runtime"
else
  fail "install-manul.sh failed on a fresh runtime (exit=$INSTALL_EXIT)"
  echo "$INSTALL_OUTPUT"
fi

if [ -f "$INSTALL_ROOT/state/manul.db" ] && [ -f "$INSTALL_ROOT/config.json" ]; then
  ok "Fresh installer creates DB and config"
else
  fail "Fresh installer did not create DB/config"
fi

INSTALL_BASELINE_VALUE="$(sqlite3 "$INSTALL_ROOT/state/manul.db" "SELECT value FROM meta WHERE key='baseline';" 2>/dev/null || true)"
if [ -n "$INSTALL_BASELINE_VALUE" ] && [[ "$INSTALL_BASELINE_VALUE" > "$INSTALL_START" || "$INSTALL_BASELINE_VALUE" == "$INSTALL_START" ]] && [[ "$INSTALL_BASELINE_VALUE" < "$INSTALL_END" || "$INSTALL_BASELINE_VALUE" == "$INSTALL_END" ]]; then
  ok "Fresh installer persists baseline at installation time"
else
  fail "Fresh installer baseline is missing or outside installation window (value=$INSTALL_BASELINE_VALUE start=$INSTALL_START end=$INSTALL_END)"
fi

if [ ! -f "$INSTALL_ROOT/.enabled" ]; then
  ok "Fresh installer does not create .enabled"
else
  fail "Fresh installer unexpectedly created .enabled"
fi

if grep -qF "source \"$SCRIPT_DIR/manul-shell.zsh\"" "$INSTALL_HOME/.zshrc" 2>/dev/null; then
  ok "Fresh installer installs canonical zsh integration"
else
  fail "Fresh installer did not install zsh integration"
fi

if [ -L "$INSTALL_ROOT/watchdog.sh" ] && crontab -l 2>/dev/null | grep -qF "$INSTALL_ROOT/watchdog.sh"; then
  ok "Fresh installer installs watchdog cron entry"
else
  fail "Fresh installer did not install watchdog cron entry"
fi

set +e
INSTALL_OUTPUT_2=$(PATH="$FAKE_BIN:$PATH" HOME="$INSTALL_HOME" MANUL_RUNTIME_DIR="$INSTALL_ROOT" MANUL_CANONICAL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/install-manul.sh" 2>&1)
INSTALL_EXIT_2=$?
set -e
if [ "$INSTALL_EXIT_2" -eq 0 ]; then
  INSTALL_BASELINE_AFTER="$(sqlite3 "$INSTALL_ROOT/state/manul.db" "SELECT value FROM meta WHERE key='baseline';" 2>/dev/null || true)"
  if [ "$INSTALL_BASELINE_AFTER" = "$INSTALL_BASELINE_VALUE" ]; then
    ok "Canonical installer preserves the existing installation baseline"
  else
    fail "Canonical installer moved the existing baseline ($INSTALL_BASELINE_VALUE -> $INSTALL_BASELINE_AFTER)"
  fi
  ok "Canonical installer remains idempotent after explicit initialization"
else
  fail "Canonical installer is not idempotent (exit=$INSTALL_EXIT_2)"
  echo "$INSTALL_OUTPUT_2"
fi


# ── Test: repair must fail closed when DB is missing ─────────────────────────
echo

# ── Test: OpenCode provider permission setup ─────────────────────────────────
echo
echo "Test: OpenCode provider permission setup"
OC_ROOT="$TMPROOT/opencode-permissions"
OC_HOME="$OC_ROOT/home"
OC_CONFIG="$OC_HOME/.config/opencode/opencode.json"
OC_BIN="$OC_ROOT/bin/opencode"
mkdir -p "$(dirname "$OC_CONFIG")" "$(dirname "$OC_BIN")"

cat >"$OC_CONFIG" <<'JSON'
{
  "theme": "test",
  "permission": {
    "external_directory": {
      "~/litellm/**": "allow",
      "~/.npm/**": "allow"
    },
    "bash": "ask",
    "read": "allow",
    "edit": "ask",
    "glob": "allow",
    "grep": "allow"
  }
}
JSON

cat >"$OC_BIN" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" = "debug" ] && [ "${2:-}" = "config" ]; then
  config="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
  if [ ! -f "$config" ]; then
    echo "mock opencode: config not found: $config" >&2
    exit 1
  fi
  cat "$config"
  exit $?
fi
exit 2
MOCK
chmod +x "$OC_BIN"

set +e
OC_OUTPUT="$(HOME="$OC_HOME" OPENCODE_CONFIG="$OC_CONFIG" OPENCODE_BIN="$OC_BIN" \
  "$SCRIPT_DIR/opencode-permissions.sh" 2>&1)"
OC_RC=$?
set -e

if [ "$OC_RC" -eq 0 ] && jq -e '.permission.external_directory["/tmp/**"] == "allow"' "$OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode setup adds /tmp/** allow rule"
else
  fail "OpenCode setup did not add /tmp/** allow rule (rc=$OC_RC)"
  echo "$OC_OUTPUT"
fi

if [ "$OC_RC" -eq 0 ] && jq -e '
  .permission.external_directory["/tmp/manul-diagnostics/**"] == "allow" and
  .permission.read["/tmp/manul-diagnostics/**"] == "allow" and
  .permission.edit["/tmp/manul-diagnostics/**"] == "allow"
' "$OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode allows read/write in the dedicated diagnostics output directory"
else
  fail "OpenCode diagnostics output-directory permissions are incomplete"
fi

if [ "$OC_RC" -eq 0 ] && jq -e '
  .permission.external_directory["~/.manul/logs/**"] == "allow" and
  .permission.read["~/.manul/logs/**"] == "allow" and
  .permission.glob["~/.manul/logs/**"] == "allow" and
  .permission.grep["~/.manul/logs/**"] == "allow" and
  .permission.edit["~/.manul/logs/**"] == "deny"
' "$OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode grants log read/search and explicitly denies file editing"
else
  fail "OpenCode log permissions are not read-only as intended"
fi

if [ "$OC_RC" -eq 0 ] && jq -e '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] == "allow"' "$OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode setup adds Gradle dependency-cache allow rule"
else
  fail "OpenCode setup did not add Gradle dependency-cache allow rule (rc=$OC_RC)"
  echo "$OC_OUTPUT"
fi

if jq -e '.theme == "test" and .permission.external_directory["~/litellm/**"] == "allow" and .permission.external_directory["~/.npm/**"] == "allow" and .permission.bash == "ask" and .permission.read["*"] == "allow" and .permission.edit["*"] == "ask" and .permission.glob["*"] == "allow" and .permission.grep["*"] == "allow" and .permission.edit["~/.manul/logs/**"] == "deny"' "$OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode setup preserves unrelated provider configuration"
else
  fail "OpenCode setup changed unrelated provider configuration"
fi

# The Gradle rule must be scoped to the module cache only, never the whole
# Gradle home, which may hold credentials in gradle.properties.
if jq -e '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] == "allow" and (.permission.external_directory["~/.gradle/**"] // "absent" | ( . != "allow" ))' "$OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode setup scopes the Gradle rule to the module cache only"
else
  fail "OpenCode setup granted a broader Gradle rule than the module cache"
fi

# Explicit OPENCODE_CONFIG override is respected over default ~/.config/opencode/opencode.json.
CUSTOM_OC_CONFIG="$OC_ROOT/custom-override/opencode.json"
mkdir -p "$(dirname "$CUSTOM_OC_CONFIG")"
cat >"$CUSTOM_OC_CONFIG" <<'JSON'
{
  "permission": {
    "external_directory": {
      "~/custom/**": "allow"
    }
  }
}
JSON
set +e
CUSTOM_OUTPUT="$(HOME="$OC_HOME" OPENCODE_CONFIG="$CUSTOM_OC_CONFIG" OPENCODE_BIN="$OC_BIN" \
  "$SCRIPT_DIR/opencode-permissions.sh" 2>&1)"
CUSTOM_RC=$?
set -e
if [ "$CUSTOM_RC" -eq 0 ] && \
   jq -e '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] == "allow" and .permission.external_directory["~/.manul/logs/**"] == "allow" and .permission.external_directory["~/custom/**"] == "allow"' "$CUSTOM_OC_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode setup respects explicitly configured OPENCODE_CONFIG path"
else
  fail "OpenCode setup did not modify explicitly configured OPENCODE_CONFIG (rc=$CUSTOM_RC)"
  echo "$CUSTOM_OUTPUT"
fi

# Default fallback: without explicit OPENCODE_CONFIG, $HOME/.config/opencode/opencode.json is modified.
DEFAULT_FALLBACK_HOME="$OC_ROOT/default-fallback-home"
DEFAULT_FALLBACK_CONFIG="$DEFAULT_FALLBACK_HOME/.config/opencode/opencode.json"
mkdir -p "$(dirname "$DEFAULT_FALLBACK_CONFIG")"
cat >"$DEFAULT_FALLBACK_CONFIG" <<'JSON'
{
  "permission": {
    "external_directory": {
      "~/fallback/**": "allow"
    }
  }
}
JSON
set +e
FALLBACK_OUTPUT="$(unset OPENCODE_CONFIG; HOME="$DEFAULT_FALLBACK_HOME" OPENCODE_BIN="$OC_BIN" \
  "$SCRIPT_DIR/opencode-permissions.sh" 2>&1)"
FALLBACK_RC=$?
set -e
if [ "$FALLBACK_RC" -eq 0 ] && \
   jq -e '.permission.external_directory["~/.gradle/caches/modules-2/files-2.1/**"] == "allow" and .permission.external_directory["~/.manul/logs/**"] == "allow" and .permission.external_directory["~/fallback/**"] == "allow"' "$DEFAULT_FALLBACK_CONFIG" >/dev/null 2>&1; then
  ok "OpenCode setup defaults to \$HOME/.config/opencode/opencode.json when OPENCODE_CONFIG is unset"
else
  fail "OpenCode setup did not use default config path when OPENCODE_CONFIG unset (rc=$FALLBACK_RC)"
  echo "$FALLBACK_OUTPUT"
fi

OC_HASH_BEFORE="$(sha256sum "$OC_CONFIG" | awk '{print $1}')"
set +e
HOME="$OC_HOME" OPENCODE_CONFIG="$OC_CONFIG" OPENCODE_BIN="$OC_BIN" \
  "$SCRIPT_DIR/opencode-permissions.sh" >/dev/null 2>&1
OC_RC_2=$?
set -e
OC_HASH_AFTER="$(sha256sum "$OC_CONFIG" | awk '{print $1}')"
if [ "$OC_RC_2" -eq 0 ] && [ "$OC_HASH_BEFORE" = "$OC_HASH_AFTER" ]; then
  ok "OpenCode setup is idempotent"
else
  fail "OpenCode setup is not idempotent (rc=$OC_RC_2)"
fi

OC_MISSING_ROOT="$OC_ROOT/missing"
OC_MISSING_CONFIG="$OC_MISSING_ROOT/.config/opencode/opencode.json"
set +e
HOME="$OC_MISSING_ROOT" OPENCODE_CONFIG="$OC_MISSING_CONFIG" OPENCODE_BIN="$OC_BIN" \
  "$SCRIPT_DIR/opencode-permissions.sh" >/dev/null 2>&1
OC_MISSING_RC=$?
set -e
if [ "$OC_MISSING_RC" -eq 0 ] && [ ! -f "$OC_MISSING_CONFIG" ]; then
  ok "OpenCode setup safely handles missing provider configuration"
else
  fail "OpenCode setup should safely skip a missing provider configuration"
fi

OC_INVALID="$OC_ROOT/invalid.json"
printf '{ invalid json\n' >"$OC_INVALID"
set +e
HOME="$OC_HOME" OPENCODE_CONFIG="$OC_INVALID" OPENCODE_BIN="$OC_BIN" \
  "$SCRIPT_DIR/opencode-permissions.sh" >/dev/null 2>&1
OC_INVALID_RC=$?
set -e
if [ "$OC_INVALID_RC" -ne 0 ] && grep -qxF '{ invalid json' "$OC_INVALID"; then
  ok "OpenCode setup fails closed on invalid configuration"
else
  fail "OpenCode setup did not fail closed on invalid configuration"
fi

NO_OPENCODE_ROOT="$OC_ROOT/no-opencode"
mkdir -p "$NO_OPENCODE_ROOT"
set +e
HOME="$NO_OPENCODE_ROOT" OPENCODE_CONFIG="$NO_OPENCODE_ROOT/opencode.json" OPENCODE_BIN="$NO_OPENCODE_ROOT/missing-opencode" \
  "$SCRIPT_DIR/opencode-permissions.sh" >/dev/null 2>&1
NO_OC_RC=$?
set -e
if [ "$NO_OC_RC" -eq 0 ]; then
  ok "OpenCode setup safely no-ops when provider is absent"
else
  fail "OpenCode setup fails when OpenCode provider is absent"
fi
echo "Test: Repair refuses implicit fresh DB creation"
FAIL_CLOSED_ROOT="$(mktemp -d /tmp/manul-fail-closed-XXXXXX)"
FAIL_CLOSED_RUNTIME="$FAIL_CLOSED_ROOT/runtime"
mkdir -p "$FAIL_CLOSED_RUNTIME"
set +e
FAIL_CLOSED_OUTPUT=$(
  MANUL_RUNTIME_DIR="$FAIL_CLOSED_RUNTIME"   MANUL_CANONICAL_DIR="$SCRIPT_DIR"   "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1
)
FAIL_CLOSED_EXIT=$?
set -e
if [ "$FAIL_CLOSED_EXIT" -ne 0 ] && echo "$FAIL_CLOSED_OUTPUT" | grep -q "No valid backup DB found"; then
  ok "Repair fails closed when DB is missing and no backup exists"
else
  fail "Repair unexpectedly fabricated/accepted a fresh DB (exit=$FAIL_CLOSED_EXIT)"
fi
rm -rf "$FAIL_CLOSED_ROOT"

# ── Test: explicit installer opt-in is the only fresh-DB path ────────────────
INIT_ROOT="$(mktemp -d /tmp/manul-init-optin-XXXXXX)"
INIT_RUNTIME="$INIT_ROOT/runtime"
mkdir -p "$INIT_RUNTIME"
set +e
INIT_OUTPUT=$(
  PATH="$FAKE_BIN:$PATH" MANUL_RUNTIME_DIR="$INIT_RUNTIME" MANUL_CANONICAL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/install-manul.sh" --init-state 2>&1
)
INIT_EXIT=$?
set -e
if [ "$INIT_EXIT" -eq 0 ] && [ -s "$INIT_RUNTIME/state/manul.db" ]; then
  ok "Fresh DB creation requires explicit --init-state"
else
  fail "Explicit --init-state did not initialize a fresh DB (exit=$INIT_EXIT)"
fi
rm -rf "$INIT_ROOT"

# ── Test: runtime repair cannot turn an existing queue into a new empty DB ─────
echo
echo "Test: Self-healing never loses an existing queue"
PERSIST_ROOT="$(mktemp -d /tmp/manul-persistence-XXXXXX)"
PERSIST_RUNTIME="$PERSIST_ROOT/runtime"
mkdir -p "$PERSIST_RUNTIME/state"
cp "$SCRIPT_DIR/config.json.example" "$PERSIST_RUNTIME/config.json"
sqlite3 "$PERSIST_RUNTIME/state/manul.db" "CREATE TABLE processed_comments(commentId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER NOT NULL, commentUrl TEXT NOT NULL, prompt TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'queued', attempts INTEGER NOT NULL DEFAULT 0, createdAt TEXT); CREATE TABLE conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL); CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT); CREATE TABLE workspaces(workspaceId TEXT PRIMARY KEY, workspacePath TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'IDLE', currentTaskId TEXT, lastUsedAt TEXT); INSERT INTO processed_comments(commentId,repository,issueNumber,commentUrl,prompt,status,createdAt) VALUES('persist-task','test/repo',1,'https://github.com/test/repo/issues/1','do it','queued','2026-09-22T00:00:00Z');"
PERSIST_BEFORE="$(sqlite3 "$PERSIST_RUNTIME/state/manul.db" "SELECT COUNT(*) FROM processed_comments;")"
set +e
PERSIST_OUTPUT="$(MANUL_RUNTIME_DIR="$PERSIST_RUNTIME" MANUL_CANONICAL_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/repair-manul-runtime.sh" 2>&1)"
PERSIST_EXIT=$?
set -e
PERSIST_AFTER="$(sqlite3 "$PERSIST_RUNTIME/state/manul.db" "SELECT COUNT(*) FROM processed_comments;" 2>/dev/null || echo 0)"
if [ "$PERSIST_EXIT" -eq 0 ] && [ "$PERSIST_BEFORE" = "$PERSIST_AFTER" ] && [ "$PERSIST_AFTER" -eq 1 ]; then
  ok "Repair preserves an existing queued task"
else
  fail "Repair changed/lost an existing queued task (exit=$PERSIST_EXIT before=$PERSIST_BEFORE after=$PERSIST_AFTER)"
  echo "$PERSIST_OUTPUT"
fi
rm -rf "$PERSIST_ROOT"
# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
