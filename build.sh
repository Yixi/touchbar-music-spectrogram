#!/usr/bin/env bash
#
# build.sh — Build TouchBarSpectrum.app WITHOUT full Xcode (Command Line Tools only).
#
# Compiles every Swift source with the Objective-C bridging header, assembles a
# proper .app bundle, resolves the Info.plist build variables, and ad-hoc signs
# the bundle with the (sandbox-off) entitlements. Produces ./TouchBarSpectrum.app
# which you can launch with `open TouchBarSpectrum.app`.
#
# If you have full Xcode, prefer opening TouchBarSpectrum.xcodeproj and hitting Run.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="TouchBarSpectrum"
BUNDLE_ID="com.yixi.TouchBarSpectrum"
VERSION="1.0"
BUILD="1"
MIN_OS="15.0"
ARCH="$(uname -m)"                 # x86_64 on the Intel target
APP="${APP_NAME}.app"
BRIDGING="TouchBarSpectrum/Support/TouchBarSpectrum-Bridging-Header.h"
ENTITLEMENTS="TouchBarSpectrum/TouchBarSpectrum.entitlements"

SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "▸ Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compiling ($ARCH, macOS $MIN_OS, Swift 5)"
# shellcheck disable=SC2046
swiftc -O \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${MIN_OS}" \
  -swift-version 5 \
  -import-objc-header "$BRIDGING" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  $(find TouchBarSpectrum -name '*.swift' | sort)

echo "▸ Writing Info.plist"
sed -e "s|\$(EXECUTABLE_NAME)|$APP_NAME|g" \
    -e "s|\$(PRODUCT_NAME)|$APP_NAME|g" \
    -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$BUNDLE_ID|g" \
    -e "s|\$(MARKETING_VERSION)|$VERSION|g" \
    -e "s|\$(CURRENT_PROJECT_VERSION)|$BUILD|g" \
    -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|$MIN_OS|g" \
    TouchBarSpectrum/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Ad-hoc signing with entitlements (sandbox off)"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --verbose=2 "$APP"

echo "✓ Built $APP"
echo "  Run with:  open $APP        (or ./$APP/Contents/MacOS/$APP_NAME for console logs)"
