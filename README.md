# QA Automation Bot

Remote QA Automation & IAP Validation Framework. A Telegram bot hosted on [Railway](https://railway.com) that triggers Android in-app purchase (IAP) UI flow testing on a GCP VM using disposable Docker containers.

## Architecture

```
Telegram ──> Railway (this bot) ──SSH──> GCP VM ──Docker──> Android AVD + Frida
```

- **Trigger Node (Railway):** Python Telegram bot — acts as the CI/CD trigger.
- **Execution Node (GCP):** n1-standard-4 VM running headless Android Virtual Devices (AVD) with nested virtualization.
- **Golden Image:** Immutable Docker image (`qa-avd-golden`) with Android 12 x86_64 AVD and Frida server pre-installed.
- **Target:** Configurable Android APK (`com.yourcompany.app` by default).

## Execution Flows

### Legacy Flow (`/test_iap`)

1. Dev sends `/test_iap` to the Telegram bot.
2. Railway bot SSH-execs into GCP.
3. GCP worker script boots a clean emulator.
4. Script launches target app, injects Frida to monitor network/SSL state during the billing flow.
5. ADB simulates UAT taps to verify UI responsiveness during checkout.
6. Results are piped back to Telegram.

### Containerized IAP Flow (`/run_iap_test`)

```
User ──> /run_iap_test <email> <password> <mock_payment>
         │
         ├─ Bot SSHs into GCP VM
         ├─ Spins up disposable Docker container (golden image)
         ├─ Container lifecycle (setup_session.sh):
         │   ├─ Phase 1: Boot Android emulator (headless)
         │   ├─ Phase 2: Push Frida server + install staging APK
         │   ├─ Phase 3: Login to Google Play sandbox (adb keyevents)
         │   ├─ Phase 4: Save pre-warmed snapshot (test_ready_<session_id>)
         │   ├─ Phase 5: Inject Frida hooks (hook_1m.js)
         │   │   ├─ Bypass emulator/root detection
         │   │   ├─ Override offerToken → 1-month subscription tier
         │   │   └─ Intercept BillingResult for validation
         │   ├─ Phase 6: UI automation (qa_worker.sh)
         │   │   ├─ Navigate to subscription screen
         │   │   ├─ Select 1-month plan
         │   │   ├─ Tap "Upgrade" button
         │   │   ├─ Confirm billing dialog (sandbox)
         │   │   └─ Validate purchase result
         │   └─ Phase 7: Logout + cleanup
         └─ Container auto-destroyed (--rm)
```

#### Example Bot Interaction

```
User  → /run_iap_test qa@test.com P@ssw0rd mock_card_visa
Bot   → "Containerized IAP Test
         Session: a1b2c3d4e5f6
         ⏳ Spinning up isolated test environment..."
Bot   → "1️⃣ SSH connected
         2️⃣ Container launched
         3️⃣ Executing UI automation & validating subscription state..."
Bot   → "Containerized IAP Test — PASSED ✅
         ...
         Container torn down — clean state"
```

## Bot Commands

| Command | Description |
|---------|-------------|
| `/start` `/help` | Show available commands |
| `/test_iap` | Run the full IAP validation QA suite on GCP (legacy) |
| `/run_iap_test <email> <password> [mock_payment]` | Run containerized IAP test with Frida instrumentation |
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
  - Docker installed (for containerized IAP tests)
  - `/dev/kvm` available (for Android emulator inside Docker)

### 2. GCP VM Setup

#### Docker Golden Image

Build the golden image on your GCP VM:

```bash
# Clone the repo on the GCP VM
git clone https://github.com/your-org/qa-automation-bot.git
cd qa-automation-bot

# Build the golden image
docker build -f docker/Dockerfile.golden -t qa-avd-golden:latest .

# Create the persistent data volume directory
sudo mkdir -p /mnt/qa-data
sudo chown $(whoami):$(whoami) /mnt/qa-data

# Copy your staging APK to the data volume
cp /path/to/your/app-staging.apk /mnt/qa-data/app-staging.apk
```

#### Legacy Worker Setup

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
| `DOCKER_IMAGE` | No | Golden image name (default: `qa-avd-golden:latest`) |
| `QA_DATA_VOLUME` | No | Persistent data path on GCP (default: `/mnt/qa-data`) |
| `TARGET_PACKAGE` | No | Android package name (default: `com.yourcompany.app`) |
| `TARGET_APK_PATH` | No | APK path inside data volume (default: `/mnt/qa-data/app-staging.apk`) |
| `IAP_TEST_TIMEOUT` | No | Container test timeout in seconds (default: `900`) |

#### Encoding your SSH key

```bash
cat ~/.ssh/id_rsa | base64 -w 0
```

Copy the output and paste it as the `SSH_PRIVATE_KEY_B64` value in Railway.

## Containerized IAP Pipeline — Detailed

### Golden Image (`docker/Dockerfile.golden`)

The golden image is an immutable base containing:
- Ubuntu 22.04 with KVM support
- Android SDK (API 31 / Android 12)
- Pre-configured AVD (`qa_device`, Pixel 4, x86_64)
- Frida server (`frida-server-16.2.1-android-x86_64`)
- `frida-tools` Python package
- QA scripts (`setup_session.sh`, `qa_worker.sh`, `hook_1m.js`)

Each test session spawns a new container from this image, ensuring complete isolation and a clean state.

### Container Lifecycle (`scripts/setup_session.sh`)

| Phase | Action |
|-------|--------|
| 1 | Boot headless Android emulator |
| 2 | Push Frida server to device, install staging APK |
| 3 | Login to Google Play sandbox via ADB keyevents |
| 4 | Save pre-warmed AVD snapshot (`test_ready_<session_id>`) |
| 5 | Start Frida server, inject `hook_1m.js` |
| 6 | Run UI automation (`qa_worker.sh`) |
| 7 | Logout, cleanup, auto-destroy container |

### Frida Instrumentation (`scripts/hook_1m.js`)

The Frida script provides:
- **Emulator detection bypass** — spoofs `android.os.Build` fields
- **Root/integrity check bypass** — stubs `RootDetector` and `IntegrityValidator`
- **offerToken override** — forces Google Play Billing `SubscriptionOfferDetails` to return the 1-month tier mock token
- **BillingResult interception** — logs purchase response codes for validation
- **PurchasesUpdatedListener hook** — captures order details from sandbox transactions
- **SSL pinning bypass** — allows Frida traffic inspection on staging builds

### UI Automation (`scripts/qa_worker.sh`)

Automated tap sequences through the subscription upgrade flow:
1. Launch app and navigate to subscription screen
2. Select 1-month plan
3. Tap "Upgrade" button
4. Confirm billing dialog (sandbox)
5. Validate purchase via Frida hook output in logcat
6. Verify subscription state in-app
7. Capture screenshots at each step

### Persistent Data Volume

The GCP persistent disk mounted at `/mnt/qa-data` stores:
- Staging APK files
- AVD snapshots for faster re-runs
- Session logs (`session_<id>.log`)
- QA screenshots

## Local Development

```bash
# Clone the repo
git clone https://github.com/your-org/qa-automation-bot.git
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

## Docker (Bot Only)

```bash
docker build -t qa-bot .
docker run --env-file .env qa-bot
```

## Docker Compose (Full Pipeline)

On the GCP VM, use docker-compose to run test sessions:

```bash
cd qa-automation-bot

# Run a test session
TEST_EMAIL="qa@test.com" \
TEST_PASSWORD="P@ssw0rd" \
MOCK_PAYMENT="mock_card_visa" \
  docker compose -f docker/docker-compose.yml run --rm iap-test
```

## Project Structure

```
qa-automation-bot/
├── bot.py                      # Main Telegram bot (runs on Railway)
├── scripts/
│   ├── setup_session.sh        # Container lifecycle (runs inside Docker)
│   ├── qa_worker.sh            # UI automation for IAP flow
│   └── hook_1m.js              # Frida instrumentation (billing mocks)
├── docker/
│   ├── Dockerfile.golden       # Golden image (Android AVD + Frida)
│   └── docker-compose.yml      # Container orchestration
├── requirements.txt            # Python dependencies
├── Procfile                    # Railway process definition
├── railway.toml                # Railway deployment config
├── nixpacks.toml               # Nixpacks build config
├── Dockerfile                  # Docker build for bot (Railway)
├── .env.example                # Environment variable template
├── .gitignore                  # Git ignore rules
└── README.md                   # This file
```

## Security Notes

- **Never commit `.env` or SSH keys** to the repository.
- Use `ALLOWED_CHAT_IDS` to restrict bot access to authorized users only.
- SSH keys are stored base64-encoded in environment variables and written to temp files only during connection, then immediately deleted.
- Test credentials are passed as environment variables to containers and never persisted to disk beyond the session log.
- Docker containers run with `--rm` to ensure automatic cleanup.
- Consider using GCP IAM service accounts and OS Login for production deployments.

## License

Private — All rights reserved.
