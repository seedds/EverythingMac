# User guide

[Home](../README.md) · [Development](DEVELOPMENT.md)

## Search interface

The app is English-only, with no language setting or bundled translations.

The layout follows the original Cardinal app: **one search row, a full-width
results table, and a compact bottom status bar**.

| Area | Purpose |
| --- | --- |
| Main search field | Search filenames, or filter recent events when Events is selected. |
| Folder scope field | Always visible to the right of the search field. Filters file results by folder; clear it to remove the filter. Disabled on the Events tab. |
| Search Library button | Left of the search field, beside Aa; browse saved searches and recent history. |
| Aa button | Left of the search field; toggles case-sensitive matching. |
| Results table | Name, Path, Size on disk, Modified, and Created columns, with resizable widths and single-line middle truncation. |
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

## Keyboard and file actions

| Shortcut or interaction | Action |
| --- | --- |
| Command-F | Focus search. |
| Command-/ | Open searchable Search & Shortcuts help. |
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
| Command-Shift-Space (default) | Toggle the app window. Record, disable, or reset the shortcut in Preferences. |
| Escape / Close Window | Hide the window; live monitoring continues. |
| Command-Q | Save the native checkpoint and quit. |

The context menu also provides filename copying, Double Commander reveal, and
column-width reset. Dragging results exports file URLs. Standard file icons load
lazily into a bounded cache. Search results never generate content thumbnails; Quick Look opens only when explicitly requested.

Scrolling loads filenames and paths directly from the index. Size and dates load
from indexed metadata, with a separate visible-row fallback while indexing is incomplete;
slow filesystem metadata cannot hold up a whole page.
Metadata requests for rows that scroll out of view are cancelled when possible.

The **Size on disk** column displays and sorts by allocated bytes (`st_blocks × 512`),
so sparse disk images show their disk usage rather than their virtual capacity.
Directories show a dash; their contents are not summed. This is filesystem-reported
allocation, not exclusive space reclaimable from APFS clones or snapshots.
`size:` search filters continue to use logical file size.

Modified and Created dates (plus logical and allocated sizes from the same metadata read) are indexed in
the background and saved in the native checkpoint. Missing metadata in current-format
indexes is filled in automatically without a full rescan. File-change events keep these values current.
The index details popover shows **Indexing file sizes and dates…** while this work is running;
unavailable dates remain unknown. Sorting uses indexed values only, so date ordering
fills in as indexing progresses. There is no sorting limit.
Read-only snapshot mode does not start background indexing.

Snapshot format v8 stores exclusion patterns and indexed metadata. Version 7 indexes
remain readable and upgrade on the next checkpoint; older formats must be rebuilt.
Older app versions cannot read v8 indexes. See [performance measurements](PERFORMANCE.md)
for versioned search and sorting results.

## Indexing and storage

Open **EverythingMac → Settings…** with **Command-,** or the gear button.
Settings opens in its own window, so you can continue using search. **Save**
applies changes; **Cancel** or closing the window discards unsaved edits.
On macOS 12, the system menu calls this **Preferences…**.

Normal launch loads EverythingMac's saved index when one exists. Otherwise it
scans the configured monitor root. New installations start with empty include
and ignore paths and an empty terminal application setting (F9 uses macOS Terminal).
Preferences and indexes
from older apps are not imported. If a loaded index's root/include/ignore/exclusion-pattern
configuration differs from the saved preferences, it starts a rebuild.

Native data is stored separately:

```text
~/Library/Application Support/com.everything.mac/
├── everything-mac.db
├── preferences.json
└── search-library.json
```

The original Cardinal index and preferences are not overwritten.

Existing EverythingMac installations migrate the old index filename to
`everything-mac.db` on normal startup. Read-only snapshot and diagnostic runs can
still open the old filename without changing it. An existing `everything-mac.db`
takes precedence; migration failures preserve the old file and stop startup scanning.

Use **Index folder…** in Index details to choose a monitored root, and the bottom
rescan button to rebuild the current scope. Preferences contains include/ignore
paths, appearance, menu bar visibility, and terminal application. Include paths override ignored ancestors.

The app processes filesystem events and writes checkpoints during idle intervals
and before quitting. Cancelling a scan retains the previous index. If macOS blocks
a filesystem call, cancellation releases the native engine queue while at most one
scan worker remains outstanding. Another scan must wait for that worker to finish.

### Exclusion patterns

Preferences has a separate **Exclude patterns** field, one rule per line:

```text
node_modules
*.log
**/build/**
```

Names match at any depth. Patterns containing `/` are relative to the monitor root:
`build/**` excludes that root's build folder, while `**/build/**` excludes build folders
at any depth. A trailing `/` matches directories only. `*`, `?`, `**`, character classes,
and brace alternatives use glob syntax. Patterns are case-sensitive, prune matching
directory trees, and still apply inside explicit Include paths. Absolute paths belong
in Include/Ignore paths. No patterns are enabled by default.

**Save and Rebuild** validates the rules and rebuilds the index. A cancelled or failed
rebuild retains the previous index and its rules. Exclusions survive checkpoint reloads
and apply to live filesystem updates.

### Search library and help

The **Search Library** button beside the search field opens named saved searches and
recent history. A saved search restores its visible query, folder scope, and case
sensitivity without changing the index root or sort order. Its menu provides rename,
update-from-current, and delete actions.

The latest 100 distinct successful searches are stored locally in `search-library.json`
beside preferences. Enter, entering results, or two seconds without editing records a
search; errors and background refreshes do not. Individual history entries can be removed,
and Clear History preserves saved searches. Unreadable library files are preserved and
reported rather than overwritten.

**Down** enters results; **Option-Up/Down** navigates recent history.

**Help → Search & Shortcuts** (Cmd-/) provides an offline searchable reference with
copyable, runnable examples and the currently configured activation shortcut.

### Snapshot mode

To search an index without monitoring the filesystem or writing an index:

```bash
./run.sh --snapshot --index /absolute/path/to/everything-mac.db
```

**Choose index…** also enters snapshot mode. **Enable live updates** switches the
loaded index to live mode and saves subsequent checkpoints in the native store.
Missing or incompatible snapshots produce an actionable error without starting a
scan.

“Read-only” describes the **index**, not the files represented by it. File actions
still operate on real files, and metadata/content queries retain the engine’s
existing filesystem reads. A snapshot is not a frozen copy of file contents.

## Permissions and troubleshooting

EverythingMac needs its own filesystem permissions. For protected locations,
enable it under **System Settings → Privacy & Security → Full Disk Access**, then
relaunch. The app provides permission guidance and a link to System Settings.

If the activation shortcut is already registered by another app, EverythingMac reports
the conflict. Record an alternative in Preferences. A failed replacement keeps the working shortcut.

Releases are ad-hoc signed rather than signed with a stable Developer ID or notarized.
Replacing the app can require renewed macOS permission approval. Launch the installed
copy from `/Applications`; a locally built copy can have a different version and signature.
