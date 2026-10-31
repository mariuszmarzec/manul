#!/usr/bin/env bash
# manul-poll.sh — GitHub /manul trigger poller for OpenClaw cron.
#
# Scans configured repos for issue comments + PR review comments containing the
# trigger command, queues unprocessed ones in SQLite
# and prints a single MANUL_RESULT line for the cron trigger wrapper.
#
# Usage: manul-poll.sh [repo...]   (repos override config for testing)
#
# State:
#   processed_comments(commentId PK, repository, issueNumber, commentUrl,
#                      author, prompt, status, createdAt, processedAt)
#     status: queued -> running -> done | failed
#   meta(baseline)   — BASELINE = manul install/config moment (UTC ISO).
#     Only issues/comments created AFTER baseline are considered, so manul
#     never picks up old posts after a (re)install on a new machine.
#     Set explicitly during install/repair. Polling fails closed when it is
#     missing, because the cutoff must never silently become "now" or a lookback.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
source "$SCRIPT_DIR/task-source.sh"
source "$SCRIPT_DIR/manul-env.sh"
manul_env_load "$MANUL_DIR" || fail "failed to load Manul environment"
CONFIG="$MANUL_CONFIG"
DB="${DB:-$MANUL_DB}"
LOCK="${MANUL_LOCKS_DIR}/poll.lock"
LOG="$MANUL_LOG_DIR/poll.log"
LOCK_TTL_SECONDS="${MANUL_LOCK_TTL_SECONDS:-1800}"
REPO_LOCK_DIR="$MANUL_LOCKS_DIR/repo"
REPO_LOCK_TTL="${MANUL_REPO_LOCK_TTL_SECONDS:-1800}"
# Per-repository timeout to prevent one slow repo from blocking all others
REPO_POLL_TIMEOUT="${MANUL_REPO_POLL_TIMEOUT:-60}"
# Poll overlap prevention: prevents multiple poll.sh instances from running simultaneously
POLL_LOCK_FILE="${MANUL_LOCKS_DIR}/poll.flock"
mkdir -p "$REPO_LOCK_DIR" 2>/dev/null || true

log() { echo "[$(date -Is)] $*" >>"$LOG"; }
fail() { echo "MANUL_RESULT {\"fire\":false,\"error\":\"$1\"}"; exit 0; }

# SQL escaping helpers
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_num() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s' "$val"
  else
    printf ''
  fi
}

# Per-repo lock: prevents two different tasks from working on the same local
# repo workdir at the same time. The lock is an atomic directory creation, so
# concurrent contenders cannot both acquire it. A short-lived reclaim mutex
# serializes stale-lock recovery.
acquire_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  local lockfile="${REPO_LOCK_DIR}/${slug}.lock"
  local reclaim_lock="${lockfile}.reclaim"

  mkdir -p "$REPO_LOCK_DIR"

  # Fast path: mkdir is atomic across processes.
  if mkdir "$lockfile" 2>/dev/null; then
    date +%s >"$lockfile/acquiredAt"
    printf '%s\n' "$$" >"$lockfile/pid"
    return 0
  fi

  local age
  age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
  if [ "$age" -lt "$REPO_LOCK_TTL" ]; then
    log "repo $repo is locked by another task (age=${age}s, ttl=${REPO_LOCK_TTL}s); skipping"
    return 1
  fi

  # Stale recovery must itself be serialized; otherwise two contenders could
  # both remove the stale lock and then both acquire a replacement lock.
  if [ -d "$reclaim_lock" ]; then
    local reclaim_age
    reclaim_age=$(( $(date +%s) - $(stat -c %Y "$reclaim_lock" 2>/dev/null || echo 0) ))
    if [ "$reclaim_age" -ge "$REPO_LOCK_TTL" ]; then
      rm -rf "$reclaim_lock"
    fi
  fi
  if ! mkdir "$reclaim_lock" 2>/dev/null; then
    log "repo $repo stale-lock recovery is already in progress; skipping"
    return 1
  fi

  local safe_repo
  safe_repo="$(sql_escape "$repo")"
  local running_count
  running_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE repository='$safe_repo' AND status='running';" 2>/dev/null || echo 0)"

  # Re-check the lock after taking the reclaim mutex.
  age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
  if [ -e "$lockfile" ] && [ "$age" -ge "$REPO_LOCK_TTL" ] && [ "${running_count:-0}" -eq 0 ]; then
    log "stale repo lock for $repo removed (age=${age}s, no running tasks)"
    rm -rf "$lockfile"
  elif [ "${running_count:-0}" -gt 0 ]; then
    log "stale repo lock for $repo ignored because task is still running in DB (running=$running_count); skipping"
  fi

  rmdir "$reclaim_lock" 2>/dev/null || true

  # Retry exactly once after successful stale cleanup. The second acquisition
  # is still atomic, so only one contender can win.
  if [ ! -e "$lockfile" ]; then
    if mkdir "$lockfile" 2>/dev/null; then
      date +%s >"$lockfile/acquiredAt"
      printf '%s\n' "$$" >"$lockfile/pid"
      return 0
    fi
  fi

  return 1
}

release_repo_lock() {
  local repo="$1"
  local slug
  slug="$(printf '%s' "$repo" | sed 's/\//-/g')"
  rm -rf "${REPO_LOCK_DIR}/${slug}.lock"
}

[ -f "$CONFIG" ] || fail "no config at $CONFIG"
TRIGGER="$(jq -r '.trigger // "/manul"' "$CONFIG")"
[ -n "$TRIGGER" ] || TRIGGER="/manul"

# Bot signature: any comment ending with this is manul's OWN comment
# (feedback.sh signs every comment). Skip them so manul never re-triggers
# itself — e.g. a Done comment mentioning a path like docs/manul-… would
# otherwise match the trigger substring.
SIG="— manul 🐈"

# Known role agents (from config.json `.agents`, fallback = skill's role set).
# The parser sets `.agent` only when the first token after the trigger on the
# trigger line matches one of these (case-sensitive exact). Anything else stays
# in the prompt and the orchestrator decides (default coder).
mapfile -t AGENTS < <(jq -r '.agents[]?' "$CONFIG" 2>/dev/null)
if [ "${#AGENTS[@]}" -eq 0 ]; then
  AGENTS=(architect coder coder-cheap coder-strong coder-expert reviewer reviewer-expert reviewer-adversarial debugger debugger-expert researcher tester security performance refactorer)
fi
AGENTS_JSON="$(printf '%s\n' "${AGENTS[@]}" | jq -R . | jq -sc .)"

# Shared jq: extract (agent, prompt) from a comment/issue body.
# - find the first line containing the trigger,
# - everything after the trigger on that line = rest0 (leading spaces trimmed),
# - if rest0 is empty, the following lines become the prompt,
# - first token of the rest: known agent name => agent; the remainder = prompt.
PARSE='($trig | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) as $trig_re
| (.body | split("\n")) as $lines
| ([range(0; $lines|length) | select($lines[.] | test("^[ \\t]*" + $trig_re + "([ \\t]|$)"))][0]) as $idx
| ($lines[$idx] | sub("^[ \\t]*" + $trig_re + "([ \\t]*|$)"; "")) as $rest0_raw
| ($rest0_raw | test("(^|[ \\t])--auto([ \\t]|$)")) as $auto_accept
| ($rest0_raw | gsub("(^|[ \\t])--auto([ \\t]|$)"; " ") | sub("^[ \\t]+"; "") | sub("[ \\t]+$"; "")) as $rest0
| (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else ($rest0 + "\n" + ($lines[$idx+1:] | join("\n"))) end) as $rest
| ($rest | split(" ")[0]) as $tok
| (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
| (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt
| {agent: $agent, prompt: $prompt, autoAccept: $auto_accept}'

# Only these GitHub logins may invoke manul. Default: repo owner.
#
# IMPORTANT: `allowedUsers` is the only authoritative allow-list. The fallback
# to repo owners was a silent opt-out trap — if a deployer copied
# config.json.example verbatim (which still ships `"allowedUsers": ["<GITHUB_LOGIN>"]`),
# the literal string "<GITHUB_LOGIN>" never matched any real GitHub login, so
# EVERY comment was filtered out and no task ever reached SQLite. A placeholder
# must never be treated as a valid allow-list; when it is present we fall back to
# the documented default (repo owners) and warn, instead of silently dropping
# all traffic.
#
# GitHub logins may not contain '<' or '>', so any entry with those characters
# is treated as an unresolved placeholder and stripped before filtering.
#
# Resolution is deferred to process_repo_body() so the per-repo fallback can
# use the repo owner (which requires the repo name). Without that, a
# placeholder config would silently disable filtering for every repo.
ALLOWED_JSON="$(jq -c '.allowedUsers // ([.repositories[]? | split("/")[0]] | if length == 0 then [] else . end)' "$CONFIG" 2>/dev/null)"
if [ -z "$ALLOWED_JSON" ] || [ "$ALLOWED_JSON" = "null" ]; then
  ALLOWED_JSON='[]'
fi
CONFIG_ALLOWED_USERS="$ALLOWED_JSON"
resolve_allowed_users() {
  local repo="$1"
  if printf '%s' "$ALLOWED_JSON" | jq -e 'any(.[]; test("[<>]"))' >/dev/null 2>&1; then
    ALLOWED_JSON="$(printf '%s' "$ALLOWED_JSON" | jq -c '[.[] | select(test("[<>]") | not)]')"
    if [ "$(printf '%s' "$ALLOWED_JSON" | jq 'length')" -eq 0 ]; then
      ALLOWED_JSON="$(jq -nc --arg repo "$repo" '[$repo | split("/")[0]]')"
    fi
    log "WARN: config.json allowedUsers contained an unresolved placeholder (config: $CONFIG_ALLOWED_USERS); "
    log "WARN: falling back to repo owner allow-list: $ALLOWED_JSON"
  fi
}

# CI Fix config
CI_FIX_ENABLED="$(jq -r '.ciFix.enabled // false' "$CONFIG" 2>/dev/null)"
CI_FIX_MAX_ATTEMPTS="$(jq -r '.ciFix.maxAttemptsPerRun // 2' "$CONFIG" 2>/dev/null)"
CI_FIX_COOLDOWN_MINUTES="$(jq -r '.ciFix.cooldownMinutes // 60' "$CONFIG" 2>/dev/null)"

if [ "$CI_FIX_ENABLED" = "null" ]; then CI_FIX_ENABLED="false"; fi
if [ "$CI_FIX_MAX_ATTEMPTS" = "null" ]; then CI_FIX_MAX_ATTEMPTS="2"; fi
if [ "$CI_FIX_COOLDOWN_MINUTES" = "null" ]; then CI_FIX_COOLDOWN_MINUTES="60"; fi

# Generate conversation ID for task grouping
# Returns a deterministic conversation ID based on commentUrl (not just issue)
# This allows multiple independent conversations on the same issue/PR
# Generate the canonical conversation ID.
#
# Conversation identity is NOT a comment identity.
#
# Rules:
#   issue / issue-body / PR top-level conversation:
#       conv-<repo>-issue-<issue>
#
#   PR inline review thread:
#       conv-<repo>-review-<root-review-comment-id>
#
# IMPORTANT:
#   Never use commentUrl as conversation identity.
generate_conversation_id() {
  local repo="$1"
  local issue="$2"
  local kind="${3:-issue}"
  local thread_id="${4:-}"

  case "$kind" in
    review-thread)
      [ -n "$thread_id" ] || {
        log "ERROR: review-thread conversation requires thread_id"
        return 1
      }
      printf 'conv-%s-review-%s' "$repo" "$thread_id"
      ;;
    issue|pr-top-level)
      printf 'conv-%s-issue-%s' "$repo" "$issue"
      ;;
    *)
      log "ERROR: unknown conversation kind: $kind"
      return 1
      ;;
  esac
}

# Select only newly authored review threads from one submitted review.
# Replies remain persisted in conversation history but must not create new tasks.
filter_actionable_review_comments() {
  local comments_json="$1"
  local review_id="$2"

  printf '%s\n' "$comments_json" |
    jq -cs --arg rid "$review_id" '
      [.[][]
       | select((.pull_request_review_id // "") | tostring == $rid)
       | select((.in_reply_to_id // null) == null)
      ]'
}

# Return the root review-comment id for a PR review thread.
#
# GitHub inline review replies contain `in_reply_to_id`.
# A top-level review comment has no `in_reply_to_id` and is therefore its own
# thread root.
get_review_thread_root_id() {
  local comments_json="$1"
  local comment_id="$2"
  local current="$comment_id"
  local parent=""
  local guard=0
  while [ -n "$current" ] && [ "$guard" -lt 100 ]; do
    parent="$(
      printf '%s' "$comments_json" |
        jq -r --arg id "$current" '
          .[] | select((.id | tostring) == $id) | (.in_reply_to_id // empty)
        ' 2>/dev/null |
        head -n1
    )"
    if [ -z "$parent" ] || [ "$parent" = "null" ]; then
      printf '%s' "$current"
      return 0
    fi
    current="$parent"
    guard=$((guard + 1))
  done
  printf '%s' "$comment_id"
}


persist_conversation_message() {
  # Args:
  #   conv_id repo issue comment_id author body url created_at message_type
  local conv_id="$1"
  local repo="$2"
  local issue="$3"
  local comment_id="$4"
  local author="$5"
  local body="$6"
  local url="$7"
  local created="$8"
  local message_type="${9:-comment}"

  [ -n "$conv_id" ] || return 0
  [ -n "$comment_id" ] || return 0

  # Idempotency: skip if this (conversationId, commentId) pair already exists.
  local already_persisted
  already_persisted="$(sqlite3 "$DB" "
    SELECT 1
    FROM conversation_messages
    WHERE conversationId='$(sql_escape "$conv_id")'
      AND commentId='$(sql_escape "$comment_id")'
    LIMIT 1;
  " 2>/dev/null || true)"
  [ "$already_persisted" = "1" ] && return 0

  local esc_repo esc_author esc_body esc_url esc_type message_id
  esc_repo="$(sql_escape "$repo")"
  esc_author="$(sql_escape "$author")"
  esc_body="$(sql_escape "$body")"
  esc_url="$(sql_escape "$url")"
  esc_type="$(sql_escape "$message_type")"
  message_id="$(uuidgen)"

  sqlite3 "$DB" "
    INSERT OR IGNORE INTO conversation_messages(
      messageId,
      conversationId,
      commentId,
      repo,
      issueNumber,
      author,
      body,
      commentUrl,
      createdAt,
      messageType
    )
    VALUES(
      '$message_id',
      '$(sql_escape "$conv_id")',
      '$(sql_escape "$comment_id")',
      '$esc_repo',
      $issue,
      '$esc_author',
      '$esc_body',
      '$esc_url',
      '$(sql_escape "$created")',
      '$esc_type'
    );
  " 2>>"$LOG" || true
}

ensure_conversation() {
  local conv_id="$1"
  local repo="$2"
  local issue="$3"
  local issue_url="$4"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  sqlite3 "$DB" "
    INSERT OR IGNORE INTO conversations(
      conversationId,
      repository,
      issueNumber,
      issueUrl,
      status,
      createdAt,
      updatedAt
    )
    VALUES(
      '$(sql_escape "$conv_id")',
      '$(sql_escape "$repo")',
      $issue,
      '$(sql_escape "$issue_url")',
      'OPEN',
      '$now',
      '$now'
    );

    UPDATE conversations
    SET updatedAt='$now'
    WHERE conversationId='$(sql_escape "$conv_id")';
  " 2>>"$LOG" || true
}

persist_conversation_root_message() {
  # Persist the Issue/PR root as part of a top-level conversation so a trigger
  # such as "/manul do this" still has the authoritative task description.
  local conv_id="$1"
  local repo="$2"
  local issue="$3"
  local is_pr="${4:-0}"

  local root_json
  root_json="$(gh api "repos/$repo/issues/$issue" 2>>"$LOG" || echo "{}")"
  [ -n "$root_json" ] || root_json="{}"

  local root_id="root:${repo}:${issue}"
  local root_author root_body root_url root_created root_title message_type
  root_author="$(jq -r '.user.login // "unknown"' <<<"$root_json")"
  root_body="$(jq -r '.body // ""' <<<"$root_json")"
  root_url="$(jq -r '.html_url // empty' <<<"$root_json")"
  [ -n "$root_url" ] || root_url="https://github.com/$repo/issues/$issue"
  root_created="$(jq -r '.created_at // ""' <<<"$root_json")"
  root_title="$(jq -r '.title // ""' <<<"$root_json")"

  # Even when the root body is empty, the title is useful authoritative context.
  local formatted_body=""
  if [ -n "$root_title" ] && [ -n "$root_body" ]; then
    formatted_body="# $root_title

$root_body"
  elif [ -n "$root_title" ]; then
    formatted_body="# $root_title"
  else
    formatted_body="$root_body"
  fi
  [ -n "$formatted_body" ] || return 0

  if [ "$is_pr" -eq 1 ]; then
    message_type="pr-description"
  else
    message_type="issue"
  fi

  persist_conversation_message \
    "$conv_id" "$repo" "$issue" "$root_id" "$root_author" \
    "$formatted_body" "$root_url" "$root_created" "$message_type"
}

build_conversation_context() {
  local conv_id="$1"

  sqlite3 -separator $'\t' "$DB" "
    SELECT
      author,
      messageType,
      body,
      commentId,
      commentUrl,
      createdAt
    FROM conversation_messages
    WHERE conversationId='$(sql_escape "$conv_id")'
    ORDER BY createdAt ASC, rowid ASC;
  " 2>/dev/null |
  while IFS=$'\t' read -r author message_type body comment_id comment_url created_at; do
    printf '[%s] %s (%s)\n%s\n\n'       "$created_at" "$author" "$message_type" "$body"
  done
}

# Resume a task that is waiting for explicit user input.
# The continuation comment is stored as conversation context but does not
# create a second processed_comments task.
resume_blocked_user_task() {
  local conv_id="$1" repo="$2" issue="$3" comment_id="$4" author="$5" answer="$6" created="$7" url="$8"
  local safe_conv_id safe_answer safe_url
  safe_conv_id="$(sql_escape "$conv_id")"
  safe_answer="$(sql_escape "$answer")"
  safe_url="$(sql_escape "$url")"

  local blocked_count
  blocked_count="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE conversationId='$safe_conv_id' AND status='blocked_user';" 2>/dev/null || echo 0)"
  [ "${blocked_count:-0}" -gt 0 ] || return 1

  local blocked_task_id
  blocked_task_id="$(sqlite3 "$DB" "SELECT commentId FROM processed_comments WHERE conversationId='$safe_conv_id' AND status='blocked_user' ORDER BY processedAt DESC, createdAt DESC LIMIT 1;" 2>/dev/null || true)"
  [ -n "$blocked_task_id" ] || return 1

  if [ "${blocked_count:-0}" -gt 1 ]; then
    log "WARN: multiple blocked_user tasks in conversation $conv_id; resuming newest task $blocked_task_id"
  fi

  persist_conversation_message "$conv_id" "$repo" "$issue" "$comment_id" "$author" "$answer" "$url" "$created" "user-clarification"

  local context esc_context
  context="$(build_conversation_context "$conv_id")"
  esc_context="$(printf '%s' "$context" | sed "s/'/''/g")"

  local changed
  changed="$(sqlite3 "$DB" "
    UPDATE processed_comments
    SET status='queued',
        prompt=prompt || char(10) || char(10) || '## User clarification' || char(10) || '$safe_answer',
        context='$esc_context',
        processedAt=NULL, nextAttemptAt=NULL,
        heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL, claimToken=NULL
    WHERE commentId='$(sql_escape "$blocked_task_id")' AND status='blocked_user';
    SELECT changes();
  " 2>>"$LOG" | tail -1)"

  if [ "$changed" = "1" ]; then
    sqlite3 "$DB" "UPDATE conversations SET status='OPEN', activeTaskId='$(sql_escape "$blocked_task_id")', updatedAt='$(sql_escape "$created")' WHERE conversationId='$safe_conv_id';" 2>>"$LOG" || true
    log "resumed blocked task $blocked_task_id in conversation $conv_id from user clarification $comment_id"
    lc_log "TASK_RESUMED_USER" "task=$blocked_task_id conversation=$conv_id source=$comment_id"
    return 0
  fi

  log "WARN: failed to resume blocked task $blocked_task_id from user clarification $comment_id"
  return 1
}

refresh_queued_task_contexts_for_repo() {
  local repo="$1"
  local conv_id context esc_ctx

  while IFS= read -r conv_id; do
    [ -n "$conv_id" ] || continue
    context="$(build_conversation_context "$conv_id")"
    [ -n "$context" ] || continue
    esc_ctx="$(printf '%s' "$context" | sed "s/'/''/g")"

    sqlite3 "$DB" "UPDATE processed_comments
      SET context='$esc_ctx'
      WHERE repository='$(sql_escape "$repo")'
        AND conversationId='$(sql_escape "$conv_id")'
        AND status='queued';" 2>>"$LOG"

    log "context refreshed for queued tasks on $repo (conversation=$conv_id)"
  done < <(
    sqlite3 "$DB" "SELECT DISTINCT conversationId
      FROM processed_comments
      WHERE repository='$(sql_escape "$repo")'
        AND conversationId IS NOT NULL
        AND conversationId != ''
        AND status='queued';" 2>>"$LOG" || true
  )
}

persist_conversation_messages_for_repo() {
  # After processing trigger comments, also persist ALL non-trigger comments
  # on the same issues/PRs as conversation history. This ensures the daemon
  # has full thread context even for messages that didn't contain /manul.
  #
  # Requirement: persist ALL conversation messages regardless of task status.
  # Even completed/resolved tasks should have their conversation context preserved
  # so the bot can reference full thread history.
  local repo="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Get all issue/PR numbers that have ANY processed comments (not just queued/running)
  local affected_ids
  affected_ids="$(sqlite3 "$DB" "SELECT DISTINCT issueNumber FROM processed_comments WHERE repository='$(sql_escape "$repo")';" 2>>"$LOG")" || true

  [ -z "$affected_ids" ] && return 0

  for issue_num in $affected_ids; do
    [ -n "$issue_num" ] || continue
    # Determine if this is a PR or issue
    local is_pr=0
    [ -n "${OPEN_PRS[$issue_num]:-}" ] && is_pr=1
    [ -n "${MERGED_PRS[$issue_num]:-}" ] && is_pr=1
    [ -n "${CLOSED_PRS[$issue_num]:-}" ] && is_pr=1

    local conv_id
    conv_id="$(generate_conversation_id "$repo" "$issue_num" "issue")" || continue

    # Persist the authoritative Issue/PR root before any task context is built.
    # This is what lets "/manul do this" resolve to the actual Issue request.
    persist_conversation_root_message "$conv_id" "$repo" "$issue_num" "$is_pr"

    local comments_json
    if [ "$is_pr" -eq 1 ]; then
      comments_json="$(gh api --paginate "repos/$repo/issues/$issue_num/comments?per_page=100" 2>>"$LOG" || echo "[]")"
    else
      comments_json="$(gh api --paginate "repos/$repo/issues/$issue_num/comments?per_page=100" 2>>"$LOG" || echo "[]")"
    fi

    # Get existing message comment IDs for this conversation to avoid re-persisting
    local existing_ids
    existing_ids="$(sqlite3 "$DB" "
      SELECT commentId
      FROM conversation_messages
      WHERE conversationId='$(sql_escape "$conv_id")'
        AND repo='$(sql_escape "$repo")'
        AND issueNumber=$issue_num;
    " 2>>"$LOG" || echo "")"

    while IFS= read -r comment; do
      [ -n "$comment" ] || continue
      local c_id c_author c_body c_url c_created
      c_id="$(jq -r '.id' <<<"$comment")"
      c_author="$(jq -r '.user.login // .login // "unknown"' <<<"$comment")"
      c_body="$(jq -r '.body // ""' <<<"$comment")"
      c_url="$(jq -r '.html_url // ""' <<<"$comment")"
      c_created="$(jq -r '.created_at // ""' <<<"$comment")"
      [ -n "$c_id" ] || continue
      [ -n "$c_url" ] || continue
      echo "$existing_ids" | grep -qxF "$c_id" && continue

      persist_conversation_message         "$conv_id" "$repo" "$issue_num" "$c_id" "$c_author"         "$c_body" "$c_url" "$c_created" "comment"

      existing_ids="$(printf '%s
%s' "$existing_ids" "$c_id")"
    done < <(echo "$comments_json" | jq -c '.[]' 2>/dev/null || true)

    # Also persist PR review comments for PRs — every comment, not just roots.
    if [ "$is_pr" -eq 1 ]; then
      local review_comments
      review_comments="$(gh api --paginate "repos/$repo/pulls/$issue_num/comments?per_page=100" 2>>"$LOG" || echo "[]")"

      while IFS= read -r comment; do
        [ -n "$comment" ] || continue
        local c_id c_author c_body c_url c_created root_id review_conv_id
        c_id="$(jq -r '.id' <<<"$comment")"
        c_author="$(jq -r '.user.login // .login // "unknown"' <<<"$comment")"
        c_body="$(jq -r '.body // ""' <<<"$comment")"
        c_url="$(jq -r '.html_url // ""' <<<"$comment")"
        c_created="$(jq -r '.created_at // ""' <<<"$comment")"
        [ -n "$c_id" ] || continue
        [ -n "$c_url" ] || continue

        # Determine thread root for conversation identity
        if [ "$(jq -r '.in_reply_to_id // empty' <<<"$comment")" = "" ]; then
          root_id="$c_id"
        else
          root_id="$(get_review_thread_root_id "$review_comments" "$c_id")"
        fi
        [ -n "$root_id" ] || continue

        review_conv_id="$(generate_conversation_id "$repo" "$issue_num" "review-thread" "$root_id")" || continue

        persist_conversation_message "$review_conv_id" "$repo" "$issue_num" "$c_id" "$c_author" "$c_body" "$c_url" "$c_created" "review-comment"
      done < <(echo "$review_comments" | jq -c '.[]' 2>/dev/null || true)
    fi
  done
}

# Close conversations whose active PR has been merged and have no remaining tasks.
# Idempotent: only touches conversations with status != 'COMPLETED'.
close_merged_pr_conversations() {
  local merged_pr_list="$1"
  [ -z "$merged_pr_list" ] && return 0

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local query_err
  query_err=$(sqlite3 "$DB" "
    SELECT c.conversationId FROM conversations c
    WHERE c.activePrNumber IN ($merged_pr_list)
      AND c.status != 'COMPLETED'
      AND NOT EXISTS (
        SELECT 1 FROM processed_comments t
        WHERE t.conversationId = c.conversationId
          AND t.status IN ('queued', 'running', 'blocked_user')
      );" 2>>"$LOG") || query_err="FAILED"
  if [ "$query_err" = "FAILED" ]; then
    log "ERROR: failed to query conversations for merged PR auto-close"
  else
    while IFS='|' read -r conv_id; do
      [ -n "$conv_id" ] || continue
      if sqlite3 "$DB" "UPDATE conversations SET status='COMPLETED', activePrNumber=NULL, activePrUrl=NULL, updatedAt='$now' WHERE conversationId='$(sql_escape "$conv_id")' AND status != 'COMPLETED';" 2>>"$LOG"; then
        log "auto-closed conversation $conv_id (merged PR has no remaining tasks)"
      else
        log "ERROR: failed to close conversation $conv_id (merged PR)"
      fi
    done <<<"$query_err"
  fi
}

if [ $# -gt 0 ]; then
  REPOS=("$@")
else
  mapfile -t REPOS < <(jq -r '.repositories[]?' "$CONFIG" 2>/dev/null)
fi

# `taskSources` is authoritative for generic providers. When configured, derive
# the GitHub Issue repository set from all enabled github_issues sources so the
# legacy GitHub event/context plane scans every configured GitHub source.
if [ $# -eq 0 ] && jq -e '(.taskSources // []) | length > 0' "$CONFIG" >/dev/null 2>&1; then
  mapfile -t REPOS < <(
    jq -r '.taskSources[] | select((.enabled != false)) | select(.type == "github_issues") | .repositories[]?' "$CONFIG" 2>/dev/null |
      sort -u
  )
fi

# `taskSources` is authoritative for generic providers; legacy repositories remain GitHub Issues.

# Generic task-source configuration. `taskSources` is authoritative when present;
# legacy `.repositories` continues to mean GitHub Issues.
TASK_SOURCE_CONFIGS=()
while IFS= read -r _source_json; do
  [ -n "$_source_json" ] || continue
  TASK_SOURCE_CONFIGS+=("$_source_json")
done < <(task_source_configured_sources "$CONFIG" 2>>"$LOG")

# Explicit taskSources makes adapter-based root discovery authoritative.
TASK_SOURCES_EXPLICIT=0
if jq -e '(.taskSources // []) | length > 0' "$CONFIG" >/dev/null 2>&1; then
  TASK_SOURCES_EXPLICIT=1
fi

# === DB schema initialization and migration (runs on source) ===
mkdir -p "$MANUL_DIR"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS processed_comments (
    commentId TEXT PRIMARY KEY,
    repository TEXT NOT NULL,
    issueNumber INTEGER NOT NULL,
    commentUrl TEXT NOT NULL,
    author TEXT,
    agent TEXT,
    prompt TEXT NOT NULL,
    context TEXT,
    autoAccept INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'queued',
    attempts INTEGER NOT NULL DEFAULT 0,
    createdAt TEXT,
    processedAt TEXT,
    claimToken TEXT
);" 2>>"$LOG"
# migration for existing DBs (pre-agent column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|agent|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN agent TEXT;" 2>>"$LOG"
    log "migration: added agent column"
fi
# migration for existing DBs (pre-attempts column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|attempts|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;" 2>>"$LOG"
    log "migration: added attempts column"
fi
# migration for existing DBs (pre-context column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|context|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN context TEXT;" 2>>"$LOG"
    log "migration: added context column"
fi
# migration for per-task OpenCode --auto mode
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|autoAccept|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN autoAccept INTEGER NOT NULL DEFAULT 0;" 2>>"$LOG"
    log "migration: added autoAccept column"
fi
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|taskSourceType|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceType TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceUrl TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceTitle TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceUpdatedAt TEXT;" 2>>"$LOG"
    log "migration: added generic task source identity fields"
fi
# migration for existing DBs (pre-action/PR fields)
# The poller writes these fields directly; older DBs may predate them.
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|action|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN action TEXT DEFAULT 'IMPLEMENT';" 2>>"$LOG"
    log "migration: added action column"
fi
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|prNumber|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN prNumber INTEGER;" 2>>"$LOG"
    log "migration: added prNumber column"
fi
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|prUrl|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN prUrl TEXT;" 2>>"$LOG"
    log "migration: added prUrl column"
fi
# migration for existing DBs (pre-heartbeatAt column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|heartbeatAt|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN heartbeatAt TEXT;" 2>>"$LOG"
    log "migration: added heartbeatAt column"
fi
# migration for existing DBs (pre-leaseExpiresAt column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|leaseExpiresAt|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN leaseExpiresAt TEXT;" 2>>"$LOG"
    log "migration: added leaseExpiresAt column"
fi
# migration for existing DBs (pre-workerPid column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|workerPid|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workerPid INTEGER;" 2>>"$LOG"
    log "migration: added workerPid column"
fi
# migration for existing DBs (pre-claimToken column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|claimToken|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN claimToken TEXT;" 2>>"$LOG"
    log "migration: added claimToken column"
fi
# migration for existing DBs (pre-nextAttemptAt column)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|nextAttemptAt|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN nextAttemptAt TEXT;" 2>>"$LOG"
    # Set nextAttemptAt for existing retry tasks (attempts > 0) to allow gradual eligibility
    sqlite3 "$DB" "UPDATE processed_comments SET nextAttemptAt = datetime('now', '+60 seconds') WHERE status='queued' AND attempts > 0 AND nextAttemptAt IS NULL;" 2>>"$LOG"
    log "migration: added nextAttemptAt column"
fi
# migration for existing DBs (pre-concurrency fields)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|conversationId|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN conversationId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN parentTaskId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN workspaceId TEXT;" 2>>"$LOG"
    log "migration: added concurrency fields"
fi
# migration for existing DBs (pre-result fields)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|resultSummary|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN resultSummary TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN resultJson TEXT;" 2>>"$LOG"
    log "migration: added result fields"
fi
# migration for runtime session identity used by AgentExecutor continuation.
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|session_id|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN session_id TEXT;" 2>>"$LOG"
    log "migration: added session_id column"
fi
# migration for existing DBs (pre-baseId field for idempotency)
if ! sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" | grep -q '|baseId|'; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN baseId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "CREATE UNIQUE INDEX IF NOT EXISTS idx_base_status ON processed_comments(baseId, status);" 2>>"$LOG"
    log "migration: added baseId column and unique index for idempotency"
fi
# migration for submission claims table (atomic idempotency)
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS submission_claims (
    baseId TEXT PRIMARY KEY,
    commentId TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    createdAt TEXT DEFAULT (datetime('now'))
);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversations(conversationId TEXT PRIMARY KEY, repository TEXT NOT NULL, issueNumber INTEGER, issueUrl TEXT, activePrNumber INTEGER, activePrUrl TEXT, activeTaskId TEXT, status TEXT NOT NULL DEFAULT 'OPEN', createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_links(id INTEGER PRIMARY KEY AUTOINCREMENT, conversationId TEXT NOT NULL, repo TEXT NOT NULL, issueNumber INTEGER, prNumber INTEGER, commentId TEXT, taskCommentId TEXT, linkType TEXT NOT NULL, createdAt TEXT NOT NULL);" 2>>"$LOG"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS conversation_messages(messageId TEXT PRIMARY KEY, conversationId TEXT NOT NULL, commentId TEXT, repo TEXT, issueNumber INTEGER, author TEXT, body TEXT, commentUrl TEXT, createdAt TEXT, messageType TEXT);" 2>>"$LOG"

BASELINE="$(sqlite3 "$DB" "SELECT value FROM meta WHERE key='baseline';")"
if [ -z "$BASELINE" ]; then
    log "ERROR: baseline is missing from Manul state; refusing to poll without an installation baseline"
    fail "baseline is missing from Manul state (run install-manul.sh or repair-manul-runtime.sh)"
fi

# Generic task-source state helpers
# Existing GitHub comment/review processing below remains unchanged for context.
# Root task rows discovered from non-GitHub providers use source:<type>:<id>.
ensure_task_source_columns() {
  local cols
  cols="$(sqlite3 "$DB" "PRAGMA table_info(processed_comments);" 2>>"$LOG" || true)"
  if ! grep -q "|taskSourceType|" <<<"$cols"; then
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceType TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceId TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceUrl TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceTitle TEXT;" 2>>"$LOG"
    sqlite3 "$DB" "ALTER TABLE processed_comments ADD COLUMN taskSourceUpdatedAt TEXT;" 2>>"$LOG"
  fi
}

ensure_task_source_columns

# Lease metadata belongs only to claimed/running tasks. Older pollers populated
# these columns on queued rows, so normalize those rows when the poller loads.
# Never touch running rows: their lease/ownership is managed by the daemon.
cleared_queued_leases="$(sqlite3 "$DB" "UPDATE processed_comments SET heartbeatAt=NULL, leaseExpiresAt=NULL WHERE status='queued' AND (heartbeatAt IS NOT NULL OR leaseExpiresAt IS NOT NULL); SELECT changes();" 2>>"$LOG" | tail -n 1)"
if [[ "${cleared_queued_leases:-0}" =~ ^[0-9]+$ ]] && [ "$cleared_queued_leases" -gt 0 ]; then
  log "cleared stale heartbeat/lease metadata for $cleared_queued_leases queued task(s)"
fi

# === context enrichment helpers ===
declare -A CTX_PR_CACHE CTX_ISSUE_CACHE

extract_issue_refs() {
    local text="$1" repo="$2"
    printf '%s' "$text" | grep -oE 'https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+|#[0-9]+' | awk -v repo="$repo" '
      /^http/ { split($0, a, "/"); print a[4] "/" a[5], a[7] }
      /#/ && !/^http/ && index($0, "/") { split($0, a, "#"); print a[1], a[2] }
      /^#/ { sub(/^#/, ""); print repo, $0 }
    ' | sort -u
}

fetch_issue_ctx() {
    local repo="$1" n="$2" key="$repo#$n" j
    if [ -n "${CTX_ISSUE_CACHE[$key]:-}" ]; then
      printf '%s' "${CTX_ISSUE_CACHE[$key]}"
      return
    fi
    if ! j="$(gh issue view "$n" --repo "$repo" --json number,title,body 2>>"$LOG" | jq -c '{number,title,body}' 2>>"$LOG")"; then
      log "ERROR: failed to fetch issue context for $repo#$n via gh issue view"
      j=""
    fi
    CTX_ISSUE_CACHE[$key]="$j"
    printf '%s' "$j"
}

build_review_context() {
    local repo="$1" pr="$2" path="$3" line="$4" hunk="$5"
    local key="$repo#$pr" pr_json issues_json r n issue_json
    if [ -n "${CTX_PR_CACHE[$key]:-}" ]; then
      pr_json="${CTX_PR_CACHE[$key]}"
    else
      if ! pr_json="$(gh pr view "$pr" --repo "$repo" --json number,title,state,body 2>>"$LOG" | jq -c . 2>>"$LOG")"; then
        log "ERROR: failed to fetch PR view for $repo#$pr"
        pr_json='{"number":0,"title":"","state":"","body":""}'
      fi
      [ -n "$pr_json" ] || pr_json='{"number":0,"title":"","state":"","body":""}'
      CTX_PR_CACHE[$key]="$pr_json"
    fi
    issues_json='[]'
    while read -r r n; do
      [ -n "${r:-}" ] || continue
      issue_json="$(fetch_issue_ctx "$r" "$n")"
      [ -n "$issue_json" ] && issues_json="$(printf '%s' "$issues_json" | jq -c --argjson x "$issue_json" '. + [$x]')"
    done <<< "$(extract_issue_refs "$(printf '%s' "$pr_json" | jq -r '.body // ""')" "$repo")"
    jq -nc --argjson pr "$pr_json" --argjson issues "$issues_json" --arg path "$path" --arg line "$line" --arg hunk "$hunk" '{pr:$pr, linkedIssues:$issues, comment:{path:$path,line:$line,diffHunk:$hunk}}'
}

build_issue_context() {
    local repo="$1" n="$2" issue_json
    issue_json="$(fetch_issue_ctx "$repo" "$n")"
    if [ -n "$issue_json" ]; then
      printf '%s' "$issue_json" | jq -c '{issue:.}'
    fi
}
# === end context enrichment helpers ===

# === ci fix helpers ===
# ci_fix_seen table: tracks PRs/runs we've already attempted to fix to avoid loops
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS ci_fix_seen (
    prNumber INTEGER NOT NULL,
    runId TEXT NOT NULL,
    attemptedAt TEXT NOT NULL,
    PRIMARY KEY (prNumber, runId)
);" 2>>"$LOG"

# ci_fix_failed table: records (repo, PR, head_sha) where a build-fix attempt
# already failed. While the PR head stays on this commit, the poller must NOT
# queue another build-fix task — the bot has already proven it could not fix
# this build, and adding more attempts would burn time and tokens without
# changing the result. When the PR head moves (new commit), the row no longer
# matches and a fresh fix is eligible again.
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS ci_fix_failed (
    repository TEXT NOT NULL,
    prNumber INTEGER NOT NULL,
    head_sha TEXT NOT NULL,
    branch TEXT,
    reason TEXT,
    failed_at TEXT NOT NULL,
    PRIMARY KEY (repository, prNumber, head_sha)
);" 2>>"$LOG"

# check_ci_fix_eligible <repo> <prNumber> <runId> -> returns 0 if eligible, 1 if not
check_ci_fix_eligible() {
    local repo="$1" pr="$2" run="$3"
    local key="$repo#$pr#$run"
    local pr_num
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 1
    local safe_run
    safe_run="$(sql_escape "$run")"
    local safe_repo
    safe_repo="$(sql_escape "$repo")"
    local seen
    seen="$(sqlite3 "$DB" "SELECT 1 FROM ci_fix_seen WHERE prNumber=$pr_num AND runId='$safe_run';" 2>>"$LOG")"
    if [ -n "$seen" ]; then
      return 1
    fi
    # Check cooldown
    local last_attempt
    last_attempt="$(sqlite3 "$DB" "SELECT MAX(attemptedAt) FROM ci_fix_seen WHERE prNumber=$pr_num;" 2>>"$LOG")"
    if [ -n "$last_attempt" ] && [ "$last_attempt" != "null" ]; then
      local last_ts now_ts
      last_ts=$(date -d "$last_attempt" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_attempt" +%s 2>/dev/null || echo 0)
      now_ts=$(date +%s)
      local cooldown_secs=$((CI_FIX_COOLDOWN_MINUTES * 60))
      if [ $((now_ts - last_ts)) -lt $cooldown_secs ]; then
        return 1
      fi
    fi
    return 0
}

# mark_ci_fix_attempted <repo> <prNumber> <runId>
mark_ci_fix_attempted() {
    local repo="$1" pr="$2" run="$3"
    local pr_num
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 0
    local safe_run
    safe_run="$(sql_escape "$run")"
    local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$DB" "INSERT OR REPLACE INTO ci_fix_seen (prNumber, runId, attemptedAt) VALUES ($pr_num, '$safe_run', '$now');" 2>>"$LOG"
}

# mark_ci_fix_failed_for_commit <repo> <prNumber> <head_sha> <branch> <reason>
# Records that a build-fix attempt failed for this specific commit. Until the
# PR head advances past this commit, the poller will skip queuing build-fix
# tasks for this PR (see is_ci_fix_failed_for_commit). Old rows for prior
# commits are preserved as a historical record and naturally fall out of
# relevance as the PR moves on.
mark_ci_fix_failed_for_commit() {
    local repo="$1" pr="$2" sha="$3" branch="$4" reason="$5"
    [ -n "$sha" ] || return 0
    local pr_num
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 0
    local safe_repo safe_branch safe_reason
    safe_repo="$(sql_escape "$repo")"
    safe_branch="$(sql_escape "$branch")"
    safe_reason="$(sql_escape "$reason")"
    local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sqlite3 "$DB" "INSERT OR REPLACE INTO ci_fix_failed (repository, prNumber, head_sha, branch, reason, failed_at) VALUES ('$safe_repo', $pr_num, '$sha', '$safe_branch', '$safe_reason', '$now');" 2>>"$LOG"
    log "ci fix FAILED for $repo#$pr at commit $sha (branch=$branch): $reason — will not retry until head changes"
}

# is_ci_fix_failed_for_commit <repo> <prNumber> <head_sha> -> returns 0 if a
# failed attempt is already recorded for this exact commit (must skip), 1 if
# the commit is fresh and a fix attempt is allowed.
is_ci_fix_failed_for_commit() {
    local repo="$1" pr="$2" sha="$3"
    [ -n "$sha" ] && sqlite3 "$DB" "SELECT 1 FROM ci_fix_failed WHERE repository='$repo' AND prNumber=$pr AND head_sha='$sha' LIMIT 1;" 2>/dev/null | grep -q 1
}

has_unresolved_manul_tasks() {
    local repo="$1"
    local issue="$2"
    local safe_repo found

    # These values originate from configured repositories and GitHub PR
    # numbers, but still validate/escape them before building the SQL query.
    if ! [[ "$issue" =~ ^[0-9]+$ ]]; then
        log "WARN: invalid issue number '$issue' in unresolved-task check; skipping CI auto-fix conservatively"
        return 0
    fi
    safe_repo="$(printf '%s' "$repo" | sed "s/'/''/g")"

    # EXISTS returns exactly 0/1 internally. Capture it so this helper emits
    # no stray "1" on stdout; callers depend on its exit status, not SQL output.
    if ! found="$(sqlite3 "$DB" "SELECT EXISTS(SELECT 1 FROM processed_comments WHERE repository='$safe_repo' AND issueNumber=$issue AND commentId NOT LIKE 'ci_fix:%' AND status IN ('queued','running','failed') AND (status!='failed' OR attempts <= 2));" 2>>"$LOG")"; then
        # Fail closed: on DB/query errors, do not launch a duplicate CI fix task.
        log "WARN: unresolved-task check failed for $repo#$issue; skipping CI auto-fix conservatively"
        return 0
    fi

    case "$found" in
        1) return 0 ;;
        0) return 1 ;;
        *)
            log "WARN: unexpected unresolved-task query result '$found' for $repo#$issue; skipping CI auto-fix conservatively"
            return 0
            ;;
    esac
}

# is_manul_owned_pr <repo> <prNumber> <prUrl> -> returns 0 only when a completed Manul task
# has persisted this exact verified PR URL as its deliverable. Source PR numbers,
# branch names, bot comments, CI history, and non-terminal task rows are not proof.
# A missing record or any database/query error fails closed.
is_manul_owned_pr() {
    local repo="$1" pr="$2" pr_url="$3"
    local pr_num safe_repo safe_url found
    pr_num="$(sql_num "$pr")"
    [ -n "$pr_num" ] || return 1
    [[ "$pr_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/$pr_num/?$ ]] || return 1
    safe_repo="$(sql_escape "$repo")"
    safe_url="$(sql_escape "$pr_url")"
    if ! found="$(sqlite3 "$DB" "SELECT EXISTS(
      SELECT 1 FROM processed_comments
      WHERE repository='$safe_repo'
        AND commentId NOT LIKE 'ci_fix:%'
        AND status='completed'
        AND prNumber=$pr_num
        AND rtrim(prUrl, '/') = rtrim('$safe_url', '/')
    );" 2>>"$LOG")"; then
      log "WARN: CI provenance query failed for $repo#$pr; skipping automatic CI fix"
      return 1
    fi
    [ "$found" = "1" ]
}

# scan_failing_ci <repo> -> queues synthetic tasks only for verified Manul deliverable PRs
scan_failing_ci() {
    local repo="$1"
    [ "$CI_FIX_ENABLED" = "true" ] || return 0
    local prs_json
    # Scan open PRs, then require verified Manul deliverable provenance before CI auto-fix
    prs_json="$(gh pr list --repo "$repo" --limit 100 --json number,headRefName,baseRefName,title,url 2>>"$LOG" | jq -c '[.[] | {number: .number, head: .headRefName, base: .baseRefName, title: .title, html_url: .url}]' 2>>"$LOG" || true)"
    [ -n "$prs_json" ] || return 0
    local pr_count
    pr_count="$(printf '%s' "$prs_json" | jq -r 'length // 0' 2>/dev/null || echo 0)"
    [[ "$pr_count" =~ ^[0-9]+$ ]] || {
      log "WARN: invalid PR count '$pr_count'; skipping CI scan for $repo"
      return 0
    }
    [ "$pr_count" -gt 0 ] || return 0
    log "scanning $pr_count open PR(s) on $repo for failing CI provenance"
    local i=0
    while [ $i -lt "$pr_count" ]; do
      local pr
      pr="$(printf '%s' "$prs_json" | jq -c ".[$i]")"
      local pr_num pr_branch pr_title
      pr_num="$(printf '%s' "$pr" | jq -r '.number')"
      pr_branch="$(printf '%s' "$pr" | jq -r '.head')"
      pr_title="$(printf '%s' "$pr" | jq -r '.title')"
      local pr_url
      pr_url="$(printf '%s' "$pr" | jq -r '.html_url // ""')"
      # Only auto-fix a PR when a completed Manul task persisted this exact
      # canonical PR URL as its verified deliverable. Never infer ownership
      # from an arbitrary open PR, branch naming, source issue number, or comments.
      if ! is_manul_owned_pr "$repo" "$pr_num" "$pr_url"; then
        log "skipping CI fix for $repo#$pr_num — no verified Manul-owned PR record"
        i=$((i+1))
        continue
      fi
      # Skip build-fix if this PR already has unresolved manul tasks
      if has_unresolved_manul_tasks "$repo" "$pr_num"; then
        log "skipping CI fix for $repo#$pr_num — unresolved manul tasks present"
        i=$((i+1))
        continue
      fi
      # Get the PR's current head SHA — used as the per-commit skip key. If a
      # build-fix attempt already failed for THIS exact commit, do not queue
      # another one (the bot has proven it could not fix this build). The gate
      # lifts automatically the moment the PR head moves to a new commit.
      local pr_head_sha
      pr_head_sha="$(gh pr view "$pr_num" --repo "$repo" --json headRefOid --jq '.headRefOid // ""' 2>>"$LOG" || true)"
      if [ -n "$pr_head_sha" ] && is_ci_fix_failed_for_commit "$repo" "$pr_num" "$pr_head_sha"; then
        local prev_reason prev_at
        prev_reason="$(sqlite3 "$DB" "SELECT reason FROM ci_fix_failed WHERE repository='$repo' AND prNumber=$pr_num AND head_sha='$pr_head_sha' LIMIT 1;" 2>>"$LOG")"
        prev_at="$(sqlite3 "$DB" "SELECT failed_at FROM ci_fix_failed WHERE repository='$repo' AND prNumber=$pr_num AND head_sha='$pr_head_sha' LIMIT 1;" 2>>"$LOG")"
        log "skipping CI fix for $repo#$pr_num — build fix already FAILED for commit $pr_head_sha at ${prev_at:-?}: ${prev_reason:-no reason recorded}. Will retry once a new commit is pushed."
        i=$((i+1))
        continue
      fi
      # Get failing checks for this PR
      local checks_json
      checks_json="$(gh pr checks "$pr_num" --repo "$repo" --json name,state,completedAt,link 2>>"$LOG" | jq -c '[.[] | select(.state=="FAILURE" or .state=="ERROR")]' 2>>"$LOG" || true)"
      [ -n "$checks_json" ] || { i=$((i+1)); continue; }
      local failing_count
      failing_count="$(printf '%s' "$checks_json" | jq 'length')"
      [ "$failing_count" -gt 0 ] || { i=$((i+1)); continue; }
      log "found $failing_count failing check(s) on $repo#$pr_num ($pr_branch)"
      local j=0
      while [ $j -lt "$failing_count" ] && [ $j -lt "$CI_FIX_MAX_ATTEMPTS" ]; do
        local check
        check="$(printf '%s' "$checks_json" | jq -c ".[$j]")"
        local check_name check_state check_url
        check_name="$(printf '%s' "$check" | jq -r '.name')"
        check_state="$(printf '%s' "$check" | jq -r '.state')"
        check_url="$(printf '%s' "$check" | jq -r '.link // ""')"
        # Extract run ID from link if possible
        local run_id=""
        if printf '%s' "$check_url" | grep -q '/runs/'; then
          run_id="$(printf '%s' "$check_url" | sed -E 's|.*/runs/([0-9]+).*|\1|')"
        fi
        [ -n "$run_id" ] || run_id="check-$check_name-$(date +%s)"
        # Check if we already attempted this run
        if check_ci_fix_eligible "$repo" "$pr_num" "$run_id"; then
# Create synthetic task for CI fix
           local prompt="CI build '$check_name' is failing on PR #$pr_num (branch: $pr_branch). Fix the failing build. PR: $(printf '%s' "$pr" | jq -r '.html_url')"
           local comment_id="ci_fix:$repo:$pr_num:$run_id"
           local created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
           local esc_prompt
           esc_prompt="$(printf '%s' "$prompt" | sed "s/'/''/g")"
           local base_id="$comment_id"
           sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId,baseId) VALUES('$comment_id','$repo',$pr_num,'$(printf '%s' "$pr" | jq -r '.html_url')','manul-ci-fix','debugger','$esc_prompt','queued','$created_at',NULL,NULL,'$(generate_conversation_id "$repo" "$pr_num" "pr-top-level")','$base_id');" 2>>"$LOG"
           if [ "$(sqlite3 "$DB" "SELECT changes();" 2>>"$LOG")" -gt 0 ]; then
            NEW=$((NEW + 1))
            log "queued CI fix task for $repo#$pr_num run $run_id (check: $check_name)"
          fi
          mark_ci_fix_attempted "$repo" "$pr_num" "$run_id"
        fi
        j=$((j+1))
      done
      i=$((i+1))
    done
}
# === end ci fix helpers ===

NEW=0

queue_normalized_source_task() {
  local task_json="$1" source_type source_id source_url title body created updated state execution_kind source_action
  source_type="$(jq -r ".taskSourceType // empty" <<<"$task_json")"
  source_id="$(jq -r ".taskSourceId // empty" <<<"$task_json")"
  source_url="$(jq -r ".taskSourceUrl // empty" <<<"$task_json")"
  title="$(jq -r ".title // empty" <<<"$task_json")"
  body="$(jq -r ".body // empty" <<<"$task_json")"
  created="$(jq -r ".createdAt // \"\"" <<<"$task_json")"
  updated="$(jq -r ".updatedAt // .createdAt // \"\"" <<<"$task_json")"
  state="$(jq -r ".state // \"OPEN\"" <<<"$task_json")"
  execution_kind="$(jq -r ".execution.kind // \"repository\"" <<<"$task_json")"
  local normalized_prompt
  normalized_prompt="$(jq -r ".prompt // .body // empty" <<<"$task_json")"
  source_action="$(jq -r '.action // "IMPLEMENT"' <<<"$task_json")"
  case "$source_action" in
    IMPLEMENT|REVIEW_FIX|VERIFY) ;;
    *) source_action="IMPLEMENT" ;;
  esac
  [ -n "$source_type" ] && [ -n "$source_id" ] && [ -n "$body" ] && [ -n "$normalized_prompt" ] || return 0
  [ "$state" = "OPEN" ] || return 0

  local task_id="source:${source_type}:${source_id}" repo source_context
  repo="$(jq -r ".metadata.repository // empty" <<<"$task_json")"
  local issue_number
  issue_number="$(jq -r ".metadata.issueNumber // 0" <<<"$task_json")"

  if [ "$execution_kind" = "report_only" ]; then
    case "$source_type" in
      todo_local_mcp|todo_remote_mcp) ;;
      *)
        log "WARN: non-Todo source $source_type cannot request report-only execution"
        return 0 ;;
    esac
    # The legacy queue schema requires a non-empty repository column. Use a
    # reserved sentinel; the report-only dispatcher must never lock, clone,
    # enter or otherwise treat this value as a GitHub repository.
    repo="todo-report-only"
    issue_number=0
  elif [ "$execution_kind" != "repository" ]; then
    log "discovered task source $source_type:$source_id (execution.kind=$execution_kind); unsupported execution kind"
    return 0
  fi
  issue_number="$(sql_num "$issue_number")"
  issue_number="${issue_number:-0}"
  source_context="$(printf "%s" "$task_json" | jq -c '{execution:(.execution // {kind:"repository"}),metadata:(.metadata // {})}')"
  if [ "$execution_kind" = "repository" ] && [ -z "$repo" ]; then
    log "WARN: task source $source_type:$source_id has repository execution but no repository metadata; not queued"
    return 0
  fi
  if sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId,baseId,taskSourceType,taskSourceId,taskSourceUrl,taskSourceTitle,taskSourceUpdatedAt,context,action) VALUES('$(sql_escape "$task_id")','$(sql_escape "$repo")',${issue_number},'$(sql_escape "$source_url")','task-source','','$(sql_escape "$normalized_prompt")','queued','$(sql_escape "$created")',NULL,NULL,NULL,'$(sql_escape "$task_id")','$(sql_escape "$source_type")','$(sql_escape "$source_id")','$(sql_escape "$source_url")','$(sql_escape "$title")','$(sql_escape "$updated")','$(sql_escape "$source_context")','$(sql_escape "$source_action")'); SELECT changes();" 2>>"$LOG" | tail -1 | grep -q "^1$"; then
    NEW=$((NEW + 1))
    log "queued task source $source_type:$source_id"
  fi
}
poll_all_task_sources() {
  local source_json type task_json
  for source_json in "${TASK_SOURCE_CONFIGS[@]}"; do
    type="$(task_source_name "$source_json")"
    [ -n "$type" ] || continue
    # The install baseline is scan metadata, not a universal task filter.
    # Providers decide whether/how they apply it.
    local source_poll_json
    source_poll_json="$(jq -c --arg baseline "$BASELINE" '.baseline=$baseline' <<<"$source_json")"
    while IFS= read -r task_json; do
      [ -n "$task_json" ] || continue
      queue_normalized_source_task "$task_json"
    done < <(task_source_poll "$source_poll_json" 2>>"$LOG" || {
      log "WARN: task source provider failed (type=$type), continuing with other sources"
      true
    })
  done
}

# process_repo_body — processes a single repository (issue comments, issue bodies,
# PR review comments, PR reviews, skip-log drain, CI scan). Used by poll.sh's main
# loop and by tests. Must be called from within this script's shell.
process_repo_body() {
  local repo="$1"

  # Resolve the allow-list for this repo before any GitHub traffic is filtered.
  # A placeholder like "<GITHUB_LOGIN>" must never be treated as a real login.
  resolve_allowed_users "$repo"

  # Batch-fetch issue/PR states for this repo to avoid per-comment API calls.
  # Populates: OPEN_ISSUES, CLOSED_ISSUES, OPEN_PRS, MERGED_PRS, CLOSED_PRS
  declare -A OPEN_ISSUES=() CLOSED_ISSUES=() OPEN_PRS=() MERGED_PRS=() CLOSED_PRS=()
  while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && OPEN_ISSUES["$n"]=1; done < <(gh issue list --repo "$repo" --limit 100 --json number --jq '.[].number' 2>>"$LOG" || true)
  while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && CLOSED_ISSUES["$n"]=1; done < <(gh issue list --repo "$repo" --limit 100 --state closed --json number --jq '.[].number' 2>>"$LOG" || true)
  while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && OPEN_PRS["$n"]=1; done < <(gh pr list --repo "$repo" --limit 100 --json number --jq '.[].number' 2>>"$LOG" || true)
  while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && MERGED_PRS["$n"]=1; done < <(gh pr list --repo "$repo" --limit 100 --state merged --json number --jq '.[] | select(.merged_at != null) | .number' 2>>"$LOG" || true)
  while read -r n; do [ -n "$n" ] && [ "$n" != "[]" ] && CLOSED_PRS["$n"]=1; done < <(gh pr list --repo "$repo" --limit 100 --state closed --json number --jq '.[] | select(.merged_at == null) | .number' 2>>"$LOG" || true)

  # Auto-close conversations for merged PRs that have no remaining active tasks.
  if [ ${#MERGED_PRS[@]} -gt 0 ]; then
    merged_pr_ids=""
    for mp in "${!MERGED_PRS[@]}"; do
      [ -n "$merged_pr_ids" ] && merged_pr_ids="$merged_pr_ids,"
      merged_pr_ids="${merged_pr_ids}${mp}"
    done
    close_merged_pr_conversations "$merged_pr_ids"
  fi

  # Drain pending skip comments from a previous failed run.
  skip_log="$MANUL_DIR/skip-comments.log"
  if [ -f "$skip_log" ]; then
    tmp_skip="${skip_log}.tmp"
    > "$tmp_skip"
    while IFS='|' read -r srepo sissue smsg stime; do
      [ -n "$srepo" ] || continue
      if "$MANUL_DIR/feedback.sh" "$srepo" "$sissue" "$smsg" 2>>"$LOG"; then
        log "delivered pending skip comment for $srepo#$sissue (queued at $stime)"
      else
        printf '%s|%s|%s|%s\n' "$srepo" "$sissue" "$smsg" "$stime" >> "$tmp_skip"
        log "WARN: pending skip comment for $srepo#$sissue still failing, will retry next poll"
      fi
    done < "$skip_log"
    mv "$tmp_skip" "$skip_log"
  fi

  # Build JSON array of open PR numbers for routing decision in issue comment path.
  open_prs_json="[]"
  if [ ${#OPEN_PRS[@]} -gt 0 ]; then
    open_prs_json="$(printf '%s\n' "${!OPEN_PRS[@]}" | jq -R 'tonumber' | jq -s '.')"
  fi

# 1) Issue comments (PR conversation comments are issue comments too)
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    id="$(jq -r '.id' <<<"$obj")"
    issue="$(jq -r '.issueNumber' <<<"$obj")"
    [ -n "${CLOSED_ISSUES[$issue]:-}" ] && continue
    [ -n "${MERGED_PRS[$issue]:-}" ] && continue
    [ -n "${CLOSED_PRS[$issue]:-}" ] && continue
    url="$(jq -r '.url' <<<"$obj")"
    author="$(jq -r '.author' <<<"$obj")"
    created="$(jq -r '.created' <<<"$obj")"
    prompt="$(jq -r '.prompt' <<<"$obj")"
    agent="$(jq -r '.agent // ""' <<<"$obj")"
    action="$(jq -r '.action // ""' <<<"$obj")"
    auto_accept=0
    if [ "$(jq -r '.autoAccept // false' <<<"$obj")" = "true" ]; then auto_accept=1; fi
    # A bare trigger ("/manul" with no following text) legitimately yields an
    # empty prompt — the issue/PR body supplies the task via conversation
    # context. Only a bare CONTINUE (no answer) is not a real task.
    if [ -z "$prompt" ] && [ "$action" = "CONTINUE" ]; then continue; fi
    fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
    [ -n "$fullBody" ] || fullBody="$prompt"
    prompt="$fullBody"
    prompt="$(printf '%s' "$prompt" | sed -E 's/(^|[[:space:]])--auto([[:space:]]|$)/\1\2/g')"
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # processed_comments is short-lived; conversation_messages is the durable
    # message-identity record used to prevent old triggers from being requeued.
    already_recorded="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='$(sql_escape "$id")' UNION ALL SELECT 1 FROM conversation_messages WHERE commentId='$(sql_escape "$id")' LIMIT 1;" 2>/dev/null || true)"
    [ "$already_recorded" = "1" ] && continue
    conv_id="$(generate_conversation_id "$repo" "$issue" "issue")" || continue
    base_id="$id"

    if [ "$action" = "CONTINUE" ]; then
      conv_id="$(generate_conversation_id "$repo" "$issue" "issue")" || continue
      if resume_blocked_user_task "$conv_id" "$repo" "$issue" "$id" "$author" "$prompt" "$created" "$url"; then
        NEW=$((NEW + 1))
        continue
      fi
      action="CONTINUE"
    fi

    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,action,prNumber,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId,baseId,autoAccept) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','$action',$issue,'queued','$created',NULL,NULL,'$(sql_escape "$conv_id")','$base_id',$auto_accept); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      raw_id="$(jq -r '.rawId // .id' <<<"$obj")"
      raw_body="$(jq -r '.rawBody // .body // ""' <<<"$obj")"
      persist_conversation_message "$conv_id" "$repo" "$issue" "$raw_id" "$author" "$raw_body" "$url" "$created" "comment"
      sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', '$(sql_escape "$repo")', $issue, '$url', NULL, 'OPEN', '$now', '$now');" 2>>"$LOG" || true
      # Task context is materialized after the poll has ingested all
      # available GitHub messages for this repository.
      log "queued $id on $repo#$issue (agent=${agent:-default})"
    fi
  done < <(gh api --paginate "repos/$repo/issues/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" --argjson open_prs "$open_prs_json" '
    ($trig | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) as $trig_re
    | .[] | select(.created_at >= $base) | select((.body // "") | test("(^|\\r?\\n)[ \\t]*" + $trig_re + "([ \\t\\r\\n]|$)")) | select((.body // "") | contains($sig) | not) | select((.user.type // "User") != "Bot") | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | test("^[ \\t]*" + $trig_re + "([ \\t]|$)"))][0]) as $idx
    | ($lines[$idx] | sub("^[ \\t]*" + $trig_re + "([ \\t]*|$)"; "")) as $rest0_raw
    | ($rest0_raw | test("(^|[ \\t])--auto([ \\t]|$)")) as $auto_accept
    | ($rest0_raw | gsub("(^|[ \\t])--auto([ \\t]|$)"; " ") | sub("^[ \\t]+"; "") | sub("[ \\t]+$"; "")) as $rest0
    | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else ($rest0 + "\n" + ($lines[$idx+1:] | join("\n"))) end) as $rest
    | ($rest | split(" ")[0]) as $tok
    | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
    | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt_no_agent
    | (if $tok == "run" then
         (($rest | sub("^run([ \\t]+|$)"; "")) as $run_rest
          | if ($run_rest | test("^--agent([ \\t]+|$)")) then
              (try ($run_rest | capture("^--agent[ \\t]+(?<requested_agent>[^ \\t]+)(?:[ \\t]+(?<requested_prompt>(?s:.*)))?$"))
               catch {requested_agent:"__missing_agent__",requested_prompt:""}) as $requested
              | {action: "IMPLEMENT", prompt: ($requested.requested_prompt // ""), agent: $requested.requested_agent}
            else {action: "IMPLEMENT", prompt: ($run_rest | sub("^[ \\t]+"; "")), agent: ""}
            end)
       elif $tok == "review-fix" then {action: "REVIEW_FIX", prompt: ($rest | ltrimstr("review-fix") | sub("^[ \\t]+"; ""))}
       elif $tok == "verify" then {action: "VERIFY", prompt: ($rest | ltrimstr("verify") | sub("^[ \\t]+"; ""))}
       elif $tok == "fix-impl" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("fix-impl") | sub("^[ \\t]+"; ""))}
       elif $tok == "continue" then {action: "CONTINUE", prompt: ($rest | ltrimstr("continue") | sub("^[ \\t]+"; ""))}
       elif $agent != "" then {action: "IMPLEMENT", prompt: $prompt_no_agent, agent: $agent}
       else {action: null, prompt: $rest, agent: ""}
       end) as $actx
    | (.html_url | capture("(?:issues|pull)/(?<n>[0-9]+)").n | tonumber) as $issue_num
    | (if $actx.action != null then $actx.action
        elif ($open_prs | index($issue_num)) then "REVIEW_FIX"
        else "IMPLEMENT"
        end) as $action
    | {
      id: ("issue:" + (.id|tostring)),
      rawId: (.id|tostring),
      rawBody: .body,
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: $issue_num,
      agent: ($actx.agent // $agent),
      action: $action,
      autoAccept: $auto_accept,
      prompt: $actx.prompt,
      fullBody: (if (($actx.agent // $agent) != "") then $actx.prompt else (.body | sub("^[ \\t]*" + $trig_re + "([ \\t]*|$)"; "") | sub("^.*?((\\r?\\n)[ \\t]*" + $trig_re + "([ \\t]*|$))"; "") | sub("^[ \\t]+"; "")) end)
    }' 2>>"$LOG" || true)

  if [ "$TASK_SOURCES_EXPLICIT" -eq 0 ]; then
  # 1b) Issue bodies (new OPEN issues carrying the trigger in the description)
  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    id="$(jq -r '.id' <<<"$obj")"
    issue="$(jq -r '.issueNumber' <<<"$obj")"
    url="$(jq -r '.url' <<<"$obj")"
    author="$(jq -r '.author' <<<"$obj")"
    created="$(jq -r '.created' <<<"$obj")"
    prompt="$(jq -r '.prompt' <<<"$obj")"
    agent="$(jq -r '.agent // ""' <<<"$obj")"
    action="$(jq -r '.action // ""' <<<"$obj")"
    auto_accept=0
    if [ "$(jq -r '.autoAccept // false' <<<"$obj")" = "true" ]; then auto_accept=1; fi
    # A bare trigger in the issue body legitimately yields an empty prompt —
    # the issue description itself is the task via conversation context.
    if [ -z "$prompt" ] && [ "$action" = "CONTINUE" ]; then continue; fi
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # See the issue-comment path above: keep processed_comments short-lived,
    # but never rediscover an already-ingested issue as a new task.
    already_recorded="$(sqlite3 "$DB" "SELECT 1 FROM processed_comments WHERE commentId='$(sql_escape "$id")' UNION ALL SELECT 1 FROM conversation_messages WHERE commentId='$(sql_escape "$id")' LIMIT 1;" 2>/dev/null || true)"
    [ "$already_recorded" = "1" ] && continue
    conv_id="$(generate_conversation_id "$repo" "$issue" "issue")" || continue
    base_id="$id"
    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,action,prNumber,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId,baseId,autoAccept) VALUES('$id','$repo',$issue,'$url','$author','$esc_a','$esc','$action',$issue,'queued','$created',NULL,NULL,'$(sql_escape "$conv_id")','$base_id',$auto_accept); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', '$(sql_escape "$repo")', $issue, '$url', NULL, 'OPEN', '$now', '$now');" 2>>"$LOG" || true
      # Task context is materialized after the poll has ingested all
      # available GitHub messages for this repository.
      log "queued $id on $repo#$issue (issue body, agent=${agent:-default}, action=${action:-IMPLEMENT})"
    fi
  done < <(gh api --paginate "repos/$repo/issues?state=open&since=$BASELINE&per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
    ($trig | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) as $trig_re
    | .[] | select(.pull_request | not) | select(.created_at >= $base) | select((.body // "") | test("(^|\\r?\\n)[ \\t]*" + $trig_re + "([ \\t\\r\\n]|$)")) | select((.body // "") | contains($sig) | not) | select((.user.type // "User") != "Bot") | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | test("^[ \\t]*" + $trig_re + "([ \\t]|$)"))][0]) as $idx
    | ($lines[$idx] | sub("^[ \\t]*" + $trig_re + "([ \\t]*|$)"; "")) as $rest0_raw
    | ($rest0_raw | test("(^|[ \\t])--auto([ \\t]|$)")) as $auto_accept
    | ($rest0_raw | gsub("(^|[ \\t])--auto([ \\t]|$)"; " ") | sub("^[ \\t]+"; "") | sub("[ \\t]+$"; "")) as $rest0
    | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else ($rest0 + "\n" + ($lines[$idx+1:] | join("\n"))) end) as $rest
    | ($rest | split(" ")[0]) as $tok
    | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
    | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt_no_agent
    | (if $tok == "run" then
         (($rest | sub("^run([ \\t]+|$)"; "")) as $run_rest
          | if ($run_rest | test("^--agent([ \\t]+|$)")) then
              (try ($run_rest | capture("^--agent[ \\t]+(?<requested_agent>[^ \\t]+)(?:[ \\t]+(?<requested_prompt>(?s:.*)))?$"))
               catch {requested_agent:"__missing_agent__",requested_prompt:""}) as $requested
              | {action: "IMPLEMENT", prompt: ($requested.requested_prompt // ""), agent: $requested.requested_agent}
            else {action: "IMPLEMENT", prompt: ($run_rest | sub("^[ \\t]+"; "")), agent: ""}
            end)
       elif $tok == "review-fix" then {action: "REVIEW_FIX", prompt: ($rest | ltrimstr("review-fix") | sub("^[ \\t]+"; ""))}
       elif $tok == "verify" then {action: "VERIFY", prompt: ($rest | ltrimstr("verify") | sub("^[ \\t]+"; ""))}
       elif $tok == "fix-impl" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("fix-impl") | sub("^[ \\t]+"; ""))}
       elif $tok == "continue" then {action: "CONTINUE", prompt: ($rest | ltrimstr("continue") | sub("^[ \\t]+"; ""))}
       elif $agent != "" then {action: "IMPLEMENT", prompt: $prompt_no_agent, agent: $agent}
       else {action: null, prompt: $rest, agent: ""}
       end) as $actx
    | (if $actx.action != null then $actx.action else "IMPLEMENT" end) as $action
    | {
      id: ("issuebody:" + (.id|tostring)),
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: .number,
      agent: ($actx.agent // $agent),
      action: $action,
      autoAccept: $auto_accept,
      prompt: $actx.prompt
    }' 2>>"$LOG" || true)

  fi

  # 2) PR review comments
  review_comments="$(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" || echo "[]")"

  declare -A PR_COMMENT_COUNTS=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pr_num="$(jq -r '.html_url | capture("pull/(?<n>[0-9]+)").n' <<<"$line")"
    [ -n "$pr_num" ] && PR_COMMENT_COUNTS["$pr_num"]=$(( ${PR_COMMENT_COUNTS["$pr_num"]:-0} + 1 ))
  done < <(printf '%s\n' "$review_comments" | jq -c '.[]' 2>/dev/null || true)

  while IFS= read -r obj; do
    [ -n "$obj" ] || continue
    id="$(jq -r '.id' <<<"$obj")"
    pr_num="$(jq -r '.issueNumber' <<<"$obj")"
    [ -n "${OPEN_PRS[$pr_num]:-}" ] || continue
    [ -n "${MERGED_PRS[$pr_num]:-}" ] && continue
    [ -n "${CLOSED_PRS[$pr_num]:-}" ] && continue
    url="$(jq -r '.url' <<<"$obj")"
    author="$(jq -r '.author' <<<"$obj")"
    created="$(jq -r '.created' <<<"$obj")"
    prompt="$(jq -r '.prompt' <<<"$obj")"
    agent="$(jq -r '.agent // ""' <<<"$obj")"
    action="$(jq -r '.action // ""' <<<"$obj")"
    auto_accept=0
    if [ "$(jq -r '.autoAccept // false' <<<"$obj")" = "true" ]; then auto_accept=1; fi
    # A bare trigger on a review comment legitimately yields an empty prompt —
    # the review thread supplies the task via conversation context. Only a
    # bare CONTINUE (no answer) is not a real task.
    if [ -z "$prompt" ] && [ "$action" = "CONTINUE" ]; then continue; fi
    fullBody="$(jq -r '.fullBody // ""' <<<"$obj")"
    [ -n "$fullBody" ] || fullBody="$prompt"
    prompt="$fullBody"
    prompt="$(printf '%s' "$prompt" | sed -E 's/(^|[[:space:]])--auto([[:space:]]|$)/\1\2/g')"
    cpath="$(jq -r '.path // ""' <<<"$obj")"
    cline="$(jq -r '.line // ""' <<<"$obj")"
    chunk="$(jq -r '.diffHunk // ""' <<<"$obj")"
    esc="$(printf '%s' "$prompt" | sed "s/'/''/g")"
    esc_a="$(printf '%s' "$agent" | sed "s/'/''/g")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    raw_id="$(jq -r '.rawId // .id' <<<"$obj")"
    raw_id="${raw_id#review:}"
    reply_to="$(jq -r '.in_reply_to_id // empty' <<<"$obj")"
    if [ -n "$reply_to" ]; then
      root_id="$(get_review_thread_root_id "$review_comments" "$raw_id")"
    else
      root_id="$raw_id"
    fi
    conv_id="$(generate_conversation_id "$repo" "$pr_num" "review-thread" "$root_id")" || continue
    base_id="$id"

    if [ "$action" = "CONTINUE" ]; then
      if resume_blocked_user_task "$conv_id" "$repo" "$pr_num" "$id" "$author" "$prompt" "$created" "$url"; then
        NEW=$((NEW + 1))
        continue
      fi
      action="CONTINUE"
    fi

    ins="$(sqlite3 "$DB" "INSERT OR IGNORE INTO processed_comments(commentId,repository,issueNumber,commentUrl,author,agent,prompt,action,prNumber,status,createdAt,heartbeatAt,leaseExpiresAt,conversationId,baseId,autoAccept) VALUES('$id','$repo',$pr_num,'$url','$author','$esc_a','$esc','$action',$pr_num,'queued','$created',NULL,NULL,'$(sql_escape "$conv_id")','$base_id',$auto_accept); SELECT changes();" 2>>"$LOG")"
    if [ "${ins:-0}" -gt 0 ]; then
      NEW=$((NEW + 1))
      raw_id="$(jq -r '.rawId // .id' <<<"$obj")"
      raw_body="$(jq -r '.rawBody // .body // ""' <<<"$obj")"
      persist_conversation_message "$conv_id" "$repo" "$pr_num" "$raw_id" "$author" "$raw_body" "$url" "$created" "review-comment"
      sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$conv_id', '$(sql_escape "$repo")', $pr_num, '$url', $pr_num, 'OPEN', '$now', '$now');" 2>>"$LOG" || true
      # Review-thread context is materialized after the poll has ingested
      # all available GitHub messages for this repository.
      if [ -f "$MANUL_DIR/manul-pr-review.sh" ] && [ -n "$prompt" ]; then
        review_id="${id#review:}"
        if [ -n "$conv_id" ]; then
          sqlite3 "$DB" "INSERT OR IGNORE INTO conversation_links(conversationId, repo, prNumber, commentId, linkType, createdAt) VALUES('$conv_id', '$(sql_escape "$repo")', $pr_num, '$(sql_escape "$id")', 'review', '$now');" 2>>"$LOG" || true
        fi
      fi
      log "queued $id on $repo#$pr_num (agent=${agent:-default})"
    fi
  done < <(gh api --paginate "repos/$repo/pulls/comments?per_page=100" 2>>"$LOG" | jq -c --arg repo "$repo" --arg trig "$TRIGGER" --arg sig "$SIG" --arg base "$BASELINE" --argjson allowed "$ALLOWED_JSON" --argjson agents "$AGENTS_JSON" '
    ($trig | gsub("[\\^$.|?*+()\\[\\]{}]"; "\\\\$&")) as $trig_re
    | .[] | select((.pull_request_review_id // null) == null) | select(.created_at >= $base) | select((.body // "") | test("(^|\\r?\\n)[ \\t]*" + $trig_re + "([ \\t\\r\\n]|$)")) | select((.body // "") | contains($sig) | not) | select((.user.type // "User") != "Bot") | select(.user.login as $u | $allowed | index($u)) |
    (.body | split("\n")) as $lines
    | ([range(0; $lines|length) | select($lines[.] | test("^[ \\t]*" + $trig_re + "([ \\t]|$)"))][0]) as $idx
    | ($lines[$idx] | sub("^[ \\t]*" + $trig_re + "([ \\t]*|$)"; "")) as $rest0_raw
    | ($rest0_raw | test("(^|[ \\t])--auto([ \\t]|$)")) as $auto_accept
    | ($rest0_raw | gsub("(^|[ \\t])--auto([ \\t]|$)"; " ") | sub("^[ \\t]+"; "") | sub("[ \\t]+$"; "")) as $rest0
    | (if $rest0 == "" then ($lines[$idx+1:] | join("\n")) else ($rest0 + "\n" + ($lines[$idx+1:] | join("\n"))) end) as $rest
    | ($rest | split(" ")[0]) as $tok
    | (if ($tok != "" and ($agents | index($tok))) then $tok else "" end) as $agent
    | (if $agent == "" then $rest else ($rest | split(" ") | .[1:] | join(" ")) end) as $prompt_no_agent
    | (if $tok == "run" then
         (($rest | sub("^run([ \\t]+|$)"; "")) as $run_rest
          | if ($run_rest | test("^--agent([ \\t]+|$)")) then
              (try ($run_rest | capture("^--agent[ \\t]+(?<requested_agent>[^ \\t]+)(?:[ \\t]+(?<requested_prompt>(?s:.*)))?$"))
               catch {requested_agent:"__missing_agent__",requested_prompt:""}) as $requested
              | {action: "IMPLEMENT", prompt: ($requested.requested_prompt // ""), agent: $requested.requested_agent}
            else {action: "IMPLEMENT", prompt: ($run_rest | sub("^[ \\t]+"; "")), agent: ""}
            end)
       elif $tok == "review-fix" then {action: "REVIEW_FIX", prompt: ($rest | ltrimstr("review-fix") | sub("^[ \\t]+"; ""))}
       elif $tok == "verify" then {action: "VERIFY", prompt: ($rest | ltrimstr("verify") | sub("^[ \\t]+"; ""))}
       elif $tok == "fix-impl" then {action: "IMPLEMENT", prompt: ($rest | ltrimstr("fix-impl") | sub("^[ \\t]+"; ""))}
       elif $tok == "continue" then {action: "CONTINUE", prompt: ($rest | ltrimstr("continue") | sub("^[ \\t]+"; ""))}
       elif $agent != "" then {action: "IMPLEMENT", prompt: $prompt_no_agent, agent: $agent}
       else {action: null, prompt: $rest, agent: ""}
       end) as $actx
    | (if $actx.action != null then $actx.action else "REVIEW_FIX" end) as $action
    | {
      id: ("review:" + (.id|tostring)),
      rawId: (.id|tostring),
      rawBody: .body,
      repo: $repo,
      author: .user.login,
      created: .created_at,
      url: .html_url,
      issueNumber: (.html_url | capture("pull/(?<n>[0-9]+)").n | tonumber),
      agent: ($actx.agent // $agent),
      action: $action,
      autoAccept: $auto_accept,
      prompt: $actx.prompt,
      fullBody: (if (($actx.agent // $agent) != "") then $actx.prompt else (.body | sub("^[ \\t]*" + $trig_re + "([ \\t]*|$)"; "") | sub("^[ \\t]+"; "")) end),
      path: (.path // ""),
      line: ((.line // .original_line // "") | tostring),
      diffHunk: (.diff_hunk // ""),
      in_reply_to_id: (.in_reply_to_id // null)
    }' 2>>"$LOG" || true)

  # 2b) Submitted PR reviews: one task per review, with all its inline comments.
  # Individual comment ingestion above excludes review-associated comments so a
  # multi-comment review cannot fan out into multiple Manul tasks.
  if [ -f "$MANUL_DIR/manul-pr-review.sh" ]; then
    while IFS= read -r pr_obj; do
      [ -n "$pr_obj" ] || continue
      pr_num="$(jq -r '.number' <<<"$pr_obj")"
      [ -n "$pr_num" ] || continue
      [ -n "${OPEN_PRS[$pr_num]:-}" ] || continue

      reviews_json="$(gh api "repos/$repo/pulls/$pr_num/reviews?per_page=100" 2>>"$LOG" || echo '[]')"
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      while IFS= read -r review; do
        [ -n "$review" ] || continue
        review_id="$(jq -r '.id // empty' <<<"$review")"
        [ -n "$review_id" ] || continue
        review_state="$(jq -r '.state // empty' <<<"$review")"
        review_body="$(jq -r '.body // ""' <<<"$review")"
        review_author="$(jq -r '.user.login // "unknown"' <<<"$review")"
        review_created="$(jq -r '.submitted_at // empty' <<<"$review")"
        [ -n "$review_created" ] || review_created="$now"

        # Keep only new root comments from this review. Replies are persisted
        # separately as conversation context and must not spawn REVIEW_FIX tasks.
        review_inline_comments_json="$(filter_actionable_review_comments "$review_comments" "$review_id" 2>/dev/null)" || review_inline_comments_json='[]'
        review_inline_count="$(jq -r 'length' <<<"$review_inline_comments_json" 2>/dev/null || echo 0)"

        # Attach each thread's true root comment ID (GitHub reply endpoints
        # require a root, not a nested reply ID).
        review_inline_comments_with_roots='[]'
        while IFS= read -r inline_comment; do
          [ -n "$inline_comment" ] || continue
          inline_comment_id="$(jq -r '.id // empty' <<<"$inline_comment")"
          [ -n "$inline_comment_id" ] || continue
          inline_thread_root_id="$(get_review_thread_root_id "$review_comments" "$inline_comment_id")"
          review_inline_comments_with_roots="$(jq -cn --argjson existing "$review_inline_comments_with_roots" --argjson comment "$inline_comment" --arg root "$inline_thread_root_id" '$existing + [($comment + {manul_thread_root_id:$root})]')"
        done < <(jq -c '.[]' <<<"$review_inline_comments_json" 2>/dev/null)
        review_inline_comments_json="$review_inline_comments_with_roots"

        case "$review_state" in
          CHANGES_REQUESTED) review_handler_state="REQUEST_CHANGES" ;;
          APPROVED) review_handler_state="APPROVE" ;;
          COMMENTED) review_handler_state="COMMENT" ;;
          *) review_handler_state="" ;;
        esac

        # Keep existing REQUEST_CHANGES behavior (including recovery of older
        # active reviews). For approval/comment reviews, only start work for
        # newly submitted reviews, avoiding a backfill of historical review
        # comments on every open PR after this feature is deployed.
        should_handle_review=false
        if [ "$review_state" = "CHANGES_REQUESTED" ]; then
          should_handle_review=true
        elif [ "$review_inline_count" -gt 0 ] && [ -n "$review_handler_state" ] && [ "$review_state" != "DISMISSED" ]; then
          if [[ "$review_created" == "$BASELINE" || "$review_created" > "$BASELINE" ]]; then
            should_handle_review=true
          fi
        fi

        if [ "$should_handle_review" = true ]; then
          log "processing review $review_id on $repo#$pr_num (state=$review_state, inline_comments=$review_inline_count)"
          existing_conv="$(sqlite3 "$DB" "SELECT conversationId FROM conversations WHERE repository='$(sql_escape "$repo")' AND activePrNumber=$pr_num AND status != 'COMPLETED' LIMIT 1;" 2>/dev/null || echo "")"
          if [ -z "$existing_conv" ]; then
            pr_url="$(gh pr view "$pr_num" --repo "$repo" --json url --jq '.url' 2>/dev/null)" || pr_url="https://github.com/$repo/pull/$pr_num"
            [ -n "$pr_url" ] || pr_url="https://github.com/$repo/pull/$pr_num"
            new_conv_id="$(generate_conversation_id "$repo" "$pr_num" "pr-top-level")"
            sqlite3 "$DB" "INSERT OR IGNORE INTO conversations(conversationId, repository, issueNumber, issueUrl, activePrNumber, status, createdAt, updatedAt) VALUES('$new_conv_id', '$(sql_escape "$repo")', $pr_num, '$pr_url', $pr_num, 'OPEN', '$now', '$now');" 2>>"$LOG"
            log "auto-created conversation $new_conv_id for $repo#$pr_num"
          fi
          if "$MANUL_DIR/manul-pr-review.sh" handle \
            --repo "$repo" \
            --pr-number "$pr_num" \
            --review-id "$review_id" \
            --review-state "$review_handler_state" \
            --body "$review_body" \
            --author "$review_author" \
            --created "$review_created" \
            --review-comments-json "$review_inline_comments_json" \
            --json >>"$LOG" 2>&1; then
            log "review $review_id on $repo#$pr_num processed successfully"
          else
            log "WARN: failed to process review $review_id on $repo#$pr_num"
          fi
        elif [ "$review_state" = "APPROVED" ]; then
          log "received APPROVE on $repo#$pr_num with no eligible inline review comments (no fix task created)"
        else
          log "received $review_state review on $repo#$pr_num with no eligible inline review comments (no task created)"
        fi
      done < <(echo "$reviews_json" | jq -c '.[]' 2>/dev/null)
    done < <(gh pr list --repo "$repo" --state open --json number,headRefName,baseRefName,title,url 2>>"$LOG" | jq -c '.[]' 2>>"$LOG" || true)
  fi

  # Persist all available conversation messages first, then materialize the
  # complete conversation into every queued task. This also refreshes queued
  # tasks when new comments arrive after their original trigger.
  persist_conversation_messages_for_repo "$repo"
  refresh_queued_task_contexts_for_repo "$repo"

  # Retry any skipped comments from a previous poll run
  skip_log="$MANUL_DIR/skip-comments.log"
  if [ -f "$skip_log" ]; then
    tmp_skip="${skip_log}.tmp"
    > "$tmp_skip"
    while IFS='|' read -r srepo sissue smsg stime; do
      [ -n "$srepo" ] || continue
      if "$MANUL_DIR/feedback.sh" "$srepo" "$sissue" "$smsg" 2>>"$LOG"; then
        log "delivered pending skip comment for $srepo#$sissue (queued at $stime)"
      else
        printf '%s|%s|%s|%s\n' "$srepo" "$sissue" "$smsg" "$stime" >> "$tmp_skip"
        log "WARN: pending skip comment for $srepo#$sissue still failing, will retry next poll"
      fi
    done < "$skip_log"
    mv "$tmp_skip" "$skip_log"
  fi

  # Scan for failing CI on manul PRs
  scan_failing_ci "$repo"
}

# === Main polling logic (runs only when executed directly) ===
# Only run main logic when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ "${#REPOS[@]}" -eq 0 ] && [ "${#TASK_SOURCE_CONFIGS[@]}" -eq 0 ]; then
    echo 'MANUL_RESULT {"fire":false,"new":0,"pending":0,"repos":0}'
    exit 0
  fi

  # Prevent overlapping poll instances: acquire poll-level lock
  exec 201>"$POLL_LOCK_FILE"
  if ! flock -n 201; then
    log "poll already in progress (poll.flock held); skipping"
    PENDING="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued';" 2>/dev/null || echo 0)"
    echo "MANUL_RESULT {\"fire\":false,\"new\":0,\"pending\":$PENDING,\"locked\":true}"
    exit 0
  fi

  # Release any repo locks owned by this poll even when the shell is terminated
  # before the normal end-of-loop cleanup can run. The cleanup trap is
  # installed only after poll.flock is acquired, so the per-repo worker
  # subprocesses (which cannot acquire this lock) cannot release a parent's lock.
  ACTIVE_REPO_PID=""
  ACTIVE_REPO_LAUNCHER_PID=""

  cleanup_repo_locks() {
    # Kill an active repo worker when poll.sh is interrupted; otherwise the
    # detached setsid session can survive and keep CI pipes open.
    if [ -n "${ACTIVE_REPO_PID:-}" ]; then
      kill -TERM -- "-$ACTIVE_REPO_PID" 2>/dev/null || true
      kill -KILL -- "-$ACTIVE_REPO_PID" 2>/dev/null || true
    fi
    if [ -n "${ACTIVE_REPO_LAUNCHER_PID:-}" ]; then
      kill -TERM "$ACTIVE_REPO_LAUNCHER_PID" 2>/dev/null || true
      kill -KILL "$ACTIVE_REPO_LAUNCHER_PID" 2>/dev/null || true
    fi
    local cleanup_repo
    for cleanup_repo in "${REPOS[@]}"; do
      [ -n "$cleanup_repo" ] || continue
      release_repo_lock "$cleanup_repo"
    done
  }
  # emit_result is defined below, before the repo loop, so the signal traps can
  # call it even when they fire mid-loop (bash resolves the name at call time).
  trap 'cleanup_repo_locks; emit_result; exit 143' TERM
  trap 'cleanup_repo_locks; emit_result; exit 130' INT
  trap 'cleanup_repo_locks; emit_result; exit 129' HUP
  trap 'cleanup_repo_locks' EXIT

  emit_result() {
    # Emit the MANUL_RESULT line. Called at the normal end of the loop AND
    # from the signal traps above, so a poll.sh that is killed by an outer
    # timeout (e.g. the daemon's global POLL_TIMEOUT) still reports the
    # queued tasks it already discovered. Without this, every interrupted
    # cycle reports fire:false and the daemon never dispatches.
    # Idempotent: the EXIT trap also fires after a signal handler's exit, so
    # guard against emitting the result twice.
    if [ "${_EMITTED:-0}" = "1" ]; then
      return 0
    fi
    _EMITTED=1
    PENDING="$(sqlite3 "$DB" "SELECT COUNT(*) FROM processed_comments WHERE status='queued';" 2>/dev/null || echo 0)"

    LOCKED=0
    if [ -f "$LOCK" ]; then
      age=$(( $(date +%s) - $(stat -c %Y "$LOCK") ))
      [ "$age" -lt "$LOCK_TTL_SECONDS" ] && LOCKED=1
    fi

    if { [ "$NEW" -gt 0 ] || [ "$PENDING" -gt 0 ]; } && [ "$LOCKED" -eq 0 ]; then
      echo "MANUL_RESULT {\"fire\":true,\"new\":$NEW,\"pending\":$PENDING}"
    elif [ "$NEW" -gt 0 ] || [ "$PENDING" -gt 0 ]; then
      echo "MANUL_RESULT {\"fire\":false,\"new\":$NEW,\"pending\":$PENDING,\"locked\":true}"
    else
      echo "MANUL_RESULT {\"fire\":false,\"new\":0,\"pending\":0}"
    fi
  }

  # Run each repo in its own session/process group so a hung gh subprocess
  # cannot leak past the per-repository timeout. Return 124 on timeout.
  run_repo_with_timeout() {
    local repo="$1"
    local script
    local launcher_pid
    local pid=""
    local started
    local result=0

    script="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    started="$SECONDS"

    # --fork + --wait gives us a stable launcher we can wait on while the
    # actual worker is guaranteed to be a session/process-group leader.
    # Plain "setsid ... &" is racy: setsid may fork when its caller is already
    # a process-group leader and the $! PID can then belong to the short-lived
    # parent rather than the real worker.
    #
    # The poll.flock fd (201) is inherited by this child and, through it, by
    # the whole session it creates. If the daemon's outer timeout then SIGTERMs
    # the poll.sh parent, the flock is never released — the child session keeps
    # it alive forever and every subsequent poll cycle is skipped. Close the
    # inherited lock fd in the worker so a killed parent cannot strand the lock.
    setsid --fork --wait bash -c "exec 201>&-; source '$script'; process_repo_body \"\$1\"" _ "$repo" &
    launcher_pid=$!

    # Resolve the real session leader created by setsid --fork.
    for _ in {1..50}; do
      pid="$(ps -ww -axo pid=,ppid= 2>/dev/null | awk -v parent="$launcher_pid" '$2 == parent {print $1; exit}')"
      [ -n "$pid" ] && break
      kill -0 "$launcher_pid" 2>/dev/null || break
      sleep 0.01
    done
    pid="${pid:-$launcher_pid}"
    ACTIVE_REPO_PID="$pid"
    ACTIVE_REPO_LAUNCHER_PID="$launcher_pid"

    while kill -0 "$pid" 2>/dev/null; do
      if [ $((SECONDS - started)) -ge "$REPO_POLL_TIMEOUT" ]; then
        log "WARN: repo $repo timed out after ${REPO_POLL_TIMEOUT}s, terminating process group"
        kill -TERM -- "-$pid" 2>/dev/null || true
        kill -TERM "$launcher_pid" 2>/dev/null || true
        sleep 0.2
        kill -KILL -- "-$pid" 2>/dev/null || true
        kill -KILL "$launcher_pid" 2>/dev/null || true
        wait "$launcher_pid" 2>/dev/null || true
        ACTIVE_REPO_PID=""
        ACTIVE_REPO_LAUNCHER_PID=""
        return 124
      fi
      sleep 0.1
    done

    wait "$launcher_pid" 2>/dev/null || result=$?
    ACTIVE_REPO_PID=""
    ACTIVE_REPO_LAUNCHER_PID=""
    return "$result"
  }

  if [ "$TASK_SOURCES_EXPLICIT" -eq 1 ]; then
    poll_all_task_sources
  fi

  for repo in "${REPOS[@]}"; do
    [ -n "$repo" ] || continue

    if ! acquire_repo_lock "$repo"; then
      continue
    fi
    repo_cleanup_lock=1

    # Process this repo with a per-repository timeout. If the repo times out,
    # its lock is released and the next repo is processed immediately — no
    # starvation.
    _result=0
    run_repo_with_timeout "$repo" || _result=$?

    if [ "$_result" -eq 124 ]; then
      log "WARN: repo $repo timed out after ${REPO_POLL_TIMEOUT}s, continuing to next repo"
    elif [ "$_result" -ne 0 ]; then
      log "WARN: repo $repo processing failed with exit code $_result"
    fi

    # Release immediately after each repo. This prevents a later global poll
    # timeout from leaking the repo lock for a repository already processed.
    release_repo_lock "$repo"
  done

  # Normal completion path.
  emit_result
  exit 0
fi

