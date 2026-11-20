# Manul

Manul is a local GitHub task orchestrator. It polls configured task sources,
maintains a durable SQLite task queue, provisions isolated repository workspaces,
runs configured agent runtimes, verifies delivery, and reports results to the
originating task conversation.

This repository owns the Manul runtime, installers, adapters, operational
contracts, and runtime test suite. Global agent definitions and host-specific
launcher integrations remain in their respective host repositories.

## Runtime ownership

- Canonical source: `~/.manul-repo/skills/manul-github-bot/`
- Runtime data: `~/.manul/`
- Task database: `~/.manul/state/manul.db`
- Monitor registry: `~/.manul/state/monitors.db`
- Monitor definitions/workspaces: `~/.manul/monitors/<id>/`
- Operator/provider environment: `~/.manul/.env` (mode 600)
- Workspaces and shared repository caches: `~/.manul/workspace/`
- Recovery snapshots: `~/.manul/state/recovery/workspaces/`

The workspace garbage collector runs from the daemon and watchdog. It reuses
shared repository caches, removes unbound workspaces after one hour, expires
inactive issue/review contexts after 30 days, and expires PR contexts seven
days after GitHub confirms closure. Expired workspaces are first moved to
recovery; recovery snapshots are retained for 30 days. Unused shared repository
caches are eligible after 30 days without use and are removed only while holding
the repository's normal cache lock. GitHub/API uncertainty, active task
references, and active locks always retain the affected data.

The source checkout and runtime state are deliberately separate. Reinstalling
or updating the source must not delete the database, task artifacts, logs,
locks, or workspaces.

## Install

Requirements: Bash 4+, Git, GitHub CLI (`gh`), `jq`, `sqlite3`, Python 3,
and the GNU process/filesystem utilities documented in
[macOS prerequisites](skills/manul-github-bot/SKILL.md) when using macOS.

```bash
git clone https://github.com/mariuszmarzec/manul.git ~/.manul-repo
export MANUL_CANONICAL_DIR="$HOME/.manul-repo/skills/manul-github-bot"
# Mapped project skills are read from ~/.agents/skills.
MANUL_DB="$HOME/.manul/state/manul.db"
if [ -f "$MANUL_DB" ]; then
  bash "$MANUL_CANONICAL_DIR/install-manul.sh"
else
  # Explicitly initialize only a brand-new runtime with no existing database.
  bash "$MANUL_CANONICAL_DIR/install-manul.sh" --init-state
fi
```

The installer prepares `~/.manul`, restores `config.json` from the example
when needed, deploys runtime symlinks, preserves an existing database and
environment, and adds the interactive zsh entrypoints. It does not start
automation automatically.

To start or inspect Manul:

```bash
manul start
manul status
manul stop
manul --update
```

For an existing installation, `manul --update` fetches `origin/master` using
fast-forward-only semantics and then runs the canonical installer to redeploy
runtime symlinks. It refuses a dirty/diverged checkout and never initializes a
missing database. It preserves runtime data and deliberately does not restart
a running daemon; inspect active tasks and leases before any later restart.

For a non-default checkout location, keep `MANUL_CANONICAL_DIR` exported in
the interactive environment. Project skill context and the curated repository
catalog are read only from `~/.agents/skills`; Manul does not accept an
alternate skills root or search other checkouts. If that directory or a mapped
skill is unavailable, Manul continues without the missing external skill
context.

## Configuration

The installer initializes `~/.manul/config.json` from
[config.json.example](skills/manul-github-bot/config.json.example) when no
runtime configuration exists. Edit the runtime copy, not a repository-local
operator configuration. Put credentials only in `~/.manul/.env` or the
documented environment variables; never commit credentials or a real
operator-specific `config.json`.

## Generic monitors

Manul supports independent, scheduled monitors. They are separate from the
existing proactive PR comment, CI-fix and conflict-resolution automations.
The initial source detects newly opened, non-draft GitHub PRs in configured
repositories; outputs can append to monitor logs or create a review reminder in
Todo Local/Remote.

Manage monitors through the CLI (also available to OpenCode with the Manul
skill):

```bash
manul-monitor create --config external-user-prs.json
manul-monitor list
manul-monitor show external-user-prs
manul-monitor run external-user-prs
manul-monitor pause external-user-prs
manul-monitor resume external-user-prs
manul-monitor update external-user-prs --config external-user-prs.json
manul-monitor delete external-user-prs
```

Definitions, supported filters/outputs, process isolation, storage ownership
and an example are documented in
[MONITORS.md](skills/manul-github-bot/MONITORS.md). The global registry is
`~/.manul/state/monitors.db`; each monitor has an independent workspace at
`~/.manul/monitors/<id>/workspace/`. Use the CLI for registry changes and
keep monitor-specific state in its own workspace.

### GitHub PR automation

Manul has three independent PR automation policies. Each has its own
`enabled` flag and `prScope`; enabling one does not enable the others:

- `proactivity.fixAndAnswerComments` handles new PR discussion comments,
  inline review comments/replies, and submitted review feedback.
- `ciFix` detects failing CI checks and queues bounded build-fix tasks.
- `conflictResolveAndMerge` detects merge-conflicted, open, non-draft PRs,
  queues a task for the existing PR branch, and asks the agent to resolve the
  conflict and merge that same PR after verification.

The conflict resolver is opt-in and defaults to disabled:

```json
{
  "conflictResolveAndMerge": {
    "enabled": true,
    "prScope": "OnlyManulPr"
  }
}
```

Supported `prScope` values are:

- `OnlyManulPr` (default): only PRs with an exact, verified Manul deliverable
  record are eligible.
- `AllUserAuthoredPr`: PRs authored by a GitHub login in
  `proactivity.prAuthorAllowed`. When that list is missing or empty, Manul
  falls back to `allowedUsers`.

The scope is configured independently for each policy. For example,
`ciFix.prScope` does not inherit `proactivity.fixAndAnswerComments.prScope`,
and neither setting changes `conflictResolveAndMerge.prScope`.

All three proactive PR tools use the same timing defaults, configured
independently under their own policy:

- `waitBeforeFirstMinutes` (default `30`) delays the first action until the
  later of the triggering event (comment/review or failed CI) and the PR's
  latest activity. Conflict resolution uses the PR's latest activity.
- `cooldownMinutes` (default `60`) is the minimum interval before another
  proactive task for that policy and PR can be queued.
- Polling does not renew either timer. The cooldown timestamp is updated only
  when a task is actually queued.

Before pushing a proactive PR fix, Manul pins the source branch head and target
base SHA and installs a guarded Git pre-push check. If the PR head or base moves
while the agent is working, the push is rejected; Manul does not pull/rebase
over the newer work or force-push. It requeues the review/comment task after
`cooldownMinutes` with a fresh workspace, while CI/conflict tasks are retried
against the refreshed PR state. The next attempt fetches the newest PR head
and base before starting.

Conflict tasks are tied to the PR head and target/base commit SHAs observed by
the poller. Before making changes, the agent must re-check that the same PR is
still open and that its head has not unexpectedly changed. It must resolve the
conflict on that PR's existing source branch, push the resolution, and verify
the resulting head, required CI checks, and review decision before attempting
a normal GitHub merge. Manul never authorizes an admin/bypass merge or bypasses
branch protection. If checks, approvals, or repository rules block the merge,
the PR is left open and the blocker is reported.

Enabling `conflictResolveAndMerge` grants the configured agent permission to
push to eligible PR branches and request their merge, so review the selected
scope and repository protections before turning it on. The complete set of
runtime options is documented in
[config.json.example](skills/manul-github-bot/config.json.example) and the
[Manul skill reference](skills/manul-github-bot/SKILL.md).

## Development and tests

The runtime scripts and tests live together under
`skills/manul-github-bot/` because the scripts source one another relative to
their canonical directory.

The repository's hermetic shell regression suite and the shared Todo MCP
transport tests are run by GitHub Actions. Treat CI as the canonical test
environment for repository changes. Do not run unit, integration, or diagnostic
tests on a machine with an active Manul installation; that machine is reserved
for the later end-to-end run against
`https://github.com/mariuszmarzec/test-manul-e2e`.

`test_manul_pr_workflow.sh` is an operator-side workflow test that uses a
configured runtime database and must not run in disposable CI or on the Manul
host. No test is required on the installed Manul machine during updates.

## Extraction provenance

The initial standalone source was extracted from
`mariuszmarzec/globalskills` at commit
`f4d69f9f300b90b7fbdf68bad144cff792d061e4`. The operator-specific
`config.json` was intentionally not copied; use the example and keep runtime
configuration outside version control.


## Specification-Driven Development (SDD)

Manul supports an opt-in, resumable SDD workflow shared with Globalskills.
A repository enables SDD by merging a root
`/.specification/config.yaml` with `mode: specification-driven`. No config
means the normal Manul workflow. Bootstrap must be explicit:

```text
/manul sdd bootstrap
/manul sdd <request>
```

Ordinary implementation and review-fix tasks in an SDD repository are
automatically routed through the existing Orchestrator to the SDD agent.
Manul blocks direct coding roles from bypassing the specification gate and
fails closed if the SDD agent, Orchestrator role, or skill is missing.

Baseline and Specification PRs contain requirements/configuration only and
require human approval before implementation. The Implementation PR is
separate and pinned to the approved specification commit and requirement IDs.
Manul persists workflow checkpoints in SQLite and restores the latest
checkpoint into the next task in the same conversation, independently of the
LLM runtime session.

See the [Globalskills SDD workflow and architecture](https://github.com/mariuszmarzec/globalskills#specification-driven-development-sdd).
