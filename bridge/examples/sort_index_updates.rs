//! Read-only index maintenance benchmark. Re-read one existing file's metadata
//! using the normal event path; never modify that file or the source snapshot.
use cardinal_sdk::{EventFlag, FsEvent};
use search_cache::{SearchCache, SortColumn, read_cache_from_file};
use search_cancel::CancellationToken;
use std::{path::Path, sync::atomic::AtomicBool, time::Instant};
fn main() {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(
        args.len(),
        3,
        "Usage: sort_index_updates SNAPSHOT EXISTING_FILE"
    );
    static STOP: AtomicBool = AtomicBool::new(false);
    let mut cache = SearchCache::from_persistent_storage(
        read_cache_from_file(Path::new(&args[1])).unwrap(),
        &STOP,
    );
    let path = std::fs::canonicalize(&args[2]).unwrap();
    assert!(
        cache.node_index_for_path(&path).is_some(),
        "file must be in snapshot"
    );
    cache.prepare_sort_indexes();
    let mut reports = vec![];
    for column in [
        SortColumn::Filename,
        SortColumn::FullPath,
        SortColumn::Size,
        SortColumn::Mtime,
        SortColumn::Ctime,
    ] {
        for iteration in 0..6 {
            let event_id = cache.last_event_id() + 1;
            let start = Instant::now();
            assert!(
                cache
                    .handle_fs_events(vec![FsEvent {
                        path: path.clone(),
                        id: event_id,
                        flag: EventFlag::ItemModified
                    }])
                    .unwrap()
            );
            let event_ms = start.elapsed().as_secs_f64() * 1000.;
            let start = Instant::now();
            let mut results = cache.search_empty(CancellationToken::noop()).unwrap();
            cache
                .sort_results(&mut results, column, false, CancellationToken::noop())
                .unwrap();
            reports.push(serde_json::json!({"column":format!("{column:?}"), "iteration":iteration,
                "matches":results.len(), "event_ms":event_ms, "search_sort_ms":start.elapsed().as_secs_f64()*1000.}));
        }
    }
    println!("{}", serde_json::to_string_pretty(&reports).unwrap());
}
