#!/bin/sh
# Packs build/iRessources.app into a compressed disk image, build/iRessources-<version>.dmg,
# with a link to /Applications for drag-and-drop installation. Prints the image path.
# Usage: scripts/build-app.sh && scripts/make-dmg.sh
set -eu

cd "$(dirname "$0")/.."

APP=build/iRessources.app
[ -d "$APP" ] || { echo "Run scripts/build-app.sh first" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/iRessources-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/iRessources.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname iRessources -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$DMG"
echo "$DMG"
