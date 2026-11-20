#!/usr/bin/env bash
# Reject proactive PR pushes when the source head or target/base changed after
# the agent started. This intentionally permits one final delivery push only.
set -euo pipefail

block_stale() {
  printf 'MANUL_PROACTIVE_PR_STALE_HEAD: %s\n' "$1" >&2
  exit 1
}
block_scope() {
  printf 'MANUL_PROACTIVE_PR_PUSH_BLOCKED: %s\n' "$1" >&2
  exit 1
}

remote_name="${1:-}"
[ "$remote_name" = "origin" ] || block_scope "push is restricted to origin"
repository="$(git config --local --get manul.proactive.repository 2>/dev/null || true)"
pr_number="$(git config --local --get manul.proactive.prNumber 2>/dev/null || true)"
branch="$(git config --local --get manul.proactive.branch 2>/dev/null || true)"
expected_head="$(git config --local --get manul.proactive.expectedHead 2>/dev/null || true)"
expected_base="$(git config --local --get manul.proactive.expectedBase 2>/dev/null || true)"
[ -n "$repository" ] && [ -n "$pr_number" ] && [ -n "$branch" ] &&
  [ -n "$expected_head" ] && [ -n "$expected_base" ] ||
  block_stale "guard snapshot is missing"

updates=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ -n "${local_ref:-}" ] || continue
  updates=$((updates + 1))
  [ "$remote_ref" = "refs/heads/$branch" ] || block_scope "push is restricted to PR branch $branch"
  [[ "$local_sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || block_scope "deleting or invalid PR branch refs are forbidden"

  current_head="$(git ls-remote --heads origin "$remote_ref" 2>/dev/null | awk 'NR==1 {print $1}')"
  [ -n "$current_head" ] || block_stale "could not read current remote PR head"
  [ "$current_head" = "$expected_head" ] || block_stale "remote PR head advanced after this task started"

  pr_snapshot="$(gh pr view "$pr_number" --repo "$repository" --json state,headRefOid,baseRefOid --jq '[.state, .headRefOid, .baseRefOid] | @tsv' 2>/dev/null)" ||
    block_stale "could not revalidate live PR head/base"
  IFS=$'\t' read -r pr_state live_head live_base <<<"$pr_snapshot"
  [ "$pr_state" = "OPEN" ] || block_stale "PR is no longer open"
  [ "$live_head" = "$expected_head" ] || block_stale "GitHub PR head changed after this task started"
  [ "$live_base" = "$expected_base" ] || block_stale "GitHub PR target/base changed after this task started"

  git merge-base --is-ancestor "$current_head" "$local_sha" 2>/dev/null ||
    block_stale "non-fast-forward pushes are forbidden for proactive PR work"
done

[ "$updates" -gt 0 ] || exit 0
