#!/bin/bash
# Build "UPS Print Bridge.app" — a menu-bar app with a setup wizard.
set -e
cd "$(dirname "$0")"

APP="build/UPS Print Bridge.app"
EXE="UPSPrintBridge"
BUNDLE_ID="com.mercatek.upsprintbridge"
VERSION="1.0"

echo "==> Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 \
  Sources/Bridge.swift Sources/HTTPServer.swift Sources/Handshake.swift \
  app/App.swift app/Views.swift \
  -o "$APP/Contents/MacOS/$EXE"

echo "==> Writing Info.plist…"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>UPS Print Bridge</string>
    <key>CFBundleDisplayName</key><string>UPS Print Bridge</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXE</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> Code signing (ad-hoc)…"
codesign --force --deep -s - "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> Built: $APP"
echo "    Run:  open \"$APP\"    (first time: right-click → Open to bypass Gatekeeper)"
