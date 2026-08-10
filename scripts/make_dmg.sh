#!/bin/bash
# Builds MIKE in Release and wraps it in a distributable disk image.
#
# The exact create-dmg invocation lives here rather than in someone's shell
# history: the icon coordinates below are tuned to the background image, so a
# rebuild from memory would silently misplace them.
#
# Needs: xcodegen (only after project.yml changes), create-dmg (brew install create-dmg)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/.build-release"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Building Release"
rm -rf "$BUILD_DIR"
xcodebuild -project MIKE.xcodeproj -scheme MIKE -configuration Release \
  -derivedDataPath "$BUILD_DIR" build >/dev/null

APP="$BUILD_DIR/Build/Products/Release/MIKE.app"
[ -d "$APP" ] || { echo "Build produced no app bundle"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCH=$(lipo -archs "$APP/Contents/MacOS/MIKE")
DMG="$ROOT/MIKE-$VERSION-$ARCH.dmg"

# The bundled JavaScript is a resource, not source — if it ever lands in
# Compile Sources instead, the build still succeeds and Extract Article fails
# at runtime, so the packaged bundle is checked rather than assumed.
for res in Readability.js Extraction.js LICENSE; do
  [ -e "$APP/Contents/Resources/$res" ] || { echo "Missing resource: $res"; exit 1; }
done

echo "==> Regenerating the DMG background"
python3 "$ROOT/scripts/make_dmg_background.py" >/dev/null

echo "==> Packaging $DMG"
rm -f "$DMG"
cp -R "$APP" "$STAGE/"

# Icon y positions keep the 160pt icons and their labels above the painted
# horizon; --window-size matches the background's pixel size. See
# make_dmg_background.py for why the lower part of that image is bleed.
create-dmg \
  --volname "MIKE $VERSION" \
  --background "$ROOT/scripts/dmg_background.png" \
  --window-pos 200 120 \
  --window-size 660 430 \
  --icon-size 160 \
  --icon "MIKE.app" 175 165 \
  --hide-extension "MIKE.app" \
  --app-drop-link 485 165 \
  --no-internet-enable \
  "$DMG" "$STAGE" >/dev/null

echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    Ad-hoc signed and not notarized, so Gatekeeper will refuse it on"
echo "    first launch — the README's 'Open Anyway' step covers that."
