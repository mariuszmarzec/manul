#!/usr/bin/env bash
# manul-zsh-bootstrap.sh — initialize Manul from the operator's Zsh environment.
#
# Manul's runtime scripts remain Bash. This wrapper only makes sure that an
# unattended entrypoint (notably the cron watchdog) first loads ~/.zshrc so its
# exported PATH/provider/tool settings are inherited by the Bash process tree.
#
# Interactive Manul commands already enter through manul-shell.zsh, which sets
# MANUL_ZSH_ENV_READY=1; those commands do not start a second Zsh process.

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: manul-zsh-bootstrap.sh <command> [args...]" >&2
    exit 2
fi

if [ "${MANUL_ZSH_ENV_READY:-}" = "1" ]; then
    exec "$@"
fi

ZSH_EXECUTABLE=""
if [ -n "${ZSH_BIN:-}" ]; then
    case "$ZSH_BIN" in
        */*)
            [ -x "$ZSH_BIN" ] && ZSH_EXECUTABLE="$ZSH_BIN"
            ;;
        *)
            ZSH_EXECUTABLE="$(command -v -- "$ZSH_BIN" 2>/dev/null || true)"
            ;;
    esac
fi
if [ -z "$ZSH_EXECUTABLE" ]; then
    ZSH_EXECUTABLE="$(command -v zsh 2>/dev/null || true)"
fi
if [ -z "$ZSH_EXECUTABLE" ]; then
    for candidate in /usr/bin/zsh /bin/zsh /usr/local/bin/zsh /opt/homebrew/bin/zsh; do
        if [ -x "$candidate" ]; then
            ZSH_EXECUTABLE="$candidate"
            break
        fi
    done
fi

if [ -z "$ZSH_EXECUTABLE" ] || [ ! -x "$ZSH_EXECUTABLE" ]; then
    echo "ERROR: zsh is required to load the operator's ~/.zshrc for unattended Manul execution" >&2
    exit 127
fi

# -i loads ~/.zshrc (the operator's source of truth); -c executes the target.
# Do not use a login shell here: Manul needs the interactive rc environment,
# without adding a second, separately maintained login-profile configuration.
#
# A user's ~/.zshrc may start ssh-agent and add keys. Hide only those routine
# status lines; keep all other startup diagnostics and Manul output visible.
# Capture stderr in a private temporary file so filtering completes before this
# process exits. Process substitution here is asynchronous and can write to a
# restored parent stderr descriptor after the caller's redirection has ended.
umask 077
stderr_file="$(mktemp "${TMPDIR:-/tmp}/manul-zsh-bootstrap.stderr.XXXXXX")" || {
    echo "ERROR: could not create a private temporary file for Zsh startup diagnostics" >&2
    exit 1
}
trap 'rm -f -- "$stderr_file"' EXIT

set +e
"$ZSH_EXECUTABLE" -ic '
    export MANUL_ZSH_ENV_READY=1
    exec "$@"
' manul-zsh-bootstrap "$@" 2>"$stderr_file" \
    | sed -E '/^Agent pid [0-9]+$/d; /^Identity added: /d'
pipeline_status=("${PIPESTATUS[@]}")
set -e

if ! sed -E '/^Agent pid [0-9]+$/d; /^Identity added: /d' "$stderr_file" >&2; then
    echo "ERROR: could not forward filtered Zsh startup diagnostics" >&2
    exit 1
fi

if [ "${pipeline_status[0]}" -ne 0 ]; then
    exit "${pipeline_status[0]}"
fi
exit "${pipeline_status[1]}"
