#!/bin/sh
# ==============================================================================
# Merlin-CI: Autonomous WAN Gateway & Internet Self-Healing Watchdog
# ==============================================================================
# Detects when the WAN interface is connected but the ISP gateway or internet
# connectivity is stalled/dead. Executes progressive self-healing:
# 1. Soft DHCP lease renewal (udhcpc SIGUSR1)
# 2. WAN subsystem soft-restart (service restart_wan)
# 3. Post-heal CI verification (multi-endpoint ping & DNS resolution)
# 4. Automated rollback & alert dispatch
# ==============================================================================

JOB_NAME="wan-gateway-watchdog"
JOB_DESCRIPTION="Self-healing watchdog: detects WAN/gateway drop and auto-recovers connection"
JOB_ENABLED=1
JOB_TYPE="watchdog"

# Targets to verify internet routing
PING_TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
PING_TIMEOUT=2
PING_COUNT=2

_is_wan_linked() {
    # Check if router WAN is in connected state (2 = CONNECTED in Asuswrt nvram)
    local wan_state
    wan_state="$(nvram get wan0_state_t 2>/dev/null)"
    [ "$wan_state" = "2" ] && return 0

    # Fallback: check if WAN interface has an assigned IPv4 address
    local wan_if
    wan_if="$(nvram get wan0_ifname 2>/dev/null)"
    [ -z "$wan_if" ] && wan_if="$(nvram get wan0_gwifname 2>/dev/null)"
    if [ -n "$wan_if" ]; then
        if ifconfig "$wan_if" 2>/dev/null | grep -q "inet addr:"; then
            return 0
        fi
    fi
    return 1
}

_test_connectivity() {
    for target in $PING_TARGETS; do
        if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[WAN-WATCHDOG]${COLOR_RESET} Checking WAN link and internet routing status...\n"

    # If WAN is not physically linked or configured, do not trigger false alarm
    if ! _is_wan_linked; then
        printf "--> ${COLOR_YELLOW}[WAN-WATCHDOG]${COLOR_RESET} WAN interface is currently not linked/configured. Skipping.\n"
        return 1
    fi

    # Test internet reachability
    if _test_connectivity; then
        printf "${COLOR_GREEN}--> [WAN-WATCHDOG]${COLOR_RESET} Internet connectivity is healthy (ping verified). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi

    printf "${COLOR_YELLOW}--> [WAN-WATCHDOG] WARNING: Initial ping check failed. Running 2nd verification pass...${COLOR_RESET}\n"
    sleep 3

    if _test_connectivity; then
        printf "${COLOR_GREEN}--> [WAN-WATCHDOG]${COLOR_RESET} Transient blip resolved on retry. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}WAN interface is linked but all internet ping targets are unreachable!${COLOR_RESET}\n"
    return 0
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving WAN routing table and resolver state to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    ip route show > "$backup_dir/routes_before.txt" 2>/dev/null || true
    cat /etc/resolv.conf > "$backup_dir/resolv.conf.bak" 2>/dev/null || true
    ifconfig > "$backup_dir/ifconfig_before.txt" 2>/dev/null || true

    echo "   [OK] Pre-flight network snapshot recorded."
    return 0
}

mci_run() {
    echo "--> [RUN] Starting progressive self-healing on WAN connection..."

    # Stage 1: Attempt soft DHCP lease renewal
    local wan_proto
    wan_proto="$(nvram get wan0_proto 2>/dev/null)"

    if [ "$wan_proto" = "dhcp" ] || [ -z "$wan_proto" ]; then
        echo "--> [HEAL: STEP 1] Refreshing DHCP lease via udhcpc..."
        killall -SIGUSR1 udhcpc 2>/dev/null || true
        sleep 4

        if _test_connectivity; then
            echo "   [OK] Internet recovered via DHCP lease refresh!"
            return 0
        fi
    fi

    # Stage 2: Soft-restart the WAN service
    echo "--> [HEAL: STEP 2] Performing service restart_wan..."
    service restart_wan >/dev/null 2>&1 || true

    # Allow router modem/gateway handshake
    local waited=0
    while [ "$waited" -lt 15 ]; do
        sleep 3
        waited=$((waited + 3))
        if _is_wan_linked && _test_connectivity; then
            echo "   [OK] WAN connection recovered after ${waited}s!"
            return 0
        fi
    done

    echo "--> [WARNING] WAN recovery attempt completed, verifying post-action state..."
    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running post-heal CI connectivity tests..."

    # Check 1: Multi-target ping verification
    if ! _test_connectivity; then
        echo "--> [FAIL] Internet ping targets are still unreachable after recovery!"
        return 1
    fi
    echo "   [PASS] Multi-target external ping verified."

    # Check 2: DNS resolution test
    if command -v nslookup >/dev/null 2>&1; then
        if ! nslookup google.com 1.1.1.1 >/dev/null 2>&1; then
            echo "--> [FAIL] Public DNS resolution through 1.1.1.1 failed!"
            return 1
        fi
        echo "   [PASS] Public DNS resolution responsive."
    fi

    echo "--> [VERIFY] WAN connection successfully restored and operational!"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] WAN verification failed. Restoring resolver configuration..."

    if [ -f "$backup_dir/resolv.conf.bak" ]; then
        cp -pf "$backup_dir/resolv.conf.bak" /etc/resolv.conf 2>/dev/null || true
    fi

    echo "--> [ROLLBACK] Re-triggering clean network restart..."
    service restart_wan >/dev/null 2>&1 || true
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] WAN self-healing completed with status: $status (${duration}s)"
}
