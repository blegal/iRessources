#!/bin/sh
# Builds a release iRessources.app bundle in ./build.
# Usage: scripts/build-app.sh [--universal]
# Optional environment: VERSION and BUILD_NUMBER override those of Support/Info.plist,
# SIGN_IDENTITY replaces the ad-hoc signature.
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
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
strip -x "$APP/Contents/MacOS/iRessources"

# The icon is drawn by the app itself (AppIcon.swift), so it has a single source.
ICONSET=$(mktemp -d)/AppIcon.iconset
"$APP/Contents/MacOS/iRessources" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signature by default, so the app launches locally; set SIGN_IDENTITY to use a certificate.
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP"

echo "Built $APP"
