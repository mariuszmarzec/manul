# Agent Instructions for Manul

This file is the local guardrail for agents modifying `skills/manul-github-bot/`.

## Read before changing code

For any non-trivial change, read these files first:

1. `AGENTS.md`
2. `ARCHITECTURE.md`
3. `CONTRACTS.md`
4. `SKILL.md`
5. The specific scripts and tests involved in the change.

Treat `CONTRACTS.md` as the list of behavioural invariants. Treat `ARCHITECTURE.md` as the ownership and dependency model.

## Current architecture (implemented)

The runtime isolation refactor has landed. The current implementation:

- Uses `~/.manul/` as the single canonical runtime directory
  (`MANUL_DIR`, resolved in `manul-paths.sh`).
- Routes all agent execution through `AgentExecutor`. `AGENT_RUNTIME`
  (default `openclaw`) selects the automatic entry point; `ROLE_RUNTIME`
  (default `opencode`) selects the runtime for explicitly named canonical roles.
  Both settings accept `openclaw`, `opencode`, `codex`, and `claude-code`.
- Adapters are independent backends behind a single `ProcessRunner.run()`
  process boundary; they must not spawn subprocesses directly and must not
  depend on each other. OpenCode receives canonical roles through its native
  `--agent` flag; Codex and Claude Code receive the matching canonical role
  instructions from `~/.globalskills/agents/` prepended to the task prompt.
  Never silently route role names to OpenClaw's config-agent selector.
- Has no fallback to `~/.openclaw/manul` and no `OPENCLAW_MANUL_DIR` alias.

Do not reintroduce `~/.openclaw/manul` ownership, compatibility shims, or
dual runtime directories. A clean replacement is preferred over:

- dual runtime directories;
- fallback from `~/.manul` to `~/.openclaw/manul`;
- database migrations solely to preserve obsolete runtime state;
- compatibility aliases that couple Manul back to OpenClaw.

Existing behavioural contracts must still be preserved unless a change is intentional, documented, and tested.

## Core invariants

Do not accidentally break:

- SQLite as the authoritative Manul task state.
- Atomic task claiming and worker ownership.
- Heartbeat/lease recovery semantics.
- Attempt counting semantics.
- `blocked_user` as a resumable user-input state, not a failure.
- Deterministic task/attempt result markers.
- Exactly one user-facing result comment per agent attempt.
- Correct routing of top-level comments vs PR review-thread replies.
- Issue-task branch creation and PR requirements.
- Refresh and read back the same PR's complete description after every push, including checkpoint and review-fix pushes.
- Reuse of an existing PR head branch for PR review/conversation tasks.
- Source revalidation for stale/closed GitHub objects.
- Workspace/repository lock ownership.
- No direct task changes on a base/default branch.
- Existing GitHub control protocol and local CLI semantics.

## Responsibility boundaries

Manul owns:

- GitHub polling/control events;
- task queue and state;
- retries, leases and watchdog recovery;
- workspaces and repository locks;
- lifecycle/result verification;
- GitHub comments and PR delivery checks.

An agent runtime owns:

- the LLM/tool execution loop;
- runtime-specific session internals and context;
- runtime-specific continuation mechanics.

Manul owns the persisted runtime session ID pointer in SQLite because it is
needed for task retry/recovery. Preserve it only for a claim-scoped
`NEEDS_CONTINUATION` result with a non-empty session ID; clear it on all other
outcomes without deleting the workspace/context mapping.

Do not move runtime-specific behaviour into the Manul core when an adapter can contain it.

## Coding and verification rules

Prefer small, surgical changes.

Before declaring success:

- run the relevant tests;
- run the broader Manul test suite when architecture or shared helpers change;
- inspect `git diff` and `git status`;
- never claim a test passed without actually running it.

Do not modify `manul.db` as part of repository changes.

Never put secrets, local credentials, or machine-specific state into the repository.

A task-scoped OpenCode permission exception must use a temporary invocation-local config for the exact canonical active workspace only; do not weaken the global sibling-workspace deny or persist per-task permissions globally. Add regression coverage for global config immutability and sibling isolation.

When changing a behavioural contract, update `CONTRACTS.md` in the same change and add/adjust tests that prove the new contract.

## Documentation truthfulness

Current-state documentation must describe the code that is actually on the current branch.

Planned architecture must be explicitly marked as planned/unimplemented.

Do not keep a statement in documentation merely because it was true in an older version of Manul.
