# Maintained sorting performance — Cardinal Native 0.1.41

Historical report for 0.1.41. Version 0.1.42 removes the sorting cap and its setting. To reproduce these historical capped comparisons, use the scripts and code from the corresponding release tag.

Measured on 2026-09-28 on the same M4 Pro (14 cores, 48 GiB RAM, macOS 27.0) and the exact same fully indexed **4,621,437-entry snapshot** as the 0.1.40 benchmark. The default 20,000-result cap and saved preferences are unchanged; uncapped measurements use the benchmark API only.

## First sort after opening

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

## Same-snapshot comparison: all 4.62 million entries

| Column | Previous first sort | New first sort | First-sort speedup | Previous repeat median | New repeat median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Name | 2796.3 ms | 18.6 ms | 150× | 2639.3 ms | 17.8 ms |
| Modified | 3310.7 ms | 18.7 ms | 177× | 3095.2 ms | 18.6 ms |
| Created | 3325.6 ms | 18.6 ms | 179× | 3187.1 ms | 18.0 ms |

Repeat CPU medians for all files: Name 17.9 ms, Path 17.7 ms, Size 19.1 ms, Modified 18.3 ms, Created 18.0 ms.
Across the five all-files sorts, repeat samples ranged from 17.5 to 32.6 ms.

For the 2,580,929-match `a` query, repeat medians are Name 182.5 ms, Path 187.0 ms, Size 188.7 ms, Modified 186.0 ms, Created 183.4 ms. Most of this is query matching: the capped comparison, which skips sorting at this size, takes 175.8 ms. Different result orderings must not be treated as equivalent outputs.

## Startup and memory tradeoff

- Median snapshot opening, including index preparation: **2.12 s → 2.73 s** (about 0.62 s extra per launch).
- Median RSS immediately after opening: **489 → 737 MiB** (about 248 MiB extra resident memory).
- Peak sampled RSS over all measured search/sort cases: **3312 → 851 MiB** (3.23 → 0.83 GiB).
- Peak sampled RSS during the new startup: **738 MiB**. The old harness did not sample startup peak.
- Five ID orders plus five inverse-rank arrays use approximately 40 bytes per slab slot, or 176 MiB for this snapshot, excluding allocator overhead and temporary build buffers.

The tradeoff is deliberate: retain orders in memory and construct them once per launch, instead of allocating multiple paths and sort records per matching file on every search. Orders are derived from the snapshot; the snapshot format is unchanged. RSS is sampled every 10 ms, so very brief peaks may be missed. These figures are for the benchmark process, not total GUI application memory.

## First sort after a file event

The maintenance harness loads the same snapshot, then sends a normal file-modified event for the existing repository `Cargo.toml` before every measurement. It only rereads metadata; neither the source file nor the source snapshot is modified. Each column has six event/search/sort cycles. This measures a single-file update, not a mass rescan.

| Column | Median event processing | Median following search + sort |
| --- | ---: | ---: |
| Filename | 0.06 ms | 22.2 ms |
| FullPath | 0.05 ms | 21.1 ms |
| Size | 0.06 ms | 23.6 ms |
| Mtime | 0.06 ms | 21.7 ms |
| Ctime | 0.06 ms | 21.6 ms |

Small changes remove obsolete IDs and merge the changed entries into the existing order. Binary searches locate insertion points, avoiding path comparisons against every unchanged entry. More than 8,192 accumulated dirty IDs marks an order for rebuilding; a bulk backfill or rescan can therefore make its next sort slower than the steady-state numbers above.

## Correctness and limits

- 1,797 Rust tests passed, including comparison against the previous independent comparator for all five columns in both directions. The fixture exercises sparse/broad/all results, punctuation and Unicode paths, unknown metadata, timestamp/size ties, small updates, more than 8,192 metadata updates, renamed/deleted/recreated subtrees, recycled IDs, and checkpoint reopening.
- Native UI checks passed: 23 live workflows, 16 sorting-preference checks, and seven selection-update scenarios with no observed selection gaps. Workspace Clippy completed without warnings.
- 216 benchmark calls completed across 36 cases. The production sorting cap remains 20,000, with no preference changes.
- This establishes Everything-style reuse of sorted indexes and millisecond sorting on this Mac. It does **not** establish exact parity with Everything on Windows: no Windows/Everything baseline was measured. It also does not benchmark first filesystem discovery, cloud-provider stalls, or mass event storms.

## Reproduction

Snapshot: `build/indexed-sort-benchmark/current-source.db`, SHA-256 `81d2fc0a7154aa1c625ae80b823896a799c082d0abfa6c046fc419262def40b3`. Metadata coverage is recorded in [INDEXED-SORT-PERFORMANCE.md](INDEXED-SORT-PERFORMANCE.md). The snapshot and generated raw measurements remain local, excluded from Git.

```bash
export PATH="$HOME/.cargo/bin:$PATH"
CARGO_PROFILE_RELEASE_STRIP=none cargo build --locked --release \
  -p cardinal-native-prototype --lib --example sort_index_updates
swiftc -O -module-cache-path /tmp/cardinal-sort-module-cache -I Sources/CNative \
  scripts/benchmark-sort.swift -L target/release -lcardinal_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/cardinal-maintained-sort-benchmark
python3 scripts/benchmark-sort.py /tmp/cardinal-maintained-sort-benchmark \
  build/indexed-sort-benchmark/current-source.db \
  build/maintained-sort-benchmark/final --timeout 90
target/release/examples/sort_index_updates \
  build/indexed-sort-benchmark/current-source.db Cargo.toml \
  > build/maintained-sort-benchmark/updates.json
```
