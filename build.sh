#!/usr/bin/env bash
set -euo pipefail

mkdir -p HomeRow.app/Contents/MacOS HomeRow.app/Contents/Resources
cp Info.plist HomeRow.app/Contents/Info.plist
cp Resources/AppIcon.icns HomeRow.app/Contents/Resources/AppIcon.icns
swiftc -O -target arm64-apple-macosx26.0 -parse-as-library \
  Sources/HomeRowEngine.swift \
  Sources/HomeRowApp.swift \
  -o HomeRow.app/Contents/MacOS/HomeRow \
  -framework Cocoa -framework SwiftUI -framework ApplicationServices -framework ServiceManagement
codesign --force --deep --sign - HomeRow.app
echo "Built HomeRow.app"
