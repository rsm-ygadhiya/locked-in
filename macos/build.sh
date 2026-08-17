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
echo "==> compiling main.swift"
mkdir -p "$BUILD"
swiftc -O "$HERE/src/main.swift" -o "$BUILD/LockedIn"

# ---------- assemble the bundle ----------
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/src/Info.plist"          "$APP/Contents/Info.plist"
cp "$BUILD/LockedIn"               "$APP/Contents/MacOS/LockedIn"
cp "$ICNS"                         "$APP/Contents/Resources/AppIcon.icns"
cp "$HERE/guided-access.command"   "$APP/Contents/Resources/guided-access.command"
# The Python helpers ship inside the bundle so the app is self-contained: the lockdown
# reads its settings through lockedin_config.py, records with recorder.py, and the
# Admin button opens admin_panel.py. For proctored exams it also runs the check-in
# (student_session.py) and the live feed (uploader.py), both of which talk to Supabase
# through lockedin_cloud.py.
for helper in recorder.py lockedin_config.py admin_panel.py \
              lockedin_cloud.py student_session.py uploader.py; do
	cp "$ROOT/$helper" "$APP/Contents/Resources/$helper"
done
chmod +x "$APP/Contents/MacOS/LockedIn" "$APP/Contents/Resources/guided-access.command"

# ---------- ad-hoc sign ----------
# No paid Developer ID here, so this is an ad-hoc signature. Gatekeeper will still
# ask for right-click -> Open the first time on another Mac.
echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"
codesign -dv "$APP" 2>&1 | head -4

echo "==> done: $APP"
