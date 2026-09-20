#!/bin/sh
# ==============================================================================
# Merlin-CI: Custom Job Template (templates/custom.job.sh)
# ==============================================================================

# Job Metadata
JOB_NAME="custom-script"
JOB_DESCRIPTION="Custom Router Automation and Health Check CI"
JOB_ENABLED=1

# --- Step 1: Trigger Condition ---
# Return 0 if the trigger condition is met (CI job will run).
# Return 1 if no action is needed (job will be skipped).
mci_check_trigger() {
    echo "--> [TRIGGER] Checking trigger condition for $JOB_NAME..."
    
    # Example: Check if a trigger file exists, or if remote version is newer,
    # or if a service has stopped.
    # Replace with your own trigger logic:
    # if [ -f "/tmp/run_my_job.flag" ]; then return 0; fi
    
    return 1
}

# --- Step 2: Pre-Execution Backup ---
# Snapshot any configuration files or scripts before executing changes.
mci_backup() {
    local backup_dir="$1" # Provided by runner: e.g. /opt/var/merlin-ci/backups/...
    echo "--> [BACKUP] Backing up files to $backup_dir..."
    
    # Example:
    # cp -f /jffs/scripts/my_script "$backup_dir/" 2>/dev/null || true
    return 0
}

# --- Step 3: Main Action / Execution ---
# Perform the update, deployment, or automation action.
mci_run() {
    echo "--> [RUN] Executing main action for $JOB_NAME..."
    
    # Example:
    # sh /jffs/scripts/my_script update
    return 0
}

# --- Step 4: Post-Execution Verification (CI Smoke Test) ---
# Verify the service is running properly.
# Return 0 if healthy (job SUCCEEDS).
# Return 1 if broken (triggers automated ROLLBACK).
mci_verify() {
    echo "--> [VERIFY] Running post-execution CI smoke tests..."
    
    # Example tests:
    # 1. Check syntax: sh -n /jffs/scripts/my_script || return 1
    # 2. Check process: pidof my_daemon >/dev/null || return 1
    # 3. Check connectivity: ping -c 1 1.1.1.1 >/dev/null || return 1
    return 0
}

# --- Step 5: Automated Rollback ---
# Called automatically if mci_verify returns non-zero.
# Restores files from the backup directory.
mci_rollback() {
    local backup_dir="$1"
    echo "--> [ROLLBACK] Reverting changes from $backup_dir..."
    
    # Example:
    # cp -f "$backup_dir/my_script" /jffs/scripts/my_script
    # sh /jffs/scripts/my_script restart
    return 0
}

# --- Step 6: Custom Notifications (Optional) ---
mci_notify() {
    local status="$1"    # "SUCCESS", "FAILED", or "ROLLED_BACK"
    local duration="$2"  # Runtime in seconds
    echo "--> [NOTIFY] Job $JOB_NAME finished with status: $status (${duration}s)"
}
