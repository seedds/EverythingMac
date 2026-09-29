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

## Validation boundaries

The deployment target is macOS 12; actual older-macOS and Intel execution remain
unverified. Real cloud-provider behavior, sustained event storms, external terminal
and Double Commander integrations, and drag/drop across all target apps need broader
validation. Ad-hoc signing does not provide notarization or a stable Developer ID.
Draw proxies, sampled RSS, and historical timings are not universal guarantees.
