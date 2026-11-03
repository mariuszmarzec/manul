#!/usr/bin/env bash
# V2-native, additive OpenCode permissions for Manul.
# V2 allows external_directory by default, so preserve explicit operator rules
# and add an ask-by-default boundary unless the operator explicitly set one.
# A global deny protects all Manul workspaces; each task overlay allows only
# its currently assigned workspace.
#
# grep permission resources are query strings, not paths, and V2 has no
# path-scoped list action. Keep those actions at their normal policy instead
# of creating misleading broad grants.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/manul-paths.sh"
MANUL_WORKSPACE_CANONICAL="$(realpath -m -- "$MANUL_WORKSPACE")"
[ "$MANUL_WORKSPACE_CANONICAL" != "/" ] || { echo "ERROR: MANUL_WORKSPACE must not resolve to /" >&2; exit 1; }
MANUL_WORKSPACE_RULE="${MANUL_WORKSPACE_CANONICAL%/}/*"
DEFAULT_WORKSPACE_RULE="$HOME/.manul/workspace/*"

resolve_opencode_bin() {
  if [ -n "${OPENCODE_BIN:-}" ] && [ -x "$OPENCODE_BIN" ]; then printf '%s' "$OPENCODE_BIN"; return 0; fi
  local found=""
  found="$(command -v opencode 2>/dev/null || true)"
  if [ -n "$found" ] && [ -x "$found" ]; then printf '%s' "$found"; return 0; fi
  if [ -x "$HOME/.opencode/bin/opencode" ]; then printf '%s' "$HOME/.opencode/bin/opencode"; return 0; fi
  return 1
}
OPENCODE_BIN_RESOLVED="$(resolve_opencode_bin || true)"
[ -n "$OPENCODE_BIN_RESOLVED" ] || exit 0
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
[ -f "$OPENCODE_CONFIG" ] || exit 0
CONFIG_DIR="$(dirname "$OPENCODE_CONFIG")"
jq empty "$OPENCODE_CONFIG" >/dev/null 2>&1 || { echo "ERROR: invalid OpenCode configuration: $OPENCODE_CONFIG" >&2; exit 1; }
TMP_FILE="$(mktemp "$CONFIG_DIR/.opencode.manul.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

jq --arg workspace "$MANUL_WORKSPACE_CANONICAL" --arg workspaceRule "$MANUL_WORKSPACE_RULE" --arg defaultWorkspaceRule "$DEFAULT_WORKSPACE_RULE" '
  def merge_rules($rules):
    reduce $rules[] as $rule ([]; map(select(.action != $rule.action or .resource != $rule.resource)) + [$rule]);
  def home_path:
    if startswith("~/") then env.HOME + .[1:]
    elif startswith("$HOME/") then env.HOME + .[5:]
    else .
    end;
  . as $root
  | (($root.permissions // []) | if type == "array" then . else [] end) as $native
  | ($root.permission.external_directory // {}) as $legacyRaw
  | (if ($legacyRaw|type)=="object" then [$legacyRaw|to_entries[]|{action:"external_directory",resource:.key,effect:.value}]
     elif ($legacyRaw|type)=="string" then [{action:"external_directory",resource:"*",effect:$legacyRaw}]
     else [] end) as $legacy
  | merge_rules($legacy + [$native[]|select(.action=="external_directory")]) as $allExternal
  | ($allExternal | map(select((.resource|home_path) as $p | $p != $workspace and (($p|startswith($workspace + "/"))|not)))) as $external
  | ([$native[]|select(.action!="external_directory")]) as $other
  | (if any($external[];.resource=="*") then [] else [{action:"external_directory",resource:"*",effect:"ask"}] end) as $default
  | .permissions = merge_rules($other + $default + $external + [
      {action:"external_directory",resource:"/tmp/*",effect:"allow"},
      {action:"external_directory",resource:"/tmp/manul-diagnostics/*",effect:"allow"},
      {action:"read",resource:"/tmp/manul-diagnostics/*",effect:"allow"},
      {action:"edit",resource:"/tmp/manul-diagnostics/*",effect:"allow"},
      {action:"external_directory",resource:"~/.manul/logs/*",effect:"allow"},
      {action:"read",resource:"~/.manul/logs/*",effect:"allow"},
      {action:"glob",resource:"~/.manul/logs/*",effect:"allow"},
      {action:"edit",resource:"~/.manul/logs/*",effect:"deny"},
      {action:"external_directory",resource:"~/.gradle/caches/modules-2/files-2.1/*",effect:"allow"},
      {action:"external_directory",resource:$defaultWorkspaceRule,effect:"deny"},
      {action:"external_directory",resource:$workspaceRule,effect:"deny"}
    ])
' "$OPENCODE_CONFIG" >"$TMP_FILE"
MODE="$(stat -c '%a' "$OPENCODE_CONFIG" 2>/dev/null || true)"
[ -n "$MODE" ] && chmod "$MODE" "$TMP_FILE" 2>/dev/null || true
jq empty "$TMP_FILE" >/dev/null 2>&1 || { echo "ERROR: generated V2 permissions are invalid" >&2; exit 1; }
if ! cmp -s "$OPENCODE_CONFIG" "$TMP_FILE"; then mv -f "$TMP_FILE" "$OPENCODE_CONFIG"; fi

configured_has() {
  local action="$1" resource="$2" effect="$3" expanded="$resource"
  case "$expanded" in "~/"*) expanded="$HOME/${expanded#~/}" ;; "\$HOME/"*) expanded="$HOME/${expanded#\$HOME/}" ;; esac
  jq -e --arg a "$action" --arg r "$resource" --arg x "$expanded" --arg e "$effect" '
      any(.permissions[]?; .action==$a and (.resource==$r or .resource==$x) and .effect==$e)
    ' "$OPENCODE_CONFIG" >/dev/null 2>&1
}

# OpenCode V2's `debug config` lists the config sources but no longer prints the
# resolved config object. Verify that it loaded this exact file, then validate
# the native rules directly in that file rather than querying the old V1 shape.
if ! "$OPENCODE_BIN_RESOLVED" debug config 2>/dev/null |
  jq -e --arg config "$OPENCODE_CONFIG" '
    type == "array" and any(.[]?; .type == "document" and .path == $config)
  ' >/dev/null 2>&1; then
  echo "ERROR: OpenCode V2 did not load the expected config source: $OPENCODE_CONFIG" >&2
  exit 1
fi

for rule in \
  "external_directory|/tmp/*|allow" \
  "external_directory|/tmp/manul-diagnostics/*|allow" \
  "read|/tmp/manul-diagnostics/*|allow" \
  "edit|/tmp/manul-diagnostics/*|allow" \
  "external_directory|~/.manul/logs/*|allow" \
  "read|~/.manul/logs/*|allow" \
  "glob|~/.manul/logs/*|allow" \
  "edit|~/.manul/logs/*|deny" \
  "external_directory|~/.gradle/caches/modules-2/files-2.1/*|allow" \
  "external_directory|$DEFAULT_WORKSPACE_RULE|deny" \
  "external_directory|$MANUL_WORKSPACE_RULE|deny"; do
  IFS='|' read -r action resource effect <<<"$rule"
  configured_has "$action" "$resource" "$effect" || { echo "ERROR: configured V2 rule missing: $action $resource => $effect" >&2; exit 1; }
done
jq -e '
  any(.permissions[]?; .action=="external_directory" and .resource=="*" and (.effect=="ask" or .effect=="allow" or .effect=="deny"))
' "$OPENCODE_CONFIG" >/dev/null 2>&1 || { echo "ERROR: configured V2 file lacks an external-directory default rule" >&2; exit 1; }
echo "OpenCode V2 permissions verified (task workspace remains denied globally)."
