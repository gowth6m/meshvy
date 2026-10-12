#!/usr/bin/env bash
# Produces the downloadable artifacts: a DMG, a zip, and their checksums.
#
# Notarisation runs only when Apple credentials are present. Set either
#   NOTARY_PROFILE                       (a `notarytool store-credentials` profile)
# or
#   NOTARY_KEY_PATH / NOTARY_KEY_ID / NOTARY_ISSUER   (App Store Connect API key)
# Without them the artifacts are usable but Gatekeeper will warn on first open.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
APP="$DIST/Meshvy.app"
DMG="$DIST/Meshvy-$VERSION.dmg"
ZIP="$DIST/Meshvy-$VERSION-macOS.zip"

"$ROOT/scripts/build-app.sh"

# Stapling that checks it actually took.
#
# `stapler staple` reported success on a release where the ticket was then not
# there two steps later — never reproduced, and Gatekeeper accepted the app
# anyway because it can look the ticket up online. But a stapled ticket is the
# whole point of stapling: it is what makes the app open on a machine that is
# offline or behind a filter. Both the staple and the ticket fetch are
# idempotent and cost nothing, so a ticket that has not landed is worth
# retrying rather than failing a release over.
staple() {
  local target="$1" attempt
  for attempt in 1 2 3; do
    xcrun stapler staple "$target" || true
    if xcrun stapler validate "$target" >/dev/null 2>&1; then
      return 0
    fi
    echo "    ticket did not land on $(basename "$target") (attempt $attempt); retrying"
    sleep 5
  done
  echo "    could not staple $(basename "$target")" >&2
  return 1
}

notarize() {
  local target="$1"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    xcrun notarytool submit "$target" \
      --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  else
    return 1
  fi
}

echo "==> building $DMG"
STAGE="$(mktemp -d)/Meshvy"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Meshvy $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"

echo "==> building $ZIP"
rm -f "$ZIP"
# ditto preserves the bundle's symlinks and signature; `zip` does not.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# The app inside is signed, but the disk image is its own container and
# Gatekeeper judges it separately. An unsigned one can still be stapled, but a
# signed one is what Apple asks for and costs nothing here.
if [ -n "${MACOS_SIGN_IDENTITY:-}" ]; then
  echo "==> signing $DMG"
  codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG"
fi

if notarize "$DMG"; then
  echo "==> stapling"
  staple "$DMG"
  # The zip has to be notarised separately — stapling a zip is not supported,
  # so staple the app and re-zip it.
  #
  # Deliberately not `|| true`: a half-notarised release is worse than a failed
  # one, because the release notes would then tell people it is signed while
  # macOS refuses to open it.
  notarize "$ZIP"
  staple "$APP"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
else
  echo "==> not notarised (no Apple credentials); Gatekeeper will warn on download"
fi

echo "==> checksums"
cd "$DIST"
shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" | tee "Meshvy-$VERSION-SHA256.txt"

echo
echo "artifacts:"
ls -lh "$DMG" "$ZIP" "$DIST/Meshvy-$VERSION-SHA256.txt"

# What Apple will make of it, said out loud rather than discovered by a user.
"$ROOT/scripts/verify-release.sh" "$APP" "$DMG" || true
