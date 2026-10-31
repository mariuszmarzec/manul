#!/usr/bin/env zsh
# manul-shell.zsh — Manul CLI entrypoints for interactive shells.
#
# Source this from ~/.zshrc:
#   source "$HOME/.globalskills/skills/manul-github-bot/manul-shell.zsh"
#
# All three CLI entrypoints point at the CANONICAL source scripts, never at the
# runtime dir. This means deleting/archiving ~/.manul can never
# permanently break `manul`, `manul-status`, or `manul-comments-remove`.
#
# Self-healing: manul-ensure-runtime() runs the repair path when the
# runtime is missing or any CLI entrypoint is not a usable file. Repair is
# fail-closed: it restores an existing DB from backup/archive and never
# fabricates a fresh application DB during self-healing. All three CLI
# entrypoints are checked, not just manul-daemon.sh.
#
# The `.enabled` marker is the lifecycle contract:
#   - install-manul.sh prepares the runtime but does NOT start anything and does
#     NOT create the marker.
#   - the `manul` alias / start-manul-automation.sh start (intentional start)
#     CREATE it.
#   - start-manul-automation.sh stop / manul-daemon.sh stop REMOVE it.
#   - watchdog.sh only restarts the daemon when it is present, so crash recovery
#     never re-enables automation.

MANUL_CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$HOME/.globalskills/skills/manul-github-bot}"
MANUL_RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.manul}"
MANUL_INSTALLER="$MANUL_CANONICAL_DIR/install-manul.sh"
MANUL_REPAIR="$MANUL_CANONICAL_DIR/repair-manul-runtime.sh"
MANUL_AUTOMATION="$MANUL_CANONICAL_DIR/start-manul-automation.sh"

manul-ensure-runtime() {
    if [ ! -d "$MANUL_RUNTIME_DIR" ] \
       || [ ! -f "$MANUL_RUNTIME_DIR/manul-daemon.sh" ] \
       || [ ! -f "$MANUL_RUNTIME_DIR/manul-status.sh" ] \
       || [ ! -f "$MANUL_RUNTIME_DIR/manul-comments-remove.sh" ]; then
        # Keep repair output off this function's stdout. CLI callers commonly
        # pipe status through head/grep; a closed stdout pipe must not SIGPIPE
        # the installer halfway through deployment.
        local repair_log
        repair_log="$(mktemp "${TMPDIR:-/tmp}/manul-runtime-repair.XXXXXX")" || {
            echo "ERROR: could not create a temporary Manul repair log" >&2
            return 1
        }

        if ! "$MANUL_REPAIR" >"$repair_log" 2>&1; then
            echo "ERROR: failed to repair Manul runtime without risking task state" >&2
            echo "Repair log retained at: $repair_log" >&2
            echo "Run the installer explicitly for a first-time initialization." >&2
            return 1
        fi

        rm -f "$repair_log"
    fi
}

# Remove legacy aliases before defining the canonical functions.
unalias manul manul-status manul-comments-remove 2>/dev/null || true

# manul is the intentional lifecycle entrypoint.
# With no arguments it starts Manul; explicit subcommands are passed through.
manul() {
    local action="start"
    if (( $# > 0 )); then
        action="$1"
        shift
    fi

    # Accept both readable subcommands and convenient long-option flags.
    case "$action" in
        --start) action="start" ;;
        --stop) action="stop" ;;
        --restart) action="restart" ;;
        --status) action="status" ;;
    esac

    case "$action" in
        start|stop|restart|status)
            ;;
        *)
            echo "Usage: manul [--start|--stop|--restart|--status]" >&2
            echo "       manul [start|stop|restart|status]" >&2
            return 2
            ;;
    esac

    manul-ensure-runtime || return $?
    "$MANUL_AUTOMATION" "$action" "$@"
}

manul-status() {
    manul-ensure-runtime || return $?
    "$MANUL_CANONICAL_DIR/manul-status.sh" "$@"
}

manul-comments-remove() {
    manul-ensure-runtime || return $?
    "$MANUL_CANONICAL_DIR/manul-comments-remove.sh" "$@"
}
