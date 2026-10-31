---
name: manul-github-bot
description: Operate, install, and debug the Manul GitHub command bot. Manul reacts to /manul commands in issues and PRs, manages isolated tasks and workspaces, invokes the current agent runtime, verifies results, and posts feedback signed "manul 🐈". The canonical executable source is this skill directory.
---

# Manul GitHub Bot 🐈

Manul is a GitHub command bot and local task orchestrator.

It watches configured repositories, reacts to `/manul` in issue bodies, issue/PR conversation comments, and PR review comments, then:

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
`manul-paths.sh`. `AGENT_RUNTIME` selects the automatic entry-point runtime
(default: `openclaw`); `ROLE_RUNTIME` selects the worker runtime for explicitly
named canonical roles (default: `opencode`). Both accept `openclaw`,
`opencode`, `codex`, and `claude-code`. The config keys are
`automation.agentRuntime` and `automation.roleRuntime`. There is no
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
workspace and lists the effective `permission.external_directory` path rules
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
~/.globalskills/skills/manul-github-bot/
```

Current runtime:

```
~/.manul/
├── config.json
├── .env                # operator/provider environment for unattended runs
├── state/
│   ├── manul.db
│   ├── locks/
│   └── tasks/
├── logs/
└── workspace/
```

The runtime contains Manul configuration, SQLite state, logs, locks, task
artifacts, workspace state, runtime script links, and the operator environment
file `.env`. OpenClaw configuration/state remains outside that ownership
boundary. Provider-specific environment such as `OPENCLAW_STATE_DIR` or
`OPENCLAW_CONFIG_PATH` is persisted in `~/.manul/.env` when present during
installation/repair. Existing `.env` entries are preserved; arbitrary
environment variables are never copied. Unattended daemon/watchdog processes
load this file because cron/systemd does not load `~/.zshrc`.

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

Startup serializes the entire workspace-preparation path and holds a separate
OS-level owner lock for the supervisor's lifetime. Worker processes must close
that lock descriptor so a worker cannot keep a dead supervisor's lock alive.

## Agent execution boundary

The daemon never invokes an agent runtime directly. It calls
`AgentExecutionController.execute`, which routes through `AgentExecutor`:

```
No explicit role -> AGENT_RUNTIME -> OpenClaw / OpenCode / Codex / Claude Code
Explicit role    -> ROLE_RUNTIME  -> OpenCode / Codex / Claude Code (OpenClaw fails closed)
```

This means a plain `/manul run <task>` uses OpenClaw by default, while
`/manul run --agent coder <task>` routes the canonical `coder` role through
`automation.roleRuntime`. OpenCode uses its native `--agent` option; Codex and
Claude Code receive the canonical role instructions as part of the prompt.
This is direct CLI routing, not an ACP session spawned by OpenClaw. Setting
`automation.roleRuntime` to `openclaw` fails closed for explicit roles until a
native OpenClaw role adapter exists.

Use `/manul --auto run <task>` to run one task directly through OpenCode's
native `opencode run --auto` option. Manul persists this per-task choice in
the queue and passes the flag only to the OpenCode adapter; it overrides the
normal runtime and role-runtime settings. OpenClaw does not support this mode.

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


## Task sources

The root work item is owned by a configured task source. GitHub Issues are the default source. Additional providers can be enabled in `.taskSources[]` and are polled independently.

PRs, review comments and CI checks are related development context, not task sources. A source can have multiple PRs attached to it.

Current provider types:

- `github_issues` — default, backed by GitHub repositories.
- `jira_tasks` — Jira REST provider, disabled by default.
- `todo_local_mcp` — separate Todo Desktop MCP source. It selects active root tasks whose description contains a line beginning with `/manul`.
- `todo_remote_mcp` — separate Fiteo backend MCP source. It selects active root tasks explicitly shared with the configured `manulUserId` using `EDITOR_AND_VIEWER` permission.

For either Todo provider, an operator may set `allowReportOnly: true` to enable
the explicit `/manul report <question>` trigger. A report-only source does not
need a project alias or repository URL: the daemon skips repository locks,
checkouts, branches, PRs, and the GitHub result-comment protocol, then runs the
agent in a disposable task-scoped scratch directory. The complete answer is
saved as a child of the source Todo item, read back and verified, and recorded
as a local delivery receipt before the Todo tree is completed. The generated
child is identified by a source-version-bound marker and is the only child
excluded from the source fingerprint; edits to the original task or its other
subtasks still invalidate the queued source. Partial writes are retried by
reusing the exact child instead of creating duplicates. The root is marked done
last, after the result and all original descendants.

Todo sources do not have a fixed project repository. Manul resolves each
Todo root independently using the curated catalog at
`skills/globalskills-repository/project-repositories.json`: an explicit
GitHub repository URL in the task takes precedence; otherwise the longest
whole-phrase project alias must identify exactly one catalog entry. Relevant
project skills listed by that entry are included as task context rather than
being opened by the worker from a global path. The resolved canonical
`owner/repo` and routing provenance are persisted with the queued task.
Configure `repositoryAllowlist` to narrow which catalog repositories the Todo
sources may target. Unknown, ambiguous, and disallowed targets are logged and
not queued; Manul must never fall back to a hardcoded Todo repository.

The local adapter connects directly to Todo Desktop at `http://127.0.0.1:8765/mcp` on native Linux/macOS hosts. Inside WSL it first tries the same loopback endpoint and falls back to the existing WSL bridge at `http://127.0.0.1:8766/mcp` when direct loopback is unavailable. Both paths use `TODO_LOCAL_MCP_TOKEN`. The remote adapter requires an HTTPS MCP URL and a PAT supplied through a configured environment variable (default `FITEO_PAT`). Neither token belongs in `config.json`.

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

Do not emit `TASK_DONE`, `TASK_COMPLETED`, or `TASK_FAILED` in the same execution output. After reaching the decision point, make no further irreversible repository changes. Manul records `blocked_user`, posts the request to the same GitHub conversation, and resumes the same task via `/manul continue <answer>`. Partial or malformed decision blocks are not valid pauses.

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

```
manul-submit.sh
manul-status.sh
manul-result.sh
manul-wait.sh
manul-conversation.sh
manul-orchestrator.sh
```

See `LOCAL_INTERFACE.md` and `ORCHESTRATOR.md`.

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
| `manul-result-feedback.sh` | Publish structured task lifecycle/result events |
| `manul-result.sh` | Read completed/failed task results |
| `manul-status.sh` | Inspect task state/logs |
| `manul-submit.sh` | Submit local tasks |
| `manul-wait.sh` | Wait for task completion/blocking |
| `manul-orchestrator.sh` | External conversation/review orchestration |

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
- `automation.agentRuntime` (default `openclaw`) selects the runtime for tasks without an explicit role; supported values: `openclaw`, `opencode`, `codex`, `claude-code`;
- `automation.roleRuntime` (default `opencode`) selects the runtime for explicitly named canonical roles; supported values are the same, but `openclaw` fails closed for these roles until a native role adapter exists;

Human mode is intentionally a presentation/attribution mode: task state remains authoritative in SQLite and local logs, while GitHub receives only the user-facing agent result (and genuine user-decision questions when needed). When `commentStyle.human.concise` is enabled, that result should read like a short teammate reply and stay within the configured visible line limit, without automation-report headings or boilerplate.

```
agentTimeoutSeconds
heartbeatInterval
heartbeatTimeout
leaseTimeout
maxConcurrentTasks
maxAttemptsBeforeFail
maxPreExecutionFailures (default 8)
lockTtl
```

Other top-level controls include:

- trigger;
- allowed users;
- repositories;
- agent list (canonical role names);
- automatic and explicit-role runtime selection;
- PR creation/rebase behaviour;
- retry/context strategy;
- compaction;
- CI-fix policy.

Do not put provider-global configuration into Manul's config merely because the current runtime happens to be OpenClaw.

## Installation

Current installer:

```bash
bash skills/manul-github-bot/install-manul.sh
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
- prepares the operator `.env` for unattended processes;
- configures required provider-owned OpenCode permissions when OpenCode is installed;
- prepares/validates the DB;
- installs the watchdog cron;
- installs the zsh shell integration.

For OpenCode, the installer/repair path updates the effective provider config
selected by `OPENCODE_CONFIG` (when configured) and preserves unrelated settings.
The supported unattended environment persists `OPENCODE_CONFIG` in
`~/.manul/.env`, so the daemon/watchdog and installer use the same file. Rules
include `/tmp/**` for task scratch space, the dedicated
`/tmp/manul-diagnostics/**` directory for local diagnostic artifacts,
read/search-only access to `~/.manul/logs/**`, and the narrowly scoped Gradle
module cache. File editing of the log directory is explicitly denied. No broad
permission bypass such as `--auto` is enabled, and the provider config remains
outside `~/.manul`.

The log-read permission is for explicitly authorized **local operator diagnostics**.
It does not authorize ordinary Manul worker tasks to inspect runtime state: the
generated task boundary in `CONTRACTS.md` continues to prohibit that. Keep
diagnostic archives under `/tmp/manul-diagnostics`, ensure that directory is
user-owned and mode `700`, and redact credentials before sharing artifacts.

The operator `.env` is runtime-owned and mode 600. It carries only explicitly
supported provider variables, including custom OpenClaw paths and `OPENCODE_CONFIG`,
plus `CARACAL_MCP_URL` and `CARACAL_ACCESS_TOKEN`. The Caracal URL/token are
refreshed from the launcher's current environment while unrelated operator settings
are preserved. Arbitrary environment variables are never copied.

For an OpenCode task, `opencode-adapter.sh` adds the authenticated `caracal-rag`
MCP entry to an invocation-local `opencode.json` using OpenCode's canonical
`mcp["caracal-rag"]` schema. It does not mutate the operator's global config.
Before starting the task, it runs `opencode mcp list` and refuses to launch the
task unless Caracal reports a live connected status. A URL or token alone is not
treated as proof of access.

In this deployment, OpenClaw runs OpenCode through ACPX. The `aicode`
launcher configures the ACPX `opencode` harness to invoke
`aicode/opencode-acp-caracal.sh` and sets
`plugins.entries.acpx.config.probeAgent` to `opencode`, so ACPX startup
healthchecks validate the harness actually used. The wrapper resolves the
current Caracal loopback endpoint and token from Caracal's local config/secret
store, sets `OPENCODE_CONFIG`, checks that `opencode mcp list` reports Caracal
connected, and only then starts `opencode acp`. Its stdout remains reserved for
ACP protocol messages. This avoids relying on environment captured when a
long-lived OpenClaw Gateway first started and avoids registering a duplicate
native OpenClaw MCP server for the same tools.

The ACPX plugin must already be installed and enabled. The launcher fails if
it cannot configure the `opencode` ACP target or if Caracal is not connected.
Selecting an OpenCode model provider alone is not ACP delegation; this setup
specifically configures the ACPX `opencode` harness.

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

Check that the role is present in `agents[]` in `~/.manul/config.json`, then
inspect `automation.roleRuntime`. The default is OpenCode; OpenCode uses its
native `--agent <role>` option, while Codex and Claude Code receive the canonical
role instructions in the prompt. An unknown role or `roleRuntime: "openclaw"`
intentionally fails instead of silently running OpenClaw's `main` agent.

### OpenClaw execution failure

Check:

- OpenClaw is installed and reachable;
- the current OpenClaw `main` agent exists;
- the OpenClaw gateway/runtime is healthy;
- the Manul agent prompt/config is valid.

The long-term design should isolate these runtime-specific checks inside the OpenClaw adapter.
