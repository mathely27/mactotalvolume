#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build -c release

APP=".build/Mactotalvolume.app"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/VolumeMixer" "$APP/Contents/MacOS/VolumeMixer"
cp "Info.plist" "$APP/Contents/Info.plist"

echo "Built $APP"
open "$APP"
