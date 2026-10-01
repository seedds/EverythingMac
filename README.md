# EverythingMac

EverythingMac is an open-source, native macOS file-search app derived from
[Cardinal](https://github.com/cardisoft/cardinal) and the
[seedds Cardinal fork](https://github.com/seedds/cardinal), inspired by
[Everything for Windows](https://www.voidtools.com/).

It combines SwiftUI controls, an AppKit results table, and a Rust search engine.
Search indexed filenames and paths, narrow results by folder, and work with files
using familiar macOS actions.

<img src="Resources/EverythingMac.png" alt="EverythingMac app icon" width="160" />

## Speed compared with Cardinal

Cardinal 0.1.23 and EverythingMac 0.1.81 were timed on the same Mac, indexing the same
5.83 million files and folders. The table compares the search engines, not the apps'
interfaces, and gives the median of three alternating rounds. The Mac was busy at the
time (load average 31–44). The [method and full results](docs/PERFORMANCE.md#compared-with-cardinal-0123)
are in the performance report.

| Operation | Cardinal 0.1.23 | EverythingMac 0.1.81 | Faster by |
| --- | ---: | ---: | ---: |
| Full scan of `/` | 16.2 s | 13.2 s | 1.2× |
| Opening the saved index | 3.56 s | 1.68 s | 2.1× |
| Search `report` | 47.3 ms | 7.4 ms | 6.4× |
| Search `e` (4.2 million matches) | 307 ms | 4.9 ms | 63× |
| Search `*.swift` | 58.3 ms | 10.1 ms | 5.8× |
| Search `ext:pdf` | 217 ms | 5.4 ms | 40× |
| Search `infolder:/Applications plist` | 56.1 ms | 12.6 ms | 4.4× |
| Empty search (all 5.83 million) | 29.5 ms | 12.4 ms | 2.4× |

Peak memory and index size are about the same. Saving the index takes 0.84 s instead
of 0.68 s; EverythingMac's index also carries a checksum that opening verifies.

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
scans the configured root when no index exists. Choose the monitored root and
configure scope and exclusions in **Settings → Index** (Command-,). The index covers
the startup disk; add other drives to Include paths to search them.

Type a filename or a query such as `report*.txt`. Use the Folder scope field to
narrow the results and **Aa** for case sensitivity. Press Down to enter results,
Space for Quick Look, or Command-R to reveal a selection in Finder.

The default activation shortcut is **Command-Shift-Space** and can be changed in
**Settings → General**. **Command-/** opens Search & Shortcuts. The **Search Library** button
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
