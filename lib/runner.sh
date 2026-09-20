#!/bin/sh
# ==============================================================================
# Merlin-CI: Modular Job Runner & CI Lifecycle Engine (lib/runner.sh)
# Optimized for Embedded Linux (Low CPU & Memory Footprint)
# ==============================================================================

# --- Resource Guardrail Checks ---
runner_check_safety() {
    local max_load="${MCI_MAX_LOADAVG:-2.50}"
    local min_ram_mb="${MCI_MIN_FREE_RAM_MB:-32}"

    # 1. CPU Load Average Check
    if [ -f /proc/loadavg ]; then
        local current_load_1m
        current_load_1m="$(awk '{print $1}' /proc/loadavg)"
        
        local load_exceeded
        load_exceeded=$(awk -v cur="$current_load_1m" -v max="$max_load" 'BEGIN {print (cur > max) ? "1" : "0"}')
        if [ "$load_exceeded" = "1" ]; then
            echo "--> [GUARD] DEFERRED: CPU 1-min load ($current_load_1m) exceeds threshold ($max_load)!"
            echo "--> Routing and WiFi traffic take priority. Deferring job execution."
            return 1
        fi
    fi

    # 2. Available RAM Check (Accurate for Linux kernels with/without MemAvailable)
    if [ -f /proc/meminfo ]; then
        local mem_avail_mb
        mem_avail_mb=$(awk '/MemAvailable/ {print int($2/1024); f=1} END {if (!f) print -1}' /proc/meminfo)
        if [ "$mem_avail_mb" -eq -1 ]; then
            mem_avail_mb=$(awk '/MemFree/ {free=$2} /Buffers/ {buf=$2} /Cached/ {cach=$2} END {print int((free+buf+cach)/1024)}' /proc/meminfo)
        fi

        if [ "$mem_avail_mb" -lt "$min_ram_mb" ]; then
            echo "--> [GUARD] DEFERRED: Available RAM (${mem_avail_mb}MB) is below safety limit (${min_ram_mb}MB)!"
            echo "--> Deferring job to prevent router Out-Of-Memory (OOM) condition."
            return 1
        fi
    fi

    return 0
}

runner_rotate_logs() {
    local max_logs="${MCI_MAX_LOG_HISTORY:-10}"
    mkdir -p "$MCI_LOG_DIR" 2>/dev/null || true

    local log_count
    log_count=$(find "$MCI_LOG_DIR" -type f -name "job_*.log" | wc -l)

    if [ "$log_count" -gt "$max_logs" ]; then
        local to_remove=$((log_count - max_logs))
        # shellcheck disable=SC2012
        ls -1tr "$MCI_LOG_DIR"/job_*.log 2>/dev/null | head -n "$to_remove" | xargs rm -f 2>/dev/null || true
    fi
}

runner_rotate_backups() {
    local job_name="$1"
    local job_backup_dir="${MCI_BACKUP_DIR:-/opt/var/merlin-ci/backups}/${job_name}"
    mkdir -p "$job_backup_dir" 2>/dev/null || true

    # Keep at most 3 backups in embedded mode to preserve storage & inodes
    local max_backups=3
    local backup_count
    backup_count=$(find "$job_backup_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    if [ "$backup_count" -gt "$max_backups" ]; then
        local to_prune=$((backup_count - max_backups))
        # shellcheck disable=SC2012
        ls -1dtr "$job_backup_dir"/* 2>/dev/null | head -n "$to_prune" | xargs rm -rf 2>/dev/null || true
    fi
}

# Helper: Reliably test if a shell function is defined in BusyBox ash & Bash
_is_function() {
    local fn="$1"
    [ -n "$fn" ] || return 1
    # Check if 'type' reports it as a function (BusyBox ash outputs '<name> is a function')
    case "$(type "$fn" 2>/dev/null)" in
        *"function"*|*"()"*) return 0 ;;
    esac
    # Fallback to general type or command check
    type "$fn" >/dev/null 2>&1 && return 0
    command -v "$fn" >/dev/null 2>&1 && return 0
    return 1
}

# Execute a specific job definition with embedded-safe priority and timeout
runner_execute_job() {
    local job_file="$1"
    local trigger_source="${2:-manual}"
    local force_flag="${3:-0}"

    if [ ! -f "$job_file" ]; then
        echo "--> [ERROR] Job file not found: $job_file"
        return 1
    fi

    # Reset job variables & functions before sourcing
    JOB_NAME=""
    JOB_DESCRIPTION=""
    JOB_ENABLED=1
    JOB_TYPE="daily"
    MCI_OLD_VERSION=""
    MCI_NEW_VERSION=""
    unset -f mci_check_trigger mci_backup mci_run mci_verify mci_rollback mci_notify 2>/dev/null || true

    # shellcheck disable=SC1090
    . "$job_file"

    local job_id="${JOB_NAME:-$(basename "$job_file" .job.sh)}"
    local name="$job_id"

    if [ "$JOB_ENABLED" != "1" ] && [ "$force_flag" != "1" ]; then
        echo "--> [JOB: $name] Job is currently disabled. Skipping."
        return 0
    fi

    # Safety Guardrail Check
    if ! runner_check_safety; then
        return 2
    fi

    # Check Trigger condition unless forced
    if [ "$force_flag" != "1" ]; then
        if _is_function mci_check_trigger; then
            if ! mci_check_trigger; then
                name="${name:-$job_id}"
                printf "--> [JOB: ${COLOR_BOLD}${COLOR_MAGENTA}%s${COLOR_RESET}] ${COLOR_DIM}Trigger condition not met (all clear). Use 'mci run %s -f' to force execution.${COLOR_RESET}\n" "$name" "$name"
                return 0
            fi
            name="${name:-$job_id}"
        fi
    fi

    # Dispatch immediate 'TRIGGERED' notification only if explicitly enabled
    if [ "$MCI_NOTIFY_ON_TRIGGER" = "1" ]; then
        local trigger_msg="Trigger condition met. Job $name starting execution..."
        if [ -n "$MCI_OLD_VERSION" ] && [ -n "$MCI_NEW_VERSION" ]; then
            trigger_msg="New version detected (${MCI_OLD_VERSION} -> ${MCI_NEW_VERSION}). Starting upgrade pipeline..."
        fi
        notify_dispatch "TRIGGERED" "$name" "0" "$trigger_msg" "$MCI_OLD_VERSION" "$MCI_NEW_VERSION"
    fi

    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local build_log="${MCI_LOG_DIR}/job_${name}_${timestamp}_RUNNING.log"
    local latest_log="${MCI_LOG_DIR}/latest_${name}.log"
    local global_latest="${MCI_LOG_DIR}/latest.log"

    mkdir -p "$MCI_LOG_DIR" "${MCI_BACKUP_DIR:-/opt/var/merlin-ci/backups}/${name}" 2>/dev/null || true

    printf "${COLOR_YELLOW}================================================================================${COLOR_RESET}\n" | tee "$build_log"
    printf " ${COLOR_BOLD}Merlin-CI Job Execution:${COLOR_RESET} ${COLOR_YELLOW}${COLOR_BOLD}%s${COLOR_RESET}\n" "$name" | tee -a "$build_log"
    printf " ${COLOR_DIM}Description :${COLOR_RESET} %s\n" "${JOB_DESCRIPTION:-No description}" | tee -a "$build_log"
    printf " ${COLOR_DIM}Started at  :${COLOR_RESET} %s\n" "$(date)" | tee -a "$build_log"
    printf " ${COLOR_DIM}Triggered by:${COLOR_RESET} %s\n" "$trigger_source" | tee -a "$build_log"
    printf " ${COLOR_DIM}Router Model:${COLOR_RESET} %s\n" "$(nvram get productid 2>/dev/null || uname -m)" | tee -a "$build_log"
    printf "${COLOR_YELLOW}================================================================================${COLOR_RESET}\n" | tee -a "$build_log"

    local start_epoch
    start_epoch="$(date +%s)"

    # Stage 1: Pre-Execution Backup
    local backup_dir="${MCI_BACKUP_DIR:-/opt/var/merlin-ci/backups}/${name}/${timestamp}"
    mkdir -p "$backup_dir" 2>/dev/null || true

    if _is_function mci_backup; then
        printf "${COLOR_CYAN}--> [STAGE 1]${COLOR_RESET} Creating pre-execution backup...\n" | tee -a "$build_log"
        local b_status_file="/tmp/mci_bstatus_$$"
        (
            mci_backup "$backup_dir"
            echo $? > "$b_status_file"
        ) 2>&1 | tee -a "$build_log"
        local b_status
        b_status=$(cat "$b_status_file" 2>/dev/null || echo 1)
        rm -f "$b_status_file" 2>/dev/null || true

        if [ "$b_status" -ne 0 ]; then
            printf "${COLOR_RED}${COLOR_BOLD}--> [ERROR]${COLOR_RESET} ${COLOR_RED}Backup stage failed! Aborting to prevent inconsistent state.${COLOR_RESET}\n" | tee -a "$build_log"
            _finish_job "$name" "$timestamp" "$build_log" "$latest_log" "$global_latest" "BACKUP_FAILED" 1 "$start_epoch" "$trigger_source" "$force_flag"
            return 1
        fi
        printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Backup stored at: ${COLOR_DIM}%s${COLOR_RESET}\n" "$backup_dir" | tee -a "$build_log"
    else
        printf "${COLOR_DIM}--> [STAGE 1] No pre-execution backup hook (mci_backup) required.${COLOR_RESET}\n" | tee -a "$build_log"
    fi

    # Stage 2: Main Action Execution with live output streaming & renice priority
    local timeout_val="${MCI_JOB_TIMEOUT:-600}"
    local nice_val="${MCI_NICE_LEVEL:-19}"
    printf "${COLOR_CYAN}--> [STAGE 2]${COLOR_RESET} Executing main action ${COLOR_DIM}(nice: %s, timeout: %ss)${COLOR_RESET}...\n" "$nice_val" "$timeout_val" | tee -a "$build_log"

    local run_status=0
    if _is_function mci_run; then
        local r_status_file="/tmp/mci_rstatus_$$"
        (
            renice -n "$nice_val" -p $$ >/dev/null 2>&1 || true
            export CI=1
            export DEBIAN_FRONTEND=noninteractive
            export TERM="${TERM:-xterm-256color}"
            export FORCE_COLOR=1
            mci_run
            echo $? > "$r_status_file"
        ) 2>&1 | tee -a "$build_log"
        run_status=$(cat "$r_status_file" 2>/dev/null || echo 1)
        rm -f "$r_status_file" 2>/dev/null || true
    else
        printf "${COLOR_YELLOW}--> [WARNING] No mci_run function defined in %s.${COLOR_RESET}\n" "$job_file" | tee -a "$build_log"
    fi

    if [ "$run_status" -ne 0 ]; then
        printf "${COLOR_RED}${COLOR_BOLD}--> [ERROR]${COLOR_RESET} ${COLOR_RED}Main action failed with exit code %s!${COLOR_RESET}\n" "$run_status" | tee -a "$build_log"
        if _is_function mci_rollback; then
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} ${COLOR_YELLOW}Initiating automated rollback...${COLOR_RESET}\n" | tee -a "$build_log"
            mci_rollback "$backup_dir" 2>&1 | tee -a "$build_log" || true
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} Rollback completed.\n" | tee -a "$build_log"
        fi
        _finish_job "$name" "$timestamp" "$build_log" "$latest_log" "$global_latest" "ROLLED_BACK" "$run_status" "$start_epoch" "$trigger_source" "$force_flag"
        return "$run_status"
    fi

    # Stage 3: Post-Execution Verification (CI Smoke Test) with live streaming
    local verify_status=0
    if _is_function mci_verify; then
        printf "${COLOR_CYAN}--> [STAGE 3]${COLOR_RESET} Running post-execution CI smoke tests...\n" | tee -a "$build_log"
        local v_status_file="/tmp/mci_vstatus_$$"
        (
            mci_verify
            echo $? > "$v_status_file"
        ) 2>&1 | tee -a "$build_log"
        verify_status=$(cat "$v_status_file" 2>/dev/null || echo 1)
        rm -f "$v_status_file" 2>/dev/null || true

        if [ "$verify_status" -ne 0 ]; then
            printf "${COLOR_RED}${COLOR_BOLD}--> [FAIL]${COLOR_RESET} ${COLOR_RED}Post-execution verification smoke test FAILED (code: %s)!${COLOR_RESET}\n" "$verify_status" | tee -a "$build_log"
            printf "${COLOR_YELLOW}--> State is unhealthy after action. Initiating automated ROLLBACK...${COLOR_RESET}\n" | tee -a "$build_log"
            if _is_function mci_rollback; then
                printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} ${COLOR_YELLOW}Initiating automated rollback...${COLOR_RESET}\n" | tee -a "$build_log"
                mci_rollback "$backup_dir" 2>&1 | tee -a "$build_log" || true
                printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} Rollback completed.\n" | tee -a "$build_log"
            fi
            _finish_job "$name" "$timestamp" "$build_log" "$latest_log" "$global_latest" "ROLLED_BACK" "$verify_status" "$start_epoch" "$trigger_source" "$force_flag"
            return "$verify_status"
        fi
        printf "${COLOR_GREEN}--> [VERIFY]${COLOR_RESET} Verification checks passed successfully! ${COLOR_GREEN}${COLOR_BOLD}[PASS]${COLOR_RESET}\n" | tee -a "$build_log"
    else
        printf "${COLOR_DIM}--> [STAGE 3] No post-execution verification hook (mci_verify) defined.${COLOR_RESET}\n" | tee -a "$build_log"
    fi

    # Stage 4: Success
    _finish_job "$name" "$timestamp" "$build_log" "$latest_log" "$global_latest" "SUCCESS" 0 "$start_epoch" "$trigger_source" "$force_flag"

    runner_rotate_backups "$name"
    runner_rotate_logs

    return 0
}

_finish_job() {
    local name="$1"
    local timestamp="$2"
    local build_log="$3"
    local latest_log="$4"
    local global_latest="$5"
    local status="$6"
    local exit_code="$7"
    local start_epoch="$8"
    local trigger_source="${9:-manual}"
    local force_flag="${10:-0}"

    local end_epoch
    end_epoch="$(date +%s)"
    local duration=$((end_epoch - start_epoch))

    local badge_color="${COLOR_GREEN}"
    [ "$status" = "FAILED" ] && badge_color="${COLOR_RED}"
    [ "$status" = "ROLLED_BACK" ] && badge_color="${COLOR_YELLOW}"

    printf "${badge_color}================================================================================${COLOR_RESET}\n" | tee -a "$build_log"
    printf " ${COLOR_BOLD}Merlin-CI Job %s finished with status: ${badge_color}${COLOR_BOLD}%s${COLOR_RESET} (Exit Code: %s)\n" "$name" "$status" "$exit_code" | tee -a "$build_log"
    printf " ${COLOR_DIM}Duration: %ss | Completed at: %s${COLOR_RESET}\n" "$duration" "$(date)" | tee -a "$build_log"
    printf "${badge_color}================================================================================${COLOR_RESET}\n" | tee -a "$build_log"

    local final_log="${MCI_LOG_DIR}/job_${name}_${timestamp}_${status}.log"
    mv -f "$build_log" "$final_log"
    cp -f "$final_log" "$latest_log" 2>/dev/null || ln -sf "$final_log" "$latest_log" 2>/dev/null || true
    cp -f "$final_log" "$global_latest" 2>/dev/null || ln -sf "$final_log" "$global_latest" 2>/dev/null || true

    echo "$status" > "${MCI_LOG_DIR}/last_run_status_${name}"
    echo "$status" > "${MCI_LOG_DIR}/last_run_status"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "${MCI_LOG_DIR}/last_run_time_${name}"
    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "${MCI_LOG_DIR}/last_run_time"

    local is_healing_event=0
    # A healing event occurs when a watchdog job triggered autonomously on an anomaly and restored nominal state
    if [ "${JOB_TYPE:-}" = "watchdog" ] && [ "$force_flag" != "1" ] && [ "$status" = "SUCCESS" ]; then
        is_healing_event=1
    fi

    # Record run in 24-hour activity log for morning daily digest aggregation
    local daily_log="${MCI_LOG_DIR}/daily_activity.log"
    mkdir -p "$(dirname "$daily_log")" 2>/dev/null || true
    local now_time
    now_time="$(date '+%H:%M:%S' 2>/dev/null || date)"
    if [ "$status" = "SUCCESS" ]; then
        if [ "$is_healing_event" = "1" ]; then
            printf "[%s] [HEALED] %s (Auto-repaired in %ss)\n" "$now_time" "$name" "$duration" >> "$daily_log" 2>/dev/null || true
        else
            printf "[%s] [PASS] %s (Completed in %ss)\n" "$now_time" "$name" "$duration" >> "$daily_log" 2>/dev/null || true
        fi
    else
        printf "[%s] [%s] %s (Exit code: %s)\n" "$now_time" "$status" "$name" "$exit_code" >> "$daily_log" 2>/dev/null || true
    fi

    if _is_function mci_notify; then
        mci_notify "$status" "$duration" >> "$final_log" 2>&1 || true
    fi

    # 1. Failure / Rollback: ALWAYS dispatch immediate alert email
    if [ "$status" = "FAILED" ] || [ "$status" = "ROLLED_BACK" ]; then
        if [ "${MCI_NOTIFY_ON_FAILURE:-1}" = "1" ]; then
            local log_summary
            log_summary="$(tail -n 60 "$final_log" 2>/dev/null)"
            notify_dispatch "$status" "$name" "$duration" "$log_summary" "$MCI_OLD_VERSION" "$MCI_NEW_VERSION"
        fi
        return 0
    fi

    # 2. Watchdog Needed Healing: ALWAYS dispatch immediate alert email
    if [ "$is_healing_event" = "1" ]; then
        if [ "${MCI_NOTIFY_ON_HEAL:-1}" = "1" ]; then
            local log_summary
            log_summary="$(tail -n 60 "$final_log" 2>/dev/null)"
            notify_dispatch "HEALED" "$name" "$duration" "$log_summary" "$MCI_OLD_VERSION" "$MCI_NEW_VERSION"
        fi
        return 0
    fi

    # 3. Routine Pass / Success:
    # Silent by default (MCI_NOTIFY_ON_SUCCESS=0).
    # All passed info is batched into daily_activity.log and delivered in the single morning digest email!
    if [ "${JOB_NOTIFY_SUCCESS:-}" = "0" ] || [ "${MCI_NOTIFY_ON_SUCCESS:-0}" = "0" ]; then
        return 0
    fi

    local log_summary
    log_summary="$(tail -n 60 "$final_log" 2>/dev/null)"
    notify_dispatch "$status" "$name" "$duration" "$log_summary" "$MCI_OLD_VERSION" "$MCI_NEW_VERSION"
}
