#!/usr/bin/env bash
# Regression tests for the `manul --update` CLI and safe updater.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/manul-update-test-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
assert_contains() {
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3')";; esac
}

echo "=== manul CLI update dispatch ==="
CLI_CANONICAL="$TEST_DIR/cli-canonical"
mkdir -p "$CLI_CANONICAL"
cp "$SCRIPT_DIR/manul-shell.zsh" "$CLI_CANONICAL/manul-shell.zsh"
cat > "$CLI_CANONICAL/update-manul.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MANUL_UPDATE_TEST_CAPTURE"
STUB
chmod +x "$CLI_CANONICAL/update-manul.sh"
export MANUL_UPDATE_TEST_CAPTURE="$TEST_DIR/update-dispatch.log"
: > "$MANUL_UPDATE_TEST_CAPTURE"
MANUL_CANONICAL_DIR="$CLI_CANONICAL" MANUL_RUNTIME_DIR="$TEST_DIR/no-runtime" bash -c '
    source "$MANUL_CANONICAL_DIR/manul-shell.zsh"
    manul --update --dry-run
    manul update
'
assert_eq "manul --update dispatches to the canonical updater" "--dry-run" "$(sed -n '1p' "$MANUL_UPDATE_TEST_CAPTURE")"
assert_eq "manul update shorthand dispatches to the canonical updater" "" "$(sed -n '2p' "$MANUL_UPDATE_TEST_CAPTURE")"

echo
echo "=== fast-forward update and deployment ==="
ORIGIN="$TEST_DIR/origin.git"
SEED="$TEST_DIR/seed"
CHECKOUT="$TEST_DIR/checkout"
RUNTIME="$TEST_DIR/runtime"
INSTALL_LOG="$TEST_DIR/installer.log"

git init -q --bare --initial-branch=master "$ORIGIN"
git init -q --initial-branch=master "$SEED"
git -C "$SEED" config user.name "Manul Update Test"
git -C "$SEED" config user.email "manul-update-test@example.invalid"
mkdir -p "$SEED/skills/manul-github-bot"
cp "$SCRIPT_DIR/update-manul.sh" "$SEED/skills/manul-github-bot/update-manul.sh"
cat > "$SEED/skills/manul-github-bot/install-manul.sh" <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
printf 'canonical=%s\nruntime=%s\nargs=%s\n' "$MANUL_CANONICAL_DIR" "$MANUL_RUNTIME_DIR" "$*" >> "$MANUL_UPDATE_TEST_INSTALL_LOG"
INSTALLER
chmod +x "$SEED/skills/manul-github-bot/install-manul.sh"
printf 'version-1\n' > "$SEED/version.txt"
git -C "$SEED" add .
git -C "$SEED" commit -qm "test: initial Manul checkout"
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -qu origin master
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/master
git clone -q --branch master "$ORIGIN" "$CHECKOUT"

printf 'version-2\n' > "$SEED/version.txt"
git -C "$SEED" commit -qam "test: newer Manul revision"
git -C "$SEED" push -qu origin master

mkdir -p "$RUNTIME/state"
printf 'sqlite-test-placeholder\n' > "$RUNTIME/state/manul.db"
touch "$RUNTIME/.enabled"
MANUL_CANONICAL_DIR="$CHECKOUT/skills/manul-github-bot" \
MANUL_RUNTIME_DIR="$RUNTIME" \
MANUL_UPDATE_EXPECTED_ORIGIN="$ORIGIN" \
MANUL_UPDATE_TEST_INSTALL_LOG="$INSTALL_LOG" \
bash "$CHECKOUT/skills/manul-github-bot/update-manul.sh" > "$TEST_DIR/update.log" 2>&1

assert_eq "updater fast-forwards the canonical checkout" "$(git -C "$SEED" rev-parse HEAD)" "$(git -C "$CHECKOUT" rev-parse HEAD)"
assert_eq "updater fetches the latest source content" "version-2" "$(cat "$CHECKOUT/version.txt")"
assert_contains "updater invokes the existing installer" "$(cat "$INSTALL_LOG")" "canonical=$CHECKOUT/skills/manul-github-bot"
assert_contains "updater passes the existing runtime directory" "$(cat "$INSTALL_LOG")" "runtime=$RUNTIME"
assert_eq "updater does not pass destructive initialization flags" "" "$(sed -n 's/^args=//p' "$INSTALL_LOG")"
[ -f "$RUNTIME/.enabled" ] && ok "updater leaves automation enabled without restarting it" || bad "updater leaves automation enabled without restarting it"
assert_contains "updater reports that it did not restart the daemon" "$(cat "$TEST_DIR/update.log")" "daemon was not stopped or restarted"

echo
echo "=== fail-closed update guards ==="
BEFORE_DIRTY_HEAD="$(git -C "$CHECKOUT" rev-parse HEAD)"
printf 'local edit\n' > "$CHECKOUT/untracked-local-file"
dirty_rc=0
dirty_output="$(MANUL_CANONICAL_DIR="$CHECKOUT/skills/manul-github-bot" MANUL_RUNTIME_DIR="$RUNTIME" MANUL_UPDATE_EXPECTED_ORIGIN="$ORIGIN" MANUL_UPDATE_TEST_INSTALL_LOG="$INSTALL_LOG" bash "$CHECKOUT/skills/manul-github-bot/update-manul.sh" 2>&1)" || dirty_rc=$?
assert_eq "updater refuses dirty checkouts" "1" "$dirty_rc"
assert_contains "dirty checkout failure explains the reason" "$dirty_output" "local changes"
assert_eq "dirty checkout is not advanced" "$BEFORE_DIRTY_HEAD" "$(git -C "$CHECKOUT" rev-parse HEAD)"
rm -f "$CHECKOUT/untracked-local-file"

git -C "$CHECKOUT" checkout -qb feature/test-update
branch_rc=0
branch_output="$(MANUL_CANONICAL_DIR="$CHECKOUT/skills/manul-github-bot" MANUL_RUNTIME_DIR="$RUNTIME" MANUL_UPDATE_EXPECTED_ORIGIN="$ORIGIN" MANUL_UPDATE_TEST_INSTALL_LOG="$INSTALL_LOG" bash "$CHECKOUT/skills/manul-github-bot/update-manul.sh" 2>&1)" || branch_rc=$?
assert_eq "updater refuses to update from a non-default branch" "1" "$branch_rc"
assert_contains "non-default branch failure explains the required branch" "$branch_output" "default branch 'master' only"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
