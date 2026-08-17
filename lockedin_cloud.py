# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
lockedin_cloud.py — everything Locked In needs from Supabase, over plain HTTPS.

Supabase is three REST APIs behind one hostname, and all three are reachable with
nothing but urllib:

    /auth/v1      sign in, refresh a token          (GoTrue)
    /rest/v1      read and write the tables         (PostgREST)
    /storage/v1   upload the photos and thumbnails  (Storage)

So this file has no dependencies. That is deliberate: the student app already has
to work on a machine where the only guarantee is a Python interpreter, and adding
the supabase-py stack (httpx, pydantic, websockets, ...) to that path would mean
one more thing that can fail five minutes before an exam.

The anon key is the only key that ever appears here. It is designed to be public
— it ships inside an app students can open — and every real access rule lives in
the Row Level Security policies in cloud/schema.sql. If you ever find yourself
reaching for the service_role key to make something work, the policy is wrong.

Logging in with an ID rather than an email:
    Supabase authenticates on email, but students know their campus ID. So an
    entry with no "@" is expanded with the configured domain — A12345678 becomes
    A12345678@ucsd.edu — which is a stable, unique, well-formed address. Email
    confirmation must be off in the Supabase project for that to work; see
    cloud/SETUP.md.

Use it as a library (see student_session.py), or check a project from the CLI:

    python3 lockedin_cloud.py check
    python3 lockedin_cloud.py login          # prompts, then prints your role
"""

from __future__ import annotations

import json
import mimetypes
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import lockedin_config

TIMEOUT = 20        # seconds; an exam-morning network is not always a fast one
RETRIES = 3


class CloudError(RuntimeError):
    """Anything that went wrong talking to Supabase, with a readable message."""


class NotConfigured(CloudError):
    """No project URL / anon key yet — the admin panel has not been filled in."""


# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

def cloud_settings(config: dict | None = None) -> dict:
    """The 'cloud' block out of the local config file, with defaults filled in."""
    config = config if config is not None else lockedin_config.load()
    settings = dict(lockedin_config.DEFAULT_CLOUD)
    settings.update(config.get("cloud") or {})
    # Environment overrides win, so a lab machine can be pointed at a test
    # project without editing its config file.
    if os.environ.get("LOCKEDIN_SUPABASE_URL"):
        settings["url"] = os.environ["LOCKEDIN_SUPABASE_URL"]
    if os.environ.get("LOCKEDIN_SUPABASE_ANON_KEY"):
        settings["anon_key"] = os.environ["LOCKEDIN_SUPABASE_ANON_KEY"]
    return settings


def resolve_email(identifier: str, domain: str) -> str:
    """A campus ID becomes an address; something that is already one is left alone."""
    identifier = identifier.strip()
    if "@" in identifier:
        return identifier.lower()
    return f"{identifier}@{domain.lstrip('@')}".lower()


# ---------------------------------------------------------------------------
# the client
# ---------------------------------------------------------------------------

@dataclass
class Session:
    """Who is signed in, and the tokens that prove it."""
    user_id: str
    access_token: str
    refresh_token: str
    expires_at: float
    email: str = ""
    role: str = "student"
    full_name: str = ""
    campus_id: str = ""


@dataclass
class Cloud:
    url: str
    anon_key: str
    id_email_domain: str = "ucsd.edu"
    session: Session | None = None
    # Verifying TLS is the point of using HTTPS; this is here so a machine with a
    # broken certificate store can be diagnosed, not so it can be ignored.
    verify_tls: bool = True
    _ssl: Any = field(default=None, repr=False)

    @classmethod
    def from_config(cls, config: dict | None = None) -> Cloud:
        settings = cloud_settings(config)
        if not settings.get("url") or not settings.get("anon_key"):
            raise NotConfigured(
                "This machine has no Supabase project configured yet. Open the "
                "Locked In admin panel and paste the project URL and anon key "
                "from Supabase > Project Settings > API."
            )
        return cls(
            url=str(settings["url"]).rstrip("/"),
            anon_key=str(settings["anon_key"]).strip(),
            id_email_domain=str(settings.get("id_email_domain") or "ucsd.edu"),
        )

    # ---------- plumbing ----------

    def _context(self):
        if self._ssl is None:
            self._ssl = ssl.create_default_context()
            if not self.verify_tls:
                self._ssl.check_hostname = False
                self._ssl.verify_mode = ssl.CERT_NONE
        return self._ssl

    def _request(self, method: str, path: str, *, body: bytes | None = None,
                 headers: dict[str, str] | None = None, params: dict | None = None,
                 auth: bool = True, retry_on_401: bool = True) -> tuple[int, bytes, dict]:
        target = f"{self.url}{path}"
        if params:
            target += "?" + urllib.parse.urlencode(params, doseq=True)

        head = {"apikey": self.anon_key, "Accept": "application/json"}
        if auth:
            token = self.access_token()
            head["Authorization"] = f"Bearer {token or self.anon_key}"
        head.update(headers or {})

        last: Exception | None = None
        for attempt in range(RETRIES):
            request = urllib.request.Request(target, data=body, method=method,
                                             headers=head)
            try:
                with urllib.request.urlopen(request, timeout=TIMEOUT,
                                            context=self._context()) as response:
                    return response.status, response.read(), dict(response.headers)
            except urllib.error.HTTPError as error:
                payload = error.read()
                # An expired access token looks like a hard failure but is not:
                # refresh once and replay the request.
                if error.code == 401 and auth and retry_on_401 and self.session:
                    if self._refresh():
                        return self._request(method, path, body=body, headers=headers,
                                             params=params, auth=auth,
                                             retry_on_401=False)
                raise CloudError(self._explain(error.code, payload)) from None
            except (urllib.error.URLError, TimeoutError, ssl.SSLError) as error:
                # Transient: a dropped wifi packet should not end an exam.
                last = error
                if attempt < RETRIES - 1:
                    time.sleep(1.5 * (attempt + 1))
        raise CloudError(f"could not reach {self.url}: {last}")

    @staticmethod
    def _explain(status: int, payload: bytes) -> str:
        """Turn a Supabase error body into one sentence worth showing a student."""
        text = payload.decode("utf-8", "replace").strip()
        try:
            data = json.loads(text)
            for key in ("msg", "message", "error_description", "error", "hint"):
                if isinstance(data.get(key), str) and data[key]:
                    text = data[key]
                    break
        except (ValueError, AttributeError):
            pass
        friendly = {
            400: "the server rejected that request",
            401: "not signed in, or the session expired",
            403: "not allowed — the account may lack permission for this",
            404: "that endpoint does not exist on this project",
            409: "that already exists",
            413: "that file is too large",
            429: "too many requests just now — wait a moment",
        }
        lead = friendly.get(status, f"HTTP {status}")
        return f"{lead}: {text}" if text else lead

    def _json(self, method: str, path: str, *, payload: Any = None,
              headers: dict | None = None, params: dict | None = None,
              auth: bool = True) -> Any:
        body = None
        head = dict(headers or {})
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            head["Content-Type"] = "application/json"
        _, raw, _ = self._request(method, path, body=body, headers=head,
                                  params=params, auth=auth)
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError:
            return None

    # ---------- auth ----------

    def access_token(self) -> str | None:
        if not self.session:
            return None
        if time.time() > self.session.expires_at - 60:
            self._refresh()
        return self.session.access_token

    def _adopt(self, data: dict, email: str = "") -> Session:
        user = data.get("user") or {}
        self.session = Session(
            user_id=user.get("id", ""),
            access_token=data.get("access_token", ""),
            refresh_token=data.get("refresh_token", ""),
            expires_at=time.time() + float(data.get("expires_in") or 3600),
            email=user.get("email", email),
        )
        return self.session

    def _refresh(self) -> bool:
        if not self.session or not self.session.refresh_token:
            return False
        try:
            data = self._json(
                "POST", "/auth/v1/token",
                params={"grant_type": "refresh_token"},
                payload={"refresh_token": self.session.refresh_token},
                auth=False,
                headers={"Authorization": f"Bearer {self.anon_key}"},
            )
        except CloudError:
            return False
        if not isinstance(data, dict) or not data.get("access_token"):
            return False
        keep = self.session
        self._adopt(data, keep.email)
        # The profile fields are not in the token response; carry them over.
        if self.session:
            self.session.role = keep.role
            self.session.full_name = keep.full_name
            self.session.campus_id = keep.campus_id
        return True

    def sign_in(self, identifier: str, password: str) -> Session:
        """Sign in with a campus ID (or an email) and a password."""
        email = resolve_email(identifier, self.id_email_domain)
        data = self._json(
            "POST", "/auth/v1/token",
            params={"grant_type": "password"},
            payload={"email": email, "password": password},
            auth=False,
            headers={"Authorization": f"Bearer {self.anon_key}"},
        )
        if not isinstance(data, dict) or not data.get("access_token"):
            raise CloudError("that ID and password were not accepted")
        session = self._adopt(data, email)
        self._load_profile()
        return session

    def sign_up(self, identifier: str, password: str, full_name: str) -> Session:
        """
        Register a new account. Always lands as a student — the role is set by the
        database trigger, never by the client, so this cannot mint a proctor.
        """
        email = resolve_email(identifier, self.id_email_domain)
        campus_id = identifier.strip() if "@" not in identifier else email.split("@")[0]
        data = self._json(
            "POST", "/auth/v1/signup",
            payload={
                "email": email,
                "password": password,
                "data": {"full_name": full_name.strip(), "campus_id": campus_id},
            },
            auth=False,
            headers={"Authorization": f"Bearer {self.anon_key}"},
        )
        if not isinstance(data, dict):
            raise CloudError("the server did not accept that registration")

        if not data.get("access_token"):
            # Two very different situations produce this identical response, and
            # Supabase makes them identical on purpose so that signup cannot be used
            # to discover which addresses are already registered:
            #   * the account already exists
            #   * the account is new but the project requires email confirmation
            #
            # Trying to sign in separates them, and in the first case it is also the
            # thing the student wanted anyway — so a returning student who hits
            # "create an account" out of habit just gets signed in.
            try:
                return self.sign_in(identifier, password)
            except CloudError:
                pass
            raise CloudError(
                "That could not be signed in. Either this ID is already registered "
                "with a different password — go back and sign in instead — or this "
                "project still has 'Confirm email' switched on, which your proctor "
                "needs to turn off in Supabase > Authentication > Sign In / "
                "Providers > Email."
            )

        self._adopt(data, email)
        self._load_profile()
        return self.session          # type: ignore[return-value]

    def _load_profile(self) -> None:
        if not self.session:
            return
        rows = self._json("GET", "/rest/v1/profiles",
                          params={"select": "role,full_name,campus_id",
                                  "id": f"eq.{self.session.user_id}", "limit": 1})
        if isinstance(rows, list) and rows:
            self.session.role = rows[0].get("role") or "student"
            self.session.full_name = rows[0].get("full_name") or ""
            self.session.campus_id = rows[0].get("campus_id") or ""

    @property
    def is_faculty(self) -> bool:
        return bool(self.session and self.session.role == "faculty")

    # ---------- exams ----------

    def exam_by_code(self, join_code: str) -> dict | None:
        """Resolve a join code to an open exam, or None if there is no such exam."""
        code = join_code.strip().upper()
        rows = self._json("GET", "/rest/v1/exams",
                          params={"select": "id,title,allowed_url,is_open,join_code",
                                  "join_code": f"eq.{code}", "limit": 1})
        if isinstance(rows, list) and rows:
            return rows[0]
        return None

    # ---------- sessions ----------

    def my_session(self, exam_id: str) -> dict | None:
        """This student's existing attempt at an exam, if there is one."""
        if not self.session:
            raise CloudError("not signed in")
        rows = self._json("GET", "/rest/v1/sessions",
                          params={"select": "*", "exam_id": f"eq.{exam_id}",
                                  "student_id": f"eq.{self.session.user_id}",
                                  "limit": 1})
        if isinstance(rows, list) and rows:
            return rows[0]
        return None

    def open_session(self, exam_id: str, machine: str) -> dict:
        """
        Get the student's attempt at this exam, creating a pending one if needed.
        Returning the existing row matters: reopening the app after a crash should
        rejoin the same session, not queue a second request behind the first.
        """
        existing = self.my_session(exam_id)
        if existing:
            return existing
        if not self.session:
            raise CloudError("not signed in")
        rows = self._json(
            "POST", "/rest/v1/sessions",
            payload={"exam_id": exam_id, "student_id": self.session.user_id,
                     "status": "pending", "machine": machine},
            headers={"Prefer": "return=representation"},
        )
        if isinstance(rows, list) and rows:
            return rows[0]
        raise CloudError("the server did not create a session")

    def patch_session(self, session_id: str, changes: dict) -> dict | None:
        rows = self._json("PATCH", "/rest/v1/sessions", payload=changes,
                          params={"id": f"eq.{session_id}"},
                          headers={"Prefer": "return=representation"})
        if isinstance(rows, list) and rows:
            return rows[0]
        return None

    def session_status(self, session_id: str) -> dict | None:
        rows = self._json("GET", "/rest/v1/sessions",
                          params={"select": "status,reject_reason,decided_at",
                                  "id": f"eq.{session_id}", "limit": 1})
        if isinstance(rows, list) and rows:
            return rows[0]
        return None

    def heartbeat(self, session_id: str) -> None:
        """Say 'still here'. Failure is not fatal — the exam continues offline."""
        try:
            self.patch_session(session_id, {"heartbeat_at": _now_iso()})
        except CloudError:
            pass

    def log_event(self, session_id: str, kind: str, detail: str = "") -> None:
        """Append to the session timeline. Also best-effort."""
        try:
            self._json("POST", "/rest/v1/events",
                       payload={"session_id": session_id, "kind": kind,
                                "detail": detail[:2000]},
                       headers={"Prefer": "return=minimal"})
        except CloudError:
            pass

    # ---------- storage ----------

    def upload(self, bucket: str, path: str, data: bytes,
               content_type: str | None = None, upsert: bool = True) -> str:
        """Put bytes at bucket/path and return the storage path that was written."""
        guessed = content_type or mimetypes.guess_type(path)[0] or "application/octet-stream"
        self._request(
            "POST", f"/storage/v1/object/{bucket}/{urllib.parse.quote(path)}",
            body=data,
            headers={"Content-Type": guessed,
                     "x-upsert": "true" if upsert else "false",
                     "Cache-Control": "no-store"},
        )
        return path

    def upload_file(self, bucket: str, path: str, source: Path) -> str:
        return self.upload(bucket, path, source.read_bytes())

    def put_frame(self, session_id: str, kind: str, jpeg: bytes) -> None:
        """
        Publish the newest thumbnail for one stream: overwrite the image, then
        upsert the row that tells the dashboard when it was taken.
        """
        path = f"{session_id}/{kind}.jpg"
        self.upload("live", path, jpeg, "image/jpeg")
        self._json("POST", "/rest/v1/live_frames",
                   payload={"session_id": session_id, "kind": kind,
                            "storage_path": path, "captured_at": _now_iso()},
                   headers={"Prefer": "resolution=merge-duplicates,return=minimal"})


def _now_iso() -> str:
    import datetime as dt
    return dt.datetime.now(dt.timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# CLI — for checking a project without launching the whole app
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    command = argv[0] if argv else "help"

    if command == "help":
        print(__doc__.strip())
        return 0

    if command == "check":
        settings = cloud_settings()
        if not settings.get("url") or not settings.get("anon_key"):
            print("cloud: not configured (no url / anon_key)")
            return 1
        cloud = Cloud.from_config()
        print(f"cloud: {cloud.url}")
        try:
            # An unauthenticated read of a protected table should come back as an
            # empty list, which proves the URL and key are both good.
            cloud._json("GET", "/rest/v1/exams", params={"select": "id", "limit": 1},
                        auth=True)
            print("cloud: reachable, key accepted")
            return 0
        except CloudError as error:
            print(f"cloud: {error}")
            return 1

    if command == "login":
        import getpass
        cloud = Cloud.from_config()
        identifier = input("campus ID or email: ").strip()
        password = getpass.getpass("password: ")
        try:
            session = cloud.sign_in(identifier, password)
        except CloudError as error:
            print(f"login failed: {error}")
            return 1
        print(f"signed in as {session.email}")
        print(f"role: {session.role}   name: {session.full_name or '(unset)'}")
        return 0

    print(f"unknown command: {command}", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
