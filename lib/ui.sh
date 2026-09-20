#!/bin/sh
# ==============================================================================
# Merlin-CI: Terminal UI & AMTM Aesthetics Library (lib/ui.sh)
# ==============================================================================

ESC="$(printf '\033_')"
ESC="${ESC%_}"
[ -z "$ESC" ] && ESC="$(echo -e '\033_')" && ESC="${ESC%_}"
COLOR_RESET="${ESC}[0m"
COLOR_BOLD="${ESC}[1m"
COLOR_DIM="${ESC}[2m"
COLOR_RED="${ESC}[31m"
COLOR_GREEN="${ESC}[32m"
COLOR_YELLOW="${ESC}[33m"
COLOR_BLUE="${ESC}[34m"
COLOR_MAGENTA="${ESC}[35m"
COLOR_CYAN="${ESC}[36m"
COLOR_WHITE="${ESC}[37m"

export ESC COLOR_RESET COLOR_BOLD COLOR_DIM COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_MAGENTA COLOR_CYAN COLOR_WHITE

ui_clear() {
    if [ -t 1 ]; then
        clear 2>/dev/null || printf "\033[H\033[2J"
    fi
}

ui_divider() {
    printf "${COLOR_CYAN}--------------------------------------------------------------------------------${COLOR_RESET}\n"
}

ui_banner() {
    printf "${COLOR_CYAN}${COLOR_BOLD}"
    echo "  __  __           _ _             ____ ___ "
    echo " |  \/  | ___ _ __| (_)_ __       / ___|_ _|"
    echo " | |\/| |/ _ \ '__| | | '_ \ ____| |    | | "
    echo " | |  | |  __/ |  | | | | | |____| |___ | | "
    echo " |_|  |_|\___|_|  |_|_|_| |_|     \____|___|"
    printf "${COLOR_RESET}"
    printf "${COLOR_DIM}  Trigger-Driven Router Automation & CI Engine for Asuswrt-Merlin (v%s)${COLOR_RESET}\n" "${MCI_VERSION:-1.0.0}"
    printf "${COLOR_DIM}  Developed by ${COLOR_CYAN}${COLOR_BOLD}The Void${COLOR_RESET}\n"
    ui_divider
}

ui_badge_status() {
    local status="$1"
    case "$status" in
        "SUCCESS"|"success"|"PASS"|"pass")
            printf "${COLOR_GREEN}${COLOR_BOLD}[SUCCESS]${COLOR_RESET}"
            ;;
        "ROLLED_BACK"|"rolled_back")
            printf "${COLOR_YELLOW}${COLOR_BOLD}[ROLLED_BACK]${COLOR_RESET}"
            ;;
        "FAILED"|"failed"|"FAIL"|"fail")
            printf "${COLOR_RED}${COLOR_BOLD}[FAILED]${COLOR_RESET}"
            ;;
        "RUNNING"|"running")
            printf "${COLOR_YELLOW}${COLOR_BOLD}[RUNNING]${COLOR_RESET}"
            ;;
        "ENABLED"|"enabled"|"ACTIVE"|"active")
            printf "${COLOR_GREEN}[ENABLED]${COLOR_RESET}"
            ;;
        "DISABLED"|"disabled")
            printf "${COLOR_DIM}[DISABLED]${COLOR_RESET}"
            ;;
        *)
            printf "${COLOR_DIM}[%s]${COLOR_RESET}" "$status"
            ;;
    esac
}

ui_dashboard_header() {
    local router_model router_fw load_str mem_str

    if command -v nvram >/dev/null 2>&1; then
        router_model="$(nvram get productid 2>/dev/null)"
        [ -z "$router_model" ] && router_model="$(nvram get model 2>/dev/null)"
        router_fw="$(nvram get buildno 2>/dev/null)_$(nvram get extendno 2>/dev/null)"
    fi
    [ -z "$router_model" ] && router_model="$(uname -m)"
    [ -z "$router_fw" ] && router_fw="$(uname -r)"

    if [ -f /proc/loadavg ]; then
        load_str="$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
    else
        load_str="N/A"
    fi

    if [ -f /proc/meminfo ]; then
        local mem_free
        mem_free=$(awk '/MemAvailable/ {print int($2/1024); f=1} END {if (!f) print "N/A"}' /proc/meminfo)
        if [ "$mem_free" = "N/A" ]; then
            mem_free=$(awk '/MemFree/ {free=$2} /Buffers/ {buf=$2} /Cached/ {cach=$2} END {print int((free+buf+cach)/1024)}' /proc/meminfo)
        fi
        mem_str="${mem_free} MB free"
    else
        mem_str="N/A"
    fi

    local cron_info
    cron_info="$(daemon_cron_status 2>/dev/null)"
    [ -z "$cron_info" ] && cron_info="Disabled"

    local last_status="None"
    local last_time="Never"
    if [ -f "${MCI_LOG_DIR}/last_run_status" ]; then
        last_status="$(cat "${MCI_LOG_DIR}/last_run_status")"
    fi
    if [ -f "${MCI_LOG_DIR}/last_run_time" ]; then
        last_time="$(cat "${MCI_LOG_DIR}/last_run_time")"
    fi

    printf "${COLOR_BOLD} Device:${COLOR_RESET}   %-18s ${COLOR_BOLD}Firmware:${COLOR_RESET}  %s\n" "$router_model" "$router_fw"
    printf "${COLOR_BOLD} Load:${COLOR_RESET}     %-18s ${COLOR_BOLD}Memory:${COLOR_RESET}    %s\n" "$load_str" "$mem_str"
    printf "${COLOR_BOLD} Cron:${COLOR_RESET}     %-18s ${COLOR_BOLD}Last Run:${COLOR_RESET}  " "$cron_info"
    ui_badge_status "$last_status"
    printf " (%s)\n" "$last_time"
    ui_divider
}

ui_list_jobs_table() {
    local jobs_dir="${MCI_JOBS_DIR:-./jobs}"
    printf "${COLOR_BOLD} Configured CI Automation Jobs:${COLOR_RESET}\n\n"

    local idx=1
    for jf in "$jobs_dir"/*.job.sh; do
        if [ -f "$jf" ]; then
            local jname="" jdesc="" jenabled=1
            jname="$(basename "$jf" .job.sh)"
            # Extract metadata without executing full script
            jenabled="$(grep -E '^JOB_ENABLED=' "$jf" | cut -d= -f2 | tr -d '"'\'' ' || echo "1")"
            [ -z "$jenabled" ] && jenabled=1
            jdesc="$(grep -E '^JOB_DESCRIPTION=' "$jf" | head -n 1 | cut -d= -f2- | tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//' || echo "$jname")"

            local jlast="None"
            if [ -f "${MCI_LOG_DIR}/last_run_status_${jname}" ]; then
                jlast="$(cat "${MCI_LOG_DIR}/last_run_status_${jname}")"
            fi

            local status_badge="[ENABLED]"
            [ "$jenabled" != "1" ] && status_badge="[DISABLED]"

            printf "  ${COLOR_CYAN}[%d]${COLOR_RESET} %-22s " "$idx" "$jname"
            if [ "$jenabled" = "1" ]; then
                printf "${COLOR_GREEN}%-10s${COLOR_RESET} " "$status_badge"
            else
                printf "${COLOR_DIM}%-10s${COLOR_RESET} " "$status_badge"
            fi
            printf "Result: "
            ui_badge_status "$jlast"
            printf "\n      ${COLOR_DIM}%s${COLOR_RESET}\n" "$jdesc"
            idx=$((idx + 1))
        fi
    done
    printf "\n"
}

ui_print_menu() {
    printf "${COLOR_BOLD} Actions:${COLOR_RESET}\n"
    printf "  ${COLOR_CYAN}[1]${COLOR_RESET}  Check All Triggers Now (Scan & Auto-Run Updates)\n"
    printf "  ${COLOR_CYAN}[2]${COLOR_RESET}  Force-Run a Specific Job (Manual Override)\n"
    printf "  ${COLOR_CYAN}[3]${COLOR_RESET}  Enable / Disable a Job\n"
    printf "  ${COLOR_CYAN}[4]${COLOR_RESET}  Create New Custom CI Job (Wizard)\n"
    printf "  ${COLOR_CYAN}[5]${COLOR_RESET}  View Job Execution & Rollback Logs\n"
    printf "  ${COLOR_CYAN}[6]${COLOR_RESET}  Configure Automated Scheduler / Cron (cru)\n"
    printf "  ${COLOR_CYAN}[7]${COLOR_RESET}  Router Resource Diagnostics & Guardrails\n"
    printf "  ${COLOR_CYAN}[8]${COLOR_RESET}  Notification Settings (Email / Discord / Telegram)\n"
    printf "\n"
    printf "  ${COLOR_YELLOW}[u]${COLOR_RESET}  Uninstall Merlin-CI\n"
    printf "  ${COLOR_RED}[e]${COLOR_RESET}  Exit to Shell / AMTM\n"
    printf "\n"
}

ui_prompt() {
    local prompt_msg="$1"
    local default_val="$2"
    if [ -n "$default_val" ]; then
        printf "${COLOR_BOLD}%s [default: %s]: ${COLOR_RESET}" "$prompt_msg" "$default_val"
    else
        printf "${COLOR_BOLD}%s: ${COLOR_RESET}" "$prompt_msg"
    fi
}

ui_pause() {
    printf "\n${COLOR_DIM}Press [Enter] to continue...${COLOR_RESET}"
    # shellcheck disable=SC2162
    read dummy
}
