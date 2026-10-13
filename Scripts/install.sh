#!/usr/bin/env bash
# Installs the latest Meshvy release into /Applications.
#
#   ./Scripts/install.sh              latest release
#   ./Scripts/install.sh 0.8.0        a specific version
#   PREFIX=~/Applications ./Scripts/install.sh
#
# The repository is public, so the release is fetched with curl and no sign-in
# is needed. If it is ever made private again, the `gh` CLI you are already
# signed in to is used instead.
set -euo pipefail

REPO="gowth6m/meshvy"
PREFIX="${PREFIX:-/Applications}"
APP="$PREFIX/Meshvy.app"
WANTED="${1:-}"

say() { printf '==> %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Meshvy is a macOS app."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  say "fetching release with gh"
  if [ -n "$WANTED" ]; then
    gh release download "v$WANTED" --repo "$REPO" --dir "$WORK" \
      --pattern '*-macOS.zip' --pattern '*SHA256.txt' >/dev/null
  else
    gh release download --repo "$REPO" --dir "$WORK" \
      --pattern '*-macOS.zip' --pattern '*SHA256.txt' >/dev/null
  fi
else
  say "fetching release with curl"
  TAG="${WANTED:+v$WANTED}"
  if [ -z "$TAG" ]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$TAG" ] || die "could not find a release. The repository may be private — install the gh CLI and run 'gh auth login'."
  BASE="https://github.com/$REPO/releases/download/$TAG"
  VERSION="${TAG#v}"
  curl -fsSL -o "$WORK/Meshvy-$VERSION-macOS.zip" "$BASE/Meshvy-$VERSION-macOS.zip" \
    || die "could not download the release. If the repository is private, install the gh CLI and run 'gh auth login'."
  curl -fsSL -o "$WORK/Meshvy-$VERSION-SHA256.txt" "$BASE/Meshvy-$VERSION-SHA256.txt" || true
fi

ZIP="$(find "$WORK" -name '*-macOS.zip' | head -1)"
[ -n "$ZIP" ] || die "the release has no .zip to install."

SUMS="$(find "$WORK" -name '*SHA256.txt' | head -1)"
if [ -n "$SUMS" ]; then
  EXPECTED="$(grep 'macOS.zip' "$SUMS" | awk '{print $1}' | head -1)"
  ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  [ "$EXPECTED" = "$ACTUAL" ] || die "the download did not match its published checksum."
  say "checksum ok"
fi

say "unpacking"
/usr/bin/ditto -x -k "$ZIP" "$WORK/app"
STAGED="$(find "$WORK/app" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$STAGED" ] || die "the archive did not contain an app."

# Refuse to install anything that is not recognisably Meshvy.
ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED/Contents/Info.plist" 2>/dev/null || true)"
[ "$ID" = "dev.gowtham.meshvy" ] || die "that is not Meshvy."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED/Contents/Info.plist")"

if pgrep -f "Meshvy.app/Contents/MacOS/Meshvy" >/dev/null 2>&1; then
  say "quitting the running copy"
  osascript -e 'quit app "Meshvy"' >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    pgrep -f "Meshvy.app/Contents/MacOS/Meshvy" >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

mkdir -p "$PREFIX"
if [ -d "$APP" ]; then
  say "replacing $APP"
  rm -rf "$APP.meshvy-previous"
  mv "$APP" "$APP.meshvy-previous"
fi
if ! mv "$STAGED" "$APP"; then
  [ -d "$APP.meshvy-previous" ] && mv "$APP.meshvy-previous" "$APP"
  die "could not write to $PREFIX. Try: PREFIX=~/Applications $0"
fi
rm -rf "$APP.meshvy-previous"

# Releases are notarised, so this is belt and braces — but it costs nothing and
# covers anyone installing an older build, which was not.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "installed Meshvy $VERSION to $APP"
say "open it with:  open -a Meshvy"
