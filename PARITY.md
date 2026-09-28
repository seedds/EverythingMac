# Native feature parity work

Baseline: Cardinal 0.1.27, native prototype commit `b21b2cc`.
Request: bring the native SwiftUI/AppKit + Rust app to feature parity with the existing app.

Acceptance checklist (implementation and validation are tracked separately):

- Live index: load, scan, cancel, resume filesystem history, root/include/ignore configuration, rescan, checkpoint/relaunch, status and recent events.
- Search: existing query language and cloud-file semantics, directory scope, case sensitivity, history, sorting by Name/Path/Size/Modified/Created with a configurable limit, bounded rows and stale-response protection.
- Results: persistent resizable columns, multiple selection and stable background refresh, standard file icons, drag/copy files, copy names/paths, context menu.
- Actions: open, Finder/Double Commander reveal, Quick Look with keyboard navigation, F2 exclusive rename, F8 recoverable Trash, configurable F9 terminal.
- App: Command-F, search-to-list navigation, Escape/hide, Command-Shift-Space, menu bar item, preferences/theme, permission guidance, window restoration, single-instance normal launch.
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

## F9 during live updates — 0.1.30

A focused check reproduced the exact “index changed” error by processing a real
filesystem event before invoking the terminal action. F9 now uses the first
selected path retained by the UI, avoiding stale result-row resolution and full
selection expansion. The focused check passes for one file and 1,200 selected
files; the complete live suite passes all 23 checks. An earlier full-suite run
timed out on the existing Events-tab transition before reaching the new check;
the focused reproduction and subsequent complete run both finished.

## Stable lifecycle status layout — 0.1.31

The spinner and idle dot now share a 12-point slot. Lifecycle text reserves the
widest translated state, and rescan/cancel icons share a fixed frame. The SwiftUI
layout check reproduced a 6-point busy/idle shift before the fix, plus additional
movement between lifecycle labels. After the fix it measured zero width change
across all six label/busy combinations in each of the 15 bundled languages.
The release build and all 10 rendered snapshot-window checks passed.

## English-only app — 0.1.32

Removed the language picker, persisted/imported language preference, translation
lookup code, and all translation JSON resources. App labels are English strings,
and the bundle declares English as its only language. The build recreates its
generated resource directory to remove translations left by earlier builds.
The status-layout check now measures the six English label/activity states and
continues to report zero width change. Earlier multilingual validation above is
historical.

Validation: release build, English-only bundle inspection, six-state status
layout, 10 snapshot checks, and focused F9 checks passed. The full live suite
completed its first 19 checks (including English-only resources and legacy
preference import) but timed out at the previously observed Events-tab transition
on both runs; this is not a full live-suite pass.

## Nonblocking scrolling — 0.1.36

The old row pager fetched filesystem metadata for all 128 rows before returning
any filenames. Instrumentation measured a 253 ms fetch with the next page queued
behind it. The UI also constructed file URLs without a directory hint while
formatting names and paths, allowing implicit filesystem checks on the main thread.

Paging now expands indexed paths and cached metadata without filesystem reads.
Two separate workers load metadata only for visible rows, cancel obsolete work,
and reject replies from older result generations. Filename/path formatting uses
string operations. Metadata reads and icons can finish after filenames appear;
neither requires content thumbnails.

The real-table `--scroll-check` harness sampled 60 positions in 2,577,296 matching
rows from a fixed copy of a 4,536,478-entry index on the M4 Pro development machine.
Before: maximum 988 ms, four stops above 250 ms. After, at fresh positions:
median 39 ms, maximum 71 ms. Replaying the original positions: median 36 ms,
maximum 95 ms. Six jumps through the unfiltered index: median 24 ms, maximum 50 ms.
These are observed viewport readiness timings, not display-frame or universal
latency guarantees; OS filesystem caches and the sampled paths influence results.

Validation: the bridge regression failed before the fix and passed afterward;
1,793 Rust workspace tests, 10 rendered snapshot checks (including deferred size
and dates), and three focused live F9 checks passed. The initial sandboxed Rust
run could not create filesystem event streams; the unrestricted rerun passed.

## Stable selection during live changes — 0.1.37

Previously, a live search published new rows and cleared the table selection
before asynchronously restoring it. A focused real-window test reproduced three
visible selection gaps across file creation, modification, and deletion updates.

Background searches now finish remapping selection before publishing rows and
selection together. The table retains its row views and only adjusts selection
when the selected indices actually change. Restoration supplies the count and a
bounded path sample without resetting selection as though the user had clicked.
A newer click takes precedence over an in-flight refresh. Deleted selections and
selections cleared by a new search are removed from the backend too.

Validation: `--selection-check` completed seven scenarios with zero highlight or
selection-count gaps across 3,309 observations. It covers unrelated creation and
deletion, selected-file modification, a click during refresh, selected-file
deletion, a new search, and a subsequent refresh after clearing selection.
All six bridge tests and all 23 full live UI checks passed, including sorting,
Quick Look with 1,200 selected files, Events/Files switching, and F9 races.

## F8 after index invalidation — 0.1.38

A focused live-event check reproduced the exact "The index changed" warning
before Trash ran. Explicit actions were resolving selection through the displayed
result generation, which a filesystem poll can invalidate even when the selected
files are unchanged.

The bridge now retains compact selected node IDs alongside path identities.
Explicit actions use `cn_selection_paths`, independent of the current result-row
generation, and verify each resolved path still belongs to the retained selection.
Display restoration continues using generation-checked row ranges. New selections
and index replacements still invalidate pending Swift action replies. Selection
clearing and rescans clear or remap the retained node IDs as well.

Validation: the focused F8 check moved exactly one selected file, then all 130
selected files (beyond the UI's 128-path sample), after real filesystem events made
the displayed rows stale. All files were restored using macOS Trash recovery URLs;
unselected fixtures were untouched. Six bridge tests cover stale generations,
reused-node rejection, clearing, and engine replacement. All 23 live UI checks and
all seven selection-stability scenarios passed, with zero highlight/count gaps.

## Persistent column sorting — 0.1.39

Header clicks now save the sort column and direction to native preferences,
including the third-click unsorted state. New models restore this choice before
their first search, and new tables restore the matching header arrow. Missing or
unrecognized saved column keys fall back to unsorted order.

Validation: the disk-backed `--sort-check` passed all 15 combinations of five
columns and ascending/descending/unsorted states, checking fresh preferences,
models, and table indicators after each click. Existing/invalid preference cases
and all 10 rendered saved-index UI checks also passed.

## Background date indexing — 0.1.40

Modified and Created dates are filled into the existing persistent metadata fields
by two background workers, independent of search and scan queues. This also records
size, which comes from the same filesystem metadata call. Registering a native
checkpoint starts the backfill for old or newly scanned indexes; read-only snapshots
remain unchanged. Live events refresh metadata as before. Sorting now consumes
indexed values without fetching metadata from every matching file. Missing values
remain unknown until indexed; the 20,000-result limit remains in effect.

Workers release the engine lock and ownership before filesystem reads, so a blocked
volume cannot block searches or keep an old index alive after close/replacement.
Late replies are rejected if an event already removed, replaced, or refreshed the
node. The pool is globally bounded across engine replacements. Filesystem waits can
delay background completion, but the app continues using the available index.
Collected values are checkpointed normally, including on quit, so interrupted work
resumes from the remaining missing metadata on the next launch.

Validation: all 1,796 Rust workspace tests passed (including nine bridge tests),
23 live UI checks, 16 preference/sort checks, and seven selection-stability scenarios
with zero highlight/count gaps. New regressions verify legacy backfill while live
monitoring is paused, birth/modified dates against filesystem values, event updates,
late-result rejection, checkpoint/reopen with the source file removed, timestamp
sorting in both directions, and a deliberately blocked metadata read that neither
locks nor retains the engine. All five sorts are checked to avoid fetching missing
metadata during interactive searches.

## Unlimited column sorting — 0.1.42

All matching rows participate in column sorting. The preferences field, saved
limit, legacy threshold import, UI warning, and backend limit parameter are
removed. Old preferences containing a limit are accepted but the value is ignored
and dropped on the next save. Column and direction preferences still persist.

Regression coverage checks ascending, descending, and backend order with 20,001
actual matches; header clicks above 20,000; and removal of an obsolete saved limit.

The focused `--tab-check` also covers a background refresh on the Events tab.
The live harness waits for a Files-table draw only while Files is visible, avoiding
a false timeout when hidden results have a pending draw and selection is already clear.
