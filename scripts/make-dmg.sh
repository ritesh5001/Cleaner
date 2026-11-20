#!/usr/bin/env bash
# Builds Cleaner.app and packages it as a drag-to-install disk image in ./dist.
#
#   ./scripts/make-dmg.sh
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/make-dmg.sh   # for sharing
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="dist/Cleaner-${VERSION}.dmg"
STAGE="$(mktemp -d)/Cleaner"

# 1. App icon (regenerated if missing)
if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET=$(swift scripts/make-icon.swift Resources | tail -1)
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$ICONSET"
fi

# 2. Release build of the .app
./scripts/build-app.sh release

# 3. Stage: the app + a shortcut to /Applications for drag-and-drop install
mkdir -p "$STAGE" dist
cp -R build/Cleaner.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 4. Compressed, read-only disk image
rm -f "$DMG"
hdiutil create -volname "Cleaner" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [ "${SIGN_ID:--}" != "-" ]; then codesign --force --sign "$SIGN_ID" "$DMG"; fi
rm -rf "$(dirname "$STAGE")"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
