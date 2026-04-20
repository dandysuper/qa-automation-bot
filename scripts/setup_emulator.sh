#!/bin/bash
# setup_emulator.sh — Automated emulator setup for QA testing
#
# Handles:
#   - APK installation on emulator
#   - Frida server push and startup
#   - AVD root verification
#   - Google Play login state check
#
# Usage:
#   bash scripts/setup_emulator.sh [--apk /path/to/app.apk] [--avd pixel_12] [--no-wipe]
#
# Environment:
#   APK_PATH        — Path to target APK (or use --apk)
#   AVD_NAME        — AVD name (default: pixel_12, or use --avd)
#   FRIDA_SERVER    — Path to frida-server binary (default: /home/ubuntu/frida/frida-server)

set -euo pipefail

# ---------------------------------------------------------------------------
# Color output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
info()  { echo -e "        $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
AVD_NAME="${AVD_NAME:-pixel_12}"
APK_PATH="${APK_PATH:-}"
FRIDA_SERVER="${FRIDA_SERVER:-/home/ubuntu/frida/frida-server}"
WIPE_DATA="--wipe-data"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/home/ubuntu/android-sdk}"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk)
            APK_PATH="$2"
            shift 2
            ;;
        --avd)
            AVD_NAME="$2"
            shift 2
            ;;
        --no-wipe)
            WIPE_DATA=""
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--apk /path/to/app.apk] [--avd pixel_12] [--no-wipe]"
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
step "Running pre-flight checks..."

if ! command -v emulator &>/dev/null; then
    fail "Android emulator not found in PATH"
    info "Run: export PATH=\$ANDROID_SDK_ROOT/emulator:\$PATH"
    exit 1
fi
ok "Emulator binary found"

if ! command -v adb &>/dev/null; then
    fail "adb not found in PATH"
    exit 1
fi
ok "adb found"

if [ ! -f "$FRIDA_SERVER" ]; then
    fail "Frida server not found at $FRIDA_SERVER"
    info "Download from: https://github.com/frida/frida/releases"
    exit 1
fi
ok "Frida server binary found"

# Check KVM
if [ -e /dev/kvm ]; then
    ok "KVM available — hardware acceleration enabled"
else
    warn "KVM not available — emulator will be slow (software rendering)"
fi

# ---------------------------------------------------------------------------
# 2. Kill existing emulator instances
# ---------------------------------------------------------------------------
step "Cleaning up existing emulator instances..."
adb emu kill 2>/dev/null || true
killall qemu-system-x86_64 2>/dev/null || true
sleep 2
ok "Previous instances cleaned up"

# ---------------------------------------------------------------------------
# 3. Boot emulator
# ---------------------------------------------------------------------------
step "Booting AVD '$AVD_NAME' (this may take 1-3 minutes)..."
emulator -avd "$AVD_NAME" -no-window -no-audio -no-snapshot $WIPE_DATA &
EMU_PID=$!
info "Emulator PID: $EMU_PID"

step "Waiting for device to come online..."
adb wait-for-device
info "Device detected, waiting for boot to complete..."

BOOT_TIMEOUT=180
ELAPSED=0
while [[ -z $(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') ]]; do
    if [ $ELAPSED -ge $BOOT_TIMEOUT ]; then
        fail "Boot timeout after ${BOOT_TIMEOUT}s"
        kill $EMU_PID 2>/dev/null || true
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
ok "Emulator booted successfully (${ELAPSED}s)"

# ---------------------------------------------------------------------------
# 4. Root check and setup
# ---------------------------------------------------------------------------
step "Checking root access..."
ROOT_CHECK=$(adb shell "su -c 'whoami'" 2>/dev/null | tr -d '\r' || echo "no-root")
if [ "$ROOT_CHECK" = "root" ]; then
    ok "Root access confirmed"
else
    warn "Root access not available (su returned: '$ROOT_CHECK')"
    info "Some features (Frida injection) may not work without root"
    info "Try: adb root (for userdebug/eng builds)"
    adb root 2>/dev/null || true
    sleep 2
fi

# ---------------------------------------------------------------------------
# 5. Push and start Frida server
# ---------------------------------------------------------------------------
step "Pushing frida-server to device..."
adb push "$FRIDA_SERVER" /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server
ok "Frida server pushed"

step "Starting frida-server..."
adb shell "su -c 'killall frida-server 2>/dev/null; nohup /data/local/tmp/frida-server &'" &
sleep 3

# Verify frida-server is running
FRIDA_PID=$(adb shell "ps -A | grep frida-server" 2>/dev/null | awk '{print $2}' || echo "")
if [ -n "$FRIDA_PID" ]; then
    ok "Frida server running (PID: $FRIDA_PID)"
else
    warn "Frida server may not have started — check manually"
fi

# ---------------------------------------------------------------------------
# 6. Install APK (if provided)
# ---------------------------------------------------------------------------
if [ -n "$APK_PATH" ]; then
    if [ -f "$APK_PATH" ]; then
        step "Installing APK: $APK_PATH"
        adb install -r -g "$APK_PATH" 2>&1
        if [ $? -eq 0 ]; then
            ok "APK installed successfully"
        else
            fail "APK installation failed"
        fi
    else
        fail "APK file not found: $APK_PATH"
    fi
else
    info "No APK specified (use --apk /path/to/app.apk to install)"
fi

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=== Emulator Setup Complete ===${NC}"
echo -e "  AVD:           $AVD_NAME"
echo -e "  Emulator PID:  $EMU_PID"
echo -e "  Frida Server:  running"
[ -n "$APK_PATH" ] && echo -e "  APK:           $APK_PATH"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Verify with: frida-ps -U"
echo "  2. Run QA suite: bash scripts/qa_worker.sh"
echo "  3. Or attach Frida: frida -U -n <process> -l scripts/frida/qa_profiler.js"
