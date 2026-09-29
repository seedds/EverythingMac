# EverythingMac

EverythingMac is an open-source, native macOS file-search app derived from
[Cardinal](https://github.com/cardisoft/cardinal) and the
[seedds Cardinal fork](https://github.com/seedds/cardinal), inspired by
[Everything for Windows](https://www.voidtools.com/).

It combines SwiftUI controls, an AppKit results table, and a Rust search engine.
Search indexed filenames and paths, narrow results by folder, and work with files
using familiar macOS actions.

<img src="Resources/EverythingMac.png" alt="EverythingMac app icon" width="160" />

## Features

- Search filenames and paths with wildcards, regular expressions, Boolean queries,
  and filters. Reusable sort indexes support sorting all matching results.
- Live filesystem updates, indexed dates and disk usage, and stable selection as
  files change. Open, reveal, preview, rename, copy, drag, or trash selected files.
- Exclude names and glob patterns such as `node_modules`, `*.log`, and `**/build/**`.
  Content searches skip offline cloud placeholders rather than downloading them.
- Saved searches, the latest 100 distinct recent searches, a configurable global
  activation shortcut, and searchable offline help.

See the [versioned performance report](docs/PERFORMANCE.md) for measured latency,
startup costs, memory use, and comparison limits. Its historical results are not
a benchmark of the latest release.

## Install

```sh
brew install --cask seedds/tap/everything
```

Or download the Apple Silicon DMG from the
[latest release](https://github.com/seedds/EverythingMac/releases/latest).
The cask installs **EverythingMac.app** in `/Applications`.

To update:

```sh
brew update
brew upgrade --cask seedds/tap/everything
```

The published release targets **Apple Silicon and macOS 14 or later**. Development
validation has used an M4 Pro on macOS 27; actual macOS 14 and Intel execution
remain unverified. Releases are ad-hoc signed and are not notarized. macOS may
require approval in Privacy & Security and renewed permissions after an update.

## First use

Launch the installed app and grant **Full Disk Access** in System Settings when
needed to search protected locations. Normal startup opens the saved index or
scans the configured root when no index exists. Configure scope and exclusions
in Preferences; use **Index folder…** in Index details to choose a monitored root.

Type a filename or a query such as `report*.txt`. Use the Folder scope field to
narrow the results and **Aa** for case sensitivity. Press Down to enter results,
Space for Quick Look, or Command-R to reveal a selection in Finder.

The default activation shortcut is **Command-Shift-Space** and can be changed in
Preferences. **Command-/** opens Search & Shortcuts. The **Search Library** button
beside the search field contains recent and saved searches.

## Documentation

| Guide | Contents |
| --- | --- |
| [User guide](docs/USER_GUIDE.md) | Search controls, file actions, exclusions, history, storage, and permissions. |
| [Development](docs/DEVELOPMENT.md) | Build setup, architecture, validation, packaging, and releases. |
| [Performance](docs/PERFORMANCE.md) | Measurement tools and versioned benchmark results with their limitations. |
| [History](docs/HISTORY.md) | Engineering decisions, important regressions, and recorded validation. |

To build from source, install Xcode and the pinned Rust toolchain described in the
[developer guide](docs/DEVELOPMENT.md#build-and-run), then run `./run.sh` from the
repository root. Source builds create a separate app under `build/`.

## Feedback and license

Report bugs and suggestions in
[GitHub Issues](https://github.com/seedds/EverythingMac/issues), including the app
version, macOS version, and steps to reproduce. Avoid including private file paths
or index snapshots unless you intend to share them.

EverythingMac is distributed under the [MIT license](LICENSE). Original upstream
copyright notices are retained. Credits to Cardinal and Everything appear above;
[source provenance](docs/DEVELOPMENT.md#source-provenance) records the original
engine revision and compatibility references.
