#!/bin/bash
# gcp_firewall_setup.sh — Configure GCP firewall rules for SSH access
#
# This script creates/updates GCP firewall rules to allow SSH (port 22)
# from Railway (and other sources) to your GCP VM.
#
# Usage:
#   # From your local machine or Cloud Shell (requires gcloud auth):
#   bash scripts/gcp_firewall_setup.sh
#
#   # With custom settings:
#   bash scripts/gcp_firewall_setup.sh --vm android-frida-vm --zone europe-west1-b
#
# Prerequisites:
#   - gcloud CLI authenticated with appropriate permissions
#   - Compute Engine API enabled

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info()  { echo -e "        $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
VM_NAME="${VM_NAME:-android-frida-vm}"
ZONE="${ZONE:-europe-west1-b}"
NETWORK_TAG="allow-ssh"
FIREWALL_RULE_NAME="allow-ssh-ingress"
# Railway doesn't publish static IPs, so we allow all sources.
# Restrict with ALLOWED_CHAT_IDS on the bot level instead.
SOURCE_RANGES="0.0.0.0/0"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)       VM_NAME="$2"; shift 2 ;;
        --zone)     ZONE="$2"; shift 2 ;;
        --source)   SOURCE_RANGES="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--vm <name>] [--zone <zone>] [--source <cidr>]"
            echo ""
            echo "  --vm      VM instance name (default: android-frida-vm)"
            echo "  --zone    GCP zone (default: europe-west1-b)"
            echo "  --source  Source IP ranges for SSH (default: 0.0.0.0/0)"
            exit 0
            ;;
        *) fail "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=== GCP Firewall Setup for SSH ===${NC}"
echo ""

step "Checking gcloud authentication..."
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1; then
    fail "No active gcloud account. Run: gcloud auth login"
    exit 1
fi
ok "gcloud authenticated"

step "Checking project..."
PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
    fail "No project set. Run: gcloud config set project YOUR_PROJECT_ID"
    exit 1
fi
ok "Project: $PROJECT"

# ---------------------------------------------------------------------------
# 1. Check VM exists and get current state
# ---------------------------------------------------------------------------
step "Checking VM '$VM_NAME' in zone '$ZONE'..."
VM_STATUS=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" \
    --format="value(status)" 2>/dev/null || echo "NOT_FOUND")

if [ "$VM_STATUS" = "NOT_FOUND" ]; then
    fail "VM '$VM_NAME' not found in zone '$ZONE'"
    info "List VMs: gcloud compute instances list"
    exit 1
elif [ "$VM_STATUS" = "RUNNING" ]; then
    ok "VM is RUNNING"
elif [ "$VM_STATUS" = "TERMINATED" ] || [ "$VM_STATUS" = "STOPPED" ]; then
    warn "VM is $VM_STATUS — starting it..."
    gcloud compute instances start "$VM_NAME" --zone="$ZONE"
    ok "VM start command sent"
else
    warn "VM status: $VM_STATUS"
fi

# Get current external IP
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" \
    --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null || echo "")

if [ -n "$EXTERNAL_IP" ]; then
    ok "External IP: $EXTERNAL_IP"
else
    warn "No external IP found — VM may need an access config"
    info "Fix: gcloud compute instances add-access-config $VM_NAME --zone=$ZONE"
fi

# ---------------------------------------------------------------------------
# 2. Create/update firewall rule
# ---------------------------------------------------------------------------
step "Configuring firewall rule '$FIREWALL_RULE_NAME'..."

EXISTING_RULE=$(gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
    --format="value(name)" 2>/dev/null || echo "")

if [ -n "$EXISTING_RULE" ]; then
    info "Rule already exists — updating..."
    gcloud compute firewall-rules update "$FIREWALL_RULE_NAME" \
        --source-ranges="$SOURCE_RANGES" \
        --rules=tcp:22 2>/dev/null
    ok "Firewall rule updated"
else
    gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
        --direction=INGRESS \
        --priority=1000 \
        --action=ALLOW \
        --rules=tcp:22 \
        --source-ranges="$SOURCE_RANGES" \
        --target-tags="$NETWORK_TAG" \
        --description="Allow SSH from Railway bot to QA VM"
    ok "Firewall rule created"
fi

# ---------------------------------------------------------------------------
# 3. Add network tag to VM
# ---------------------------------------------------------------------------
step "Adding network tag '$NETWORK_TAG' to VM..."
CURRENT_TAGS=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" \
    --format="value(tags.items)" 2>/dev/null || echo "")

if echo "$CURRENT_TAGS" | grep -q "$NETWORK_TAG"; then
    ok "Tag '$NETWORK_TAG' already present"
else
    gcloud compute instances add-tags "$VM_NAME" \
        --zone="$ZONE" \
        --tags="$NETWORK_TAG"
    ok "Tag added"
fi

# ---------------------------------------------------------------------------
# 4. Verify SSH service on VM
# ---------------------------------------------------------------------------
step "Verifying SSH service on VM..."
SSH_CHECK=$(gcloud compute ssh "$VM_NAME" \
    --zone="$ZONE" \
    --command="systemctl is-active sshd || systemctl is-active ssh" \
    --quiet 2>/dev/null || echo "FAILED")

if [ "$SSH_CHECK" = "active" ]; then
    ok "SSH service is active on VM"
else
    warn "Could not verify SSH service (may need manual check)"
    info "Try: gcloud compute ssh $VM_NAME --zone=$ZONE -- 'sudo systemctl restart sshd'"
fi

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}=== Setup Complete ===${NC}"
echo ""
echo -e "  VM:            $VM_NAME"
echo -e "  Zone:          $ZONE"
echo -e "  External IP:   ${EXTERNAL_IP:-unknown}"
echo -e "  Firewall Rule: $FIREWALL_RULE_NAME (allow TCP:22 from $SOURCE_RANGES)"
echo -e "  Network Tag:   $NETWORK_TAG"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Verify GCP_IP in Railway matches: $EXTERNAL_IP"
echo "  2. Test from bot: send /diagnose or /status"
echo "  3. If IP changed, update Railway env: GCP_IP=$EXTERNAL_IP"
echo ""

if [ -n "$EXTERNAL_IP" ]; then
    echo -e "${BLUE}Quick SSH test:${NC}"
    echo "  ssh ubuntu@$EXTERNAL_IP -o ConnectTimeout=10 'echo SSH OK'"
fi
