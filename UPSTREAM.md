# Upstream attribution

Cardinal Native is derived from [Cardinal](https://github.com/cardisoft/cardinal)
and the [seedds fork](https://github.com/seedds/cardinal), under the MIT license
included in LICENSE.

The native app was extracted from `native-prototype/`. The Rust engine crates in
`engine/`, `bridge/src/sort.rs`, translations, and app icon were copied from the
local seedds/cardinal checkout at commit
`444fdd8618cab97bde45dab7b747ab331133dc06`.

This repository includes all source and resources needed to build the native app.
Historical Tauri benchmark scripts require a separate seedds/cardinal checkout;
set `CARDINAL_TAURI_REPO` to its absolute path (defaults to `../cardinal`).
