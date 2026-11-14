#!/usr/bin/env bash
# Add SDD entrypoint roles to existing Manul configs without removing operator roles.
set -euo pipefail

CONFIG_FILE="$1"
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "Usage: migrate-sdd-agent-config.sh /path/to/config.json" >&2
  exit 2
fi
if ! jq -e 'type == "object" and ((has("agents") | not) or (.agents | type == "array"))' "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "ERROR: config root must be an object and agents, when present, must be an array; refusing to modify it" >&2
  exit 1
fi

DEFAULT_AGENTS='["orchestrator","sdd","architect","coder","coder-cheap","coder-strong","coder-expert","reviewer","reviewer-expert","reviewer-adversarial","debugger","debugger-expert","researcher","tester","security","performance","refactorer"]'
UPDATED="$(jq -c --argjson defaults "$DEFAULT_AGENTS" '
  if ((.agents // []) | length) == 0 then
    .agents = $defaults
  else
    reduce ["orchestrator","sdd"][] as $role (.;
      if (.agents | index($role)) == null then .agents += [$role] else . end)
  end
' "$CONFIG_FILE")" || {
  echo "ERROR: could not prepare SDD role migration" >&2
  exit 1
}

CURRENT="$(jq -cS . "$CONFIG_FILE")"
NEXT="$(printf '%s' "$UPDATED" | jq -cS .)"
if [ "$CURRENT" = "$NEXT" ]; then
  echo "SDD roles already enabled in $CONFIG_FILE"
  exit 0
fi

DIR="$(dirname "$CONFIG_FILE")"
BASE="$(basename "$CONFIG_FILE")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$CONFIG_FILE.bak.sdd-agents.$STAMP"
if [ -e "$BACKUP" ]; then
  echo "ERROR: refusing to overwrite existing migration backup $BACKUP" >&2
  exit 1
fi
TMP="$(mktemp "$DIR/.$BASE.sdd.XXXXXX")"
cleanup() { rm -f -- "$TMP"; }
trap cleanup EXIT

cp -p -- "$CONFIG_FILE" "$BACKUP" || {
  echo "ERROR: could not create recoverable config backup" >&2
  exit 1
}
printf '%s\n' "$UPDATED" | jq . > "$TMP" || {
  echo "ERROR: could not write migrated config" >&2
  exit 1
}
chmod --reference="$CONFIG_FILE" "$TMP" || {
  echo "ERROR: could not preserve config permissions" >&2
  exit 1
}
mv -f -- "$TMP" "$CONFIG_FILE" || {
  echo "ERROR: could not install migrated config" >&2
  exit 1
}
echo "Enabled Manul SDD entrypoint roles (orchestrator, sdd) in $CONFIG_FILE"
echo "Original config backup: $BACKUP"
