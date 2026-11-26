#!/usr/bin/env bash
set -euo pipefail

OS="$(uname -s)"
if [[ "$OS" == "Linux" ]]; then
  if command -v blueprint-compiler >/dev/null 2>&1; then
    blueprint-compiler compile linux/window.blp --output linux/window.ui
  else
    mod_dir="$(compgen -G "/var/lib/flatpak/runtime/org.gnome.Platform/*/active/files/lib/python*/site-packages" | head -n1 || true)"
    if [[ -n "$mod_dir" && -d "$mod_dir/blueprintcompiler" ]]; then
      PYTHONPATH="$mod_dir" /usr/bin/python3 -c \
        'from blueprintcompiler import main; main.main("0.20.4", "/usr/lib64", "/usr/share")' \
        compile linux/window.blp --output linux/window.ui
    fi
  fi
  gcc -O2 -Wall -Wextra linux/homerow-daemon.c -o linux/homerow-daemon
  gcc -shared -fPIC -O2 -Wall -Wextra linux/wingpanel-indicator.c -o linux/libhomerow.so \
    /usr/lib64/libwingpanel-9.so.8 \
    /usr/lib64/libgtk-4.so.1 \
    /usr/lib64/libgio-2.0.so.0 \
    /usr/lib64/libgobject-2.0.so.0 \
    /usr/lib64/libglib-2.0.so.0
  echo "Built linux/homerow-daemon and linux/libhomerow.so (run ./linux/install.sh to install app & service)"
  exit 0
fi

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
