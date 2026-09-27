# Native feature parity work

Baseline: Cardinal 0.1.27, native prototype commit `b21b2cc`.
Request: bring the native SwiftUI/AppKit + Rust app to feature parity with the existing app.

Acceptance checklist (implementation and validation are tracked separately):

- Live index: load, scan, cancel, resume filesystem history, root/include/ignore configuration, rescan, checkpoint/relaunch, status and recent events.
- Search: existing query language and cloud-file semantics, directory scope, case sensitivity, history, sorting by Name/Path/Size/Modified/Created with a configurable limit, bounded rows and stale-response protection.
- Results: persistent resizable columns, multiple selection and stable background refresh, standard file icons, drag/copy files, copy names/paths, context menu.
- Actions: open, Finder/Double Commander reveal, Quick Look with keyboard navigation, F2 exclusive rename, F8 recoverable Trash, configurable F9 terminal.
- App: Command-F, search-to-list navigation, Escape/hide, Command-Shift-Space, menu bar item, preferences/theme/language, permission guidance, window restoration, single-instance normal launch.
- Migration: import existing preferences read-only; keep an independent native index/preferences store. Snapshot benchmark mode remains read-only and has no watcher.
- Delivery: release app, local DMG packaging, macOS 12 deployment target; explicitly distinguish build compatibility from verified OS/hardware coverage.

No public release, remote upload, replacement of the existing app, or modification of its index is part of this request.

## Implementation and evidence

The checklist above is implemented in the native app. Snapshot mode remains a
separate read-only path. The bridge reuses the production sort module and SDK
watcher instead of changing the existing app's behavior.

Automated rendered-window validation covers live create/rename/delete, canonical
scope handling, include exceptions, selection restoration, watcher pause/resume,
sorting, checkpoint save/reload, configuration rebuild, native Trash recovery,
Quick Look, and bundled translations. The original snapshot regression suite also
covers rapid replacement, Unicode, directory scope, missing files, query/load
errors, empty queries, and shutdown with queued work. Rust tests exercise bridge
ownership, cancellation, sorting, stale generations, selection lookup and a
checkpoint that leaves the source index unchanged.

This is implementation parity with validation limits, not a claim that every
production workflow has been exhaustively certified. Actual older-macOS/Intel
execution, real cloud-provider downloads, sustained high-churn indexing, external
Double Commander/iTerm launches and drag/drop into every target application remain
manual deployment checks. Ad-hoc local packaging is supported; no public release
or notarization is performed. The previous benchmark is historical and should not
be presented as a speed guarantee for the expanded app.


## Final validation — 2026-09-27

Environment: Apple M4 Pro, 48 GB RAM, macOS 27.0 (26A428), Xcode 27,
arm64 release build, macOS 12 deployment target.

- Rendered native live suite: **21 passed**, including 1,200 selected files, complete
  Quick Look contents after sorting, and Files → Events → Files selection safety.
- Rendered snapshot suite: **10 passed**.
- Native Rust bridge: **5 passed**, including cancellation while the scan worker is
  blocked before producing an index. Workspace Clippy and final bridge Clippy pass.
- Workspace Rust suite passed earlier in this implementation. During the final
  rerun, the pre-existing `fswalk::tests::test_search_cancel` stalled in a system-wide
  walk: macOS blocked directory access. That process was stopped; the complete
  suite passed with only that test filtered out. This is not an unqualified final
  full-suite pass. Native cancellation was hardened and tested separately.
- Tauri Rust: **42 passed, 1 intentionally ignored** (real Trash test).
- Existing frontend: **305 passed across 34 files**.
- Physical keyboard/window check: Cancel restored 3,289,458 loaded rows while the
  full-root scan was waiting; search remained usable, Command-F and Down selected
  the first row once, and Command-Q saved and exited successfully.
- Read-only selection probe: 30 repeated single-file action resolutions against
  **3,289,458 results**, median **0.0049 ms**, p95 **0.0071 ms**. This measures only
  bridge path resolution on an unchanged generation, not opening a file, drawing,
  first selection, index refresh, or a Tauri comparison.

macOS directory-access waits also affected `dsymutil`, so Swift build products now
live in a per-repository temporary cache. Final Rust checks used unpacked debug
information to avoid the same ancestor-folder lookup:

```sh
cargo test --workspace --no-fail-fast \
  --config 'build.rustflags=["-Csymbol-mangling-version=v0","-Csplit-debuginfo=unpacked"]' \
  -- --skip tests::test_search_cancel
cargo clippy --workspace --all-targets \
  --config 'build.rustflags=["-Csymbol-mangling-version=v0","-Csplit-debuginfo=unpacked"]'
./native-prototype/run.sh --probe --selection-probe
```

See [REVIEW.md](REVIEW.md) for the separate standards and specification reviews.

## Layout alignment

The native window now follows the original search/table/status layout: a single
search row with collapsible folder scope and an Aa toggle, full-width 24-point
result rows, and bottom lifecycle/tabs/counters/rescan/preferences controls. The
same search field filters Events. Index location/date, snapshot/live controls and
debounce are available in the adjacent Index details popover. Errors and permission
notices remain visible when relevant. Long filenames and paths remain single-line
with middle truncation, including highlighted matches.

Validation: release build and DMG packaging passed; the existing 21 live and 10
snapshot UI checks passed. Interactive checks covered scope expansion, Events
search placement, the details popover and loading a large read-only index. Visual
inspection confirmed long paths no longer overlap neighboring rows. No Rust engine
or persistence-format changes were made for this layout update.

## Standalone release 0.1.28 — 2026-09-27

The native app and its required engine crates/resources now build from this
repository alone. Fresh release build and DMG packaging passed. The packaged
application passed 21 live UI checks and 10 snapshot UI checks, with `error: null`
in both reports. The standalone bridge suite passed all 5 tests. Codesign
verification and the DMG checksum verification passed. Validation used the same
macOS 27 / Apple M4 Pro environment above; older macOS releases remain untested.

## Thumbnail removal — 0.1.29

The thumbnail feature has been deleted: generator requests, thumbnail cache,
preference toggle, saved preference handling, reset behavior, and translations.
Results always use standard file icons. There is no setting to enable thumbnails.
The release binary has no Quick Look thumbnail generator references.
