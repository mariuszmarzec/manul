#!/usr/bin/env bash
# process-runner.sh — Testable process boundary for AgentExecutor adapters.
#
# Adapters MUST NOT spawn subprocesses directly. They call ProcessRunner.run()
# which returns a structured result the test suite can mock without a real
# process. This file provides both the interface contract and a production
# implementation backed by bash's built-in process management.
#
# The production return value begins with one protocol line:
#   exit_code|duration_seconds|interrupted|timed_out[|timeout_reason]
# timeout_reason is present for idle_timeout, step_idle_timeout, or tool_idle_timeout, and absent
# for normal completion / the generic wall-clock timeout. Adapter output is
# written to the supplied stdout/stderr files; no runtime JSONL is mixed into
# this protocol line.
#
# Production usage (inside an adapter):
#   source "$SCRIPT_DIR/process-runner.sh"
#   local result
#   result="$(ProcessRunner.run --timeout "$timeout" --cwd "$cwd" \
#           -- bin args...)"
#   local exit_code duration interrupted timed_out
#   exit_code="$(printf '%s\n' "$result" | head -1 | cut -f1)"
#   ...
#
# Testing usage (inside tests):
#   ProcessRunner.MockMode=true  # before sourcing
#   # ProcessRunner.run returns the fixture output instead of spawning.
#
# Public API:
#   ProcessRunner.run [--timeout N] [--idle-timeout N] [--idle-jsonl-file PATH] [--idle-tool-timeout N] [--idle-step-timeout N] [--cwd PATH] [--env K=V ...] <COMMAND> [ARGS...]
#     → stdout: protocol line exit_code|duration|interrupted|timed_out[|timeout_reason]
#     → adapter stdout/stderr are captured in caller-supplied files when present
#
# ProcessRunner.fixture() — set the mock return value from a test.
#   ProcessRunner.fixture '0|5.2|false|false'
#   ProcessRunner.fixture_stdout "TASK_DONE"
#   ProcessRunner.fixture_stderr "starting..."
#
# ProcessRunner.MockMode — boolean; when true, run() returns fixture instead.

ProcessRunner_ExitCode=""
ProcessRunner_Duration=""
ProcessRunner_Interrupted=""
ProcessRunner_TimedOut=""
ProcessRunner_FixtureStdout=""
ProcessRunner_FixtureStderr=""
ProcessRunner_OverrideCommand=""
ProcessRunner_OverrideArgs=""

ProcessRunner_RunPid=""
ProcessRunner_RunStart=""
ProcessRunner_WaitPid=""
ProcessRunner_Rc=""
ProcessRunner_TimedOut=""
ProcessRunner_ToolIdleTimedOut="false"
ProcessRunner_StepIdleTimedOut="false"
ProcessRunner_Interrupted=""

# Track whether ProcessRunner created the stdout/stderr temp files itself.
# Files it created are cleaned up; files supplied by the caller (e.g. the
# daemon's task stdout/stderr) are left intact so the caller can inspect them.
ProcessRunner_ManagedStdout=""
ProcessRunner_ManagedStderr=""

_process_runner_now() {
    python3 -c 'import time; print(time.time())' 2>/dev/null \
        || date +%s.%N
}

ProcessRunner.fixture() {
    ProcessRunner_ExitCode="$1"
    ProcessRunner_Duration="${2:-}"
    ProcessRunner_Interrupted="${3:-false}"
    ProcessRunner_TimedOut="${4:-false}"
}

ProcessRunner.fixture_stdout() {
    ProcessRunner_FixtureStdout="$*"
}

ProcessRunner.fixture_stderr() {
    ProcessRunner_FixtureStderr="$*"
}

ProcessRunner.override() {
    # For tests that need a specific command+args to be reported.
    ProcessRunner_OverrideCommand="$1"
    shift
    ProcessRunner_OverrideArgs=("$@")
}

ProcessRunner.run() {
    local timeout="" idle_timeout="" idle_jsonl_file="" idle_tool_timeout="" idle_step_timeout="" cwd="" env_args=() cmd_args=()
    ProcessRunner_Rc=""
    ProcessRunner_Interrupted="false"
    ProcessRunner_TimedOut="false"
    ProcessRunner_IdleTimedOut="false"
    ProcessRunner_ToolIdleTimedOut="false"
    ProcessRunner_StepIdleTimedOut="false"
    ProcessRunner_ManagedStdout=""
    ProcessRunner_ManagedStderr=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --idle-timeout) idle_timeout="$2"; shift 2 ;;
            --idle-jsonl-file) idle_jsonl_file="$2"; shift 2 ;;
            --idle-tool-timeout) idle_tool_timeout="$2"; shift 2 ;;
            --idle-step-timeout) idle_step_timeout="$2"; shift 2 ;;
            --cwd)     cwd="$2";     shift 2 ;;
            --env)     env_args+=("$2"); shift 2 ;;
            --)        shift; cmd_args+=("$@"); break ;;
            -*)        cmd_args+=("$1"); shift ;;
            *)
                # First positional arg is the command; rest are args.
                if [ ${#cmd_args[@]} -eq 0 ]; then
                    cmd_args+=("$1")
                else
                    cmd_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    # --- Mock mode (set by tests via ProcessRunner.MockMode=true) ---
    if [ "${ProcessRunner_MockMode:-false}" = "true" ]; then
        local mock_exit="${ProcessRunner_ExitCode:-0}"
        local mock_dur="${ProcessRunner_Duration:-0}"
        local mock_int="${ProcessRunner_Interrupted:-false}"
        local mock_to="${ProcessRunner_TimedOut:-false}"
        printf '%s|%s|%s|%s\n' "$mock_exit" "$mock_dur" "$mock_int" "$mock_to"
        if [ -n "$ProcessRunner_FixtureStdout" ]; then
            printf '%s' "$ProcessRunner_FixtureStdout"
        fi
        if [ -n "$ProcessRunner_FixtureStderr" ]; then
            printf '%s' "$ProcessRunner_FixtureStderr" >&2
        fi
        return 0
    fi

    # --- Production path ---
    local start_ts end_ts dur
    start_ts="$(_process_runner_now)"

    local full_cmd=("${cmd_args[@]}")
    if [ ${#full_cmd[@]} -eq 0 ]; then
        echo "ProcessRunner: missing command" >&2
        return 2
    fi

    local env_prefix=()
    local i
    for i in "${!env_args[@]}"; do
        env_prefix+=("${env_args[$i]}")
    done

    # Resolve stdout/stderr destinations. Caller-supplied files (e.g. the
    # daemon's per-task stdout/stderr) are kept intact so the caller can
    # inspect result markers after the run. If none are supplied, ProcessRunner
    # creates managed temp files and cleans them up afterwards.
    local out_file="${ProcessRunner_TmpStdout:-}"
    local err_file="${ProcessRunner_TmpStderr:-}"
    if [ -z "$out_file" ]; then
        out_file="$(mktemp "${TMPDIR:-/tmp}/manul-pr-out.XXXXXX")"
        ProcessRunner_ManagedStdout="$out_file"
    fi
    if [ -z "$err_file" ]; then
        err_file="$(mktemp "${TMPDIR:-/tmp}/manul-pr-err.XXXXXX")"
        ProcessRunner_ManagedStderr="$err_file"
    fi

    local old_pwd
    old_pwd="$(pwd)"
    if [ -n "$cwd" ] && [ ! -d "$cwd" ]; then
        echo "ProcessRunner: working directory does not exist: $cwd" >&2
        ProcessRunner_Rc=66
    else
        if [ -n "$cwd" ]; then
            cd "$cwd" || ProcessRunner_Rc=66
        fi

        local -a exec_cmd=()
        if [ ${#env_prefix[@]} -gt 0 ]; then
            exec_cmd=(env "${env_prefix[@]}" "${full_cmd[@]}")
        else
            exec_cmd=("${full_cmd[@]}")
        fi

        if [ -z "${ProcessRunner_Rc:-}" ]; then
            if [ -n "$idle_timeout" ] && [[ "$idle_timeout" =~ ^[0-9]+$ ]] && [ "$idle_timeout" -gt 0 ] 2>/dev/null; then
                # Isolate the runtime in its own process group so an idle timeout
                # cannot signal the Manul supervisor or sibling tasks.
                if command -v setsid >/dev/null 2>&1; then
                    setsid timeout -k 60 "${timeout:-2147483647}" "${exec_cmd[@]}" <&0 >>"$out_file" 2>>"$err_file" &
                else
                    printf '%s\n' "ProcessRunner: --idle-timeout requires setsid; runtime was not launched" >>"$err_file"
                    ProcessRunner_Rc=127
                fi
                if [ -z "${ProcessRunner_Rc:-}" ]; then
                    local idle_runner_pid idle_last_progress idle_now idle_out_size idle_err_size idle_prev_out idle_prev_err idle_state idle_pgid idle_tool_status idle_tool_started idle_step_status idle_step_started idle_output_changed
                    idle_runner_pid=$!
                    idle_last_progress="$(date +%s)"
                    idle_tool_started=""
                    idle_step_started=""
                    if ! [[ "$idle_tool_timeout" =~ ^[0-9]+$ ]] || [ "$idle_tool_timeout" -lt 1 ]; then
                        idle_tool_timeout=3600
                    fi
                    if ! [[ "$idle_step_timeout" =~ ^[0-9]+$ ]] || [ "$idle_step_timeout" -lt 1 ]; then
                        idle_step_timeout=3600
                    fi
                    idle_prev_out="$(stat -c '%s' "$out_file" 2>/dev/null || echo 0)"
                    idle_prev_err="$(stat -c '%s' "$err_file" 2>/dev/null || echo 0)"
                    while :; do
                        sleep 1
                        idle_state="$(ps -o stat= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                        case "$idle_state" in ""|*Z*) break ;; esac

                        idle_now="$(date +%s)"
                        # Measure file growth before checking active-step/tool
                        # timers so newly emitted JSONL/stderr progress refreshes
                        # those bounded idle windows before any timeout decision.
                        idle_output_changed="false"
                        idle_out_size="$(stat -c '%s' "$out_file" 2>/dev/null || echo 0)"
                        idle_err_size="$(stat -c '%s' "$err_file" 2>/dev/null || echo 0)"
                        if [ "$idle_out_size" != "$idle_prev_out" ] || [ "$idle_err_size" != "$idle_prev_err" ]; then
                            idle_last_progress="$idle_now"
                            [ -n "$idle_tool_started" ] && idle_tool_started="$idle_now"
                            [ -n "$idle_step_started" ] && idle_step_started="$idle_now"
                            idle_prev_out="$idle_out_size"
                            idle_prev_err="$idle_err_size"
                            idle_output_changed="true"
                        fi
                        idle_tool_status=""
                        if [ -n "$idle_jsonl_file" ] && [ -s "$idle_jsonl_file" ]; then
                            # OpenCode, Codex CLI, and Claude Code can spend a long time inside one tool call.
                            # Their JSONL event streams identify active tool calls even
                            # when no additional output is emitted. Do not classify that
                            # bounded, explicit activity as a dead agent; the total
                            # execution timeout remains in force.
                            idle_tool_status="$(tail -n 100 "$idle_jsonl_file" 2>/dev/null |
                                jq -Rr '
                                    try fromjson catch empty |
                                    if .type == "tool_use" then
                                        (.part.state.status // .state.status // empty)
                                    elif .type == "item.started" and (.item.type | IN("command_execution", "mcp_tool_call", "computer_call", "web_search")) then
                                        "running"
                                    elif .type == "item.completed" and (.item.type | IN("command_execution", "mcp_tool_call", "computer_call", "web_search")) then
                                        "completed"
                                    elif .type == "assistant" and any(.message.content[]?; .type == "tool_use") then
                                        "running"
                                    elif .type == "user" and any(.message.content[]?; .type == "tool_result") then
                                        "completed"
                                    else empty end
                                ' 2>/dev/null |
                                awk 'NF { value=$0 } END { print value }')"
                        fi
                        case "$idle_tool_status" in
                            running|pending|started|executing)
                                [ -n "$idle_tool_started" ] || idle_tool_started="$idle_now"
                                if [ "$((idle_now - idle_tool_started))" -ge "$idle_tool_timeout" ]; then
                                    printf 'ProcessRunner: OpenCode JSONL tool call remained active without completion for %ss; terminating isolated runtime process group\n' "$idle_tool_timeout" >>"$err_file"
                                    idle_pgid="$(ps -o pgid= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                                    if [ "$idle_pgid" = "$idle_runner_pid" ]; then
                                        kill -TERM -- "-$idle_runner_pid" 2>/dev/null || true
                                    else
                                        kill -TERM "$idle_runner_pid" 2>/dev/null || true
                                    fi
                                    sleep 2
                                    idle_state="$(ps -o stat= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                                    case "$idle_state" in
                                        ""|*Z*) ;;
                                        *)
                                            if [ "$idle_pgid" = "$idle_runner_pid" ]; then
                                                kill -KILL -- "-$idle_runner_pid" 2>/dev/null || true
                                            else
                                                kill -KILL "$idle_runner_pid" 2>/dev/null || true
                                            fi
                                            ;;
                                    esac
                                    wait "$idle_runner_pid" 2>/dev/null || true
                                    ProcessRunner_Rc=124
                                    ProcessRunner_TimedOut="true"
                                    ProcessRunner_ToolIdleTimedOut="true"
                                    break
                                fi
                                # A pending JSONL tool event is explicit execution
                                # state. The generic stdout-idle budget doesn't apply
                                # until the tool completes, but the total execution
                                # timeout continues to cap the entire runtime.
                                idle_last_progress="$idle_now"
                                ;;
                            *)
                                idle_tool_started=""
                                ;;
                        esac

                        if [ -n "$idle_jsonl_file" ] && [ -s "$idle_jsonl_file" ]; then
                            # opencode run --format json emits step_start before
                            # its model/tool work and step_finish at the end. Some
                            # long model/tool operations emit no further CLI output
                            # until they finish, so a trailing unfinished step is
                            # bounded active work even when stdout/stderr are quiet.
                            idle_step_status="$(tail -n 2000 "$idle_jsonl_file" 2>/dev/null |
                                jq -Rr 'try fromjson catch empty | select(.type == "step_start" or .type == "step_finish") | .type' 2>/dev/null |
                                awk 'NF { value=$0 } END { print value }')"
                        else
                            idle_step_status=""
                        fi
                        if [ "$idle_step_status" = "step_start" ]; then
                            [ -n "$idle_step_started" ] || idle_step_started="$idle_now"
                            if [ "$((idle_now - idle_step_started))" -ge "$idle_step_timeout" ]; then
                                printf 'ProcessRunner: OpenCode step remained unfinished without output for %ss; terminating isolated runtime process group\n' "$idle_step_timeout" >>"$err_file"
                                idle_pgid="$(ps -o pgid= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                                if [ "$idle_pgid" = "$idle_runner_pid" ]; then
                                    kill -TERM -- "-$idle_runner_pid" 2>/dev/null || true
                                else
                                    kill -TERM "$idle_runner_pid" 2>/dev/null || true
                                fi
                                sleep 2
                                idle_state="$(ps -o stat= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                                case "$idle_state" in
                                    ""|*Z*) ;;
                                    *)
                                        if [ "$idle_pgid" = "$idle_runner_pid" ]; then
                                            kill -KILL -- "-$idle_runner_pid" 2>/dev/null || true
                                        else
                                            kill -KILL "$idle_runner_pid" 2>/dev/null || true
                                        fi
                                        ;;
                                esac
                                wait "$idle_runner_pid" 2>/dev/null || true
                                ProcessRunner_Rc=124
                                ProcessRunner_TimedOut="true"
                                ProcessRunner_StepIdleTimedOut="true"
                                break
                            fi
                            idle_last_progress="$idle_now"
                        else
                            idle_step_started=""
                        fi

                        if [ "$idle_output_changed" = "true" ]; then
                            continue
                        fi
                        if [ "$((idle_now - idle_last_progress))" -ge "$idle_timeout" ]; then
                            if [ -n "$idle_jsonl_file" ]; then
                                printf 'ProcessRunner: no stdout/stderr or recognized active JSONL step/tool progress for %ss; terminating isolated runtime process group\n' "$idle_timeout" >>"$err_file"
                            else
                                printf 'ProcessRunner: no stdout/stderr progress for %ss; terminating isolated runtime process group\n' "$idle_timeout" >>"$err_file"
                            fi
                            idle_pgid="$(ps -o pgid= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                            if [ "$idle_pgid" = "$idle_runner_pid" ]; then
                                kill -TERM -- "-$idle_runner_pid" 2>/dev/null || true
                            else
                                kill -TERM "$idle_runner_pid" 2>/dev/null || true
                            fi
                            sleep 2
                            idle_state="$(ps -o stat= -p "$idle_runner_pid" 2>/dev/null | tr -d '[:space:]')"
                            case "$idle_state" in
                                ""|*Z*) ;;
                                *)
                                    if [ "$idle_pgid" = "$idle_runner_pid" ]; then
                                        kill -KILL -- "-$idle_runner_pid" 2>/dev/null || true
                                    else
                                        kill -KILL "$idle_runner_pid" 2>/dev/null || true
                                    fi
                                    ;;
                            esac
                            wait "$idle_runner_pid" 2>/dev/null || true
                            ProcessRunner_Rc=124
                            ProcessRunner_TimedOut="true"
                            ProcessRunner_IdleTimedOut="true"
                            break
                        fi
                    done
                    if [ "${ProcessRunner_IdleTimedOut:-false}" != "true" ] && [ "${ProcessRunner_ToolIdleTimedOut:-false}" != "true" ] && [ "${ProcessRunner_StepIdleTimedOut:-false}" != "true" ]; then
                        wait "$idle_runner_pid"
                        ProcessRunner_Rc=$?
                        if [ "$ProcessRunner_Rc" -eq 124 ]; then ProcessRunner_TimedOut="true"; fi
                    fi
                fi
            elif [ -n "$timeout" ] && [ "$timeout" -gt 0 ] 2>/dev/null; then
                timeout -k 60 "$timeout" "${exec_cmd[@]}" >>"$out_file" 2>>"$err_file"
                ProcessRunner_Rc=$?
                if [ "$ProcessRunner_Rc" -eq 124 ]; then
                    ProcessRunner_TimedOut="true"
                fi
            else
                "${exec_cmd[@]}" >>"$out_file" 2>>"$err_file"
                ProcessRunner_Rc=$?
            fi
        fi
        cd "$old_pwd" 2>/dev/null || true
    fi

    end_ts="$(_process_runner_now)"
    dur="$(python3 -c "print(round($end_ts - $start_ts, 3))" 2>/dev/null || echo "$(( end_ts - start_ts ))")"

    # Emit captured output for managed files so callers using $(...) can see it.
    if [ -n "$ProcessRunner_ManagedStdout" ] && [ -s "$out_file" ]; then
        cat "$out_file"
    fi
    if [ -n "$ProcessRunner_ManagedStderr" ] && [ -s "$err_file" ]; then
        cat "$err_file" >&2
    fi

    # Clean up only files ProcessRunner created itself.
    [ -n "$ProcessRunner_ManagedStdout" ] && rm -f "$ProcessRunner_ManagedStdout" 2>/dev/null || true
    [ -n "$ProcessRunner_ManagedStderr" ] && rm -f "$ProcessRunner_ManagedStderr" 2>/dev/null || true
    unset ProcessRunner_ManagedStdout ProcessRunner_ManagedStderr

    if [ "${ProcessRunner_ToolIdleTimedOut:-false}" = "true" ]; then
        printf '%s|%s|false|true|tool_idle_timeout\n' "$ProcessRunner_Rc" "$dur"
    elif [ "${ProcessRunner_StepIdleTimedOut:-false}" = "true" ]; then
        printf '%s|%s|false|true|step_idle_timeout\n' "$ProcessRunner_Rc" "$dur"
    elif [ "${ProcessRunner_IdleTimedOut:-false}" = "true" ]; then
        printf '%s|%s|false|true|idle_timeout\n' "$ProcessRunner_Rc" "$dur"
    else
        printf '%s|%s|false|%s\n' "$ProcessRunner_Rc" "$dur" "${ProcessRunner_TimedOut:-false}"
    fi
    return "$ProcessRunner_Rc"
}
