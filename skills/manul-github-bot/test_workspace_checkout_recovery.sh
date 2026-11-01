#!/usr/bin/env bash
# Regression tests for safe, branch-specific checkout recovery.
set -euo pipefail

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export MANUL_DIR="$TEST_DIR/manul"
mkdir -p "$MANUL_DIR"
export GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
cat > "$MANUL_DIR/config.json" <<'CONFIG'
{"automation":{"maxConcurrentTasks":1}}
CONFIG

SCRIPT_DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
source "$SCRIPT_DIR/workspace-manager.sh"

passed=0
check() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS: $label"
    passed=$((passed + 1))
  else
    echo "FAIL: $label" >&2
    exit 1
  fi
}
assert_file() { [ -f "$1" ]; }
assert_branch() { [ "$(git -C "$1" symbolic-ref --short HEAD 2>/dev/null)" = "$2" ]; }
assert_head() { [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$2" ]; }
assert_clean() { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }

REMOTE="$TEST_DIR/test-owner/primary.git"
SEED="$TEST_DIR/seed"
CACHE="$TEST_DIR/cache"
mkdir -p "$(dirname "$REMOTE")"
git init -q --bare "$REMOTE"
git init -q -b main "$SEED"
git -C "$SEED" config user.name "Manul recovery tests"
git -C "$SEED" config user.email "manul-recovery@example.invalid"
printf 'main base\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -qm "main base"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q -u origin main

# The primary repository includes a local-only submodule. Every workspace
# checkout and every branch-specific recovery must initialize its exact
# gitlink, not merely clone the superproject from the shared cache.
SUBMODULE_REMOTE="$TEST_DIR/test-owner/shared.git"
SUBMODULE_SEED="$TEST_DIR/shared-seed"
git init -q --bare "$SUBMODULE_REMOTE"
git init -q -b main "$SUBMODULE_SEED"
git -C "$SUBMODULE_SEED" config user.name "Manul recovery tests"
git -C "$SUBMODULE_SEED" config user.email "manul-recovery@example.invalid"
printf 'shared dependency\n' > "$SUBMODULE_SEED/shared.txt"
git -C "$SUBMODULE_SEED" add shared.txt
git -C "$SUBMODULE_SEED" commit -qm "shared dependency"
git -C "$SUBMODULE_SEED" remote add origin "$SUBMODULE_REMOTE"
git -C "$SUBMODULE_SEED" push -q -u origin main
git --git-dir="$SUBMODULE_REMOTE" symbolic-ref HEAD refs/heads/main
git -C "$SEED" submodule add "$SUBMODULE_REMOTE" shared-utils
git -C "$SEED" commit -qm "add shared submodule"
git -C "$SEED" push -q origin main

git -C "$SEED" checkout -q -b release/task-base main
printf 'base-only file\n' > "$SEED/release-only.txt"
git -C "$SEED" add release-only.txt
git -C "$SEED" commit -qm "add task base branch file"
git -C "$SEED" push -q -u origin release/task-base

git -C "$SEED" checkout -q -b feature/pr-target main
printf 'PR-only file\n' > "$SEED/feature-only.txt"
git -C "$SEED" add feature-only.txt
git -C "$SEED" commit -qm "add PR head branch file"
git -C "$SEED" push -q -u origin feature/pr-target
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

git clone -q "$REMOTE" "$CACHE"
git -C "$CACHE" fetch --quiet origin --prune

# Standalone recovery at the selected non-default base branch. Checkout is
# blocked because the target branch contains a path currently present as an
# untracked file. The previous local commit and file must remain recoverable.
ISSUE_ROOT="$MANUL_WORKSPACE/ws-recovery-issue"
mkdir -p "$ISSUE_ROOT"
ISSUE_CHECKOUT="$(workspace_prepare_primary_checkout "$ISSUE_ROOT" "test-owner/primary" "$CACHE")"
check "initial workspace checkout initializes its submodule" assert_file "$ISSUE_CHECKOUT/shared-utils/shared.txt"
git -C "$ISSUE_CHECKOUT" remote set-url origin "$REMOTE"
git -C "$ISSUE_CHECKOUT" config user.name "Manul recovery tests"
git -C "$ISSUE_CHECKOUT" config user.email "manul-recovery@example.invalid"
git -C "$ISSUE_CHECKOUT" checkout -q -b stale/local
printf 'local commit\n' > "$ISSUE_CHECKOUT/local-commit.txt"
git -C "$ISSUE_CHECKOUT" add local-commit.txt
git -C "$ISSUE_CHECKOUT" commit -qm "local-only commit that must be recoverable"
printf 'untracked collision\n' > "$ISSUE_CHECKOUT/release-only.txt"
ISSUE_OLD_HEAD="$(git -C "$ISSUE_CHECKOUT" rev-parse HEAD)"
ISSUE_EXPECTED_HEAD="$(git --git-dir="$REMOTE" rev-parse refs/heads/release/task-base)"
git -C "$ISSUE_CHECKOUT" fetch --quiet origin --prune
check "standalone checkout fixture has selected base ref" git -C "$ISSUE_CHECKOUT" show-ref --verify --quiet refs/remotes/origin/release/task-base
check "standalone preparation recovers at the selected base branch" workspace_prepare_task_base_branch "$ISSUE_CHECKOUT" release/task-base "$ISSUE_ROOT" test-owner/primary
check "standalone checkout lands on selected non-default branch" assert_branch "$ISSUE_CHECKOUT" release/task-base
check "standalone checkout uses exact remote head" assert_head "$ISSUE_CHECKOUT" "$ISSUE_EXPECTED_HEAD"
check "standalone replacement is clean" assert_clean "$ISSUE_CHECKOUT"
check "replacement contains selected base branch's file" assert_file "$ISSUE_CHECKOUT/release-only.txt"
check "standalone recovery initializes its submodule" assert_file "$ISSUE_CHECKOUT/shared-utils/shared.txt"
ISSUE_BACKUP="$(find "$ISSUE_ROOT/tmp/checkout-recovery" -mindepth 1 -maxdepth 1 -type d -print -quit)"
check "standalone old checkout is preserved" assert_file "$ISSUE_BACKUP/local-commit.txt"
check "standalone old checkout retains prior commit" assert_head "$ISSUE_BACKUP" "$ISSUE_OLD_HEAD"
check "standalone old checkout retains colliding untracked file" assert_file "$ISSUE_BACKUP/release-only.txt"

# PR recovery at the actual PR head branch, not the default branch. The dirty
# checkout is preserved in recovery storage before the feature branch is used.
PR_ROOT="$MANUL_WORKSPACE/ws-recovery-pr"
mkdir -p "$PR_ROOT"
PR_CHECKOUT="$(workspace_prepare_primary_checkout "$PR_ROOT" "test-owner/primary" "$CACHE")"
git -C "$PR_CHECKOUT" remote set-url origin "$REMOTE"
printf 'untracked collision\n' > "$PR_CHECKOUT/feature-only.txt"
PR_EXPECTED_HEAD="$(git --git-dir="$REMOTE" rev-parse refs/heads/feature/pr-target)"
check "PR preparation recovers a blocked switch to the explicit PR head" workspace_prepare_pr_branch "$PR_CHECKOUT" feature/pr-target "$PR_ROOT" test-owner/primary
check "PR replacement is on requested feature branch" assert_branch "$PR_CHECKOUT" feature/pr-target
check "PR replacement uses exact remote feature head" assert_head "$PR_CHECKOUT" "$PR_EXPECTED_HEAD"
check "PR replacement includes the PR-only file" assert_file "$PR_CHECKOUT/feature-only.txt"
check "PR recovery initializes its submodule" assert_file "$PR_CHECKOUT/shared-utils/shared.txt"
PR_BACKUP="$(find "$PR_ROOT/tmp/checkout-recovery" -mindepth 1 -maxdepth 1 -type d -print -quit)"
check "PR old checkout is preserved outside active checkout" assert_file "$PR_BACKUP/feature-only.txt"
check "PR replacement is clean" assert_clean "$PR_CHECKOUT"

printf '\nResults: %s passed, 0 failed\n' "$passed"
