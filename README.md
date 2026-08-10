# Locked In 🔒

A cross-platform, single-site study lockdown. One launcher screen, two backends: it
pins Chrome full-screen to one allowed URL, blocks everything else, and won't let you
out without a passcode.

> **This is a focus tool, not a secure exam browser.** Force Quit, Task Manager, a
> reboot, or a second device all defeat it. For a graded exam use an official
> proctoring tool (Respondus / Proctorio / Honorlock) enabled by your instructor.

![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-black)

---

## What it does

| | |
|---|---|
| **Single site** | Chrome opens in kiosk/full-screen at one allowed URL |
| **Everything else blocked** | Chrome managed policy blocklists `*`, allowlists only your hosts |
| **No escape hatches** | Incognito disabled, DevTools disabled |
| **Other apps killed** | Non-system apps are quit; you're snapped back to Chrome |
| **Can't quit** | Closing Chrome relaunches it and demands the passcode — the prompt keeps returning |
| **Always cleans up** | Policy removed, Chrome unlocked on exit — even on Ctrl+C or crash |

---

## Repo layout

```
locked-in/
├── macos/
│   ├── build.sh              build dist/Locked In.app from source
│   ├── guided-access.command the actual macOS lockdown (bash + AppleScript)
│   └── src/
│       ├── main.swift        the launcher UI (Cocoa + WKWebView, matrix-rain screen)
│       ├── Info.plist        app bundle metadata
│       ├── mkicon.swift      draws the padlock AppIcon programmatically
│       ├── launcher.applescript   earlier AppleScript-only launcher (superseded)
│       └── lockdown.applescript   the lockdown loop, standalone (reference)
├── windows/
│   ├── LockedIn.hta          the launcher UI (HTA, same screen as the Mac app)
│   └── guided-access.ps1     the actual Windows lockdown (PowerShell, self-elevating)
├── assets/
│   └── AppIcon.icns          prebuilt icon
└── dist/
    └── Locked In.app         prebuilt, ad-hoc-signed macOS app (arm64)
```

The two launchers show the same screen with a macOS / Windows picker, so you can copy
this whole folder to both machines (USB / iCloud / OneDrive) and use whichever applies.

---

## Running it

### macOS

1. Double-click **`dist/Locked In.app`**.
   First time only: right-click → **Open** → **Open**, to get past Gatekeeper (the app
   is ad-hoc signed, not notarized).
2. Click **macOS**.
3. Terminal opens and runs the lockdown. Enter your Mac admin password when asked —
   it's needed to write the Chrome managed-preferences policy.

First run also prompts for **Automation** and **Accessibility**
permission in System Settings → Privacy & Security.

To exit: quit Chrome (⌘Q), then enter the passcode.

### Windows

1. Keep **`windows/LockedIn.hta`** and **`windows/guided-access.ps1`** in the same folder.
2. Double-click **`LockedIn.hta`**.
3. Click **Windows**, then approve the Administrator (UAC) prompt — needed for the
   Chrome registry policy.

To exit: close Chrome, then enter the passcode.

---

## Configuring it

Both platforms have the same three knobs, at the top of their lockdown script.

**macOS** — `macos/guided-access.command` (and the copy inside the app bundle at
`Locked In.app/Contents/Resources/guided-access.command`):

```bash
ALLOWED_URL="https://rsm-django-02.ucsd.edu/video-exam/station/"
ALLOW_HOSTS=("rsm-django-02.ucsd.edu" "ucsd.edu" "duosecurity.com")
UNLOCK_PASSCODE="letmeout"
```

**Windows** — `windows/guided-access.ps1`:

```powershell
$AllowedUrl      = "https://rsm-django-02.ucsd.edu/video-exam/station/"
$AllowHosts      = @("rsm-django-02.ucsd.edu", "ucsd.edu", "duosecurity.com")
$UnlockPasscode  = "letmeout"
```

`ucsd.edu` and `duosecurity.com` are in the allowlist so SSO login and Duo 2FA still
work. Drop them if your target site doesn't need them.

**The passcode is stored in plain text** in these files. That's deliberate — it's a
self-control speed bump, not a secret. Anyone who opens the file can read it.

After editing the macOS copy, either edit the one inside the bundle directly
(right-click the app → *Show Package Contents*) or re-run `./macos/build.sh`.

---

## Building the macOS app

Needs the Xcode Command Line Tools (`xcode-select --install`):

```bash
./macos/build.sh           # compile + bundle + ad-hoc sign -> dist/Locked In.app
./macos/build.sh --icon    # also regenerate assets/AppIcon.icns from src/mkicon.swift
```

Windows has no build step — the `.hta` and `.ps1` are the shipped artifacts.

---

## Emergency exit

If you forget the passcode:

- **macOS** — Ctrl+C in the Terminal window, or Force Quit (⌘⌥Esc), or reboot
- **Windows** — close the PowerShell window, or kill it from Task Manager, or reboot

Cleanup (removing the Chrome policy) runs automatically on exit either way, so Chrome
always goes back to normal.

---

## License

MIT — see [LICENSE](LICENSE).
