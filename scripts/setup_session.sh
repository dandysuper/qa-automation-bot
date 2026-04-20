#!/usr/bin/env bash
# ============================================================================
# setup_session.sh — Container lifecycle script for IAP QA testing
#
# This script runs INSIDE the Docker container (golden image entrypoint).
# It orchestrates: emulator boot → app install → login → snapshot →
# Frida injection → UI automation → validation → teardown.
#
# Usage (invoked by the bot via SSH on GCP):
#   docker run --rm --privileged \
#       -e TEST_EMAIL="..." -e TEST_PASSWORD="..." -e MOCK_PAYMENT="..." \
#       -e SESSION_ID="..." -e TARGET_APK_PATH="..." \
#       -v /mnt/qa-data:/data/qa \
#       qa-avd-golden:latest
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (from environment or defaults)
# ---------------------------------------------------------------------------
SESSION_ID="${SESSION_ID:-$(date +%s)-$$}"
TEST_EMAIL="${TEST_EMAIL:?TEST_EMAIL is required}"
TEST_PASSWORD="${TEST_PASSWORD:?TEST_PASSWORD is required}"
MOCK_PAYMENT="${MOCK_PAYMENT:-mock_card_visa}"
TARGET_APK_PATH="${TARGET_APK_PATH:-/data/qa/app-staging.apk}"
TARGET_PACKAGE="${TARGET_PACKAGE:-com.yourcompany.app}"
AVD_NAME="${AVD_NAME:-qa_device}"
DATA_DIR="/data/qa"
LOG_FILE="${DATA_DIR}/session_${SESSION_ID}.log"
SNAPSHOT_NAME="test_ready_${SESSION_ID}"
FRIDA_SCRIPT="/opt/qa/hook_1m.js"
QA_WORKER="/opt/qa/qa_worker.sh"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "${DATA_DIR}"

log() {
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[${ts}] [${SESSION_ID}] $*" | tee -a "${LOG_FILE}"
}

cleanup() {
    log "TEARDOWN: killing emulator and cleaning up"
    adb emu kill 2>/dev/null || true
    killall qemu-system-x86_64 2>/dev/null || true
    log "TEARDOWN: session ${SESSION_ID} complete"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Phase 1 — Boot emulator
# ---------------------------------------------------------------------------
log "PHASE 1: Booting Android emulator (AVD=${AVD_NAME})"

# Start Xvfb for headless rendering
Xvfb :1 -screen 0 1080x2340x24 &
export DISPLAY=:1
sleep 2

emulator -avd "${AVD_NAME}" \
    -no-window \
    -no-audio \
    -no-snapshot \
    -gpu swiftshader_indirect \
    -memory 2048 \
    -cores 2 \
    -wipe-data &
EMU_PID=$!

log "PHASE 1: Waiting for emulator to boot (PID=${EMU_PID})"
adb wait-for-device

# Wait for full boot
BOOT_TIMEOUT=180
BOOT_ELAPSED=0
while [ -z "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" ]; do
    sleep 3
    BOOT_ELAPSED=$((BOOT_ELAPSED + 3))
    if [ "${BOOT_ELAPSED}" -ge "${BOOT_TIMEOUT}" ]; then
        log "ERROR: Emulator boot timed out after ${BOOT_TIMEOUT}s"
        exit 1
    fi
done
log "PHASE 1: Emulator booted in ${BOOT_ELAPSED}s"

# Disable animations for reliable UI automation
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

# ---------------------------------------------------------------------------
# Phase 2 — Push Frida server & install APK
# ---------------------------------------------------------------------------
log "PHASE 2: Pushing Frida server to device"
adb push /opt/frida-server /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server

log "PHASE 2: Installing app from ${TARGET_APK_PATH}"
if [ -f "${TARGET_APK_PATH}" ]; then
    bash /opt/qa/install_xapk.sh "${TARGET_APK_PATH}"
    log "PHASE 2: App installed successfully"
else
    log "WARNING: App package not found at ${TARGET_APK_PATH}, assuming pre-installed"
fi

# ---------------------------------------------------------------------------
# Phase 3 — Login to Google Play sandbox
# ---------------------------------------------------------------------------
log "PHASE 3: Logging into test account (${TEST_EMAIL})"

# Open Google Play Store
adb shell am start -n com.android.vending/.AssetBrowserActivity
sleep 5

# Type email via adb keyevents
type_text() {
    local text="$1"
    adb shell input text "${text}"
    sleep 1
}

press_key() {
    local key="$1"
    adb shell input keyevent "${key}"
    sleep 1
}

# Navigate sign-in flow (coordinates for standard Google Play sign-in)
# Tap on account/sign-in area
adb shell input tap 540 1170
sleep 3

type_text "${TEST_EMAIL}"
press_key 66  # KEYCODE_ENTER
sleep 3

type_text "${TEST_PASSWORD}"
press_key 66  # KEYCODE_ENTER
sleep 5

# Accept terms if prompted
adb shell input tap 540 1800
sleep 3

log "PHASE 3: Login sequence completed"

# ---------------------------------------------------------------------------
# Phase 4 — Save pre-warmed snapshot
# ---------------------------------------------------------------------------
log "PHASE 4: Saving pre-warmed snapshot (${SNAPSHOT_NAME})"
adb emu avd snapshot save "${SNAPSHOT_NAME}"
log "PHASE 4: Snapshot saved — pre-authenticated state preserved"

# Persist snapshot reference for future runs
echo "${SNAPSHOT_NAME}" >> "${DATA_DIR}/snapshots.txt"

# ---------------------------------------------------------------------------
# Phase 5 — Start Frida server & inject hooks
# ---------------------------------------------------------------------------
log "PHASE 5: Starting Frida server"
adb shell su -c '/data/local/tmp/frida-server -D &'
sleep 3

# Launch the target application
log "PHASE 5: Launching ${TARGET_PACKAGE}"
adb shell monkey -p "${TARGET_PACKAGE}" -c android.intent.category.LAUNCHER 1
sleep 8

# Inject Frida instrumentation
log "PHASE 5: Injecting Frida hooks (hook_1m.js)"
frida -U -n "${TARGET_PACKAGE##*.}" -l "${FRIDA_SCRIPT}" --no-pause &
FRIDA_PID=$!
sleep 5

if ! kill -0 "${FRIDA_PID}" 2>/dev/null; then
    log "WARNING: Frida injection may have failed, attempting with package name"
    frida -U -f "${TARGET_PACKAGE}" -l "${FRIDA_SCRIPT}" --no-pause &
    FRIDA_PID=$!
    sleep 5
fi

log "PHASE 5: Frida instrumentation active (PID=${FRIDA_PID})"

# ---------------------------------------------------------------------------
# Phase 6 — Execute UI automation (qa_worker.sh)
# ---------------------------------------------------------------------------
log "PHASE 6: Running UI automation — IAP flow"
bash "${QA_WORKER}" "${TARGET_PACKAGE}" "${MOCK_PAYMENT}" 2>&1 | tee -a "${LOG_FILE}"
QA_EXIT=$?

if [ "${QA_EXIT}" -eq 0 ]; then
    log "PHASE 6: IAP flow validation PASSED"
else
    log "PHASE 6: IAP flow validation FAILED (exit=${QA_EXIT})"
fi

# ---------------------------------------------------------------------------
# Phase 7 — Cleanup & logout
# ---------------------------------------------------------------------------
log "PHASE 7: Logging out test account"

# Force stop the app
adb shell am force-stop "${TARGET_PACKAGE}"
sleep 2

# Clear app data to log out
adb shell pm clear "${TARGET_PACKAGE}" 2>/dev/null || true

# Remove Google account from device
adb shell am start -a android.settings.SYNC_SETTINGS
sleep 3
# Navigate to remove account (best-effort)
adb shell input tap 540 400
sleep 2
adb shell input tap 540 1800
sleep 2

log "PHASE 7: Account cleanup completed"

# Kill Frida
kill "${FRIDA_PID}" 2>/dev/null || true

log "SESSION COMPLETE: ${SESSION_ID} (exit=${QA_EXIT})"
exit "${QA_EXIT}"
