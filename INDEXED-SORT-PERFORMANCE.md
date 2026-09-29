# Indexed sorting performance — EverythingMac 0.1.40

Historical measurements below retain the upstream Cardinal query text; current benchmark scripts use `everything-mac`.

Historical report for 0.1.40. Version 0.1.42 removes the sorting cap and its setting. To reproduce these historical capped comparisons, use the scripts and code from the corresponding release tag.

Measured on 2026-09-28 using the user's real, fully backfilled index. Indexed sorting removes the earlier filesystem stalls, but sorting millions of matches still takes seconds and substantially increases memory use. The app's sorting limit and preferences were not changed.

## First sort after opening the indexed snapshot

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

## Comparison with the previous unindexed benchmark

The earlier 0.1.39 Name test on 2.59 million matches had not returned after more than 160 seconds of search time, and the 4.61-million-entry case had not returned after more than 55 seconds. The 0.1.40 indexed equivalents completed in 1.75 and 2.80 seconds. At roughly 127,000 matches, the previous first Name sorts took 6.45–12.83 seconds; the indexed first call now took 105 ms. At roughly 503,000 matches, the previous first Name sorts took 4.35–7.58 seconds; the indexed call now took 328 ms.

These comparisons use the same machine and harness but snapshots from different times. The original had 4,610,087 entries; the current copy has 4,621,437. They demonstrate the removal of the large observed filesystem wait, but they are not exact same-dataset speedup ratios. The old million-row stalls were Name tests; they must not be presented as measured old Modified/Created timings. The full earlier report is in `SORT-PERFORMANCE.md`.

## Metadata coverage

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

## Complete timing and memory results

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

## Method

- Apple M4 Pro, 14 CPU cores, 48 GiB RAM; macOS 27.0 (26A428).
- Production release engine built from commit `9d3bd31ad3be389c712f9e770c4067d505061401` (0.1.40).
- Fixed copy of the existing native checkpoint; SHA-256 `81d2fc0a7154aa1c625ae80b823896a799c082d0abfa6c046fc419262def40b3`.
- All six queries tested with the current 20,000 cap, followed by uncapped Name, Modified and Created sorts: 24 fresh processes, 144 timed calls. Uncapped was represented by a one-billion-result cap, above the entire index size.
- No watcher, preference changes, background metadata collection, or checkpoint writes in the benchmark. Dates were already in the copied snapshot.
- Timing is outside the entire `cn_search` and first `cn_rows` calls; the bridge's internal `search_ms` alone excludes sorting and would underreport its cost.
- Ascending order only; descending, Path and Size were not independently timed in this follow-up.
- No concurrent build or second benchmark. Normal desktop apps remained running; no reboot or filesystem-cache purge was performed. Snapshot load time is recorded separately and excluded from the tables.
- Every timed response completed successfully with stable match counts and the expected cap behavior. Inventory counts, sample counts, and timer ordering were validated in the aggregate report.

## Reproduce

From the repository root:

```sh
PATH="$HOME/.cargo/bin:$PATH" CARGO_PROFILE_RELEASE_STRIP=none \
  cargo build --locked --release -p everything-mac-native-prototype \
  --example metadata_inventory --lib

target/release/examples/metadata_inventory /path/to/copied-index.db

swiftc -O -module-cache-path /tmp/everything-mac-sort-module-cache \
  -I Sources/CNative scripts/benchmark-sort.swift \
  -L target/release -leverything_mac_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/everything-mac-indexed-sort-benchmark

python3 scripts/benchmark-sort.py /tmp/everything-mac-indexed-sort-benchmark \
  /path/to/copied-index.db build/indexed-sort-benchmark/reproduction \
  --keys filename,mtime,ctime --timeout 180
```

Verify `missing_metadata` is zero and review date coverage before calling a snapshot fully indexed. The harness deliberately does not backfill snapshots or alter app preferences. Use a fresh output directory; `--resume` intentionally skips existing case reports.

Consolidated raw measurements and coverage are in `build/indexed-sort-benchmark/summary.json`. Individual cases are in `build/indexed-sort-benchmark/results/`; coverage alone is in `build/indexed-sort-benchmark/current-inventory.json`. The copied snapshot and generated measurements are ignored by Git.

## Decision implications

The earlier reason for multi-minute stalls has been removed for an indexed checkpoint. Sorting tens of thousands of results costs tens of milliseconds; around 127,000 costs roughly a tenth of a second; around 503,000 costs roughly a third of a second on this machine. Sorting the complete index still takes about three seconds and about 2.65 GiB of additional peak resident memory. A larger finite limit could be reasonable if those delays fit the user's workflow. Unlimited sorting still has a noticeable per-search/per-refresh cost; reusable sort indexes would be a separate improvement. No cap or app behavior was changed during this task.
