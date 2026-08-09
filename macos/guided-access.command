#!/bin/bash
#
# guided-access.command  —  a Chrome "Guided Access" / single-site lockdown for macOS
#
# What it does:
#   1. Starts recording the whole screen to a .mov file on your Desktop
#   2. Locks Chrome via managed policy: incognito OFF, DevTools OFF, only the
#      allowed sites reachable (this layer even applies inside incognito)
#   3. Asks you to set a passcode (used later to unlock)
#   4. Force-quits every other app, then opens Chrome fullscreen (kiosk: no Dock,
#      no menu bar) — you can't get out of the screen
#   5. Any other app is hidden; you're snapped back to Chrome
#   6. Inside Chrome, every page except the allowed sites is redirected back
#   7. If Chrome is ever closed it is relaunched immediately, and Guided Access
#      does NOT end — the ONLY way to end it is entering the passcode
#   8. To exit: quit Chrome (Cmd+Q) then enter your passcode. Recording is saved,
#      Chrome policy is removed, and Chrome is closed so normal browsing returns.
#
# The site you actually want:
ALLOWED_URL="https://rsm-django-02.ucsd.edu/mgta403/"
# Hosts allowed to load (target site + UCSD SSO + Duo 2FA so login works):
ALLOW_HOSTS=("rsm-django-02.ucsd.edu" "ucsd.edu" "duosecurity.com")
# Fixed unlock passcode — change this to whatever you want. It is stored in plain
# text in this file, so anyone who opens the file can read it (fine for self-control,
# not a real security secret).
UNLOCK_PASSCODE="letmeout"
#
# NOTE: This is a "soft" lockdown for focus/self-control, NOT a secure exam browser.
#   Force Quit (Cmd+Opt+Esc) or a reboot can still defeat it. Disabling incognito/
#   DevTools edits a Chrome managed-policy file, which needs your admin password;
#   on some managed Macs the policy may not apply, but the in-Chrome redirect layer
#   still blocks navigation. First run also asks for Automation / Accessibility /
#   Screen Recording permission (System Settings > Privacy & Security).

CHROME_MP="/Library/Managed Preferences/com.google.Chrome"

# ---------- Start the screen recording ----------
STAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="$HOME/Desktop/guided-access-$STAMP.mov"
screencapture -v -C "$OUTPUT" &
REC_PID=$!

# ---------- Get admin rights for the Chrome policy ----------
echo "Guided Access needs your admin password to lock Chrome (disable incognito + DevTools)..."
if ! sudo -v; then
	echo "No admin password provided — cannot lock Chrome settings. Exiting."
	kill -INT "$REC_PID" 2>/dev/null
	exit 1
fi
# Keep the sudo timestamp alive so cleanup works after a long session.
( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
KEEPALIVE_PID=$!

remove_policy() {
	sudo defaults delete "$CHROME_MP" IncognitoModeAvailability 2>/dev/null
	sudo defaults delete "$CHROME_MP" DeveloperToolsAvailability 2>/dev/null
	sudo defaults delete "$CHROME_MP" URLBlocklist 2>/dev/null
	sudo defaults delete "$CHROME_MP" URLAllowlist 2>/dev/null
	sudo killall cfprefsd 2>/dev/null
}

# ALWAYS undo everything on exit, even on crash / Ctrl+C.
cleanup() {
	kill -INT "$REC_PID" 2>/dev/null
	remove_policy
	kill "$KEEPALIVE_PID" 2>/dev/null
	killall "Google Chrome" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---------- Apply the Chrome managed policy ----------
sudo defaults write "$CHROME_MP" IncognitoModeAvailability -int 1   # 1 = incognito disabled
sudo defaults write "$CHROME_MP" DeveloperToolsAvailability -int 2  # 2 = DevTools disabled everywhere
sudo defaults write "$CHROME_MP" URLBlocklist -array "*"
sudo defaults write "$CHROME_MP" URLAllowlist -array "${ALLOW_HOSTS[@]}"
sudo killall cfprefsd 2>/dev/null
# Restart Chrome so it reads the new policy on launch.
killall "Google Chrome" 2>/dev/null
sleep 1

# ---------- The lockdown (AppleScript) ----------
osascript - "$ALLOWED_URL" "$UNLOCK_PASSCODE" "${ALLOW_HOSTS[@]}" <<'APPLESCRIPT'

on run argv
	set allowedURL to item 1 of argv
	set pass1 to item 2 of argv
	set targetApp to "Google Chrome"
	-- allowed hosts = every arg from the third onward
	set allowedHosts to {}
	repeat with i from 3 to (count of argv)
		set end of allowedHosts to item i of argv
	end repeat

	-- ---------- Force-quit every other app ----------
	-- Keep only Chrome, Finder, and the terminal running this script alive.
	set keepApps to {"Google Chrome", "Finder", "Terminal", "iTerm2", "osascript"}
	set otherApps to {}
	tell application "System Events"
		set otherApps to name of (every application process whose background only is false)
	end tell
	repeat with a in otherApps
		set a to a as string
		if a is not in keepApps then
			try
				tell application a to quit
			end try
		end if
	end repeat
	delay 1

	-- ---------- Open Chrome at the allowed URL, fullscreen ----------
	tell application "Google Chrome"
		activate
		if (count of windows) is 0 then make new window
		set URL of active tab of front window to allowedURL
	end tell
	delay 1
	-- Enter macOS fullscreen so the Dock + menu bar are hidden (kiosk feel).
	try
		tell application "System Events" to keystroke "f" using {control down, command down}
	end try
	delay 1

	-- ---------- Lockdown loop ----------
	repeat
		try
			set runningNames to {}
			tell application "System Events"
				set runningNames to name of (every application process whose background only is false)
			end tell

			if targetApp is not in runningNames then
				-- Chrome was closed: relaunch INSTANTLY and force it back to the site...
				tell application "Google Chrome"
					activate
					if (count of windows) is 0 then make new window
					set URL of active tab of front window to allowedURL
				end tell
				delay 1
				-- put it back into fullscreen kiosk mode
				try
					tell application "System Events" to keystroke "f" using {control down, command down}
				end try
				-- ...then DEMAND the passcode. The prompt keeps coming back until the
				-- correct passcode is entered — it cannot be cancelled or escaped.
				set unlocked to false
				repeat until unlocked
					set entry to ""
					try
						set entry to text returned of (display dialog "Guided Access is ON. You cannot quit Chrome without the passcode." & return & return & "Enter your passcode to end Guided Access:" & return & "(This prompt will keep returning until you do.)" default answer "" with hidden answer with title "Guided Access" buttons {"Unlock"} default button "Unlock")
					on error
						set entry to "" -- dismissed / Escape: just ask again
					end try
					if entry is pass1 then set unlocked to true
				end repeat
				-- correct passcode: restore everything and end Guided Access
				try
					tell application "System Events" to set visible of (every application process whose background only is false) to true
				end try
				exit repeat
			else
				-- Keep Chrome frontmost; hide everything else.
				set frontApp to ""
				tell application "System Events"
					set frontApp to name of first application process whose frontmost is true
				end tell
				if frontApp is not targetApp then
					repeat with pName in runningNames
						set pName to pName as string
						if pName is not targetApp then
							try
								tell application "System Events" to set visible of (first application process whose name is pName) to false
							end try
						end if
					end repeat
					tell application "Google Chrome" to activate
				end if

				-- Enforce the whitelist across every tab / window.
				try
					tell application "Google Chrome"
						set wCount to count of windows
						repeat with wi from 1 to wCount
							set tCount to count of tabs of window wi
							repeat with ti from 1 to tCount
								set u to URL of tab ti of window wi
								set okURL to false
								repeat with h in allowedHosts
									if u contains (h as string) then set okURL to true
								end repeat
								if not okURL then set URL of tab ti of window wi to allowedURL
							end repeat
						end repeat
					end tell
				end try
			end if
		end try
		delay 0.3
	end repeat
end run

APPLESCRIPT

# ---------- Stop recording, undo policy, finalize ----------
kill -INT "$REC_PID" 2>/dev/null
wait "$REC_PID" 2>/dev/null
sleep 1
remove_policy
kill "$KEEPALIVE_PID" 2>/dev/null
killall "Google Chrome" 2>/dev/null

osascript <<END
display dialog "Guided Access ended. Chrome is unlocked (incognito + DevTools restored) and you can browse normally again.

Screen recording saved to:
$OUTPUT" buttons {"OK"} default button "OK" with title "Guided Access"
END
