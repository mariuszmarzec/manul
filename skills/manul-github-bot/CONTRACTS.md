# Manul Contracts and Invariants

This document records behavioural contracts that should survive refactors. Implementation details may change; these semantics should not change accidentally.

## 1. GitHub command contract

Supported commands parsed from a `/manul` command are:

| Command | Action |
|---|---|
| `/manul run <task>` | `IMPLEMENT` using the automatic runtime entry point |
| `/manul run --agent <role> <task>` | `IMPLEMENT` using an explicit canonical role |
| `/manul <role> <task>` | `IMPLEMENT` using the explicit-role shorthand |
| `/manul sdd bootstrap` | Explicit SDD Baseline initialization; never inferred |
| `/manul sdd <task>` | SDD task; requires an existing approved SDD baseline |
| `/manul team <goal>` | `TEAM` workflow; plans/decomposes work through the existing Orchestrator |
| `/manul review-fix <prompt>` | `REVIEW_FIX` |
| `/manul continue <answer>` | resume a `blocked_user` task |
| `/manul verify <prompt>` | `VERIFY` |
| `/manul status` | query conversation status |
| `/manul close` | close a conversation |

Every task uses automation.agentRuntime (default openclaw), whether or not a canonical role is explicit.

### Poll-cycle comment batching

Newly discovered `/manul` comments on the same top-level Issue/PR conversation are grouped during one poll cycle when their task action, explicit agent selection, and `--auto` policy match. The earliest unprocessed comment anchors one queued task. The combined prompt includes every request's comment ID, author, URL, and request text; each original comment is independently persisted in `conversation_messages`.

Conversation history is not proof that a task trigger was consumed. Ordinary messages synchronized into `conversation_messages` must never suppress a later `/manul` request. Only messages explicitly marked `task-trigger` (or consumed `user-clarification` messages) participate in durable trigger deduplication. Every source comment in a batched task is linked to its anchor task with `conversation_links.linkType='task-trigger'`; replayable queue reset removes those links and their trigger markers together so the full batch can be rediscovered.

The agent must inspect the full request set and choose whether to combine related/dependent work into one cohesive change or split independent/conflicting work into ordered workstreams/subtasks. It may parallelize only when its runtime supports it and edits cannot conflict. Every request must be addressed.

The following are never grouped together: different Issue/PR conversations, different task actions, different explicit agent selections, different `--auto` policies, and `/manul continue` commands. A comment already recorded by a prior poll is excluded individually before choosing the batch anchor. Comments that arrive in a later polling cycle are not retroactively added to an already queued/running task. A submitted PR review keeps its existing one-task-per-review handling, including its inline review comments. When a review contains multiple inline comments, the same autonomous planning rule applies: combine related feedback and split independent/conflicting work into ordered workstreams/subtasks as appropriate. OpenCode receives a role through its native --agent <role> option when `opencode debug agents` returns a JSON entry whose `id` matches the role. If the plural command is unsupported, the adapter falls back to OpenCode V1's `debug agent <role>` probe. A malformed list or runtime/probe error is not treated as proof that the agent is missing; optional roles may fall back to the operator's `default_agent` or built-in `build`. OpenClaw, Codex, and Claude Code prepend the canonical role definition from ~/.agents/agents/<role>.md when it is present, with YAML frontmatter stripped. If that optional file is missing, they use the selected backend's default behavior; OpenClaw uses its configured main entry point. Agent definitions remain canonical; Manul must not copy them into another source directory. A role that is not permitted by Manul's `agents[]` configuration still fails closed.

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

Manual `--retry-stale` recovery requeues a terminal `stale` row through an
atomic compare-and-swap guarded by the full source identity. It must NEVER
terminate an executor or inspect, unlink, or otherwise modify an
`executor.pid` file. A liveness check followed by unlink is not safe: the
dispatcher can replace the marker with a fresh executor PID between those
operations. The dispatcher/runner exclusively owns executor PID-file creation
and replacement; orphaned-executor detection and termination remain the
daemon's responsibility. Retry-stale deliberately performs no executor or
PID-file cleanup after its CAS, even when a pre-existing marker appears dead.
`cleanup_orphaned_task_executors` responsibility, never the recovery CLI's.

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

The task-scoped heartbeat PID is a separate liveness signal from the long-lived
worker PID. A worker PID being alive does not prove that its heartbeat loop is
alive or successfully updating SQLite. Heartbeat database updates use a bounded
SQLite busy timeout and a configurable consecutive-failure limit
(`automation.heartbeatMaxConsecutiveFailures`, default 3). If the claim is
still owned but updates repeatedly fail or affect no row, the heartbeat must
log a `HEARTBEAT_UNHEALTHY` lifecycle event and exit non-zero so watchdog
recovery can detect it. If the claim was completed, requeued or otherwise lost,
the heartbeat exits normally without classifying the task as unhealthy.

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

A task lock/flock is a safety mechanism, not a replacement for SQLite ownership checks. Startup must serialize preparation and hold a separate OS-level daemon-owner lock for the full supervisor lifetime; a stale/reused PID must not allow a second supervisor to start. The dispatcher and daemon-owner lock descriptors must not be inherited by long-lived background helpers, workers, or isolated agent executors. Stopping/recovering a task must terminate the complete executor and heartbeat process trees—including descendants that create their own process groups—before the workspace can be reused. Stale recovery transitions the claim first, then terminates the task-scoped heartbeat child and executor tree; it may signal a heartbeat only when its PID, parent worker PID and Manul loop command identity match the exact claim, otherwise it leaves the process unsignalled so the changed SQLite ownership makes it exit normally. PID-file cleanup must not hide a still-running process. The daemon and watchdog must use the same task-scoped process-control helpers so recovery can rediscover an executor after a stale/missing PID file and does not signal unrelated/reused PIDs.



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

Delivery mode is explicit. `VERIFY` tasks are report-only: successful execution, a verified non-empty result comment with the exact task/attempt marker, and an unchanged repository are sufficient; no branch, commit, or PR are required. `IMPLEMENT` tasks normally retain branch/commit/PR validation even when status or progress comments have been posted. The presence of a comment alone never selects report-only delivery.

There is one narrowly-scoped informational exception for GitHub-sourced `IMPLEMENT` tasks: when the agent reports `TASK_DONE`, remains on the base/default branch, makes no repository changes, and publishes exactly one non-empty result comment carrying the exact current task/attempt marker, the task is accepted as comment-only delivery without a PR. The daemon first requires a non-empty current branch name, a valid current `HEAD`, and a resolvable initial commit baseline (detached HEAD is rejected), then checks repository cleanliness, verifies the marker, uniqueness, and meaningful user-facing body from the same comments read (or the already-confirmed marker-repair response), and sets a dedicated in-process `COMMENT_ONLY_DELIVERY` flag and emits the `IMPLEMENT_COMMENT_ONLY_DELIVERY` lifecycle event. Only this explicitly verified path skips PR-URL verification. A dirty base checkout, missing/stale/duplicate marker, empty result, or API uncertainty remains fail-closed; normal GitHub `IMPLEMENT` work still requires a verified PR and its canonical URL. This exception is separate from Todo `report_only` delivery and does not change the task's execution mode.

The daemon may verify the final PR identity and repository cleanliness before accepting completion.

## 8a. Lifecycle event publication and idempotency

Lifecycle events are machine-readable comments, not evidence that an agent completed
work. They are keyed by the exact task ID and execution attempt.

For the Team pause marker `TASK_WAITING_FOR_TEAM`:
- the OpenCode adapter recognizes it only from a real JSONL text event, never
  from tool input/output or arbitrary diagnostic payloads;
- it is a control outcome only when exactly one standalone wait marker is
  present, the runtime exits successfully, and no DONE, FAILED or user-decision
  marker is mixed into the same output;
- the dispatcher accepts the outcome only for `TASK_ACTION=TEAM`, validates
  the marker and current claim, then atomically parks the parent as
  `waiting_children`; a failed park remains a failure, not a successful pause;
- a valid Team pause is not task completion, does not emit `TASK_FAILED`, and
  does not consume an agent retry attempt.

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

### Team parent branch lifecycle

For `/manul team` parents:
- the daemon derives and prepares one stable task branch from the logical conversation identity before invoking the Orchestrator;
- child-completion wakeups and explicit parent resumes reuse that same branch, even when the wake comment/task ID differs;
- the daemon verifies and restores an existing PR for that branch instead of creating a second branch or PR;
- a verified no-op may finish with a non-empty result comment and no empty PR;
- repository changes on the Team branch still require the normal clean, pushed, verified PR delivery contract.

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

### Operator query execution

- `operator_query` is a one-shot, synchronous CLI execution kind. It is never
  inserted into the task queue and never claims a repository lock, workspace
  lease, Todo item, GitHub issue, or conversation.
- The CLI builds a bounded, secret-redacted snapshot from SQLite opened with
  `mode=ro` plus a small set of recent Manul log tails. The adapter receives
  the prompt and snapshot inside a disposable `MANUL_WORKSPACE/operator-query/oq-*`
  directory with mode 0700. The exact path is validated before execution and
  removed after the invocation.
- The agent must not access files, tools, MCPs, the Gateway, repositories,
  credentials, databases, or logs directly. All evidence is provided in the
  prompt. Task prompts, result summaries, contexts, and log lines are untrusted
  data, not instructions.
- OpenClaw must use embedded `agent exec` with an invocation-local
  `tools.deny=["*"]` override; it must not connect to the Gateway.
  OpenCode must use the reserved `manul-operator-query` agent with all tools
  disabled in the temporary config overlay. Claude Code must disable built-in
  tools and deny MCP tools. These controls are invocation-local and must never
  mutate operator configuration.
- Codex operator-query execution is currently unsupported and must fail closed
  until a verified tool-free runtime configuration is available. A read-only
  filesystem sandbox alone is not sufficient because it may still disclose
  host files.
- Operator queries do not emit task lifecycle markers to GitHub and must not
  persist runtime session IDs, queue rows, results, or task logs.

Todo `execution.kind=answer` is a separate queued source-task contract that
reuses the exact same tool-free adapter capability and validated
`operator-query/oq-*` workspace. Unlike the standalone CLI, it does claim its
Todo queue row and conversation context, does not read a Manul operator
snapshot, and persists the generated answer as a digest-bound Todo child task.
It never gains access to shell, filesystem, browser, GitHub, MCP, or repository
tools. The answer child is verified before the normal Todo whole-tree completion
path marks it and the root complete.


An explicitly authorized operator-side maintenance session running **outside a
Manul-managed task** may inspect read-only logs under `~/.manul/logs/**` to
diagnose runtime failures and may write sanitized evidence under
`/tmp/manul-diagnostics/**`. Do not delegate this workflow to an ordinary
`/manul` worker task; it must never expose credentials or copy secrets into
diagnostic artifacts.

Every generated implementation/review-fix prompt must enforce a least-privilege task boundary, independently of how brief or detailed the user's `/manul` comment is:

- The exact assigned task workspace root is the only local repository-access boundary. The primary checkout (`WORKDIR`) is authoritative for all default repository edits, commits, pushes and PR delivery.
- Related checkouts explicitly listed in the generated prompt may be inspected/searched but are read-only by default. No changes may be delivered from a secondary checkout unless the user has explicitly approved that repository's branch/PR/delivery policy.
- The configured Manul workspace base (`MANUL_WORKSPACE`, defaulting to `$HOME/.manul/workspace`) is private runtime state. Repository-backed tasks may access only their exact leased `ws-*` root directly below that base and its descendants. Todo implementation tasks use that same repository-backed lease and require an allowlisted repository. Todo informational `answer` tasks use only a validated, disposable `operator-query/oq-*` root directly below the same base; their adapter execution kind is mapped to the existing tool-free `operator_query` capability, with no repository, shell, filesystem, browser, GitHub, or MCP access. Legacy `report_only` queue records are stopped before agent launch; there is no Todo report-only workspace. Access to any sibling workspace, prior attempt, cache, database, prompt, log, adapter, daemon state, or runtime artifact is explicitly forbidden, including read-only inspection. The global OpenCode config must blanket-deny the default home-relative workspace rule; the adapter may add a temporary invocation-local config overlay allowing only the validated active task root and `<root>/**`. The overlay must not be persisted to provider/global config and must be deleted after invocation; sibling paths remain denied. Do not read/list/search/probe `~/.agents/**` or `~/.config/opencode/**`.
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

The watchdog is a liveness/recovery mechanism, not a general task scheduler. Its cron invocation is the periodic task-recovery mechanism (default every five minutes); the daemon performs a separate startup recovery pass only.

It may:
- restart an enabled daemon that is not running;
- remove a stale daemon lock;
- reclaim stale workspaces;
- recover a running claim when its lease is stale, its worker is dead, or its task-scoped heartbeat process is missing/unhealthy.

It must not:
- reset healthy running tasks;
- reset all tasks merely because a lock is old;
- create a second independent retry policy;
- terminate an executor based only on a stale SELECT snapshot.

Before signalling any executor, recovery must atomically transition the exact running claim using its claim token, worker PID, heartbeat timestamp and lease timestamp as compare-and-swap conditions. If the row changed (including a concurrent heartbeat refresh or new claim), recovery must skip process termination. A queued retry must retain at least a fifteen-second dispatch delay so the previous heartbeat and executor process trees can be stopped before the task PID files are reused. Concurrent watchdog invocations must be serialized.

The daemon also performs a recovery pass at loop startup; this is a deliberate startup safeguard and not a competing retry mechanism.

## 15. User-decision contract

When the agent materially needs user input it must:
1. emit the structured needs-user block;
2. let Manul persist `blocked_user`;
3. stop treating that execution as success/failure;
4. resume the same task context after `/manul continue <answer>`.

Equivalent implementation choices should be resolved by the agent without blocking the user.

## 16. Human and bot modes

The top-level configuration key `mode` selects Manul's GitHub presentation/attribution behavior. It does not select the writing style or quality of the delivered work.

The following user-facing content contract applies in every mode and across all execution runtimes:

- Branch names, commit messages, PR titles/descriptions, comments, report summaries, and generated documents must read like natural, task-focused work from a competent human teammate.
- Names and descriptions must be based on the requested change, not the way a task was received or the tool/runtime that performed it.
- Do not expose internal task sources/providers, transports, MCP server names, orchestration/automation names, agent/runtime/provider names, source labels, task IDs, comment IDs, attempt numbers, or internal workspace paths. Terms such as Manul, Todo, MCP, OpenCode, OpenClaw, Codex, and Claude Code are appropriate only when genuinely part of the requested product or technical change.
- Do not put internal task/source/attempt identifiers into branch names. Use short semantic names and resolve collisions with ordinary numeric suffixes.

Mode-specific attribution remains unchanged:

- `bot` is the default and preserves the existing Manul signature, lifecycle/status/error comments, and AI commit attribution. The required bot result-comment signature remains exactly `— manul 🐈`.
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
- allowed users;
- one top-level `.repositories` array shared by GitHub Issues polling and Todo repository routing;
- agent names;
- `automation.agentRuntime` (default `openclaw`) as the sole backend selector for all tasks;
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

The location of this configuration is `~/.manul/config.json`. The operator's
exported process environment (including `PATH`, provider settings and tool
locations) comes from the existing `~/.zshrc`. Unattended entrypoints load that
same file through `manul-zsh-bootstrap.sh`; `~/.manul/.env` is reserved for
Manul-specific integration fallbacks and is not a second PATH/provider config.
The semantics of these controls should not change accidentally.

## 18. Runtime boundary

Manul task contracts are runtime-neutral. The daemon never invokes an agent
runtime directly; it calls `AgentExecutionController.execute`, which routes
through `AgentExecutor` to a backend adapter.

Adapters are independent backends behind a single ProcessRunner.run() process boundary. The single automation.agentRuntime setting (default OpenClaw) selects the backend for every task. Role selection is adapter input, not backend selection. Supported values are openclaw, opencode, codex, and claude-code. Adapters must not spawn subprocesses directly and must not depend on each other.

For OpenCode 2.x, the adapter must set the exact task workspace as the child
process working directory through `ProcessRunner.run --cwd`; it must not pass
`--dir` to `opencode run`, which does not accept that option.

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

### Canonical skill and agent-definition locations

Mapped project skills and the Todo project catalog are read only from
`~/.agents/skills`. The skill root is fixed: Manul must not accept an
alternate skills-root environment variable, scan another global checkout, or
fall back to a copy beside the Manul source/runtime. A missing skill is skipped
with a diagnostic; it must never cause a search in a second directory.

Codex and Claude Code canonical role definitions are read from
`~/.agents/agents/<role>.md` by default. These role definitions are separate
from project skills and are not copied into Manul or runtime-specific trees.

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

For both Todo providers, a normal `/manul <request>` trigger is routed from
the complete task tree: the root description and every nested subtask
description are considered together. A GitHub repository URL, an exact
configured `owner/repo` reference, a configured short name written as
`repo <name>` or `repository <name>`, or one unambiguous catalog alias selects
repository-backed execution. Short names are matched only against the final
segment of the top-level `.repositories` allowlist; for example, `repo todo`
selects `mariuszmarzec/todo` when that is the unique configured repository
ending in `todo`. The project catalog is not needed for URL, full-name, or
configured short-name routing. The legacy `/manul report <question>` spelling
is only a trigger alias; it cannot select a different execution mode.

Todo MCP tasks use two explicit execution contracts; `report_only` is
disabled for new tasks.

A clear informational question with no repository target is normalized to
`action=ANSWER` and `execution.kind=answer`. The poller accepts this kind only
for Todo sources, only with an empty repository field, and only with the ANSWER
action. The dispatcher uses the validated `MANUL_WORKSPACE/operator-query/oq-*`
workspace and passes the existing `operator_query` tool-free capability to the
selected runtime. It supplies the current Europe/Warsaw date/time, requires a
non-empty `TASK_DONE` answer, saves that answer as an idempotent,
digest-bound OPEN child task, reads it back, and only then marks the complete
Todo tree done (root last). The generated `answered` child is excluded from the
source fingerprint only while its marker and payload digest remain valid.

Implementation/repository-investigation tasks use
`action=IMPLEMENT` and `execution.kind=repository`. A missing repository,
multiple different repository references in one task tree, duplicate configured
short names, ambiguous catalog aliases, and repositories outside the global
`.repositories` allowlist are never downgraded to answer mode or report-only.
Instead, Manul creates and verifies an OPEN child task that summarizes the
routing checks and asks for the exact repository or a correction to the
ambiguous/disallowed reference. Editing that child invalidates its digest-bound
marker and creates a new source version. The common poller rejects legacy Todo
`report_only` queue entries, and the dispatcher migrates any already-persisted
legacy entry before agent launch.

Todo providers do not select a configured default repository. For each active
root, routing searches the complete tree and gives explicit GitHub URLs and
configured repository names precedence over catalog aliases. Otherwise, the
longest whole-phrase alias in the optional project catalog
(`~/.agents/skills/globalskills-repository/project-repositories.json`) must
identify exactly one canonical `owner/repo`. The catalog supplies aliases and
optional mapped project skills. The top-level `.repositories` list remains the
only access allowlist. Mapped skill files are read only from
`~/.agents/skills/<skill>/SKILL.md`; a missing skill file is skipped.

The top-level `.repositories` array in `~/.manul/config.json` is the single
operator-controlled repository list for all task sources. GitHub Issues polling
uses it directly; Todo Local and Todo Remote use it both to recognize configured
repository names and as the access allowlist. Per-source repository lists and
`repositoryAllowlist` fields are not configuration inputs and cannot widen or
narrow this list. The curated catalog supplies optional aliases and mapped
project skills, but does not grant access. Direct URLs, configured full names,
configured short names, and catalog aliases must all resolve to a repository in
the global list. A missing, ambiguous, or disallowed project reference produces a visible OPEN routing subtask; it is never treated as informational work. The route already stored with a
queued task is reused across retries; changing the catalog does not silently
retarget existing queue rows.

The two Todo providers are separate adapters with different MCP tool names and
authentication. Local uses the existing loopback bridge without a bearer token
and is available only after an unauthenticated MCP initialize plus read-only
`tools/list` handshake succeeds. Remote uses Fiteo's HTTP(S) `/mcp` endpoint
and a PAT from an environment variable. HTTPS is required on untrusted/public
networks because HTTP does not encrypt the bearer token in transit.
Tokens never appear in normalized task JSON or configuration values.

The Streamable HTTP Todo MCP client and local endpoint resolver are owned by
the standalone Manul repository and installed into `~/.manul` with the other
runtime scripts. The local adapter resolves both helpers relative to its own
canonical source directory; environment overrides exist only for isolated
fixtures and explicit operator customization. Neither Manul nor its poller
requires a globalskills/aicode checkout. Native Linux and macOS connect to
Todo Desktop's direct loopback endpoint; WSL may use the optional reverse
bridge started by aicode. The client performs an unauthenticated MCP
initialize/tools/list handshake for local Todo and uses no Todo bearer token.

At daemon startup, Manul runs a non-fatal task-source preflight and records
provider readiness or missing dependencies in `~/.manul/logs/daemon.log`.
The poller records a distinct success or error for each enabled provider in
`~/.manul/logs/poll.log`; a failed optional provider does not prevent healthy
providers or the daemon from continuing. Missing standalone transport files
are an explicit provider error, never a successful silent skip.

Caracal remains operator-owned. If the operator's static effective OpenCode
configuration enables `caracal-rag`, the OpenCode adapter refreshes its live
provider URL/token from `~/.caracal/env.sh` for each task and passes them only
to the child OpenCode process. Before agent startup, Manul checks the MCP
connection using the exact OpenCode binary, workspace, effective configuration
and process environment that will run the agent. If the Caracal provider cannot
be prepared or OpenCode does not report the server as connected, Manul disables
only `caracal-rag` in the temporary task overlay, clears its credentials from
the agent process, records a diagnostic and continues without Caracal. This is
an optional capability, not a pre-execution infrastructure failure. Provider
secrets are never copied into `~/.manul/.env`, task artifacts or logs.

Manul also checks every MCP entry it creates in the temporary OpenCode overlay.
An entry that is not reported as connected is removed from that task overlay
before the agent starts, and its corresponding Manul-owned URL/token variables
are cleared from the agent process environment. The aggregate `opencode mcp list` exit code is not
used as a global gate: one unrelated operator-owned server being offline does
not block the task. Operator-owned MCP entries other than Caracal are never
removed or rewritten by Manul. OpenCode continues to load the operator's JSON
and JSONC files itself; Manul preserves `OPENCODE_CONFIG` and all operator
configuration files and contributes only its temporary
`OPENCODE_CONFIG_CONTENT` overlay. If Caracal is absent or disabled in the
operator's effective static configuration, its provider is not loaded or
required.

### OpenCode model/provider ownership

The effective OpenCode configuration is owned by the machine/operator and may
select a different model/provider on each installation. Manul must use that
selection without interpreting or changing it. The adapter must preserve
`OPENCODE_CONFIG` and all operator JSON/JSONC configuration, and its temporary
`OPENCODE_CONFIG_CONTENT` overlay must not contain top-level `model` or
`provider` fields. It must not pass a model-selection flag to `opencode run`,
synthesize a provider, select a fallback, or assume LiteLLM/OpenCode Go/Ollama
or any other backend. The overlay is limited to Manul-owned task permissions,
MCP entries and purpose-specific synthetic agent definitions; synthetic agents
must inherit the configured model and must not declare their own model. Tests
must prove that an arbitrary operator-selected model/provider survives while
the Manul overlay adds its own runtime controls. Any change to this boundary is
a behavioural-contract change and requires explicit user direction.

### Operator Zsh environment

The operator's existing ~/.zshrc is the single source of truth for exported
runtime settings, including PATH, OpenCode/LiteLLM/FreeLLMAPI configuration,
Node and other tool locations, and exported credentials. Manul's shell
integration marks an already initialized interactive Zsh process so commands
do not start nested shells. Unattended/direct entrypoints (including the cron
watchdog and direct daemon startup) must use manul-zsh-bootstrap.sh, which
runs zsh -ic, marks the environment initialized, and then execs the
unchanged Bash entrypoint. Manul scripts remain Bash; do not move PATH to
.zshenv, duplicate it in ~/.manul/.env, or synthesize a second PATH in
the daemon/watchdog.

~/.manul/.env is retained only for Manul-specific integration credentials
and backwards-compatible fallback values. Values exported by ~/.zshrc
always win, and bootstrap must not copy the active shell environment into this
file. Do not persist provider binary/config paths or arbitrary exported
variables there.

OpenCode task runs use the shared OpenCode service (no --standalone) so
Manul and interactive sessions use the same server, selected model/provider,
and process environment. The explicit OPENCODE_CONFIG path may be supplied
from the operator's Zsh environment or retained in ~/.manul/.env as a
non-secret path fallback; an exported Zsh value always wins. Preserve
OPENCODE_API_KEY and the operator's configured provider credentials; that
key is not an instruction to select OpenCode Go.

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

Every successful repository-backed Todo task must publish a non-empty
`completed` result subtask containing the agent's actual result (for example,
review findings, blockers, changed files, verification, and a PR URL when one
exists). The daemon reads the child back and verifies its parent, status marker,
payload digest, and source version before marking the complete Todo tree done.
The Manul task may enter `completed` only after this provider-side delivery is
confirmed.

Terminal execution failures must publish a verified OPEN `failed` result
subtask containing the failure stage and redacted reason. A failed task keeps
its Todo root active so the user can correct the problem and retry.

Both result types are first written to a durable SQLite outbox. The worker makes
an immediate delivery attempt; if Todo is unavailable, the outbox retries with
bounded exponential backoff without rerunning completed agent work.
Successful results remain in `delivery_pending` (visible and excluded from
dispatch) until the report and whole Todo tree are verified. A completed report
can be safely re-read after partial whole-tree completion; its signed payload
marker is excluded from the source fingerprint only while its digest verifies.
Informational answer tasks continue to persist their non-empty answer as a
verified `answered` Todo child before marking the tree done. Missing user input
creates a verified OPEN blocker subtask.

The task-source identity is the root work item. A pull request, review
comment, or CI check is never a task-source root. Those artifacts may be linked
as context to a task owned by another source.

The default source is `github_issues`. The top-level `.repositories` array is
always authoritative, whether or not explicit `.taskSources` are configured.
Enabled provider entries define provider settings only; nested repository lists
are ignored at runtime and removed by the installer migration.

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
- `DELIVERY_COMMENT_EMPTY` — the task/attempt marker exists, but the result comment contains no meaningful user-facing content.
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



## 24. Runtime update contract

The operator-facing `manul --update` command updates an existing canonical
checkout and deploys its scripts into the existing runtime:

- The canonical checkout must be the standalone `mariuszmarzec/manul` repository
  on `main`, with a clean working tree.
- Updates fetch `origin/main` and use fast-forward-only semantics. Local commits
  ahead of or diverged from the remote are never reset, rebased, or overwritten.
- The command invokes the normal installer without `--init-state`. A missing
  or empty `~/.manul/state/manul.db` is a hard failure; update must never create
  a fresh database implicitly.
- Existing configuration, environment, task state, artifacts, logs, locks and
  workspaces remain owned by the runtime and are not reset by the updater.
- The updater does not stop or restart the daemon, claim/requeue tasks, terminate
  workers, or edit leases/locks. A running daemon may retain functions loaded
  before deployment; any restart is a separate operator action after active
  task and lease ownership has been inspected.


## Specification-driven repository policy

An optional root file `.specification/config.yaml` opts a repository into
`mode: specification-driven`. Absence of that file means the standard
workflow. Manul never creates the file implicitly.

- `/manul sdd bootstrap` is the only initialization path. It performs a
  baseline audit and opens a Baseline PR containing specification and config,
  but no product-code changes. SDD becomes active only after the Baseline PR
  is merged.
- `/manul sdd <task>` requires an initialized repository; without the config
  it fails before model invocation.
- Ordinary implementation and review-fix tasks in an SDD repository are routed
  through the Orchestrator and SDD agent. Direct Coder/Architect role commands
  cannot bypass the specification gate.
- Before model invocation, Manul validates the config, the `agents[]`
  allow-list, canonical `sdd` and `orchestrator` definitions, and the shared
  SDD skill. Native OpenCode roles are verified as well. Missing prerequisites
  fail closed; the default runtime agent is never substituted.
- Specification PR and Implementation PR are separate. The implementation
  task is pinned to the approved specification commit and requirement IDs.
- Review-fix work must remain within the approved requirements. A new or
  changed behavior requirement returns to the Specification PR gate.

### Durable workflow checkpoints

Agents may emit a bounded
`MANUL_WORKFLOW_STATE_BEGIN` / `MANUL_WORKFLOW_STATE_END` JSON block.
The daemon validates and stores it in `workflow_instances` and the
append-only `workflow_events` tables in `manul.db`. Checkpoints are bound to
the task's trusted repository, secret-like fields are redacted, and replayed
events are idempotent. The next task in the same conversation receives the
latest checkpoint as prompt context. Agents never access Manul's DB directly.

The workflow registry is additive to the task/lease/runtime-session state. It
is generic across workflow types and does not introduce a graph engine.
GitHub PR merge state, approved spec commits and repository artifacts remain
the authority for approval and recovery decisions.


## 21. Generic monitor contract

Generic monitors are separate from the proactive PR comment watcher and the
existing CI/conflict PR automation policies. Those features retain their
existing configuration and event semantics.

- The authoritative monitor registry is `~/.manul/state/monitors.db`. It is
  owned by Manul. Agents and operators must create, update, pause, resume,
  inspect, run and delete monitors through `manul-monitor`; direct SQL edits
  and agent-owned schema migrations are forbidden.
- Monitor definitions are JSON files under
  `~/.manul/monitors/<id>/monitor.json`. IDs are stable, path-safe lowercase
  identifiers. Definition updates preserve run, event and delivery history.
- Every monitor has an independent workspace, log directory, run-artifact
  directory and non-blocking process lock under `~/.manul/monitors/<id>/`.
  The workspace is monitor-owned data. It may contain arbitrary monitor-local
  files or a database chosen for that monitor; it must not be treated as part
  of the global registry.
- Soft deletion disables a monitor and retains its definition, workspace and
  history. The runtime must not garbage-collect monitor workspaces as ordinary
  task workspaces.
- The first supported source is `github_pull_requests`. The special
  repository selector `configured` resolves to the top-level Manul
  `.repositories` list. Explicit repositories must be a subset of that list;
  monitor configuration cannot widen the repository allowlist.
- The PR source considers open PRs created after monitor registration.
  `excludeSelf` compares the PR author with the authenticated `gh` account;
  `excludeDrafts` excludes draft PRs. Older PRs are not backfilled when a
  monitor is created.
- The poller schedules due monitors after regular repository polling and
  starts each one in a detached process. Monitor work must not block the task
  poller. A per-monitor lock prevents two runs of the same monitor from
  executing concurrently; different monitors remain independent.
- Event identity is unique per monitor and GitHub PR-open event. Duplicate
  polls must not create another event or output. Each output has its own
  delivery record; a failed output stays pending and is retried independently
  of outputs already delivered.
- Todo outputs require their matching enabled Todo task source. A Todo event
  is written with a stable marker and read back before the delivery is marked
  complete. A lost MCP response must not create a duplicate on retry.
- The initial output set is `log`, `todo_local` and `todo_remote`. Todo
  reminder tasks do not carry the `/manul` trigger; they do not automatically
  start a Manul task.
- Supported monitor definitions are validated by the CLI. Unknown source or
  output types, invalid intervals, malformed IDs, disabled Todo providers
  and repository references outside the global allowlist fail closed.

