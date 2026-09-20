#!/bin/sh
# ==============================================================================
# Merlin-CI: Trigger-Driven Router Automation & CI Engine for Asuswrt-Merlin
# Author: The Void
# ==============================================================================
# Version: 1.1.0
# Description: Automated trigger detection, pre-flight backup, update execution,
#              CI smoke testing, and rollback for router scripts and addons.
# ==============================================================================

# Ensure standard Asuswrt-Merlin & Entware binary paths are available
export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/jffs/scripts:$PATH"

MCI_VERSION="1.1.0"

# Determine script base directory (resolving symlinks)
TARGET="$0"
if [ -h "$TARGET" ]; then
    RESOLVED="$(readlink -f "$TARGET" 2>/dev/null)"
    [ -n "$RESOLVED" ] && TARGET="$RESOLVED"
fi
SCRIPT_DIR="$(cd "$(dirname "$TARGET")" && pwd)"

# Fallback to standard installation directory if invoked via broken link
if [ ! -f "${SCRIPT_DIR}/lib/ui.sh" ]; then
    if [ -f "/jffs/addons/merlin-ci/lib/ui.sh" ]; then
        SCRIPT_DIR="/jffs/addons/merlin-ci"
    elif [ -f "./lib/ui.sh" ]; then
        SCRIPT_DIR="$(pwd)"
    fi
fi

# Source Libraries
# shellcheck source=lib/ui.sh
. "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=lib/notify.sh
. "${SCRIPT_DIR}/lib/notify.sh"
# shellcheck source=lib/runner.sh
. "${SCRIPT_DIR}/lib/runner.sh"
# shellcheck source=lib/daemon.sh
. "${SCRIPT_DIR}/lib/daemon.sh"

config_load

# --- Interactive Actions ---

action_check_all_triggers() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Checking All Trigger Conditions ===${COLOR_RESET}\n\n"
    daemon_check_all_jobs 0
    ui_pause
}

action_run_specific_job() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Manual Job Execution (Override) ===${COLOR_RESET}\n\n"

    local jobs_dir="${MCI_JOBS_DIR:-./jobs}"
    local job_list
    job_list="$(ls -1 "$jobs_dir"/*.job.sh 2>/dev/null)"

    if [ -z "$job_list" ]; then
        echo "--> No jobs found in $jobs_dir."
        ui_pause
        return 1
    fi

    local idx=1
    for jf in $job_list; do
        printf "  [%d] %s\n" "$idx" "$(basename "$jf" .job.sh)"
        idx=$((idx + 1))
    done

    echo ""
    ui_prompt "Select job number to execute (or [b] to back)" "b"
    read -r sel

    if [ "$sel" != "b" ] && [ -n "$sel" ]; then
        local chosen
        chosen="$(echo "$job_list" | sed -n "${sel}p")"
        if [ -n "$chosen" ] && [ -f "$chosen" ]; then
            echo ""
            ui_prompt "Force run even if trigger condition is not met? (y/n)" "y"
            read -r force_ans
            local force_val=0
            [ "$force_ans" = "y" ] || [ "$force_ans" = "Y" ] && force_val=1

            echo ""
            runner_execute_job "$chosen" "manual_override" "$force_val"
        else
            echo "--> Invalid selection."
        fi
        ui_pause
    fi
}

action_toggle_job() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Enable / Disable Jobs ===${COLOR_RESET}\n\n"

    local jobs_dir="${MCI_JOBS_DIR:-./jobs}"
    local job_list
    job_list="$(ls -1 "$jobs_dir"/*.job.sh 2>/dev/null)"

    local idx=1
    for jf in $job_list; do
        local jname
        jname="$(basename "$jf" .job.sh)"
        local cur_state
        cur_state="$(grep -E '^JOB_ENABLED=' "$jf" | cut -d= -f2 | tr -d '"'\'' ' || echo "1")"
        [ -z "$cur_state" ] && cur_state="1"

        if [ "$cur_state" = "1" ]; then
            printf "  [%d] %-24s ${COLOR_GREEN}[ENABLED]${COLOR_RESET}\n" "$idx" "$jname"
        else
            printf "  [%d] %-24s ${COLOR_DIM}[DISABLED]${COLOR_RESET}\n" "$idx" "$jname"
        fi
        idx=$((idx + 1))
    done

    echo ""
    ui_prompt "Select job number to toggle (or [b] to back)" "b"
    read -r sel

    if [ "$sel" != "b" ] && [ -n "$sel" ]; then
        local chosen
        chosen="$(echo "$job_list" | sed -n "${sel}p")"
        if [ -n "$chosen" ] && [ -f "$chosen" ]; then
            local jname
            jname="$(basename "$chosen" .job.sh)"
            local cur_state
            cur_state="$(grep -E '^JOB_ENABLED=' "$chosen" | cut -d= -f2 | tr -d '"'\'' ' || echo "1")"
            [ -z "$cur_state" ] && cur_state="1"

            if [ "$cur_state" = "1" ]; then
                config_set_job_status "$jname" 0
            else
                config_set_job_status "$jname" 1
            fi
        else
            echo "--> Invalid selection."
        fi
        ui_pause
    fi
}

action_create_wizard() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Create New Custom CI Automation Job ===${COLOR_RESET}\n\n"

    ui_prompt "Enter unique Job identifier (e.g., custom-watchdog)"
    read -r w_name
    if [ -z "$w_name" ]; then
        echo "--> Aborted: Name cannot be empty."
        ui_pause
        return 1
    fi

    # Clean name
    w_name="$(echo "$w_name" | tr -cd 'a-zA-Z0-9_-')"
    local target_file="${MCI_JOBS_DIR}/${w_name}.job.sh"

    if [ -f "$target_file" ]; then
        echo "--> [ERROR] Job file already exists: $target_file"
        ui_pause
        return 1
    fi

    ui_prompt "Enter brief description" "Custom automation workflow"
    read -r w_desc
    [ -z "$w_desc" ] && w_desc="Custom automation workflow"

    ui_prompt "Action command to execute (e.g. sh /jffs/scripts/my_script update)"
    read -r w_run
    [ -z "$w_run" ] && w_run="true"

    ui_prompt "Post-run verification smoke test (e.g. ping -c 1 1.1.1.1 or pidof my_app)"
    read -r w_verify
    [ -z "$w_verify" ] && w_verify="true"

    cat << EOF > "$target_file"
#!/bin/sh
# Custom Job: $w_name
JOB_NAME="$w_name"
JOB_DESCRIPTION="$w_desc"
JOB_ENABLED=1

mci_check_trigger() {
    # Default: manual or unconditional trigger
    return 0
}

mci_backup() {
    local backup_dir="\$1"
    return 0
}

mci_run() {
    $w_run
}

mci_verify() {
    $w_verify
}

mci_rollback() {
    local backup_dir="\$1"
    return 0
}

mci_notify() {
    local status="\$1" duration="\$2"
    echo "--> [NOTIFY] Job $w_name finished: \$status (\${duration}s)"
}
EOF
    chmod 755 "$target_file"
    echo ""
    echo "--> Successfully generated new job at $target_file!"
    ui_pause
}

action_view_logs() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Job Execution Logs in %s ===${COLOR_RESET}\n\n" "$MCI_LOG_DIR"

    # shellcheck disable=SC2012
    local logs
    logs="$(ls -1t "$MCI_LOG_DIR"/job_*.log 2>/dev/null)"

    if [ -z "$logs" ]; then
        echo "--> No execution logs found yet."
        ui_pause
        return 0
    fi

    local idx=1
    echo "$logs" | while read -r logfile; do
        printf "  [%d] %s\n" "$idx" "$(basename "$logfile")"
        idx=$((idx + 1))
    done

    echo ""
    ui_prompt "Enter log number to view or [b] to go back" "b"
    read -r choice

    if [ "$choice" != "b" ] && [ -n "$choice" ]; then
        local selected
        selected="$(echo "$logs" | sed -n "${choice}p")"
        if [ -n "$selected" ] && [ -f "$selected" ]; then
            ui_clear
            printf "${COLOR_BOLD}Viewing: %s${COLOR_RESET}\n" "$selected"
            ui_divider
            cat "$selected"
        else
            echo "--> Invalid log selection."
        fi
        ui_pause
    fi
}

action_configure_cron() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Scheduler & Cron Configuration (cru) ===${COLOR_RESET}\n\n"

    echo "Current cru status: $(daemon_cron_status)"
    echo ""

    printf "  ${COLOR_CYAN}[1]${COLOR_RESET} Enable Tiered Schedules (Recommended)\n"
    printf "      - Watchdogs (Fast self-healing): Every 15 minutes\n"
    printf "      - Daily Maintenance (AMTM & package upgrades): Daily at 4:00 AM\n"
    printf "  ${COLOR_CYAN}[2]${COLOR_RESET} Enable Aggressive Tiered (Watchdogs every 5 min, Daily at 4:00 AM)\n"
    printf "  ${COLOR_CYAN}[3]${COLOR_RESET} Enable Daily Only (All jobs once a day at 4:00 AM)\n"
    printf "  ${COLOR_CYAN}[4]${COLOR_RESET} Custom Watchdog & Daily Intervals\n"
    printf "  ${COLOR_CYAN}[5]${COLOR_RESET} Disable / Remove from Cron\n"
    printf "  ${COLOR_RED}[b]${COLOR_RESET} Back\n\n"

    ui_prompt "Select an option" "b"
    read -r c_opt

    case "$c_opt" in
        1)
            daemon_setup_cron "*/15 * * * *" "0 4 * * *"
            ui_pause
            ;;
        2)
            daemon_setup_cron "*/5 * * * *" "0 4 * * *"
            ui_pause
            ;;
        3)
            daemon_setup_cron "0 4 * * *" "0 4 * * *"
            ui_pause
            ;;
        4)
            ui_prompt "Enter Watchdog cron expression (e.g. '*/10 * * * *')" "*/15 * * * *"
            read -r w_expr
            [ -z "$w_expr" ] && w_expr="*/15 * * * *"
            ui_prompt "Enter Daily Maintenance cron expression (e.g. '0 4 * * *')" "0 4 * * *"
            read -r d_expr
            [ -z "$d_expr" ] && d_expr="0 4 * * *"
            daemon_setup_cron "$w_expr" "$d_expr"
            ui_pause
            ;;
        5)
            daemon_remove_cron
            ui_pause
            ;;
        *)
            ;;
    esac
}

action_diagnostics() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== System Diagnostics & Resource Guards ===${COLOR_RESET}\n\n"

    echo "1. CPU 1-minute Load Average:"
    if [ -f /proc/loadavg ]; then
        local cur_load
        cur_load="$(awk '{print $1}' /proc/loadavg)"
        echo "   Current: $cur_load | Configured Limit: $MCI_MAX_LOADAVG"
    else
        echo "   /proc/loadavg not accessible."
    fi

    echo ""
    echo "2. Available Memory:"
    if [ -f /proc/meminfo ]; then
        local free_ram
        free_ram="$(awk '/MemAvailable/ {print int($2/1024); f=1} END {if (!f) print "N/A"}' /proc/meminfo)"
        echo "   Current: ${free_ram} MB | Configured Threshold: ${MCI_MIN_FREE_RAM_MB} MB"
    else
        echo "   /proc/meminfo not accessible."
    fi

    echo ""
    echo "3. Storage Locations (Flash-Wear Protection):"
    echo "   Logs   : $MCI_LOG_DIR"
    echo "   Backups: $MCI_BACKUP_DIR"
    config_validate

    echo ""
    echo "4. Required Command Availability:"
    for tool in curl awk nice; do
        if command -v "$tool" >/dev/null 2>&1; then
            printf "   [OK]   %-12s (%s)\n" "$tool" "$(command -v "$tool")"
        else
            printf "   [FAIL] %-12s (Missing!)\n" "$tool"
        fi
    done

    ui_pause
}

action_scrape_email() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}=== Scrape & Import SMTP from AMTM / Asuswrt-Merlin ===${COLOR_RESET}\n\n"

    echo "--> Scanning router environment (NVRAM, /jffs/configs, /jffs/scripts, /jffs/addons, /opt)..."
    if config_scrape_amtm_email; then
        echo ""
        printf "${COLOR_GREEN}${COLOR_BOLD}[SUCCESS] Existing SMTP Configuration Detected!${COLOR_RESET}\n"
        echo "--------------------------------------------------------------------------------"
        echo "  Source       : $SCRAPED_SOURCE"
        echo "  SMTP Server  : $SCRAPED_SERVER:$SCRAPED_PORT"
        echo "  Username     : $SCRAPED_USER"
        echo "  Password     : $([ -n "$SCRAPED_PASS" ] && echo "******** (Loaded)" || echo "None")"
        echo "  Sender (From): $SCRAPED_FROM"
        echo "  Recipient(To): $SCRAPED_TO"
        echo "--------------------------------------------------------------------------------"
        echo ""
        ui_prompt "Import these settings into Merlin-CI and enable Email? (y/n)" "y"
        read -r do_import
        case "$do_import" in
            y|Y|"")
                config_set "MCI_EMAIL_ENABLED" "1"
                config_set "MCI_SMTP_SERVER" "$SCRAPED_SERVER"
                config_set "MCI_SMTP_PORT" "$SCRAPED_PORT"
                config_set "MCI_SMTP_USER" "$SCRAPED_USER"
                config_set "MCI_SMTP_PASS" "$SCRAPED_PASS"
                config_set "MCI_SMTP_FROM" "$SCRAPED_FROM"
                config_set "MCI_SMTP_TO" "$SCRAPED_TO"
                echo ""
                printf "${COLOR_GREEN}[OK] Settings imported successfully! Email notifications are now ENABLED.${COLOR_RESET}\n\n"

                ui_prompt "Send a test email now to verify delivery to $SCRAPED_TO? (y/n)" "y"
                read -r do_test
                case "$do_test" in
                    y|Y|"")
                        notify_email "TEST" "test-alert" "1" "Merlin-CI SMTP imported from ${SCRAPED_SOURCE} and verified."
                        echo "--> Test email sent!"
                        ;;
                esac
                ;;
            *)
                echo "Import cancelled."
                ;;
        esac
    else
        echo ""
        printf "${COLOR_YELLOW}[NOTICE] No existing SMTP settings were auto-detected.${COLOR_RESET}\n"
        echo "Scanned: NVRAM, /jffs/configs/, /jffs/addons/, /jffs/scripts/, and /opt/etc/."
        echo ""
        ui_prompt "If your script/config has a specific path, enter it here (or [Enter] to skip)" ""
        read -r custom_path
        if [ -n "$custom_path" ] && [ -f "$custom_path" ]; then
            if config_scrape_amtm_email "$custom_path"; then
                printf "${COLOR_GREEN}[SUCCESS] Found credentials in %s!${COLOR_RESET}\n" "$custom_path"
                echo "  SMTP Server  : $SCRAPED_SERVER:$SCRAPED_PORT"
                echo "  Username     : $SCRAPED_USER"
                echo "  Recipient(To): $SCRAPED_TO"
                ui_prompt "Import these settings? (y/n)" "y"
                read -r c_imp
                case "$c_imp" in
                    y|Y|"")
                        config_set "MCI_EMAIL_ENABLED" "1"
                        config_set "MCI_SMTP_SERVER" "$SCRAPED_SERVER"
                        config_set "MCI_SMTP_PORT" "$SCRAPED_PORT"
                        config_set "MCI_SMTP_USER" "$SCRAPED_USER"
                        config_set "MCI_SMTP_PASS" "$SCRAPED_PASS"
                        config_set "MCI_SMTP_FROM" "$SCRAPED_FROM"
                        config_set "MCI_SMTP_TO" "$SCRAPED_TO"
                        echo "${COLOR_GREEN}[OK] Imported successfully!${COLOR_RESET}"
                        ;;
                esac
            else
                printf "${COLOR_RED}[ERROR] Could not parse SMTP credentials from %s.${COLOR_RESET}\n" "$custom_path"
            fi
        fi
    fi
    ui_pause
}

action_notifications() {
    while true; do
        ui_clear
        ui_banner
        printf "${COLOR_BOLD}=== Notification Settings ===${COLOR_RESET}\n\n"

        local email_status="[DISABLED]"
        [ "$MCI_EMAIL_ENABLED" = "1" ] && email_status="[ENABLED]"

        printf "  ${COLOR_CYAN}[1]${COLOR_RESET} Email Notifications     : %s (To: %s)\n" "$email_status" "${MCI_SMTP_TO:-Not set}"
        printf "  ${COLOR_CYAN}[2]${COLOR_RESET} SMTP Server & Port      : %s:%s\n" "${MCI_SMTP_SERVER:-smtp.gmail.com}" "${MCI_SMTP_PORT:-465}"
        printf "  ${COLOR_CYAN}[3]${COLOR_RESET} SMTP Username (Login)   : %s\n" "${MCI_SMTP_USER:-Not set}"
        printf "  ${COLOR_CYAN}[4]${COLOR_RESET} SMTP Password / App Key : %s\n" "$([ -n "$MCI_SMTP_PASS" ] && echo "********" || echo "Not set")"
        printf "  ${COLOR_CYAN}[5]${COLOR_RESET} Sender & Recipient      : From: %s -> To: %s\n" "${MCI_SMTP_FROM:-router.local}" "${MCI_SMTP_TO:-Not set}"
        printf "  ${COLOR_CYAN}[6]${COLOR_RESET} Send Test Email Now\n"
        printf "  ${COLOR_YELLOW}[s]${COLOR_RESET} Scrape & Import SMTP from AMTM / Asuswrt-Merlin\n"
        printf "  ${COLOR_CYAN}[l]${COLOR_RESET} View Email Log (Troubleshooting)\n"
        printf "  ${COLOR_CYAN}[7]${COLOR_RESET} Discord Webhook URL     : %s\n" "${MCI_DISCORD_WEBHOOK_URL:-Not configured}"
        printf "  ${COLOR_CYAN}[8]${COLOR_RESET} Telegram Bot Token      : %s\n" "$([ -n "$MCI_TELEGRAM_BOT_TOKEN" ] && echo "********" || echo "Not configured")"
        printf "  ${COLOR_CYAN}[9]${COLOR_RESET} Telegram Chat ID        : %s\n" "${MCI_TELEGRAM_CHAT_ID:-Not configured}"
        printf "\n  ${COLOR_RED}[b]${COLOR_RESET} Back to Main Menu\n\n"

        ui_prompt "Select an option to update" "b"
        read -r n_opt

        case "$n_opt" in
            1)
                ui_prompt "Enable Email notifications? (1 = Enable, 0 = Disable)" "$MCI_EMAIL_ENABLED"
                read -r val
                case "$val" in
                    1|0) config_set "MCI_EMAIL_ENABLED" "$val" ;;
                    *) echo "Invalid choice (use 1 or 0)." ; sleep 1 ;;
                esac
                ;;
            2)
                ui_prompt "Enter SMTP Server Address" "$MCI_SMTP_SERVER"
                read -r s_server
                [ -n "$s_server" ] && config_set "MCI_SMTP_SERVER" "$s_server"
                ui_prompt "Enter SMTP Port (465 for SMTPS/SSL, 587 for Submission/STARTTLS)" "$MCI_SMTP_PORT"
                read -r s_port
                [ -n "$s_port" ] && config_set "MCI_SMTP_PORT" "$s_port"
                ;;
            3)
                ui_prompt "Enter SMTP Username / Login Email" "$MCI_SMTP_USER"
                read -r val
                config_set "MCI_SMTP_USER" "$val"
                ;;
            4)
                ui_prompt "Enter SMTP Password (or Gmail App Password)"
                read -r val
                config_set "MCI_SMTP_PASS" "$val"
                ;;
            5)
                ui_prompt "Enter Sender 'From' Email" "$MCI_SMTP_FROM"
                read -r val
                [ -n "$val" ] && config_set "MCI_SMTP_FROM" "$val"
                ui_prompt "Enter Recipient 'To' Email" "$MCI_SMTP_TO"
                read -r to_val
                [ -n "$to_val" ] && config_set "MCI_SMTP_TO" "$to_val"
                ;;
            6)
                echo "--> Sending test email to $MCI_SMTP_TO via ${MCI_SMTP_SERVER}:${MCI_SMTP_PORT:-465}..."
                local saved_state="$MCI_EMAIL_ENABLED"
                MCI_EMAIL_ENABLED=1
                if notify_email "TEST" "test-alert" "1" "This is a test notification from Merlin-CI on Asuswrt-Merlin."; then
                    printf "\n${COLOR_GREEN}${COLOR_BOLD}[SUCCESS] Test email delivered successfully to %s!${COLOR_RESET}\n" "$MCI_SMTP_TO"
                else
                    printf "\n${COLOR_RED}${COLOR_BOLD}[ERROR] Email delivery failed!${COLOR_RESET}\n"
                    [ -n "$MCI_LAST_EMAIL_ERROR" ] && echo "Reason: $MCI_LAST_EMAIL_ERROR"
                    echo ""
                    echo "Full error trace logged to: ${MCI_LOG_DIR:-/tmp/merlin-ci/logs}/email.log"
                fi
                MCI_EMAIL_ENABLED="$saved_state"
                ui_pause
                ;;
            s|S)
                action_scrape_email
                ;;
            l|L)
                local elog="${MCI_LOG_DIR:-/tmp/merlin-ci/logs}/email.log"
                ui_clear
                ui_banner
                printf "${COLOR_BOLD}=== Email Invocation & Error Log (%s) ===${COLOR_RESET}\n\n" "$elog"
                if [ -f "$elog" ]; then
                    cat "$elog" | tail -n 40
                else
                    echo "No email log found at $elog"
                fi
                ui_pause
                ;;
            7)
                ui_prompt "Enter Discord Webhook URL" "$MCI_DISCORD_WEBHOOK_URL"
                read -r val
                config_set "MCI_DISCORD_WEBHOOK_URL" "$val"
                ;;
            8)
                ui_prompt "Enter Telegram Bot Token" "$MCI_TELEGRAM_BOT_TOKEN"
                read -r val
                config_set "MCI_TELEGRAM_BOT_TOKEN" "$val"
                ;;
            9)
                ui_prompt "Enter Telegram Chat ID" "$MCI_TELEGRAM_CHAT_ID"
                read -r val
                config_set "MCI_TELEGRAM_CHAT_ID" "$val"
                ;;
            b|B|"")
                break
                ;;
            *)
                echo "--> Invalid selection."
                sleep 1
                ;;
        esac
    done
}

action_uninstall() {
    ui_clear
    ui_banner
    printf "${COLOR_BOLD}${COLOR_RED}=== Uninstall Merlin-CI ===${COLOR_RESET}\n\n"
    ui_prompt "Are you sure you want to uninstall Merlin-CI? (type 'yes')"
    read -r ans

    if [ "$ans" = "yes" ]; then
        daemon_remove_cron
        daemon_stop
        rm -f "/jffs/scripts/mci" "/opt/bin/mci" "/jffs/scripts/merlin-ci" 2>/dev/null || true
        echo "--> Merlin-CI uninstalled."
        exit 0
    else
        echo "--> Aborted."
        ui_pause
    fi
}

# --- Interactive Main Loop ---
interactive_main() {
    while true; do
        ui_clear
        ui_banner
        ui_dashboard_header
        ui_list_jobs_table
        ui_print_menu

        ui_prompt "Enter menu selection"
        read -r choice

        case "$choice" in
            1) action_check_all_triggers ;;
            2) action_run_specific_job ;;
            3) action_toggle_job ;;
            4) action_create_wizard ;;
            5) action_view_logs ;;
            6) action_configure_cron ;;
            7) action_diagnostics ;;
            8) action_notifications ;;
            u|U) action_uninstall ;;
            e|E|q|Q)
                ui_clear
                echo "Exited Merlin-CI. Have a great day!"
                exit 0
                ;;
            *)
                echo "--> Invalid option."
                sleep 1
                ;;
        esac
    done
}

# --- CLI Mode ---
cli_main() {
    local cmd="$1"
    shift

    case "$cmd" in
        check)
            local force=0
            local target="all"
            for arg in "$@"; do
                case "$arg" in
                    -f|--force) force=1 ;;
                    watchdog|healing) target="watchdog" ;;
                    daily|maintenance) target="daily" ;;
                    all) target="all" ;;
                esac
            done
            daemon_check_all_jobs "$target" "$force"
            ;;
        run)
            local jname="$1"
            local force=0
            [ "$2" = "-f" ] && force=1

            if [ -z "$jname" ]; then
                echo "Usage: merlin-ci run <job_name> [-f]"
                exit 1
            fi

            local jfile="${MCI_JOBS_DIR}/${jname}.job.sh"
            if [ ! -f "$jfile" ]; then
                jfile="${MCI_JOBS_DIR}/${jname}"
            fi

            if [ -f "$jfile" ]; then
                runner_execute_job "$jfile" "cli" "$force"
            else
                echo "--> [ERROR] Job not found: $jname (checked $jfile)"
                exit 1
            fi
            ;;
        list)
            local jobs_dir="${MCI_JOBS_DIR:-./jobs}"
            printf "${COLOR_CYAN}================================================================================${COLOR_RESET}\n"
            printf " ${COLOR_BOLD}%-26s %-12s %-12s %s${COLOR_RESET}\n" "JOB NAME" "TIER" "STATUS" "DESCRIPTION"
            printf "${COLOR_CYAN}--------------------------------------------------------------------------------${COLOR_RESET}\n"
            for jf in "$jobs_dir"/*.job.sh; do
                if [ -f "$jf" ]; then
                    local name
                    name="$(basename "$jf" .job.sh)"
                    local state
                    state="$(grep -E '^JOB_ENABLED=' "$jf" | cut -d= -f2 | tr -d '"'\'' ' || echo "1")"
                    local jtype
                    jtype="$(grep -m1 -E '^JOB_TYPE=' "$jf" 2>/dev/null | cut -d= -f2 | tr -d '"'\'' ' || echo "daily")"
                    [ -z "$jtype" ] && jtype="daily"
                    local tier_badge="${COLOR_CYAN}[WATCHDOG]${COLOR_RESET}"
                    [ "$jtype" = "daily" ] && tier_badge="${COLOR_BLUE}[DAILY]${COLOR_RESET}"
                    local desc
                    desc="$(grep -E '^JOB_DESCRIPTION=' "$jf" | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//' || echo "$name")"
                    local status_badge="${COLOR_GREEN}[ENABLED]${COLOR_RESET}"
                    [ "$state" != "1" ] && status_badge="${COLOR_DIM}[DISABLED]${COLOR_RESET}"
                    printf " ${COLOR_BOLD}${COLOR_MAGENTA}%-26s${COLOR_RESET} %-21s %-21s ${COLOR_DIM}%s${COLOR_RESET}\n" "$name" "$tier_badge" "$status_badge" "$desc"
                fi
            done
            printf "${COLOR_CYAN}================================================================================${COLOR_RESET}\n"
            ;;
        enable)
            [ -z "$1" ] && { echo "Usage: merlin-ci enable <job_name>"; exit 1; }
            config_set_job_status "$1" 1
            ;;
        disable)
            [ -z "$1" ] && { echo "Usage: merlin-ci disable <job_name>"; exit 1; }
            config_set_job_status "$1" 0
            ;;
        cron)
            case "$1" in
                enable) daemon_setup_cron "${2:-*/15 * * * *}" "${3:-0 4 * * *}" ;;
                disable) daemon_remove_cron ;;
                status) daemon_cron_status ;;
                *) echo "Usage: merlin-ci cron [enable [watchdog_expr] [daily_expr] | disable | status]" ;;
            esac
            ;;
        logs)
            local latest_log="${MCI_LOG_DIR}/latest.log"
            if [ "$1" = "email" ]; then
                latest_log="${MCI_LOG_DIR}/email.log"
            elif [ -n "$1" ]; then
                latest_log="${MCI_LOG_DIR}/latest_${1}.log"
            fi
            if [ -f "$latest_log" ]; then
                cat "$latest_log"
            else
                echo "No logs found at $latest_log"
            fi
            ;;
        diag)
            action_diagnostics
            ;;
        scrape-email|email-scrape|import-email)
            action_scrape_email "$@"
            ;;
        notify-test|test-notify|test-email|email-test)
            printf "--> ${COLOR_CYAN}[NOTIFY-TEST]${COLOR_RESET} Testing notification dispatch...\n"
            if [ "$MCI_EMAIL_ENABLED" != "1" ] && [ -x "/jffs/scripts/send_alert.sh" ]; then
                printf "--> ${COLOR_CYAN}[NOTIFY-TEST]${COLOR_RESET} Dispatching via /jffs/scripts/send_alert.sh...\n"
                /jffs/scripts/send_alert.sh "Merlin-CI Test Alert" "This is a test alert from Merlin-CI on $(nvram get productid 2>/dev/null || uname -m). Testing rich HTML formatting, color badges, and highlights."
                printf "${COLOR_GREEN}--> [OK] Test alert dispatched via /jffs/scripts/send_alert.sh!${COLOR_RESET}\n"
            else
                notify_dispatch "TEST" "test-alert" "1" "This is a test notification from Merlin-CI on Asuswrt-Merlin. Testing rich HTML formatting and color badges."
            fi
            ;;
        help|--help|-h)
            printf "${COLOR_CYAN}${COLOR_BOLD}Merlin-CI: Router Addon Automation & CI (v%s)${COLOR_RESET}\n\n" "$MCI_VERSION"
            printf "${COLOR_BOLD}Usage:${COLOR_RESET} merlin-ci [COMMAND] [OPTIONS]\n\n"
            printf "${COLOR_BOLD}Commands:${COLOR_RESET}\n"
            printf "  ${COLOR_CYAN}(no args)${COLOR_RESET}                   Open interactive AMTM terminal menu\n"
            printf "  ${COLOR_CYAN}check${COLOR_RESET} [watchdog|daily] [-f] Evaluate triggers (-f to force run all)\n"
            printf "  ${COLOR_CYAN}run${COLOR_RESET} <job> [-f]              Execute specific job (-f to bypass trigger check)\n"
            printf "  ${COLOR_CYAN}list${COLOR_RESET}                        List all configured jobs, their tiers, and statuses\n"
            printf "  ${COLOR_CYAN}enable${COLOR_RESET} <job>                Enable a specific job\n"
            printf "  ${COLOR_CYAN}disable${COLOR_RESET} <job>               Disable a specific job\n"
            printf "  ${COLOR_CYAN}cron${COLOR_RESET} [enable|disable]       Manage automated Tiered schedules in Asuswrt-Merlin cru\n"
            printf "  ${COLOR_CYAN}logs${COLOR_RESET} [job]                  View latest build and smoke test log\n"
            printf "  ${COLOR_CYAN}scrape-email${COLOR_RESET}                Auto-detect and import SMTP from AMTM / Asuswrt-Merlin\n"
            printf "  ${COLOR_CYAN}notify-test${COLOR_RESET}                 Send a test notification to verify email/webhooks\n"
            printf "  ${COLOR_CYAN}diag${COLOR_RESET}                        Run system diagnostics & resource checks\n"
            printf "  ${COLOR_CYAN}help${COLOR_RESET}                        Display this help message\n"
            ;;
        *)
            echo "Unknown command: $cmd. Use 'merlin-ci help' for options."
            exit 1
            ;;
    esac
}

if [ $# -eq 0 ]; then
    interactive_main
else
    cli_main "$@"
fi
