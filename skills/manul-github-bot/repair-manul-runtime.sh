#!/usr/bin/env bash
# repair-manul-runtime.sh — Repair Manul runtime directory
#
# Usage:
#   repair-manul-runtime.sh [--runtime-dir <path>] [--source-db <path>]
#
# This script repairs a broken or missing Manul runtime directory by:
# 1. Creating the runtime directory
# 2. Deploying symlinks to canonical scripts
# 3. Restoring config.json from template if missing
# 4. Restoring manul.db from an existing backup
# 5. Preparing provider environment for unattended runs
# 6. Validating/upgrading the DB using the canonical Manul init routines
#
# The repair script never invents a new application schema. A missing or
# invalid DB must be restored from an explicit backup or a previously-created
# runtime archive.
#
# Options:
#   --runtime-dir   Override MANUL_RUNTIME_DIR (default: ~/.manul)
#   --source-db     Override MANUL_SOURCE_DB (explicit backup path)

set -euo pipefail

RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.manul}"
SOURCE_DB="${MANUL_SOURCE_DB:-}"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
SCRIPT_DIR="$CANONICAL_DIR"
source "$SCRIPT_DIR/manul-platform.sh"
manul_platform_prepare || exit 1
manul_platform_reexec_if_needed "$SCRIPT_DIR/repair-manul-runtime.sh" "$@"

# Parse CLI flags (env vars take priority; flags override defaults only)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
        --source-db)   SOURCE_DB="$2";    shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--runtime-dir <path>] [--source-db <path>]"
            echo ""
            echo "Options:"
            echo "  --runtime-dir  Runtime directory (default: ~/.manul)"
            echo "  --source-db    Explicit backup DB path"
            echo ""
            echo "Environment overrides:"
            echo "  MANUL_RUNTIME_DIR  Runtime directory"
            echo "  MANUL_SOURCE_DB    Explicit backup DB path"
            echo "  MANUL_CANONICAL_DIR  Canonical skill directory"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--runtime-dir <path>] [--source-db <path>]" >&2
            exit 1
            ;;
    esac
done

STATE_DIR="$RUNTIME_DIR/state"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

if [ ! -d "$CANONICAL_DIR" ]; then
    fail "Canonical Manul directory does not exist: $CANONICAL_DIR"
fi

if [ ! -x "$CANONICAL_DIR/install-manul-symlinks.sh" ]; then
    fail "Missing or non-executable install-manul-symlinks.sh in $CANONICAL_DIR"
fi

echo "=== Manul Runtime Repair ==="
printf 'Runtime:    %s\n' "$RUNTIME_DIR"
printf 'Canonical:  %s\n\n' "$CANONICAL_DIR"

if [ ! -d "$RUNTIME_DIR" ]; then
    echo "[1/5] Creating runtime directory: $RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR" "$STATE_DIR" "$STATE_DIR/locks" "$STATE_DIR/tasks" "$RUNTIME_DIR/logs" "$RUNTIME_DIR/workspace"
else
    echo "[1/5] Runtime directory exists: $RUNTIME_DIR"
fi

echo "[2/5] Deploying symlinks..."
"$CANONICAL_DIR/install-manul-symlinks.sh" --runtime-dir "$RUNTIME_DIR"

if [ ! -f "$RUNTIME_DIR/config.json" ]; then
    echo
    echo "[3/5] Config not found, restoring template..."
    if [ -f "$CANONICAL_DIR/config.json.example" ]; then
        cp "$CANONICAL_DIR/config.json.example" "$RUNTIME_DIR/config.json"
        echo "  Copied config.json.example -> config.json"
        echo "  WARNING: Edit $RUNTIME_DIR/config.json before starting daemon"
    else
        fail "No config.json and no config.json.example found in $CANONICAL_DIR"
    fi
else
    echo
    echo "[3/5] Config exists: $RUNTIME_DIR/config.json"
fi

if ! jq empty "$RUNTIME_DIR/config.json" >/dev/null 2>&1; then
    fail "Invalid JSON in $RUNTIME_DIR/config.json"
fi

echo
echo "  Preparing operator environment..."
if ! bash "$CANONICAL_DIR/manul-env.sh" --bootstrap "$RUNTIME_DIR"; then
    fail "Could not prepare $RUNTIME_DIR/.env"
fi
echo "  Environment file: $RUNTIME_DIR/.env"

# The permission helper must use the same custom OpenCode config as daemon/watchdog.
# shellcheck source=manul-env.sh
source "$CANONICAL_DIR/manul-env.sh"
if ! manul_env_load "$RUNTIME_DIR"; then
    fail "Could not load $RUNTIME_DIR/.env for provider configuration"
fi

echo
echo "  Preparing OpenCode provider permissions..."
if ! bash "$CANONICAL_DIR/opencode-permissions.sh"; then
    fail "Could not prepare required OpenCode permissions"
fi

DB_FILE="$STATE_DIR/manul.db"
REPAIR_BASELINE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# db_is_valid: return 0 if the file is a non-empty, integrity-passing SQLite DB
# ---------------------------------------------------------------------------
db_is_valid() {
    local db="$1"
    # Must be a regular file and non-empty
    [ -f "$db" ] || return 1
    [ -s "$db" ] || return 1
    # SQLite header must be present ("SQLite format 3\000")
    head -c 16 "$db" 2>/dev/null | grep -q "^SQLite format 3" || return 1
    # Integrity check must pass
    local integrity
    integrity="$(sqlite3 "$db" 'PRAGMA integrity_check;' 2>&1)" || return 1
    [ "$integrity" = "ok" ] || return 1
    return 0
}

restore_db() {
    local source="$1"
    local staged="${DB_FILE}.restore.$$"

    rm -f "$staged"
    if ! cp "$source" "$staged"; then
        rm -f "$staged"
        fail "Failed to copy DB backup: $source"
    fi

    # Verify the SQLite file before replacing the runtime DB. This catches
    # truncated/corrupt backups without leaving a bad manul.db behind.
    local integrity
    integrity="$(sqlite3 "$staged" 'PRAGMA integrity_check;' 2>&1)" || {
        rm -f "$staged"
        printf '%s\n' "$integrity" >&2
        fail "SQLite integrity check failed for backup: $source"
    }
    if [ "$integrity" != "ok" ]; then
        rm -f "$staged"
        printf 'SQLite integrity check returned: %s\n' "$integrity" >&2
        fail "SQLite backup is not healthy: $source"
    fi

    if ! mv -f "$staged" "$DB_FILE"; then
        rm -f "$staged"
        fail "Failed to install restored DB: $DB_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Step 4: ensure a valid manul.db exists
# ---------------------------------------------------------------------------
if db_is_valid "$DB_FILE"; then
    echo
    echo "[4/5] DB valid: $DB_FILE"
else
    echo
    echo "[4/5] DB missing or invalid, attempting restore..."
    RESTORED=false

    if [ -n "$SOURCE_DB" ]; then
        if [ ! -f "$SOURCE_DB" ]; then
            fail "MANUL_SOURCE_DB does not point to a file: $SOURCE_DB"
        fi
        restore_db "$SOURCE_DB"
        RESTORED=true
        echo "  Restored DB from: $SOURCE_DB"
    else
        # Look for the newest archived runtime sibling, e.g.
        # ~/.manul-archive-20260916-123456/manul.db
        ARCHIVE_ROOT="$(dirname "$RUNTIME_DIR")"
        ARCHIVE_PREFIX="$(basename "$RUNTIME_DIR")-archive-"
        LATEST_BAK=""
        if [ -d "$ARCHIVE_ROOT" ]; then
            while IFS= read -r -d '' archive_dir; do
                candidate="$archive_dir/state/manul.db"
                if [ -f "$candidate" ]; then
                    LATEST_BAK="$candidate"
                    break
                fi
            done < <(find "$ARCHIVE_ROOT" -maxdepth 1 -mindepth 1 -type d -name "${ARCHIVE_PREFIX}*" -printf '%T@ %p\0' 2>/dev/null | sort -z -nr | sed -z 's/^[^ ]* //')
        fi

        if [ -n "$LATEST_BAK" ]; then
            restore_db "$LATEST_BAK"
            RESTORED=true
            echo "  Restored DB from archive: $LATEST_BAK"
        fi
    fi

    if [ "$RESTORED" = false ]; then
        echo
        echo "ERROR: No valid backup DB found."
        echo "To restore from a backup, run:"
        echo "  $0 --source-db /path/to/backup/manul.db"
        echo
        echo "Recovery aborted. A valid manul.db is required; no new application schema will be fabricated."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: validate/upgrade schema (idempotent — no-op if tables exist)
# ---------------------------------------------------------------------------
echo
echo "[5/5] Validating DB schema..."

MANUL_DIR="$RUNTIME_DIR" "$RUNTIME_DIR/manul-conversation.sh" init-schema || \
    fail "Canonical conversation schema initialization failed"

export MANUL_DIR="$RUNTIME_DIR"
export DB="$DB_FILE"
MANUL_DIR="$RUNTIME_DIR" DB="$DB_FILE" bash -c 'source "$1"; workspace_init' _ "$CANONICAL_DIR/workspace-manager.sh" || \
    fail "Canonical workspace initialization failed"

REQUIRED_TABLES="processed_comments conversations meta workspaces"
for table in $REQUIRED_TABLES; do
    if ! sqlite3 "$DB_FILE" "SELECT 1 FROM $table LIMIT 1;" >/dev/null 2>&1; then
        fail "Required table '$table' is missing from $DB_FILE"
    fi
done

# Legacy DBs may predate the persistent polling cutoff. Initialize it once
# during repair; an existing baseline is always preserved.
EXISTING_BASELINE="$(sqlite3 "$DB_FILE" "SELECT value FROM meta WHERE key='baseline';" 2>/dev/null || true)"
if [ -z "$EXISTING_BASELINE" ]; then
    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO meta(key,value) VALUES('baseline','$REPAIR_BASELINE');" 2>/dev/null ||         fail "Could not persist Manul repair baseline"
    echo "  Baseline initialized during repair: $REPAIR_BASELINE"
else
    echo "  Baseline preserved: $EXISTING_BASELINE"
fi

echo "  Required tables present: $REQUIRED_TABLES"
echo
echo "=== Repair Complete ==="
echo "Start daemon with:"
echo "  setsid $RUNTIME_DIR/manul-daemon.sh start >/dev/null 2>&1 &"
echo
echo "Or use the automation wrapper:"
echo "  $RUNTIME_DIR/start-manul-automation.sh start"
