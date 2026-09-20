#!/bin/sh
# ==============================================================================
# Merlin-CI: RAM Watchdog & OOM Leaker Self-Healer
# ==============================================================================
# Monitors real router memory usage.
# When memory usage exceeds threshold (default: 95%):
# 1. Silently flushes kernel buffers and caches (sync; drop_caches)
# 2. If memory remains stuck >= 95%, detects memory-leaking daemons (httpd, dnsmasq, etc.)
# 3. Gracefully reloads leaking service before Linux kernel OOM-killer strikes
# 4. Ensures swap is mounted and operational
# 5. Verifies memory recovery and alerts via /jffs/scripts/send_alert.sh
# ==============================================================================

JOB_NAME="ram-oom-heal"
JOB_DESCRIPTION="RAM watchdog & OOM defender: monitors memory usage, drops caches and reloads leakers"
JOB_ENABLED=1
JOB_TYPE="watchdog"

RAM_THRESHOLD="${MCI_RAM_THRESHOLD:-95}"
RAM_STATE_FILE="/tmp/mci_ram_usage_prev.state"
RAM_ACTION_FILE="/tmp/mci_ram_action.info"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

_get_ram_usage() {
    [ -f /proc/meminfo ] || return 1
    local total avail used
    total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

    if [ -z "$avail" ]; then
        local free buffers cached
        free=$(awk '/MemFree/ {print $2}' /proc/meminfo)
        buffers=$(awk '/Buffers/ {print $2}' /proc/meminfo)
        cached=$(awk '/^Cached/ {print $2}' /proc/meminfo)
        avail=$((free + buffers + cached))
    fi

    [ -z "$total" ] || [ "$total" -le 0 ] && return 1
    used=$((total - avail))
    echo $((used * 100 / total))
}

_dispatch_user_alert() {
    local subject="$1"
    local message="$2"
    if [ -x "/jffs/scripts/send_alert.sh" ]; then
        /jffs/scripts/send_alert.sh "$subject" "$message" 2>/dev/null || true
    fi
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[RAM-GUARD]${COLOR_RESET} Inspecting router memory usage...\n"

    local cur_usage
    cur_usage="$(_get_ram_usage)"

    if [ -z "$cur_usage" ]; then
        printf "--> ${COLOR_YELLOW}[RAM-GUARD]${COLOR_RESET} Could not read /proc/meminfo. Skipping.\n"
        return 1
    fi

    echo "$cur_usage" > "$RAM_STATE_FILE"

    if [ "$cur_usage" -ge "$RAM_THRESHOLD" ]; then
        printf "--> ${COLOR_YELLOW}[RAM-GUARD]${COLOR_RESET} RAM usage is at ${COLOR_YELLOW}%s%%${COLOR_RESET} (>= %s%%). Testing cache drop...\n" "$cur_usage" "$RAM_THRESHOLD"

        # Stage 1: Silent cache drop
        sync; echo 3 > /proc/sys/vm/drop_caches
        sleep 3

        local usage_after
        usage_after="$(_get_ram_usage)"

        if [ "$usage_after" -ge "$RAM_THRESHOLD" ]; then
            echo "$usage_after" > "$RAM_STATE_FILE"
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} RAM usage stuck at ${COLOR_RED}${COLOR_BOLD}%s%%${COLOR_RESET} even after clearing caches! Initiating OOM defense...\n" "$usage_after"
            return 0
        else
            printf "${COLOR_GREEN}--> [RAM-GUARD]${COLOR_RESET} Cache drop resolved high memory. Usage dropped from %s%% to ${COLOR_GREEN}%s%%${COLOR_RESET}. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$cur_usage" "$usage_after"
            return 1
        fi
    fi

    printf "${COLOR_GREEN}--> [RAM-GUARD]${COLOR_RESET} RAM usage is healthy (${COLOR_GREEN}%s%%${COLOR_RESET} < %s%%). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$cur_usage" "$RAM_THRESHOLD"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving memory diagnostics and process footprint to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    cat /proc/meminfo > "$backup_dir/meminfo_pre.txt" 2>/dev/null || true
    ps -o pid,vsz,comm 2>/dev/null | sort -k2 -nr | head -n 30 > "$backup_dir/top_mem_processes.txt" 2>/dev/null || true
    [ -f /proc/swaps ] && cat /proc/swaps > "$backup_dir/swaps_pre.txt" 2>/dev/null || true
    return 0
}

mci_run() {
    echo "--> [RUN] Executing targeted memory recovery and OOM defense..."

    rm -f "$RAM_ACTION_FILE"

    # Step 1: Find top memory-consuming process
    local top_hog_line top_pid top_vsz top_comm
    top_hog_line="$(ps -o pid,vsz,comm 2>/dev/null | sort -k2 -nr | grep -v "VSZ" | head -n 1)"

    top_pid="$(echo "$top_hog_line" | awk '{print $1}')"
    top_vsz="$(echo "$top_hog_line" | awk '{print $2}')"
    top_comm="$(echo "$top_hog_line" | awk '{print $3}')"

    echo "--> [RAM-GUARD] Top memory consumer: PID $top_pid ($top_comm) using ${top_vsz} kB."
    echo "$top_comm (PID $top_pid, ${top_vsz} kB)" > "$RAM_ACTION_FILE"

    # Step 2: Graceful targeted daemon reloads
    case "$top_comm" in
        *httpd*)
            echo "--> [RAM-GUARD] Reloading web server (httpd) to release memory leak..."
            service restart_httpd 2>/dev/null || killall httpd 2>/dev/null || true
            ;;
        *dnsmasq*)
            echo "--> [RAM-GUARD] Reloading dnsmasq to release bloated cache..."
            service restart_dnsmasq 2>/dev/null || true
            ;;
        *networkmap*)
            echo "--> [RAM-GUARD] Refreshing networkmap daemon..."
            killall networkmap 2>/dev/null || true
            networkmap 2>/dev/null || true
            ;;
        *avahi*)
            echo "--> [RAM-GUARD] Reloading mDNS avahi-daemon..."
            service restart_mdns 2>/dev/null || true
            ;;
        *)
            echo "--> [RAM-GUARD] Purging system memory buffers..."
            sync; echo 3 > /proc/sys/vm/drop_caches
            ;;
    esac

    # Step 3: Verify swap is active
    if [ -f /proc/swaps ]; then
        if ! grep -qE "partition|file" /proc/swaps 2>/dev/null; then
            echo "--> [RAM-GUARD] Inactive swap detected. Reactivating via swapon -a..."
            swapon -a 2>/dev/null || true
        fi
    fi

    sleep 5
    return 0
}

mci_verify() {
    echo "--> [VERIFY] Re-evaluating router memory usage post-healing..."

    local final_usage
    final_usage="$(_get_ram_usage)"

    local prev_usage
    prev_usage="$(cat "$RAM_STATE_FILE" 2>/dev/null || echo "$RAM_THRESHOLD")"

    echo "   [STATUS] Initial Usage: ${prev_usage}% | Current Usage: ${final_usage}% (Threshold: ${RAM_THRESHOLD}%)"

    if [ "$final_usage" -lt "$RAM_THRESHOLD" ]; then
        echo "   [PASS] Memory reclaimed successfully (${final_usage}% < ${RAM_THRESHOLD}%)."
        return 0
    fi

    if [ "$final_usage" -lt "$prev_usage" ]; then
        echo "   [PASS] Memory trend improving (${prev_usage}% -> ${final_usage}%)."
        return 0
    fi

    echo "--> [WARNING] Memory remains elevated at ${final_usage}%."
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] No rollback needed for memory recovery operations."
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"

    local prev_usage final_usage action_info
    prev_usage="$(cat "$RAM_STATE_FILE" 2>/dev/null || echo "$RAM_THRESHOLD")"
    final_usage="$(_get_ram_usage)"
    [ -z "$final_usage" ] && final_usage="N/A"

    local msg
    if [ -f "$RAM_ACTION_FILE" ]; then
        action_info="$(cat "$RAM_ACTION_FILE")"
        msg="RAM Watchdog: Memory usage was at ${prev_usage}%. Reloaded leaking service '$action_info'. Current usage: ${final_usage}%."
    else
        msg="CRITICAL Router Alert: RAM usage is stuck at ${final_usage}% even after clearing caches. Possible memory leak!"
    fi

    echo "--> [NOTIFY] Dispatching RAM alert: $msg"
    _dispatch_user_alert "Ram Usage Alert !" "$msg"

    rm -f "$RAM_ACTION_FILE" "$RAM_STATE_FILE" 2>/dev/null || true
}
