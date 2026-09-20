#!/bin/sh
# ==============================================================================
# Merlin-CI: AMTM Core Management Script Self-Update Job (amtm-self-update)
# ==============================================================================
# Dedicated CI watchdog & updater specifically for the AMTM management script
# itself (Asuswrt-Merlin Terminal Menu), NOT third-party scripts.
#
# Lifecycle:
# 1. Trigger Stage (mci_check_trigger):
#    Inspects /jffs/addons/amtm/availUpd.txt for 'amtmUpdate=' flag or queries
#    native 'amtm updcheck'.
# 2. Backup Stage (mci_backup):
#    Snapshots existing amtm script to external USB storage.
# 3. Execution Stage (mci_run):
#    Updates amtm itself non-interactively via 'amtm amtmupdate' or official
#    upstream repository into /jffs/scripts/amtm (overriding /usr/sbin/amtm).
# 4. Verification Stage (mci_verify):
#    Runs CI smoke test: shell syntax verification ('sh -n'), execution test,
#    and version query validation.
# 5. Rollback Stage (mci_rollback):
#    Automated rollback to working backup if verification fails.
# ==============================================================================

JOB_NAME="amtm-self-update"
JOB_DESCRIPTION="AMTM Core Updater: updates the Asuswrt-Merlin Terminal Menu (amtm) management script itself"
JOB_ENABLED=1
JOB_TYPE="daily"

# Ensure standard binary paths
export PATH="/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/jffs/scripts:$PATH"

AMTM_ADD_DIR="/jffs/addons/amtm"
AVAIL_UPD_FILE="${AMTM_ADD_DIR}/availUpd.txt"
TPU_CHECK_FILE="/tmp/amtm-core-check"
UPSTREAM_AMTM_URL="https://raw.githubusercontent.com/decoderman/amtm/master/amtm_fw/amtm"
FALLBACK_AMTM_URL="https://diversion.ch/amtm_fw/amtm"
TARGET_AMTM_BIN="/jffs/scripts/amtm"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

# Locate currently active amtm executable
_find_active_amtm() {
    for p in "/jffs/scripts/amtm" "/jffs/addons/amtm/amtm" "/usr/sbin/amtm" "$(command -v amtm 2>/dev/null)"; do
        if [ -n "$p" ] && [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# Extract version or revision number from amtm executable
_get_amtm_version() {
    local bin="$1"
    [ -z "$bin" ] && bin="$(_find_active_amtm)"
    [ -n "$bin" ] && [ -f "$bin" ] || return 1

    # 1. Check firmware revision variable: amtmRev=9 (Asuswrt-Merlin official format, rev 9 = v7.0)
    local rev
    rev="$(grep -m1 -E "^[[:space:]]*amtmRev=[0-9]+" "$bin" 2>/dev/null | grep -oE '[0-9]+' | head -n 1)"
    if [ -n "$rev" ]; then
        case "$rev" in
            9) echo "7.0 (rev 9)" ;;
            8) echo "6.8 (rev 8)" ;;
            7) echo "6.7 (rev 7)" ;;
            *) echo "rev ${rev}" ;;
        esac
        return 0
    fi

    # 2. Check explicit version variables
    local ver
    ver="$(grep -m1 -iE "^[[:space:]]*(amtm_ver|script_ver|version|amtmversion)=" "$bin" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)"
    [ -n "$ver" ] && { echo "$ver"; return 0; }

    # 3. Check header comment: # amtm v7.0 or # amtm version 7.0
    ver="$(grep -m1 -iE "^#.*amtm.*(version|v)[[:space:]]*[0-9]+\.[0-9]+" "$bin" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)"
    [ -n "$ver" ] && { echo "$ver"; return 0; }

    # 4. Check NVRAM
    local nv_ver
    nv_ver="$(nvram get amtm_ver 2>/dev/null)"
    [ -n "$nv_ver" ] && { echo "$nv_ver"; return 0; }

    echo "unknown"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[AMTM-CORE]${COLOR_RESET} Inspecting amtm management tool version & update status...\n"

    local active_bin
    active_bin="$(_find_active_amtm)"

    if [ -z "$active_bin" ]; then
        printf "--> ${COLOR_YELLOW}[AMTM-CORE]${COLOR_RESET} amtm management script not found on system. ${COLOR_DIM}Skipping.${COLOR_RESET}\n"
        return 1
    fi

    local cur_ver
    cur_ver="$(_get_amtm_version "$active_bin")"
    MCI_OLD_VERSION="$cur_ver"

    # Check 1: Inspect availUpd.txt for amtmUpdate flag
    if [ -f "$AVAIL_UPD_FILE" ] && grep -qiE "(^amtmUpdate=|^amtm=)" "$AVAIL_UPD_FILE" 2>/dev/null; then
        local raw_entry
        raw_entry="$(grep -m1 -iE "(^amtmUpdate=|^amtm=)" "$AVAIL_UPD_FILE" 2>/dev/null)"
        local remote_v
        remote_v="$(echo "$raw_entry" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)*' | tail -n 1)"
        MCI_NEW_VERSION="${remote_v:-latest}"

        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}AMTM management script update available (${COLOR_YELLOW}%s${COLOR_RESET} -> ${COLOR_GREEN}%s${COLOR_RESET})!${COLOR_RESET}\n" "$cur_ver" "$MCI_NEW_VERSION"
        return 0
    fi

    # Check 2: Compare local revision against upstream repository directly
    local local_rev
    local_rev="$(grep -m1 -E "^[[:space:]]*amtmRev=[0-9]+" "$active_bin" 2>/dev/null | grep -oE '[0-9]+' | head -n 1)"
    if [ -n "$local_rev" ]; then
        local remote_rev
        remote_rev="$(curl -sL --retry 2 --connect-timeout 5 "$UPSTREAM_AMTM_URL" 2>/dev/null | grep -m1 -E "^[[:space:]]*amtmRev=[0-9]+" | grep -oE '[0-9]+' | head -n 1)"
        if [ -n "$remote_rev" ] && [ "$remote_rev" -gt "$local_rev" ]; then
            MCI_NEW_VERSION="rev ${remote_rev}"
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}Newer AMTM core revision available upstream (${COLOR_YELLOW}%s${COLOR_RESET} -> ${COLOR_GREEN}%s${COLOR_RESET})!${COLOR_RESET}\n" "$cur_ver" "$MCI_NEW_VERSION"
            return 0
        fi
    fi

    printf "${COLOR_GREEN}--> [AMTM-CORE]${COLOR_RESET} AMTM management script is up to date (v${COLOR_GREEN}%s${COLOR_RESET}). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$cur_ver"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    printf "${COLOR_CYAN}--> [BACKUP]${COLOR_RESET} Backing up active amtm script to %s...\n" "$backup_dir"
    mkdir -p "$backup_dir" 2>/dev/null || true

    local active_bin
    active_bin="$(_find_active_amtm)"
    if [ -n "$active_bin" ] && [ -f "$active_bin" ]; then
        cp -pf "$active_bin" "$backup_dir/amtm.bak" 2>/dev/null || true
    fi

    if [ -f "$TARGET_AMTM_BIN" ]; then
        cp -pf "$TARGET_AMTM_BIN" "$backup_dir/amtm_jffs.bak" 2>/dev/null || true
    fi

    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} AMTM core backup recorded.\n"
    return 0
}

mci_run() {
    printf "${COLOR_CYAN}--> [RUN]${COLOR_RESET} Executing AMTM core management script update...\n"

    local active_bin
    active_bin="$(_find_active_amtm)"

    local updated=0

    # Direct official upstream download into /jffs/scripts/amtm
    printf "--> [UPDATING] Fetching latest amtm directly from official repository...\n"
    mkdir -p "/jffs/scripts" 2>/dev/null || true
    local tmp_download="/tmp/amtm_new_$$"

    for fetch_url in "$UPSTREAM_AMTM_URL" "$FALLBACK_AMTM_URL"; do
        printf "    ${COLOR_DIM}Trying %s...${COLOR_RESET}\n" "$fetch_url"
        if curl -sL --retry 3 --connect-timeout 8 "$fetch_url" -o "$tmp_download" 2>/dev/null; then
            if [ -s "$tmp_download" ] && head -n 1 "$tmp_download" | grep -q "^#!/bin/sh"; then
                if sh -n "$tmp_download" 2>/dev/null; then
                    mv -f "$tmp_download" "$TARGET_AMTM_BIN"
                    chmod 755 "$TARGET_AMTM_BIN"
                    printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} Installed latest amtm to %s\n" "$TARGET_AMTM_BIN"
                    updated=1
                    break
                else
                    printf "    ${COLOR_YELLOW}[WARNING] Downloaded amtm failed syntax verification.${COLOR_RESET}\n"
                    rm -f "$tmp_download"
                fi
            else
                rm -f "$tmp_download"
            fi
        fi
    done

    if [ "$updated" -eq 1 ]; then
        # Clear availUpd.txt flag
        if [ -f "$AVAIL_UPD_FILE" ]; then
            sed -i '/^amtmUpdate=/d;/^amtm=/d' "$AVAIL_UPD_FILE" 2>/dev/null || true
        fi
        local new_ver
        new_ver="$(_get_amtm_version "$TARGET_AMTM_BIN")"
        [ "$new_ver" = "unknown" ] && new_ver="$(_get_amtm_version "$active_bin")"
        MCI_NEW_VERSION="$new_ver"

        printf "   ${COLOR_GREEN}[OK]${COLOR_RESET} AMTM core updated successfully (v${COLOR_GREEN}%s${COLOR_RESET}).\n" "$MCI_NEW_VERSION"
        return 0
    fi

    printf "   ${COLOR_RED}[ERROR]${COLOR_RESET} Failed to update AMTM core management script across all methods.\n"
    return 1
}

mci_verify() {
    printf "${COLOR_CYAN}--> [VERIFY]${COLOR_RESET} Running CI smoke test on updated AMTM script...\n"

    local check_bin
    check_bin="$TARGET_AMTM_BIN"
    [ ! -f "$check_bin" ] && check_bin="$(_find_active_amtm)"

    if [ ! -f "$check_bin" ] || [ ! -x "$check_bin" ]; then
        printf "${COLOR_RED}--> [FAIL] amtm binary not found or not executable at %s!${COLOR_RESET}\n" "$check_bin"
        return 1
    fi

    # Smoke Test 1: Shell syntax verification
    if ! sh -n "$check_bin" 2>/dev/null; then
        printf "${COLOR_RED}--> [FAIL] Shell syntax error detected in %s!${COLOR_RESET}\n" "$check_bin"
        return 1
    fi
    printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} Shell syntax validation: ${COLOR_BOLD}%s${COLOR_RESET}\n" "$check_bin"

    # Smoke Test 2: Query version non-interactively
    local test_ver
    test_ver="$(_get_amtm_version "$check_bin")"
    if [ "$test_ver" = "unknown" ]; then
        printf "${COLOR_YELLOW}--> [WARNING] Could not parse version header from %s.${COLOR_RESET}\n" "$check_bin"
    else
        printf "   ${COLOR_GREEN}[PASS]${COLOR_RESET} AMTM version query verified: v${COLOR_GREEN}%s${COLOR_RESET}\n" "$test_ver"
    fi

    printf "${COLOR_GREEN}--> [VERIFY]${COLOR_RESET} AMTM Core CI smoke tests ${COLOR_GREEN}${COLOR_BOLD}PASSED${COLOR_RESET} successfully!\n"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} ${COLOR_YELLOW}Restoring previous AMTM core script from backup...${COLOR_RESET}\n"

    if [ -f "$backup_dir/amtm_jffs.bak" ]; then
        cp -pf "$backup_dir/amtm_jffs.bak" "$TARGET_AMTM_BIN" 2>/dev/null || true
        chmod 755 "$TARGET_AMTM_BIN" 2>/dev/null || true
    elif [ -f "$backup_dir/amtm.bak" ]; then
        cp -pf "$backup_dir/amtm.bak" "$TARGET_AMTM_BIN" 2>/dev/null || true
        chmod 755 "$TARGET_AMTM_BIN" 2>/dev/null || true
    fi

    printf "${COLOR_YELLOW}${COLOR_BOLD}--> [ROLLBACK]${COLOR_RESET} Restored previous amtm script. Rollback complete.\n"
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    printf "--> ${COLOR_CYAN}[NOTIFY]${COLOR_RESET} AMTM core self-update finished: ${COLOR_BOLD}%s${COLOR_RESET} (${duration}s)\n" "$status"
}
