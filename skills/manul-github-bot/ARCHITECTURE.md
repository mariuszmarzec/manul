# Manul Architecture

## Purpose

Manul is a GitHub task orchestrator. GitHub comments create tasks; Manul persists task state, prepares isolated repository workspaces, invokes an agent runtime, verifies the result, and delivers the result through GitHub.

This document describes the current runtime architecture. The runtime-isolation refactor has landed, so the "approved target architecture" is no longer a plan — it is the implementation.

## Current runtime layout

```
GitHub
  |
  +--> poll.sh / GitHub control scripts
            |
            v
        SQLite manul.db
            |
            v
       manul-daemon.sh
            |
            +--> workspace-manager.sh
            |
            +--> AgentExecutionController
                    |
                    v
               AgentExecutor
                 /        \
                v          v
        OpenClawAdapter  OpenCodeAdapter  CodexAdapter  ClaudeCodeAdapter
                ^          ^
                |          |
       automatic runtime   explicit role runtime
       (agentRuntime)      (roleRuntime)
```

The daemon is runtime-neutral: it reaches an agent runtime only through
`AgentExecutionController` → `AgentExecutor` → one of the OpenClaw, OpenCode,
Codex CLI, or Claude Code backend adapters.
`automation.agentRuntime` controls automatic entry-point selection (default
OpenClaw); `automation.roleRuntime` controls execution of explicitly selected
canonical roles (default OpenCode). With these defaults, a task without an
explicit role runs through OpenClaw, while an explicit `coder` role runs through
the OpenCode CLI using `--agent coder`. This is direct CLI routing, not an ACP
session spawned inside OpenClaw.

### Current source/runtime split

Canonical source:

`~/.globalskills/skills/manul-github-bot/`

Current default runtime:

`~/.manul/`

The installer deploys the runtime scripts as symlinks from the canonical skill directory and keeps runtime data such as the SQLite DB, logs, locks and task files in the runtime directory.

Path and runtime selection are centralized in `manul-paths.sh`, which resolves `MANUL_DIR` to `$HOME/.manul` and validates both `AGENT_RUNTIME` and `ROLE_RUNTIME` against the known adapter set. Their config keys are `automation.agentRuntime` and `automation.roleRuntime`. There is no `OPENCLAW_MANUL_DIR` alias and no fallback to `~/.openclaw/manul`.

### Current runtime ownership

The runtime effectively treats these as Manul runtime data under `MANUL_DIR`:

- `config.json`
- `manul.db`
- logs
- lock files
- task/prompt/output artifacts
- repository locks
- workspace pool/worktrees
- runtime script links

OpenClaw configuration/state remains outside that ownership boundary.


## Task source plane

Manul separates the root task source from development artifacts such as pull requests and review threads.

Configured sources live in `.taskSources[]`; disabled entries are ignored and enabled entries are polled independently:

```text
Task sources
  +--> GitHub Issues
  +--> Jira Tasks
  +--> TodoLocalMCPAdapter (Todo Desktop)
  +--> TodoRemoteMCPAdapter (Fiteo backend)
          |
          v
   provider-specific filter
          |
          v
   normalized root task
          |
          v
      SQLite queue
```

A pull request is never a root task source. A GitHub Issue or Jira task may have one or more PRs attached as implementation context. This distinction is persisted as `taskSourceType` + `taskSourceId` on queued tasks.

Todo sources have two explicit execution variants. Repository-backed tasks use
the configured project catalog and the normal checkout/branch/PR path.
`/manul report` tasks (opted in per source with `allowReportOnly: true`) bypass
repository locks and workspace-pool allocation, execute in a disposable scratch
directory, and persist the final answer as a child Todo task. The adapter verifies
that child by reading the task tree back before the daemon stores its local
receipt and marks the root last. The source fingerprint excludes only that one
valid, source-version-bound result child, so unrelated user edits remain visible.

The legacy `.repositories` configuration remains the default GitHub Issues source when `.taskSources` is absent.
## Task execution plane

```
queued
  |
  v
running
  |
  +--> completed
  |
  +--> failed
  |
  +--> blocked_user
  |
  +--> stale / requeued
```

The daemon claims queued tasks, assigns worker ownership, starts a heartbeat, executes the agent, verifies the execution result, and performs terminal state transitions.

SQLite is the authoritative task state. Files such as logs, PID markers and transient execution output are operational artifacts, not alternative sources of truth.

### Runtime session continuity

The runtime adapter owns the mechanics of invoking and resuming its session.
Manul persists only the session ID pointer in `processed_comments.session_id`
so a queued retry can resume the exact runtime conversation. That pointer is
retained only when the active claim returns `NEEDS_CONTINUATION` with a
non-empty session ID; every other outcome clears it. Updates are scoped to the
current running task and claim token, so an expired worker cannot alter a
newer attempt's session state. Clearing the pointer does not release or delete
the task's workspace/context mapping.

This automatic runtime continuation is distinct from `/manul continue <answer>`,
which resumes a task blocked on user input (`blocked_user`).

## Reliability plane

```
manul-daemon
  |
  +--> per-task heartbeat
  +--> lease expiry
  +--> startup stale-task recovery
  |
  +--> watchdog (periodic liveness/recovery)
```

The daemon performs a stale-task recovery pass when its loop starts. The watchdog is the periodic liveness mechanism: it can restart an enabled daemon, remove a stale daemon lock, reclaim stale workspaces, and recover tasks using heartbeat/lease ownership checks.

The watchdog must not blindly reset task state.

## GitHub control plane

The GitHub control scripts provide:

- command parsing for `/manul`;
- issue/PR/review event handling;
- conversation linking;
- result feedback;
- source revalidation.

The machine-readable protocol is documented in `GITHUB_CONTROL_PROTOCOL.md`.

## External orchestration plane

`manul-orchestrator.sh` is a separate local control layer. It persists its own conversation/review orchestration state in `orchestrator.db` under `ORCHESTRATOR_DIR`.

It submits and observes tasks through the Manul task system; it is not the core daemon and does not replace `manul.db`.

```
External caller
    |
    v
manul-orchestrator.sh
    |
    +--> manul-conversation / submit / wait / result
    |
    v
Manul task system
    |
    v
GitHub
```

## Runtime layout

The runtime-isolation refactor makes Manul independent of the OpenClaw runtime layout:

```
~/.manul/
├── config.json
├── .env
├── state/
│   ├── manul.db
│   ├── locks/
│   └── tasks/
├── logs/
└── workspace/
```

OpenClaw remains provider-owned, including its state/configuration paths.
Those paths are supplied through provider environment such as
`OPENCLAW_STATE_DIR` and `OPENCLAW_CONFIG_PATH`; Manul may persist those
values in `~/.manul/.env` for unattended execution.

OpenCode, Claude Code, Tabnine and other runtimes retain their native
configuration/state locations unless an adapter has a concrete reason to own
additional Manul-specific data.

For unattended Manul execution, the installer/repair path may apply the minimum required provider configuration without moving that configuration into `~/.manul`. `OPENCODE_CONFIG` is an explicitly supported variable in `~/.manul/.env`, so installer/repair and background daemon/watchdog use the same effective OpenCode config. The configuration keeps `/tmp/**` for scratch work, adds `/tmp/manul-diagnostics/**` for local diagnostic artifacts, grants read/search but denies edit for `~/.manul/logs/**` during explicitly authorized operator-side diagnosis, and keeps Gradle access limited to the dependency module cache. Ordinary Manul task prompts still prohibit inspection of Manul runtime state/logs. Manul does not own or persist `opencode.json` in its runtime state.

The hermetic `test_agent_execution_smoke.sh` suite exercises the production
execution boundary through `manul-daemon.sh`, `agent-task-runner.sh`,
`AgentExecutionController`, `AgentExecutor`, the runtime adapters, and
`ProcessRunner` using fake OpenClaw and OpenCode executables. It is independent
of GitHub and real runtime/gateway state, so CI can check process boundaries,
entry-point executability, automatic-runtime selection, explicit `--agent`
propagation, stdout/exit-code handling, and accidental direct adapter invocation.

The execution boundary becomes:

```
Manul daemon
     |
     v
AgentExecutor
     |
     +--> OpenClawAdapter
     |
     +--> OpenCodeAdapter
     |
     +--> other adapters
```

Manul should own **task lifecycle and scheduling**.

The runtime should own **agent execution and its own loop/session semantics**.
Manul still owns the claim-scoped SQLite pointer that tells a retry which runtime
session to continue; it does not interpret or manipulate the runtime's session
internals.

OpenClaw, OpenCode, Codex CLI, and Claude Code adapters are implemented behind the same `AgentExecutor` boundary. Explicit canonical roles use the configured `ROLE_RUNTIME` (OpenCode by default). OpenCode maps a role to its native `--agent` option; Codex and Claude Code prepend the canonical role definition to the prompt because those CLIs do not implement the same OpenCode role contract. If `ROLE_RUNTIME=openclaw`, explicit role routing fails closed rather than treating a role name as an OpenClaw config-agent ID.

## Ownership rule

A useful test for any new piece of state is:

> Who conceptually owns this state?

If it is required to schedule, recover, observe or coordinate Manul tasks, it belongs to Manul.

If it is required only to run one specific agent runtime, it belongs to that runtime or its adapter.

## Migration policy

The runtime architecture is intentionally a clean break.

There is no requirement to migrate old `~/.openclaw/manul` state into `~/.manul`. Obsolete paths and compatibility fallbacks are removed rather than preserved — `manul-paths.sh` has no `OPENCLAW_MANUL_DIR` alias and no fallback to `~/.openclaw/manul`.

The runtime-isolation code has landed. `~/.manul` is the single canonical runtime directory and the `AgentExecutor` abstraction is the only path from the daemon to an agent runtime.
