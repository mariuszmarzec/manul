#!/usr/bin/env bash
# Regression tests for Manul's task-root / multi-repository workspace layout.
set -euo pipefail

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export MANUL_DIR="$TEST_DIR/manul"
mkdir -p "$MANUL_DIR" "$TEST_DIR/cache"
cat > "$MANUL_DIR/config.json" <<'CONFIG'
{"automation":{"maxConcurrentTasks":1}}
CONFIG

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
export DB="$MANUL_DB"
source "$SCRIPT_DIR/workspace-manager.sh"

passed=0
failed=0
check() {
  local label="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL: %s\n' "$label" >&2
    failed=$((failed + 1))
  fi
}
assert_eq() { [ "$1" = "$2" ]; }
assert_contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
assert_rejected() {
  "$@" >/dev/null 2>&1 && return 1
  return 0
}

make_repo() {
  local dir="$1" repo="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Manul tests"
  git -C "$dir" config user.email "manul-tests@example.invalid"
  printf '%s\n' "$repo" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -qm "initial test commit"
  git -C "$dir" remote add origin "https://github.com/$repo"
}

PRIMARY_CACHE="$TEST_DIR/cache/primary"
RELATED_CACHE="$TEST_DIR/cache/related"
make_repo "$PRIMARY_CACHE" "test-owner/primary"
make_repo "$RELATED_CACHE" "test-owner/related"

check "valid repository id maps to owner/name under repos" assert_eq "$(workspace_repo_relative_path "test-owner/primary")" "repos/test-owner/primary"
check "rejects path traversal in owner" assert_rejected workspace_repo_relative_path "../escape/primary" 
check "rejects path traversal in repository" assert_rejected workspace_repo_relative_path "test-owner/../escape"
check "rejects extra repository path segments" assert_rejected workspace_repo_relative_path "test-owner/primary/extra"
check "rejects empty repository identifier" assert_rejected workspace_repo_relative_path ""

WORKSPACE="$MANUL_WORKSPACE/ws-layout-test"
mkdir -p "$WORKSPACE"
PRIMARY_CHECKOUT="$(workspace_prepare_primary_checkout "$WORKSPACE" "test-owner/primary" "$PRIMARY_CACHE")"
check "workspace root remains a non-Git task root" test ! -e "$WORKSPACE/.git"
check "primary checkout is nested under workspace root" assert_eq "$PRIMARY_CHECKOUT" "$WORKSPACE/repos/test-owner/primary"
check "primary checkout has expected GitHub origin" assert_eq "$(git -C "$PRIMARY_CHECKOUT" remote get-url origin)" "https://github.com/test-owner/primary"
printf 'preserve this edit\n' > "$PRIMARY_CHECKOUT/local-uncommitted.txt"
PRIMARY_CHECKOUT_REUSED="$(workspace_prepare_primary_checkout "$WORKSPACE" "test-owner/primary" "$PRIMARY_CACHE")"
check "primary checkout reuse preserves local edits" test -f "$PRIMARY_CHECKOUT_REUSED/local-uncommitted.txt"

# Keep the shared cache as a source only; related clones must land in this lease.
ensure_repo() {
  case "$1" in
    test-owner/related) printf '%s\n' "$RELATED_CACHE" ;;
    *) return 1 ;;
  esac
}
release_repo_lock() { :; }
workspace_prepare_related_checkouts "$WORKSPACE" "test-owner/primary" "test-owner/primary" "test-owner/related" "missing-owner/missing"
RELATED_CHECKOUT="$WORKSPACE/repos/test-owner/related"
check "related repo cloned below task root" test -d "$RELATED_CHECKOUT/.git"
check "related checkout origin uses canonical GitHub URL" assert_eq "$(git -C "$RELATED_CHECKOUT" remote get-url origin)" "https://github.com/test-owner/related"
check "related repo is declared read-only in prompt metadata" assert_contains "$WORKSPACE_RELATED_PATHS" "test-owner/related: repos/test-owner/related (read-only)"
check "unavailable related repository is identified" assert_contains "$WORKSPACE_RELATED_UNAVAILABLE" "missing-owner/missing"
check "secondary clone never replaces the shared cache" test -f "$RELATED_CACHE/README.md"
OTHER_WORKSPACE="$MANUL_WORKSPACE/ws-other-task"
mkdir -p "$OTHER_WORKSPACE"
check "other workspace cannot see this task's related checkout" test ! -e "$OTHER_WORKSPACE/repos/test-owner/related/.git"

# Symlinked repositories roots must not be accepted as destinations.
ESCAPE_ROOT="$TEST_DIR/escape-root"
SYMLINK_WORKSPACE="$MANUL_WORKSPACE/ws-symlink-test"
mkdir -p "$ESCAPE_ROOT" "$SYMLINK_WORKSPACE"
ln -s "$ESCAPE_ROOT" "$SYMLINK_WORKSPACE/repos"
check "rejects symlinked repos root" assert_rejected workspace_primary_repo_path "$SYMLINK_WORKSPACE" "test-owner/primary"
check "symlink rejection leaves outside directory untouched" test -z "$(find "$ESCAPE_ROOT" -mindepth 1 -print -quit)"

# Migration renames a legacy checkout as a unit and preserves dirt/unpushed work.
LEGACY="$MANUL_WORKSPACE/ws-legacy-test"
make_repo "$LEGACY" "test-owner/primary"
printf 'dirty legacy work\n' > "$LEGACY/local-uncommitted.txt"
workspace_migrate_legacy_checkout "$LEGACY" "test-owner/primary"
MIGRATED="$LEGACY/repos/test-owner/primary"
check "legacy root checkout migrated to nested primary path" test -d "$MIGRATED/.git"
check "legacy migration preserves uncommitted files" test -f "$MIGRATED/local-uncommitted.txt"
check "legacy migration keeps workspace root distinct from Git root" test ! -e "$LEGACY/.git"

printf '\nResults: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
