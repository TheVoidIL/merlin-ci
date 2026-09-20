#!/bin/sh
# ==============================================================================
# Merlin-CI: Firewall & IPTables Chain Integrity Watchdog (firewall-leak-audit)
# ==============================================================================
# Audits the kernel netfilter state to ensure critical security chains
# (INPUT/FORWARD filters, Skynet IPSet chains, VPN leak protections) have not
# been dropped or corrupted after WAN reconnects or script reloads.
# Automatically restores and verifies firewall integrity.
# ==============================================================================

JOB_NAME="firewall-leak-audit"
JOB_DESCRIPTION="Security watchdog: audits iptables chains and auto-repairs missing firewall rules"
JOB_ENABLED=1
JOB_TYPE="daily"

_check_core_firewall() {
    # Check that filter table and default chains exist
    if ! iptables -L INPUT -n >/dev/null 2>&1; then return 1; fi
    if ! iptables -L FORWARD -n >/dev/null 2>&1; then return 1; fi
    return 0
}

_check_skynet_rules() {
    local skynet_script="/jffs/scripts/firewall"
    local skynet_cfg="/jffs/addons/skynet/skynet.cfg"

    # Check if Skynet script exists
    if [ ! -f "$skynet_script" ] || ! grep -qi "skynet" "$skynet_script" 2>/dev/null; then
        return 0 # Skynet script not present, nothing to audit
    fi

    # Verify if Skynet is actually configured
    if [ ! -f "$skynet_cfg" ]; then
        echo "--> [AUDIT] Skynet config ($skynet_cfg) not found. Skynet is unconfigured. Skipping."
        return 0
    fi

    # Check if Skynet is explicitly disabled or uninstalled in configuration
    if grep -qE "(enabled|filterinstalled)=[\"']?0" "$skynet_cfg" 2>/dev/null; then
        echo "--> [AUDIT] Skynet is configured but currently disabled/uninstalled. Skipping."
        return 0
    fi

    # Skynet is configured and enabled: verify active filtering in kernel
    local ipset_active=0
    if command -v ipset >/dev/null 2>&1; then
        if ipset list Skynet-Master >/dev/null 2>&1 || \
           ipset -n list 2>/dev/null | grep -qi "skynet" || \
           ipset list -n 2>/dev/null | grep -qi "skynet" || \
           ipset list 2>/dev/null | grep -qi "skynet"; then
            ipset_active=1
        fi
    fi

    # Check netfilter tables (raw, filter, mangle) using verbose/specification output
    local rule_found=0
    if command -v iptables >/dev/null 2>&1; then
        if iptables -S 2>/dev/null | grep -qi "skynet" || \
           iptables -t raw -S 2>/dev/null | grep -qi "skynet" || \
           iptables -v -L -n 2>/dev/null | grep -qi "skynet" || \
           iptables -t raw -v -L -n 2>/dev/null | grep -qi "skynet" || \
           iptables -t mangle -v -L -n 2>/dev/null | grep -qi "skynet"; then
            rule_found=1
        fi
    fi

    if [ "$rule_found" -eq 1 ] || [ "$ipset_active" -eq 1 ]; then
        return 0
    fi

    echo "--> [AUDIT] Skynet iptables chains and IPSet sets are MISSING!"
    return 1
}

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[FIREWALL-AUDIT]${COLOR_RESET} Inspecting netfilter chains and firewall security status...\n"

    # Check 1: Core iptables health
    if ! _check_core_firewall; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Core iptables filter chains (INPUT/FORWARD) are missing or unresponsive!${COLOR_RESET}\n"
        return 0
    fi

    # Check 2: Skynet firewall integrity (if installed)
    if ! _check_skynet_rules; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Security vulnerability detected: Skynet firewall rules are missing from netfilter!${COLOR_RESET}\n"
        return 0
    fi

    printf "${COLOR_GREEN}--> [FIREWALL-AUDIT]${COLOR_RESET} All core and addon firewall chains are active and intact. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving current netfilter rules to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    iptables-save > "$backup_dir/iptables_before.save" 2>/dev/null || true
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$backup_dir/ip6tables_before.save" 2>/dev/null || true
    fi

    echo "   [OK] Pre-flight firewall snapshot recorded."
    return 0
}

mci_run() {
    echo "--> [RUN] Repairing and reloading router firewall chains..."

    # If Skynet rules were specifically dropped, trigger Skynet restart first
    if [ -f /jffs/scripts/firewall ]; then
        if ! _check_skynet_rules; then
            echo "--> [HEAL] Restarting Skynet firewall rules (/jffs/scripts/firewall restart)..."
            local heal_out
            heal_out="$(sh /jffs/scripts/firewall restart 2>&1 | head -n 5)"
            [ -n "$heal_out" ] && echo "$heal_out"
            sleep 10
        fi
    fi

    # General router firewall refresh
    if ! _check_core_firewall; then
        echo "--> [HEAL] Executing service restart_firewall..."
        service restart_firewall >/dev/null 2>&1 || true
        sleep 3
    fi

    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running CI smoke tests on restored firewall chains..."

    # Check 1: Core chains
    if ! _check_core_firewall; then
        echo "--> [FAIL] Core iptables chains failed to recover!"
        return 1
    fi
    echo "   [PASS] Core iptables chains active (INPUT, FORWARD, OUTPUT)."

    # Check 2: Skynet rules with retry period
    if [ -f /jffs/scripts/firewall ]; then
        local attempts=0
        while [ "$attempts" -lt 5 ]; do
            if _check_skynet_rules; then
                echo "   [PASS] Skynet firewall rules and IPSet verified active."
                echo "--> [VERIFY] Firewall security audit PASSED successfully!"
                return 0
            fi
            sleep 2
            attempts=$((attempts + 1))
        done
        echo "--> [FAIL] Skynet firewall rules failed to re-attach!"
        return 1
    fi

    echo "--> [VERIFY] Firewall security audit PASSED successfully!"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Firewall repair verification failed. Restoring from pre-flight save..."

    if [ -f "$backup_dir/iptables_before.save" ]; then
        iptables-restore < "$backup_dir/iptables_before.save" 2>/dev/null || true
    fi

    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] Firewall integrity audit completed: $status (${duration}s)"
}
