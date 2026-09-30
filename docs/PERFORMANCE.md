# Performance

[Home](../README.md) · [Development](DEVELOPMENT.md) · [History](HISTORY.md)

## Reading these results

These are workstation measurements. The 0.1.60–0.1.64 studies cover live updates,
parallel name matching, large selections, and saving and startup memory; the other matching study covers the
0.1.55 changes, and the versioned sorting studies cover historical releases.
The sorting studies used an Apple M4 Pro (14 cores, 48 GiB RAM) on macOS 27.0.
Search/sort times exclude index opening and UI rendering unless a table says otherwise.
An empty query can be faster than a filtered query because it avoids substring matching.

| Study | What it establishes |
| --- | --- |
| [Saving and startup memory, 0.1.64](#saving-and-startup-memory-0164) | Opening 4,573,469 entries fell from 2.67 s and 818 MiB to 2.15 s and 538 MiB; each index save holds the engine for about 340 ms instead of 415–440 ms and needs 188 MiB less extra memory, and idle saves happen at most every 10 minutes. |
| [Large selections, 0.1.62](#large-selections-0162) | Selecting all 4,573,469 results fell from about 2.8 s and 239 MiB to 37 ms and 70 MiB, and restoring that selection after a search from about 4 s to about 70 ms. |
| [Parallel name matching, 0.1.61](#parallel-name-matching-0161) | Unscoped case-insensitive name queries fell from 26–188 ms to 3–10.5 ms on 4,573,469 entries, with identical ordered results; folder-scoped queries gained less, and exact/prefix lookups, the all-files query, and index loading were unchanged. |
| [Live updates, 0.1.60](#live-updates-0160) | An attribute change on a 167,000-item app bundle fell from 1.24 s plus a 170 ms re-sort to under 1 ms with no re-sort; file edits no longer repeat the search. |
| [Maintained orders, 0.1.41](#maintained-orders-0141) | Search, sort, and first-page retrieval over 4,621,437 entries took about 18–19 ms for the empty query; the 2.58-million-match filtered query took about 187–194 ms on first calls. Index opening and preparation took about 2.73 s. |
| [Indexed metadata, 0.1.40](#indexed-metadata-0140) | Removing filesystem reads eliminated large waits, but full-index sorts still took roughly 2.8–3.3 s. |
| [Original sorting, 0.1.39](#original-sorting-0139) | Broad uncapped sorts stalled on filesystem reads; some runs timed out before producing results. |

Version 0.1.42 removed the sorting cap. References to a 20,000-result cap below
apply only to the historical versions. The 0.1.40 and 0.1.41 sorting studies use
the same snapshot; the 0.1.39 study uses a different one. Do not calculate precise
cross-snapshot speedup ratios. No Windows Everything baseline was measured.

## Saving and startup memory (0.1.64)

Measured on 2026-09-30 on the same read-only copy of the **4,573,469-entry
snapshot**, comparing 0.1.63 with 0.1.64 and alternating builds. Opening and search
figures come from `scripts/benchmark-sort.swift` (three processes per sort, each with
one initial and three measured searches of all files). Save figures come from a
temporary Swift probe, not included in the repository, that opened the copy, pointed
its checkpoint at a scratch file, and timed one `cn_checkpoint` call while sampling
memory every 5 ms (three processes per build).

| Measurement | 0.1.63 | 0.1.64 |
| --- | ---: | ---: |
| Open the index | 2,668–2,675 ms | 2,139–2,158 ms |
| Memory after opening | 818–819 MiB | 538 MiB |
| First search after opening, unsorted | 17.4 ms | 17.6 ms |
| First search after opening, sorted by name | 18.0 ms | 167.2 ms |
| First search after opening, sorted by date modified | 17.7 ms | 270.7 ms |
| Repeated searches | 17.3–17.7 ms | 17.2–17.9 ms |
| Peak memory during the searches (unsorted / name / date) | 894 / 893 / 893 MiB | 614 / 684 / 788 MiB |
| One index save, holding the engine | 413–439 ms | 339–343 ms |
| Extra memory during the save | 334–335 MiB | 187–188 MiB |
| Saved file | 84.6 MB | 84.6 MB |

Version 0.1.63 built all six sort orders while opening, including one the app never
uses. Version 0.1.64 builds an order on the first search that needs it, so the first
sorted search pays for that column once; opening plus a first name-sorted search
still finishes about 390 ms sooner. Saves now serialize from the cache without first
copying the name index. The saved bytes are unchanged. Compression level 3 was also
measured: it saved about 9% of the save time and produced a 3.7% larger file, so
level 6 was kept.

## Large selections (0.1.62)

Measured on 2026-09-30 on a read-only copy of the **4,573,469-entry snapshot** used
for the 0.1.61 study, on the workstation described above. A temporary Swift probe,
not included in the repository, called the bridge's C interface directly: it
searched all files, selected every result, repeated the search to force a selection
remap, and requested selected paths. Each build ran two or three times in separate
processes; the table shows the range.

| Operation | 0.1.61 | 0.1.62 |
| --- | ---: | ---: |
| Select all results (`cn_select`) | 2,770–2,803 ms, +239–240 MiB RSS | 37 ms, +70–71 MiB RSS |
| Restore the selection after a new search (`cn_selected`) | 3,966–4,071 ms | 68–74 ms |
| Selected paths for Quick Look (`cn_selection_paths`) | 5,089–5,297 ms, all 4,573,469 paths | 0.7 ms, first 1,000 paths |
| Restore a single selected row after a search | 18.9–19.4 ms | 1.4–1.7 ms |

Version 0.1.61 built a path, two SipHash digests, and a hash-set entry for every
selected row, and rebuilt the path of every selected node on each remap. Version
0.1.62 stores a slab index and per-slot generation for each selected node and marks
survivors in a bitset. Quick Look requests at most 1,000 paths; explicit file actions
still request all of them.

Search and index loading were unchanged. The all-files, name-sorted view ran at
17–25 ms per process in both builds with the same number of instructions retired;
individual processes settle into faster or slower modes, so single runs of that case
are not comparable.

## Parallel name matching (0.1.61)

Measured on 2026-09-30 on the same read-only copy of a **4,573,469-entry snapshot**,
on the workstation described above, comparing the 0.1.60 bridge with 0.1.61, which
matches live names in the name index, scanning key ranges in parallel. Previously a
case-insensitive query ran its regex serially over every name the process had
interned, collected matches into a sorted set, and looked each one up again.

Each query ran in a fresh process with `scripts/benchmark-sort.py` (one initial call
and five measured calls) or the benchmark binary directly for the folder and
case-sensitive rows (one initial and six measured calls). Each build ran twice,
alternating; the table reports the median of the two per-run medians of first-page
time, which includes search, the stated sort, and retrieving the first 128 rows.
Index loading, typing debounce, and UI rendering are excluded. No builds or other
benchmarks ran concurrently.

| Query | Folder query | Case sensitive | Sort | Matches | 0.1.60 | After |
| --- | --- | --- | --- | ---: | ---: | ---: |
| `a` | None | No | Name | 2,637,710 | 188.30 ms | 10.45 ms |
| `a` | None | No | None | 2,637,710 | 180.82 ms | 3.02 ms |
| `.py` | None | No | Name | 507,270 | 48.78 ms | 7.32 ms |
| `.js` | None | No | Name | 124,879 | 35.88 ms | 4.44 ms |
| `.swift` | None | No | Name | 43,931 | 33.73 ms | 4.12 ms |
| `everything-mac` | None | No | Name | 193 | 26.05 ms | 3.19 ms |
| `swift` | `/Users/` | No | Name | 18,799 | 65.90 ms | 29.13 ms |
| `swift` | `/Documents/` | No | Name | 10,719 | 29.92 ms | 24.34 ms |
| `rs` | `/everything_mac/` | No | Name | 2,734 | 8.49 ms | 3.17 ms |
| `/Cargo.toml/` | None | Yes | Name | 646 | 0.29 ms | 0.30 ms |
| `/Cargo` | None | Yes | Name | 1,542 | 0.31 ms | 0.30 ms |
| (all files) | None | No | Name | 4,573,469 | 18.12 ms | 17.61 ms |

Index loading took a median of 2,675 ms before and 2,696 ms after; the difference
is within run-to-run variation. Exact and prefix lookups were already direct and did
not change. Folder-scoped queries gain less because much of their time is spent
enumerating the folder scope rather than matching names.

For fourteen queries, including the complete 2,637,710-result `a` lists with and
without name sorting, wildcard, Unicode, case-sensitive, and folder-scoped cases,
every result path and its position were identical between the two builds.

## Live updates (0.1.60)

Measured on 2026-09-30 with temporary Rust programs, not included in the
repository, that link the engine directly and time `handle_fs_events`, comparing the
0.1.59 engine with 0.1.60. The first two rows load the same **4,573,469-entry**
snapshot and send synthetic events for files that exist but have not changed, so
the filesystem is only read. "Next search" is a name-sorted search of every file
immediately afterwards, which includes any sort-order rebuild caused by the events.

| Events | 0.1.59 | 0.1.60 |
| --- | ---: | ---: |
| `ItemXattrMod` on `/Applications/Xcode.app` (about 167,000 items) | 1,197–1,243 ms, next search 165–171 ms, results invalidated | under 1 ms, next search 18.6 ms, results kept |
| `ItemModified` for 10,000 files under `/usr/share` | 135–198 ms, next search 170–174 ms, results invalidated | 107 ms, next search 18.4 ms, results kept |

The remaining rows use a synthetic tree in a temporary folder and report medians of
five runs per build (ten for the last row), alternating builds.

| Events | 0.1.59 | 0.1.60 |
| --- | ---: | ---: |
| `ItemModified` for 10,000 edited files in 100 folders | 68.8 ms | 18.7 ms |
| `ItemInodeMetaMod` after `chmod` on a folder of 50,000 files | 131.9 ms | under 0.1 ms |
| Removing a folder with 20,000 `index.js` files (40,000 indexed) | 71.1 ms | 8.7 ms |
| Creating a folder with 5,000 more `index.js` files | 95.2 ms | 74.5 ms |

Before 0.1.60, every event for an existing item removed it and walked the path
again, including a folder's entire subtree, and the bridge reported a structural
change that made the app repeat its search. Attribute-only events now update the
item in place; creations, removals, and renames still walk the path.

## Exact, prefix, and scoped matching (2026-09-29)

Measured before and after the matching changes on the same read-only copy of a
**4,428,647-entry snapshot**, on the workstation described above. Both binaries
use the current native bridge; no older app or Tauri baseline is involved.
Each query ran in a fresh process, with one initial call followed by six measured
calls. The table reports the median of those six calls, including filename sorting
and retrieving the first 128 rows. Index loading, typing debounce, and UI rendering
are excluded. Builds and benchmark processes did not overlap during these runs.

| Query | Folder query | Case sensitive | Matches | Before | After |
| --- | --- | --- | ---: | ---: | ---: |
| `/Cargo.toml/` | None | Yes | 634 | 4.78 ms | 0.31 ms |
| `/Cargo` | None | Yes | 1,530 | 9.60 ms | 0.34 ms |
| `rs` | `/everything_mac/` | No | 2,261 | 39.97 ms | 8.78 ms |
| `swift` | `/Documents/` | No | 10,717 | 51.42 ms | 29.46 ms |
| `swift` | `/Users/` | No | 18,797 | 65.57 ms | 65.88 ms |

Folder queries match directory names using the engine's existing scope semantics;
they are not absolute-path restrictions. Exact and prefix tree lookups apply to
case-sensitive plain matchers. Scoped single-segment matching also supports the
existing Unicode-aware case-insensitive, wildcard, and regex matchers. Multi-segment
paths and globstars retain their traversal behavior. Broad candidate sets retain
global matching, explaining the effectively unchanged broad-scope result.

No persistent auxiliary index was added. Loaded RSS ranged from 789–799 MiB after
versus approximately 799 MiB before. Query peak RSS was 793–879 MiB after versus
803–890 MiB before; process-to-process RSS variation prevents attributing those
small differences to the change. The largest additional query allocation was
about 90 MiB in both versions, for the broad scope.

The current bridge benchmark accepts optional folder scope and case sensitivity:

```bash
/tmp/everything-mac-sort-benchmark /absolute/path/to/snapshot.db \
  /Cargo.toml/ filename 7 /tmp/exact.json '' true
/tmp/everything-mac-sort-benchmark /absolute/path/to/snapshot.db \
  swift filename 7 /tmp/scoped.json /Documents/ false
```

Omitting the two optional arguments keeps the original unscoped, case-insensitive
behavior. Differential tests compare ordered results with global matching, including
duplicate basenames, empty scopes, Unicode, Boolean expressions, cancellation,
and create/rename/delete events. The affected Rust suites passed 1,252 tests with
two ignored tests; workspace checks and the native release build also passed.

## Measuring the current app

Run from the repository root after building; use a fixed copied snapshot and fresh
output paths. Do not run builds or competing benchmarks during a measurement.

```bash
./run.sh --build-only
cp "$HOME/Library/Application Support/com.everything.mac/everything-mac.db" \
  build/benchmark-index.db
python3 scripts/measure.py \
  build/benchmark-index.db build/native.json
```

For backend and selection-resolution probes:

```bash
./run.sh --probe --index /absolute/path/to/everything-mac.db
./run.sh --probe --selection-probe \
  --index /absolute/path/to/everything-mac.db
```

Draw callbacks are rendering proxies, not physical display measurements. Report
filename display separately from icon completion. RSS covers only the EverythingMac
process and does not equal its physical memory footprint. Avoid competing builds or
benchmarks, and report typing delay separately from search execution time.

`python3 scripts/check-render.py build/native.json` checks rendering overhead and
sampled RSS against fixed-snapshot development budgets. Those thresholds depend on
the snapshot and machine; they are not portable product guarantees.

For current search/sort/first-page timings with the Rust bridge:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
CARGO_PROFILE_RELEASE_STRIP=none cargo build --locked --release \
  -p everything-mac-native-prototype --lib --example metadata_inventory --example sort_index_updates
swiftc -O -module-cache-path /tmp/everything-mac-sort-module-cache -I Sources/CNative \
  scripts/benchmark-sort.swift -L target/release -leverything_mac_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/everything-mac-sort-benchmark
python3 scripts/benchmark-sort.py /tmp/everything-mac-sort-benchmark \
  build/benchmark-index.db build/sort-measurement --timeout 90
```

Inspect each case's status and metadata coverage; a timeout is not a completed timing.
The current runner has no sorting-cap argument and uses `everything-mac` as its small
query. Historical commands below use the original crate names and query text; run
them only against the stated historical source. Private snapshots and generated raw
outputs are ignored by Git and are not distributed with these reports. Exact counts
require the original snapshot; use your own copied index for a comparable new study.

## Maintained orders 0.1.41

Historical source: [`886fbb6`](https://github.com/seedds/EverythingMac/tree/886fbb6).
Run this section’s reproduction commands in a separate checkout of that commit.

Historical report for 0.1.41. Version 0.1.42 removes the sorting cap and its setting. To reproduce these historical capped comparisons, use the scripts and code from the corresponding release tag.

Measured on 2026-09-28 on the same M4 Pro (14 cores, 48 GiB RAM, macOS 27.0) and the exact same fully indexed **4,621,437-entry snapshot** as the 0.1.40 benchmark. The default 20,000-result cap and saved preferences are unchanged; uncapped measurements use the benchmark API only.

### First sort after opening

Times include search, sorting, and retrieval/JSON decoding of the first 128 rows. Snapshot opening/index preparation and UI rendering are excluded here and reported separately below. Each case opens a fresh process, runs once, then repeats five times. All sorts are ascending.

| Matches | Name | Path | Size | Modified | Created |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 8,076 | 30.7 ms | 31.4 ms | 29.8 ms | 30.5 ms | 29.3 ms |
| 43,468 | 34.3 ms | 32.7 ms | 34.2 ms | 34.8 ms | 34.1 ms |
| 127,117 | 37.0 ms | 37.1 ms | 45.7 ms | 38.6 ms | 37.4 ms |
| 503,184 | 51.2 ms | 50.0 ms | 52.8 ms | 51.7 ms | 50.0 ms |
| 2,580,929 | 189.1 ms | 188.1 ms | 194.0 ms | 194.2 ms | 186.6 ms |
| 4,621,437 | 18.6 ms | 18.0 ms | 18.9 ms | 18.7 ms | 18.6 ms |

The empty all-files query avoids substring matching, so it can finish faster than smaller filtered searches.

### Same-snapshot comparison: all 4.62 million entries

| Column | Previous first sort | New first sort | First-sort speedup | Previous repeat median | New repeat median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Name | 2796.3 ms | 18.6 ms | 150× | 2639.3 ms | 17.8 ms |
| Modified | 3310.7 ms | 18.7 ms | 177× | 3095.2 ms | 18.6 ms |
| Created | 3325.6 ms | 18.6 ms | 179× | 3187.1 ms | 18.0 ms |

Repeat CPU medians for all files: Name 17.9 ms, Path 17.7 ms, Size 19.1 ms, Modified 18.3 ms, Created 18.0 ms.
Across the five all-files sorts, repeat samples ranged from 17.5 to 32.6 ms.

For the 2,580,929-match `a` query, repeat medians are Name 182.5 ms, Path 187.0 ms, Size 188.7 ms, Modified 186.0 ms, Created 183.4 ms. Most of this is query matching: the capped comparison, which skips sorting at this size, takes 175.8 ms. Different result orderings must not be treated as equivalent outputs.

### Startup and memory tradeoff

- Median snapshot opening, including index preparation: **2.12 s → 2.73 s** (about 0.62 s extra per launch).
- Median RSS immediately after opening: **489 → 737 MiB** (about 248 MiB extra resident memory).
- Peak sampled RSS over all measured search/sort cases: **3312 → 851 MiB** (3.23 → 0.83 GiB).
- Peak sampled RSS during the new startup: **738 MiB**. The old harness did not sample startup peak.
- Five ID orders plus five inverse-rank arrays use approximately 40 bytes per slab slot, or 176 MiB for this snapshot, excluding allocator overhead and temporary build buffers.

The tradeoff is deliberate: retain orders in memory and construct them once per launch, instead of allocating multiple paths and sort records per matching file on every search. Orders are derived from the snapshot; the snapshot format is unchanged. RSS is sampled every 10 ms, so very brief peaks may be missed. These figures are for the benchmark process, not total GUI application memory.

### First sort after a file event

The maintenance harness loads the same snapshot, then sends a normal file-modified event for the existing repository `Cargo.toml` before every measurement. It only rereads metadata; neither the source file nor the source snapshot is modified. Each column has six event/search/sort cycles. This measures a single-file update, not a mass rescan.

| Column | Median event processing | Median following search + sort |
| --- | ---: | ---: |
| Filename | 0.06 ms | 22.2 ms |
| FullPath | 0.05 ms | 21.1 ms |
| Size | 0.06 ms | 23.6 ms |
| Mtime | 0.06 ms | 21.7 ms |
| Ctime | 0.06 ms | 21.6 ms |

Small changes remove obsolete IDs and merge the changed entries into the existing order. Binary searches locate insertion points, avoiding path comparisons against every unchanged entry. More than 8,192 accumulated dirty IDs marks an order for rebuilding; a bulk backfill or rescan can therefore make its next sort slower than the steady-state numbers above.

### Correctness and limits

- 1,797 Rust tests passed, including comparison against the previous independent comparator for all five columns in both directions. The fixture exercises sparse/broad/all results, punctuation and Unicode paths, unknown metadata, timestamp/size ties, small updates, more than 8,192 metadata updates, renamed/deleted/recreated subtrees, recycled IDs, and checkpoint reopening.
- Native UI checks passed: 23 live workflows, 16 sorting-preference checks, and seven selection-update scenarios with no observed selection gaps. Workspace Clippy completed without warnings.
- 216 benchmark calls completed across 36 cases. The production sorting cap remains 20,000, with no preference changes.
- This establishes Everything-style reuse of sorted indexes and millisecond sorting on this Mac. It does **not** establish exact parity with Everything on Windows: no Windows/Everything baseline was measured. It also does not benchmark first filesystem discovery, cloud-provider stalls, or mass event storms.

### Reproduction

Snapshot: `build/indexed-sort-benchmark/current-source.db`, SHA-256 `81d2fc0a7154aa1c625ae80b823896a799c082d0abfa6c046fc419262def40b3`. Metadata coverage is recorded in [indexed metadata study](#indexed-metadata-0140). The snapshot and generated raw measurements remain local, excluded from Git.

```bash
export PATH="$HOME/.cargo/bin:$PATH"
CARGO_PROFILE_RELEASE_STRIP=none cargo build --locked --release \
  -p cardinal-native-prototype --lib --example sort_index_updates
swiftc -O -module-cache-path /tmp/everything-mac-sort-module-cache -I Sources/CNative \
  scripts/benchmark-sort.swift -L target/release -lcardinal_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/everything-mac-maintained-sort-benchmark
python3 scripts/benchmark-sort.py /tmp/everything-mac-maintained-sort-benchmark \
  build/indexed-sort-benchmark/current-source.db \
  build/maintained-sort-benchmark/final --timeout 90
target/release/examples/sort_index_updates \
  build/indexed-sort-benchmark/current-source.db Cargo.toml \
  > build/maintained-sort-benchmark/updates.json
```

## Indexed metadata 0.1.40

Historical source: [`9d3bd31`](https://github.com/seedds/EverythingMac/tree/9d3bd31).
Run this section’s reproduction commands in a separate checkout of that commit.

Historical measurements below retain the upstream Cardinal query text; current benchmark scripts use `everything-mac`.

Historical report for 0.1.40. Version 0.1.42 removes the sorting cap and its setting. To reproduce these historical capped comparisons, use the scripts and code from the corresponding release tag.

Measured on 2026-09-28 using the user's real, fully backfilled index. Indexed sorting removes the earlier filesystem stalls, but sorting millions of matches still takes seconds and substantially increases memory use. The app's sorting limit and preferences were not changed.

### First sort after opening the indexed snapshot

Times include search, sorting, and retrieval/JSON decoding of the first 128 results, excluding snapshot loading and UI rendering. All timings below are uncapped ascending sorts. The three columns used separate fresh processes, each followed by five repeat calls.

| Matches | Name | Modified | Created |
| ---: | ---: | ---: | ---: |
| 8,076 | 33 ms | 32 ms | 34 ms |
| 43,468 | 55 ms | 58 ms | 58 ms |
| 127,117 | 105 ms | 111 ms | 112 ms |
| 503,184 | 328 ms | 380 ms | 414 ms |
| 2,580,929 | 1.75 s | 2.00 s | 2.04 s |
| 4,621,437 | 2.80 s | 3.31 s | 3.33 s |

For all 4.62 million rows, repeat medians were 2.64 seconds by Name, 3.10 seconds by Modified, and 3.19 seconds by Created. Peak benchmark-process RSS reached approximately **3.23 GiB**, versus **0.59 GiB** for the capped all-files case, an increase of about 2.65 GiB. The current cap returns that all-files page in about 18 ms on its first call and 17 ms on repeats, because it skips sorting above 20,000 matches. These are different result-ordering behaviors, not equivalent sorted outputs.

### Comparison with the previous unindexed benchmark

The earlier 0.1.39 Name test on 2.59 million matches had not returned after more than 160 seconds of search time, and the 4.61-million-entry case had not returned after more than 55 seconds. The 0.1.40 indexed equivalents completed in 1.75 and 2.80 seconds. At roughly 127,000 matches, the previous first Name sorts took 6.45–12.83 seconds; the indexed first call now took 105 ms. At roughly 503,000 matches, the previous first Name sorts took 4.35–7.58 seconds; the indexed call now took 328 ms.

These comparisons use the same machine and harness but snapshots from different times. The original had 4,610,087 entries; the current copy has 4,621,437. They demonstrate the removal of the large observed filesystem wait, but they are not exact same-dataset speedup ratios. The old million-row stalls were Name tests; they must not be presented as measured old Modified/Created timings. The full earlier report is in [original sorting study](#original-sorting-0139).

### Metadata coverage

The inventory tool examined all matching entries before benchmarking. No metadata reads from indexed files were made by the inventory or timing harness. **Zero entries were pending metadata collection.** Fully indexed means that metadata collection has completed; some files can still have unavailable dates.

| Query | Matches | Pending metadata | Unavailable metadata | Modified known | Created known |
| --- | ---: | ---: | ---: | ---: | ---: |
| `cardinal` | 8,076 | 0 | 0 | 8,076 | 8,076 |
| `.swift` | 43,468 | 0 | 0 | 43,468 | 43,468 |
| `.js` | 127,117 | 0 | 0 | 127,117 | 127,117 |
| `.py` | 503,184 | 0 | 0 | 503,184 | 503,184 |
| `a` | 2,580,929 | 0 | 30 | 2,580,876 | 2,580,840 |
| `` | 4,621,437 | 0 | 39 | 4,621,357 | 4,620,986 |

Across the full index, Modified is available for 99.9983% of entries and Created for 99.9902%. Unknown timestamps were left unknown and sorted according to the existing comparator; no dates were fabricated. Every `.swift`, `.js`, `.py`, and `cardinal` match has both dates. The initial page can contain unknown dates because ascending sorting places missing values first.

### Complete timing and memory results

All timing columns are milliseconds. Repeat statistics use the five calls following the first call in each fresh process. CPU is process user+system time. Peak resident memory is sampled every 10 ms and at endpoints; short-lived peaks can be missed. This measures the harness and engine, not the entire GUI application. Loaded-engine RSS was approximately 489 MiB in each process.

| Matches | Sort | Limit | First ms | Repeat median ms | Repeat range ms | Repeat CPU ms | Peak RSS MiB |
| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 8,076 | Name | 20,000 | 32.0 | 31.4 | 31.0–32.3 | 31.5 | 498 |
| 8,076 | Name | Uncapped | 33.3 | 32.5 | 32.4–33.1 | 32.6 | 498 |
| 8,076 | Modified | Uncapped | 32.3 | 32.2 | 32.0–32.6 | 32.2 | 498 |
| 8,076 | Created | Uncapped | 33.9 | 31.9 | 31.8–32.6 | 32.0 | 500 |
| 43,468 | Name | 20,000 | 33.0 | 30.7 | 30.6–32.0 | 30.7 | 494 |
| 43,468 | Name | Uncapped | 55.4 | 51.7 | 51.3–53.0 | 51.8 | 522 |
| 43,468 | Modified | Uncapped | 58.1 | 56.7 | 55.8–58.8 | 56.8 | 523 |
| 43,468 | Created | Uncapped | 58.2 | 56.2 | 55.3–56.7 | 56.2 | 524 |
| 127,117 | Name | 20,000 | 35.7 | 33.8 | 33.8–34.2 | 33.9 | 497 |
| 127,117 | Name | Uncapped | 105.0 | 99.0 | 96.7–104.6 | 99.2 | 558 |
| 127,117 | Modified | Uncapped | 111.2 | 104.8 | 103.7–107.6 | 104.9 | 560 |
| 127,117 | Created | Uncapped | 111.8 | 105.1 | 103.2–109.8 | 105.2 | 560 |
| 503,184 | Name | 20,000 | 45.0 | 42.5 | 42.3–46.1 | 42.6 | 502 |
| 503,184 | Name | Uncapped | 327.8 | 302.6 | 299.6–315.8 | 303.0 | 755 |
| 503,184 | Modified | Uncapped | 380.2 | 355.3 | 352.0–370.7 | 355.8 | 757 |
| 503,184 | Created | Uncapped | 413.9 | 355.3 | 354.4–364.9 | 355.7 | 754 |
| 2,580,929 | Name | 20,000 | 167.0 | 161.2 | 161.0–166.9 | 161.4 | 578 |
| 2,580,929 | Name | Uncapped | 1747.7 | 1600.0 | 1582.9–1688.7 | 1602.2 | 2175 |
| 2,580,929 | Modified | Uncapped | 1996.5 | 1875.0 | 1864.1–1977.5 | 1877.7 | 2120 |
| 2,580,929 | Created | Uncapped | 2044.2 | 1883.3 | 1865.7–1965.0 | 1886.0 | 2170 |
| 4,621,437 | Name | 20,000 | 18.4 | 16.7 | 16.4–17.0 | 16.8 | 600 |
| 4,621,437 | Name | Uncapped | 2796.3 | 2639.3 | 2568.6–2694.4 | 2642.9 | 3312 |
| 4,621,437 | Modified | Uncapped | 3310.7 | 3095.2 | 3083.1–3222.4 | 3099.8 | 3312 |
| 4,621,437 | Created | Uncapped | 3325.6 | 3187.1 | 3109.5–3229.3 | 3191.6 | 3312 |

Repeat CPU time closely tracks elapsed time in the million-row cases: this workload is now dominated by CPU/memory work, rather than the long filesystem wait seen before. The current implementation still constructs paths and sort keys for every matching entry and sorts the full result set on each call. These tests do not include live event replay; live refreshes use this path and can incur comparable sorting work, but exact GUI responsiveness during events was not measured.

The half-million date cases took 355 ms on repeat calls and peaked around 754–757 MiB, versus 502 MiB with the cap. The 2.58-million date cases took about 1.88 seconds on repeats and peaked around 2.07–2.12 GiB, versus 0.56 GiB with the cap. This gives practical intermediate points without assuming linear scaling.

### Method

- Apple M4 Pro, 14 CPU cores, 48 GiB RAM; macOS 27.0 (26A428).
- Production release engine built from commit `9d3bd31ad3be389c712f9e770c4067d505061401` (0.1.40).
- Fixed copy of the existing native checkpoint; SHA-256 `81d2fc0a7154aa1c625ae80b823896a799c082d0abfa6c046fc419262def40b3`.
- All six queries tested with the current 20,000 cap, followed by uncapped Name, Modified and Created sorts: 24 fresh processes, 144 timed calls. Uncapped was represented by a one-billion-result cap, above the entire index size.
- No watcher, preference changes, background metadata collection, or checkpoint writes in the benchmark. Dates were already in the copied snapshot.
- Timing is outside the entire `cn_search` and first `cn_rows` calls; the bridge's internal `search_ms` alone excludes sorting and would underreport its cost.
- Ascending order only; descending, Path and Size were not independently timed in this follow-up.
- No concurrent build or second benchmark. Normal desktop apps remained running; no reboot or filesystem-cache purge was performed. Snapshot load time is recorded separately and excluded from the tables.
- Every timed response completed successfully with stable match counts and the expected cap behavior. Inventory counts, sample counts, and timer ordering were validated in the aggregate report.

### Reproduce

From the repository root:

```sh
PATH="$HOME/.cargo/bin:$PATH" CARGO_PROFILE_RELEASE_STRIP=none \
  cargo build --locked --release -p cardinal-native-prototype \
  --example metadata_inventory --lib

target/release/examples/metadata_inventory /path/to/copied-index.db

swiftc -O -module-cache-path /tmp/everything-mac-sort-module-cache \
  -I Sources/CNative scripts/benchmark-sort.swift \
  -L target/release -lcardinal_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/everything-mac-indexed-sort-benchmark

python3 scripts/benchmark-sort.py /tmp/everything-mac-indexed-sort-benchmark \
  /path/to/copied-index.db build/indexed-sort-benchmark/reproduction \
  --keys filename,mtime,ctime --timeout 180
```

Verify `missing_metadata` is zero and review date coverage before calling a snapshot fully indexed. The harness deliberately does not backfill snapshots or alter app preferences. Use a fresh output directory; `--resume` intentionally skips existing case reports.

Consolidated raw measurements and coverage are in `build/indexed-sort-benchmark/summary.json`. Individual cases are in `build/indexed-sort-benchmark/results/`; coverage alone is in `build/indexed-sort-benchmark/current-inventory.json`. The copied snapshot and generated measurements are ignored by Git.

### Decision implications

The earlier reason for multi-minute stalls has been removed for an indexed checkpoint. Sorting tens of thousands of results costs tens of milliseconds; around 127,000 costs roughly a tenth of a second; around 503,000 costs roughly a third of a second on this machine. Sorting the complete index still takes about three seconds and about 2.65 GiB of additional peak resident memory. A larger finite limit could be reasonable if those delays fit the user's workflow. Unlimited sorting still has a noticeable per-search/per-refresh cost; reusable sort indexes would be a separate improvement. No cap or app behavior was changed during this task.

## Original sorting 0.1.39

Historical source: [`53521d4`](https://github.com/seedds/EverythingMac/tree/53521d4).
Run this section’s reproduction commands in a separate checkout of that commit.

Historical measurements below retain the upstream Cardinal query text; current benchmark scripts use `everything-mac`.

Historical report for 0.1.39. Version 0.1.42 removes the sorting cap and its setting. To reproduce these historical capped comparisons, use the scripts and code from the corresponding release tag.

This is the **0.1.39 baseline**, recorded before background date indexing and
cache-only sorting were implemented. The measurements below describe that earlier
implementation. For comparisons with newer builds, use a checkpoint whose date
indexing has finished; the read-only benchmark harness does not backfill old indexes.

Removing the limit is inexpensive for small searches, but the current implementation has severe first-sort delays on broad searches. The 2.59-million-match Name sort was stopped without a result; the full-index Name sort also timed out. These are measured stalls, not estimates of eventual completion time. The app's limit, preferences, and production code were not changed.

### Decision table

Elapsed time includes the production engine's search, sort, and retrieval/JSON decoding of the first 128 rows. It excludes index loading and UI rendering. Above 20,000 matches, the current cap **skips sorting**, so its result is not equivalent to an uncapped sorted result. Repeat values are medians of five subsequent calls in the same engine.

| Matches / query | Current 20,000 cap, repeat | No cap: first Name sort observed | No cap: repeat Name sort |
| --- | ---: | ---: | ---: |
| 6,829 / `cardinal` | 31 ms | 41 ms | 30 ms |
| 43,457 / `.swift` | 31 ms | 1.05–1.42 s | 51 ms |
| 127,159 / `.js` | 37 ms | 6.45–12.83 s | 103 ms |
| 503,181 / `.py` | 42 ms | 4.35–7.58 s | 315 ms |
| 2,590,403 / `a` | 163 ms | No result after >160 s; stopped | Unavailable |
| 4,610,087 / empty query | 17 ms | No result after >55 s; timed out | Unavailable |

First-sort ranges come from two separate fresh-process Name tests for the middle three queries. The small query has one uncapped fresh-process test. The original five-repeat medians are shown; the second trial's repeat medians were 54, 103, and 316 ms respectively. No reboot or filesystem-cache purge was performed. Thus these are observed first-sort costs on this working machine, not controlled cold-disk bounds or predictions for every launch. Different query contents and filesystem-cache state explain why first-sort time does not grow smoothly with match count.

The broad process was manually stopped at 170 seconds of process lifetime, including index loading. The conservative search-time lower bound is 160 seconds. The all-files process deadline was 60 seconds including a measured 2.077-second load; the table conservatively reports >55 seconds for its unfinished first search. Neither reached a repeat sort. A one-second stack sample of the broad process found all 84 main-thread samples inside `lstat`, called by `expand_file_nodes` from `cn_search`.

### Completed column comparisons

All times below are milliseconds. Each row is one fresh process with one initial call and five repeat calls. Tests ran sequentially in Name, Path, Size, Modified, Created order for each query; **first-call column timings are affected by filesystem-cache warming and should not be used to rank the columns**. The half-million query tested Name and Size only. The million-match cases were stopped at Name, so no other-column or cached-repeat performance is claimed for those sizes.

“Extra memory” compares each process's peak RSS growth after loading its index with the same-query capped process's growth. Normalizing to the loaded-engine RSS avoids confusing variable baseline allocation with sorting cost. RSS was sampled every 10 ms and at endpoints, so peaks are approximate. This is engine-process memory, not the whole GUI app.

| Matches | Column | First ms | Repeat median ms | Repeat range ms | Repeat CPU ms | Extra memory MiB |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 6,829 | Name | 41.1 | 30.2 | 29.8–31.0 | 30.2 | 0 |
| 6,829 | Path | 42.3 | 31.5 | 30.9–32.0 | 31.6 | 0 |
| 6,829 | Size | 46.7 | 30.7 | 30.4–31.2 | 30.8 | 0 |
| 6,829 | Modified | 42.5 | 31.3 | 30.6–32.4 | 31.4 | 0 |
| 6,829 | Created | 41.9 | 30.5 | 30.3–32.1 | 30.5 | 2 |
| 43,457 | Name | 1418.0 | 51.3 | 50.4–54.3 | 51.4 | 27 |
| 43,457 | Path | 187.7 | 57.9 | 57.7–58.7 | 58.0 | 27 |
| 43,457 | Size | 188.0 | 57.7 | 56.7–60.3 | 57.8 | 27 |
| 43,457 | Modified | 182.9 | 55.9 | 55.0–56.0 | 56.0 | 29 |
| 43,457 | Created | 187.2 | 55.5 | 54.8–60.1 | 55.6 | 29 |
| 127,159 | Name | 12833.3 | 103.4 | 96.6–104.7 | 103.4 | 65 |
| 127,159 | Path | 1240.2 | 119.0 | 112.4–120.7 | 119.2 | 65 |
| 127,159 | Size | 652.0 | 111.1 | 109.2–119.4 | 111.3 | 65 |
| 127,159 | Modified | 371.0 | 108.6 | 105.3–111.3 | 108.8 | 64 |
| 127,159 | Created | 376.5 | 107.0 | 104.7–111.1 | 107.2 | 65 |
| 503,181 | Name | 7576.2 | 315.5 | 301.3–317.4 | 315.8 | 253 |
| 503,181 | Size | 4200.6 | 389.6 | 381.0–398.9 | 390.1 | 255 |

At 503,181 matches, uncapped sorting added approximately 253–255 MiB of peak resident memory over the capped baseline. Completed test processes sometimes retained those allocations after sorting; process RSS need not fall immediately after the temporary sort entries are freed. Full-index sorting never completed, so its eventual peak memory is unknown.

### What causes the difference

The release bridge expands every matching node before sorting, including fetching uncached metadata with filesystem calls. This applies to Name and Path as well as Size and dates. It then allocates complete paths and sort keys and sorts the entire result set. Repeat calls reuse in-memory metadata but still expand paths, allocate keys, and sort again.

The first `.js` Name run took 12.83 seconds of wall time but only 1.65 seconds of CPU time; its fresh-process rerun took 6.45 seconds wall and 1.60 seconds CPU. Alongside the broad-query stack sample, this shows that filesystem waiting is a major part of the observed first-sort cost. The `.py` rerun took 4.35 seconds wall and 4.34 seconds CPU, demonstrating that even a less I/O-bound first sort can still be slow.

The app serializes engine work. These measured search/sort calls therefore occupy the engine queue; searches, paging, and operations behind them must wait. The GUI main thread was not benchmarked, so this report does not claim measured frame freezes or click-to-paint latency. Live file events were not replayed; they use the same sorting path but can invalidate metadata and differ from these unchanged-index repeats.

The bridge's existing `search_ms` field ends before sorting. This benchmark instead measures around the entire `cn_search` call and first `cn_rows` call, preventing the sorting cost from being omitted.

### Environment and reproduction

- Apple M4 Pro, 14 CPU cores, 48 GiB RAM; macOS 27.0 (26A428).
- EverythingMac 0.1.39, commit `53521d422c83fedfcc34402cdeaf7964aaa48013`.
- Production Rust release bridge linked into a small optimized Swift harness.
- A fixed copy of the user's native index, 4,610,087 entries; SHA-256 `30b462e733d7801e44be603bfce33d86638714482746bc39116570f776b23a43`.
- No watcher, checkpoint, preference writes, file actions, or index mutations. Metadata reads use the real indexed paths.
- Normal desktop applications remained running. No concurrent benchmark or build was used. This is a local workload study, not an isolated laboratory test.
- Effectively unlimited sorting was tested through the existing API with a one-billion-result cap, above the entire index size. Ascending order was tested; descending order was not independently timed.
- 156 completed timed search/page calls across 26 fresh processes, plus two unfinished first sorts. Discovery searches were excluded from the tables.

From the repository root, build the harness:

```sh
PATH="$HOME/.cargo/bin:$PATH" cargo build --locked --release -p cardinal-native-prototype
swiftc -O -module-cache-path /tmp/everything-mac-sort-module-cache \
  -I Sources/CNative scripts/benchmark-sort.swift \
  -L target/release -lcardinal_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/everything-mac-benchmark-sort
```

Run against a copied snapshot (never overwrite the original):

```sh
python3 scripts/benchmark-sort.py /tmp/everything-mac-benchmark-sort \
  build/sort-benchmark/index.db build/sort-benchmark/reproduction \
  --names small,medium,large
python3 scripts/benchmark-sort.py /tmp/everything-mac-benchmark-sort \
  build/sort-benchmark/index.db build/sort-benchmark/reproduction \
  --names larger --keys filename,size
python3 scripts/benchmark-sort.py /tmp/everything-mac-benchmark-sort \
  build/sort-benchmark/index.db build/sort-benchmark/reproduction \
  --names broad,all --keys filename --timeout 60
```

The runner preserves partial results and records timeouts. `--resume` skips existing reports. Reproduction uses a 60-second deadline for both broad cases; the original broad test was manually stopped later as described above.

The consolidated measurements are in `build/sort-benchmark/summary.json`, individual samples in `build/sort-benchmark/results/`, fresh-process reruns in `build/sort-benchmark/*-fresh-rerun.json`, and the diagnostic stack sample in `build/sort-benchmark/slow-sort-sample.txt`. Generated data and the copied index remain ignored by Git. Reusable harnesses are `scripts/benchmark-sort.swift` and `scripts/benchmark-sort.py`.

The measurements support keeping a limit with the current implementation. A higher finite limit may be acceptable for some workloads, but even the 127,159-match case incurred multi-second first-sort waits, so result count alone does not guarantee responsiveness. Any implementation change should be benchmarked separately before treating these costs as resolved.
