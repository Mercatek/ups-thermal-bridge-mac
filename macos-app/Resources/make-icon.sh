#!/bin/bash
# Generate AppIcon.icns (all sizes) from gen-icon.swift.
set -e
cd "$(dirname "$0")"

swift gen-icon.swift master.png
ICONSET="AppIcon.iconset"
rm -rf "$ICONSET"; mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s master.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d master.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$ICONSET" master.png
echo "wrote Resources/AppIcon.icns"
