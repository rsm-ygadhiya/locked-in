# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
serve.py — publish the proctor dashboard on your own wi-fi.

`dashboard/index.html` is one self-contained page. Opened as a file:// URL it works
perfectly, but only on the machine holding the file — which is no use when you want
the live grid on an iPad next to you, or on a second laptop at the front of the room.

This puts the same page on the local network instead:

    uv run --script server/serve.py

    Dashboard, on this machine : http://127.0.0.1:8765/
    Dashboard, on your wi-fi   : http://192.168.1.23:8765/
                                 http://desk-mac.local:8765/
    Enrol a student machine    : uv run --script src/lockedin_config.py enroll http://192.168.1.23:8765

Any device on the same network opens that address in a browser — phone, tablet, the
laptop you actually want to sit behind. Nothing about the exam changes: the page still
talks to Supabase directly, so students keep working over wi-fi or cellular, and this
server only ever hands out the page itself.

Usage:
    serve.py                  serve in this terminal; Ctrl+C stops it
    serve.py --ensure         start one in the background if none is running,
                              then print its address (what the Faculty button uses)
    serve.py --status         print the running server's address; exit 1 if none
    serve.py --stop           stop the background server
    serve.py --port 9000      pick the port (default 8765)
    serve.py --local-only     bind to 127.0.0.1, so nobody else on the wi-fi can reach it

What it serves:
    /            the dashboard, with the Supabase project from this machine's
                 settings patched in, so the page and the app can never disagree
    /setup.json  the proctoring settings, for enrolling another student machine
    /enroll      that same thing as a page you can read off a phone
    /healthz     so --ensure can tell a live server from a stale pid file

Who can reach it: everyone on the network, without signing in. That is the same
exposure as publishing the page to GitHub Pages, which SETUP.md already suggests —
the page carries the anon key, which is public by design, and every access rule lives
in the database policies. A visitor still has to sign in as a proctor to see a single
student. Do not add anything secret to the page.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.parse import urlsplit
from urllib.request import urlopen

HERE = Path(__file__).resolve().parent

# The helpers sit next to this file inside the .app bundle, and one level up in the
# repo. Look in both rather than assuming a layout.
for _candidate in (HERE, HERE.parent / "src", HERE.parent):
    if (_candidate / "lockedin_config.py").exists():
        sys.path.insert(0, str(_candidate))
        break
import lockedin_config as store   # noqa: E402

DEFAULT_PORT = 8765
HEALTH_BODY = b"locked-in dashboard server\n"


def dashboard_dir() -> Path:
    """Where index.html lives — beside this file in the bundle, in server/ in the repo."""
    for candidate in (HERE / "dashboard", HERE.parent / "server" / "dashboard"):
        if (candidate / "index.html").exists():
            return candidate
    raise SystemExit("dashboard/index.html was not found next to serve.py.")


def state_path() -> Path:
    """Beside the settings file, so both platforms get a sensible per-user location."""
    return store.config_path().parent / "dashboard-server.json"


def log_path() -> Path:
    return store.config_path().parent / "dashboard-server.log"


# ---------------------------------------------------------------------------
# the page
# ---------------------------------------------------------------------------

def dashboard_html() -> bytes:
    """
    index.html with this machine's Supabase project patched in.

    SETUP.md has you type the URL and the anon key into the page *and* into the exam
    settings. Two copies of the same two values drift, and when they drift the
    dashboard watches a different project than the students are uploading to — which
    looks exactly like "nobody is joining my exam". Serving the page instead of
    opening the file lets us settle it: the settings file wins.
    """
    html = (dashboard_dir() / "index.html").read_text(encoding="utf-8")
    cloud = store.load(create=True).get("cloud") or {}
    values = {
        "SUPABASE_URL": (cloud.get("url") or "").rstrip("/"),
        "SUPABASE_ANON_KEY": cloud.get("anon_key") or "",
        "ID_EMAIL_DOMAIN": cloud.get("id_email_domain") or "",
    }
    for name, value in values.items():
        if not value:
            continue   # nothing configured here — leave whatever the file says
        pattern = re.compile(r'(const\s+' + name + r'\s*=\s*)"[^"]*"')
        html = pattern.sub(lambda m: m.group(1) + json.dumps(value), html, count=1)
    return html.encode("utf-8")


def setup_payload() -> tuple[int, bytes]:
    """The proctoring block, for `lockedin_config.py enroll` on another machine."""
    cloud = store.load(create=True).get("cloud") or {}
    if not cloud.get("url") or not cloud.get("anon_key"):
        body = {"error": "This machine has no Supabase project configured yet. "
                         "Set one under Faculty > Exam settings > Proctoring first."}
        return 409, json.dumps(body, indent=2).encode()
    payload = {
        "url": cloud.get("url", ""),
        "anon_key": cloud.get("anon_key", ""),
        "id_email_domain": cloud.get("id_email_domain", "ucsd.edu"),
        "live_interval": cloud.get("live_interval", 3.0),
        "live_width": cloud.get("live_width", 640),
    }
    return 200, json.dumps(payload, indent=2).encode()


ENROLL_PAGE = """<!doctype html>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Locked In — add a machine to this exam</title>
<style>
 body{{background:#0b0f0c;color:#d7ffe4;font:16px/1.6 -apple-system,Segoe UI,system-ui,sans-serif;
      margin:0;padding:32px 20px;display:flex;justify-content:center}}
 main{{max-width:640px;width:100%}}
 h1{{font-size:22px;margin:0 0 4px}} p{{color:#9dbfa9}}
 code,pre{{background:#111a14;border:1px solid #1f3527;border-radius:8px;color:#7ef0a5}}
 pre{{padding:14px;overflow-x:auto;font-size:14px}} code{{padding:2px 6px;font-size:14px}}
 li{{margin:10px 0}} .n{{color:#5f8f72;font-size:14px}}
</style>
<main>
<h1>Add another machine to this exam</h1>
<p>Run this on the student machine, in the Locked In folder. It copies the exam
settings across — project, key, ID domain — so that machine joins the same exams.</p>
<pre>uv run --script src/lockedin_config.py enroll {base}</pre>
<p>No terminal on that machine? Open Locked In there, choose <b>Faculty &rsaquo; Exam
settings &rsaquo; Proctoring</b>, and type these in by hand:</p>
<ul>
  <li>Project URL &mdash; <code>{url}</code></li>
  <li>Anon key &mdash; <code>{key}</code></li>
  <li>ID email domain &mdash; <code>{domain}</code></li>
</ul>
<p class="n">Proctoring from a second device instead? Just open <code>{base}/</code>
in its browser &mdash; that is the dashboard.</p>
</main>
"""


def enroll_html(base: str) -> bytes:
    cloud = store.load(create=True).get("cloud") or {}
    return ENROLL_PAGE.format(
        base=base,
        url=cloud.get("url") or "(not set on this machine yet)",
        key=cloud.get("anon_key") or "(not set on this machine yet)",
        domain=cloud.get("id_email_domain") or "ucsd.edu",
    ).encode("utf-8")


# ---------------------------------------------------------------------------
# the server
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "LockedIn"

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        # The page reads its own settings and nothing else; a stale copy after the
        # project changes would be the confusing kind of wrong.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self) -> None:   # noqa: N802 — BaseHTTPRequestHandler's spelling
        self.do_GET()

    def do_GET(self) -> None:    # noqa: N802
        path = urlsplit(self.path).path
        base = f"http://{self.headers.get('Host') or self.server.server_address[0]}"
        try:
            if path in ("/", "/index.html"):
                self._send(200, dashboard_html(), "text/html; charset=utf-8")
            elif path == "/healthz":
                self._send(200, HEALTH_BODY, "text/plain; charset=utf-8")
            elif path == "/setup.json":
                status, body = setup_payload()
                self._send(status, body, "application/json; charset=utf-8")
            elif path == "/enroll":
                self._send(200, enroll_html(base), "text/html; charset=utf-8")
            else:
                self._send(404, b"not found\n", "text/plain; charset=utf-8")
        except BrokenPipeError:
            pass   # the browser went away mid-response; not worth a traceback
        except Exception as error:                      # noqa: BLE001
            self._send(500, f"{error}\n".encode(), "text/plain; charset=utf-8")

    def log_message(self, fmt: str, *args) -> None:
        # One tidy line per request instead of the default's two-line format.
        sys.stderr.write("%s  %s\n" % (self.log_date_time_string(), fmt % args))


def free_port(host: str, first: int, tries: int = 12) -> int:
    """The first port from `first` upwards that nothing else is sitting on."""
    for port in range(first, first + tries):
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((host, port))
            return port
        except OSError:
            continue
        finally:
            probe.close()
    raise SystemExit(f"ports {first}-{first + tries - 1} are all in use.")


def addresses(port: int, local_only: bool) -> list[str]:
    """Every address worth printing, best first."""
    if local_only:
        return [f"http://127.0.0.1:{port}"]
    out = []
    ip = store.lan_ip()
    if ip and ip != "127.0.0.1":
        out.append(f"http://{ip}:{port}")
    host = socket.gethostname().split(".")[0]
    if host:
        # macOS and iOS resolve .local names, so this survives a DHCP lease change.
        out.append(f"http://{host}.local:{port}")
    out.append(f"http://127.0.0.1:{port}")
    return out


def serve(port: int, local_only: bool) -> int:
    host = "127.0.0.1" if local_only else "0.0.0.0"
    dashboard_dir()   # fail now, loudly, rather than on the first request
    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    urls = addresses(port, local_only)
    state_path().write_text(json.dumps({
        "pid": os.getpid(), "port": port, "url": urls[0],
        "urls": urls, "local_only": local_only,
    }, indent=2) + "\n", encoding="utf-8")

    print(f"Dashboard, on this machine : {urls[-1]}/")
    if not local_only:
        for index, extra in enumerate(urls[:-1]):
            label = "Dashboard, on your wi-fi   : " if index == 0 else " " * 29
            print(f"{label}{extra}/")
        print(f"Enrol a student machine    : uv run --script src/lockedin_config.py "
              f"enroll {urls[0]}")
    print("Ctrl+C to stop.\n", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")
    finally:
        httpd.server_close()
        _clear_state(os.getpid())
    return 0


# ---------------------------------------------------------------------------
# background copy: --ensure / --status / --stop
# ---------------------------------------------------------------------------

def _clear_state(only_pid: int | None = None) -> None:
    path = state_path()
    try:
        if only_pid is not None:
            state = json.loads(path.read_text(encoding="utf-8"))
            if int(state.get("pid", -1)) != only_pid:
                return
        path.unlink()
    except (OSError, ValueError):
        pass


def running() -> dict | None:
    """The live server's state, or None. A pid file alone is not evidence."""
    try:
        state = json.loads(state_path().read_text(encoding="utf-8"))
        port = int(state["port"])
    except (OSError, ValueError, KeyError):
        return None
    try:
        with urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1.5) as response:
            if response.read() != HEALTH_BODY:
                return None            # something else answers on that port now
    except (URLError, OSError):
        _clear_state()
        return None
    return state


def start_detached(port: int, local_only: bool) -> dict:
    """
    Launch a copy of this script that outlives whoever asked for it.

    The Faculty button is a launcher that quits as soon as the browser opens, and the
    settings panel gets closed the moment it is saved. Neither is a sensible parent
    for something the proctor needs for the next two hours.
    """
    port = free_port("127.0.0.1" if local_only else "0.0.0.0", port)
    command = [sys.executable, str(Path(__file__).resolve()), "--port", str(port)]
    if local_only:
        command.append("--local-only")
    log = open(log_path(), "a", encoding="utf-8")   # noqa: SIM115 — child owns it
    extras: dict = {}
    if os.name == "nt":
        DETACHED_PROCESS = 0x00000008
        extras["creationflags"] = DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        extras["start_new_session"] = True
    subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                     cwd=str(HERE), **extras)
    deadline = time.time() + 12
    while time.time() < deadline:
        state = running()
        if state:
            return state
        time.sleep(0.25)
    raise SystemExit(f"the dashboard server did not come up; see {log_path()}")


def stop() -> int:
    state = running()
    if not state:
        _clear_state()
        print("no dashboard server is running.")
        return 0
    pid = int(state.get("pid", -1))
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True, check=False)
        else:
            os.kill(pid, 15)
    except OSError as error:
        print(f"could not stop pid {pid}: {error}")
        return 1
    _clear_state()
    print(f"stopped the dashboard server (pid {pid}).")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Serve the proctor dashboard on the local network.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--local-only", action="store_true",
                        help="bind to 127.0.0.1 only")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--ensure", action="store_true",
                       help="start one in the background if needed, print its address")
    group.add_argument("--status", action="store_true")
    group.add_argument("--stop", action="store_true")
    args = parser.parse_args(argv)

    if args.stop:
        return stop()

    if args.status:
        state = running()
        if not state:
            print("no dashboard server is running.")
            return 1
        print(state["url"] + "/")
        return 0

    if args.ensure:
        state = running() or start_detached(args.port, args.local_only)
        # One bare line on stdout: the launchers read this and open it.
        print(state["url"] + "/")
        return 0

    return serve(free_port("127.0.0.1" if args.local_only else "0.0.0.0", args.port),
                 args.local_only)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
