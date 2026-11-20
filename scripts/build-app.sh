#!/usr/bin/env bash
# Builds Cleaner.app into ./build using only the Xcode Command Line Tools.
#
#   ./scripts/build-app.sh            # release build, ad-hoc signed
#   ./scripts/build-app.sh debug      # debug build
#   SIGN_ID="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh
#
# Tip: with ad-hoc signing macOS treats every rebuild as a new app, so Full Disk Access
# and Keychain "Always Allow" must be re-granted. Signing with a real identity avoids that.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
SIGN_ID="${SIGN_ID:--}"
APP="build/Cleaner.app"
# Keep build intermediates outside cloud-synced folders: Google Drive/iCloud grabbing the
# SQLite build database mid-write causes "accessing build database … disk I/O error".
SCRATCH="${SCRATCH:-$HOME/Library/Caches/cleaner-build}"

swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Cleaner" "$APP/Contents/MacOS/Cleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true

codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"
echo "✓ Built $APP (signed with: $SIGN_ID)"
echo "  Run it:  open $APP"
