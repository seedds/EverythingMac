# Cardinal Native

Cardinal Native is a macOS file-search application built with **SwiftUI controls,
an AppKit results table, and Cardinal’s existing Rust search engine**. This repository contains the standalone native app and its Rust engine.
See [UPSTREAM.md](UPSTREAM.md) for attribution.

The native application is a **local release candidate**. Core desktop workflows
are implemented, but older macOS releases, Intel hardware, cloud providers, and
some external application integrations still need deployment validation.

## Install with Homebrew

```bash
brew install --cask seedds/tap/cardinal
```

To upgrade from the previous Tauri app:

```bash
brew update
brew upgrade --cask seedds/tap/cardinal
```

Version 0.1.28 replaces the tap's Tauri app with **Cardinal Native.app**.
Quit the old Cardinal app before launching the native app. Its saved preferences
are imported on first launch, and native data is stored separately. Grant the
native app Full Disk Access if needed. The release supports Apple Silicon and is
ad-hoc signed, not notarized; macOS may require approval in Privacy & Security.

## Quick start

Run these commands from the **repository root**.

```bash
./run.sh
```

The script builds Rust and Swift in release mode, creates an ad-hoc signed app,
and launches it. To build without launching:

```bash
./run.sh --build-only
```

| Item | Value |
| --- | --- |
| Application name | Cardinal Native |
| Built application | `build/Cardinal Native.app` |
| Bundle identifier | `com.cardinal.native-prototype` |
| Deployment target | macOS 12 |
| Validated hardware | Apple Silicon, M4 Pro |
| Source repository | [seedds/cardinal_native](https://github.com/seedds/cardinal_native) |

### Requirements

- macOS with Xcode selected as the active developer toolchain.
- Rust managed by `rustup`, using the repository’s `rust-toolchain.toml`.
- Python 3 for benchmark measurement scripts.

The current Rust toolchain is `nightly-2025-12-11`. Install it if needed:

```bash
rustup toolchain install nightly-2025-12-11 --component rustfmt --component clippy
```

Node/npm is needed only for the optional Tauri benchmark in a separate checkout.

## Interface

The app is English-only, with no language setting or bundled translations.

The layout follows the original Cardinal app: **one search row, a full-width
results table, and a compact bottom status bar**.

| Area | Purpose |
| --- | --- |
| Main search field | Search filenames, or filter recent events when Events is selected. |
| Leading chevron/folder button | Expand or collapse the directory query. Closing suspends the filter; reopening restores its value for the current session. |
| Aa button | Toggle case-sensitive matching. |
| Results table | Name, Path, Size, Modified, and Created columns, with resizable widths and single-line middle truncation. |
| Bottom status bar | Lifecycle state, Files/Events tabs and counts, rescan, preferences, selection count, and search duration. |
| Index details (ⓘ) | Snapshot location and modification time, index/live-update controls, detailed timings, and typing delay. |

Enter submits a search immediately. Typing uses a **100 ms debounce** by default;
the Index details popover offers 0, 100, and 300 ms for comparison. Existing rows
remain visible while a replacement search runs.

Click a column header to cycle through ascending, descending, and backend order.
Sorting is subject to the limit configured in Preferences. The Events tab uses
the same top search field rather than adding a second search bar.

### Layout principles

For future UI changes:

1. Use the original Cardinal layout and interactions as the baseline.
2. Change that baseline only for a concrete usability, accessibility, or
   responsiveness improvement; explain the reason in the change description.
3. Keep the results prominent. Put occasional index-management and performance
   controls in Index details or Preferences rather than adding permanent toolbars.
4. Preserve native keyboard behavior, clear focus, reusable table rows, and
   visible error states.
5. Keep engine timing and implementation details out of the everyday search flow
   unless they help the user make a decision.

## Keyboard and file actions

| Shortcut or interaction | Action |
| --- | --- |
| Command-F | Focus search. |
| Enter in search | Submit immediately. |
| Down from search | Enter the results. |
| Up from the first result | Return to search. |
| Option-Up / Option-Down | Navigate query history. |
| Shift-arrow / Command-click | Extend or modify selection using AppKit behavior. |
| Double-click / Command-O | Open selected files. |
| Command-R | Reveal in Finder. |
| Space | Toggle Quick Look. |
| Up / Down in Quick Look | Navigate results. |
| Command-C | Copy file URLs. |
| Command-Shift-C | Copy paths. |
| F2 | Rename without overwriting an existing file. |
| F8 | Move selected files to macOS Trash. |
| F9 | Open the selected folder, or a file’s parent, in the configured terminal. |
| Command-Shift-Space | Toggle the app window, if the shortcut is available. |
| Escape / Close Window | Hide the window; live monitoring continues. |
| Command-Q | Save the native checkpoint and quit. |

The context menu also provides filename copying, Double Commander reveal, and
column-width reset. Dragging results exports file URLs. Standard file icons load
lazily into a bounded cache. Search results never generate content thumbnails; Quick Look opens only when explicitly requested.

## Indexing and storage

Normal launch loads the native index when one exists. Otherwise it reads the
existing Cardinal snapshot at:

```text
~/Library/Application Support/com.cardinal.one/cardinal.db
```

With no saved index, it scans the configured monitor root. If a loaded index’s
root/include/ignore configuration differs from the saved native preferences, it
starts a rebuild. Existing Cardinal preferences are imported read-only on first
launch.

Native data is stored separately:

```text
~/Library/Application Support/com.cardinal.native-prototype/
├── cardinal.db
└── preferences.json
```

The original Cardinal index and preferences are not overwritten.

Use **Index folder…** in Index details to choose a monitored root, and the bottom
rescan button to rebuild the current scope. Preferences contains include/ignore
paths, appearance, menu bar visibility, terminal application,
and sorting limit. Include paths override ignored ancestors.

The app processes filesystem events and writes checkpoints during idle intervals
and before quitting. Cancelling a scan retains the previous index. If macOS blocks
a filesystem call, cancellation releases the native engine queue while at most one
scan worker remains outstanding. Another scan must wait for that worker to finish.

### Snapshot mode

To search an index without monitoring the filesystem or writing an index:

```bash
./run.sh --snapshot --index /absolute/path/to/cardinal.db
```

**Choose index…** also enters snapshot mode. **Enable live updates** switches the
loaded index to live mode and saves subsequent checkpoints in the native store.
Missing or incompatible snapshots produce an actionable error without starting a
scan.

“Read-only” describes the **index**, not the files represented by it. File actions
still operate on real files, and metadata/content queries retain the engine’s
existing filesystem reads. A snapshot is not a frozen copy of file contents.

### macOS permissions

Cardinal Native needs its own filesystem permissions. For protected locations,
enable it under **System Settings → Privacy & Security → Full Disk Access**, then
relaunch. The app provides permission guidance and a link to System Settings.

If Command-Shift-Space is already registered by another app, the native app reports
the conflict. Quit the conflicting Cardinal instance to make the shortcut available.

## Architecture and source map

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift executable package and macOS deployment target. |
| `Sources/CardinalNative/App.swift` | Search layout, status bar, app lifecycle, menu bar item, and shortcuts. |
| `Sources/CardinalNative/ResultsTable.swift` | Virtualized AppKit table, selection, columns, and drag handling. |
| `Sources/CardinalNative/Engine.swift` | C bridge calls, background queue, search generations, and row paging. |
| `Sources/CardinalNative/LiveModel.swift` | Live updates, scans, checkpoint status, and selection restoration. |
| `Sources/CardinalNative/FileActions.swift` | Open/reveal/copy, rename, Trash, terminal, and Quick Look. |
| `Sources/CardinalNative/Icons.swift` | Bounded standard file icon loading. |
| `Sources/CardinalNative/Preferences.swift` | Native preferences and legacy import. |
| `Sources/CNative/include/cardinal_native.h` | C-compatible Rust/Swift interface and ownership contract. |
| `bridge/src/` | Rust static library, saved-index loading, search, selection, and live indexing. |
| `run.sh` | Release build, app assembly, signing, and launch. |
| `scripts/package-native.sh` | Local DMG creation. |

Rust owns the full result-ID vector and passive selection identities. Swift keeps
at most 1,024 row models around the viewport, plus bounded selection samples.
Explicit actions and an open Quick Look panel resolve the complete selected paths.

Access to the active engine is serialized on a background queue. Generation tags
reject obsolete search/row responses. Cancellation does not require the engine
lock. Scan preflight and traversal use a separate cancellable worker and a
four-thread traversal pool. Rust panics at the bridge become errors; poisoned
engines require reloading. Returned C buffers have explicit release functions.

Swift compiler products are cached under
`/private/tmp/cardinal-native-<uid>-<repository-hash>`. Set
`CARDINAL_SWIFT_BUILD_DIR` to override this location. Keeping compiler products
outside Documents avoids ancestor-folder permission waits observed in `dsymutil`.
Generated apps, caches, indexes, and benchmark outputs are excluded from commits.

## Build and validation

Run from the repository root:

```bash
cargo test --workspace
cargo clippy --workspace --all-targets
./run.sh --live-check /tmp/cardinal-native-live-check.json
```

The live check creates disposable fixtures and its own checkpoint. It exercises
FSEvents, filters, selection, rename, Trash/recovery, Quick Look, saved-scope
restoration, English-only packaging, preference import, and tab switching. A successful JSON
report contains `"error": null`; inspect the report rather than relying only on
the process exit status.

To run only the F9/live-update regression checks (single and 1,200-file selections):

```bash
./run.sh --live-check /tmp/cardinal-native-terminal-check.json --terminal-check
```

The checks use a deliberately missing terminal application to verify that F9
reaches terminal validation after the displayed result rows become stale, without
opening an external app.

To verify stable lifecycle status widths across all English states:

```bash
swiftc -parse-as-library Sources/CardinalNative/LifecycleStatus.swift \
  scripts/check-status-layout.swift -o /tmp/cardinal-status-layout-check
/tmp/cardinal-status-layout-check
```

For the saved-index window checks, create a fresh fixture directory:

```bash
FIXTURE_DIR="$(mktemp -d /tmp/cardinal-native-check.XXXXXX)"
cargo run -p cardinal-native-prototype --example fixture -- "$FIXTURE_DIR"
./run.sh --index "$FIXTURE_DIR/snapshot.db" \
  --self-check "$FIXTURE_DIR/checks.json"
```

Recorded validation includes 21 native live checks, 10 snapshot checks, 5 bridge
tests, 42 Tauri Rust tests, and 305 existing frontend tests. These are recorded
results, not a claim that every command has passed on every supported system.

See [PARITY.md](PARITY.md) for the exact environment, intentionally ignored tests,
the system-wide cancellation test that stalled on macOS directory access, and the
unpacked-debug-information workaround. See [REVIEW.md](REVIEW.md) for review
findings and their resolutions.

## Performance measurement

[BENCHMARK.md](BENCHMARK.md) documents the earlier snapshot-only prototype. Its
results are historical and are not a speed guarantee for the expanded live app.
Use the same snapshot and queries for both applications, and compare Enter-driven
searches separately from typing/debounce latency.

```bash
./run.sh --build-only
cp "$HOME/Library/Application Support/com.cardinal.one/cardinal.db" \
  build/benchmark-index.db
python3 scripts/measure.py native \
  build/benchmark-index.db build/native.json
./benchmark-tauri.sh \
  "$PWD/build/benchmark-index.db" \
  "$PWD/build/tauri.json" --build-only
python3 scripts/measure.py tauri \
  build/benchmark-index.db build/tauri.json
```

For backend and selection-resolution probes:

```bash
./run.sh --probe --index /absolute/path/to/cardinal.db
./run.sh --probe --selection-probe \
  --index /absolute/path/to/cardinal.db
```

Draw callbacks are rendering proxies, not physical display measurements. Report
filename display separately from icon completion; include WebView helpers in Tauri
memory totals. Avoid competing builds or benchmarks during measurement. Do not
attribute gains from different debounce settings or omitted features to SwiftUI.

The optional Tauri baseline requires a separate `seedds/cardinal` checkout. Set
`CARDINAL_TAURI_REPO` to its absolute path (defaults to `../cardinal`). Historical
benchmark notes retain paths from the original combined repository.

The Tauri baseline uses an explicit benchmark feature and separate app identifier.
After benchmarking, rebuild the ordinary Tauri binary with
`cd cardinal && npm run tauri build -- --no-bundle`.

## Local packaging

```bash
./scripts/package-native.sh
```

Output: `build/Cardinal-Native-0.1.33-arm64.dmg`.

This produces an ad-hoc signed package for the build machine’s architecture.
The published Homebrew release supports Apple Silicon. It does not install,
publish, or notarize the app. The macOS 12 deployment target is a build setting;
actual older-macOS and Intel execution have not been validated.

Before a production release, validate cloud-provider behavior, sustained high-churn
indexing, external terminal/Double Commander integration, and drag/drop into the
intended target applications. Full native migration should be based on those
results and an updated performance comparison.
