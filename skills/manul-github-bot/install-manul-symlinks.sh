#!/bin/bash
# install-manul-symlinks.sh — Deploy Manul scripts via symlinks from canonical source
#
# This script creates symlinks from the runtime directory to the canonical
# skill source, enabling a single source of truth for all Manul executable code.
#
# Usage:
#   install-manul-symlinks.sh [--runtime-dir <path>] [--canonical-dir <path>] [--dry-run]
#
# Options:
#   --runtime-dir    Runtime scripts directory (default: ~/.manul)
#   --canonical-dir  Canonical skill source directory (default: ~/.globalskills/skills/manul-github-bot)
#   --dry-run        Show what would be done without making changes
#
# Safety:
#   - Preserves runtime data (config.json, manul.db, logs, workspace)
#   - Only removes regular file copies; never deletes data directories
#   - Creates absolute symlinks pointing to canonical source

set -euo pipefail

# Defaults
RUNTIME_DIR="${MANUL_RUNTIME_DIR:-$HOME/.manul}"
# Self-detect canonical source from this script's own location so the installer
# keeps working even if the skill is moved or the env var is unset. Explicit
# MANUL_CANONICAL_DIR always wins.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CANONICAL_DIR="${MANUL_CANONICAL_DIR:-$SCRIPT_DIR}"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --runtime-dir)
            RUNTIME_DIR="$2"
            shift 2
            ;;
        --canonical-dir)
            CANONICAL_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--runtime-dir <path>] [--canonical-dir <path>] [--dry-run]" >&2
            exit 1
            ;;
    esac
done

# Verify canonical directory exists
if [ ! -d "$CANONICAL_DIR" ]; then
    echo "ERROR: Canonical directory not found: $CANONICAL_DIR" >&2
    exit 1
fi
# Canonicalize to an absolute path so every symlink is absolute and survives
# changes of the current working directory (required for systemd/unattended use).
CANONICAL_DIR="$(cd "$CANONICAL_DIR" && pwd)"

# List of scripts to symlink (in executable order)
SCRIPTS=(
    "feedback.sh"
    "github-api-wrapper.sh"
    # manul-agent-wrapper.sh is DEPRECATED and intentionally NOT installed.
    # It is superseded by the AgentExecutor runtime abstraction
    # (openclaw/opencode/codex/claude-code adapters). Kept in source only as a
    # historical reference for the original OpenClaw-only invocation path.
    "manul-comments-remove.sh"
    "manul-conversation-linker.sh"
    "manul-conversation.sh"
    "manul-daemon.sh"
    "manul-github-events.sh"
    "manul-pr-review.sh"
    "manul-result-feedback.sh"
    "manul-result.sh"
    "manul-status.sh"
    "manul-submit.sh"
    "manul-wait.sh"
    "orchestrator.prompt.md"
    "poll.sh"
    # Generic task-source adapters (added in 9415b99). poll.sh sources
    # task-source.sh at runtime; if the symlinks are missing, every poll cycle
    # dies with `task_source_configured_sources: command not found` and the
    # generic provider path silently degrades to legacy GitHub Issues only.
    "task-source.sh"
    "task-source-github-issues.sh"
    "task-source-jira-tasks.sh"
    "task-source-todo-local.sh"
    "todo-local-mcp-url.sh"
    "task-source-todo-remote.sh"
    "todo-task-source-utils.sh"
    "todo-mcp-client.py"
    "start-manul-automation.sh"
    "task-recovery.sh"
    "manul-queue-reset.sh"
    "watchdog.sh"
    "workspace-manager.sh"
    # Agent execution runtime abstraction (added in runtime isolation refactor)
    "agent-executor.sh"
    "agent-execution-controller.sh"
    "agent-session-state.sh"
    "manul-paths.sh"
    "manul-failure-utils.sh"
    "manul-env.sh"
    "manul-platform.sh"
    "openclaw-adapter.sh"
    "opencode-adapter.sh"
    "codex-adapter.sh"
    "claude-code-adapter.sh"
    "agent-task-runner.sh"
    "process-runner.sh"
)

echo "=== Manul Symlink Installer ==="
echo "Canonical source: $CANONICAL_DIR"
echo "Runtime target:   $RUNTIME_DIR"
echo "Dry run:          $DRY_RUN"
echo

# Ensure the runtime directory exists. This is the first self-healing step:
# if the runtime was deleted/archived, recreate the directory before touching
# anything inside it. Runtime data (config.json, manul.db, logs, workspaces)
# lives alongside the symlinks and MUST be preserved.
if [ ! -d "$RUNTIME_DIR" ]; then
    if $DRY_RUN; then
        echo "[dry-run] Would create runtime directory: $RUNTIME_DIR"
    else
        mkdir -p "$RUNTIME_DIR"
        echo "Created runtime directory: $RUNTIME_DIR"
    fi
fi

# Deploy each script. Idempotent: only touch entries that are missing, broken,
# or pointing at the wrong target. Never copies canonical source into the
# runtime — every entry is an absolute symlink to $CANONICAL_DIR.
CHANGED=0
DEPLOY_FAILURES=0
for script in "${SCRIPTS[@]}"; do
    canonical_file="$CANONICAL_DIR/$script"
    runtime_path="$RUNTIME_DIR/$script"

    if [ ! -f "$canonical_file" ]; then
        echo "ERROR: Canonical script not found: $canonical_file" >&2
        DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
        continue
    fi

    # Determine whether the runtime entry is already correct.
    needs_deploy=false
    if [ -L "$runtime_path" ]; then
        current_target="$(readlink "$runtime_path" 2>/dev/null || true)"
        if [ "$current_target" = "$canonical_file" ] && [ -f "$runtime_path" ]; then
            echo "OK $script: symlink already correct"
            continue
        fi
        needs_deploy=true
        echo "Updating $script: ${current_target:-<broken>} -> $canonical_file"
    elif [ -e "$runtime_path" ]; then
        # A regular file or directory occupies the slot. Only a regular file
        # (or a broken symlink) is safe to replace; a directory would hide data.
        if [ -d "$runtime_path" ]; then
            echo "ERROR: $runtime_path is a directory, refusing to overwrite" >&2
            DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
            continue
        fi
        needs_deploy=true
        echo "Converting $script: regular file -> symlink"
    else
        needs_deploy=true
        echo "Creating $script: new symlink"
    fi

    if $DRY_RUN; then
        echo "  [dry-run] Would create symlink: $runtime_path -> $canonical_file"
        CHANGED=$((CHANGED + 1))
        continue
    fi

    # Remove existing entry (regular file or broken symlink only).
    if [ -f "$runtime_path" ] || [ -L "$runtime_path" ]; then
        rm -f "$runtime_path"
    fi
    # Create absolute symlink to canonical source.
    if ! ln -s "$canonical_file" "$runtime_path"; then
        echo "ERROR: failed to create symlink $runtime_path -> $canonical_file" >&2
        DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
        continue
    fi
    # Executable entry points must remain executable even if the canonical
    # checkout lost its execute bit. agent-task-runner.sh is invoked directly
    # by setsid and therefore cannot rely on being sourced.
    if [ "$script" = "agent-task-runner.sh" ] || [ "$script" = "manul-queue-reset.sh" ] || [ "$script" = "codex-adapter.sh" ] || [ "$script" = "claude-code-adapter.sh" ]; then
        chmod +x "$canonical_file" "$runtime_path" 2>/dev/null || true
    elif [ -x "$canonical_file" ]; then
        chmod +x "$runtime_path" 2>/dev/null || true
    fi
    CHANGED=$((CHANGED + 1))
done

# Verify deployment. Every declared entry must be a symlink whose resolved
# target is a real file inside the canonical source. A broken or misplaced
# link is a hard failure — the installer must exit non-zero so callers
# (systemd, watchdog, humans) know the runtime is not healthy.
echo
echo "=== Verification ==="
VERIFY_FAILURES=0
for script in "${SCRIPTS[@]}"; do
    runtime_path="$RUNTIME_DIR/$script"
    canonical_file="$CANONICAL_DIR/$script"
    if [ ! -f "$canonical_file" ]; then
        continue
    fi
    if [ -L "$runtime_path" ]; then
        target="$(readlink "$runtime_path" 2>/dev/null || true)"
        if [ "$target" = "$canonical_file" ] && [ -f "$runtime_path" ]; then
            echo "OK $script -> $target"
        else
            echo "FAIL $script -> BROKEN: target=$target resolved=$resolved" >&2
            VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
        fi
    else
        echo "FAIL $script: NOT a symlink" >&2
        VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    fi
done

# Summary
echo
if $DRY_RUN; then
    echo "Dry run complete. No changes made."
    exit 0
fi

echo "Deployment complete. $CHANGED script(s) updated."
echo
echo "Runtime data preserved (not touched by this installer):"
echo "  - $RUNTIME_DIR/config.json"
echo "  - $RUNTIME_DIR/state/manul.db"
echo "  - $RUNTIME_DIR/state/tasks/"
echo "  - $RUNTIME_DIR/state/locks/"
echo "  - $RUNTIME_DIR/logs/"
echo "  - $RUNTIME_DIR/workspace/"

# Exit non-zero if any declared symlink is missing, broken, or misplaced.
if [ "$DEPLOY_FAILURES" -gt 0 ] || [ "$VERIFY_FAILURES" -gt 0 ]; then
    echo "ERROR: installer finished with $DEPLOY_FAILURES deploy failure(s) and $VERIFY_FAILURES verification failure(s)" >&2
    exit 1
fi
exit 0
