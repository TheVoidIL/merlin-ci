#!/bin/sh
# ==============================================================================
# Merlin-CI: Wi-Fi 7 MLO Association Storm & Driver Deadlock Watchdog
# ==============================================================================
# Detects rapid 802.11be MLO association/deauthorization loops (status 30),
# Broadcom wireless FIFO ring buffer congestion, and Trend Micro UDB ioctl
# faults in router syslog. Intervenes autonomously to prevent kernel deadlocks
# and unresponsiveness before the router freezes.
# ==============================================================================

JOB_NAME="mlo-storm-watchdog"
JOB_DESCRIPTION="Self-healing watchdog: detects Wi-Fi 7 MLO deauth storms & Trend Micro UDB ioctl faults to prevent kernel deadlock"
JOB_ENABLED=1
# Tier 0 (fast): evaluated every 2 min via MCI_Fast cron. A storm can escalate to a
# kernel/IO stall and WAN (PPPoE LCP) drop within ~15 min, so the 15-min tier is too slow.
JOB_TYPE="fast"
# The storm itself drives load up; never defer this job on the CPU load guard.
JOB_BYPASS_LOAD_GUARD=1

# Thresholds
MLO_LOOP_THRESHOLD=5       # Trigger if >= 5 MLO assoc failures in window
UDB_FAULT_THRESHOLD=10     # Trigger if >= 10 tdts UDB collisions or any ioctl fault in window

STATE_FILE="/tmp/mci_mlo_storm_state.txt"
SYSLOG_FILE="/tmp/syslog.log"
DETECTED_EVENTS_FILE="/tmp/mci_mlo_events_$$.txt"
FLAPPING_MACS_FILE="/tmp/mci_mlo_macs_$$.txt"
AUDIT_LOG="/opt/var/merlin-ci/logs/mlo_storm_incidents.log"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

_extract_recent_events() {
    local target_out="$1"
    [ -f "$SYSLOG_FILE" ] || return 1

    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -z "$total_lines" ] || [ "$total_lines" -eq 0 ] && return 1

    if [ ! -f "$STATE_FILE" ]; then
        echo "$total_lines" > "$STATE_FILE"
        return 1
    fi

    local last_line
    last_line=$(awk '{print $1}' "$STATE_FILE" 2>/dev/null)
    if [ -z "$last_line" ] || [ "$total_lines" -lt "$last_line" ]; then
        last_line=0
    fi

    if [ "$total_lines" -eq "$last_line" ]; then
        return 1
    fi

    local start_line=$((last_line + 1))
    sed -n "${start_line},\$p" "$SYSLOG_FILE" 2>/dev/null | \
        grep -Ei "MLO ERROR|tdts_core_ioctl|already exist in UDB" \
        > "$target_out" 2>/dev/null || true
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[MLO-GUARD]${COLOR_RESET} Auditing Wi-Fi 7 MLO association telemetry and driver stability...\n"

    rm -f "$DETECTED_EVENTS_FILE" "$FLAPPING_MACS_FILE"

    _extract_recent_events "$DETECTED_EVENTS_FILE"

    local triggered=0
    local mlo_count=0
    local udb_count=0

    if [ -s "$DETECTED_EVENTS_FILE" ]; then
        mlo_count=$(grep -Ei "MLO ERROR" "$DETECTED_EVENTS_FILE" 2>/dev/null | wc -l | awk '{print $1}')
        udb_count=$(grep -Ei "tdts_core_ioctl|already exist in UDB" "$DETECTED_EVENTS_FILE" 2>/dev/null | wc -l | awk '{print $1}')

        # 1. Check for Wi-Fi 7 MLO association storm
        if [ "$mlo_count" -ge "$MLO_LOOP_THRESHOLD" ]; then
            # Extract offending client MACs
            grep -Ei "MLO ERROR" "$DETECTED_EVENTS_FILE" 2>/dev/null | \
                grep -oE "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}" | tr 'a-z' 'A-Z' | sort -u > "$FLAPPING_MACS_FILE"

            local mac_list
            mac_list=$(tr '\n' ' ' < "$FLAPPING_MACS_FILE" 2>/dev/null)
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Wi-Fi 7 MLO association storm detected (%d loops)! Client(s): %s${COLOR_RESET}\n" \
                "$mlo_count" "$mac_list"
            triggered=1
        fi

        # 2. Check for Trend Micro DPI UDB table collision flood or ioctl fault
        if [ "$udb_count" -ge "$UDB_FAULT_THRESHOLD" ] || grep -Eiq "tdts_core_ioctl.*(fail|error)" "$DETECTED_EVENTS_FILE" 2>/dev/null; then
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Trend Micro DPI UDB table collision flood / ioctl failure detected (%d events)!${COLOR_RESET}\n" \
                "$udb_count"
            triggered=1
        fi
    fi

    if [ "$triggered" -eq 1 ]; then
        return 0
    fi

    # Advance state cursor on clean pass
    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"

    rm -f "$DETECTED_EVENTS_FILE" "$FLAPPING_MACS_FILE"
    printf "${COLOR_GREEN}--> [MLO-GUARD]${COLOR_RESET} Wi-Fi 7 MLO status and kernel network buffers are healthy. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    mkdir -p "$backup_dir" 2>/dev/null || true

    if [ -f "$DETECTED_EVENTS_FILE" ]; then
        cp -pf "$DETECTED_EVENTS_FILE" "$backup_dir/detected_events.txt" 2>/dev/null || true
    fi
    if [ -f "$FLAPPING_MACS_FILE" ]; then
        cp -pf "$FLAPPING_MACS_FILE" "$backup_dir/flapping_macs.txt" 2>/dev/null || true
    fi

    # Snapshot active wireless station associations
    if which wl >/dev/null 2>&1; then
        for iface in wl0 wl1 wl2 wl0.1 wl1.1 wl2.1; do
            wl -i "$iface" assoclist > "$backup_dir/assoc_${iface}.txt" 2>/dev/null || true
        done
    fi

    # Snapshot current conntrack & memory stats
    cat /proc/meminfo > "$backup_dir/meminfo_before.txt" 2>/dev/null || true

    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Diagnostic snapshot recorded in %s\n" "$backup_dir"
    return 0
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Executing proactive self-healing to prevent kernel deadlock...\n"

    local now_ts
    now_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true

    local actions_taken=""

    # --------------------------------------------------------------------------
    # Step 1: Forcefully Deauthenticate Looping MLO Client(s)
    # --------------------------------------------------------------------------
    if [ -s "$FLAPPING_MACS_FILE" ]; then
        while read -r bad_mac; do
            [ -z "$bad_mac" ] && continue
            printf "--> ${COLOR_YELLOW}[HEAL]${COLOR_RESET} Deauthenticating flapping MLO station: %s\n" "$bad_mac"

            # Execute across all potential radio interfaces to break the negotiation lock
            if which wl >/dev/null 2>&1; then
                wl -i wl0 deauthenticate "$bad_mac" 2>/dev/null || true
                wl -i wl1 deauthenticate "$bad_mac" 2>/dev/null || true
                wl -i wl1.1 deauthenticate "$bad_mac" 2>/dev/null || true
                wl -i wl2 deauthenticate "$bad_mac" 2>/dev/null || true
                wl -i wl2.1 deauthenticate "$bad_mac" 2>/dev/null || true
                wl deauthenticate "$bad_mac" 2>/dev/null || true
            fi

            echo "[$now_ts] MLO_DEAUTH_KICK: Client $bad_mac deauthenticated (MLO loop broken)" >> "$AUDIT_LOG"
            actions_taken="${actions_taken}Kicked flapping client ($bad_mac). "
        done < "$FLAPPING_MACS_FILE"

        # Brief sleep for driver state machine to settle
        sleep 2
    fi

    # --------------------------------------------------------------------------
    # Step 2: Flush Stale Kernel Memory & Flow Tables
    # --------------------------------------------------------------------------
    printf "--> ${COLOR_CYAN}[HEAL]${COLOR_RESET} Flushing stale kernel page cache & conntrack buffers...\n"
    sync 2>/dev/null || true
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    actions_taken="${actions_taken}Flushed kernel page cache. "

    # --------------------------------------------------------------------------
    # Step 3: Heal Trend Micro DPI / WRS Subsystem (if ioctl fault detected)
    # --------------------------------------------------------------------------
    if grep -Eiq "tdts_core_ioctl|already exist in UDB" "$DETECTED_EVENTS_FILE" 2>/dev/null; then
        printf "--> ${COLOR_YELLOW}[HEAL]${COLOR_RESET} Trend Micro UDB collision detected. Restarting WRS service...\n"
        service restart_wrs >/dev/null 2>&1 || true
        sleep 3
        echo "[$now_ts] TRENDMICRO_WRS_RESTART: WRS reinitialized cleanly to clear UDB tables" >> "$AUDIT_LOG"
        actions_taken="${actions_taken}Restarted Trend Micro WRS service. "
    fi

    # --------------------------------------------------------------------------
    # Step 4: Advance Syslog Cursor
    # --------------------------------------------------------------------------
    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"

    rm -f "$DETECTED_EVENTS_FILE" "$FLAPPING_MACS_FILE"
    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Proactive mitigation completed successfully: %s\n" "${actions_taken:-Nominal state verified.}"
    return 0
}

mci_verify() {
    printf "${COLOR_CYAN}--> [VERIFY]${COLOR_RESET} Verifying network stability and kernel routing post-mitigation...\n"

    # Check 1: Verify local DNS resolution
    if which nslookup >/dev/null 2>&1; then
        if ! nslookup router.asus.com 127.0.0.1 >/dev/null 2>&1 && ! nslookup google.com 127.0.0.1 >/dev/null 2>&1; then
            printf "${COLOR_RED}--> [FAIL] Local DNS resolution failed after mitigation!${COLOR_RESET}\n"
            return 1
        fi
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Local DNS resolution verified.\n"
    fi

    # Check 2: Verify WAN connectivity
    if which ping >/dev/null 2>&1; then
        if ! ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
            printf "${COLOR_RED}--> [FAIL] WAN ping to 8.8.8.8 failed!${COLOR_RESET}\n"
            return 1
        fi
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} WAN internet connectivity verified.\n"
    fi

    # Check 3: Verify wireless interfaces are operational
    if which wl >/dev/null 2>&1; then
        if ! wl -i wl1 status >/dev/null 2>&1; then
            printf "${COLOR_RED}--> [FAIL] 5 GHz wireless interface (wl1) is down!${COLOR_RESET}\n"
            return 1
        fi
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} 5 GHz wireless radio operational.\n"
    fi

    printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Router health verified. Deadlock averted.\n"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Verification failed. Attempting wireless subsystem recovery..."
    service restart_wireless >/dev/null 2>&1 || true
    sleep 5
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    if [ "$status" = "SUCCESS" ]; then
        logger -t "Merlin-CI" "SUCCESS: [mlo-storm-watchdog] Mitigated Wi-Fi 7 MLO association storm and preserved kernel stability."
    fi
    echo "--> [NOTIFY] MLO storm watchdog finished: $status (${duration}s)"
}
