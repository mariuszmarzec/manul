#!/usr/bin/env bash
# Shared endpoint discovery for Todo Desktop's loopback-only MCP server.
#
# Native Linux/macOS (and native Windows shells) use Todo's direct loopback
# endpoint. WSL first tries direct loopback (for mirrored/forwarded networking)
# and uses the WSL relay only when the direct endpoint is not reachable.

todo_local_mcp_is_wsl() {
  case "$(printenv TODO_LOCAL_MCP_PLATFORM_OVERRIDE 2>/dev/null || true)" in
    wsl) return 0 ;;
    native) return 1 ;;
  esac

  if [ -n "$(printenv WSL_INTEROP 2>/dev/null || true)" ] ||
     [ -n "$(printenv WSL_DISTRO_NAME 2>/dev/null || true)" ]; then
    return 0
  fi

  if [ -r /proc/sys/kernel/osrelease ] &&
     grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease; then
    return 0
  fi
  if [ -r /proc/version ] && grep -Eqi '(microsoft|wsl)' /proc/version; then
    return 0
  fi
  return 1
}

todo_local_mcp_url_is_supported() {
  python3 - "$1" <<'PY_TODO_LOCAL_URL'
import ipaddress
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    host = parsed.hostname
    port = parsed.port
except ValueError:
    raise SystemExit(1)

if (
    parsed.scheme != "http"
    or host is None
    or parsed.path != "/mcp"
    or parsed.query
    or parsed.fragment
    or parsed.username is not None
    or parsed.password is not None
):
    raise SystemExit(1)

if host.casefold() == "localhost":
    raise SystemExit(0)

try:
    address = ipaddress.ip_address(host)
except ValueError:
    raise SystemExit(1)

if not address.is_loopback:
    raise SystemExit(1)
PY_TODO_LOCAL_URL
}

todo_local_mcp_probe_status() {
  local url="$1"
  if ! command -v curl >/dev/null 2>&1; then
    printf '000'
    return 0
  fi
  local status
  status="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 4 "$url" 2>/dev/null || true)"
  printf '%s' "${status:-000}"
}

# Print a usable endpoint only after the unauthenticated probe receives HTTP
# 401. The configured URL is retained for custom loopback ports; the standard
# native endpoint is always preferred over the legacy WSL relay.
todo_local_mcp_resolve_url() {
  local preferred="$1"
  local direct_url="http://127.0.0.1:8765/mcp"
  local bridge_url="http://127.0.0.1:8766/mcp"
  local status

  if [ -n "$preferred" ]; then
    if ! todo_local_mcp_url_is_supported "$preferred"; then
      echo "Todo local MCP URL must use HTTP loopback and the /mcp path." >&2
      return 2
    fi
    case "$preferred" in
      "$direct_url"|"$bridge_url") ;;
      *)
        status="$(todo_local_mcp_probe_status "$preferred")"
        if [ "$status" = "401" ]; then
          printf '%s' "$preferred"
          return 0
        fi
        ;;
    esac
  fi

  status="$(todo_local_mcp_probe_status "$direct_url")"
  if [ "$status" = "401" ]; then
    printf '%s' "$direct_url"
    return 0
  fi

  if todo_local_mcp_is_wsl; then
    status="$(todo_local_mcp_probe_status "$bridge_url")"
    if [ "$status" = "401" ]; then
      printf '%s' "$bridge_url"
      return 0
    fi
  elif [ "$preferred" = "$bridge_url" ]; then
    # Backward compatibility for a native host with an explicitly configured
    # legacy relay. Never probe 8766 on native hosts unless it was requested.
    status="$(todo_local_mcp_probe_status "$bridge_url")"
    if [ "$status" = "401" ]; then
      printf '%s' "$bridge_url"
      return 0
    fi
  fi

  return 1
}
