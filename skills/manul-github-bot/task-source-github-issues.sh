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
