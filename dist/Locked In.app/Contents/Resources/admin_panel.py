# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""
admin_panel.py — the Locked In settings panel.

A small Tk window, so one panel serves both macOS and Windows. Log in as the admin,
then edit what the lockdown will do: which site it pins to, which hosts stay
reachable, what the unlock passcode is, and which streams are recorded.

    uv run --script admin_panel.py

Defaults on a fresh install are username "admin", password "admin", and the panel
keeps warning until both that password and the unlock passcode have been changed.

Nothing typed here is written to disk in the clear — passwords go through
lockedin_config.hash_secret (PBKDF2-SHA256) and only the hash is stored. See the
honesty note at the top of lockedin_config.py about what that does and doesn't buy.
"""

from __future__ import annotations

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
        self.title("Locked In — Admin")
        self.resizable(False, False)
        self.config = store.load(create=True)
        # Failed logins cost an increasing wait, so the panel can't be brute-forced
        # by someone sitting in front of it.
        self.failed_logins = 0
        self._build_login()

    # ---------- login ----------

    def _build_login(self) -> None:
        self.login_frame = ttk.Frame(self)
        self.login_frame.grid(row=0, column=0, **PAD)

        ttk.Label(self.login_frame, text="Locked In — Admin",
                  font=("", 16, "bold")).grid(row=0, column=0, columnspan=2, pady=(4, 10))

        ttk.Label(self.login_frame, text="Username").grid(row=1, column=0, sticky="e", **PAD)
        self.user_entry = ttk.Entry(self.login_frame, width=26)
        self.user_entry.grid(row=1, column=1, **PAD)
        self.user_entry.insert(0, store.DEFAULT_ADMIN_USER)

        ttk.Label(self.login_frame, text="Password").grid(row=2, column=0, sticky="e", **PAD)
        self.password_entry = ttk.Entry(self.login_frame, width=26, show="•")
        self.password_entry.grid(row=2, column=1, **PAD)

        self.login_error = ttk.Label(self.login_frame, text="", foreground="#c0392b")
        self.login_error.grid(row=3, column=0, columnspan=2)

        ttk.Button(self.login_frame, text="Log in", command=self._try_login) \
            .grid(row=4, column=0, columnspan=2, pady=(6, 10))

        self.bind("<Return>", lambda _event: self._try_login())
        self.password_entry.focus_set()

    def _try_login(self) -> None:
        username = self.user_entry.get()
        password = self.password_entry.get()
        if store.verify_admin(self.config, username, password):
            self.failed_logins = 0
            self.unbind("<Return>")
            self.login_frame.destroy()
            self._build_settings()
            return

        self.failed_logins += 1
        self.password_entry.delete(0, tk.END)
        self.login_error.config(text="Wrong username or password.")
        # 1s, 2s, 3s ... up to 5s between attempts.
        delay = min(self.failed_logins, 5)
        self.password_entry.config(state="disabled")
        self.after(delay * 1000,
                   lambda: self.password_entry.config(state="normal"))

    # ---------- settings ----------

    def _build_settings(self) -> None:
        notebook = ttk.Notebook(self)
        notebook.grid(row=0, column=0, padx=12, pady=12)
        notebook.add(self._sites_tab(notebook), text="Allowed sites")
        notebook.add(self._security_tab(notebook), text="Security")
        notebook.add(self._recording_tab(notebook), text="Recording")

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

        ttk.Label(tab, text="Admin password", font=("", 13, "bold")) \
            .grid(row=0, column=0, columnspan=2, sticky="w", **PAD)
        ttk.Label(tab, text="Opens this panel. Leave blank to keep the current one.") \
            .grid(row=1, column=0, columnspan=2, sticky="w", padx=12)
        self.new_admin_password = self._password_row(tab, "New password", 2)
        self.confirm_admin_password = self._password_row(tab, "Confirm", 3)

        ttk.Separator(tab, orient="horizontal") \
            .grid(row=4, column=0, columnspan=2, sticky="ew", pady=10)

        ttk.Label(tab, text="Unlock passcode", font=("", 13, "bold")) \
            .grid(row=5, column=0, columnspan=2, sticky="w", **PAD)
        ttk.Label(tab, text="What ends a locked session. Give this to whoever\n"
                            "is meant to be able to stop the exam.") \
            .grid(row=6, column=0, columnspan=2, sticky="w", padx=12)
        self.new_passcode = self._password_row(tab, "New passcode", 7)
        self.confirm_passcode = self._password_row(tab, "Confirm", 8)
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
        warnings = []
        if self.config["admin"].get("is_default"):
            warnings.append("• the admin password is still \"admin\"")
        if self.config.get("passcode_is_default"):
            warnings.append("• the unlock passcode is still the shipped default")
        if warnings:
            messagebox.showwarning(
                "Change the defaults",
                "Anyone who has seen this project knows these:\n\n"
                + "\n".join(warnings)
                + "\n\nSet your own under the Security tab before using this for "
                  "anything real.")

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

        new_admin = self.new_admin_password.get()
        if new_admin:
            if new_admin != self.confirm_admin_password.get():
                messagebox.showerror("Check the password",
                                     "The two admin passwords don't match.")
                return
            if len(new_admin) < 4:
                messagebox.showerror("Check the password",
                                     "Use at least 4 characters.")
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

        self.config["allowed_url"] = url
        self.config["allowed_hosts"] = hosts
        self.config["recording"] = {key: var.get() for key, var in self.rec_vars.items()}
        if new_admin:
            store.set_admin_password(self.config, new_admin)
        if new_passcode:
            store.set_passcode(self.config, new_passcode)

        path = store.save(self.config)
        for entry in (self.new_admin_password, self.confirm_admin_password,
                      self.new_passcode, self.confirm_passcode):
            entry.delete(0, tk.END)
        self.status.config(text=f"Saved to {path}")
        messagebox.showinfo("Saved", "Settings saved. They apply to the next session.")


if __name__ == "__main__":
    AdminPanel().mainloop()
