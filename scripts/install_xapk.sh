#!/usr/bin/env bash
# ============================================================================
# install_xapk.sh — Extract and install multi-APK (XAPK) packages
#
# XAPK files are ZIP archives containing a base APK and one or more split
# APKs. This script handles extraction and installation via adb install-multiple.
#
# Usage:
#   bash install_xapk.sh <path_to_xapk_or_apk>
#
# Supports:
#   .xapk  → unzip + adb install-multiple
#   .apk   → adb install -r -g
#   .apks  → unzip + adb install-multiple
# ============================================================================
set -euo pipefail

APP_PATH="${1:?Usage: install_xapk.sh <path_to_xapk_or_apk>}"

log() {
    echo "[install_xapk] $(date -u +%H:%M:%S) $*"
}

# ---------------------------------------------------------------------------
# Detect format and install
# ---------------------------------------------------------------------------
EXT="${APP_PATH##*.}"
EXT_LOWER=$(echo "${EXT}" | tr '[:upper:]' '[:lower:]')

case "${EXT_LOWER}" in
    apk)
        log "Single APK detected: ${APP_PATH}"
        adb install -r -g "${APP_PATH}"
        log "APK installed successfully"
        ;;

    xapk|apks)
        log "Multi-APK archive detected (${EXT_LOWER}): ${APP_PATH}"

        EXTRACT_DIR=$(mktemp -d "/tmp/xapk_extract_XXXXXX")
        trap 'rm -rf "${EXTRACT_DIR}"' EXIT

        log "Extracting to ${EXTRACT_DIR}"
        unzip -q -o "${APP_PATH}" -d "${EXTRACT_DIR}"

        # Collect all .apk files from the extracted archive
        APK_FILES=()
        while IFS= read -r -d '' apk; do
            APK_FILES+=("${apk}")
        done < <(find "${EXTRACT_DIR}" -name "*.apk" -type f -print0 | sort -z)

        if [ "${#APK_FILES[@]}" -eq 0 ]; then
            log "ERROR: No APK files found inside ${APP_PATH}"
            exit 1
        fi

        log "Found ${#APK_FILES[@]} APK(s):"
        for apk in "${APK_FILES[@]}"; do
            log "  - $(basename "${apk}") ($(du -h "${apk}" | cut -f1))"
        done

        # Install all APKs at once
        log "Running adb install-multiple..."
        adb install-multiple -r -g "${APK_FILES[@]}"

        log "Multi-APK installation completed successfully"
        ;;

    *)
        log "ERROR: Unsupported file format '.${EXT_LOWER}'"
        log "Supported formats: .apk, .xapk, .apks"
        exit 1
        ;;
esac

# Verify installation if TARGET_PACKAGE is set
if [ -n "${TARGET_PACKAGE:-}" ]; then
    if adb shell pm list packages 2>/dev/null | grep -q "${TARGET_PACKAGE}"; then
        log "Verified: ${TARGET_PACKAGE} is installed"
    else
        log "WARNING: ${TARGET_PACKAGE} not found in package list after install"
    fi
fi
