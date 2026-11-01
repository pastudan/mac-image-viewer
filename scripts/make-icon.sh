#!/usr/bin/env bash
# Regenerates Resources/AppIcon.png and Resources/AppIcon.icns from scripts/make-icon.swift.
# scripts/build-app.sh copies the .icns into the app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift scripts/make-icon.swift Resources/AppIcon.png

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "wrote Resources/AppIcon.icns"
