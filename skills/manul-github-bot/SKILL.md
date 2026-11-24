---
name: manul-github-bot
description: Operate, install, and debug Manul, including GitHub command tasks, isolated workspaces, generic scheduled monitors, and the current agent runtime. The canonical executable source is this skill directory.
---

# Manul GitHub Bot 🐈

Manul is a GitHub command bot and local task orchestrator.

It watches configured repositories, reacts to `/manul` in issue bodies, issue/PR conversation comments, and PR review comments, then:
- batches compatible new `/manul` comments from the same Issue/PR conversation when they are discovered in one polling cycle, while keeping each original comment in conversation history;
- asks the agent to plan whether batched requests should be combined or handled as separate ordered workstreams; submitted multi-comment PR reviews use the same planning rule within their existing one-task-per-review flow;

- creates or resumes a task;
- prepares an isolated workspace;
- gives the agent a task-scoped workspace root, a separate primary checkout, and read-only related repository checkouts; private runtime/global-skill directories and other tasks’ workspaces remain off-limits;
- lets the agent determine whether the request is informational or requires repository changes;
- executes the task through the current agent runtime;
- verifies the result;
- pushes repository changes and verifies a real PR when required;
- posts lifecycle and result feedback on the original GitHub conversation.

In `bot` mode, every Manul-authored comment ends with:

`— manul 🐈`

The top-level configuration key `mode` controls attribution behavior. It defaults to `bot`. In `human` mode, Manul does not append its signature, does not publish lifecycle/status/error comments, and AI-created commits must not contain a `Co-authored-by` trailer. The agent still posts its actual user-facing result comment.

Read these files before making architectural changes:

- `AGENTS.md` — agent guardrails;
- `ARCHITECTURE.md` — ownership/dependency model;
- `CONTRACTS.md` — behavioural invariants.

## Current runtime

The current implementation uses:

```
MANUL_DIR=${MANUL_DIR:-$HOME/.manul}
```

Path resolution and runtime validation are centralized in
`manul-paths.sh`. The single `AGENT_RUNTIME` setting (default: `openclaw`)
selects the backend for every task, whether or not a canonical role is
explicit. Supported values are `openclaw`, `opencode`, `codex`, and
`claude-code`. The config key is `automation.agentRuntime`; the installer
removes the obsolete `automation.roleRuntime` key from existing configs.
Legacy `ROLE_RUNTIME` environment overrides are ignored. There is no
`OPENCLAW_MANUL_DIR` alias and no fallback to `~/.openclaw/manul`.

The OpenCode adapter can resume an existing session internally when the
runtime explicitly reports its step limit. The maximum number of additional
same-session resumes is configured by
`automation.opencodeMaxStepLimitContinuations` in `~/.manul/config.json`
(default: 3, valid range: 0..20). These internal resumes share the original
execution timeout and do not consume additional Manul attempts.

The OpenCode, Codex CLI, and Claude Code adapters apply the no-progress
watchdog controlled by `automation.agentNoProgressTimeoutSeconds` in
`~/.manul/config.json` (default: 900 seconds; use
`MANUL_OPENCODE_NO_PROGRESS_TIMEOUT`, `MANUL_CODEX_NO_PROGRESS_TIMEOUT`, or
`MANUL_CLAUDE_NO_PROGRESS_TIMEOUT` for a runtime-specific override). Actual
JSONL stdout or stderr activity resets the timer; task-heartbeat updates do not.
For OpenCode, an unfinished step and an explicitly active tool call are tracked
separately. Codex and Claude Code active tool calls are recognized from their
JSONL events, so the generic idle timer pauses while a tool is active. All active
tools remain bounded by `automation.agentToolNoProgressTimeoutSeconds` (default
3600 seconds; overridden with `MANUL_CODEX_TOOL_NO_PROGRESS_TIMEOUT` or
`MANUL_CLAUDE_TOOL_NO_PROGRESS_TIMEOUT` for those runtimes). On expiry,
`ProcessRunner` terminates only the isolated runtime process group, emits the
appropriate timeout cause, and retains raw JSONL/stderr diagnostics.

For each OpenCode invocation, the adapter appends a runtime-capability snapshot
to the initial prompt and every resumed turn. It identifies the assigned
workspace and lists the effective V2 `external_directory` permission rules
from the invocation config without exposing the rest of the config. The snapshot
is advisory context, not a permission grant: tool-level and path-level checks
remain authoritative.

When OpenCode reports a permission denial and exposes a resumable session, the
adapter permits exactly one same-session recovery turn inside the original
timeout budget. The recovery prompt requires the agent to stop using the denied
operation, not to route around the same restriction, and to pursue an independent
in-scope alternative (for example, rerunning a build and saving diagnostics in
the task workspace). Permissions are never widened automatically. If the
recovery turn is denied again, or there is no resumable session, the task fails
with a sanitized `RUNTIME_PERMISSION_BLOCKED` diagnostic.

The installer deploys the runtime scripts as symlinks.

Canonical source:

```
~/.manul-repo/skills/manul-github-bot/
```

Current runtime:

```
~/.manul/
├── config.json
├── .env                # Manul-specific integration fallbacks (mode 600)
├── state/
│   ├── manul.db
│   ├── locks/
│   └── tasks/
├── logs/
└── workspace/
```

The runtime contains Manul configuration, SQLite state, logs, locks, task
artifacts, workspace state, runtime script links, and an optional Manul-specific
integration fallback file .env. OpenClaw and other provider configuration
remain outside that ownership boundary. The operator's existing ~/.zshrc is
the single source of truth for exported environment, including PATH, provider
configuration and tool locations. Interactive commands inherit it from the
shell; unattended/direct entrypoints use manul-zsh-bootstrap.sh to run zsh -ic
and then exec the existing Bash scripts. The cron watchdog bootstraps itself
before starting/recovering the daemon. No second PATH is maintained in Manul.
Existing .env values are only legacy/Manul-specific fallbacks: exported Zsh
values win, and installer bootstrap does not duplicate the active shell
environment there.

The daemon removes regular files under `~/.manul/logs` and the legacy startup
wrapper log `~/.manul/daemon.log` when they have not been modified for more than
seven days, and prunes empty task-archive directories. This log-file retention is
independent from SQLite task-history retention; other files are not affected.

A leased workspace is a task-owned **root**, not a Git repository itself. The
workspace layout is:

```
~/.manul/workspace/ws-<id>-<timestamp>/
├── repos/
│   └── <owner>/<repository>/    # primary and task-scoped related checkouts
└── tmp/                         # scratch owned by this task/context
```

The primary checkout lives at `repos/<owner>/<repository>` and remains the only
checkout used for branch setup, commit/push, PR validation, and task delivery.
Configured related repositories may also be cloned under the same workspace
root for context and dependency inspection. They are read-only by default; a
task must not modify or deliver a secondary repository without explicit user
authorization and a separate delivery policy.

The workspace root is the security and lifecycle boundary. Never grant agents
access to all of `~/.manul/**`: they may access only the exact leased workspace
and descendants, not sibling workspaces, shared repository caches, logs, DB,
configuration, adapters, or global skills. Related-repository paths are
normalized to GitHub `owner/repository` identifiers; traversal and symlink
escapes are rejected.

If Git cannot switch/reset a task checkout safely, Manul must attempt a fresh
clone of the repository remote at the task's explicit target
branch. Standalone tasks use the branch selected by the base-branch policy;
PR/review tasks use that PR's actual head branch, never an assumed `master`.
Before replacing the checkout, Manul moves the previous checkout intact to
`tmp/checkout-recovery/` inside that task workspace. If the required remote
branch is unavailable or recovery cannot be verified, the task fails with a
concrete diagnostic rather than falling back to another branch. The recovery
backup is not the active checkout; `WORKDIR` remains authoritative.

Before stale/broken workspace cleanup deletes its DB mapping, the full task-owned
workspace root is moved into a private archive under
`~/.manul/state/recovery/workspaces`. This retains staged, unstaged and
untracked implementation work. A retry may restore only the snapshot matching
its original workspace ID and task ID; snapshot preservation/restore failures
must leave data on disk and emit an actionable error. The archive is outside the
agent's allowlisted workspace and must never be exposed through broader
OpenCode path permissions.

### Workspace and repository-cache garbage collection

The daemon and watchdog run the conservative `workspace-gc.sh` collector under a
single `flock`. It reconciles interrupted GC leases even when the normal sweep
interval has not elapsed, and never removes a BUSY workspace or a workspace
referenced by a queued, running, or user-blocked task.

Default retention:
- Unbound IDLE workspaces are eligible after 1 hour.
- Issue/review contexts without a linked PR are eligible after 30 days without use.
- A PR-linked context is eligible only after GitHub confirms every attached PR
  has been closed for at least 7 days. API failures and open/reopened PRs retain
  the workspace.
- Recovery snapshots are retained for 30 days from archive creation.
- Shared repository caches are eligible after 30 days without successful use.
  The collector acquires the same per-repository lock as `ensure_repo` before
  removing a cache.

Expired workspaces and unregistered workspace directories are moved, not
immediately deleted, into the private recovery area. Expired recovery snapshots
are then removed after their retention window. The shared cache remains
reusable across task workspaces and is only removed when its usage timestamp
has expired, its canonical GitHub origin is verified, and no repository lock
or running task protects it.

Retention can be overridden with the `MANUL_WORKSPACE_GC_*` environment
variables: `INTERVAL_SECONDS`, `IDLE_HOURS`, `CONTEXT_DAYS`,
`CLOSED_PR_DAYS`, `RECOVERY_DAYS`, `REPO_DAYS`, and
`PR_CACHE_TTL_SECONDS`. The standalone command
`workspace-gc.sh --force` bypasses only the interval gate; it does not bypass
any safety checks or retention thresholds.

Startup serializes the entire workspace-preparation path and holds a separate
OS-level owner lock for the supervisor's lifetime. Worker processes must close
that lock descriptor so a worker cannot keep a dead supervisor's lock alive.

## Agent execution boundary

The daemon never invokes an agent runtime directly. It calls
`AgentExecutionController.execute`, which routes through `AgentExecutor`:

```
All tasks -> AGENT_RUNTIME -> OpenClaw / OpenCode / Codex / Claude Code
Role selection -> adapter input, never a second runtime selector
```

This means a plain `/manul run <task>` uses the configured backend (OpenClaw by default), and `/manul run --agent coder <task>` uses that same backend when its role definition is available. OpenCode uses its native `--agent` option when `opencode debug agents` returns a validated JSON entry whose non-empty `id` matches the role. Agent discovery normalizes harmless startup/log text, ANSI control sequences, and supported JSON response envelopes before validating the list; malformed output and runtime errors remain retryable discovery failures, never proof that a role is missing. The shared `opencode_agent_list.py` parser is installed with the runtime adapter so SDD policy and runtime routing apply the same strict validation. If the plural command is unsupported, Manul falls back to OpenCode V1's `opencode debug agent <role>` probe. OpenClaw, Codex, and Claude Code prepend the role definition from `~/.agents/agents/<role>.md` when it exists. If that optional file is missing, the selected backend's default is used (OpenClaw's configured `main`). A role name that is not allowed by Manul's `agents[]` configuration is still rejected. This is direct CLI execution through the selected adapter, not an ACP session spawned by OpenClaw.

Use `/manul --auto run <task>` to run one task directly through OpenCode's
native `opencode run --auto` option. Manul persists this per-task choice in
the queue and passes the flag only to the OpenCode adapter; it is an explicit
per-task override, not another configured runtime. OpenClaw does not support this mode.

Codex and Claude Code are non-interactive CLI backends. Codex runs with the `workspace-write` sandbox and explicit non-interactive approval policy. Claude Code uses `--print --output-format stream-json --permission-mode acceptEdits`; it never enables `--dangerously-skip-permissions` or `bypassPermissions`. Shell/MCP actions must be permitted by the operator's existing Claude Code settings. Codex CLI's `workspace-write` mode keeps command network access disabled by default. If Manul tasks must use remote `git`/`gh` operations, enable `[sandbox_workspace_write] network_access = true` in the operator's `$CODEX_HOME/config.toml` (normally `~/.codex/config.toml`); Manul does not silently override that security setting. Network access broadens the destinations a task can contact, so leave it disabled for offline tasks or configure Codex's network proxy/domain policy as appropriate.

Adapters are independent backends behind a single `ProcessRunner.run()`
process boundary. They must not spawn subprocesses directly and must not
depend on each other. The adapter owns runtime-specific session invocation and
continuation mechanics. Manul owns the persisted session pointer used to resume
a task: it retains a runtime session ID only when the current claim returns
`NEEDS_CONTINUATION` with a non-empty ID. Completion, ordinary failures, and
invalid continuation results clear that pointer without deleting the workspace
or conversation mapping. This runtime continuation is distinct from
`/manul continue <answer>`, which resumes a task blocked on user input.


## Team Workflow

Use `/manul team <goal>` to ask Manul to plan and coordinate a feature across
multiple independent tasks. The incoming task may originate in GitHub Issues
or Todo; that source does not select where child tasks are tracked.

Manul validates the target repository's optional `.manul/team.yaml` before
starting the Orchestrator. `prApprovedByMan` defaults to `true`. GitHub
Issues is selected when enabled; when it is disabled, the single enabled Todo
provider is selected. If multiple Todo providers are enabled, list the
intended providers explicitly instead of letting Manul guess. Multiple
trackers may be deliberately enabled, but tasks are not automatically
duplicated across them.

The Team skill is installed from Globalskills at
`team-workflow/SKILL.md`. It uses the existing Orchestrator, SDD lifecycle,
specialist roles, task-source adapters, workflow checkpoint registry and
Manul execution workspaces. Every independently executable work item must be
a separate root task to receive its own Manul workspace. Nested Todo subtasks
remain ordered steps within one task and do not create separate executions.

The parent is event-driven, not a barrier over the full child set. When one
logical work item reaches a terminal state across its tracker references, the
coordinator wakes the parent even if sibling tasks are still running. Multiple
new completions are batched into one wake; later completions can wake it again.
Stable event signatures prevent duplicate delivery when polling or re-parking.
The parent processes pending child events, can dispatch newly unblocked work,
then parks again while other items remain active. A child that completes while
the parent is running is picked up after its next park.

A Team request in an SDD-enabled repository is routed to the SDD lifecycle
owner. SDD specification and human approval gates remain mandatory even when
`prApprovedByMan: false`.

Optional repository configuration:

```yaml
version: 1
prApprovedByMan: true
trackers:
  - github_issues
```

The file is optional; omitting it keeps human approval as the default and
uses deterministic tracker resolution.

## Task sources

The root work item is owned by a configured task source. GitHub Issues are the default source. Additional providers can be enabled in `.taskSources[]` and are polled independently.

PRs, review comments and CI checks are related development context, not task sources. A source can have multiple PRs attached to it.

Current provider types:

- `github_issues` — default, backed by GitHub repositories.
- `jira_tasks` — Jira REST provider, disabled by default.
- `todo_local_mcp` — separate Todo Desktop MCP source. It selects active root tasks whose description or any nested subtask contains a line beginning with `/manul`; the complete parent tree is queued once. The Streamable HTTP client and endpoint resolver are bundled with Manul, so local polling does not require globalskills/aicode.
- `todo_remote_mcp` — separate Fiteo backend MCP source. Its `url` accepts `{env:VARIABLE}` placeholders (for example `"{env:FITEO_BASE_URL}/mcp"`). Set `manulUserIdEnv` to the name of an environment variable containing the positive numeric ID of the Manul Fiteo account; legacy numeric `manulUserId` remains supported. Sharing with that account and `EDITOR_AND_VIEWER` grants visibility; execution additionally requires a `/manul` command in the root description or any nested subtask. A nested trigger queues the complete parent tree once.

For either Todo provider, every ordinary `/manul <request>` is routed
automatically using the complete Todo task tree, including root, child, and
grandchild descriptions. A GitHub URL, an exact configured `owner/repo`
reference, a configured short name written as `repo <name>` or
`repository <name>`, or one unambiguous project alias selects
repository-backed execution. Short names are matched against the final path
segment of the top-level `.repositories` allowlist; for example, `repo todo`
selects `mariuszmarzec/todo` when it is the only configured repository named
`todo`. Direct URLs and configured repository names/short names work even
when the optional project catalog is unavailable. The legacy
`/manul report <question>` spelling is accepted only as a trigger alias: it
does not select a separate execution mode.

Todo MCP tasks use one of two explicit execution kinds; neither is
`report_only`:

- A clear informational question that does not require a repository is queued as
  `execution.kind=answer` with `action=ANSWER`. It runs in the validated,
  disposable `operator-query/oq-*` workspace through a tool-free runtime:
  no repository checkout, shell, filesystem, browser, GitHub, or MCP access.
  Manul supplies the current date/time in Europe/Warsaw for questions such as
  today's weekday. A non-empty answer is saved as a verified child task titled
  **Odpowiedź**, and only then is the complete Todo tree marked done.
- Implementation and repository investigation tasks use
  `execution.kind=repository` and require one allowlisted repository. If the
  repository is missing, ambiguous, or disallowed, Manul does not start the
  agent: it creates an OPEN routing subtask explaining what was checked and
  asking for the exact `owner/repo`, GitHub URL, or configured alias. Editing
  that subtask creates a new task-source version and re-triggers routing.

Legacy Todo `report_only` queue entries are rejected/migrated; new Todo tasks
cannot select that execution mode.

Todo sources do not have a fixed project repository. Each Todo root resolves its
execution target independently from the full task tree. Explicit GitHub URLs
and exact configured `owner/repo`/short-name matches take precedence over
catalog aliases. Multiple distinct repository targets in one task tree,
duplicate configured short names, ambiguous aliases, and targets outside the
global list fail closed and are not queued. The project catalog
(`~/.agents/skills/globalskills-repository/project-repositories.json`) supplies
aliases and optional mapped project skills; the top-level `.repositories`
array remains the only access allowlist. Missing mapped skill files are skipped
rather than blocking execution. Manul reads mapped skills only from
`~/.agents/skills/<skill>/SKILL.md`.

The top-level `.repositories` array in `~/.manul/config.json` is the only
operator-configured repository list. GitHub Issues polling and both Todo sources
use that same list; provider-local repository lists and `repositoryAllowlist`
are obsolete and ignored. The catalog does not grant access: explicit URLs,
configured full names/short names, and catalog aliases must resolve to a
repository in the global list. Ambiguous aliases, multiple distinct targets in
one Todo tree, duplicate configured short names, and targets outside the global
list are logged and not queued. Manul must never fall back to a hardcoded Todo
repository.

The local adapter connects to Todo Desktop through the shared endpoint resolver
and Streamable HTTP client exported by `globalskills/aicode`. The remote adapter
uses the same shared client and Manul's dedicated PAT supplied through
`FITEO_MANUL_PAT`. The shared client/helper paths are passed in the environment
by the `aicode` launcher; Manul does not search another checkout or hardcode a
globalskills path. If the shared helpers are unavailable, Todo sources are
skipped and other sources continue polling. HTTPS is strongly recommended for
remote MCP outside a trusted private network; HTTP does not encrypt the bearer
token in transit. Never use the operator's `FITEO_PAT` for Manul's task-scoped
Fiteo connection.

When creating tasks through Fiteo, use its native `todo_create_task` MCP tool
directly; Manul does not install a wrapper or OpenCode plugin. For a root task,
pass `shares: [{ userId: FITEO_MANUL_SHARE_USER_ID, permission:
"EDITOR_AND_VIEWER" }]` when a recipient share is required. For a subtask,
pass `parentTaskId` and do not add a duplicate direct share; Fiteo grants
access through the parent. In OpenCode the Manul-owned server is named
`manul-fiteo`, and its create tool appears as
`manul_fiteo_todo_create_task`. If the MCP is unavailable, report the
capability as unavailable rather than falling back to the operator's Fiteo
identity. Never put the PAT or recipient ID in `config.json`.

A Todo root is one Manul task. Its nested subtasks are included as ordered implementation steps in pre-order, preserving the order returned by Todo; they are not queued as independent tasks. Manul revalidates the source tree before execution and marks the root and descendants done only after repository delivery has been verified. For Fiteo, descendants are updated before the root so a partial failure can be retried while the root remains active.

See `task-source.sh`, `task-source-todo-local.sh`, `task-source-todo-remote.sh`, and `todo-task-source-utils.sh` for the separate provider contracts. The local/remote source examples are disabled by default in `config.json.example`.
## GitHub task workflow

### Issue task

1. Prepare an up-to-date isolated base workspace. Prefer `develop`, then `master`, then the repository default branch unless the task explicitly requires another base.
2. Determine whether the request is informational or a repository change.
3. Informational tasks do not create a branch and do not modify the repository.
4. Repository-change tasks create the required feature/bugfix branch using the branching strategy skill.
5. Commit only on the task branch.
6. Push the task branch.
7. Immediately after its first successful push, create a real GitHub PR with a meaningful, non-empty description targeting the branch used as the task base. This applies even if the first push is a progress checkpoint.
8. After EVERY subsequent push to a branch with an open PR—including checkpoint, review-fix, and CI-fix pushes—refresh that same PR's description from the cumulative current PR diff and current verification results. Do not blindly append the latest commit or leave stale/duplicate entries.
9. Read the description back from GitHub and verify its content, the PR URL, head/base branches, and head SHA against the pushed commit.
10. Do not report successful completion or accept `TASK_DONE` if PR creation/update or read-back verification fails; report the exact blocker.

### Existing PR review/conversation task

Reuse the PR's existing head branch. Do not create an unrelated task branch.

The task must update the same PR.
After every push to its head branch, refresh and read back the description of that same PR; never create a second PR or treat a checkpoint as delivered while the description is stale/unverified.

## Progress checkpoints

For non-trivial repository tasks, do not keep all meaningful work uncommitted
until the end. After each logically complete and valuable milestone, the agent
MUST create a checkpoint commit and push it before starting the next high-risk
investigation or implementation step.

A checkpoint can be a proven regression test, a verified root-cause fix, a
separately validated corrective change, or another meaningful recoverable state.
Checkpoints do not imply task completion.

For existing PR tasks, checkpoints MUST be pushed to the PR's existing head
branch. Always distinguish local/uncommitted changes from committed-but-
unpushed changes and from changes actually visible on the GitHub PR. After each
checkpoint push, verify the remote/PR head SHA. Immediately refresh/read back the PR description to match the cumulative diff and current test results. If no PR exists yet for a standalone task, create it after this first push.

When useful, leave a concise PR comment describing what the checkpoint
establishes and whether the overall task remains in progress. Preserve
already-pushed checkpoints across retries, timeouts, workspace loss, and
runtime failures. A runtime failure must not be treated as proof that no
progress was made.

## Unit test guidance

When a repository task adds or changes unit tests, read `UNIT_TESTING.md` before implementing the test. Treat it as the unit-testing methodology for Manul tasks, especially `REVIEW_FIX` work.

## User decision points

Routine ambiguity is resolved autonomously from repository conventions and available context. When a missing decision materially affects correctness, architecture, behavior, scope, compatibility, data model, UX, or another important outcome, the agent must stop rather than guess.

Before asking, inspect the repository, relevant skills/docs, configuration, and conversation context. The user-facing request must summarize what was checked, explain why the uncertainty is material, and present the concrete options or decision required; a recommendation is allowed, but the user's choice is authoritative.

Emit exactly one complete:

`TASK_NEEDS_USER_BEGIN`
<findings, options, recommendation if useful, explicit question/decision>
`TASK_NEEDS_USER_END`

Do not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same execution output. After reaching the decision point, make no further irreversible repository changes. Manul records `blocked_user`. For GitHub sources it posts the request to the same conversation and resumes via `/manul continue <answer>`; for Todo MCP it creates an OPEN subtask containing the question and resumes when the user edits that subtask. Partial or malformed decision blocks are not valid pauses.

## Comment routing

Review-comment tasks reply in the original review thread.

Issue-body and issue/PR conversation tasks use top-level issue/PR comments.

Cross-posting a review-thread task as a top-level PR comment is a bug.

## Result contract

The agent must post exactly one user-facing result comment before emitting `TASK_DONE`.

The comment contains:

```html
<!-- manul-task:<COMMENT_ID>:attempt:<ATTEMPT> -->
```

The daemon verifies this marker against GitHub before accepting completion.

Lifecycle comments are separate daemon responsibilities.

## Queue reset and source replay

Use `manul-queue-reset.sh --dry-run` to inspect replayable unfinished tasks. The normal `manul-queue-reset.sh --execute` mode asks for `RESET QUEUE`, creates a verified SQLite backup, removes replayable `queued`, `failed`, and `stale` task records plus their trigger-message dedupe rows, and invokes `poll.sh` once. It preserves running/completed/blocked/manual task rows, conversation mappings, workspace state, and the install baseline.

For a full reset, preview the scope first:

```bash
manul-queue-reset.sh --all-tasks --dry-run
```

Execute the full reset with:

```bash
manul-queue-reset.sh --all-tasks --execute
```

This mode requires the exact confirmation `DELETE ALL TASKS`. The script itself stops Manul automation and its watchdog, terminates recorded detached task executors after verifying their process identity, waits for polling and task-dispatch locks, creates a verified SQLite backup, then deletes all `processed_comments`, `conversation_messages`, `conversation_links`, and `conversations` rows. Stale `running` status or worker-ownership metadata does not block the wipe after automation has stopped and locks have been acquired.

**The full reset does not run `poll.sh` afterward.** It leaves the task and conversation tables empty and keeps Manul automation stopped, so the queue does not immediately refill. Poll once after the wipe only when explicitly requested:

```bash
manul-queue-reset.sh --all-tasks --execute --poll-after
```

The optional poll runs once without restarting the daemon. Both modes preserve the install baseline, configuration, workspace state, logs, and unrelated runtime state. Any poll still obeys the existing baseline and configured source filters. The backup retains the pre-reset task history.


The long-lived daemon runs a dedicated GitHub poller alongside independent SQLite queue-consumer workers. The poller only discovers and persists work; it never claims or executes tasks. Consumers inspect eligible queued rows at a short dispatch interval and do not invoke `poll.sh`, so slow GitHub/API polling cannot delay work already in SQLite. The explicit `run-once` command retains its combined poll-then-dispatch behavior for manual diagnostics.

## State and recovery

Core task flow:

```
queued -> running -> completed
                  -> failed
                  -> blocked_user
                  -> stale -> queued
```

`attempts` is the agent-execution budget. A task claim starts with
`agentStartedAt = NULL`; the field is set atomically immediately before the
isolated runtime starts. If preparation fails before that marker, Manul rolls
back the claim-time attempt increment and increments the separate
`preExecutionFailures` counter instead. The bounded
`automation.maxPreExecutionFailures` option defaults to 8. These retries still
use `nextAttemptAt` backoff; neither infrastructure retry loops nor a reboot
before runtime startup should exhaust `maxAttemptsBeforeFail`.

A stale task with `agentStartedAt` set has reached the runtime and uses the
normal agent retry budget. Recovery from a real agent execution requeue does not
increment attempts by itself.

`blocked_user` is not failure and resumes through `/manul continue <answer>`.

The daemon performs a startup stale-task recovery pass. The watchdog is the periodic liveness/recovery process.

SQLite is authoritative for task state.

## GitHub control commands

Supported `/manul` commands:

```
/manul run <task>
/manul run --agent <agent> <task>
/manul review-fix <prompt>
/manul continue <answer>
/manul verify <prompt>
/manul status
/manul close
```

See `GITHUB_CONTROL_PROTOCOL.md` for machine-readable details.

## Local CLI

The local control interface consists of:

```bash
manul --update
manul --prompt "Question for Manul"
printf '%s' "Question for Manul" | manul --json
manul-submit.sh
manul-status.sh
manul-result.sh
manul-wait.sh
manul-conversation.sh
manul-orchestrator.sh
manul-monitor
```

### Synchronous operator query

`manul --prompt "Question"` runs a one-shot, read-only operator query
through the configured agent runtime. It is separate from the GitHub/Todo
`/manul` command protocol: it does not create a queued task, reserve a
repository, post comments, or mutate Manul task state. The CLI builds a
bounded, redacted snapshot from the Manul database and selected logs, then
passes that snapshot to `AgentExecutionController`. The agent must answer
from that snapshot; it is not given direct database/log access or tools.

The question may also be supplied through stdin. Optional flags are
`--timeout SECONDS` (10–7200, default 300) and `--json`; run
`manul --help` for usage. OpenClaw, OpenCode and Claude Code have
tool-disabled execution policies. Codex fails closed until its adapter can
guarantee a zero-tool execution mode.

### Restricted Sphinx Slack intake action

Sphinx uses a separate local command:

```bash
manul --prompt "" --todo-local --json < slack-event.json
```

This action mode is available only when `automation.agentRuntime=opencode`.
It uses a dedicated `manul-slack-intake` primary agent and the Manul-owned
`manul-todo-local` MCP connection. Its tool allowlist is limited to Todo
Local list/get/create operations: it may find a matching active task, create
one review task and one child draft-reply task. It cannot use shell,
filesystem, browser, Fiteo, GitHub, other MCP servers, or Slack sending tools.
The Slack event is read from stdin, not command-line arguments.

The normal `manul --prompt` mode remains tool-free and read-only. If Todo
Local is unavailable or its reserved MCP name is occupied, the Slack intake
agent is launched without tools and must return `TODO_UNAVAILABLE`; the
caller is responsible for retaining the complete event in its local fallback
log. This mode never adds an item to Manul's own task queue.

This is a local shell entrypoint provided by `manul-shell.zsh`, not a
`/manul prompt` chat command and not a tool available to an agent running
inside a task workspace. It is available in a Zsh session after the canonical
shell integration is loaded (normally by `~/.zshrc`). If the shell reports
that the option is unknown, update the canonical checkout and reload the
shell integration:

```bash
manul --update
source ~/.zshrc
manul --help
```

See `LOCAL_INTERFACE.md` and `ORCHESTRATOR.md`.

## Generic monitor management

Generic monitors are separate from proactive PR comment handling, CI-fix
automation and conflict resolution. Those existing PR automations keep their
own scopes and lifecycle. Use `manul-monitor` when the operator asks Manul to
watch for a new class of event, such as newly opened PRs.

**Always manage monitors through the `manul-monitor` CLI. Never read or edit
`~/.manul/state/monitors.db` directly.** The CLI validates definitions,
updates the registry transactionally, and preserves event/delivery history.

Create a monitor by writing a JSON definition in the current writable
workspace, then passing it to the CLI:

```json
{
  "id": "external-user-prs",
  "name": "External user pull requests",
  "schedule": { "intervalSeconds": 300 },
  "source": {
    "type": "github_pull_requests",
    "repositories": "configured"
  },
  "filters": {
    "excludeSelf": true,
    "excludeDrafts": true
  },
  "outputs": ["log", "todo_local"]
}
```

```bash
manul-monitor create --config external-user-prs.json --json
manul-monitor list
manul-monitor show external-user-prs
manul-monitor run external-user-prs
manul-monitor pause external-user-prs
manul-monitor resume external-user-prs
manul-monitor update external-user-prs --config external-user-prs.json
manul-monitor delete external-user-prs
```

Definition rules:

- `id` is a stable lowercase identifier (letters, digits and hyphens).
- `schedule.intervalSeconds` is 60–86400 seconds; default is 300.
- The first implemented source is `github_pull_requests`.
- `source.repositories: "configured"` uses the top-level Manul
  `.repositories` allowlist. An explicit array must be a subset of that
  allowlist; a monitor cannot grant itself access to another repository.
- `filters.excludeSelf` compares the PR author with the authenticated
  `gh` account. `filters.excludeDrafts` defaults to true.
- The source detects open PRs created after the monitor was registered; it
  does not backfill older PRs.
- Supported outputs are `log`, `todo_local`, and `todo_remote`.
  Todo outputs require the corresponding enabled `taskSources[]` entry.
  Created Todo items are ordinary review reminders; they do not contain a
  `/manul` trigger and therefore do not automatically start a Manul task.
- Todo deliveries use a stable idempotency marker and are read back before
  Manul marks a delivery complete. Failed deliveries remain pending and retry.

The poller schedules due monitors after regular repository polling and starts
each run as a detached process. One monitor's slow API/output call does not
block normal polling or another monitor. Each monitor has its own lock,
workspace, logs and run artifacts:

```text
~/.manul/
  state/monitors.db
  monitors/<monitor-id>/
    monitor.json
    workspace/
    logs/events.jsonl
    logs/runner.log
    runs/run-<id>.json
```

The global database belongs to Manul and stores lifecycle, scheduling, runs,
event identities and output-delivery state. The per-monitor `workspace/` is
independent; use it for monitor-specific files or a database whose schema
belongs to that monitor. The engine does not impose a common schema on that
workspace. A soft delete disables a monitor but retains its workspace/history.

When diagnosing a monitor, use `manul-monitor show <id>` first. Inspect the
reported workspace and `logs/runner.log` for run details. Do not bypass the
CLI by editing registry rows or manually marking events delivered.

See `MONITORS.md` for the complete operator contract and examples.

## Main operational scripts

| Script | Responsibility |
|---|---|
| `poll.sh` | Poll GitHub, parse commands/events, deduplicate, enqueue |
| `manul-daemon.sh` | Claim tasks, run agent, heartbeat, verify completion, update state |
| `watchdog.sh` | Periodic liveness and stale-task recovery |
| `workspace-manager.sh` | Workspace pool, leases, release/reclaim |
| `manul-github-events.sh` | Parse/control GitHub command events |
| `manul-conversation.sh` | Conversation/task local state interface |
| `manul-pr-review.sh` | Convert PR review events into Manul tasks |
| `manul-pr-watcher.sh` | Discover and deduplicate proactive PR comments/replies without a task-source dependency |
| `manul-monitor.sh` / `manul-monitor.py` | Manage monitor definitions, schedule detached runs, deduplicate events and publish outputs |
| `manul-result-feedback.sh` | Publish structured task lifecycle/result events |
| `manul-result.sh` | Read completed/failed task results |
| `manul-status.sh` | Inspect task state/logs |
| `manul-submit.sh` | Submit local tasks |
| `manul-wait.sh` | Wait for task completion/blocking |
| `manul-orchestrator.sh` | External conversation/review orchestration |
| `update-manul.sh` | Fast-forward the canonical checkout and redeploy runtime symlinks without resetting state or restarting the daemon |

`task-health-check.sh` is legacy/deprecated and must not be installed as an automatic recovery mechanism.

## Configuration

The canonical configuration template is:

```
config.json.example
```

Current automation controls include:

- `mode`: `bot` (default) or `human`;
- `commentStyle.human.concise` (default `true`) controls concise human-mode result comments;
- `commentStyle.human.maxLines` (default `6`) caps visible human-mode result-comment lines and is clamped to 1–20;
- `automation.agentRuntime` (default `openclaw`) selects the sole execution runtime for all tasks, including tasks with explicit canonical roles; supported values: `openclaw`, `opencode`, `codex`, `claude-code`;

Proactive PR monitoring is configured independently from task sources and does not require either Todo MCP:
- `proactivity.fixAndAnswerComments.enabled` opts into automatic analysis of new PR conversation comments, inline comments/replies, and review feedback. It defaults to `false` for existing configurations; the example template opts in with `true`.
- `proactivity.fixAndAnswerComments.prScope` selects `OnlyManulPr` (default; only PRs with an exact verified Manul deliverable record) or `AllUserAuthoredPr` (PRs authored by a login in the PR-author allow-list).
- `proactivity.fixAndAnswerComments.waitBeforeFirstMinutes` (default `30`) delays the first proactive comment/review fix until the later of the source event and PR's last activity; `cooldownMinutes` (default `60`) limits subsequent proactive work on that PR.
- `proactivity.prAuthorAllowed` is the PR-author allow-list. An omitted or empty array inherits `allowedUsers`; unresolved placeholders are discarded and also fall back to `allowedUsers`.
- `ciFix.prScope` independently applies the same `OnlyManulPr` / `AllUserAuthoredPr` selection to automatic CI fixes. It defaults to `OnlyManulPr`; it does not depend on the comment-automation setting.
- `ciFix.waitBeforeFirstMinutes` (default `30`) delays the first automatic fix for a PR until this many minutes have passed since the later of the latest failing-check completion and the PR's `updatedAt`. New PR activity restarts this wait; polling alone does not.
- `ciFix.cooldownMinutes` (default `60`) is the minimum interval between subsequent automatic fix tasks for the same repository/PR. It is measured from the time a task is queued.
- `conflictResolveAndMerge.enabled` opts into automatic repair of conflicting open PRs and merging the same PR after verification. It defaults to `false` so existing installations never gain automatic merge authority.
- `conflictResolveAndMerge.prScope` independently selects `OnlyManulPr` (default) or `AllUserAuthoredPr`, using `proactivity.prAuthorAllowed` (or `allowedUsers` when empty) for the latter.
- `conflictResolveAndMerge.waitBeforeFirstMinutes` (default `30`) waits after the latest PR activity before the first conflict-resolution task; `cooldownMinutes` (default `60`) spaces later attempts for that PR.
- Every proactive PR task (comment/review fix, CI fix, and conflict resolution) is pinned to the exact PR head and target/base SHAs when its workspace is prepared. A Manul-owned pre-push hook checks both SHAs and the open PR state. If either SHA advances, the push is blocked; the agent must not pull/rebase/force-push the newer user work. Manul refunds that attempt, clears the agent session and workspace mapping, and queues a fresh workspace after that policy's `cooldownMinutes`.
- Conflict tasks are pinned to the observed PR head and base SHAs. The agent must keep the same PR, verify the new head, green checks and review state, and use normal GitHub merge protections; it must never use an admin/bypass merge. If GitHub blocks the merge, the PR stays open.
- On the first enabled scan, the watcher stores `meta.pr_watcher_baseline` so it does not enqueue historical comments/reviews. It continues to monitor eligible open PRs after their source task is completed; the PR conversation is persisted independently in SQLite.
- Feedback is classified before edits as a bug, actionable suggestion, nitpick, incorrect assumption, or human-decision-required. Only current, concrete bugs/actionable suggestions are implemented. Nitpicks and incorrect assumptions receive an explanation without code changes; human decisions are surfaced instead of guessed.
- GitHub is the source of truth for PRs, comments, reviews, commits, and CI. The watcher runs from the existing poller and does not read or require Todo MCP state.

Example:
```json
{
  "proactivity": {
    "prAuthorAllowed": [],
    "fixAndAnswerComments": {
      "enabled": true,
      "prScope": "OnlyManulPr"
    }
  },
  "ciFix": {
    "enabled": true,
    "maxAttemptsPerRun": 2,
    "cooldownMinutes": 60,
    "waitBeforeFirstMinutes": 30,
    "prScope": "OnlyManulPr"
  }
}
```

All modes and execution runtimes must produce natural, human-like, task-focused content. Branch names and delivered text must describe the requested work, not the internal task source or execution tools. Do not expose Todo/MCP/task-provider details, Manul orchestration, runtime/agent/provider names, or task/comment/attempt identifiers unless they are genuinely part of the requested product or technical change. This style contract is independent of `mode`.

Human mode is intentionally a presentation/attribution mode: task state remains authoritative in SQLite and local logs, while GitHub receives only the user-facing agent result (and genuine user-decision questions when needed). When `commentStyle.human.concise` is enabled, that result should read like a short teammate reply and stay within the configured visible line limit, without automation-report headings or boilerplate.

```
agentTimeoutSeconds
heartbeatInterval
heartbeatTimeout
heartbeatMaxConsecutiveFailures (default 3; the heartbeat exits unhealthy after this many consecutive database update failures)
leaseTimeout
maxConcurrentTasks
maxAttemptsBeforeFail
maxPreExecutionFailures (default 8)
lockTtl
```


The heartbeat child is considered healthy only when its task-scoped PID file identifies the expected direct child of the worker loop. If consecutive SQLite heartbeat updates fail or affect no row while the claim is still owned, it logs the failures and exits unhealthy after `automation.heartbeatMaxConsecutiveFailures` (default 3). The watchdog cron (every 5 minutes) checks both lease timestamps and heartbeat-process liveness; it performs one conditional SQLite claim transition before stopping the old executor tree. Recovery compares the exact claim token, worker PID, heartbeat timestamp and lease timestamp captured in its scan so it cannot kill a task whose heartbeat was refreshed concurrently. Stale retries retain their attempt count and receive at least a fifteen-second termination window before they can be dispatched again.

Other top-level controls include:

- trigger;
- allowed users;
- repositories;
- agent list (canonical role names);
- single agentRuntime selection for all tasks;
- PR creation/rebase behaviour;
- retry/context strategy;
- compaction;
- CI-fix policy.

Do not put provider-global configuration into Manul's config merely because the current runtime happens to be OpenClaw.

## Installation

Current installer (from the canonical standalone checkout):

```bash
MANUL_CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.manul-repo/skills/manul-github-bot}"
MANUL_DB="$HOME/.manul/state/manul.db"
if [ -f "$MANUL_DB" ]; then
  bash "$MANUL_CANONICAL_DIR/install-manul.sh"
else
  # Explicit first-time initialization; never used when a DB already exists.
  bash "$MANUL_CANONICAL_DIR/install-manul.sh" --init-state
fi
```

Useful options:

```
--runtime-dir <path>
--canonical-dir <path>
--init-state
```

The installer currently:

- verifies dependencies;
- creates the runtime directory;
- deploys runtime symlinks, including `agent-session-state.sh`;
- initializes configuration when absent;
- prepares the Manul-specific integration fallback file;
- configures required provider-owned OpenCode permissions when OpenCode is installed;
- prepares/validates the DB;
- installs the watchdog cron;
- installs the zsh shell integration.

For OpenCode, the installer/repair path updates the effective provider config
selected by the operator's OPENCODE_CONFIG environment (when configured) and
preserves unrelated settings. That variable and provider authentication come
from the operator's ~/.zshrc; they are not copied into ~/.manul/.env.
Daemon/watchdog and installer all inherit the same initialized shell
environment. OpenCode task invocations use opencode run --standalone so a
stale shared background service cannot override task-local environment.
Rules include /tmp/** for task scratch space, the dedicated
/tmp/manul-diagnostics/** directory for local diagnostic artifacts,
read/search-only access to ~/.manul/logs/**, and the narrowly scoped Gradle
module cache. File editing of the log directory is explicitly denied. No broad
permission bypass such as --auto is enabled, and the provider config remains
outside ~/.manul.

The log-read permission is for explicitly authorized **local operator diagnostics**.
It does not authorize ordinary Manul worker tasks to inspect runtime state: the
generated task boundary in `CONTRACTS.md` continues to prohibit that. Keep
diagnostic archives under `/tmp/manul-diagnostics`, ensure that directory is
user-owned and mode `700`, and redact credentials before sharing artifacts.

The optional Manul .env is runtime-owned and mode 600. It is not the
operator's general environment file and must not contain a second PATH,
provider binary/config selection, or copies of currently exported Zsh values.
It is retained only for Manul-specific integration credentials/fallbacks that
the operator deliberately keeps there. Caracal remains operator-owned; its URL
and token are never copied into ~/.manul/.env or task artifacts. When the
operator's static effective OpenCode configuration enables
mcp.servers.caracal-rag, the OpenCode adapter loads the current provider
environment from ~/.caracal/env.sh for that task (with
CARACAL_RESOLVE_LIVE=1), passes the values only to the OpenCode process,
and verifies caracal-rag through that same binary/configuration before agent
startup. A missing provider or disconnected configured Caracal server is a
pre-execution infrastructure failure. Manul does not inject or rewrite the
Caracal MCP entry or modify operator JSON/JSONC files. If Caracal is absent or
disabled in the operator's static config, the adapter does not load its
provider or require Caracal.

OpenCode loads the operator's JSON or JSONC configuration itself. Manul leaves
`OPENCODE_CONFIG` and all operator config files untouched, then supplies a
temporary task-scoped `OPENCODE_CONFIG_CONTENT` overlay. The overlay adds only
the Manul-owned Fiteo MCP and adds `manul-todo-local` only when no
configured MCP server already uses the resolved Todo Local URL. It scans every
known config layer by normalized URL, reuses one unambiguous, enabled remote
entry under its existing name, and never replaces an operator MCP entry. An
occupied URL that is disabled or ambiguous is not duplicated; the optional
Todo capability is skipped instead. Optional MCP outages or missing Todo
helpers do not block agent startup. The overlay adds the exact leased workspace
permission boundary and is discarded after the task.

The Streamable HTTP Todo MCP client and local endpoint resolver are bundled
with standalone Manul and installed into `~/.manul`. Local Todo polling works
without a globalskills/aicode checkout. On native Linux/macOS Manul connects
directly to Todo Desktop's loopback MCP endpoint; under WSL, aicode may start
the existing optional Windows reverse bridge. The local MCP is unauthenticated
and does not use a Todo bearer token.

Every intentional daemon start performs a non-fatal preflight of enabled task
sources. Provider readiness and missing prerequisites are written to
`~/.manul/logs/daemon.log`; per-cycle provider success/failure and error
details are written to `~/.manul/logs/poll.log`. A missing Todo client,
resolver, Python runtime, unreachable MCP endpoint, or failed `list_tasks`
call is visible as an error instead of being silently treated as a successful
poll. Manul continues operating other healthy providers.

The task-creation wrapper and OpenCode plugin have been removed; agents use
the native Fiteo MCP capability.

For an existing installation, run `manul --update`. It fetches only
`origin/main`, refuses local changes or a non-fast-forward checkout, and runs
the canonical installer without `--init-state`. Runtime data is preserved.
The command does not stop or restart the daemon or alter task/lease state; a
running daemon may retain functions loaded before the update. Inspect active
tasks and leases before deciding whether a restart is needed.

The current installer deliberately does not start the daemon automatically.

The runtime isolation refactor has landed: the runtime is `~/.manul` and there is no migration path from obsolete `.openclaw/manul` state.

## Verification

Relevant test entry points include:

```bash
bash skills/manul-github-bot/test_runtime_health.sh
bash skills/manul-github-bot/test_agent_session_state.sh
bash skills/manul-github-bot/test_agent_execution_smoke.sh
bash skills/manul-github-bot/test_manul_cli.sh
bash skills/manul-github-bot/test_queue_reset.sh
bash skills/manul-github-bot/test_github_control_protocol.sh
bash skills/manul-github-bot/test_repository_config_migration.sh
bash skills/manul-github-bot/test_orchestrator.sh
```

Architecture changes should run the broad relevant test suite rather than only a single focused test.

## Safe deployment of terminal-failure reporting fixes

The canonical Manul scripts are deployed through runtime symlinks under `~/.manul`. Updating the canonical checkout changes the scripts those links resolve to; a running daemon may also have older function definitions loaded in memory. Deploy and restart deliberately rather than restarting automatically after a code change.

Before any daemon restart, inspect `processed_comments` and the workspace lease table for every active task. In particular, preserve tasks `issue:6223712757`, `issue:6223679559`, and `issue:6223643297` when they are still active: verify each task's `status`, `workerPid`, `claimToken`, `heartbeatAt`, and `leaseExpiresAt`, along with its workspace ownership. Do not kill workers, clear leases/locks, manually change task state, or restart the daemon while an active worker depends on that state. Wait until those tasks reach a terminal state, or use a separately verified worker/lease handoff that preserves ownership before restarting. A deployment must not requeue a healthy active task just to apply comment-reporting fixes.

A failure to publish a GitHub comment is a secondary observability error: retain the original terminal `failed` state, log the publication failure separately, and allow the publisher to be retried. The publication receipt suppresses overlapping duplicate comments for the same task attempt; do not delete those receipts during normal rollout.

## Troubleshooting

### Daemon not running

Check:

```bash
manul --status
manul-status.sh --log --tail=200
```

Then inspect the configured runtime directory and daemon PID.

### Watchdog not acting

Check the cron entry and the `.enabled` marker.

The watchdog is intentionally dormant until Manul has been explicitly started.

### Stale task

Inspect:

```bash
manul-status.sh --list
task-recovery.sh --list-stuck
```

Use task recovery only for manual intervention; normal stale recovery belongs to the daemon/watchdog mechanisms.

### Explicit role does not execute

Check that the role is present in `agents[]` in
`~/.manul/config.json`, then check the configured
`automation.agentRuntime`. A role not allowed by `agents[]` is rejected. If
its optional definition file is missing, OpenClaw, Codex, and Claude Code use
the selected backend's default behavior; OpenClaw uses `main`. OpenCode
checks native roles with `opencode debug agents` and passes `--agent` only
when the JSON agent list contains the requested ID. It uses the singular
`debug agent <name>` command only as a compatibility fallback when the
plural command is unsupported by OpenCode V1.

### OpenClaw execution failure

Check:

- OpenClaw is installed and reachable;
- the current OpenClaw `main` agent exists;
- the OpenClaw gateway/runtime is healthy;
- the Manul agent prompt/config is valid.

The long-term design should isolate these runtime-specific checks inside the OpenClaw adapter.


### Review-fix tasks in SDD repositories

A review-fix task on an SDD implementation PR remains inside the approved
specification scope. The Orchestrator delegates the fix through the SDD agent,
which checks the review feedback against the approved requirement IDs and
specification commit. A fix that only corrects conformance or implementation
quality may proceed under that approval. If the feedback exposes a missing,
ambiguous, or changed product behavior requirement, return to the Specification
PR gate before changing behavior. Review-fix is not a bypass around SDD.
