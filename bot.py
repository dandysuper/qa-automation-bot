"""
Remote QA Automation & IAP Validation Framework
Telegram bot hosted on Railway, executing QA suites on GCP.
"""

import logging
import os
import base64
import signal
import socket
import sys
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
SSH_RETRIES = int(os.getenv("SSH_RETRIES", "3"))
SSH_RETRY_DELAY = int(os.getenv("SSH_RETRY_DELAY", "5"))  # seconds between retries
STARTUP_DELAY = int(os.getenv("STARTUP_DELAY", "3"))  # seconds to wait before polling

if not TG_TOKEN:
    logger.error("TG_TOKEN environment variable is required. Set it in Railway dashboard.")
    logger.error("Bot cannot start without a valid Telegram token.")
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
    """Return a connected SSH client to the GCP execution node with retry logic."""
    if not GCP_IP:
        raise ValueError("GCP_IP environment variable is not set")
    key_path = _write_key_file()
    last_exc: Exception | None = None
    try:
        for attempt in range(1, SSH_RETRIES + 1):
            try:
                logger.info(
                    "SSH attempt %d/%d to %s@%s:%s (timeout=%ss)",
                    attempt, SSH_RETRIES, GCP_USER, GCP_IP, GCP_PORT, SSH_TIMEOUT,
                )
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
                logger.info("SSH connected successfully on attempt %d", attempt)
                return ssh
            except Exception as e:
                last_exc = e
                logger.warning(
                    "SSH attempt %d/%d failed: %s (%s)",
                    attempt, SSH_RETRIES, e, type(e).__name__,
                )
                if attempt < SSH_RETRIES:
                    delay = SSH_RETRY_DELAY * attempt
                    logger.info("Retrying in %ds...", delay)
                    time.sleep(delay)
        logger.error("All %d SSH attempts failed", SSH_RETRIES)
        raise last_exc  # type: ignore[misc]
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
        "`/test_iap <plan>` - Run with specific plan (e.g. chatgpt-plus-monthly)\n"
        "`/status` - Check GCP node connectivity\n"
        "`/diagnose` - Run network diagnostics to GCP node\n"
        "`/install_apk <url>` - Download & install APK on emulator\n"
        "`/snapshot save <name>` - Save emulator snapshot\n"
        "`/snapshot load <name>` - Load emulator snapshot\n"
        "`/snapshot list` - List saved snapshots\n"
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
        troubleshoot = _ssh_troubleshoot_tips(e)
        bot.edit_message_text(
            f"*GCP Node Unreachable*\n\n"
            f"Error: `{type(e).__name__}: {e}`\n"
            f"Target: `{GCP_USER}@{GCP_IP}:{GCP_PORT}`\n\n"
            f"{troubleshoot}\n\n"
            f"Run `/diagnose` for detailed network diagnostics.",
            message.chat.id,
            msg.message_id,
            parse_mode="Markdown",
        )


def _ssh_troubleshoot_tips(exc: Exception) -> str:
    """Return context-specific troubleshooting tips based on the SSH error."""
    name = type(exc).__name__
    msg = str(exc).lower()
    if "timed out" in msg or name == "TimeoutError":
        return (
            "*Likely cause: GCP firewall blocking port 22*\n"
            "Fix:\n"
            "```\n"
            "gcloud compute firewall-rules create allow-ssh-railway \\\n"
            "  --direction=INGRESS --action=ALLOW \\\n"
            "  --rules=tcp:22 --source-ranges=0.0.0.0/0 \\\n"
            "  --target-tags=allow-ssh\n"
            "```\n"
            "Also verify:\n"
            "- VM is running: `gcloud compute instances list`\n"
            "- IP is current: `gcloud compute instances describe android-frida-vm --zone=europe-west1-b --format='get(networkInterfaces[0].accessConfigs[0].natIP)'`"
        )
    if "auth" in msg or "key" in msg or name == "AuthenticationException":
        return (
            "*Likely cause: SSH key mismatch*\n"
            "Verify `SSH_PRIVATE_KEY_B64` in Railway matches the public key on the VM:\n"
            "`gcloud compute ssh android-frida-vm --zone=europe-west1-b -- 'cat ~/.ssh/authorized_keys'`"
        )
    if "refused" in msg:
        return (
            "*Likely cause: SSH service not running on VM*\n"
            "Fix: `gcloud compute ssh android-frida-vm --zone=europe-west1-b -- 'sudo systemctl restart sshd'`"
        )
    return (
        "Check:\n"
        "1. VM is running\n"
        "2. Firewall allows TCP:22\n"
        "3. SSH key is correct"
    )


@bot.message_handler(commands=["diagnose"])
def cmd_diagnose(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    msg = bot.reply_to(message, "Running network diagnostics to GCP node...")
    results = []
    results.append(f"Target: `{GCP_USER}@{GCP_IP}:{GCP_PORT}`")
    results.append("")

    # 1. DNS resolution
    try:
        resolved = socket.getaddrinfo(GCP_IP, GCP_PORT, socket.AF_INET, socket.SOCK_STREAM)
        ip = resolved[0][4][0] if resolved else GCP_IP
        results.append(f"DNS/IP resolve: `{ip}`")
    except socket.gaierror as e:
        results.append(f"DNS resolution FAILED: `{e}`")
        results.append("\nThe GCP_IP may be invalid. Check your Railway env vars.")
        bot.edit_message_text(
            "*Diagnostics Result*\n\n" + "\n".join(results),
            message.chat.id, msg.message_id, parse_mode="Markdown",
        )
        return

    # 2. TCP port check (quick 10s timeout)
    results.append("")
    results.append("*TCP Port Check (10s timeout):*")
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)
        result = sock.connect_ex((GCP_IP, GCP_PORT))
        sock.close()
        if result == 0:
            results.append(f"Port {GCP_PORT}: OPEN")
        else:
            results.append(f"Port {GCP_PORT}: CLOSED/FILTERED (errno={result})")
            results.append("")
            results.append("*This means the GCP firewall is blocking SSH.*")
            results.append("Fix with:")
            results.append("```")
            results.append("gcloud compute firewall-rules create allow-ssh \\")
            results.append("  --direction=INGRESS --action=ALLOW \\")
            results.append("  --rules=tcp:22 --source-ranges=0.0.0.0/0 \\")
            results.append("  --target-tags=allow-ssh")
            results.append("```")
            results.append("Then add the `allow-ssh` network tag to your VM:")
            results.append("```")
            results.append("gcloud compute instances add-tags android-frida-vm \\")
            results.append("  --zone=europe-west1-b --tags=allow-ssh")
            results.append("```")
    except socket.timeout:
        results.append(f"Port {GCP_PORT}: TIMEOUT (no response in 10s)")
        results.append("")
        results.append("*Firewall is likely blocking traffic.* See fix above.")
    except Exception as e:
        results.append(f"Port check error: `{e}`")

    # 3. SSH auth test (only if port is open)
    if result == 0:
        results.append("")
        results.append("*SSH Authentication Test:*")
        try:
            ssh = get_ssh_client()
            ssh.close()
            results.append("SSH auth: SUCCESS")
        except Exception as e:
            results.append(f"SSH auth: FAILED — `{type(e).__name__}: {e}`")
            results.append("")
            tips = _ssh_troubleshoot_tips(e)
            results.append(tips)

    bot.edit_message_text(
        "*Diagnostics Result*\n\n" + "\n".join(results),
        message.chat.id, msg.message_id, parse_mode="Markdown",
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

        # Step 2-3: Run worker script (with optional plan argument)
        parts = message.text.split(maxsplit=1)
        plan_arg = ""
        if len(parts) > 1:
            plan_arg = f" --plan {parts[1].strip()}"
        exit_code, out, err = run_remote_command(ssh, f"bash {QA_WORKER_SCRIPT}{plan_arg}")
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


@bot.message_handler(commands=["install_apk"])
def cmd_install_apk(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    parts = message.text.split(maxsplit=1)
    if len(parts) < 2:
        bot.reply_to(
            message,
            "Usage: `/install_apk <url_or_path>`\n\n"
            "Examples:\n"
            "`/install_apk https://example.com/chatgpt.apk`\n"
            "`/install_apk ~/chatgpt.apk`",
        )
        return

    target = parts[1].strip()
    msg = bot.reply_to(message, f"Installing APK: `{_truncate(target, 100)}`...")

    try:
        ssh = get_ssh_client()

        if target.startswith("http://") or target.startswith("https://"):
            # Download from URL then install
            bot.edit_message_text(
                f"Downloading APK from URL...\n`{_truncate(target, 80)}`",
                message.chat.id, msg.message_id, parse_mode="Markdown",
            )
            dl_cmd = (
                f"wget -q -O /home/ubuntu/downloaded_app.apk '{target}' 2>&1 && "
                "adb install -r -g /home/ubuntu/downloaded_app.apk 2>&1"
            )
            exit_code, out, err = run_remote_command(ssh, dl_cmd)
        else:
            # Install from local path on VM
            exit_code, out, err = run_remote_command(
                ssh, f"adb install -r -g {target} 2>&1"
            )

        ssh.close()
        output = out if out else err
        status = "APK Installed" if exit_code == 0 else f"Install Failed (exit {exit_code})"
        bot.edit_message_text(
            f"*{status}*\n```\n{_truncate(output)}\n```",
            message.chat.id, msg.message_id, parse_mode="Markdown",
        )
    except Exception as e:
        logger.exception("APK install failed")
        bot.edit_message_text(
            f"APK install failed: `{e}`",
            message.chat.id, msg.message_id, parse_mode="Markdown",
        )


@bot.message_handler(commands=["snapshot"])
def cmd_snapshot(message: telebot.types.Message):
    if not is_authorized(message):
        return unauthorized_reply(message)

    parts = message.text.split()
    if len(parts) < 2:
        bot.reply_to(
            message,
            "Usage:\n"
            "`/snapshot save <name>` - Save current state\n"
            "`/snapshot load <name>` - Load a saved snapshot\n"
            "`/snapshot list` - List saved snapshots\n\n"
            "Example: `/snapshot save chatgpt_logged_in`",
        )
        return

    action = parts[1].lower()
    name = parts[2] if len(parts) > 2 else ""

    if action == "list":
        msg = bot.reply_to(message, "Listing snapshots...")
        try:
            ssh = get_ssh_client()
            exit_code, out, err = run_remote_command(
                ssh, "adb emu avd snapshot list 2>&1"
            )
            ssh.close()
            bot.edit_message_text(
                f"*Snapshots*\n```\n{_truncate(out if out else err)}\n```",
                message.chat.id, msg.message_id, parse_mode="Markdown",
            )
        except Exception as e:
            bot.edit_message_text(
                f"Failed: `{e}`", message.chat.id, msg.message_id, parse_mode="Markdown",
            )
        return

    if not name:
        bot.reply_to(message, f"Usage: `/snapshot {action} <name>`")
        return

    if action == "save":
        msg = bot.reply_to(message, f"Saving snapshot `{name}`...")
        try:
            ssh = get_ssh_client()
            exit_code, out, err = run_remote_command(
                ssh, f"adb emu avd snapshot save {name} 2>&1"
            )
            ssh.close()
            status = "Snapshot Saved" if exit_code == 0 else "Save Failed"
            bot.edit_message_text(
                f"*{status}*: `{name}`\n```\n{_truncate(out if out else err)}\n```",
                message.chat.id, msg.message_id, parse_mode="Markdown",
            )
        except Exception as e:
            bot.edit_message_text(
                f"Snapshot save failed: `{e}`",
                message.chat.id, msg.message_id, parse_mode="Markdown",
            )

    elif action == "load":
        msg = bot.reply_to(message, f"Loading snapshot `{name}`...")
        try:
            ssh = get_ssh_client()
            exit_code, out, err = run_remote_command(
                ssh, f"adb emu avd snapshot load {name} 2>&1"
            )
            ssh.close()
            status = "Snapshot Loaded" if exit_code == 0 else "Load Failed"
            bot.edit_message_text(
                f"*{status}*: `{name}`\n```\n{_truncate(out if out else err)}\n```",
                message.chat.id, msg.message_id, parse_mode="Markdown",
            )
        except Exception as e:
            bot.edit_message_text(
                f"Snapshot load failed: `{e}`",
                message.chat.id, msg.message_id, parse_mode="Markdown",
            )

    else:
        bot.reply_to(message, f"Unknown snapshot action: `{action}`. Use save, load, or list.")


# ---------------------------------------------------------------------------
# Graceful shutdown & entry point
# ---------------------------------------------------------------------------
_shutdown_requested = False


def _signal_handler(signum: int, _frame: object) -> None:
    global _shutdown_requested
    sig_name = signal.Signals(signum).name
    logger.info("Received %s — shutting down gracefully...", sig_name)
    _shutdown_requested = True
    try:
        bot.stop_polling()
    except Exception:
        pass


if __name__ == "__main__":
    logger.info("QA Automation Bot starting...")
    logger.info("GCP target: %s@%s:%s", GCP_USER, GCP_IP, GCP_PORT)
    if _allowed_ids():
        logger.info("Access restricted to chat IDs: %s", ALLOWED_CHAT_IDS)
    else:
        logger.info("No chat ID restriction configured (open access)")

    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)

    # Clear any existing webhook/polling to avoid 409 conflicts
    logger.info("Clearing previous webhook/polling sessions...")
    try:
        bot.delete_webhook(drop_pending_updates=True)
    except Exception as e:
        logger.warning("Failed to delete webhook: %s", e)

    logger.info("Waiting %ds for previous instances to release polling...", STARTUP_DELAY)
    time.sleep(STARTUP_DELAY)

    backoff = 5
    while not _shutdown_requested:
        try:
            logger.info("Starting polling...")
            bot.polling(
                none_stop=True,
                timeout=60,
                long_polling_timeout=60,
                allowed_updates=["message"],
                skip_pending=True,
            )
        except telebot.apihelper.ApiTelegramException as e:
            if e.error_code == 409:
                logger.error("409 Conflict — another instance is polling. Retrying in %ds...", backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
                try:
                    bot.delete_webhook(drop_pending_updates=True)
                except Exception:
                    pass
            else:
                logger.error("Telegram API error: %s — restarting in 10s", e)
                time.sleep(10)
                backoff = 5
        except Exception as e:
            if _shutdown_requested:
                break
            logger.error("Polling error: %s — restarting in 10s", e)
            time.sleep(10)
            backoff = 5

    logger.info("Bot stopped.")
