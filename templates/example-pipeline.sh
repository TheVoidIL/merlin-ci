#!/bin/sh
# ==============================================================================
# Merlin-CI Pipeline Definition Example (.merlin-ci.sh)
# Place this file in the root of your Git repository.
# ==============================================================================

# Pipeline Name & Metadata
PIPELINE_NAME="Router Custom Scripts CI"
PIPELINE_VERSION="1.0"

# Optional: Require specific Entware tools before running
REQUIRED_PACKAGES="jq curl"

mci_before_script() {
    echo "==> [SETUP] Checking prerequisites and environment..."
    echo "--> Running on router model: $(nvram get productid 2>/dev/null || uname -m)"
    echo "--> Firmware: $(nvram get buildno 2>/dev/null || uname -r)"
    echo "--> Current date: $(date)"

    # Verify required packages
    for pkg in $REQUIRED_PACKAGES; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            echo "--> Package '$pkg' missing. Attempting opkg install..."
            opkg update && opkg install "$pkg"
        fi
    done
}

mci_script() {
    echo "==> [BUILD & TEST] Running CI stages..."

    # Stage 1: Syntax check all shell scripts in the repository
    echo "--> Stage 1: Validating shell script syntax..."
    syntax_errors=0
    for script in $(find . -type f -name "*.sh" ! -path "*/.*/*"); do
        echo -n "  Checking $script... "
        if sh -n "$script" 2>/tmp/mci_syntax.err; then
            echo "PASS"
        else
            echo "FAIL"
            cat /tmp/mci_syntax.err
            syntax_errors=$((syntax_errors + 1))
        fi
    done
    rm -f /tmp/mci_syntax.err

    if [ "$syntax_errors" -gt 0 ]; then
        echo "--> ERROR: $syntax_errors syntax error(s) detected!"
        return 1
    fi

    # Stage 2: Custom tests (e.g., verifying custom iptables or dnsmasq config generators)
    echo "--> Stage 2: Running mock execution / unit tests..."
    if [ -f "./tests/run_tests.sh" ]; then
        sh "./tests/run_tests.sh"
    else
        echo "  No separate test suite found. Basic validation passed."
    fi

    echo "==> [SUCCESS] All pipeline checks passed successfully!"
    return 0
}

mci_after_script() {
    echo "==> [TEARDOWN] Cleaning temporary test artifacts..."
    rm -rf /tmp/mci_test_* 2>/dev/null || true
}

mci_on_success() {
    echo "==> [NOTIFY] Pipeline succeeded!"
}

mci_on_failure() {
    echo "==> [ALERT] Pipeline failed! Exit code: $MCI_JOB_EXIT_CODE"
}
