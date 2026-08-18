# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
admin_panel.py — the Locked In settings panel.

A small Tk window, so one panel serves both macOS and Windows. It holds the exam
settings — the site the lockdown pins to, the hosts that stay reachable, the unlock
passcode, which streams are recorded, and the Supabase project behind proctored
exams. They are the same settings, in the same file, on either platform.

    uv run --script src/admin_panel.py

Getting in: sign in with your proctor account, the same Supabase account that
approves students in the dashboard. There is no separate admin password any more.
A machine with no project configured yet opens straight into the settings — there
is nothing to authenticate against, and entering the project is the reason you are
there.

The unlock passcode is never written to disk in the clear: it goes through
lockedin_config.hash_secret (PBKDF2-SHA256) and only the hash is stored. See the
honesty note at the top of lockedin_config.py about what that does and doesn't buy.
"""

from __future__ import annotations

import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lockedin_config as store   # noqa: E402

PAD = {"padx": 12, "pady": 6}


class AdminPanel(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Locked In — Exam settings")
        self.resizable(False, False)
        self.config = store.load(create=True)
        # Failed logins cost an increasing wait, so the panel can't be brute-forced
        # by someone sitting in front of it.
        self.failed_logins = 0
        self._build_login()

    # ---------- login ----------

    def _build_login(self) -> None:
        """
        Ask for the proctor's Supabase account.

        There used to be a separate local admin password here. One credential is
        better than two, and this one is already the thing that means "you are the
        proctor" — the same account that approves students in the dashboard.

        The exception is a machine with no project configured yet. There is nothing
        to authenticate against and nothing worth protecting, and the whole point of
        opening the panel then is to enter the project details. So a fresh machine
        opens straight into the settings.
        """
        cloud_ready = bool((self.config.get("cloud") or {}).get("url")
                           and (self.config.get("cloud") or {}).get("anon_key"))
        if not cloud_ready:
            self._build_settings(first_run=True)
            return

        self.login_frame = ttk.Frame(self)
        self.login_frame.grid(row=0, column=0, **PAD)

        ttk.Label(self.login_frame, text="Locked In — Exam settings",
                  font=("", 16, "bold")).grid(row=0, column=0, columnspan=2, pady=(4, 2))
        ttk.Label(self.login_frame, text="Sign in with your proctor account.",
                  foreground="#555").grid(row=1, column=0, columnspan=2, pady=(0, 10))

        ttk.Label(self.login_frame, text="Campus ID").grid(row=2, column=0, sticky="e", **PAD)
        self.user_entry = ttk.Entry(self.login_frame, width=26)
        self.user_entry.grid(row=2, column=1, **PAD)

        ttk.Label(self.login_frame, text="Password").grid(row=3, column=0, sticky="e", **PAD)
        self.password_entry = ttk.Entry(self.login_frame, width=26, show="•")
        self.password_entry.grid(row=3, column=1, **PAD)

        self.login_error = ttk.Label(self.login_frame, text="", foreground="#c0392b",
                                     wraplength=300)
        self.login_error.grid(row=4, column=0, columnspan=2)

        self.login_button = ttk.Button(self.login_frame, text="Sign in",
                                       command=self._try_login)
        self.login_button.grid(row=5, column=0, columnspan=2, pady=(6, 10))

        self.bind("<Return>", lambda _event: self._try_login())
        self.user_entry.focus_set()

    def _try_login(self) -> None:
        username = self.user_entry.get().strip()
        password = self.password_entry.get()
        if not username or not password:
            self.login_error.config(text="Enter your campus ID and password.")
            return

        self.login_button.config(state="disabled")
        self.login_error.config(text="Checking...")
        self.update_idletasks()

        try:
            import lockedin_cloud
        except ImportError:
            self.login_button.config(state="normal")
            self.login_error.config(
                text="lockedin_cloud.py is missing next to this panel.")
            return

        try:
            cloud = lockedin_cloud.Cloud.from_config(self.config)
            session = cloud.sign_in(username, password)
        except lockedin_cloud.CloudError as error:
            self.login_button.config(state="normal")
            self._reject(str(error)[:160])
            return

        if session.role != "faculty":
            self.login_button.config(state="normal")
            self._reject("That is a student account. Only a proctor can change "
                         "these settings.")
            return

        self.failed_logins = 0
        self.unbind("<Return>")
        self.login_frame.destroy()
        self._build_settings()

    def _reject(self, message: str) -> None:
        """A wrong answer costs an increasing wait, so this cannot be sat and guessed."""
        self.failed_logins += 1
        self.password_entry.delete(0, tk.END)
        self.login_error.config(text=message)
        delay = min(self.failed_logins, 5)          # 1s, 2s ... up to 5s
        self.password_entry.config(state="disabled")
        self.after(delay * 1000,
                   lambda: self.password_entry.config(state="normal"))

    # ---------- settings ----------

    def _build_settings(self, first_run: bool = False) -> None:
        if first_run:
            # No project configured yet, so there was nothing to sign in against.
            ttk.Label(self, foreground="#8a6d0b",
                      text="No proctoring project is set up on this machine yet, so "
                           "these settings are open.\nOnce you save a Supabase "
                           "project below, opening this panel will ask for your "
                           "proctor account.",
                      justify="left").grid(row=2, column=0, sticky="w", padx=14,
                                           pady=(0, 10))
        notebook = ttk.Notebook(self)
        notebook.grid(row=0, column=0, padx=12, pady=12)
        notebook.add(self._sites_tab(notebook), text="Allowed sites")
        notebook.add(self._security_tab(notebook), text="Security")
        notebook.add(self._recording_tab(notebook), text="Recording")
        notebook.add(self._proctoring_tab(notebook), text="Proctoring")

        footer = ttk.Frame(self)
        footer.grid(row=1, column=0, sticky="ew", padx=12, pady=(0, 12))
        self.status = ttk.Label(footer, text=f"Settings file: {store.config_path()}",
                                foreground="#555")
        self.status.grid(row=0, column=0, sticky="w")
        ttk.Button(footer, text="Save", command=self._save).grid(row=0, column=1, padx=6)
        ttk.Button(footer, text="Close", command=self.destroy).grid(row=0, column=2)

        self._warn_about_defaults()

    def _sites_tab(self, parent: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(parent)

        ttk.Label(tab, text="The one site the session is pinned to:") \
            .grid(row=0, column=0, columnspan=2, sticky="w", **PAD)
        self.url_entry = ttk.Entry(tab, width=54)
        self.url_entry.grid(row=1, column=0, columnspan=2, **PAD)
        self.url_entry.insert(0, self.config["allowed_url"])

        ttk.Label(tab, text="Hosts Chrome may still load (SSO, 2FA, CDNs):") \
            .grid(row=2, column=0, columnspan=2, sticky="w", **PAD)
        self.hosts_list = tk.Listbox(tab, width=44, height=7)
        self.hosts_list.grid(row=3, column=0, rowspan=2, **PAD)
        for host in self.config["allowed_hosts"]:
            self.hosts_list.insert(tk.END, host)

        buttons = ttk.Frame(tab)
        buttons.grid(row=3, column=1, sticky="n", pady=6)
        self.new_host = ttk.Entry(buttons, width=22)
        self.new_host.grid(row=0, column=0, pady=(0, 6))
        ttk.Button(buttons, text="Add", command=self._add_host) \
            .grid(row=1, column=0, sticky="ew")
        ttk.Button(buttons, text="Remove selected", command=self._remove_host) \
            .grid(row=2, column=0, sticky="ew", pady=4)

        ttk.Label(tab, text="Drop a host and that login step stops working — remove\n"
                            "ucsd.edu or duosecurity.com and SSO will fail.",
                  foreground="#555").grid(row=5, column=0, columnspan=2, sticky="w", **PAD)
        return tab

    def _security_tab(self, parent: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(parent)

        # There is no admin password any more. This panel is gated on the proctor's
        # Supabase account, which is the same identity that approves students, so a
        # second local password was one more thing to set and forget.
        ttk.Label(tab, text="Who can open this panel", font=("", 13, "bold")) \
            .grid(row=0, column=0, columnspan=2, sticky="w", **PAD)
        ttk.Label(tab, text="Your proctor account, the same one you use for the\n"
                            "dashboard. Change that password in Supabase.",
                  foreground="#555") \
            .grid(row=1, column=0, columnspan=2, sticky="w", padx=12)

        ttk.Separator(tab, orient="horizontal") \
            .grid(row=2, column=0, columnspan=2, sticky="ew", pady=10)

        ttk.Label(tab, text="Unlock passcode", font=("", 13, "bold")) \
            .grid(row=3, column=0, columnspan=2, sticky="w", **PAD)
        ttk.Label(tab, text="What ends a locked session. Give this to whoever\n"
                            "is meant to be able to stop the exam.") \
            .grid(row=4, column=0, columnspan=2, sticky="w", padx=12)
        self.new_passcode = self._password_row(tab, "New passcode", 5)
        self.confirm_passcode = self._password_row(tab, "Confirm", 6)
        return tab

    def _password_row(self, tab: ttk.Frame, label: str, row: int) -> ttk.Entry:
        ttk.Label(tab, text=label).grid(row=row, column=0, sticky="e", **PAD)
        entry = ttk.Entry(tab, width=28, show="•")
        entry.grid(row=row, column=1, sticky="w", **PAD)
        return entry

    def _recording_tab(self, parent: ttk.Notebook) -> ttk.Frame:
        tab = ttk.Frame(parent)
        ttk.Label(tab, text="Captured for the whole session:") \
            .grid(row=0, column=0, sticky="w", **PAD)

        rec = self.config["recording"]
        self.rec_vars = {}
        labels = {
            "screen": "Screen  →  screen.mp4",
            "camera": "Webcam  →  camera.mp4",
            "audio": "Microphone  →  audio.wav",
        }
        for index, (key, text) in enumerate(labels.items(), start=1):
            var = tk.BooleanVar(value=bool(rec.get(key, True)))
            self.rec_vars[key] = var
            ttk.Checkbutton(tab, text=text, variable=var) \
                .grid(row=index, column=0, sticky="w", padx=24, pady=4)

        ttk.Label(tab, text="Students always see the recording notice and must agree\n"
                            "before anything starts. Recordings are written to the\n"
                            "Desktop, in LockedIn-Recordings/<date-time>/.",
                  foreground="#555").grid(row=5, column=0, sticky="w", **PAD)
        return tab

    def _proctoring_tab(self, parent: ttk.Notebook) -> ttk.Frame:
        """
        The Supabase project behind the Student / Faculty flow.

        Leaving these blank is a supported configuration, not an unfinished one: the
        lockdown then runs exactly as it did before any of this existed — no
        accounts, no approval gate, nothing leaving the machine.
        """
        tab = ttk.Frame(parent)
        cloud = self.config.get("cloud") or {}

        ttk.Label(tab, text="Proctored exams (optional)", font=("", 13, "bold")) \
            .grid(row=0, column=0, columnspan=2, sticky="w", **PAD)
        ttk.Label(tab, text="Fill these in to require a proctor's approval before an\n"
                            "exam can start. Leave them blank for a standalone,\n"
                            "offline lockdown.", foreground="#555") \
            .grid(row=1, column=0, columnspan=2, sticky="w", padx=12)

        self.cloud_entries: dict[str, ttk.Entry] = {}
        fields = [
            ("url", "Project URL", "https://xxxxxxxx.supabase.co"),
            ("anon_key", "Anon key", "the anon public key — never service_role"),
            ("dashboard_url", "Dashboard address", "where index.html is published"),
            ("id_email_domain", "ID email domain", "ucsd.edu"),
        ]
        for index, (key, text, hint) in enumerate(fields, start=2):
            ttk.Label(tab, text=text).grid(row=index, column=0, sticky="e", **PAD)
            entry = ttk.Entry(tab, width=52)
            entry.insert(0, str(cloud.get(key, "")))
            entry.grid(row=index, column=1, sticky="w", **PAD)
            self.cloud_entries[key] = entry
            ttk.Label(tab, text=hint, foreground="#777") \
                .grid(row=index, column=2, sticky="w", padx=(0, 12))

        # Serving the dashboard rather than opening the file is what lets a proctor
        # watch from a second device — a phone, an iPad, the laptop at the front of
        # the room. It is the same page either way; the only difference is whether
        # anything but this machine can reach it.
        ttk.Label(tab, text="Show it on my wi-fi").grid(row=6, column=0, sticky="e",
                                                       **PAD)
        hosting = ttk.Frame(tab)
        hosting.grid(row=6, column=1, sticky="w", **PAD)
        ttk.Button(hosting, text="Serve on this network", command=self._serve_dashboard) \
            .grid(row=0, column=0)
        ttk.Button(hosting, text="Stop", command=self._stop_dashboard) \
            .grid(row=0, column=1, padx=6)
        self.serve_status = ttk.Label(tab, text="", foreground="#555",
                                      wraplength=520, justify="left")
        self.serve_status.grid(row=7, column=1, columnspan=2, sticky="w", padx=12)
        self._refresh_serve_status()

        ttk.Separator(tab, orient="horizontal") \
            .grid(row=8, column=0, columnspan=3, sticky="ew", pady=10)

        ttk.Label(tab, text="Live monitoring").grid(row=9, column=0, sticky="e", **PAD)
        live = ttk.Frame(tab)
        live.grid(row=9, column=1, sticky="w", **PAD)
        self.live_interval = ttk.Spinbox(live, from_=1.0, to=30.0, increment=0.5,
                                        width=6)
        self.live_interval.set(float(cloud.get("live_interval") or 3.0))
        self.live_interval.grid(row=0, column=0)
        ttk.Label(live, text="seconds between frames,").grid(row=0, column=1, padx=6)
        self.live_width = ttk.Spinbox(live, from_=240, to=1600, increment=80, width=6)
        self.live_width.set(int(cloud.get("live_width") or 640))
        self.live_width.grid(row=0, column=2)
        ttk.Label(live, text="px wide").grid(row=0, column=3, padx=6)

        # Kept frames are the ones that outlive the exam, so this is the number
        # that decides how much of the free tier an exam costs.
        ttk.Label(tab, text="Keep a frame").grid(row=10, column=0, sticky="e", **PAD)
        keep = ttk.Frame(tab)
        keep.grid(row=10, column=1, sticky="w", **PAD)
        self.snapshot_interval = ttk.Spinbox(keep, from_=0, to=600, increment=15,
                                             width=6)
        self.snapshot_interval.set(float(cloud.get("snapshot_interval") or 0.0))
        self.snapshot_interval.grid(row=0, column=0)
        ttk.Label(keep, text="seconds apart, kept until the exam is deleted "
                             "(0 keeps none)").grid(row=0, column=1, padx=6)

        ttk.Label(tab, text="The anon key is meant to be public — it ships inside this\n"
                            "app. Access is enforced by the database policies in\n"
                            "server/schema.sql. Never paste the service_role key here.",
                  foreground="#555").grid(row=12, column=0, columnspan=3, sticky="w",
                                          **PAD)

        self.cloud_status = ttk.Label(tab, text="", foreground="#555")
        self.cloud_status.grid(row=13, column=1, sticky="w", padx=12)
        ttk.Button(tab, text="Test the connection", command=self._test_cloud) \
            .grid(row=13, column=0, sticky="e", **PAD)
        return tab

    # ---------- serving the dashboard on the local network ----------

    def _serve_script(self) -> Path | None:
        """server/serve.py — beside this panel in the .app bundle, in server/ in the repo."""
        here = Path(__file__).resolve().parent
        for candidate in (here / "serve.py", here.parent / "server" / "serve.py"):
            if candidate.exists():
                return candidate
        return None

    def _run_serve(self, *arguments: str) -> tuple[int, str]:
        script = self._serve_script()
        if not script:
            return 1, "serve.py was not found next to this panel."
        try:
            done = subprocess.run([sys.executable, str(script), *arguments],
                                  capture_output=True, text=True, timeout=25)
        except (OSError, subprocess.SubprocessError) as error:
            return 1, str(error)
        output = (done.stdout or done.stderr or "").strip()
        return done.returncode, output

    def _refresh_serve_status(self) -> None:
        code, output = self._run_serve("--status")
        if code == 0 and output.startswith("http"):
            self._announce_serving(output)
        else:
            self.serve_status.config(
                text="Not being served. The dashboard is only reachable on this "
                     "machine until you start it.")

    def _announce_serving(self, url: str) -> None:
        base = url.rstrip("/")
        self.serve_status.config(
            text=f"Serving at {base}/ — open that on any device on this wi-fi.\n"
                 f"To point another machine at this exam, run there:  "
                 f"uv run --script src/lockedin_config.py enroll {base}")

    def _serve_dashboard(self) -> None:
        self.serve_status.config(text="starting...")
        self.update_idletasks()
        code, output = self._run_serve("--ensure")
        if code != 0 or not output.startswith("http"):
            self.serve_status.config(text=output[:200] or "could not start the server.")
            return
        # Fill the address in rather than saving behind their back: Save is what
        # commits every other field on this panel, and this one is no different.
        self.cloud_entries["dashboard_url"].delete(0, tk.END)
        self.cloud_entries["dashboard_url"].insert(0, output.strip())
        self._announce_serving(output.strip())
        messagebox.showinfo(
            "Serving the dashboard",
            f"The proctor dashboard is now at\n\n{output.strip()}\n\nOpen that on "
            "your phone, tablet or other laptop — anything on this wi-fi.\n\nIt keeps "
            "running after this panel closes. Press Save to make the Faculty button "
            "open this address too.")

    def _stop_dashboard(self) -> None:
        code, output = self._run_serve("--stop")
        self.serve_status.config(text=output[:200] or "stopped.")

    def _test_cloud(self) -> None:
        """Save nothing; just say whether what is typed in actually works."""
        url = self.cloud_entries["url"].get().strip().rstrip("/")
        key = self.cloud_entries["anon_key"].get().strip()
        if not url or not key:
            self.cloud_status.config(text="Fill in the URL and the anon key first.")
            return
        self.cloud_status.config(text="checking...")
        self.update_idletasks()
        try:
            import lockedin_cloud
        except ImportError:
            self.cloud_status.config(text="lockedin_cloud.py is missing next to this panel.")
            return
        cloud = lockedin_cloud.Cloud(url=url, anon_key=key)
        try:
            # An anonymous select against a policy-protected table: an empty result
            # is a pass, because it proves the URL resolved and the key was accepted.
            cloud._json("GET", "/rest/v1/exams", params={"select": "id", "limit": 1})
        except lockedin_cloud.CloudError as error:
            self.cloud_status.config(text=str(error)[:120])
            return
        self.cloud_status.config(text="Reachable, and the key was accepted.")

    # ---------- actions ----------

    def _add_host(self) -> None:
        host = self.new_host.get().strip()
        if not host:
            return
        # Paste a whole URL and take the hostname out of it — an easy thing to get
        # wrong, and a wrong entry silently blocks the site.
        for prefix in ("https://", "http://"):
            if host.startswith(prefix):
                host = host[len(prefix):].split("/")[0]
        if host in self.hosts_list.get(0, tk.END):
            return
        self.hosts_list.insert(tk.END, host)
        self.new_host.delete(0, tk.END)

    def _remove_host(self) -> None:
        for index in reversed(self.hosts_list.curselection()):
            self.hosts_list.delete(index)

    def _warn_about_defaults(self) -> None:
        if self.config.get("passcode_is_default"):
            messagebox.showwarning(
                "Change the passcode",
                "The unlock passcode is still the shipped default, which anyone who "
                "has seen this project knows.\n\nIt is the only way to end a locked "
                "session, so set your own under the Security tab before using this "
                "for anything real.")

    def _save(self) -> None:
        url = self.url_entry.get().strip()
        if not url.startswith(("http://", "https://")):
            messagebox.showerror("Check the URL",
                                 "The allowed URL must start with http:// or https://")
            return
        hosts = list(self.hosts_list.get(0, tk.END))
        if not hosts:
            messagebox.showerror("Check the hosts",
                                 "Leave at least one allowed host, or Chrome will "
                                 "block the exam site itself.")
            return

        new_passcode = self.new_passcode.get()
        if new_passcode:
            if new_passcode != self.confirm_passcode.get():
                messagebox.showerror("Check the passcode",
                                     "The two passcodes don't match.")
                return
            if len(new_passcode) < 4:
                messagebox.showerror("Check the passcode",
                                     "Use at least 4 characters.")
                return

        cloud_url = self.cloud_entries["url"].get().strip().rstrip("/")
        cloud_key = self.cloud_entries["anon_key"].get().strip()
        if bool(cloud_url) != bool(cloud_key):
            messagebox.showerror(
                "Check the proctoring settings",
                "A project URL needs its anon key, and vice versa. Fill in both to "
                "turn on proctored exams, or clear both to run standalone.")
            return
        if cloud_url and not cloud_url.startswith("https://"):
            messagebox.showerror("Check the project URL",
                                 "The Supabase project URL must start with https://")
            return
        # A pasted service_role key would work, and would hand every student the
        # ability to read and rewrite everyone's data. Worth refusing outright.
        if cloud_key and "service_role" in cloud_key:
            messagebox.showerror(
                "That is the wrong key",
                "That looks like the service_role key. It bypasses every access "
                "rule in the database.\n\nUse the \"anon public\" key from "
                "Project Settings > API.")
            return

        self.config["allowed_url"] = url
        self.config["allowed_hosts"] = hosts
        self.config["recording"] = {key: var.get() for key, var in self.rec_vars.items()}

        cloud = dict(self.config.get("cloud") or {})
        cloud["url"] = cloud_url
        cloud["anon_key"] = cloud_key
        cloud["dashboard_url"] = self.cloud_entries["dashboard_url"].get().strip()
        cloud["id_email_domain"] = (self.cloud_entries["id_email_domain"].get().strip()
                                    or "ucsd.edu")
        try:
            cloud["live_interval"] = max(1.0, float(self.live_interval.get()))
            cloud["live_width"] = max(240, int(float(self.live_width.get())))
            keep_every = float(self.snapshot_interval.get())
            cloud["snapshot_interval"] = 0.0 if keep_every <= 0 else max(5.0, keep_every)
        except ValueError:
            messagebox.showerror("Check the live monitoring values",
                                 "The interval and width have to be numbers.")
            return
        self.config["cloud"] = cloud

        if new_passcode:
            store.set_passcode(self.config, new_passcode)

        path = store.save(self.config)
        for entry in (self.new_passcode, self.confirm_passcode):
            entry.delete(0, tk.END)
        self.status.config(text=f"Saved to {path}")
        messagebox.showinfo("Saved", "Settings saved. They apply to the next session.")


if __name__ == "__main__":
    AdminPanel().mainloop()
