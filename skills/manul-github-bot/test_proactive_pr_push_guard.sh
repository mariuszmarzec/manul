#!/usr/bin/env bash
# Hermetic tests for the proactive PR pre-push guard.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export MANUL_DIR="$TEST_DIR/manul"
export MANUL_WORKSPACE="$MANUL_DIR/workspace"
export DB="$MANUL_DIR/manul.db"
export CONFIG="$MANUL_DIR/config.json"
export LOG="$MANUL_DIR/logs/test.log"
mkdir -p "$MANUL_DIR/state" "$MANUL_WORKSPACE" "$MANUL_DIR/logs"
printf '{}\n' >"$CONFIG"

source "$SCRIPT_DIR/manul-paths.sh"
source "$SCRIPT_DIR/workspace-manager.sh"

MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '%s\t%s\t%s\n' "$MOCK_PR_STATE" "$MOCK_PR_HEAD" "$MOCK_PR_BASE"
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
GH
chmod +x "$MOCK_BIN/gh"
export PATH="$MOCK_BIN:$PATH"

REMOTE="$TEST_DIR/remote.git"
WORK="$TEST_DIR/work"
USER_WORK="$TEST_DIR/user-work"
git init --bare -q "$REMOTE"
git clone -q "$REMOTE" "$WORK"
git -C "$WORK" config user.name "Manul Guard Test"
git -C "$WORK" config user.email "manul-guard@example.test"
printf '%s\n' "base" >"$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" commit -qm "initial base"
git -C "$WORK" branch -M master
git -C "$WORK" push -q -u origin master
BASE_SHA="$(git -C "$WORK" rev-parse HEAD)"

git -C "$WORK" checkout -qb feature/proactive-guard
printf '%s\n' "PR source" >>"$WORK/file.txt"
git -C "$WORK" commit -qam "PR source"
git -C "$WORK" push -q -u origin feature/proactive-guard
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"

export MOCK_PR_STATE="OPEN" MOCK_PR_HEAD="$HEAD_SHA" MOCK_PR_BASE="$BASE_SHA"
GUARD_DIR="$TEST_DIR/private-guard"
workspace_install_proactive_pr_push_guard \
  "$WORK" "$GUARD_DIR" "owner/repo" 42 "feature/proactive-guard" "$HEAD_SHA" "$BASE_SHA"

# A normal fast-forward push against the unchanged PR head/base is allowed.
printf '%s\n' "Manul fix" >>"$WORK/file.txt"
git -C "$WORK" commit -qam "Manul fix"
git -C "$WORK" push -q origin HEAD:refs/heads/feature/proactive-guard
echo "PASS: push succeeds when the PR head and base are unchanged"

# A later task must pin the newly pushed PR head, not reuse its prior snapshot.
workspace_remove_proactive_pr_push_guard "$WORK" "$GUARD_DIR"
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"
export MOCK_PR_HEAD="$HEAD_SHA"
workspace_install_proactive_pr_push_guard \
  "$WORK" "$GUARD_DIR" "owner/repo" 42 "feature/proactive-guard" "$HEAD_SHA" "$BASE_SHA"

# Simulate the user pushing another commit after Manul checked out the branch.
git clone -q --branch feature/proactive-guard "$REMOTE" "$USER_WORK"
git -C "$USER_WORK" config user.name "User"
git -C "$USER_WORK" config user.email "user@example.test"
printf '%s\n' "user's concurrent change" >>"$USER_WORK/file.txt"
git -C "$USER_WORK" commit -qam "user concurrent change"
git -C "$USER_WORK" push -q origin HEAD:refs/heads/feature/proactive-guard
git -C "$WORK" fetch -q origin feature/proactive-guard
printf '%s\n' "stale Manul follow-up" >>"$WORK/file.txt"
git -C "$WORK" commit -qam "stale Manul follow-up"
if output="$(git -C "$WORK" push origin HEAD:refs/heads/feature/proactive-guard 2>&1)"; then
  echo "FAIL: push was allowed after the remote PR head advanced" >&2
  exit 1
fi
grep -q "MANUL_PROACTIVE_PR_STALE_HEAD" <<<"$output" || {
  printf 'FAIL: missing stale-head marker in push output:\n%s\n' "$output" >&2
  exit 1
}
echo "PASS: push is blocked after a concurrent PR-head update"

# Reset to the latest source branch and confirm a target/base update is blocked too.
git -C "$WORK" fetch -q origin feature/proactive-guard
git -C "$WORK" reset --hard -q origin/feature/proactive-guard
LATEST_HEAD="$(git -C "$WORK" rev-parse HEAD)"
workspace_remove_proactive_pr_push_guard "$WORK" "$GUARD_DIR"
export MOCK_PR_HEAD="$LATEST_HEAD"
workspace_install_proactive_pr_push_guard \
  "$WORK" "$GUARD_DIR" "owner/repo" 42 "feature/proactive-guard" "$LATEST_HEAD" "$BASE_SHA"
printf '%s\n' "new base commit" >"$TEST_DIR/base.txt"
git -C "$WORK" checkout -q master
cp "$TEST_DIR/base.txt" "$WORK/base.txt"
git -C "$WORK" add base.txt
git -C "$WORK" commit -qm "advance target branch"
git -C "$WORK" push -q origin master
NEW_BASE_SHA="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" checkout -q feature/proactive-guard
git -C "$WORK" reset --hard -q "$LATEST_HEAD"
export MOCK_PR_HEAD="$LATEST_HEAD" MOCK_PR_BASE="$NEW_BASE_SHA"
# This task pins the current PR head and the old target SHA; only the target moves.
printf '%s\n' "work after target update" >>"$WORK/file.txt"
git -C "$WORK" commit -qam "work after target update"
if output="$(git -C "$WORK" push origin HEAD:refs/heads/feature/proactive-guard 2>&1)"; then
  echo "FAIL: push was allowed after the PR target/base changed" >&2
  exit 1
fi
grep -q "MANUL_PROACTIVE_PR_STALE_HEAD" <<<"$output" || {
  printf 'FAIL: missing base-change marker in push output:\n%s\n' "$output" >&2
  exit 1
}
echo "PASS: push is blocked after the target/base SHA changes"

workspace_remove_proactive_pr_push_guard "$WORK" "$GUARD_DIR"
[ -z "$(git -C "$WORK" config --local --get core.hooksPath 2>/dev/null || true)" ] || {
  echo "FAIL: proactive hook path was not removed" >&2
  exit 1
}
echo "All proactive PR push guard tests passed."
