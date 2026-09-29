# EverythingMac

**EverythingMac** is a native macOS file-search app derived from
[Cardinal](https://github.com/cardisoft/cardinal) and the
[seedds Cardinal fork](https://github.com/seedds/cardinal), with many improvements
to performance, reliability, and the macOS interface. It is inspired by
[Everything for Windows](https://www.voidtools.com/).

EverythingMac combines SwiftUI controls, an AppKit results table, and Cardinal’s
Rust search engine. Improvements include reusable sort indexes with unlimited
column sorting, indexed file dates, faster scrolling, stable selection during
live updates, more reliable file actions, and persistent sorting preferences.
See [UPSTREAM.md](UPSTREAM.md) for attribution and [the performance report](MAINTAINED-SORT-PERFORMANCE.md)
for measured sorting improvements.

<img src="Resources/EverythingMac.png" alt="EverythingMac app icon" width="160" />

Download the [latest native release](https://github.com/seedds/EverythingMac/releases/latest).
The `seedds/tap/everything` Homebrew cask follows releases from this repository.
The older `seedds/cardinal` repository contains the previous Tauri app.

The native application is a **local release candidate**. Core desktop workflows
are implemented, but older macOS releases, Intel hardware, cloud providers, and
some external application integrations still need deployment validation.

## Install with Homebrew

```bash
brew install --cask seedds/tap/everything
```

To upgrade an existing installation:

```bash
brew update
brew upgrade --cask seedds/tap/everything
```

The cask is named `everything`. After `brew tap seedds/tap`, you can also use
`brew install --cask everything`. The app is **EverythingMac.app**.
Grant EverythingMac Full Disk Access if needed. The release supports Apple Silicon
and is ad-hoc signed, not notarized; macOS may require approval in Privacy & Security.

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

To verify that a direct launch uses the current app icon with macOS's standard
size and shape, including the default icon shown when a runtime override is removed:

```sh
./run.sh --icon-check /tmp/everythingmac-icon-check.json
```

This startup check exits without opening the index or changing preferences.

The supplied icon source is `Resources/EverythingMac.png`. To rebuild its macOS
icon sizes, run `./scripts/build-icon.sh`.

| Item | Value |
| --- | --- |
| Application name | EverythingMac |
| Built application | `build/EverythingMac.app` |
| Bundle identifier | `com.everything.mac` |
| Deployment target | macOS 12 |
| Validated hardware | Apple Silicon, M4 Pro |
| Source repository | [seedds/EverythingMac](https://github.com/seedds/EverythingMac) |

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
| Folder scope field | Always visible to the right of the search field. Filters file results by folder; clear it to remove the filter. Disabled on the Events tab. |
| Aa button | Left of the search field; toggles case-sensitive matching. |
| Results table | Name, Path, Size, Modified, and Created columns, with resizable widths and single-line middle truncation. |
| Bottom status bar | Lifecycle state, Files/Events tabs and counts, rescan, preferences, selection count, and search duration. |
| Index details (ⓘ) | Snapshot location and modification time, index/live-update controls, detailed timings, and typing delay. |

Enter submits a search immediately. Typing uses a **100 ms debounce** by default;
the Index details popover offers 0, 100, and 300 ms for comparison. Existing rows
remain visible while a replacement search runs.

Click a column header to cycle through ascending, descending, and backend order.
The chosen column and direction (including unsorted order) are saved immediately
and restored with the header arrow when the app opens again.
Column sorting applies to all matching results, with no result-count limit. The Events tab uses
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

Scrolling loads filenames and paths directly from the index. Size and dates load
from indexed metadata, with a separate visible-row fallback while indexing is incomplete;
slow filesystem metadata cannot hold up a whole page.
Metadata requests for rows that scroll out of view are cancelled when possible.

Modified and Created dates (plus size from the same metadata read) are indexed in
the background and saved in the native checkpoint. Existing indexes are filled in
automatically without a full rescan. File-change events keep these values current.
The index details popover shows **Indexing file dates…** while this work is running;
unavailable dates remain unknown. Sorting uses indexed values only, so date ordering
fills in as indexing progresses. There is no sorting limit.
Read-only snapshot mode does not start background indexing.

Sorting reuses compact ID orders for Name, Path, Size, Modified, and Created.
These orders are prepared when the index opens; small searches use integer ranks
and broad searches filter an existing order. File events and metadata updates
refresh affected entries. The snapshot format is unchanged. Sorting has no result-count limit or limit setting. See [the measured comparison](MAINTAINED-SORT-PERFORMANCE.md)
for query latency, startup cost, and memory use.

## Indexing and storage

Normal launch loads EverythingMac's saved index when one exists. Otherwise it
scans the configured monitor root. New installations start with empty include
and ignore paths and an empty terminal application setting (F9 uses macOS Terminal).
Preferences and indexes
from older apps are not imported. If a loaded index's root/include/ignore
configuration differs from the saved preferences, it starts a rebuild.

Native data is stored separately:

```text
~/Library/Application Support/com.everything.mac/
├── cardinal.db
└── preferences.json
```

The original Cardinal index and preferences are not overwritten.

Use **Index folder…** in Index details to choose a monitored root, and the bottom
rescan button to rebuild the current scope. Preferences contains include/ignore
paths, appearance, menu bar visibility, and terminal application. Include paths override ignored ancestors.

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

EverythingMac needs its own filesystem permissions. For protected locations,
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
| `Sources/CardinalNative/Preferences.swift` | Native preferences and empty installation defaults. |
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
restoration, English-only packaging, fresh preference defaults, saved settings, and tab switching. A successful JSON
report contains `"error": null`; inspect the report rather than relying only on
the process exit status.

To check selection clearing when a background refresh completes on the Events tab:

```bash
./run.sh --live-check /tmp/cardinal-native-tab-check.json --tab-check
```

To run only the F9/live-update regression checks (single and 1,200-file selections):

```bash
./run.sh --live-check /tmp/cardinal-native-terminal-check.json --terminal-check
```

The checks use a deliberately missing terminal application to verify that F9
reaches terminal validation after the displayed result rows become stale, without
opening an external app.

To reproduce F8 after an index update, for one and 130 selected files:

```bash
./run.sh --live-check /tmp/cardinal-native-trash-check.json --trash-check
```

This trashes only disposable fixture files, verifies that unselected files remain,
and restores each fixture from the recovery location returned by macOS Trash.
The larger selection exceeds the UI's 128-path sample, checking that every
selected file is resolved even when the displayed result generation is stale.

To check that live file changes preserve the selected row without flickering:

```bash
./run.sh --selection-check /tmp/cardinal-selection.json
python3 -c 'import json; r=json.load(open("/tmp/cardinal-selection.json")); assert r["error"] is None, r'
```

This uses disposable files and the real table. It checks continuous selection
through live updates, a new click during refresh, selected-file deletion, and
clearing selection when starting a new search.

To verify stable lifecycle status widths across all English states:

```bash
swiftc -parse-as-library Sources/CardinalNative/LifecycleStatus.swift \
  scripts/check-status-layout.swift -o /tmp/cardinal-status-layout-check
/tmp/cardinal-status-layout-check
```

To verify sort persistence and header arrows for every column, using temporary
preferences and fresh app models without changing your saved settings:

```bash
./run.sh --sort-check /tmp/cardinal-sort.json
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
cp "$HOME/Library/Application Support/com.everything.mac/cardinal.db" \
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

Output: `build/EverythingMac-<VERSION>-arm64.dmg`, using the root `VERSION` file.

This produces an ad-hoc signed package for the build machine’s architecture.
The published Homebrew release supports Apple Silicon. It does not install,
publish, or notarize the app. The macOS 12 deployment target is a build setting;
actual older-macOS and Intel execution have not been validated.

Before a production release, validate cloud-provider behavior, sustained high-churn
indexing, external terminal/Double Commander integration, and drag/drop into the
intended target applications. Broader release readiness should be based on those
results and an updated performance comparison.

## Scrolling regression check

With a saved index containing at least 10,000 matching rows:

```bash
./run.sh --index /absolute/path/to/cardinal.db --scroll-query a \
  --scroll-stress --scroll-check /tmp/cardinal-scroll.json
python3 -c 'import json; r=json.load(open("/tmp/cardinal-scroll.json")); assert r["error"] is None, r'
```

This opens the index read-only, scrolls the real table through 60 positions, and
fails if visible filenames take longer than 250 ms to appear. The report records
each delay. `--scroll-seed 5107` samples different positions; omit `--scroll-query`
to check all indexed files. Filesystem and icon caches affect timings, so compare
both repeated positions and fresh positions without competing builds running.

## Automated releases

`VERSION` is the app's release version. To publish, increase it using `major.minor.patch`
and push the change to `main`. The [release workflow](.github/workflows/release.yml)
tests the Rust bridge, builds an Apple Silicon DMG on macOS 15, verifies the app
signature and DMG, and publishes a matching GitHub tag and release. It then downloads
the public DMG and updates the Homebrew cask's version and SHA256 together.

Run the workflow manually from GitHub Actions on `main` to retry a failed release
or tap update. Published DMGs are reused, never replaced; older versions cannot
replace the latest release or downgrade the tap. Concurrent releases are serialized.
If the tap job fails, the GitHub release remains available; rerun the failed job
after fixing the reported error.

The `HOMEBREW_TAP_DEPLOY_KEY` Actions secret holds a dedicated write deploy key
for `seedds/homebrew-tap`. The normal `GITHUB_TOKEN` publishes releases in this
repository. No personal account token is needed. Packaging remains ad-hoc signed;
this workflow does not notarize the application.
