#!/usr/bin/env bash
# Durable lifecycle result delivery for Todo Local and Todo Remote.
# The daemon supplies DB/CONFIG/LOG/MANUL_DIR and the task-source helpers.

ensure_todo_result_outbox_table() {
  sqlite3 "$DB" "
    CREATE TABLE IF NOT EXISTS manul_todo_result_outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      taskId TEXT NOT NULL,
      sourceType TEXT NOT NULL,
      sourceId TEXT NOT NULL,
      resultStatus TEXT NOT NULL CHECK(resultStatus IN ('completed','failed')),
      summary TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      nextAttemptAt TEXT NOT NULL DEFAULT (datetime('now')),
      lastError TEXT,
      createdAt TEXT NOT NULL DEFAULT (datetime('now')),
      updatedAt TEXT NOT NULL DEFAULT (datetime('now')),
      deliveredAt TEXT,
      UNIQUE(taskId, sourceType, sourceId, resultStatus)
    );
    CREATE INDEX IF NOT EXISTS idx_manul_todo_result_outbox_pending
      ON manul_todo_result_outbox(deliveredAt, nextAttemptAt);
    DELETE FROM manul_todo_result_outbox
      WHERE deliveredAt IS NOT NULL AND deliveredAt < datetime('now', '-30 days');
  " >/dev/null
}

queue_todo_result_update() {
  local task_id="$1" source_type="$2" source_id="$3" result_status="$4" summary="$5"
  local safe_task_id safe_source_type safe_source_id safe_status safe_summary
  [ -n "$task_id" ] && [ -n "$source_id" ] || return 1
  task_source_is_todo_type "$source_type" || return 2
  case "$result_status" in completed|failed) ;; *) return 2 ;; esac
  ensure_todo_result_outbox_table || return 1
  safe_task_id="$(sql_escape "$task_id")"
  safe_source_type="$(sql_escape "$source_type")"
  safe_source_id="$(sql_escape "$source_id")"
  safe_status="$(sql_escape "$result_status")"
  safe_summary="$(sql_escape "$summary")"
  sqlite3 "$DB" "
    INSERT INTO manul_todo_result_outbox
      (taskId, sourceType, sourceId, resultStatus, summary, nextAttemptAt)
    VALUES
      ('$safe_task_id', '$safe_source_type', '$safe_source_id', '$safe_status', '$summary', datetime('now'))
    ON CONFLICT(taskId, sourceType, sourceId, resultStatus) DO UPDATE SET
      summary=excluded.summary, nextAttemptAt=datetime('now'), updatedAt=datetime('now')
    WHERE manul_todo_result_outbox.deliveredAt IS NULL;
    SELECT id FROM manul_todo_result_outbox
    WHERE taskId='$safe_task_id' AND sourceType='$safe_source_type'
      AND sourceId='$safe_source_id' AND resultStatus='$safe_status'
    LIMIT 1;
  " 2>>"$LOG" | tail -n 1
}

todo_result_outbox_is_delivered() {
  local task_id="$1" source_type="$2" source_id="$3" result_status="$4"
  local safe_task_id safe_source_type safe_source_id safe_status
  safe_task_id="$(sql_escape "$task_id")"
  safe_source_type="$(sql_escape "$source_type")"
  safe_source_id="$(sql_escape "$source_id")"
  safe_status="$(sql_escape "$result_status")"
  [ "$(sqlite3 "$DB" "
    SELECT COUNT(*) FROM manul_todo_result_outbox
    WHERE taskId='$safe_task_id' AND sourceType='$safe_source_type'
      AND sourceId='$safe_source_id' AND resultStatus='$safe_status'
      AND deliveredAt IS NOT NULL;
  " 2>/dev/null)" = "1" ]
}

retry_pending_todo_result_updates() {
  local only_task_id="${1:-}" only_source_type="${2:-}" only_source_id="${3:-}" only_status="${4:-}"
  local lock_path lock_fd where_sql rows row row_id task_id source_type source_id result_status summary
  local delivery_receipt delivery_rc delivery_error previous_attempts delay safe_error transaction
  ensure_todo_result_outbox_table || return 1
  mkdir -p "$MANUL_DIR/state" || return 1
  lock_path="$MANUL_DIR/state/todo-result-outbox.lock"
  exec {lock_fd}>"$lock_path" || return 1
  if ! flock -n "$lock_fd"; then
    exec {lock_fd}>&-
    return 0
  fi

  where_sql="deliveredAt IS NULL"
  if [ -n "$only_task_id" ]; then
    where_sql+=" AND taskId='$(sql_escape "$only_task_id")'"
    where_sql+=" AND sourceType='$(sql_escape "$only_source_type")'"
    where_sql+=" AND sourceId='$(sql_escape "$only_source_id")'"
    where_sql+=" AND resultStatus='$(sql_escape "$only_status")'"
  else
    where_sql+=" AND nextAttemptAt <= datetime('now')"
    where_sql+=" AND (
      resultStatus='failed'
      OR (resultStatus='completed' AND EXISTS (
        SELECT 1 FROM processed_comments p
        WHERE p.commentId=manul_todo_result_outbox.taskId AND p.status='delivery_pending'
      ))
    )"
  fi

  rows="$(sqlite3 "$DB" "
    SELECT json_object('id',id,'taskId',taskId,'sourceType',sourceType,
      'sourceId',sourceId,'resultStatus',resultStatus,'summary',summary,'attempts',attempts)
    FROM manul_todo_result_outbox WHERE $where_sql ORDER BY id LIMIT 25;
  " 2>>"$LOG")" || rows=""

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    row_id="$(jq -r '.id' <<<"$row")"
    task_id="$(jq -r '.taskId' <<<"$row")"
    source_type="$(jq -r '.sourceType' <<<"$row")"
    source_id="$(jq -r '.sourceId' <<<"$row")"
    result_status="$(jq -r '.resultStatus' <<<"$row")"
    summary="$(jq -r '.summary' <<<"$row")"

    delivery_rc=0
    delivery_receipt="$(task_source_publish_update "$CONFIG" "$source_type" "$source_id" "$result_status" "$summary" 2>&1)" || delivery_rc=$?
    delivery_error="$delivery_receipt"
    if [ "$delivery_rc" -eq 0 ] && [ "$result_status" = "completed" ]; then
      task_source_complete "$CONFIG" "$source_type" "$source_id" >>"$LOG" 2>&1 || {
        delivery_rc=$?
        delivery_error="Todo report was saved, but the task tree could not be marked done: $delivery_receipt"
      }
    fi

    if [ "$delivery_rc" -eq 0 ]; then
      transaction="BEGIN IMMEDIATE;
        UPDATE manul_todo_result_outbox
        SET deliveredAt=datetime('now'), updatedAt=datetime('now'), lastError=NULL
        WHERE id=$row_id AND deliveredAt IS NULL;"
      if [ "$result_status" = "completed" ]; then
        transaction+="
          UPDATE processed_comments
          SET status='completed', processedAt=datetime('now'),
              heartbeatAt=NULL, leaseExpiresAt=NULL, workerPid=NULL,
              claimToken=NULL, agentStartedAt=NULL, nextAttemptAt=NULL
          WHERE commentId='$(sql_escape "$task_id")' AND status='delivery_pending';"
      fi
      transaction+=" COMMIT;"
      if sqlite3 "$DB" "$transaction" >/dev/null 2>>"$LOG"; then
        lc_log "TODO_RESULT_DELIVERED" "task=$task_id source=$source_type status=$result_status outbox_id=$row_id"
        log "dispatch: verified Todo $result_status report for task $task_id (outbox=$row_id)"
        continue
      fi
      delivery_rc=1
      delivery_error="Todo report delivered, but the local outbox acknowledgement failed"
    fi

    previous_attempts="$(jq -r '.attempts // 0' <<<"$row")"
    case "$previous_attempts" in
      0) delay=60 ;; 1) delay=120 ;; 2) delay=240 ;; 3) delay=480 ;;
      4) delay=960 ;; 5) delay=1800 ;; *) delay=3600 ;;
    esac
    if declare -F manul_redact_failure_details >/dev/null 2>&1; then
      safe_error="$(manul_redact_failure_details "$delivery_error")"
    else
      safe_error="$delivery_error"
    fi
    safe_error="${safe_error:0:1000}"
    sqlite3 "$DB" "
      UPDATE manul_todo_result_outbox
      SET attempts=attempts+1,nextAttemptAt=datetime('now','+$delay seconds'),
          updatedAt=datetime('now'),lastError='$(sql_escape "$safe_error")'
      WHERE id=$row_id AND deliveredAt IS NULL;
    " >/dev/null 2>>"$LOG" || true
    lc_log "TODO_RESULT_DELIVERY_RETRY_SCHEDULED" "task=$task_id source=$source_type status=$result_status attempt=$((previous_attempts + 1)) delay=${delay}s"
    log "WARN: Todo $result_status report for task $task_id remains pending; retry scheduled in ${delay}s: ${safe_error:-unknown error}"
  done <<<"$rows"

  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return 0
}

publish_todo_task_result() {
  local task_id="$1" source_type="$2" source_id="$3" summary="$4" claim_token="$5"
  queue_todo_result_update "$task_id" "$source_type" "$source_id" completed "$summary" >/dev/null || return 1
  update_task_completion "$task_id" "delivery_pending" "Todo result delivery pending" "$claim_token" || return 1
  retry_pending_todo_result_updates "$task_id" "$source_type" "$source_id" completed || true
  todo_result_outbox_is_delivered "$task_id" "$source_type" "$source_id" completed && return 0
  return 10
}
