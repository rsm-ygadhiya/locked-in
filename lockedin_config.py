# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
lockedin_config.py — the settings store behind Locked In, plus the CLI the lockdown
scripts use to read it.

Everything configurable now lives in one JSON file instead of being edited into the
top of guided-access.command / guided-access.ps1:

    allowed_url      the one site the session is pinned to
    allowed_hosts    hostnames Chrome is still allowed to load (SSO, 2FA, ...)
    admin            username + PBKDF2 hash of the admin-panel password
    passcode         PBKDF2 hash of the unlock passcode
    recording        which of screen / camera / audio to capture

Neither password is stored — only a PBKDF2-HMAC-SHA256 hash with a random 16-byte salt
and 200,000 iterations. So a student who opens the config file finds no usable secret,
which is the whole reason this file exists.

What that does NOT do — say so plainly to anyone approving this tool: whoever
administers the machine can still delete or replace this file and set their own
passcode, and a weak passcode can still be attacked offline once the file is copied.
This raises the cost of casually reading the passcode out of a script. It is not a
security boundary against the machine's own owner.

CLI (used by the lockdown scripts; all output is plain text on stdout):

    python3 lockedin_config.py init             create the file with defaults if absent
    python3 lockedin_config.py path             print the config file location
    python3 lockedin_config.py get-url          print the allowed URL
    python3 lockedin_config.py get-hosts        print allowed hosts, one per line
    python3 lockedin_config.py get-recording    print "screen camera audio" as 3 bools
    python3 lockedin_config.py verify-passcode  read passcode on STDIN; exit 0 if correct
    python3 lockedin_config.py verify-admin     read "user\\npassword" on STDIN; exit 0 if ok

Secrets are read from stdin, never taken as arguments — an argument would be visible
to every other process on the machine via the process list.
"""

from __future__ import annotations

import json
import os
import platform
import secrets
import sys
from hashlib import pbkdf2_hmac
from pathlib import Path

ITERATIONS = 200_000
DEFAULT_URL = "https://rsm-django-02.ucsd.edu/video-exam/station/"
DEFAULT_HOSTS = ["rsm-django-02.ucsd.edu", "ucsd.edu", "duosecurity.com"]
DEFAULT_ADMIN_USER = "admin"
DEFAULT_ADMIN_PASSWORD = "admin"
DEFAULT_PASSCODE = "letmeout"


def config_path() -> Path:
    """Where the settings live, per platform. LOCKEDIN_CONFIG overrides it."""
    override = os.environ.get("LOCKEDIN_CONFIG")
    if override:
        # Lets you keep a separate config for testing, or point a whole lab of
        # machines at one prepared file.
        return Path(override).expanduser()
    if platform.system() == "Windows":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    elif platform.system() == "Darwin":
        base = Path.home() / "Library" / "Application Support"
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "LockedIn" / "config.json"


# ---------- hashing ----------

def hash_secret(secret: str, *, salt: bytes | None = None,
                iterations: int = ITERATIONS) -> dict:
    """A stored-password record: algorithm, salt, iteration count, digest."""
    salt = salt or secrets.token_bytes(16)
    digest = pbkdf2_hmac("sha256", secret.encode("utf-8"), salt, iterations)
    return {
        "algorithm": "pbkdf2-sha256",
        "salt": salt.hex(),
        "iterations": iterations,
        "hash": digest.hex(),
    }


def check_secret(record: dict, candidate: str) -> bool:
    """Constant-time comparison against a stored record."""
    try:
        digest = pbkdf2_hmac(
            "sha256",
            candidate.encode("utf-8"),
            bytes.fromhex(record["salt"]),
            int(record["iterations"]),
        )
    except (KeyError, ValueError):
        return False
    # compare_digest, not ==, so a wrong guess can't be narrowed down by timing.
    return secrets.compare_digest(digest.hex(), record.get("hash", ""))


# ---------- load / save ----------

def defaults() -> dict:
    return {
        "version": 1,
        "allowed_url": DEFAULT_URL,
        "allowed_hosts": list(DEFAULT_HOSTS),
        "admin": {
            "username": DEFAULT_ADMIN_USER,
            "password": hash_secret(DEFAULT_ADMIN_PASSWORD),
            # Flipped to False by the admin panel the first time both defaults are
            # changed; the panel warns while this is True.
            "is_default": True,
        },
        "passcode": hash_secret(DEFAULT_PASSCODE),
        "passcode_is_default": True,
        "recording": {"screen": True, "camera": True, "audio": True},
    }


def load(create: bool = True) -> dict:
    path = config_path()
    if not path.exists():
        if not create:
            raise FileNotFoundError(path)
        config = defaults()
        save(config)
        return config
    with path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
    # Merge in anything a newer version added, so an old file keeps working.
    merged = defaults()
    merged.update(config)
    return merged


def save(config: dict) -> Path:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    # Write to a temp file and swap, so a crash mid-write can't leave a truncated
    # config that would lock the admin out of their own settings.
    temp = path.with_suffix(".json.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.replace(temp, path)
    try:
        path.chmod(0o600)   # owner-only; no-op on Windows, worth having on macOS
    except OSError:
        pass
    return path


# ---------- mutations used by the admin panel ----------

def set_admin_password(config: dict, new_password: str) -> None:
    config["admin"]["password"] = hash_secret(new_password)
    config["admin"]["is_default"] = new_password == DEFAULT_ADMIN_PASSWORD


def set_passcode(config: dict, new_passcode: str) -> None:
    config["passcode"] = hash_secret(new_passcode)
    config["passcode_is_default"] = new_passcode == DEFAULT_PASSCODE


def verify_admin(config: dict, username: str, password: str) -> bool:
    if username.strip().lower() != str(config["admin"]["username"]).strip().lower():
        # Still run the hash so a wrong username and a wrong password take the
        # same amount of time.
        check_secret(config["admin"]["password"], password)
        return False
    return check_secret(config["admin"]["password"], password)


def verify_passcode(config: dict, entry: str) -> bool:
    return check_secret(config["passcode"], entry)


# ---------- CLI ----------

def main(argv: list[str]) -> int:
    command = argv[0] if argv else "help"

    if command == "help":
        print(__doc__.strip())
        return 0

    if command == "init":
        path = config_path()
        existed = path.exists()
        load(create=True)
        print(f"{'found' if existed else 'created'} {path}")
        return 0

    if command == "path":
        print(config_path())
        return 0

    config = load(create=True)

    if command == "get-url":
        print(config["allowed_url"])
        return 0

    if command == "get-hosts":
        for host in config["allowed_hosts"]:
            print(host)
        return 0

    if command == "get-recording":
        rec = config["recording"]
        print(" ".join("true" if rec.get(k, True) else "false"
                       for k in ("screen", "camera", "audio")))
        return 0

    if command == "verify-passcode":
        # Trailing newline from the shell's pipe is not part of the passcode.
        entry = sys.stdin.read().rstrip("\r\n")
        return 0 if verify_passcode(config, entry) else 1

    if command == "verify-admin":
        lines = sys.stdin.read().splitlines()
        if len(lines) < 2:
            return 1
        return 0 if verify_admin(config, lines[0], lines[1]) else 1

    print(f"unknown command: {command}", file=sys.stderr)
    print(__doc__.strip(), file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
