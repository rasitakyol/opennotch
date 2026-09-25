#!/usr/bin/env bash
# Builds OpenNotch.app into ./build (release by default; pass "debug" for a debug build).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
APP="build/OpenNotch.app"

swift build -c "$CONFIGURATION" --product OpenNotch
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Logos"
cp "$BIN_DIR/OpenNotch" "$APP/Contents/MacOS/OpenNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Logos/*.svg "$APP/Contents/Resources/Logos/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS treats the bundle as one app (login item, stable identity).
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "✓ $APP"
