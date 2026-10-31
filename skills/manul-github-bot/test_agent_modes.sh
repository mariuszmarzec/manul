#!/usr/bin/env bash
# Ensure canonical specialist agents are directly invokable and delegatable.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agents_dir="$ROOT_DIR/agents"
failed=0
for agent in "$agents_dir"/*.md; do
  name="$(basename "$agent")"
  mode="$(sed -n 's/^mode: *//p' "$agent" | head -n 1)"
  if [ "$name" = "orchestrator.md" ]; then
    if [ "$mode" != "primary" ]; then
      echo "FAIL: orchestrator.md must remain primary (got $mode)"
      failed=1
    else
      echo "PASS: orchestrator remains primary"
    fi
  elif [ "$mode" != "all" ]; then
    echo "FAIL: $name must use mode: all for direct CLI and subagent use (got $mode)"
    failed=1
  else
    echo "PASS: $name uses mode: all"
  fi
done
exit "$failed"
