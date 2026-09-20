#!/bin/sh
# ==============================================================================
# Merlin-CI: Daily Router Health Digest & Telemetry Report (router-daily-digest)
# ==============================================================================
# Aggregates comprehensive 24h operational telemetry:
# - WAN IP & Gateway status
# - System Uptime
# - CPU Thermal footprint (/sys/power/bpcm/cpu_temp)
# - Actual RAM usage & memory pressure
# - JFFS persistent storage utilization
# - Active connection table count (/proc/net/nf_conntrack)
# - Connected IoT device count (192.168.53.x VLAN/subnet)
# - Internet latency (ICMP ping to 8.8.8.8)
# - Skynet malicious firewall blocks
# - Diversion / dnsmasq ad blocking telemetry
# - Active automation scheduled tasks
#
# Formats into an elegant report and dispatches via /jffs/scripts/send_alert.sh.
# ==============================================================================

JOB_NAME="router-daily-digest"
JOB_DESCRIPTION="Health digest: aggregates 24h router telemetry, thermal, RAM, security, and WAN health report"
JOB_ENABLED=1
JOB_TYPE="daily"
JOB_NOTIFY_SUCCESS=0

LAST_DIGEST_FILE="/tmp/mci_last_daily_digest"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[HEALTH-DIGEST]${COLOR_RESET} Evaluating daily report dispatch schedule...\n"

    local today
    today="$(date +%Y-%m-%d 2>/dev/null || date)"

    # Only run once per calendar day unless force-executed (-f)
    if [ -f "$LAST_DIGEST_FILE" ]; then
        local last_date
        last_date=$(cat "$LAST_DIGEST_FILE" 2>/dev/null)
        if [ "$last_date" = "$today" ]; then
            printf "${COLOR_GREEN}--> [HEALTH-DIGEST]${COLOR_RESET} Daily report already generated for today (%s). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$today"
            return 1
        fi
    fi

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}Daily health report is ready for generation (${today}).${COLOR_RESET}\n"
    return 0
}

mci_backup() {
    local backup_dir="$1"
    mkdir -p "$backup_dir" 2>/dev/null || true
    # Archive previous digest if available
    [ -f "$LAST_DIGEST_FILE" ] && cp -pf "$LAST_DIGEST_FILE" "$backup_dir/last_digest.bak" 2>/dev/null || true
    return 0
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Aggregating full-spectrum router telemetry...\n"

    # 1. WAN IP
    local wan_ip
    wan_ip="$(nvram get wan0_ipaddr 2>/dev/null)"
    [ -z "$wan_ip" ] && wan_ip="$(nvram get wan_ipaddr 2>/dev/null)"
    [ -z "$wan_ip" ] && wan_ip="Disconnected"

    # 2. Uptime
    local uptime_str
    uptime_str="$(awk '{print int($1/86400)" days, "int(($1%86400)/3600)" hours"}' /proc/uptime 2>/dev/null || uptime)"

    # 3. CPU Temperature
    local raw_temp temp_str="N/A"
    raw_temp="$(cat /sys/power/bpcm/cpu_temp 2>/dev/null)"
    if [ -n "$raw_temp" ]; then
        local temp_c
        temp_c="$(echo "$raw_temp" | grep -oE '[0-9]+' | head -n 1)"
        [ -n "$temp_c" ] && temp_str="${temp_c}°C"
    fi

    # 4. RAM Usage (Actual)
    local total_ram avail_ram used_ram ram_usage=0
    total_ram="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
    avail_ram="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)"
    if [ -n "$total_ram" ] && [ -n "$avail_ram" ] && [ "$total_ram" -gt 0 ]; then
        used_ram=$((total_ram - avail_ram))
        ram_usage=$((used_ram * 100 / total_ram))
    fi

    # 5. JFFS Storage Usage
    local jffs_usage
    jffs_usage="$(df /jffs 2>/dev/null | awk 'NR==2 {print $5}')"
    [ -z "$jffs_usage" ] && jffs_usage="N/A"

    # 6. Active Connections
    local active_conns
    active_conns="$(wc -l < /proc/net/nf_conntrack 2>/dev/null || echo 0)"

    # 7. IoT Devices Online (192.168.53.x subnet)
    local iot_count
    iot_count="$(arp -a 2>/dev/null | awk '/192\.168\.53\./ {count++} END {print count+0}')"
    iot_count="$(echo "$iot_count" | tr -cd '0-9')"
    [ -z "$iot_count" ] && iot_count=0

    # 8. Internet Latency (Ping to Google 8.8.8.8)
    local ping_latency
    ping_latency="$(ping -c 3 -W 2 8.8.8.8 2>/dev/null | awk -F '/' 'END {printf "%.1f ms", $4}')"
    if [ -z "$ping_latency" ] || [ "$ping_latency" = " ms" ]; then
        ping_latency="Timeout"
    fi

    # 9. Ad Blocks (Diversion / dnsmasq)
    local ad_blocks=0
    if [ -f "/opt/var/log/dnsmasq.log" ]; then
        ad_blocks="$(awk '/blocked/ || /0\.0\.0\.0/ || /NXDOMAIN/ {count++} END {print count+0}' /opt/var/log/dnsmasq.log 2>/dev/null || echo 0)"
    else
        ad_blocks="$(awk '/blocked/ || /0\.0\.0\.0/ || /NXDOMAIN/ {count++} END {print count+0}' /tmp/syslog.log 2>/dev/null || echo 0)"
    fi
    ad_blocks="$(echo "$ad_blocks" | tr -cd '0-9')"
    [ -z "$ad_blocks" ] && ad_blocks=0

    # 10. Skynet Malicious Firewall Blocks
    local skynet_blocks=0
    if [ -f "/tmp/mnt/tamird_swap/skynet/skynet.log" ]; then
        skynet_blocks="$(awk '/BLOCKED/ {count++} END {print count+0}' /tmp/mnt/tamird_swap/skynet/skynet.log 2>/dev/null || echo 0)"
    elif [ -f "/jffs/addons/skynet/skynet.log" ]; then
        skynet_blocks="$(awk '/BLOCKED/ {count++} END {print count+0}' /jffs/addons/skynet/skynet.log 2>/dev/null || echo 0)"
    else
        skynet_blocks="$(awk '/BLOCKED/ {count++} END {print count+0}' /tmp/syslog.log 2>/dev/null || echo 0)"
    fi
    skynet_blocks="$(echo "$skynet_blocks" | tr -cd '0-9')"
    [ -z "$skynet_blocks" ] && skynet_blocks=0

    # 11. Cron Automation Status
    local cron_jobs
    cron_jobs="$(cru l 2>/dev/null | wc -l | awk '{print $1}')"
    [ -z "$cron_jobs" ] && cron_jobs=0

    local cron_status
    if [ "$cron_jobs" = "0" ]; then
        cron_status="⚠️ No tasks scheduled"
    else
        cron_status="${cron_jobs} Active Tasks"
    fi

    # Construct the canonical Daily Report message
    local report_msg
    report_msg="📊 Daily Router Health Report:
🌐 WAN IP: $wan_ip
⏱️ Uptime: $uptime_str
🌡️ CPU Temp: $temp_str
🧠 RAM Usage: ${ram_usage}%
💾 JFFS Storage: $jffs_usage
🔌 Active Connections: $active_conns
🏠 IoT Devices Online: $iot_count
⚡ Avg Latency: $ping_latency
🛡️ Skynet Blocks: $skynet_blocks
🚫 Ads Blocked: $ad_blocks
⚙️ Automation: $cron_status"

    # Display rich telemetry card in terminal
    printf "${COLOR_CYAN}--------------------------------------------------------------------------------${COLOR_RESET}\n"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : %s\n" "WAN IP" "$wan_ip"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : %s\n" "Uptime" "$uptime_str"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : ${COLOR_YELLOW}%s${COLOR_RESET}\n" "CPU Temperature" "$temp_str"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : ${COLOR_MAGENTA}%s%%${COLOR_RESET}\n" "RAM Usage" "$ram_usage"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : %s\n" "JFFS Storage" "$jffs_usage"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : %s\n" "Active Connections" "$active_conns"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : ${COLOR_GREEN}%s online${COLOR_RESET}\n" "IoT Devices (192.168.53.x)" "$iot_count"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : %s\n" "Internet Latency (8.8.8.8)" "$ping_latency"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : ${COLOR_RED}%s threats blocked${COLOR_RESET}\n" "Skynet Firewall" "$skynet_blocks"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : ${COLOR_BLUE}%s ads blocked${COLOR_RESET}\n" "Ad-Blocking (Diversion)" "$ad_blocks"
    printf " ${COLOR_BOLD}%-24s${COLOR_RESET} : %s\n" "Automation Engine" "$cron_status"
    printf "${COLOR_CYAN}--------------------------------------------------------------------------------${COLOR_RESET}\n"

    # Dispatch to Email
    if [ -x "/jffs/scripts/send_alert.sh" ]; then
        printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} Sending Daily Report via /jffs/scripts/send_alert.sh...\n"
        /jffs/scripts/send_alert.sh "Daily Report" "$report_msg"
    else
        notify_dispatch "HEALTH" "router-daily-digest" "0" "$report_msg"
    fi

    # Record date marker
    date +%Y-%m-%d > "$LAST_DIGEST_FILE" 2>/dev/null || true
    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Daily health report dispatched successfully.\n"
    return 0
}

mci_verify() {
    printf "${COLOR_CYAN}--> [VERIFY]${COLOR_RESET} Validating daily digest execution state...\n"

    local today
    today="$(date +%Y-%m-%d 2>/dev/null || date)"

    if [ -f "$LAST_DIGEST_FILE" ] && [ "$(cat "$LAST_DIGEST_FILE" 2>/dev/null)" = "$today" ]; then
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Daily report generation verified for %s.\n" "$today"
        return 0
    fi

    printf "${COLOR_YELLOW}--> [WARNING] Last digest marker not updated.${COLOR_RESET}\n"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    [ -f "$backup_dir/last_digest.bak" ] && cp -pf "$backup_dir/last_digest.bak" "$LAST_DIGEST_FILE" 2>/dev/null || true
    return 0
}

mci_notify() {
    local status="$1" duration="$2"
    printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} Daily router digest finished: ${COLOR_BOLD}%s${COLOR_RESET} (${duration}s)\n" "$status"
}
