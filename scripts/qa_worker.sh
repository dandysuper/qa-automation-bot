#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# qa_worker.sh — GCP QA Worker Script
# Boots a clean Android emulator, installs the target APK, runs IAP
# validation flow with Frida instrumentation, and reports results.
#
# This script is executed on the GCP VM via SSH from the Railway bot.
# ---------------------------------------------------------------------------

set -euo pipefail

LOG_FILE="/home/ubuntu/qa_worker.log"
TARGET_APK="${TARGET_APK:-/home/ubuntu/app.apk}"
TARGET_PACKAGE="${TARGET_PACKAGE:-com.yourcompany.app}"
AVD_NAME="${AVD_NAME:-qa_device}"
EMULATOR_PORT="${EMULATOR_PORT:-5554}"
FRIDA_SCRIPT="${FRIDA_SCRIPT:-/home/ubuntu/frida_iap_hook.js}"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
    log "Cleaning up..."
    adb -s "emulator-${EMULATOR_PORT}" emu kill 2>/dev/null || true
    log "Cleanup complete."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Boot clean emulator
# ---------------------------------------------------------------------------
log "=== QA Worker Started ==="
log "Target package: ${TARGET_PACKAGE}"
log "AVD: ${AVD_NAME}"

log "Wiping and booting emulator..."
emulator -avd "${AVD_NAME}" \
    -port "${EMULATOR_PORT}" \
    -no-window \
    -no-audio \
    -no-snapshot \
    -wipe-data \
    -gpu swiftshader_indirect &

EMULATOR_PID=$!
log "Emulator PID: ${EMULATOR_PID}"

# Wait for boot
log "Waiting for emulator to boot..."
BOOT_TIMEOUT=120
ELAPSED=0
while [ "$ELAPSED" -lt "$BOOT_TIMEOUT" ]; do
    BOOT_STATUS=$(adb -s "emulator-${EMULATOR_PORT}" shell getprop sys.boot_completed 2>/dev/null || echo "")
    if [ "$BOOT_STATUS" = "1" ]; then
        log "Emulator booted successfully."
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
    log "ERROR: Emulator boot timed out after ${BOOT_TIMEOUT}s"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Install target APK
# ---------------------------------------------------------------------------
log "Installing target APK: ${TARGET_APK}"
if [ ! -f "${TARGET_APK}" ]; then
    log "ERROR: APK not found at ${TARGET_APK}"
    exit 1
fi

adb -s "emulator-${EMULATOR_PORT}" install -r "${TARGET_APK}"
log "APK installed."

# ---------------------------------------------------------------------------
# 3. Launch app
# ---------------------------------------------------------------------------
log "Launching ${TARGET_PACKAGE}..."
adb -s "emulator-${EMULATOR_PORT}" shell monkey \
    -p "${TARGET_PACKAGE}" \
    -c android.intent.category.LAUNCHER 1
sleep 3

# ---------------------------------------------------------------------------
# 4. Frida instrumentation (IAP/SSL monitoring)
# ---------------------------------------------------------------------------
if command -v frida &>/dev/null && [ -f "${FRIDA_SCRIPT}" ]; then
    log "Starting Frida instrumentation..."
    frida -U -f "${TARGET_PACKAGE}" \
        -l "${FRIDA_SCRIPT}" \
        --no-pause &
    FRIDA_PID=$!
    sleep 5
    log "Frida attached (PID: ${FRIDA_PID})"
else
    log "WARN: Frida not available or script missing — skipping instrumentation"
fi

# ---------------------------------------------------------------------------
# 5. ADB UAT — simulate IAP purchase flow taps
# ---------------------------------------------------------------------------
log "Running IAP UI acceptance tests..."

# Navigate to subscription/purchase screen (adjust coordinates for your app)
adb -s "emulator-${EMULATOR_PORT}" shell input tap 540 960    # tap purchase button
sleep 2
adb -s "emulator-${EMULATOR_PORT}" shell input tap 540 1200   # confirm dialog
sleep 2
adb -s "emulator-${EMULATOR_PORT}" shell input tap 540 1400   # accept terms
sleep 2

# Verify purchase flow completed
ACTIVITY=$(adb -s "emulator-${EMULATOR_PORT}" shell dumpsys activity activities \
    | grep -i "mResumedActivity" || echo "unknown")
log "Current activity: ${ACTIVITY}"

# ---------------------------------------------------------------------------
# 6. Collect results
# ---------------------------------------------------------------------------
log "Collecting test results..."

# Capture logcat for billing events
adb -s "emulator-${EMULATOR_PORT}" shell logcat -d \
    -s "BillingClient" "InAppBilling" "Purchase" \
    > /home/ubuntu/qa_billing_log.txt 2>/dev/null || true

BILLING_EVENTS=$(wc -l < /home/ubuntu/qa_billing_log.txt 2>/dev/null || echo "0")
log "Captured ${BILLING_EVENTS} billing log events."

# Kill Frida if running
if [ -n "${FRIDA_PID:-}" ]; then
    kill "${FRIDA_PID}" 2>/dev/null || true
fi

log "=== QA Worker Completed Successfully ==="
exit 0
