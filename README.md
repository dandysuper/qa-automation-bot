# QA Automation Bot

Remote QA Automation & IAP Validation Framework. A Telegram bot hosted on [Railway](https://railway.com) that triggers Android in-app purchase (IAP) UI flow testing on a GCP VM.

## Architecture

```
Telegram ──> Railway (this bot) ──SSH──> GCP VM (Android emulator + Frida)
```

- **Trigger Node (Railway):** Python Telegram bot — acts as the CI/CD trigger.
- **Execution Node (GCP):** n1-standard-4 VM running headless Android Virtual Devices (AVD) with nested virtualization.
- **Target:** Configurable Android APK (`com.yourcompany.app` by default).

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
  - AVD configured (default name: `qa_device`)
  - Frida server running (optional, for SSL/network monitoring)
  - SSH access with key-based auth

### 2. GCP VM Setup

Copy the worker script to your GCP VM:

```bash
scp scripts/qa_worker.sh ubuntu@<GCP_IP>:/home/ubuntu/qa_worker.sh
chmod +x /home/ubuntu/qa_worker.sh
```

Customize the environment variables in the script:
- `TARGET_APK` — path to your APK on the VM
- `TARGET_PACKAGE` — your app's package name
- `AVD_NAME` — Android Virtual Device name
- Adjust tap coordinates in the UAT section for your app's layout

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
| `SSH_TIMEOUT` | No | SSH connection timeout in seconds (default: `30`) |
| `COMMAND_TIMEOUT` | No | Remote command timeout in seconds (default: `600`) |

#### Encoding your SSH key

```bash
cat ~/.ssh/id_rsa | base64 -w 0
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
├── bot.py              # Main Telegram bot (runs on Railway)
├── scripts/
│   └── qa_worker.sh    # GCP worker script (runs on GCP VM)
├── requirements.txt    # Python dependencies
├── Procfile            # Railway process definition
├── railway.toml        # Railway deployment config
├── nixpacks.toml       # Nixpacks build config
├── Dockerfile          # Docker build (alternative)
├── .env.example        # Environment variable template
├── .gitignore          # Git ignore rules
└── README.md           # This file
```

## Security Notes

- **Never commit `.env` or SSH keys** to the repository.
- Use `ALLOWED_CHAT_IDS` to restrict bot access to authorized users only.
- SSH keys are stored base64-encoded in environment variables and written to temp files only during connection, then immediately deleted.
- Consider using GCP IAM service accounts and OS Login for production deployments.

## License

Private — All rights reserved.
