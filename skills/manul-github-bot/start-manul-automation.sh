#!/usr/bin/env bash
# start-manul-automation.sh — Manul automation startup/management wrapper
#
# Manages the canonical runtime components:
#   manul-daemon.sh  — background poll loop (polls GitHub, dispatches orchestrator)
#   watchdog.sh      — automatic recovery via cron (daemon liveness + heartbeat/lease)
#
# Does NOT start task-health-check.sh (legacy/deprecated).
# Does NOT create multiple recovery mechanisms.
#
# Usage:
#   start-manul-automation.sh start    — start daemon + install watchdog cron
#   start-manul-automation.sh stop     — stop daemon
#   start-manul-automation.sh status   — show daemon + watchdog status
#   start-manul-automation.sh restart  — stop then start

set -uo pipefail

MANUL_DIR="${MANUL_DIR:-$HOME/.manul}"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/manul-platform.sh"
manul_platform_prepare || exit 1
manul_platform_reexec_if_needed "$SCRIPT_DIR/start-manul-automation.sh" "$@"

DAEMON="$MANUL_DIR/manul-daemon.sh"
WATCHDOG="$MANUL_DIR/watchdog.sh"
WATCHDOG_CRON="*/5 * * * * $WATCHDOG"

log() { echo "[$(date -Is)] $*"; }

install_watchdog_cron() {
    # Install watchdog cron if not already present
    if crontab -l 2>/dev/null | grep -qF "$WATCHDOG"; then
        log "watchdog cron already installed"
    else
        (crontab -l 2>/dev/null; echo "$WATCHDOG_CRON") | crontab -
        log "watchdog cron installed (every 5 minutes)"
    fi
}

remove_watchdog_cron() {
    if crontab -l 2>/dev/null | grep -qF "$WATCHDOG"; then
        crontab -l 2>/dev/null | grep -vF "$WATCHDOG" | crontab -
        log "watchdog cron removed"
    fi
}

case "${1:-}" in
    start)
        log "Starting manul automation..."
        # The runtime is a symlinked view of the canonical source. Before
        # starting, require that the configured canonical source is a real
        # git checkout and fast-forward it to origin/master when possible.
        CANONICAL_ROOT="${MANUL_CANONICAL_ROOT:-$HOME/.globalskills}"
        CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$CANONICAL_ROOT/skills/manul-github-bot}"
        if [ -d "$CANONICAL_ROOT/.git" ]; then
            if git -C "$CANONICAL_ROOT" fetch origin master --quiet >/dev/null 2>&1; then
                if ! git -C "$CANONICAL_ROOT" merge --ff-only origin/master >/dev/null 2>&1; then
                    log "ERROR: canonical globalskills checkout is not fast-forwardable to origin/master"
                    exit 1
                fi
            else
                log "ERROR: failed to fetch canonical globalskills/master"
                exit 1
            fi
        fi
        SYMLINK_INSTALLER="$CANONICAL_DIR/install-manul-symlinks.sh"
        if [ ! -x "$SYMLINK_INSTALLER" ]; then
            log "ERROR: canonical Manul symlink installer not found: $SYMLINK_INSTALLER"
            exit 1
        fi
        if ! "$SYMLINK_INSTALLER" --runtime-dir "$MANUL_DIR" --canonical-dir "$CANONICAL_DIR" >/dev/null 2>&1; then
            log "ERROR: failed to refresh Manul runtime symlinks from $CANONICAL_DIR"
            exit 1
        fi
        # Ensure direct executable entry points are executable. The task runner
        # is launched by setsid and is not sourced, so enforce its execute bit
        # independently of the canonical file mode.
        chmod +x "$DAEMON" "$WATCHDOG" "$MANUL_DIR/agent-task-runner.sh" 2>/dev/null || true
        # Lifecycle marker: this is an INTENTIONAL start. Touch .enabled
        # unconditionally — even if the daemon is already running (and its
        # start() early-returns before touching the marker), the wrapper is the
        # authoritative start path and must leave the marker present so the
        # watchdog is allowed to recover the daemon.
        touch "$MANUL_DIR/.enabled"
        # Start daemon. Install watchdog even when startup fails so the
        # independent recovery path remains available, but preserve the failure
        # status instead of claiming automation started successfully.
        daemon_rc=0
        # Start daemon detached so the long-lived master survives the wrapper exit.
        # Without this, the master process ends when start() returns, leaving a stale
        # PID file and causing watchdog to restart it in an endless loop.
        setsid nohup "$DAEMON" start >>"$MANUL_DIR/daemon.log" 2>&1 &
        sleep 2
        if ! "$DAEMON" status >/dev/null 2>&1; then
            log "Manul daemon did not stay running after startup; rc=$daemon_rc"
            daemon_rc=1
        fi

        # Install watchdog cron regardless of daemon startup result. The watchdog
        # is the recovery mechanism for exactly this class of failure.
        install_watchdog_cron

        if [ "$daemon_rc" -ne 0 ]; then
            log "Manul automation startup failed (daemon rc=$daemon_rc); watchdog installed for recovery"
            exit "$daemon_rc"
        fi

        log "Manul automation started"
        ;;
    stop)
        log "Stopping manul automation..."
        # Lifecycle marker: this is an INTENTIONAL stop. Remove .enabled so the
        # watchdog stops trying to restart the daemon. Done before the daemon
        # stop so a "not running" answer still clears a stale marker.
        rm -f "$MANUL_DIR/.enabled"
        "$DAEMON" stop
        remove_watchdog_cron
        log "Manul automation stopped"
        ;;
    status)
        echo "=== Manul Automation Status ==="
        "$DAEMON" status
        echo ""
        echo "Watchdog cron:"
        if crontab -l 2>/dev/null | grep -qF "$WATCHDOG"; then
            echo "  installed (every 5 minutes)"
        else
            echo "  NOT installed"
        fi
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}" >&2
        exit 1
        ;;
esac
