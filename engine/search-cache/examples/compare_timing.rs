//! Times this engine the way the app runs it, for the comparison with Cardinal 0.1.23
//! in docs/PERFORMANCE.md. `scripts/compare-cardinal/cardinal_timing.rs` is the same
//! program for Cardinal's engine, and `scripts/compare-cardinal/run.sh` runs both.
//! Usage:
//!   compare_timing scan ROOT INDEX IGNORE...    walk ROOT and save the index
//!   compare_timing load ROOT INDEX IGNORE...    open a saved index
//!   compare_timing query ROOT INDEX REPS IGNORE... -- QUERY...
//!   compare_timing mounts ROOT -     the other volumes a scan of ROOT leaves out
//! Each prints one JSON line per operation; queries report the median of REPS warm runs.
use search_cache::{SearchCache, SearchOptions, WalkData, other_volumes};
use search_cancel::CancellationToken;
use std::{
    path::{Path, PathBuf},
    sync::atomic::AtomicBool,
    time::Instant,
};

static STOP: AtomicBool = AtomicBool::new(false);

fn ms(started: Instant) -> f64 {
    started.elapsed().as_secs_f64() * 1000.0
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (mode, root, index) = (&args[0], Path::new(&args[1]), Path::new(&args[2]));
    let (reps, rest) = match mode.as_str() {
        "query" => (args[3].parse::<usize>().unwrap(), &args[4..]),
        _ => (0, &args[3..]),
    };
    let split = rest.iter().position(|a| a == "--").unwrap_or(rest.len());
    let ignores: Vec<PathBuf> = rest[..split].iter().map(PathBuf::from).collect();
    let queries = rest.get(split + 1..).unwrap_or_default();
    match mode.as_str() {
        "mounts" => {
            for mount in other_volumes(root, &[]).skipped() {
                println!("{}", mount.display());
            }
        }
        "scan" => {
            // As `cn_scan`: up to six walk threads, other volumes left out.
            let threads = std::thread::available_parallelism().map_or(4, |n| n.get().clamp(2, 6));
            let pool = rayon::ThreadPoolBuilder::new()
                .num_threads(threads)
                .build()
                .unwrap();
            let started = Instant::now();
            let volumes = other_volumes(root, &[]);
            let walk = WalkData::new(root, &ignores, &[], false, || false).with_volumes(&volumes);
            let cache = pool
                .install(|| SearchCache::walk_fs_with_walk_data(&walk, &STOP))
                .unwrap();
            let scan_ms = ms(started);
            let entries = cache.get_total_files();
            let started = Instant::now();
            cache.flush_to_file(index).unwrap();
            println!(
                "{{\"engine\":\"everythingmac\",\"op\":\"scan\",\"entries\":{entries},\"scan_ms\":{scan_ms:.1},\"save_ms\":{:.1},\"index_bytes\":{}}}",
                ms(started),
                std::fs::metadata(index).unwrap().len()
            );
        }
        "load" | "query" => {
            let started = Instant::now();
            let mut cache =
                SearchCache::try_read_persistent_cache(root, index, &ignores, &vec![], &STOP)
                    .unwrap();
            let load_ms = ms(started);
            if mode == "load" {
                println!(
                    "{{\"engine\":\"everythingmac\",\"op\":\"load\",\"entries\":{},\"load_ms\":{load_ms:.1}}}",
                    cache.get_total_files()
                );
                return;
            }
            let options = SearchOptions {
                case_insensitive: true,
            };
            for query in queries {
                let mut times = Vec::with_capacity(reps);
                let mut count = 0;
                // One warm-up run, then REPS timed runs.
                for run in 0..=reps {
                    let started = Instant::now();
                    let outcome = cache
                        .search_with_options(query, options, CancellationToken::noop())
                        .unwrap();
                    let elapsed = ms(started);
                    count = outcome.nodes.map_or(0, |nodes| nodes.len());
                    if run > 0 {
                        times.push(elapsed);
                    }
                }
                times.sort_by(f64::total_cmp);
                println!(
                    "{{\"engine\":\"everythingmac\",\"op\":\"query\",\"query\":{query:?},\"results\":{count},\"median_ms\":{:.2},\"min_ms\":{:.2},\"max_ms\":{:.2}}}",
                    times[times.len() / 2],
                    times[0],
                    times[times.len() - 1]
                );
            }
        }
        _ => panic!("mode must be scan, load, query, or mounts"),
    }
}
