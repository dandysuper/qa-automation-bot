#!/usr/bin/env bash
# ============================================================================
# ui_mapper.sh — Dump UI hierarchy and extract element coordinates
#
# Uses uiautomator to dump the current screen's XML and parses it to find
# clickable elements with their coordinates. Useful for mapping tap targets
# before writing automation scripts.
#
# Usage:
#   bash ui_mapper.sh                     # dump all clickable elements
#   bash ui_mapper.sh "button text"       # find specific element
#   bash ui_mapper.sh --save <filename>   # save full XML dump
# ============================================================================
set -euo pipefail

SEARCH_TEXT="${1:-}"
SAVE_FILE="${2:-}"

log() {
    echo "[ui_mapper] $(date -u +%H:%M:%S) $*"
}

# ---------------------------------------------------------------------------
# Dump UI hierarchy
# ---------------------------------------------------------------------------
log "Dumping UI hierarchy..."
adb shell uiautomator dump /sdcard/ui_dump.xml 2>/dev/null
sleep 1

XML_CONTENT=$(adb shell cat /sdcard/ui_dump.xml 2>/dev/null)

if [ -z "${XML_CONTENT}" ]; then
    log "ERROR: UI dump returned empty content"
    exit 1
fi

# Save full dump if requested
if [ "${SEARCH_TEXT}" = "--save" ] && [ -n "${SAVE_FILE}" ]; then
    echo "${XML_CONTENT}" > "${SAVE_FILE}"
    log "Full UI dump saved to ${SAVE_FILE}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Parse and display elements
# ---------------------------------------------------------------------------
if [ -n "${SEARCH_TEXT}" ]; then
    log "Searching for elements containing: '${SEARCH_TEXT}'"
    echo "${XML_CONTENT}" | grep -oP 'node[^/]*' | while IFS= read -r node; do
        text=$(echo "${node}" | grep -oP 'text="\K[^"]*' || true)
        desc=$(echo "${node}" | grep -oP 'content-desc="\K[^"]*' || true)
        bounds=$(echo "${node}" | grep -oP 'bounds="\K[^"]*' || true)
        clickable=$(echo "${node}" | grep -oP 'clickable="\K[^"]*' || true)

        if echo "${text}${desc}" | grep -qi "${SEARCH_TEXT}"; then
            # Parse bounds [x1,y1][x2,y2] to center coordinates
            if [ -n "${bounds}" ]; then
                coords=$(echo "${bounds}" | sed 's/\]\[/,/g; s/\[//g; s/\]//g')
                x1=$(echo "${coords}" | cut -d',' -f1)
                y1=$(echo "${coords}" | cut -d',' -f2)
                x2=$(echo "${coords}" | cut -d',' -f3)
                y2=$(echo "${coords}" | cut -d',' -f4)
                cx=$(( (x1 + x2) / 2 ))
                cy=$(( (y1 + y2) / 2 ))

                echo "  MATCH: text=\"${text}\" desc=\"${desc}\""
                echo "         bounds=${bounds} center=(${cx}, ${cy}) clickable=${clickable}"
            fi
        fi
    done
else
    log "Listing all clickable elements:"
    echo "${XML_CONTENT}" | grep -oP 'node[^/]*' | while IFS= read -r node; do
        clickable=$(echo "${node}" | grep -oP 'clickable="\K[^"]*' || true)
        if [ "${clickable}" = "true" ]; then
            text=$(echo "${node}" | grep -oP 'text="\K[^"]*' || true)
            desc=$(echo "${node}" | grep -oP 'content-desc="\K[^"]*' || true)
            bounds=$(echo "${node}" | grep -oP 'bounds="\K[^"]*' || true)
            class=$(echo "${node}" | grep -oP 'class="\K[^"]*' || true)

            if [ -n "${bounds}" ]; then
                coords=$(echo "${bounds}" | sed 's/\]\[/,/g; s/\[//g; s/\]//g')
                x1=$(echo "${coords}" | cut -d',' -f1)
                y1=$(echo "${coords}" | cut -d',' -f2)
                x2=$(echo "${coords}" | cut -d',' -f3)
                y2=$(echo "${coords}" | cut -d',' -f4)
                cx=$(( (x1 + x2) / 2 ))
                cy=$(( (y1 + y2) / 2 ))

                label="${text:-${desc:-${class}}}"
                echo "  [${cx}, ${cy}] ${label}  (${bounds})"
            fi
        fi
    done
fi

# Cleanup
adb shell rm -f /sdcard/ui_dump.xml 2>/dev/null || true
log "Done"
