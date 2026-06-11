#!/bin/bash
# Build the Phase-1 headless engine (no UI) to validate it against ups.com.
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 \
  Sources/Bridge.swift Sources/HTTPServer.swift Sources/Handshake.swift \
  cli/main.swift \
  -o build/ups-bridge-cli
echo "Built build/ups-bridge-cli"
