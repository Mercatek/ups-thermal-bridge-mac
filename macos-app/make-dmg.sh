#!/bin/bash
# Build the app and package it as a drag-to-install DMG.
#   ./make-dmg.sh [version]
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP="build/UPS Print Bridge.app"
VOL="UPS Print Bridge"
DMG="build/UPS-Print-Bridge-$VERSION.dmg"
STAGE="build/dmg-stage"

./build-app.sh

echo "==> Staging DMG contents…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # drag-to-install target

echo "==> Creating DMG…"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo "==> Built $DMG ($SIZE)"
