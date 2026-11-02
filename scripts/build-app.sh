#!/bin/sh
# Builds a release iRessources.app bundle in ./build.
# Usage: scripts/build-app.sh [--universal]
set -eu

cd "$(dirname "$0")/.."

ARCH_FLAGS=""
if [ "${1:-}" = "--universal" ]; then
    ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
BIN_DIR=$(swift build -c release $ARCH_FLAGS --show-bin-path)

APP=build/iRessources.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/iRessources" "$APP/Contents/MacOS/iRessources"
cp Support/Info.plist "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/iRessources"

# The icon is drawn by the app itself (AppIcon.swift), so it has a single source.
ICONSET=$(mktemp -d)/AppIcon.iconset
"$APP/Contents/MacOS/iRessources" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signature so the app launches locally; use your Developer ID to distribute it.
codesign --force --sign - --options runtime "$APP"

echo "Built $APP"
