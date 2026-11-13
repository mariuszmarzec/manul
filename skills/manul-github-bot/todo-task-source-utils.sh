#!/usr/bin/env bash
# Helpers shared by the independent local and remote Todo MCP source adapters.
# This is transport/normalization support, not a combined Todo adapter.

TODO_TASK_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

todo_mcp_source_url() {
  jq -r '.url // empty' <<<"$1"
}

todo_mcp_source_token_env() {
  jq -r '.tokenEnv // empty' <<<"$1"
}

todo_mcp_source_repository() {
  jq -r '.repository // empty' <<<"$1"
}

todo_mcp_source_repositories() {
  jq -c '
    .repositories
    | if type == "array" then map(select(type == "string")) | unique else [] end
  ' <<<"$1"
}

todo_task_repository_catalog_path() {
  # An explicit override is authoritative (also used by isolated test fixtures).
  if [ -n "${TODO_TASK_REPOSITORY_CATALOG:-}" ]; then
    printf '%s\n' "$TODO_TASK_REPOSITORY_CATALOG"
    return 0
  fi

  # The curated project catalog is part of the canonical agent skills tree.
  # Keep skill discovery fixed to ~/.agents/skills in interactive and daemon
  # processes; no alternate checkout or bundled fallback is supported.
  printf '%s\n' "$HOME/.agents/skills/globalskills-repository/project-repositories.json"
}

# Resolve a task target only from the curated project catalog. Explicit GitHub
# URLs win; otherwise the longest unambiguous whole-phrase alias wins. A
# The operator's global .repositories list is the allowlist; the catalog only maps names and skills.
todo_task_resolve_repository() {
  local source_json="$1" task_json="$2"
  local catalog_file description explicit_matches candidate_count repository method matched_alias
  local catalog_json="" catalog_valid=false matches_json match_json entry_json="" repositories_json canonical_repository skills_json="[]"

  description="$(jq -r '.description // ""' <<<"$task_json")"
  # The leading /manul command is a trigger, not a repository alias.
  # Strip it before matching catalog aliases so plain questions stay report-only.
  description="$(todo_strip_manul_trigger "$description")"
  explicit_matches="$(
    grep -Eo 'https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' <<<"$description" \
      | sed -E 's#^https?://github\.com/##; s#\.git$##' \
      | sort -u || true
  )"
  candidate_count="$(printf '%s\n' "$explicit_matches" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"

  # The catalog is an optional alias/skills index. Explicit GitHub URLs do
  # not depend on it; aliases do.
  catalog_file="$(todo_task_repository_catalog_path)"
  if [ -r "$catalog_file" ]; then
    catalog_json="$(cat "$catalog_file" 2>/dev/null || true)"
    if jq -e '.repositories | type == "array"' <<<"$catalog_json" >/dev/null 2>&1; then
      catalog_valid=true
    else
      catalog_json=""
    fi
  fi

  if [ "$candidate_count" -gt 1 ]; then
    echo "Todo task mentions multiple GitHub repositories; routing is ambiguous" >&2
    return 1
  fi

  if [ "$candidate_count" -eq 1 ]; then
    repository="$explicit_matches"
    method="explicit_github_url"
    matched_alias=""
  else
    if [ "$catalog_valid" != "true" ]; then
      echo "project catalog is unavailable; alias routing is disabled and this task will be report-only" >&2
      return 3
    fi
    matches_json="$(jq -c --arg description "$description" '
      def norm:
        ascii_downcase
        | gsub("[^a-z0-9]+"; " ")
        | gsub("^ +| +$"; "");
      ($description | norm) as $task_text
      | [
          .repositories[] as $repo
          | ($repo.aliases // [])[] as $alias
          | ($alias | norm) as $normalized_alias
          | select($normalized_alias != "")
          | select((" " + $task_text + " ") | contains(" " + $normalized_alias + " "))
          | {
              repository: $repo.name,
              alias: $alias,
              length: ($normalized_alias | length)
            }
        ]
      | if length == 0 then []
        else (map(.length) | max) as $max_length
        | map(select(.length == $max_length))
        | unique_by(.repository)
        end
    ' <<<"$catalog_json")" || return 2
    candidate_count="$(jq -r 'length' <<<"$matches_json")"
    if [ "$candidate_count" -eq 0 ]; then
      echo "no project alias matched the Todo task description" >&2
      # Exit code 3 tells Todo adapters there is no repository route, so the
      # task can safely run in report-only mode. Routing errors stay distinct.
      return 3
    fi
    if [ "$candidate_count" -gt 1 ]; then
      local candidates
      candidates="$(jq -r '[.[].repository] | join(", ")' <<<"$matches_json")"
      echo "Todo task matches multiple projects ($candidates); routing is ambiguous" >&2
      return 1
    fi
    match_json="$(jq -c '.[0]' <<<"$matches_json")"
    repository="$(jq -r '.repository' <<<"$match_json")"
    matched_alias="$(jq -r '.alias' <<<"$match_json")"
    method="catalog_alias"
  fi

  [[ "$repository" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    echo "resolved repository has an invalid owner/name value" >&2
    return 2
  }

  if [ "$catalog_valid" = "true" ]; then
    entry_json="$(jq -c --arg repo "$repository" '
      [.repositories[] | select((.name | ascii_downcase) == ($repo | ascii_downcase))]
      | first // empty
    ' <<<"$catalog_json")" || return 2
  fi
  canonical_repository="$(jq -r '.name // empty' <<<"${entry_json:-}")"
  [ -n "$canonical_repository" ] || canonical_repository="$repository"

  repositories_json="$(todo_mcp_source_repositories "$source_json")" || return 2
  if ! jq -e --arg repo "$canonical_repository" 'any(.[]; ascii_downcase == ($repo | ascii_downcase))' <<<"$repositories_json" >/dev/null 2>&1; then
    echo "repository $canonical_repository is excluded by the global .repositories list" >&2
    return 1
  fi

  if [ -n "$entry_json" ]; then
    skills_json="$(jq -c '.skills // [] | if type == "array" then map(select(type == "string")) else [] end' <<<"$entry_json")" || skills_json="[]"
  fi
  jq -cn \
    --arg repository "$canonical_repository" \
    --arg method "$method" \
    --arg matchedAlias "$matched_alias" \
    --argjson skills "$skills_json" \
    '{repository:$repository,method:$method,matchedAlias:$matchedAlias,skills:$skills}'
}

todo_task_resolved_skill_context() {
  local resolution_json="$1" skill skill_file skills_dir
  # Mapped project skills have one canonical source and are never loaded from
  # a Manul checkout, runtime directory, or alternate host path.
  skills_dir="$HOME/.agents/skills"
  while IFS= read -r skill; do
    [[ "$skill" =~ ^[a-z0-9][a-z0-9-]*$ ]] || continue
    skill_file="$skills_dir/$skill/SKILL.md"
    [ -r "$skill_file" ] || {
      echo "project skill context is unavailable: $skill" >&2
      continue
    }
    printf '\n## Project skill context: %s\n\n' "$skill"
    cat "$skill_file"
    printf '\n'
  done < <(jq -r '.skills[]? // empty' <<<"$resolution_json")
}

todo_mcp_source_call() {
  local source_json="$1" source_type="$2" tool="$3" arguments="$4"
  local url token_env
  url="$(todo_mcp_source_url "$source_json")"
  [ -n "$url" ] || {
    echo "todo-mcp: source URL is missing" >&2
    return 2
  }
  local -a token_args=()
  if [ "$source_type" = "todo_remote_mcp" ]; then
    token_env="$(todo_mcp_source_token_env "$source_json")"
    [ -n "$token_env" ] || {
      echo "todo-mcp: remote source tokenEnv is missing" >&2
      return 2
    }
    token_args=(--token-env "$token_env")
  elif [ "$source_type" != "todo_local_mcp" ]; then
    echo "todo-mcp: unsupported source type: $source_type" >&2
    return 2
  fi
  local client="${TODO_MCP_CLIENT:-$TODO_TASK_SOURCE_DIR/todo-mcp-client.py}"
  if [ ! -r "$client" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: todo-mcp: standalone Todo MCP client is missing or Python 3 is unavailable ($client)" >&2
    return 2
  fi
  python3 "$client" \
    --url "$url" "${token_args[@]}" --tool "$tool" --arguments "$arguments"
}

todo_mcp_source_list_tasks() {
  local source_json="$1" source_type="$2"
  case "$source_type" in
    todo_local_mcp)
      todo_mcp_source_call "$source_json" todo_local_mcp list_tasks '{}' ;;
    todo_remote_mcp)
      todo_mcp_source_call "$source_json" todo_remote_mcp todo_list_tasks '{}' ;;
    *)
      echo "todo-mcp: unsupported source type: $source_type" >&2
      return 2 ;;
  esac
}

todo_task_id_from_source_id() {
  local source_id="$1"
  printf '%s' "${source_id%%@*}"
}

todo_task_version_from_source_id() {
  local source_id="$1"
  [[ "$source_id" == *@* ]] || return 1
  printf '%s' "${source_id#*@}"
}

todo_task_find_root() {
  local tasks_json="$1" task_id="$2"
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 1
  jq -ce --argjson id "$task_id" \
    '[.[] | select(.id == $id)] | first // empty' <<<"$tasks_json"
}

todo_task_fingerprint_raw() {
  jq -cS '
    def stable:
      {
        id,
        description,
        parentTaskId,
        priority,
        scheduler,
        shares:((.shares // []) | sort_by(.userId, .permission)),
        subTasks:([.subTasks[]? | stable] | sort_by([-(.priority // 0), .id]))
      };
    stable
  ' <<<"$1" | sha256sum | awk '{print substr($1, 1, 16)}'
}

# Ignore only one source-version-bound Manul report child whose marker and
# payload digest verify. A changed result or any user-owned subtask remains in
# the structural fingerprint and makes the source stale.
todo_task_strip_verified_report_result() {
  local task_json="$1" root_id parsed candidate_record candidate_json candidate_source expected_version
  local verified_count=0 verified_candidate=""
  root_id="$(jq -r '.id // empty' <<<"$task_json")"
  [[ "$root_id" =~ ^[0-9]+$ ]] || { printf '%s\n' "$task_json"; return 0; }
  parsed="$(python3 -c '
import base64, hashlib, json, re, sys
root_id = int(sys.argv[1])
root = json.load(sys.stdin)
candidates = []
subtasks = root.get("subTasks") or []
marker_pattern = re.compile(
    r"<!-- MANUL_REPORT_RESULT:v1;root=([0-9]+);source=([0-9]+@[0-9a-f]{16});"
    r"sha256=([0-9a-f]{64})(?:;answerSha256=([0-9a-f]{64});"
    r"answerBase64=([A-Za-z0-9+/]*={0,2}))? -->"
)
for index, child in enumerate(subtasks):
    description = child.get("description")
    if not isinstance(description, str):
        continue
    lines = description.splitlines()
    marker_positions = [
        position for position, line in enumerate(lines)
        if line.startswith("<!-- MANUL_REPORT_RESULT:v1;")
    ]
    if len(marker_positions) != 1:
        continue
    marker_position = marker_positions[0]
    marker = lines[marker_position]
    match = marker_pattern.fullmatch(marker)
    if not match or int(match.group(1)) != root_id:
        continue
    if marker_position == 0 and "\n" in description:
        payload = description.partition("\n")[2]  # Legacy marker at the start.
    elif marker_position == len(lines) - 1 and "\n" in description:
        payload = description.rsplit("\n", 1)[0]  # New marker after the Markdown.
    else:
        continue
    if child.get("parentTaskId") != root_id or child.get("subTasks"):
        continue
    if hashlib.sha256(payload.encode("utf-8")).hexdigest() != match.group(3):
        continue
    if match.group(4) is not None:
        try:
            raw_answer = base64.b64decode(match.group(5), validate=True)
            raw_answer.decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        if hashlib.sha256(raw_answer).hexdigest() != match.group(4):
            continue
    candidate = dict(root)
    candidate["subTasks"] = [item for position, item in enumerate(subtasks) if position != index]
    candidates.append({"task": candidate, "sourceId": match.group(2)})
print(json.dumps(candidates, separators=(",", ":")))
' "$root_id" <<<"$task_json")" || { printf '%s\n' "$task_json"; return 0; }

  # Test each individually valid output record against the source tree that
  # remains when only that record is removed. This keeps historical Manul
  # reports in the user's task tree while excluding exactly the record bound
  # to the current source version. Ambiguous matches fail closed.
  while IFS= read -r candidate_record; do
    candidate_json="$(jq -c '.task' <<<"$candidate_record")"
    candidate_source="$(jq -r '.sourceId // empty' <<<"$candidate_record")"
    expected_version="$(todo_task_fingerprint_raw "$candidate_json")" || continue
    if [ "$candidate_source" = "${root_id}@${expected_version}" ]; then
      verified_count=$((verified_count + 1))
      verified_candidate="$candidate_json"
    fi
  done < <(jq -c '.[]' <<<"$parsed")

  if [ "$verified_count" -eq 1 ]; then
    printf '%s\n' "$verified_candidate"
  else
    printf '%s\n' "$task_json"
  fi
}

todo_task_fingerprint() {
  local stable_task
  stable_task="$(todo_task_strip_verified_report_result "$1")" || return 1
  todo_task_fingerprint_raw "$stable_task"
}

todo_task_ids_json() {
  jq -c '
    def ids:
      [.id] + ([.subTasks[]? | ids] | add // []);
    ids
  ' <<<"$1"
}

todo_task_steps_json() {
  local task_json="$1" source_id="${2:-}"
  if [ -n "$source_id" ]; then
    task_json="$(todo_task_strip_verified_report_result "$task_json")" || return 1
  fi
  jq -c '
    def descendants($depth):
      . as $task
      | [{id:$task.id, description:(($task.description // "") | sub("^[[:space:]]*/manul([[:space:]]+report)?([[:space:]]+|$)"; "") | gsub("\\n[[:space:]]*/manul([[:space:]]+report)?([[:space:]]+|$)"; "\n")), isToDo:(if ($task | has("isToDo")) then $task.isToDo else true end), depth:$depth}]
        + ([ $task.subTasks[]? | descendants($depth + 1) ] | add // []);
    [.subTasks[]? | descendants(0)] | add // []
  ' <<<"$task_json"
}

todo_task_is_report_only() {
  jq -r '.description // ""' <<<"$1" |
    grep -qE '^[[:space:]]*/manul[[:space:]]+report([[:space:]]|$)'
}

todo_strip_manul_trigger() {
  awk '
    {
      if (!found && $0 ~ /^[[:space:]]*\/manul[[:space:]]+report([[:space:]]|$)/) {
        sub(/^[[:space:]]*\/manul[[:space:]]+report([[:space:]]+|$)/, "")
        found = 1
      } else if (!found && $0 ~ /^[[:space:]]*\/manul([[:space:]]|$)/) {
        sub(/^[[:space:]]*\/manul([[:space:]]+|$)/, "")
        found = 1
      }
      print
    }
  ' <<<"$1"
}

todo_task_prompt() {
  local task_json="$1" source_id="${2:-}" prompt_text steps_json steps_markdown description task_id
  description="$(jq -r '.description // ""' <<<"$task_json")"
  task_id="$(jq -r '.id // "unknown"' <<<"$task_json")"
  prompt_text="$(todo_strip_manul_trigger "$description")"
  steps_json="$(todo_task_steps_json "$task_json" "$source_id")"
  steps_markdown="$(jq -r '
    to_entries[]
    | .key as $index
    | .value as $step
    | (([range(0; ($step.depth // 0)) | "  "] | join(""))
       + (($index + 1 | tostring) + ". ")
       + (if $step.isToDo then "[TODO] " else "[DONE] " end)
       + ($step.description // ""))
  ' <<<"$steps_json")"

  {
    printf '## Todo task\n\n'
    printf '**Todo task ID:** %s\n\n' "$task_id"
    if [ -n "$prompt_text" ]; then
      printf '%s\n' "$prompt_text"
    else
      printf '%s\n' "${description:-Complete the Todo task.}"
    fi
    if [ -n "$steps_markdown" ]; then
      printf '\n## Ordered subtask steps\n\n%s\n' "$steps_markdown"
      printf '\nExecute the pending subtask steps in the exact order shown. Preserve the existing order; nested subtasks follow their parent step immediately. Steps marked [DONE] are context and must not be repeated.\n'
    fi
    if todo_task_is_report_only "$task_json"; then
      printf '\nThis is an informational report-only task. Do not modify a repository, create a branch, or create a PR. Manul will save the final answer as a completed subtask under this Todo task and verify it before completing the task tree.\n'
      printf 'Write the saved result as a polished, self-contained Markdown document. Its FIRST line must be one concise plain-text sentence summarizing the answer or the key conclusion; this line is used as the Todo task-list preview. Do not put a heading, blank line, label, HTML comment, hash, or code fence before that sentence.\n'
      printf 'After the first line, provide the full explanation and useful details using clear Markdown headings, paragraphs, lists, and code fences when appropriate. Avoid unnecessary boilerplate and tables.\n'
      printf 'Manul will append a short task-context section with the source and original Todo task description. Do not add task IDs, source labels, hashes, fingerprints, HTML comments, or other internal metadata yourself.\n'
      printf 'The final output must end with a standalone completion marker on its own line: TASK_DONE or TASK_FAILED: <brief reason>. Write the marker as plain text, without Markdown backticks or code fences. Do not put any prose after the marker.\n'
    else
      printf '\nAfter the implementation is complete and its PR is verified, Manul will mark this Todo task and its subtasks done. Do not change Todo completion state yourself.\n'
    fi
  }
}

todo_task_to_source_json() {
  local task_json="$1" source_type="$2" resolution_json="${3:-}"
  local repository task_id fingerprint source_id source_url title body prompt ids created updated matched_alias project_skill_context resolution_method report_only
  [ -n "$resolution_json" ] || resolution_json='{}'
  report_only="$(jq -r '.reportOnly // false' <<<"$resolution_json")"
  repository="$(jq -r '.repository // empty' <<<"$resolution_json")"
  if [ "$report_only" != "true" ] && [ -z "$repository" ]; then return 1; fi
  task_id="$(jq -r '.id // empty' <<<"$task_json")"
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 1
  fingerprint="$(todo_task_fingerprint "$task_json")" || return 1
  source_id="${task_id}@${fingerprint}"
  case "$source_type" in
    todo_local_mcp) source_url="todo-local://task/${source_id}" ;;
    todo_remote_mcp) source_url="fiteo-todo://task/${source_id}" ;;
    *) return 2 ;;
  esac
  title="$(jq -r '.description // "Todo task"' <<<"$task_json")"
  body="$title"
  prompt="$(todo_task_prompt "$task_json" "$source_id")"
  resolution_method="$(jq -r '.method // "unknown"' <<<"$resolution_json")"
  if [ "$report_only" != "true" ]; then
    prompt+=$'\n\n## Repository routing\n\nTarget repository: '
    prompt+="$repository"
    prompt+=$'\nResolution method: '
    prompt+="$resolution_method"
    matched_alias="$(jq -r '.matchedAlias // empty' <<<"$resolution_json")"
    if [ -n "$matched_alias" ]; then
      prompt+=$'\nMatched project alias: '
      prompt+="$matched_alias"
    fi
    project_skill_context="$(todo_task_resolved_skill_context "$resolution_json")"
    if [ -n "$project_skill_context" ]; then
      prompt+=$'\n\n## Relevant project skills (included below)\n\n'
      prompt+="$project_skill_context"
    fi
  fi
  ids="$(todo_task_ids_json "$task_json")"
  created="$(jq -r '.addedTime // ""' <<<"$task_json")"
  updated="$(jq -r '.modifiedTime // .addedTime // ""' <<<"$task_json")"
  jq -cn \
    --arg type "$source_type" \
    --arg sourceId "$source_id" \
    --arg sourceUrl "$source_url" \
    --arg title "$title" \
    --arg body "$body" \
    --arg prompt "$prompt" \
    --arg created "$created" \
    --arg updated "$updated" \
    --arg repository "$repository" \
    --argjson resolution "$resolution_json" \
    --argjson taskId "$task_id" \
    --argjson stepIds "$ids" \
    --argjson reportOnly "$report_only" \
    '{
      taskSourceType:$type,
      taskSourceId:$sourceId,
      taskSourceUrl:$sourceUrl,
      title:$title,
      body:$body,
      prompt:$prompt,
      action:"IMPLEMENT",
      createdAt:$created,
      updatedAt:$updated,
      state:"OPEN",
      metadata:({
        issueNumber:0,
        todoTaskId:$taskId,
        stepIds:$stepIds
      } + (if $repository != "" then {repository:$repository,repositoryResolution:$resolution} else {} end)),
      execution:{kind:(if $reportOnly then "report_only" else "repository" end)}
    }'
}

todo_task_is_active() {
  jq -e '(.isToDo // false) == true and (.scheduler == null)' <<<"$1" >/dev/null 2>&1
}

todo_task_tree_is_done() {
  jq -e '
    def tasks: [.] + ([.subTasks[]? | tasks] | add // []);
    all(tasks[]; .isToDo == false)
  ' <<<"$1" >/dev/null 2>&1
}

todo_task_has_local_trigger() {
  jq -e '
    def triggered:
      ((.description // "") | test("(^|\\n)[[:space:]]*/manul([[:space:]]|$)"))
      or any(.subTasks[]?; triggered);
    triggered
  ' <<<"$1" >/dev/null 2>&1
}

# A remote task is only actionable when the command is present anywhere in
# its task tree. Sharing alone grants visibility, never execution permission.
todo_task_has_remote_trigger() {
  jq -e '
    def triggered:
      ((.description // "") | test("(^|\\n)[[:space:]]*/manul([[:space:]]|$)"))
      or any(.subTasks[]?; triggered);
    triggered
  ' <<<"$1" >/dev/null 2>&1
}

todo_task_has_remote_share() {
  local task_json="$1" user_id="$2"
  [[ "$user_id" =~ ^[0-9]+$ ]] || return 1
  jq -e --arg userId "$user_id" '
    any(.shares[]?;
      ((.userId | tostring) == $userId)
      and .permission == "EDITOR_AND_VIEWER"
    )
  ' <<<"$task_json" >/dev/null 2>&1
}

todo_task_still_current() {
  local source_json="$1" source_type="$2" source_id="$3"
  local task_id expected_version tasks_json task_json actual_version
  task_id="$(todo_task_id_from_source_id "$source_id")"
  expected_version="$(todo_task_version_from_source_id "$source_id")" || return 1
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return 2
  task_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  case "$source_type" in
    todo_local_mcp)
      todo_task_has_local_trigger "$task_json" || return 1 ;;
    todo_remote_mcp)
      local manul_user_id
      manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
      todo_task_has_remote_share "$task_json" "$manul_user_id" || return 1
      todo_task_has_remote_trigger "$task_json" || return 1 ;;
    *)
      return 2 ;;
  esac
  actual_version="$(todo_task_fingerprint "$task_json")"
  [ "$actual_version" = "$expected_version" ] || return 1
  return 0
}

todo_task_mark_done() {
  local source_json="$1" source_type="$2" source_id="$3"
  local task_id expected_version tasks_json task_json actual_version ids_json arguments tool
  task_id="$(todo_task_id_from_source_id "$source_id")"
  expected_version="$(todo_task_version_from_source_id "$source_id")" || return 1
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return 1
  task_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  case "$source_type" in
    todo_local_mcp)
      todo_task_has_local_trigger "$task_json" || return 1 ;;
    todo_remote_mcp)
      local manul_user_id
      manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
      todo_task_has_remote_share "$task_json" "$manul_user_id" || return 1
      todo_task_has_remote_trigger "$task_json" || return 1 ;;
    *)
      return 2 ;;
  esac
  actual_version="$(todo_task_fingerprint "$task_json")"
  [ "$actual_version" = "$expected_version" ] || return 1
  # A lost response after the final root update is still a successful,
  # idempotent completion when the entire tree is already done.
  todo_task_tree_is_done "$task_json" && return 0
  todo_task_is_active "$task_json" || return 1
  ids_json="$(todo_task_ids_json "$task_json")"
  if [ "$source_type" = "todo_local_mcp" ]; then
    arguments="$(jq -c 'reverse' <<<"$ids_json")"
    arguments="$(jq -cn --argjson taskIds "$arguments" '{taskIds:$taskIds}')"
    todo_mcp_source_call "$source_json" "$source_type" "mark_tasks_done" "$arguments" >/dev/null
  else
    # Fiteo's bulk mark tool checks a direct share on every ID. Updating each
    # task individually preserves its existing ancestor-share permission rules.
    # Descendants go first and the root last, so the root stays active if one
    # child update fails and a retry can safely resume the same tree.
    local task_item
    while IFS= read -r task_item; do
      local step_id
      step_id="$(jq -r '.id' <<<"$task_item")"
      arguments="$(jq -cn --argjson id "$step_id" '{id:$id,task:{isToDo:false}}')"
      todo_mcp_source_call "$source_json" "$source_type" "todo_update_task" "$arguments" >/dev/null || return $?
    done < <(jq -c 'def ids: [{id}] + ([.subTasks[]? | ids] | add // []); ids | reverse[]' <<<"$task_json")
  fi
}


# The Todo UI renders descriptions with mikepenz/multiplatform-markdown-renderer.
# Preserve Markdown structure and make ordinary line breaks explicit hard breaks.
todo_task_markdown_format() {
  python3 -c '
import re, sys
text = sys.stdin.read().replace("\r\n", "\n").replace("\r", "\n")
lines = text.split("\n")
result = []
in_fence = False
fence_char = None
fence_length = 0
for index, line in enumerate(lines):
    match = re.match(r"^\s*(\x60{3,}|~{3,})", line)
    if match:
        marker = match.group(1)
        if not in_fence:
            in_fence, fence_char, fence_length = True, marker[0], len(marker)
        elif marker[0] == fence_char and len(marker) >= fence_length:
            in_fence, fence_char, fence_length = False, None, 0
        result.append(line)
        continue
    next_line = lines[index + 1] if index + 1 < len(lines) else ""
    if (
        not in_fence
        and line
        and next_line.strip()
        and not line.endswith(("  ", "\\"))
    ):
        line += "  "
    result.append(line)
sys.stdout.write("\n".join(result))
'
}


# Read the original answer from a verified report marker. New records carry a
# separately checksummed base64 payload; legacy records fall back to Markdown.
todo_task_report_markdown() {
  local generated_answer="$1" source_type="$2" root_json="$3"
  local formatted_answer source_label task_description

  formatted_answer="$(todo_task_markdown_format <<<"$generated_answer")" || return 1
  task_description="$(jq -r '.description // empty' <<<"$root_json")"
  task_description="$(todo_strip_manul_trigger "$task_description" | python3 -c 'import sys; print(sys.stdin.read().strip())')"
  [ -n "$task_description" ] || task_description="Brak opisu zadania."

  case "$source_type" in
    todo_local_mcp) source_label="Todo Local" ;;
    todo_remote_mcp) source_label="Fiteo Backend" ;;
    *) return 2 ;;
  esac

  {
    printf '%s\n\n---\n\n## Kontekst zadania\n\n' "$formatted_answer"
    printf -- '- **Źródło:** %s\n' "$source_label"
    printf -- '- **Zadanie:** %s\n' "$task_description"
  } | todo_task_markdown_format
}

# Read the original answer from a verified report marker. New records keep the
# marker after the Markdown body so Todo's first-line preview stays user-facing.
# The parser also accepts legacy records whose marker was the first line.
todo_task_report_receipt_answer() {
  printf '%s' "$1" | python3 -c '
import base64, hashlib, re, sys

description = sys.stdin.read()
lines = description.splitlines()
marker_positions = [
    position for position, line in enumerate(lines)
    if line.startswith("<!-- MANUL_REPORT_RESULT:v1;")
]
if len(marker_positions) != 1:
    raise SystemExit("Todo report result marker is invalid")
marker_position = marker_positions[0]
marker = lines[marker_position]
match = re.fullmatch(
    r"<!-- MANUL_REPORT_RESULT:v1;root=([0-9]+);source=([0-9]+@[0-9a-f]{16});"
    r"sha256=([0-9a-f]{64})(?:;answerSha256=([0-9a-f]{64});"
    r"answerBase64=([A-Za-z0-9+/]*={0,2}))? -->",
    marker,
)
if marker_position == 0 and "\n" in description:
    payload = description.partition("\n")[2]  # Legacy marker at the start.
elif marker_position == len(lines) - 1 and "\n" in description:
    payload = description.rsplit("\n", 1)[0]  # New marker after the Markdown.
else:
    raise SystemExit("Todo report result marker is not at the beginning or end")
if not match:
    raise SystemExit("Todo report result marker is invalid")
if hashlib.sha256(payload.encode("utf-8")).hexdigest() != match.group(3):
    raise SystemExit("Todo report Markdown payload digest does not match")
if match.group(4) is None:
    sys.stdout.write(payload)
else:
    raw_answer = base64.b64decode(match.group(5), validate=True)
    if hashlib.sha256(raw_answer).hexdigest() != match.group(4):
        raise SystemExit("Todo report original answer digest does not match")
    raw_answer.decode("utf-8")
    sys.stdout.buffer.write(raw_answer)
'
}

# Persist an informational answer as a child task. The marker binds the record
# to the exact source version and payload digest; retries reuse it instead of
# creating duplicate answers, including after a lost MCP response.
todo_task_report_deliver() {
  local source_json="$1" source_type="$2" source_id="$3" generated_answer="$4"
  local task_id expected_version tasks_json root_json marker_prefix result_json result_count
  local result_id result_description result_todo arguments answer digest receipt actual_version formatted_answer answer_digest answer_base64 answer_with_sentinel
  local manul_user_id=""
  task_id="$(todo_task_id_from_source_id "$source_id")"
  expected_version="$(todo_task_version_from_source_id "$source_id")" || return 1
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 1

  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  case "$source_type" in
    todo_local_mcp)
      todo_task_has_local_trigger "$root_json" || return 1 ;;
    todo_remote_mcp)
      manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
      # The parent must already be shared with Manul. Its descendants inherit
      # that access, so a result child does not need a duplicate direct share.
      todo_task_has_remote_share "$root_json" "$manul_user_id" || return 1 ;;
    *)
      return 2 ;;
  esac
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo source changed before the report could be saved" >&2
    return 1
  }

  marker_prefix="<!-- MANUL_REPORT_RESULT:v1;root=${task_id};source=${source_id};"
  result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  result_count="$(jq -r 'length' <<<"$result_json")"
  if [ "$result_count" -gt 1 ]; then
    echo "Multiple Manul report result subtasks exist for this Todo source version" >&2
    return 1
  fi

  formatted_answer="$(todo_task_report_markdown "$generated_answer" "$source_type" "$root_json")" || return 1

  if [ "$result_count" -eq 1 ]; then
    result_json="$(jq -c '.[0]' <<<"$result_json")"
    result_id="$(jq -r '.id // empty' <<<"$result_json")"
    result_description="$(jq -r '.description // empty' <<<"$result_json")"
  else
    digest="$(printf '%s' "$formatted_answer" | sha256sum | awk '{print $1}')"
    answer_digest="$(printf '%s' "$generated_answer" | sha256sum | awk '{print $1}')"
    answer_base64="$(printf '%s' "$generated_answer" | python3 -c 'import base64, sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode("ascii"))')" || return 1
    result_description="${formatted_answer}"
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}')"
        todo_mcp_source_call "$source_json" "$source_type" create_task "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{task:{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_create_task "$arguments" >/dev/null || return $? ;;
    esac
    tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
    root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
    result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
      [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
    ' <<<"$root_json")" || return 1
    result_count="$(jq -r 'length' <<<"$result_json")"
    [ "$result_count" -eq 1 ] || {
      echo "Todo report create did not produce exactly one readable result subtask" >&2
      return 1
    }
    result_json="$(jq -c '.[0]' <<<"$result_json")"
    result_id="$(jq -r '.id // empty' <<<"$result_json")"
    result_description="$(jq -r '.description // empty' <<<"$result_json")"
  fi

  [[ "$result_id" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo report result read-back failed source-version verification" >&2
    return 1
  }
  result_todo="$(jq -r 'if .isToDo == null then "true" else (.isToDo|tostring) end' <<<"$result_json")"
  if [ "$result_todo" != "false" ]; then
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --argjson taskId "$result_id" '{taskIds:[$taskId]}')"
        todo_mcp_source_call "$source_json" "$source_type" mark_tasks_done "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --argjson id "$result_id" '{id:$id,task:{isToDo:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_update_task "$arguments" >/dev/null || return $? ;;
    esac
  fi

  # Read the provider state again after mutation. Exact text, parent, completed
  # flag, unique receipt and unchanged source structure are all required.
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  [ "$(jq -r 'length' <<<"$result_json")" -eq 1 ] || return 1
  result_json="$(jq -c '.[0]' <<<"$result_json")"
  [ "$(jq -r '.parentTaskId' <<<"$result_json")" = "$task_id" ] || return 1
  [ "$(jq -r '.isToDo' <<<"$result_json")" = "false" ] || return 1
  [ "$(jq -r '.description // empty' <<<"$result_json")" = "$result_description" ] || return 1
  if [ "$source_type" = "todo_remote_mcp" ] &&
     ! todo_task_has_remote_share "$root_json" "$manul_user_id"; then
    echo "Todo report parent is no longer shared with Manul" >&2
    return 1
  fi
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo source changed while the report result was being verified" >&2
    return 1
  }

  answer_with_sentinel="$(todo_task_report_receipt_answer "$result_description" && printf '\001')" || return 1
  answer="${answer_with_sentinel%$'\001'}"
  digest="$(printf '%s' "$answer" | sha256sum | awk '{print $1}')"
  receipt="$(jq -cn \
    --arg sourceId "$source_id" \
    --argjson rootTaskId "$task_id" \
    --argjson resultTaskId "$result_id" \
    --arg answerSha256 "$digest" \
    --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg answer "$answer" \
    '{sourceId:$sourceId,rootTaskId:$rootTaskId,resultTaskId:$resultTaskId,answerSha256:$answerSha256,verifiedAt:$verifiedAt,answer:$answer}')"
  printf '%s\n' "$receipt"
}\n'"${marker_prefix}"sha256=${digest};answerSha256=${answer_digest};answerBase64=${answer_base64} -->"
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}')"
        todo_mcp_source_call "$source_json" "$source_type" create_task "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{task:{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_create_task "$arguments" >/dev/null || return $? ;;
    esac
    tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
    root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
    result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
      [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
    ' <<<"$root_json")" || return 1
    result_count="$(jq -r 'length' <<<"$result_json")"
    [ "$result_count" -eq 1 ] || {
      echo "Todo report create did not produce exactly one readable result subtask" >&2
      return 1
    }
    result_json="$(jq -c '.[0]' <<<"$result_json")"
    result_id="$(jq -r '.id // empty' <<<"$result_json")"
    result_description="$(jq -r '.description // empty' <<<"$result_json")"
  fi

  [[ "$result_id" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo report result read-back failed source-version verification" >&2
    return 1
  }
  result_todo="$(jq -r 'if .isToDo == null then "true" else (.isToDo|tostring) end' <<<"$result_json")"
  if [ "$result_todo" != "false" ]; then
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --argjson taskId "$result_id" '{taskIds:[$taskId]}')"
        todo_mcp_source_call "$source_json" "$source_type" mark_tasks_done "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --argjson id "$result_id" '{id:$id,task:{isToDo:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_update_task "$arguments" >/dev/null || return $? ;;
    esac
  fi

  # Read the provider state again after mutation. Exact text, parent, completed
  # flag, unique receipt and unchanged source structure are all required.
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  [ "$(jq -r 'length' <<<"$result_json")" -eq 1 ] || return 1
  result_json="$(jq -c '.[0]' <<<"$result_json")"
  [ "$(jq -r '.parentTaskId' <<<"$result_json")" = "$task_id" ] || return 1
  [ "$(jq -r '.isToDo' <<<"$result_json")" = "false" ] || return 1
  [ "$(jq -r '.description // empty' <<<"$result_json")" = "$result_description" ] || return 1
  if [ "$source_type" = "todo_remote_mcp" ] &&
     ! todo_task_has_remote_share "$root_json" "$manul_user_id"; then
    echo "Todo report parent is no longer shared with Manul" >&2
    return 1
  fi
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo source changed while the report result was being verified" >&2
    return 1
  }

  answer_with_sentinel="$(todo_task_report_receipt_answer "$result_description" && printf '\001')" || return 1
  answer="${answer_with_sentinel%$'\001'}"
  digest="$(printf '%s' "$answer" | sha256sum | awk '{print $1}')"
  receipt="$(jq -cn \
    --arg sourceId "$source_id" \
    --argjson rootTaskId "$task_id" \
    --argjson resultTaskId "$result_id" \
    --arg answerSha256 "$digest" \
    --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg answer "$answer" \
    '{sourceId:$sourceId,rootTaskId:$rootTaskId,resultTaskId:$resultTaskId,answerSha256:$answerSha256,verifiedAt:$verifiedAt,answer:$answer}')"
  printf '%s\n' "$receipt"
}
\n'"${marker_prefix}sha256=${digest};answerSha256=${answer_digest};answerBase64=${answer_base64} -->"
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}')"
        todo_mcp_source_call "$source_json" "$source_type" create_task "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{task:{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_create_task "$arguments" >/dev/null || return $? ;;
    esac
    tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
    root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
    result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
      [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
    ' <<<"$root_json")" || return 1
    result_count="$(jq -r 'length' <<<"$result_json")"
    [ "$result_count" -eq 1 ] || {
      echo "Todo report create did not produce exactly one readable result subtask" >&2
      return 1
    }
    result_json="$(jq -c '.[0]' <<<"$result_json")"
    result_id="$(jq -r '.id // empty' <<<"$result_json")"
    result_description="$(jq -r '.description // empty' <<<"$result_json")"
  fi

  [[ "$result_id" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo report result read-back failed source-version verification" >&2
    return 1
  }
  result_todo="$(jq -r 'if .isToDo == null then "true" else (.isToDo|tostring) end' <<<"$result_json")"
  if [ "$result_todo" != "false" ]; then
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --argjson taskId "$result_id" '{taskIds:[$taskId]}')"
        todo_mcp_source_call "$source_json" "$source_type" mark_tasks_done "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --argjson id "$result_id" '{id:$id,task:{isToDo:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_update_task "$arguments" >/dev/null || return $? ;;
    esac
  fi

  # Read the provider state again after mutation. Exact text, parent, completed
  # flag, unique receipt and unchanged source structure are all required.
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  [ "$(jq -r 'length' <<<"$result_json")" -eq 1 ] || return 1
  result_json="$(jq -c '.[0]' <<<"$result_json")"
  [ "$(jq -r '.parentTaskId' <<<"$result_json")" = "$task_id" ] || return 1
  [ "$(jq -r '.isToDo' <<<"$result_json")" = "false" ] || return 1
  [ "$(jq -r '.description // empty' <<<"$result_json")" = "$result_description" ] || return 1
  if [ "$source_type" = "todo_remote_mcp" ] &&
     ! todo_task_has_remote_share "$root_json" "$manul_user_id"; then
    echo "Todo report parent is no longer shared with Manul" >&2
    return 1
  fi
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo source changed while the report result was being verified" >&2
    return 1
  }

  answer_with_sentinel="$(todo_task_report_receipt_answer "$result_description" && printf '\001')" || return 1
  answer="${answer_with_sentinel%$'\001'}"
  digest="$(printf '%s' "$answer" | sha256sum | awk '{print $1}')"
  receipt="$(jq -cn \
    --arg sourceId "$source_id" \
    --argjson rootTaskId "$task_id" \
    --argjson resultTaskId "$result_id" \
    --arg answerSha256 "$digest" \
    --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg answer "$answer" \
    '{sourceId:$sourceId,rootTaskId:$rootTaskId,resultTaskId:$resultTaskId,answerSha256:$answerSha256,verifiedAt:$verifiedAt,answer:$answer}')"
  printf '%s\n' "$receipt"
}\n'"${marker_prefix}"sha256=${digest};answerSha256=${answer_digest};answerBase64=${answer_base64} -->"
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}')"
        todo_mcp_source_call "$source_json" "$source_type" create_task "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{task:{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_create_task "$arguments" >/dev/null || return $? ;;
    esac
    tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
    root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
    result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
      [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
    ' <<<"$root_json")" || return 1
    result_count="$(jq -r 'length' <<<"$result_json")"
    [ "$result_count" -eq 1 ] || {
      echo "Todo report create did not produce exactly one readable result subtask" >&2
      return 1
    }
    result_json="$(jq -c '.[0]' <<<"$result_json")"
    result_id="$(jq -r '.id // empty' <<<"$result_json")"
    result_description="$(jq -r '.description // empty' <<<"$result_json")"
  fi

  [[ "$result_id" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo report result read-back failed source-version verification" >&2
    return 1
  }
  result_todo="$(jq -r 'if .isToDo == null then "true" else (.isToDo|tostring) end' <<<"$result_json")"
  if [ "$result_todo" != "false" ]; then
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --argjson taskId "$result_id" '{taskIds:[$taskId]}')"
        todo_mcp_source_call "$source_json" "$source_type" mark_tasks_done "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --argjson id "$result_id" '{id:$id,task:{isToDo:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_update_task "$arguments" >/dev/null || return $? ;;
    esac
  fi

  # Read the provider state again after mutation. Exact text, parent, completed
  # flag, unique receipt and unchanged source structure are all required.
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  [ "$(jq -r 'length' <<<"$result_json")" -eq 1 ] || return 1
  result_json="$(jq -c '.[0]' <<<"$result_json")"
  [ "$(jq -r '.parentTaskId' <<<"$result_json")" = "$task_id" ] || return 1
  [ "$(jq -r '.isToDo' <<<"$result_json")" = "false" ] || return 1
  [ "$(jq -r '.description // empty' <<<"$result_json")" = "$result_description" ] || return 1
  if [ "$source_type" = "todo_remote_mcp" ] &&
     ! todo_task_has_remote_share "$root_json" "$manul_user_id"; then
    echo "Todo report parent is no longer shared with Manul" >&2
    return 1
  fi
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo source changed while the report result was being verified" >&2
    return 1
  }

  answer_with_sentinel="$(todo_task_report_receipt_answer "$result_description" && printf '\001')" || return 1
  answer="${answer_with_sentinel%$'\001'}"
  digest="$(printf '%s' "$answer" | sha256sum | awk '{print $1}')"
  receipt="$(jq -cn \
    --arg sourceId "$source_id" \
    --argjson rootTaskId "$task_id" \
    --argjson resultTaskId "$result_id" \
    --arg answerSha256 "$digest" \
    --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg answer "$answer" \
    '{sourceId:$sourceId,rootTaskId:$rootTaskId,resultTaskId:$resultTaskId,answerSha256:$answerSha256,verifiedAt:$verifiedAt,answer:$answer}')"
  printf '%s\n' "$receipt"
}
