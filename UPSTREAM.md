# Upstream attribution

EverythingMac (previously Cardinal Native) is derived from [Cardinal](https://github.com/cardisoft/cardinal)
and the [seedds fork](https://github.com/seedds/cardinal), under the MIT license
included in LICENSE.

The native app was extracted from `native-prototype/`. The original Rust engine crates in
`engine/` and sorting code were copied from the
local seedds/cardinal checkout at commit
`444fdd8618cab97bde45dab7b747ab331133dc06`.

This repository includes all source and resources needed to build the native app.
Historical Tauri benchmark scripts require a separate seedds/cardinal checkout;
set `CARDINAL_TAURI_REPO` to its absolute path (defaults to `../cardinal`).

EverythingMac is inspired by [Everything for Windows](https://www.voidtools.com/).
It adds a native SwiftUI/AppKit interface and improvements to sorting performance,
metadata indexing, scrolling, live selection, file actions, and saved preferences.

The original Cardinal icon was replaced in version 0.1.43. Version 0.1.45 uses
the orange folder and magnifying-glass artwork supplied for this project. Its
source is `Resources/EverythingMac.png`; macOS icon representations are packaged
in `Resources/icon.icns`.
