"""
Remote QA Automation & IAP Validation Framework
Telegram bot hosted on Railway, executing QA suites on GCP.
"""

import logging
import os
import base64
import tempfile
import time
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
SSH_TIMEOUT = int(os.getenv("SSH_TIMEOUT", "60"))
COMMAND_TIMEOUT = int(os.getenv("COMMAND_TIMEOUT", "600"))  # 10 min default

if not TG_TOKEN:
    logger.error("TG_TOKEN environment variable is required. Set it in Railway dashboard.")
    logger.error("Bot cannot start without a valid Telegram token.")
    import sys
    sys.exit(1)

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
        logger.info("Connecting to %s@%s:%s (timeout=%ss)", GCP_USER, GCP_IP, GCP_PORT, SSH_TIMEOUT)
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        ssh.connect(
            GCP_IP,
            port=GCP_PORT,
            username=GCP_USER,
            key_filename=key_path,
            timeout=SSH_TIMEOUT,
            banner_timeout=SSH_TIMEOUT,
            auth_timeout=SSH_TIMEOUT,
        )
        logger.info("SSH connected successfully")
        return ssh
    except Exception as e:
        logger.error("SSH connection failed: %s (%s)", e, type(e).__name__)
        raise
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
        "`/test_iap` - Run the full IAP validation QA suite on GCP\n"
        "`/status` - Check GCP node connectivity\n"
        "`/run <cmd>` - Execute a custom command on GCP\n"
        "`/logs` - Fetch last 50 lines of QA worker log\n"
        "`/emulator` - Check emulator status on GCP\n"
        "`/help` - Show this help message\n"
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
            f"GCP node unreachable: `{type(e).__name__}: {e}`\n\n"
            f"Target: `{GCP_USER}@{GCP_IP}:{GCP_PORT}`",
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

    # Clear any existing webhook/polling to avoid 409 conflicts
    logger.info("Clearing previous webhook/polling sessions...")
    bot.remove_webhook()
    time.sleep(1)

    while True:
        try:
            bot.polling(
                none_stop=True,
                timeout=60,
                long_polling_timeout=60,
                allowed_updates=["message"],
            )
        except Exception as e:
            logger.error("Polling error: %s — restarting in 10s", e)
            time.sleep(10)
