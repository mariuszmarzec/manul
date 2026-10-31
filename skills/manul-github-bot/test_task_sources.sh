#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TMPROOT="$(mktemp -d /tmp/manul-task-sources-XXXXXX)"
BIN="$TMPROOT/bin"
WORK="$TMPROOT/work"
mkdir -p "$BIN" "$WORK"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0
FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_contains(){ [[ "$2" == *"$3"* ]] && ok "$1" || fail "$1"; }
assert_not_contains(){ [[ "$2" != *"$3"* ]] && ok "$1" || fail "$1"; }
assert_eq(){ [[ "$2" == "$3" ]] && ok "$1" || fail "$1 (expected $2, got $3)"; }
source "$SCRIPT_DIR/task-source.sh"
for todo_type in todo_local_mcp todo_remote_mcp; do
  if task_source_type_is_supported "$todo_type"; then
    ok "$todo_type is registered as an independent task source"
  else
    fail "$todo_type is missing from the task-source registry"
  fi
done

cat >"$WORK/config.json" <<'JSON'
{"repositories":["legacy/repo"],"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/issues"]},{"type":"jira_tasks","enabled":false,"baseUrl":"http://jira.local","repository":"owner/jira-repo"}]}
JSON
sources="$(task_source_configured_sources "$WORK/config.json")"
assert_contains "enabled GitHub source appears" "$sources" '"type":"github_issues"'
assert_not_contains "disabled Jira source is omitted" "$sources" '"type":"jira_tasks"'

cat >"$WORK/todo-sources.json" <<'JSON'
{
  "repositoryAllowlist": ["owner/catalog-a", "owner/catalog-b"],
  "taskSources": [
    {"type":"todo_local_mcp","enabled":true,"tokenEnv":"TODO_LOCAL_MCP_TOKEN"},
    {"type":"todo_remote_mcp","enabled":true,"tokenEnv":"FITEO_PAT","manulUserId":77,"url":"https://fiteo.example.test/mcp"},
    {"type":"github_issues","enabled":true,"repositories":["owner/issues"]}
  ]
}
JSON
todo_sources="$(task_source_configured_sources "$WORK/todo-sources.json")"
assert_contains "global repository allowlist is inherited by local Todo source" "$todo_sources" '"type":"todo_local_mcp","enabled":true,"tokenEnv":"TODO_LOCAL_MCP_TOKEN","repositoryAllowlist":["owner/catalog-a","owner/catalog-b"]'
assert_contains "global repository allowlist is inherited by remote Todo source" "$todo_sources" '"type":"todo_remote_mcp","enabled":true,"tokenEnv":"FITEO_PAT","manulUserId":77,"url":"https://fiteo.example.test/mcp","repositoryAllowlist":["owner/catalog-a","owner/catalog-b"]'
assert_not_contains "global Todo repository allowlist does not alter GitHub repository filters" "$todo_sources" '"type":"github_issues","repositories":["owner/issues"],"repositoryAllowlist"'

cat >"$WORK/todo-allowlist-intersection.json" <<'JSON'
{
  "repositoryAllowlist": ["owner/catalog-a"],
  "taskSources": [
    {"type":"todo_local_mcp","enabled":true,"repositoryAllowlist":["owner/catalog-a","owner/catalog-b"]},
    {"type":"todo_remote_mcp","enabled":true,"repositoryAllowlist":[]}
  ]
}
JSON
intersected_todo_sources="$(task_source_configured_sources "$WORK/todo-allowlist-intersection.json")"
assert_contains "per-source Todo allowlist is intersected with the global allowlist" "$intersected_todo_sources" '"repositoryAllowlist":["owner/catalog-a"]'
assert_contains "explicit empty source allowlist remains deny-all after intersection" "$intersected_todo_sources" '"repositoryAllowlist":[],"repositoryAllowlistEnforced":true'



cat >"$WORK/legacy.json" <<'JSON'
{"repositories":["owner/legacy"]}
JSON
legacy="$(task_source_configured_sources "$WORK/legacy.json")"
assert_contains "legacy config maps to GitHub Issues" "$legacy" '"type":"github_issues"'
assert_contains "legacy repository preserved" "$legacy" "owner/legacy"

cat >"$WORK/multi.json" <<'JSON'
{"taskSources":[{"type":"github_issues","enabled":true,"repositories":["owner/b"]},{"type":"github_issues","enabled":true,"repositories":["owner/a","owner/b"]},{"type":"jira_tasks","enabled":true,"baseUrl":"http://todo.local"}]}
JSON
multi="$(task_source_configured_sources "$WORK/multi.json")"
count="$(printf "%s\n" "$multi" | wc -l | tr -d " ")"
assert_eq "multiple source entries are preserved" "3" "$count"
assert_contains "first GitHub repository preserved" "$multi" "owner/b"
assert_contains "second GitHub repository preserved" "$multi" "owner/a"
assert_contains "Jira source is preserved when enabled" "$multi" '"type":"jira_tasks"'

cat >"$WORK/jira.json" <<'JSON'
{"type":"jira_tasks","enabled":true,"baseUrl":"http://jira.local","repository":"owner/jira-repo","userEnv":"CUSTOM_JIRA_USER","passwordEnv":"CUSTOM_JIRA_PASSWORD","jql":"project = DEMO"}
JSON
cat >"$BIN/curl" <<'CURL'
#!/usr/bin/env bash
cat <<'JSON'
{"issues":[{"id":"10001","key":"DEMO-7","fields":{"summary":"Fix sync","description":"Fix sync","created":"2026-10-08T10:00:00.000+0000","updated":"2026-10-08T11:00:00.000+0000","status":{"name":"To Do"},"project":{"key":"DEMO"},"issuetype":{"name":"Task"}}},{"id":"10002","key":"DEMO-8","fields":{"summary":"Do not run","description":"ordinary Jira task","status":{"name":"Done"},"project":{"key":"DEMO"},"issuetype":{"name":"Task"}}}]}
JSON
CURL
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"
export CUSTOM_JIRA_USER="jira-user"
export CUSTOM_JIRA_PASSWORD="jira-password"
source "$SCRIPT_DIR/task-source-jira-tasks.sh"
jira_source="$(cat "$WORK/jira.json")"
jira_tasks="$(task_source_jira_tasks_poll "$jira_source")"
assert_contains "Jira task is discovered without /manul" "$jira_tasks" '"taskSourceType":"jira_tasks"'
assert_contains "Jira issue key is stable id" "$jira_tasks" '"taskSourceId":"DEMO-7"'
assert_contains "Jira browse url is normalized" "$jira_tasks" '"http://jira.local/browse/DEMO-7"'
assert_not_contains "completed Jira task is ignored" "$jira_tasks" '"taskSourceId":"DEMO-8"'
assert_not_contains "Jira user is not emitted" "$jira_tasks" "jira-user"
assert_not_contains "Jira password is not emitted" "$jira_tasks" "jira-password"
assert_contains "Jira repository execution target is normalized" "$jira_tasks" '"repository":"owner/jira-repo"'
if task_source_type_is_supported github_pr; then fail "PR must not be a task source"; else ok "PR is not a task source"; fi
assert_eq "stable Jira source identity" "jira_tasks:DEMO-7" "$(task_source_identity '{"taskSourceType":"jira_tasks","taskSourceId":"DEMO-7"}')"

cat >"$BIN/gh" <<'GH'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"number":11,"html_url":"https://github.com/owner/issues/issues/11","user":{"login":"alice"},"created_at":"2026-10-08T10:00:00Z","updated_at":"2026-10-08T10:00:00Z","title":"Run root task","body":"/manul implement this"},
  {"number":13,"html_url":"https://github.com/owner/issues/issues/13","user":{"login":"alice"},"created_at":"2026-10-08T10:00:00Z","updated_at":"2026-10-08T10:00:00Z","title":"Diagnostics only","body":"/manul verify\nDiagnose only and report findings without changing code"},
  {"number":12,"html_url":"https://github.com/owner/issues/pull/12","user":{"login":"alice"},"created_at":"2026-10-08T10:00:00Z","updated_at":"2026-10-08T10:00:00Z","title":"PR is not root","body":"/manul should never be a source","pull_request":{"url":"https://api.github.com/repos/owner/issues/pulls/12"}}
]
JSON
GH
chmod +x "$BIN/gh"
cat >"$WORK/github.json" <<'JSON'
{"type":"github_issues","enabled":true,"repositories":["owner/issues"],"trigger":"/manul","baseline":"2026-10-01T00:00:00Z","allowedUsers":[]}
JSON
source "$SCRIPT_DIR/task-source-github-issues.sh"
github_tasks="$(task_source_github_issues_poll "$(cat "$WORK/github.json")")"
assert_contains "GitHub /manul issue is normalized" "$github_tasks" '"taskSourceType":"github_issues"'
assert_contains "GitHub source id is stable" "$github_tasks" '"taskSourceId":"owner/issues#11"'
assert_contains "GitHub trigger is removed from normalized prompt" "$github_tasks" '"prompt":"implement this"'
assert_not_contains "GitHub PR is never a root source" "$github_tasks" '"taskSourceId":"owner/issues#12"'
assert_contains "explicit verify command is normalized as report-only" "$github_tasks" '"action":"VERIFY"'
assert_contains "verify command is removed from the agent prompt" "$github_tasks" '"prompt":"Diagnose only and report findings without changing code"'

# Queue a normalized VERIFY source through the production queueing function and assert
# the explicit delivery action survives persistence in processed_comments.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
sql_num() { [[ "$1" =~ ^[0-9]+$ ]] && printf '%s' "$1" || printf ''; }
log() { :; }
eval "$(sed -n '/^queue_normalized_source_task() {/,/^}/p' "$SCRIPT_DIR/poll.sh")"
DB="$WORK/queue.db"
LOG="$WORK/poll.log"
LEASE_TIMEOUT=900
NEW=0
sqlite3 "$DB" "CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY, repository TEXT, issueNumber INTEGER, commentUrl TEXT,
  author TEXT, agent TEXT, prompt TEXT, status TEXT, createdAt TEXT, heartbeatAt TEXT,
  leaseExpiresAt TEXT, conversationId TEXT, baseId TEXT, taskSourceType TEXT,
  taskSourceId TEXT, taskSourceUrl TEXT, taskSourceTitle TEXT, taskSourceUpdatedAt TEXT,
  context TEXT, action TEXT DEFAULT 'IMPLEMENT'
);"
verify_task="$(printf '%s\n' "$github_tasks" | jq -c 'select(.taskSourceId == "owner/issues#13")')"
queue_normalized_source_task "$verify_task"
if [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE commentId='source:github_issues:owner/issues#13';")" -eq 0 ]; then
  echo "DEBUG: source task was not inserted; queue log follows:" >&2
  cat "$LOG" >&2 2>/dev/null || true
  echo "DEBUG: normalized source payload:" >&2
  printf '%s\n' "$verify_task" >&2
fi
actual_action="$(sqlite3 "$DB" "SELECT action FROM processed_comments WHERE commentId='source:github_issues:owner/issues#13';")"
actual_prompt="$(sqlite3 "$DB" "SELECT prompt FROM processed_comments WHERE commentId='source:github_issues:owner/issues#13';")"
assert_eq "VERIFY action persists through source queueing" "VERIFY" "$actual_action"
assert_eq "verify prompt persists without command prefix" "Diagnose only and report findings without changing code" "$actual_prompt"
actual_heartbeat="$(sqlite3 "$DB" "SELECT coalesce(heartbeatAt,'') FROM processed_comments WHERE commentId='source:github_issues:owner/issues#13';")"
actual_lease="$(sqlite3 "$DB" "SELECT coalesce(leaseExpiresAt,'') FROM processed_comments WHERE commentId='source:github_issues:owner/issues#13';")"
assert_eq "queued source task starts without heartbeat" "" "$actual_heartbeat"
assert_eq "queued source task starts without lease" "" "$actual_lease"

# Guard every poller enqueue path, including the synthetic CI-fix path that is
# not practical to exercise through the GitHub integration fixture above.
queued_insert_lines="$(grep -F 'INSERT OR IGNORE INTO processed_comments(' "$SCRIPT_DIR/poll.sh" | grep -F "'queued'" || true)"
queued_insert_count="$(printf '%s\n' "$queued_insert_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
queued_insert_null_count="$(printf '%s\n' "$queued_insert_lines" | grep -Ec "'queued','[^']*',NULL,NULL," || true)"
assert_eq "all five poller enqueue paths are checked" "5" "$queued_insert_count"
assert_eq "every queued enqueue leaves heartbeat and lease NULL" "$queued_insert_count" "$queued_insert_null_count"

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
