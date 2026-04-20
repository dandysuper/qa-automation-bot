#!/bin/bash
# multi_instance_runner.sh — Run QA suites in parallel across multiple AVD instances
#
# Usage:
#   bash scripts/multi_instance_runner.sh [--instances 3] [--plans "trial,1-month,6-month"]
#   bash scripts/multi_instance_runner.sh --instances 2 --plans "1-month,12-month"
#
# Each instance gets its own AVD clone and runs independently.
# Results are aggregated at the end.

set -uo pipefail

# ---------------------------------------------------------------------------
# Color output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${BLUE}[Runner]${NC} $*"; }
ok()   { echo -e "${GREEN}[Runner]${NC} $*"; }
fail() { echo -e "${RED}[Runner]${NC} $*"; }
warn() { echo -e "${YELLOW}[Runner]${NC} $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NUM_INSTANCES=1
PLANS=""
RESULTS_DIR="/home/ubuntu/qa_results_$(date +%s)"
PIDS=()
EXIT_CODES=()

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instances)
            NUM_INSTANCES="$2"
            shift 2
            ;;
        --plans)
            PLANS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--instances <N>] [--plans 'plan1,plan2,...']"
            echo ""
            echo "  --instances  Number of parallel AVD instances (default: 1)"
            echo "  --plans      Comma-separated plan names to test"
            echo ""
            echo "Examples:"
            echo "  $0 --instances 3 --plans 'trial,1-month,12-month'"
            echo "  $0 --instances 2"
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Split plans into array
IFS=',' read -ra PLAN_ARRAY <<< "$PLANS"

# If more plans than instances, use plan count
if [ ${#PLAN_ARRAY[@]} -gt "$NUM_INSTANCES" ] && [ ${#PLAN_ARRAY[@]} -gt 0 ]; then
    NUM_INSTANCES=${#PLAN_ARRAY[@]}
fi

mkdir -p "$RESULTS_DIR"

# ---------------------------------------------------------------------------
# Launch instances
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Multi-Instance QA Runner${NC}"
echo -e "${BOLD} $(date '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BOLD} Instances: $NUM_INSTANCES${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""

for i in $(seq 0 $((NUM_INSTANCES - 1))); do
    PLAN_ARG=""
    if [ $i -lt ${#PLAN_ARRAY[@]} ] && [ -n "${PLAN_ARRAY[$i]:-}" ]; then
        PLAN_ARG="--plan ${PLAN_ARRAY[$i]}"
        log "Instance $i: plan=${PLAN_ARRAY[$i]}"
    else
        log "Instance $i: default plan"
    fi

    LOG_FILE="${RESULTS_DIR}/instance_${i}.log"

    bash "${SCRIPT_DIR}/qa_worker.sh" \
        --instance "$i" \
        $PLAN_ARG \
        > "$LOG_FILE" 2>&1 &

    PIDS+=($!)
    log "  Started PID: ${PIDS[$i]} → $LOG_FILE"
done

# ---------------------------------------------------------------------------
# Wait for all instances
# ---------------------------------------------------------------------------
log ""
log "Waiting for all instances to complete..."

TOTAL_ERRORS=0
for i in $(seq 0 $((NUM_INSTANCES - 1))); do
    wait "${PIDS[$i]}" 2>/dev/null
    EXIT_CODES+=($?)

    if [ ${EXIT_CODES[$i]} -eq 0 ]; then
        ok "Instance $i: PASSED"
    else
        fail "Instance $i: FAILED (exit code ${EXIT_CODES[$i]})"
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    fi
done

# ---------------------------------------------------------------------------
# Aggregate results
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} Results Summary${NC}"
echo -e "${BOLD}========================================${NC}"

for i in $(seq 0 $((NUM_INSTANCES - 1))); do
    PLAN_LABEL="default"
    if [ $i -lt ${#PLAN_ARRAY[@]} ] && [ -n "${PLAN_ARRAY[$i]:-}" ]; then
        PLAN_LABEL="${PLAN_ARRAY[$i]}"
    fi

    if [ ${EXIT_CODES[$i]} -eq 0 ]; then
        echo -e "  Instance $i (${PLAN_LABEL}): ${GREEN}PASSED${NC}"
    else
        echo -e "  Instance $i (${PLAN_LABEL}): ${RED}FAILED${NC}"
    fi
done

echo ""
echo -e "  Total: $NUM_INSTANCES | Passed: $((NUM_INSTANCES - TOTAL_ERRORS)) | Failed: $TOTAL_ERRORS"
echo -e "  Logs:  $RESULTS_DIR/"
echo ""

if [ $TOTAL_ERRORS -gt 0 ]; then
    fail "$TOTAL_ERRORS instance(s) failed"
    exit 1
else
    ok "All instances passed"
    exit 0
fi
