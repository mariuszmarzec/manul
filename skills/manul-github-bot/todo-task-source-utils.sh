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

# Resolve Todo task targets from the complete task tree. The global
# .repositories list is both the allowlist and the source of configured
# owner/repo names and short repository slugs; the catalog adds optional aliases.
todo_task_resolve_repository() {
  local source_json="$1" task_json="$2"
  local catalog_file description explicit_matches candidate_count repository method matched_alias
  local catalog_json="" catalog_valid=false matches_json match_json entry_json="" repositories_json canonical_repository skills_json="[]"
  local configured_matches_json direct_matches_json direct_match_count

  # Inspect the complete Todo tree: the repository may be named in any
  # root/child/grandchild description, not necessarily on the root.
  description="$(jq -r '
    def strip_trigger:
      gsub("(?m)^[[:space:]]*/manul([[:space:]]+report)?([[:space:]]+|$)"; "");
    def task_descriptions:
      ((.description // "") | strip_trigger),
      (.subTasks[]? | task_descriptions);
    [task_descriptions] | join("\n")
  ' <<<"$task_json")" || return 2

  # The top-level .repositories list is the allowlist and also the source of
  # configured short names. "repo todo" selects mariuszmarzec/todo without
  # requiring a project-catalog alias.
  repositories_json="$(todo_mcp_source_repositories "$source_json")" || return 2
  configured_matches_json='[]'
  local configured_repository configured_owner configured_slug owner_pattern slug_pattern configured_method
  while IFS= read -r configured_repository; do
    [[ "$configured_repository" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || continue
    configured_owner="${configured_repository%%/*}"
    configured_slug="${configured_repository#*/}"
    # Repository path components are restricted above; escape their only ERE
    # metacharacter (dot) before constructing whole-token patterns.
    owner_pattern="${configured_owner//./\\.}"
    slug_pattern="${configured_slug//./\\.}"
    if grep -Eiq "(^|[^[:alnum:]_.-])${owner_pattern}/${slug_pattern}([.]git)?([^[:alnum:]_.-]|[.]([[:space:]]|$)|$)" <<<"$description"; then
      configured_method="explicit_repository_name"
      matched_alias=""
    elif grep -Eiq "(^|[^[:alnum:]_.-])(repo|repository)[[:space:]:=]+${slug_pattern}([^[:alnum:]_.-]|[.]([[:space:]]|$)|$)" <<<"$description"; then
      configured_method="configured_repository_slug"
      matched_alias="$configured_slug"
    else
      continue
    fi
    configured_matches_json="$(jq -cn \
      --argjson existing "$configured_matches_json" \
      --arg repository "$configured_repository" \
      --arg method "$configured_method" \
      --arg matchedAlias "$matched_alias" \
      '$existing + [{repository:$repository,method:$method,matchedAlias:$matchedAlias}]')" || return 2
  done < <(jq -r '.[]' <<<"$repositories_json")

  explicit_matches="$(
    grep -Eo 'https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' <<<"$description" \
      | sed -E 's#^https?://github\.com/##; s#\.git$##' \
      | sort -u || true
  )"

  # URLs and configured names are stronger signals than catalog aliases.
  # Multiple different configured targets in one tree are rejected, never
  # resolved by occurrence order.
  direct_matches_json="$(jq -cn \
    --arg urls "$explicit_matches" \
    --argjson configured "$configured_matches_json" '
      ([
        $urls
        | split("\n")[]
        | select(length > 0)
        | {repository:., method:"explicit_github_url", matchedAlias:"", length:(length)}
      ] + $configured)
      | group_by(.repository)
      | map(
          sort_by(
            if .method == "explicit_github_url" then 0
            elif .method == "explicit_repository_name" then 1
            else 2 end
          )[0]
        )
    ')" || return 2
  direct_match_count="$(jq -r 'length' <<<"$direct_matches_json")" || return 2

  if [ "$direct_match_count" -gt 1 ]; then
    local candidates
    candidates="$(jq -r '[.[].repository] | join(", ")' <<<"$direct_matches_json")"
    echo "Todo task mentions multiple configured repositories; routing is ambiguous ($candidates)" >&2
    return 1
  fi

  # The project catalog is optional when the task names an allowlisted
  # repository directly. It is needed only for project aliases/skill metadata.
  catalog_file="$(todo_task_repository_catalog_path)"
  if [ -r "$catalog_file" ]; then
    catalog_json="$(cat "$catalog_file" 2>/dev/null || true)"
    if jq -e '.repositories | type == "array"' <<<"$catalog_json" >/dev/null 2>&1; then
      catalog_valid=true
    else
      catalog_json=""
    fi
  fi

  if [ "$direct_match_count" -eq 1 ]; then
    match_json="$(jq -c '.[0]' <<<"$direct_matches_json")"
    repository="$(jq -r '.repository' <<<"$match_json")"
    method="$(jq -r '.method' <<<"$match_json")"
    matched_alias="$(jq -r '.matchedAlias // empty' <<<"$match_json")"
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
          | (($repo.aliases // []) + [(($repo.name // "") | split("/") | last)])[] as $alias
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
      echo "no project alias matched and no configured repository name was present in the Todo task tree" >&2
      # No project reference remains the informational/report-only fallback.
      # Ambiguous and disallowed repository targets fail closed above/below.
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
todo_task_strip_verified_generated_update() {
  local task_json="$1" root_id parsed candidate_record candidate_json candidate_source expected_version
  local verified_count=0 verified_candidate=""
  root_id="$(jq -r '.id // empty' <<<"$task_json")"
  [[ "$root_id" =~ ^[0-9]+$ ]] || { printf '%s\n' "$task_json"; return 0; }
  parsed="$(python3 -c '
import base64, hashlib, json, re, sys
root_id = int(sys.argv[1])
root = json.load(sys.stdin)
valid_positions = []
valid_sources = []
report_marker_pattern = re.compile(
    r"<!-- MANUL_REPORT_RESULT:v1;root=([0-9]+);source=([0-9]+@[0-9a-f]{16});"
    r"sha256=([0-9a-f]{64})(?:;answerSha256=([0-9a-f]{64});"
    r"answerBase64=([A-Za-z0-9+/]*={0,2}))? -->"
)
update_marker_pattern = re.compile(
    r"<!-- MANUL_TASK_UPDATE:v1;root=([0-9]+);source=([0-9]+@[0-9a-f]{16});"
    r"status=(?:needs_input|failed|answered);sha256=([0-9a-f]{64}) -->"
)
for index, child in enumerate(root.get("subTasks") or []):
    description = child.get("description")
    if not isinstance(description, str):
        continue
    lines = description.splitlines()
    marker_positions = [
        position for position, line in enumerate(lines)
        if line.startswith("<!-- MANUL_REPORT_RESULT:v1;")
        or line.startswith("<!-- MANUL_TASK_UPDATE:v1;")
    ]
    if len(marker_positions) != 1:
        continue
    marker_position = marker_positions[0]
    marker = lines[marker_position]
    report_match = report_marker_pattern.fullmatch(marker)
    update_match = update_marker_pattern.fullmatch(marker)
    match = report_match or update_match
    if not match or int(match.group(1)) != root_id:
        continue
    if marker_position == 0 and report_match and "\n" in description:
        payload = description.partition("\n")[2]
    elif marker_position == len(lines) - 1 and "\n" in description:
        payload = description.rsplit("\n", 1)[0]
    else:
        continue
    if child.get("parentTaskId") != root_id or child.get("subTasks"):
        continue
    if hashlib.sha256(payload.encode("utf-8")).hexdigest() != match.group(3):
        continue
    if report_match and match.group(4) is not None:
        try:
            raw_answer = base64.b64decode(match.group(5), validate=True)
            raw_answer.decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        if hashlib.sha256(raw_answer).hexdigest() != match.group(4):
            continue
    valid_positions.append(index)
    valid_sources.append(match.group(2))
if valid_positions:
    candidate = dict(root)
    candidate["subTasks"] = [
        item for position, item in enumerate(root.get("subTasks") or [])
        if position not in set(valid_positions)
    ]
    print(json.dumps([{"task": candidate, "sourceIds": valid_sources}], separators=(",", ":")))
else:
    print("[]")
' "$root_id" <<<"$task_json")" || { printf '%s\n' "$task_json"; return 0; }

  # Test each individually valid output record against the source tree that
  # remains when only that record is removed. This keeps historical Manul
  # reports in the user's task tree while excluding exactly the record bound
  # to the current source version. Ambiguous matches fail closed.
  while IFS= read -r candidate_record; do
    candidate_json="$(jq -c '.task' <<<"$candidate_record")"
    expected_version="$(todo_task_fingerprint_raw "$candidate_json")" || continue
    if jq -e --arg sourceId "${root_id}@${expected_version}" '.sourceIds | index($sourceId) != null' <<<"$candidate_record" >/dev/null 2>&1; then
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
  stable_task="$(todo_task_strip_verified_generated_update "$1")" || return 1
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
    task_json="$(todo_task_strip_verified_generated_update "$task_json")" || return 1
  fi
  jq -c '
    def descendants($depth):
      . as $task
      | [{id:$task.id, description:(($task.description // "") | sub("^[[:space:]]*/manul([[:space:]]+report)?([[:space:]]+|$)"; "") | gsub("\\n[[:space:]]*/manul([[:space:]]+report)?([[:space:]]+|$)"; "\n")), isToDo:(if ($task | has("isToDo")) then $task.isToDo else true end), depth:$depth}]
        + ([ $task.subTasks[]? | descendants($depth + 1) ] | add // []);
    [.subTasks[]? | descendants(0)] | add // []
  ' <<<"$task_json"
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

# Route clear natural-language questions to the dedicated tool-free answer path.
# This is deliberately conservative: implementation commands still require a
# uniquely allowlisted repository and create a routing blocker when missing.
todo_task_is_answer_request() {
  local task_json="$1" description
  description="$(jq -r '
    def strip_trigger:
      gsub("(?m)^[[:space:]]*/manul([[:space:]]+report)?([[:space:]]+|$)"; "");
    def task_descriptions:
      ((.description // "") | strip_trigger),
      (.subTasks[]? | task_descriptions);
    [task_descriptions] | join("\n")
  ' <<<"$task_json")" || return 1
  [ -n "$(printf '%s' "$description" | tr -d '[:space:]')" ] || return 1

  # Explicit change/delivery instructions must never be downgraded to answers.
  if grep -Eiq '(^|[^[:alnum:]_])(implement|implementing|fix|fixes|create|add|modify|update|refactor|deploy|merge|commit|open[[:space:]]+a?[[:space:]]*(pull[[:space:]]+request|pr)|zaimplementuj|implementuj|napraw|dodaj|utw[oó]rz|zmie[nń]|popraw|zrefaktoryzuj|wdro[zż]|scal|merguj|zmergeuj|napisz[[:space:]]+kod|zmie[nń][[:space:]]+plik)([^[:alnum:]_]|$)' <<<"$description"; then
    return 1
  fi

  # Require a question/explanation cue; arbitrary un-routed work remains blocked.
  grep -Eiq '(^|[[:space:][:punct:]])(what|what.s|which|who|when|where|why|how|is|are|am|can|could|do|does|did|will|would|should|has|have|explain|describe|summari[sz]e|tell[[:space:]]+me|jaki|jaka|jakie|jak|co|kiedy|gdzie|dlaczego|czy|kto|ile|kt[oó]ry|kt[oó]ra|kt[oó]re|wyja[sś]nij|wyt[lł]umacz|opisz|stre[sś][cć]|podsumuj|powiedz|podaj|daj[[:space:]]+zna[cć]|sprawd[zź])([[:space:][:punct:]]|$)|[?？]' <<<"$description"
}

todo_task_prompt() {
  local task_json="$1" source_id="${2:-}" execution_kind="${3:-repository}"
  local prompt_text steps_json steps_markdown description task_id answer_current_date
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
      printf '\nExecute pending subtask steps in their exact order. Preserve the existing order; nested subtasks follow their parent step immediately. Steps marked [DONE] are context and must not be repeated.\n'
    fi
    if [ "$execution_kind" = "answer" ]; then
      answer_current_date="$(TZ=Europe/Warsaw LC_ALL=C date '+%A, %Y-%m-%d %H:%M %Z' 2>/dev/null || date '+%A, %Y-%m-%d %H:%M %Z')"
      printf '\n## Direct answer task\n\n'
      printf 'This is a normal informational answer, not repository implementation and not a report-only task.\n'
      printf 'No repository is assigned or needed. Answer the user directly and clearly in the same language as the request. Do not ask for a repository merely because none was supplied.\n'
      printf 'The current date and time in the user timezone (Europe/Warsaw) is: %s. Use this exact date when answering questions such as the current weekday; do not infer today from model training data.\n' "$answer_current_date"
      printf 'This execution is tool-free and has no repository, shell, filesystem, browser, GitHub, or MCP access. Answer from the supplied task and general knowledge. When a live external fact cannot be established from the supplied context, state that limitation rather than inventing it.\n'
      printf 'Do not create code, branches, commits, or PRs. Do not emit TASK_NEEDS_USER just because there is no repository. When the answer is complete, emit TASK_DONE on a standalone final line and put no prose after it.\n'
    else
      printf '\nTreat this as repository-backed work. Investigate the assigned repository and complete the requested change or analysis there. Create a branch and PR when repository files change; a genuinely read-only answer may finish without a PR.\n'
      printf 'If the repository or other material input is missing, inspect the full task tree and repository context first, then emit TASK_NEEDS_USER_BEGIN/END with a concise summary of what you checked and the exact information needed. Manul will save this as an open subtask under the root task. Do not guess a repository or switch execution modes.\n'
      printf 'After verified delivery, Manul will mark the root task and its subtasks done. Do not change Todo task completion state yourself.\n'
    fi
  }
}
todo_task_to_source_json() {
  local task_json="$1" source_type="$2" resolution_json="${3-}"
  local repository execution_kind task_id fingerprint source_id source_url title body prompt ids created updated matched_alias project_skill_context resolution_method action
  [ -n "$resolution_json" ] || resolution_json='{}'
  repository="$(jq -r '.repository // empty' <<<"$resolution_json")"
  execution_kind="$(jq -r '.executionKind // "repository"' <<<"$resolution_json")"
  if [ "$execution_kind" = "repository" ] && [ -z "$repository" ]; then
    echo "Todo implementation task cannot be queued without an allowlisted repository" >&2
    return 1
  fi
  if [ "$execution_kind" = "answer" ] && [ -n "$repository" ]; then
    echo "Todo answer tasks must not be assigned a repository" >&2
    return 1
  fi
  case "$execution_kind" in repository|answer) ;; *) return 2 ;; esac
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
  prompt="$(todo_task_prompt "$task_json" "$source_id" "$execution_kind")"
  action="IMPLEMENT"
  local trigger_action
  trigger_action="$(jq -r '
    def nodes: ., (.subTasks[]? | nodes);
    [nodes | (.description // "") | split("\\n")[]
      | select(test("^[[:space:]]*/manul[[:space:]]+team([[:space:]]|$)"; "i"))][0] // ""
  ' <<<"$task_json" | awk '{print tolower($2)}')"
  if [ "$trigger_action" = "team" ]; then action="TEAM"; fi
  if [ "$execution_kind" = "answer" ]; then
    action="ANSWER"
  else
    resolution_method="$(jq -r '.method // "unknown"' <<<"$resolution_json")"
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
    --arg action "$action" \
    --arg created "$created" \
    --arg updated "$updated" \
    --arg repository "$repository" \
    --arg executionKind "$execution_kind" \
    --argjson resolution "$resolution_json" \
    --argjson taskId "$task_id" \
    --argjson stepIds "$ids" \
    '{
      taskSourceType:$type,
      taskSourceId:$sourceId,
      taskSourceUrl:$sourceUrl,
      title:$title,
      body:$body,
      prompt:$prompt,
      action:$action,
      createdAt:$created,
      updatedAt:$updated,
      state:"OPEN",
      metadata:({
        issueNumber:0,
        todoTaskId:$taskId,
        stepIds:$stepIds
      } + (if $repository != "" then {repository:$repository,repositoryResolution:$resolution} else {repositoryResolution:$resolution} end)),
      execution:{kind:$executionKind}
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


# Persist a status update as a verified OPEN child under the Todo root.
# The generated child is source-version-bound and idempotent across retries.
todo_task_publish_update() {
  local source_json="$1" source_type="$2" source_id="$3" status="$4" summary="$5"
  local task_id expected_version tasks_json root_json manul_user_id marker_prefix
  local existing_json existing_count result_json result_id result_description body digest arguments actual_version
  task_id="$(todo_task_id_from_source_id "$source_id")"
  expected_version="$(todo_task_version_from_source_id "$source_id")" || return 1
  [[ "$task_id" =~ ^[0-9]+$ ]] || return 1
  case "$status" in needs_input|failed|answered) ;; *) echo "Unsupported Todo update status: $status" >&2; return 2 ;; esac

  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  case "$source_type" in
    todo_local_mcp)
      todo_task_has_local_trigger "$root_json" || return 1 ;;
    todo_remote_mcp)
      manul_user_id="$(jq -r '.manulUserId // empty' <<<"$source_json")"
      todo_task_has_remote_share "$root_json" "$manul_user_id" || return 1
      todo_task_has_remote_trigger "$root_json" || return 1 ;;
    *) return 2 ;;
  esac
  todo_task_is_active "$root_json" || return 1
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo source changed before its status update could be saved" >&2
    return 1
  }

  marker_prefix="<!-- MANUL_TASK_UPDATE:v1;root=${task_id};source=${source_id};status=${status};"
  existing_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  existing_count="$(jq -r 'length' <<<"$existing_json")"
  if [ "$existing_count" -gt 1 ]; then
    echo "Multiple matching Manul status subtasks exist for this Todo source version" >&2
    return 1
  fi

  if [ "$existing_count" -eq 1 ]; then
    result_json="$(jq -c '.[0]' <<<"$existing_json")"
    result_id="$(jq -r '.id // empty' <<<"$result_json")"
    result_description="$(jq -r '.description // empty' <<<"$result_json")"
    [ "$(jq -r '.parentTaskId' <<<"$result_json")" = "$task_id" ] || return 1
    if [ "$status" != "answered" ] && [ "$(jq -r '.isToDo // true' <<<"$result_json")" != "true" ]; then
      echo "Generated Todo status subtask is no longer open" >&2
      return 1
    fi
  else
    local heading
    if [ "$status" = "needs_input" ]; then
      heading="Wymagane informacje do kontynuacji"
    elif [ "$status" = "answered" ]; then
      heading="Odpowiedź"
    else
      heading="Wykonanie zadania nie powiodło się"
    fi
    body="$(printf '%s\n\n%s' "$heading" "$summary" | todo_task_markdown_format)" || return 1
    digest="$(printf '%s' "$body" | sha256sum | awk '{print $1}')"
    result_description="${body}"$'\n'"${marker_prefix}sha256=${digest} -->"
    case "$source_type" in
      todo_local_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}')"
        todo_mcp_source_call "$source_json" "$source_type" create_task "$arguments" >/dev/null || return $? ;;
      todo_remote_mcp)
        arguments="$(jq -cn --arg description "$result_description" --argjson parentTaskId "$task_id" '{task:{description:$description,parentTaskId:$parentTaskId,highestPriorityAsDefault:false}}')"
        todo_mcp_source_call "$source_json" "$source_type" todo_create_task "$arguments" >/dev/null || return $? ;;
    esac
  fi

  # Verify the exact task text, parent link and OPEN state from a fresh provider read.
  tasks_json="$(todo_mcp_source_list_tasks "$source_json" "$source_type")" || return $?
  root_json="$(todo_task_find_root "$tasks_json" "$task_id")" || return 1
  result_json="$(jq -c --arg prefix "$marker_prefix" --argjson rootId "$task_id" '
    [.subTasks[]? | select(.parentTaskId == $rootId) | select((.description // "") | contains($prefix))]
  ' <<<"$root_json")" || return 1
  [ "$(jq -r 'length' <<<"$result_json")" -eq 1 ] || {
    echo "Todo status update was not readable after creation" >&2
    return 1
  }
  result_json="$(jq -c '.[0]' <<<"$result_json")"
  result_id="$(jq -r '.id // empty' <<<"$result_json")"
  result_description="$(jq -r '.description // empty' <<<"$result_json")"
  [[ "$result_id" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$(jq -r '.parentTaskId' <<<"$result_json")" = "$task_id" ] || return 1
  if [ "$status" != "answered" ] && [ "$(jq -r '.isToDo // true' <<<"$result_json")" != "true" ]; then
    return 1
  fi
  actual_version="$(todo_task_fingerprint "$root_json")" || return 1
  [ "$actual_version" = "$expected_version" ] || {
    echo "Todo status update changed the original source identity" >&2
    return 1
  }
  jq -cn --arg sourceId "$source_id" --arg status "$status" --argjson rootTaskId "$task_id" --argjson updateTaskId "$result_id" --arg summary "$summary" \
    '{sourceId:$sourceId,status:$status,rootTaskId:$rootTaskId,updateTaskId:$updateTaskId,summary:$summary}'
}

