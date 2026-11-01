#!/usr/bin/env bash
# agent-session-state.sh — claim-scoped persistence for runtime continuation.
#
# Runtime session IDs are only valid for a follow-up when the adapter explicitly
# reports NEEDS_CONTINUATION with a non-empty session ID. Any other result clears
# the previous pointer, so generic failures restart from a fresh runtime session.
# The workspace/context mapping is deliberately untouched: the next attempt can
# reuse the same isolated workspace without reusing stale LLM conversation state.

manul_session_sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

manul_record_execution_session_state() {
    local db="$1"
    local task_id="$2"
    local claim_token="$3"
    local status="$4"
    local session_id="${5:-}"

    [ -n "$db" ] && [ -n "$task_id" ] && [ -n "$claim_token" ] || return 1

    local safe_task_id safe_claim_token session_value result changes
    safe_task_id="$(manul_session_sql_escape "$task_id")"
    safe_claim_token="$(manul_session_sql_escape "$claim_token")"

    if [ "$status" = "NEEDS_CONTINUATION" ] && [ -n "$session_id" ]; then
        session_value="'$(manul_session_sql_escape "$session_id")'"
    else
        session_value="NULL"
    fi

    # A worker may update the session pointer only while it still owns this
    # exact running claim. This prevents an expired worker from overwriting a
    # newer attempt's session state.
    result="$(sqlite3 "$db" "
        UPDATE processed_comments
        SET session_id=$session_value
        WHERE commentId='$safe_task_id'
          AND status='running'
          AND claimToken='$safe_claim_token';
        SELECT changes();
    " 2>/dev/null)" || return 1

    changes="$(printf '%s\n' "$result" | tail -n 1)"
    [ "$changes" = "1" ]
}
