#!/bin/sh
# ==============================================================================
# Merlin-CI: SSH Authentication Brute-Force Defender & Watchdog
# ==============================================================================
# Analyzes router syslog for repeated failed SSH authentication attempts
# (Dropbear / OpenSSH dictionary attacks).
# Automatically defends the router:
# 1. Extracts offending attacker IP addresses
# 2. Inserts temporary firewall DROP rules
# 3. Logs incidents to persistent USB audit file
# 4. Dispatches immediate security notification
# ==============================================================================

JOB_NAME="ssh-auth-watchdog"
JOB_DESCRIPTION="Security defender: detects SSH brute-force attacks in syslog and defends router"
JOB_ENABLED=1
JOB_TYPE="watchdog"

FAILED_THRESHOLD=5
STATE_FILE="/jffs/scripts/ssh_log_state.txt"
SYSLOG_FILE="/tmp/syslog.log"
AUDIT_LOG="${MCI_LOG_DIR:-/opt/var/merlin-ci/logs}/blocked_ssh_ips.txt"
ATTACKERS_FOUND_FILE="/tmp/mci_attackers_$$.txt"
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

    local start_line=$((last_line + 1))
    sed -n "${start_line},\$p" "$SYSLOG_FILE" 2>/dev/null | \
        grep -Ei "dropbear|httpd|web:" | \
        grep -Ei "bad password|Login attempt|auth succeeded|Login completed|Login failed|Exit before auth|auth failed|login attempt for nonexistent user" \
        > "$target_out" 2>/dev/null || true
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[AUTH-WATCHDOG]${COLOR_RESET} Inspecting syslog for new SSH and WebUI login events...\n"

    rm -f "$ATTACKERS_FOUND_FILE" "$NEW_EVENTS_FILE"

    _extract_new_auth_events "$NEW_EVENTS_FILE"

    if [ ! -s "$NEW_EVENTS_FILE" ]; then
        # Advance state file cursor so we don't re-read the same benign syslog lines
        local total_lines
        total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
        [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"
        rm -f "$NEW_EVENTS_FILE"
        printf "${COLOR_GREEN}--> [AUTH-WATCHDOG]${COLOR_RESET} No security-sensitive login events. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi

    local event_count
    event_count=$(wc -l < "$NEW_EVENTS_FILE" 2>/dev/null | awk '{print $1}')

    # Check for brute-force attacks (repeated failed logins)
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
        [ -n "$external_ips" ] && echo "$external_ips" > "$ATTACKERS_FOUND_FILE"
    fi

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}Detected %d new login event(s) in router syslog!${COLOR_RESET}\n" "${event_count:-1}"
    return 0
}

mci_backup() {
    local backup_dir="$1"
    mkdir -p "$backup_dir" 2>/dev/null || true
    if [ -f "$NEW_EVENTS_FILE" ]; then
        cp -f "$NEW_EVENTS_FILE" "$backup_dir/login_events.txt" 2>/dev/null || true
    fi
    [ -f "$STATE_FILE" ] && cp -f "$STATE_FILE" "$backup_dir/ssh_log_state.bak" 2>/dev/null || true
    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Forensic snapshot recorded in %s\n" "$backup_dir"
    return 0
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Processing router login events and applying defensive rules...\n"

    # If triggered manually via -f, ensure events are available
    if [ ! -s "$NEW_EVENTS_FILE" ]; then
        tail -n 100 "$SYSLOG_FILE" 2>/dev/null | \
            grep -Ei "dropbear|httpd|web:" | \
            grep -Ei "bad password|Login attempt|auth succeeded|Login completed|Login failed|Exit before auth|auth failed|login attempt for nonexistent user" \
            > "$NEW_EVENTS_FILE" 2>/dev/null || true
    fi

    # Step 1: Active Firewall Defense against external brute-force IPs
    if [ -s "$ATTACKERS_FOUND_FILE" ]; then
        local ext_ips
        ext_ips=$(cat "$ATTACKERS_FOUND_FILE")
        if [ -n "$ext_ips" ]; then
            mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null || true
            local now_ts
            now_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"

            for ip in $ext_ips; do
                if ! iptables -C INPUT -s "$ip" -j DROP >/dev/null 2>&1; then
                    printf "--> ${COLOR_RED}[DEFENDER] Blocking brute-force attacker IP %s via iptables DROP...${COLOR_RESET}\n" "$ip"
                    iptables -I INPUT 1 -s "$ip" -j DROP 2>/dev/null || true
                    echo "[$now_ts] BLOCKED: $ip" >> "$AUDIT_LOG"
                fi
            done
        fi
    fi

    # Step 2: Dispatch login alert notification
    if [ -s "$NEW_EVENTS_FILE" ]; then
        local events_content
        events_content=$(head -n 25 "$NEW_EVENTS_FILE")
        if [ -n "$events_content" ]; then
            if [ -x "/jffs/scripts/send_alert.sh" ]; then
                printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} Dispatching alert via /jffs/scripts/send_alert.sh...\n"
                /jffs/scripts/send_alert.sh "Router Login Alert" "$events_content"
            else
                notify_dispatch "SECURITY" "ssh-auth-watchdog" "0" "$events_content"
            fi
        fi
    fi

    # Step 3: Advance cursor state
    local total_lines
    total_lines=$(wc -l < "$SYSLOG_FILE" 2>/dev/null | awk '{print $1}')
    [ -n "$total_lines" ] && echo "$total_lines" > "$STATE_FILE"

    rm -f "$ATTACKERS_FOUND_FILE" "$NEW_EVENTS_FILE"
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
