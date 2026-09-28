# Sorting limit performance — 2026-09-28

Historical report for 0.1.39. Version 0.1.42 removes the sorting cap and its setting. To reproduce these historical capped comparisons, use the scripts and code from the corresponding release tag.

This is the **0.1.39 baseline**, recorded before background date indexing and
cache-only sorting were implemented. The measurements below describe that earlier
implementation. For comparisons with newer builds, use a checkpoint whose date
indexing has finished; the read-only benchmark harness does not backfill old indexes.

Removing the limit is inexpensive for small searches, but the current implementation has severe first-sort delays on broad searches. The 2.59-million-match Name sort was stopped without a result; the full-index Name sort also timed out. These are measured stalls, not estimates of eventual completion time. The app's limit, preferences, and production code were not changed.

## Decision table

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

## Completed column comparisons

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

## What causes the difference

The release bridge expands every matching node before sorting, including fetching uncached metadata with filesystem calls. This applies to Name and Path as well as Size and dates. It then allocates complete paths and sort keys and sorts the entire result set. Repeat calls reuse in-memory metadata but still expand paths, allocate keys, and sort again.

The first `.js` Name run took 12.83 seconds of wall time but only 1.65 seconds of CPU time; its fresh-process rerun took 6.45 seconds wall and 1.60 seconds CPU. Alongside the broad-query stack sample, this shows that filesystem waiting is a major part of the observed first-sort cost. The `.py` rerun took 4.35 seconds wall and 4.34 seconds CPU, demonstrating that even a less I/O-bound first sort can still be slow.

The app serializes engine work. These measured search/sort calls therefore occupy the engine queue; searches, paging, and operations behind them must wait. The GUI main thread was not benchmarked, so this report does not claim measured frame freezes or click-to-paint latency. Live file events were not replayed; they use the same sorting path but can invalidate metadata and differ from these unchanged-index repeats.

The bridge's existing `search_ms` field ends before sorting. This benchmark instead measures around the entire `cn_search` call and first `cn_rows` call, preventing the sorting cost from being omitted.

## Environment and reproduction

- Apple M4 Pro, 14 CPU cores, 48 GiB RAM; macOS 27.0 (26A428).
- Cardinal Native 0.1.39, commit `53521d422c83fedfcc34402cdeaf7964aaa48013`.
- Production Rust release bridge linked into a small optimized Swift harness.
- A fixed copy of the user's native index, 4,610,087 entries; SHA-256 `30b462e733d7801e44be603bfce33d86638714482746bc39116570f776b23a43`.
- No watcher, checkpoint, preference writes, file actions, or index mutations. Metadata reads use the real indexed paths.
- Normal desktop applications remained running. No concurrent benchmark or build was used. This is a local workload study, not an isolated laboratory test.
- Effectively unlimited sorting was tested through the existing API with a one-billion-result cap, above the entire index size. Ascending order was tested; descending order was not independently timed.
- 156 completed timed search/page calls across 26 fresh processes, plus two unfinished first sorts. Discovery searches were excluded from the tables.

From the repository root, build the harness:

```sh
PATH="$HOME/.cargo/bin:$PATH" cargo build --locked --release -p cardinal-native-prototype
swiftc -O -module-cache-path /tmp/cardinal-sort-module-cache \
  -I Sources/CNative scripts/benchmark-sort.swift \
  -L target/release -lcardinal_native_prototype \
  -framework CoreServices -framework CoreFoundation -framework Security \
  -liconv -lresolv -o /tmp/cardinal-benchmark-sort
```

Run against a copied snapshot (never overwrite the original):

```sh
python3 scripts/benchmark-sort.py /tmp/cardinal-benchmark-sort \
  build/sort-benchmark/index.db build/sort-benchmark/reproduction \
  --names small,medium,large
python3 scripts/benchmark-sort.py /tmp/cardinal-benchmark-sort \
  build/sort-benchmark/index.db build/sort-benchmark/reproduction \
  --names larger --keys filename,size
python3 scripts/benchmark-sort.py /tmp/cardinal-benchmark-sort \
  build/sort-benchmark/index.db build/sort-benchmark/reproduction \
  --names broad,all --keys filename --timeout 60
```

The runner preserves partial results and records timeouts. `--resume` skips existing reports. Reproduction uses a 60-second deadline for both broad cases; the original broad test was manually stopped later as described above.

The consolidated measurements are in `build/sort-benchmark/summary.json`, individual samples in `build/sort-benchmark/results/`, fresh-process reruns in `build/sort-benchmark/*-fresh-rerun.json`, and the diagnostic stack sample in `build/sort-benchmark/slow-sort-sample.txt`. Generated data and the copied index remain ignored by Git. Reusable harnesses are `scripts/benchmark-sort.swift` and `scripts/benchmark-sort.py`.

The measurements support keeping a limit with the current implementation. A higher finite limit may be acceptable for some workloads, but even the 127,159-match case incurred multi-second first-sort waits, so result count alone does not guarantee responsiveness. Any implementation change should be benchmarked separately before treating these costs as resolved.
