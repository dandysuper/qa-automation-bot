#!/usr/bin/env python3
"""
login_automation.py — Generic Google account login automation for Android emulators.

Automates the "Add Account" flow on a headless Android emulator using ADB
commands. Designed for QA test sessions that need fresh credential injection.

Usage:
    python3 login_automation.py --email <email> --password <password>
    python3 login_automation.py --email <email> --password <password> --package <pkg>

Environment variables (alternative to CLI args):
    TEST_EMAIL, TEST_PASSWORD, TARGET_PACKAGE
"""

import argparse
import logging
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

logging.basicConfig(
    level=logging.INFO,
    format="[login_auto] %(asctime)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("login_auto")


# ---------------------------------------------------------------------------
# ADB helpers
# ---------------------------------------------------------------------------

def adb(cmd: str, timeout: int = 30) -> str:
    """Run an ADB shell command and return stdout."""
    full_cmd = f"adb shell {cmd}"
    try:
        result = subprocess.run(
            full_cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        log.warning("ADB command timed out: %s", cmd)
        return ""


def adb_host(cmd: str, timeout: int = 30) -> str:
    """Run an ADB command on the host (not shell)."""
    full_cmd = f"adb {cmd}"
    try:
        result = subprocess.run(
            full_cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        log.warning("ADB host command timed out: %s", cmd)
        return ""


def tap(x: int, y: int, label: str = "") -> None:
    """Tap at coordinates."""
    log.info("TAP (%d, %d) %s", x, y, label)
    adb(f"input tap {x} {y}")
    time.sleep(2)


def type_text(text: str) -> None:
    """Type text via ADB. Escapes special characters."""
    escaped = text.replace(" ", "%s").replace("&", "\\&").replace("@", "\\@")
    adb(f"input text '{escaped}'")
    time.sleep(1)


def press_key(keycode: int) -> None:
    """Send a keyevent."""
    adb(f"input keyevent {keycode}")
    time.sleep(1)


def press_enter() -> None:
    press_key(66)


def press_back() -> None:
    press_key(4)


def press_tab() -> None:
    press_key(61)


# ---------------------------------------------------------------------------
# UI dump & element finder
# ---------------------------------------------------------------------------

def dump_ui() -> ET.Element | None:
    """Dump the UI hierarchy and parse it."""
    adb("uiautomator dump /sdcard/ui_dump.xml")
    time.sleep(1)
    xml_content = adb("cat /sdcard/ui_dump.xml")
    if not xml_content:
        log.warning("UI dump returned empty content")
        return None
    try:
        return ET.fromstring(xml_content)
    except ET.ParseError as e:
        log.warning("Failed to parse UI dump: %s", e)
        return None


def find_element_coords(root: ET.Element, text: str) -> tuple[int, int] | None:
    """Find an element by text content and return its center coordinates."""
    for node in root.iter("node"):
        node_text = node.get("text", "")
        node_desc = node.get("content-desc", "")
        if text.lower() in node_text.lower() or text.lower() in node_desc.lower():
            bounds = node.get("bounds", "")
            if bounds:
                coords = bounds.replace("][", ",").strip("[]").split(",")
                if len(coords) == 4:
                    x = (int(coords[0]) + int(coords[2])) // 2
                    y = (int(coords[1]) + int(coords[3])) // 2
                    log.info("Found '%s' at (%d, %d)", text, x, y)
                    return (x, y)
    return None


def wait_for_element(text: str, timeout: int = 60) -> tuple[int, int] | None:
    """Poll UI dumps until an element with the given text appears."""
    elapsed = 0
    while elapsed < timeout:
        root = dump_ui()
        if root is not None:
            coords = find_element_coords(root, text)
            if coords:
                return coords
        time.sleep(3)
        elapsed += 3
    log.warning("Element '%s' not found after %ds", text, timeout)
    return None


def wait_until_gone(text: str, timeout: int = 60) -> bool:
    """Wait until an element with the given text disappears from the UI."""
    elapsed = 0
    while elapsed < timeout:
        root = dump_ui()
        if root is not None:
            coords = find_element_coords(root, text)
            if coords is None:
                log.info("'%s' has disappeared from UI", text)
                return True
        time.sleep(3)
        elapsed += 3
    log.warning("'%s' still present after %ds", text, timeout)
    return False


# ---------------------------------------------------------------------------
# Login flow
# ---------------------------------------------------------------------------

def launch_add_account() -> None:
    """Open the Add Google Account screen."""
    log.info("Launching Google account sign-in activity")
    adb("am start -a android.settings.ADD_ACCOUNT_SETTINGS")
    time.sleep(3)

    # Look for "Google" in the account type picker
    coords = wait_for_element("Google", timeout=15)
    if coords:
        tap(coords[0], coords[1], "Google account type")
    else:
        log.info("Google option not found, trying direct GSF login")
        adb("am start -n com.google.android.gsf.login/.LoginActivity")
        time.sleep(3)


def enter_email(email: str) -> None:
    """Enter email on the sign-in screen."""
    log.info("Entering email: %s", email)

    # Wait for the email input field
    time.sleep(2)

    # Try to find and tap the email field via UI dump
    root = dump_ui()
    if root is not None:
        email_field = find_element_coords(root, "Email or phone")
        if email_field:
            tap(email_field[0], email_field[1], "email input field")

    type_text(email)
    time.sleep(1)

    # Tap "Next" button
    next_btn = wait_for_element("Next", timeout=10)
    if next_btn:
        tap(next_btn[0], next_btn[1], "Next button")
    else:
        press_enter()

    time.sleep(3)


def wait_for_checking_screen() -> None:
    """Wait for the 'Checking info' loading screen to pass."""
    log.info("Waiting for verification screen to complete...")
    # Wait for loading indicators to appear and then disappear
    time.sleep(3)
    wait_until_gone("Checking", timeout=30)
    wait_until_gone("Verifying", timeout=30)
    time.sleep(2)


def enter_password(password: str) -> None:
    """Enter password on the sign-in screen."""
    log.info("Entering password")

    # Wait for password field
    time.sleep(2)

    root = dump_ui()
    if root is not None:
        pw_field = find_element_coords(root, "Enter your password")
        if pw_field:
            tap(pw_field[0], pw_field[1], "password input field")

    type_text(password)
    time.sleep(1)

    next_btn = wait_for_element("Next", timeout=10)
    if next_btn:
        tap(next_btn[0], next_btn[1], "Next button")
    else:
        press_enter()

    time.sleep(3)


def accept_terms() -> None:
    """Accept Google Terms of Service if prompted."""
    log.info("Checking for Terms of Service screen")

    agree_btn = wait_for_element("I agree", timeout=15)
    if agree_btn:
        tap(agree_btn[0], agree_btn[1], "I agree button")
        time.sleep(3)

    # Handle "More" button that sometimes appears before "Accept"
    more_btn = wait_for_element("More", timeout=5)
    if more_btn:
        tap(more_btn[0], more_btn[1], "More button")
        time.sleep(2)

    accept_btn = wait_for_element("Accept", timeout=10)
    if accept_btn:
        tap(accept_btn[0], accept_btn[1], "Accept button")
        time.sleep(3)


def verify_account_added(email: str) -> bool:
    """Verify the Google account was successfully added."""
    log.info("Verifying account was added")
    output = adb("dumpsys account")
    if email.lower() in output.lower():
        log.info("Account %s found in device accounts", email)
        return True
    log.warning("Account %s NOT found in device accounts", email)
    return False


def run_login_flow(email: str, password: str) -> bool:
    """Execute the full Google account login flow."""
    log.info("Starting login flow for %s", email)

    launch_add_account()
    enter_email(email)
    wait_for_checking_screen()
    enter_password(password)
    wait_for_checking_screen()
    accept_terms()

    time.sleep(5)
    return verify_account_added(email)


# ---------------------------------------------------------------------------
# App launch & UI mapping
# ---------------------------------------------------------------------------

def launch_app(package: str) -> None:
    """Launch the target application."""
    log.info("Launching %s", package)
    adb(f"monkey -p {package} -c android.intent.category.LAUNCHER 1")
    time.sleep(8)


def find_button_coords(button_text: str) -> tuple[int, int] | None:
    """Dump UI and find coordinates for a specific button."""
    log.info("Searching for button: '%s'", button_text)
    root = dump_ui()
    if root is None:
        return None
    return find_element_coords(root, button_text)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Android login automation")
    parser.add_argument("--email", default=os.getenv("TEST_EMAIL"), help="Test account email")
    parser.add_argument("--password", default=os.getenv("TEST_PASSWORD"), help="Test account password")
    parser.add_argument("--package", default=os.getenv("TARGET_PACKAGE", ""), help="App package to launch after login")
    parser.add_argument("--sso-button", default="", help="Text of SSO button to locate (e.g. 'Continue with Google')")
    args = parser.parse_args()

    if not args.email or not args.password:
        log.error("Email and password are required (via args or TEST_EMAIL/TEST_PASSWORD env vars)")
        return 1

    # Step 1: Login
    success = run_login_flow(args.email, args.password)
    if not success:
        log.error("Login flow failed")
        return 1

    log.info("Login completed successfully")

    # Step 2: Launch app if package specified
    if args.package:
        launch_app(args.package)

        # Step 3: Find SSO button if requested
        if args.sso_button:
            coords = find_button_coords(args.sso_button)
            if coords:
                log.info("SSO button '%s' found at (%d, %d)", args.sso_button, coords[0], coords[1])
                tap(coords[0], coords[1], f"SSO button: {args.sso_button}")
            else:
                log.warning("SSO button '%s' not found", args.sso_button)

    return 0


if __name__ == "__main__":
    sys.exit(main())
