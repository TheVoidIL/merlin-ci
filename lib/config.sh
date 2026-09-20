#!/bin/sh
# ==============================================================================
# Merlin-CI: Configuration Management Library (lib/config.sh)
# ==============================================================================

MCI_CONFIG_DIR="/jffs/addons/merlin-ci"
MCI_CONFIG_FILE="${MCI_CONFIG_DIR}/merlin-ci.conf"
MCI_LOCAL_CONF="./merlin-ci.conf"

config_find_usb_storage() {
    if [ -d "/opt" ] && [ -w "/opt" ]; then
        echo "/opt/var/merlin-ci"
        return 0
    fi

    local usb_mount
    usb_mount="$(df -k 2>/dev/null | awk '/\/tmp\/mnt\// {print $6; exit}')"
    if [ -n "$usb_mount" ] && [ -d "$usb_mount" ] && [ -w "$usb_mount" ]; then
        echo "${usb_mount}/merlin-ci"
        return 0
    fi

    echo "/tmp/merlin-ci"
}

config_set_defaults() {
    MCI_ENABLED="${MCI_ENABLED:-1}"

    # Embedded Optimization: 1 = Lean memory/CPU usage for low-spec routers
    MCI_EMBEDDED_MODE="${MCI_EMBEDDED_MODE:-1}"

    local default_storage
    default_storage="$(config_find_usb_storage)"

    MCI_STORAGE_BASE="${MCI_STORAGE_BASE:-$default_storage}"
    MCI_LOG_DIR="${MCI_LOG_DIR:-${MCI_STORAGE_BASE}/logs}"
    MCI_BACKUP_DIR="${MCI_BACKUP_DIR:-${MCI_STORAGE_BASE}/backups}"
    MCI_MAX_LOG_HISTORY="${MCI_MAX_LOG_HISTORY:-10}"

    # Default jobs directory
    if [ -d "/jffs/addons/merlin-ci/jobs" ]; then
        MCI_JOBS_DIR="${MCI_JOBS_DIR:-/jffs/addons/merlin-ci/jobs}"
    else
        MCI_JOBS_DIR="${MCI_JOBS_DIR:-./jobs}"
    fi

    # Execution Mode: "cron" (zero background RAM) or "daemon"
    MCI_EXEC_MODE="${MCI_EXEC_MODE:-cron}"
    MCI_CHECK_INTERVAL="${MCI_CHECK_INTERVAL:-3600}"
    MCI_CRON_SCHEDULE="${MCI_CRON_SCHEDULE:-0 4 * * *}"

    # Resource Guardrails
    MCI_MAX_LOADAVG="${MCI_MAX_LOADAVG:-2.50}"
    MCI_MIN_FREE_RAM_MB="${MCI_MIN_FREE_RAM_MB:-32}" # Lowered for low-memory 256MB/512MB routers
    MCI_JOB_TIMEOUT="${MCI_JOB_TIMEOUT:-600}"
    MCI_NICE_LEVEL="${MCI_NICE_LEVEL:-19}"

    # Email (SMTP) Notifications
    MCI_EMAIL_ENABLED="${MCI_EMAIL_ENABLED:-0}"
    MCI_SMTP_SERVER="${MCI_SMTP_SERVER:-smtp.gmail.com}"
    MCI_SMTP_PORT="${MCI_SMTP_PORT:-465}"
    MCI_SMTP_USER="${MCI_SMTP_USER:-}"
    MCI_SMTP_PASS="${MCI_SMTP_PASS:-}"
    MCI_SMTP_FROM="${MCI_SMTP_FROM:-}"
    MCI_SMTP_TO="${MCI_SMTP_TO:-}"
    MCI_SMTP_TLS="${MCI_SMTP_TLS:-1}"
    # Notification Frequency: 0 = Single summary email upon completion (Recommended), 1 = Two emails (TRIGGERED + SUCCESS)
    MCI_NOTIFY_ON_TRIGGER="${MCI_NOTIFY_ON_TRIGGER:-0}"
    # Notification Policy: 0 = Silent on routine passes (batch into single morning digest), 1 = Send email on each pass
    MCI_NOTIFY_ON_SUCCESS="${MCI_NOTIFY_ON_SUCCESS:-0}"
    # Immediate Alerting: Always dispatch immediate email if a job fails, rolls back, or watchdog heals an anomaly
    MCI_NOTIFY_ON_FAILURE="${MCI_NOTIFY_ON_FAILURE:-1}"
    MCI_NOTIFY_ON_HEAL="${MCI_NOTIFY_ON_HEAL:-1}"

    # Webhook Notifications
    MCI_DISCORD_WEBHOOK_URL="${MCI_DISCORD_WEBHOOK_URL:-}"
    MCI_TELEGRAM_BOT_TOKEN="${MCI_TELEGRAM_BOT_TOKEN:-}"
    MCI_TELEGRAM_CHAT_ID="${MCI_TELEGRAM_CHAT_ID:-}"
}

config_load() {
    local active_conf=""
    if [ -n "$MCI_CUSTOM_CONF" ] && [ -f "$MCI_CUSTOM_CONF" ]; then
        active_conf="$MCI_CUSTOM_CONF"
    elif [ -f "$MCI_CONFIG_FILE" ]; then
        active_conf="$MCI_CONFIG_FILE"
    elif [ -f "$MCI_LOCAL_CONF" ]; then
        active_conf="$MCI_LOCAL_CONF"
    elif [ -f "/opt/etc/merlin-ci.conf" ]; then
        active_conf="/opt/etc/merlin-ci.conf"
    fi

    if [ -n "$active_conf" ]; then
        # shellcheck disable=SC1090
        . "$active_conf"
        MCI_ACTIVE_CONF_PATH="$active_conf"
    else
        MCI_ACTIVE_CONF_PATH=""
    fi

    config_set_defaults

    mkdir -p "$MCI_LOG_DIR" "$MCI_BACKUP_DIR" 2>/dev/null || true
}

config_init() {
    local target="${1:-$MCI_CONFIG_FILE}"
    local target_dir
    target_dir="$(dirname "$target")"
    mkdir -p "$target_dir" 2>/dev/null || true

    if [ -f "$target" ]; then
        return 0
    fi

    cat << 'EOF' > "$target"
# Merlin-CI Configuration
MCI_ENABLED=1
MCI_EMBEDDED_MODE=1
MCI_EXEC_MODE="cron"
MCI_LOG_DIR="/opt/var/merlin-ci/logs"
MCI_BACKUP_DIR="/opt/var/merlin-ci/backups"
MCI_MAX_LOG_HISTORY=10
MCI_CRON_SCHEDULE="0 4 * * *"
MCI_MAX_LOADAVG="2.50"
MCI_MIN_FREE_RAM_MB=32
MCI_JOB_TIMEOUT=600
MCI_NICE_LEVEL=19
EOF
}

config_set() {
    local key="$1"
    local val="$2"
    local conf_file="${MCI_ACTIVE_CONF_PATH:-$MCI_CONFIG_FILE}"

    [ ! -f "$conf_file" ] && config_init "$conf_file"

    if grep -q "^${key}=" "$conf_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$conf_file"
    else
        printf "\n%s=\"%s\"\n" "$key" "$val" >> "$conf_file"
    fi

    config_load
}

config_set_job_status() {
    local job_name="$1"
    local enabled_val="$2"
    local job_file="${MCI_JOBS_DIR}/${job_name}.job.sh"

    if [ -f "$job_file" ]; then
        sed -i "s|^JOB_ENABLED=.*|JOB_ENABLED=${enabled_val}|" "$job_file"
        echo "--> Job '$job_name' set to JOB_ENABLED=${enabled_val}."
    else
        echo "--> [ERROR] Job file $job_file not found."
    fi
}

config_validate() {
    local issues=0
    case "$MCI_LOG_DIR" in
        /jffs*)
            echo "[WARNING] Log directory is on /jffs ($MCI_LOG_DIR)!"
            echo "          Logs on /jffs wear out flash. Please point to /opt or USB storage."
            issues=$((issues + 1))
            ;;
    esac
    case "$MCI_BACKUP_DIR" in
        /jffs*)
            echo "[WARNING] Backup directory is on /jffs ($MCI_BACKUP_DIR)!"
            echo "          Backups on /jffs wear out flash. Please point to /opt or USB storage."
            issues=$((issues + 1))
            ;;
    esac
    return $issues
}

config_scrape_amtm_email() {
    local target_file="$1"

    SCRAPED_SERVER=""
    SCRAPED_PORT=""
    SCRAPED_USER=""
    SCRAPED_PASS=""
    SCRAPED_FROM=""
    SCRAPED_TO=""
    SCRAPED_SOURCE=""

    _parse_email_file() {
        local f="$1"
        [ ! -f "$f" ] && return 1
        [ ! -r "$f" ] && return 1

        # 1. msmtprc format
        if grep -qi "^[[:space:]]*host[[:space:]]" "$f" 2>/dev/null && grep -qi "^[[:space:]]*user[[:space:]]" "$f" 2>/dev/null; then
            SCRAPED_SERVER="$(awk '/^[[:space:]]*host[[:space:]]+/ {print $2; exit}' "$f")"
            SCRAPED_PORT="$(awk '/^[[:space:]]*port[[:space:]]+/ {print $2; exit}' "$f")"
            SCRAPED_USER="$(awk '/^[[:space:]]*user[[:space:]]+/ {print $2; exit}' "$f")"
            SCRAPED_PASS="$(awk '/^[[:space:]]*password[[:space:]]+/ {print $2; exit}' "$f")"
            SCRAPED_FROM="$(awk '/^[[:space:]]*from[[:space:]]+/ {print $2; exit}' "$f")"
            SCRAPED_TO="$SCRAPED_FROM"
            SCRAPED_SOURCE="$f (msmtprc)"
            return 0
        fi

        # 2. ssmtp.conf format
        if grep -qi "^[[:space:]]*mailhub=" "$f" 2>/dev/null; then
            local hub
            hub="$(awk -F= '/^[[:space:]]*mailhub=/ {print $2; exit}' "$f" | tr -d '"'\'' ')"
            SCRAPED_SERVER="$(echo "$hub" | cut -d: -f1)"
            SCRAPED_PORT="$(echo "$hub" | cut -d: -f2 -s)"
            SCRAPED_USER="$(awk -F= '/^[[:space:]]*AuthUser=/ {print $2; exit}' "$f" | tr -d '"'\'' ')"
            SCRAPED_PASS="$(awk -F= '/^[[:space:]]*AuthPass=/ {print $2; exit}' "$f" | tr -d '"'\'' ')"
            SCRAPED_FROM="$(awk -F= '/^[[:space:]]*root=/ {print $2; exit}' "$f" | tr -d '"'\'' ')"
            SCRAPED_TO="$SCRAPED_FROM"
            SCRAPED_SOURCE="$f (ssmtp.conf)"
            return 0
        fi

        # 3. Shell variables format (e.g. WICENS, Diversion, custom AMTM scripts)
        local s_srv s_prt s_usr s_pwd s_from s_to
        s_srv="$(grep -Ei '^[[:space:]]*(export[[:space:]]+)?(SMTP_SERVER|SMTP_HOST|SMTP|SMTP_RELAY)=' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
        s_prt="$(grep -Ei '^[[:space:]]*(export[[:space:]]+)?(SMTP_PORT|PORT)=["'\'']?[0-9]+' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
        s_usr="$(grep -Ei '^[[:space:]]*(export[[:space:]]+)?(SMTP_USER|SMTP_USERNAME|USERNAME|AUTH_USER)=' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
        s_pwd="$(grep -Ei '^[[:space:]]*(export[[:space:]]+)?(SMTP_PASS|SMTP_PASSWORD|PASSWORD|AUTH_PASS|PASS|PW|PASSWD|SMTPPASS|APP_PASS|USERPASS|USER_PASS)=' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
        s_from="$(grep -Ei '^[[:space:]]*(export[[:space:]]+)?(SMTP_FROM|FROM_ADDRESS|FROM|SENDER)=' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'' ' || true)"
        s_to="$(grep -Ei '^[[:space:]]*(export[[:space:]]+)?(SMTP_TO|TO_ADDRESS|TO|RECIPIENT|TARGET)=' "$f" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'' ' || true)"

        # Check companion password files in same directory (common in AMTM / Unix tools)
        if [ -z "$s_pwd" ]; then
            local p_dir
            p_dir="$(dirname "$f")"
            for pf in "$p_dir/.password" "$p_dir/password" "$p_dir/.pwd" "$p_dir/pwd" "$p_dir/.pass" "$p_dir/pass" "$p_dir/.secret" "$p_dir/secret" "$p_dir/email.pwd" "$p_dir/.email.pwd"; do
                if [ -f "$pf" ] && [ -s "$pf" ]; then
                    s_pwd="$(cat "$pf" 2>/dev/null | tr -d '\r\n')"
                    [ -n "$s_pwd" ] && break
                fi
            done
        fi

        if [ -n "$s_srv" ]; then
            SCRAPED_SERVER="$s_srv"
            SCRAPED_PORT="${s_prt:-465}"
            SCRAPED_USER="$s_usr"
            SCRAPED_PASS="$s_pwd"
            SCRAPED_FROM="$s_from"
            SCRAPED_TO="$s_to"
            SCRAPED_SOURCE="$f"
            return 0
        fi

        # 4. Embedded curl command lines (e.g. curl ... --url smtps://...)
        local curl_line
        curl_line="$(grep -Ei 'curl.*--url[[:space:]]+["'\'']?smtps?://' "$f" 2>/dev/null | head -n1 || true)"
        if [ -n "$curl_line" ]; then
            local s_url
            s_url="$(echo "$curl_line" | grep -oEi 'smtps?://[^ "]+' | head -n1 || true)"
            if [ -n "$s_url" ]; then
                local clean_host
                clean_host="$(echo "$s_url" | sed -E 's|smtps?://||')"
                SCRAPED_SERVER="$(echo "$clean_host" | cut -d: -f1)"
                SCRAPED_PORT="$(echo "$clean_host" | cut -d: -f2 -s)"
                [ -z "$SCRAPED_PORT" ] && SCRAPED_PORT="465"
                local u_part
                u_part="$(echo "$curl_line" | sed -n 's/.*--user[[:space:]]*\([^ ]*\).*/\1/p' | tr -d '"' | tr -d "'")"
                SCRAPED_USER="$(echo "$u_part" | cut -d: -f1)"
                SCRAPED_PASS="$(echo "$u_part" | cut -d: -f2-)"
                SCRAPED_TO="$(echo "$curl_line" | sed -n 's/.*--mail-rcpt[[:space:]]*\([^ ]*\).*/\1/p' | tr -d '"' | tr -d "'")"
                SCRAPED_FROM="$(echo "$curl_line" | sed -n 's/.*--mail-from[[:space:]]*\([^ ]*\).*/\1/p' | tr -d '"' | tr -d "'")"
                SCRAPED_SOURCE="$f (curl command)"
                return 0
            fi
        fi

        return 1
    }

    # If specific file passed, check only that
    if [ -n "$target_file" ]; then
        if _parse_email_file "$target_file"; then
            [ -z "$SCRAPED_TO" ] && SCRAPED_TO="$SCRAPED_USER"
            [ -z "$SCRAPED_FROM" ] && SCRAPED_FROM="${SCRAPED_USER:-merlin-ci@router.local}"
            return 0
        fi
        return 1
    fi

    # 1. Check Asuswrt-Merlin NVRAM
    if command -v nvram >/dev/null 2>&1; then
        local nv_server nv_port nv_user nv_pass nv_from nv_to
        nv_server="$(nvram get pm_smtp_server 2>/dev/null)"
        nv_port="$(nvram get pm_smtp_port 2>/dev/null)"
        nv_user="$(nvram get pm_smtp_auth_user 2>/dev/null)"
        nv_pass="$(nvram get pm_smtp_auth_pass 2>/dev/null)"
        nv_from="$(nvram get pm_smtp_sender 2>/dev/null)"
        nv_to="$(nvram get pm_smtp_target 2>/dev/null)"
        [ -z "$nv_to" ] && nv_to="$(nvram get pm_smtp_recipient 2>/dev/null)"
        [ -z "$nv_to" ] && nv_to="$(nvram get alert_email 2>/dev/null)"
        [ -z "$nv_to" ] && nv_to="$(nvram get mail_to 2>/dev/null)"

        if [ -n "$nv_server" ] && [ "$nv_server" != "0" ]; then
            SCRAPED_SERVER="$nv_server"
            SCRAPED_PORT="${nv_port:-465}"
            SCRAPED_USER="$nv_user"
            SCRAPED_PASS="$nv_pass"
            SCRAPED_FROM="$nv_from"
            SCRAPED_TO="$nv_to"
            SCRAPED_SOURCE="Asuswrt-Merlin NVRAM"
            [ -z "$SCRAPED_TO" ] && SCRAPED_TO="$SCRAPED_USER"
            [ -z "$SCRAPED_FROM" ] && SCRAPED_FROM="${SCRAPED_USER:-merlin-ci@router.local}"
            return 0
        fi
    fi

    # 2. Known configuration candidate paths
    local candidate_files="
        /jffs/configs/email.conf
        /jffs/configs/mail.conf
        /jffs/addons/amtm/email.conf
        /jffs/addons/amtm/mail.conf
        /jffs/addons/amtm/amtm.conf
        /jffs/scripts/email.conf
        /jffs/scripts/mail.conf
        /jffs/scripts/wicens.conf
        /jffs/scripts/wicens
        /jffs/scripts/div-email.sh
        /jffs/scripts/email-notify
        /jffs/addons/diversion/email.conf
        /opt/share/diversion/file/mail.conf
        /opt/etc/msmtprc
        /opt/etc/ssmtp/ssmtp.conf
        /opt/etc/email/email.conf
    "

    for cand in $candidate_files; do
        if _parse_email_file "$cand"; then
            [ -z "$SCRAPED_TO" ] && SCRAPED_TO="$SCRAPED_USER"
            [ -z "$SCRAPED_FROM" ] && SCRAPED_FROM="${SCRAPED_USER:-merlin-ci@router.local}"
            return 0
        fi
    done

    # 3. Dynamic scan in /jffs/scripts, /jffs/configs, and /jffs/addons
    local dynamic_files
    dynamic_files="$(find /jffs/scripts /jffs/configs /jffs/addons /opt/etc /opt/share -maxdepth 3 -type f \( -name "*mail*" -o -name "*email*" -o -name "*smtp*" \) 2>/dev/null || true)"

    for df in $dynamic_files; do
        if _parse_email_file "$df"; then
            [ -z "$SCRAPED_TO" ] && SCRAPED_TO="$SCRAPED_USER"
            [ -z "$SCRAPED_FROM" ] && SCRAPED_FROM="${SCRAPED_USER:-merlin-ci@router.local}"
            return 0
        fi
    done

    return 1
}
