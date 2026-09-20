#!/bin/sh
# ==============================================================================
# Merlin-CI: Disaster Recovery Vault (NVRAM & /jffs/ Automated Snapshot)
# ==============================================================================
# Creates automated disaster recovery backups of the router's entire configuration:
# 1. Full NVRAM export (WiFi, static DHCP, VPNs, port forwards)
# 2. Complete /jffs/ filesystem tarball (custom scripts, configs, AMTM addons)
# 3. Static DHCP and DNS hosts mapping
# 4. Rotation keeping the last 4 weekly snapshots on USB storage
# 5. Archive integrity CI verification with 'tar -tzf'
# ==============================================================================

JOB_NAME="nvram-jffs-vault"
JOB_DESCRIPTION="Disaster recovery vault: automated weekly snapshot of NVRAM and /jffs/ to USB"
JOB_ENABLED=1
JOB_TYPE="daily"

# Storage location strictly on USB (NAND wear protection)
VAULT_DIR="${MCI_BACKUP_DIR:-/opt/var/merlin-ci/backups}/nvram-jffs-vault"
BACKUP_INTERVAL_SEC=604800 # 7 days (in seconds)
MAX_SNAPSHOTS=4

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[VAULT]${COLOR_RESET} Checking disaster recovery backup schedule...\n"

    mkdir -p "$VAULT_DIR" 2>/dev/null || true
    local last_ts_file="${VAULT_DIR}/.last_vault_timestamp"
    [ ! -f "$last_ts_file" ] && [ -f "${VAULT_DIR}/last_vault_timestamp" ] && last_ts_file="${VAULT_DIR}/last_vault_timestamp"

    if [ ! -f "$last_ts_file" ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}No previous disaster recovery backup found. Initial backup required!${COLOR_RESET}\n"
        return 0
    fi

    local last_ts now_ts elapsed
    last_ts="$(cat "$last_ts_file" 2>/dev/null || echo 0)"
    now_ts="$(date +%s 2>/dev/null || echo 0)"
    elapsed=$((now_ts - last_ts))

    if [ "$elapsed" -ge "$BACKUP_INTERVAL_SEC" ]; then
        local elapsed_days=$((elapsed / 86400))
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_YELLOW}Last disaster backup was %d day(s) ago (Threshold: 7 days).${COLOR_RESET}\n" "$elapsed_days"
        return 0
    fi

    local remaining_days=$(((BACKUP_INTERVAL_SEC - elapsed) / 86400))
    printf "${COLOR_GREEN}--> [VAULT]${COLOR_RESET} Recent backup is current (Next scheduled backup in ~${COLOR_GREEN}%d${COLOR_RESET} days). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$remaining_days"
    return 1
}

mci_backup() {
    # Vault itself creates backups; previous snapshots are preserved in VAULT_DIR
    echo "--> [BACKUP] Preparing disaster recovery snapshot directories in $VAULT_DIR..."
    return 0
}

mci_run() {
    local now_str
    now_str="$(date '+%Y%m%d_%H%M%S' 2>/dev/null || date +%s)"
    local snapshot_dir="${VAULT_DIR}/${now_str}"
    mkdir -p "$snapshot_dir" 2>/dev/null || true
    echo "$snapshot_dir" > /tmp/mci_current_vault_dir 2>/dev/null || true

    echo "--> [RUN] Creating disaster recovery snapshot in $snapshot_dir..."

    # Step 1: Dump NVRAM configuration
    echo "--> [VAULT] Exporting sorted NVRAM configuration..."
    if command -v nvram >/dev/null 2>&1; then
        nvram show 2>/dev/null | sort > "${snapshot_dir}/nvram_full.cfg"
        echo "   [OK] Exported $(wc -l < "${snapshot_dir}/nvram_full.cfg" 2>/dev/null || echo 0) NVRAM parameters."
    fi

    # Step 2: Export static DHCP and DNS reservations
    echo "--> [VAULT] Saving static DHCP leases and hosts..."
    if [ -f /etc/hosts.dnsmasq ]; then
        cp -pf /etc/hosts.dnsmasq "${snapshot_dir}/" 2>/dev/null || true
    fi
    if [ -f /jffs/configs/dnsmasq.conf.add ]; then
        cp -pf /jffs/configs/dnsmasq.conf.add "${snapshot_dir}/" 2>/dev/null || true
    fi

    # Step 3: Archive /jffs/ directory
    echo "--> [VAULT] Compressing /jffs/ into tarball archive..."
    if [ -d /jffs ]; then
        # Exclude temporary socket files, logs, or vault directory to prevent infinite nesting
        tar -czf "${snapshot_dir}/jffs_backup.tar.gz" \
            --exclude="*.sock" \
            --exclude="*.pid" \
            -C / jffs 2>/dev/null || true
        echo "   [OK] /jffs/ compressed archive created."
    fi

    # Step 4: Prune old snapshots (keep MAX_SNAPSHOTS)
    echo "--> [VAULT] Rotating old snapshots (Retention: $MAX_SNAPSHOTS snapshots)..."
    local count
    count="$(find "$VAULT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    if [ "$count" -gt "$MAX_SNAPSHOTS" ]; then
        local to_remove=$((count - MAX_SNAPSHOTS))
        find "$VAULT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n "$to_remove" | xargs rm -rf 2>/dev/null || true
        echo "   [OK] Pruned $to_remove older backup snapshot(s)."
    fi

    # Step 5: Record completion timestamp in hidden file
    date +%s > "${VAULT_DIR}/.last_vault_timestamp" 2>/dev/null || true
    rm -f "${VAULT_DIR}/last_vault_timestamp" 2>/dev/null || true

    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running CI integrity tests on created disaster archive..."

    local target_dir
    if [ -f /tmp/mci_current_vault_dir ]; then
        target_dir="$(cat /tmp/mci_current_vault_dir 2>/dev/null)"
    fi
    if [ -z "$target_dir" ] || [ ! -d "$target_dir" ]; then
        target_dir="$(find "$VAULT_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
    fi

    if [ -z "$target_dir" ] || [ ! -d "$target_dir" ]; then
        echo "--> [FAIL] Snapshot directory not found in $VAULT_DIR!"
        return 1
    fi

    # Check 1: NVRAM file exists and has content
    local nvram_cfg="${target_dir}/nvram_full.cfg"
    if [ ! -s "$nvram_cfg" ]; then
        echo "--> [FAIL] NVRAM export file is missing or empty at $nvram_cfg!"
        return 1
    fi
    echo "   [PASS] NVRAM export file verified ($(ls -lh "$nvram_cfg" 2>/dev/null | awk '{print $5}'))."

    # Check 2: /jffs/ tarball integrity
    local jffs_tar="${target_dir}/jffs_backup.tar.gz"
    if [ -f "$jffs_tar" ]; then
        if ! tar -tzf "$jffs_tar" >/dev/null 2>&1; then
            echo "--> [FAIL] /jffs/ tarball failed gzip/tar integrity test!"
            return 1
        fi
        echo "   [PASS] /jffs/ tarball passed archive integrity test ($(ls -lh "$jffs_tar" 2>/dev/null | awk '{print $5}'))."
    fi

    # Clean up state file on verification pass
    rm -f /tmp/mci_current_vault_dir 2>/dev/null || true

    echo "--> [VERIFY] Disaster recovery snapshot verified successfully!"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Disaster recovery verification failed. Pruning incomplete snapshot..."
    local target_dir
    if [ -f /tmp/mci_current_vault_dir ]; then
        target_dir="$(cat /tmp/mci_current_vault_dir 2>/dev/null)"
        rm -f /tmp/mci_current_vault_dir 2>/dev/null || true
    fi
    [ -n "$target_dir" ] && [ -d "$target_dir" ] && rm -rf "$target_dir" 2>/dev/null || true
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] Disaster recovery vault completed: $status (${duration}s)"
}
