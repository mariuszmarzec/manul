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
