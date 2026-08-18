#!/bin/bash
#
# build.sh — compiles the "Locked In" macOS launcher into ../dist/Locked In.app
#
# Usage:
#   ./build.sh            build the app (reuses ../assets/AppIcon.icns)
#   ./build.sh --icon     regenerate AppIcon.icns from src/mkicon.swift first
#
# Requires the Xcode Command Line Tools (swiftc, iconutil, codesign):
#   xcode-select --install

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$ROOT/dist/Locked In.app"
ICNS="$ROOT/assets/AppIcon.icns"
BUILD="$HERE/.build"

# ---------- optional: regenerate the icon ----------
if [[ "${1:-}" == "--icon" ]]; then
	echo "==> regenerating AppIcon.icns"
	mkdir -p "$BUILD"
	swiftc -O "$HERE/src/mkicon.swift" -o "$BUILD/mkicon"
	( cd "$BUILD" && ./mkicon )   # writes icon_1024.png
	rm -rf "$BUILD/AppIcon.iconset"
	mkdir -p "$BUILD/AppIcon.iconset"
	for s in 16 32 128 256 512; do
		sips -z $s   $s   "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png"    >/dev/null
		sips -z $((s*2)) $((s*2)) "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
	done
	iconutil -c icns "$BUILD/AppIcon.iconset" -o "$ICNS"
fi

# ---------- compile the launcher ----------
mkdir -p "$BUILD"

# Compile from a copy outside the project, not from src/ in place. On an
# iCloud-synced Desktop the file provider touches the sources while swiftc is
# reading them, and swiftc fails the build outright with "input file was modified
# during the build". A staging directory under /tmp is not synced by anything.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lockedin-build-XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$HERE/src/main.swift" "$HERE/src/overlay.swift" "$STAGE/"

echo "==> compiling main.swift"
swiftc -O "$STAGE/main.swift" -o "$BUILD/LockedIn"

# The floating "End exam" pill the lockdown draws over Chrome. Separate binary
# rather than part of the launcher: the launcher has quit long before it is needed,
# and this one has to run as an accessory app so the lockdown leaves it alone.
echo "==> compiling overlay.swift"
swiftc -O "$STAGE/overlay.swift" -o "$BUILD/LockedInOverlay"

# ---------- assemble the bundle ----------
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/src/Info.plist"          "$APP/Contents/Info.plist"
cp "$BUILD/LockedIn"               "$APP/Contents/MacOS/LockedIn"
cp "$BUILD/LockedInOverlay"        "$APP/Contents/Resources/LockedInOverlay"
cp "$ICNS"                         "$APP/Contents/Resources/AppIcon.icns"
cp "$HERE/guided-access.command"   "$APP/Contents/Resources/guided-access.command"
# The Python helpers ship inside the bundle so the app is self-contained: the lockdown
# reads its settings through lockedin_config.py, records with recorder.py, and the
# Admin button opens admin_panel.py. For proctored exams it also runs the check-in
# (student_session.py) and the live feed (uploader.py), both of which talk to Supabase
# through lockedin_cloud.py.
for helper in recorder.py lockedin_config.py admin_panel.py \
              lockedin_cloud.py student_session.py uploader.py; do
	cp "$ROOT/src/$helper" "$APP/Contents/Resources/$helper"
done
# The dashboard and its little server ship too, so the Faculty button can publish the
# page on the local wi-fi from a bundle that was copied to a machine on its own.
mkdir -p "$APP/Contents/Resources/dashboard"
cp "$ROOT/server/serve.py"             "$APP/Contents/Resources/serve.py"
cp "$ROOT/server/dashboard/index.html" "$APP/Contents/Resources/dashboard/index.html"
chmod +x "$APP/Contents/MacOS/LockedIn" "$APP/Contents/Resources/guided-access.command" \
         "$APP/Contents/Resources/LockedInOverlay"

# ---------- ad-hoc sign ----------
# No paid Developer ID here, so this is an ad-hoc signature. Gatekeeper will still
# ask for right-click -> Open the first time on another Mac.
#
# Strip extended attributes first. Launching the app, or copying it through Finder
# or a cloud folder, leaves quarantine flags and Finder metadata behind, and
# codesign refuses those outright: "resource fork, Finder information, or similar
# detritus not allowed". Without this, the build works once and then fails for
# everyone who has actually run the thing.
echo "==> ad-hoc signing"
# Retried, because clearing the attributes is not always the end of it: on a Desktop
# or Documents folder synced by iCloud, the file provider re-stamps com.apple.FinderInfo
# on the bundle within moments, and codesign refuses whatever it finds at the instant
# it looks. Clearing and signing in a tight loop wins that race; three tries is plenty.
signed=false
for attempt in 1 2 3; do
	xattr -cr "$APP" 2>/dev/null || true
	xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
	if codesign --force --deep --sign - "$APP" 2>/dev/null; then
		signed=true
		break
	fi
	sleep 1
done
if [[ "$signed" != true ]]; then
	echo "!! codesign failed three times. If this bundle lives in an iCloud-synced" >&2
	echo "   folder, build it somewhere local instead — the sync daemon keeps" >&2
	echo "   putting Finder metadata back faster than it can be cleared." >&2
	exit 1
fi
codesign -dv "$APP" 2>&1 | head -4

echo "==> done: $APP"
