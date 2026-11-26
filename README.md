# HomeRow

ZMK-style home row mods, Caps Lock → Backspace, and navigation layer for macOS and Linux.

I wanted my Corne's home row mods and navigation layer on my MacBook without losing the native top-row keys (brightness, mission control, dictation, focus, media) the way DriverKit virtual keyboards do. HomeRow uses a `CGEventTap` on macOS and an `evdev` + `uinput` daemon on Linux, so the hardware function row stays untouched.

## Features

- Balanced home row mods (`A S D F` / `J K L ;`, or `A R S T` / `N E I O` on Colemak-DH) with prior-idle and opposite-hand trigger checks
- Typing test to auto-tune tap and idle delays
- Caps Lock to Backspace (`hidutil` on macOS, `evdev` on Linux)
- Optional `Left Cmd` navigation layer (`J K L ;` arrows, `U O` home/end, `H N` page up/down)
- Optional `Cmd+Tab` / `Ctrl+Tab` swap (macOS)
- Apple ISO `~` / `§` swap and `ctrl:swap_lwin_lctl` detection (Linux)

## Build

### macOS

```sh
./build.sh
open HomeRow.app
```

Or grab `HomeRow-macOS.zip` from [Releases](https://github.com/fuwaflow/HomeRow/releases). On first launch, grant permission under **System Settings > Privacy & Security > Device Control and Data Access** (or **Accessibility**).

### Linux

Requires `gcc`, `gtk4`, `libadwaita`, and `python3-gobject`:

```sh
./linux/install.sh
```

Open **HomeRow** from your app launcher (or run `homerow`) and click **Enable & Start** to set up `homerow.service`, or run `./linux/install.sh --system`.
