#!/usr/bin/env bash
# Builds Crowsnest.app into ./build (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG" --product Crowsnest
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Crowsnest"

APP="build/Crowsnest.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Crowsnest"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Copy SwiftPM resource bundles, if any.
find "$(dirname "$BIN")" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --deep --sign - "$APP"
echo "Built: $APP"
