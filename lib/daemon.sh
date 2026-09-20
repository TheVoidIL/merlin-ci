#!/bin/sh
# ==============================================================================
# Merlin-CI: Scheduler, Cron (cru) & Trigger Evaluator Library (lib/daemon.sh)
# ==============================================================================

MCI_PID_FILE="/tmp/merlin-ci.pid"
MCI_DAEMON_LOG="${MCI_LOG_DIR:-/tmp/merlin-ci/logs}/daemon.log"
MCI_CRON_WATCHDOG_TAG="MCI_Watchdog"
MCI_CRON_DAILY_TAG="MCI_Daily"
MCI_CRON_LEGACY_TAG="MerlinCI"

# Check enabled jobs and execute any whose trigger conditions are met
daemon_check_all_jobs() {
    local filter_type="${1:-all}"
    local force_all="${2:-0}"
    local jobs_dir="${MCI_JOBS_DIR:-/jffs/addons/merlin-ci/jobs}"
    [ ! -d "$jobs_dir" ] && jobs_dir="./jobs"

    if [ ! -d "$jobs_dir" ]; then
        echo "--> [SCHEDULER] No jobs directory found at $jobs_dir."
        return 1
    fi

    local banner_label="All Jobs"
    case "$filter_type" in
        watchdog) banner_label="Tier 1: Watchdogs & Self-Healing" ;;
        daily|maintenance) banner_label="Tier 2: Daily Maintenance & Upgrades" ;;
    esac

    printf "${COLOR_CYAN}================================================================================${COLOR_RESET}\n"
    printf " ${COLOR_BOLD}%s${COLOR_RESET} (${COLOR_CYAN}%s${COLOR_RESET})\n" "Merlin-CI Trigger Evaluation Check" "$banner_label"
    printf " ${COLOR_DIM}Started at:${COLOR_RESET} %s\n" "$(date)"
    printf " ${COLOR_DIM}Scanning directory:${COLOR_RESET} %s\n" "$jobs_dir"
    printf "${COLOR_CYAN}================================================================================${COLOR_RESET}\n"

    local triggered_count=0

    for job in "$jobs_dir"/*.job.sh; do
        if [ -f "$job" ]; then
            local job_name
            job_name="$(basename "$job" .job.sh)"

            # Check job type filtering
            local jtype
            jtype="$(grep -m1 -E '^JOB_TYPE=' "$job" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ' || echo "daily")"
            [ -z "$jtype" ] && jtype="daily"

            if [ "$filter_type" = "watchdog" ] && [ "$jtype" != "watchdog" ]; then
                continue
            fi
            if [ "$filter_type" = "daily" ] && [ "$jtype" = "watchdog" ]; then
                continue
            fi

            local tier_badge="${COLOR_CYAN}[WATCHDOG]${COLOR_RESET}"
            [ "$jtype" = "daily" ] && tier_badge="${COLOR_BLUE}[DAILY]${COLOR_RESET}"

            printf "\n${COLOR_CYAN}-->${COLOR_RESET} Scanning job: ${COLOR_BOLD}${COLOR_MAGENTA}%-26s${COLOR_RESET} %s\n" "$job_name" "$tier_badge"

            # Run in subshell to isolate variables and functions
            (
                runner_execute_job "$job" "trigger_eval" "$force_all"
            )
            local status=$?
            if [ "$status" -eq 0 ]; then
                triggered_count=$((triggered_count + 1))
            fi
        fi
    done

    printf "\n${COLOR_GREEN}--> [SCHEDULER]${COLOR_RESET} Evaluation complete. Checked configured ${COLOR_CYAN}%s${COLOR_RESET}.\n" "$banner_label"
    return 0
}

# --- Asuswrt-Merlin 'cru' Cron Management ---

_get_cru() {
    if command -v cru >/dev/null 2>&1; then
        echo "cru"
    elif [ -x "/usr/sbin/cru" ]; then
        echo "/usr/sbin/cru"
    else
        return 1
    fi
}

daemon_setup_cron() {
    local watchdog_sched="${1:-*/15 * * * *}" # Default: Every 15 minutes
    local daily_sched="${2:-0 4 * * *}"       # Default: Daily at 4:00 AM
    local exec_bin="/jffs/scripts/mci"
    [ ! -x "$exec_bin" ] && exec_bin="$(pwd)/merlin-ci.sh"

    local cru_bin
    cru_bin="$(_get_cru 2>/dev/null || true)"
    if [ -n "$cru_bin" ]; then
        echo "--> [CRON] Setting up Tiered Merlin-CI schedules in Asuswrt-Merlin 'cru'..."

        # Remove legacy single cron tags if present
        "$cru_bin" d "$MCI_CRON_LEGACY_TAG" 2>/dev/null || true
        "$cru_bin" d "MerlinCI_SwapWatch" 2>/dev/null || true

        # Tier 1: Fast Watchdogs (WAN, DNS, Swap, Storage, SSH)
        echo "--> [CRON] Registering Tier 1: Watchdogs ($watchdog_sched)..."
        "$cru_bin" a "$MCI_CRON_WATCHDOG_TAG" "$watchdog_sched $exec_bin check watchdog >/dev/null 2>&1"

        # Tier 2: Daily Maintenance (AMTM, Entware, Cert, Vault, Firewall)
        echo "--> [CRON] Registering Tier 2: Daily Maintenance ($daily_sched)..."
        "$cru_bin" a "$MCI_CRON_DAILY_TAG" "$daily_sched $exec_bin check daily >/dev/null 2>&1"

        echo "--> [CRON] Registered successfully. Current active crontab:"
        "$cru_bin" l | grep -E "MCI_" || true
    else
        echo "--> [WARNING] 'cru' command not found. Add these to your system crontab:"
        echo "    $watchdog_sched $exec_bin check watchdog"
        echo "    $daily_sched $exec_bin check daily"
    fi
}

daemon_remove_cron() {
    local cru_bin
    cru_bin="$(_get_cru 2>/dev/null || true)"
    if [ -n "$cru_bin" ]; then
        echo "--> [CRON] Removing Merlin-CI schedules from Asuswrt-Merlin 'cru'..."
        "$cru_bin" d "$MCI_CRON_WATCHDOG_TAG" 2>/dev/null || true
        "$cru_bin" d "$MCI_CRON_DAILY_TAG" 2>/dev/null || true
        "$cru_bin" d "$MCI_CRON_LEGACY_TAG" 2>/dev/null || true
        "$cru_bin" d "MerlinCI_SwapWatch" 2>/dev/null || true
        echo "--> [CRON] Removed all Merlin-CI cron jobs."
    fi
}

daemon_cron_status() {
    local cru_bin
    cru_bin="$(_get_cru 2>/dev/null || true)"
    if [ -n "$cru_bin" ]; then
        local w_entry d_entry l_entry
        w_entry="$($cru_bin l 2>/dev/null | grep "$MCI_CRON_WATCHDOG_TAG" || true)"
        d_entry="$($cru_bin l 2>/dev/null | grep "$MCI_CRON_DAILY_TAG" || true)"
        l_entry="$($cru_bin l 2>/dev/null | grep "$MCI_CRON_LEGACY_TAG" || true)"

        if [ -n "$w_entry" ] && [ -n "$d_entry" ]; then
            printf "Tiered Active (Watchdogs + Daily)"
            return 0
        elif [ -n "$w_entry" ] || [ -n "$d_entry" ] || [ -n "$l_entry" ]; then
            printf "Active"
            return 0
        else
            printf "Not scheduled"
            return 1
        fi
    fi
    printf "Disabled (no cru)"
    return 1
}

# --- Background Daemon Worker (Alternative to Cron) ---

daemon_is_running() {
    if [ -f "$MCI_PID_FILE" ]; then
        local pid
        pid="$(cat "$MCI_PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

daemon_stop() {
    if daemon_is_running; then
        local pid
        pid="$(cat "$MCI_PID_FILE" 2>/dev/null)"
        echo "--> [DAEMON] Stopping Merlin-CI background worker (PID: $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL "$pid" 2>/dev/null || true
        rm -f "$MCI_PID_FILE"
        echo "--> [DAEMON] Stopped."
    else
        echo "--> [DAEMON] Daemon is not running."
        rm -f "$MCI_PID_FILE" 2>/dev/null || true
    fi
}

daemon_loop() {
    local interval="${MCI_CHECK_INTERVAL:-3600}" # Default: Check every 1 hour

    echo "================================================================================" >> "$MCI_DAEMON_LOG"
    echo " Merlin-CI Background Worker Started at $(date)" >> "$MCI_DAEMON_LOG"
    echo " Interval: ${interval}s | PID: $$" >> "$MCI_DAEMON_LOG"
    echo "================================================================================" >> "$MCI_DAEMON_LOG"

    while true; do
        daemon_check_all_jobs 0 >> "$MCI_DAEMON_LOG" 2>&1
        sleep "$interval"
    done
}

daemon_start() {
    if daemon_is_running; then
        echo "--> [DAEMON] Already running (PID: $(cat "$MCI_PID_FILE"))."
        return 0
    fi

    mkdir -p "$(dirname "$MCI_PID_FILE")" "$MCI_LOG_DIR" 2>/dev/null || true

    echo "--> [DAEMON] Starting background trigger evaluator..."
    (
        daemon_loop
    ) >/dev/null 2>&1 &
    
    local daemon_pid=$!
    echo "$daemon_pid" > "$MCI_PID_FILE"
    sleep 1

    if daemon_is_running; then
        echo "--> [DAEMON] Started successfully (PID: $daemon_pid)."
    else
        echo "--> [ERROR] Failed to start daemon. Check $MCI_DAEMON_LOG."
        return 1
    fi
}
