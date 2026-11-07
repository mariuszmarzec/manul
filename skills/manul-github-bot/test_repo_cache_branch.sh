#!/usr/bin/env bash
# Regression tests for resolving origin's actual default branch in shared caches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/manul-daemon.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$label (expected=$expected got=$actual)"
  pass "$label"
}

# Extract the pure repository metadata helper without starting the daemon.
eval "$(sed -n '/^repo_cache_remote_branch() {/,/^}/p' "$DAEMON")"
eval "$(sed -n '/^repo_git_diagnostic() {/,/^}/p' "$DAEMON")"

ORIGIN="$TEST_DIR/origin.git"
SEED="$TEST_DIR/seed"
CHECKOUT="$TEST_DIR/checkout"

# Keep the test compatible with Git 2.25 ( --initial-branch was added in Git 2.28).
# Explicitly set the unborn branch for both the bare remote and seed repository.
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" symbolic-ref HEAD refs/heads/main
git -C "$SEED" config user.name "Manul Test"
git -C "$SEED" config user.email "manul-test@example.invalid"
printf 'main\n' >"$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m "initial main"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q -u origin main

git clone -q "$ORIGIN" "$CHECKOUT"
assert_eq "normal main checkout resolves main" "main" "$(repo_cache_remote_branch "$CHECKOUT")"

git -C "$CHECKOUT" checkout -q --detach HEAD
assert_eq "detached HEAD follows origin/HEAD main" "main" "$(repo_cache_remote_branch "$CHECKOUT")"

# A valid local branch with a corresponding origin ref takes precedence.
git -C "$SEED" checkout -q -b feature/cache-test
printf 'feature\n' >>"$SEED/README.md"
git -C "$SEED" commit -q -am "feature commit"
git -C "$SEED" push -q -u origin feature/cache-test
git -C "$CHECKOUT" fetch -q origin
git -C "$CHECKOUT" checkout -q -B feature/cache-test origin/feature/cache-test
assert_eq "existing remote-tracking feature branch is preserved" "feature/cache-test" "$(repo_cache_remote_branch "$CHECKOUT")"

# Recreate the detached + missing origin/HEAD case. The helper must refresh the
# remote HEAD symref and still resolve main without assuming master.
git -C "$CHECKOUT" checkout -q --detach HEAD
git -C "$CHECKOUT" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || true
assert_eq "missing origin/HEAD is refreshed from the remote" "main" "$(repo_cache_remote_branch "$CHECKOUT")"

diagnostic="$(repo_git_diagnostic "fatal: could not fetch https://user:secret@example.invalid/repo Bearer abc123 token=hidden")"
[[ "$diagnostic" != *"secret"* && "$diagnostic" != *"abc123"* && "$diagnostic" != *"hidden"* ]] || fail "Git diagnostic leaked credential-like data"
[[ "$diagnostic" == *"<URL_REDACTED>"* && "$diagnostic" == *"[REDACTED]"* ]] || fail "Git diagnostic did not show redaction markers"
pass "Git diagnostics redact URLs and credential-like values"

echo "All shared repository cache tests passed."
