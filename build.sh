#!/usr/bin/env bash
set -euo pipefail

mkdir -p HomeRow.app/Contents/MacOS
cp Info.plist HomeRow.app/Contents/Info.plist
swiftc -O -parse-as-library \
  Sources/HomeRowEngine.swift \
  Sources/HomeRowApp.swift \
  -o HomeRow.app/Contents/MacOS/HomeRow \
  -framework Cocoa -framework SwiftUI -framework ApplicationServices
codesign --force --deep --sign - HomeRow.app
echo "Built HomeRow.app"
