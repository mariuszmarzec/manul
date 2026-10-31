# Manul GitHub Control Protocol

Machine-readable protocol for external orchestrators and agents to communicate with Manul through GitHub Issues and Pull Requests.

## Overview

The protocol provides:

- command submission through `/manul` comments;
- review-driven fix tasks;
- user-input continuation;
- structured lifecycle/result events;
- Issue ↔ PR ↔ task conversation linking.

## Command grammar

Issue/PR comments beginning with `/manul` are parsed as:

| Command | Action | Description |
|---|---|---|
| `/manul run <task>` | `IMPLEMENT` | Submit an implementation task |
| `/manul run --agent <agent> <task>` | `IMPLEMENT` | Submit with a specific configured role agent |
| `/manul --auto run <task>` | `IMPLEMENT` | Run directly via OpenCode's native `opencode run --auto` mode |
| `/manul review-fix <prompt>` | `REVIEW_FIX` | Create a task for PR review feedback |
| `/manul continue <answer>` | `CONTINUE` | Resume a task blocked on user input |
| `/manul verify <prompt>` | `VERIFY` | Create a verification task |
| `/manul status` | `STATUS` | Query conversation status |
| `/manul close` | `CLOSE` | Close a conversation |

## Agent selection and runtime compatibility

Role names are taken from the configured `.agents[]` allow-list; the agent
definitions remain canonical under `~/.globalskills/agents` and are not copied
into Manul or runtime-specific directories.

Both `/manul run --agent <role> <task>` and the shorthand
`/manul <role> <task>` select a role explicitly. Without an explicit role,
the `agent` field is empty and Manul uses the configured automatic entry point.
The daemon must preserve the stored role in the execution context; an empty
value means automatic selection, not an implicit `main`.

The automatic entry-point runtime is configured through
`automation.agentRuntime` (default: `openclaw`). Explicit canonical worker
roles are routed through `automation.roleRuntime` (default: `opencode`).
This separation lets ordinary tasks continue to use OpenClaw while explicit
roles can use any supported role runtime. OpenCode maps a role to its native
`opencode run --agent <role>` option; Codex and Claude Code prepend the canonical
role instructions to the prompt because those CLIs have different role models.

OpenClaw's `--agent` selects an OpenClaw configuration entry, not a Markdown
role definition. If `automation.roleRuntime` is set to `openclaw`, Manul fails
closed for explicit canonical worker roles rather than silently executing them
under `main`. Unknown/unconfigured roles also fail before a runtime starts;
they must not be converted into prompt text or silently fall back to another
role.

The per-task `--auto` flag can be placed immediately after `/manul` (for
example, `/manul --auto run add tests`) or inside the run arguments. Manul
stores the flag with the queued task and routes that task directly to OpenCode,
passing its native `opencode run --auto` option. This mode deliberately bypasses
both automatic runtime selection and `automation.roleRuntime`; the OpenClaw
adapter does not implement `--auto`.

## Event format

Structured events are posted as HTML comments:

```html
<!-- manul:event {"type":"TASK_DONE","timestamp":"2026-09-11T18:00:00Z","data":{"taskId":"t-1","conversationId":"conv-1","status":"completed","prNumber":100,"attempt":1}} -->
```

### Event types

| Type | Direction | Meaning |
|---|---|---|
| `TASK_STARTED` | Bot → GitHub | Execution began |
| `TASK_NEEDS_USER` | Bot → GitHub | Task is waiting for user input |
| `TASK_DONE` | Bot → GitHub | Task completed |
| `TASK_FAILED` | Bot → GitHub | Task failed after retry policy |
| `REVIEW_APPROVED` | Bot → GitHub | Review approved |
| `REVIEW_REQUESTED` | Orchestrator → Bot | Review feedback to address |

The result-comment marker is a separate deterministic correlation mechanism:

`<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->`

The daemon requires that marker when accepting an agent `TASK_DONE`.

## User-input semantics

An implementation agent may request user input only when a material decision cannot be resolved from repository context, documentation, skills, or established conventions.

When input is required:

1. the agent inspects the repository, documentation, skills, configuration, and conversation context before asking;
2. the agent emits exactly one `TASK_NEEDS_USER_BEGIN` / `TASK_NEEDS_USER_END` block with non-empty content between the markers;
3. the decision block explains what was checked, why the uncertainty is material, and the concrete options or decision required; a recommendation is allowed, but the user's choice is authoritative;
4. the agent must not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same execution output as a user-decision block;
5. Manul records `blocked_user`;
6. the question is posted to the same GitHub conversation;
7. the original task/conversation context is retained;
8. `/manul continue <answer>` resumes the same task.

Malformed or partial decision blocks are execution failures, not `blocked_user`. Once the agent reaches a material user-decision point, it must not make further irreversible repository changes in that execution.

`blocked_user` is not a failure and does not consume another execution attempt until resumed.

## Conversation lifecycle

### Issue workflow

```
Issue -> /manul command -> task -> execution -> result
```

An issue is associated with a conversation ID. Multiple tasks may belong to the same conversation.

### PR review workflow

```
PR review -> /manul review-fix -> REVIEW_FIX task -> same PR branch -> updated PR
```

Review handling:

- `APPROVE` without inline comments -> record approval, no fix task;
- `REQUEST_CHANGES` -> create one `REVIEW_FIX` task for the submitted review;
- any newly submitted review (`APPROVE`, `COMMENT`, or `REQUEST_CHANGES`) with inline comments -> create one `REVIEW_FIX` task containing all inline comments with that `pull_request_review_id`;
- inline comments belonging to a submitted review are not separately queued as individual tasks;
- comments posted outside a review retain the independent comment-task behavior;
- the executor replies to each distinct inline thread and posts one canonical task result to the PR conversation;
- `DISMISS` -> no fix task.

## Database schema

The following describes the effective logical schema used by the current Manul scripts. Individual schema initializers may create a subset and add columns incrementally.

### processed_comments

```sql
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER NOT NULL,
  commentUrl TEXT NOT NULL,
  author TEXT,
  agent TEXT,
  prompt TEXT NOT NULL,
  context TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  createdAt TEXT,
  processedAt TEXT,
  heartbeatAt TEXT,
  leaseExpiresAt TEXT,
  workerPid INTEGER,
  claimToken TEXT,
  nextAttemptAt TEXT,
  conversationId TEXT,
  parentTaskId TEXT,
  workspaceId TEXT,
  action TEXT DEFAULT 'IMPLEMENT',
  prNumber INTEGER,
  prUrl TEXT,
  resultSummary TEXT,
  resultJson TEXT,
  baseId TEXT,
  taskId TEXT,
  session_id TEXT
);
```

Important execution fields:

- `attempts` — actual claims only;
- `heartbeatAt` / `leaseExpiresAt` — liveness;
- `workerPid` / `claimToken` — ownership;
- `conversationId` / `parentTaskId` — task graph/context;
- `workspaceId` — isolated workspace assignment;
- `session_id` — runtime session pointer retained only for an explicit continuation result;
- `resultSummary` / `resultJson` — result data;
- `baseId` — idempotency/deduplication support;
- `taskId` — review/orchestrator task association where present.

### conversations

```sql
CREATE TABLE conversations (
  conversationId TEXT PRIMARY KEY,
  repository TEXT NOT NULL,
  issueNumber INTEGER,
  issueUrl TEXT,
  activeTaskId TEXT,
  activePrNumber INTEGER,
  activePrUrl TEXT,
  status TEXT NOT NULL DEFAULT 'OPEN',
  createdAt TEXT NOT NULL,
  updatedAt TEXT NOT NULL
);
```

### conversation_links

```sql
CREATE TABLE conversation_links (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversationId TEXT NOT NULL,
  repo TEXT NOT NULL,
  issueNumber INTEGER,
  prNumber INTEGER,
  commentId TEXT,
  taskCommentId TEXT,
  linkType TEXT NOT NULL,
  createdAt TEXT NOT NULL,
  FOREIGN KEY (conversationId) REFERENCES conversations(conversationId)
);
```

SQLite is the source of truth for Manul task state.

## Security and integrity

- User inputs are SQL-escaped before SQL construction.
- Command parsing requires the `/manul` prefix.
- `commentId` and related idempotency mechanisms prevent duplicate event processing.
- Task/attempt markers prevent stale result comments from satisfying a later retry.
- Worker ownership checks prevent one worker from finalizing another worker's task.

## Result and PR verification

Repository-change tasks must:

- commit on a non-base task branch;
- push the branch;
- create/verify a concrete PR;
- report the verified PR URL.

The daemon may create a missing PR when `autoCreatePr` is enabled, but a `TASK_DONE` is still not accepted without verified PR identity.

Never treat `/compare` or `/pull/new` URLs as proof of a PR.

## Current runtime boundary

Manul executes tasks through
`AgentExecutionController` → `AgentExecutor` → a backend adapter; the daemon
never invokes an adapter script directly.

- No explicit role: `automation.agentRuntime` (default `openclaw`) selects the
  automatic entry point.
- Explicit canonical role: `automation.roleRuntime` (default `opencode`)
  selects the runtime. OpenCode receives the role through native
  `--agent <role>`; Codex and Claude Code receive canonical role instructions
  in the task prompt. Supported values are `openclaw`, `opencode`, `codex`, and
  `claude-code`.
- Unknown roles and explicit roles with `roleRuntime: "openclaw"` fail closed;
  they do not fall back to a different role or OpenClaw's `main`.

The adapter owns runtime session mechanics. Manul persists
`processed_comments.session_id` only when the current claim returns
`NEEDS_CONTINUATION` with a non-empty ID, and clears it on any other result.
This write is scoped to the current task claim. The workspace/context mapping is
preserved when the runtime session pointer is cleared. This runtime continuation
is not the same as the user-input command `/manul continue <answer>`.

The canonical source for Manul code remains
`~/.globalskills/skills/manul-github-bot/`; `~/.manul` is the runtime
directory for configuration, state, logs, locks, and workspace data. Existing
configuration files do not require a migration: `manul-paths.sh` supplies the
default runtime values if `automation.agentRuntime` or `automation.roleRuntime`
is omitted.

## Testing

Protocol tests:

```bash
bash skills/manul-github-bot/test_github_control_protocol.sh
bash skills/manul-github-bot/test_github_control_integration.sh
```

For behavioural changes, also run the relevant daemon/concurrency/review workflow tests.
