#!/usr/bin/env bash
# GitHub Issues task-source provider. PRs are never roots.
set -uo pipefail

task_source_github_issues_poll() {
  local source_json="$1"
  local baseline trigger allowed_json repo effective_allowed_json issues_json

  baseline="$(jq -r '.baseline // ""' <<<"$source_json")"
  trigger="$(jq -r '.trigger // "/manul"' <<<"$source_json")"
  allowed_json="$(jq -c '.allowedUsers // []' <<<"$source_json")"

  local -a repos=()
  mapfile -t repos < <(jq -r '.repositories[]?' <<<"$source_json")

  for repo in "${repos[@]}"; do
    [ -n "$repo" ] || continue

    effective_allowed_json="$allowed_json"
    if printf "%s" "$effective_allowed_json" | jq -e 'any(.[]; test("[<>]"))' >/dev/null 2>&1; then
      effective_allowed_json="$(printf "%s" "$effective_allowed_json" | jq -c '[.[] | select(test("[<>]") | not)]')"
      if [ "$(printf "%s" "$effective_allowed_json" | jq 'length')" -eq 0 ]; then
        effective_allowed_json="$(jq -nc --arg owner "${repo%%/*}" '[$owner]')"
      fi
    fi

    issues_json="$(gh api --paginate "repos/$repo/issues?state=open&since=${baseline}&per_page=100" 2>/dev/null || printf "[]")"

    printf "%s" "$issues_json" |
      jq -c \
        --arg repo "$repo" \
        --arg trigger "$trigger" \
        --arg baseline "$baseline" \
        --argjson allowed "$effective_allowed_json" '
          .[]
          | select(.pull_request | not)
          | select(.created_at >= $baseline)
          | select(($allowed | length == 0) or (.user.login as $u | ($allowed | index($u)) != null))
          | select((.body // "") | test("(^|\\r?\\n)[ \\t]*" + ($trigger | gsub("[\\^$.|?+()\\[\\]{}]"; "\\\\$&")) + "([ \\t\\r\\n]|$)"))
          | (.body | split("\n")) as $lines
          | ([range(0; $lines|length) | select($lines[.] | test("^[ \\t]*" + ($trigger | gsub("[\\^$.|?+()\\[\\]{}]"; "\\\\$&")) + "([ \\t]|$)"))][0]) as $idx
          | ($lines[$idx] | sub("^[ \\t]*" + ($trigger | gsub("[\\^$.|?+()\\[\\]{}]"; "\\\\$&")) + "[ \\t]*"; "")) as $first_prompt
          | ($lines[$idx+1:] | join("\n")) as $tail_prompt
          | (if $first_prompt == "" then $tail_prompt elif $tail_prompt == "" then $first_prompt else ($first_prompt + "\n" + $tail_prompt) end) as $raw_prompt
          | ($raw_prompt | sub("^[ \t\r\n]+"; "")) as $command_prompt
          | (if ($command_prompt | test("^verify([ \t\r\n]|$)")) then "VERIFY"
             elif ($command_prompt | test("^review-fix([ \t\r\n]|$)")) then "REVIEW_FIX"
             else "IMPLEMENT" end) as $action
          | (if $action == "VERIFY" then ($command_prompt | sub("^verify([ \t\r\n]+|$)"; ""))
             elif $action == "REVIEW_FIX" then ($command_prompt | sub("^review-fix([ \t\r\n]+|$)"; ""))
             else $command_prompt end) as $task_prompt
          | select(($task_prompt | gsub("[ \t\r\n]"; "")) != "")
          | {
              taskSourceType:"github_issues",
              taskSourceId:($repo + "#" + (.number|tostring)),
              taskSourceUrl:.html_url,
              title:(.title // ""),
              body:(.body // ""),
              prompt:$task_prompt,
              action:$action,
              createdAt:(.created_at // ""),
              updatedAt:(.updated_at // .created_at // ""),
              state:"OPEN",
              metadata:{repository:$repo,issueNumber:.number},
              execution:{kind:"repository"}
            }
        '
  done
}

# Revalidate a queued GitHub Issues root by its stable repo#number identity.
# This is intentionally separate from issue-comment revalidation: normalized
# source task IDs are not GitHub comment IDs.
task_source_github_issues_revalidate() {
  local source_json="$1"
  local source_id="$2"
  local expected_repo="${3:-}"
  local expected_issue="${4:-}"
  local repo issue trigger allowed_json issue_json rc

  [[ "$source_id" == *"#"* ]] || return 2
  repo="${source_id%#*}"
  issue="${source_id##*#}"
  [[ "$repo" =~ ^[^/]+/[^/]+$ && "$issue" =~ ^[0-9]+$ ]] || return 2
  if { [ -n "$expected_repo" ] && [ "$expected_repo" != "$repo" ]; } ||
     { [ -n "$expected_issue" ] && [ "$expected_issue" != "$issue" ]; }; then
    echo "task-source: GitHub source identity mismatch for $source_id" >&2
    return 2
  fi

  issue_json="$(timeout "${GH_API_TIMEOUT:-30}" gh api "repos/$repo/issues/$issue" 2>>"${LOG:-/dev/null}")" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      echo "task-source: GitHub issue revalidation timed out for $source_id" >&2
      return 2
    fi
    if printf '%s' "$issue_json" | jq -e '.message == "Not Found"' >/dev/null 2>&1; then
      echo "task-source: GitHub issue $source_id no longer exists" >&2
      return 1
    fi
    echo "task-source: GitHub issue revalidation failed transiently for $source_id" >&2
    return 2
  fi

  if ! jq -e 'type == "object" and (.state == "open" or .state == "closed")' <<<"$issue_json" >/dev/null 2>&1; then
    echo "task-source: GitHub issue revalidation returned an invalid response for $source_id" >&2
    return 2
  fi
  if ! jq -e '.state == "open" and (.pull_request? == null)' <<<"$issue_json" >/dev/null 2>&1; then
    echo "task-source: GitHub source $source_id is not an open issue" >&2
    return 1
  fi

  trigger="$(jq -r '.trigger // "/manul"' <<<"$source_json")"
  if ! jq -e --arg trigger "$trigger" '
    (.body // "")
    | split("\n")
    | any(.[]; . as $line
      | ($line | sub("^[ \t]*"; "")) as $trimmed
      | ($trimmed == $trigger)
        or ($trimmed | startswith($trigger + " "))
        or ($trimmed | startswith($trigger + "\t"))
    )
  ' <<<"$issue_json" >/dev/null 2>&1; then
    echo "task-source: GitHub issue $source_id no longer contains the configured trigger" >&2
    return 1
  fi

  allowed_json="$(jq -c '.allowedUsers // []' <<<"$source_json")"
  if [ "$(jq 'length' <<<"$allowed_json" 2>/dev/null || echo 0)" -gt 0 ]; then
    if ! jq -e --argjson allowed "$allowed_json" '(.user.login // "") as $author | ($allowed | index($author)) != null' <<<"$issue_json" >/dev/null 2>&1; then
      echo "task-source: GitHub issue $source_id author is no longer allowed by source configuration" >&2
      return 1
    fi
  fi

  return 0
}

