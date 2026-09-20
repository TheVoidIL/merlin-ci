#!/bin/sh
# ==============================================================================
# Merlin-CI: CPU Thermal Guard & Runaway Process Healer
# ==============================================================================
# Monitors ASUS RT-BE92U CPU temperature using the native BPCM thermal sensor.
# When temperature exceeds threshold (default: 75°C):
# 1. Scans for rogue/runaway CPU-hogging processes
# 2. Deprioritizes or terminates runaway processes (preserving critical daemons)
# 3. Flushes disk and page caches (sync; drop_caches)
# 4. Verifies temperature cooldown
# 5. Dispatches formatted alert via /jffs/scripts/send_alert.sh
# ==============================================================================

JOB_NAME="cpu-thermal-heal"
JOB_DESCRIPTION="Thermal watchdog: monitors RT-BE92U CPU temp, mitigates runaway hogs and cools SoC"
JOB_ENABLED=1
JOB_TYPE="watchdog"

TEMP_THRESHOLD="${MCI_TEMP_THRESHOLD:-75}"
RUNAWAY_FILE="/tmp/mci_cpu_runaway.info"
TEMP_STATE_FILE="/tmp/mci_cpu_temp_prev.state"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

_get_cpu_temp() {
    if [ -f "/sys/power/bpcm/cpu_temp" ]; then
        cat /sys/power/bpcm/cpu_temp 2>/dev/null | cut -d' ' -f2 | cut -d'.' -f1
    elif [ -f "/proc/dmu/temperature" ]; then
        awk '{print int($1)}' /proc/dmu/temperature 2>/dev/null
    fi
}

_dispatch_user_alert() {
    local subject="$1"
    local message="$2"
    if [ -x "/jffs/scripts/send_alert.sh" ]; then
        /jffs/scripts/send_alert.sh "$subject" "$message" 2>/dev/null || true
    fi
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[THERMAL-GUARD]${COLOR_RESET} Inspecting RT-BE92U CPU temperature sensor...\n"

    local cur_temp
    cur_temp="$(_get_cpu_temp)"

    if [ -z "$cur_temp" ]; then
        printf "--> ${COLOR_YELLOW}[THERMAL-GUARD]${COLOR_RESET} Unable to read CPU temperature sensor. Skipping.\n"
        return 1
    fi

    echo "$cur_temp" > "$TEMP_STATE_FILE"

    if [ "$cur_temp" -gt "$TEMP_THRESHOLD" ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} CPU temperature (${COLOR_RED}${COLOR_BOLD}%s°C${COLOR_RESET}) exceeds threshold (%s°C)!\n" "$cur_temp" "$TEMP_THRESHOLD"
        return 0
    fi

    printf "${COLOR_GREEN}--> [THERMAL-GUARD]${COLOR_RESET} CPU temperature is normal (${COLOR_GREEN}%s°C${COLOR_RESET} <= %s°C). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$cur_temp" "$TEMP_THRESHOLD"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving system load and process table snapshot to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    top -b -n 1 2>/dev/null | head -n 35 > "$backup_dir/top_pre_mitigation.txt" 2>/dev/null || true
    ps 2>/dev/null > "$backup_dir/ps_pre_mitigation.txt" 2>/dev/null || true
    [ -f /proc/loadavg ] && cp /proc/loadavg "$backup_dir/loadavg_pre.txt" 2>/dev/null || true
    return 0
}

mci_run() {
    echo "--> [RUN] Initiating active thermal mitigation..."

    rm -f "$RUNAWAY_FILE"

    # Step 1: Detect runaway processes using top (>40% CPU, skipping kernel/init)
    local runaway_pid="" runaway_comm="" runaway_cpu=""
    local top_sample
    top_sample="$(top -b -n 1 2>/dev/null)"

    runaway_pid="$(echo "$top_sample" | awk 'NR>4 && $7 > 40 && $1 > 10 {print $1; exit}')"

    if [ -n "$runaway_pid" ]; then
        runaway_comm="$(ps 2>/dev/null | grep -E "^[ ]*$runaway_pid " | awk '{print $NF}')"
        runaway_cpu="$(echo "$top_sample" | awk -v p="$runaway_pid" '$1 == p {print $7; exit}')"

        [ -z "$runaway_comm" ] && runaway_comm="pid-$runaway_pid"
        echo "--> [THERMAL-GUARD] Identified runaway process: PID $runaway_pid ($runaway_comm) using ${runaway_cpu}% CPU."
        echo "$runaway_pid $runaway_comm $runaway_cpu" > "$RUNAWAY_FILE"

        # Check if process is critical router infrastructure
        case "$runaway_comm" in
            *init*|*ksoftirqd*|*kworker*|*dropbear*|*dnsmasq*)
                echo "--> [THERMAL-GUARD] Process is protected system daemon. Deprioritizing via renice 19..."
                renice 19 -p "$runaway_pid" 2>/dev/null || true
                ;;
            *)
                echo "--> [THERMAL-GUARD] Terminating runaway process PID $runaway_pid ($runaway_comm)..."
                kill -TERM "$runaway_pid" 2>/dev/null || true
                sleep 2
                kill -KILL "$runaway_pid" 2>/dev/null || true
                ;;
        esac
    else
        echo "--> [THERMAL-GUARD] No single process exceeding 40% CPU identified. General load mitigation."
    fi

    # Step 2: Flush filesystem and kernel memory buffers to reduce I/O churn
    echo "--> [THERMAL-GUARD] Flushing disk and memory caches..."
    sync; echo 3 > /proc/sys/vm/drop_caches

    # Step 3: Stabilization pause
    echo "--> [THERMAL-GUARD] Waiting 15 seconds for SoC thermal dissipation..."
    sleep 15
    return 0
}

mci_verify() {
    echo "--> [VERIFY] Inspecting post-mitigation CPU temperature..."

    local new_temp
    new_temp="$(_get_cpu_temp)"

    local prev_temp
    prev_temp="$(cat "$TEMP_STATE_FILE" 2>/dev/null || echo "$TEMP_THRESHOLD")"

    if [ -n "$new_temp" ]; then
        echo "   [STATUS] Initial Temp: ${prev_temp}°C | Current Temp: ${new_temp}°C (Threshold: ${TEMP_THRESHOLD}°C)"
        if [ "$new_temp" -le "$TEMP_THRESHOLD" ]; then
            echo "   [PASS] Temperature successfully returned to safe range (${new_temp}°C <= ${TEMP_THRESHOLD}°C)."
            return 0
        fi

        if [ "$new_temp" -lt "$prev_temp" ]; then
            echo "   [PASS] Thermal trend cooling down (${prev_temp}°C -> ${new_temp}°C)."
            return 0
        fi
    fi

    echo "--> [WARNING] CPU temperature remains elevated at ${new_temp}°C."
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] No rollback necessary for thermal mitigations."
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"

    local prev_temp new_temp runaway_info
    prev_temp="$(cat "$TEMP_STATE_FILE" 2>/dev/null || echo "$TEMP_THRESHOLD")"
    new_temp="$(_get_cpu_temp)"
    [ -z "$new_temp" ] && new_temp="N/A"

    local msg="Alert: RT-BE92U High Temp! Initial: ${prev_temp}°C (Threshold: ${TEMP_THRESHOLD}°C)."

    if [ -f "$RUNAWAY_FILE" ]; then
        runaway_info="$(cat "$RUNAWAY_FILE")"
        msg="$msg Runaway process mitigated: $runaway_info."
    fi

    msg="$msg Post-mitigation temp: ${new_temp}°C."

    echo "--> [NOTIFY] Dispatching thermal alert: $msg"
    _dispatch_user_alert "CPU Alert !" "$msg"

    rm -f "$RUNAWAY_FILE" "$TEMP_STATE_FILE" 2>/dev/null || true
}
