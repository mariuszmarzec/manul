#!/usr/bin/env bash
# Jira task-source provider.
# Each Jira issue is routed independently using the same repository resolver
# used by Todo. Multiple write targets become a Team parent so each target can
# receive its own isolated child workspace and PR.
set -uo pipefail

JIRA_TASK_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$JIRA_TASK_SOURCE_DIR/todo-task-source-utils.sh"

task_source_jira_tasks_poll() {
  local source_json="$1"
  local base_url user_env password_env jql search_path configured_repository user password url payload
  local repositories_json issues_json issue_json issue_key summary description routing_task resolution resolution_rc
  local repository target_repositories_json target_count action prompt skill_context method routing_hint source_updated_at

  base_url="$(jq -r '.baseUrl // empty' <<<"$source_json")"
  user_env="$(jq -r '.userEnv // "MANUL_JIRA_USER"' <<<"$source_json")"
  password_env="$(jq -r '.passwordEnv // "MANUL_JIRA_PASSWORD"' <<<"$source_json")"
  jql="$(jq -r '.jql // "project is not EMPTY"' <<<"$source_json")"
  search_path="$(jq -r '.searchPath // "/rest/api/2/search"' <<<"$source_json")"
  configured_repository="$(jq -r '.repository // empty' <<<"$source_json")"
  repositories_json="$(todo_mcp_source_repositories "$source_json")" || return 2

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
  issues_json="$(curl --fail --silent --show-error \
    --connect-timeout "${MANUL_JIRA_CONNECT_TIMEOUT:-10}" \
    --max-time "${MANUL_JIRA_TIMEOUT:-30}" \
    -u "$user:$password" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    -X POST "$url" 2>/dev/null)" || {
      echo "task-source: Jira search failed; no Jira tasks were emitted" >&2
      return 2
    }

  while IFS= read -r issue_json; do
    [ -n "$issue_json" ] || continue
    local state
    state="$(jq -r '.fields.status.name // "" | ascii_upcase' <<<"$issue_json")"
    [ "$state" != "DONE" ] || continue

    issue_key="$(jq -r '.key // (.id|tostring)' <<<"$issue_json")"
    source_updated_at="$(jq -r '.fields.updated // .fields.created // ""' <<<"$issue_json")"
    if todo_task_source_already_known jira_tasks "$issue_key"; then
      continue
    fi
    if todo_task_routing_attempt_recently jira_tasks "$issue_key" "$source_updated_at" "${MANUL_REPOSITORY_RESOLVER_RETRY_SECONDS:-300}"; then
      echo "task-source: Jira issue $issue_key had a recent unresolved repository-routing attempt; waiting for an update or retry interval" >&2
      continue
    fi
    summary="$(jq -r '.fields.summary // ""' <<<"$issue_json")"
    description="$(jq -r '
      .fields.description // ""
      | if type == "string" then . else tojson end
    ' <<<"$issue_json")"
    routing_task="$(jq -cn --arg description "$summary"$'\n\n'"$description" '{description:$description,subTasks:[]}')"

    resolution="$(todo_task_resolve_repository "$source_json" "$routing_task" 2>&1)"
    resolution_rc=$?
    if [ "$resolution_rc" -ne 0 ] && [ "$resolution_rc" -eq 3 ] && [ -n "$configured_repository" ]; then
      # Preserve the legacy fixed Jira repository only when the ticket contains
      # no repository-selection intent. An explicit target hint that could not
      # be resolved must never silently fall back to the source default.
      routing_hint="false"
      if grep -Eiq '(repo|repository|repozytor|github\.com|backend[[:space:]-]+for[[:space:]-]+frontend|\bbff\b)' <<<"$summary"$'\n'"$description"; then
        routing_hint="true"
      fi
      if [ "$routing_hint" = "false" ] &&
         jq -e --arg repo "$configured_repository" 'any(.[]; ascii_downcase == ($repo|ascii_downcase))' <<<"$repositories_json" >/dev/null 2>&1; then
        resolution="$(jq -cn --arg repo "$configured_repository" '{repository:$repo,repositories:[$repo],method:"jira_source_default",matchedAlias:"",skills:[]}')"
        resolution_rc=0
      fi
    fi
    if [ "$resolution_rc" -ne 0 ]; then
      todo_task_record_routing_attempt jira_tasks "$issue_key" "$source_updated_at" || true
      echo "task-source: Jira issue $issue_key was not queued because repository routing did not resolve safely: ${resolution:-no diagnostic}" >&2
      continue
    fi

    repository="$(jq -r '.repository // empty' <<<"$resolution")"
    target_repositories_json="$(jq -c --arg repository "$repository" '
      if (.repositories | type == "array" and length > 0)
      then (.repositories | map(select(type == "string")) | unique)
      else [$repository]
      end
    ' <<<"$resolution")" || continue
    target_count="$(jq 'length' <<<"$target_repositories_json")" || continue
    [ "$target_count" -gt 0 ] || continue
    action="IMPLEMENT"
    [ "$target_count" -le 1 ] || action="TEAM"

    prompt="$summary"
    [ -z "$description" ] || prompt+=$'\n\n'"$description"
    method="$(jq -r '.method // "unknown"' <<<"$resolution")"
    prompt+=$'\n\n## Repository routing\n\n'
    if [ "$target_count" -eq 1 ]; then
      prompt+="Target repository: $repository"
    else
      prompt+="All required write-target repositories (each must receive its own separate PR):"
      while IFS= read -r target_repository; do
        [ -n "$target_repository" ] && prompt+=$'\n- '"$target_repository"
      done < <(jq -r '.[]' <<<"$target_repositories_json")
      prompt+=$'\n\n'
      prompt+="**Mandatory multi-repository execution:** Manul selected its existing TEAM workflow. The first target ($repository) is owned by this parent task: implement it in the assigned primary checkout and deliver a verified PR for that repository. Do not create a duplicate child task for the primary target. For every remaining target, create exactly one independent TOP-LEVEL tracker task, each with its exact owner/repo, bounded implementation request, acceptance criteria, stable work-item marker, and /manul run trigger. Each additional child must receive its own workspace and deliver a separate verified branch and PR. Do not create nested Todo subtasks for these tasks. Preserve cross-repository dependencies, wait for every additional child, verify every child PR and its CI/review evidence, and include the parent's own primary-repository PR plus all child PR links in the final report. Do not omit or combine targets. Use the canonical team-workflow skill."
    fi
    prompt+=$'\nResolution method: '"$method"
    if [ "$target_count" -gt 1 ]; then
      prompt+=$'\nResolver reason: '"$(jq -r '.reason // empty' <<<"$resolution")"
    fi
    skill_context="$(todo_task_resolved_skill_context "$resolution")"
    if [ -n "$skill_context" ]; then
      prompt+=$'\n\n## Relevant project skills (included below)\n\n'"$skill_context"
    fi

    jq -cn \
      --arg base "$base_url" \
      --arg key "$issue_key" \
      --arg summary "$summary" \
      --arg description "$description" \
      --arg prompt "$prompt" \
      --arg repository "$repository" \
      --arg action "$action" \
      --argjson targets "$target_repositories_json" \
      --argjson resolution "$resolution" \
      --arg created "$(jq -r '.fields.created // ""' <<<"$issue_json")" \
      --arg updated "$source_updated_at" \
      --arg issueType "$(jq -r '.fields.issuetype.name // ""' <<<"$issue_json")" \
      --arg status "$(jq -r '.fields.status.name // ""' <<<"$issue_json")" \
      '{
        taskSourceType:"jira_tasks",
        taskSourceId:$key,
        taskSourceUrl:($base + "/browse/" + $key),
        title:$summary,
        body:(if $description == "" then $summary else $description end),
        prompt:$prompt,
        action:$action,
        createdAt:$created,
        updatedAt:$updated,
        state:"OPEN",
        metadata:{
          projectKey:($key | split("-")[0]),
          issueType:(if $issueType == "" then null else $issueType end),
          status:(if $status == "" then null else $status end),
          repository:$repository,
          repositories:$targets,
          repositoryResolution:$resolution
        },
        execution:{kind:"repository"}
      }'
  done < <(jq -c '.issues[]?' <<<"$issues_json")
}
