#!/usr/bin/env bash
# Builds Meshvy.app. No Xcode required — SwiftPM compiles the binary and the
# bundle is assembled here, then signed.
#
# Signing: set MACOS_SIGN_IDENTITY to a "Developer ID Application: ..." identity
# to produce a distributable build. Without it the app is ad-hoc signed, which
# runs fine locally but is blocked by Gatekeeper when downloaded.
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Meshvy.app"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"

cd "$ROOT"

# A released app has to run on Intel Macs too. SwiftPM's own `--arch a --arch b`
# needs Xcode's xcbuild, which the Command Line Tools do not ship, so each slice
# is cross-compiled separately and lipo'd together. Set UNIVERSAL=0 for a
# faster native-only build while developing.
if [ "${UNIVERSAL:-1}" = "1" ]; then
  echo "==> swift build -c $CONFIG (arm64 + x86_64)"
  swift build -c "$CONFIG" --triple arm64-apple-macosx14.0
  swift build -c "$CONFIG" --triple x86_64-apple-macosx14.0
  BIN="$ROOT/.build/Meshvy-universal"
  lipo -create \
    "$ROOT/.build/arm64-apple-macosx/$CONFIG/Meshvy" \
    "$ROOT/.build/x86_64-apple-macosx/$CONFIG/Meshvy" \
    -output "$BIN"
  lipo -archs "$BIN"
else
  echo "==> swift build -c $CONFIG (native only)"
  swift build -c "$CONFIG"
  BIN="$(swift build -c "$CONFIG" --show-bin-path)/Meshvy"
fi

echo "==> assembling $APP ($VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Meshvy"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-$VERSION}" "$APP/Contents/Info.plist" >/dev/null

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "==> signing with $MACOS_SIGN_IDENTITY"
  # The hardened runtime is required for notarisation.
  codesign --force --deep --options runtime --timestamp \
           --sign "$MACOS_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "==> ad-hoc signing (no MACOS_SIGN_IDENTITY set)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    (ad-hoc signing skipped)"
fi

echo "==> done: $APP"
