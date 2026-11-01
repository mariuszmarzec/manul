# Manul Contracts and Invariants

This document records behavioural contracts that should survive refactors. Implementation details may change; these semantics should not change accidentally.

## 1. GitHub command contract

Supported commands parsed from a `/manul` command are:

| Command | Action |
|---|---|
| `/manul run <task>` | `IMPLEMENT` using the automatic runtime entry point |
| `/manul run --agent <role> <task>` | `IMPLEMENT` using an explicit canonical role |
| `/manul <role> <task>` | `IMPLEMENT` using the explicit-role shorthand |
| `/manul review-fix <prompt>` | `REVIEW_FIX` |
| `/manul continue <answer>` | resume a `blocked_user` task |
| `/manul verify <prompt>` | `VERIFY` |
| `/manul status` | query conversation status |
| `/manul close` | close a conversation |

Without an explicit role, Manul uses `automation.agentRuntime` (default
`openclaw`). With an explicit canonical role, it uses
`automation.roleRuntime` (default `opencode`). Supported runtime values are
`openclaw`, `opencode`, `codex`, and `claude-code`. OpenCode receives a role
through its native `--agent <role>` option. Codex and Claude Code receive the
canonical role definition from `~/.globalskills/agents/<role>.md`, with YAML
frontmatter stripped and the role instructions prepended to the task prompt.
Agent definitions remain canonical; Manul must not copy them into another
source directory. Unknown/unconfigured roles fail closed. OpenClaw does not
receive canonical worker roles as its config-agent selector.

Routine ambiguity should be resolved by the agent. User input is requested only for a materially important unresolved decision.

A user-decision request is valid only when the agent emits exactly one:
`TASK_NEEDS_USER_BEGIN`
...
`TASK_NEEDS_USER_END`
block, with non-empty content between the markers and no `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` marker in the same execution output. Malformed or partial blocks are treated as execution failures, not as `blocked_user`.

The decision content should summarize what the agent checked, explain why the remaining uncertainty materially affects correctness or outcome, and present the concrete options or decision required. The agent may recommend an option, but the user's decision remains authoritative. Once the decision point is reached, no further irreversible repository changes are allowed in that execution.

## 2. Task state contract

Core execution states are:

```
queued
  -> running
      -> completed
      -> failed
      -> blocked_user
      -> stale / requeued
```

A `blocked_user` task is terminal-for-now, not a failure. It remains associated with its existing conversation/task context and resumes through `/manul continue <answer>`.

A stale running task is either:
- requeued for another execution attempt, preserving its attempt count; or
- marked failed when the configured maximum attempts has been reached.

## 3. Attempt counting

`attempts` is the bounded budget for actual agent-runtime executions, not workspace/checkout preparation.

A task claim first transitions:

```
queued -> running
```

and creates a fresh `claimToken` with `agentStartedAt = NULL`. Immediately before invoking the isolated agent runner, the dispatcher must atomically set `agentStartedAt` for that same running claim. A crash after this marker counts as an agent execution attempt.

If workspace acquisition, checkout preparation, lifecycle-comment publication, or another pre-agent step fails before the marker is written, recovery must atomically:
- decrement the claim-time `attempts` increment (never below zero);
- increment the separate `preExecutionFailures` counter;
- clear worker/lease/claim ownership and `agentStartedAt`;
- requeue with `nextAttemptAt`, or fail only when the configured bounded `maxPreExecutionFailures` budget is exhausted.

Pre-agent failures therefore cannot exhaust `maxAttemptsBeforeFail`. Infrastructure retries remain finite and respect backoff. A stale claim with a non-empty `agentStartedAt` follows the normal agent execution retry budget. A normal running-to-queued recovery never increments `attempts` by itself.

## 4. Worker ownership and leases

A running task is owned by its worker identity/claim token.

The daemon records and/or refreshes:
- `heartbeatAt`
- `leaseExpiresAt`
- `workerPid`
- `claimToken`

A recovery operation must verify ownership before changing a running task.

Heartbeat/lease recovery must never blindly reset a live task owned by another worker.

## 5. Single source of truth

`manul.db` is the authoritative task state.

Operational files such as:
- PID files;
- heartbeat PID files;
- logs;
- transient task stdout/stderr;
- result artifacts

must not become a second task-state database.

## 6. Concurrency

Task execution is serialized according to the configured concurrency limit.

The default configuration uses:

`maxConcurrentTasks = 1`

Repository locks prevent two tasks from concurrently modifying the same repository workspace.

A task lock/flock is a safety mechanism, not a replacement for SQLite ownership checks. Startup must serialize preparation and hold a separate OS-level daemon-owner lock for the full supervisor lifetime; a stale/reused PID must not allow a second supervisor to start. The dispatcher and daemon-owner lock descriptors must not be inherited by long-lived background helpers, workers, or isolated agent executors. Stopping/recovering a task must terminate the complete executor and heartbeat process trees—including descendants that create their own process groups—before the workspace can be reused. PID-file cleanup must not hide a still-running process.



## 6a. Workspace recovery data

Before marking a stale/broken workspace reclaimable or deleting its database mapping, the manager must atomically move the complete task-owned workspace root into a private recovery area under `$MANUL_DIR/state/recovery/workspaces`. Do not remove staged, unstaged, untracked, or uncommitted work. Snapshot names must bind the original workspace ID and task ID so a retry can restore only its own snapshot. If preservation fails, leave the workspace and its ownership metadata intact and report a diagnostic. Never widen runtime permissions to let an agent browse the recovery area or another task's workspace.

## 7. GitHub comment contract

Every Manul-signed comment ends with exactly one:

`— manul 🐈`

The signature is separated from the body by two newlines.

A result comment additionally contains an invisible deterministic marker:

`<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->`

The daemon uses that marker to correlate the result to the exact task execution attempt.

## 8. Result-comment contract

For an agent execution:
- the agent must post exactly one user-facing result comment;
- the result comment must be posted before `TASK_DONE`;
- the comment must contain the exact task/attempt marker;
- if a comment with the exact marker already exists, the agent must update it in place instead of creating a duplicate;
- the final GitHub state must contain exactly one matching result comment for that task/attempt;
- lifecycle comments such as `🔄 working`, `✅ completed`, `❌ failed`, and retry notifications are separate daemon responsibilities.

A `TASK_DONE` without a verified result comment is not accepted as successful completion.

Recovery for a stale attempt marker is deliberately narrow: when the current
running claim has `agentStartedAt`, the daemon may repair the marker in the
existing comment only if exactly one non-lifecycle comment for the same task
contains a lower numeric attempt marker, carries the required `— manul 🐈`
signature, and its `created_at` timestamp is strictly after the current attempt's start. The daemon changes only the invisible
marker, patches the existing comment in place, and verifies the returned body
before accepting delivery. Missing timestamps, multiple candidates, a comment
older than the current attempt, or an API/update/read-back error remain
fail-closed. This handles an agent accidentally copying an old attempt number
without accepting a previous attempt's result or creating duplicate comments.

Delivery mode is explicit. `VERIFY` tasks are report-only: successful execution, a verified non-empty result comment with the exact task/attempt marker, and an unchanged repository are sufficient; no branch, commit, or PR is required. `IMPLEMENT` tasks retain branch/commit/PR validation even when status or progress comments have been posted. The presence of a comment alone never selects report-only delivery.

The daemon may verify the final PR identity and repository cleanliness before accepting completion.

## 8a. Lifecycle event publication and idempotency

Lifecycle events are machine-readable comments, not evidence that an agent completed
work. They are keyed by the exact task ID and execution attempt.

For `TASK_STARTED`:
- the daemon publishes at most one signed start comment for a task/attempt;
- before posting, it reads the correct issue-comment or PR-review-comment endpoint
  and matches the event type, task ID, attempt, Manul signature, and (for review
  tasks) the exact `in_reply_to_id` thread;
- an existing match suppresses publication; a failed read-before-write check is
  fail-closed and must not publish blindly;
- when the publish client reports an error, the daemon reads the same endpoint
  again and treats the operation as successful only when the exact signed event
  is found. A retry must not create another visible comment.

Result-comment verification for inline PR review tasks is scoped to the exact source
review thread (`in_reply_to_id` from the source `discussion_r` URL). Marker
verification, non-empty-result verification, canonical PR URL verification and
stale-marker repair must all use that same thread. A marker or PR URL in another
review thread is not delivery evidence.

For terminal `TASK_DONE` and `TASK_FAILED` events:
- the marker is assembled into the exact user-facing result body before posting;
- the daemon persists the full body and routing metadata in a SQLite outbox keyed
  by task ID, attempt, and event type before calling GitHub;
- publication is serialized per event and reconciled by reading the matching
  task/attempt marker before every post and after an ambiguous post error;
- a confirmed existing marker records the outbox receipt without posting again;
- definite or ambiguous publication failures remain pending for retry. The
  terminal task state is not rolled back, and retries reuse the persisted body;
- intermediate retry states do not emit terminal events.

Neither `TASK_STARTED` nor a queued/published terminal comment can bypass the
result-comment, repository-delivery, or explicit `TASK_DONE` verification
contracts above. A start event, partial GitHub activity, or a terminal database
state without a verified result is never sufficient evidence of successful work.


## 8b. Issue #110 incident diagnosis and evidence boundary

The #110 audit established these code-level failure modes:

- **Duplicate TASK_STARTED:** publication was previously treated as acknowledged only when the POST client returned success. There was no exact task/attempt read-before-write or read-back after a non-zero POST. A transport error after GitHub accepted the comment could therefore enter pre-execution recovery and reuse the same attempt without knowing whether the marker already existed. Review-thread tasks also require lookup and deduplication in the exact in_reply_to_id thread.
- **Missing terminal lifecycle evidence:** the result body could be posted before its TASK_DONE/TASK_FAILED marker was appended. A failed POST was only logged, with no durable body/routing record for retry; task state and conversation closure could advance while the corresponding GitHub marker was still absent.
- **OpenCode continuation misclassification:** step-limit detection over the whole JSONL stream could match ordinary task text or tool payloads. Independently, the controller converted any TIMEOUT carrying a session ID into NEEDS_CONTINUATION, including overall and watchdog timeouts that the adapter reports as TIMEOUT. Only an explicit structured step-limit continuation is resumable.
- **Attempt diagnostics:** preExecutionFailures and agentStartedAt were already delivered on the base by merged PR #114; they are not reimplemented here. Pre-agent rollback must clear agentStartedAt and the claim/lease metadata while returning the claim-time attempt bump and charging the separate infrastructure counter.

The regression suite uses deterministic GitHub and runtime fakes to prove the corrected behavior at the publication, controller, adapter, session-state and dispatcher boundaries. The historical issue comments do not preserve every raw OpenCode JSONL stream or GitHub transport response for each old attempt; therefore this audit establishes the reproducible code-level causes and verifies the repaired failure semantics, but does not claim to reconstruct the exact network event sequence for every historical duplicate.


## 9. Comment routing

Tasks originating from:
- an issue body;
- an issue/PR conversation comment

receive top-level result/lifecycle feedback on that issue/PR conversation.

Tasks originating from a PR review comment receive feedback as an in-thread reply to that review comment.

Cross-posting a review-thread task into a top-level PR comment is a routing bug.

## 10. Repository workflow

### Issue tasks

Manul first prepares an up-to-date isolated base workspace.

The agent decides whether the task is:
- informational; or
- a repository-change task.

Informational tasks:
- do not modify repository files;
- do not create a task branch;
- answer on GitHub and finish.

Repository-change tasks:
- create a dedicated task branch according to the feature/bugfix branching policy;
- never commit directly to a base/default branch;
- push the task branch;
- deliver changes through a real GitHub PR with a meaningful description immediately after the first push;
- after every later push to a branch with a PR, including checkpoints and review/CI fixes, refresh the same PR description from the cumulative diff and current verification results;
- read back and verify the description and PR identity/head SHA before reporting delivery; stale or unverified description means delivery is incomplete.

### PR review/conversation tasks

When a task comes from an existing PR review/conversation:
- reuse the PR's existing head branch;
- do not create a new unrelated branch;
- update the same PR.

## 11. PR identity

Issue numbers and PR numbers are independent.

A repository-change task is not successfully delivered until the PR has been verified as a real GitHub PR with:
- the expected head branch;
- the expected base branch;
- the concrete GitHub PR URL;
- a non-empty description that matches the cumulative changes and current verification results after the latest push.

The agent must refresh the same PR body after every push (including checkpoints), read it back from GitHub, and confirm the pushed head SHA. `/compare` and `/pull/new` links are not valid completion evidence.

## 12. Source revalidation

Before executing a queued task, Manul may revalidate that its GitHub source still exists and is active.

Examples:
- closed issue -> stale;
- closed or merged PR -> stale;
- a PR-backed comment whose parent PR is closed/merged -> stale;
- a PR whose head repository or head branch no longer exists -> stale;
- resolved/deleted review context -> stale.

PR-backed sources must be revalidated before workspace/checkout preparation. The
check must distinguish a definitive missing/closed source from transient API,
network, rate-limit, or permission errors: only confirmed terminal sources are
marked `stale`, while ambiguous failures use the bounded pre-execution retry
path. A stale source is not treated as a successful task completion.

## 13. Workspace contract

Workspace preparation is part of Manul orchestration.

Workspaces must be isolated per active task and released after task completion/failure/recovery.

Workspace reclamation must use the same liveness/lease semantics as task recovery.

The leased `ws-*` path is the task workspace root. It contains task-scoped repository checkouts under `repos/<owner>/<name>/` and task-local scratch under `tmp/`. The primary checkout path (`WORKDIR`) is passed separately and remains authoritative for branch setup, commits, pushes, PR metadata, dirty-state checks, and completion verification. Manul's shared repository cache (`REPO_DIR`) is an internal clone source and must never appear in the generated agent prompt.

The agent may read/search configured related repository checkouts inside the leased workspace. Those secondary checkouts are read-only by default; only the primary checkout may be modified or delivered unless the user explicitly approves a separate delivery policy for another repository. An unavailable required checkout must be reported as a concrete blocker. Agents must not access sibling workspaces, shared caches, or other Manul runtime state.

### Checkout recovery

- The branch Manul prepares is explicit and task-specific. For a standalone issue task, use the resolved base branch selected by the branch policy. For a PR/review task, use that PR's actual head branch. Never assume `master` or the repository default for a PR task.
- Before preparing a standalone task, fetch the repository and resolve the intended base branch. If checkout, reset, cleanup, or verification of that branch fails, Manul must attempt a fresh clone of the repository remote at the **same intended branch**.
- If switching to a PR head branch fails because of dirty/stale checkout state, Manul must attempt a fresh checkout at that exact PR head branch. Do not silently switch to another branch if the requested PR branch cannot be fetched.
- Clone and verify the replacement first, then move the existing checkout intact to the task-owned `tmp/checkout-recovery/` area. Keep that backup; if installing the replacement fails, restore it where possible. Never delete the previous checkout as part of fallback.
- If the intended remote branch is unavailable, path validation fails, or a fresh checkout cannot be verified, fail with a concrete diagnostic and preserve the prior checkout where possible. Never turn a recovery failure into a checkout of `master`/default.
- A recovery backup is operator/recovery material, not a second active checkout. The normal agent prompt and all delivery checks must continue to use only the validated primary checkout at `WORKDIR`.

## 14. Agent task access boundary

An explicitly authorized operator-side maintenance session running **outside a
Manul-managed task** may inspect read-only logs under `~/.manul/logs/**` to
diagnose runtime failures and may write sanitized evidence under
`/tmp/manul-diagnostics/**`. Do not delegate this workflow to an ordinary
`/manul` worker task; it must never expose credentials or copy secrets into
diagnostic artifacts.

Every generated implementation/review-fix prompt must enforce a least-privilege task boundary, independently of how brief or detailed the user's `/manul` comment is:

- The exact assigned task workspace root is the only local repository-access boundary. The primary checkout (`WORKDIR`) is authoritative for all default repository edits, commits, pushes and PR delivery.
- Related checkouts explicitly listed in the generated prompt may be inspected/searched but are read-only by default. No changes may be delivered from a secondary checkout unless the user has explicitly approved that repository's branch/PR/delivery policy.
- The configured Manul workspace base (`MANUL_WORKSPACE`, defaulting to `$HOME/.manul/workspace`) is private runtime state. Only the exact leased task workspace root and its descendants are permitted. Access to any sibling task workspace, prior attempt, cache, database, prompt, log, adapter, daemon state, or runtime artifact is explicitly forbidden, including read-only inspection. The global OpenCode config must blanket-deny the default home-relative workspace rule; the adapter may add a temporary invocation-local config overlay allowing only the validated active lease root and `<root>/**`. The overlay must not be persisted to provider/global config and must be deleted after invocation; sibling paths remain denied. Do not read/list/search/probe `~/.agents/**` or `~/.config/opencode/**`.
- Do not follow symlinks or use shell/file/skill tools, globbing, shell redirection, `git -C`, subagents, or indirect path tricks to reach another workspace or escape the task root.
- Do not inspect Manul task state or runtime artifacts to prove routing/role selection. Those are operator-owned diagnostics collected outside the implementation session.
- Prefer repository-local instructions and skills. Global skills may only be used when their contents are explicitly supplied to the agent as task context; never tell the agent to open a global skill path.
- If needed context is missing, first seek it from the assigned workspace, related checkouts explicitly prepared inside it, the authoritative GitHub issue/PR and comment history, repository history, or approved public documentation. If the information remains unavailable and materially affects the work, ask the user through the structured `TASK_NEEDS_USER` flow, naming the specific input required and what was already checked. Never inspect another task's workspace to fill the gap.
- Do not change runtime configuration or permissions to work around this boundary.

### Scope-first investigation and host-system boundary

- Start with the smallest relevant evidence set: the task request, `WORKDIR`, repository-local documentation, source, tests, build/dependency files, and documented project commands. Search narrowly and expand only when a concrete finding shows it is necessary. Do not perform broad host/environment reconnaissance just to understand an ordinary repository task.
- For ordinary implementation, review, and test tasks, host OS/service configuration is out of scope. Do not inspect paths outside the authorized workspace merely because a dependency is unavailable. In particular, do not inspect `/etc/**`, `/var/**`, `/run/**`, `/proc/**`, `/sys/**`, host database configuration such as `/etc/mysql/**`, other users' home directories, or enumerate unrelated host processes/services/containers. The exception is a task that explicitly targets host/system administration and expressly authorizes that access; do not infer such authorization from a generic coding task or a dependency failing to start.
- Repository-declared build/test/dependency commands (including a repository's own documented Docker Compose setup) may be used when required by the task. This does not authorize reading host configuration, probing unrelated services, or starting/stopping host-level services. If the documented project command cannot run, capture its error and report the precise blocker rather than diagnosing the host installation.
- Keep shell/tool calls focused on one diagnostic purpose. Avoid compound commands that mix in-workspace work with unrelated filesystem or system probes.
- After a permission denial, do not retry the same restricted operation through another tool, path, symlink, or reshaped command, and do not ask for broader permissions just to continue routine work. Record the exact denied operation and continue only with independent in-scope work; otherwise report the blocker.
- These restrictions also apply to delegated/subagents. Preserve the same boundary in every delegated task prompt.

These restrictions are part of the default task contract, not requirements that the user must repeat in every GitHub comment. The generated prompt must not contain conflicting instructions that tell the agent to load `~/.agents/**` or inspect private runtime state.

### Runtime capability awareness and permission recovery

- The OpenCode adapter appends a capability snapshot to the initial prompt and every same-session continuation. The snapshot is generated from the exact leased workspace and the invocation's effective `permission.external_directory` rules; it must not dump the full OpenCode config or environment.
- The snapshot describes rules; it does not grant access or promise that every tool or shell command can use an allowed path. Actual OpenCode tool and path decisions remain authoritative.
- On an explicit permission denial, never repeat the same request, reshape it, split it, or route around the boundary through another tool, path, symlink, wrapper, subagent, or command. Do not modify permissions or invoke a permission bypass.
- If a resumable session ID is available and no task-control marker was emitted, the adapter may issue exactly one recovery continuation within the same execution timeout and attempt. The recovery instruction must make the denial and boundary explicit, preserve task progress, and request an independent permitted strategy.
- Prefer diagnostics created by commands running inside the task workspace. For a blocked external build log, rerun the documented project command with appropriate diagnostic flags and write a minimal, secret-redacted log under the task workspace.
- A second denial, absent session ID, or lack of a safe alternative remains a concrete failure. Preserve sanitized logs and report what evidence is missing; never claim completion without verification and never widen permissions automatically.
- Test both the recovery-success path and repeated-denial fail-closed path. Recovery must use the exact same runtime session, run at most once, preserve the original timeout budget, and never create an unbounded retry loop.

## 14. Watchdog contract

The watchdog is a liveness/recovery mechanism, not a general task scheduler.

It may:
- restart an enabled daemon that is not running;
- remove a stale daemon lock;
- reclaim stale workspaces;
- recover tasks whose heartbeat/lease is stale.

It must not:
- reset healthy running tasks;
- reset all tasks merely because a lock is old;
- create a second independent retry policy.

The daemon also performs a recovery pass at loop startup; this is a deliberate startup safeguard and not a competing retry mechanism.

## 15. User-decision contract

When the agent materially needs user input it must:
1. emit the structured needs-user block;
2. let Manul persist `blocked_user`;
3. stop treating that execution as success/failure;
4. resume the same task context after `/manul continue <answer>`.

Equivalent implementation choices should be resolved by the agent without blocking the user.

## 16. Human and bot modes

The top-level configuration key `mode` selects Manul's GitHub presentation/attribution behavior:

- `bot` is the default and preserves the existing Manul signature, lifecycle/status/error comments, and AI commit attribution.
- `human` suppresses Manul signatures and orchestration lifecycle/status/error comments on GitHub.
- In `human`, when `commentStyle.human.concise` is enabled, the visible result comment should be a short, natural teammate reply and stay within `commentStyle.human.maxLines`; automation-report headings and boilerplate should be avoided.
- In `human`, the agent's actual result comment remains user-facing and is verified using the invisible deterministic task/attempt marker.
- In `human`, commits must not contain an AI `Co-authored-by` trailer.
- Task state, recovery, leases, and local diagnostics remain unchanged; human mode is not a weaker execution or verification mode.

The mode is resolved from `MANUL_MODE` when explicitly provided, otherwise from `.mode`, defaulting to `bot`. Invalid values are rejected.

## 17. Configuration contract

The runtime reads Manul configuration from `MANUL_DIR/config.json`, where `MANUL_DIR` resolves to `~/.manul`.

The example configuration currently defines:
- polling interval;
- allowed users/repositories;
- agent names;
- `automation.agentRuntime` (default `openclaw`) for tasks without an explicit role;
- `automation.roleRuntime` (default `opencode`) for explicitly named canonical roles;
- PR automation;
- rebase behaviour;
- retry/context limits;
- CI-fix limits;
- agent timeout;
- `automation.opencodeMaxStepLimitContinuations` — maximum internal OpenCode
  same-session resumes after step-limit events (default 3, valid range 0..20);
- `automation.agentNoProgressTimeoutSeconds` — maximum silent period for supported
  CLI runtimes before their isolated process group is terminated (default 900s);
- `automation.agentToolNoProgressTimeoutSeconds` — maximum period an explicitly
  active tool call may remain without completion/progress before termination
  (default 3600s);
- heartbeat timeout;
- lease timeout;
- maximum attempts;
- lock TTL;
- maximum concurrent tasks.

The location of this configuration is `~/.manul/config.json`. Operator/provider
environment for unattended execution is stored separately in `~/.manul/.env`;
it is not part of the Manul JSON configuration contract. The semantics of
these controls should not change accidentally.

## 18. Runtime boundary

Manul task contracts are runtime-neutral. The daemon never invokes an agent
runtime directly; it calls `AgentExecutionController.execute`, which routes
through `AgentExecutor` to a backend adapter.

Adapters are independent backends behind a single `ProcessRunner.run()`
process boundary. `automation.agentRuntime` (default OpenClaw) selects the
automatic entry point; `automation.roleRuntime` (default OpenCode) selects the
runtime for explicitly named canonical roles. Both accept `openclaw`, `opencode`,
`codex`, and `claude-code`. Adapters must not spawn subprocesses directly and
must not depend on each other.

The adapter owns runtime session invocation/resume mechanics. Manul owns the
persisted `processed_comments.session_id` pointer: retain it only when the
current running claim returns `NEEDS_CONTINUATION` with a non-empty session ID,
and clear it on every other result. Session-pointer updates must be scoped to
the active claim token so an expired worker cannot overwrite newer task state.
Clearing the pointer must not delete the task's workspace/context mapping.
This internal continuation is distinct from the user-input flow
`blocked_user` → `/manul continue <answer>`.

For OpenCode, `automation.opencodeMaxStepLimitContinuations` (default `3`,
valid range `0..20`) sets the maximum number of additional same-session
`opencode run --session <id>` invocations the adapter may perform after an
explicit step-limit event. These invocations stay inside the same adapter
execution and Manul task attempt; they do not update task state or increment
the attempt count. The initial call and all internal continuations share one
overall wall-clock timeout. Only a confirmed step-limit event with a known
session is eligible; permission denials, provider/runtime errors, normal stops,
completion/user-input markers, and timeouts must not trigger this retry loop.
When the configured internal budget is exhausted and OpenCode still reports a
step limit, the adapter returns the existing `NEEDS_CONTINUATION` result so
the daemon's existing retry/session handling remains authoritative.

The CLI adapters apply `automation.agentNoProgressTimeoutSeconds`
(default `900`) to the current run's stdout/stderr stream. A fresh JSONL
event or stderr write resets the generic idle timer; a heartbeat alone does
not. For Codex CLI and Claude Code, `ProcessRunner` recognizes the runtime's
active-tool JSONL events and pauses the generic idle timer while a tool is
running, bounded by `automation.agentToolNoProgressTimeoutSeconds` (default
`3600`; runtime-specific overrides are `MANUL_CODEX_TOOL_NO_PROGRESS_TIMEOUT`
and `MANUL_CLAUDE_TOOL_NO_PROGRESS_TIMEOUT`). For OpenCode, a running/pending
tool uses `MANUL_OPENCODE_TOOL_NO_PROGRESS_TIMEOUT`, while an unfinished
`step_start` without a corresponding `step_finish` is bounded by
`automation.agentStepNoProgressTimeoutSeconds` (default `3600`, overridable
with `MANUL_OPENCODE_STEP_NO_PROGRESS_TIMEOUT`). Thus an active tool/step
cannot suppress timeouts indefinitely. On expiry, `ProcessRunner` terminates
only the isolated runtime process group and reports
`AGENT_NO_PROGRESS_TIMEOUT` for generic idle, `AGENT_STEP_NO_PROGRESS_TIMEOUT`
for an unfinished OpenCode step, or `AGENT_TOOL_NO_PROGRESS_TIMEOUT` for an
active tool that never completes.
The aggregate JSONL log and stderr diagnostics are retained for task recovery. This timeout is
independent of the overall agent timeout and of the daemon lease/heartbeat.

Every adapter failure result should preserve actionable diagnostics in its
`ExecutionResult` when the runtime provides them, including the runtime,
exit code, session ID, duration, error type/message, and the location of any
retained raw runtime log. A generic summary such as "agent exited with code 1"
is not sufficient when the runtime exposes a more specific error.

When a runtime permission policy rejects a tool call, the adapter and lifecycle
comment must report, when present in structured runtime output, the tool name
and permission/resource being requested (for example,
`external_directory (/tmp/**)`). The user-facing retry/failure comment must
include this compact diagnostic rather than only `RUNTIME_PERMISSION_BLOCKED`.
If the operation cannot be identified from captured output, explicitly state
that operation details were unavailable. Never publish raw event payloads,
tool arguments, prompts, file contents, credentials, or entire log excerpts to
GitHub; retain raw runtime logs locally for operator-side inspection.

Per-attempt runtime logs are diagnostic artifacts, not task state. They should
be retained under the Manul task-log directory and cleaned by the normal task
retention policy.

## 19. Clean-break policy

The runtime isolation refactor is a clean break from `~/.openclaw/manul`.

- `MANUL_DIR` resolves to `~/.manul`; there is no fallback and no
  `OPENCLAW_MANUL_DIR` alias.
- Old `~/.openclaw/manul` state or paths are not preserved or migrated.
- No compatibility shims keep obsolete runtime state working.

Behavioural compatibility is required; obsolete filesystem layout
compatibility is not.


## 20. Task-source contract

Manul task sources are configured as `.taskSources[]`. Each enabled source is
an independent provider and is polled during the same cycle.

The provider contract is normalized to:
- `taskSourceType`
- `taskSourceId`
- `taskSourceUrl`
- title/body, timestamps and a normalized `prompt`
- provider-specific `metadata`
- an execution target when the provider can resolve one (currently
  `metadata.repository` for repository-backed execution)

Filtering is provider-owned. The common poller does not impose a universal
trigger or task-selection rule:
- `github_issues` selects issue roots containing the configured `/manul`
  trigger;
- `jira_tasks` selects issues returned by its configured JQL;
- `todo_local_mcp` selects active unscheduled root tasks in Todo Desktop
  whose description contains a line beginning with `/manul`;
- `todo_remote_mcp` selects active unscheduled root tasks whose `shares`
  contain the configured `manulUserId` with `EDITOR_AND_VIEWER` permission.

For both Todo providers, report-only selection is an explicit opt-in: the source
must set `allowReportOnly: true`, and the Todo description must contain a line
beginning with `/manul report`. Such a task normalizes to
`execution.kind=report_only` and does not require repository metadata. The
common poller accepts this execution kind only for the two Todo source types;
all other unsupported execution kinds fail closed.

Todo providers do not select a configured default repository. For each
active root, the adapter resolves the execution target from the task description:
an explicit GitHub repository URL takes precedence; otherwise the longest
whole-phrase alias in the curated project catalog
(`skills/globalskills-repository/project-repositories.json`) must identify
exactly one canonical `owner/repo`. The resolved `repository`, method,
matched alias and mapped skill names are stored in normalized metadata as
`repositoryResolution`. Full contents of the mapped skills are included in
the task prompt; workers must not inspect global skill paths.

The catalog is the maximum set of repositories Todo routing can choose.
Operator-level `repositoryAllowlist` and a per-source override can only narrow
that set. A missing match, multiple equally-specific project matches, an
uncatalogued explicit URL, or an allowlist rejection is fail-closed: log the
source task ID and skip it without creating a queue entry or falling back to a
static repository. The route already stored with a queued task is reused across
retries; changing the catalog does not silently retarget existing queue rows.

The two Todo providers are separate adapters with different MCP tool names and
credentials. Local uses the existing loopback bridge and `TODO_LOCAL_MCP_TOKEN`;
remote uses Fiteo's HTTPS `/mcp` endpoint and a PAT from an environment variable.
Tokens never appear in normalized task JSON or configuration values.

A Todo root is queued once with its complete subtask tree. Descendants are ordered
implementation steps, not separate queue entries. The adapter preserves the
provider-returned order and traverses nested subtasks in pre-order. The source ID
includes a structural fingerprint (task IDs, descriptions, permissions, priority,
scheduler and tree topology); it deliberately excludes progress flags and modified
timestamps. Sibling arrays in the fingerprint are canonicalized by priority and ID
because Fiteo sorts visible tasks by status, priority and modified time, so marking a
step done can reorder the returned tree without changing the plan. The initial prompt
still uses the exact provider-returned order. A priority, description, permission or
topology change invalidates the source; status/time-only progress does not. The root
must remain active and the current source tree must still match before execution and
completion.

For repository-backed Todo tasks, completion follows repository delivery
verification (including a verified PR when code changed). For report-only Todo
tasks, the agent's non-empty final answer is instead written as a child task under
the source root. The adapter reads the tree back and verifies the unique child,
parent relationship, exact answer, and completed flag. Its marker binds the child
to the original source fingerprint and an answer SHA-256 digest; only one valid,
source-version-bound result child is omitted from subsequent source fingerprints.
A modified/ambiguous output child is not ignored.
 
The daemon persists the verified result receipt in its own task row before
completion. A lost create response or later partial failure is retry-safe: a
matching child is located and reused, never duplicated. If result persistence,
read-back, or local receipt storage fails, the source root remains active.
 
After delivery verification, the local adapter marks the root and all descendants
done in one local operation. The remote adapter updates descendants individually
before the root, using Fiteo's inherited ancestor-share permission rules. For
report-only tasks the generated result is included with the original descendants;
the root remains active if any child update fails, allowing a safe retry. Todo
tasks do not post GitHub lifecycle or result comments. Repository-backed Todo
tasks use a verified repository PR when code changed; report-only tasks use the
verified Todo child as their delivery. The common GitHub comment-marker contract
does not apply to these external sources.

The task-source identity is the root work item. A pull request, review
comment, or CI check is never a task-source root. Those artifacts may be linked
as context to a task owned by another source.

The default source is `github_issues`. Existing configurations without
`.taskSources` fall back to the legacy `.repositories` array as one GitHub
Issues source.

Multiple enabled sources are independent: a failure in one provider must not
prevent other providers from being polled.

The initial non-GitHub provider is `jira_tasks`. Its REST search endpoint is
configurable (default `/rest/api/2/search`). Authentication uses the
environment variables named by `userEnv` and `passwordEnv` (defaults
`MANUL_JIRA_USER` and `MANUL_JIRA_PASSWORD`), and credential values never
appear in JSON configuration or normalized tasks. A repository mapping can be
provided with `repository` when the Jira task is executed against a known
repository. The provider is disabled by default.

## 21. Unit-test contract

When an implementation task adds or changes unit tests:
- tests must prove the requested behavior, not merely object construction, helper execution, DTO conversion, or property structure;
- the test should execute the real production entry point containing the behavior under test;
- external dependencies may be mocked, but the system under test must remain real;
- interaction-based behavior must be asserted through the real dependency boundary with the requested calls and arguments;
- a test is invalid if it would still pass after the requested production behavior is removed;
- when an existing relevant unit test or test file exists, extend or modify it rather than creating a parallel duplicate unless there is a concrete reason;
- when a review comment names a test location, treat that location as part of the acceptance criteria;
- test-framework or mocking difficulties must not be solved by weakening or removing the behavioral assertion;
- if the intended behavioral test remains blocked after reasonable investigation, use `TASK_NEEDS_USER` when a material design choice is required rather than silently lowering test quality;
- compilation alone is not evidence that the requested behavior is covered.

For `REVIEW_FIX`, the review comment's requested production call, side effect, interaction, or verification is authoritative. Implementation details may differ, but the behavioral contract must remain intact.

## 21. Deployment and executable-entry-point contract

Runtime entry points that Manul invokes directly must remain executable in the canonical checkout. In particular, `agent-task-runner.sh` is launched directly by `setsid` and therefore requires the Git executable mode `100755`. Sourced helper scripts do not require the execute bit. The runtime installer/startup path must preserve or restore the execute bit, and CI must fail when the canonical runner loses it.
## 22. Progress checkpoint contract

For non-trivial repository-change tasks, the agent MUST NOT accumulate all
meaningful work as uncommitted workspace state until the end. After each
logically complete and meaningful milestone, it MUST create a checkpoint commit
and push it to the task branch/PR branch, together with a concise status comment
when useful.

A milestone may include, for example:
- a reproducible regression test that captures the original failure;
- a proven root-cause fix with focused tests passing;
- a separately verified corrective change;
- a regenerated artifact/snapshot after its inputs are known to be correct.

Checkpoint commits are valid even when the overall task is not complete. A checkpoint must not be presented as final completion unless all task acceptance criteria are satisfied.

For existing PR tasks, checkpoint commits must be pushed to the PR's existing head branch. For standalone repository-change tasks, checkpoint commits must be pushed to the task branch.

Workspace-only changes are not considered delivered progress. The agent should distinguish explicitly between:
- local/uncommitted progress;
- committed but unpushed progress;
- pushed progress visible on the GitHub PR.

When a meaningful milestone has been reached, the agent MUST commit and
push it before starting a new high-risk investigation or implementation step.
After the push, the agent MUST verify that the remote branch (and existing PR,
when applicable) points at the pushed commit.

A failed or blocked execution MUST preserve already-pushed checkpoints and,
when safely possible, continue from the latest verified checkpoint rather than
restarting from the original task state. Runtime/LLM failure is not evidence
that repository work made no progress.


## 23. Delivery verification and failure classification

For repository-changing tasks, `TASK_DONE` is not sufficient evidence of delivery. The daemon must distinguish implementation completion from delivery completion and verify the repository/PR state before marking the task `completed`.

For a changed repository the delivery checks are:

1. The agent is on the expected task/PR branch.
2. The working tree has no staged, unstaged, or relevant untracked changes.
3. The changes are committed.
4. When an `origin` remote is available, the task branch exists on `origin` and its SHA matches the local `HEAD`.
5. For an existing PR task, the GitHub PR head branch and head SHA match the expected branch and delivered commit.

Failure codes must be stable and actionable:

- `RUNTIME_PERMISSION_BLOCKED` — runtime rejected a tool call because of a permission boundary.
- `PROVIDER_ERROR` — provider returned a structured runtime/provider error.
- `RUNTIME_FAILURE` — generic runtime execution failure.
- `RUNTIME_TIMEOUT` — the overall runtime execution budget expired.
- `AGENT_NO_PROGRESS_TIMEOUT` — neither runtime output nor recognized JSONL activity progressed within the idle budget.
- `AGENT_STEP_NO_PROGRESS_TIMEOUT` — an OpenCode `step_start` remained unfinished past the bounded active-step budget.
- `AGENT_TOOL_NO_PROGRESS_TIMEOUT` — an explicitly active OpenCode tool call failed to complete within its bounded budget.
- `TASK_NEEDS_USER` — structured user decision is required.
- `NEEDS_CONTINUATION` — adapter explicitly identified a bounded, resumable runtime condition and returned a session ID. A `TIMEOUT` plus a non-empty session ID is not sufficient; overall, idle, step-idle and tool-idle watchdog timeouts remain timeouts and clear the continuation pointer.
- `DELIVERY_NOT_COMMITTED` — repository changes remain uncommitted when the agent reports completion; the dirty workspace is preserved for diagnosis and must not be treated as delivered.
- `DELIVERY_NOT_PUSHED` — committed work is not present on the remote/PR head.
- `DELIVERY_COMMENT_MISSING` — the required task/attempt result marker could not be verified; a completion marker from the agent is not a substitute for delivery evidence.
- `WORKSPACE_DIRTY` — workspace contains unexpected residue that is not the agent's intended repository change.
- `VERIFICATION_FAILED` — branch, PR identity, or another required invariant could not be verified.
- `CONTROLLER_ERROR` — execution controller could not construct/return a valid execution result.

A final `completed` state requires the applicable verification checks to pass; a failure classification must not be overwritten by a later generic workspace check.


## CI auto-fix ownership boundary

CI auto-fix is permitted only for a PR whose exact canonical URL is persisted
as the verified deliverable of a completed Manul task (processed_comments.prUrl,
with the matching repository and PR number). The source issue/PR number,
branch naming, bot comments, prior CI attempts, or an active task on the same
PR do not prove that Manul created or delivered that PR. Synthetic ci_fix
tasks can never establish their own eligibility. Missing provenance or a
database/query error must fail closed and skip automatic fixes. This prevents
Manul from taking ownership of CI failures on unrelated PRs.

