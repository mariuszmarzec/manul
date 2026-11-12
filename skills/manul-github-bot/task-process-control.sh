#!/usr/bin/env bash
# task-process-control.sh — shared, task-scoped process identity and cleanup.
#
# Both the daemon and periodic watchdog use this file so stale recovery and
# manual/task shutdown operate on the same executor process tree.

task_process_is_running() {
  local pid="$1"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  local process_state
  process_state="$(ps -o stat= -p "$pid" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [ -n "$process_state" ] && [[ "$process_state" != Z* ]]
}

# Print every live descendant of a PID from one process-table snapshot. This
# includes tools such as GNU timeout that put their own children into a
# different process group, which a group-only signal cannot terminate.
task_descendant_pids() {
  local root_pid="$1"
  ps -axo pid=,ppid= | awk -v root="$root_pid" '
    {
      pids[NR] = $1
      parents[$1] = $2
      total = NR
    }
    END {
      depth[root] = 0
      do {
        changed = 0
        for (i = 1; i <= total; i++) {
          pid = pids[i]
          parent = parents[pid]
          if (pid != root && (parent in depth) && !(pid in depth)) {
            depth[pid] = depth[parent] + 1
            if (depth[pid] > max_depth) max_depth = depth[pid]
            changed = 1
          }
        }
      } while (changed)

      # Emit from root toward leaves. Callers signal in reverse order so the
      # deepest descendants are stopped before their parents.
      for (level = 1; level <= max_depth; level++) {
        for (i = 1; i <= total; i++) {
          if (depth[pids[i]] == level) print pids[i]
        }
      }
    }'
}

# Find a task runner by its explicit context/PID-file arguments when a prior
# stop removed the PID marker before the isolated process had actually exited.
find_task_executor_pid() {
  local comment_id="$1"
  local expected_context="$(manul_task_file_path "$MANUL_STATE_DIR/tasks" "$comment_id" "ctx.json")"
  local expected_pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "executor.pid")"
  local pid cmdline

  while read -r pid cmdline; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$cmdline" == *agent-task-runner.sh*"$expected_context"*"$expected_pid_file"* ]] || continue
    printf '%s\n' "$pid"
    return 0
  done < <(ps -ww -axo pid=,command= 2>/dev/null)
  return 1
}

# Verify the heartbeat PID is the direct child started for this task's
# long-lived daemon worker. A stale/reused PID must never be mistaken for a
# healthy heartbeat.
task_heartbeat_is_alive() {
  local comment_id="$1"
  local worker_pid="$2"
  local pid_file heartbeat_pid heartbeat_state heartbeat_ppid heartbeat_args

  [[ "$worker_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")"
  [ -f "$pid_file" ] || return 1

  heartbeat_pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$heartbeat_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$heartbeat_pid" != "$worker_pid" ] || return 1
  kill -0 "$heartbeat_pid" 2>/dev/null || return 1

  heartbeat_state="$(ps -o stat= -p "$heartbeat_pid" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [ -n "$heartbeat_state" ] && [[ "$heartbeat_state" != Z* ]] || return 1

  heartbeat_ppid="$(ps -o ppid= -p "$heartbeat_pid" 2>/dev/null | tr -d '[:space:]')"
  [ "$heartbeat_ppid" = "$worker_pid" ] || return 1

  heartbeat_args="$(ps -ww -o command= -p "$heartbeat_pid" 2>/dev/null || true)"
  [[ "$heartbeat_args" == *manul-daemon.sh* && "$heartbeat_args" == *loop* ]]
}

# Stop only the heartbeat process proven to belong to this exact claim.
# If the worker already exited, the heartbeat is orphaned and will observe the
# cleared/changed DB claim on its next iteration; do not risk killing a reused
# PID or another task's generic Manul loop process.
terminate_task_heartbeat_for_claim() {
  local comment_id="$1"
  local worker_pid="$2"
  local pid_file heartbeat_pid heartbeat_ppid heartbeat_args
  local descendants=() process_pid wait_attempt alive forced=0

  pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "heartbeat.pid")"
  [ -f "$pid_file" ] || return 0
  heartbeat_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if ! [[ "$heartbeat_pid" =~ ^[1-9][0-9]*$ ]] || ! task_process_is_running "$heartbeat_pid"; then
    rm -f "$pid_file" 2>/dev/null || true
    return 0
  fi

  heartbeat_ppid="$(ps -o ppid= -p "$heartbeat_pid" 2>/dev/null | tr -d '[:space:]')"
  heartbeat_args="$(ps -ww -o command= -p "$heartbeat_pid" 2>/dev/null || true)"
  if [ "$heartbeat_ppid" != "$worker_pid" ] ||
     [[ "$heartbeat_args" != *manul-daemon.sh* ]] ||
     [[ "$heartbeat_args" != *loop* ]]; then
    log "WARN: refusing to terminate heartbeat PID $heartbeat_pid for task $comment_id (expected parent=$worker_pid actual_parent=${heartbeat_ppid:-missing}); claim transition will make it exit normally"
    return 1
  fi

  mapfile -t descendants < <(task_descendant_pids "$heartbeat_pid")
  log "terminating heartbeat process tree for $comment_id (pid=$heartbeat_pid descendants=${#descendants[@]})"
  for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
    kill -TERM "${descendants[$wait_attempt]}" 2>/dev/null || true
  done
  kill -TERM "$heartbeat_pid" 2>/dev/null || true

  alive=1
  for ((wait_attempt=0; wait_attempt<20; wait_attempt++)); do
    alive=0
    for process_pid in "${descendants[@]}" "$heartbeat_pid"; do
      if task_process_is_running "$process_pid"; then
        alive=1
        break
      fi
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.1
  done

  if [ "$alive" -eq 1 ]; then
    forced=1
    log "WARN: heartbeat tree for $comment_id did not stop after TERM; sending KILL"
    for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
      process_pid="${descendants[$wait_attempt]}"
      task_process_is_running "$process_pid" && kill -KILL "$process_pid" 2>/dev/null || true
    done
    kill -KILL "$heartbeat_pid" 2>/dev/null || true
  fi

  rm -f "$pid_file" 2>/dev/null || true
  if declare -F lc_log >/dev/null 2>&1; then
    lc_log "HEARTBEAT_REAPED" "task=$comment_id pid=$heartbeat_pid descendants=${#descendants[@]} forced=$forced"
  fi
}
terminate_task_executor() {
  local comment_id="$1"
  local pid_file="$(manul_task_file_path "$MANUL_DIR" "$comment_id" "executor.pid")"
  local executor_pid="" executor_args="" executor_pgid=""
  local descendants=() process_pid wait_attempt alive forced=0

  if [ -f "$pid_file" ]; then
    executor_pid="$(cat "$pid_file" 2>/dev/null || true)"
  fi

  # Older stop paths removed PID files even though setsid-created executors
  # survived. Recover the root PID from its task-specific command line.
  if ! [[ "$executor_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$executor_pid" 2>/dev/null; then
    executor_pid="$(find_task_executor_pid "$comment_id" 2>/dev/null || true)"
  fi

  if [[ "$executor_pid" =~ ^[0-9]+$ ]] && [ "$executor_pid" -gt 0 ] && kill -0 "$executor_pid" 2>/dev/null; then
    executor_args="$(ps -o args= -p "$executor_pid" 2>/dev/null || true)"
    # A PID file can outlive its process and the OS can reuse the numeric PID.
    # Never signal a process unless it still identifies the expected task runner.
    if [[ "$executor_args" != *agent-task-runner.sh* || "$executor_args" != *"$pid_file"* ]]; then
      local discovered_pid
      discovered_pid="$(find_task_executor_pid "$comment_id" 2>/dev/null || true)"
      if [[ "$discovered_pid" =~ ^[0-9]+$ ]] && [ "$discovered_pid" -gt 0 ] && kill -0 "$discovered_pid" 2>/dev/null; then
        executor_pid="$discovered_pid"
        executor_args="$(ps -o args= -p "$executor_pid" 2>/dev/null || true)"
      fi
    fi

    if [[ "$executor_args" == *agent-task-runner.sh* && "$executor_args" == *"$pid_file"* ]]; then
      executor_pgid="$(ps -o pgid= -p "$executor_pid" 2>/dev/null | tr -d '[:space:]')"
      mapfile -t descendants < <(task_descendant_pids "$executor_pid")
      log "terminating task executor tree for $comment_id (pid=$executor_pid descendants=${#descendants[@]})"

      # Signal descendants before their parents so a child that created a new
      # session (e.g. timeout -> opencode) cannot survive when its parent exits.
      for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
        kill -TERM "${descendants[$wait_attempt]}" 2>/dev/null || true
      done
      if [[ "$executor_pgid" =~ ^[0-9]+$ ]] && [ "$executor_pgid" -eq "$executor_pid" ]; then
        kill -TERM -- "-$executor_pgid" 2>/dev/null || true
      fi
      kill -TERM "$executor_pid" 2>/dev/null || true

      alive=1
      for ((wait_attempt=0; wait_attempt<30; wait_attempt++)); do
        alive=0
        for process_pid in "${descendants[@]}" "$executor_pid"; do
          if task_process_is_running "$process_pid"; then
            alive=1
            break
          fi
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.1
      done

      if [ "$alive" -eq 1 ]; then
        forced=1
        log "WARN: task executor tree for $comment_id did not stop after TERM; sending KILL"
        for ((wait_attempt=${#descendants[@]} - 1; wait_attempt >= 0; wait_attempt--)); do
          process_pid="${descendants[$wait_attempt]}"
          task_process_is_running "$process_pid" && kill -KILL "$process_pid" 2>/dev/null || true
        done
        if [[ "$executor_pgid" =~ ^[0-9]+$ ]] && [ "$executor_pgid" -eq "$executor_pid" ]; then
          kill -KILL -- "-$executor_pgid" 2>/dev/null || true
        fi
        kill -KILL "$executor_pid" 2>/dev/null || true
      fi
      if declare -F lc_log >/dev/null 2>&1; then
        lc_log "EXECUTOR_KILLED" "task=$comment_id pid=$executor_pid descendants=${#descendants[@]} forced=$forced"
      fi
    else
      log "WARN: refusing to terminate PID $executor_pid for task $comment_id because it no longer matches the task runner"
    fi
  fi

  rm -f "$pid_file" 2>/dev/null || true
}
