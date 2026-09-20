#!/bin/sh
# ==============================================================================
# Merlin-CI: Installer & Setup Script for Asuswrt-Merlin
# ==============================================================================

set -e

COLOR_CYAN="\033[36m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_RED="\033[31m"
COLOR_RESET="\033[0m"

echo "${COLOR_CYAN}================================================================================${COLOR_RESET}"
echo "${COLOR_CYAN}    Merlin-CI: Router Addon Automation & CI Installer for Asuswrt-Merlin${COLOR_RESET}"
echo "${COLOR_CYAN}    Developed by The Void${COLOR_RESET}"
echo "${COLOR_CYAN}================================================================================${COLOR_RESET}"

# 1. Environment Check
echo "--> Step 1: Checking router environment..."

if [ ! -d "/jffs" ]; then
    echo "${COLOR_RED}[ERROR] /jffs directory not found! Is this an Asuswrt-Merlin router?${COLOR_RESET}"
    exit 1
fi

if command -v nvram >/dev/null 2>&1; then
    JFFS_ENABLED="$(nvram get jffs2_scripts 2>/dev/null || echo "0")"
    if [ "$JFFS_ENABLED" != "1" ]; then
        echo "${COLOR_YELLOW}[WARNING] JFFS custom scripts are not enabled in NVRAM.${COLOR_RESET}"
        echo "--> Enabling 'jffs2_scripts' via nvram..."
        nvram set jffs2_scripts=1
        nvram commit
        echo "${COLOR_GREEN}[OK] Enabled JFFS custom scripts.${COLOR_RESET}"
    fi
fi

# 2. Entware Verification
echo "--> Step 2: Checking Entware package manager..."
if [ ! -f "/opt/bin/opkg" ]; then
    echo "${COLOR_YELLOW}[WARNING] Entware not detected at /opt/bin/opkg.${COLOR_RESET}"
    echo "Merlin-CI stores logs and backups on USB storage to prevent NAND flash wear."
    echo "You can install Entware anytime using AMTM ('amtm' -> 'ep')."
else
    echo "${COLOR_GREEN}[OK] Entware detected.${COLOR_RESET}"
fi

# 3. File Installation
INSTALL_DIR="/jffs/addons/merlin-ci"
echo "--> Step 3: Installing files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/templates" "$INSTALL_DIR/jobs"

SCRIPT_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
cp -rf "$SCRIPT_SRC_DIR/merlin-ci.sh" "$INSTALL_DIR/"
cp -rf "$SCRIPT_SRC_DIR/lib/"* "$INSTALL_DIR/lib/"
cp -rf "$SCRIPT_SRC_DIR/templates/"* "$INSTALL_DIR/templates/"

# Copy jobs without overwriting existing customized jobs
for job in "$SCRIPT_SRC_DIR/jobs/"*.job.sh; do
    if [ -f "$job" ]; then
        dest="$INSTALL_DIR/jobs/$(basename "$job")"
        if [ ! -f "$dest" ]; then
            cp -f "$job" "$dest"
        fi
    fi
done

chmod -R 755 "$INSTALL_DIR"

# 4. Command Symlinks
echo "--> Step 4: Creating command symlinks..."
mkdir -p /jffs/scripts /opt/bin 2>/dev/null || true

ln -sf "$INSTALL_DIR/merlin-ci.sh" /jffs/scripts/mci
ln -sf "$INSTALL_DIR/merlin-ci.sh" /jffs/scripts/merlin-ci
[ -d "/opt/bin" ] && ln -sf "$INSTALL_DIR/merlin-ci.sh" /opt/bin/mci

# 5. Automated Schedule in 'cru'
echo "--> Step 5: Setting up automated trigger evaluation in Asuswrt-Merlin 'cru'..."
if command -v cru >/dev/null 2>&1; then
    cru a MerlinCI "0 4 * * * /jffs/scripts/mci check >/dev/null 2>&1"
    echo "${COLOR_GREEN}[OK] Registered daily trigger evaluation at 4:00 AM in cru.${COLOR_RESET}"
fi

# 6. Persistence across reboots in /jffs/scripts/services-start
SERVICES_START="/jffs/scripts/services-start"
if [ ! -f "$SERVICES_START" ]; then
    cat << 'EOF' > "$SERVICES_START"
#!/bin/sh
EOF
    chmod 755 "$SERVICES_START"
fi

if ! grep -q "MerlinCI" "$SERVICES_START"; then
    cat << 'EOF' >> "$SERVICES_START"

# Merlin-CI: Ensure cru cron job is registered on boot
if command -v cru >/dev/null 2>&1 && [ -x /jffs/scripts/mci ]; then
    cru a MerlinCI "0 4 * * * /jffs/scripts/mci check >/dev/null 2>&1"
fi
EOF
    echo "${COLOR_GREEN}[OK] Added boot persistence to $SERVICES_START${COLOR_RESET}"
fi

echo ""
echo "${COLOR_GREEN}================================================================================${COLOR_RESET}"
echo "${COLOR_GREEN}           Merlin-CI Installation Complete!${COLOR_RESET}"
echo "${COLOR_GREEN}================================================================================${COLOR_RESET}"
echo "Pre-built jobs installed in $INSTALL_DIR/jobs/:"
echo "  - amtm-general-autoupdate.job.sh (Master updates for Skynet, Diversion & all AMTM scripts)"
echo "  - entware-autoupdate.job.sh"
echo "  - wan-gateway-watchdog.job.sh"
echo "  - dns-unresponsive-heal.job.sh"
echo "  - usb-storage-fsck-watchdog.job.sh"
echo "  - usb-swap-repair.job.sh"
echo "  - nvram-jffs-vault.job.sh"
echo "  - firewall-leak-audit.job.sh"
echo "  - letsencrypt-cert-watchdog.job.sh"
echo "  - ssh-auth-watchdog.job.sh"
echo "  - cpu-thermal-heal.job.sh"
echo "  - ram-oom-heal.job.sh"
echo "  - iot-anomaly-contain.job.sh"
echo ""
echo "Run Merlin-CI by typing:"
echo "    ${COLOR_CYAN}mci${COLOR_RESET}         (interactive AMTM menu)"
echo "    ${COLOR_CYAN}mci check${COLOR_RESET}   (scan all triggers and update if new release detected)"
echo "    ${COLOR_CYAN}mci list${COLOR_RESET}    (show all configured automation jobs)"
echo "    ${COLOR_CYAN}mci help${COLOR_RESET}    (show all CLI options)"
echo ""
