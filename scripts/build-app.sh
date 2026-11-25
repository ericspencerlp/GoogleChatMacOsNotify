#!/usr/bin/env bash
# Builds "Google Chat Notifier.app" from the Swift package.
#
#   ./scripts/build-app.sh              # build into ./build/
#   ./scripts/build-app.sh --install    # build, copy to /Applications, and launch
#
# Optional: SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" to sign with a real
# certificate. Default is ad-hoc signing ("-"), which is fine for running on your own Mac.
set -euo pipefail

APP_NAME="Google Chat Notifier"
EXECUTABLE="GoogleChatNotifier"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: 'swift' not found. Install the Command Line Tools: xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Bundle copies of the built-in macOS alert sounds (played by the app via NSSound).
for sound in /System/Library/Sounds/*.aiff; do
  [ -e "$sound" ] && cp "$sound" "$APP/Contents/Resources/"
done

# App icon (shown in notifications and System Settings).
if [ -f "$ROOT/Resources/AppIcon.png" ]; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "==> Signing (identity: $SIGN_IDENTITY)…"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "==> Built: $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST…"
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "==> Launched. Look for the chat bubble icon in the menu bar."
fi
