#!/bin/bash
# gcp_vm_setup.sh — One-shot setup script for GCP QA worker VM
# Run this on the GCP VM after creation to install:
#   - Android SDK (command-line tools, platform-tools, emulator)
#   - Android system image (API 32, x86_64)
#   - AVD (pixel_12)
#   - Frida server
#
# Usage: ssh ubuntu@<GCP_IP> 'bash -s' < scripts/gcp_vm_setup.sh

set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

export DEBIAN_FRONTEND=noninteractive
ANDROID_SDK_ROOT="/home/ubuntu/android-sdk"
FRIDA_VERSION="16.5.9"

# ---------------------------------------------------------------------------
# 1. System dependencies
# ---------------------------------------------------------------------------
log "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    openjdk-17-jdk-headless \
    unzip \
    wget \
    curl \
    python3-pip \
    libvirt-daemon-system \
    qemu-kvm \
    cpu-checker \
    adb

# Check KVM support
log "Checking KVM support..."
if [ -e /dev/kvm ]; then
    log "KVM is available — hardware acceleration enabled"
    sudo chmod 666 /dev/kvm
else
    log "WARNING: KVM not available — emulator will use software rendering (slower)"
fi

# ---------------------------------------------------------------------------
# 2. Android SDK
# ---------------------------------------------------------------------------
log "Installing Android SDK..."
mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
wget -q "$CMDLINE_TOOLS_URL" -O /tmp/cmdline-tools.zip
unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"
mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
rm /tmp/cmdline-tools.zip

# Set up environment
cat >> ~/.bashrc << 'EOF'
export ANDROID_SDK_ROOT="$HOME/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"
EOF

export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

# Accept licenses and install components
log "Accepting SDK licenses..."
yes | sdkmanager --licenses > /dev/null 2>&1 || true

log "Installing SDK components (this takes a few minutes)..."
sdkmanager --install \
    "platform-tools" \
    "emulator" \
    "platforms;android-32" \
    "system-images;android-32;google_apis;x86_64"

# ---------------------------------------------------------------------------
# 3. Create AVD
# ---------------------------------------------------------------------------
log "Creating AVD 'pixel_12'..."
echo "no" | avdmanager create avd \
    -n pixel_12 \
    -k "system-images;android-32;google_apis;x86_64" \
    -d "pixel_4" \
    --force

# ---------------------------------------------------------------------------
# 4. Frida
# ---------------------------------------------------------------------------
log "Installing Frida tools..."
pip3 install frida-tools --break-system-packages 2>/dev/null || pip3 install frida-tools

log "Downloading Frida server for Android x86_64..."
FRIDA_SERVER_URL="https://github.com/frida/frida/releases/download/${FRIDA_VERSION}/frida-server-${FRIDA_VERSION}-android-x86_64.xz"
wget -q "$FRIDA_SERVER_URL" -O /tmp/frida-server.xz
xz -d /tmp/frida-server.xz
chmod +x /tmp/frida-server

# The frida-server binary will be pushed to the emulator after it boots
mkdir -p /home/ubuntu/frida
mv /tmp/frida-server /home/ubuntu/frida/frida-server
log "Frida server saved to /home/ubuntu/frida/frida-server"

# ---------------------------------------------------------------------------
# 5. Create helper script to push frida-server to emulator
# ---------------------------------------------------------------------------
cat > /home/ubuntu/push_frida.sh << 'FRIDA_SCRIPT'
#!/bin/bash
# Push frida-server to a running emulator
adb wait-for-device
adb push /home/ubuntu/frida/frida-server /data/local/tmp/frida-server
adb shell chmod 755 /data/local/tmp/frida-server
echo "Frida server pushed to emulator. Start with:"
echo "  adb shell su -c '/data/local/tmp/frida-server &'"
FRIDA_SCRIPT
chmod +x /home/ubuntu/push_frida.sh

# ---------------------------------------------------------------------------
# 6. Create placeholder profiler script
# ---------------------------------------------------------------------------
cat > /home/ubuntu/qa_profiler.js << 'PROFILER'
// qa_profiler.js — Frida hook for IAP/SSL monitoring
// Replace with your actual instrumentation hooks

Java.perform(function() {
    console.log("[*] QA Profiler loaded");

    // Monitor SSL pinning
    try {
        var SSLContext = Java.use("javax.net.ssl.SSLContext");
        SSLContext.init.overload(
            "[Ljavax.net.ssl.KeyManager;",
            "[Ljavax.net.ssl.TrustManager;",
            "java.security.SecureRandom"
        ).implementation = function(km, tm, sr) {
            console.log("[*] SSLContext.init called");
            this.init(km, tm, sr);
        };
    } catch(e) {
        console.log("[!] SSL hook error: " + e);
    }

    // Monitor billing flow
    try {
        var BillingClient = Java.use("com.android.vending.billing.IInAppBillingService");
        console.log("[*] Billing service class found");
    } catch(e) {
        console.log("[!] Billing class not found (expected if not Google Play billing)");
    }

    console.log("[*] QA Profiler hooks installed");
});
PROFILER

# ---------------------------------------------------------------------------
# 7. Copy qa_worker.sh
# ---------------------------------------------------------------------------
cat > /home/ubuntu/qa_worker.sh << 'WORKER'
#!/bin/bash
# qa_worker.sh - executes uat on gcp

# 1. clear previous test environments
adb emu kill || true
killall qemu-system-x86_64 || true
sleep 2

# 2. boot clean test environment
emulator -avd pixel_12 -no-window -no-audio -no-snapshot -wipe-data &
EMU_PID=$!

adb wait-for-device
while [[ -z $(adb shell getprop sys.boot_completed 2>/dev/null) ]]; do sleep 2; done

# 3. start qa telemetry server
adb push /home/ubuntu/frida/frida-server /data/local/tmp/frida-server 2>/dev/null || true
adb shell chmod 755 /data/local/tmp/frida-server
adb shell su -c '/data/local/tmp/frida-server &'
sleep 2

# 4. launch target application
# replace with your target package
adb shell monkey -p com.target.application -c android.intent.category.LAUNCHER 1
sleep 10

# 5. inject network/ssl profiling script
# replace qa_profiler.js with your specific hook script
frida -U -n TargetApp -l /home/ubuntu/qa_profiler.js &
FRIDA_PID=$!
sleep 5

# 6. simulate user interaction (uat)
# adjust coordinates for your specific avd resolution
# simulate tap on 'checkout'
adb shell input tap 500 1500
sleep 3
# simulate tap on 'confirm'
adb shell input tap 500 1800
sleep 5

# 7. teardown test environment
kill $FRIDA_PID
adb emu kill
exit 0
WORKER
chmod +x /home/ubuntu/qa_worker.sh

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "=== GCP VM Setup Complete ==="
log "Android SDK: $ANDROID_SDK_ROOT"
log "AVD: pixel_12"
log "Frida server: /home/ubuntu/frida/frida-server"
log "QA worker: /home/ubuntu/qa_worker.sh"
log ""
log "Next steps:"
log "  1. Push frida-server to emulator: bash /home/ubuntu/push_frida.sh"
log "  2. Test emulator: emulator -avd pixel_12 -no-window -no-audio &"
log "  3. Update target package in /home/ubuntu/qa_worker.sh"
