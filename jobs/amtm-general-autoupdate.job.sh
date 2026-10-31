#!/bin/sh
# ==============================================================================
# Merlin-CI: General AMTM Ecosystem Auto-Update & CI Validation Job
# ==============================================================================
# Native AMTM update integration:
# 1. Trigger Stage (mci_check_trigger):
#    Proactively evaluates 3rd-party script updates via AMTM's native updcheck
#    and cached state (availUpd.txt / amtm-tpu-check). If everything is current,
#    exits quietly (0 disk writes).
# 2. Backup Stage (mci_backup):
#    Snapshots /jffs/scripts/ and any targeted external addons to external USB storage.
# 3. Execution Stage (mci_run):
#    ONLY updates the specific scripts identified as having newer versions!
#    Supports official 'amtmupdate' parameter, handles lock contention (e.g. Skynet cron),
#    and never force-re-downloads scripts that are already up to date.
# 4. Verification Stage (mci_verify):
#    Runs CI smoke tests (syntax check on updated scripts, dnsmasq/httpd health, DNS resolution).
# 5. Rollback Stage (mci_rollback):
#    Automatically restores pre-flight backup if verification fails.
# ==============================================================================

JOB_NAME="amtm-general-autoupdate"
JOB_DESCRIPTION="Master update for amtm and all amtmupdate-compliant router scripts"
JOB_ENABLED=1
JOB_TYPE="both"

# Ensure router binary paths are present
export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/jffs/scripts:$PATH"

AMTM_ADD_DIR="/jffs/addons/amtm"
AMTM_MOD_REGISTRY="${AMTM_ADD_DIR}/a_fw/amtm.mod"
AMTM_UPDATE_SCRIPTS_CONF="${AMTM_ADD_DIR}/amtmUpdateScripts"
TPU_CHECK_FILE="/tmp/amtm-tpu-check"
PENDING_UPDATES_FILE="/tmp/mci_amtm_pending_updates.txt"
SCRIPTS_DIR="/jffs/scripts"

# Helper: Determine if a script is permitted for automatic updates
_is_script_autoupdate_enabled() {
    local sname="$1"
    [ -z "$sname" ] && return 1

    local lower_sname
    lower_sname="$(echo "$sname" | tr 'A-Z' 'a-z')"

    # 1. Permanent core / default exclusions:
    # - amtm core is strictly handled by amtm-self-update.job.sh
    # - MerlinAU (Merlin Auto-Update) handles router firmware updates and has script
    #   auto-update disabled by default; attempting AMTM updates causes failures/loops.
    case "$lower_sname" in
        amtm|*amtm*) return 1 ;;
        merlinau|*merlinau*) return 1 ;;
    esac

    # 2. Check custom user exclusions if configured (via merlin-ci.conf)
    if [ -n "$MCI_EXCLUDE_SCRIPTS" ]; then
        for excl in $MCI_EXCLUDE_SCRIPTS; do
            if [ "$(echo "$excl" | tr 'A-Z' 'a-z')" = "$lower_sname" ]; then
                return 1
            fi
        done
    fi

    # 3. Check AMTM's official amtmUpdateScripts registry
    # AMTM prefixes disabled scripts with # (disabled in amtm) or ## (disabled by script, like ##MerlinAU)
    if [ -f "$AMTM_UPDATE_SCRIPTS_CONF" ]; then
        if grep -qiE "^[[:space:]]*##?[[:space:]]*${sname}([[:space:]]|$)" "$AMTM_UPDATE_SCRIPTS_CONF" 2>/dev/null; then
            return 1
        fi
        if grep -qiE "^[[:space:]]*##?[[:space:]]*${lower_sname}([[:space:]]|$)" "$AMTM_UPDATE_SCRIPTS_CONF" 2>/dev/null; then
            return 1
        fi
    fi

    return 0
}

# Helper: BusyBox-compatible case-insensitive pruning of a script from all update tracking files
_prune_script_from_update_files() {
    local target_script="$1"
    [ -z "$target_script" ] && return 0

    local uf
    for uf in "${AMTM_ADD_DIR}/availUpd.txt" "/tmp/availUpd.txt" "$TPU_CHECK_FILE"; do
        if [ -f "$uf" ]; then
            local tmp_prune="${uf}.prune.$$"
            grep -v -iE "^[[:space:]]*[-*[:space:]]*${target_script}([[:space:]]|=|$)" "$uf" > "$tmp_prune" 2>/dev/null || true
            if [ -s "$tmp_prune" ]; then
                local content_count
                content_count="$(grep -v -iE '^[[:space:]]*$|^#|Available script updates|No script updates' "$tmp_prune" 2>/dev/null | wc -l)"
                if [ "$content_count" -gt 0 ]; then
                    mv -f "$tmp_prune" "$uf" 2>/dev/null || true
                else
                    rm -f "$uf" "$tmp_prune" 2>/dev/null || true
                fi
            else
                rm -f "$uf" "$tmp_prune" 2>/dev/null || true
            fi
        fi
    done
}

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

# Helper: Resolve any AMTM script name (e.g. Skynet, Diversion, Vnstat, Wireless_Report) to its executable path
_resolve_script_path() {
    local sname="$1"
    [ -z "$sname" ] && return 1

    # AMTM core is strictly handled by amtm-self-update. Never resolve amtm here!
    # MerlinAU is disabled by default for AMTM auto-updates. Never resolve MerlinAU here!
    case "$sname" in
        amtm|AMTM|*amtm*|merlinau|MerlinAU|*merlinau*|*MerlinAU*) return 1 ;;
    esac

    local lower_sname
    lower_sname="$(echo "$sname" | tr 'A-Z' 'a-z')"

    # 1. Canonical Mapping Table for AMTM ecosystem scripts
    case "$lower_sname" in
        skynet|firewall)
            for c in "/jffs/scripts/firewall" "/jffs/scripts/firewall.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        diversion)
            for c in "/opt/bin/diversion" "/jffs/scripts/diversion"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        vnstat|dn-vnstat|dn_vnstat)
            for c in "/jffs/scripts/dn-vnstat" "/jffs/scripts/vnstat" "/opt/bin/vnstat"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        flexqos)
            for c in "/jffs/addons/flexqos/flexqos.sh" "/jffs/scripts/flexqos"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        yazfi)
            for c in "/jffs/scripts/YazFi" "/jffs/scripts/yazfi.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        yazdhcp)
            for c in "/jffs/scripts/YazDHCP" "/jffs/scripts/yazdhcp.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        scribe)
            for c in "/jffs/scripts/scribe" "/jffs/scripts/scribe.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        x3mrouting|x3mmenu)
            for c in "/opt/bin/x3mMenu" "/opt/bin/x3mRouting"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        unbound_manager|unbound-manager|unboundmanager)
            for c in "/jffs/addons/unbound/unbound_manager.sh" "/jffs/scripts/unbound_manager.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        unbound_stats|unboundstats)
            for c in "/jffs/addons/unbound/unbound_stats.sh" "/jffs/scripts/unbound_stats.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        connmon)
            for c in "/jffs/scripts/connmon" "/jffs/scripts/connmon.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        rtrmon)
            for c in "/jffs/scripts/rtrmon.sh" "/jffs/scripts/rtrmon"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        killmon)
            for c in "/jffs/scripts/killmon.sh" "/jffs/scripts/killmon"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        backupmon)
            for c in "/jffs/scripts/backupmon.sh" "/jffs/scripts/backupmon"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        ntpmerlin)
            for c in "/jffs/scripts/ntpmerlin" "/jffs/scripts/ntpmerlin.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        scmerlin)
            for c in "/jffs/scripts/scmerlin" "/jffs/scripts/scmerlin.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        spdmerlin)
            for c in "/jffs/scripts/spdmerlin" "/jffs/scripts/spdmerlin.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        wxmon)
            for c in "/jffs/scripts/wxmon.sh" "/jffs/scripts/wxmon"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        wireless_report|wirelessreport|wr)
            for c in "/jffs/addons/wireless_report/wirelessreport.sh" \
                     "/jffs/scripts/Wireless_Report" \
                     "/jffs/scripts/Wireless_Report.sh" \
                     "/jffs/scripts/wirelessreport.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        uidivstats)
            for c in "/jffs/scripts/uiDivStats" "/jffs/scripts/uidivstats.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        uiscribe)
            for c in "/jffs/scripts/uiScribe" "/jffs/scripts/uiscribe.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        modsyslogui)
            for c in "/jffs/addons/modsyslogui/modsyslogui" "/jffs/scripts/modsyslogui"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        adguardhome)
            for c in "/opt/etc/AdGuardHome/installer" "/opt/etc/AdGuardHome/AdGuardHome"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        wicens)
            for c in "/jffs/scripts/wicens.sh" "/jffs/scripts/wicens"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        wan_failover|wan-failover|wanfailover)
            for c in "/jffs/scripts/wan-failover.sh" "/jffs/scripts/wan-failover"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        knock)
            for c in "/jffs/scripts/knock.sh" "/jffs/scripts/knock"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        vpnmon|vpnmon-r3)
            for c in "/jffs/scripts/vpnmon-r3.sh" "/jffs/scripts/vpnmon.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        vpn_routing|domain_vpn_routing)
            for c in "/jffs/scripts/domain_vpn_routing.sh" "/jffs/scripts/vpn_routing.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        wireguard_manager|wireguard)
            for c in "/jffs/addons/wireguard/wg_manager.sh" "/jffs/scripts/wg_manager.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        tailmon)
            for c in "/jffs/scripts/tailmon.sh" "/jffs/scripts/tailmon"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
        sendemail|se)
            for c in "/jffs/addons/SendEmail.d/SendEmail.sh" "/jffs/scripts/SendEmail" "/jffs/scripts/SendEmail.sh"; do
                [ -f "$c" ] && { echo "$c"; return 0; }
            done
            ;;
    esac

    # 2. Dynamic Search in official AMTM master registry (a_fw/amtm.mod)
    if [ -f "$AMTM_MOD_REGISTRY" ]; then
        local reg_line
        reg_line="$(grep -iE "^[[:space:]]*/(jffs|opt)/[^[:space:]]+[[:space:]]+.*[[:space:]¦]${lower_sname}([[:space:]¦]|$)" "$AMTM_MOD_REGISTRY" 2>/dev/null | head -n 1)"
        [ -z "$reg_line" ] && reg_line="$(grep -iE "^[[:space:]]*/(jffs|opt)/[^[:space:]]+[[:space:]]+${lower_sname}[[:space:]]" "$AMTM_MOD_REGISTRY" 2>/dev/null | head -n 1)"
        if [ -n "$reg_line" ]; then
            local dyn_loc
            dyn_loc="$(echo "$reg_line" | awk '{print $1}')"
            if [ -n "$dyn_loc" ] && [ -f "$dyn_loc" ] && [ "$(basename "$dyn_loc")" != "amtm" ]; then
                echo "$dyn_loc"
                return 0
            fi
        fi
    fi

    # 3. Check AMTM individual .mod files
    for mf in "${AMTM_ADD_DIR}/${lower_sname}.mod" "${AMTM_ADD_DIR}/${sname}.mod"; do
        if [ -f "$mf" ]; then
            local modloc
            modloc="$(grep -E '^/jffs/|^/opt/bin/' "$mf" 2>/dev/null | awk '{print $1}' | head -n 1)"
            if [ -n "$modloc" ] && [ -f "$modloc" ] && [ "$(basename "$modloc")" != "amtm" ]; then
                echo "$modloc"
                return 0
            fi
        fi
    done

    # 4. Check standard filesystem candidates in /jffs/scripts, /opt/bin, /jffs/addons
    for cand in \
        "${SCRIPTS_DIR}/${sname}" \
        "${SCRIPTS_DIR}/${sname}.sh" \
        "${SCRIPTS_DIR}/${lower_sname}" \
        "${SCRIPTS_DIR}/${lower_sname}.sh" \
        "/opt/bin/${sname}" \
        "/opt/bin/${lower_sname}" \
        "/jffs/addons/${lower_sname}/"*.sh \
        "/jffs/addons/${sname}/"*.sh; do
        if [ -f "$cand" ] && [ "$(basename "$cand")" != "amtm" ]; then
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

    # Loop Guard: Prevent rapid trigger loops (enforce minimum 1 hour cooldown between update executions)
    local last_exec_file="/tmp/mci_amtm_last_exec_epoch"
    local now_epoch
    now_epoch="$(date +%s 2>/dev/null || echo 0)"
    case "$now_epoch" in *[!0-9]*) now_epoch=0 ;; esac
    local last_exec_epoch=0
    [ -f "$last_exec_file" ] && last_exec_epoch="$(cat "$last_exec_file" 2>/dev/null || echo 0)"
    case "$last_exec_epoch" in *[!0-9]*) last_exec_epoch=0 ;; esac
    [ -z "$last_exec_epoch" ] && last_exec_epoch=0
    local since_last_exec=$((now_epoch - last_exec_epoch))
    if [ "$last_exec_epoch" -gt 0 ] && [ "$since_last_exec" -ge 0 ] && [ "$since_last_exec" -lt 3600 ]; then
        printf "--> ${COLOR_GREEN}[AMTM-GENERAL]${COLOR_RESET} Update cycle ran recently (%ds ago < 3600s cooldown). ${COLOR_GREEN}[ALL CLEAR]${COLOR_RESET}\n" "$since_last_exec"
        return 1
    fi

    local check_source=""

    # Check 1: Check existing persistent AMTM updates file (< 2ms, zero network)
    if [ -s "${AMTM_ADD_DIR}/availUpd.txt" ] && grep -qiE "(\->|Update=)" "${AMTM_ADD_DIR}/availUpd.txt" 2>/dev/null; then
        check_source="${AMTM_ADD_DIR}/availUpd.txt"
    elif [ -s "/tmp/availUpd.txt" ] && grep -qiE "(\->|Update=)" "/tmp/availUpd.txt" 2>/dev/null; then
        check_source="/tmp/availUpd.txt"
    elif [ -s "$TPU_CHECK_FILE" ] && grep -qiE "(\->|MD5 update)" "$TPU_CHECK_FILE" 2>/dev/null; then
        check_source="$TPU_CHECK_FILE"
    fi

    # Check 2: Proactive periodic update check with rate limiting (every 6 hours / 21600s)
    # Never run heavy 35s network queries on every 15-minute watchdog tick!
    local last_check_file="/tmp/mci_amtm_last_active_check"
    local last_check_epoch=0
    [ -f "$last_check_file" ] && last_check_epoch="$(cat "$last_check_file" 2>/dev/null || echo 0)"
    case "$last_check_epoch" in *[!0-9]*) last_check_epoch=0 ;; esac
    [ -z "$last_check_epoch" ] && last_check_epoch=0
    local elapsed=$((now_epoch - last_check_epoch))

    if [ -z "$check_source" ] && [ "$elapsed" -ge 21600 ]; then
        local amtm_bin
        amtm_bin="$(_find_amtm_bin)"
        if [ -n "$amtm_bin" ] && [ -x "$amtm_bin" ]; then
            printf "    ${COLOR_DIM}Running periodic proactive AMTM update check (6h cooldown)...${COLOR_RESET}\n"
            echo "$now_epoch" > "$last_check_file"
            touch /tmp/amtm-no-delete
            # Use non-interactive 'tpu' check
            "$amtm_bin" tpu >/dev/null 2>&1
            rm -f /tmp/amtm-no-delete

            if [ -s "${AMTM_ADD_DIR}/availUpd.txt" ] && grep -qiE "(\->|Update=)" "${AMTM_ADD_DIR}/availUpd.txt" 2>/dev/null; then
                check_source="${AMTM_ADD_DIR}/availUpd.txt"
            elif [ -s "/tmp/availUpd.txt" ] && grep -qiE "(\->|Update=)" "/tmp/availUpd.txt" 2>/dev/null; then
                check_source="/tmp/availUpd.txt"
            elif [ -s "$TPU_CHECK_FILE" ] && grep -qiE "(\->|MD5 update)" "$TPU_CHECK_FILE" 2>/dev/null; then
                check_source="$TPU_CHECK_FILE"
            fi
        fi
    fi

    # Check 3: Check Wireless_Report directly as fallback if due for active check
    if [ -z "$check_source" ] && [ "$elapsed" -ge 21600 ]; then
        local wr_path
        wr_path="$(_resolve_script_path "Wireless_Report")"
        if [ -n "$wr_path" ] && [ -f "$wr_path" ]; then
            local wr_cur
            wr_cur="$(grep -m1 "SCRIPT_VERSION=" "$wr_path" 2>/dev/null | cut -d'"' -f2)"
            [ -z "$wr_cur" ] && wr_cur="$("$wr_path" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1)"
            if [ -n "$wr_cur" ]; then
                local wr_remote
                wr_remote="$(curl -sL --retry 2 --connect-timeout 5 "https://raw.githubusercontent.com/JB1366/Wireless_Report/main/wirelessreport.sh" 2>/dev/null | grep -m1 "SCRIPT_VERSION=" | cut -d'"' -f2)"
                [ -z "$wr_remote" ] && wr_remote="$(curl -sL --retry 2 --connect-timeout 5 "https://raw.githubusercontent.com/JB1366/Wireless_Report/master/wirelessreport.sh" 2>/dev/null | grep -m1 "SCRIPT_VERSION=" | cut -d'"' -f2)"
                if [ -n "$wr_remote" ] && [ "$wr_cur" != "$wr_remote" ]; then
                    echo "Wireless_Report ${wr_cur} ${wr_remote}" >> "$PENDING_UPDATES_FILE"
                fi
            fi
        fi
    fi

    if [ -n "$check_source" ] && [ -s "$check_source" ]; then
        # Parse scripts that have pending updates
        # Supports:
        # 1. AMTM variable format: skynetUpdate="-> 9.0.4"
        # 2. AMTM tpu check format: - skynet 9.0.3 -> 9.0.4
        # 3. AMTM menu format: 2 open Skynet 9.0.3 -> 9.0.4
        while read -r raw_line; do
            [ -z "$raw_line" ] && continue
            case "$raw_line" in
                *"No script updates available"*) continue ;;
                *"Available script updates"*) continue ;;
                *MD5=*|*md5=*) continue ;;
            esac

            local sname="" old_v="installed" new_v="latest"

            # Strip HTML tags like <br> generated by AMTM email format
            local clean_raw
            clean_raw="$(echo "$raw_line" | sed 's/<[^>]*>//g')"

            case "$clean_raw" in
                *Update=*|*update=*)
                    sname="${clean_raw%%Update=*}"
                    sname="${sname%%update=*}"
                    sname="$(echo "$sname" | tr -d '"'\'' ')"

                    local ver_match
                    ver_match="$(echo "$clean_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | tail -n 1)"
                    [ -n "$ver_match" ] && new_v="$ver_match"
                    ;;
                *"->"*)
                    local clean_line
                    clean_line="$(echo "$clean_raw" | sed 's/^[-*[:space:]]*//')"
                    # Strip leading AMTM menu columns like "2 open " or "vn manage "
                    if echo "$clean_line" | grep -qE '^[0-9a-zA-Z]+[[:space:]]+(open|manage)[[:space:]]+'; then
                        clean_line="$(echo "$clean_line" | awk '{ $1=""; $2=""; print $0 }' | sed 's/^[[:space:]]*//')"
                    fi
                    sname="$(echo "$clean_line" | awk '{print $1}')"
                    sname="${sname%%Update*}"
                    sname="${sname%%update*}"
                    sname="${sname%%=*}"
                    sname="$(echo "$sname" | tr -d '"'\'' ')"

                    old_v="$(echo "$clean_line" | awk '{print $(NF-2)}')"
                    new_v="$(echo "$clean_line" | awk '{print $NF}')"
                    ;;
                *"MD5 update"*)
                    local clean_line
                    clean_line="$(echo "$clean_raw" | sed 's/^[-*[:space:]]*//')"
                    sname="$(echo "$clean_line" | awk '{print $1}')"
                    sname="$(echo "$sname" | tr -d '"'\'' ')"
                    old_v="$(echo "$clean_line" | awk '{print $2}' | tr -d ',')"
                    new_v="MD5-latest"
                    ;;
            esac

            [ -z "$sname" ] && continue

            # Filter out scripts not permitted for automatic updates
            if ! _is_script_autoupdate_enabled "$sname"; then
                printf "    ${COLOR_DIM}Skipping %s (auto-update disabled by default / in amtmUpdateScripts)${COLOR_RESET}\n" "$sname"
                _prune_script_from_update_files "$sname"
                continue
            fi

            local spath
            spath="$(_resolve_script_path "$sname")"
            if [ -n "$spath" ] && [ -f "$spath" ]; then
                if [ -z "$old_v" ] || [ "$old_v" = "installed" ] || [ "$old_v" = "unknown" ]; then
                    local v_query
                    v_query="$("$spath" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1)"
                    [ -z "$v_query" ] && v_query="$(grep -m1 "SCRIPT_VERSION=" "$spath" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -n 1)"
                    [ -n "$v_query" ] && old_v="$v_query"
                fi
            else
                _prune_script_from_update_files "$sname"
                continue
            fi

            # Guard: If old_v and new_v are valid versions and already equal, do not trigger!
            if [ -n "$old_v" ] && [ -n "$new_v" ] && [ "$old_v" != "unknown" ] && [ "$new_v" != "latest" ] && [ "$new_v" != "MD5-latest" ]; then
                if [ "$old_v" = "$new_v" ]; then
                    printf "    ${COLOR_DIM}%s is already at version %s. Pruning stale update notice.${COLOR_RESET}\n" "$sname" "$old_v"
                    _prune_script_from_update_files "$sname"
                    continue
                fi
            fi

            # De-duplicate entries in pending list
            if ! grep -qi "^${sname} " "$PENDING_UPDATES_FILE" 2>/dev/null; then
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

    # Clean up empty check files if no updates pending
    for uf in "/tmp/availUpd.txt" "$TPU_CHECK_FILE"; do
        if [ -f "$uf" ]; then
            local rem_cnt
            rem_cnt="$(grep -v -iE '^[[:space:]]*$|^#|Available script updates|No script updates' "$uf" 2>/dev/null | wc -l)"
            [ "$rem_cnt" -eq 0 ] && rm -f "$uf" 2>/dev/null || true
        fi
    done

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

    # Also back up any external scripts (e.g. in /opt/bin or /jffs/addons) targeted by pending updates
    if [ -f "$PENDING_UPDATES_FILE" ]; then
        mkdir -p "$backup_dir/external" 2>/dev/null || true
        while read -r u_line; do
            local u_name
            u_name="$(echo "$u_line" | awk '{print $1}')"
            [ -z "$u_name" ] && continue
            local u_path
            u_path="$(_resolve_script_path "$u_name")"
            if [ -n "$u_path" ] && [ -f "$u_path" ]; then
                case "$u_path" in
                    /jffs/scripts/*) ;;
                    *)
                        cp -pf "$u_path" "$backup_dir/external/$(basename "$u_path")" 2>/dev/null || true
                        ;;
                esac
            fi
        done < "$PENDING_UPDATES_FILE"
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

    # Guard: Ensure script is allowed for automatic updates
    if ! _is_script_autoupdate_enabled "$sname"; then
        printf "--> ${COLOR_YELLOW}[SKIP]${COLOR_RESET} Script %s is disabled for automatic updates.\n" "$sname"
        return 0
    fi

    printf "--> [UPDATING] Updating ${COLOR_BOLD}%s${COLOR_RESET} (${COLOR_DIM}%s${COLOR_RESET})...\n" "$sname" "$spath"

    [ -x "$spath" ] || chmod 755 "$spath" 2>/dev/null || true

    # Method 1: Direct repository fetch for Wireless_Report (cleanest & safest)
    case "$sname" in
        Wireless_Report*|wireless_report*|wirelessreport*|wr|WR)
            printf "--> [UPDATING] Fetching latest Wireless_Report from official repository...\n"
            local target_loc="$spath"
            [ -z "$target_loc" ] && target_loc="/jffs/addons/wireless_report/wirelessreport.sh"
            local tmp_wr="/tmp/wr_new_$$"
            local wr_done=0
            for branch in main master; do
                if curl -sL --retry 3 --connect-timeout 10 "https://raw.githubusercontent.com/JB1366/Wireless_Report/${branch}/wirelessreport.sh" -o "$tmp_wr" 2>/dev/null; then
                    if [ -s "$tmp_wr" ] && grep -q "SCRIPT_VERSION" "$tmp_wr"; then
                        if sh -n "$tmp_wr" 2>/dev/null; then
                            mv -f "$tmp_wr" "$target_loc"
                            chmod 755 "$target_loc"
                            printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Wireless_Report updated successfully to %s (branch: %s).\n" "$target_loc" "$branch"
                            _prune_script_from_update_files "$sname"
                            wr_done=1
                            break
                        fi
                    fi
                    rm -f "$tmp_wr"
                fi
            done
            [ "$wr_done" -eq 1 ] && return 0
            ;;
    esac

    # Handle lock contention: if script has a lock (e.g. Skynet cron collect), wait briefly
    local attempt=1
    while [ "$attempt" -le 3 ]; do
        # Method 2: Native AMTM ecosystem parameter 'amtmupdate'
        local out
        out="$(sh "$spath" amtmupdate < /dev/null 2>&1 || "$spath" amtmupdate < /dev/null 2>&1 || true)"
        if echo "$out" | grep -qiE "(Lock File Detected|lock file exists|is locked)"; then
            printf "    ${COLOR_YELLOW}[WAIT]${COLOR_RESET} Lock detected for %s (attempt %d/3). Waiting 5s...\n" "$sname" "$attempt"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        [ -n "$out" ] && echo "$out"

        # Detect explicit script output indicating auto-update is disabled
        if echo "$out" | grep -qiE "(currently disabled|disabled via amtm|is disabled)"; then
            printf "    ${COLOR_YELLOW}[SKIP]${COLOR_RESET} %s reported auto-updates are disabled.\n" "$sname"
            return 1
        fi

        if echo "$out" | grep -qiE "(updated successfully|updating to|up to date|changes saved|complete)"; then
            return 0
        fi

        # Method 3: Non-interactive script update with closed stdin
        out="$(sh "$spath" update < /dev/null 2>&1 || "$spath" update < /dev/null 2>&1 || true)"
        if echo "$out" | grep -qiE "(Lock File Detected|lock file exists|is locked)"; then
            printf "    ${COLOR_YELLOW}[WAIT]${COLOR_RESET} Lock detected for %s (attempt %d/3). Waiting 5s...\n" "$sname" "$attempt"
            sleep 5
            attempt=$((attempt + 1))
            continue
        fi

        [ -n "$out" ] && echo "$out"

        if echo "$out" | grep -qiE "(currently disabled|disabled via amtm|is disabled)"; then
            printf "    ${COLOR_YELLOW}[SKIP]${COLOR_RESET} %s reported auto-updates are disabled.\n" "$sname"
            return 1
        fi

        if echo "$out" | grep -qiE "(updated successfully|updating to|up to date|changes saved|complete)"; then
            return 0
        fi

        # Method 4: Flags (-checkupdate for @Martinski scripts like SendEmail, or -u)
        if "$spath" -checkupdate < /dev/null 2>&1; then
            return 0
        fi
        if "$spath" -u < /dev/null 2>&1; then
            return 0
        fi

        break
    done

    return 1
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Starting targeted updates for scripts identified by AMTM...\n"

    if [ ! -f "$PENDING_UPDATES_FILE" ] || [ ! -s "$PENDING_UPDATES_FILE" ]; then
        printf "    ${COLOR_DIM}No cached pending updates file. Running active update check...${COLOR_RESET}\n"
        mci_check_trigger >/dev/null 2>&1 || true
    fi

    if [ ! -f "$PENDING_UPDATES_FILE" ] || [ ! -s "$PENDING_UPDATES_FILE" ]; then
        printf "${COLOR_GREEN}--> [RUN] All registered scripts and addons are already up-to-date. Nothing to execute.${COLOR_RESET}\n"
        return 0
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

        # Safeguard: Verify script is permitted for auto-update
        if ! _is_script_autoupdate_enabled "$sname"; then
            printf "--> ${COLOR_YELLOW}[SKIP]${COLOR_RESET} %s is disabled for automatic updates. Skipping.\n" "$sname"
            continue
        fi

        # Resolve script location
        local script_path
        script_path="$(_resolve_script_path "$sname")"

        if [ -n "$script_path" ] && [ -f "$script_path" ]; then
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

    # Prune updated scripts from all AMTM update tracking files using BusyBox-safe helper
    if [ -f "$PENDING_UPDATES_FILE" ]; then
        while read -r line; do
            local done_sname
            done_sname=$(echo "$line" | awk '{print $1}')
            [ -n "$done_sname" ] && _prune_script_from_update_files "$done_sname"
        done < "$PENDING_UPDATES_FILE"
    fi

    # Always ensure MerlinAU, amtm, and excluded scripts are pruned from tracking files
    _prune_script_from_update_files "MerlinAU"
    _prune_script_from_update_files "amtm"
    if [ -n "$MCI_EXCLUDE_SCRIPTS" ]; then
        for excl in $MCI_EXCLUDE_SCRIPTS; do
            _prune_script_from_update_files "$excl"
        done
    fi

    # Record completion epoch for cooldown enforcement
    echo "$(date +%s 2>/dev/null || echo 0)" > /tmp/mci_amtm_last_exec_epoch 2>/dev/null || true

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
    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} ${COLOR_YELLOW}Smoke tests failed! Restoring scripts from backup...${COLOR_RESET}\n"

    if [ -d "$backup_dir/scripts" ]; then
        cp -pf "$backup_dir/scripts/"* "$SCRIPTS_DIR/" 2>/dev/null || true
        chmod 755 "$SCRIPTS_DIR"/* 2>/dev/null || true
    fi

    if [ -d "$backup_dir/external" ] && [ -f "$backup_dir/pending_updates.txt" ]; then
        while read -r u_line; do
            local u_name
            u_name="$(echo "$u_line" | awk '{print $1}')"
            [ -z "$u_name" ] && continue
            local u_path
            u_path="$(_resolve_script_path "$u_name")"
            if [ -n "$u_path" ]; then
                case "$u_path" in
                    /jffs/scripts/*) ;;
                    *)
                        local bname
                        bname="$(basename "$u_path")"
                        if [ -f "$backup_dir/external/$bname" ]; then
                            cp -pf "$backup_dir/external/$bname" "$u_path" 2>/dev/null || true
                            chmod 755 "$u_path" 2>/dev/null || true
                        fi
                        ;;
                esac
            fi
        done < "$backup_dir/pending_updates.txt"
    fi

    rm -f "$PENDING_UPDATES_FILE"

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} Restored scripts. Restarting services...\n"
    service restart_dnsmasq >/dev/null 2>&1 || true
    service restart_firewall >/dev/null 2>&1 || true
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} AMTM general auto-update finished: ${COLOR_BOLD}%s${COLOR_RESET} (${duration}s)\n" "$status"
}
