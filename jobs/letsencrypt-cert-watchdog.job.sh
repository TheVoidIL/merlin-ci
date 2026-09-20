#!/bin/sh
# ==============================================================================
# Merlin-CI: Autonomous SSL Certificate & Let's Encrypt Renewal Watchdog
# ==============================================================================
# Monitors router SSL/TLS certificates (Asus DDNS, Let's Encrypt, or WebUI certs)
# to detect imminent expiration. Triggers automated renewal when expiration is
# within 7 days, verifies certificate validity, and prevents WebUI security lockouts.
# ==============================================================================

JOB_NAME="letsencrypt-cert-watchdog"
JOB_DESCRIPTION="Certificate watchdog: detects expiring router SSL certificates and auto-renews"
JOB_ENABLED=1
JOB_TYPE="daily"

CERT_WARN_SECONDS=604800 # 7 days in seconds

_find_active_cert() {
    for c in \
        "/jffs/.cert/cert.pem" \
        "/jffs/ssl/cert.pem" \
        "/etc/cert.pem" \
        "/etc/server.pem"; do
        if [ -f "$c" ] && [ -s "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

_get_openssl_bin() {
    if command -v openssl >/dev/null 2>&1; then
        command -v openssl
    elif [ -x /opt/bin/openssl ]; then
        echo "/opt/bin/openssl"
    elif [ -x /usr/sbin/openssl ]; then
        echo "/usr/sbin/openssl"
    else
        return 1
    fi
}

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[CERT-WATCHDOG]${COLOR_RESET} Inspecting router SSL certificate validity...\n"

    local cert_file
    cert_file="$(_find_active_cert)"

    if [ -z "$cert_file" ]; then
        printf "--> ${COLOR_YELLOW}[CERT-WATCHDOG]${COLOR_RESET} No SSL certificate found in standard locations. ${COLOR_DIM}Skipping.${COLOR_RESET}\n"
        return 1
    fi

    # Verify openssl tool availability
    local openssl_bin
    openssl_bin="$(_get_openssl_bin)"
    if [ -z "$openssl_bin" ]; then
        printf "--> ${COLOR_YELLOW}[CERT-WATCHDOG]${COLOR_RESET} openssl binary not available (run 'opkg install openssl-util' to enable). ${COLOR_DIM}Skipping.${COLOR_RESET}\n"
        return 1
    fi

    # Check if certificate expires within threshold
    if "$openssl_bin" x509 -checkend "$CERT_WARN_SECONDS" -noout -in "$cert_file" >/dev/null 2>&1; then
        local expiry_date
        expiry_date="$("$openssl_bin" x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
        printf "${COLOR_GREEN}--> [CERT-WATCHDOG]${COLOR_RESET} SSL certificate is valid until: ${COLOR_GREEN}%s${COLOR_RESET}. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$expiry_date"
        return 1
    fi

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}SSL certificate at %s is expired or expiring within 7 days!${COLOR_RESET}\n" "$cert_file"
    ACTIVE_CERT_FILE="$cert_file"
    return 0
}

mci_backup() {
    local backup_dir="$1"
    local cert_file="${ACTIVE_CERT_FILE:-$(_find_active_cert)}"

    echo "--> [BACKUP] Backing up existing SSL certificate to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    if [ -n "$cert_file" ] && [ -f "$cert_file" ]; then
        cp -pf "$cert_file" "$backup_dir/cert.pem.bak" 2>/dev/null || true
        local cert_dir
        cert_dir="$(dirname "$cert_file")"
        [ -f "${cert_dir}/key.pem" ] && cp -pf "${cert_dir}/key.pem" "$backup_dir/" 2>/dev/null || true
    fi

    echo "   [OK] SSL certificate snapshot saved."
    return 0
}

mci_run() {
    echo "--> [RUN] Triggering router SSL certificate renewal..."

    # If Asus DDNS / Let's Encrypt is enabled, trigger renewal via system service
    local ddns_enable
    ddns_enable="$(nvram get ddns_enable_x 2>/dev/null)"
    local le_enable
    le_enable="$(nvram get le_enable 2>/dev/null)"

    if [ "$ddns_enable" = "1" ] || [ "$le_enable" = "1" ]; then
        echo "--> [RENEW] Triggering Let's Encrypt refresh through Asuswrt service..."
        service restart_httpd >/dev/null 2>&1 || true
        sleep 5
    fi

    # If custom acme / cert script exists in /jffs/scripts/
    if [ -x /jffs/scripts/le-renew ]; then
        echo "--> [RENEW] Executing /jffs/scripts/le-renew..."
        sh /jffs/scripts/le-renew >/dev/null 2>&1 || true
        sleep 3
    fi

    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running CI smoke tests on renewed SSL certificate..."

    local cert_file
    cert_file="$(_find_active_cert)"

    if [ -z "$cert_file" ]; then
        echo "--> [FAIL] No active certificate found post-renewal!"
        return 1
    fi

    local openssl_bin
    openssl_bin="$(_get_openssl_bin)"
    if [ -z "$openssl_bin" ]; then
        echo "--> [FAIL] openssl binary not available for verification!"
        return 1
    fi

    # Verify certificate is valid for at least 7 days
    if ! "$openssl_bin" x509 -checkend "$CERT_WARN_SECONDS" -noout -in "$cert_file" >/dev/null 2>&1; then
        echo "--> [FAIL] Certificate still reports expiration within 7 days!"
        return 1
    fi

    local new_expiry
    new_expiry="$("$openssl_bin" x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)"
    echo "   [PASS] SSL certificate renewed successfully (New Expiry: $new_expiry)."

    # Verify WebUI is still listening
    if ! pidof httpd >/dev/null 2>&1 && ! pidof httpds >/dev/null 2>&1; then
        echo "--> [WARNING] Router web server is still reloading."
    else
        echo "   [PASS] Router web server active with renewed certificate."
    fi

    echo "--> [VERIFY] SSL certificate renewal verified!"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Restoring previous SSL certificate from backup..."

    local cert_file
    cert_file="$(_find_active_cert)"

    if [ -f "$backup_dir/cert.pem.bak" ] && [ -n "$cert_file" ]; then
        cp -pf "$backup_dir/cert.pem.bak" "$cert_file" 2>/dev/null || true
        service restart_httpd >/dev/null 2>&1 || true
    fi

    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] SSL certificate watchdog completed: $status (${duration}s)"
}
