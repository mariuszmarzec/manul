#!/usr/bin/env bash
# manul-env.sh — Load and bootstrap Manul operator environment.
#
# The daemon and watchdog can run from cron/systemd without a login shell, so
# provider-specific environment must not rely on ~/.zshrc.
#
# Runtime-owned environment file:
#   ~/.manul/.env
#
# The bootstrap operation preserves existing operator settings and adds only
# explicitly supported provider values. It never copies arbitrary environment variables.

manul_env_file() {
  local runtime_dir="${1:-${MANUL_DIR:-$HOME/.manul}}"
  printf '%s/.env' "$runtime_dir"
}

manul_env_load() {
  local runtime_dir="${1:-${MANUL_DIR:-$HOME/.manul}}"
  local env_file
  env_file="$(manul_env_file "$runtime_dir")"

  [ -f "$env_file" ] || return 0

  if ! bash -n "$env_file" >/dev/null 2>&1; then
    echo "ERROR: invalid shell syntax in Manul environment file: $env_file" >&2
    return 1
  fi

  set -a
  # shellcheck disable=SC1090
  . <(awk '
    $0 !~ /^[[:space:]]*(export[[:space:]]+)?TODO_LOCAL_MCP_TOKEN=/ &&
    $0 !~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_MCP_URL=/ &&
    $0 !~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_ACCESS_TOKEN=/
  ' "$env_file")
  set +a
}

manul_env_bootstrap() {
  local runtime_dir="${1:?runtime directory required}"
  local env_file
  env_file="$(manul_env_file "$runtime_dir")"

  mkdir -p "$runtime_dir" || return 1

  if [ -e "$env_file" ] && [ ! -f "$env_file" ]; then
    echo "ERROR: Manul environment path exists but is not a regular file: $env_file" >&2
    return 1
  fi

  if [ ! -f "$env_file" ]; then
    if ! cat > "$env_file" <<'EOF'
# Manul operator environment.
#
# This file is loaded by unattended Manul processes (daemon/watchdog).
# Keep provider-specific paths here when they are not available from cron,
# for example OPENCLAW_STATE_DIR, OPENCODE_CONFIG, CODEX_HOME/CODEX_BIN/
# CODEX_MODEL and CLAUDE_CONFIG_DIR/CLAUDE_BIN/CLAUDE_MODEL. Only supported
# variables are persisted.
#
# The installer only copies a small allowlist of provider variables from the
# current process environment. Existing entries are always preserved.
EOF
    then
      return 1
    fi
  chmod 600 "$env_file" || return 1
  fi

  local variable value refreshed_file
  for variable in \
    OPENCLAW_STATE_DIR \
    OPENCLAW_CONFIG_PATH \
    OPENCLAW_HOME \
    OPENCLAW_GATEWAY_PORT \
    OPENCLAW_BIN \
    OPENCODE_BIN \
    OPENCODE_CONFIG \
    CODEX_HOME \
    CODEX_BIN \
    CODEX_MODEL \
    CLAUDE_CONFIG_DIR \
    CLAUDE_BIN \
    CLAUDE_MODEL \
    MANUL_JIRA_USER \
    MANUL_JIRA_PASSWORD \
    MANUL_CANONICAL_DIR \
    MANUL_CANONICAL_ROOT \
    MANUL_CANONICAL_BRANCH; do
    value="${!variable:-}"
    [ -n "$value" ] || continue

    if ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${variable}=" "$env_file"; then
      printf '%s=%q\n' "$variable" "$value" >> "$env_file"
      echo "  Captured $variable for unattended Manul processes" >&2
    fi
  done

  # FITEO_PAT belongs to the interactive/operator aicode session, not Manul.
  # Remove it from any legacy Manul runtime file so an ACP wrapper cannot
  # accidentally resurrect the operator identity from stale runtime state.
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?FITEO_PAT=" "$env_file"; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '$0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_PAT=/' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
    echo "  Removed legacy operator Fiteo PAT from Manul runtime environment" >&2
  fi

  # Canonical source locations are migration-sensitive: refresh them on every
  # installer bootstrap so obsolete source-path overrides cannot remain in the
  # unattended daemon/watchdog environment after source extraction.
  if [ -n "${MANUL_CANONICAL_DIR:-}" ]; then
    local canonical_refresh_file
    canonical_refresh_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?MANUL_CANONICAL_DIR=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?MANUL_CANONICAL_ROOT=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?MANUL_CANONICAL_BRANCH=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?MANUL_HOST_SKILLS_DIR=/
    ' "$env_file" > "$canonical_refresh_file"; then
      rm -f -- "$canonical_refresh_file"
      return 1
    fi
    printf 'MANUL_CANONICAL_DIR=%q\n' "$MANUL_CANONICAL_DIR" >> "$canonical_refresh_file"
    if [ -n "${MANUL_CANONICAL_ROOT:-}" ]; then
      printf 'MANUL_CANONICAL_ROOT=%q\n' "$MANUL_CANONICAL_ROOT" >> "$canonical_refresh_file"
    fi
    if [ -n "${MANUL_CANONICAL_BRANCH:-}" ]; then
      printf 'MANUL_CANONICAL_BRANCH=%q\n' "$MANUL_CANONICAL_BRANCH" >> "$canonical_refresh_file"
    fi
    chmod 600 "$canonical_refresh_file" || { rm -f -- "$canonical_refresh_file"; return 1; }
    mv -- "$canonical_refresh_file" "$env_file" || { rm -f -- "$canonical_refresh_file"; return 1; }
    echo "  Refreshed standalone Manul source paths" >&2
  fi

  if grep -qE '^[[:space:]]*(export[[:space:]]+)?TODO_LOCAL_MCP_TOKEN=' "$env_file"; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '$0 !~ /^[[:space:]]*(export[[:space:]]+)?TODO_LOCAL_MCP_TOKEN=/' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
    echo "  Removed legacy local Todo MCP credential from Manul runtime environment" >&2
  fi

  # Caracal is an operator-owned optional service, not a Manul dependency.
  # Do not load or retain stale credentials from older Manul installations.
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?(CARACAL_MCP_URL|CARACAL_ACCESS_TOKEN)=' "$env_file"; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_MCP_URL=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_ACCESS_TOKEN=/
    ' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
    echo "  Removed obsolete Caracal credentials from Manul runtime environment" >&2
  fi

  # Manul uses a dedicated Fiteo identity. Never persist or fall back to the
  # operator's FITEO_PAT: remote Todo reads and the task-scoped MCP use only the
  # PAT belonging to the Manul account.
  if [ -n "${FITEO_BASE_URL:-}" ] && [ -n "${FITEO_MANUL_PAT:-}" ]; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_BASE_URL=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_MANUL_PAT=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_MANUL_SHARE_USER_ID=/
    ' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    printf 'FITEO_BASE_URL=%q\nFITEO_MANUL_PAT=%q\n' \
      "$FITEO_BASE_URL" "$FITEO_MANUL_PAT" >> "$refreshed_file"
    if [[ "${FITEO_MANUL_SHARE_USER_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
      printf 'FITEO_MANUL_SHARE_USER_ID=%q\n' "$FITEO_MANUL_SHARE_USER_ID" >> "$refreshed_file"
    fi
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
    echo "  Refreshed Manul Fiteo MCP endpoint/PAT for unattended processes" >&2
  fi

  # FITEO_BASE_URL may be supplied by the login shell while the dedicated
  # PAT already lives in ~/.manul/.env. Persist the URL independently so the
  # configured {env:FITEO_BASE_URL} placeholder also works after daemon restart.
  if [ -n "${FITEO_BASE_URL:-}" ] && [ -z "${FITEO_MANUL_PAT:-}" ]; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '$0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_BASE_URL=/' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    printf 'FITEO_BASE_URL=%q\n' "$FITEO_BASE_URL" >> "$refreshed_file"
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
    echo "  Refreshed Fiteo base URL for unattended processes" >&2
  fi

  # Jira credentials may use operator-selected environment variable names.
  # Capture only names explicitly configured by enabled Jira task sources; never
  # copy arbitrary process environment variables into Manul runtime state.
  local jira_variable
  if [ -f "$runtime_dir/config.json" ]; then
    while IFS= read -r jira_variable; do
      [ -n "$jira_variable" ] || continue
      if [[ ! "$jira_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  Ignoring invalid Jira environment variable name: $jira_variable" >&2
        continue
      fi
      value="${!jira_variable:-}"
      if [ -n "$value" ] && ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${jira_variable}=" "$env_file"; then
        printf "%s=%q\n" "$jira_variable" "$value" >> "$env_file"
        echo "  Captured $jira_variable for unattended Manul processes" >&2
      fi
    done < <(
      jq -r '
        .taskSources[]?
        | select((.enabled != false))
        | select(.type == "jira_tasks")
        | (.userEnv // "MANUL_JIRA_USER"), (.passwordEnv // "MANUL_JIRA_PASSWORD")
      ' "$runtime_dir/config.json" 2>/dev/null | sort -u
    )
  fi

  # MCP source tokens are captured only when their environment-variable names
  # are explicitly configured by an enabled Todo source. Values are never
  # copied to logs or repository configuration.
  local mcp_token_variable
  if [ -f "$runtime_dir/config.json" ]; then
    while IFS= read -r mcp_token_variable; do
      [ -n "$mcp_token_variable" ] || continue
      if [[ ! "$mcp_token_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  Ignoring invalid Todo MCP token environment variable name" >&2
        continue
      fi
      value="${!mcp_token_variable:-}"
      if [ -n "$value" ] && ! grep -qE "^[[:space:]]*(export[[:space:]]+)?${mcp_token_variable}=" "$env_file"; then
        printf "%s=%q\n" "$mcp_token_variable" "$value" >> "$env_file"
        echo "  Captured ${mcp_token_variable} for unattended Manul Todo MCP access" >&2
      fi
    done < <(
      jq -r '
        .taskSources[]?
        | select((.enabled != false))
        | if .type == "todo_remote_mcp" then (.tokenEnv // "FITEO_MANUL_PAT")
          else empty
          end
      ' "$runtime_dir/config.json" 2>/dev/null | sort -u
    )
  fi

  # Persist the remote Todo identity variable configured by manulUserIdEnv.
  # The poller may run under cron/systemd without inheriting the interactive shell.
  local remote_manul_user_id_variable
  if [ -f "$runtime_dir/config.json" ]; then
    while IFS= read -r remote_manul_user_id_variable; do
      [ -n "$remote_manul_user_id_variable" ] || continue
      if [[ ! "$remote_manul_user_id_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "  Ignoring invalid Fiteo Manul user ID environment variable name" >&2
        continue
      fi
      value="${!remote_manul_user_id_variable:-}"
      [ -n "$value" ] || continue
      if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "  Ignoring non-numeric value for configured Fiteo Manul user ID variable" >&2
        continue
      fi

      refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
      if ! awk -v variable="$remote_manul_user_id_variable" '
        $0 !~ ("^[[:space:]]*(export[[:space:]]+)?" variable "=")
      ' "$env_file" > "$refreshed_file"; then
        rm -f -- "$refreshed_file"
        return 1
      fi
      printf '%s=%q\n' "$remote_manul_user_id_variable" "$value" >> "$refreshed_file"
      chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
      mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
      echo "  Refreshed configured Fiteo Manul user ID for unattended processes" >&2
    done < <(
      jq -r '
        .taskSources[]?
        | select((.enabled != false) and .type == "todo_remote_mcp")
        | .manulUserIdEnv // empty
      ' "$runtime_dir/config.json" 2>/dev/null
    )
  fi

  # Persist the configured non-secret recipient for Manul-created remote Todo tasks.
  # This is independent from the endpoint/PAT pair: remote task discovery may
  # use a task-scoped MCP URL while the bootstrap environment supplies the ID.
  if [[ "${FITEO_MANUL_SHARE_USER_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '$0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_MANUL_SHARE_USER_ID=/' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    printf 'FITEO_MANUL_SHARE_USER_ID=%q\n' "$FITEO_MANUL_SHARE_USER_ID" >> "$refreshed_file"
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
    echo "  Refreshed Fiteo share-recipient ID for unattended Manul tasks" >&2
  fi

  chmod 600 "$env_file" || return 1

  if ! bash -n "$env_file" >/dev/null 2>&1; then
    echo "ERROR: invalid shell syntax in generated Manul environment file: $env_file" >&2
    return 1
  fi

  printf '%s' "$env_file"
}

if [ "${1:-}" = "--bootstrap" ]; then
  [ "${2:-}" != "" ] || {
    echo "Usage: $0 --bootstrap <runtime-dir>" >&2
    exit 2
  }
  manul_env_bootstrap "$2"
elif [ "${1:-}" = "--load" ]; then
  [ "${2:-}" != "" ] || {
    echo "Usage: $0 --load <runtime-dir>" >&2
    exit 2
  }
  manul_env_load "$2"
fi
