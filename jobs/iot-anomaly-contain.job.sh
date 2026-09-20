#!/bin/sh
# ==============================================================================
# Merlin-CI: IoT Anomaly Defender & Connection Containment
# ==============================================================================
# Monitors connection counts of designated IoT devices via /proc/net/nf_conntrack.
# When an IoT device exceeds connection limits (default: 20 connections):
# 1. Captures forensic destination IPs from conntrack
# 2. Injects Netfilter throttle/connlimit rules into iptables
# 3. Flushes bloated stale connections for the rogue device
# 4. Verifies containment rules are active
# 5. Dispatches alert with forensic connection details via /jffs/scripts/send_alert.sh
# ==============================================================================

JOB_NAME="iot-anomaly-contain"
JOB_DESCRIPTION="IoT anomaly defender: monitors IoT conntrack spikes and enforces active containment"
JOB_ENABLED=1
JOB_TYPE="watchdog"

DEFAULT_IOT_IPS="192.168.53.129 192.168.53.94 192.168.53.96 192.168.53.165 192.168.53.246"
IOT_SUBNET_PREFIX="${MCI_IOT_SUBNET_PREFIX:-192.168.53.}"
MAX_CONNS="${MCI_IOT_MAX_CONNS:-20}"
ROGUE_INFO_FILE="/tmp/mci_iot_rogue_devices.info"
ROGUE_DESTS_FILE="/tmp/mci_iot_rogue_dests.info"
IOT_CONFIG_FILE="/jffs/addons/merlin-ci/config/iot_devices.conf"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

_get_monitored_ips() {
    local discovered_ips=""

    # 1. Discover all active DHCP leases on the IoT subnet (192.168.53.x)
    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        discovered_ips="$discovered_ips $(awk -v pfx="$IOT_SUBNET_PREFIX" '$3 ~ "^"pfx {print $3}' /var/lib/misc/dnsmasq.leases 2>/dev/null)"
    fi

    # 2. Discover all active ARP table entries on the IoT subnet
    if [ -f /proc/net/arp ]; then
        discovered_ips="$discovered_ips $(awk -v pfx="$IOT_SUBNET_PREFIX" '$1 ~ "^"pfx {print $1}' /proc/net/arp 2>/dev/null)"
    fi

    # 3. Discover active connections in conntrack originating from the IoT subnet
    if [ -f /proc/net/nf_conntrack ]; then
        discovered_ips="$discovered_ips $(grep -oE "src=${IOT_SUBNET_PREFIX}[0-9]+" /proc/net/nf_conntrack 2>/dev/null | cut -d= -f2)"
    fi

    # 4. Include custom config file if present
    if [ -f "$IOT_CONFIG_FILE" ]; then
        discovered_ips="$discovered_ips $(grep -v '^[ ]*#' "$IOT_CONFIG_FILE" 2>/dev/null)"
    fi

    # 5. Include fallback default list
    discovered_ips="$discovered_ips $DEFAULT_IOT_IPS"

    # Deduplicate and filter out gateway (.1), network (.0), and broadcast (.255)
    echo "$discovered_ips" | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
        grep -v -E '\.(0|1|255)$' | sort -u | tr '\n' ' '
}

_get_device_name() {
    local target_ip="$1"
    local dev_name=""

    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        dev_name="$(awk -v ip="$target_ip" '$3 == ip {print $4}' /var/lib/misc/dnsmasq.leases 2>/dev/null | head -n 1)"
    fi

    if [ -z "$dev_name" ] || [ "$dev_name" = "*" ]; then
        dev_name="$(grep -E "^[ ]*$target_ip[ \t]+" /etc/hosts /etc/hosts.dnsmasq 2>/dev/null | awk '{print $2}' | head -n 1)"
    fi

    if [ -z "$dev_name" ] || [ "$dev_name" = "*" ]; then
        dev_name="$(nvram get custom_clientlist 2>/dev/null | tr '>' '\n' | grep -B 2 "$target_ip" | head -n 1)"
    fi

    [ -z "$dev_name" ] || [ "$dev_name" = "*" ] && dev_name="IoT-Device"
    echo "$dev_name"
}

_dispatch_user_alert() {
    local subject="$1"
    local message="$2"
    if [ -x "/jffs/scripts/send_alert.sh" ]; then
        /jffs/scripts/send_alert.sh "$subject" "$message" 2>/dev/null || true
    fi
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[IOT-DEFENDER]${COLOR_RESET} Scanning connection footprints in /proc/net/nf_conntrack...\n"

    if [ ! -f /proc/net/nf_conntrack ]; then
        printf "--> ${COLOR_YELLOW}[IOT-DEFENDER]${COLOR_RESET} /proc/net/nf_conntrack not accessible. Skipping.\n"
        return 1
    fi

    rm -f "$ROGUE_INFO_FILE" "$ROGUE_DESTS_FILE"

    local ip_list
    ip_list="$(_get_monitored_ips)"

    local rogue_found=0

    for ip in $ip_list; do
        [ -z "$ip" ] && continue

        # Skip router gateway and self addresses
        case "$ip" in
            *.1|*.0|*.255) continue ;;
        esac
        if ifconfig 2>/dev/null | grep -q "inet addr:$ip "; then
            continue
        fi

        local conns dev_name
        conns="$(grep -c "src=$ip" /proc/net/nf_conntrack 2>/dev/null)"
        conns="${conns:-0}"
        dev_name="$(_get_device_name "$ip")"

        local conn_color="${COLOR_GREEN}"
        local status_badge="${COLOR_GREEN}[NORMAL]${COLOR_RESET}"
        if [ "$conns" -ge "$MAX_CONNS" ]; then
            conn_color="${COLOR_RED}${COLOR_BOLD}"
            status_badge="${COLOR_RED}${COLOR_BOLD}[ALERT: LIMIT EXCEEDED]${COLOR_RESET}"
        elif [ "$conns" -ge $((MAX_CONNS / 2)) ]; then
            conn_color="${COLOR_YELLOW}"
            status_badge="${COLOR_YELLOW}[MODERATE]${COLOR_RESET}"
        fi

        printf "   ${COLOR_BOLD}%-16s${COLOR_RESET} (${COLOR_CYAN}%-15s${COLOR_RESET}): ${conn_color}%2d active connections${COLOR_RESET} ${COLOR_DIM}(Limit: %d)${COLOR_RESET} %s\n" \
            "$dev_name" "$ip" "$conns" "$MAX_CONNS" "$status_badge"

        if [ "$conns" -gt "$MAX_CONNS" ]; then
            echo "$ip $conns $dev_name" >> "$ROGUE_INFO_FILE"
            rogue_found=1
        fi
    done

    if [ "$rogue_found" -eq 1 ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}Detected IoT anomalous connection flood exceeding limit of %d!${COLOR_RESET}\n" "$MAX_CONNS"
        return 0
    fi

    printf "${COLOR_GREEN}--> [IOT-DEFENDER]${COLOR_RESET} All monitored IoT devices operating within normal thresholds. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving forensic connection tracking table snapshot to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    if [ -f "$ROGUE_INFO_FILE" ]; then
        while read -r rogue_ip conns dev_name; do
            [ -z "$rogue_ip" ] && continue
            grep "src=$rogue_ip" /proc/net/nf_conntrack > "$backup_dir/conntrack_${rogue_ip}.txt" 2>/dev/null || true
        done < "$ROGUE_INFO_FILE"
    fi

    iptables-save > "$backup_dir/iptables_pre.rules" 2>/dev/null || true
    return 0
}

mci_run() {
    echo "--> [RUN] Enforcing active network containment on rogue IoT devices..."

    if [ ! -f "$ROGUE_INFO_FILE" ]; then
        echo "--> [IOT-DEFENDER] No rogue devices queued."
        return 0
    fi

    while read -r rogue_ip conns dev_name; do
        [ -z "$rogue_ip" ] && continue
        [ -z "$dev_name" ] && dev_name="$(_get_device_name "$rogue_ip")"
        echo "--> [IOT-DEFENDER] Containing anomaly on $dev_name ($rogue_ip, $conns connections)..."

        # Capture top destination IPs
        local dest_summary
        dest_summary="$(grep "src=$rogue_ip" /proc/net/nf_conntrack 2>/dev/null | \
            awk '{for(i=1;i<=NF;i++) if($i ~ /^dst=/) print $i}' | sort | uniq -c | sort -nr | head -n 5)"
        echo "$rogue_ip: $dest_summary" >> "$ROGUE_DESTS_FILE"

        # Apply iptables rate-limiting rule (connlimit above 20)
        if ! iptables -C FORWARD -s "$rogue_ip" -m connlimit --connlimit-above 20 -j DROP 2>/dev/null; then
            echo "   Injecting iptables rate-limit rule for $dev_name ($rogue_ip)..."
            iptables -I FORWARD 1 -s "$rogue_ip" -m connlimit --connlimit-above 20 -j DROP 2>/dev/null || true
        fi

        # If connections exceed extreme flood threshold (>50), quarantine WAN outbound
        if [ "$conns" -gt 50 ]; then
            echo "   [CAUTION] Severe flood ($conns > 50). Quarantining WAN access for $dev_name ($rogue_ip)..."
            local wan_if
            wan_if="$(nvram get wan0_ifname 2>/dev/null || echo "eth0")"
            if ! iptables -C FORWARD -s "$rogue_ip" -o "$wan_if" -j DROP 2>/dev/null; then
                iptables -I FORWARD 1 -s "$rogue_ip" -o "$wan_if" -j DROP 2>/dev/null || true
            fi
        fi

        # Clear stale conntrack entries if conntrack binary is installed (Entware)
        if command -v conntrack >/dev/null 2>&1; then
            conntrack -D -s "$rogue_ip" >/dev/null 2>&1 || true
        fi
    done < "$ROGUE_INFO_FILE"

    return 0
}

mci_verify() {
    echo "--> [VERIFY] Verifying defensive containment rules in Netfilter..."

    if [ -f "$ROGUE_INFO_FILE" ]; then
        while read -r rogue_ip conns dev_name; do
            [ -z "$rogue_ip" ] && continue
            if iptables -L FORWARD -n 2>/dev/null | grep -q "$rogue_ip"; then
                echo "   [PASS] Active Netfilter containment verified for ${dev_name:-$rogue_ip} ($rogue_ip)."
            else
                echo "--> [WARNING] Containment rule for ${dev_name:-$rogue_ip} ($rogue_ip) not found in FORWARD chain."
            fi
        done < "$ROGUE_INFO_FILE"
    fi

    return 0
}

mci_rollback() {
    local backup_dir="$1"
    if [ -f "$backup_dir/iptables_pre.rules" ]; then
        echo "--> [ROLLBACK] Restoring previous iptables firewall state..."
        iptables-restore < "$backup_dir/iptables_pre.rules" 2>/dev/null || true
    fi
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"

    if [ -f "$ROGUE_INFO_FILE" ]; then
        while read -r rogue_ip conns dev_name; do
            [ -z "$rogue_ip" ] && continue
            [ -z "$dev_name" ] && dev_name="$(_get_device_name "$rogue_ip")"

            local msg="IoT Watchdog Alert!
Device: $dev_name (IP: $rogue_ip) has $conns active external connections (Threshold: $MAX_CONNS).
Active containment applied: Netfilter connection throttled."

            if [ -f "$ROGUE_DESTS_FILE" ]; then
                local top_dests
                top_dests="$(grep "^$rogue_ip:" "$ROGUE_DESTS_FILE" 2>/dev/null)"
                if [ -n "$top_dests" ]; then
                    msg="$msg
Top destinations:
$top_dests"
                fi
            fi

            echo "--> [NOTIFY] Dispatching IoT alert for $dev_name ($rogue_ip)..."
            _dispatch_user_alert "IOT alert !" "$msg"
        done < "$ROGUE_INFO_FILE"
    fi

    rm -f "$ROGUE_INFO_FILE" "$ROGUE_DESTS_FILE" 2>/dev/null || true
}
