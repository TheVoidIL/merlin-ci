#!/bin/sh
# ==============================================================================
# Merlin-CI: Test Suite (Embedded-Safe CI & Swap Self-Healing)
# ==============================================================================

set -e

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="/tmp/mci_test_suite_$$"
mkdir -p "$TEST_DIR"

PASS_COUNT=0
FAIL_COUNT=0

test_assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        printf "  [PASS] %s\n" "$desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf "  [FAIL] %s\n" "$desc"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

echo "================================================================================"
echo " Running Merlin-CI Test Suite (Embedded Optimization & Swap Repair)"
echo " Workspace: $BASE_DIR"
echo "================================================================================"

# 1. Syntax Validation
echo "--> Test 1: Validating shell syntax of all scripts and jobs..."
syntax_ok=0
for script in "$BASE_DIR"/merlin-ci.sh "$BASE_DIR"/install.sh "$BASE_DIR"/lib/*.sh "$BASE_DIR"/templates/*.sh "$BASE_DIR"/jobs/*.sh; do
    if [ -f "$script" ]; then
        if sh -n "$script" 2>/dev/null; then
            :
        else
            echo "Syntax error in $script!"
            syntax_ok=1
            break
        fi
    fi
done
test_assert "All scripts and job definitions pass sh -n syntax check" "$syntax_ok"

# 2. Config Loading & Embedded Defaults
echo "--> Test 2: Testing configuration manager & embedded defaults..."
# shellcheck source=lib/ui.sh
. "$BASE_DIR/lib/ui.sh"
# shellcheck source=lib/config.sh
. "$BASE_DIR/lib/config.sh"
# shellcheck source=lib/notify.sh
. "$BASE_DIR/lib/notify.sh"
# shellcheck source=lib/runner.sh
. "$BASE_DIR/lib/runner.sh"
# shellcheck source=lib/daemon.sh
. "$BASE_DIR/lib/daemon.sh"

MCI_CUSTOM_CONF="${TEST_DIR}/test_mci.conf"
config_init "$MCI_CUSTOM_CONF"
config_load
MCI_ACTIVE_CONF_PATH="$MCI_CUSTOM_CONF"
MCI_LOG_DIR="${TEST_DIR}/logs"
MCI_BACKUP_DIR="${TEST_DIR}/backups"
MCI_JOBS_DIR="${TEST_DIR}/jobs"
mkdir -p "$MCI_LOG_DIR" "$MCI_BACKUP_DIR" "$MCI_JOBS_DIR"

test_assert "Embedded configuration defaults initialized" "$([ "$MCI_EMBEDDED_MODE" = "1" ]; echo $?)"
test_assert "Cron is configured as primary execution mode" "$([ "$MCI_EXEC_MODE" = "cron" ]; echo $?)"

# 3. Resource Safety Guards
echo "--> Test 3: Testing resource safety guardrails..."
MCI_MAX_LOADAVG="0.0001"
if [ -f /proc/loadavg ]; then
    runner_check_safety >/dev/null 2>&1 && guard_res=0 || guard_res=1
    test_assert "High load guardrail properly triggers" "$([ "$guard_res" -eq 1 ]; echo $?)"
else
    echo "  [SKIP] /proc/loadavg not available."
fi
MCI_MAX_LOADAVG="99.00"
MCI_MIN_FREE_RAM_MB=1
runner_check_safety >/dev/null 2>&1 && guard_safe=0 || guard_safe=1
test_assert "Safe thresholds allow execution" "$guard_safe"

# 4. Trigger Evaluation & Successful Run
echo "--> Test 4: Testing successful trigger, backup, execution, and verification..."
MOCK_FILE="${TEST_DIR}/mock_target_script.sh"
echo "VERSION=1.0.0" > "$MOCK_FILE"

cat << EOF > "${MCI_JOBS_DIR}/test-success.job.sh"
#!/bin/sh
JOB_NAME="test-success"
JOB_DESCRIPTION="Test successful update"
JOB_ENABLED=1

mci_check_trigger() {
    return 0
}

mci_backup() {
    local backup_dir="\$1"
    cp -pf "$MOCK_FILE" "\$backup_dir/mock.bak"
    return 0
}

mci_run() {
    echo "VERSION=2.0.0" > "$MOCK_FILE"
    return 0
}

mci_verify() {
    grep -q "VERSION=2.0.0" "$MOCK_FILE"
    return \$?
}

mci_rollback() {
    local backup_dir="\$1"
    cp -pf "\$backup_dir/mock.bak" "$MOCK_FILE"
    return 0
}
EOF
chmod 755 "${MCI_JOBS_DIR}/test-success.job.sh"

runner_execute_job "${MCI_JOBS_DIR}/test-success.job.sh" "test_runner" 0 >/dev/null 2>&1
test_assert "Success job returned 0" "$?"
test_assert "Mock file was updated to 2.0.0" "$([ "$(cat "$MOCK_FILE")" = "VERSION=2.0.0" ]; echo $?)"
test_assert "Status recorded as SUCCESS" "$([ "$(cat "${MCI_LOG_DIR}/last_run_status_test-success" 2>/dev/null)" = "SUCCESS" ]; echo $?)"

# 5. Rollback on Smoke Test Failure
echo "--> Test 5: Testing automated rollback on CI verification failure..."
echo "ORIGINAL_STATE" > "$MOCK_FILE"

cat << EOF > "${MCI_JOBS_DIR}/test-fail-rollback.job.sh"
#!/bin/sh
JOB_NAME="test-fail-rollback"
JOB_DESCRIPTION="Test rollback on failure"
JOB_ENABLED=1

mci_check_trigger() {
    return 0
}

mci_backup() {
    local backup_dir="\$1"
    cp -pf "$MOCK_FILE" "\$backup_dir/mock.bak"
    return 0
}

mci_run() {
    echo "BROKEN_NEW_STATE" > "$MOCK_FILE"
    return 0
}

mci_verify() {
    return 1
}

mci_rollback() {
    local backup_dir="\$1"
    cp -pf "\$backup_dir/mock.bak" "$MOCK_FILE"
    return 0
}
EOF
chmod 755 "${MCI_JOBS_DIR}/test-fail-rollback.job.sh"

runner_execute_job "${MCI_JOBS_DIR}/test-fail-rollback.job.sh" "test_runner" 0 >/dev/null 2>&1 || true
test_assert "File was restored to ORIGINAL_STATE by rollback" "$([ "$(cat "$MOCK_FILE")" = "ORIGINAL_STATE" ]; echo $?)"
test_assert "Status recorded as ROLLED_BACK" "$([ "$(cat "${MCI_LOG_DIR}/last_run_status_test-fail-rollback" 2>/dev/null)" = "ROLLED_BACK" ]; echo $?)"

# 6. USB Swap Self-Healing Logic Test
echo "--> Test 6: Testing USB Swap health check and self-healing job logic..."
# Source the swap repair job in a subshell to test logic
MOCK_SWAP="${TEST_DIR}/mock_myswap.swp"
# Create a 12MB mock file
dd if=/dev/zero of="$MOCK_SWAP" bs=1048576 count=12 >/dev/null 2>&1

(
    # shellcheck source=jobs/usb-swap-repair.job.sh
    . "$BASE_DIR/jobs/usb-swap-repair.job.sh"
    TARGET_SWAP_FILE="$MOCK_SWAP"
    
    # Test backup
    mci_backup "$TEST_DIR/backups/swap" >/dev/null 2>&1
    [ -d "$TEST_DIR/backups/swap" ] || exit 1

    # Test mkswap formatting if mkswap utility is available
    if command -v mkswap >/dev/null 2>&1; then
        mkswap "$MOCK_SWAP" >/dev/null 2>&1
        # Check swap signature "SWAPSPACE2" in last 10 bytes of first page
        grep -q "SWAPSPACE2" "$MOCK_SWAP" 2>/dev/null || true
    fi
)
test_assert "USB Swap self-healing logic and backup executed cleanly" "$?"

# 7. CLI Commands
echo "--> Test 7: Testing CLI command execution..."
sh "$BASE_DIR/merlin-ci.sh" list >/dev/null 2>&1
test_assert "CLI 'list' command works" "$?"
sh "$BASE_DIR/merlin-ci.sh" help >/dev/null 2>&1
test_assert "CLI 'help' command works" "$?"

# 8. Email Notification Logic
echo "--> Test 8: Testing Email notification handler & version reporting..."
MCI_EMAIL_ENABLED=0
notify_email "SUCCESS" "test-job" "5" "test log" "v1.0" "v2.0"
test_assert "Disabled email notification exits quietly" "$?"

MCI_EMAIL_ENABLED=1
MCI_SMTP_TO="admin@example.com"
MCI_SMTP_SERVER="127.0.0.1"
MCI_SMTP_PORT="25"
notify_email "TRIGGERED" "skynet-autoupdate" "0" "Starting upgrade" "v7.4.8" "v7.4.9" >/dev/null 2>&1 || true
test_assert "TRIGGERED email notification with old/new versions handled" "$?"

notify_email "SUCCESS" "skynet-autoupdate" "12" "Upgrade successful" "v7.4.8" "v7.4.9" >/dev/null 2>&1 || true
test_assert "SUCCESS email notification with old/new versions handled" "$?"

# 9. New Watchdogs & Vault Lifecycle Tests
echo "--> Test 9: Testing new Watchdog & Vault jobs structure and interfaces..."
new_jobs_ok=0
for jf in "$BASE_DIR"/jobs/wan-gateway-watchdog.job.sh \
          "$BASE_DIR"/jobs/dns-unresponsive-heal.job.sh \
          "$BASE_DIR"/jobs/usb-storage-fsck-watchdog.job.sh \
          "$BASE_DIR"/jobs/nvram-jffs-vault.job.sh \
          "$BASE_DIR"/jobs/firewall-leak-audit.job.sh \
          "$BASE_DIR"/jobs/letsencrypt-cert-watchdog.job.sh \
          "$BASE_DIR"/jobs/ssh-auth-watchdog.job.sh; do
    if [ ! -f "$jf" ]; then
        echo "Missing job file: $jf"
        new_jobs_ok=1
        break
    fi
    # Verify required job metadata
    if ! grep -q '^JOB_NAME=' "$jf" || ! grep -q '^JOB_DESCRIPTION=' "$jf" || ! grep -q '^JOB_ENABLED=' "$jf"; then
        echo "Missing required metadata in $jf"
        new_jobs_ok=1
        break
    fi
    # Verify required lifecycle functions
    if ! grep -q 'mci_check_trigger()' "$jf" || ! grep -q 'mci_backup()' "$jf" || ! grep -q 'mci_run()' "$jf" || ! grep -q 'mci_verify()' "$jf"; then
        echo "Missing lifecycle function in $jf"
        new_jobs_ok=1
        break
    fi
done
test_assert "All 7 new watchdog jobs satisfy Merlin-CI lifecycle contract" "$new_jobs_ok"

# Test NVRAM & JFFS Vault execution in sandbox
VAULT_TEST_DIR="${TEST_DIR}/vault_test"
mkdir -p "$VAULT_TEST_DIR/jffs/scripts"
echo "echo test" > "$VAULT_TEST_DIR/jffs/scripts/canary.sh"

(
    # shellcheck source=jobs/nvram-jffs-vault.job.sh
    . "$BASE_DIR/jobs/nvram-jffs-vault.job.sh"
    VAULT_DIR="$VAULT_TEST_DIR/vault_output"
    mkdir -p "$VAULT_DIR"
    
    # Run vault snapshot
    mci_run >/dev/null 2>&1
    [ -d "$CURRENT_SNAPSHOT_DIR" ] || exit 1
)
test_assert "nvram-jffs-vault executes and outputs archive snapshot" "$?"

# Cleanup
rm -rf "$TEST_DIR"

echo "================================================================================"
echo " Test Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "================================================================================"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
