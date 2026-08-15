#!/bin/bash
# Builds spatial-cable.app in Release configuration and drops it in ./build.
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="spatial-cable"
CONFIGURATION="Release"
BUILD_DIR="$(pwd)/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"

echo "==> Building $SCHEME ($CONFIGURATION)…"
# Ad-hoc sign instead of relying on the project's Automatic signing / Apple
# Development certificate (which may be expired, missing, or tied to a team
# you're not logged into) — fine for local use since the app is unsandboxed
# and requests no special entitlements.
xcodebuild \
  -project spatial-cable.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/spatial-cable.app"

if [ ! -d "$APP_PATH" ]; then
  echo "Build succeeded but couldn't find app at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/spatial-cable.app"
cp -R "$APP_PATH" "$BUILD_DIR/spatial-cable.app"

echo "==> Done: $BUILD_DIR/spatial-cable.app"

echo "==> Building install DMG…"
DMG_PATH="$BUILD_DIR/spatial-cable.dmg"
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$BUILD_DIR/spatial-cable.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "spatial-cable" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING_DIR"

echo "==> Opening ${DMG_PATH}…"
open "$DMG_PATH"
