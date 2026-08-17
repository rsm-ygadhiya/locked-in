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
    passcode         PBKDF2 hash of the unlock passcode
    recording        which of screen / camera / audio to capture
    cloud            the Supabase project behind the Student / Faculty flow;
                     empty means this machine runs standalone, as it always did

The passcode is not stored — only a PBKDF2-HMAC-SHA256 hash with a random 16-byte
salt and 200,000 iterations. So a student who opens the config file finds no usable
secret, which is the whole reason this file exists. (The anon key in the cloud block
is not a secret; see the note on DEFAULT_CLOUD.)

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
    python3 lockedin_config.py get-cloud        print the cloud block as JSON
    python3 lockedin_config.py cloud-enabled    exit 0 if a Supabase project is set
    python3 lockedin_config.py verify-passcode  read passcode on STDIN; exit 0 if correct

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
DEFAULT_PASSCODE = "letmeout"

# The proctoring backend. Empty url/anon_key means this machine runs in the
# original standalone mode: no accounts, no approval gate, nothing leaves the
# laptop. Filling these in is what turns on the Student / Faculty flow.
#
# The anon key belongs here despite being a "key": Supabase publishes it to
# browsers and desktop apps by design, and every access rule is enforced by the
# Row Level Security policies in cloud/schema.sql. The service_role key must
# never be pasted here — it bypasses all of them.
DEFAULT_CLOUD = {
    "url": "",
    "anon_key": "",
    # A campus ID typed at the login screen is expanded into an address with
    # this domain, because Supabase authenticates on email and students know
    # their ID. A12345678 -> A12345678@ucsd.edu.
    "id_email_domain": "ucsd.edu",
    # Where the faculty dashboard is published; the Faculty button opens it.
    "dashboard_url": "",
    # Live monitoring: how often a thumbnail is published, and how wide it is.
    # 3s at 640px is roughly 20 KB per student per stream per tick, which is what
    # keeps a class inside a free tier.
    "live_interval": 3.0,
    "live_width": 640,
}


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
        "passcode": hash_secret(DEFAULT_PASSCODE),
        "passcode_is_default": True,
        "recording": {"screen": True, "camera": True, "audio": True},
        "cloud": dict(DEFAULT_CLOUD),
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
    # The nested blocks need the same treatment one level down, or a config
    # written before a key existed comes back missing it.
    for block in ("recording", "cloud"):
        nested = dict(defaults()[block])
        nested.update(config.get(block) or {})
        merged[block] = nested
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

def set_passcode(config: dict, new_passcode: str) -> None:
    config["passcode"] = hash_secret(new_passcode)
    config["passcode_is_default"] = new_passcode == DEFAULT_PASSCODE


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

    if command == "get-cloud":
        print(json.dumps(config["cloud"], indent=2))
        return 0

    if command == "cloud-enabled":
        # Exit status, so a shell script can branch on it without parsing output.
        cloud = config["cloud"]
        return 0 if cloud.get("url") and cloud.get("anon_key") else 1

    if command == "verify-passcode":
        # Trailing newline from the shell's pipe is not part of the passcode.
        entry = sys.stdin.read().rstrip("\r\n")
        return 0 if verify_passcode(config, entry) else 1

    print(f"unknown command: {command}", file=sys.stderr)
    print(__doc__.strip(), file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
