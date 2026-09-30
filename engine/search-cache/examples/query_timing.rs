//! Times queries against a saved index, or against a fresh walk whose sizes and
//! dates are not loaded yet. Never modifies the index or any indexed file.
//! Usage:
//!   query_timing snapshot INDEX REPETITIONS [FOLDER=]QUERY...
//!   query_timing walk FOLDER REPETITIONS [FOLDER=]QUERY...
//! `snapshot` reports the median of warm runs and checksums of the result order and
//! of the result set.
//! `walk` walks again before each run, so every run starts with no metadata.
//! A `FOLDER=` prefix fills the folder search field; `=QUERY` leaves it empty.
use search_cache::{SearchCache, SearchOptions, SearchQuery, read_cache_from_file};
use search_cancel::CancellationToken;
use std::{hash::Hasher, path::Path, sync::atomic::AtomicBool, time::Instant};

static STOP: AtomicBool = AtomicBool::new(false);

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let [_, mode, source, repetitions, queries @ ..] = args.as_slice() else {
        eprintln!("Usage: query_timing snapshot|walk INDEX|FOLDER REPETITIONS QUERY...");
        std::process::exit(2);
    };
    let repetitions: usize = repetitions.parse().expect("repetitions");
    let load = || match mode.as_str() {
        "snapshot" => SearchCache::from_persistent_storage(
            read_cache_from_file(Path::new(source)).expect("read index"),
            &STOP,
        ),
        "walk" => SearchCache::walk_fs(Path::new(source)),
        _ => panic!("mode must be snapshot or walk"),
    };
    let started = Instant::now();
    let mut cache = load();
    let mut fresh = true;
    println!(
        "{} entries loaded in {:.0} ms",
        cache.get_total_files(),
        started.elapsed().as_secs_f64() * 1000.0
    );
    for line in queries {
        let (folder, query) = line.split_once('=').unwrap_or(("", line));
        let query = SearchQuery {
            directory_query: (!folder.is_empty()).then(|| folder.into()),
            query: (!query.is_empty()).then(|| query.into()),
        };
        let mut times = Vec::new();
        let mut summary = (0, 0, 0u64);
        for _ in 0..repetitions {
            if mode == "walk" && !fresh {
                cache = load();
            }
            fresh = false;
            let started = Instant::now();
            let nodes = cache
                .search_query_with_options(
                    query.clone(),
                    SearchOptions {
                        case_insensitive: true,
                    },
                    CancellationToken::noop(),
                )
                .expect("query")
                .nodes
                .expect("completed");
            times.push(started.elapsed().as_secs_f64() * 1000.0);
            let mut hasher = std::hash::DefaultHasher::new();
            let mut set = 0u64;
            for index in &nodes {
                hasher.write_usize(index.get());
                set =
                    set.wrapping_add((index.get() as u64 + 1).wrapping_mul(0x9e37_79b9_7f4a_7c15));
            }
            summary = (nodes.len(), hasher.finish(), set);
        }
        times.sort_by(f64::total_cmp);
        println!(
            "{line:?}: {} matches, median {:.1} ms (min {:.1}, max {:.1}), order {:016x}, set {:016x}",
            summary.0,
            times[times.len() / 2],
            times[0],
            times[times.len() - 1],
            summary.1,
            summary.2
        );
    }
}
