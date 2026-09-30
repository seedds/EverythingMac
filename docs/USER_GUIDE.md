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
| Aa button | Left of the search field; toggles case-sensitive matching. When off, names and the `parent:` and `infolder:` filters ignore case for all letters, including accented and non-Latin ones. |
| Results table | Name, Path, Size on disk, Modified, and Created columns, with resizable widths and single-line middle truncation. |
| Bottom status bar | Lifecycle state (Ready, Updating, Paused; hover for index details), Files/Events segmented control with counts, rescan, selection count, and search duration. Updating also appears while folders changed on disk are read in the background. |
| Index menu | Live Updates on/off (Paused in the status bar while off), Rescan (Option-Command-R), and Cancel Scan. |

Searches match file and folder names and paths only; they never open files or read
their contents or Finder tags. The supported filters are listed in **Help → Search &
Shortcuts**. Other text with a colon, such as `content:invoice` or `tag:work`, is
matched against names like any other word.

Enter submits a search immediately. Typing uses a **100 ms debounce** by default;
Settings → General → **Search delay** offers none, 100, and 300 ms, and is saved. Existing rows
remain visible while a replacement search runs.

Click a column header to cycle through ascending, descending, and backend order.
The chosen column and direction (including unsorted order) are saved immediately
and restored with the header arrow when the app opens again.
Column sorting applies to all matching results, with no result-count limit. The Events tab uses
the same top search field rather than adding a second search bar; it lists the latest 500
events while the tab is open. Double-click an event to open its file, or right-click
for Reveal in Finder and Copy Path.

## Keyboard and file actions

| Shortcut or interaction | Action |
| --- | --- |
| Command-F / Edit → Find | Focus search. |
| Command-1 / Command-2 | Show Files or Events. |
| Command-/ | Open searchable Search & Shortcuts help. |
| Enter in search | Submit immediately. |
| Down from search | Enter the results. |
| Up from the first result | Return to search. |
| Option-Up / Option-Down | Browse query history without reordering it. |
| Shift-arrow / Command-click | Extend or modify selection using AppKit behavior. |
| Double-click / Command-O | Open selected files. More than 50 items ask for confirmation. |
| Command-R | Reveal in Finder. |
| Space / Command-Y | Toggle Quick Look for up to 1,000 selected items. |
| Up / Down in Quick Look | Navigate results. |
| Command-C | Copy file URLs. |
| Command-Shift-C / Option-Command-C | Copy paths. |
| F2 | Rename without overwriting an existing file. The name is selected without its extension. |
| F8 | Move selected files to macOS Trash. More than 50 items ask for confirmation; items inside a selected folder go with it. |
| F9 | Open the selected folder, or a file’s parent, in the configured terminal. |
| Command-Shift-Space (default) | Toggle the app window. Record, disable, or reset the shortcut in Settings → General. |
| Escape / Close Window | Hide the window; live monitoring continues, and the results update when it is shown again. |
| Command-Q | Save the native checkpoint and quit. |

While an input method such as Pinyin is composing text in the search or folder field,
Return, Escape, and the arrow keys go to the input method, and the search runs once
you choose a character.

Open, Reveal in Finder, Quick Look, and Copy Path are also in the File menu; they
are enabled while the results table has focus and files are selected. The context
menu also provides filename copying and Double Commander reveal. Right-click the
column headers to reset column widths. Dragging results exports file URLs. Standard file icons load
lazily into a bounded cache. Search results never generate content thumbnails; Quick Look opens only when explicitly requested.

Selecting all results stays fast even across millions of files, and the selection
stays in place through searches and live updates. When a live update scans a folder
again, selections of up to 4,096 items keep their files selected. An action run right
after clicking waits for that selection instead of reporting that it is loading.

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
indexes is filled in automatically without a full rescan. File-change events keep these values current:
editing a file, or changing a folder's permissions, extended attributes, or Finder tags,
updates that item in place without repeating the search or disturbing the selection.
Hovering over the status shows **Indexing file sizes and dates…** while this work is running;
unavailable dates remain unknown. Sorting uses indexed values only, so date ordering
fills in as indexing progresses. While indexing runs, results sorted or filtered by size
or date refresh at most every 10 seconds and once more when it finishes; other results
stay in place. There is no sorting limit.
Read-only snapshot mode does not start background indexing.

Snapshot format v8 stores exclusion patterns and indexed metadata. Version 7 indexes
remain readable and upgrade on the next checkpoint; older formats must be rebuilt.
Older app versions cannot read v8 indexes. See [performance measurements](PERFORMANCE.md)
for versioned search and sorting results.

## Indexing and storage

Open **EverythingMac → Settings…** with **Command-,**.
Settings opens in its own window, so you can continue using search. It has three tabs:

- **General**: activation shortcut, search delay, appearance, menu bar icon, and the
  F9 terminal app (**Choose…** / **Reset**). These apply immediately.
- **Index**: index file and status, monitor root (**Choose…**), include/ignore paths, and exclude patterns. Edits apply only
  with **Apply & Rebuild**; **Revert** or closing the window discards them.
- **Privacy**: a link to Full Disk Access in System Settings.

Normal launch loads EverythingMac's saved index when one exists. Otherwise it
scans the configured monitor root. A saved index that cannot be read, for example
because it was damaged or cut short, is rebuilt the same way. New installations start with empty include
and ignore paths and an empty terminal application setting (F9 uses macOS Terminal).
Preferences and indexes
from older apps are not imported. If a loaded index's root/include/ignore/exclusion-pattern
configuration differs from the saved preferences, it starts a rebuild; the loaded index
stays searchable until the rebuilt one replaces it.

The index covers the startup disk. Other volumes mounted inside the monitored root are
skipped: external and network drives, disk images, Xcode Simulator runtimes, system
volumes such as Preboot and Recovery, and `/dev`. To search one, add its mount point
(such as `/Volumes/Backup`) or a folder on it to Include paths. An included volume is
indexed with the next rebuild and read in the background whenever it is mounted.
Indexes saved by 0.1.65 or earlier drop their entries from other volumes on the next
launch, without a rescan.

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

Choose a monitored root in **Settings → Index**, and use the bottom rescan button or
**Index → Rescan** to rebuild the current scope. Searching, scrolling, and file actions
keep working on the current index during a rescan, and the new index replaces it when
the scan finishes. **File → Open Index…** opens another
saved index read-only; **Index → Enable Live Updates** makes it live. A live index is
saved before switching, and if the chosen file cannot be opened the current index stays loaded. Pausing live
updates lasts until the next launch. Include paths override ignored ancestors.
If the index cannot be updated, EverythingMac rescans automatically. When such a
rescan fails or is cancelled, the status bar shows **Rescan needed** until you choose
**Rescan**.

The app processes filesystem events and writes checkpoints while idle, at most every
10 minutes (within about a minute of a new scan), and before quitting. Folders that
events report as new or changed, such as a large folder moved into place, are read in
the background; searches continue meanwhile, and the results update when reading
finishes. While the search window is hidden, minimized, on another Space, or covered by
other windows, the index stays current but the displayed search is not repeated; it
runs again as soon as the window is shown. Changes made
since the last checkpoint are replayed from macOS filesystem events on the next launch. Cancelling a scan retains the previous index. If macOS blocks
a filesystem call, cancellation releases the native engine queue while at most one
scan worker remains outstanding. Another scan must wait for that worker to finish.

### Exclusion patterns

Settings → Index has a separate **Exclude patterns** field, one rule per line:

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

**Apply & Rebuild** validates the rules and rebuilds the index. A cancelled or failed
rebuild retains the previous index and its rules. Exclusions survive checkpoint reloads
and apply to live filesystem updates.

### Search library and help

The **Search Library** button beside the search field opens named saved searches and
recent history. A saved search restores its visible query, folder scope, and case
sensitivity without changing the index root or sort order. Its menu provides rename,
update-from-current, and delete actions.

The latest 100 distinct successful searches are stored locally in `search-library.json`
beside preferences. Enter, entering results, or two seconds without editing records a
search; errors and background refreshes do not. Browsing with Option-Up/Down leaves the
history order unchanged until Enter or entering the results records the search. Individual history entries can be removed,
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

**File → Open Index…** also enters snapshot mode. **Index → Enable Live Updates** switches the
loaded index to live mode and saves subsequent checkpoints in the native store.
Missing or incompatible snapshots produce an actionable error without starting a
scan.

“Read-only” describes the **index**, not the files represented by it. File actions
still operate on real files, and size and date filters can still read sizes and dates
from disk for items the index has none for. A snapshot is not a frozen copy of file
contents.

## Permissions and troubleshooting

EverythingMac needs its own filesystem permissions. For protected locations,
enable it under **System Settings → Privacy & Security → Full Disk Access**, then
relaunch. The app provides permission guidance and a link to System Settings.

If the activation shortcut is already registered by another app, EverythingMac reports
the conflict. Record an alternative in Settings → General. A failed replacement keeps the working shortcut.

Releases are ad-hoc signed rather than signed with a stable Developer ID or notarized.
Replacing the app can require renewed macOS permission approval. Launch the installed
copy from `/Applications`; a locally built copy can have a different version and signature.
