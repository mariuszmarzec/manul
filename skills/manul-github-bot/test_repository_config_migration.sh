#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATOR="$SCRIPT_DIR/migrate-repository-config.sh"
TEST_DIR="$(mktemp -d /tmp/manul-repository-migration-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

CONFIG="$TEST_DIR/config.json"
cat > "$CONFIG" <<'JSON'
{
  "enabled": true,
  "repositories": ["owner/keep", "owner/test-manul-e2e"],
  "repositoryAllowlist": ["owner/legacy-extra"],
  "taskSources": [
    {
      "type": "github_issues",
      "enabled": true,
      "repositories": ["owner/old-github-list"],
      "trigger": "/manul"
    },
    {
      "type": "todo_local_mcp",
      "enabled": true,
      "repositories": ["owner/old-local-list"],
      "repositoryAllowlist": ["owner/old-local-allowlist"],
      "repositoryAllowlistEnforced": true,
      "url": "http://127.0.0.1:8766/mcp",
      "allowReportOnly": true
    },
    {
      "type": "todo_remote_mcp",
      "enabled": true,
      "repositories": [],
      "url": "{env:FITEO_BASE_URL}/mcp",
      "tokenEnv": "FITEO_MANUL_PAT",
      "manulUserIdEnv": "MANUL_USER_ID"
    },
    {
      "type": "jira_tasks",
      "enabled": false,
      "repository": "owner/jira-target",
      "baseUrl": "https://jira.example.test"
    }
  ],
  "automation": { "agentRuntime": "opencode" }
}
JSON
chmod 640 "$CONFIG"
ORIGINAL_REPOSITORIES='["owner/keep","owner/test-manul-e2e"]'

bash "$MIGRATOR" "$CONFIG" > "$TEST_DIR/migration.log"
assert_eq "top-level repository list is preserved exactly" "$ORIGINAL_REPOSITORIES" "$(jq -c '.repositories' "$CONFIG")"
assert_eq "legacy extra repository is not merged into the global list" "false" "$(jq -r '.repositories | index("owner/legacy-extra") != null' "$CONFIG")"
assert_eq "unrelated automation config is preserved" "opencode" "$(jq -r '.automation.agentRuntime' "$CONFIG")"
assert_eq "Todo provider URL survives migration" "http://127.0.0.1:8766/mcp" "$(jq -r '.taskSources[1].url' "$CONFIG")"
assert_eq "fixed Jira target remains intact" "owner/jira-target" "$(jq -r '.taskSources[3].repository' "$CONFIG")"
assert_eq "top-level duplicate allowlist is removed" "false" "$(jq -r 'has("repositoryAllowlist")' "$CONFIG")"
assert_eq "GitHub provider-local list is removed" "false" "$(jq -r '.taskSources[0] | has("repositories")' "$CONFIG")"
assert_eq "Todo provider-local list is removed" "false" "$(jq -r '.taskSources[1] | has("repositories")' "$CONFIG")"
assert_eq "legacy Todo allowlist fields are removed" "false" "$(jq -r '.taskSources[1] | has("repositoryAllowlist") or has("repositoryAllowlistEnforced")' "$CONFIG")"
assert_eq "original config mode is preserved" "640" "$(stat -c '%a' "$CONFIG")"

BACKUP="$(find "$TEST_DIR" -maxdepth 1 -name 'config.json.bak.repository-list.*' -print -quit)"
if [ -n "$BACKUP" ]; then
  ok "recoverable backup is created before migration"
  assert_eq "backup retains the original repository list" "$ORIGINAL_REPOSITORIES" "$(jq -c '.repositories' "$BACKUP")"
else
  fail "recoverable backup is created before migration"
fi

BEFORE="$(cat "$CONFIG")"
BACKUP_COUNT_BEFORE="$(find "$TEST_DIR" -maxdepth 1 -name 'config.json.bak.repository-list.*' | wc -l | tr -d ' ')"
bash "$MIGRATOR" "$CONFIG" > "$TEST_DIR/idempotent.log"
AFTER="$(cat "$CONFIG")"
BACKUP_COUNT_AFTER="$(find "$TEST_DIR" -maxdepth 1 -name 'config.json.bak.repository-list.*' | wc -l | tr -d ' ')"
assert_eq "second migration leaves config unchanged" "$BEFORE" "$AFTER"
assert_eq "second migration does not create another backup" "$BACKUP_COUNT_BEFORE" "$BACKUP_COUNT_AFTER"

INVALID="$TEST_DIR/missing-global-list.json"
printf '%s\n' '{"repositoryAllowlist":["owner/old"],"taskSources":[{"type":"github_issues","repositories":["owner/nested"]}]}' > "$INVALID"
INVALID_BEFORE="$(cat "$INVALID")"
INVALID_RC=0
bash "$MIGRATOR" "$INVALID" > /dev/null 2> "$TEST_DIR/invalid.log" || INVALID_RC=$?
assert_eq "migration fails when global repositories are missing" "1" "$INVALID_RC"
assert_eq "failed migration leaves original config unchanged" "$INVALID_BEFORE" "$(cat "$INVALID")"
if grep -q 'top-level .repositories must exist' "$TEST_DIR/invalid.log"; then
  ok "missing global list has an actionable diagnostic"
else
  fail "missing global list has an actionable diagnostic"
fi

INVALID_ITEM="$TEST_DIR/invalid-global-list.json"
printf '%s\n' '{"repositories":["not-a-repository"],"repositoryAllowlist":[]}' > "$INVALID_ITEM"
INVALID_ITEM_RC=0
bash "$MIGRATOR" "$INVALID_ITEM" > /dev/null 2>&1 || INVALID_ITEM_RC=$?
assert_eq "migration rejects malformed global repository entries" "1" "$INVALID_ITEM_RC"

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
