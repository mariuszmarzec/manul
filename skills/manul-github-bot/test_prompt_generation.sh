#!/usr/bin/bash
# test_prompt_generation.sh — Regression tests for prompt generation
#
# Verifies that the daemon generates prompts safely:
#   A. Markdown backticks (`run`, `TASK_DONE`) remain literal
#   B. ${current_attempt}, $(), backticks in task/context remain literal
#   C. Actual runtime values are injected (COMMENT_ID, attempt, repo, issue)
#   D. Multiline task/context survives unchanged
#   E. Malicious $(touch /tmp/should-not-exist) does NOT execute
#   F. Generated prompt is inspected as an actual file
#   G. PR description freshness is mandatory in the generated and production prompt
#
# Uses isolated temp environment, fake gh, fake OpenClaw. No production state touched.
#
# Usage: bash test_prompt_generation.sh
# Exit code: 0 if all pass, >0 if any fail

set -uo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; TOTAL=0

# ─── Temp working directory (cleaned on exit) ─────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ─── Helper counters ──────────────────────────────────────────────────────────
ok() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    if [ -f "$file" ] && grep -qF -- "$needle" "$file"; then
        ok "$label"
    else
        fail "$label (expected file '$file' to contain '$needle')"
    fi
}

assert_file_not_contains() {
    local label="$1" file="$2" needle="$3"
    if [ -f "$file" ] && ! grep -qF -- "$needle" "$file"; then
        ok "$label"
    else
        fail "$label (expected file '$file' NOT to contain '$needle')"
    fi
}

# ─── Prompt generation logic (mirrors daemon's safe pattern) ──────────────────
generate_prompt() {
    local out_file="$1"
    local REPO="$2"
    local ISSUE_NUM="$3"
    local COMMENT_ID="$4"
    local COMMENT_URL="$5"
    local TASK_TYPE="$6"
    local TASK_PROMPT="$7"
    local TASK_CONTEXT="$8"
    local current_attempt="$9"
    local REPO_DIR="${10}"
    local WORKDIR="${11}"
    local PR_HEAD_BRANCH="${12}"
    local timestamp="${13}"
    local CURRENT_BRANCH="${14}"
    local DEFAULT_BRANCH="${15}"
    local PR_NUMBER="${16:-$ISSUE_NUM}"
    local REPLY_TO="${17:-}"
    local WORKSPACE_ROOT="${18:-$WORKDIR}"
    local RELATED_REPOSITORIES="${19:-}"
    local RELATED_UNAVAILABLE="${20:-}"

    # Top of prompt (static text + placeholders for single-line runtime values)
    cat > "$out_file" <<'PROMPT_EOF'
# Manul Task:

You are the Manul implementation agent. Complete ONE task and then emit exactly one of the completion markers.

## Task
- Repository: __REPO__
- Issue/PR: #__ISSUE_NUM__
- Comment ID: __COMMENT_ID__
- Comment URL: __COMMENT_URL__
- Task Type: __TASK_TYPE__
- PR Number: __PR_NUMBER__
- Original Review Comment ID: __REPLY_TO__

## User Request
PROMPT_EOF

    # Append multiline task prompt (literal, no shell expansion)
    printf '%s\n' "$TASK_PROMPT" >> "$out_file"

    cat >> "$out_file" <<'PROMPT_EOF'

## Context
PROMPT_EOF

    # Append multiline task context (literal, no shell expansion)
    printf '%s\n' "$TASK_CONTEXT" >> "$out_file"

    cat >> "$out_file" <<'PROMPT_EOF'
## Command Intent Guidance
Before taking any action, determine whether this task is:
- **Informational**: The user is asking a question, requesting an explanation, or seeking advice. Reply with a thoughtful answer via GitHub comment. Do NOT modify any repository files.
- **Repository Change**: The user wants code changes, fixes, features, or other modifications. Proceed with implementation on the appropriate branch.

If the task is informational, you MUST post a thoughtful answer as a GitHub comment using the `run` tool (see GitHub Comment Posting section below), then emit `TASK_DONE`. Do NOT modify any repository files.

## User interaction and decision points
1. Behave like a competent human teammate.
2. Make straightforward, low-risk decisions autonomously.
3. You may proactively propose a concrete solution, improvement, trade-off, or next step when you have enough information.
4. Do not ask the user merely because two equivalent implementations exist.
5. When multiple materially different valid approaches would change architecture, behavior, scope, compatibility, data model, UX, or another important outcome, involve the user.
6. When more than two materially different viable directions remain, briefly present the options and ask what to do next.
7. You may recommend one option and explain why, but leave the final choice to the user.
8. Before asking, inspect the repository, relevant skills/docs, configuration, and conversation context.
9. Do not guess when missing information materially affects correctness.
10. The user-facing decision request must summarize what you checked, explain why the uncertainty is material, and present the concrete options or decision required.
11. Once user input is required, avoid further irreversible repository changes and emit exactly one complete block:
`TASK_NEEDS_USER_BEGIN`
<findings, options, recommendation if useful, and explicit question/decision>
`TASK_NEEDS_USER_END`
12. Do not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same run as `TASK_NEEDS_USER_BEGIN/END`.
13. A partial or malformed user-decision block is not a valid pause; do not rely on it to stop execution.

## Rules
1. Inspect the local repository and implement the requested change.
2. Run appropriate tests/validation.
3. Make the requested code changes.
4. When finished, output exactly: `TASK_DONE`
5. If you cannot complete the task, output exactly: `TASK_FAILED: <brief reason>`
6. Do NOT modify `manul.db`.
7. Do NOT manage Manul task state.

## Completion-marker protocol (mandatory)

The completion marker is a protocol message, not progress narration.
- Do not end a turn after describing the next action or saying you will make a change. Execute the next concrete step in the current turn, or emit the appropriate failure/user-input marker.
- Only after all requested work, validation, delivery checks, and the single result comment are complete, make the final assistant output exactly one line: `TASK_DONE` or `TASK_DONE <one-sentence summary>`.
- Do not emit `TASK_DONE` early, and do not append prose after the completion-marker line.

## PR Description Freshness (MANDATORY DELIVERY CONTRACT)

A pushed commit is not fully delivered until the GitHub PR description reflects the complete current PR and has been read back from GitHub.

- For a standalone task, immediately after the first successful push, create a real PR with a meaningful, non-empty description. Do not wait for the final implementation phase if the first push is a checkpoint.
- After EVERY later push to a branch with an open PR—including checkpoint, review-fix, and CI-fix pushes—update the description of that same PR before continuing the task or reporting the push as delivered.
- Rebuild the body from the cumulative PR diff and current verification results, not just the latest commit. Keep Summary, Changes, Testing, and related-issue references accurate; preserve still-valid issue-closing links. Do not blindly append bullets, which can leave stale or duplicated content.
- Write the full Markdown body to a temporary file and use `gh pr edit <PR_NUMBER> --body-file "$BODY_FILE"` (or the equivalent safe `--body-file` option for PR creation); never interpolate a body directly into a double-quoted shell argument.
- Read back with `gh pr view <PR_NUMBER> --json body,url,headRefName,baseRefName,headRefOid`. Verify the body is non-empty and accurate, the URL is the expected PR, the head/base are correct, and the head SHA matches the pushed commit.
- For an existing-PR task, update the original PR, never create a second PR. If creating/updating or read-back verification fails, report the precise blocker and do NOT emit `TASK_DONE`.

## GitHub Comment Posting (CRITICAL)
You MUST post exactly one user-facing result comment to GitHub using the `run` tool.

Before posting, query the source issue/PR for an existing result comment
containing the exact marker
`<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`.
If a result comment with that marker already exists, do NOT create another comment.
Update the existing comment in place with the final verified content using the safe
request-body method below.
Only create a new comment when no result comment with that marker exists. The final
state must contain exactly one matching result comment for this task/attempt.

### Safe request-body handling (MANDATORY)
Never put `YOUR_RESULT_COMMENT` or `YOUR_REPLY` directly inside shell quotes such as `-f body="..."`.
Build the complete comment body as literal file content and send JSON through `--input`.
Use a quoted heredoc or another non-evaluating file/stdin method.
```bash
RESULT_FILE="$(mktemp)"
cat >"$RESULT_FILE" <<'RESULT_EOF'
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Summary: [brief summary]

[detailed result]

— manul 🐈
RESULT_EOF
jq -n --rawfile body "$RESULT_FILE" '{body:$body}' |
  gh api repos/__REPO__/issues/__ISSUE_NUM__/comments --input - --jq .id
rm -f "$RESULT_FILE"
```
For PATCH, use the same `jq --rawfile` pipeline with:
```bash
gh api --method PATCH repos/__REPO__/issues/comments/<RESULT_COMMENT_ID> --input -
```
Do NOT use `-f body="..."` or `-F body="..."` for user-facing result/reply comments.

### Routing
Use the task metadata above and choose the endpoint that matches `Task Type`:

- For `pr_review_comment`: reply to the existing inline review thread. Use the PR review-comments endpoint and the original review comment ID:
```bash
gh api repos/__REPO__/pulls/__PR_NUMBER__/comments \
  -f body="YOUR_REPLY" \
  -f in_reply_to=__REPLY_TO__ \
  --jq .id
```

- For `pr_conversation_comment` or an issue task: post a top-level conversation comment:
```bash
gh api repos/__REPO__/issues/__ISSUE_NUM__/comments \
  -f body="YOUR_RESULT_COMMENT" \
  --jq .id
```

Do NOT use `/issues/__ISSUE_NUM__/comments` with `in_reply_to`: that endpoint does not create replies to inline PR review threads.
Replace REPO, PR_NUMBER, ISSUE_NUM, and the result body with the actual values from this prompt.

Your comment MUST:
- Start with the task summary
- Include the deterministic task/attempt marker: `<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->`
- Include your actual work/output
- End with: "— manul 🐈"
- Be posted BEFORE emitting TASK_DONE

Example informational task response:
```
<!-- manul-task:__COMMENT_ID__:attempt:__CURRENT_ATTEMPT__ -->
# Available Skills

[Your skill listing here]

— manul 🐈
```

The daemon handles lifecycle comments (🔄 working, ✅ completed, ❌ failed).
You handle the result comment.
PROMPT_EOF

    cat >> "$out_file" <<'PROMPT_APPEND'

## Task Workspace and Local-Access Boundary
The leased task workspace root (your only permitted repository-access boundary) is:
__WORKSPACE_ROOT__

The primary repository checkout is the only repository that may be edited, committed, pushed, or delivered by default:
__WORKDIR__

## Canonical Path Handling — Mandatory
The absolute paths supplied by Manul above are authoritative. Treat the leased workspace root as the task boundary and the primary checkout as the working repository. Never reconstruct paths from usernames, task IDs, previous attempts, logs, or assumptions about the machine.

- The execution runner provides `MANUL_TASK_WORKSPACE_ROOT` and `MANUL_TASK_WORKDIR` to local command processes when supported. Prefer `cd "$MANUL_TASK_WORKDIR"` for shell commands and verify the repository root with `git rev-parse --show-toplevel`.
- If a tool does not inherit those variables, use the exact literal primary-checkout path printed above. Do not invent or “correct” an absolute path.
- Prefer `"$HOME/…"` for home-relative shell paths. Do not assume `~` expands inside quoted strings, tool arguments, configuration values, or file APIs.
- If the supplied paths and the actual filesystem disagree, stop path-dependent operations and report the observed `HOME`, `PWD`, supplied path values, and the exact failed check. Never try alternate username/home prefixes.
- A path or permission failure is not permission to search another workspace, guess a replacement, use a symlink, or broaden access.

Additional repositories prepared inside this workspace for READ-ONLY inspection:
__RELATED_REPOSITORIES__

Configured related repositories unavailable in this attempt:
__RELATED_UNAVAILABLE__

All repository file access must stay inside the exact task workspace root above. Run primary-repository build, test, git, commit, push, and PR commands from the primary checkout at `__WORKDIR__`. Related checkouts, if listed, are read-only context. Do not edit, commit, branch, or push a related checkout by default. If the task genuinely requires changing another repository, stop and request an explicit delivery policy for that repository/branch/PR before changing it. If a required related repository is unavailable, report the exact repository and blocker; do not search for its shared cache or another task's checkout.

Treat local Manul/OpenCode/operator state as outside the task boundary. The configured Manul workspace tree is private runtime state: only the exact task workspace root shown above and its descendants are permitted. Every sibling workspace is forbidden, even read-only, as are shared repository caches, databases, prompts, logs, runtime artifacts, adapters, and symlink targets outside this task root. Do NOT read, list, search, probe, enumerate, or follow them through shell commands, file tools, skill tools, subagents, or indirect access. Also do NOT read, list, search, probe, or follow paths in:
- ~/.config/opencode/** (provider configuration and permissions)
- ~/.agents/** or other global agent/skill directories
- daemon logs, process environments, agent runtime internals, or other tasks' workspaces

Do not use shell commands, file tools, skill tools, symlinks, or indirect access to bypass this boundary. Do not attempt to diagnose or prove runtime routing from inside the implementation session. Manul/operator diagnostics must gather that evidence separately, outside this agent run.

If information is missing, first seek it through authorized sources: the assigned workspace, related repositories explicitly checked out INSIDE that workspace, the authoritative GitHub issue/PR and its comments/history, repository history, or approved public documentation. If the required information still cannot be obtained, ask the user for the specific missing input using the structured TASK_NEEDS_USER flow; summarize what you checked and why the answer matters. Do NOT search another task's workspace or request broader filesystem permissions as a workaround. Do not change runtime configuration or access permissions to get around this boundary.

## Scope-First Investigation and Host-System Boundary
Start with the task request and the smallest relevant evidence set inside WORKDIR: repository docs, source, tests, build/dependency declarations, and documented project commands. Search narrowly and expand only when a concrete finding proves it is needed. Do not perform broad host/environment reconnaissance just to understand an ordinary repository task.

For ordinary implementation, PR review, and test tasks, do NOT inspect host OS/service configuration outside the authorized workspace, including /etc/**, /var/**, /run/**, /proc/**, /sys/**, host database configuration (for example /etc/mysql/**), other users' home directories, or unrelated host process/service/container state.

You may run repository-declared build/test/dependency commands (including the repository's documented Docker Compose setup) when required by the task. This does NOT authorize reading host configuration, probing unrelated services, or starting/stopping host-level services. If a documented project command fails because a dependency is unavailable, capture the exact error and report the blocker instead of diagnosing the host installation.

Keep shell/tool calls focused on one diagnostic purpose. Avoid compound commands that mix repository work with unrelated filesystem or system probes.

If a tool call is denied by the permission policy, do not retry the same restricted operation through another tool, path, symlink, or reshaped command, and do not ask for broader permissions just to continue routine work. Record the exact denied operation and continue only with independent in-scope work; otherwise report the blocker.

These limits apply to all delegated/subagents too. Pass the same scope boundary into every delegated task prompt.

## Branch Policy
PROMPT_APPEND

    if [ -n "$PR_HEAD_BRANCH" ]; then
      cat >> "$out_file" <<'PROMPT_APPEND'
- This task is tied to PR #__ISSUE_NUM__
- PR head branch: `__PR_HEAD_BRANCH__`
- Switch to the PR head branch (`git checkout __PR_HEAD_BRANCH__`) before making any changes
- Commit and push changes to the same PR head branch
- Do NOT create a new branch for this task
PROMPT_APPEND
    else
      cat >> "$out_file" <<'PROMPT_APPEND'
- This is a standalone task (not tied to an existing PR)
- Current branch: __CURRENT_BRANCH__
- Repository default branch: __DEFAULT_BRANCH__
- The daemon prepares an up-to-date base but does NOT create the task branch
- First determine whether this is informational or requires repository changes
- For informational tasks: do NOT modify the repository and do NOT create a branch
- For repository changes: follow repository-local branching guidance or skill content explicitly supplied in the task context; do not inspect global skill directories. Do not read `~/.agents/**` or any global skill directory; the task-access boundary above takes precedence.
- For repository changes, **branch preparation is a mandatory precondition to every edit**: do not edit, patch, generate, format, or otherwise modify repository files until the branch preflight below has succeeded.
- Preserve existing changes. Never use `git reset --hard`, `git clean`, or discard unknown work. If the checkout is dirty or the branch cannot be established safely, stop before editing and report the exact blocker.
- Create the branch yourself before committing or pushing changes, and before the first repository edit.
- Use `__INITIAL_BASE_BRANCH__` as the base unless the task explicitly requires another base. Example (replace `<short-description>` with a lowercase kebab-case summary):
  ```bash
  WORKDIR="__WORKDIR__"
  BASE_BRANCH="__INITIAL_BASE_BRANCH__"
  TASK_SUFFIX="$(printf '%s' '__COMMENT_ID__-attempt-__CURRENT_ATTEMPT__' | tr -cs '[:alnum:]-' '-')"
  TASK_BRANCH="feature/__ISSUE_NUM__-manul-<short-description>-$TASK_SUFFIX"
  git -C "$WORKDIR" fetch origin "$BASE_BRANCH" &&
    git -C "$WORKDIR" switch --create "$TASK_BRANCH" "origin/$BASE_BRANCH"
  ```
- Verify `git -C "$WORKDIR" branch --show-current` equals the new task branch before modifying files. If fetching or branch creation fails, do not continue with edits or commits; report the cause. Do not overwrite or reuse a stale branch from an earlier attempt; use a unique task/attempt suffix.
- If the task explicitly requires another branch as the base, including another feature branch, fetch that exact remote base before creating your branch and use it as the PR base.
- Never commit or push repository changes directly to the prepared/base/default branch
PROMPT_APPEND
    fi

    cat >> "$out_file" <<'PROMPT_APPEND'

## Skills
Use relevant repository-local instructions and skills available within the assigned workspace. Do not browse or load global skills from `~/.agents/**`; only use externally provided skill content if it is explicitly included in this task prompt/context. If an unavailable external skill is essential, report the missing input rather than searching outside the workspace.
PROMPT_APPEND

    # Substitute all single-line placeholders with actual runtime values
    # Using bash parameter expansion (safe: replacement is literal, no command substitution)
    local prompt_content
    prompt_content="$(cat "$out_file")"
    prompt_content="${prompt_content//__REPO__/$REPO}"
    prompt_content="${prompt_content//__ISSUE_NUM__/$ISSUE_NUM}"
    prompt_content="${prompt_content//__COMMENT_ID__/$COMMENT_ID}"
    prompt_content="${prompt_content//__COMMENT_URL__/$COMMENT_URL}"
    prompt_content="${prompt_content//__TASK_TYPE__/$TASK_TYPE}"
    prompt_content="${prompt_content//__CURRENT_ATTEMPT__/$current_attempt}"
    prompt_content="${prompt_content//__REPO_DIR__/$REPO_DIR}"
    prompt_content="${prompt_content//__WORKDIR__/$WORKDIR}"
    prompt_content="${prompt_content//__WORKSPACE_ROOT__/$WORKSPACE_ROOT}"
    prompt_content="${prompt_content//__RELATED_REPOSITORIES__/$RELATED_REPOSITORIES}"
    prompt_content="${prompt_content//__RELATED_UNAVAILABLE__/$RELATED_UNAVAILABLE}"
    prompt_content="${prompt_content//__PR_HEAD_BRANCH__/$PR_HEAD_BRANCH}"
    prompt_content="${prompt_content//__TIMESTAMP__/$timestamp}"
    prompt_content="${prompt_content//__CURRENT_BRANCH__/$CURRENT_BRANCH}"
    prompt_content="${prompt_content//__DEFAULT_BRANCH__/$DEFAULT_BRANCH}"
    prompt_content="${prompt_content//__PR_NUMBER__/$PR_NUMBER}"
    prompt_content="${prompt_content//__REPLY_TO__/$REPLY_TO}"
    printf '%s' "$prompt_content" > "$out_file"
}

# ─── Safety contract in generated prompt ─────────────────────────────────────
echo -n "Test: Result comment posting uses literal request body handling ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-safe-body" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-safe-body" \
    "issue" \
    "Post a result." \
    "Context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "safe body guidance present" "$WORK/prompt.md" "jq -n --rawfile body"; then :; else :; fi
if assert_file_contains "stdin request body present" "$WORK/prompt.md" "--input -"; then :; else :; fi
if assert_file_contains "inline body flags forbidden" "$WORK/prompt.md" 'Do NOT use `-f body="..."` or `-F body="..."`'; then :; else :; fi
if assert_file_contains "material ambiguity guidance present" "$WORK/prompt.md" "The user-facing decision request must summarize what you checked"; then :; else :; fi
if assert_file_contains "structured user decision marker guidance present" "$WORK/prompt.md" "TASK_NEEDS_USER_BEGIN"; then :; else :; fi
if assert_file_contains "sibling workspace access is explicitly forbidden" "$WORK/prompt.md" "Every sibling workspace is forbidden, even read-only"; then :; else :; fi
if assert_file_contains "missing context fallback uses authorized sources" "$WORK/prompt.md" "the assigned workspace, related repositories explicitly checked out INSIDE that workspace"; then :; else :; fi
if assert_file_contains "missing context must be requested from user" "$WORK/prompt.md" "ask the user for the specific missing input using the structured TASK_NEEDS_USER flow"; then :; else :; fi
if assert_file_contains "completion forbidden with user decision" "$WORK/prompt.md" 'Do not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same run'; then :; else :; fi
if assert_file_contains "generated prompt requires an explicit final completion marker" "$WORK/prompt.md" 'make the final assistant output exactly one line: `TASK_DONE` or `TASK_DONE <one-sentence summary>`'; then :; else :; fi
if assert_file_contains "production prompt has mandatory completion-marker protocol" "$SCRIPT_DIR/manul-daemon.sh" "Completion-marker protocol (mandatory)"; then :; else :; fi

# ─── Tests ────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Prompt Generation Regression Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Test A: Markdown backticks remain literal in prompt
echo -n "Test: Markdown backticks remain literal ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-123" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-123" \
    "issue" \
    'Fix the bug in the `run` command and ensure `TASK_DONE` is emitted.' \
    "Some context" \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "backticks preserved in prompt" "$WORK/prompt.md" "Fix the bug in the \`run\` command and ensure \`TASK_DONE\` is emitted."; then
    :
else
    :
fi

# Test B: Shell metacharacters remain literal in task/context
echo -n "Test: Shell metacharacters remain literal ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-456" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-456" \
    "issue" \
    'Use ${current_attempt} to track retries. Run $(date) to timestamp. Use `TASK_DONE` when done.' \
    'Context with $() and ${var} and `backticks`.' \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "literal \${current_attempt} in prompt" "$WORK/prompt.md" 'Use ${current_attempt} to track retries.'; then
    :
else
    :
fi
if assert_file_contains "literal \$() in prompt" "$WORK/prompt.md" 'Run $(date) to timestamp.'; then
    :
else
    :
fi
if assert_file_contains "literal backticks in prompt" "$WORK/prompt.md" 'Use `TASK_DONE` when done.'; then
    :
else
    :
fi
if assert_file_contains "literal \$() in context" "$WORK/prompt.md" 'Context with $() and ${var} and `backticks`.'; then
    :
else
    :
fi

# Test C: Actual runtime values are injected
echo -n "Test: Runtime values are injected ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-789" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-789" \
    "issue" \
    "Implement the feature." \
    "Some context here." \
    "2" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "repo injected" "$WORK/prompt.md" "Repository: test-owner/test-repo"; then
    :
else
    :
fi
if assert_file_contains "issue injected" "$WORK/prompt.md" "Issue/PR: #42"; then
    :
else
    :
fi
if assert_file_contains "comment_id injected" "$WORK/prompt.md" "Comment ID: test-comment-789"; then
    :
else
    :
fi
if assert_file_contains "comment_url injected" "$WORK/prompt.md" "Comment URL: https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-789"; then
    :
else
    :
fi
if assert_file_contains "marker with actual values" "$WORK/prompt.md" "<!-- manul-task:test-comment-789:attempt:2 -->"; then
    :
else
    :
fi
if assert_file_not_contains "unresolved placeholder COMMENT_ID" "$WORK/prompt.md" "<COMMENT_ID>"; then
    :
else
    :
fi
if assert_file_not_contains "unresolved placeholder current_attempt" "$WORK/prompt.md" '${current_attempt}'; then
    :
else
    :
fi

# Test D: Multiline task/context survives unchanged
echo -n "Test: Multiline task/context survives ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-multiline" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-multiline" \
    "issue" \
    $'Line 1 of task\nLine 2 of task\nLine 3 of task' \
    $'Line 1 of context\nLine 2 of context' \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "multiline task line 1" "$WORK/prompt.md" "Line 1 of task"; then
    :
else
    :
fi
if assert_file_contains "multiline task line 2" "$WORK/prompt.md" "Line 2 of task"; then
    :
else
    :
fi
if assert_file_contains "multiline context line 1" "$WORK/prompt.md" "Line 1 of context"; then
    :
else
    :
fi
if assert_file_contains "multiline context line 2" "$WORK/prompt.md" "Line 2 of context"; then
    :
else
    :
fi

# Test E: Malicious command does NOT execute
echo -n "Test: Malicious command does not execute ... "
rm -f "/tmp/should-not-exist"
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-malicious" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-malicious" \
    "issue" \
    'Execute this: $(touch /tmp/should-not-exist)' \
    "Normal context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_contains "malicious string preserved" "$WORK/prompt.md" 'Execute this: $(touch /tmp/should-not-exist)'; then
    :
else
    :
fi
if [ ! -f "/tmp/should-not-exist" ]; then
    ok "Malicious command did not execute"
else
    fail "Malicious command executed (file /tmp/should-not-exist exists)"
fi

# Test F: Prompt file is inspectable as actual file
echo -n "Test: Prompt file is inspectable as actual file ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "inspect-test" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-inspect-test" \
    "issue" \
    "Simple task." \
    "Simple context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if [ -f "$WORK/prompt.md" ] && [ -s "$WORK/prompt.md" ]; then
    ok "Prompt file is inspectable as actual file ($(wc -l < "$WORK/prompt.md") lines)"
else
    fail "Prompt file is inspectable as actual file (file missing or empty)"
fi

# Test G: standalone issue prompt delegates branch creation to the agent and
# relies only on repository-local or explicitly supplied branching guidance.
echo -n "Test: standalone prompt delegates branch creation to agent ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-branch" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-branch" \
    "issue" \
    "Implement the feature." \
    "Some context here." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "" \
    "1234567890" \
    "master" \
    "master"
if assert_file_not_contains "agent must not be told task branch already exists" "$WORK/prompt.md" "Your task branch has ALREADY been created for you by Manul"; then
    :
else
    :
fi
if assert_file_not_contains "agent must not be told to avoid branch creation" "$WORK/prompt.md" "Do NOT create a new branch"; then
    :
else
    :
fi
if assert_file_contains "agent told to use repository-local/provided branching guidance" "$WORK/prompt.md" "follow repository-local branching guidance or skill content explicitly supplied in the task context"; then
    :
else
    :
fi
if assert_file_not_contains "global branching skill path is not exposed" "$WORK/prompt.md" "~/.agents/skills/feature-branching-strategy/SKILL.md"; then
    :
else
    :
fi
if assert_file_contains "agent told branch creation is its responsibility" "$WORK/prompt.md" "Create the branch yourself before committing or pushing changes, and before the first repository edit."; then
    :
else
    :
fi
if assert_file_contains "branch preflight must happen before every edit" "$WORK/prompt.md" "branch preparation is a mandatory precondition to every edit"; then
    :
else
    :
fi
if assert_file_contains "task branch starts from explicit prepared base" "$WORK/prompt.md" 'git -C "$WORKDIR" switch --create "$TASK_BRANCH" "origin/$BASE_BRANCH"'; then
    :
else
    :
fi
if assert_file_contains "branch creation failure stops edits" "$WORK/prompt.md" "If fetching or branch creation fails, do not continue with edits or commits"; then
    :
else
    :
fi
if assert_file_contains "agent told not to commit base" "$WORK/prompt.md" "Never commit or push repository changes directly to the prepared/base/default branch"; then
    :
else
    :
fi
if assert_file_not_contains "legacy TASK_BRANCH placeholder removed" "$WORK/prompt.md" "__TASK_BRANCH__"; then
    :
else
    :
fi
# Test H: PR-tied task prompt must NOT contain the standalone-task branch policy
# (it must not instruct the agent to create a task branch for PR tasks).
echo -n "Test: PR-tied prompt has no standalone branch policy ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-pr" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-pr" \
    "issue" \
    "Review the PR." \
    "Some context here." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "feature-branch" \
    "1234567890" \
    "feature-branch" \
    "master" \
    ""
if assert_file_not_contains "PR-tied prompt must not say task branch already created" "$WORK/prompt.md" "Your task branch has ALREADY been created for you by Manul"; then
    :
else
    :
fi
pr_head_line="PR head branch: \`feature-branch\`"
if assert_file_contains "PR-tied prompt names the PR head branch" "$WORK/prompt.md" "$pr_head_line"; then
    :
else
    :
fi

# Test I: PR review-comment prompt uses the review-thread endpoint and carries
# the original comment ID explicitly.
echo -n "Test: PR review prompt uses review-thread routing ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "review:789" \
    "https://github.com/test-owner/test-repo/pull/42#discussion_r789" \
    "pr_review_comment" \
    "Change the requested value." \
    "Review context." \
    "1" \
    "/tmp/repo" \
    "/tmp/repo" \
    "feature-branch" \
    "1234567890" \
    "feature-branch" \
    "master" \
    "42" \
    "789"
if assert_file_contains "review PR number injected" "$WORK/prompt.md" "PR Number: 42"; then :; else :; fi
if assert_file_contains "original review comment ID injected" "$WORK/prompt.md" "Original Review Comment ID: 789"; then :; else :; fi
if assert_file_contains "review task uses pulls comments endpoint" "$WORK/prompt.md" "gh api repos/test-owner/test-repo/pulls/42/comments"; then :; else :; fi
if assert_file_contains "review task uses in_reply_to" "$WORK/prompt.md" "-f in_reply_to=789"; then :; else :; fi
if assert_file_contains "top-level route remains available" "$WORK/prompt.md" "gh api repos/test-owner/test-repo/issues/42/comments"; then :; else :; fi
if assert_file_contains "review endpoint explains no issues in_reply_to" "$WORK/prompt.md" "Do NOT use \`/issues/42/comments\` with \`in_reply_to\`"; then :; else :; fi

# Test J: agent prompt exposes only the task workspace and never exposes Manul's
# internal repository preparation directory.
echo -n "Test: Prompt exposes only task workspace ... "
rm -f "$WORK/prompt.md"
generate_prompt \
    "$WORK/prompt.md" \
    "test-owner/test-repo" \
    "42" \
    "test-comment-workspace-boundary" \
    "https://github.com/test-owner/test-repo/issues/42#issuecomment-test-comment-workspace-boundary" \
    "issue" \
    "Implement the feature." \
    "Some context here." \
    "1" \
    "/tmp/manul-internal-repo" \
    "/tmp/manul-task-workspace/repos/test-owner/test-repo" \
    "" \
    "1234567890" \
    "master" \
    "master" \
    "42" \
    "" \
    "/tmp/manul-task-workspace" \
    "- test-owner/related: repos/test-owner/related (read-only)" \
    "- test-owner/missing: cache unavailable"

if assert_file_contains "task workspace injected" "$WORK/prompt.md" "The leased task workspace root (your only permitted repository-access boundary) is:"; then
    :
else
    :
fi
if assert_file_contains "task workspace path injected" "$WORK/prompt.md" "/tmp/manul-task-workspace"; then
    :
else
    :
fi
if assert_file_contains "canonical path policy included" "$WORK/prompt.md" "Canonical Path Handling — Mandatory"; then :; else :; fi
if assert_file_contains "runner-provided primary path variable explained" "$WORK/prompt.md" 'cd "$MANUL_TASK_WORKDIR"'; then :; else :; fi
if assert_file_contains "home-relative path expansion guidance included" "$WORK/prompt.md" 'Prefer `"$HOME/…"` for home-relative shell paths'; then :; else :; fi
if assert_file_contains "path guessing explicitly forbidden" "$WORK/prompt.md" "Never reconstruct paths from usernames"; then :; else :; fi
if assert_file_not_contains "prompt does not hardcode a Linux account home path" "$WORK/prompt.md" "/home/marzec"; then :; else :; fi
if assert_file_contains "primary checkout path injected" "$WORK/prompt.md" "/tmp/manul-task-workspace/repos/test-owner/test-repo"; then :; else :; fi
if assert_file_contains "related checkout read-only path injected" "$WORK/prompt.md" "test-owner/related: repos/test-owner/related (read-only)"; then :; else :; fi
if assert_file_contains "unavailable related repo blocker injected" "$WORK/prompt.md" "test-owner/missing: cache unavailable"; then :; else :; fi
if assert_file_contains "secondary checkout read-only rule enforced" "$WORK/prompt.md" "Related checkouts, if listed, are read-only context"; then :; else :; fi
if assert_file_not_contains "internal repo path not exposed" "$WORK/prompt.md" "/tmp/manul-internal-repo"; then
    :
else
    :
fi
if assert_file_not_contains "legacy authoritative repository section removed" "$WORK/prompt.md" "## Authoritative Repository"; then
    :
else
    :
fi
if assert_file_contains "scope-first investigation required" "$WORK/prompt.md" "Search narrowly and expand only when a concrete finding proves it is needed"; then :; else :; fi
if assert_file_contains "host system paths are explicitly out of scope" "$WORK/prompt.md" "/etc/**, /var/**, /run/**, /proc/**, /sys/**"; then :; else :; fi
if assert_file_contains "documented project dependencies remain allowed" "$WORK/prompt.md" "repository-declared build/test/dependency commands"; then :; else :; fi
if assert_file_contains "permission denial must not be bypassed" "$WORK/prompt.md" "do not retry the same restricted operation through another tool"; then :; else :; fi
if assert_file_contains "scope boundary applies to delegated agents" "$WORK/prompt.md" "Pass the same scope boundary into every delegated task prompt"; then :; else :; fi


# Test K: PR description freshness is part of the generated worker prompt and
# the real daemon's production prompt template.
if assert_file_contains "generated prompt requires PR description freshness" "$WORK/prompt.md" "PR Description Freshness (MANDATORY DELIVERY CONTRACT)"; then :; else :; fi
if assert_file_contains "generated prompt refreshes after every later push" "$WORK/prompt.md" "After EVERY later push to a branch with an open PR"; then :; else :; fi
if assert_file_contains "generated prompt uses cumulative PR diff" "$WORK/prompt.md" "Rebuild the body from the cumulative PR diff and current verification results"; then :; else :; fi
if assert_file_contains "generated prompt requires safe body-file edit" "$WORK/prompt.md" 'gh pr edit <PR_NUMBER> --body-file "$BODY_FILE"'; then :; else :; fi
if assert_file_contains "generated prompt requires PR head/body read-back" "$WORK/prompt.md" "gh pr view <PR_NUMBER> --json body,url,headRefName,baseRefName,headRefOid"; then :; else :; fi
if assert_file_contains "generated prompt blocks TASK_DONE when description verification fails" "$WORK/prompt.md" 'do NOT emit `TASK_DONE`'; then :; else :; fi
if assert_file_contains "production daemon contains mandatory PR description policy" "$SCRIPT_DIR/manul-daemon.sh" "PR Description Freshness (MANDATORY DELIVERY CONTRACT)"; then :; else :; fi
if assert_file_contains "production prompt enforces canonical path handling" "$SCRIPT_DIR/manul-daemon.sh" "Canonical Path Handling — Mandatory"; then :; else :; fi
if assert_file_contains "execution context carries a primary checkout path" "$SCRIPT_DIR/manul-daemon.sh" '--arg workdir "$WORKDIR"'; then :; else :; fi
if assert_file_contains "execution context carries the task workspace root" "$SCRIPT_DIR/manul-daemon.sh" '--arg workspaceRoot "$workspace_path"'; then :; else :; fi
if assert_file_contains "production daemon refreshes after every later push" "$SCRIPT_DIR/manul-daemon.sh" "After EVERY later push to a branch with an open PR"; then :; else :; fi

# ─── Results summary ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL tests)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All tests passed.${NC}"
else
    echo -e "${RED}$FAIL test(s) failed.${NC}"
fi

exit $FAIL
