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
```

For a non-default checkout location, keep `MANUL_CANONICAL_DIR` exported in
the interactive environment; the installer also persists it in the
runtime-owned environment file for unattended watchdog/daemon processes.

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

Run the hermetic test suite locally:

```bash
for test in skills/manul-github-bot/test_*.sh; do
  case "$(basename "$test")" in
    test_agent_modes.sh|test_manul_pr_workflow.sh|test_concurrency_impl.sh) continue ;;
  esac
  bash "$test"
done
python3 skills/manul-github-bot/test_todo_mcp_client.py
```

`test_agent_modes.sh` validates host-owned agent definitions and remains an
integration check in the host skills repository. `test_manul_pr_workflow.sh`
is an operator-side workflow test that uses the configured runtime database;
do not run it against a disposable CI environment.

## Extraction provenance

The initial standalone source was extracted from
`mariuszmarzec/globalskills` at commit
`f4d69f9f300b90b7fbdf68bad144cff792d061e4`. The operator-specific
`config.json` was intentionally not copied; use the example and keep runtime
configuration outside version control.
