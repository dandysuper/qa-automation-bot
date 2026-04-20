#!/bin/bash
# frida_service.sh — Persistent frida-server manager
#
# Runs frida-server as a supervised process that auto-restarts on crash or
# emulator reboot. Designed to be run via systemd or as a background daemon.
#
# Usage:
#   bash scripts/frida_service.sh [--install-systemd]
#   bash scripts/frida_service.sh --start
#   bash scripts/frida_service.sh --stop
#   bash scripts/frida_service.sh --status
#
# As systemd service:
#   sudo bash scripts/frida_service.sh --install-systemd
#   sudo systemctl start frida-server
#   sudo systemctl enable frida-server

set -uo pipefail

FRIDA_SERVER="/home/ubuntu/frida/frida-server"
FRIDA_DEVICE_PATH="/data/local/tmp/frida-server"
CHECK_INTERVAL=10
MAX_RESTART_ATTEMPTS=5
PID_FILE="/tmp/frida_service.pid"
LOG_FILE="/home/ubuntu/frida_service.log"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/home/ubuntu/android-sdk}"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$PATH"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# ---------------------------------------------------------------------------
# Systemd unit installation
# ---------------------------------------------------------------------------
install_systemd() {
    local unit_file="/etc/systemd/system/frida-server.service"
    local script_path
    script_path="$(realpath "$0")"

    cat > "$unit_file" << EOF
[Unit]
Description=Frida Server Manager for Android Emulator
After=network.target

[Service]
Type=simple
User=ubuntu
ExecStart=/bin/bash $script_path --daemon
Restart=always
RestartSec=10
Environment=ANDROID_SDK_ROOT=/home/ubuntu/android-sdk

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ok "Systemd unit installed at $unit_file"
    echo "  Start:  sudo systemctl start frida-server"
    echo "  Enable: sudo systemctl enable frida-server"
    echo "  Status: sudo systemctl status frida-server"
    echo "  Logs:   journalctl -u frida-server -f"
}

# ---------------------------------------------------------------------------
# Check if emulator is running and frida-server is alive
# ---------------------------------------------------------------------------
is_emulator_running() {
    adb devices 2>/dev/null | grep -q "emulator"
}

is_frida_running() {
    adb shell "ps -A 2>/dev/null" | grep -q "frida-server"
}

push_and_start_frida() {
    log "Pushing frida-server to device..."
    adb push "$FRIDA_SERVER" "$FRIDA_DEVICE_PATH" 2>/dev/null
    adb shell chmod 755 "$FRIDA_DEVICE_PATH" 2>/dev/null

    log "Starting frida-server on device..."
    adb shell "su -c 'killall frida-server 2>/dev/null; nohup $FRIDA_DEVICE_PATH > /dev/null 2>&1 &'" 2>/dev/null
    sleep 2

    if is_frida_running; then
        log "frida-server started successfully"
        return 0
    else
        log "Failed to start frida-server"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Daemon loop — monitors and restarts frida-server
# ---------------------------------------------------------------------------
run_daemon() {
    log "Frida service daemon started (PID: $$)"
    echo $$ > "$PID_FILE"

    local restart_count=0

    while true; do
        if is_emulator_running; then
            if ! is_frida_running; then
                restart_count=$((restart_count + 1))
                log "frida-server not running (restart attempt $restart_count/$MAX_RESTART_ATTEMPTS)"

                if [ $restart_count -le $MAX_RESTART_ATTEMPTS ]; then
                    push_and_start_frida
                else
                    log "Max restart attempts reached — waiting for manual intervention"
                    sleep 60
                    restart_count=0
                fi
            else
                # Reset counter on successful running state
                restart_count=0
            fi
        else
            restart_count=0
        fi

        sleep "$CHECK_INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# Status check
# ---------------------------------------------------------------------------
show_status() {
    echo "=== Frida Service Status ==="

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        ok "Service daemon running (PID: $(cat "$PID_FILE"))"
    else
        warn "Service daemon not running"
    fi

    if is_emulator_running; then
        ok "Android emulator detected"
    else
        warn "No Android emulator running"
    fi

    if is_emulator_running && is_frida_running; then
        ok "frida-server running on device"
    elif is_emulator_running; then
        fail "frida-server NOT running on device"
    else
        echo "  (cannot check frida — no emulator)"
    fi
}

# ---------------------------------------------------------------------------
# Stop daemon
# ---------------------------------------------------------------------------
stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
            ok "Daemon stopped (PID: $pid)"
        else
            rm -f "$PID_FILE"
            warn "Daemon was not running (stale PID file removed)"
        fi
    else
        warn "No PID file found — daemon may not be running"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    --install-systemd)
        install_systemd
        ;;
    --daemon)
        run_daemon
        ;;
    --start)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            warn "Daemon already running (PID: $(cat "$PID_FILE"))"
        else
            echo "Starting frida service daemon in background..."
            nohup bash "$0" --daemon >> "$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
            ok "Daemon started (PID: $!)"
        fi
        ;;
    --stop)
        stop_daemon
        ;;
    --status)
        show_status
        ;;
    -h|--help|*)
        echo "Usage: $0 [--install-systemd|--start|--stop|--status|--daemon]"
        echo ""
        echo "  --install-systemd  Install as a systemd service"
        echo "  --start            Start the daemon in background"
        echo "  --stop             Stop the daemon"
        echo "  --status           Show current status"
        echo "  --daemon           Run in foreground (used by systemd)"
        ;;
esac
