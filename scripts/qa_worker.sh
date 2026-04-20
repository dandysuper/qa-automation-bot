#!/bin/bash
# qa_worker.sh — Enhanced QA worker for IAP validation on GCP
#
# Features:
#   - Color-coded output with step-by-step logging
#   - Configurable target app via subscription_plans.json or env vars
#   - Multi-instance AVD support (--instance <id>)
#   - Detailed error handling and result reporting
#
# Usage:
#   bash qa_worker.sh [--plan <plan_name>] [--instance <id>] [--config /path/to/config.json]
#   bash qa_worker.sh --plan 1-month --instance 0
#
# Environment:
#   TARGET_PACKAGE   — Android package name (default: from config)
#   TARGET_PROCESS   — Process name for Frida (default: from config)
#   AVD_NAME         — AVD name (default: pixel_12)
#   FRIDA_SCRIPT     — Path to Frida hook script
#   QA_LOG_FILE      — Log output file (default: /home/ubuntu/qa_worker.log)

set -uo pipefail

# ---------------------------------------------------------------------------
# Color output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

STEP_NUM=0
TOTAL_STEPS=7
ERRORS=0
WARNINGS=0

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "${BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${NC} ${BOLD}$*${NC}"
}

ok()    { echo -e "  ${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $*"; ERRORS=$((ERRORS + 1)); }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; WARNINGS=$((WARNINGS + 1)); }
info()  { echo -e "  ${CYAN}[INFO]${NC}  $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/subscription_plans.json"
PLAN_NAME=""
INSTANCE_ID=0
AVD_NAME="${AVD_NAME:-pixel_12}"
TARGET_PACKAGE="${TARGET_PACKAGE:-}"
TARGET_PROCESS="${TARGET_PROCESS:-}"
FRIDA_SCRIPT="${FRIDA_SCRIPT:-${SCRIPT_DIR}/frida/qa_profiler.js}"
QA_LOG_FILE="${QA_LOG_FILE:-/home/ubuntu/qa_worker.log}"
BOOT_TIMEOUT=180
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/home/ubuntu/android-sdk}"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)
            PLAN_NAME="$2"
            shift 2
            ;;
        --instance)
            INSTANCE_ID="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --package)
            TARGET_PACKAGE="$2"
            shift 2
            ;;
        --process)
            TARGET_PROCESS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--plan <name>] [--instance <id>] [--config /path/to/config.json]"
            echo "  --plan      Subscription plan name (from config)"
            echo "  --instance  AVD instance ID for parallel runs (default: 0)"
            echo "  --config    Path to subscription_plans.json"
            echo "  --package   Target Android package name"
            echo "  --process   Target process name for Frida"
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [ -f "$CONFIG_FILE" ] && command -v python3 &>/dev/null; then
    if [ -z "$TARGET_PACKAGE" ]; then
        TARGET_PACKAGE=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('$CONFIG_FILE'))
    print(cfg.get('target_package', 'com.target.application'))
except: print('com.target.application')
" 2>/dev/null)
    fi
    if [ -z "$TARGET_PROCESS" ]; then
        TARGET_PROCESS=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('$CONFIG_FILE'))
    print(cfg.get('target_process', 'TargetApp'))
except: print('TargetApp')
" 2>/dev/null)
    fi
    if [ -n "$PLAN_NAME" ]; then
        OFFER_TOKEN=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('$CONFIG_FILE'))
    plan = cfg['plans'].get('$PLAN_NAME', {})
    print(plan.get('offerToken', ''))
except: print('')
" 2>/dev/null)
    fi
fi

TARGET_PACKAGE="${TARGET_PACKAGE:-com.target.application}"
TARGET_PROCESS="${TARGET_PROCESS:-TargetApp}"

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
exec > >(tee -a "$QA_LOG_FILE") 2>&1

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} QA Automation Worker${NC}"
echo -e "${BOLD} $(date '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
info "Target package:  $TARGET_PACKAGE"
info "Target process:  $TARGET_PROCESS"
info "AVD:             $AVD_NAME"
info "Instance ID:     $INSTANCE_ID"
info "Frida script:    $FRIDA_SCRIPT"
[ -n "$PLAN_NAME" ] && info "Subscription plan: $PLAN_NAME"
echo ""

# ---------------------------------------------------------------------------
# 1. Clear previous test environments
# ---------------------------------------------------------------------------
step "Clearing previous test environments"
adb emu kill 2>/dev/null && ok "Previous emulator killed" || info "No emulator to kill"
killall qemu-system-x86_64 2>/dev/null && ok "Previous QEMU killed" || info "No QEMU to kill"
sleep 2

# ---------------------------------------------------------------------------
# 2. Boot clean test environment
# ---------------------------------------------------------------------------
step "Booting clean AVD '$AVD_NAME'"
emulator -avd "$AVD_NAME" -no-window -no-audio -no-snapshot -wipe-data &
EMU_PID=$!
info "Emulator PID: $EMU_PID"

info "Waiting for device..."
adb wait-for-device
ok "Device detected"

info "Waiting for boot to complete (timeout: ${BOOT_TIMEOUT}s)..."
ELAPSED=0
while [[ -z $(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') ]]; do
    if [ $ELAPSED -ge $BOOT_TIMEOUT ]; then
        fail "Boot timed out after ${BOOT_TIMEOUT}s"
        kill $EMU_PID 2>/dev/null || true
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
ok "Emulator booted in ${ELAPSED}s"

# ---------------------------------------------------------------------------
# 3. Start Frida server
# ---------------------------------------------------------------------------
step "Starting Frida server"
adb push /home/ubuntu/frida/frida-server /data/local/tmp/frida-server 2>/dev/null || true
adb shell chmod 755 /data/local/tmp/frida-server
adb shell "su -c 'killall frida-server 2>/dev/null; nohup /data/local/tmp/frida-server &'" 2>/dev/null
sleep 2

if adb shell "ps -A" 2>/dev/null | grep -q frida-server; then
    ok "Frida server running"
else
    warn "Frida server may not have started — continuing anyway"
fi

# Set offer token override if specified
if [ -n "${OFFER_TOKEN:-}" ] && [ "$OFFER_TOKEN" != "" ]; then
    info "Setting offer token override: $OFFER_TOKEN"
    adb shell "setprop qa.offer.token.override '$OFFER_TOKEN'" 2>/dev/null
    ok "Offer token override set"
fi

# ---------------------------------------------------------------------------
# 4. Launch target application
# ---------------------------------------------------------------------------
step "Launching target application ($TARGET_PACKAGE)"
LAUNCH_RESULT=$(adb shell monkey -p "$TARGET_PACKAGE" -c android.intent.category.LAUNCHER 1 2>&1)
if echo "$LAUNCH_RESULT" | grep -q "No activities found"; then
    fail "Package '$TARGET_PACKAGE' not found on device"
    warn "Install the target APK first: adb install /path/to/app.apk"
else
    ok "Application launched"
fi
sleep 10

# ---------------------------------------------------------------------------
# 5. Inject Frida profiling hooks
# ---------------------------------------------------------------------------
step "Injecting Frida profiling hooks"
FRIDA_PID=""
if [ -f "$FRIDA_SCRIPT" ]; then
    frida -U -n "$TARGET_PROCESS" -l "$FRIDA_SCRIPT" --no-pause &
    FRIDA_PID=$!
    sleep 5

    if kill -0 "$FRIDA_PID" 2>/dev/null; then
        ok "Frida hooks injected (PID: $FRIDA_PID)"
    else
        warn "Frida injection may have failed — check if process '$TARGET_PROCESS' is running"
        FRIDA_PID=""
    fi
else
    warn "Frida script not found at: $FRIDA_SCRIPT"
    warn "Skipping Frida injection"
fi

# Also load subscription hooks if available
SUB_HOOKS="${SCRIPT_DIR}/frida/subscription_hooks.js"
SUB_FRIDA_PID=""
if [ -f "$SUB_HOOKS" ]; then
    frida -U -n "$TARGET_PROCESS" -l "$SUB_HOOKS" --no-pause &
    SUB_FRIDA_PID=$!
    sleep 3
    if kill -0 "$SUB_FRIDA_PID" 2>/dev/null; then
        ok "Subscription hooks injected"
    else
        warn "Subscription hooks injection failed"
        SUB_FRIDA_PID=""
    fi
fi

# ---------------------------------------------------------------------------
# 6. Simulate user interaction (UAT)
# ---------------------------------------------------------------------------
step "Simulating user interaction"
info "Tap: checkout button (500, 1500)"
adb shell input tap 500 1500
sleep 3
ok "Checkout tap sent"

info "Tap: confirm button (500, 1800)"
adb shell input tap 500 1800
sleep 5
ok "Confirm tap sent"

# ---------------------------------------------------------------------------
# 7. Teardown and report
# ---------------------------------------------------------------------------
step "Tearing down test environment"
[ -n "$FRIDA_PID" ] && kill "$FRIDA_PID" 2>/dev/null && ok "Frida profiler stopped"
[ -n "$SUB_FRIDA_PID" ] && kill "$SUB_FRIDA_PID" 2>/dev/null && ok "Subscription hooks stopped"
adb emu kill 2>/dev/null && ok "Emulator stopped"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}${BOLD} QA Suite: PASSED${NC}"
else
    echo -e "${RED}${BOLD} QA Suite: FAILED ($ERRORS errors)${NC}"
fi
echo -e "${BOLD} Completed: $(date '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BOLD} Errors: $ERRORS | Warnings: $WARNINGS${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

exit $ERRORS
