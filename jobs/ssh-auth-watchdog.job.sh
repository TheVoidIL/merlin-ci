#!/bin/sh
# ==============================================================================
# Merlin-CI: SSH Authentication Defender & LAN Brute-Force Watchdog
# ==============================================================================
# Monitors router syslog for failed SSH authentication attempts (Dropbear).
# Defense Policy:
# 1. External (WAN) attacks: Immediate iptables DROP & security alert.
# 2. Local (LAN) attacks:
#    - Allows up to 3 failed attempts (e.g. encrypted key unlocking).
#    - Successful login immediately resets failure counter to 0.
#    - 3 consecutive failed attempts: Rejects SSH access from that LAN IP
#      for 5 minutes (300s) via kernel ipset timeout & iptables TCP reset.
#    - Dispatches instant high-priority security alert.
# ==============================================================================

JOB_NAME="ssh-auth-watchdog"
JOB_DESCRIPTION="Security defender: detects SSH brute-force attacks in syslog and defends router"
JOB_ENABLED=1
JOB_TYPE="watchdog"

FAILED_THRESHOLD=5
LAN_FAIL_LIMIT=3
LAN_BLOCK_TIMEOUT=300
STATE_FILE="/jffs/scripts/ssh_log_state.txt"
SYSLOG_FILE="/tmp/syslog.log"
AUDIT_LOG="${MCI_LOG_DIR:-/opt/var/merlin-ci/logs}/blocked_ssh_ips.txt"
ATTACKERS_FOUND_FILE="/tmp/mci_attackers_$$.txt"
LAN_BLOCKED_QUEUE_FILE="/tmp/mci_lan_blocked_$$.txt"
LAN_FAILS_DIR="/tmp/mci_ssh_lan_fails"
LAN_IPSET_NAME="mci_ssh_lan_block"
NEW_EVENTS_FILE="/tmp/mci_login_events_$$.txt"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

_extract_new_auth_events() {
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

    mkdir -p "$LAN_FAILS_DIR" 2>/dev/null || true

    local start_line=$((last_line + 1))
    local raw_chunk
    raw_chunk=$(sed -n "${start_line},\$p" "$SYSLOG_FILE" 2>/dev/null | grep -Ei "dropbear|httpd|web:")

    [ -z "$raw_chunk" ] && return 1

    # 1. Reset LAN fail count on any successful login
    local success_lan_ips
    success_lan_ips=$(echo "$raw_chunk" | grep -Ei "Pubkey auth succeeded|auth succeeded|Login completed" | \
        grep -oE "from (<?)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | tr -d '<' | awk '{print $2}' | sort -u)
    for s_ip in $success_lan_ips; do
        case "$s_ip" in
            192.168.*|10.*|127.0.0.1|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                rm -f "$LAN_FAILS_DIR/$s_ip" 2>/dev/null || true
                ;;
        esac
    done

    # 2. Track failed attempts originating from LAN
    local failed_lan_events
    failed_lan_events=$(echo "$raw_chunk" | grep -Ei "bad password|Login failed|auth failed|Pubkey auth failed|Exit before auth.*[1-9][0-9]* fails")
    if [ -n "$failed_lan_events" ]; then
        local fail_ips
        fail_ips=$(echo "$failed_lan_events" | grep -oE "from (<?)[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | tr -d '<' | awk '{print $2}')
        for f_ip in $fail_ips; do
            case "$f_ip" in
                192.168.*|10.*|127.0.0.1|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                    local prev_fails
                    prev_fails=$(cat "$LAN_FAILS_DIR/$f_ip" 2>/dev/null || echo 0)
                    prev_fails=$((prev_fails + 1))
                    echo "$prev_fails" > "$LAN_FAILS_DIR/$f_ip"
                    if [ "$prev_fails" -ge "$LAN_FAIL_LIMIT" ]; then
                        echo "$f_ip $prev_fails" >> "$LAN_BLOCKED_QUEUE_FILE"
                        rm -f "$LAN_FAILS_DIR/$f_ip" 2>/dev/null || true
                    fi
                    ;;
            esac
        done
    fi

    # 3. Output filtered events for alerting (exclude benign LAN activity)
    echo "$raw_chunk" | \
        grep -Ei "bad password|Login attempt|auth succeeded|Login completed|Login failed|Exit before auth|auth failed|login attempt for nonexistent user" | \
        grep -v -E "dropbear.*(Pubkey )?auth (succeeded|failed) for .* from (192\.168\.|10\.|127\.0\.0\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.)" | \
        grep -v -E "dropbear.*Exit before auth from <(192\.168\.|10\.|127\.0\.0\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.).*>: \(user 'tamird', [0-9]+ fails\)" | \
        grep -v -E "dropbear.*Exit before auth from <(192\.168\.|10\.|127\.0\.0\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.).*>: \(user '[^']*', 0 fails\)" | \
        grep -v -E "httpd: Login completed from (192\.168\.|10\.|127\.0\.0\.1|172\.(1[6-9]|2[0-9]|3[0-1])\.)" \
        > "$target_out" 2>/dev/null || true
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[AUTH-WATCHDOG]${COLOR_RESET} Inspecting syslog for new SSH and WebUI login events...\n"

    rm -f "$ATTACKERS_FOUND_FILE" "$LAN_BLOCKED_QUEUE_FILE" "$NEW_EVENTS_FILE"

    _extract_new_auth_events "$NEW_EVENTS_FILE"

    local triggered=0

    # 1. Check if LAN limit was reached (3 fails)
    if [ -s "$LAN_BLOCKED_QUEUE_FILE" ]; then
        while read -r l_ip l_fails; do
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}LAN IP %s exceeded %d failed SSH key attempts (%d fails)!${COLOR_RESET}\n" \
                "$l_ip" "$LAN_FAIL_LIMIT" "$l_fails"
        done < "$LAN_BLOCKED_QUEUE_FILE"
        triggered=1
    fi

    # 2. Check for brute-force attacks from external WAN IPs
    if [ -s "$NEW_EVENTS_FILE" ]; then
        local attacker_ips
        attacker_ips=$(grep -Ei "bad password|Login failed|auth failed|login attempt for nonexistent user" "$NEW_EVENTS_FILE" 2>/dev/null | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u)
        if [ -n "$attacker_ips" ]; then
            local external_ips=""
            for ip in $attacker_ips; do
                case "$ip" in
                    127.0.0.1|0.0.0.0|192.168.*|10.*) continue ;;
                    *) external_ips="$external_ips $ip" ;;
                esac
            done
            if [ -n "$external_ips" ]; then
                echo "$external_ips" > "$ATTACKERS_FOUND_FILE"
                triggered=1
            fi
        fi
    fi

    if [ "$triggered" -eq 1 ]; then
        return 0
    fi

    # Advance state file cursor so we don't re-read the same benign syslog lines
    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"
    rm -f "$NEW_EVENTS_FILE"
    printf "${COLOR_GREEN}--> [AUTH-WATCHDOG]${COLOR_RESET} No security-sensitive login events. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    mkdir -p "$backup_dir" 2>/dev/null || true
    if [ -f "$NEW_EVENTS_FILE" ]; then
        cp -f "$NEW_EVENTS_FILE" "$backup_dir/login_events.txt" 2>/dev/null || true
    fi
    if [ -f "$LAN_BLOCKED_QUEUE_FILE" ]; then
        cp -f "$LAN_BLOCKED_QUEUE_FILE" "$backup_dir/lan_blocked_queue.txt" 2>/dev/null || true
    fi
    [ -f "$STATE_FILE" ] && cp -f "$STATE_FILE" "$backup_dir/ssh_log_state.bak" 2>/dev/null || true
    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Forensic snapshot recorded in %s\n" "$backup_dir"
    return 0
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Processing router login events and applying defensive rules...\n"

    local now_ts
    now_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true

    local sshd_port
    sshd_port="$(nvram get sshd_port 2>/dev/null || echo 1025)"
    [ -z "$sshd_port" ] && sshd_port=1025

    # Step 1: Enforce 5-minute Netfilter block for LAN IPs exceeding 3 failed attempts
    if [ -s "$LAN_BLOCKED_QUEUE_FILE" ]; then
        ipset create "$LAN_IPSET_NAME" hash:ip timeout "$LAN_BLOCK_TIMEOUT" -exist 2>/dev/null || true

        while read -r l_ip l_fails; do
            [ -z "$l_ip" ] && continue
            printf "--> ${COLOR_RED}[DEFENDER] LAN IP %s reached %s failed attempts. Rejecting SSH for %ds (5 min)...${COLOR_RESET}\n" \
                "$l_ip" "$l_fails" "$LAN_BLOCK_TIMEOUT"

            ipset add "$LAN_IPSET_NAME" "$l_ip" timeout "$LAN_BLOCK_TIMEOUT" -exist 2>/dev/null || true
            echo "[$now_ts] LAN_SSH_REJECT (5 min): $l_ip ($l_fails failed attempts)" >> "$AUDIT_LOG"

            # Inject immediate TCP-Reset reject rule into INPUT chain
            if ! iptables -C INPUT -p tcp --dport "$sshd_port" -m set --match-set "$LAN_IPSET_NAME" src -j REJECT --reject-with tcp-reset >/dev/null 2>&1; then
                iptables -I INPUT 1 -p tcp --dport "$sshd_port" -m set --match-set "$LAN_IPSET_NAME" src -j REJECT --reject-with tcp-reset 2>/dev/null || true
            fi

            # Dispatch immediate security alert
            local alert_msg="LAN Security Alert!
Device IP: $l_ip has exceeded $LAN_FAIL_LIMIT failed SSH key attempts ($l_fails attempts).
Defense Enforced: SSH connection (port $sshd_port) rejected for 5 minutes.
Timestamp: $now_ts"

            if [ -x "/jffs/scripts/send_alert.sh" ]; then
                /jffs/scripts/send_alert.sh "LAN Security: SSH Rejected (5 min)" "$alert_msg"
            else
                notify_dispatch "SECURITY" "ssh-auth-watchdog" "0" "$alert_msg"
            fi
        done < "$LAN_BLOCKED_QUEUE_FILE"
    fi

    # Step 2: Active Firewall Defense against external brute-force IPs (permanent DROP)
    if [ -s "$ATTACKERS_FOUND_FILE" ]; then
        local ext_ips
        ext_ips=$(cat "$ATTACKERS_FOUND_FILE")
        if [ -n "$ext_ips" ]; then
            for ip in $ext_ips; do
                if ! iptables -C INPUT -s "$ip" -j DROP >/dev/null 2>&1; then
                    printf "--> ${COLOR_RED}[DEFENDER] Blocking external brute-force IP %s via iptables DROP...${COLOR_RESET}\n" "$ip"
                    iptables -I INPUT 1 -s "$ip" -j DROP 2>/dev/null || true
                    echo "[$now_ts] BLOCKED_WAN: $ip" >> "$AUDIT_LOG"
                fi
            done

            local ext_alert="External Attack Alert!
Offending IP(s): $ext_ips
Defense Enforced: iptables DROP rule injected.
Timestamp: $now_ts"
            if [ -x "/jffs/scripts/send_alert.sh" ]; then
                /jffs/scripts/send_alert.sh "Security Alert: WAN Brute-Force Blocked" "$ext_alert"
            else
                notify_dispatch "SECURITY" "ssh-auth-watchdog" "0" "$ext_alert"
            fi
        fi
    fi

    # Step 3: Advance cursor state
    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"

    rm -f "$ATTACKERS_FOUND_FILE" "$LAN_BLOCKED_QUEUE_FILE" "$NEW_EVENTS_FILE"
    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Login events processed and log cursor advanced.\n"
    return 0
}

mci_verify() {
    printf "${COLOR_CYAN}--> [VERIFY]${COLOR_RESET} Verifying firewall integrity and cursor pointer...\n"

    if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
        printf "${COLOR_RED}--> [FAIL] State file %s is missing or empty!${COLOR_RESET}\n" "$STATE_FILE"
        return 1
    fi

    # Ensure iptables INPUT chain is intact
    if ! iptables -L INPUT -n >/dev/null 2>&1; then
        printf "${COLOR_RED}--> [FAIL] iptables INPUT chain error!${COLOR_RESET}\n"
        return 1
    fi

    # Ensure ipset mci_ssh_lan_block is valid if initialized
    if ipset list "$LAN_IPSET_NAME" >/dev/null 2>&1; then
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} LAN defender ipset %s is active.\n" "$LAN_IPSET_NAME"
    fi

    printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} State cursor and defensive firewall verified.\n"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    if [ -f "$backup_dir/ssh_log_state.bak" ]; then
        cp -pf "$backup_dir/ssh_log_state.bak" "$STATE_FILE" 2>/dev/null || true
    fi
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] SSH authentication defender finished: $status (${duration}s)"
}
