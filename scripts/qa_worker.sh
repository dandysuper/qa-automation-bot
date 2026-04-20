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
#   bash qa_worker.sh --plan chatgpt-plus-monthly --instance 0
#   bash qa_worker.sh --snapshot chatgpt_logged_in --plan chatgpt-plus-monthly
#   bash qa_worker.sh --frida-script /path/to/custom_hook.js
#
# Environment:
#   TARGET_PACKAGE   — Android package name (default: from config)
#   TARGET_PROCESS   — Process name for Frida (default: from config)
#   AVD_NAME         — AVD name (default: pixel_12)
#   FRIDA_SCRIPT     — Path to Frida hook script
#   QA_LOG_FILE      — Log output file (default: /home/ubuntu/qa_worker.log)
#   SNAPSHOT_NAME    — Emulator snapshot to load instead of fresh boot

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
SNAPSHOT_NAME="${SNAPSHOT_NAME:-}"
BOOT_TIMEOUT=180
BOOT_WAIT_EXTRA=5
POST_LAUNCH_WAIT=10
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
        --snapshot)
            SNAPSHOT_NAME="$2"
            shift 2
            ;;
        --frida-script)
            FRIDA_SCRIPT="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--plan <name>] [--instance <id>] [--config /path/to/config.json]"
            echo "  --plan      Subscription plan name (from config)"
            echo "  --instance  AVD instance ID for parallel runs (default: 0)"
            echo "  --config    Path to subscription_plans.json"
            echo "  --package   Target Android package name"
            echo "  --process   Target process name for Frida"
            echo "  --snapshot  Load emulator snapshot instead of fresh boot"
            echo "  --frida-script  Path to custom Frida hook script"
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
    # Load all config values in a single python call
    eval $(python3 -c "
import json, sys, shlex
try:
    cfg = json.load(open('$CONFIG_FILE'))
    print(f'_CFG_PACKAGE={shlex.quote(cfg.get("target_package", "com.openai.chatgpt"))}')
    print(f'_CFG_PROCESS={shlex.quote(cfg.get("target_process", "com.openai.chatgpt"))}')
    # Tap coordinates
    taps = cfg.get('tap_coordinates', {})
    print(f'TAP_UPGRADE={shlex.quote(" ".join(str(c) for c in taps.get("upgrade_button", [540, 1700])))}')
    print(f'TAP_PLAN={shlex.quote(" ".join(str(c) for c in taps.get("plan_select", [540, 900])))}')
    print(f'TAP_CONFIRM={shlex.quote(" ".join(str(c) for c in taps.get("subscribe_confirm", [540, 1800])))}')
    print(f'TAP_SETTINGS={shlex.quote(" ".join(str(c) for c in taps.get("settings_menu", [980, 160])))}')
    print(f'TAP_SUB_MENU={shlex.quote(" ".join(str(c) for c in taps.get("subscription_menu", [540, 600])))}')
    # Emulator settings
    emu = cfg.get('emulator', {})
    if not '$SNAPSHOT_NAME':
        snap = emu.get('snapshot_name', '')
        if snap: print(f'SNAPSHOT_NAME={shlex.quote(snap)}')
    print(f'BOOT_WAIT_EXTRA={emu.get("boot_wait_extra", 5)}')
    print(f'POST_LAUNCH_WAIT={emu.get("post_launch_wait", 10)}')
    # Plan offer token
    plan = cfg.get('plans', {}).get('$PLAN_NAME', {})
    print(f'_CFG_OFFER_TOKEN={shlex.quote(plan.get("offerToken", ""))}')
except Exception as e:
    print(f'# Config parse error: {e}', file=sys.stderr)
" 2>/dev/null)

    [ -z "$TARGET_PACKAGE" ] && TARGET_PACKAGE="${_CFG_PACKAGE:-}"
    [ -z "$TARGET_PROCESS" ] && TARGET_PROCESS="${_CFG_PROCESS:-}"
    [ -n "$PLAN_NAME" ] && OFFER_TOKEN="${_CFG_OFFER_TOKEN:-}"
fi

TARGET_PACKAGE="${TARGET_PACKAGE:-com.openai.chatgpt}"
TARGET_PROCESS="${TARGET_PROCESS:-com.openai.chatgpt}"
TAP_UPGRADE="${TAP_UPGRADE:-540 1700}"
TAP_PLAN="${TAP_PLAN:-540 900}"
TAP_CONFIRM="${TAP_CONFIRM:-540 1800}"
TAP_SETTINGS="${TAP_SETTINGS:-980 160}"
TAP_SUB_MENU="${TAP_SUB_MENU:-540 600}"

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
[ -n "$SNAPSHOT_NAME" ] && info "Snapshot:        $SNAPSHOT_NAME"
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
# 2. Boot test environment (snapshot or clean)
# ---------------------------------------------------------------------------
if [ -n "$SNAPSHOT_NAME" ]; then
    step "Loading AVD '$AVD_NAME' from snapshot '$SNAPSHOT_NAME'"
    emulator -avd "$AVD_NAME" -no-window -no-audio -snapshot "$SNAPSHOT_NAME" &
    EMU_PID=$!
else
    step "Booting clean AVD '$AVD_NAME'"
    emulator -avd "$AVD_NAME" -no-window -no-audio -no-snapshot -wipe-data &
    EMU_PID=$!
fi
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

# Extra wait for system services
if [ "$BOOT_WAIT_EXTRA" -gt 0 ]; then
    info "Waiting ${BOOT_WAIT_EXTRA}s for system services to stabilize..."
    sleep "$BOOT_WAIT_EXTRA"
fi

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
# 6. Simulate user interaction (ChatGPT IAP flow)
# ---------------------------------------------------------------------------
step "Simulating user interaction (IAP flow)"

# Navigate to subscription: Settings → Subscription
info "Tap: settings menu ($TAP_SETTINGS)"
adb shell input tap $TAP_SETTINGS
sleep 2
ok "Settings menu tap sent"

info "Tap: subscription menu ($TAP_SUB_MENU)"
adb shell input tap $TAP_SUB_MENU
sleep 3
ok "Subscription menu tap sent"

# Select plan and trigger purchase
info "Tap: upgrade/plan button ($TAP_UPGRADE)"
adb shell input tap $TAP_UPGRADE
sleep 3
ok "Upgrade button tap sent"

info "Tap: select plan ($TAP_PLAN)"
adb shell input tap $TAP_PLAN
sleep 2
ok "Plan selection tap sent"

info "Tap: confirm subscription ($TAP_CONFIRM)"
adb shell input tap $TAP_CONFIRM
sleep 5
ok "Subscription confirm tap sent"

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
