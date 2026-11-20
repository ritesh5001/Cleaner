#!/usr/bin/env bash
# Builds "Storage Fusion.app" and packages it as a drag-to-install disk image in ./dist.
#
#   ./scripts/make-dmg.sh
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/make-dmg.sh   # for sharing
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="dist/Storage-Fusion-${VERSION}.dmg"
STAGE="$(mktemp -d)/Storage Fusion"

# 1. Release build of the .app
./scripts/build-app.sh release

# 2. Stage: the app + a shortcut to /Applications for drag-and-drop install
mkdir -p "$STAGE" dist
cp -R "build/Storage Fusion.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 3. Compressed, read-only disk image
rm -f "$DMG"
hdiutil create -volname "Storage Fusion" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [ "${SIGN_ID:--}" != "-" ]; then codesign --force --sign "$SIGN_ID" "$DMG"; fi
rm -rf "$(dirname "$STAGE")"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
