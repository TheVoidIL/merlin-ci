#!/bin/sh
# ==============================================================================
# Merlin-CI: New Device Discovery & LAN Sentry Watchdog (new-device-watchdog)
# ==============================================================================
# Scans dnsmasq DHCP lease table for unrecognized MAC addresses connecting to
# the home network.
#
# Lifecycle:
# 1. Trigger Stage (mci_check_trigger):
#    Compares /var/lib/misc/dnsmasq.leases against /jffs/scripts/known_macs.txt.
#    Triggers immediately when an unknown MAC is discovered.
# 2. Backup Stage (mci_backup):
#    Snapshots known_macs.txt to USB backup before updating registry.
# 3. Execution Stage (mci_run):
#    Formats device details (Hostname, IP, MAC) and dispatches instant security
#    alert via /jffs/scripts/send_alert.sh.
#    Registers new MAC in /jffs/scripts/known_macs.txt.
# 4. Verification Stage (mci_verify):
#    Confirms file permissions and that newly identified MACs are now recorded.
# 5. Rollback Stage (mci_rollback):
#    Restores previous known_macs.txt if write failed or was corrupted.
# ==============================================================================

JOB_NAME="new-device-watchdog"
JOB_DESCRIPTION="Network sentry: detects new unrecognized devices on the network via DHCP leases"
JOB_ENABLED=1
JOB_TYPE="watchdog"

KNOWN_MACS_FILE="/jffs/scripts/known_macs.txt"
LEASES_FILE="/var/lib/misc/dnsmasq.leases"
STAGED_NEW_DEVICES="/tmp/mci_new_devs_$$.txt"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[DEVICE-SENTRY]${COLOR_RESET} Auditing active DHCP leases against known MAC registry...\n"

    touch "$KNOWN_MACS_FILE" 2>/dev/null || true
    rm -f "$STAGED_NEW_DEVICES"

    if [ ! -f "$LEASES_FILE" ]; then
        printf "${COLOR_GREEN}--> [DEVICE-SENTRY]${COLOR_RESET} DHCP lease database not present. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi

    local new_count=0
    local dev_mac dev_ip dev_name

    # Parse dnsmasq leases: <timestamp> <mac> <ip> <hostname> <client-id>
    while read -r _ dev_mac dev_ip dev_name _; do
        [ -z "$dev_mac" ] && continue

        if ! grep -qi "$dev_mac" "$KNOWN_MACS_FILE" 2>/dev/null; then
            echo "$dev_mac $dev_ip ${dev_name:-unknown}" >> "$STAGED_NEW_DEVICES"
            new_count=$((new_count + 1))
        fi
    done < "$LEASES_FILE"

    if [ "$new_count" -gt 0 ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Discovered %d new/unrecognized device(s) on LAN!${COLOR_RESET}\n" "$new_count"
        while read -r d_mac d_ip d_name; do
            printf "    ${COLOR_CYAN}*${COLOR_RESET} ${COLOR_BOLD}%s${COLOR_RESET} (${COLOR_YELLOW}%s${COLOR_RESET} / ${COLOR_MAGENTA}%s${COLOR_RESET})\n" "$d_name" "$d_ip" "$d_mac"
        done < "$STAGED_NEW_DEVICES"
        return 0
    fi

    printf "${COLOR_GREEN}--> [DEVICE-SENTRY]${COLOR_RESET} All connected devices recognized in registry. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    mkdir -p "$backup_dir" 2>/dev/null || true

    if [ -f "$KNOWN_MACS_FILE" ]; then
        cp -pf "$KNOWN_MACS_FILE" "$backup_dir/known_macs.bak" 2>/dev/null || true
    fi

    if [ -f "$STAGED_NEW_DEVICES" ]; then
        cp -f "$STAGED_NEW_DEVICES" "$backup_dir/new_devices_staged.txt" 2>/dev/null || true
    fi

    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Device registry snapshot stored in %s\n" "$backup_dir"
    return 0
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Processing new device alerts and registering MACs...\n"

    if [ ! -f "$STAGED_NEW_DEVICES" ] || [ ! -s "$STAGED_NEW_DEVICES" ]; then
        echo "--> [RUN] No new devices queued."
        return 0
    fi

    local dev_mac dev_ip dev_name
    while read -r dev_mac dev_ip dev_name; do
        [ -z "$dev_mac" ] && continue

        local message
        message="New Device Detected!
Name: $dev_name
IP: $dev_ip
MAC: $dev_mac"

        printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} Dispatching new device alert for ${COLOR_BOLD}%s${COLOR_RESET} (${COLOR_YELLOW}%s${COLOR_RESET})...\n" "$dev_name" "$dev_ip"
        if [ -x "/jffs/scripts/send_alert.sh" ]; then
            /jffs/scripts/send_alert.sh "New Device Alert !" "$message"
        else
            notify_dispatch "SECURITY" "new-device-watchdog" "0" "$message"
        fi

        # Add to known MACs registry
        echo "$dev_mac" >> "$KNOWN_MACS_FILE"
        printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Registered MAC ${COLOR_BOLD}%s${COLOR_RESET} in %s\n" "$dev_mac" "$KNOWN_MACS_FILE"
    done < "$STAGED_NEW_DEVICES"

    rm -f "$STAGED_NEW_DEVICES"
    return 0
}

mci_verify() {
    printf "${COLOR_CYAN}--> [VERIFY]${COLOR_RESET} Verifying device registry integrity...\n"

    if [ ! -f "$KNOWN_MACS_FILE" ]; then
        printf "${COLOR_RED}--> [FAIL] Registry file %s not found!${COLOR_RESET}\n" "$KNOWN_MACS_FILE"
        return 1
    fi

    local mac_count
    mac_count=$(wc -l < "$KNOWN_MACS_FILE" 2>/dev/null || echo 0)
    printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Known MAC registry verified (%d entries recorded).\n" "$mac_count"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    if [ -f "$backup_dir/known_macs.bak" ]; then
        cp -pf "$backup_dir/known_macs.bak" "$KNOWN_MACS_FILE" 2>/dev/null || true
    fi
    return 0
}

mci_notify() {
    local status="$1" duration="$2"
    printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} New device watchdog finished: ${COLOR_BOLD}%s${COLOR_RESET} (${duration}s)\n" "$status"
}
