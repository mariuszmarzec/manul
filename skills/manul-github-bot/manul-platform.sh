#!/usr/bin/env bash
# Shared host compatibility bootstrap for Manul and aicode.
# Source this file before starting Manul processes so detached workers inherit
# the same Bash and GNU utility implementations as the interactive launcher.

manul_platform_prepare() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0

    local brew_bin="" prefix="" command_name
    if command -v brew >/dev/null 2>&1; then
        brew_bin="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
        brew_bin=/opt/homebrew/bin/brew
    elif [ -x /usr/local/bin/brew ]; then
        brew_bin=/usr/local/bin/brew
    fi

    if [ -z "$brew_bin" ]; then
        echo "ERROR: Manul on macOS requires Homebrew. Install Homebrew, then run: brew install bash coreutils util-linux" >&2
        return 1
    fi

    prefix="$("$brew_bin" --prefix 2>/dev/null || true)"
    if [ -z "$prefix" ]; then
        echo "ERROR: unable to resolve the Homebrew prefix using $brew_bin." >&2
        return 1
    fi

    HOMEBREW_PREFIX="$prefix"
    export HOMEBREW_PREFIX
    PATH="$prefix/opt/bash/bin:$prefix/opt/coreutils/libexec/gnubin:$prefix/opt/util-linux/bin:$prefix/bin:$PATH"
    export PATH

    local missing=()
    for command_name in bash flock setsid timeout realpath stat sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: Manul's macOS runtime dependencies are missing: ${missing[*]}" >&2
        echo "Install them with: brew install bash coreutils util-linux" >&2
        return 1
    fi
}

manul_platform_reexec_if_needed() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
    [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] && return 0

    local script_path="$1"
    shift
    local bash_bin="${HOMEBREW_PREFIX:-}/opt/bash/bin/bash"
    if [ ! -x "$bash_bin" ]; then
        echo "ERROR: Manul requires Bash 4+ on macOS; expected $bash_bin." >&2
        return 1
    fi
    exec "$bash_bin" "$script_path" "$@"
}
