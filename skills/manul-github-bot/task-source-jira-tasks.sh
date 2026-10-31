#!/usr/bin/env bash
# Jira task-source provider.
# Root tasks come from Jira issues returned by /rest/api/2/search.
# Credentials are referenced by environment-variable names configured in the
# source entry; credential values are never persisted in config or normalized
# task output.

set -uo pipefail

task_source_jira_tasks_poll() {
  local source_json="$1"
  local base_url user_env password_env jql search_path repository user password url payload

  base_url="$(jq -r '.baseUrl // empty' <<<"$source_json")"
  user_env="$(jq -r '.userEnv // "MANUL_JIRA_USER"' <<<"$source_json")"
  password_env="$(jq -r '.passwordEnv // "MANUL_JIRA_PASSWORD"' <<<"$source_json")"
  jql="$(jq -r '.jql // "project is not EMPTY"' <<<"$source_json")"
  search_path="$(jq -r '.searchPath // "/rest/api/2/search"' <<<"$source_json")"
  repository="$(jq -r '.repository // empty' <<<"$source_json")"

  [ -n "$base_url" ] || {
    echo "task-source: jira_tasks disabled: baseUrl missing" >&2
    return 0
  }

  user="${!user_env:-}"
  password="${!password_env:-}"
  [ -n "$user" ] || {
    echo "task-source: jira_tasks disabled: $user_env missing" >&2
    return 0
  }
  [ -n "$password" ] || {
    echo "task-source: jira_tasks disabled: $password_env missing" >&2
    return 0
  }

  url="${base_url%/}${search_path}"
  payload="$(jq -nc --arg jql "$jql" '{jql:$jql,maxResults:100,startAt:0}')"

  curl --fail --silent --show-error     --connect-timeout "${MANUL_JIRA_CONNECT_TIMEOUT:-10}"     --max-time "${MANUL_JIRA_TIMEOUT:-30}"     -u "$user:$password"     -H 'Accept: application/json'     -H 'Content-Type: application/json'     --data "$payload"     -X POST "$url" 2>/dev/null |
    jq -c --arg base "$base_url" --arg repository "$repository" '
      .issues[]?
      | select(((.fields.status.name // "") | ascii_upcase) != "DONE")
      | {
          taskSourceType:"jira_tasks",
          taskSourceId:(.key // (.id|tostring)),
          taskSourceUrl:($base + "/browse/" + (.key // (.id|tostring))),
          title:(.fields.summary // ""),
          body:(.fields.description // ""),
          prompt:(.fields.description // ""),
          createdAt:(.fields.created // ""),
          updatedAt:(.fields.updated // .fields.created // ""),
          state:(if ((.fields.status.name // "") | ascii_upcase) == "DONE" then "DONE" else "OPEN" end),
          metadata:{
            projectKey:(.fields.project.key // null),
            issueType:(.fields.issuetype.name // null),
            status:(.fields.status.name // null),
            repository:(if $repository == "" then null else $repository end)
          },
          execution:{kind:"repository"}
        }
    '
}
