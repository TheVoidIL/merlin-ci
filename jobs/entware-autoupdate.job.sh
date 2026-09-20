#!/bin/sh
# ==============================================================================
# Merlin-CI: Entware Packages Auto-Update & Validation Job
# ==============================================================================

JOB_NAME="entware-autoupdate"
JOB_DESCRIPTION="Auto-updates Entware packages with service smoke tests"
JOB_ENABLED=1
JOB_TYPE="daily"

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

OPKG_BIN="/opt/bin/opkg"

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[ENTWARE]${COLOR_RESET} Checking for upgradable Entware packages...\n"

    if [ ! -x "$OPKG_BIN" ]; then
        printf "--> ${COLOR_YELLOW}[ENTWARE]${COLOR_RESET} Entware opkg not found at %s. ${COLOR_DIM}Skipping.${COLOR_RESET}\n" "$OPKG_BIN"
        return 1
    fi

    "$OPKG_BIN" update >/dev/null 2>&1 || true
    local upgradable
    upgradable="$("$OPKG_BIN" list-upgradable 2>/dev/null)"

    if [ -n "$upgradable" ]; then
        local count
        count="$(echo "$upgradable" | grep -c . || echo 0)"
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}%d Entware package(s) can be upgraded:${COLOR_RESET}\n" "$count"
        echo "$upgradable" | while read -r line; do
            [ -n "$line" ] && printf "    ${COLOR_CYAN}*${COLOR_RESET} %s\n" "$line"
        done
        return 0
    else
        printf "${COLOR_GREEN}--> [ENTWARE]${COLOR_RESET} All packages are up to date. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
        return 1
    fi
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Backing up Entware configuration files (/opt/etc/)..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    # Save list of currently installed packages
    "$OPKG_BIN" list-installed > "$backup_dir/packages_installed.txt" 2>/dev/null || true

    if [ -d "/opt/etc" ]; then
        cp -prf "/opt/etc" "$backup_dir/opt_etc_backup" 2>/dev/null || true
    fi

    return 0
}

mci_run() {
    echo "--> [RUN] Upgrading Entware packages in headless CI mode..."
    local pkgs
    pkgs="$("$OPKG_BIN" list-upgradable 2>/dev/null | awk '{print $1}')"

    if [ -z "$pkgs" ]; then
        echo "--> [RUN] No upgradable packages found."
        return 0
    fi

    for pkg in $pkgs; do
        echo "   Upgrading $pkg (non-interactive)..."
        # --force-maintainer preserves maintainer configs without prompting
        # printf 'y\ny\n' auto-confirms post-install questions (e.g. privoxy filter files)
        if ! printf "y\ny\ny\n" | "$OPKG_BIN" --force-maintainer upgrade "$pkg" 2>&1; then
            echo "--> [ERROR] Failed to upgrade package: $pkg"
            return 1
        fi
    done

    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running Entware smoke tests..."

    # Check 1: Ensure opkg itself still functions
    if ! "$OPKG_BIN" list-installed >/dev/null 2>&1; then
        echo "--> [FAIL] opkg database is corrupt or failing after upgrade!"
        return 1
    fi
    echo "   [PASS] opkg database integrity"

    # Check 2: Verify essential tools exist and execute
    for tool in curl jq git; do
        if [ -x "/opt/bin/$tool" ]; then
            if ! "/opt/bin/$tool" --version >/dev/null 2>&1; then
                echo "--> [FAIL] Essential tool /opt/bin/$tool failed execution!"
                return 1
            fi
        fi
    done
    echo "   [PASS] Entware binaries functional"

    echo "--> [VERIFY] Entware smoke tests PASSED."
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Restoring /opt/etc/ configurations..."

    if [ -d "$backup_dir/opt_etc_backup" ]; then
        cp -prf "$backup_dir/opt_etc_backup/"* "/opt/etc/" 2>/dev/null || true
    fi

    echo "--> [ROLLBACK] Config files restored."
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] Entware update finished: $status (${duration}s)"
}
