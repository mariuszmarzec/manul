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
# credentials. It never copies active shell variables into a second file.

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
# directly from the operator's ~/.zshrc. This file is only for Manul-specific
# values intentionally managed here. Existing entries are preserved.
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
