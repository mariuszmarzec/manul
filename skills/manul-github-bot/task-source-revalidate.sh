#!/usr/bin/env bash
# task-source-revalidate.sh — Safe, side-effect-free GitHub source revalidation.
#
# Extracted from manul-daemon.sh so the manual recovery CLI (task-recovery.sh)
# can revalidate a stale task's source WITHOUT sourcing the full daemon — whose
# trailing CLI dispatcher would `exit 2` under normal invocation when
# MANUL_TESTING is unset.
#
# This module:
#   * defines only pure functions (no loops, no daemon state mutation);
#   * never calls `exit` and never sources the daemon;
#   * is safe to source from any Manul component.
#
# Both manul-daemon.sh and task-recovery.sh source the SAME module, so the
# revalidation logic is defined exactly once.
#
# Depends on `gh`, `jq`, `timeout` being on PATH. It uses `log()`, `lc_log()`
# and `GH_API_TIMEOUT`; the consumer normally provides richer versions. Safe
# fallbacks are defined below ONLY when the consumer has not defined them, so a
# consumer's own definitions always win.

GH_API_TIMEOUT="${GH_API_TIMEOUT:-30}"   # seconds timeout for gh api calls

if ! declare -f log >/dev/null 2>&1; then
  log() { echo "[$(date -Is)] $*" >&2; }
fi
if ! declare -f lc_log >/dev/null 2>&1; then
  lc_log() {
    local event="$1"
    shift
    echo "[$(date -Is)] $event ${*:-}" >&2
  }
fi

# ── Source revalidation ────────────────────────────────────────────────────────
# Pre-flight check before dispatching a claimed task.  Ensures the GitHub source
# (issue, PR, or review thread) still exists and is in an active state.
# Returns: 0=fresh (proceed), 1=stale (terminal), 2=transient (requeue).

# Detect the source kind from a comment_id prefix.
# Prefixes are authoritative:
#   issue:     -> issue comment
#   issuebody: -> issue/PR state
#   ci_fix:    -> PR state
#   review:    -> PR review thread/comment
detect_source_kind() {
  local comment_id="$1"
  case "$comment_id" in
    review:*)    echo "pr_review_comment" ;;
    issuebody:*) echo "issue_state" ;;
    ci_fix:*)    echo "pr_state" ;;
    issue:*)     echo "issue_comment" ;;
    *)           echo "issue_comment" ;;
  esac
}

# Revalidate a single source. Returns:
#   0 = fresh
#   1 = stale (terminal)
#   2 = transient (requeue)
# The issue/PR number is passed separately because review:<id> contains only
# the review comment database ID.
revalidate_source() {
  local comment_id="$1"
  local repo="$2"
  local issue_num="${3:-}"
  local source_url="${4:-}"
  local kind
  kind="$(detect_source_kind "$comment_id")"
  case "$kind" in
    issue_comment)      revalidate_issue_comment "$comment_id" "$repo" "$source_url" ;;
    issue_state)        revalidate_issue_state "$comment_id" "$repo" "$source_url" ;;
    pr_state)           revalidate_pr_state "$comment_id" "$repo" ;;
    pr_review_comment)  revalidate_pr_review_comment "$comment_id" "$repo" "$issue_num" ;;
    *)                  return 2 ;;
  esac
}

# ── issue_comment ─────────────────────────────────────────────────────────────
# Matched by prefix issue:<id>. Verifies the comment still exists on GitHub.
revalidate_issue_comment() {
  local comment_id="$1" repo="$2" source_url="${3:-}"
  local num="${comment_id#issue:}"
  local owner name
  IFS='/' read -r owner name _ <<<"$repo"

  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/issues/comments/$num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: issue comment $num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_comment reason=not_found"
      return 1
    fi
    log "revalidate_source: issue comment API error for $comment_id (rc=$rc)"
    return 2
  fi

  local returned_id
  returned_id="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
  if [ -n "$returned_id" ]; then
    if [[ "$source_url" =~ /pull/([0-9]+)([/#?]|$) ]]; then
      local source_pr_num="${BASH_REMATCH[1]}"
      revalidate_pr_target "$comment_id" "$repo" "$source_pr_num" "issue_comment"
      return $?
    fi
    log "revalidate_source: issue comment $num still exists on $repo — fresh"
    return 0
  fi
  log "revalidate_source: issue comment $num returned no id — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_comment reason=missing_id"
  return 1
}

# ── issue_state ───────────────────────────────────────────────────────────────
revalidate_issue_state() {
  local comment_id="$1" repo="$2" source_url="${3:-}"
  local num="${comment_id#issuebody:}"

  # issuebody task IDs are GitHub API object IDs, while /issues/<N> expects
  # the human-facing issue number. The stored issue URL is authoritative for
  # legacy queue rows created with the wrong numeric identifier.
  if [[ "$source_url" =~ /issues/([0-9]+)(/|#|$) ]]; then
    local source_num="${BASH_REMATCH[1]}"
    if [ "$source_num" != "$num" ]; then
      log "revalidate_source: correcting issuebody source id $num to issue number $source_num from $source_url"
      num="$source_num"
    fi
  fi

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"

  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/issues/$num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then return 2; fi
    if printf '%s' "$resp" | jq -e -r '.message == "Not Found"' >/dev/null 2>&1; then
      log "revalidate_source: issue $num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_state reason=not_found"
      return 1
    fi
    log "revalidate_source: issue state API error for $comment_id (rc=$rc)"
    return 2
  fi
  local state
  state="$(printf '%s' "$resp" | jq -r '.state // empty' 2>/dev/null || true)"
  if [ "$state" = "open" ]; then
    log "revalidate_source: issue $num is still open on $repo — fresh"
    return 0
  fi
  log "revalidate_source: issue $num is ${state:-unknown} on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=issue_state reason=closed state=${state:-unknown}"
  return 1
}

revalidate_pr_target() {
  local comment_id="$1" repo="$2" pr_num="$3" source_kind="${4:-pr_state}"
  [[ "$pr_num" =~ ^[0-9]+$ ]] || return 2

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"
  local resp rc
  resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$owner/$name/pulls/$pr_num" 2>/dev/null)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      log "revalidate_source: PR $pr_num lookup timed out for $repo"
      return 2
    fi
    if printf '%s' "$resp" | jq -e '(.message // "" | strings | ascii_downcase | contains("not found"))' >/dev/null 2>&1; then
      log "revalidate_source: PR $pr_num not found on $repo — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=pr_not_found"
      return 1
    fi
    log "revalidate_source: PR state API error for $comment_id (rc=$rc)"
    return 2
  fi

  local state merged head_ref head_repo
  state="$(printf '%s' "$resp" | jq -r '.state // empty' 2>/dev/null || true)"
  merged="$(printf '%s' "$resp" | jq -r '.merged // false' 2>/dev/null || echo false)"
  if [ -z "$state" ]; then
    log "revalidate_source: PR $pr_num response omitted state for $repo; treating as transient"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=missing_pr_state"
    return 2
  fi
  if [ "$state" != "open" ] || [ "$merged" = "true" ]; then
    local reason="pr_${state:-unknown}"
    [ "$merged" = "true" ] && reason="pr_merged"
    log "revalidate_source: PR $pr_num is ${state:-unknown} on $repo — stale"
    lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=$reason"
    return 1
  fi

  head_ref="$(printf '%s' "$resp" | jq -r '.head.ref // empty' 2>/dev/null || true)"
  head_repo="$(printf '%s' "$resp" | jq -r '.head.repo.full_name // empty' 2>/dev/null || true)"
  if [ -z "$head_ref" ]; then
    log "revalidate_source: open PR $pr_num omitted head.ref for $repo; treating as transient"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=missing_head_ref"
    return 2
  fi
  if [ -z "$head_repo" ]; then
    log "revalidate_source: open PR $pr_num has no accessible head repository on $repo — stale"
    lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=head_repo_missing"
    return 1
  fi
  if [[ ! "$head_repo" =~ ^[^/]+/[^/]+$ ]]; then
    log "revalidate_source: invalid head repository metadata for PR $pr_num on $repo"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=invalid_head_repo"
    return 2
  fi

  local encoded_head_ref branch_resp branch_rc
  encoded_head_ref="$(printf '%s' "$head_ref" | jq -sRr '@uri' 2>/dev/null)" || return 2
  branch_resp="$(timeout "$GH_API_TIMEOUT" gh api "repos/$head_repo/branches/$encoded_head_ref" 2>/dev/null)" && branch_rc=0 || branch_rc=$?
  if [ "$branch_rc" -ne 0 ]; then
    if [ "$branch_rc" -eq 124 ]; then
      log "revalidate_source: head branch lookup timed out for PR $pr_num ($head_repo/$head_ref)"
      return 2
    fi
    if printf '%s' "$branch_resp" | jq -e '(.message // "" | strings | ascii_downcase | contains("not found"))' >/dev/null 2>&1; then
      log "revalidate_source: head branch $head_repo/$head_ref missing for PR $pr_num — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=$source_kind reason=head_branch_missing"
      return 1
    fi
    log "revalidate_source: head branch API error for PR $pr_num ($head_repo/$head_ref, rc=$branch_rc)"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=head_branch_api_error rc=$branch_rc"
    return 2
  fi

  local returned_branch
  returned_branch="$(printf '%s' "$branch_resp" | jq -r '.name // empty' 2>/dev/null || true)"
  if [ "$returned_branch" != "$head_ref" ]; then
    log "revalidate_source: head branch response did not match PR $pr_num ($head_repo/$head_ref) — treating as transient"
    lc_log "SOURCE_REVALIDATION_ERROR" "task=$comment_id repo=$repo kind=$source_kind reason=head_branch_mismatch"
    return 2
  fi

  log "revalidate_source: PR $pr_num and head branch $head_repo/$head_ref are open and available on $repo — fresh"
  return 0
}

# ── pr_state ──────────────────────────────────────────────────────────────────
# Matched by prefix ci_fix:<repo>:<pr_num>:<run_id>. OPEN only.
revalidate_pr_state() {
  local comment_id="$1" repo="$2"
  local pr_num
  case "$comment_id" in
    ci_fix:*) pr_num="$(printf '%s' "$comment_id" | awk -F: '{print $3}')" ;;
    *) return 2 ;;
  esac
  revalidate_pr_target "$comment_id" "$repo" "$pr_num" "pr_state"
}

# ── pr_review_comment ─────────────────────────────────────────────────────────
# review:<id> uses issueNumber as the PR number. Verifies PR OPEN, thread
# unresolved, and paginates reviewThreads until found/exhausted.
revalidate_pr_review_comment() {
  local comment_id="$1" repo="$2" pr_num="$3"
  local tid="${comment_id#review:}"
  [[ "$tid" =~ ^[0-9]+$ ]] || return 2
  [[ "$pr_num" =~ ^[0-9]+$ ]] || return 2

  local target_rc=0
  revalidate_pr_target "$comment_id" "$repo" "$pr_num" "pr_review_comment" || target_rc=$?
  [ "$target_rc" -eq 0 ] || return "$target_rc"

  local owner name
  IFS='/' read -r owner name _ <<<"$repo"
  local tmp_cursor="" has_more=true
  local q_base='query($o:String!,$n:String!,$num:Int!,$c:String){repository(owner:$o,name:$n){pullRequest(number:$num){state reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor}nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'
  local q_no_cursor='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){pullRequest(number:$num){state reviewThreads(first:100){pageInfo{hasNextPage endCursor}nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}'

  while $has_more; do
    local resp rc
    if [ -n "$tmp_cursor" ]; then
      resp="$(timeout "$GH_API_TIMEOUT" gh api graphql --field query="$q_base" --field o="$owner" --field n="$name" --field num="$pr_num" --field c="$tmp_cursor" 2>/dev/null)" && rc=0 || rc=$?
    else
      resp="$(timeout "$GH_API_TIMEOUT" gh api graphql --field query="$q_no_cursor" --field o="$owner" --field n="$name" --field num="$pr_num" 2>/dev/null)" && rc=0 || rc=$?
    fi
    if [ "$rc" -eq 124 ]; then
      log "revalidate_source: review GraphQL timeout for $comment_id"
      return 2
    fi
    if [ "$rc" -ne 0 ]; then
      log "revalidate_source: review GraphQL error for $comment_id (rc=$rc)"
      return 2
    fi

    local pr_null
    pr_null="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest == null' 2>/dev/null || true)"
    if [ "$pr_null" = "true" ]; then
      log "revalidate_source: PR $pr_num not found for review $comment_id — stale"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=pr_not_found"
      return 1
    fi

    local pr_state
    pr_state="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.state // empty' 2>/dev/null || true)"
    if [ "$pr_state" != "OPEN" ]; then
      log "revalidate_source: PR $pr_num is ${pr_state:-unknown} on $repo — stale for review task"
      lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=pr_${pr_state:-unknown}"
      return 1
    fi

    local thread_info
    thread_info="$(printf '%s' "$resp" | jq -r --argjson tid "$tid" '.data.repository.pullRequest.reviewThreads.nodes[]? | select((.comments.nodes // []) | map(.databaseId) | index($tid) != null) | "\(.isResolved)"' 2>/dev/null || true)"
    if [ -n "$thread_info" ]; then
      if [ "$(printf '%s' "$thread_info" | head -1)" = "true" ]; then
        log "revalidate_source: review thread $tid is resolved on $repo — stale"
        lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=resolved"
        return 1
      fi
      log "revalidate_source: review thread $tid is unresolved on $repo — fresh"
      return 0
    fi

    local has_next next_cursor
    has_next="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' 2>/dev/null || echo false)"
    next_cursor="$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // empty' 2>/dev/null || true)"
    if [ "$has_next" != "true" ] || [ -z "$next_cursor" ]; then
      has_more=false
    else
      tmp_cursor="$next_cursor"
    fi
  done

  log "revalidate_source: review thread $tid not found after pagination on $repo — stale"
  lc_log "SOURCE_STALE" "task=$comment_id repo=$repo kind=pr_review_comment reason=thread_not_found"
  return 1
}
