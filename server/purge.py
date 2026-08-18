# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
purge.py — delete old exam sessions, and the identity photos that came with them.

Retention is the part of a proctoring system that people skip, so this is a single
command a proctor can run — or put on a cron — once grades are in:

    uv run --script server/purge.py --days 30            # ask first, then delete
    uv run --script server/purge.py --days 30 --yes      # no prompt, for cron
    uv run --script server/purge.py --days 30 --dry-run  # just show what would go

Order matters, and it is the reason this is a script rather than one line of SQL.
Supabase guards storage.objects against direct deletion, because removing a row
there only drops the metadata and leaves the real file orphaned in the storage
backend where nothing can find it again. So the files have to go through the
Storage API first, and only then can the session rows be deleted.

It signs in as a proctor and works entirely within that account's own exams — the
policies in schema.sql see to that. No service_role key, which means this is safe
to keep next to the rest of the project.
"""

from __future__ import annotations

import argparse
import getpass
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import lockedin_cloud as lc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Delete old Locked In sessions")
    parser.add_argument("--days", type=int, default=30,
                       help="delete sessions older than this many days (default 30)")
    parser.add_argument("--id", help="proctor campus ID or email (prompted if absent)")
    parser.add_argument("--password", help="prompted if absent; avoid on a shared box")
    parser.add_argument("--dry-run", action="store_true",
                       help="list what would be deleted and stop")
    parser.add_argument("--yes", action="store_true", help="skip the confirmation")
    args = parser.parse_args(argv)

    if args.days < 0:
        print("--days cannot be negative", file=sys.stderr)
        return 64

    try:
        cloud = lc.Cloud.from_config()
    except lc.NotConfigured as error:
        print(f"purge: {error}", file=sys.stderr)
        return 2

    identifier = args.id or input("proctor campus ID or email: ").strip()
    password = args.password or getpass.getpass("password: ")
    try:
        session = cloud.sign_in(identifier, password)
    except lc.CloudError as error:
        print(f"purge: sign-in failed: {error}", file=sys.stderr)
        return 1
    if session.role != "faculty":
        print("purge: that account is not a proctor, so it owns no exams to purge",
              file=sys.stderr)
        return 1
    print(f"signed in as {session.email}")

    # What is old enough to go. session_files() is scoped to this proctor's exams.
    try:
        files = cloud._json("POST", "/rest/v1/rpc/session_files",
                            payload={"older_than_days": args.days}) or []
    except lc.CloudError as error:
        print(f"purge: could not list files: {error}", file=sys.stderr)
        return 1

    if not files:
        print(f"nothing older than {args.days} days — nothing to do")
        return 0

    sessions = sorted({row["path"].split("/")[0] for row in files})
    print(f"\n{len(sessions)} session(s) older than {args.days} days, "
          f"up to {len(files)} file(s):")
    for session_id in sessions:
        print(f"  {session_id}")

    if args.dry_run:
        print("\n--dry-run: nothing was deleted")
        return 0

    if not args.yes:
        print("\nThis permanently deletes those sessions, their ID photos and "
              "check-in photos.")
        if input('Type "delete" to confirm: ').strip().lower() != "delete":
            print("cancelled")
            return 1

    # 1. Files, through the Storage API. A file that is already gone is not an
    #    error worth stopping for — the goal is that it no longer exists.
    deleted = missing = failed = 0
    for row in files:
        bucket, path = row["bucket"], row["path"]
        try:
            cloud._request("DELETE", f"/storage/v1/object/{bucket}/{path}")
            deleted += 1
        except lc.CloudError as error:
            if "not found" in str(error).lower() or "404" in str(error):
                missing += 1
            else:
                failed += 1
                print(f"  could not delete {bucket}/{path}: {error}", file=sys.stderr)

    print(f"\nfiles: {deleted} deleted, {missing} already gone, {failed} failed")

    # 2. Only now the rows. Stopping here on a file failure is deliberate: a session
    #    row is the only thing that can still find its files, so dropping the row
    #    while a file survives is what creates an unreachable orphan.
    if failed:
        print("some files could not be deleted, so the session rows were kept —\n"
              "fix the errors above and run this again", file=sys.stderr)
        return 1

    try:
        removed = cloud._json("POST", "/rest/v1/rpc/purge_old_sessions",
                              payload={"older_than_days": args.days})
    except lc.CloudError as error:
        print(f"purge: files are gone but the rows could not be deleted: {error}",
              file=sys.stderr)
        return 1

    print(f"sessions deleted: {removed}")
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
