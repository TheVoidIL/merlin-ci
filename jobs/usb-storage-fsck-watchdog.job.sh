#!/bin/sh
# ==============================================================================
# Merlin-CI: USB Storage Health & Read-Only Self-Healing Watchdog
# ==============================================================================
# Detects when external USB storage partitions have flipped to Read-Only (ro)
# due to journal errors, power blips, or unclean disconnects.
# Performs progressive recovery:
# 1. Soft remount (mount -o remount,rw)
# 2. Storage filesystem check and repair (fsck / e2fsck)
# 3. Post-heal CI write verification
# ==============================================================================

JOB_NAME="usb-storage-fsck-watchdog"
JOB_DESCRIPTION="Storage watchdog: detects Read-Only USB mounts and restores Read-Write state"
JOB_ENABLED=1
JOB_TYPE="watchdog"

# Scan all USB mount points under /tmp/mnt/
_find_usb_mounts() {
    awk '$2 ~ /^\/tmp\/mnt\// {print $2}' /proc/mounts 2>/dev/null
}

_is_partition_ro() {
    local mnt="$1"
    [ -d "$mnt" ] || return 1

    # Check /proc/mounts options
    if awk -v m="$mnt" '$2 == m && $4 ~ /(^|,)ro(,|$)/ {exit 0} END {exit 1}' /proc/mounts 2>/dev/null; then
        return 0
    fi

    # Test actual write permissions with canary file
    local test_canary="${mnt}/.mci_ro_check_$$"
    if ! touch "$test_canary" 2>/dev/null; then
        return 0
    fi
    rm -f "$test_canary" 2>/dev/null || true

    return 1
}

[ -z "$COLOR_RESET" ] && {
    ESC="$(printf '\033')"
    COLOR_RESET="${ESC}[0m" COLOR_BOLD="${ESC}[1m" COLOR_DIM="${ESC}[2m"
    COLOR_RED="${ESC}[31m" COLOR_GREEN="${ESC}[32m" COLOR_YELLOW="${ESC}[33m"
    COLOR_BLUE="${ESC}[34m" COLOR_MAGENTA="${ESC}[35m" COLOR_CYAN="${ESC}[36m"
}

mci_check_trigger() {
    printf "--> ${COLOR_CYAN}[STORAGE-WATCHDOG]${COLOR_RESET} Checking USB storage write status on /tmp/mnt/...\n"

    local mounts
    mounts="$(_find_usb_mounts)"

    if [ -z "$mounts" ]; then
        printf "--> ${COLOR_YELLOW}[STORAGE-WATCHDOG]${COLOR_RESET} No USB mounts detected under /tmp/mnt/. ${COLOR_DIM}Skipping.${COLOR_RESET}\n"
        return 1
    fi

    local ro_detected=0
    for m in $mounts; do
        if _is_partition_ro "$m"; then
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}USB partition %s is locked in Read-Only mode!${COLOR_RESET}\n" "$m"
            TARGET_RO_MOUNT="$m"
            ro_detected=1
            break
        fi
    done

    if [ "$ro_detected" -eq 1 ]; then
        return 0
    fi

    # Also check dmesg for recent ext4 I/O or Remounting read-only errors
    if dmesg | tail -n 40 | grep -qiE "Remounting filesystem read-only|EXT4-fs error"; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Recent ext4 filesystem errors detected in dmesg!${COLOR_RESET}\n"
        return 0
    fi

    printf "${COLOR_GREEN}--> [STORAGE-WATCHDOG]${COLOR_RESET} All attached USB storage mounts are Read-Write. ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Saving storage mount diagnostics to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    cat /proc/mounts > "$backup_dir/mounts_before.txt" 2>/dev/null || true
    dmesg | tail -n 50 > "$backup_dir/dmesg_tail.txt" 2>/dev/null || true

    echo "   [OK] Diagnostic snapshot recorded."
    return 0
}

mci_run() {
    echo "--> [RUN] Starting storage self-healing pipeline..."

    local target_mnt="${TARGET_RO_MOUNT}"
    if [ -z "$target_mnt" ]; then
        for m in $(_find_usb_mounts); do
            if _is_partition_ro "$m"; then
                target_mnt="$m"
                break
            fi
        done
    fi

    if [ -z "$target_mnt" ]; then
        echo "--> [RUN] No specific read-only mount identified. Checking all mounts..."
        return 0
    fi

    echo "--> [RUN] Target read-only partition: $target_mnt"

    # Step 1: Attempt soft remount rw
    echo "--> [HEAL: STEP 1] Attempting mount -o remount,rw $target_mnt..."
    mount -o remount,rw "$target_mnt" 2>/dev/null || true
    sleep 2

    if ! _is_partition_ro "$target_mnt"; then
        echo "   [OK] Partition successfully remounted Read-Write!"
        return 0
    fi

    # Step 2: Progressive recovery with filesystem check if remount failed
    local dev
    dev="$(awk -v m="$target_mnt" '$2 == m {print $1; exit}' /proc/mounts 2>/dev/null)"

    if [ -n "$dev" ] && [ -b "$dev" ]; then
        echo "--> [HEAL: STEP 2] Remount failed. Running filesystem check on $dev..."
        
        # Stop background disk writing services safely
        swapoff -a 2>/dev/null || true

        if command -v fsck.ext4 >/dev/null 2>&1; then
            fsck.ext4 -pv "$dev" 2>&1 || true
        elif command -v e2fsck >/dev/null 2>&1; then
            e2fsck -pv "$dev" 2>&1 || true
        fi

        # Remount rw
        mount -o remount,rw "$target_mnt" 2>/dev/null || true
    fi

    return 0
}

mci_verify() {
    echo "--> [VERIFY] Testing post-recovery write permissions..."

    local still_ro=0
    for m in $(_find_usb_mounts); do
        if _is_partition_ro "$m"; then
            echo "--> [FAIL] Partition $m is still locked in Read-Only mode!"
            still_ro=1
        else
            echo "   [PASS] Partition $m is Read-Write operational."
        fi
    done

    if [ "$still_ro" -eq 1 ]; then
        return 1
    fi

    echo "--> [VERIFY] USB storage successfully healed and operational!"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Storage self-healing failed. Recording dmesg for manual inspection..."
    dmesg | tail -n 40 > "$backup_dir/dmesg_rollback.txt" 2>/dev/null || true
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    echo "--> [NOTIFY] USB storage watchdog finished: $status (${duration}s)"
}
