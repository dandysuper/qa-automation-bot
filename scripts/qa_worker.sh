#!/usr/bin/env bash
# ============================================================================
# qa_worker.sh — UI automation for IAP flow validation
#
# Runs inside the Docker container after Frida hooks are injected.
# Simulates user taps through the subscription upgrade flow and validates
# the mocked purchase completes successfully via the overridden offerToken.
#
# Usage (called by setup_session.sh):
#   bash qa_worker.sh <target_package> <mock_payment>
# ============================================================================
set -euo pipefail

TARGET_PACKAGE="${1:-com.yourcompany.app}"
MOCK_PAYMENT="${2:-mock_card_visa}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
    echo "[qa_worker] $(date -u +%H:%M:%S) $*"
}

wait_for_activity() {
    local expected="$1"
    local timeout="${2:-30}"
    local elapsed=0

    while [ "${elapsed}" -lt "${timeout}" ]; do
        local current
        current=$(adb shell dumpsys activity activities 2>/dev/null \
            | grep -oP 'mResumedActivity.*?\K[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' \
            | head -1 || true)

        if echo "${current}" | grep -qi "${expected}"; then
            log "Activity matched: ${current}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log "WARNING: Timed out waiting for activity containing '${expected}'"
    return 1
}

tap() {
    local x="$1" y="$2" label="${3:-}"
    log "TAP (${x}, ${y}) ${label}"
    adb shell input tap "${x}" "${y}"
    sleep 2
}

swipe_up() {
    log "SWIPE UP"
    adb shell input swipe 540 1800 540 800 300
    sleep 2
}

take_screenshot() {
    local name="${1:-screenshot}"
    local path="/data/qa/${name}_$(date +%s).png"
    adb shell screencap -p "/sdcard/${name}.png"
    adb pull "/sdcard/${name}.png" "${path}" 2>/dev/null || true
    log "Screenshot saved: ${path}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log "Starting IAP UI automation"
log "Target package: ${TARGET_PACKAGE}"
log "Mock payment: ${MOCK_PAYMENT}"

# Verify app is running
APP_PID=$(adb shell pidof "${TARGET_PACKAGE}" 2>/dev/null || true)
if [ -z "${APP_PID}" ]; then
    log "App not running, launching..."
    adb shell monkey -p "${TARGET_PACKAGE}" -c android.intent.category.LAUNCHER 1
    sleep 8
    APP_PID=$(adb shell pidof "${TARGET_PACKAGE}" 2>/dev/null || true)
fi
log "App PID: ${APP_PID:-unknown}"

take_screenshot "01_app_launched"

# ---------------------------------------------------------------------------
# Step 1 — Navigate to subscription / upgrade screen
# ---------------------------------------------------------------------------
log "STEP 1: Navigating to subscription screen"

# Tap on profile / settings (typical top-right corner)
tap 980 160 "profile/settings icon"
sleep 3

# Tap on "Upgrade" or "Premium" option
tap 540 900 "upgrade/premium option"
sleep 3

take_screenshot "02_subscription_screen"

# ---------------------------------------------------------------------------
# Step 2 — Select 1-month subscription tier
# ---------------------------------------------------------------------------
log "STEP 2: Selecting 1-month subscription tier"

# Scroll to find subscription options if needed
swipe_up
sleep 2

# Tap on the 1-month plan option
tap 540 1200 "1-month plan"
sleep 2

take_screenshot "03_plan_selected"

# ---------------------------------------------------------------------------
# Step 3 — Tap the "Upgrade" / "Subscribe" button
# ---------------------------------------------------------------------------
log "STEP 3: Tapping upgrade/subscribe button"

# The "Upgrade" button — coordinates adjusted for standard layout
tap 540 1500 "upgrade button"
sleep 3

take_screenshot "04_upgrade_tapped"

# ---------------------------------------------------------------------------
# Step 4 — Handle Google Play billing dialog
# ---------------------------------------------------------------------------
log "STEP 4: Handling billing dialog (sandbox)"

# Wait for the Google Play billing sheet to appear
sleep 5

# The billing dialog shows payment method — tap "Subscribe" / "Buy"
# In sandbox mode with Frida hooks, the offerToken is overridden
tap 540 1800 "confirm purchase (billing dialog)"
sleep 5

take_screenshot "05_billing_confirmed"

# ---------------------------------------------------------------------------
# Step 5 — Validate purchase result
# ---------------------------------------------------------------------------
log "STEP 5: Validating purchase result"

# Check logcat for Frida hook output confirming purchase
PURCHASE_RESULT=$(adb logcat -d -t 50 | grep -i "hook_1m.*purchase\|hook_1m.*BillingResult" || true)

if echo "${PURCHASE_RESULT}" | grep -qi "completed successfully\|code=0"; then
    log "VALIDATION: Purchase flow completed successfully (sandbox)"
    VALIDATION_STATUS="PASSED"
elif echo "${PURCHASE_RESULT}" | grep -qi "USER_CANCELED\|code=1"; then
    log "VALIDATION: Purchase was canceled by user"
    VALIDATION_STATUS="CANCELED"
else
    log "VALIDATION: Purchase result unclear — check logs"
    log "Frida output: ${PURCHASE_RESULT}"
    VALIDATION_STATUS="INCONCLUSIVE"
fi

take_screenshot "06_final_state"

# ---------------------------------------------------------------------------
# Step 6 — Verify subscription state in-app
# ---------------------------------------------------------------------------
log "STEP 6: Verifying subscription state"

# Navigate back to main screen
adb shell input keyevent 4  # BACK
sleep 2
adb shell input keyevent 4  # BACK
sleep 2

# Check if premium features are unlocked (app-specific)
take_screenshot "07_subscription_verified"

# Dump activity state for logging
adb shell dumpsys activity "${TARGET_PACKAGE}" 2>/dev/null | \
    grep -iE "subscription|premium|pro|upgrade" | head -10 || true

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
log "==========================================="
log "IAP QA RESULT: ${VALIDATION_STATUS}"
log "Session complete"
log "==========================================="

case "${VALIDATION_STATUS}" in
    PASSED)
        exit 0
        ;;
    CANCELED)
        exit 2
        ;;
    *)
        exit 1
        ;;
esac
