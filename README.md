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
- Send `/status` to the bot on Telegram
- If it shows "GCP node reachable", SSH is working
- If it shows a timeout after all retries, check Railway logs for the detailed error

### 2. Configure Target Application (Priority: Medium)
The worker script (`scripts/qa_worker.sh` and `/home/ubuntu/qa_worker.sh` on GCP) uses placeholder values:
- Replace `com.target.application` with your actual Android package name
- Replace `TargetApp` with the app's process name (for Frida)
- Adjust tap coordinates (`500 1500`, `500 1800`) for your app's checkout UI
- Install your target APK on the emulator

### 3. Frida Profiler Script (Priority: Low)
The file `/home/ubuntu/qa_profiler.js` on the GCP VM is a placeholder. Replace it with your actual Frida hooks for:
- SSL pinning monitoring
- IAP billing flow interception
- Network traffic analysis

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

1. Dev sends `/test_iap` to the Telegram bot.
2. Railway bot SSH-execs into GCP.
3. GCP worker script boots a clean emulator.
4. Script launches target app, injects Frida to monitor network/SSL state during the billing flow.
5. ADB simulates UAT taps to verify UI responsiveness during checkout.
6. Results are piped back to Telegram.

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` `/help` | Show available commands |
| `/test_iap` | Run the full IAP validation QA suite on GCP |
| `/status` | Check GCP node connectivity |
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
├── bot.py                    # Main Telegram bot (runs on Railway)
├── scripts/
│   ├── qa_worker.sh          # GCP worker script (runs on GCP VM)
│   └── gcp_vm_setup.sh       # One-shot GCP VM setup script
├── requirements.txt          # Python dependencies
├── Procfile                  # Railway process definition
├── railway.toml              # Railway deployment config
├── nixpacks.toml             # Nixpacks build config
├── Dockerfile                # Docker build (alternative)
├── .env.example              # Environment variable template
├── .gitignore                # Git ignore rules
└── README.md                 # This file
```

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

## Security Notes

- **Never commit `.env` or SSH keys** to the repository.
- Use `ALLOWED_CHAT_IDS` to restrict bot access to authorized users only.
- SSH keys are stored base64-encoded in environment variables and written to temp files only during connection, then immediately deleted.
- Consider using GCP IAM service accounts and OS Login for production deployments.
- Rotate your Telegram bot token and SSH keys periodically.

## License

Private — All rights reserved.
