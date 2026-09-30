# Engineering history

[Home](../README.md) · [User guide](USER_GUIDE.md) · [Development](DEVELOPMENT.md) · [Performance](PERFORMANCE.md)

This records decisions and observed checks, not current usage instructions or a claim
that every check was rerun for every release. Published versions are listed in
[GitHub releases](https://github.com/seedds/EverythingMac/releases). The original
[parity log](https://github.com/seedds/EverythingMac/blob/a073da6/PARITY.md) and
[review report](https://github.com/seedds/EverythingMac/blob/a073da6/REVIEW.md)
remain available in Git history.

## Native foundation and review — September 27, 2026

The SwiftUI/AppKit interface and Rust bridge were developed against Cardinal 0.1.27,
starting from prototype commit `b21b2cc`. Initial parity work covered live indexing,
cancellation, scope changes, file actions, selection, preferences, and read-only
snapshots. Preference import and multilingual behavior in the early reports are
historical; current installations have independent settings and an English-only UI.

Standards and Spec reviews of `f1969e2` and subsequent fixes resolved these issues:

- Keep passive selection compact in Rust; resolve complete paths for explicit
  actions instead of transferring entire large result sets to Swift.
- Reject stale selections and reused nodes, include uncached rows in dragging, and
  use the actual AppKit drag callback. Clear actionable selection and Quick Look
  state when switching tabs.
- Clean up replacement engines after failed adoption. Run scan preflight and
  symlink resolution inside the bounded cancellable worker.
- Rebuild on changed saved scope and resolve the complete selection for Quick Look.

Both reviews ended with no unresolved correctness findings in their scope. An
optional suggestion to replace string-based file-action dispatch with an enum if
the interface grows was not a release blocker.

On an Apple M4 Pro, 48 GB RAM, macOS 27.0 (26A428), Xcode 27: 21 live checks,
10 snapshot checks, and 5 bridge checks passed.

The final workspace rerun stalled in the existing system-wide
`fswalk::tests::test_search_cancel` while macOS waited for directory access. The
remaining suite passed with that test excluded; separate native cancellation checks
passed. This was not an unqualified full-workspace pass. Build artifacts moved to
temporary storage and Rust used unpacked debug information to avoid ancestor-folder
access waits in `dsymutil`. Current commands and the filtered fallback are in
[Development](DEVELOPMENT.md#filesystem-access-and-debug-information).

## Standalone app and interface — 0.1.28–0.1.32

- **0.1.28:** App, engine crates, and resources became independently buildable.
  App signing, DMG verification, 21 live checks, 10 snapshot checks, and 5 bridge
  checks passed on the development machine.
- **0.1.29:** Removed automatic content thumbnails and their settings. Standard
  file icons and explicitly requested Quick Look remain.
- **0.1.30:** Fixed F9 failing after filesystem events invalidated displayed results.
  Terminal actions use the retained first selected path. Checks covered one and
  1,200 selections, followed by a successful 23-check live run.
- **0.1.31:** Fixed status-bar movement by reserving consistent spinner and label
  space. Movement fell from 6 points to zero in the checked states.
- **0.1.32:** Removed translations and the language preference. English-only layout
  and snapshot checks passed. The live run timed out on the Events-tab transition
  after 19 checks; it was not recorded as a full live-suite pass.

## Scrolling and selection — 0.1.36–0.1.38

**0.1.36:** Filenames and paths began paging directly from indexed data. Separate
workers fetch visible-row metadata, cancel obsolete work, and reject old replies.
String formatting avoids implicit filesystem reads on the UI thread, replacing a
pager that waited for metadata on all 128 rows.

The scroll harness sampled 60 positions in 2,577,296 matching rows from a
4,536,478-entry index. The previous maximum wait was 988 ms; fresh positions after
the change had a 39 ms median and 71 ms maximum. These are viewport readiness times,
not frame rates or portable guarantees; caches and sampled paths affect them.
The regression, 1,793 Rust checks, 10 snapshot checks, and focused F9 checks passed
after a host rerun resolved sandboxed FSEvents failures.

**0.1.37:** Background searches remap selection before publishing rows. New clicks
override older refresh work, and deleted selections are cleared. Seven scenarios
and 3,309 observations had zero highlight/count gaps; all 23 live checks passed.

**0.1.38:** Trash actions resolve retained selected IDs and path identities instead
of relying on an obsolete displayed generation. Checks moved one and 130 selected
fixtures to Trash after live events and restored each file. Reused-node rejection,
engine replacement, clearing, and selection stability were also covered.

## Sorting and metadata — 0.1.39–0.1.42

- **0.1.39:** Persisted column and ascending/descending/backend order, restoring the
  header arrow too. Checks covered all 15 column/order combinations plus old or
  invalid preferences.
- **0.1.40:** Added background metadata indexing and cache-only interactive sorting.
  Workers release locks before filesystem reads and reject obsolete results, so
  blocked reads do not retain old engines. Recorded checks: 1,796 Rust passes,
  23 live checks, 16 preference/sort checks, and seven selection scenarios.
- **0.1.41:** Added reusable sorted ID orders and inverse ranks, merging small live
  updates into existing orders. Recorded validation included 1,797 Rust passes
  and 216 benchmark calls across 36 cases. Full evidence is in
  [Performance](PERFORMANCE.md#maintained-orders-0141).
- **0.1.42:** Removed the 20,000-result sorting cap, preference, and warning; old keys
  are ignored. Regression checks used 20,001 actual matches. The live harness was
  corrected to await Files-table draws only while that tab is visible, eliminating
  a false timeout during Events-tab refreshes.

## App identity and disk usage — through 0.1.52

The project became EverythingMac, using `com.everything.mac` for its bundle and
data directory. [Source provenance](DEVELOPMENT.md#source-provenance) records its origins. The
original icon was replaced in 0.1.43; the supplied orange-folder artwork was adopted
in 0.1.45. Release 0.1.52 introduced Size on disk using allocated bytes and included
copying and Dock-launch fixes. Logical size remains the basis of `size:` queries.
Preferences and indexes from separate older apps are no longer imported.

## Exclusions, shortcuts, history, and help — 0.1.53

Added compiled name/glob exclusions across scans, events, and recovery; v8 index
writes with v7 reading; a configurable Carbon activation shortcut; persistent search
history and saved states; and searchable offline help. Type-ahead suggestions were
also introduced here, then removed in 0.1.54.

Preferences uses a draft and prevents saving indexing changes during active scans.
Exclusions apply after absolute include/ignore precedence, including inside explicit
includes. Failed/cancelled rebuilds retain the previous index. Search-library load
failures preserve unreadable data rather than overwriting it.

Recorded checks: 49 native feature checks, 23 live checks, 11 snapshot checks, seven
selection updates, and five copy scenarios passed. The workspace run had 1,803 Rust
passes and two sandbox-blocked FSEvents failures; both passed in the unrestricted
SDK rerun (11/11). Five tests stayed ignored and the known system-wide cancellation
hang was excluded. Clippy and the release build passed.

Review fixes covered root-relative pruning, history-deletion races, suggestion
focus, folder-field Enter recording, and scan-time preference saving. Both final
reviews reported no outstanding findings. GitHub publication and Homebrew updating
subsequently succeeded; the old log's “not published” note describes local validation.

## Naming and UI simplification — 0.1.54

Removed automatic search suggestions and file-row full-path tooltips. Search Library
and history navigation remain. A dedicated represented-path field tracks reused
cells instead of using the tooltip as identity.

Renamed native targets, Rust crates, headers, and build variables to EverythingMac.
Startup migrates `cardinal.db` to `everything-mac.db` after taking the instance lock.
Read-only diagnostics resolve the old name without moving it. An existing new index
takes precedence; migration failures preserve the original and stop startup scanning.

Recorded checks: 401 Rust passes with one ignored test, 48 native feature checks
(including migration), 11 snapshot checks (including absent tooltips), and 10
release-safeguard checks. Workspace checking and native compilation passed. GitHub
built and verified the DMG, published it, and updated the cask with its checksum.
No new full live-suite pass is claimed for this release.

## Matching performance and documentation — 0.1.55

Exact and prefix name matching use the existing sorted tree directly. Narrowed
single-segment searches match candidate filenames and preserve the global result
order; broad scopes and path traversal retain the existing evaluation. No index
migration or preference change is required.

Same-snapshot measurements over 4.43 million entries reduced exact/prefix first-page
latency below 1 ms and improved project-folder and Documents searches; broad-scope
performance stayed effectively unchanged. See [Performance](PERFORMANCE.md) for
queries, case settings, timing boundaries, and memory measurements.

Consolidated documentation into the user guide, development guide, performance
report, and this history. Removed obsolete older-app comparison scripts.
Recorded checks: 1,252 Rust tests passed, two ignored; workspace checks, native
release compilation, and all 10 release-safeguard tests passed.

## SwiftUI lifecycle and native interface — 0.1.56–0.1.58

- **0.1.56:** Moved the Search Library button beside the Aa button, left of the search
  field. Releases began publishing their written notes directly, without changelog links.
- **0.1.57:** Adopted SwiftUI's application lifecycle for the search window and standard
  menus, with Settings in its own window that discards unsaved edits when closed. The
  results table, engine, activation shortcut, menu bar item, Quick Look, and saving
  before quit were kept. Recorded checks: 63 feature and lifecycle checks, 23 live
  checks, 11 saved-index checks, and 2 startup-icon checks.
- **0.1.58:** Required macOS 14. Row pages and file details update only changed rows;
  each row's details come from one filesystem call, and icons are cached by path.
  Polling sends the event list only to a visible, changed Events tab and slows while
  the window is hidden. Settings gained General, Index, and Privacy tabs; the Index
  menu took over Live Updates, Rescan, and Cancel Scan. Recorded checks: self, sort,
  selection, feature, live, tab, and terminal checks and the bridge tests passed;
  `--trash-check` timed out at step 23, as it already did on 0.1.57.

## Code review follow-up — 0.1.59–0.1.62

A review of the Swift app, Rust bridge, and engine on September 30, 2026 ranked
performance problems and bugs. The most important were fixed over four releases,
each validated with the workspace tests (the system-wide cancellation test excluded),
clippy, and the self, sort, selection, feature, live, tab, and terminal checks, and
published through the release workflow. `--trash-check` still times out at step 23,
as before. Measurements are in [Performance](PERFORMANCE.md).

- **0.1.59:** Background date and size indexing stopped invalidating the displayed
  results about once a second: `cn_poll` reports `metadata_changed` separately from
  structural changes, name order uses the file-type hint so it no longer shifts while
  metadata loads, and size and date orders merge larger batches instead of rebuilding.
  Snapshot writes now return flush and compression errors, sync before renaming, and
  delete the temporary file on failure; an unchanged index is not rewritten. The
  FSEvents stream is released only after it is stopped and invalidated, a stopped
  watcher still invalidates stale row IDs, and an event path that is not valid UTF-8
  no longer faults the engine. The temporary slab mapping no longer syncs to disk on
  growth or release. In the app, a failed Open Index keeps the current index, every
  file action waits for a pending selection, Trash confirms more than 50 items and
  continues past failures, and icons follow the Name column after reordering. Fat LTO
  with one codegen unit was measured and rejected: search was unchanged and index
  loading about 10% slower. Recorded checks: 1,815 Rust tests passed.
- **0.1.60:** FSEvents that only change an existing item's attributes update it in
  place instead of removing it and walking its path (for a folder, its whole
  subtree), so row IDs stay valid and the app does not repeat its search; visible rows
  refresh their sizes and dates. Name-index inserts compare ancestor chains instead of
  building paths, and removing a subtree updates each name's postings once. Case-only
  renames resolve the stored name with `getattrlist` and no longer leave duplicates.
  The selection check now also accepts a size updated in place, since file edits no
  longer start a new search. The release workflow moved to `actions/checkout` v7.0.1
  for Node 24. Recorded checks: 1,821 Rust tests passed.
- **0.1.61:** Name queries match live names in the name index, scanning key ranges in
  parallel, instead of running serially over every name ever interned. Fourteen
  queries returned identical paths in identical order compared with 0.1.60, including
  a complete 2.6-million-result list. Recorded checks: 1,824 Rust tests passed.
- **0.1.62:** Selections are node identities (slab index, per-slot generation, and
  cache instance) instead of hashed paths; selections of up to 4,096 items also keep
  paths to survive folder re-scans, and a rescan transfers only files it still finds.
  Quick Look shows at most 1,000 selected items, file actions build URLs without
  checking the filesystem, and opening more than 50 items asks for confirmation. The
  live and tab checks now expect Quick Look's 1,000-item limit. Recorded checks:
  1,826 Rust tests passed.

## Input methods — 0.1.63

Typing Chinese with Pinyin could not reliably produce characters: every SwiftUI
update of the search field read and reassigned its value, which ended the input
method's composition and committed the typed letters. The field now leaves its value
alone while marked text exists and searches only committed text, and the global key
monitor passes Return, Escape, and the arrow keys to the input method while it is
composing. A feature check drives the field editor through the same text-input calls
an input method makes; it reproduced the reset before the fix. Recorded checks: 70
feature checks and the self, sort, selection, live, tab, and terminal checks passed.

## Saving and startup memory — 0.1.64

Index saves serialize directly from the cache instead of copying the name index and
swapping out the slab, with byte-identical output. Periodic idle saves moved from every
minute to at most every 10 minutes (one minute until a new scan is first saved) and no
longer rewrite the index when only the FSEvents position advanced; quitting and
switching indexes still save it. Opening an index no longer builds all six sort orders;
each is built by the first search that needs it. zstd level 3 was measured for saves
and rejected: 9% faster for a 3.7% larger file. Recorded checks: 1,828 Rust tests
passed (the system-wide cancellation test excluded), clippy passed, and the self, sort,
selection, feature, live, tab, and terminal checks passed; `--trash-check` timed out at
step 23 as before.

## Immediate Trash updates — 0.1.65

Pressing F8 moved a file to the Trash within about 7 ms, but its row stayed in the
results for about 1.5 s: the refresh right after the action ran before macOS reported
the removal through FSEvents, and the refresh that followed the event waited for the
one-second background-refresh limit. The app now removes the paths it trashed from
the index at once through `cn_remove_paths` and refreshes immediately. The trash
check, which had timed out at step 23 since 0.1.57 because it waited for a status
message that the refresh replaced within milliseconds, now waits for the action's
completion, passes, and reports F8 timings. Recorded checks: 1,829 Rust tests passed
(the system-wide cancellation test excluded), clippy passed, and the self, sort,
selection, feature, live, tab, terminal, and trash checks passed.

## Rescans, folder walks, and other volumes — 0.1.66

A rescan ran on the app's serial engine queue and marked the index as not ready, so
searches, scrolling to unloaded rows, and file actions waited for the whole rebuild.
Scans now run on their own queue and the new index replaces the current one on the
engine queue only when it is finished; a finished scan is discarded if an index was
opened, the app closed, or the scan was cancelled meanwhile. Folders that FSEvents
report as new or changed were walked inside `cn_poll` under the engine lock with a
cancel flag that nothing set. Event handling is now split into planning, a walk that
needs no cache, and applying: `cn_poll` starts walks on a separate pool, waits up to
50 ms for small ones, and otherwise returns `walking` and applies the result on a later
poll, holding back later events until then and re-applying removals the app made
meanwhile. With the default root `/`, scans also crossed into every mounted volume, and
mounting a drive walked it inline; the index now covers the startup disk, and other
volumes are skipped unless an include path selects them. Indexes saved earlier drop
those entries on the first poll. Recorded checks: 1,837 Rust tests passed (the
system-wide cancellation test excluded), clippy passed, and the self, sort, selection,
feature, live, tab, terminal, and trash checks passed. A new rescan check measured
searches during a rescan of `/`, and a real disk image mounted inside a watched folder
stayed out of the index.

## Idle work and redraws — 0.1.67

While the search window was hidden, the app still ran the displayed search again
after each filesystem change, about every 2 s. It now keeps processing events and
defers the search and the refresh of visible rows until the window is on screen again,
using the window's occlusion state; checks count an open window as shown because other
apps may cover it. Each arrow key in the results set the selection count to zero and
back and toggled an observed loading flag, so the app's scenes and menus were
re-evaluated for every row. The count now stays until the selection reply arrives,
the menus read a separate `hasSelection`, the loading flag is not observed, and the
empty-results placeholder has its own view. A new idle check measures CPU while idle
and per arrow key, and the live check hides the window, changes a file, and confirms
the search runs again only once the window is shown. Recorded checks: 1,837 Rust
tests passed (the system-wide cancellation test excluded), and the self, sort,
selection, feature, live, tab, terminal, and trash checks passed.

## Small fixes from the review — 0.1.68

`content:` and `tag:` checked files through rayon's `par_bridge`, which returns matches
in completion order, so unsorted results changed order between runs and rows moved on
live refreshes; both now keep the order of the searched nodes, as the Spotlight path
for large tag searches also does. Case-insensitive `parent:`, `infolder:`, and
`nosubfolders:` compared folder names with ASCII case folding, and `content:` and
`tag:` lowercased ASCII only; folder names now compare with Unicode case and in either
normalization form, non-ASCII `content:` needles use a Unicode case-insensitive byte
regex, and tags use Unicode lowercase. In the app, browsing history with Option-Up/Down
recorded each entry, reordering history and rewriting its file; F2 selected the
extension because the selection was set before the alert gave the field an editor, and
a main-queue block would wait for the alert to close, so it now runs as a run-loop block
in the modal mode; the results table maps Option-Command-C to Copy Paths as the menu
does; and closing Settings while recording a shortcut left its key monitor installed,
so a modified key typed in the search window replaced the global shortcut. The feature
check reproduced the history, F2, and recorder bugs before the fixes. Two review items
did not reproduce and received defensive fixes: Dock reopen now returns `false` once
the existing window is shown, and table updates reconfigure every row view AppKit holds
rather than only the visible range (AppKit prepared no rows outside the visible area in
the checks). A query typed during a rescan was already handled by 0.1.66. Recorded
checks: 1,842 Rust tests passed (the system-wide cancellation test excluded), clippy
passed, and the self, sort, selection, feature, live, tab, terminal, and trash checks
passed.

## Names-only search — 0.1.69

`content:` opened and read every candidate file, and `tag:` read each file's Finder-tag
extended attribute or asked Spotlight, so either could make a search slow; EverythingMac
is meant to search names. Both filters were removed, together with every Everything
filter the engine never implemented (date accessed and run, `child:`, attributes,
duplicates, media properties, `case:`, `nowholefilename:`) and the parser's `Custom`
kind. The parser now recognizes only the filters the engine implements; any other
`name:` text is part of an ordinary word and is matched against names, so `content:x`
finds names containing `content:x` rather than an error. The query optimizer keeps
scope filters first, then words, then the other filters in typed order. Removed with
them: the `file-tags` crate, the cloud-placeholder skip count in search replies and
the status bar, and the content and tag tests. Recorded checks: 1,644 Rust tests passed
(the system-wide cancellation test excluded; the count fell with the removed suites),
clippy passed, and the self, sort, selection, feature, live, tab, terminal, and trash
checks passed.

## Validation boundaries

The deployment target is macOS 14; actual macOS 14 and Intel execution remain
unverified. Real cloud-provider behavior, sustained event storms, external terminal
and Double Commander integrations, and drag/drop across all target apps need broader
validation. Ad-hoc signing does not provide notarization or a stable Developer ID.
Draw proxies, sampled RSS, and historical timings are not universal guarantees.
