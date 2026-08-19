#!/bin/bash
#
# guided-access.command  —  a Chrome "Guided Access" / single-site lockdown for macOS
#
# What it does:
#   0. If this Mac is set up for proctored exams, runs the check-in first
#      (student_session.py): sign in, join code, consent, photograph the student ID,
#      then wait for a proctor to approve. Nothing below happens without approval.
#   1. Shows the recording notice and waits for the student to agree (nothing below
#      this point happens if they decline; skipped when the check-in already got it)
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
# recorded all live in the settings file now, not in this script. Edit them from the
# launcher under Faculty > Exam settings (or: uv run --script src/admin_panel.py).
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
# clone of the repo they are in src/, one directory up from macos/.
RECORDER=""
CONFIG_PY=""
CHECKIN_PY=""
UPLOADER_PY=""
CLOUD_PY=""
for candidate in "$SCRIPT_DIR/recorder.py" "$SCRIPT_DIR/../src/recorder.py" \
                 "$SCRIPT_DIR/../recorder.py"; do
	if [[ -f "$candidate" ]]; then RECORDER="$candidate"; break; fi
done
for candidate in "$SCRIPT_DIR/lockedin_config.py" "$SCRIPT_DIR/../src/lockedin_config.py" \
                 "$SCRIPT_DIR/../lockedin_config.py"; do
	if [[ -f "$candidate" ]]; then CONFIG_PY="$candidate"; break; fi
done
for candidate in "$SCRIPT_DIR/student_session.py" "$SCRIPT_DIR/../src/student_session.py" \
                 "$SCRIPT_DIR/../student_session.py"; do
	if [[ -f "$candidate" ]]; then CHECKIN_PY="$candidate"; break; fi
done
for candidate in "$SCRIPT_DIR/uploader.py" "$SCRIPT_DIR/../src/uploader.py" \
                 "$SCRIPT_DIR/../uploader.py"; do
	if [[ -f "$candidate" ]]; then UPLOADER_PY="$candidate"; break; fi
done
for candidate in "$SCRIPT_DIR/lockedin_cloud.py" "$SCRIPT_DIR/../src/lockedin_cloud.py" \
                 "$SCRIPT_DIR/../lockedin_cloud.py"; do
	if [[ -f "$candidate" ]]; then CLOUD_PY="$candidate"; break; fi
done

# The floating "End exam" pill. Built by macos/build.sh, so it exists inside the
# .app bundle and in macos/.build for anyone running from a clone. Missing is not an
# error: the lockdown then behaves exactly as it did before it existed, and quitting
# Chrome is still the way out.
OVERLAY_BIN=""
for candidate in "$SCRIPT_DIR/LockedInOverlay" "$SCRIPT_DIR/.build/LockedInOverlay" \
                 "$SCRIPT_DIR/../macos/.build/LockedInOverlay"; do
	if [[ -x "$candidate" ]]; then OVERLAY_BIN="$candidate"; break; fi
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

# A plain interpreter as well as the runner. `uv run --script` needs a file, so it
# cannot read a snippet from stdin, and reading one JSON field is not worth a whole
# extra helper file. Anything with a standard library will do here.
PLAIN_PY=""
for py in "$(command -v python3 2>/dev/null)" "/opt/homebrew/bin/python3" "/usr/local/bin/python3" "/usr/bin/python3"; do
	if [[ -n "$py" && -x "$py" ]]; then PLAIN_PY="$py"; break; fi
done

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

Open the launcher, choose Faculty > Exam settings, and check the allowed URL and hosts." buttons {"OK"} default button "OK" with title "Locked In" with icon stop' >/dev/null 2>&1
	exit 1
fi
SESSION_DIR="$RECORD_DIR/$(date +%Y%m%d-%H%M%S)"
REC_PID=""
UPLOAD_PID=""
PROCTORED=false
LIVE_SESSION_ID=""

# ---------- Proctored check-in ----------
# When a Supabase project is configured, a student cannot get into the lockdown by
# themselves: student_session.py signs them in, photographs their ID, and waits for
# a proctor to approve them. It exits non-zero if that does not happen, and this
# script stops there — before the admin prompt, before any policy is written, so a
# student who was not admitted leaves with their Mac untouched.
#
# With no project configured, everything below is skipped and this behaves exactly
# as it always did: a local, standalone lockdown.
if "${PY_RUNNER[@]}" "$CONFIG_PY" cloud-enabled >/dev/null 2>&1; then
	if [[ -z "$CHECKIN_PY" ]]; then
		echo "This machine is set up for proctored exams but student_session.py is missing."
		osascript -e 'display dialog "This Mac is configured for proctored exams, but student_session.py is missing next to the lockdown script.

Reinstall Locked In, or clear the Supabase settings in the admin panel to run it standalone." buttons {"OK"} default button "OK" with title "Locked In" with icon stop' >/dev/null 2>&1
		exit 1
	fi

	mkdir -p "$SESSION_DIR"
	echo "Opening check-in (sign in, photograph your ID, wait for your proctor)..."
	if ! "${PY_RUNNER[@]}" "$CHECKIN_PY" --session-dir "$SESSION_DIR"; then
		echo "Check-in was not completed — the exam was not started, and nothing on this Mac was changed."
		# An empty session folder is just noise on the Desktop.
		rmdir "$SESSION_DIR" 2>/dev/null
		exit 1
	fi

	HANDOFF="$SESSION_DIR/handoff.json"
	if [[ ! -f "$HANDOFF" ]]; then
		echo "Check-in finished but left no approval on disk. Not starting the exam."
		exit 1
	fi

	# One short Python call rather than a pile of sed: the handoff is JSON, and the
	# allowed URL can contain characters that would need escaping anyway.
	LIVE_SESSION_ID=""
	LIVE_EXAM_ID=""
	EXAM_URL=""
	EXAM_SNAP_INTERVAL=""
	if [[ -n "$PLAIN_PY" ]]; then
		read -r LIVE_SESSION_ID LIVE_EXAM_ID EXAM_URL < <(
			"$PLAIN_PY" -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
print(data.get("session_id", ""), data.get("exam_id", ""), data.get("allowed_url", ""))
' "$HANDOFF" 2>/dev/null
		)
		# What this exam records. The exam decides, not this machine's settings —
		# the person who set the exam up is the one who chose whether a webcam is
		# filmed, and they are not standing at this laptop.
		read -r RECORD_SCREEN RECORD_CAMERA RECORD_AUDIO LIVE_TILES EXAM_SNAP_INTERVAL < <(
			"$PLAIN_PY" -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
def flag(key):
    return "true" if data.get(key, True) else "false"
print(flag("record_screen"), flag("record_camera"), flag("record_audio"),
      flag("live_tiles"), data.get("snapshot_interval", 60))
' "$HANDOFF" 2>/dev/null
		)
		# The other tabs, one per line so a URL with spaces survives the trip.
		EXAM_TABS=()
		while IFS= read -r line; do
			[[ -n "$line" ]] && EXAM_TABS+=("$line")
		done < <(
			"$PLAIN_PY" -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
for url in data.get("extra_urls") or []:
    if url:
        print(url)
' "$HANDOFF" 2>/dev/null
		)
		echo "This exam records: screen=$RECORD_SCREEN camera=$RECORD_CAMERA audio=$RECORD_AUDIO"
		echo "Live tiles: $LIVE_TILES · kept frames every ${EXAM_SNAP_INTERVAL}s (0 = none)"
	fi
	if [[ -z "$LIVE_SESSION_ID" || -z "$EXAM_URL" ]]; then
		echo "The approval file was unreadable. Not starting the exam."
		exit 1
	fi
	# The exam decides the allowed site, not this laptop's local settings.
	ALLOWED_URL="$EXAM_URL"
	EXAM_HOST="$(printf '%s' "$ALLOWED_URL" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#')"
	[[ -n "$EXAM_HOST" ]] && ALLOW_HOSTS+=("$EXAM_HOST")
	# Every extra tab is only usable if Chrome will load it, so each one's host has
	# to be on the allowlist as well. An exam that opens a calculator the policy
	# blocks would show the student a blocked page and nothing else.
	for tab in "${EXAM_TABS[@]:-}"; do
		[[ -z "$tab" ]] && continue
		tab_host="$(printf '%s' "$tab" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#')"
		[[ -n "$tab_host" ]] && ALLOW_HOSTS+=("$tab_host")
	done
	if [[ ${#EXAM_TABS[@]:-0} -gt 0 ]]; then
		echo "This exam also opens: ${EXAM_TABS[*]}"
	fi
	PROCTORED=true
	echo "Approved. Session $LIVE_SESSION_ID"
fi

echo "Allowed site: $ALLOWED_URL"

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
	# A proctored student already read the consent text and ticked the box during
	# check-in; asking a second time in a different dialog just trains people to
	# click through notices.
	if [[ "$REQUIRE_CONSENT" == true && "$PROCTORED" != true ]]; then
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
		# In a proctored exam the recorder also keeps two small JPEGs current for
		# uploader.py to publish to the proctor's dashboard.
		# --live-tiles is what makes the recorder keep two small JPEGs current on
		# disk. Both the live grid and the kept frames are published from those same
		# two files, so it has to be on if *either* is wanted — turning it off
		# because the grid is off would silently stop the kept frames as well, which
		# is the setting somebody chose on purpose.
		#
		# What the proctor actually sees is decided further down, by whether the
		# uploader is told --no-tiles.
		WANT_TILES=false
		[[ "${LIVE_TILES:-true}" == true ]] && WANT_TILES=true
		[[ -n "${EXAM_SNAP_INTERVAL:-}" && "${EXAM_SNAP_INTERVAL:-0}" != 0 ]] && WANT_TILES=true
		[[ "$PROCTORED" == true && "$WANT_TILES" == true ]] && REC_FLAGS+=("--live-tiles")
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

# ---------- Start the live feed to the proctor ----------
# Separate process from the recorder on purpose: the camera can only be held by one
# process, and a stalled upload must never cost frames of the exam recording. If
# this dies, the recording carries on and the dashboard simply shows the student as
# stale.
#
# It runs whether or not the recorder does, and that is not a detail. This process
# carries the things that are not pictures: the heartbeat, the events, the flip to
# 'ended', and the note saying how the session ended. An in-person exam that records
# nothing and publishes nothing still wants all four — and with every stream turned
# off the recorder exits on purpose, which used to take the uploader with it and
# silently ended the flagging along with the pictures.
if [[ "$PROCTORED" == true && -n "$UPLOADER_PY" ]]; then
	UPLOAD_FLAGS=()
	# The exam's own cadence for kept frames, and whether the grid gets pictures
	# at all. Both come from the exam row; the machine's settings only decide when
	# there is no exam.
	[[ -n "$EXAM_SNAP_INTERVAL" ]] && UPLOAD_FLAGS+=("--snapshot-interval" "$EXAM_SNAP_INTERVAL")
	[[ "${LIVE_TILES:-true}" != true ]] && UPLOAD_FLAGS+=("--no-tiles")
	"${PY_RUNNER[@]}" "$UPLOADER_PY" \
		--session-dir "$SESSION_DIR" \
		--session-id "$LIVE_SESSION_ID" \
		--token-file "$SESSION_DIR/token.json" \
		"${UPLOAD_FLAGS[@]}" \
		>"$SESSION_DIR/uploader.log" 2>&1 &
	UPLOAD_PID=$!
	sleep 1
	if ! kill -0 "$UPLOAD_PID" 2>/dev/null; then
		UPLOAD_PID=""
		echo "WARNING: the live feed to your proctor could not start. The exam is still"
		echo "         being recorded locally. Details in uploader.log."
	else
		echo "Live feed to the proctor: on"
	fi
elif [[ "$PROCTORED" == true && -z "$REC_PID" ]]; then
	echo "WARNING: nothing is being recorded, so there is no live feed either."
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

# The uploader is signalled rather than left to notice the STOP file: the recorder
# deletes that file when it finishes, so whichever of the two looks second might
# never see it.
stop_uploading() {
	[[ -z "$UPLOAD_PID" ]] && return
	kill -INT "$UPLOAD_PID" 2>/dev/null
	local waited=0
	while kill -0 "$UPLOAD_PID" 2>/dev/null && (( waited < 100 )); do
		sleep 0.1
		waited=$((waited + 1))
	done
	kill -9 "$UPLOAD_PID" 2>/dev/null
	UPLOAD_PID=""
}

# The token file is the student's credential for the whole session. uploader.py
# deletes it as soon as it has read it; this is the safety net for the paths where
# the uploader never ran.
scrub_token() {
	rm -f "$SESSION_DIR/token.json" "$SESSION_DIR/verify-exit.sh" 2>/dev/null
}

# ---------- Get admin rights for the Chrome policy ----------
echo "Guided Access needs your admin password to lock Chrome (disable incognito + DevTools)..."
if ! sudo -v; then
	echo "No admin password provided — cannot lock Chrome settings. Exiting."
	# The EXIT trap is not installed yet, so unwind by hand.
	stop_uploading
	stop_recording
	scrub_token
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

# How this session ended, in the proctor's timeline. Runs before the token is
# scrubbed, because it needs it.
#
# The absence of a marker file is itself the answer: nothing wrote one, so nobody
# typed a code that was accepted — Ctrl+C, a signal, a crash. A hard kill of this
# script writes nothing at all and reaches nothing, which is why the dashboard also
# watches for sessions that simply stop checking in.
log_exit_kind() {
	[[ "$PROCTORED" != true || -z "$LIVE_SESSION_ID" || -z "$CLOUD_PY" ]] && return
	[[ -f "$SESSION_DIR/token.json" ]] || return
	local kind="exit.signal"
	local detail="ended without a verified exit code"
	if [[ -f "$SESSION_DIR/exit-kind" ]]; then
		kind="$(cat "$SESSION_DIR/exit-kind" 2>/dev/null)"
		case "$kind" in
			exit.code)     detail="the exam's own exit code was accepted" ;;
			exit.passcode) detail="this machine's local passcode was used" ;;
			exit.proctor)  detail="the proctor ended the exam from the dashboard" ;;
			*)             kind="exit.signal" ;;
		esac
	fi
	"${PY_RUNNER[@]}" "$CLOUD_PY" log-event "$LIVE_SESSION_ID" \
		"$SESSION_DIR/token.json" "$kind" "$detail" >/dev/null 2>&1 || true
}

# ALWAYS undo everything on exit, even on crash / Ctrl+C.
cleanup() {
	log_exit_kind
	# Uploader first: it needs the live tiles to still exist to publish a last frame,
	# and it is what marks the session ended for the proctor.
	stop_uploading
	stop_recording
	scrub_token
	remove_policy
	kill "$KEEPALIVE_PID" 2>/dev/null
	# The pill outlives the AppleScript on any path that is not a clean exit, and a
	# floating "End exam" button over an unlocked machine would be a puzzle.
	[[ -n "${OVERLAY_PID:-}" ]] && kill "$OVERLAY_PID" 2>/dev/null
	rm -f "${RELEASE_FILE:-}" "${PROMPT_FILE:-}" 2>/dev/null
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

# ---------- What ends the lockdown ----------
# The AppleScript never sees what was typed — it pipes it into a verifier and reads
# the exit code.
#
# In a proctored exam that verifier asks the server whether this is the exam's own
# exit code, so each exam has its own and a student cannot learn it by reading
# anything on their machine: the hash lives in the database and the answer comes
# back as a yes or a no.
#
# The local passcode stays as a fallback, and that is deliberate. If the network is
# down at the moment a proctor tries to release a machine, refusing would leave a
# student locked in a browser with no way out — so an unreachable server falls
# through to the machine's own passcode rather than failing closed.
# Standalone: the only door is the machine's own passcode, and it still records
# that it was used, so a session folder always says how it ended.
STANDALONE_HELPER="$SESSION_DIR/verify-passcode.sh"
{
	echo '#!/bin/bash'
	echo 'code="$(cat)"'
	printf 'printf %%s "$code" | %s verify-passcode >/dev/null 2>&1\n' \
		"$(printf '%q ' "${PY_RUNNER[@]}" "$CONFIG_PY")"
	printf 'rc=$?\n'
	printf '[[ $rc -eq 0 ]] && echo exit.passcode >%q\n' "$SESSION_DIR/exit-kind"
	printf 'exit $rc\n'
} >"$STANDALONE_HELPER"
chmod +x "$STANDALONE_HELPER"
VERIFY_CMD="$(printf '%q' "$STANDALONE_HELPER")"

if [[ "$PROCTORED" == true && -n "$LIVE_EXAM_ID" && -n "$CLOUD_PY" ]]; then
	EXIT_HELPER="$SESSION_DIR/verify-exit.sh"
	{
		echo '#!/bin/bash'
		echo '# Written per session by guided-access.command. Reads the typed code on'
		echo '# stdin. 0 = correct, 1 = wrong.'
		echo '#'
		echo '# Two things fall through to the local passcode, and neither is optional:'
		echo '# an unreachable server, and an exam whose proctor never set an exit code.'
		echo '# The second one used to be treated as a wrong code, which left the'
		echo '# student behind a code that did not exist, with Force Quit as the only'
		echo '# way out.'
		echo 'code="$(cat)"'
		printf 'printf %%s "$code" | %s verify-exit %q %q >/dev/null 2>&1\n' \
			"$(printf '%q ' "${PY_RUNNER[@]}" "$CLOUD_PY")" \
			"$LIVE_EXAM_ID" "$SESSION_DIR/token.json"
		echo 'rc=$?'
		# Which door was used, for the proctor's timeline. The trustworthy record
		# is exit_verified_at, which the server writes; this only explains it.
		printf 'if [[ $rc -eq 0 ]]; then echo exit.code >%q; exit 0; fi\n' \
			"$SESSION_DIR/exit-kind"
		printf 'if [[ $rc -eq 1 ]]; then\n'
		printf '\t%s has-exit-code %q %q >/dev/null 2>&1\n' \
			"$(printf '%q ' "${PY_RUNNER[@]}" "$CLOUD_PY")" \
			"$LIVE_EXAM_ID" "$SESSION_DIR/token.json"
		printf '\t[[ $? -eq 0 ]] && exit 1   # the exam has a code, and that was not it\n'
		printf 'fi\n'
		printf 'printf %%s "$code" | %s verify-passcode >/dev/null 2>&1\n' \
			"$(printf '%q ' "${PY_RUNNER[@]}" "$CONFIG_PY")"
		printf 'rc=$?\n'
		printf '[[ $rc -eq 0 ]] && echo exit.passcode >%q\n' "$SESSION_DIR/exit-kind"
		printf 'exit $rc\n'
	} >"$EXIT_HELPER"
	chmod +x "$EXIT_HELPER"
	VERIFY_CMD="$(printf '%q' "$EXIT_HELPER")"
	echo "Exit code: this exam's own (the machine passcode still works if the network drops)"
fi

# Two files the overlay and the AppleScript loop talk through. RELEASE means "a
# correct code was typed into the pill, let them out"; PROMPTING means "the code
# prompt is open, stop pulling focus back to Chrome for a moment".
RELEASE_FILE="$SESSION_DIR/RELEASE"
PROMPT_FILE="$SESSION_DIR/PROMPTING"
rm -f "$RELEASE_FILE" "$PROMPT_FILE"
OVERLAY_PID=""
if [[ -n "$OVERLAY_BIN" ]]; then
	"$OVERLAY_BIN" "$VERIFY_CMD" "$RELEASE_FILE" "$PROMPT_FILE" \
		>"$SESSION_DIR/overlay.log" 2>&1 &
	OVERLAY_PID=$!
	echo "Floating exit button: on (drag it anywhere; click it to enter the code)"
else
	echo "Floating exit button: not built — quit Chrome to be asked for the code"
fi

# The AppleScript takes the tab list as one newline-separated argument, so the
# allowed-hosts list that follows stays unambiguous however many tabs there are.
TABS_ARG=""
if [[ ${#EXAM_TABS[@]:-0} -gt 0 ]]; then
	TABS_ARG="$(printf '%s\n' "${EXAM_TABS[@]}")"
fi

osascript - "$ALLOWED_URL" "$VERIFY_CMD" "$RELEASE_FILE" "$PROMPT_FILE" "$TABS_ARG" "${ALLOW_HOSTS[@]}" <<'APPLESCRIPT'

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

-- POSIX file / "exists" is fussy about paths that do not exist yet, so ask the
-- shell instead: it is one process every 0.3s and it never raises.
-- The tab list arrives as one newline-separated argument.
on splitLines(blob)
	set out to {}
	if blob is "" then return out
	set saved to AppleScript's text item delimiters
	set AppleScript's text item delimiters to (ASCII character 10)
	repeat with piece in text items of blob
		set piece to piece as string
		if piece is not "" then set end of out to piece
	end repeat
	set AppleScript's text item delimiters to saved
	return out
end splitLines

-- The host part of a URL, which is what "is this tab still open" is judged on: a
-- student working inside the allowed site changes the path constantly and has not
-- closed anything.
on hostOf(theURL)
	try
		set saved to AppleScript's text item delimiters
		set AppleScript's text item delimiters to "//"
		set rest to text item 2 of theURL
		set AppleScript's text item delimiters to "/"
		set theHost to text item 1 of rest
		set AppleScript's text item delimiters to saved
		return theHost
	on error
		return theURL
	end try
end hostOf

-- Put back any tab the exam is supposed to have. This is the answer to closing a
-- tab with ⌘W or the window's own close button: it comes straight back, in the
-- same window, without ending the exam or demanding a code for something a student
-- may well have done by accident.
on ensureTabs(requiredURLs)
	if requiredURLs is {} then return
	try
		tell application "Google Chrome"
			if (count of windows) is 0 then return
			set openHosts to {}
			repeat with w from 1 to (count of windows)
				repeat with t from 1 to (count of tabs of window w)
					set end of openHosts to my hostOf(URL of tab t of window w)
				end repeat
			end repeat
			repeat with wanted in requiredURLs
				set wantedHost to my hostOf(wanted as string)
				if wantedHost is not in openHosts then
					tell window 1 to make new tab with properties {URL:wanted as string}
				end if
			end repeat
		end tell
	end try
end ensureTabs

-- Cold-start Chrome with its own kiosk mode. open -na is what makes the flags
-- apply: without -n an already-running Chrome just gets a new window and ignores
-- them, which is the difference between a locked screen and a browser somebody can
-- ⌘Tab away from.
on launchKiosk(allowedURL, extraTabs)
	-- One tab means kiosk: no tab strip, no omnibox, nothing to click. Several tabs
	-- means the student has to be able to see and switch them, so it is Chrome's
	-- own --start-fullscreen instead — same automatic fullscreen, tab strip kept.
	-- Either way the managed policy is what decides where they can go; this only
	-- decides how much of the browser they can see.
	set flags to "--kiosk "
	if extraTabs is not {} then set flags to "--start-fullscreen "
	set urls to quoted form of allowedURL
	repeat with extra in extraTabs
		set urls to urls & " " & quoted form of (extra as string)
	end repeat
	try
		do shell script "open -na 'Google Chrome' --args " & flags & ¬
			"--disable-session-crashed-bubble --no-first-run --no-default-browser-check " & ¬
			urls
	on error
		-- No Chrome at that name, or open refused: fall back to the old way so the
		-- exam still starts.
		try
			tell application "Google Chrome"
				activate
				if (count of windows) is 0 then make new window
				set URL of active tab of front window to allowedURL
			end tell
			tell application "System Events" to keystroke "f" using {control down, command down}
		end try
	end try
end launchKiosk

on fileExists(path)
	try
		do shell script "test -e " & quoted form of path
		return true
	on error
		return false
	end try
end fileExists

on run argv
	set allowedURL to item 1 of argv
	set verifyCmd to item 2 of argv
	set releaseFile to item 3 of argv
	set promptFile to item 4 of argv
	set extraTabs to my splitLines(item 5 of argv)
	set requiredURLs to {allowedURL}
	repeat with extra in extraTabs
		set end of requiredURLs to (extra as string)
	end repeat
	set targetApp to "Google Chrome"
	-- allowed hosts = every arg from the sixth onward
	set allowedHosts to {}
	repeat with i from 6 to (count of argv)
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

	-- ---------- Open Chrome at the allowed URL, in kiosk mode ----------
	-- Chrome's own --kiosk: fullscreen, no tab strip, no omnibox, and no Dock or
	-- menu bar. It replaces sending ⌃⌘F through System Events, which needed
	-- Accessibility permission for Terminal and did nothing at all without it —
	-- which is why the window kept coming up as an ordinary one that somebody had
	-- to full-screen by hand.
	--
	-- The flags only apply to a cold start, which is why the caller kills Chrome
	-- first.
	my launchKiosk(allowedURL, extraTabs)
	delay 2
	-- Backstop for the case where Chrome was already running and ignored the flags.
	tell application "System Events"
		if not (exists (process "Google Chrome")) then return
	end tell
	try
		tell application "Google Chrome"
			if (count of windows) is 0 then make new window
		end tell
	end try

	-- ---------- Lockdown loop ----------
	repeat
		try
			-- The floating pill got a correct code. Same ending as the passcode
			-- dialog below: put everything back and stop.
			if my fileExists(releaseFile) then
				try
					tell application "System Events" to set visible of (every application process whose background only is false) to true
				end try
				exit repeat
			end if

			set runningNames to {}
			tell application "System Events"
				set runningNames to name of (every application process whose background only is false)
			end tell

			if targetApp is not in runningNames then
				-- Chrome was closed: relaunch INSTANTLY, in kiosk again, and force it
				-- back to the site...
				my launchKiosk(allowedURL, extraTabs)
				delay 1
				try
					tell application "Google Chrome"
						if (count of windows) is 0 then make new window
						set URL of active tab of front window to allowedURL
					end tell
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
				-- While the pill's code prompt is open, leave focus alone: pulling
				-- Chrome back to the front every 0.3s would eat the keystrokes of
				-- whoever is typing the code.
				if frontApp is not targetApp and not my fileExists(promptFile) then
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

				-- Closing the window is not quitting Chrome: on macOS the app stays
				-- running with no windows at all, so the check above sees Chrome
				-- "running" and the student sees their desktop. Put a window back,
				-- full screen, at the exam.
				try
					tell application "Google Chrome"
						if (count of windows) is 0 then
							make new window
							set URL of active tab of front window to allowedURL
							activate
							delay 0.4
							try
								tell application "System Events" to keystroke "f" using {control down, command down}
							end try
						end if
					end tell
				end try

				-- Any tab the exam provides that has been closed comes back.
				my ensureTabs(requiredURLs)

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
