#!/usr/bin/env bash
# Collapse legacy repository lists into the canonical top-level .repositories.

set -euo pipefail

CONFIG_FILE="${1:-${MANUL_CONFIG:-${MANUL_DIR:-$HOME/.manul}/config.json}}"
fail() { echo "ERROR: repository config migration: $*" >&2; exit 1; }

[ -f "$CONFIG_FILE" ] || fail "config file does not exist: $CONFIG_FILE"
[ ! -L "$CONFIG_FILE" ] || fail "refusing to replace a symlinked config file: $CONFIG_FILE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Never guess which legacy list should win and never merge lists: this preserves
# the operator's explicit global access boundary without silently widening it.
if ! jq -e '
  type == "object"
  and has("repositories")
  and (.repositories | type == "array")
  and all(.repositories[]; type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
' "$CONFIG_FILE" >/dev/null 2>&1; then
  fail "top-level .repositories must exist and contain only owner/repo strings; no legacy lists were merged"
fi

if ! jq -e '
  has("repositoryAllowlist")
  or any(.taskSources[]?; type == "object" and
    (has("repositories") or has("repositoryAllowlist") or has("repositoryAllowlistEnforced")))
' "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "Repository config already uses the canonical top-level .repositories list."
  exit 0
fi

CONFIG_DIR="$(dirname "$CONFIG_FILE")"
BACKUP_FILE="${CONFIG_FILE}.bak.repository-list.$(date -u +%Y%m%dT%H%M%SZ).$$"
TMP_FILE=""
cleanup() { [ -z "$TMP_FILE" ] || rm -f -- "$TMP_FILE"; }
trap cleanup EXIT

cp -p -- "$CONFIG_FILE" "$BACKUP_FILE" || fail "could not create recoverable backup: $BACKUP_FILE"
TMP_FILE="$(mktemp "$CONFIG_DIR/.config.json.repository-migration.XXXXXX")" || fail "could not create temporary config in $CONFIG_DIR"

if ! jq '
  del(.repositoryAllowlist)
  | if (.taskSources | type) == "array" then
      .taskSources |= map(
        if type == "object"
        then del(.repositories, .repositoryAllowlist, .repositoryAllowlistEnforced)
        else .
        end
      )
    else .
    end
' "$CONFIG_FILE" > "$TMP_FILE"; then
  fail "could not produce migrated configuration; original file is unchanged"
fi

chmod --reference="$CONFIG_FILE" "$TMP_FILE" || fail "could not preserve config file permissions"
mv -f -- "$TMP_FILE" "$CONFIG_FILE" || fail "could not atomically install migrated config; original backup: $BACKUP_FILE"
TMP_FILE=""

echo "Migrated repository configuration to the single top-level .repositories list."
echo "Preserved top-level .repositories and all unrelated settings."
echo "Backup: $BACKUP_FILE"
