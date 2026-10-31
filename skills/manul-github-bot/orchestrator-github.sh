#!/bin/bash
# orchestrator-github.sh - GitHub integration helpers for orchestrator
#
# Provides clean abstraction for GitHub PR/issue inspection.
# Uses `gh` CLI underneath.

set -euo pipefail

# Get PR state
get_pr_state() {
  local repo="$1"
  local pr_number="$2"
  
  gh pr view "$pr_number" --repo "$repo" --json state,number,url,title,author,mergeable,mergedAt,closedAt 2>/dev/null || echo "{}"
}

# Get PR diff
get_pr_diff() {
  local repo="$1"
  local pr_number="$2"
  
  gh pr diff "$pr_number" --repo "$repo" 2>/dev/null || echo ""
}

# Get PR comments
get_pr_comments() {
  local repo="$1"
  local pr_number="$2"
  
  gh pr view "$pr_number" --repo "$repo" --json comments 2>/dev/null | jq '.comments // []'
}

# Get PR reviews
get_pr_reviews() {
  local repo="$1"
  local pr_number="$2"
  
  gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" 2>/dev/null || echo "[]"
}

# Get PR head SHA
get_pr_head_sha() {
  local repo="$1"
  local pr_number="$2"
  
  gh pr view "$pr_number" --repo "$repo" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty'
}

# Get issue state
get_issue_state() {
  local repo="$1"
  local issue_number="$2"
  
  gh issue view "$issue_number" --repo "$repo" --json state,number,title,author,closedAt 2>/dev/null || echo "{}"
}

# Get issue comments
get_issue_comments() {
  local repo="$1"
  local issue_number="$2"
  
  gh api "repos/{owner}/{repo}/issues/${issue_number}/comments" 2>/dev/null || echo "[]"
}

# Determine if PR is merged
is_pr_merged() {
  local repo="$1"
  local pr_number="$2"
  
  local merged
  merged="$(gh pr view "$pr_number" --repo "$repo" --json mergedAt 2>/dev/null | jq -r '.mergedAt // empty')"
  
  [ -n "$merged" ]
}

# Determine if PR is open
is_pr_open() {
  local repo="$1"
  local pr_number="$2"
  
  local state
  state="$(gh pr view "$pr_number" --repo "$repo" --json state 2>/dev/null | jq -r '.state // empty')"
  
  [ "$state" = "OPEN" ]
}

# Get PR review decisions
get_pr_review_decisions() {
  local repo="$1"
  local pr_number="$2"
  
  gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" 2>/dev/null | jq '[.[] | {author: .user.login, state: .state, body: .body}]'
}

# Main dispatch
case "${1:-}" in
  get-pr-state) shift; get_pr_state "$@" ;;
  get-pr-diff) shift; get_pr_diff "$@" ;;
  get-pr-comments) shift; get_pr_comments "$@" ;;
  get-pr-reviews) shift; get_pr_reviews "$@" ;;
  get-pr-head-sha) shift; get_pr_head_sha "$@" ;;
  get-issue-state) shift; get_issue_state "$@" ;;
  get-issue-comments) shift; get_issue_comments "$@" ;;
  is-pr-merged) shift; is_pr_merged "$@" ;;
  is-pr-open) shift; is_pr_open "$@" ;;
  get-pr-review-decisions) shift; get_pr_review_decisions "$@" ;;
  *)
    echo "Usage: orchestrator-github.sh <command> [args...]" >&2
    echo "" >&2
    echo "Commands:" >&2
    echo "  get-pr-state REPO PR_NUMBER" >&2
    echo "  get-pr-diff REPO PR_NUMBER" >&2
    echo "  get-pr-comments REPO PR_NUMBER" >&2
    echo "  get-pr-reviews REPO PR_NUMBER" >&2
    echo "  get-pr-head-sha REPO PR_NUMBER" >&2
    echo "  get-issue-state REPO ISSUE_NUMBER" >&2
    echo "  get-issue-comments REPO ISSUE_NUMBER" >&2
    echo "  is-pr-merged REPO PR_NUMBER" >&2
    echo "  is-pr-open REPO PR_NUMBER" >&2
    echo "  get-pr-review-decisions REPO PR_NUMBER" >&2
    exit 3
    ;;
esac
