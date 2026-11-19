# Manul generic monitors

Generic monitors are scheduled, independently running checks managed by
Manul. They are intentionally separate from the proactive PR comment watcher
(`proactivity.fixAndAnswerComments`), CI-fix automation (`ciFix`) and
conflict-resolution automation (`conflictResolveAndMerge`). Those existing
features retain their current event policies.

## First monitor: newly opened PRs by other users

Create a JSON definition such as
[`examples/monitors/external-user-prs.json`](examples/monitors/external-user-prs.json):

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

Register it:

```bash
manul-monitor create --config skills/manul-github-bot/examples/monitors/external-user-prs.json --json
manul-monitor list
manul-monitor show external-user-prs
```

The monitor becomes due immediately after registration and is picked up by
the next Manul poll cycle. It checks open PRs in the configured repositories.
Only PRs whose `createdAt` is later than the monitor registration timestamp
are eligible. By default, Manul excludes the authenticated `gh` account and
draft PRs. Existing PRs are not backfilled.

The special repository selector `configured` means the top-level
`.repositories` array in `~/.manul/config.json`. An explicit repository
array is also supported, but every entry must already be present in that
allowlist. A monitor cannot expand Manul's repository access.

## Supported definition

| Field | Meaning |
|---|---|
| `id` | Stable ID: lowercase letters, digits and hyphens, 1–63 characters |
| `name` | Human-readable monitor name |
| `enabled` | Optional boolean, defaults to true |
| `schedule.intervalSeconds` | Poll interval from 60 to 86400 seconds; default 300 |
| `source.type` | Currently `github_pull_requests` |
| `source.repositories` | `configured` or an explicit subset of `.repositories` |
| `filters.excludeSelf` | Exclude PRs authored by the authenticated GitHub login; default true |
| `filters.excludeDrafts` | Exclude draft PRs; default true |
| `outputs` | One or more of `log`, `todo_local`, `todo_remote` |

Todo outputs require an enabled matching entry in `taskSources[]`. Todo
reminders are ordinary Todo root tasks and do not contain a `/manul` trigger;
they will not automatically start a Manul coding/review task. This avoids
turning a reminder monitor into an autonomous reviewer unless that behavior
is explicitly introduced as a separate output contract.

## CLI

```bash
manul-monitor create --config monitor.json
manul-monitor create --config - < monitor.json
manul-monitor list [--all] [--json]
manul-monitor show <id> [--json]
manul-monitor update <id> --config monitor.json
manul-monitor pause <id>
manul-monitor resume <id>
manul-monitor run <id>
manul-monitor delete <id>
```

- `create` validates the definition, creates its workspace and registers it.
- `update` replaces the definition while preserving the monitor's creation
  timestamp, events and delivery history. The ID must remain unchanged.
- `pause` stops scheduling without deleting any state.
- `resume` schedules the monitor for the next poll cycle.
- `run` requests an immediate run. It uses the same non-overlap lock as the
  scheduler.
- `delete` is a soft delete: it disables scheduling and retains the definition,
  workspace and history.
- `show` reports the workspace, recent run outcomes and pending event count.

## Runtime and process isolation

The regular poller invokes the scheduler after repository polling. The
scheduler reserves due monitors in the global registry and starts one detached
process per monitor. It does not wait for those runs to finish, so a slow
GitHub or Todo API call cannot stall normal task polling. A monitor-specific
OS lock prevents overlapping runs of the same monitor. Different monitors
have independent locks and workspaces.

A source event is stored before output delivery. Event identity is unique per
monitor and PR-open event. Each output has a separate delivery record. If one
output fails, already delivered outputs are not repeated and the failed output
remains pending for the next run.

Todo delivery uses a deterministic marker embedded in the task description.
Before creating a task, Manul checks whether that marker already exists. After
creation it reads tasks again and requires the marker to be visible. The
delivery is marked complete only after read-back succeeds.

## State ownership and storage

The global registry is:

```text
~/.manul/state/monitors.db
```

It stores monitor index/metadata, scheduling state, run history, event
identities and output-delivery status. It is controlled by Manul. Agents must
use the `manul-monitor` CLI and must not modify this database directly.

Every monitor has its own directory:

```text
~/.manul/monitors/<id>/
  monitor.json
  monitor.lock
  workspace/
  logs/
    events.jsonl
    runner.log
  runs/
    run-<id>.json
```

The monitor workspace is independent data. A monitor may keep JSON, Markdown,
SQLite or other monitor-specific state there without changing the global
registry schema. The engine creates the directory but does not prescribe the
schema of files inside it. The monitor's logs and run artifacts are also kept
separate from task worker logs.

A soft delete deliberately retains the whole monitor directory and its history.
Do not treat monitor workspaces as normal task workspaces or remove them with
task-workspace cleanup.

## OpenCode / Manul skill workflow

An OpenCode agent with the Manul skill can create a monitor by:
1. translating the operator's request into a supported JSON definition;
2. checking the global repository allowlist and required Todo provider;
3. writing the definition in its current writable workspace;
4. calling `manul-monitor create --config <path>`;
5. reading back the created monitor using `manul-monitor show <id>`.

To change a monitor, the agent reads its current definition, edits a copy and
uses `manul-monitor update`. To diagnose an issue, it starts with
`manul-monitor show` and inspects the reported per-monitor logs/run artifacts.
The agent must not bypass this interface by editing `monitors.db`.

The initial implementation supports the GitHub PR source and the three outputs
listed above. Additional sources, filters, handlers and outputs require an
explicit implementation and contract update; do not invent unsupported
definition fields and assume the runtime will execute them.
