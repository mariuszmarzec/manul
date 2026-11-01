#!/usr/bin/env bash
# test_task_branch_lifecycle.sh — regression tests for agent-owned branching.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MANUL_TESTING=true
export MANUL_DIR="$WORK/manul"
mkdir -p "$MANUL_DIR"
cat > "$MANUL_DIR/config.json" <<'JSON'
{"automation":{"heartbeatInterval":60,"heartbeatTimeout":900,"leaseTimeout":900,"maxAttemptsBeforeFail":3,"lockTtl":1800}}
JSON

set +e
source "$ROOT_DIR/skills/manul-github-bot/manul-daemon.sh" 2>"$WORK/source.err"
source_rc=$?
set -e
if [ "$source_rc" -ne 0 ]; then
  echo "FAIL: sourcing manul-daemon.sh returned rc=$source_rc"
  cat "$WORK/source.err" 2>/dev/null || true
  exit 1
fi

git init -q "$WORK/repo"
git -C "$WORK/repo" config user.email test@example.com
git -C "$WORK/repo" config user.name Test
echo initial > "$WORK/repo/file.txt"
git -C "$WORK/repo" add file.txt
git -C "$WORK/repo" commit -qm initial
sha="$(git -C "$WORK/repo" rev-parse HEAD)"

git -C "$WORK/repo" update-ref refs/remotes/origin/develop "$sha"
git -C "$WORK/repo" update-ref refs/remotes/origin/master "$sha"
git -C "$WORK/repo" update-ref refs/remotes/origin/main "$sha"

tests=0
pass=0
assert_eq() {
  tests=$((tests+1))
  if [ "$1" = "$2" ]; then
    pass=$((pass+1))
    echo "PASS: $3"
  else
    echo "FAIL: $3 (expected='$2' actual='$1')"
    exit 1
  fi
}

assert_eq "$(determine_task_base_branch "$WORK/repo" "main")" "develop" "develop preferred when present"
git -C "$WORK/repo" update-ref -d refs/remotes/origin/develop
assert_eq "$(determine_task_base_branch "$WORK/repo" "main")" "master" "master preferred when develop is absent"
git -C "$WORK/repo" update-ref -d refs/remotes/origin/master
assert_eq "$(determine_task_base_branch "$WORK/repo" "main")" "main" "repository default used as fallback"

tests=$((tests+1))
if repository_changed_since "$WORK/repo" "$sha"; then
  echo "FAIL: clean workspace incorrectly detected as changed"
  exit 1
else
  pass=$((pass+1))
  echo "PASS: clean workspace is unchanged"
fi

echo changed >> "$WORK/repo/file.txt"
tests=$((tests+1))
if repository_changed_since "$WORK/repo" "$sha"; then
  pass=$((pass+1))
  echo "PASS: dirty tracked file is detected"
else
  echo "FAIL: dirty tracked file was not detected"
  exit 1
fi
git -C "$WORK/repo" restore file.txt

git -C "$WORK/repo" checkout -q -b develop
git -C "$WORK/repo" checkout -q -b feature/42-parent
printf 'parent\n' >> "$WORK/repo/file.txt"
git -C "$WORK/repo" add file.txt
git -C "$WORK/repo" commit -qm parent
git -C "$WORK/repo" checkout -q -b feature/42-child
assert_eq "$(infer_task_base_branch "$WORK/repo" "feature/42-child" "develop")" "feature/42-parent" "branch base inferred from reflog"

if grep -q 'TASK_BRANCH=.*manul-task-' "$ROOT_DIR/skills/manul-github-bot/manul-daemon.sh"; then
  echo "FAIL: daemon still manufactures manul-task branches"
  exit 1
fi
tests=$((tests+1))
pass=$((pass+1))
echo "PASS: daemon does not manufacture manul-task branches"

echo "All task-branch lifecycle tests passed: $pass/$tests"