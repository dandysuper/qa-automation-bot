# QA Automation Bot

Remote QA Automation & IAP Validation Framework. A Telegram bot hosted on [Railway](https://railway.com) that triggers Android in-app purchase (IAP) UI flow testing on a GCP VM.

## Current Status

| Component | Status | Details |
|-----------|--------|---------|
| **Telegram Bot** | ✅ Live | Deployed on Railway, responding to commands |
| **GCP VM** | ✅ Running | `n1-standard-4` in `europe-west1-b` (IP: `34.79.0.196`) |
| **Android SDK** | ✅ Installed | SDK, emulator, platform-tools on GCP VM |
| **AVD (pixel_12)** | ✅ Created | `system-images;android-32;google_apis;x86_64` |
| **Frida** | ✅ Installed | frida-tools + frida-server binary for Android x86_64 |
| **SSH Bot → GCP** | ⚠️ Needs Testing | Verify with `/status` after Railway redeploy |
| **Target App** | ❌ Not Set | Still using placeholder `com.target.application` |
| **Full QA Flow** | ❌ Not Tested | Needs SSH working + target app configured |

## What Needs Fixing

### 1. Verify SSH Connectivity (Priority: High)
The bot was hitting a **409 conflict** (multiple polling instances) and SSH timeouts. Both issues are now addressed:
- **409 fix:** Graceful SIGTERM shutdown, `delete_webhook(drop_pending_updates=True)`, configurable startup delay, and exponential backoff on 409 retries.
- **SSH fix:** Automatic retry with configurable attempts (`SSH_RETRIES`) and exponential backoff (`SSH_RETRY_DELAY`).
- Send `/diagnose` to the bot for full network diagnostics (DNS, TCP port, SSH auth)
- Send `/status` to the bot on Telegram
- If it shows "GCP node reachable", SSH is working
- If SSH times out, run the firewall setup script:

```bash
# From Cloud Shell or local machine with gcloud:
bash scripts/gcp_firewall_setup.sh

# Or manually:
gcloud compute firewall-rules create allow-ssh-ingress \
  --direction=INGRESS --action=ALLOW \
  --rules=tcp:22 --source-ranges=0.0.0.0/0 \
  --target-tags=allow-ssh

gcloud compute instances add-tags android-frida-vm \
  --zone=europe-west1-b --tags=allow-ssh
```

Also verify the VM's external IP hasn't changed:
```bash
gcloud compute instances describe android-frida-vm \
  --zone=europe-west1-b \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```
If it differs from the `GCP_IP` in Railway, update it.

### 2. Configure Target Application (Priority: Medium)
Update `config/subscription_plans.json` with your app details:
- Set `target_package` to your actual Android package name
- Set `target_process` to the app's process name (for Frida)
- Configure offer tokens for each subscription plan
- Adjust tap coordinates in `scripts/qa_worker.sh` for your app's checkout UI
- Install your target APK: `bash scripts/setup_emulator.sh --apk /path/to/app.apk`

### 3. Frida Profiler Script (Priority: Done)
Enhanced Frida hooks are now implemented in `scripts/frida/`:
- `qa_profiler.js` — Appdome bypass, SSL pinning bypass, billing flow interception, network monitoring
- `subscription_hooks.js` — Trial detection, OfferId injection, purchase flow logging

## What to Test

### Step 1: Bot Connectivity
```
/status          → Should show "GCP node reachable" with uptime
```

### Step 2: Remote Commands
```
/run whoami      → Should return "ubuntu" (or your GCP_USER)
/run uname -a    → Should return Linux kernel info
/emulator        → Shows if any AVD is running
```

### Step 3: Emulator Boot
```
/run emulator -avd pixel_12 -no-window -no-audio -no-snapshot &
/emulator        → Should show emulator process running
```

### Step 4: Full QA Suite (after configuring target app)
```
/test_iap        → Runs full qa_worker.sh flow
/logs            → Check output of last run
```

## Architecture

```
Telegram ──> Railway (this bot) ──SSH──> GCP VM (Android emulator + Frida)
```

- **Trigger Node (Railway):** Python Telegram bot — acts as the CI/CD trigger.
- **Execution Node (GCP):** n1-standard-4 VM in europe-west1-b with nested virtualization.
- **Target:** Configurable Android APK.

## Execution Flow

1. Dev sends `/test_iap` (or `/test_iap chatgpt-plus-monthly`) to the Telegram bot.
2. Railway bot SSH-execs into GCP.
3. GCP worker loads emulator snapshot (or boots fresh AVD).
4. Script launches ChatGPT, injects Frida hooks for SSL bypass, billing interception, and Appdome bypass.
5. ADB simulates subscription UI taps (configurable coordinates from `subscription_plans.json`).
6. Results are piped back to Telegram.

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` `/help` | Show available commands |
| `/test_iap` | Run the full IAP validation QA suite on GCP |
| `/test_iap <plan>` | Run with specific plan (e.g. `chatgpt-plus-monthly`) |
| `/run_iap_test <email> <pass> [mock]` | Containerized IAP test in disposable Docker environment |
| `/upload_apk` | Upload APK/XAPK file to GCP via Telegram (reply to file) |
| `/status` | Check GCP node connectivity |
| `/diagnose` | Run network diagnostics (DNS, TCP port, SSH auth) |
| `/install_apk <url>` | Download & install APK on emulator |
| `/snapshot save <name>` | Save current emulator state as snapshot |
| `/snapshot load <name>` | Load a saved emulator snapshot |
| `/snapshot list` | List available snapshots |
| `/run <cmd>` | Execute a custom command on GCP |
| `/logs` | Fetch last 50 lines of QA worker log |
| `/emulator` | Check emulator status on GCP |

## Setup

### 1. Prerequisites

- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- A GCP VM (n1-standard-4 recommended) with:
  - Nested virtualization enabled
  - Android SDK / emulator installed
  - AVD configured (name: `pixel_12`)
  - Frida server binary at `/home/ubuntu/frida/frida-server`
  - SSH access with key-based auth

### 2. GCP VM Setup

Run the automated setup script on your GCP VM:

```bash
# From Cloud Shell:
gcloud compute ssh android-frida-vm --zone=europe-west1-b -- 'bash -s' < scripts/gcp_vm_setup.sh

# Or SSH in manually and run:
bash scripts/gcp_vm_setup.sh
```

This installs Android SDK, emulator, AVD (pixel_12), Frida server, and helper scripts.

After setup, push Frida server to the emulator:
```bash
bash /home/ubuntu/push_frida.sh
```

### 3. Deploy to Railway

#### Option A: Railway Dashboard

1. Push this repo to GitHub (private).
2. Go to [railway.com](https://railway.com) → New Project → Deploy from GitHub repo.
3. Add environment variables (see below).
4. Railway auto-deploys on push.

#### Option B: Railway CLI

```bash
npm install -g @railway/cli
railway login
railway init
railway up
```

### 4. Environment Variables

Set these in Railway dashboard (Settings → Variables):

| Variable | Required | Description |
|----------|----------|-------------|
| `TG_TOKEN` | Yes | Telegram bot token from BotFather |
| `GCP_IP` | Yes | GCP VM public IP address |
| `GCP_USER` | No | SSH username (default: `ubuntu`) |
| `GCP_PORT` | No | SSH port (default: `22`) |
| `SSH_PRIVATE_KEY_B64` | Yes | Base64-encoded SSH private key |
| `ALLOWED_CHAT_IDS` | No | Comma-separated Telegram chat IDs (empty = open access) |
| `QA_WORKER_SCRIPT` | No | Path to worker script on GCP (default: `/home/ubuntu/qa_worker.sh`) |
| `SSH_TIMEOUT` | No | SSH connection timeout in seconds (default: `60`) |
| `COMMAND_TIMEOUT` | No | Remote command timeout in seconds (default: `600`) |
| `SSH_RETRIES` | No | Number of SSH connection attempts before failing (default: `3`) |
| `SSH_RETRY_DELAY` | No | Base delay in seconds between SSH retries (default: `5`) |
| `STARTUP_DELAY` | No | Seconds to wait before polling to avoid 409 conflicts (default: `3`) |
| `DOCKER_IMAGE` | No | Golden image for containerized IAP tests (default: `qa-avd-golden:latest`) |
| `QA_DATA_VOLUME` | No | Persistent data volume path on GCP (default: `/mnt/qa-data`) |
| `TARGET_PACKAGE` | No | Target app package name (default: `com.yourcompany.app`) |
| `TARGET_APK_PATH` | No | Path to staging APK on GCP (default: `/mnt/qa-data/app-staging.apk`) |
| `IAP_TEST_TIMEOUT` | No | Timeout for containerized IAP tests in seconds (default: `900`) |

#### Encoding your SSH key

```bash
cat ~/.ssh/your_key | base64 -w 0
```

Copy the output and paste it as the `SSH_PRIVATE_KEY_B64` value in Railway.

## Local Development

```bash
# Clone the repo
git clone https://github.com/dandysuper/qa-automation-bot.git
cd qa-automation-bot

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Copy and fill in environment variables
cp .env.example .env
# Edit .env with your values

# Run the bot
source .env
python bot.py
```

## Docker

```bash
docker build -t qa-bot .
docker run --env-file .env qa-bot
```

## Project Structure

```
qa-automation-bot/
├── bot.py                        # Main Telegram bot (runs on Railway)
├── scripts/
│   ├── qa_worker.sh              # Enhanced GCP worker with color output & logging
│   ├── gcp_vm_setup.sh           # One-shot GCP VM setup script
│   ├── setup_emulator.sh         # Automated emulator setup (APK, Frida, root)
│   ├── frida_service.sh          # Persistent frida-server manager (systemd)
│   ├── multi_instance_runner.sh  # Parallel AVD instance runner
│   ├── gcp_firewall_setup.sh     # GCP firewall rules for SSH access
│   ├── setup_session.sh          # Container lifecycle script (7-phase flow)
│   ├── hook_1m.js                # Frida instrumentation for billing mocks
│   ├── install_xapk.sh           # Multi-APK (XAPK/APKS) installer
│   ├── login_automation.py       # Google account login automation via ADB
│   ├── ui_mapper.sh              # UI element coordinate mapper (uiautomator)
│   └── frida/
│       ├── qa_profiler.js        # Enhanced Frida hooks (Appdome, SSL, billing)
│       └── subscription_hooks.js # Subscription state detection & OfferId injection
├── config/
│   └── subscription_plans.json   # Configurable subscription plan mapping
├── .github/
│   └── workflows/
│       └── qa-tests.yml          # CI/CD pipeline (lint, docker, integration)
├── requirements.txt              # Python dependencies
├── Procfile                      # Railway process definition
├── railway.toml                  # Railway deployment config
├── nixpacks.toml                 # Nixpacks build config
├── docker/
│   ├── Dockerfile.golden         # Golden image: Android 12 AVD + Frida + SDK
│   └── docker-compose.yml        # Container orchestration for QA sessions
├── Dockerfile                    # Docker build (alternative)
├── .env.example                  # Environment variable template
├── .gitignore                    # Git ignore rules
└── README.md                     # This file
```

## ChatGPT IAP Testing Workflow

Complete step-by-step guide for testing ChatGPT's in-app purchase flow:

### Step 1: Install ChatGPT APK on Emulator
```bash
# From Telegram — download and install directly:
/install_apk https://example.com/chatgpt.apk

# Or from GCP VM manually:
/run wget -O ~/chatgpt.apk "https://apkpure.com/apk/com.openai.chatgpt/download"
/run adb install -r -g ~/chatgpt.apk

# Verify installation:
/run adb shell pm list packages | grep com.openai.chatgpt
```

### Step 2: Configure Google Play Account
```bash
# Boot emulator (fresh):
/run bash scripts/setup_emulator.sh --no-wipe

# Manually log into Google Play on the emulator (use VNC or scrcpy)
# Then save the logged-in state as a snapshot:
/snapshot save chatgpt_logged_in
```

### Step 3: Run IAP Test
```bash
# Run with the saved snapshot and a specific plan:
/test_iap chatgpt-plus-monthly

# Or run from GCP directly with custom Frida hooks:
/run bash scripts/qa_worker.sh --snapshot chatgpt_logged_in --plan chatgpt-plus-monthly --frida-script /home/ubuntu/custom_hook.js
```

### Step 4: Review Results
```bash
# Check execution logs:
/logs

# Verify Frida hooks were injected:
/run frida-ps -U | grep chatgpt
```

### Tap Coordinates
The UI tap coordinates for ChatGPT are configured in `config/subscription_plans.json` under `tap_coordinates`. Adjust these values based on your emulator screen resolution:
```json
{
  "tap_coordinates": {
    "settings_menu": [980, 160],
    "subscription_menu": [540, 600],
    "upgrade_button": [540, 1700],
    "plan_select": [540, 900],
    "subscribe_confirm": [540, 1800]
  }
}
```

### Example Full Session
```
/install_apk ~/chatgpt.apk          → Install ChatGPT APK
/snapshot save chatgpt_logged_in     → Save Google Play logged-in state
/test_iap chatgpt-plus-monthly      → Run IAP test with Plus monthly plan
/logs                                → Review execution output
```

## Enhanced Features

### Security Countermeasures

#### Appdome / libpairipcore.so Bypass
The enhanced `scripts/frida/qa_profiler.js` includes an obfuscated Appdome bypass that:
- Uses hex-encoded library name to avoid static string detection
- Neutralizes all exported functions with architecture-appropriate NOP+RET sequences (ARM64, ARM32, x86/x86_64)
- Intercepts `JNI_OnLoad` to prevent re-initialization

#### SSL Certificate Pinning Bypass
Multiple SSL pinning frameworks are bypassed simultaneously:
- `javax.net.ssl.SSLContext` (universal)
- OkHttp3 `CertificatePinner`
- Conscrypt / Android `NetworkSecurityConfig`
- `TrustManagerImpl` (Android internal)

### Subscription Management

#### Dynamic OfferId Injection
Configure subscription plans in `config/subscription_plans.json`:
```json
{
  "plans": {
    "chatgpt-plus-monthly": { "offerId": "chatgpt-plus-monthly", "offerToken": "..." },
    "chatgpt-plus-annual": { "offerId": "chatgpt-plus-annual", "offerToken": "..." },
    "chatgpt-team": { "offerId": "chatgpt-team", "offerToken": "..." }
  }
}
```

Run with a specific plan:
```bash
bash scripts/qa_worker.sh --plan chatgpt-plus-monthly
```

Or override at runtime via ADB property:
```bash
adb shell setprop qa.offer.token.override <token>
```

#### Automated Trial Detection
The `subscription_hooks.js` Frida script automatically:
- Queries active purchases via `BillingClient.queryPurchasesAsync`
- Detects trial periods from order IDs
- Logs subscription state before injection

### Environment Setup

#### Quick Emulator Setup
```bash
# Full automated setup with APK installation
bash scripts/setup_emulator.sh --apk /path/to/app.apk

# Without wiping data
bash scripts/setup_emulator.sh --avd pixel_12 --no-wipe
```

#### Frida Server Persistence
Keep frida-server running across emulator reboots:
```bash
# As a background daemon
bash scripts/frida_service.sh --start

# As a systemd service (recommended)
sudo bash scripts/frida_service.sh --install-systemd
sudo systemctl enable --now frida-server
```

### Multi-Instance Parallel Testing
Run QA suites across multiple AVD instances simultaneously:
```bash
# Test 3 plans in parallel
bash scripts/multi_instance_runner.sh --instances 3 --plans "trial,1-month,12-month"
```

### CI/CD Integration
GitHub Actions workflow (`.github/workflows/qa-tests.yml`) runs on push/PR:
- **Lint & Validate**: Python syntax, JSON config, shell script checks
- **Docker Build**: Verifies container builds correctly
- **Integration Readiness**: Checks project structure and Frida scripts

## GCP VM Details

| Property | Value |
|----------|-------|
| Instance | `android-frida-vm` |
| Zone | `europe-west1-b` |
| Machine | `n1-standard-4` (4 vCPU, 15 GB RAM) |
| OS | Ubuntu 22.04 LTS |
| Disk | 60 GB SSD |
| IP | `34.79.0.196` |
| SSH User | `ubuntu` |
| Android SDK | `/home/ubuntu/android-sdk` |
| AVD | `pixel_12` (API 32, x86_64) |
| Frida Server | `/home/ubuntu/frida/frida-server` |
| Worker Script | `/home/ubuntu/qa_worker.sh` |
| Profiler | `/home/ubuntu/qa_profiler.js` |

## Containerized IAP Testing

The containerized pipeline runs each IAP test in an isolated Docker container for clean-state testing:

### Build the Golden Image
```bash
# On GCP VM:
docker build -f docker/Dockerfile.golden -t qa-avd-golden:latest .
```

### Run a Containerized Test
```
/run_iap_test qa@example.com P@ssw0rd mock_card_visa
```

This triggers the full 7-phase flow:
1. Container boot from golden image
2. APK/XAPK installation
3. Google account login
4. Pre-warmed snapshot creation
5. Frida instrumentation injection
6. UI automation & IAP validation
7. Teardown & cleanup

### XAPK Support
Multi-APK packages (`.xapk`, `.apks`) are automatically extracted and installed:
```bash
bash scripts/install_xapk.sh /path/to/app.xapk
```

### APK Upload via Telegram
Send your APK/XAPK file to the bot, then reply with `/upload_apk` to transfer it to the GCP data volume. Files over 20 MB should be transferred directly via SCP.

### Login Automation
The `scripts/login_automation.py` script automates Google account sign-in using `uiautomator dump` for element discovery (no hardcoded coordinates).

### UI Coordinate Mapper
Use `scripts/ui_mapper.sh` to dump the screen hierarchy and find clickable element coordinates for automation scripting.

## Security Notes

- **Never commit `.env` or SSH keys** to the repository.
- Use `ALLOWED_CHAT_IDS` to restrict bot access to authorized users only.
- SSH keys are stored base64-encoded in environment variables and written to temp files only during connection, then immediately deleted.
- Consider using GCP IAM service accounts and OS Login for production deployments.
- Rotate your Telegram bot token and SSH keys periodically.

## License

Private — All rights reserved.
