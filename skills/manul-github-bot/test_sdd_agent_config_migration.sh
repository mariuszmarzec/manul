#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
MIGRATOR="$SCRIPT_DIR/migrate-sdd-agent-config.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected=$expected actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

CONFIG="$TEST_DIR/config.json"
cat > "$CONFIG" <<'JSON'
{
  "agents": ["coder", "architect", "sdd"],
  "automation": {"agentRuntime": "opencode"},
  "repositories": ["owner/repo"]
}
JSON
chmod 640 "$CONFIG"
bash "$MIGRATOR" "$CONFIG" > "$TEST_DIR/migrate.log"
assert_eq "existing configured roles are preserved" '["coder","architect","sdd","orchestrator"]' "$(jq -c '.agents' "$CONFIG")"
assert_eq "unrelated config is preserved" "opencode" "$(jq -r '.automation.agentRuntime' "$CONFIG")"
assert_eq "file mode is preserved" "640" "$(stat -c '%a' "$CONFIG")"
assert_eq "recoverable backup exists" "1" "$(find "$TEST_DIR" -maxdepth 1 -name 'config.json.bak.sdd-agents.*' | wc -l | tr -d ' ')"

BEFORE="$(cat "$CONFIG")"
BACKUPS_BEFORE="$(find "$TEST_DIR" -maxdepth 1 -name 'config.json.bak.sdd-agents.*' | wc -l | tr -d ' ')"
bash "$MIGRATOR" "$CONFIG" > "$TEST_DIR/idempotent.log"
assert_eq "migration is idempotent" "$BEFORE" "$(cat "$CONFIG")"
assert_eq "idempotent run creates no backup" "$BACKUPS_BEFORE" "$(find "$TEST_DIR" -maxdepth 1 -name 'config.json.bak.sdd-agents.*' | wc -l | tr -d ' ')"

MISSING="$TEST_DIR/missing-agents.json"
printf '{"automation":{"agentRuntime":"opencode"}}\n' > "$MISSING"
bash "$MIGRATOR" "$MISSING" >/dev/null
assert_eq "missing agents array receives default role set" "sdd" "$(jq -r '.agents | index("sdd") | if . == null then "missing" else "sdd" end' "$MISSING")"
assert_eq "missing agents array receives orchestrator role" "orchestrator" "$(jq -r '.agents | index("orchestrator") | if . == null then "missing" else "orchestrator" end' "$MISSING")"

INVALID="$TEST_DIR/invalid-agents.json"
printf '{"agents":"coder"}\n' > "$INVALID"
ORIGINAL="$(cat "$INVALID")"
RC=0
bash "$MIGRATOR" "$INVALID" >/dev/null 2>&1 || RC=$?
assert_eq "non-array agents config is rejected" "1" "$RC"
assert_eq "rejected config remains unchanged" "$ORIGINAL" "$(cat "$INVALID")"

echo "SDD agent config migration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
