# HomeRow

A simple, native macOS menu bar app for **ZMK-style home-row mods**—with **all 12 MacBook top-row keys** (Brightness, Mission Control, Spotlight, Dictation/Mic, Focus, Media, Volume) working 100% natively.

## Features

- **Home-Row Mods**: Tap to type normally; hold + press an opposite-hand key to trigger `⌃ Ctrl`, `⌥ Opt`, `⌘ Cmd`, or `⇧ Shift`.
- **Anti-Misfire Protections**: Built-in **Fast-Typing Protection** (`require-prior-idle`), **Safer Two-Hand Shortcuts** (`hold-trigger-key-positions`), and **Double-Tap Repeat** (`quick-tap`).
- **Auto-Tune Typing Test**: Measures your real typing speed and tap duration to pick comfortable delays automatically.
- **Visual Home-Row Editor**: Click any keycap (supports **QWERTY** and **Colemak-DH** labels) to customize its hold modifier.
- **Optional Extras**: `Left Cmd → Arrow Keys` navigation layer and `Swap Cmd+Tab & Ctrl+Tab`.
- **100% Native macOS**: Uses `CGEventTap` + SwiftUI—no DriverKit/VirtualHIDDevice needed.

## Build & Run

Requires macOS 13+ and Swift (`xcode-select --install`).

```sh
chmod +x build.sh
./build.sh
open HomeRow.app
```

Grant permission when prompted in **System Settings → Privacy & Security → Device Control and Data Access** (or **Accessibility** on older macOS).
