#!/usr/bin/env bash
# update-manul.sh — update the canonical checkout and deploy its runtime scripts.
#
# This command upgrades an existing installation only. It never initializes,
# replaces, or resets the Manul database, and it deliberately does not restart
# the daemon or interfere with active task workers/leases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$SCRIPT_DIR}"
RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.manul}"
BRANCH="main"
EXPECTED_ORIGIN="${MANUL_UPDATE_EXPECTED_ORIGIN:-https://github.com/mariuszmarzec/manul.git}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if [ "$#" -gt 0 ]; then
    echo "Usage: manul --update" >&2
    exit 2
fi

command -v git >/dev/null 2>&1 || fail "git is required to update Manul"
command -v realpath >/dev/null 2>&1 || fail "realpath is required to update Manul"

[ -d "$CANONICAL_DIR" ] || fail "Canonical Manul directory does not exist: $CANONICAL_DIR"
CANONICAL_DIR="$(cd "$CANONICAL_DIR" && pwd -P)"
REPO_ROOT="$(git -C "$CANONICAL_DIR" rev-parse --show-toplevel 2>/dev/null)" ||     fail "Canonical Manul directory is not inside a Git checkout"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd -P)"

EXPECTED_CANONICAL_DIR="$REPO_ROOT/skills/manul-github-bot"
[ "$CANONICAL_DIR" = "$EXPECTED_CANONICAL_DIR" ] ||     fail "MANUL_CANONICAL_DIR must point to <checkout>/skills/manul-github-bot"

[ -d "$RUNTIME_DIR/state" ] || fail "Manul runtime state directory is missing: $RUNTIME_DIR/state"
DB_FILE="$RUNTIME_DIR/state/manul.db"
[ -s "$DB_FILE" ] || fail "Manul database is missing or empty at $DB_FILE; updater never creates a fresh database"

CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
[ "$CURRENT_BRANCH" = "$BRANCH" ] ||     fail "Manul updates are applied from '$BRANCH' only (current branch: ${CURRENT_BRANCH:-detached HEAD})"

normalize_origin() {
    local value="$1"
    case "$value" in
        git@github.com:*)
            value="https://github.com/${value#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            value="https://github.com/${value#ssh://git@github.com/}"
            ;;
    esac
    value="${value%.git}"
    printf '%s' "$value"
}

ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" ||     fail "Git remote 'origin' is not configured"
if [ "$(normalize_origin "$ORIGIN_URL")" != "$(normalize_origin "$EXPECTED_ORIGIN")" ]; then
    fail "unexpected origin URL for Manul checkout: $ORIGIN_URL"
fi

LOCAL_CHANGES="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
if [ -n "$LOCAL_CHANGES" ]; then
    echo "ERROR: Manul checkout has local changes; refusing to overwrite them:" >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 1
fi

echo "=== Updating Manul ==="
echo "Checkout: $REPO_ROOT"
echo "Runtime:  $RUNTIME_DIR"
echo "Branch:   $BRANCH"
echo

LOCAL_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
REMOTE_REF="refs/remotes/origin/$BRANCH"
git -C "$REPO_ROOT" fetch --prune origin "+refs/heads/$BRANCH:$REMOTE_REF" ||     fail "could not fetch origin/$BRANCH"
REMOTE_HEAD="$(git -C "$REPO_ROOT" rev-parse --verify "$REMOTE_REF" 2>/dev/null)" ||     fail "origin/$BRANCH was not found after fetch"

if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$LOCAL_HEAD" "$REMOTE_HEAD"; then
    fail "local main is ahead of or has diverged from origin/main; reconcile it manually before updating"
fi

if ! git -C "$REPO_ROOT" merge --ff-only "$REMOTE_REF"; then
    fail "could not fast-forward Manul to origin/$BRANCH"
fi

UPDATED_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [ "$LOCAL_HEAD" = "$UPDATED_HEAD" ]; then
    echo "Manul source is already up to date ($UPDATED_HEAD)"
else
    echo "Updated Manul source:"
    git -C "$REPO_ROOT" log --oneline --reverse "$LOCAL_HEAD..$UPDATED_HEAD"
fi

INSTALLER="$CANONICAL_DIR/install-manul.sh"
[ -f "$INSTALLER" ] || fail "updated installer is missing: $INSTALLER"
echo
echo "=== Deploying runtime ==="
if ! MANUL_CANONICAL_DIR="$CANONICAL_DIR" MANUL_RUNTIME_DIR="$RUNTIME_DIR" bash "$INSTALLER"; then
    fail "source checkout was updated, but runtime deployment failed; fix the installer error and run 'manul --update' again"
fi

echo
echo "=== Manul update complete ==="
echo "Runtime data and task state were not reset."
echo "The daemon was not stopped or restarted; no tasks, workers, leases, or locks were modified."
if [ -f "$RUNTIME_DIR/.enabled" ]; then
    echo "Automation remains enabled. A running daemon may retain code loaded before this update."
    echo "Only restart it after verifying that no active task or lease depends on the current process."
fi
