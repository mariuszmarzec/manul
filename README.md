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
- Workspaces: `~/.manul/workspace/`

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

The runtime scripts and Manul-specific regression tests live under
`skills/manul-github-bot/`. Shared Todo MCP transport and endpoint discovery
are owned and tested by `globalskills/aicode`; Manul CI uses a mock shared
component to test the source-adapter contract.

Run the hermetic shell regression suite in GitHub Actions CI. Do not run test
scripts against an operator machine with an installed Manul runtime. The
operator-side `test_manul_pr_workflow.sh` uses the configured runtime database
and is not part of the disposable hermetic CI suite. End-to-end testing against
a dedicated test repository is a separate, explicit workflow.

## Extraction provenance

The initial standalone source was extracted from
`mariuszmarzec/globalskills` at commit
`f4d69f9f300b90b7fbdf68bad144cff792d061e4`. The operator-specific
`config.json` was intentionally not copied; use the example and keep runtime
configuration outside version control.
