#!/bin/sh
# ==============================================================================
# Merlin-CI: Notification & Status Reporting Library (lib/notify.sh)
# Supports Email (SMTP/curl/sendmail), Discord, and Telegram
# ==============================================================================

notify_email() {
    local status="$1"
    local job_name="$2"
    local duration="$3"
    local log_snippet="$4"
    local old_version="$5"
    local new_version="$6"

    local email_log="${MCI_LOG_DIR:-/tmp/merlin-ci/logs}/email.log"
    mkdir -p "$(dirname "$email_log")" 2>/dev/null || true

    local now_ts
    now_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"

    if [ "$MCI_EMAIL_ENABLED" != "1" ]; then
        echo "[$now_ts] [SKIP] Email disabled (MCI_EMAIL_ENABLED=$MCI_EMAIL_ENABLED)" >> "$email_log"
        return 0
    fi

    if [ -z "$MCI_SMTP_TO" ] || [ -z "$MCI_SMTP_SERVER" ]; then
        echo "[$now_ts] [ERROR] Incomplete config: Server='${MCI_SMTP_SERVER}', To='${MCI_SMTP_TO}'" >> "$email_log"
        echo "--> [NOTIFY ERROR] Incomplete email configuration (Server or Recipient missing)."
        return 1
    fi

    local router_name router_fw
    router_name="$(nvram get productid 2>/dev/null || uname -m)"
    router_fw="$(nvram get buildno 2>/dev/null)_$(nvram get extendno 2>/dev/null)"
    [ "$router_fw" = "_" ] && router_fw="$(uname -r)"

    # Format Subject line dynamically
    local subject=""
    case "$status" in
        TRIGGERED|triggered)
            if [ -n "$old_version" ] && [ -n "$new_version" ]; then
                subject="[Merlin-CI] TRIGGERED: ${job_name} Upgrade (${old_version} -> ${new_version})"
            else
                subject="[Merlin-CI] TRIGGERED: Job ${job_name} on ${router_name}"
            fi
            ;;
        SUCCESS|success)
            if [ -n "$old_version" ] && [ -n "$new_version" ]; then
                subject="[Merlin-CI] SUCCESS: ${job_name} Upgraded (${old_version} -> ${new_version})"
            else
                subject="[Merlin-CI] SUCCESS: Job ${job_name} Completed on ${router_name}"
            fi
            ;;
        HEALED|healed)
            subject="[Merlin-CI] HEALED: Watchdog ${job_name} Auto-Repaired on ${router_name}"
            ;;
        ROLLED_BACK|rolled_back)
            subject="[Merlin-CI] ROLLED BACK: Job ${job_name} on ${router_name}"
            ;;
        FAILED|failed)
            subject="[Merlin-CI] FAILED: Job ${job_name} on ${router_name}"
            ;;
        TEST|test)
            subject="[Merlin-CI] Test Notification from ${router_name}"
            ;;
        *)
            subject="[Merlin-CI] ${status}: Job ${job_name} on ${router_name}"
            ;;
    esac

    local version_info=""
    if [ -n "$old_version" ] || [ -n "$new_version" ]; then
        version_info="--------------------------------------------------------------------------------
Version Information:
  Old / Current Version : ${old_version:-N/A}
  New / Target Version  : ${new_version:-N/A}
--------------------------------------------------------------------------------
"
    fi

    local action_summary=""
    case "$status" in
        TRIGGERED|triggered)
            action_summary="Action: Trigger condition met. Pipeline execution has started (Pre-flight backup -> Action -> Smoke test verification)."
            ;;
        HEALED|healed)
            action_summary="Action: Autonomous Watchdog detected an anomaly, executed self-healing recovery, and verified nominal state restored."
            ;;
        SUCCESS|success)
            action_summary="Action: All pipeline stages completed and CI smoke tests verified successfully!"
            ;;
        ROLLED_BACK|rolled_back)
            action_summary="Action: Verification failed! Automated rollback successfully restored pre-flight backup."
            ;;
        FAILED|failed)
            action_summary="Action: Job execution failed. Check log snippet below."
            ;;
        TEST|test)
            action_summary="Action: Manual verification test of Merlin-CI notification pipeline."
            ;;
    esac

    local badge_bg="#10b981" # Green
    case "$status" in
        SUCCESS|success|PASS|pass|RESOLVED|resolved|HEALED|healed) badge_bg="#10b981" ;; # Green
        FAILED|failed|FAIL|fail) badge_bg="#ef4444" ;; # Red
        TRIGGERED|triggered) badge_bg="#f59e0b" ;; # Amber/Orange
        ROLLED_BACK|rolled_back) badge_bg="#f59e0b" ;; # Amber/Orange
        *) badge_bg="#10b981" ;; # Green
    esac

    local esc_char
    esc_char="$(printf '\033')"

    # Prepare sanitized plain text log snippet (strip all raw ANSI escape sequences)
    local plain_log
    plain_log="$(echo "$log_snippet" | sed "s/${esc_char}\[[0-9;]*[a-zA-Z]//g" 2>/dev/null || echo "$log_snippet")"

    # Prepare ANSI-free, HTML-safe log snippet for crisp display
    local html_log
    html_log="$(echo "$plain_log" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"

    local boundary="MCI_BOUNDARY_$$"
    local email_file="/tmp/mci_mail_$$.txt"

    cat << EOF > "$email_file"
From: ${MCI_SMTP_FROM:-merlin-ci@${router_name}.local}
To: ${MCI_SMTP_TO}
Subject: ${subject}
Date: $(date -R 2>/dev/null || date)
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="${boundary}"

--${boundary}
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

Merlin-CI Automated Notification
================================================================================
Job Name    : ${job_name}
Status      : ${status}
Router Host : ${router_name}
Firmware    : ${router_fw}
Duration    : ${duration}s
Timestamp   : $(date)
================================================================================
${version_info}${action_summary}

Execution Log Snippet:
--------------------------------------------------------------------------------
${plain_log:-No additional log details provided.}

--
Merlin-CI Automation & Self-Healing Engine on Asuswrt-Merlin

--${boundary}
Content-Type: text/html; charset=UTF-8
Content-Transfer-Encoding: 8bit

<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #0b0f19; color: #f8fafc; margin: 0; padding: 24px; }
  .card { background-color: #1e293b; border-radius: 10px; border: 1px solid #334155; padding: 24px; max-width: 680px; margin: 0 auto; box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.5); }
  .header { border-bottom: 1px solid #334155; padding-bottom: 16px; margin-bottom: 20px; }
  .title { font-size: 20px; font-weight: 700; color: #38bdf8; margin: 0; }
  .subtitle { font-size: 13px; color: #94a3b8; margin-top: 4px; }
  .badge { display: inline-block; padding: 5px 14px; font-size: 12px; font-weight: 700; border-radius: 9999px; text-transform: uppercase; color: #ffffff; background-color: ${badge_bg}; }
  .grid { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
  .grid td { padding: 8px 12px; font-size: 13px; }
  .label { color: #94a3b8; font-weight: 500; width: 35%; border-bottom: 1px solid #283548; }
  .value { color: #f8fafc; font-weight: 600; border-bottom: 1px solid #283548; }
  .summary-box { background-color: #0f172a; border-left: 4px solid ${badge_bg}; padding: 12px 16px; margin-bottom: 20px; border-radius: 0 6px 6px 0; font-size: 13px; color: #e2e8f0; line-height: 1.5; }
  .log-title { font-size: 12px; font-weight: 700; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px; }
  .terminal-box { background-color: #060911; border-radius: 8px; border: 1px solid #1e293b; padding: 16px; font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace; font-size: 12px; line-height: 1.55; color: #e2e8f0; overflow-x: auto; white-space: pre-wrap; word-break: break-word; }
  .footer { margin-top: 24px; padding-top: 14px; border-top: 1px solid #334155; font-size: 11px; color: #64748b; text-align: center; }
</style>
</head>
<body>
  <div class="card">
    <div class="header">
      <table style="width: 100%;">
        <tr>
          <td>
            <div class="title">Merlin-CI Automation</div>
            <div class="subtitle">Asuswrt-Merlin Self-Healing &amp; Watchdog Engine</div>
          </td>
          <td style="text-align: right;">
            <span class="badge">${status}</span>
          </td>
        </tr>
      </table>
    </div>

    <div class="summary-box">
      ${action_summary}
    </div>

    <table class="grid">
      <tr><td class="label">Job Name</td><td class="value"><span style="color:#f472b6;">${job_name}</span></td></tr>
      <tr><td class="label">Router Host</td><td class="value"><span style="color:#38bdf8;">${router_name}</span></td></tr>
      <tr><td class="label">Firmware</td><td class="value">${router_fw}</td></tr>
      <tr><td class="label">Duration</td><td class="value">${duration}s</td></tr>
      <tr><td class="label">Timestamp</td><td class="value">$(date)</td></tr>
    </table>

    <div class="log-title">Execution Log &amp; Forensic Trace:</div>
    <div class="terminal-box">
${html_log:-No additional log details provided.}
    </div>

    <div class="footer">
      Merlin-CI Autonomous Pipeline • RT-BE92U High Availability
    </div>
  </div>
</body>
</html>

--${boundary}--
EOF

    echo "--> [NOTIFY] Sending email notification ($status) to $MCI_SMTP_TO..."

    local clean_pass
    clean_pass="$(echo "${MCI_SMTP_PASS}" | tr -d ' ')"

    local port="${MCI_SMTP_PORT:-465}"
    local smtp_scheme="smtps"
    local ssl_opt=""

    if [ "$port" = "587" ] || [ "$port" = "25" ]; then
        smtp_scheme="smtp"
        [ "$MCI_SMTP_TLS" != "0" ] && ssl_opt="--ssl-reqd"
    fi

    local curl_err_file="/tmp/mci_curl_err_$$.log"
    echo "[$now_ts] [INVOKED] Status: $status, Job: $job_name, To: $MCI_SMTP_TO, Server: ${smtp_scheme}://${MCI_SMTP_SERVER}:${port}, User: ${MCI_SMTP_USER:-None}" >> "$email_log"

    export PATH="/opt/bin:/opt/sbin:/usr/sbin:/sbin:/bin:/usr/bin:/jffs/scripts:$PATH"

    local curl_bin=""
    if command -v curl >/dev/null 2>&1; then
        curl_bin="$(command -v curl)"
    elif [ -x "/opt/bin/curl" ]; then
        curl_bin="/opt/bin/curl"
    elif [ -x "/usr/sbin/curl" ]; then
        curl_bin="/usr/sbin/curl"
    elif [ -x "/usr/bin/curl" ]; then
        curl_bin="/usr/bin/curl"
    elif [ -x "/bin/curl" ]; then
        curl_bin="/bin/curl"
    fi

    # If curl is not found but Entware opkg is present, install it
    if [ -z "$curl_bin" ] && [ -x "/opt/bin/opkg" ]; then
        echo "--> [NOTIFY] 'curl' not found in standard paths. Installing via Entware opkg..."
        echo "[$now_ts] [INSTALL] Attempting opkg install curl ca-certificates..." >> "$email_log"
        /opt/bin/opkg update >/dev/null 2>&1 || true
        /opt/bin/opkg install curl ca-certificates >/dev/null 2>&1 || true
        if [ -x "/opt/bin/curl" ]; then
            curl_bin="/opt/bin/curl"
            echo "--> [NOTIFY] Entware curl installed successfully at /opt/bin/curl!"
            echo "[$now_ts] [INSTALL] Entware curl installed successfully at /opt/bin/curl" >> "$email_log"
        fi
    fi

    local sendmail_bin=""
    if command -v sendmail >/dev/null 2>&1; then
        sendmail_bin="$(command -v sendmail)"
    elif [ -x "/usr/sbin/sendmail" ]; then
        sendmail_bin="/usr/sbin/sendmail"
    elif [ -x "/opt/sbin/sendmail" ]; then
        sendmail_bin="/opt/sbin/sendmail"
    elif [ -x "/opt/bin/sendmail" ]; then
        sendmail_bin="/opt/bin/sendmail"
    fi

    local send_success=0
    local send_err_msg=""

    if [ -n "$curl_bin" ]; then
        local ca_opt=""
        if [ -f "/etc/ssl/certs/ca-certificates.crt" ]; then
            ca_opt="--cacert /etc/ssl/certs/ca-certificates.crt"
        elif [ -f "/rom/etc/ssl/certs/ca-certificates.crt" ]; then
            ca_opt="--cacert /rom/etc/ssl/certs/ca-certificates.crt"
        elif [ -f "/etc/ssl/cert.pem" ]; then
            ca_opt="--cacert /etc/ssl/cert.pem"
        elif [ -f "/opt/etc/ssl/certs/ca-certificates.crt" ]; then
            ca_opt="--cacert /opt/etc/ssl/certs/ca-certificates.crt"
        fi

        local from_addr="${MCI_SMTP_FROM:-${MCI_SMTP_USER:-merlin-ci@${router_name}.local}}"

        if [ -n "$MCI_SMTP_USER" ] && [ -n "$clean_pass" ]; then
            # Attempt 1: Standard TLS
            "$curl_bin" -v --url "${smtp_scheme}://${MCI_SMTP_SERVER}:${port}" \
                $ssl_opt $ca_opt \
                --mail-from "$from_addr" \
                --mail-rcpt "$MCI_SMTP_TO" \
                --user "${MCI_SMTP_USER}:${clean_pass}" \
                -T "$email_file" >"$curl_err_file" 2>&1
            local exit_code=$?

            # If SSL certificate error (e.g. exit code 60 or 35), auto-retry with --insecure
            if [ $exit_code -ne 0 ]; then
                if grep -qiE "SSL|certificate|issuer|handshake" "$curl_err_file" 2>/dev/null; then
                    echo "[$now_ts] [RETRY] SSL cert verification issue. Retrying with --insecure..." >> "$email_log"
                    "$curl_bin" -v --url "${smtp_scheme}://${MCI_SMTP_SERVER}:${port}" \
                        $ssl_opt --insecure \
                        --mail-from "$from_addr" \
                        --mail-rcpt "$MCI_SMTP_TO" \
                        --user "${MCI_SMTP_USER}:${clean_pass}" \
                        -T "$email_file" >"$curl_err_file" 2>&1
                    exit_code=$?
                fi
            fi
        else
            "$curl_bin" -v --url "${smtp_scheme}://${MCI_SMTP_SERVER}:${port}" \
                $ssl_opt $ca_opt \
                --mail-from "$from_addr" \
                --mail-rcpt "$MCI_SMTP_TO" \
                -T "$email_file" >"$curl_err_file" 2>&1
            local exit_code=$?
        fi

        if [ $exit_code -eq 0 ]; then
            send_success=1
            echo "[$now_ts] [SUCCESS] Delivered email to $MCI_SMTP_TO via ${MCI_SMTP_SERVER}:${port} (using $curl_bin)" >> "$email_log"
        else
            send_err_msg="$(grep -E '^< [45][0-9]{2}|curl: \([0-9]+\)' "$curl_err_file" 2>/dev/null | tail -n 5)"
            [ -z "$send_err_msg" ] && send_err_msg="$(cat "$curl_err_file" 2>/dev/null | tail -n 5)"
            echo "[$now_ts] [ERROR] curl ($curl_bin) failed (exit code: $exit_code):" >> "$email_log"
            cat "$curl_err_file" >> "$email_log" 2>/dev/null || true
        fi
    elif [ -n "$sendmail_bin" ]; then
        if "$sendmail_bin" -t < "$email_file" >"$curl_err_file" 2>&1; then
            send_success=1
            echo "[$now_ts] [SUCCESS] Delivered email to $MCI_SMTP_TO via local $sendmail_bin" >> "$email_log"
        else
            local exit_code=$?
            send_err_msg="$(cat "$curl_err_file" 2>/dev/null | tail -n 3)"
            echo "[$now_ts] [ERROR] sendmail ($sendmail_bin) failed (exit code: $exit_code): $send_err_msg" >> "$email_log"
        fi
    else
        echo "[$now_ts] [ERROR] Neither 'curl' nor 'sendmail' found. Checked PATH, /opt/bin, /usr/sbin, /usr/bin." >> "$email_log"
        send_err_msg="Neither 'curl' nor 'sendmail' found in /opt/bin, /usr/sbin, or /usr/bin. Run 'opkg install curl ca-certificates'."
    fi

    rm -f "$email_file" "$curl_err_file" 2>/dev/null || true

    if [ $send_success -eq 1 ]; then
        return 0
    else
        export MCI_LAST_EMAIL_ERROR="$send_err_msg"
        return 1
    fi
}

notify_discord() {
    local status="$1"
    local job_name="$2"
    local duration="$3"
    local log_snippet="$4"
    local old_version="$5"
    local new_version="$6"

    if [ -z "$MCI_DISCORD_WEBHOOK_URL" ]; then
        return 0
    fi

    local color_int=3066993   # Green (success)
    [ "$status" = "TRIGGERED" ] && color_int=3447003 # Blue
    [ "$status" = "ROLLED_BACK" ] && color_int=15844367 # Yellow
    [ "$status" = "FAILED" ] && color_int=15158332 # Red

    local router_name
    router_name="$(nvram get productid 2>/dev/null || uname -m)"

    local version_field=""
    if [ -n "$old_version" ] || [ -n "$new_version" ]; then
        version_field=", { \"name\": \"Version\", \"value\": \"${old_version:-N/A} ➔ ${new_version:-N/A}\", \"inline\": true }"
    fi

    local payload
    payload=$(cat <<EOF
{
  "embeds": [
    {
      "title": "Merlin-CI Job ${status}",
      "color": ${color_int},
      "fields": [
        { "name": "Job", "value": "${job_name:-Unknown}", "inline": true },
        { "name": "Duration", "value": "${duration}s", "inline": true },
        { "name": "Host", "value": "${router_name}", "inline": true }${version_field}
      ],
      "footer": { "text": "Merlin-CI on Asuswrt-Merlin" },
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  ]
}
EOF
)

    curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$MCI_DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

notify_telegram() {
    local status="$1"
    local job_name="$2"
    local duration="$3"
    local log_snippet="$4"
    local old_version="$5"
    local new_version="$6"

    if [ -z "$MCI_TELEGRAM_BOT_TOKEN" ] || [ -z "$MCI_TELEGRAM_CHAT_ID" ]; then
        return 0
    fi

    local emoji="✅"
    [ "$status" = "TRIGGERED" ] && emoji="🚀"
    [ "$status" = "ROLLED_BACK" ] && emoji="⚠️"
    [ "$status" = "FAILED" ] && emoji="❌"

    local router_name
    router_name="$(nvram get productid 2>/dev/null || uname -m)"

    local text="${emoji} <b>Merlin-CI Job ${status}</b>%0A"
    text="${text}<b>Host:</b> ${router_name}%0A"
    text="${text}<b>Job:</b> ${job_name}%0A"

    if [ -n "$old_version" ] || [ -n "$new_version" ]; then
        text="${text}<b>Version:</b> ${old_version:-N/A} ➔ ${new_version:-N/A}%0A"
    fi

    text="${text}<b>Duration:</b> ${duration}s"

    local api_url="https://api.telegram.org/bot${MCI_TELEGRAM_BOT_TOKEN}/sendMessage"

    curl -s -X POST \
        -d "chat_id=${MCI_TELEGRAM_CHAT_ID}&text=${text}&parse_mode=HTML" \
        "$api_url" >/dev/null 2>&1 || true
}

notify_dispatch() {
    local status="$1"
    local job_name="$2"
    local duration="${3:-0}"
    local log_snippet="$4"
    local old_version="$5"
    local new_version="$6"

    notify_email "$status" "$job_name" "$duration" "$log_snippet" "$old_version" "$new_version"
    notify_discord "$status" "$job_name" "$duration" "$log_snippet" "$old_version" "$new_version"
    notify_telegram "$status" "$job_name" "$duration" "$log_snippet" "$old_version" "$new_version"
}
