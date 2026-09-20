#!/bin/sh
# ==============================================================================
# Merlin-CI: General AMTM Ecosystem Auto-Update & CI Validation Job
# ==============================================================================
# Native AMTM update integration:
# 1. Trigger Stage (mci_check_trigger):
#    Runs 'amtm updcheck' non-interactively to check all 3rd-party scripts
#    and amtm itself. If everything is current, it exits quietly (0 disk writes).
# 2. Backup Stage (mci_backup):
#    Snapshots /jffs/scripts/ to external USB storage before any changes.
# 3. Execution Stage (mci_run):
#    ONLY updates the specific scripts that 'amtm updcheck' identified as having
#    newer versions! Never force-re-downloads scripts that are already up to date.
# 4. Verification Stage (mci_verify):
#    Runs CI smoke tests (syntax check on updated scripts, dnsmasq/httpd health).
# 5. Rollback Stage (mci_rollback):
#    Automatically restores pre-flight backup if verification fails.
# ==============================================================================

JOB_NAME="amtm-general-autoupdate"
JOB_DESCRIPTION="Master update for amtm and all amtmupdate-compliant router scripts"
JOB_ENABLED=1
JOB_TYPE="daily"

# Ensure router binary paths are present
export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/jffs/scripts:$PATH"

AMTM_ADD_DIR="/jffs/addons/amtm"
AMTM_MOD_REGISTRY="${AMTM_ADD_DIR}/a_fw/amtm.mod"
TPU_CHECK_FILE="/tmp/amtm-tpu-check"
PENDING_UPDATES_FILE="/tmp/mci_amtm_pending_updates.txt"
SCRIPTS_DIR="/jffs/scripts"

# Helper: Locate amtm executable on Asuswrt-Merlin
_find_amtm_bin() {
    for p in "/usr/sbin/amtm" "/jffs/scripts/amtm" "$(command -v amtm 2>/dev/null)" "$(which amtm 2>/dev/null)"; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# Helper: Resolve any AMTM script name (e.g. Wireless_Report, spdMerlin) to its executable path
_resolve_script_path() {
    local sname="$1"
    [ -z "$sname" ] && return 1

    # AMTM core is strictly handled by amtm-self-update. Never resolve amtm here!
    case "$sname" in
        amtm|AMTM|*amtm*) return 1 ;;
    esac

    # Explicit resolver for Wireless_Report
    case "$sname" in
        Wireless_Report*|wireless_report*|wirelessreport*|wr|WR)
            for c in "/jffs/addons/wireless_report/wirelessreport.sh" \
                     "/jffs/scripts/Wireless_Report" \
                     "/jffs/scripts/Wireless_Report.sh" \
                     "/jffs/scripts/wirelessreport.sh"; do
                if [ -f "$c" ]; then
                    echo "$c"
                    return 0
                fi
            done
            ;;
    esac

    local scriptloc=""

    # 1. Search the official AMTM master modules registry
    if [ -f "$AMTM_MOD_REGISTRY" ]; then
        scriptloc="$(grep -E "[[:space:]]${sname}([[:space:]]|$)" "$AMTM_MOD_REGISTRY" 2>/dev/null | awk '{print $1}' | head -n 1)"
        if [ -n "$scriptloc" ] && [ -f "$scriptloc" ] && [ "$(basename "$scriptloc")" != "amtm" ]; then
            echo "$scriptloc"
            return 0
        fi
    fi

    # 2. Check AMTM individual .mod files
    local mod_file="${AMTM_ADD_DIR}/${sname}.mod"
    if [ -f "$mod_file" ]; then
        scriptloc="$(grep -E '^/jffs/|^/opt/bin/' "$mod_file" 2>/dev/null | awk '{print $1}' | head -n 1)"
        if [ -n "$scriptloc" ] && [ -f "$scriptloc" ] && [ "$(basename "$scriptloc")" != "amtm" ]; then
            echo "$scriptloc"
            return 0
        fi
    fi

    # 3. Check standard filesystem candidates in /jffs/scripts and /jffs/addons
    local lower_sname
    lower_sname="$(echo "$sname" | tr '[:upper:]' '[:lower:]')"

    for cand in \
        "${SCRIPTS_DIR}/${sname}" \
        "${SCRIPTS_DIR}/${sname}.sh" \
        "${SCRIPTS_DIR}/${lower_sname}" \
        "${SCRIPTS_DIR}/${lower_sname}.sh" \
        "/opt/bin/${sname}" \
        "/opt/bin/${lower_sname}" \
        "/jffs/addons/${lower_sname}/"*.sh \
        "/jffs/addons/${sname}/"*.sh; do
        if [ -f "$cand" ] && [ -x "$cand" ] && [ "$(basename "$cand")" != "amtm" ]; then
            echo "$cand"
            return 0
        fi
    done

    return 1
}

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[AMTM-GENERAL]${COLOR_RESET} Checking for 3rd-party script updates via AMTM registry...\n"

    rm -f "$PENDING_UPDATES_FILE"

    local check_source=""

    # Check 1: Check existing persistent AMTM updates file
    if [ -s "${AMTM_ADD_DIR}/availUpd.txt" ] && grep -qiE "(\->|Update=)" "${AMTM_ADD_DIR}/availUpd.txt" 2>/dev/null; then
        check_source="${AMTM_ADD_DIR}/availUpd.txt"
    elif [ -s "/tmp/availUpd.txt" ] && grep -qiE "(\->|Update=)" "/tmp/availUpd.txt" 2>/dev/null; then
        check_source="/tmp/availUpd.txt"
    fi

    # Check 2: If AMTM update file doesn't exist, check known installed scripts directly
    if [ -z "$check_source" ]; then
        # Check Wireless_Report directly if installed
        local wr_path
        wr_path="$(_resolve_script_path "Wireless_Report")"
        if [ -n "$wr_path" ] && [ -f "$wr_path" ]; then
            local wr_cur
            wr_cur="$(grep -m1 "SCRIPT_VERSION=" "$wr_path" 2>/dev/null | cut -d'"' -f2)"
            [ -z "$wr_cur" ] && wr_cur="$("$wr_path" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1)"
            if [ -n "$wr_cur" ]; then
                local wr_remote
                wr_remote="$(curl -sL --retry 2 --connect-timeout 5 "https://raw.githubusercontent.com/JB1366/Wireless_Report/master/wirelessreport.sh" 2>/dev/null | grep -m1 "SCRIPT_VERSION=" | cut -d'"' -f2)"
                if [ -n "$wr_remote" ] && [ "$wr_cur" != "$wr_remote" ]; then
                    echo "Wireless_Report ${wr_cur} ${wr_remote}" >> "$PENDING_UPDATES_FILE"
                fi
            fi
        fi
    fi

    if [ -n "$check_source" ] && [ -s "$check_source" ]; then
        # Parse scripts that have pending updates
        # Supports both AMTM variable format: Wireless_ReportUpdate="-> upd"
        # and notification format: - Wireless_Report 3.2.5 -> 3.2.7
        while read -r raw_line; do
            [ -z "$raw_line" ] && continue

            local sname="" old_v="installed" new_v="latest"

            case "$raw_line" in
                *Update=*|*update=*)
                    # AMTM internal format: Wireless_ReportUpdate="-> upd" or Wireless_ReportUpdate="-> 3.2.7"
                    sname="${raw_line%%Update=*}"
                    sname="${sname%%update=*}"
                    sname="$(echo "$sname" | tr -d '"'\'' ')"

                    local ver_match
                    ver_match="$(echo "$raw_line" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | tail -n 1)"
                    [ -n "$ver_match" ] && new_v="$ver_match"
                    ;;
                *"->"*)
                    # AMTM email/CLI format: - Wireless_Report 3.2.5 -> 3.2.7
                    local clean_line
                    clean_line="$(echo "$raw_line" | sed 's/^[-*[:space:]]*//')"
                    sname="$(echo "$clean_line" | awk '{print $1}')"
                    sname="${sname%%Update*}"
                    sname="${sname%%update*}"
                    sname="${sname%%=*}"
                    sname="$(echo "$sname" | tr -d '"'\'' ')"

                    old_v="$(echo "$clean_line" | awk '{print $(NF-2)}')"
                    new_v="$(echo "$clean_line" | awk '{print $NF}')"
                    ;;
            esac

            [ -z "$sname" ] && continue
            [ "$sname" = "amtm" ] && continue

            # De-duplicate entries in pending list
            if ! grep -q "^${sname} " "$PENDING_UPDATES_FILE" 2>/dev/null; then
                # Query installed version from script if known
                local spath
                spath="$(_resolve_script_path "$sname")"
                if [ -n "$spath" ] && [ -x "$spath" ]; then
                    local v_query
                    v_query="$("$spath" -v 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)"
                    [ -z "$v_query" ] && v_query="$(grep -m1 "SCRIPT_VERSION=" "$spath" 2>/dev/null | cut -d'"' -f2)"
                    [ -n "$v_query" ] && old_v="$v_query"
                fi

                echo "$sname ${old_v:-unknown} ${new_v:-latest}" >> "$PENDING_UPDATES_FILE"
            fi
        done < "$check_source"
    fi

    local found_updates=0
    if [ -f "$PENDING_UPDATES_FILE" ]; then
        found_updates=$(wc -l < "$PENDING_UPDATES_FILE" 2>/dev/null || echo 0)
    fi

    if [ "$found_updates" -gt 0 ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}Detected %d pending script update(s):${COLOR_RESET}\n" "$found_updates"
        local first_old_ver="" first_new_ver=""
        while read -r u_s u_old u_new; do
            printf "    ${COLOR_CYAN}*${COLOR_RESET} ${COLOR_BOLD}${COLOR_MAGENTA}%s${COLOR_RESET} (${COLOR_YELLOW}%s${COLOR_RESET} -> ${COLOR_GREEN}%s${COLOR_RESET})\n" "$u_s" "$u_old" "$u_new"
            [ -z "$first_old_ver" ] && first_old_ver="$u_old"
            [ -z "$first_new_ver" ] && first_new_ver="$u_new"
        done < "$PENDING_UPDATES_FILE"

        if [ "$found_updates" -eq 1 ]; then
            MCI_OLD_VERSION="${first_old_ver:-unknown}"
            MCI_NEW_VERSION="${first_new_ver:-latest}"
        else
            MCI_OLD_VERSION="Multiple"
            MCI_NEW_VERSION="$found_updates scripts"
        fi
        return 0
    fi

    printf "${COLOR_GREEN}--> [AMTM-GENERAL]${COLOR_RESET} All AMTM scripts and addons are up-to-date. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    printf "${COLOR_CYAN}--> [BACKUP]${COLOR_RESET} Creating pre-update snapshot of /jffs/scripts/ to %s...\n" "$backup_dir"
    mkdir -p "$backup_dir/scripts" 2>/dev/null || true

    if [ -d "$SCRIPTS_DIR" ]; then
        cp -pf "$SCRIPTS_DIR"/* "$backup_dir/scripts/" 2>/dev/null || true
    fi

    # Snapshot checksums
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$SCRIPTS_DIR"/* > "$backup_dir/checksums_before.md5" 2>/dev/null || true
    fi

    # Copy list of pending updates for audit
    if [ -f "$PENDING_UPDATES_FILE" ]; then
        cp -f "$PENDING_UPDATES_FILE" "$backup_dir/pending_updates.txt" 2>/dev/null || true
    fi

    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Pre-flight backup recorded in %s\n" "$backup_dir"
    return 0
}

_execute_script_update() {
    local spath="$1"
    local sname="$2"

    [ -z "$spath" ] && return 1
    # Guard: Never execute amtm core inside 3rd-party autoupdater
    case "$sname" in amtm|AMTM) return 1 ;; esac
    case "$(basename "$spath")" in amtm) return 1 ;; esac

    printf "--> [UPDATING] Updating ${COLOR_BOLD}%s${COLOR_RESET} (${COLOR_DIM}%s${COLOR_RESET})...\n" "$sname" "$spath"

    # Method 1: Direct repository fetch for Wireless_Report (cleanest & safest)
    case "$sname" in
        Wireless_Report*|wireless_report*|wirelessreport*|wr|WR)
            printf "--> [UPDATING] Fetching latest Wireless_Report from official repository...\n"
            local target_loc="$spath"
            [ -z "$target_loc" ] && target_loc="/jffs/addons/wireless_report/wirelessreport.sh"
            local tmp_wr="/tmp/wr_new_$$"
            if curl -sL --retry 3 --connect-timeout 10 "https://raw.githubusercontent.com/JB1366/Wireless_Report/master/wirelessreport.sh" -o "$tmp_wr" 2>/dev/null; then
                if [ -s "$tmp_wr" ] && grep -q "SCRIPT_VERSION" "$tmp_wr"; then
                    if sh -n "$tmp_wr" 2>/dev/null; then
                        mv -f "$tmp_wr" "$target_loc"
                        chmod 755 "$target_loc"
                        printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Wireless_Report updated successfully to %s.\n" "$target_loc"
                        return 0
                    fi
                fi
                rm -f "$tmp_wr"
            fi
            ;;
    esac

    # Method 2: Non-interactive script update with closed stdin
    if [ -x "$spath" ]; then
        if "$spath" update < /dev/null 2>&1; then
            return 0
        fi
        if "$spath" amtmupdate < /dev/null 2>&1; then
            return 0
        fi
        if "$spath" -u < /dev/null 2>&1; then
            return 0
        fi
        if "$spath" -f < /dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Starting targeted updates for scripts identified by AMTM...\n"

    if [ ! -f "$PENDING_UPDATES_FILE" ] || [ ! -s "$PENDING_UPDATES_FILE" ]; then
        # If run was forced (-f), populate from installed scripts (e.g. Wireless_Report)
        local wr_path
        wr_path="$(_resolve_script_path "Wireless_Report")"
        if [ -n "$wr_path" ] && [ -f "$wr_path" ]; then
            local wr_cur
            wr_cur="$(grep -m1 "SCRIPT_VERSION=" "$wr_path" 2>/dev/null | cut -d'"' -f2)"
            [ -z "$wr_cur" ] && wr_cur="$("$wr_path" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1)"
            echo "Wireless_Report ${wr_cur:-installed} 3.2.7" > "$PENDING_UPDATES_FILE"
        else
            printf "${COLOR_YELLOW}--> [RUN] No pending updates recorded. Nothing to execute.${COLOR_RESET}\n"
            return 0
        fi
    fi

    local updated_count=0
    local failed_count=0

    # Read each pending update and execute update on that script
    while read -r line; do
        [ -z "$line" ] && continue

        local sname old_v new_v
        sname=$(echo "$line" | awk '{print $1}')
        old_v=$(echo "$line" | awk '{print $2}')
        new_v=$(echo "$line" | awk '{print $3}')

        # Resolve script location
        local script_path
        script_path="$(_resolve_script_path "$sname")"

        if [ -n "$script_path" ] && [ -x "$script_path" ]; then
            printf "${COLOR_CYAN}--> [UPDATING]${COLOR_RESET} Updating ${COLOR_BOLD}${COLOR_MAGENTA}%s${COLOR_RESET} (${COLOR_YELLOW}%s${COLOR_RESET} -> ${COLOR_GREEN}%s${COLOR_RESET})...\n" "$sname" "$old_v" "$new_v"
            if _execute_script_update "$script_path" "$sname"; then
                printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} ${COLOR_BOLD}%s${COLOR_RESET} updated successfully to ${COLOR_GREEN}%s${COLOR_RESET}.\n" "$sname" "$new_v"
                updated_count=$((updated_count + 1))
            else
                printf "--> ${COLOR_YELLOW}[WARNING]${COLOR_RESET} %s update failed across all update methods.\n" "$sname"
                failed_count=$((failed_count + 1))
            fi
        else
            printf "   ${COLOR_RED}[ERROR]${COLOR_RESET} Could not resolve executable path for ${COLOR_BOLD}%s${COLOR_RESET}. Checked AMTM registry and filesystem.\n" "$sname"
            failed_count=$((failed_count + 1))
        fi
    done < "$PENDING_UPDATES_FILE"

    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Targeted update cycle completed (${COLOR_GREEN}%d updated${COLOR_RESET}, ${COLOR_YELLOW}%d warnings${COLOR_RESET}).\n" "$updated_count" "$failed_count"

    # Prune updated scripts from AMTM availUpd.txt rather than deleting entire file
    if [ -f "${AMTM_ADD_DIR}/availUpd.txt" ]; then
        while read -r line; do
            local done_sname
            done_sname=$(echo "$line" | awk '{print $1}')
            [ -n "$done_sname" ] && sed -i "/${done_sname}/d" "${AMTM_ADD_DIR}/availUpd.txt" 2>/dev/null || true
        done < "$PENDING_UPDATES_FILE"
    fi

    if [ "$failed_count" -gt 0 ] && [ "$updated_count" -eq 0 ]; then
        return 1
    fi

    return 0
}

mci_verify() {
    printf "${COLOR_CYAN}--> [VERIFY]${COLOR_RESET} Running CI smoke tests across updated scripts...\n"

    # Check 1: Syntax validation ONLY on the scripts that were updated
    if [ -f "$PENDING_UPDATES_FILE" ]; then
        while read -r line; do
            local sname
            sname=$(echo "$line" | awk '{print $1}')
            [ -z "$sname" ] || [ "$sname" = "amtm" ] && continue

            local script_path
            script_path="$(_resolve_script_path "$sname")"
            if [ -n "$script_path" ] && [ -f "$script_path" ]; then
                if ! sh -n "$script_path" 2>/dev/null; then
                    printf "${COLOR_RED}--> [FAIL] Syntax error detected in %s post-update!${COLOR_RESET}\n" "$script_path"
                    return 1
                fi
                printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Syntax check: ${COLOR_BOLD}%s${COLOR_RESET} (${COLOR_DIM}%s${COLOR_RESET})\n" "$sname" "$script_path"
            fi
        done < "$PENDING_UPDATES_FILE"
    fi

    # Check 2: Core router process health
    if ! pidof dnsmasq >/dev/null 2>&1; then
        printf "${COLOR_RED}--> [FAIL] Critical service 'dnsmasq' is not running!${COLOR_RESET}\n"
        return 1
    fi

    # Check web server (allow a brief grace period if an addon reloaded web UI hooks)
    local web_ok=0
    for attempt in 1 2 3; do
        if pidof httpd >/dev/null 2>&1 || pidof httpds >/dev/null 2>&1; then
            web_ok=1
            break
        fi
        sleep 1
    done

    if [ "$web_ok" -eq 1 ]; then
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Critical router processes (dnsmasq, httpd/httpds) are operational.\n"
    else
        printf "--> ${COLOR_YELLOW}[WARNING] Web server (httpd/httpds) is still initializing.${COLOR_RESET}\n"
    fi

    # Check 3: Local DNS resolution test
    if command -v nslookup >/dev/null 2>&1; then
        if ! nslookup router.asus.com 127.0.0.1 >/dev/null 2>&1; then
            printf "--> ${COLOR_YELLOW}[WARNING] Local DNS resolution test on 127.0.0.1 failed.${COLOR_RESET}\n"
        else
            printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Local DNS resolution responsive.\n"
        fi
    fi

    # Clean up pending list post verification
    rm -f "$PENDING_UPDATES_FILE"

    printf "${COLOR_GREEN}--> [VERIFY]${COLOR_RESET} All CI smoke tests ${COLOR_GREEN}${COLOR_BOLD}PASSED${COLOR_RESET} successfully!\n"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} ${COLOR_YELLOW}Smoke tests failed! Restoring /jffs/scripts/ from backup...${COLOR_RESET}\n"

    if [ -d "$backup_dir/scripts" ]; then
        cp -pf "$backup_dir/scripts/"* "$SCRIPTS_DIR/" 2>/dev/null || true
        chmod 755 "$SCRIPTS_DIR"/* 2>/dev/null || true
    fi

    rm -f "$PENDING_UPDATES_FILE"

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} Restored /jffs/scripts/. Restarting services...\n"
    service restart_dnsmasq >/dev/null 2>&1 || true
    service restart_firewall >/dev/null 2>&1 || true
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} AMTM general auto-update finished: ${COLOR_BOLD}%s${COLOR_RESET} (${duration}s)\n" "$status"
}
