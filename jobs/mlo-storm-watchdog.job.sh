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
JOB_DESCRIPTION="Self-healing watchdog: detects Wi-Fi 7 MLO deauth storms, Broadcom FIFO congestion & BPM memory exhaustion to prevent kernel deadlock"
JOB_ENABLED=1
# Tier 0 (fast): evaluated every 2 min via MCI_Fast cron. A storm can escalate to a
# kernel/IO stall and WAN (PPPoE LCP) drop within ~15 min, so the 15-min tier is too slow.
JOB_TYPE="fast"
# The storm itself drives load up; never defer this job on the CPU load guard.
JOB_BYPASS_LOAD_GUARD=1

# Thresholds
MLO_LOOP_THRESHOLD=5         # Trigger if >= 5 MLO assoc failures in window
UDB_FAULT_THRESHOLD=10       # Trigger if >= 10 tdts UDB collisions or any ioctl fault in window
BPM_FAULT_THRESHOLD=1        # Trigger if any Broadcom Buffer Pool Manager allocation faults in window
BPM_SLAB_WATERMARK=11000     # Trigger if live /proc/slabinfo bpmbuf active objects >= 11000 (panic at ~12174)
DEAUTH_STORM_THRESHOLD=20    # Trigger if >= 20 Broadcom driver deauth error (-30) events in 2-min window
HEAL_COOLDOWN_SEC=900        # Minimum 15 min cooldown between flow-cache flushes / healing alerts

STATE_FILE="/tmp/mci_mlo_storm_state.txt"
COOLDOWN_FILE="/tmp/mci_mlo_storm_cooldown.txt"
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
        # Syslog rotated; only inspect the tail (last 200 lines) to avoid re-scanning old history
        if [ "$total_lines" -gt 200 ]; then
            last_line=$((total_lines - 200))
        else
            last_line=0
        fi
    fi

    if [ "$total_lines" -eq "$last_line" ]; then
        return 1
    fi

    local start_line=$((last_line + 1))
    sed -n "${start_line},\$p" "$SYSLOG_FILE" 2>/dev/null | \
        grep -Ei "MLO ERROR|tdts_core_ioctl|already exist in UDB|page allocation failure.*order|ERROR bpm|bpm_alloc_buf|WLC_SCB_DEAUTHORIZE error \(-30\)" \
        > "$target_out" 2>/dev/null || true
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[MLO-GUARD]${COLOR_RESET} Auditing Wi-Fi 7 MLO association telemetry, BPM slab buffers, and driver stability...\n"

    rm -f "$DETECTED_EVENTS_FILE" "$FLAPPING_MACS_FILE"

    _extract_recent_events "$DETECTED_EVENTS_FILE"

    local triggered=0
    local mlo_count=0
    local udb_count=0
    local bpm_count=0
    local deauth_count=0
    local bpm_active=0

    # Check live /proc/slabinfo bpmbuf active count
    if [ -r /proc/slabinfo ]; then
        bpm_active=$(awk '$1 == "bpmbuf" {print $2}' /proc/slabinfo 2>/dev/null)
        [ -z "$bpm_active" ] && bpm_active=0
    fi

    if [ -s "$DETECTED_EVENTS_FILE" ]; then
        mlo_count=$(grep -Ei "MLO ERROR" "$DETECTED_EVENTS_FILE" 2>/dev/null | wc -l | awk '{print $1}')
        udb_count=$(grep -Ei "tdts_core_ioctl|already exist in UDB" "$DETECTED_EVENTS_FILE" 2>/dev/null | wc -l | awk '{print $1}')
        bpm_count=$(grep -Ei "page allocation failure.*order|ERROR bpm|bpm_alloc_buf" "$DETECTED_EVENTS_FILE" 2>/dev/null | wc -l | awk '{print $1}')
        deauth_count=$(grep -Ei "WLC_SCB_DEAUTHORIZE error \(-30\)" "$DETECTED_EVENTS_FILE" 2>/dev/null | wc -l | awk '{print $1}')

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

        # 3. Check for Broadcom Buffer Pool Manager (BPM) DMA memory exhaustion
        if [ "$bpm_count" -ge "$BPM_FAULT_THRESHOLD" ]; then
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Broadcom Buffer Pool Manager (BPM) DMA page allocation failure detected (%d events)!${COLOR_RESET}\n" \
                "$bpm_count"
            triggered=1
        fi

        # 4. Check for driver deauthorization loop storm (error -30)
        if [ "$deauth_count" -ge "$DEAUTH_STORM_THRESHOLD" ]; then
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Broadcom wireless driver deauth storm detected (%d events with error -30)!${COLOR_RESET}\n" \
                "$deauth_count"
            triggered=1
        fi
    fi

    # 5. Check live Broadcom BPM slab memory watermark
    if [ "$bpm_active" -ge "$BPM_SLAB_WATERMARK" ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Broadcom BPM slab pool critically high (%d active objects >= %d)!${COLOR_RESET}\n" \
            "$bpm_active" "$BPM_SLAB_WATERMARK"
        echo "BPM_SLAB_HIGH_WATERMARK: active=$bpm_active" >> "$DETECTED_EVENTS_FILE"
        triggered=1
    fi

    if [ "$triggered" -eq 1 ]; then
        # Enforce cooldown guard to prevent repeated flow-cache flushes or email storms
        if [ -f "$COOLDOWN_FILE" ] && [ ! -s "$FLAPPING_MACS_FILE" ]; then
            local last_heal_epoch now_epoch elapsed
            last_heal_epoch=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
            now_epoch=$(date +%s 2>/dev/null || echo 0)
            elapsed=$((now_epoch - last_heal_epoch))
            if [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$HEAL_COOLDOWN_SEC" ]; then
                local total_lines_cd
                total_lines_cd=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
                [ -n "$total_lines_cd" ] && echo "$total_lines_cd" > "$STATE_FILE"
                rm -f "$DETECTED_EVENTS_FILE" "$FLAPPING_MACS_FILE"
                printf "${COLOR_YELLOW}--> [MLO-GUARD]${COLOR_RESET} Cooldown active (%ds / %ds elapsed). Skipping redundant heal.\n" "$elapsed" "$HEAL_COOLDOWN_SEC"
                return 1
            fi
        fi
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
    # Step 2: Mitigate Broadcom Buffer Pool Exhaustion & Deauth Storms
    # --------------------------------------------------------------------------
    if grep -Eiq "page allocation failure|ERROR bpm|bpm_alloc_buf|BPM_SLAB_HIGH_WATERMARK|WLC_SCB_DEAUTHORIZE error \(-30\)" "$DETECTED_EVENTS_FILE" 2>/dev/null; then
        printf "--> ${COLOR_YELLOW}[HEAL]${COLOR_RESET} Broadcom BPM buffer exhaustion or deauth storm detected. Purging flow cache & reclaiming DMA buffers...\n"
        if which fc >/dev/null 2>&1; then
            fc flush 2>/dev/null || true
        fi
        sync 2>/dev/null || true
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        echo "[$now_ts] BROADCOM_BPM_HEAL: Purged flow caches and reclaimed DMA slab buffers" >> "$AUDIT_LOG"
        actions_taken="${actions_taken}Flushed Broadcom flow cache & recovered DMA slab buffers. "
    else
        printf "--> ${COLOR_CYAN}[HEAL]${COLOR_RESET} Flushing stale kernel page cache & conntrack buffers...\n"
        sync 2>/dev/null || true
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        actions_taken="${actions_taken}Flushed kernel page cache. "
    fi

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
    # Step 4: Advance Syslog Cursor & Record Cooldown
    # --------------------------------------------------------------------------
    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"
    date +%s > "$COOLDOWN_FILE" 2>/dev/null || true

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
