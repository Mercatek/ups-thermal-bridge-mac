#!/bin/bash
#
# UPS Print Bridge — uninstaller
#
set -e
LABEL="com.ups-print-bridge"

echo "==> Stopping and removing the LaunchAgent..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Removing the runtime..."
rm -rf "$HOME/Library/Application Support/UPSPrintBridge"

echo "==> Done. Port 4349 is free."
echo "    Logs were left in place: $HOME/Library/Logs/ups-print-bridge*.log"
echo "    Remember to also remove the Tampermonkey userscript in your browser."
