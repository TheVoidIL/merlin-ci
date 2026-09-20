#!/bin/sh
# ==============================================================================
# Merlin-CI: Autonomous DNS & Dnsmasq Freeze Self-Healing Watchdog
# ==============================================================================
# Detects when dnsmasq has deadlocked, cache is corrupted, or local queries
# timeout. Validates dnsmasq configuration syntax, flushes cache, restarts
# service, and verifies low-latency local resolution with automated rollback.
# ==============================================================================

JOB_NAME="dns-unresponsive-heal"
JOB_DESCRIPTION="Self-healing watchdog: detects dnsmasq lockup/timeout and restarts DNS"
JOB_ENABLED=1
JOB_TYPE="watchdog"

DNS_SERVER="127.0.0.1"
QUERY_DOMAIN="router.asus.com"
EXTERNAL_DOMAIN="cloudflare.com"

_get_dns_target() {
    local lan_ip
    lan_ip="$(nvram get lan_ipaddr 2>/dev/null)"
    if [ -n "$lan_ip" ]; then
        echo "$lan_ip"
    else
        echo "127.0.0.1"
    fi
}

_test_local_dns() {
    if ! command -v nslookup >/dev/null 2>&1; then
        return 0 # Cannot test, assume healthy to avoid false restarts
    fi

    local lan_ip
    lan_ip="$(_get_dns_target)"

    # Test 1: System default resolver (queries /etc/resolv.conf directly)
    local out1
    out1="$(nslookup cloudflare.com 2>&1)"
    if echo "$out1" | grep -E -qi "Address|answer:"; then
        return 0
    fi

    # Test 2: Explicitly query router LAN IP (where dnsmasq listens on br0)
    if [ -n "$lan_ip" ]; then
        local out2
        out2="$(nslookup cloudflare.com "$lan_ip" 2>&1)"
        if echo "$out2" | grep -E -qi "Address|answer:"; then
            return 0
        fi
    fi

    # Test 3: Query 127.0.0.1 (if loopback listener is configured via Diversion/Stubby)
    local out3
    out3="$(nslookup cloudflare.com 127.0.0.1 2>&1)"
    if echo "$out3" | grep -E -qi "Address|answer:"; then
        return 0
    fi

    # Test 4: Query local router domain name
    for rdomain in "asusrouter.com" "router.asus.com" "$(nvram get lan_domain 2>/dev/null)"; do
        [ -z "$rdomain" ] && continue
        local out4
        out4="$(nslookup "$rdomain" "$lan_ip" 2>&1)"
        if echo "$out4" | grep -E -qi "Address|answer:"; then
            return 0
        fi
    done

    return 1
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[DNS-WATCHDOG]${COLOR_RESET} Inspecting local dnsmasq health and query responsiveness...\n"

    # Check 1: Is dnsmasq process running?
    if ! pidof dnsmasq >/dev/null 2>&1; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}dnsmasq process is NOT running!${COLOR_RESET}\n"
        return 0
    fi

    # Check 2: Does local DNS respond?
    if _test_local_dns; then
        printf "${COLOR_GREEN}--> [DNS-WATCHDOG]${COLOR_RESET} Local DNS resolution is responsive. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi

    printf "${COLOR_YELLOW}--> [DNS-WATCHDOG] WARNING: Initial DNS query failed. Retrying in 3s...${COLOR_RESET}\n"
    sleep 3

    if _test_local_dns; then
        printf "${COLOR_GREEN}--> [DNS-WATCHDOG]${COLOR_RESET} DNS responded on second attempt. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}Local DNS resolution is unresponsive or timed out!${COLOR_RESET}\n"
    return 0
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving current dnsmasq configurations to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    [ -f /etc/dnsmasq.conf ] && cp -pf /etc/dnsmasq.conf "$backup_dir/" 2>/dev/null || true
    [ -f /jffs/configs/dnsmasq.conf.add ] && cp -pf /jffs/configs/dnsmasq.conf.add "$backup_dir/" 2>/dev/null || true
    [ -d /jffs/addons/diversion ] && cp -pf /jffs/addons/diversion/mount-entware.div "$backup_dir/" 2>/dev/null || true

    echo "   [OK] Pre-flight DNS configuration snapshot recorded."
    return 0
}

mci_run() {
    echo "--> [RUN] Starting dnsmasq self-healing pipeline..."

    # Step 1: Validate configuration syntax to prevent broken restart
    if command -v dnsmasq >/dev/null 2>&1; then
        echo "--> [VALIDATE] Checking dnsmasq configuration syntax..."
        if ! dnsmasq --test 2>&1; then
            echo "--> [WARNING] dnsmasq reported syntax warning/error in active config."
        else
            echo "   [OK] Configuration syntax is valid."
        fi
    fi

    # Step 2: Flush caches and restart service
    echo "--> [RUN] Executing service restart_dnsmasq..."
    service restart_dnsmasq >/dev/null 2>&1 || true

    # Step 3: Brief grace period for socket binding
    sleep 2
    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running CI smoke tests on restored dnsmasq..."

    # Check 1: Process presence
    if ! pidof dnsmasq >/dev/null 2>&1; then
        echo "--> [FAIL] dnsmasq process is still not running after restart!"
        return 1
    fi
    echo "   [PASS] dnsmasq daemon running (PID: $(pidof dnsmasq))."

    # Check 2: Resolution verification
    local attempts=0
    while [ "$attempts" -lt 5 ]; do
        if _test_local_dns; then
            echo "   [PASS] Local DNS resolution verified successfully."
            return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    echo "--> [FAIL] Local DNS failed to respond after recovery!"
    return 1
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] DNS verification failed. Restoring pre-flight configs..."

    if [ -f "$backup_dir/dnsmasq.conf.add" ]; then
        cp -pf "$backup_dir/dnsmasq.conf.add" /jffs/configs/dnsmasq.conf.add 2>/dev/null || true
    fi

    echo "--> [ROLLBACK] Restarting dnsmasq with original configuration..."
    service restart_dnsmasq >/dev/null 2>&1 || true
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] DNS self-healing finished with status: $status (${duration}s)"
}
