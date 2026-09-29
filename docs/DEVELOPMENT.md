# Development

[Home](../README.md) · [User guide](USER_GUIDE.md) · [Performance](PERFORMANCE.md) · [History](HISTORY.md)

All shell commands below run from the repository root. Source-map paths are also relative to that root.

## Build and run

Run these commands from the **repository root**.

```bash
./run.sh
```

The script builds Rust and Swift in release mode, creates an ad-hoc signed app,
and opens it through macOS Launch Services so the Dock applies its normal icon
styling. Runs with command-line arguments launch the executable directly to retain
diagnostic output and exit status. To build without launching:

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
| Deployment target | macOS 14 |
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

A source build creates a separate `build/EverythingMac.app`. Keep track of which copy
you launch when also using the Homebrew installation; their version and signature can differ.

## Architecture and source map

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift executable package and macOS deployment target. |
| `Sources/EverythingMacNative/App.swift` | Search layout, status bar, app lifecycle, menu bar item, and shortcuts. |
| `Sources/EverythingMacNative/AppWindows.swift` | SwiftUI window access, close-to-hide behavior, and Settings presentation. |
| `Sources/EverythingMacNative/ResultsTable.swift` | Virtualized AppKit table, selection, columns, and drag handling. |
| `Sources/EverythingMacNative/Engine.swift` | C bridge calls, background queue, search generations, and row paging. |
| `Sources/EverythingMacNative/LiveModel.swift` | Live updates, scans, checkpoint status, and selection restoration. |
| `Sources/EverythingMacNative/FileActions.swift` | Open/reveal/copy, rename, Trash, terminal, and Quick Look. |
| `Sources/EverythingMacNative/Icons.swift` | Bounded standard file icon loading. |
| `Sources/EverythingMacNative/Preferences.swift` | Native preferences and empty installation defaults. |
| `Sources/CNative/include/everything_mac_native.h` | C-compatible Rust/Swift interface and ownership contract. |
| `bridge/src/` | Rust static library, saved-index loading, search, selection, and live indexing. |
| `run.sh` | Release build, app assembly, signing, and launch. |
| `scripts/package-native.sh` | Local DMG creation. |

SwiftUI's `App` lifecycle owns the search `WindowGroup`, standard menus, and
`Settings` scene. An `NSApplicationDelegateAdaptor` retains native activation,
global shortcuts, the menu bar item, and asynchronous index saving before quit.
The search window forwards delegate callbacks to SwiftUI while intercepting close
to hide it; a responder adapter preserves Quick Look without a custom window class.
The deployment target is macOS 14.

Rust owns the full result-ID vector and passive selection identities. Swift keeps
at most 1,024 row models around the viewport, plus bounded selection samples.
Explicit actions and an open Quick Look panel resolve the complete selected paths.

Access to the active engine is serialized on a background queue. Generation tags
reject obsolete search/row responses. Cancellation does not require the engine
lock. Scan preflight and traversal use a separate cancellable worker and a
four-thread traversal pool. Rust panics at the bridge become errors; poisoned
engines require reloading. Returned C buffers have explicit release functions.

Swift compiler products are cached under
`/private/tmp/everything-mac-native-<uid>-<repository-hash>`. Set
`EVERYTHING_MAC_SWIFT_BUILD_DIR` to override this location. Keeping compiler products
outside Documents avoids ancestor-folder permission waits observed in `dsymutil`.
Generated apps, caches, indexes, and benchmark outputs are excluded from commits.

## UI design principles

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

## Build and validation

Run from the repository root:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --locked --workspace
cargo clippy --locked --workspace --all-targets
./run.sh --live-check /tmp/everything-mac-native-live-check.json
./run.sh --feature-check /tmp/everything-feature-check.json
```

The live check creates disposable fixtures and its own checkpoint. It exercises
FSEvents, filters, selection, rename, Trash/recovery, Quick Look, saved-scope
restoration, English-only packaging, fresh preference defaults, saved settings, and tab switching. A successful JSON
report contains `"error": null`; inspect the report rather than relying only on
the process exit status.

To check selection clearing when a background refresh completes on the Events tab:

```bash
./run.sh --live-check /tmp/everything-mac-native-tab-check.json --tab-check
```

To run only the F9/live-update regression checks (single and 1,200-file selections):

```bash
./run.sh --live-check /tmp/everything-mac-native-terminal-check.json --terminal-check
```

The checks use a deliberately missing terminal application to verify that F9
reaches terminal validation after the displayed result rows become stale, without
opening an external app.

To reproduce F8 after an index update, for one and 130 selected files:

```bash
./run.sh --live-check /tmp/everything-mac-native-trash-check.json --trash-check
```

This trashes only disposable fixture files, verifies that unselected files remain,
and restores each fixture from the recovery location returned by macOS Trash.
The larger selection exceeds the UI's 128-path sample, checking that every
selected file is resolved even when the displayed result generation is stale.

To check that live file changes preserve the selected row without flickering:

```bash
./run.sh --selection-check /tmp/everything-mac-selection.json
python3 -c 'import json; r=json.load(open("/tmp/everything-mac-selection.json")); assert r["error"] is None, r'
```

This uses disposable files and the real table. It checks continuous selection
through live updates, a new click during refresh, selected-file deletion, and
clearing selection when starting a new search. A private test clipboard also checks
immediate Copy, Copy during refresh, and cancellation when the selection or search
changes. Copy Files, Paths, and Filenames wait for a pending selection automatically.

To measure selection restoration after broad searches against a read-only snapshot:

```bash
EVERYTHING_MAC_SELECTION_INDEX=/absolute/path/to/everything-mac.db \
  cargo test -p everything-mac-native-prototype --release selection_refresh_probe -- --ignored --nocapture
```

To verify that the lifecycle status and Files/Events control keep a fixed width
across all English states and counts:

```bash
swiftc -parse-as-library Sources/EverythingMacNative/LifecycleStatus.swift \
  scripts/check-status-layout.swift -o /tmp/everything-mac-status-layout-check
/tmp/everything-mac-status-layout-check
```

To verify sort persistence and header arrows for every column, using temporary
preferences and fresh app models without changing your saved settings:

```bash
./run.sh --sort-check /tmp/everything-mac-sort.json
```

For the saved-index window checks, create a fresh fixture directory:

```bash
FIXTURE_DIR="$(mktemp -d /tmp/everything-mac-native-check.XXXXXX)"
cargo run -p everything-mac-native-prototype --example fixture -- "$FIXTURE_DIR"
./run.sh --index "$FIXTURE_DIR/snapshot.db" \
  --self-check "$FIXTURE_DIR/checks.json"
```

The feature suite checks exclusions, shortcuts, history persistence/restoration, help,
index filename migration, the 800-point minimum layout, the independent Settings
window and draft cancellation, standard menu shortcuts, search-window hiding,
reopening and restoration from the Dock, and asynchronous shutdown on quit.
Historical test totals
and coverage limits are recorded in [History](HISTORY.md); they are not current pass counts.

### Filesystem access and debug information

FSEvents checks require macOS host services; a sandbox restriction can cause failures.
The existing system-wide `tests::test_search_cancel` has also stalled on directory-access
prompts. If it blocks the run, stop it and report the exclusion explicitly:

```bash
cargo test --locked --workspace --no-fail-fast \
  --config 'build.rustflags=["-Csplit-debuginfo=unpacked"]' \
  -- --skip tests::test_search_cancel
cargo clippy --locked --workspace --all-targets \
  --config 'build.rustflags=["-Csplit-debuginfo=unpacked"]'
```

Unpacked debug information avoids ancestor-folder access waits in `dsymutil`.
A run with a skipped test must not be described as a complete workspace pass.

## Scrolling regression check

With a saved index containing at least 10,000 matching rows:

```bash
./run.sh --index /absolute/path/to/everything-mac.db --scroll-query a \
  --scroll-stress --scroll-check /tmp/everything-mac-scroll.json
python3 -c 'import json; r=json.load(open("/tmp/everything-mac-scroll.json")); assert r["error"] is None, r'
```

This opens the index read-only, scrolls the real table through 60 positions, and
fails if visible filenames take longer than 250 ms to appear. The report records
each delay. `--scroll-seed 5107` samples different positions; omit `--scroll-query`
to check all indexed files. Filesystem and icon caches affect timings, so compare
both repeated positions and fresh positions without competing builds running.

## Local packaging

```bash
./scripts/package-native.sh
```

Output: `build/EverythingMac-<VERSION>-<ARCH>.dmg`, using the root `VERSION` file.

This produces an ad-hoc signed package for the build machine’s architecture.
The published Homebrew release supports Apple Silicon. This packaging command does not
install, publish, or notarize the app. The macOS 14 deployment target is a build setting;
actual older-macOS and Intel execution have not been validated.

For broader release validation, check cloud-provider behavior, sustained high-churn
indexing, external terminal/Double Commander integration, and drag/drop into the
intended target applications. Broader release readiness should be based on those
results and an updated performance comparison.

## Source provenance

EverythingMac, previously Cardinal Native, was extracted from `native-prototype/`.
Its original Rust engine crates and sorting code came from the
[seedds Cardinal fork](https://github.com/seedds/cardinal) at commit
`444fdd8618cab97bde45dab7b747ab331133dc06`, derived from
[Cardinal](https://github.com/cardisoft/cardinal). The upstream MIT copyright notice
is retained in [LICENSE](../LICENSE). The app is inspired by
[Everything for Windows](https://www.voidtools.com/).

The native app builds entirely from this repository. The old native index filename
remains in migration code so existing installations keep their data.

The original icon was replaced in 0.1.43. Version 0.1.45 adopted the supplied orange
folder and magnifying-glass artwork in `Resources/EverythingMac.png`, packaged as
`Resources/icon.icns`.

## Automated releases

`VERSION` is the app's release version. To publish, increase it using `major.minor.patch`,
write `docs/releases/<VERSION>.md`, and push both changes to `main`.
Release notes must describe the actual changes directly in text, including relevant
compatibility or upgrade information. Do not include links or a comparison-link
placeholder. The workflow checks for written notes before building and publishes
that file verbatim; retrying a draft also refreshes its notes from the file.
The [release workflow](../.github/workflows/release.yml)
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
