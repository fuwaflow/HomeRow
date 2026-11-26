#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--system-install" ]]; then
  TARGET_USER="${2:-${SUDO_USER:-}}"
  [[ -n "$TARGET_USER" ]] || { echo "Usage: $0 --system-install <user> [config] [daemon] [panel_so]" >&2; exit 1; }
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  CONFIG_PATH="${3:-$USER_HOME/.config/homerow/config.json}"
  DAEMON_SRC="${4:-$USER_HOME/.local/bin/homerow-daemon}"
  PANEL_SRC="${5:-$USER_HOME/.local/share/homerow/libhomerow.so}"

  install -Dm755 "$DAEMON_SRC" /usr/local/bin/homerow-daemon

  if [[ -f "$PANEL_SRC" && -d /usr/lib64/wingpanel-9 ]]; then
    install -Dm755 "$PANEL_SRC" /usr/local/lib64/wingpanel-9/libhomerow.so
    if [[ -w /usr/lib64/wingpanel-9 ]]; then
      install -Dm755 "$PANEL_SRC" /usr/lib64/wingpanel-9/libhomerow.so
    else
      mkdir -p /var/lib/homerow/wingpanel-upper /var/lib/homerow/wingpanel-work
      install -Dm755 "$PANEL_SRC" /var/lib/homerow/wingpanel-upper/libhomerow.so
      grep -q " /usr/lib64/wingpanel-9 overlay " /proc/mounts || \
        mount -t overlay overlay -o lowerdir=/usr/lib64/wingpanel-9,upperdir=/var/lib/homerow/wingpanel-upper,workdir=/var/lib/homerow/wingpanel-work /usr/lib64/wingpanel-9 || true
      cat >/etc/systemd/system/homerow-wingpanel.service <<'EOF'
[Unit]
Description=Mount HomeRow Wingpanel Indicator Overlay
After=local-fs.target
Before=display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash -c 'mkdir -p /var/lib/homerow/wingpanel-upper /var/lib/homerow/wingpanel-work && grep -q " /usr/lib64/wingpanel-9 overlay " /proc/mounts || mount -t overlay overlay -o lowerdir=/usr/lib64/wingpanel-9,upperdir=/var/lib/homerow/wingpanel-upper,workdir=/var/lib/homerow/wingpanel-work /usr/lib64/wingpanel-9'

[Install]
WantedBy=multi-user.target
EOF
      systemctl enable homerow-wingpanel.service
    fi
  fi

  mkdir -p /etc/libinput
  if [[ ! -f /etc/libinput/local-overrides.quirks ]] || ! grep -q '^\[HomeRow Internal Keyboard\]' /etc/libinput/local-overrides.quirks; then
    printf '\n[HomeRow Internal Keyboard]\nMatchUdevType=keyboard\nMatchName=*HomeRow*\nAttrKeyboardIntegration=internal\n' >>/etc/libinput/local-overrides.quirks
  fi

  cat >/etc/systemd/system/homerow.service <<EOF
[Unit]
Description=HomeRow Linux Keyboard Remapper
After=local-fs.target systemd-udevd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/homerow-daemon --config ${CONFIG_PATH}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable homerow.service
  systemctl restart homerow.service
  exit 0
fi

MODE="${1:-interactive}"
if command -v blueprint-compiler >/dev/null 2>&1; then
  blueprint-compiler compile "$SCRIPT_DIR/window.blp" --output "$SCRIPT_DIR/window.ui"
else
  mod_dir="$(compgen -G "/var/lib/flatpak/runtime/org.gnome.Platform/*/active/files/lib/python*/site-packages" | head -n1 || true)"
  if [[ -n "$mod_dir" && -d "$mod_dir/blueprintcompiler" ]]; then
    PYTHONPATH="$mod_dir" /usr/bin/python3 -c 'from blueprintcompiler import main; main.main("0.20.4", "/usr/lib64", "/usr/share")' \
      compile "$SCRIPT_DIR/window.blp" --output "$SCRIPT_DIR/window.ui"
  fi
fi

gcc -O2 -Wall -Wextra "$SCRIPT_DIR/homerow-daemon.c" -o "$SCRIPT_DIR/homerow-daemon"
gcc -shared -fPIC -O2 -Wall -Wextra "$SCRIPT_DIR/wingpanel-indicator.c" -o "$SCRIPT_DIR/libhomerow.so" \
  /usr/lib64/libwingpanel-9.so.8 /usr/lib64/libgtk-4.so.1 /usr/lib64/libgio-2.0.so.0 /usr/lib64/libgobject-2.0.so.0 /usr/lib64/libglib-2.0.so.0

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/homerow" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/scalable/apps" "$HOME/.config/homerow"
install -m755 "$SCRIPT_DIR/homerow-daemon" "$HOME/.local/bin/homerow-daemon"
install -m755 "$SCRIPT_DIR/libhomerow.so" "$HOME/.local/share/homerow/libhomerow.so"
install -m755 "$SCRIPT_DIR/homerow-app.py" "$HOME/.local/share/homerow/homerow-app.py"
install -m644 "$SCRIPT_DIR/window.blp" "$HOME/.local/share/homerow/window.blp"
[[ -f "$SCRIPT_DIR/window.ui" ]] && install -m644 "$SCRIPT_DIR/window.ui" "$HOME/.local/share/homerow/window.ui"
install -m755 "$SCRIPT_DIR/install.sh" "$HOME/.local/share/homerow/install.sh"
ln -sf "$HOME/.local/share/homerow/homerow-app.py" "$HOME/.local/bin/homerow"

/usr/bin/python3 "$HOME/.local/share/homerow/homerow-app.py" --write-icon "$HOME/.local/share/icons/hicolor/scalable/apps/io.github.fuwaflow.HomeRow.svg"
cat >"$HOME/.local/share/applications/io.github.fuwaflow.HomeRow.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=HomeRow
Comment=ZMK-style home row mods and navigation layer
Exec=$HOME/.local/bin/homerow
Icon=io.github.fuwaflow.HomeRow
Terminal=false
Categories=Utility;Settings;
StartupNotify=true
EOF

[[ -f "$HOME/.config/homerow/config.json" ]] || /usr/bin/python3 "$HOME/.local/share/homerow/homerow-app.py" --check >/dev/null 2>&1 || true

if [[ "$MODE" == "--system" ]]; then
  pkexec "$HOME/.local/share/homerow/install.sh" --system-install "$USER" "$HOME/.config/homerow/config.json" "$HOME/.local/bin/homerow-daemon" "$HOME/.local/share/homerow/libhomerow.so"
fi
echo "Installed HomeRow Linux user files."
