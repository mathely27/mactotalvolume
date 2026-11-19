#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

VERSION="0.1.0"
BUILD_ROOT=".build/dmg-build"
ARM_SCRATCH="$BUILD_ROOT/arm64"
INTEL_SCRATCH="$BUILD_ROOT/x86_64"
STAGE="$BUILD_ROOT/stage"
APP="$STAGE/Mactotalvolume.app"
DIST="dist"
DMG="$DIST/Mactotalvolume-$VERSION-universal.dmg"

mkdir -p "$BUILD_ROOT" "$DIST"

swift build -c release --triple arm64-apple-macosx14.2 \
    --scratch-path "$ARM_SCRATCH" --disable-sandbox
ARM_BIN=$(swift build --show-bin-path -c release --triple arm64-apple-macosx14.2 \
    --scratch-path "$ARM_SCRATCH" --disable-sandbox)

swift build -c release --triple x86_64-apple-macosx14.2 \
    --scratch-path "$INTEL_SCRATCH" --disable-sandbox
INTEL_BIN=$(swift build --show-bin-path -c release --triple x86_64-apple-macosx14.2 \
    --scratch-path "$INTEL_SCRATCH" --disable-sandbox)

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS"
lipo -create "$ARM_BIN/VolumeMixer" "$INTEL_BIN/VolumeMixer" \
    -output "$APP/Contents/MacOS/VolumeMixer"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
ln -s /Applications "$STAGE/Applications"

hdiutil create -ov -volname "Mactotalvolume" -srcfolder "$STAGE" \
    -format UDZO "$DMG"

echo "Created $DMG"
