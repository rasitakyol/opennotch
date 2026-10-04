#!/usr/bin/env bash
# Builds OpenNotch.app into ./build (release by default; pass "debug" for a debug build).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
APP="build/OpenNotch.app"
SIGNING_IDENTITY="${OPENNOTCH_SIGNING_IDENTITY:--}"

swift build -c "$CONFIGURATION" --product OpenNotch
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Logos"
cp "$BIN_DIR/OpenNotch" "$APP/Contents/MacOS/OpenNotch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Logos/*.svg "$APP/Contents/Resources/Logos/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A persistent signing identity can keep Keychain trust across builds. The default ad-hoc signature's
# designated requirement includes the binary hash, so a changed build can need authorization again.
# Quiet on success, where codesign only notes that it replaced the linker's ad-hoc signature.
if ! SIGN_OUTPUT="$(codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP" 2>&1)"; then
    echo "$SIGN_OUTPUT" >&2
    exit 1
fi

echo "✓ $APP"
