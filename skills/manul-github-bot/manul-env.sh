#!/usr/bin/env bash
# manul-env.sh — Load and bootstrap Manul operator environment.
#
# Runtime environment is initialized from the operator's existing ~/.zshrc
# before the daemon/watchdog starts. This file is reserved for Manul-specific
# integration credentials and legacy fallbacks; exported values already
# supplied by Zsh always take precedence. PATH is never loaded from this file.
#
# Runtime-owned integration environment file:
#   ~/.manul/.env
#
# Bootstrap creates/validates this private fallback file and removes retired
# credentials. It persists only the allowlisted Manul-owned Fiteo integration
# values; the operator's own FITEO_PAT and host/provider credentials are never
# copied into this file.

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
  # Treat ~/.zshrc as the source of truth for exported operator settings.
  # The Manul file supplies only values absent from the inherited environment;
  # it can never replace PATH, even if an older version wrote one here.
  # shellcheck disable=SC1090
  . <(awk '
    BEGIN {
      for (name in ENVIRON) inherited[name] = 1
      # These are host/provider-owned settings. They must come from the
      # operator shell, never from a legacy Manul fallback file.
      split("OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH OPENCLAW_HOME OPENCLAW_GATEWAY_PORT OPENCLAW_BIN OPENCODE_BIN OPENCODE_API_KEY OPENCODE_CONSOLE_TOKEN CODEX_HOME CODEX_BIN CODEX_MODEL CLAUDE_CONFIG_DIR CLAUDE_BIN CLAUDE_MODEL OPENAI_API_KEY OPENAI_API_BASE OPENAI_BASE_URL ANTHROPIC_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY MISTRAL_API_KEY LITELLM_API_KEY LITELLM_MASTER_KEY LITELLM_API_BASE FREELLMAPI_API_KEY FREELLMAPI_BASE_URL OLLAMA_API_KEY OLLAMA_HOST", names, " ")
      for (i in names) shell_owned[names[i]] = 1
    }
    {
      candidate = $0
      sub(/^[[:space:]]*/, "", candidate)
      sub(/^export[[:space:]]+/, "", candidate)
      name = ""
      if (match(candidate, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        name = substr(candidate, 1, index(candidate, "=") - 1)
      }
      if (name == "PATH" || (name != "" && name in shell_owned) ||
          (name != "" && name in inherited)) next
      if ($0 ~ /^[[:space:]]*(export[[:space:]]+)?TODO_LOCAL_MCP_TOKEN=/) next
      if ($0 ~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_MCP_URL=/) next
      if ($0 ~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_ACCESS_TOKEN=/) next
      print
    }
  ' "$env_file")
  set +a
}

manul_env_persist_integration_values() {
  local runtime_dir="${1:?runtime directory required}"
  local env_file="${2:?environment file required}"
  local values_file refreshed_file refresh_names=""
  local var_name var_value

  values_file="$(mktemp "$runtime_dir/.env-values.XXXXXX")" || return 1
  for var_name in FITEO_BASE_URL FITEO_MANUL_PAT MANUL_USER_ID FITEO_MANUL_SHARE_USER_ID; do
    # The operator's initialized Zsh is the source of truth for exported
    # values. Do not copy those values into ~/.manul/.env: keep an existing
    # Manul-owned fallback intact and let the live shell value take precedence
    # through manul_env_load. Non-exported Manul values may still be persisted.
    if declare -xp "$var_name" >/dev/null 2>&1; then
      continue
    fi
    case "$var_name" in
      FITEO_BASE_URL) var_value="${FITEO_BASE_URL:-}" ;;
      FITEO_MANUL_PAT) var_value="${FITEO_MANUL_PAT:-}" ;;
      MANUL_USER_ID) var_value="${MANUL_USER_ID:-}" ;;
      FITEO_MANUL_SHARE_USER_ID) var_value="${FITEO_MANUL_SHARE_USER_ID:-}" ;;
    esac
    [ -n "$var_value" ] || continue

    # Persist only values valid for the remote Fiteo integration. Never write
    # multiline values into a shell environment file.
    case "$var_name" in
      FITEO_BASE_URL)
        [[ "$var_value" =~ ^https?://[^[:space:][:cntrl:]]+$ ]] || continue
        ;;
      MANUL_USER_ID|FITEO_MANUL_SHARE_USER_ID)
        [[ "$var_value" =~ ^[1-9][0-9]*$ ]] || continue
        ;;
    esac
    if [[ "$var_value" == *$'\n'* || "$var_value" == *$'\r'* ]]; then
      continue
    fi

    printf '%s=%q\n' "$var_name" "$var_value" >> "$values_file" || {
      rm -f -- "$values_file"
      return 1
    }
    refresh_names="${refresh_names:+$refresh_names }$var_name"
  done

  if [ ! -s "$values_file" ]; then
    rm -f -- "$values_file"
    return 0
  fi

  refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || {
    rm -f -- "$values_file"
    return 1
  }
  if ! awk -v refresh_names="$refresh_names" '
    BEGIN {
      count = split(refresh_names, names, " ")
    }
    {
      candidate = $0
      sub(/^[[:space:]]*/, "", candidate)
      sub(/^export[[:space:]]+/, "", candidate)
      for (i = 1; i <= count; i++) {
        prefix = names[i] "="
        if (index(candidate, prefix) == 1) next
      }
      print
    }
  ' "$env_file" > "$refreshed_file"; then
    rm -f -- "$values_file" "$refreshed_file"
    return 1
  fi
  if ! cat "$values_file" >> "$refreshed_file"; then
    rm -f -- "$values_file" "$refreshed_file"
    return 1
  fi
  rm -f -- "$values_file"
  chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
  mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
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
# Manul integration environment.
#
# Operator PATH, provider configuration, API keys and tool settings come
# directly from the operator's ~/.zshrc. This file stores only Manul-owned
# integration fallbacks such as the dedicated Fiteo URL, PAT and share IDs.
EOF
    then
      return 1
    fi
  fi

  # Remove retired operator/local credentials and obsolete host/provider
  # config/API-key entries. Preserve Manul-specific integration fallbacks.
  local refreshed_file
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?(FITEO_PAT|TODO_LOCAL_MCP_TOKEN|CARACAL_MCP_URL|CARACAL_ACCESS_TOKEN|OPENCLAW_STATE_DIR|OPENCLAW_CONFIG_PATH|OPENCLAW_HOME|OPENCLAW_GATEWAY_PORT|OPENCLAW_BIN|OPENCODE_BIN|OPENCODE_API_KEY|OPENCODE_CONSOLE_TOKEN|CODEX_HOME|CODEX_BIN|CODEX_MODEL|CLAUDE_CONFIG_DIR|CLAUDE_BIN|CLAUDE_MODEL|OPENAI_API_KEY|OPENAI_API_BASE|OPENAI_BASE_URL|ANTHROPIC_API_KEY|OPENROUTER_API_KEY|GOOGLE_API_KEY|MISTRAL_API_KEY|LITELLM_API_KEY|LITELLM_MASTER_KEY|LITELLM_API_BASE|FREELLMAPI_API_KEY|FREELLMAPI_BASE_URL|OLLAMA_API_KEY|OLLAMA_HOST)=' "$env_file"; then
    refreshed_file="$(mktemp "$runtime_dir/.env.XXXXXX")" || return 1
    if ! awk '
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?FITEO_PAT=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?TODO_LOCAL_MCP_TOKEN=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_MCP_URL=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?CARACAL_ACCESS_TOKEN=/ &&
      $0 !~ /^[[:space:]]*(export[[:space:]]+)?(OPENCLAW_STATE_DIR|OPENCLAW_CONFIG_PATH|OPENCLAW_HOME|OPENCLAW_GATEWAY_PORT|OPENCLAW_BIN|OPENCODE_BIN|OPENCODE_API_KEY|OPENCODE_CONSOLE_TOKEN|CODEX_HOME|CODEX_BIN|CODEX_MODEL|CLAUDE_CONFIG_DIR|CLAUDE_BIN|CLAUDE_MODEL|OPENAI_API_KEY|OPENAI_API_BASE|OPENAI_BASE_URL|ANTHROPIC_API_KEY|OPENROUTER_API_KEY|GOOGLE_API_KEY|MISTRAL_API_KEY|LITELLM_API_KEY|LITELLM_MASTER_KEY|LITELLM_API_BASE|FREELLMAPI_API_KEY|FREELLMAPI_BASE_URL|OLLAMA_API_KEY|OLLAMA_HOST)=/
    ' "$env_file" > "$refreshed_file"; then
      rm -f -- "$refreshed_file"
      return 1
    fi
    chmod 600 "$refreshed_file" || { rm -f -- "$refreshed_file"; return 1; }
    mv -- "$refreshed_file" "$env_file" || { rm -f -- "$refreshed_file"; return 1; }
  fi

  # Persist only the allowlisted Manul-owned Fiteo values needed by unattended
  # poller/watchdog tasks. A pre-existing PAT remains when it is not in this
  # shell; the operator's FITEO_PAT is removed above and never copied.
  manul_env_persist_integration_values "$runtime_dir" "$env_file" || {
    echo "ERROR: could not persist Manul-owned integration values." >&2
    return 1
  }

  chmod 600 "$env_file" || return 1
  if ! bash -n "$env_file" >/dev/null 2>&1; then
    echo "ERROR: invalid shell syntax in Manul environment file: $env_file" >&2
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
