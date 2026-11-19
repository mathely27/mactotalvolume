#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
APP=".build/Mactotalvolume.app"
swift build -c release --disable-sandbox

# Close any previous copy first so rebuilding never leaves two menu bar icons.
killall VolumeMixer 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/VolumeMixer" "$APP/Contents/MacOS/VolumeMixer"
cp "Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
open -n "$APP"
