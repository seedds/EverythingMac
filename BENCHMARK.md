# EverythingMac benchmark — 2026-09-27

Historical measurements below retain the upstream Cardinal query text; current benchmark scripts use `everything-mac`.

Historical snapshot-only prototype measurement, before live feature-parity work.
The expanded native app requires a new feature-equivalent performance comparison.

## Recommendation

**Continue a staged native experiment; defer a full migration decision.** The optimized SwiftUI/AppKit prototype uses substantially less sampled resident memory and has a lower draw-proxy latency for repeated Enter-driven searches in this run. However, typing between different result counts still incurs table rebuilding, and at equal 300 ms debounce its typing latency is higher than React. These results support further native development, not a blanket speedup claim or replacement of the production app yet.

## Method

- Apple M4 Pro, 48 GiB RAM; macOS 27.0 (26A428); Swift 6.4; Rust nightly-2025-12-11. Both applications built with release optimization; deployment target macOS 12, which was not tested on actual macOS 12 hardware.
- Both successful comparison runs used the same copied index. SHA-256: `90637f0de1b416f220a02b8824f781adadaf85db7f16724409345b46e1d0afb2`. Its hash remained unchanged after benchmarking. No index migration, write, scan or filesystem watcher was active in either benchmark app.
- Three warmups followed by twenty immediate (Enter-equivalent) searches per query. Runs were sequential, with build/test work finished. Other user applications remained running, so this is a workstation experiment, not an isolated lab result.
- The React baseline uses the actual App, search hook and virtual list. An explicit build feature substitutes a read-only snapshot worker and enables timing hooks. Native retrieves the first 128 rows and then bounded pages; the existing UI retains its original result-ID transfer and row/icon pipeline.
- Native reports its table draw callback followed by main-queue delivery; React reports a requestAnimationFrame after the viewport has row data. These are different first-draw proxies, not verified physical display times. Icons are not awaited in either measure.
- Successful raw runs are `build/native-final.json` and `build/tauri-final.json`, with matching `.memory.json` and `.log` files. Raw outputs are local/ignored. Preliminary runs, a partial timed-out baseline run, an unsuccessful table optimization, and profiling runs are excluded. Each query is repeated consecutively; that favors same-count cell reuse. The alternating-query typing test below covers result-count changes.

## Immediate-search latency

All timings are **median / p95 milliseconds**. p95 uses the nearest-rank method. Result counts agree between interfaces.

| Query | Results | Native Rust search | React Rust search | Native submission → draw proxy | React submission → draw proxy |
| --- | ---: | ---: | ---: | ---: | ---: |
| `EE.en` | 2 | 27.8 / 32.5 | 30.2 / 38.5 | 33.1 / 38.4 | 42.0 / 51.0 |
| `cardinal` | 694 | 25.7 / 29.1 | 33.7 / 43.1 | 36.7 / 40.6 | 58.0 / 60.0 |
| `package.json` | 3,704 | 26.0 / 29.0 | 27.2 / 35.9 | 36.8 / 40.6 | 44.0 / 59.0 |
| `a` | 1,934,142 | 161.0 / 167.8 | 150.8 / 153.5 | 170.9 / 178.4 | 193.0 / 204.0 |

One snapshot-load measurement per app: native **1942 ms**, baseline **2012 ms**. These are engine decode/construction times, not cold application launch times. No startup-speed conclusion is justified from one warm filesystem-cache sample.

## Typing and memory

Typing measurements alternate `cardinal` and `package.json`, discard two warmups per delay, and retain ten samples. Input-to-draw includes the configured delay.

| Interface | Typing delay | Input → draw proxy, median / p95 ms |
| --- | ---: | ---: |
| Native | 0 ms | 74.0 / 81.8 |
| Native | 100 ms | 180.9 / 191.9 |
| Native | 300 ms | 406.9 / 413.5 |
| React | 300 ms | 352.0 / 360.0 |

The native default feels quicker while typing largely because its delay is 100 ms instead of 300 ms. At the same 300 ms delay, React is faster in this run. The default-delay advantage is not evidence that SwiftUI renders faster.

RSS samples every 200 ms, excluding the first three seconds. Values below are **median / sampled peak MiB**.

| Interface | Host process | WebKit helpers | Combined |
| --- | ---: | ---: | ---: |
| Native | 532.1 / 550.5 | 0.0 / 0.0 | 532.1 / 550.5 |
| React | 735.1 / 1040.5 | 525.3 / 660.8 | 1260.5 / 1701.3 |

The baseline total includes newly spawned WebContent, GPU and Networking helper processes. Attribution is based on new helper PIDs observed during that isolated launch; it is not a kernel-verified ownership measurement. RSS can double-count shared resident pages and does not equal physical footprint. Native also omits thumbnails and much of the production UI, so the memory reduction is not a full-feature-parity projection.

## Scrolling and profiling

- Native: 189 table inter-draw intervals, median / p95 **16.4 / 21.8 ms**.
- React: 179 animation-frame intervals, median / p95 **17.0 / 22.0 ms**.
- The scripted sweeps use different native/WebKit scrolling mechanisms. These intervals are diagnostic proxies, not comparable FPS or proof of smooth physical presentation.
- An Instruments Animation Hitches recording was attempted, but finalization stalled and export reported “Document Missing Template Error”. It cannot validate the draw proxy. The trace is not used as evidence.
- A separate five-second `sample` CPU profile is captured locally as `build/native-search.sample.txt`; the profiled run is excluded from comparison numbers. The main-thread sample contained substantial AppKit layout/commit work (770 of 2,429 samples under the display-cycle flush branch), including table cell creation and constraint layout. This supports investigating the native table update path; it does not establish a precise bottleneck share or validate physical presentation timing.
- A five-second profile of the optimized build (`build/native-final.sample.txt`) contains 189 of 2,992 main-thread samples under the same dominant display-cycle flush branch. This is consistent with less layout work during repeated searches, but the sampled query segments differ; these counts are diagnostic, not a controlled CPU percentage comparison. It still does not validate physical presentation timestamps.

## Table update experiment

The first implementation rebuilt visible table cells for every search. Its earlier run (`native-run-2.json`) had median draw proxies of 80.9 ms for `cardinal` and 77.7 ms for `package.json`. Reusing visible cells on equal-count replacements reduced these to 36.7 and 36.8 ms in the final run. Changing the count still uses a full reload; no query debounce was changed for this experiment.

An intermediate approach used `noteNumberOfRowsChanged` on every update. It retained excessive AppKit row state after the initial millions-of-results query: peak RSS reached 3,418 MiB and the two-result query's median draw proxy reached 941 ms. That approach was rejected. The final code reloads when the count changes and updates existing cells otherwise; the large-to-small transition regression is included in the benchmark checker.

`python3 native-prototype/scripts/check-render.py native-prototype/build/native-final.json` passes: median non-backend overhead is 5.3 / 10.7 / 10.8 / 9.7 ms for the four queries, with 550 MiB sampled peak RSS. The 30 ms overhead and 1,024 MiB budgets are development thresholds for this host and fixed snapshot, not portable CI or product guarantees. An independent preceding run of the same update strategy (`count-aware-table.json`) also passed all four thresholds, with 574 MiB peak RSS.

## Validation and limits

- `cargo test --workspace --no-fail-fast`: passed. Initial sandbox runs failed filesystem-event tests; a first host run hit an existing one-second filesystem-walk timing assertion. The subsequent complete host run passed.
- `cargo clippy --workspace --all-targets`: passed.
- Tauri Rust library tests: 42 passed, one opt-in real-Trash test ignored. Tauri Clippy passed.
- Frontend: TypeScript passed, 34 Vitest files / 305 tests passed, production Vite build passed. Full Prettier check reports four generated Tauri schema files; edited frontend source files pass targeted formatting checks.
- Native release build and real window verified. Fixture-based rendered-window checks passed: case sensitivity, directory scope, Unicode, no matches, rapid replacement/cancellation, deleted-file metadata, invalid query, missing index, reopening after a load error, and close with queued work.
- The fixture check found and fixed a query-edit-during-load race. It also inspects actual rendered filename cells and table row counts after query transitions, including equal-count replacements. These checks cover the model/engine/rendering flow, not physical keyboard synthesis. Command-O/Command-R use AppKit operations; opening arbitrary user documents was not exercised.
- No deployment on an older macOS version, Intel build, full native feature parity, energy test, cold launch comparison, or verified display scanout measurement was performed.

## Next decision

Keep this experiment on its prototype branch. Next, measure and reduce native table rebuilding when the result count changes, then compare randomized query transitions and equivalent features. Verify frame presentation with working Instruments tooling before making a full migration decision. A full application will also need the deliberately excluded production features; their costs are not represented here.
