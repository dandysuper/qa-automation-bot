"""
Remote QA Automation & IAP Validation Framework
Telegram bot hosted on Railway, executing QA suites on GCP.
"""

import logging
import os
import base64
import tempfile
import time
import uuid
from datetime import datetime, timezone

import paramiko
import telebot

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("qa-bot")

# ---------------------------------------------------------------------------
# Environment variables
# ---------------------------------------------------------------------------
TG_TOKEN = os.getenv("TG_TOKEN")
GCP_IP = os.getenv("GCP_IP")
GCP_USER = os.getenv("GCP_USER", "ubuntu")
GCP_PORT = int(os.getenv("GCP_PORT", "22"))
SSH_PRIVATE_KEY_B64 = os.getenv("SSH_PRIVATE_KEY_B64")
ALLOWED_CHAT_IDS = os.getenv("ALLOWED_CHAT_IDS", "")  # comma-separated

QA_WORKER_SCRIPT = os.getenv("QA_WORKER_SCRIPT", "/home/ubuntu/qa_worker.sh")
SSH_TIMEOUT = int(os.getenv("SSH_TIMEOUT", "30"))
COMMAND_TIMEOUT = int(os.getenv("COMMAND_TIMEOUT", "600"))  # 10 min default

# IAP test container settings
DOCKER_IMAGE = os.getenv("DOCKER_IMAGE", "qa-avd-golden:latest")
QA_DATA_VOLUME = os.getenv("QA_DATA_VOLUME", "/mnt/qa-data")
TARGET_PACKAGE = os.getenv("TARGET_PACKAGE", "com.yourcompany.app")
TARGET_APK_PATH = os.getenv("TARGET_APK_PATH", "/mnt/qa-data/app-staging.apk")
IAP_TEST_TIMEOUT = int(os.getenv("IAP_TEST_TIMEOUT", "900"))  # 15 min default

if not TG_TOKEN:
    raise RuntimeError("TG_TOKEN environment variable is required")

bot = telebot.TeleBot(TG_TOKEN, parse_mode="Markdown")

# ---------------------------------------------------------------------------
# Access control
# ---------------------------------------------------------------------------


def _allowed_ids() -> set[int]:
    if not ALLOWED_CHAT_IDS:
        return set()
    return {int(cid.strip()) for cid in ALLOWED_CHAT_IDS.split(",") if cid.strip()}


def is_authorized(message: telebot.types.Message) -> bool:
    allowed = _allowed_ids()
    if not allowed:
        return True  # no restriction configured
    return message.chat.id in allowed


def unauthorized_reply(message: telebot.types.Message):
    bot.reply_to(message, "Access denied. Your chat ID is not authorized.")

# ---------------------------------------------------------------------------
# SSH helpers
# ---------------------------------------------------------------------------


def _write_key_file() -> str:
    """Decode the base64 SSH private key and write to a temp file."""
    if not SSH_PRIVATE_KEY_B64:
        raise ValueError("SSH_PRIVATE_KEY_B64 environment variable is not set")
    key_data = base64.b64decode(SSH_PRIVATE_KEY_B64).decode("utf-8")
    fd, path = tempfile.mkstemp(prefix="gcp_key_", suffix=".pem")
    with os.fdopen(fd, "w") as f:
        f.write(key_data)
    os.chmod(path, 0o600)
    return path


def get_ssh_client() -> paramiko.SSHClient:
    """Return a connected SSH client to the GCP execution node."""
    if not GCP_IP:
        raise ValueError("GCP_IP environment variable is not set")
    key_path = _write_key_file()
    try:
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            GCP_IP,
            port=GCP_PORT,
            username=GCP_USER,
            key_filename=key_path,
            timeout=SSH_TIMEOUT,
        )
        return ssh
    finally:
        os.unlink(key_path)


def run_remote_command(ssh: paramiko.SSHClient, command: str) -> tuple[int, str, str]:
    """Execute a command on the remote host and return (exit_code, stdout, stderr)."""
    stdin, stdout, stderr = ssh.exec_command(command, timeout=COMMAND_TIMEOUT)
    exit_code = stdout.channel.recv_exit_status()
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    return exit_code, out, err

# ---------------------------------------------------------------------------
# Telegram helpers
# ---------------------------------------------------------------------------


def _shell_escape(value: str) -> str:
    """Escape a value for safe use in a shell command string."""
    return "'" + value.replace("'", "'\\''") + "'"


def _truncate(text: str, limit: int = 3500) -> str:
    """Truncate text to fit within Telegram message limits."""
    if len(text) <= limit:
        return text
    return text[:limit] + "\n... (truncated)"


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S UTC")

# ---------------------------------------------------------------------------
# Bot commands
# ---------------------------------------------------------------------------


@bot.message_handler(commands=["start", "help"])
def cmd_help(message: telebot.types.Message):
    help_text = (
        "*QA Automation Bot*\n\n"
        "Commands:\n"
        "`/test_iap` — Run the full IAP validation QA suite on GCP\n"
        "`/run_iap_test <email> <password> <mock_payment>` — "
        "Spin up an isolated Docker container and run the containerized "
        "IAP flow with Frida instrumentation\n"
        "`/upload_apk` — Reply to a file with this command to upload "
        "APK/XAPK to the GCP data volume\n"
        "`/status` — Check GCP node connectivity\n"
        "`/run <cmd>` — Execute a custom command on GCP\n"
        "`/logs` — Fetch last 50 lines of QA worker log\n"
        "`/emulator` — Check emulator status on GCP\n"
        "`/help` — Show this help message\n"
    )
    bot.reply_to(message, help_text)


@bot.message_handler(commands=["status"])
def cmd_status(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    msg = bot.reply_to(message, "Checking GCP node connectivity...")
    try:
        ssh = get_ssh_client()
        exit_code, out, _ = run_remote_command(ssh, "uptime && free -h | head -2")
        ssh.close()
        bot.edit_message_text(
            f"*GCP Node Online*\n```\n{_truncate(out)}\n```",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )
    except Exception as e:
        logger.exception("Status check failed")
        bot.edit_message_text(
            f"GCP node unreachable: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


@bot.message_handler(commands=["test_iap"])
def cmd_test_iap(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    started = _ts()
    msg = bot.reply_to(
        message,
        f"Initiating remote QA suite on GCP...\nStarted: {started}\n\n"
        "1. Connecting via SSH\n"
        "2. Booting clean AVD\n"
        "3. Running IAP validation flow\n"
        "4. Collecting results",
    )

    try:
        # Step 1: SSH connect
        ssh = get_ssh_client()
        bot.edit_message_text(
            f"*QA Suite Progress*\nStarted: {started}\n\n"
            "1. SSH connected\n"
            "2. Booting AVD...\n"
            "3. Pending\n"
            "4. Pending",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )

        # Step 2-3: Run worker script
        exit_code, out, err = run_remote_command(ssh, f"bash {QA_WORKER_SCRIPT}")
        ssh.close()
        finished = _ts()

        if exit_code == 0:
            bot.edit_message_text(
                f"*QA Suite Completed*\n"
                f"Started: {started} | Finished: {finished}\n\n"
                f"IAP flow validated successfully.\n\n"
                f"```\n{_truncate(out)}\n```",
                message.chat.id,
                msg.message_id,
                parse_mode="Markdown",
            )
        else:
            error_output = err if err else out
            bot.edit_message_text(
                f"*QA Suite Failed* (exit code {exit_code})\n"
                f"Started: {started} | Finished: {finished}\n\n"
                f"```\n{_truncate(error_output)}\n```",
                message.chat.id,
                msg.message_id,
                parse_mode="Markdown",
            )

    except Exception as e:
        logger.exception("QA suite execution failed")
        bot.edit_message_text(
            f"*QA Suite Error*\n\nSSH connection failed: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


@bot.message_handler(commands=["run_iap_test"])
def cmd_run_iap_test(message: telebot.types.Message):
    """Containerized IAP test: spin up a disposable Docker environment,
    inject Frida hooks, run the purchase flow, then tear down."""
    if not is_authorized(message):
        return unauthorized_reply(message)

    # Parse arguments: /run_iap_test <email> <password> <mock_payment>
    parts = message.text.split()
    if len(parts) < 3:
        bot.reply_to(
            message,
            "Usage: `/run_iap_test <test_email> <test_password> [mock_payment]`\n\n"
            "Example:\n"
            "`/run_iap_test qa@example.com P@ssw0rd mock_card_visa`",
        )
        return

    test_email = parts[1]
    test_password = parts[2]
    mock_payment = parts[3] if len(parts) > 3 else "mock_card_visa"
    session_id = uuid.uuid4().hex[:12]
    started = _ts()

    msg = bot.reply_to(
        message,
        f"*Containerized IAP Test*\n"
        f"Session: `{session_id}`\n"
        f"Started: {started}\n\n"
        "⏳ Spinning up isolated test environment...",
    )

    try:
        ssh = get_ssh_client()

        # Update progress — container starting
        bot.edit_message_text(
            f"*Containerized IAP Test*\n"
            f"Session: `{session_id}`\n"
            f"Started: {started}\n\n"
            "1️⃣ SSH connected\n"
            "2️⃣ Launching Docker container...\n"
            "3️⃣ Pending — Frida injection\n"
            "4️⃣ Pending — UI automation\n"
            "5️⃣ Pending — Validation & teardown",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )

        # Build the docker run command
        docker_cmd = (
            f"docker run --rm --privileged "
            f"--device /dev/kvm:/dev/kvm "
            f"-e SESSION_ID={session_id} "
            f"-e TEST_EMAIL={_shell_escape(test_email)} "
            f"-e TEST_PASSWORD={_shell_escape(test_password)} "
            f"-e MOCK_PAYMENT={_shell_escape(mock_payment)} "
            f"-e TARGET_PACKAGE={TARGET_PACKAGE} "
            f"-e TARGET_APK_PATH={TARGET_APK_PATH} "
            f"-v {QA_DATA_VOLUME}:/data/qa "
            f"{DOCKER_IMAGE} "
            f"2>&1"
        )

        # Update progress — running
        bot.edit_message_text(
            f"*Containerized IAP Test*\n"
            f"Session: `{session_id}`\n"
            f"Started: {started}\n\n"
            "1️⃣ SSH connected\n"
            "2️⃣ Container launched\n"
            "3️⃣ Executing UI automation & validating subscription state...\n"
            "4️⃣ Pending — Results\n"
            "5️⃣ Pending — Teardown",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )

        exit_code, out, err = run_remote_command(ssh, docker_cmd)
        ssh.close()
        finished = _ts()

        # Parse result
        output = out if out else err
        last_lines = "\n".join(output.strip().splitlines()[-30:])

        if exit_code == 0:
            bot.edit_message_text(
                f"*Containerized IAP Test — PASSED ✅*\n"
                f"Session: `{session_id}`\n"
                f"Started: {started} | Finished: {finished}\n\n"
                f"1️⃣ SSH connected\n"
                f"2️⃣ Container launched & emulator booted\n"
                f"3️⃣ Frida hooks injected (hook\\_1m.js)\n"
                f"4️⃣ IAP flow validated successfully\n"
                f"5️⃣ Container torn down — clean state\n\n"
                f"```\n{_truncate(last_lines)}\n```",
                message.chat.id,
                msg.message_id,
                parse_mode="Markdown",
            )
        else:
            status_label = "CANCELED" if exit_code == 2 else "FAILED"
            bot.edit_message_text(
                f"*Containerized IAP Test — {status_label} ❌*\n"
                f"Session: `{session_id}` | Exit: {exit_code}\n"
                f"Started: {started} | Finished: {finished}\n\n"
                f"```\n{_truncate(last_lines)}\n```\n\n"
                f"Logs: `{QA_DATA_VOLUME}/session_{session_id}.log`",
                message.chat.id,
                msg.message_id,
                parse_mode="Markdown",
            )

    except Exception as e:
        logger.exception("Containerized IAP test failed")
        bot.edit_message_text(
            f"*Containerized IAP Test — ERROR*\n"
            f"Session: `{session_id}`\n\n"
            f"Connection failed: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


@bot.message_handler(commands=["upload_apk"])
def cmd_upload_apk(message: telebot.types.Message):
    """Download an APK/XAPK file sent via Telegram and upload it to the GCP
    data volume via SCP. Supports both direct file messages and replies."""
    if not is_authorized(message):
        return unauthorized_reply(message)

    # Find the document — either in this message or in a replied-to message
    doc = None
    if message.document:
        doc = message.document
    elif message.reply_to_message and message.reply_to_message.document:
        doc = message.reply_to_message.document

    if not doc:
        bot.reply_to(
            message,
            "Send an APK/XAPK file, or reply to a file message with "
            "`/upload_apk` to upload it to the GCP test environment.",
        )
        return

    file_name = doc.file_name or "app-staging.apk"
    ext = file_name.rsplit(".", 1)[-1].lower() if "." in file_name else ""
    if ext not in ("apk", "xapk", "apks"):
        bot.reply_to(message, f"Unsupported file type `.{ext}`. Send an APK, XAPK, or APKS file.")
        return

    file_size_mb = (doc.file_size or 0) / (1024 * 1024)
    msg = bot.reply_to(
        message,
        f"Downloading `{file_name}` ({file_size_mb:.1f} MB) from Telegram...",
    )

    try:
        # Download file from Telegram
        file_info = bot.get_file(doc.file_id)
        downloaded = bot.download_file(file_info.file_path)

        # Write to a local temp file
        local_path = f"/tmp/{file_name}"
        with open(local_path, "wb") as f:
            f.write(downloaded)

        bot.edit_message_text(
            f"Downloaded `{file_name}`. Uploading to GCP...",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )

        # SCP to GCP data volume
        remote_path = f"{QA_DATA_VOLUME}/{file_name}"
        ssh = get_ssh_client()
        sftp = ssh.open_sftp()
        sftp.put(local_path, remote_path)
        sftp.close()
        ssh.close()

        # Clean up local temp file
        os.unlink(local_path)

        bot.edit_message_text(
            f"*Upload Complete*\n\n"
            f"File: `{file_name}` ({file_size_mb:.1f} MB)\n"
            f"Location: `{remote_path}`\n\n"
            f"To use this in a test run:\n"
            f"`/run_iap_test <email> <password>`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )

    except Exception as e:
        logger.exception("APK upload failed")
        bot.edit_message_text(
            f"Upload failed: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


@bot.message_handler(content_types=["document"])
def handle_document(message: telebot.types.Message):
    """Auto-detect APK/XAPK files sent without a command and offer to upload."""
    if not is_authorized(message):
        return

    doc = message.document
    if not doc or not doc.file_name:
        return

    ext = doc.file_name.rsplit(".", 1)[-1].lower() if "." in doc.file_name else ""
    if ext in ("apk", "xapk", "apks"):
        file_size_mb = (doc.file_size or 0) / (1024 * 1024)
        bot.reply_to(
            message,
            f"Detected `{doc.file_name}` ({file_size_mb:.1f} MB).\n"
            f"Reply to this file with `/upload_apk` to upload it to the GCP test environment.",
        )


@bot.message_handler(commands=["run"])
def cmd_run(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    parts = message.text.split(maxsplit=1)
    if len(parts) < 2:
        bot.reply_to(message, "Usage: `/run <command>`")
        return

    command = parts[1]
    msg = bot.reply_to(message, f"Running: `{_truncate(command, 100)}`...")

    try:
        ssh = get_ssh_client()
        exit_code, out, err = run_remote_command(ssh, command)
        ssh.close()

        output = out if out else err
        status = "OK" if exit_code == 0 else f"FAILED (exit {exit_code})"
        bot.edit_message_text(
            f"*{status}*\n```\n{_truncate(output)}\n```",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )
    except Exception as e:
        logger.exception("Remote command failed")
        bot.edit_message_text(
            f"Command failed: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


@bot.message_handler(commands=["logs"])
def cmd_logs(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    msg = bot.reply_to(message, "Fetching QA worker logs...")
    try:
        ssh = get_ssh_client()
        exit_code, out, err = run_remote_command(
            ssh, "tail -n 50 /home/ubuntu/qa_worker.log 2>/dev/null || echo 'No log file found.'"
        )
        ssh.close()
        bot.edit_message_text(
            f"*QA Worker Logs*\n```\n{_truncate(out)}\n```",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )
    except Exception as e:
        logger.exception("Log fetch failed")
        bot.edit_message_text(
            f"Failed to fetch logs: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


@bot.message_handler(commands=["emulator"])
def cmd_emulator(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    msg = bot.reply_to(message, "Checking emulator status on GCP...")
    try:
        ssh = get_ssh_client()
        exit_code, out, err = run_remote_command(
            ssh,
            "adb devices 2>/dev/null && "
            "ps aux | grep -E 'qemu|emulator' | grep -v grep || "
            "echo 'No emulator processes found.'",
        )
        ssh.close()
        bot.edit_message_text(
            f"*Emulator Status*\n```\n{_truncate(out)}\n```",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )
    except Exception as e:
        logger.exception("Emulator check failed")
        bot.edit_message_text(
            f"Emulator check failed: `{e}`",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    logger.info("QA Automation Bot starting...")
    logger.info("GCP target: %s@%s:%s", GCP_USER, GCP_IP, GCP_PORT)
    if _allowed_ids():
        logger.info("Access restricted to chat IDs: %s", ALLOWED_CHAT_IDS)
    else:
        logger.info("No chat ID restriction configured (open access)")

    while True:
        try:
            bot.polling(none_stop=True, timeout=60)
        except Exception as e:
            logger.error("Polling error: %s — restarting in 5s", e)
            time.sleep(5)
