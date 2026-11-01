# Manul External Orchestrator

## Purpose

`manul-orchestrator.sh` is a local state-machine wrapper around the Manul task system.

It is useful for external callers such as ChatGPT or another supervisory process that needs to:

- create a conversation;
- submit tasks;
- wait for execution;
- inspect results;
- record review decisions;
- create review-fix tasks;
- close a conversation.

It is **not** the Manul daemon and it does not replace `manul.db`.

## Architecture

```
External caller
      |
      v
manul-orchestrator.sh
      |
      +--> manul-conversation.sh
      +--> manul-submit.sh
      +--> manul-status.sh
      +--> manul-result.sh
      +--> manul-wait.sh
      |
      v
Manul task system
      |
      +--> SQLite manul.db
      |
      +--> GitHub
```

The external orchestrator also persists its own control-plane state in `orchestrator.db`.

Current default location:

```
${ORCHESTRATOR_DIR:-${MANUL_DIR:-$HOME/.manul}}/orchestrator.db
```

The runtime-isolation refactor has moved this Manul-owned state under `~/.manul`. There is no fallback to `~/.openclaw/manul`.

## Conversation state machine

Current phases are:

```
NEW
  -> SUBMITTING
  -> RUNNING
  -> PR_READY
  -> REVIEWED
  -> APPROVED
  -> CHANGES_REQUESTED
  -> BLOCKED
  -> FIXING
  -> COMPLETED
```

Not every conversation visits every phase.

A typical repository-change cycle is:

```
NEW
 -> SUBMITTING
 -> RUNNING
 -> PR_READY
 -> CHANGES_REQUESTED
 -> FIXING
 -> RUNNING
 -> PR_READY
 -> APPROVED
 -> COMPLETED
```

`COMMENT` review decisions are recorded as review events and do not create a fix task.

## CLI

### `create`

```bash
manul-orchestrator.sh create \
  --repo REPO \
  --title TITLE \
  --prompt PROMPT \
  [--json] [--dry-run]
```

Creates/reuses a conversation and submits its initial task.

### `submit`

```bash
manul-orchestrator.sh submit \
  --conversation-id ID \
  --prompt PROMPT \
  [--action ACTION] \
  [--pr-number N] \
  [--parent-task-id ID] \
  [--json] [--dry-run]
```

Supported actions include implementation and review-fix flows exposed by Manul.

### `wait`

```bash
manul-orchestrator.sh wait \
  --task-id ID \
  [--timeout SECONDS] [--json]
```

Delegates waiting to the Manul local task interface and updates orchestration state.

A completed task normally moves the conversation to `PR_READY`. If the Manul database is missing, the command preserves the machine-readable `not_found` result and returns exit code `2`; timeout remains exit code `4`.

### `status`

```bash
manul-orchestrator.sh status --conversation-id ID [--json]
```

Returns conversation state, task history and the latest task result.

### `result`

```bash
manul-orchestrator.sh result --task-id ID [--json]
```

Combines the Manul task result with external orchestration metadata.

### `review`

```bash
manul-orchestrator.sh review \
  --task-id ID \
  --decision APPROVE|REQUEST_CHANGES|COMMENT|BLOCKED \
  [--json]
```

Phase mapping:

| Decision | Phase | Creates a fix task? |
|---|---|---|
| `APPROVE` | `APPROVED` | No |
| `REQUEST_CHANGES` | `CHANGES_REQUESTED` | No, until `fix` is invoked |
| `COMMENT` | `REVIEWED` | No |
| `BLOCKED` | `BLOCKED` | No |

### `fix`

```bash
manul-orchestrator.sh fix \
  --conversation-id ID \
  --prompt PROMPT \
  --task-id PARENT_TASK_ID \
  [--pr-number N] [--json]
```

Creates a `REVIEW_FIX` task associated with the same conversation and PR. When a PR number is present, the orchestrator derives a deterministic internal review ID from `PARENT_TASK_ID`. Retrying a fix for the same parent therefore reuses the same Manul task identity; pass the latest completed task as the parent for a distinct subsequent fix cycle.

### `run`

```bash
manul-orchestrator.sh run \
  --repo REPO \
  --title TITLE \
  --prompt PROMPT \
  [--max-review-cycles N] [--json] [--dry-run]
```

Runs the initial task and returns a conversation/PR-ready state. Review approval and later fix cycles are explicit operations.

### `close`

```bash
manul-orchestrator.sh close --conversation-id ID [--json]
```

A conversation cannot be closed while it has incomplete Manul tasks.

On success the external orchestration phase becomes `COMPLETED`.

## Persistent schema

The control-plane DB contains:

### conversations

```
conversationId
repo
issueNumber
issueUrl
title
initialState
currentPhase
currentTaskId
prNumber
prUrl
reviewCycle
maxReviewCycles
createdAt
updatedAt
```

### task_history

```
id
conversationId
taskId
action
status
prNumber
parentTaskId
resultSummary
resultJson
createdAt
completedAt
```

### review_history

```
id
conversationId
taskId
decision
feedback
createdAt
```

## Review-cycle limit

The default maximum review cycle is 3 unless overridden by the CLI/task flow.

This limit belongs to the external orchestration layer; it does not replace Manul's execution retry limit.

## Dry run

Commands supporting `--dry-run` must not create real GitHub or task state.

They return synthetic IDs/URLs for inspection only.

## Testing

```bash
bash skills/manul-github-bot/test_orchestrator.sh
```

Because the external orchestrator uses the same Manul task interface, changes to shared task semantics should also run the relevant Manul CLI/concurrency tests.

## Runtime note

`MANUL_DIR` defaults to `~/.manul`. That path is an implementation detail; do not encode the current filesystem path into new orchestration APIs.
