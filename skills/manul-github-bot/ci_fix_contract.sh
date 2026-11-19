#!/usr/bin/env bash
# Fixture-backed contract tests for automatic CI-fix cooldown behavior.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
DB="$TEST_DIR/manul.db"
LOG="$TEST_DIR/poll.log"
MOCK_BIN="$TEST_DIR/bin"
export DB LOG
mkdir -p "$MOCK_BIN"

log() { printf '%s\n' "$*" >>"$LOG"; }
sql_num() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && printf '%s' "$1"
}
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

cat >"$MOCK_BIN/date" <<'DATE'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  printf '%s\n' "$CI_FIX_TEST_NOW"
else
  exec /bin/date "$@"
fi
DATE
chmod +x "$MOCK_BIN/date"
export PATH="$MOCK_BIN:$PATH"

sqlite3 "$DB" "
CREATE TABLE processed_comments (
  commentId TEXT PRIMARY KEY,
  repository TEXT,
  issueNumber INTEGER,
  createdAt TEXT
);
"

CI_FIX_COOLDOWN_MINUTES=60
CI_FIX_WAIT_BEFORE_FIRST_MINUTES=30
export CI_FIX_COOLDOWN_MINUTES CI_FIX_WAIT_BEFORE_FIRST_MINUTES

CI_FIX_TEST_NOW=1800000000
export CI_FIX_TEST_NOW
to_iso() { /bin/date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# Existing task history must be migrated to the new per-repository attempt table.
legacy_at="$(to_iso "$((CI_FIX_TEST_NOW - 59 * 60))")"
sqlite3 "$DB" "INSERT INTO processed_comments(commentId, repository, issueNumber, createdAt)
VALUES('ci_fix:test/repo:8:legacy-run', 'test/repo', 8, '$legacy_at');"

# Load the production CI-fix helpers from poll.sh, without starting the poller.
source <(sed -n '/^# === ci fix helpers ===$/,/^# === end ci fix helpers ===$/p' "$SCRIPT_DIR/poll.sh")

fail_29="$(to_iso "$((CI_FIX_TEST_NOW - 29 * 60))")"
activity_45="$(to_iso "$((CI_FIX_TEST_NOW - 45 * 60))")"
if check_ci_fix_eligible "test/repo" "42" "first-run" "$fail_29" "$activity_45"; then
  echo "FAIL: first attempt ran before 30 minutes had elapsed from CI failure" >&2
  exit 1
fi

fail_45="$(to_iso "$((CI_FIX_TEST_NOW - 45 * 60))")"
activity_5="$(to_iso "$((CI_FIX_TEST_NOW - 5 * 60))")"
if check_ci_fix_eligible "test/repo" "42" "first-run-activity" "$fail_45" "$activity_5"; then
  echo "FAIL: recent PR activity did not restart the first-attempt wait" >&2
  exit 1
fi

fail_31="$(to_iso "$((CI_FIX_TEST_NOW - 31 * 60))")"
activity_32="$(to_iso "$((CI_FIX_TEST_NOW - 32 * 60))")"
check_ci_fix_eligible "test/repo" "42" "first-run-ready" "$fail_31" "$activity_32" || {
  echo "FAIL: first attempt remained blocked after both timers elapsed" >&2
  exit 1
}

mark_ci_fix_attempted "test/repo" "42" "first-run-ready"
if check_ci_fix_eligible "test/repo" "42" "first-run-ready" "$fail_31" "$activity_32"; then
  echo "FAIL: the same CI run was allowed twice" >&2
  exit 1
fi

CI_FIX_TEST_NOW=$((CI_FIX_TEST_NOW + 59 * 60))
export CI_FIX_TEST_NOW
fail_old="$(to_iso "$((CI_FIX_TEST_NOW - 180 * 60))")"
activity_old="$(to_iso "$((CI_FIX_TEST_NOW - 180 * 60))")"
if check_ci_fix_eligible "test/repo" "42" "second-run-too-soon" "$fail_old" "$activity_old"; then
  echo "FAIL: cooldownMinutes did not block a retry before 60 minutes" >&2
  exit 1
fi

CI_FIX_TEST_NOW=$((CI_FIX_TEST_NOW + 2 * 60))
export CI_FIX_TEST_NOW
check_ci_fix_eligible "test/repo" "42" "second-run-ready" "$fail_old" "$activity_old" || {
  echo "FAIL: retry remained blocked after cooldownMinutes elapsed" >&2
  exit 1
}

# A same-numbered PR in another repository must not inherit this PR's cooldown.
check_ci_fix_eligible "another/repo" "42" "independent-repo" "$fail_old" "$activity_old" || {
  echo "FAIL: per-PR cooldown leaked across repositories" >&2
  exit 1
}

# Legacy tasks are migrated and continue to observe the 60-minute cooldown.
if check_ci_fix_eligible "test/repo" "8" "legacy-retry-too-soon" "$fail_old" "$activity_old"; then
  echo "FAIL: an existing PR was incorrectly treated as a first attempt after upgrade" >&2
  exit 1
fi
CI_FIX_TEST_NOW=$((CI_FIX_TEST_NOW + 2 * 60))
export CI_FIX_TEST_NOW
check_ci_fix_eligible "test/repo" "8" "legacy-retry-ready" "$fail_old" "$activity_old" || {
  echo "FAIL: migrated PR cooldown did not expire" >&2
  exit 1
}

echo "All CI-fix cooldown contract tests passed."
