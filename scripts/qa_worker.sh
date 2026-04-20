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
