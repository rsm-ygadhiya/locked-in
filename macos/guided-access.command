#!/bin/bash
#
# guided-access.command  —  a Chrome "Guided Access" / single-site lockdown for macOS
#
# What it does:
#   1. Shows the recording notice and waits for the student to agree (nothing below
#      this point happens if they decline)
#   2. Starts recording the screen, the webcam, and the microphone (recorder.py)
#   3. Locks Chrome via managed policy: incognito OFF, DevTools OFF, only the
#      allowed sites reachable (this layer even applies inside incognito)
#   4. Reads the allowed site, allowed hosts and passcode hash from the settings file
#   5. Force-quits every other app, then opens Chrome fullscreen (kiosk: no Dock,
#      no menu bar) — you can't get out of the screen
#   6. Any other app is hidden; you're snapped back to Chrome
#   7. Inside Chrome, every page except the allowed sites is redirected back
#   8. If Chrome is ever closed it is relaunched immediately, and Guided Access
#      does NOT end — the ONLY way to end it is entering the passcode
#   9. To exit: quit Chrome (Cmd+Q) then enter your passcode. The recordings are
#      finalized, the Chrome policy is removed, and Chrome is closed so normal
#      browsing returns.
#
# ---------- Settings ----------
# The allowed URL, the allowed hosts, the unlock passcode and which streams get
# recorded all live in the settings file now, not in this script. Edit them in the
# admin panel (the "Admin" button on the launcher, or: uv run --script admin_panel.py).
# The passcode is stored only as a PBKDF2 hash, so it is no longer sitting in plain
# text in a file every student can open.
RECORD_DIR="$HOME/Desktop/LockedIn-Recordings"
# Set to false to start recording without asking. Only do that where the students have
# already been told, in writing, that the session is recorded — see the "Recording and
# consent" section of the README.
REQUIRE_CONSENT=true
#
# NOTE: This is a "soft" lockdown for focus/self-control, NOT a secure exam browser.
#   Force Quit (Cmd+Opt+Esc) or a reboot can still defeat it. Disabling incognito/
#   DevTools edits a Chrome managed-policy file, which needs your admin password;
#   on some managed Macs the policy may not apply, but the in-Chrome redirect layer
#   still blocks navigation. First run also asks for Automation / Accessibility /
#   Screen Recording / Camera / Microphone permission (System Settings > Privacy
#   & Security) — all of them are attributed to Terminal, which is what runs this.

CHROME_MP="/Library/Managed Preferences/com.google.Chrome"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Locate the Python helpers and something to run them with ----------
# Inside the app bundle the .py files sit next to this script in Resources/; in a plain
# clone of the repo they are at the top level, one directory up from macos/.
RECORDER=""
CONFIG_PY=""
for candidate in "$SCRIPT_DIR/recorder.py" "$SCRIPT_DIR/../recorder.py"; do
	if [[ -f "$candidate" ]]; then RECORDER="$candidate"; break; fi
done
for candidate in "$SCRIPT_DIR/lockedin_config.py" "$SCRIPT_DIR/../lockedin_config.py"; do
	if [[ -f "$candidate" ]]; then CONFIG_PY="$candidate"; break; fi
done

# uv reads the dependency block inside recorder.py and installs them on first run, so
# it is much the better runner; a plain python3 works if the packages are already
# installed. Double-clicked apps don't always inherit a login shell PATH, hence the
# hard-coded fallbacks.
PY_RUNNER=()
for uv_bin in "$(command -v uv 2>/dev/null)" "$HOME/.local/bin/uv" "/opt/homebrew/bin/uv" "/usr/local/bin/uv"; do
	if [[ -n "$uv_bin" && -x "$uv_bin" ]]; then
		PY_RUNNER=("$uv_bin" "run" "--script")
		break
	fi
done
if [[ ${#PY_RUNNER[@]} -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
	PY_RUNNER=("$(command -v python3)")
fi

# ---------- Read the settings ----------
# The settings file holds the passcode hash, so there is no safe way to carry on
# without it — better to stop with an explanation than to run an exam session that
# can't be unlocked.
if [[ -z "$CONFIG_PY" || ${#PY_RUNNER[@]} -eq 0 ]]; then
	MISSING="lockedin_config.py was not found next to this script."
	if [[ ${#PY_RUNNER[@]} -eq 0 ]]; then
		MISSING="Locked In needs Python. Install uv, then run this again:

curl -LsSf https://astral.sh/uv/install.sh | sh"
	fi
	echo "$MISSING"
	osascript -e "display dialog \"$MISSING\" buttons {\"OK\"} default button \"OK\" with title \"Locked In\" with icon stop" >/dev/null 2>&1
	exit 1
fi

config_get() { "${PY_RUNNER[@]}" "$CONFIG_PY" "$@" 2>/dev/null; }

"${PY_RUNNER[@]}" "$CONFIG_PY" init >/dev/null 2>&1
ALLOWED_URL="$(config_get get-url)"
ALLOW_HOSTS=()
while IFS= read -r host; do
	[[ -n "$host" ]] && ALLOW_HOSTS+=("$host")
done < <(config_get get-hosts)
read -r RECORD_SCREEN RECORD_CAMERA RECORD_AUDIO <<<"$(config_get get-recording)"

if [[ -z "$ALLOWED_URL" || ${#ALLOW_HOSTS[@]} -eq 0 ]]; then
	echo "Could not read the settings. Open the admin panel and check them."
	osascript -e 'display dialog "Could not read the Locked In settings.

Open the admin panel (Admin button on the launcher) and check the allowed URL and hosts." buttons {"OK"} default button "OK" with title "Locked In" with icon stop' >/dev/null 2>&1
	exit 1
fi
echo "Allowed site: $ALLOWED_URL"

SESSION_DIR="$RECORD_DIR/$(date +%Y%m%d-%H%M%S)"
REC_PID=""

# ---------- Recording notice + consent ----------
# This runs before the admin prompt and before any lockdown, so declining leaves the
# machine completely untouched.
recording_summary() {
	local lines=()
	[[ "$RECORD_SCREEN" == true ]] && lines+=("  •  everything on your screen")
	[[ "$RECORD_CAMERA" == true ]] && lines+=("  •  your webcam")
	[[ "$RECORD_AUDIO"  == true ]] && lines+=("  •  your microphone")
	printf '%s\n' "${lines[@]}"
}

if [[ "$RECORD_SCREEN" == true || "$RECORD_CAMERA" == true || "$RECORD_AUDIO" == true ]]; then
	if [[ "$REQUIRE_CONSENT" == true ]]; then
		NOTICE="This session will be RECORDED.

The following are captured for the whole session:
$(recording_summary)

Recordings are saved on this Mac, in:
$SESSION_DIR

Recording starts when you click Agree and stops when the session ends. If you do not
agree, click Cancel — nothing is recorded and nothing on this Mac is changed."
		if ! osascript -e "display dialog \"$NOTICE\" buttons {\"Cancel\", \"Agree and start\"} default button \"Agree and start\" cancel button \"Cancel\" with title \"Locked In — recording notice\" with icon caution" >/dev/null 2>&1; then
			echo "Declined — nothing was recorded and nothing was changed. Exiting."
			exit 0
		fi
	fi

	if [[ -z "$RECORDER" ]]; then
		echo "WARNING: recorder.py not found next to this script — continuing WITHOUT recording."
	elif [[ ${#PY_RUNNER[@]} -eq 0 ]]; then
		echo "WARNING: no uv or python3 found — continuing WITHOUT recording."
		echo "         Install uv:  curl -LsSf https://astral.sh/uv/install.sh | sh"
	else
		REC_FLAGS=()
		[[ "$RECORD_SCREEN" != true ]] && REC_FLAGS+=("--no-screen")
		[[ "$RECORD_CAMERA" != true ]] && REC_FLAGS+=("--no-camera")
		[[ "$RECORD_AUDIO"  != true ]] && REC_FLAGS+=("--no-audio")
		mkdir -p "$SESSION_DIR"
		echo "Starting the recording (first run installs the Python packages, ~30s)..."
		"${PY_RUNNER[@]}" "$RECORDER" --out-dir "$SESSION_DIR" "${REC_FLAGS[@]}" \
			>"$SESSION_DIR/recorder.log" 2>&1 &
		REC_PID=$!
		# Give it a moment to fall over loudly (missing permission, no camera) rather
		# than silently recording nothing for the whole exam.
		sleep 3
		if ! kill -0 "$REC_PID" 2>/dev/null; then
			REC_PID=""
			echo "WARNING: the recorder exited immediately. Details:"
			tail -5 "$SESSION_DIR/recorder.log" 2>/dev/null
			osascript -e 'display dialog "The recorder could not start, so this session is NOT being recorded.

Most likely Terminal has not been granted Screen Recording / Camera / Microphone access in System Settings > Privacy & Security.

See recorder.log in the session folder." buttons {"Continue anyway"} default button "Continue anyway" with title "Locked In" with icon stop' >/dev/null 2>&1
		else
			echo "Recording to: $SESSION_DIR"
		fi
	fi
fi

# Don't let the Mac sleep mid-session and cut the recording short. -w makes caffeinate
# exit by itself as soon as this script does.
caffeinate -dimsu -w $$ >/dev/null 2>&1 &

# Close the recording files cleanly. The STOP sentinel and the signal are two routes
# to the same graceful shutdown; whichever lands first wins.
stop_recording() {
	[[ -z "$REC_PID" ]] && return
	touch "$SESSION_DIR/STOP" 2>/dev/null
	kill -INT "$REC_PID" 2>/dev/null
	local waited=0
	while kill -0 "$REC_PID" 2>/dev/null && (( waited < 200 )); do
		sleep 0.1
		waited=$((waited + 1))
	done
	kill -9 "$REC_PID" 2>/dev/null   # last resort after 20s; mp4s keep what was flushed
	REC_PID=""
}

# ---------- Get admin rights for the Chrome policy ----------
echo "Guided Access needs your admin password to lock Chrome (disable incognito + DevTools)..."
if ! sudo -v; then
	echo "No admin password provided — cannot lock Chrome settings. Exiting."
	stop_recording
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
	stop_recording
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
# The AppleScript never sees the passcode — it pipes whatever was typed into the
# verifier, which compares it against the stored hash and answers with its exit code.
VERIFY_CMD="$(printf '%q ' "${PY_RUNNER[@]}" "$CONFIG_PY")verify-passcode"

osascript - "$ALLOWED_URL" "$VERIFY_CMD" "${ALLOW_HOSTS[@]}" <<'APPLESCRIPT'

-- Pipe the entry into the verifier on stdin (never as an argument — arguments are
-- visible to every other process). A non-zero exit raises, which means "wrong".
on passcodeAccepted(entry, verifyCmd)
	try
		do shell script "printf '%s' " & quoted form of entry & " | " & verifyCmd
		return true
	on error
		return false
	end try
end passcodeAccepted

on run argv
	set allowedURL to item 1 of argv
	set verifyCmd to item 2 of argv
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
					if entry is not "" then
						if my passcodeAccepted(entry, verifyCmd) then set unlocked to true
					end if
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
# stop_recording comes first: closing the video files matters more than tidying Chrome,
# and it is the step that takes real time.
echo "Finalizing the recording..."
stop_recording
remove_policy
kill "$KEEPALIVE_PID" 2>/dev/null
killall "Google Chrome" 2>/dev/null

if [[ -d "$SESSION_DIR" ]]; then
	SAVED="

Recording saved to:
$SESSION_DIR"
else
	SAVED=""
fi

osascript <<END
display dialog "Guided Access ended. Chrome is unlocked (incognito + DevTools restored) and you can browse normally again.$SAVED" buttons {"OK"} default button "OK" with title "Guided Access"
END
