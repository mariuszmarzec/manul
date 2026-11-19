#!/usr/bin/env bash
# Hermetic tests for opt-in PR conflict resolution and guarded merging.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

MANUL_DIR="$TEST_DIR/manul"
DB="$TEST_DIR/manul.db"
CONFIG="$TEST_DIR/config.json"
LOG="$TEST_DIR/poll.log"
MOCK_BIN="$TEST_DIR/bin"
DETAILS_DIR="$TEST_DIR/details"
mkdir -p "$MANUL_DIR" "$MOCK_BIN" "$DETAILS_DIR"
export MANUL_DIR DB CONFIG LOG DETAILS_DIR

log() { :; }
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
generate_conversation_id() { printf 'conv-%s-issue-%s' "$1" "$2"; }
has_unresolved_manul_tasks() { return 1; }
MANUL_OWNED_PR=""
is_manul_owned_pr() { [ "$2" = "$MANUL_OWNED_PR" ]; }
NEW=0
ALLOWED_JSON='["allowed-user"]'
SIG="— manul 🐈"

sqlite3 "$DB" "
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE conversations(
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER,
  issueUrl TEXT,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  status TEXT NOT NULL DEFAULT 'OPEN',
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
CREATE TABLE processed_comments(
  commentId TEXT PRIMARY KEY,
  repository TEXT,
  issueNumber INTEGER,
  commentUrl TEXT,
  author TEXT,
  agent TEXT,
  prompt TEXT,
  action TEXT,
  prNumber INTEGER,
  prUrl TEXT,
  status TEXT,
  createdAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  conversationId TEXT,
  baseId TEXT,
  processedAt TEXT
);
"

cat >"$CONFIG" <<'JSON'
{
  "allowedUsers": ["allowed-user"],
  "proactivity": {"prAuthorAllowed": ["allowed-user"]},
  "conflictResolveAndMerge": {
    "enabled": false,
    "prScope": "AllUserAuthoredPr"
  }
}
JSON

cat >"$MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  cat "$MOCK_PRS"
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  cat "$DETAILS_DIR/${3}.json"
  exit 0
fi
echo "unexpected gh command: $*" >&2
exit 2
GH
chmod +x "$MOCK_BIN/gh"
export PATH="$MOCK_BIN:$PATH"
export MOCK_PRS="$TEST_DIR/prs.json"

cat >"$MOCK_PRS" <<'JSON'
[
  {
    "number": 42,
    "headRefName": "feature/conflict",
    "baseRefName": "master",
    "title": "Conflict PR",
    "url": "https://github.com/test/repo/pull/42",
    "author": {"login": "allowed-user"},
    "isDraft": false
  },
  {
    "number": 43,
    "headRefName": "feature/unapproved",
    "baseRefName": "master",
    "title": "Unapproved PR",
    "url": "https://github.com/test/repo/pull/43",
    "author": {"login": "other-user"},
    "isDraft": false
  },
  {
    "number": 44,
    "headRefName": "feature/draft",
    "baseRefName": "master",
    "title": "Draft PR",
    "url": "https://github.com/test/repo/pull/44",
    "author": {"login": "allowed-user"},
    "isDraft": true
  },
  {
    "number": 45,
    "headRefName": "feature/clean",
    "baseRefName": "master",
    "title": "Clean PR",
    "url": "https://github.com/test/repo/pull/45",
    "author": {"login": "allowed-user"},
    "isDraft": false
  }
]
JSON

for n in 42 43 44; do
  cat >"$DETAILS_DIR/$n.json" <<JSON
{"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","headRefOid":"head-$n-v1","baseRefOid":"base-$n-v1","isDraft":false}
JSON
done
cat >"$DETAILS_DIR/45.json" <<'JSON'
{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","headRefOid":"head-45-v1","baseRefOid":"base-45-v1","isDraft":false}
JSON
# GitHub's detail payload is authoritative for draft state as well.
cat >"$DETAILS_DIR/44.json" <<'JSON'
{"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","headRefOid":"head-44-v1","baseRefOid":"base-44-v1","isDraft":true}
JSON

source "$SCRIPT_DIR/manul-pr-watcher.sh"

# Defaults and invalid values fail closed.
conflict_resolve_and_merge_enabled && {
  echo "FAIL: conflict automation must default to disabled" >&2
  exit 1
}
[ "$(conflict_resolve_and_merge_scope)" = "AllUserAuthoredPr" ] || {
  echo "FAIL: configured conflict PR scope was not read" >&2
  exit 1
}
cat >"$CONFIG" <<'JSON'
{"conflictResolveAndMerge":{"enabled":true,"prScope":"UntrustedValue"}}
JSON
[ "$(conflict_resolve_and_merge_scope)" = "OnlyManulPr" ] || {
  echo "FAIL: invalid scope did not fail closed to OnlyManulPr" >&2
  exit 1
}

# Disabled means no PR listing, task creation or conversation mutation.
CONFLICT_RESOLVE_AND_MERGE_ENABLED=false
CONFLICT_RESOLVE_AND_MERGE_PR_SCOPE=AllUserAuthoredPr
scan_conflicted_prs "test/repo"
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")" = "0" ] || {
  echo "FAIL: disabled conflict automation queued a task" >&2
  exit 1
}

# Enabled AllUserAuthoredPr queues only allow-listed, open, non-draft conflicts.
cat >"$CONFIG" <<'JSON'
{
  "allowedUsers": ["allowed-user"],
  "proactivity": {"prAuthorAllowed": ["allowed-user"]},
  "conflictResolveAndMerge": {"enabled": true, "prScope": "AllUserAuthoredPr"}
}
JSON
CONFLICT_RESOLVE_AND_MERGE_ENABLED=true
conflict_resolve_and_merge_enabled || {
  echo "FAIL: enabled=true was not recognized" >&2
  exit 1
}
CONFLICT_RESOLVE_AND_MERGE_PR_SCOPE="$(conflict_resolve_and_merge_scope)"
scan_conflicted_prs "test/repo"

[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")" = "1" ] || {
  echo "FAIL: expected only one eligible conflict task" >&2
  exit 1
}
[ "$(sqlite3 "$DB" "SELECT prNumber FROM processed_comments LIMIT 1;")" = "42" ] || {
  echo "FAIL: conflict task was not attached to PR #42" >&2
  exit 1
}
[ "$(sqlite3 "$DB" "SELECT action FROM processed_comments LIMIT 1;")" = "IMPLEMENT" ] || {
  echo "FAIL: conflict task did not use the normal implementation action" >&2
  exit 1
}
task_prompt="$(sqlite3 "$DB" "SELECT prompt FROM processed_comments LIMIT 1;")"
grep -q "Target branch: master" <<<"$task_prompt" || {
  echo "FAIL: task prompt omitted the target branch" >&2
  exit 1
}
grep -q "gh pr merge" <<<"$task_prompt" || {
  echo "FAIL: task prompt omitted guarded merge instructions" >&2
  exit 1
}
grep -q -- "--admin" <<<"$task_prompt" || {
  echo "FAIL: task prompt omitted the explicit no-admin-merge constraint" >&2
  exit 1
}
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM conversations WHERE activePrNumber=42;")" = "1" ] || {
  echo "FAIL: PR-level conversation was not established" >&2
  exit 1
}

# The same head/base SHA pair is idempotent across poll cycles.
scan_conflicted_prs "test/repo"
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")" = "1" ] || {
  echo "FAIL: repeated scan duplicated the same conflict task" >&2
  exit 1
}

# A changed PR head creates a fresh task, but the unapproved and draft PRs stay excluded.
cat >"$DETAILS_DIR/42.json" <<'JSON'
{"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","headRefOid":"head-42-v2","baseRefOid":"base-42-v1","isDraft":false}
JSON
scan_conflicted_prs "test/repo"
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments;")" = "2" ] || {
  echo "FAIL: changed PR head did not create a distinct conflict task" >&2
  exit 1
}

# OnlyManulPr still requires exact Manul ownership, regardless of allow-listed author.
cat >"$CONFIG" <<'JSON'
{"conflictResolveAndMerge":{"enabled":true,"prScope":"OnlyManulPr"}}
JSON
CONFLICT_RESOLVE_AND_MERGE_PR_SCOPE="$(conflict_resolve_and_merge_scope)"
MANUL_OWNED_PR=43
# Test PR #43 is still not selected because its author is outside AllUserAuthoredPr
# only in the other mode; in OnlyManulPr the explicit provenance is authoritative.
scan_conflicted_prs "test/repo"
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE prNumber=43;")" = "1" ] || {
  echo "FAIL: OnlyManulPr did not use the exact provenance check" >&2
  exit 1
}

echo "All conflict resolve-and-merge tests passed."
