#!/usr/bin/env bash
# Builds Resources/AppIcon.icns from the brand artwork.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Resources/brand/app-icon.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" \
            "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" \
            "1024 icon_512x512@2x.png"; do
  set -- $spec
  swift "$ROOT/scripts/make-icon.swift" "$SOURCE" "$1" "$SET/$2"
done

iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
