#!/usr/bin/env bash
# github-api-wrapper.sh — Centralized GitHub API integration with resilience
#
# This wrapper provides resilient GitHub API calls with:
# - Bounded retries with exponential backoff
# - Error classification (transient vs permanent)
# - Rate limit awareness and handling
# - Enhanced logging and diagnostics
# - TLS/network failure detection
#
# Usage: github-api-wrapper.sh <function> [args...]
# Functions: call, issues, issue-comments, pr-comments, branches, pulls, repo-info, rate-limit,
#           issue-comments-repo, pr-comments-repo
#
# All calls go through the same resilience mechanism for consistent error handling.

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
CONFIG="${MANUL_DIR}/config.json"
# DB on native ext4 (NOT on 9p /mnt/f)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
DB="${DB:-$MANUL_DB}"
LOG="${MANUL_DIR}/github-api.log"

# Load configuration defaults
GITHUB_MAX_RETRIES="${GITHUB_MAX_RETRIES:-5}"
GITHUB_RETRY_BASE_DELAY="${GITHUB_RETRY_BASE_DELAY:-2000}"   # milliseconds
GITHUB_RETRY_MAX_DELAY="${GITHUB_RETRY_MAX_DELAY:-16000}"    # milliseconds

# Load configuration from config.json if available
if [ -f "$CONFIG" ]; then
  GITHUB_MAX_RETRIES="$(jq -r '.retryConfig.maxAttempts // empty' "$CONFIG" 2>/dev/null || echo "$GITHUB_MAX_RETRIES")"
  GITHUB_RETRY_BASE_DELAY="$(jq -r '.retryConfig.contextStrategy == \"progressive\" ? (.retryConfig.contextLimits[0] // 240000) : ($GITHUB_RETRY_BASE_DELAY / 1000)' "$CONFIG" 2>/dev/null || echo "$GITHUB_RETRY_BASE_DELAY")"
  GITHUB_RETRY_MAX_DELAY="$(jq -r '.retryConfig.maxDelay // empty' "$CONFIG" 2>/dev/null || echo "$GITHUB_RETRY_MAX_DELAY")"
fi

log_api() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# Classify failure type and determine if it's retryable
classify_failure() {
  local error_msg="$1"
  local http_code="$2"
  
  local failure_type="network"
  local retryable=true
  
  # Check for HTTP status codes
  if echo "$error_msg" | grep -q "HTTP 4[0-9][0-9]\|HTTP 5[0-9][0-9]"; then
    http_code=$(echo "$error_msg" | grep -o "HTTP [0-9][0-9][0-9]" | head -1 | cut -d' ' -f2)
    
    case $http_code in
      401|403)
        failure_type="auth"
        retryable=false
        ;;
      404)
        failure_type="resource"
        retryable=false
        ;;
      429)
        failure_type="rate_limit"
        retryable=true
        ;;
      502|503|504)
        failure_type="github_unavailable"
        retryable=true
        ;;
      *)
        # Other HTTP errors - check if they might be transient
        if echo "$error_msg" | grep -qi "service unavailable\|temporarily.*down\|slow down"; then
          failure_type="github_unavailable"
          retryable=true
        else
          failure_type="permanent"
          retryable=false
        fi
        ;;
    esac
  fi
  
  # Check for connection-level failures
  if echo "$error_msg" | grep -q -i "TLS\|handshake.*timeout\|connection.*reset\|connection.*timeout\|network.*unreachable\|Temporary failure"; then
    failure_type="network"
    retryable=true
  fi
  
  echo "$failure_type"
  echo "$retryable"
  echo "$http_code"
}

# Calculate exponential backoff with jitter
calculate_backoff() {
  local retry_count="$1"
  local delay=$(( GITHUB_RETRY_BASE_DELAY / 1000 * (1 << retry_count) ))
  
  if [[ $delay -gt GITHUB_RETRY_MAX_DELAY ]]; then
    delay=$(( GITHUB_RETRY_MAX_DELAY / 1000 ))
  fi
  
  if [[ $delay -lt 1 ]]; then
    delay=1
  fi
  
  # Add jitter (±20%)
  local jitter=$(( delay / 5 ))
  local random_jitter=$(( RANDOM % (jitter * 2) ))
  delay=$(( delay + random_jitter - jitter ))
  
  if [[ $delay -lt 1 ]]; then
    delay=1
  fi
  
  echo $delay
}

# Enhanced GitHub API wrapper with retry logic
github_api_call() {
  local operation="$1"
  local endpoint="$2"
  local method="${3:-GET}"
  local body="${4:-}"
  local extra_args="${5:-}"
  local paginate="${6:-false}"
  
  log_api "GitHub API call: operation=$operation endpoint=$endpoint method=$method"
  
  local retry_count=0
  local success=false
  local response
  
  while [[ $retry_count -le GITHUB_MAX_RETRIES ]] && ! $success; do
    local start_time end_time elapsed wait_time
    start_time=$(date +%s)
    
    # Build the gh api command
    local cmd="gh api"
    
    if [[ "$paginate" == "true" ]]; then
      cmd+=" --paginate"
    fi
    
    cmd+=" --method $method \"$endpoint\""
    
    if [[ -n "$body" ]]; then
      cmd+=" --input - <<< \"$body\""
    fi
    
    if [[ -n "$extra_args" ]]; then
      cmd+=" $extra_args"
    fi
    
    # Execute with timeout
    response=$(timeout 30 bash -c "$cmd 2>&1" || echo "TIMEOUT_ERROR")
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    
    if echo "$response" | grep -q "TIMEOUT_ERROR\|command not found\|gh: command not found"; then
      # CLI-level error (not API error)
      log_api "GitHub CLI error: $response"
      echo "{}"
      return 1
    fi
    
    # Check for GitHub API errors
    local http_code=""
    local failure_type
    local retryable
    
    if echo "$response" | grep -q "HTTP 4[0-9][0-9]\|HTTP 5[0-9][0-9]"; then
      http_code=$(echo "$response" | grep -o "HTTP [0-9][0-9][0-9]" | head -1 | cut -d' ' -f2)
      
      # Check for rate limit
      if [[ "$http_code" == "429" ]]; then
        local retry_after
        retry_after=$(echo "$response" | grep -i "Retry-After" | head -1 | cut -d' ' -f2)
        if [[ -n "$retry_after" ]]; then
          sleep "$retry_after"
          ((retry_count++))
          continue
        fi
      fi
      
      # Classify failure
      failure_type=$(echo "$response" | xargs -I {} bash -c 'echo "{}"' | classify_failure "$response" "$http_code" | sed -n '1p')
      retryable=$(echo "$response" | xargs -I {} bash -c 'echo "{}"' | classify_failure "$response" "$http_code" | sed -n '2p')
    else
      # Network/connection error
      failure_type=$(echo "$response" | xargs -I {} bash -c 'echo "{}"' | classify_failure "$response" "" | sed -n '1p')
      retryable=$(echo "$response" | xargs -I {} bash -c 'echo "{}"' | classify_failure "$response" "" | sed -n '2p')
      http_code=""
    fi
    
    if [[ "$retryable" == "true" ]]; then
      if (( retry_count >= GITHUB_MAX_RETRIES )); then
        log_api "GitHub API request failed after $max_retries attempts: operation=$operation reason=$failure_type http=$http_code"
        echo "{}"
        return 1
      fi
      
      wait_time=$(calculate_backoff $retry_count)
      local remaining=$((wait_time - elapsed))
      if [[ $remaining -gt 0 ]]; then
        log_api "GitHub API request failed: operation=$operation attempt=$((retry_count + 1))/$max_retries reason=$failure_type http=$http_code, retrying in ${remaining}s"
        sleep $remaining
      fi
      
      ((retry_count++))
    else
      log_api "GitHub API request failed (permanent): operation=$operation reason=$failure_type http=$http_code"
      echo "{}"
      return 1
    fi
  done
  
  # Success - parse JSON if possible
  if echo "$response" | grep -q "^{\|^\["; then
    echo "$response" | jq -c . 2>/dev/null || echo "$response"
  else
    echo "$response"
  fi
}

# Wrapper functions for common operations

github_api_issues() {
  local repo="$1"
  local since="$2"
  github_api_call "poll_issues" "repos/$repo/issues?state=open&since=$since&per_page=100" "GET" "" "" "true"
}

github_api_issue_comments() {
  local repo="$3"
  local issue_number="$2"
  github_api_call "poll_issue_comments" "repos/$repo/issues/$issue_number/comments?per_page=100" "GET" "" "" "true"
}

github_api_pr_comments() {
  local repo="$3"
  local pr_number="$2"
  github_api_call "poll_pr_comments" "repos/$repo/pulls/$pr_number/comments?per_page=100" "GET" "" "" "true"
}

# Repository-wide issue comments (includes PR review comments and issue comments)
github_api_issue_comments_repo() {
  local repo="$1"
  github_api_call "poll_issue_comments_repo" "repos/$repo/issues/comments?per_page=100" "GET" "" "" "true"
}

# Repository-wide PR comments (review comments on PRs)
github_api_pr_comments_repo() {
  local repo="$1"
  github_api_call "poll_pr_comments_repo" "repos/$repo/pulls/comments?per_page=100" "GET" "" "" "true"
}

github_api_branches() {
  local repo="$1"
  github_api_call "get_branches" "repos/$repo/branches" "GET" "" "" "false"
}

github_api_pulls() {
  local repo="$1"
  github_api_call "get_pulls" "repos/$repo/pulls?state=open&per_page=100" "GET" "" "" "true"
}

github_api_repo_info() {
  local repo="$1"
  github_api_call "get_repo_info" "repos/$repo" "GET" "" "" "false"
}

github_api_rate_limit() {
  github_api_call "rate_limit" "rate_limit" "GET" "" "" "false" | grep -o '"rate":{[^}]*}' | jq .rate 2>/dev/null || echo '{}'
}

# Main dispatch function
main() {
  local func="$1"
  shift
  
  case "$func" in
    "call")
      github_api_call "$@"
      ;;
    "issues")
      github_api_issues "$@"
      ;;
    "issue-comments")
      github_api_issue_comments "$@"
      ;;
    "pr-comments")
      github_api_pr_comments "$@"
      ;;
    "issue-comments-repo")
      github_api_issue_comments_repo "$@"
      ;;
    "pr-comments-repo")
      github_api_pr_comments_repo "$@"
      ;;
    "branches")
      github_api_branches "$@"
      ;;
    "pulls")
      github_api_pulls "$@"
      ;;
    "repo-info")
      github_api_repo_info "$@"
      ;;
    "rate-limit")
      github_api_rate_limit "$@"
      ;;
    *)
      echo "Usage: $0 <function> [args...]" >&2
      echo "Functions: call, issues, issue-comments, pr-comments, issue-comments-repo, pr-comments-repo, branches, pulls, repo-info, rate-limit"
      return 1
      ;;
  esac
}

# Execute if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi