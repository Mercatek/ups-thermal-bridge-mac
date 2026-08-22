#!/bin/bash
#
# UPS Print Bridge — installer for macOS
#
# Installs the local print service as a LaunchAgent so it starts on login.
#
# Usage:
#   ./install.sh                      # uses default printer "Bixolon_SRP770III"
#   ./install.sh "My_Printer_Queue"   # uses the given CUPS queue name
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.ups-print-bridge"
APP_DIR="$HOME/Library/Application Support/UPSPrintBridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PRINTER="${1:-${UPS_BRIDGE_PRINTER:-Brother_QL_1110NWB}}"
MEDIA="${UPS_BRIDGE_MEDIA:-103x164mm}"
LABEL_WIDTH_MM="${UPS_BRIDGE_LABEL_WIDTH_MM:-103}"
LABEL_HEIGHT_MM="${UPS_BRIDGE_LABEL_HEIGHT_MM:-164}"
LABEL_DPMM="${UPS_BRIDGE_LABEL_DPMM:-8}"

echo "==> UPS Print Bridge installer (Brother/labelize fork)"

# 1) Requirements
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found. Install the Xcode Command Line Tools:  xcode-select --install"
  exit 1
fi
echo "    python3:  $(python3 --version)"

LABELIZE_BIN="$(command -v labelize || true)"
if [ -z "$LABELIZE_BIN" ]; then
  echo "ERROR: labelize not found. Install it first:"
  echo "    brew tap GOODBOY008/homebrew-labelize && brew install labelize"
  exit 1
fi
echo "    labelize: $LABELIZE_BIN ($($LABELIZE_BIN --version))"

# 2) Check the CUPS printer exists
if ! lpstat -p "$PRINTER" >/dev/null 2>&1; then
  echo "WARNING: CUPS printer '$PRINTER' not found. Available printers:"
  lpstat -p 2>/dev/null | sed 's/^/      /' || echo "      (none)"
  echo "    Re-run with:  ./install.sh \"<your_printer_queue_name>\""
  echo "    (continuing anyway — you can change it later in the plist)"
else
  echo "    printer:  $PRINTER (found)"
fi

# 3) Copy the runtime out of any TCC-protected folder (Documents/Desktop/etc.)
mkdir -p "$APP_DIR"
cp "$SCRIPT_DIR/ups_print_bridge.py" "$APP_DIR/ups_print_bridge.py"
echo "    runtime:  $APP_DIR/ups_print_bridge.py"

# 4) Write the LaunchAgent
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$APP_DIR/ups_print_bridge.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>UPS_BRIDGE_PRINTER</key>
        <string>$PRINTER</string>
        <key>UPS_BRIDGE_PORT</key>
        <string>4349</string>
        <key>UPS_BRIDGE_HOST</key>
        <string>127.0.0.1</string>
        <key>UPS_BRIDGE_LABELIZE_BIN</key>
        <string>$LABELIZE_BIN</string>
        <key>UPS_BRIDGE_MEDIA</key>
        <string>$MEDIA</string>
        <key>UPS_BRIDGE_LABEL_WIDTH_MM</key>
        <string>$LABEL_WIDTH_MM</string>
        <key>UPS_BRIDGE_LABEL_HEIGHT_MM</key>
        <string>$LABEL_HEIGHT_MM</string>
        <key>UPS_BRIDGE_LABEL_DPMM</key>
        <string>$LABEL_DPMM</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/ups-print-bridge.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/ups-print-bridge.err.log</string>
</dict>
</plist>
PLISTEOF
echo "    agent:    $PLIST"

# 5) (Re)load it
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
sleep 0.5
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
sleep 1.5

# 6) Smoke test
if curl -s "http://127.0.0.1:4349/listPrinters?app=www" -H "Origin: https://www.ups.com" \
     -H "Accept: application/json" -H "Sec-Fetch-Dest: empty" | grep -q "$PRINTER"; then
  echo "==> Service is running on http://127.0.0.1:4349  (printer: $PRINTER)"
else
  echo "==> Service did not respond. Check: $HOME/Library/Logs/ups-print-bridge.err.log"
fi

echo ""
echo "Next: install the Tampermonkey userscript (userscript/ups-thermal-bridge.user.js)."
echo "See the README for details."
