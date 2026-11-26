# HomeRow

macOS menu bar app for ZMK-style home row mods on the built-in MacBook keyboard.

I wanted my Corne's home row mods and navigation layer on my MacBook without losing the native macOS top-row keys (brightness, mission control, dictation, focus, media) the way DriverKit virtual keyboards do. HomeRow uses a `CGEventTap` instead, so the hardware function row stays untouched.

## Features

- Balanced home row mods (`A S D F` / `J K L ;`, or `A R S T` / `N E I O` on Colemak-DH) with prior-idle and opposite-hand trigger checks
- Typing test to auto-tune tap and idle delays
- Caps Lock to Backspace (`hidutil`)
- Optional `Left Cmd` navigation layer (`J K L ;` arrows, `U O` home/end, `H N` page up/down)
- Optional `Cmd+Tab` / `Ctrl+Tab` swap

## Build

```sh
./build.sh
open HomeRow.app
```

Or grab `HomeRow-macOS.zip` from [Releases](https://github.com/fuwaflow/HomeRow/releases). On first launch, grant permission under **System Settings > Privacy & Security > Device Control and Data Access** (or **Accessibility**).
