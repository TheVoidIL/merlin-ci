#!/bin/sh
# ==============================================================================
# Merlin-CI: USB Swap Health Check & Automated Self-Healing Job
# ==============================================================================
# Detects when USB swap file is disconnected, inactive, or corrupted,
# verifies USB filesystem read-write state, repairs with mkswap if needed,
# and reactivates swapon with post-repair CI verification.
# ==============================================================================

JOB_NAME="usb-swap-repair"
JOB_DESCRIPTION="Self-healing watchdog: detects, repairs, and reactivates USB swap"
JOB_ENABLED=1
JOB_TYPE="watchdog"

## Target mount and partition labels
SWAP_LABEL="tamird_swap"
REAL_MNT="/tmp/mnt/tamird_swap"

# Common locations where AMTM, Diversion, or Skynet place swapfiles on Asuswrt-Merlin
SWAP_LOCATIONS="
/tmp/mnt/tamird_swap/myswap.swp
/tmp/mnt/*/myswap.swp
/tmp/mnt/*/.swap/myswap.swp
/opt/swap.swp
/tmp/mnt/*/*.swp
/tmp/mnt/*/swapfile
/tmp/mnt/*/.swap/swapfile
/opt/swapfile
"

_fix_ghost_mounts() {
    # Check for Asuswrt ghost mounts (e.g., /tmp/mnt/tamird_swap (1))
    local ghost_line
    ghost_line=$(mount | grep "/tmp/mnt/.*(1)")
    if [ -n "$ghost_line" ]; then
        echo "--> [STORAGE] Ghost mount detected: $ghost_line"
        echo "--> [STORAGE] Starting automated storage recovery..."
        swapoff -a 2>/dev/null || true

        while read -r line; do
            [ -z "$line" ] && continue
            local dev mnt real_mnt
            dev=$(echo "$line" | awk '{print $1}')
            mnt=$(echo "$line" | awk '{print $3}')
            real_mnt=$(echo "$mnt" | sed -e 's/ *(1).*//' -e 's/(1).*//')
            [ -z "$real_mnt" ] && real_mnt="$REAL_MNT"

            echo "--> [STORAGE] Remapping device $dev from '$mnt' to '$real_mnt'..."
            umount -l "$mnt" 2>/dev/null || true
            [ -d "$mnt" ] && rmdir "$mnt" 2>/dev/null || true
            [ -d "$real_mnt" ] && rmdir "$real_mnt" 2>/dev/null || true

            mkdir -p "$real_mnt"
            mount "$dev" "$real_mnt" 2>/dev/null || true
        done << EOF
$ghost_line
EOF
        sleep 2
        return 0
    fi
    return 1
}

_recover_unmounted_drive() {
    # If not mounted anywhere, search by partition label using blkid
    local label dev target_mnt
    for label in "$SWAP_LABEL" "tamird_swap" "swap" "myswap"; do
        target_mnt="/tmp/mnt/$label"
        if ! grep -q "$target_mnt" /proc/mounts 2>/dev/null; then
            dev=$(blkid 2>/dev/null | grep -i "LABEL=\"$label\"" | cut -d':' -f1 | head -n 1)
            if [ -n "$dev" ]; then
                echo "--> [STORAGE] Detected unmounted swap partition ($dev, LABEL=$label)."
                echo "--> [STORAGE] Mounting $dev to $target_mnt..."
                mkdir -p "$target_mnt"
                mount "$dev" "$target_mnt" 2>/dev/null || true
                sleep 2
                return 0
            fi
        fi
    done
    return 1
}

_find_configured_swap() {
    # 1. Check if swap file is currently in /proc/swaps
    if [ -f /proc/swaps ]; then
        local active_file
        active_file="$(awk 'NR>1 && $1 ~ /^\// {print $1; exit}' /proc/swaps 2>/dev/null)"
        if [ -n "$active_file" ] && [ -f "$active_file" ]; then
            echo "$active_file"
            return 0
        fi
    fi

    # 2. Check /jffs/scripts/post-mount for configured swapon path (standard AMTM/Merlin setup)
    if [ -f /jffs/scripts/post-mount ]; then
        local post_mount_swap
        post_mount_swap="$(awk '/swapon/ && $2 ~ /^\// {print $2; exit}' /jffs/scripts/post-mount 2>/dev/null)"
        if [ -n "$post_mount_swap" ] && [ -f "$post_mount_swap" ]; then
            echo "$post_mount_swap"
            return 0
        fi
    fi

    # 3. Check common USB mount paths
    for pattern in $SWAP_LOCATIONS; do
        # shellcheck disable=SC2086
        for candidate in $pattern; do
            if [ -f "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        done
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
    printf "--> ${COLOR_CYAN}[SWAP-CHECK]${COLOR_RESET} Inspecting router swap status...\n"

    # 1. Check if swap is currently active in /proc/swaps
    local active_swaps=0
    if [ -f /proc/swaps ]; then
        # Count lines excluding the header
        active_swaps=$(awk 'NR>1 {count++} END {print count+0}' /proc/swaps)
    fi

    # 2. Check total swap in /proc/meminfo
    local swap_total_kb=0
    if [ -f /proc/meminfo ]; then
        swap_total_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    fi

    # If swap is active and Total > 0, swap is healthy!
    if [ "$active_swaps" -gt 0 ] && [ "${swap_total_kb:-0}" -gt 0 ]; then
        printf "${COLOR_GREEN}--> [SWAP-CHECK]${COLOR_RESET} Swap is active (${COLOR_GREEN}%s kB${COLOR_RESET} total). ${COLOR_GREEN}${COLOR_BOLD}[ALL CLEAR]${COLOR_RESET}\n" "$swap_total_kb"
        return 1
    fi

    printf "--> ${COLOR_YELLOW}[SWAP-CHECK]${COLOR_RESET} ${COLOR_YELLOW}WARNING: Swap is currently INACTIVE (SwapTotal: %s kB)!${COLOR_RESET}\n" "${swap_total_kb:-0}"

    # 3. Check if ghost mounts exist (causes swap failure)
    if mount | grep -q "/tmp/mnt/.*(1)"; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Ghost mount detected in /tmp/mnt/. Automated recovery required.${COLOR_RESET}\n"
        return 0
    fi

    # 4. Check if unmounted partition exists by label
    for label in "$SWAP_LABEL" "tamird_swap" "swap"; do
        if blkid 2>/dev/null | grep -qi "LABEL=\"$label\""; then
            printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Detected unmounted swap partition '%s' via blkid.${COLOR_RESET}\n" "$label"
            return 0
        fi
    done

    # 5. Check if a swapfile exists on an attached USB drive
    local found_swap
    found_swap="$(_find_configured_swap)"

    if [ -n "$found_swap" ] && [ -f "$found_swap" ]; then
        printf "${COLOR_YELLOW}${COLOR_BOLD}--> [TRIGGERED]${COLOR_RESET} ${COLOR_RED}${COLOR_BOLD}Found existing USB swap file: %s (Status: Inactive/Degraded)${COLOR_RESET}\n" "$found_swap"
        TARGET_SWAP_FILE="$found_swap"
        return 0
    fi

    printf "--> ${COLOR_CYAN}[SWAP-CHECK]${COLOR_RESET} No existing USB swap file found on /tmp/mnt/. ${COLOR_DIM}Skipping.${COLOR_RESET}\n"
    return 1
}

mci_backup() {
    local backup_dir="$1"
    echo "--> [BACKUP] Recording current swap and mount diagnostics to $backup_dir..."
    mkdir -p "$backup_dir" 2>/dev/null || true

    # Save diagnostic state
    cat /proc/swaps > "$backup_dir/swaps_before.txt" 2>/dev/null || true
    cat /proc/mounts > "$backup_dir/mounts_before.txt" 2>/dev/null || true
    dmesg | tail -n 30 > "$backup_dir/dmesg_tail.txt" 2>/dev/null || true

    echo "   [OK] Diagnostic snapshot recorded (swaps, mounts, dmesg)"
    return 0
}

mci_run() {
    # Step 1: Storage Layer Self-Healing (Ghost Mounts & Unmounted Partitions)
    _fix_ghost_mounts || true
    _recover_unmounted_drive || true

    local swap_file="${TARGET_SWAP_FILE:-$(_find_configured_swap)}"

    if [ -z "$swap_file" ] || [ ! -f "$swap_file" ]; then
        echo "--> [ERROR] Target swap file not found after storage scan!"
        echo "--> Scanned: /proc/swaps, /jffs/scripts/post-mount, blkid, and /tmp/mnt/*"
        return 1
    fi

    echo "--> [RUN] Target swap file: $swap_file"

    local swap_dir
    swap_dir="$(dirname "$swap_file")"

    # Step 2: Check if USB mount is mounted Read-Only (common reason swap fails on Asus routers)
    echo "--> [RUN] Testing USB filesystem write permissions..."
    local rw_test="${swap_dir}/.mci_rw_test_$$"
    if ! touch "$rw_test" 2>/dev/null; then
        echo "--> [WARN] USB storage is Read-Only! Attempting remount rw..."
        local mount_point
        mount_point="$(df "$swap_dir" 2>/dev/null | awk 'NR==2 {print $6}')"
        if [ -n "$mount_point" ]; then
            mount -o remount,rw "$mount_point" 2>/dev/null || true
        fi
        # Re-check
        if ! touch "$rw_test" 2>/dev/null; then
            echo "--> [ERROR] USB drive remains Read-Only! Filesystem check (fsck) may be required."
            return 1
        fi
    fi
    rm -f "$rw_test" 2>/dev/null || true
    echo "   [OK] USB storage is mounted Read-Write."

    # Step 3: Ensure any stale/broken swap association is released
    echo "--> [RUN] Deactivating any stale swap mapping..."
    swapoff "$swap_file" 2>/dev/null || true

    # Step 4: Test swap file header / size (using awk to avoid 32-bit shell integer overflow on 2GB+ swap)
    local swap_size_mb
    swap_size_mb=$(ls -l "$swap_file" 2>/dev/null | awk '{print int($5 / 1048576)}')

    echo "--> [RUN] Validating swap file size (${swap_size_mb:-0} MB)..."

    if [ "${swap_size_mb:-0}" -lt 10 ]; then # Less than 10MB
        echo "--> [ERROR] Swap file is too small or truncated (${swap_size_mb:-0} MB)."
        return 1
    fi

    # Step 5: Verify or re-format swap header with mkswap
    echo "--> [RUN] Verifying / re-initializing swap structure with mkswap..."
    if ! mkswap "$swap_file" 2>&1; then
        echo "--> [ERROR] mkswap failed on $swap_file!"
        return 1
    fi

    # Set secure permissions (rw-------)
    chmod 600 "$swap_file" 2>/dev/null || true

    # Step 6: Activate swap
    echo "--> [RUN] Activating swap: swapon $swap_file..."
    if ! swapon "$swap_file" 2>&1; then
        echo "--> [ERROR] swapon failed for $swap_file!"
        return 1
    fi

    echo "   [OK] Swap activated successfully."
    return 0
}

mci_verify() {
    echo "--> [VERIFY] Running post-repair verification checks..."

    # Check 1: Verify /proc/swaps has active entries
    if ! grep -q -v "^Filename" /proc/swaps 2>/dev/null; then
        echo "--> [FAIL] /proc/swaps has no active swap entry!"
        return 1
    fi
    echo "   [PASS] /proc/swaps contains active swap:"
    if [ -f /proc/swaps ]; then
        awk 'NR>1 {printf "          File: %-25s Size: %s kB | Used: %s kB\n", $1, $3, $4}' /proc/swaps 2>/dev/null || true
    fi

    # Check 2: Verify SwapTotal in /proc/meminfo is greater than 0
    local total_swap
    total_swap=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local free_swap
    free_swap=$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$total_swap" -le 0 ]; then
        echo "--> [FAIL] SwapTotal is 0 kB in /proc/meminfo!"
        return 1
    fi
    echo "   [PASS] Memory swap stats: Total ${total_swap} kB (Free: ${free_swap} kB)"

    echo "--> [VERIFY] USB Swap successfully repaired and operational!"
    return 0
}

mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Swap activation failed. Disabling partial swap to prevent memory freeze..."
    swapoff -a 2>/dev/null || true
    logger -t "Merlin-CI" "CRITICAL: USB Swap repair failed. Swap remains disabled."
    return 0
}

mci_notify() {
    local status="$1"
    local duration="$2"
    if [ "$status" = "SUCCESS" ]; then
        logger -t "Merlin-CI" "SUCCESS: USB Swap was automatically repaired and reactivated."
    fi
    echo "--> [NOTIFY] Swap repair job finished with status: $status (${duration}s)"
}
