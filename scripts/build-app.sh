#!/usr/bin/env bash
# Builds "Image Canvas.app", ad-hoc signs it, installs it to ~/Applications and
# registers it with LaunchServices so Finder offers it as an opener for images.
#
#   scripts/build-app.sh            build + install
#   scripts/build-app.sh --no-install   build only (output in build/)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="Image Canvas"
APP="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Building release binary"
swift build -c release --product ImageCanvas
BIN="$(swift build -c release --show-bin-path)/ImageCanvas"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ImageCanvas"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Built: $APP"
  exit 0
fi

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
# Quit a running copy so the new binary is picked up.
osascript -e "tell application id \"com.dan.ImageCanvas\" to quit" >/dev/null 2>&1 || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
# Nudge Finder and the Dock to pick up a changed icon.
touch "$INSTALL_DIR/$APP_NAME.app"

echo "==> Registering with LaunchServices"
"$LSREGISTER" -f "$INSTALL_DIR/$APP_NAME.app"

echo
echo "Installed: $INSTALL_DIR/$APP_NAME.app"
echo "Make it the default: launch it and accept the prompt, or use"
echo "  Image Canvas menu > Make Default Viewer…"
