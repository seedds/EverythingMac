@@PRESERVE0@@@@PRESERVE1@@@@PRESERVE5@@@@PRESERVE10@@@@PRESERVE14@@

EverythingMac (previously Cardinal Native) is derived from [Cardinal](https://github.com/cardisoft/cardinal)
and the [seedds fork](https://github.com/seedds/cardinal), under the MIT license
included in LICENSE.

The native app was extracted from `native-prototype/`. The original Rust engine crates in
`engine/` and sorting code were copied from the
local seedds/cardinal checkout at commit
`444fdd8618cab97bde45dab7b747ab331133dc06`.

This repository includes all source and resources needed to build the native app.
Historical Tauri benchmark scripts require a separate seedds/cardinal checkout;
set `EVERYTHING_MAC_TAURI_REPO` to its absolute path (defaults to `../cardinal`).
Those comparison scripts retain the real upstream paths and legacy benchmark environment
variables for interoperability. EverythingMac targets, crates, and build variables use
the EverythingMac name. The only old native storage name retained in app code is the
legacy index filename needed to migrate existing installations.

EverythingMac is inspired by [Everything for Windows](https://www.voidtools.com/).
It adds a native SwiftUI/AppKit interface and improvements to sorting performance,
metadata indexing, scrolling, live selection, file actions, and saved preferences.

The original Cardinal icon was replaced in version 0.1.43. Version 0.1.45 uses
the orange folder and magnifying-glass artwork supplied for this project. Its
source is `Resources/EverythingMac.png`; macOS icon representations are packaged
in `Resources/icon.icns`.
