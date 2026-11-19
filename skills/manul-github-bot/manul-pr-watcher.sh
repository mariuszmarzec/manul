#!/usr/bin/env bash
# manul-pr-watcher.sh — proactive PR feedback discovery.
#
# Sourced by poll.sh. GitHub remains the source of truth; SQLite is used only
# for durable PR conversation mapping and idempotent event/task correlation.

pr_watcher_enabled() {
  [ "$(jq -r '.proactivity.fixAndAnswerComments.enabled // false' "$CONFIG" 2>/dev/null || echo false)" = "true" ]
}

pr_watcher_scope() {
  local scope
  scope="$(jq -r '.proactivity.fixAndAnswerComments.prScope // "OnlyManulPr"' "$CONFIG" 2>/dev/null || echo OnlyManulPr)"
  case "$scope" in
    OnlyManulPr|AllUserAuthoredPr) printf '%s' "$scope" ;;
    *)
      log "WARN: invalid proactivity.fixAndAnswerComments.prScope '$scope'; defaulting to OnlyManulPr"
      printf '%s' "OnlyManulPr"
      ;;
  esac
}

pr_watcher_ci_scope() {
  local scope
  scope="$(jq -r '.ciFix.prScope // "OnlyManulPr"' "$CONFIG" 2>/dev/null || echo OnlyManulPr)"
  case "$scope" in
    OnlyManulPr|AllUserAuthoredPr) printf '%s' "$scope" ;;
    *)
      log "WARN: invalid ciFix.prScope '$scope'; defaulting to OnlyManulPr"
      printf '%s' "OnlyManulPr"
      ;;
  esac
}

# Empty/missing prAuthorAllowed inherits the already-resolved allowedUsers
# list. This deliberately reuses poll.sh's per-repository owner fallback when
# allowedUsers contains only an unresolved template placeholder.
pr_watcher_author_allowlist_json() {
  local configured configured_count sanitized sanitized_count
  configured="$(jq -c '.proactivity.prAuthorAllowed // [] | if type == "array" then . else [] end' "$CONFIG" 2>/dev/null || echo '[]')"
  configured_count="$(jq -r 'length' <<<"$configured" 2>/dev/null || echo 0)"
  if [ "${configured_count:-0}" -eq 0 ]; then
    configured="${ALLOWED_JSON:-[]}"
  fi
  sanitized="$(jq -c '
    [.[]?
      | select(type == "string")
      | gsub("^\\s+|\\s+$"; "")
      | select(length > 0)
      | select(test("[<>]") | not)
    ] | unique
  ' <<<"$configured" 2>/dev/null || echo '[]')"
  sanitized_count="$(jq -r 'length' <<<"$sanitized" 2>/dev/null || echo 0)"
  # An array containing only unresolved placeholders is effectively empty too.
  if [ "${sanitized_count:-0}" -eq 0 ] && [ "${configured_count:-0}" -gt 0 ]; then
    sanitized="$(jq -c '
      [.[]?
        | select(type == "string")
        | gsub("^\\s+|\\s+$"; "")
        | select(length > 0)
        | select(test("[<>]") | not)
      ] | unique
    ' <<<"${ALLOWED_JSON:-[]}" 2>/dev/null || echo '[]')"
  fi
  printf '%s' "$sanitized"
}

# pr_watcher_pr_in_scope <repo> <number> <url> <author> <scope>
pr_watcher_pr_in_scope() {
  local repo="$1" pr_number="$2" pr_url="$3" pr_author="$4" scope="$5"
  case "$scope" in
    OnlyManulPr)
      is_manul_owned_pr "$repo" "$pr_number" "$pr_url"
      ;;
    AllUserAuthoredPr)
      [ -n "$pr_author" ] || return 1
      local allowed
      allowed="$(pr_watcher_author_allowlist_json)"
      jq -en --arg author "$pr_author" --argjson allowed "$allowed" '$allowed | index($author) != null' >/dev/null 2>&1
      ;;
    *)
      log "WARN: refusing unknown PR scope '$scope' for $repo#$pr_number"
      return 1
      ;;
  esac
}

pr_watcher_ensure_pr_conversation() {
  local repo="$1" pr_number="$2" pr_url="$3"
  local now conv_id safe_repo safe_url existing_conv
  [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
  [ -n "$pr_url" ] || return 1
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  safe_repo="$(sql_escape "$repo")"
  safe_url="$(sql_escape "$pr_url")"

  # Prefer the source task's established conversation (including completed
  # tasks); CI/review work must continue in that history rather than creating
  # a disconnected PR conversation.
  existing_conv="$(sqlite3 "$DB" "
    SELECT conversationId
    FROM processed_comments
    WHERE repository='$safe_repo'
      AND prNumber=$pr_number
      AND status!='failed'
      AND action!='REVIEW'
      AND conversationId IS NOT NULL
      AND conversationId!=''
    ORDER BY createdAt DESC
    LIMIT 1;
  " 2>>"$LOG" || true)"
  if [ -z "$existing_conv" ]; then
    existing_conv="$(sqlite3 "$DB" "
      SELECT conversationId
      FROM conversations
      WHERE repository='$safe_repo'
        AND activePrNumber=$pr_number
      ORDER BY updatedAt DESC
      LIMIT 1;
    " 2>>"$LOG" || true)"
  fi
  conv_id="${existing_conv:-$(generate_conversation_id "$repo" "$pr_number" "pr-top-level")}"
  [ -n "$conv_id" ] || return 1

  # A PR must remain discoverable even if it has no source task or its source
  # task/conversation was already completed. Existing task rows remain intact.
  sqlite3 "$DB" "
    INSERT OR IGNORE INTO conversations(
      conversationId, repository, issueNumber, issueUrl, activePrNumber,
      activePrUrl, status, createdAt, updatedAt
    ) VALUES(
      '$(sql_escape "$conv_id")', '$safe_repo', $pr_number, '$safe_url',
      $pr_number, '$safe_url', 'OPEN', '$now', '$now'
    );
    UPDATE conversations
    SET issueUrl='$safe_url',
        activePrNumber=$pr_number,
        activePrUrl='$safe_url',
        status='OPEN',
        updatedAt='$now'
    WHERE conversationId='$(sql_escape "$conv_id")';
  " 2>>"$LOG"
}

# Event identity checks bridge the existing explicit /manul comment keys with
# proactive keys. The review handler writes review:<event-id> transactionally.
pr_watcher_comment_was_handled() {
  local raw_id="$1"
  [[ "$raw_id" =~ ^[0-9]+$ ]] || return 1
  local found
  # Conversation history is not proof that an event was handled: the poller
  # stores comments there even when a previous delivery attempt failed.
  found="$(sqlite3 "$DB" "
    SELECT 1 FROM processed_comments
    WHERE commentId IN ('issue:$raw_id', 'review:$raw_id')
    UNION ALL
    SELECT 1 FROM processed_comments
    WHERE commentId IN (
      'review:proactive-comment-$raw_id',
      'review:proactive-inline-$raw_id'
    )
      AND status IN ('task_created', 'completed')
    LIMIT 1;
  " 2>/dev/null || true)"
  [ "$found" = "1" ]
}

pr_watcher_submit_feedback() {
  local repo="$1" pr_number="$2" review_id="$3" body="$4" author="$5" created="$6" inline_json="${7:-}"
  local args=(
    handle
    --repo "$repo"
    --pr-number "$pr_number"
    --review-id "$review_id"
    --review-state COMMENT
    --body "$body"
    --author "$author"
    --created "$created"
    --proactive-feedback
    --json
  )
  if [ -n "$inline_json" ]; then
    args+=(--review-comments-json "$inline_json")
  fi

  if bash "$MANUL_DIR/manul-pr-review.sh" "${args[@]}" >>"$LOG" 2>&1; then
    log "proactive PR feedback accepted: $repo#$pr_number event=$review_id author=$author"
    return 0
  fi
  log "WARN: proactive PR feedback handler failed: $repo#$pr_number event=$review_id"
  return 1
}


# Use a watcher-specific one-time baseline so enabling the feature does not
# backfill every historical comment/review since the original Manul install.
pr_watcher_ensure_baseline() {
  local current baseline
  current="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! sqlite3 "$DB" "
    INSERT OR IGNORE INTO meta(key, value) VALUES('pr_watcher_baseline', '$current');
  " 2>>"$LOG"; then
    log "WARN: could not initialize proactive PR watcher baseline"
    return 1
  fi
  baseline="$(sqlite3 "$DB" "SELECT value FROM meta WHERE key='pr_watcher_baseline' LIMIT 1;" 2>>"$LOG" || true)"
  [ -n "$baseline" ] || {
    log "WARN: proactive PR watcher baseline is empty; refusing historical backfill"
    return 1
  }
  printf '%s' "$baseline"
}

# scan_proactive_pr_comments <repo>
# Scans new PR discussion comments and standalone inline comments. Submitted
# reviews (and their inline comments) are grouped by the existing review
# handler in poll.sh, avoiding one task per comment in a multi-comment review.
scan_proactive_pr_comments() {
  local repo="$1"
  pr_watcher_enabled || return 0

  local scope prs_json issue_comments_json inline_comments_json watcher_baseline
  scope="$(pr_watcher_scope)"
  watcher_baseline="$(pr_watcher_ensure_baseline)" || return 0
  prs_json="$(gh pr list --repo "$repo" --state open --limit 100 --json number,author,url,title 2>>"$LOG" | jq -c '[.[] | {number: .number, author: (.author.login // ""), url: .url, title: (.title // "")}]' 2>>"$LOG" || echo '[]')"
  [ -n "$prs_json" ] || prs_json='[]'
  issue_comments_json="$(gh api --paginate "repos/$repo/issues/comments?per_page=100" 2>>"$LOG" || echo '[]')"
  inline_comments_json="${review_comments:-}"
  if [ -z "$inline_comments_json" ]; then
    inline_comments_json="$(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" || echo '[]')"
  fi

  local pr_count i pr pr_number pr_url pr_author
  pr_count="$(jq -r 'length' <<<"$prs_json" 2>/dev/null || echo 0)"
  [[ "$pr_count" =~ ^[0-9]+$ ]] || return 0

  i=0
  while [ "$i" -lt "$pr_count" ]; do
    pr="$(jq -c ".[$i]" <<<"$prs_json")"
    pr_number="$(jq -r '.number' <<<"$pr")"
    pr_url="$(jq -r '.url // empty' <<<"$pr")"
    pr_author="$(jq -r '.author // empty' <<<"$pr")"

    if ! pr_watcher_pr_in_scope "$repo" "$pr_number" "$pr_url" "$pr_author" "$scope"; then
      i=$((i + 1))
      continue
    fi
    if ! pr_watcher_ensure_pr_conversation "$repo" "$pr_number" "$pr_url"; then
      log "WARN: could not ensure PR conversation for proactive watcher $repo#$pr_number"
      i=$((i + 1))
      continue
    fi

    # PR Conversation comments, including subsequent replies. Ignore bot
    # feedback and our own signed result comments to prevent self-triggering.
    while IFS= read -r comment; do
      [ -n "$comment" ] || continue
      local comment_id comment_body comment_author comment_created comment_url
      comment_id="$(jq -r '.id // empty' <<<"$comment")"
      comment_body="$(jq -r '.body // empty' <<<"$comment")"
      comment_author="$(jq -r '.user.login // "unknown"' <<<"$comment")"
      comment_created="$(jq -r '.created_at // empty' <<<"$comment")"
      comment_url="$(jq -r '.html_url // empty' <<<"$comment")"
      [ -n "$comment_id" ] && [ -n "$comment_body" ] || continue
      pr_watcher_comment_was_handled "$comment_id" && continue
      local task_body
      task_body="Proactive PR conversation feedback from @$comment_author. Original comment: $comment_url

$comment_body"
      pr_watcher_submit_feedback "$repo" "$pr_number" "proactive-comment-$comment_id" "$task_body" "$comment_author" "$comment_created" || true
    done < <(
      jq -c --arg pr "$pr_number" --arg baseline "$BASELINE" --arg sig "$SIG" '
        .[]
        | select((.html_url // "") | test("/pull/" + $pr + "($|[#?])"))
        | select((.created_at // "") >= $baseline)
        | select((.user.type // "User") != "Bot")
        | select((.body // "") | contains($sig) | not)
      ' <<<"$issue_comments_json" 2>/dev/null
    )

    # Inline comments not attached to a submitted review are independent
    # feedback events. Replies map back to the true root thread before the
    # review handler asks the agent to answer that thread.
    while IFS= read -r comment; do
      [ -n "$comment" ] || continue
      local comment_id comment_body comment_author comment_created comment_url root_id inline_json
      comment_id="$(jq -r '.id // empty' <<<"$comment")"
      comment_body="$(jq -r '.body // empty' <<<"$comment")"
      comment_author="$(jq -r '.user.login // "unknown"' <<<"$comment")"
      comment_created="$(jq -r '.created_at // empty' <<<"$comment")"
      comment_url="$(jq -r '.html_url // empty' <<<"$comment")"
      [ -n "$comment_id" ] && [ -n "$comment_body" ] || continue
      pr_watcher_comment_was_handled "$comment_id" && continue
      root_id="$(get_review_thread_root_id "$inline_comments_json" "$comment_id")"
      if [ "$root_id" != "$comment_id" ]; then
        # Review replies are new feedback on an existing thread. Pass the
        # thread root to the review handler (it intentionally filters replies
        # as standalone comments) and append the new reply for assessment.
        local root_comment
        root_comment="$(jq -c --arg root "$root_id" '.[] | select((.id | tostring) == $root)' <<<"$inline_comments_json" 2>/dev/null | head -n1)"
        [ -n "$root_comment" ] || continue
        inline_json="$(jq -cn --argjson comment "$root_comment" --arg root "$root_id" --arg reply "$comment_body" --arg reply_id "$comment_id" '$comment + {body: (($comment.body // "") + "\n\nNew reply (" + $reply_id + "): " + $reply), manul_thread_root_id:$root} | [.]')"
      else
        inline_json="$(jq -cn --argjson comment "$comment" --arg root "$root_id" '[($comment + {manul_thread_root_id:$root})]')"
      fi
      local task_body
      task_body="Proactive PR inline feedback from @$comment_author. Original comment: $comment_url

$comment_body"
      pr_watcher_submit_feedback "$repo" "$pr_number" "proactive-inline-$comment_id" "$task_body" "$comment_author" "$comment_created" "$inline_json" || true
    done < <(
      jq -c --arg pr "$pr_number" --arg baseline "$BASELINE" --arg sig "$SIG" '
        .[]
        | select((.html_url // "") | test("/pull/" + $pr + "($|[#?])"))
        | select((.created_at // "") >= $baseline)
        | select((.pull_request_review_id // null) == null or (.in_reply_to_id // null) != null)
        | select((.user.type // "User") != "Bot")
        | select((.body // "") | contains($sig) | not)
      ' <<<"$inline_comments_json" 2>/dev/null
    )
    i=$((i + 1))
  done
}
