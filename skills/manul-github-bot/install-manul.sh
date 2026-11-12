#!/usr/bin/env bash
# install-manul.sh — Canonical Manul installer
#
# Idempotent one-shot bootstrap of a fresh Manul runtime:
#   1. Self-detect and validate canonical source
#   2. Ensure runtime directory
#   3. Deploy symlinks via install-manul-symlinks.sh
#   4. Restore config.json from example if missing and prepare operator .env
#   5. Validate/migrate manul.db. Existing task state is preserved. A fresh DB
#      is created only with explicit --init-state on a first-time installation.
#   6. Install the dormant watchdog cron and canonical zsh shell integration
#   7. Verify and print summary
#
# This installer does NOT start the daemon and does NOT create the .enabled
# marker. The watchdog cron may exist after installation, but it exits
# immediately until .enabled is present.
#
# Usage:
#   install-manul.sh [--runtime-dir <path>] [--canonical-dir <path>] [--init-state]
#
# Environment overrides:
#   MANUL_RUNTIME_DIR    Runtime directory (default: ~/.manul)
#   MANUL_CANONICAL_DIR  Canonical skill directory (default: this script's dir)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-platform.sh"
manul_platform_prepare || exit 1
manul_platform_reexec_if_needed "$SCRIPT_DIR/install-manul.sh" "$@"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$SCRIPT_DIR}"
RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.manul}"
INIT_STATE=false

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Parse CLI flags (env vars take priority; flags override defaults only)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
        --canonical-dir) CANONICAL_DIR="$2"; shift 2 ;;
        --init-state) INIT_STATE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--runtime-dir <path>] [--canonical-dir <path>] [--init-state]"
            echo ""
            echo "Environment overrides:"
            echo "  MANUL_RUNTIME_DIR    Runtime directory"
            echo "  MANUL_CANONICAL_DIR  Canonical skill directory"
            echo "  --init-state         Explicitly initialize a brand-new DB if no valid DB/backup exists"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--runtime-dir <path>] [--canonical-dir <path>]" >&2
            exit 1
            ;;
    esac
done

STATE_DIR="$RUNTIME_DIR/state"

# 1. Self-detect / validate canonical source
if [ ! -d "$CANONICAL_DIR" ]; then
    fail "Canonical Manul directory does not exist: $CANONICAL_DIR"
fi
CANONICAL_DIR="$(cd "$CANONICAL_DIR" && pwd)"
export MANUL_CANONICAL_DIR="$CANONICAL_DIR"

for required in install-manul-symlinks.sh config.json.example migrate-repository-config.sh manul-env.sh \
             manul-conversation.sh workspace-manager.sh watchdog.sh \
             manul-shell.zsh update-manul.sh opencode-permissions.sh manul-daemon.sh task-process-control.sh manul-status.sh manul-query.sh manul-operator-context.py; do
    if [ ! -f "$CANONICAL_DIR/$required" ]; then
        fail "Missing required canonical file: $CANONICAL_DIR/$required"
    fi
done

echo "=== Manul Installer ==="
echo "Canonical source: $CANONICAL_DIR"
echo "Runtime target:   $RUNTIME_DIR"
echo

# 0. Verify required commands before claiming success. Do not invent
# dependencies; these are what the current Manul runtime actually needs:
#   bash      - all canonical scripts are bash
#   git       - worktrees / repo operations
#   gh        - GitHub API (polling, comments, PRs)
#   jq        - config.json parsing throughout the runtime
#   sqlite3   - manul.db (native ext4 I/O, concurrent access)
#   curl      - HTTP used by manul-comments-remove.sh
#   python3   - lifecycle SQLite/JSON helpers and OpenCode stderr redaction
# The configured automation.agentRuntime selects the one required agent binary.
MISSING_DEPS=()
for cmd in bash git gh jq sqlite3 curl crontab python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done
if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
    echo "ERROR: Missing required dependencies: ${MISSING_DEPS[*]}" >&2
    echo "Install them before running this installer." >&2
    exit 1
fi
echo "Prerequisites OK: bash git gh jq sqlite3 curl crontab python3"
echo

# 2. Ensure runtime directory
if [ ! -d "$RUNTIME_DIR" ]; then
    echo "[1/7] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR" "$STATE_DIR" "$STATE_DIR/locks" "$STATE_DIR/tasks" "$RUNTIME_DIR/logs" "$RUNTIME_DIR/workspace"
else
    echo "[1/7] Runtime directory exists: $RUNTIME_DIR"
    mkdir -p "$STATE_DIR" "$STATE_DIR/locks" "$STATE_DIR/tasks" "$RUNTIME_DIR/logs" "$RUNTIME_DIR/workspace"
fi

# 3. Deploy symlinks
echo
echo "[2/7] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" \
    --runtime-dir "$RUNTIME_DIR" \
    --canonical-dir "$CANONICAL_DIR" || \
    fail "Symlink deployment failed"

# 4. Restore config.json from example if missing
echo
if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo "[3/7] Config not found, restoring template..."
    cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
    echo "  Copied config.json.example -> config.json"
    echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting the daemon"
else
    echo "[3/7] Config exists: $RUNTIME_DIR/config.json"
fi

if ! jq empty "$RUNTIME_DIR/config.json" >/dev/null 2>&1; then
    fail "Invalid JSON in $RUNTIME_DIR/config.json"
fi

SELECTED_AGENT_RUNTIME="$(jq -r '.automation.agentRuntime // "openclaw"' "$RUNTIME_DIR/config.json")"
case "$SELECTED_AGENT_RUNTIME" in
    openclaw) RUNTIME_COMMAND="openclaw"; RUNTIME_OVERRIDE="${OPENCLAW_BIN:-}" ;;
    opencode) RUNTIME_COMMAND="opencode"; RUNTIME_OVERRIDE="${OPENCODE_BIN:-}" ;;
    codex) RUNTIME_COMMAND="codex"; RUNTIME_OVERRIDE="${CODEX_BIN:-}" ;;
    claude-code) RUNTIME_COMMAND="claude"; RUNTIME_OVERRIDE="${CLAUDE_BIN:-}" ;;
    *)
        fail "Unsupported automation.agentRuntime '$SELECTED_AGENT_RUNTIME' (expected openclaw, opencode, codex, or claude-code)"
        ;;
esac
RUNTIME_OVERRIDE_AVAILABLE=false
if [ -n "$RUNTIME_OVERRIDE" ]; then
    if [[ "$RUNTIME_OVERRIDE" == */* ]]; then
        [ -x "$RUNTIME_OVERRIDE" ] && RUNTIME_OVERRIDE_AVAILABLE=true
    elif command -v "$RUNTIME_OVERRIDE" >/dev/null 2>&1; then
        RUNTIME_OVERRIDE_AVAILABLE=true
    fi
fi
if ! command -v "$RUNTIME_COMMAND" >/dev/null 2>&1 && [ "$RUNTIME_OVERRIDE_AVAILABLE" != "true" ]; then
    fail "Selected agent runtime '$SELECTED_AGENT_RUNTIME' is not installed (missing $RUNTIME_COMMAND or configured $SELECTED_AGENT_RUNTIME binary override)"
fi
echo "Selected agent runtime is available: $SELECTED_AGENT_RUNTIME"

# Collapse duplicate repository lists without widening access. The migration
# validates the canonical list before writing and keeps a recoverable backup.
if ! bash "$CANONICAL_DIR/migrate-repository-config.sh" "$RUNTIME_DIR/config.json"; then
    fail "Repository configuration migration failed"
fi

# Runtime selection is a single setting: automation.agentRuntime. Remove the
# obsolete roleRuntime key from existing installations without replacing any
# other operator-managed configuration.
CONFIG_FILE="$RUNTIME_DIR/config.json"
if jq -e '((.automation? // {}) | if type == "object" then has("roleRuntime") else false end)' "$CONFIG_FILE" >/dev/null 2>&1; then
    CONFIG_TMP="$(mktemp "$RUNTIME_DIR/.config.json.XXXXXX")" || fail "Could not prepare config migration"
    if ! jq 'if (.automation | type) == "object" then .automation |= del(.roleRuntime) else . end' "$CONFIG_FILE" > "$CONFIG_TMP"; then
        rm -f -- "$CONFIG_TMP"
        fail "Could not remove obsolete automation.roleRuntime"
    fi
    chmod --reference="$CONFIG_FILE" "$CONFIG_TMP" 2>/dev/null || {
        rm -f -- "$CONFIG_TMP"
        fail "Could not preserve config.json permissions during migration"
    }
    mv -f -- "$CONFIG_TMP" "$CONFIG_FILE" || {
        rm -f -- "$CONFIG_TMP"
        fail "Could not install migrated config.json"
    }
    echo "  Removed obsolete automation.roleRuntime; all tasks use automation.agentRuntime"
fi

# Validate only the backend selected by the operator. An unrelated installed
# backend must not make an incomplete installation look ready.
# 4b. Persist provider-specific environment needed by unattended processes.
#     Only an explicit allowlist is copied from the installer environment.
#     Existing ~/.manul/.env content is preserved.
echo
echo "  Preparing operator environment..."
if ! bash "$CANONICAL_DIR/manul-env.sh" --bootstrap "$RUNTIME_DIR"; then
    fail "Could not prepare $RUNTIME_DIR/.env"
fi
echo "  Environment file: $RUNTIME_DIR/.env"

# Use the exact persisted provider config that the daemon/watchdog will load.
# In particular, do not silently drop OPENCODE_CONFIG between install and run.
# shellcheck source=manul-env.sh
source "$CANONICAL_DIR/manul-env.sh"
if ! manul_env_load "$RUNTIME_DIR"; then
    fail "Could not load $RUNTIME_DIR/.env for provider configuration"
fi

# 4c. Configure provider-owned OpenCode permissions required by unattended Manul execution.
echo
echo "  Preparing OpenCode provider permissions..."
if ! bash "$CANONICAL_DIR/opencode-permissions.sh"; then
    fail "Could not prepare required OpenCode permissions"
fi

# 5. Bootstrap/migrate the DB
#    - missing/empty file -> only --init-state may bootstrap a fresh schema
#    - valid SQLite file -> init_schema/workspace_init are idempotent
#    - schema initialization failure -> fail closed; never replace the DB
#
# Explicit --init-state is the only destructive installer operation. Repair
# paths use repair-manul-runtime.sh, which restores an existing DB/backup.
echo
DB_FILE="$STATE_DIR/manul.db"
INSTALL_BASELINE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BOOTSTRAP_FRESH=false

backup_db() {
    [ -f "$DB_FILE" ] || return 0
    local base="${DB_FILE}.old-$(date +%Y%m%d-%H%M%S)"
    local backup="$base"
    local n=1
    while [ -e "$backup" ] || [ -e "${backup}-wal" ] || [ -e "${backup}-shm" ]; do
        backup="${base}-${n}"
        n=$((n + 1))
    done
    mv "$DB_FILE" "$backup" || return 1
    # Preserve SQLite sidecars with the DB backup so an old WAL cannot be
    # accidentally applied to the newly-created database.
    if [ -e "${DB_FILE}-wal" ]; then
        mv "${DB_FILE}-wal" "${backup}-wal" || return 1
    fi
    if [ -e "${DB_FILE}-shm" ]; then
        mv "${DB_FILE}-shm" "${backup}-shm" || return 1
    fi
    echo "  Previous DB preserved as: $backup"
}

reset_to_fresh_db() {
    if [ -f "$DB_FILE" ]; then
        backup_db || fail "Could not preserve existing DB before fresh bootstrap"
    else
        rm -f "${DB_FILE}-wal" "${DB_FILE}-shm"
    fi
    rm -f "$DB_FILE"
    BOOTSTRAP_FRESH=true
}

if [ ! -f "$DB_FILE" ]; then
    echo "[4/7] DB not found."
    if [ "$INIT_STATE" = true ]; then
        echo "  Explicit --init-state supplied; bootstrapping fresh DB."
        BOOTSTRAP_FRESH=true
    else
        fail "Manul DB is missing. Refusing to create a fresh DB implicitly; use repair-manul-runtime.sh or run install-manul.sh --init-state for first-time setup"
    fi
elif [ ! -s "$DB_FILE" ]; then
    if [ "$INIT_STATE" = true ]; then
        echo "[4/7] DB is empty; explicit --init-state allows fresh bootstrap."
        rm -f "$DB_FILE" "$DB_FILE-wal" "$DB_FILE-shm"
        BOOTSTRAP_FRESH=true
    else
        fail "Manul DB is empty. Refusing to replace task state implicitly; restore a backup or run install-manul.sh --init-state only for a deliberate fresh initialization"
    fi
elif ! head -c 16 "$DB_FILE" 2>/dev/null | grep -q "^SQLite format 3"; then
    if [ "$INIT_STATE" = true ]; then
        echo "[4/7] Existing DB is not SQLite; explicit --init-state allows replacement."
        reset_to_fresh_db
    else
        fail "Existing Manul DB is not SQLite. Refusing automatic replacement; repair or restore it explicitly"
    fi
elif ! sqlite3 "$DB_FILE" "PRAGMA integrity_check;" 2>/dev/null | grep -q "^ok$"; then
    if [ "$INIT_STATE" = true ]; then
        echo "[4/7] Existing DB failed integrity check; explicit --init-state allows replacement."
        reset_to_fresh_db
    else
        fail "Existing Manul DB failed integrity check. Refusing automatic replacement; repair or restore it explicitly"
    fi
else
    echo "[4/7] DB present and valid, validating/migrating schema..."
fi

export MANUL_DIR="$RUNTIME_DIR"
export DB="$DB_FILE"

init_current_db() {
    MANUL_DIR="$RUNTIME_DIR" DB="$DB_FILE" "$RUNTIME_DIR/manul-conversation.sh" init-schema &&
    MANUL_DIR="$RUNTIME_DIR" DB="$DB_FILE" bash -c 'source "$1"; workspace_init' _ "$CANONICAL_DIR/workspace-manager.sh"
}

if ! init_current_db; then
    fail "DB schema initialization failed; refusing to replace existing task state automatically"
fi

REQUIRED_TABLES="processed_comments conversations meta workspaces"
for table in $REQUIRED_TABLES; do
    if ! sqlite3 "$DB_FILE" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
        fail "Required table '$table' is missing from $DB_FILE"
    fi
done
echo "  Required tables present: $REQUIRED_TABLES"

# Persist the installation cutoff. Fresh installs get the exact installer
# timestamp; upgrades preserve an existing baseline so old GitHub comments stay
# excluded forever.
EXISTING_BASELINE="$(sqlite3 "$DB_FILE" "SELECT value FROM meta WHERE key='baseline';" 2>/dev/null || true)"
if [ -z "$EXISTING_BASELINE" ]; then
    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO meta(key,value) VALUES('baseline','$INSTALL_BASELINE');" 2>/dev/null ||         fail "Could not persist Manul installation baseline"
    echo "  Baseline initialized: $INSTALL_BASELINE"
else
    echo "  Baseline preserved: $EXISTING_BASELINE"
fi

if $BOOTSTRAP_FRESH; then
    echo "  Fresh DB bootstrap complete"
fi

# 7. Install watchdog cron + zsh shell integration.
#    Neither operation starts the daemon. The watchdog is dormant until .enabled
#    is created by an intentional start.
WATCHDOG_CRON="*/5 * * * * $RUNTIME_DIR/watchdog.sh"
if crontab -l 2>/dev/null | grep -qF "$WATCHDOG_CRON"; then
    echo
    echo "[5/7] Watchdog cron already installed"
else
    echo
    echo "[5/7] Installing watchdog cron (dormant until .enabled exists)..."
    (crontab -l 2>/dev/null; echo "$WATCHDOG_CRON") | crontab - || \
        fail "Could not install watchdog cron"
fi

ZSHRC="$HOME/.zshrc"
MANUL_SHELL_LINE="export MANUL_CANONICAL_DIR=\"$CANONICAL_DIR\"; source \"$CANONICAL_DIR/manul-shell.zsh\""
if [ ! -f "$ZSHRC" ]; then
    touch "$ZSHRC" || fail "Could not create $ZSHRC"
fi

# Remove obsolete Manul shell integrations from a previous skill checkout.
# Keep the current canonical source line and preserve the zshrc inode/mode.
ZSHRC_TMP="$(mktemp)" || fail "Could not create temporary zshrc migration file"
awk -v canonical="$CANONICAL_DIR/manul-shell.zsh" '
  /^[[:space:]]*(source|[.])[[:space:]]+/ &&
  index($0, "manul-shell.zsh") > 0 &&
  index($0, canonical) == 0 &&
  index($0, ";") == 0 { next }
  { print }
' "$ZSHRC" > "$ZSHRC_TMP" || fail "Could not filter stale Manul zsh entries"
if ! cmp -s "$ZSHRC" "$ZSHRC_TMP"; then
    cat "$ZSHRC_TMP" > "$ZSHRC" || fail "Could not remove stale Manul zsh entries"
    echo "[6/7] Removed stale Manul zsh integration"
fi
rm -f "$ZSHRC_TMP"

if grep -Fq "$MANUL_SHELL_LINE" "$ZSHRC"; then
    echo "[6/7] Manul zsh integration already installed"
else
    echo >> "$ZSHRC"
    echo "# Manul CLI (managed by Manul)" >> "$ZSHRC"
    echo "$MANUL_SHELL_LINE" >> "$ZSHRC"
    echo "[6/7] Installed Manul zsh integration"
fi

echo
echo "[7/7] Runtime prepared (not started)."
echo "  .enabled marker: absent"
echo "  Watchdog cron: installed but dormant until an intentional start"

# 7. Verify
echo
echo "=== Verification ==="
VERIFY_OK=true
for entry in manul-daemon.sh manul-status.sh manul-comments-remove.sh \
             start-manul-automation.sh watchdog.sh; do
    if [ -L "$RUNTIME_DIR/$entry" ] && [ -f "$(readlink -f "$RUNTIME_DIR/$entry")" ]; then
        echo "OK $entry -> $(readlink "$RUNTIME_DIR/$entry")"
    else
        echo "FAIL $entry: missing or broken symlink" >&2
        VERIFY_OK=false
    fi
done

for data_path in "$RUNTIME_DIR/config.json" "$RUNTIME_DIR/state/manul.db" "$RUNTIME_DIR/.env"; do
    if [ -f "$data_path" ]; then
        echo "OK $(realpath --relative-to="$RUNTIME_DIR" "$data_path") present"
    else
        echo "FAIL $data missing" >&2
        VERIFY_OK=false
    fi
done

if grep -Fq "$MANUL_SHELL_LINE" "$ZSHRC"; then
    echo "OK zsh integration present"
else
    echo "FAIL zsh integration missing from $ZSHRC" >&2
    VERIFY_OK=false
fi

if crontab -l 2>/dev/null | grep -qF "$WATCHDOG_CRON"; then
    echo "OK watchdog cron present"
else
    echo "FAIL watchdog cron missing" >&2
    VERIFY_OK=false
fi

echo
if $VERIFY_OK; then
    echo "=== Install Complete ==="
    echo "Runtime:    $RUNTIME_DIR"
    echo "Canonical:  $CANONICAL_DIR"
    echo
    echo "Start Manul manually with:"
    echo "  manul"
    echo "  # or explicitly:"
    echo "  $RUNTIME_DIR/start-manul-automation.sh start"
    exit 0
else
    echo "ERROR: installation verification failed" >&2
    exit 1
fi