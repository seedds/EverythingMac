//! Throwaway C bridge for the native UI experiment. See include/everything_mac_native.h.
mod live;
mod metadata;
mod sort;

use search_cache::{SearchCache, SearchOptions, SearchQuery, SlabIndex, read_cache_with_format};
use search_cancel::CancellationToken;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize},
    },
    time::Instant,
};

static STOP: AtomicBool = AtomicBool::new(false);
const MAX_PAGE: usize = 256;

pub struct Engine(Arc<Mutex<State>>);
struct State {
    cache: SearchCache,
    results: Vec<SlabIndex>,
    generation: u64,
    root: std::path::PathBuf,
    watcher: Option<everything_mac_sdk::EventWatcher>,
    event_root: std::path::PathBuf,
    needs_rescan: bool,
    checkpoint: Option<std::path::PathBuf>,
    /// The saved index this state was opened from, unchanged until `dirty` is set.
    loaded_from: Option<std::path::PathBuf>,
    dirty: bool,
    events: std::collections::VecDeque<Value>,
    processed_events: u64,
    sort: Option<sort::SortStatePayload>,
    selection: std::collections::HashSet<[u64; 2]>,
    selection_nodes: Vec<SlabIndex>,
    selection_positions: Vec<usize>,
    selection_generation: Option<u64>,
    metadata: metadata::Indexing,
}
impl State {
    fn new(mut cache: SearchCache, root: std::path::PathBuf) -> Self {
        cache.prepare_sort_indexes();
        Self {
            cache,
            root: root.clone(),
            event_root: root,
            results: vec![],
            generation: 0,
            watcher: None,
            needs_rescan: false,
            checkpoint: None,
            loaded_from: None,
            dirty: true,
            events: Default::default(),
            processed_events: 0,
            sort: None,
            selection: Default::default(),
            selection_nodes: vec![],
            selection_positions: vec![],
            selection_generation: None,
            metadata: Default::default(),
        }
    }
}
pub struct Request(CancellationToken, Arc<AtomicUsize>);

/// UTF-8 JSON owned by Rust; release exactly once with cn_buffer_free.
#[repr(C)]
pub struct Buffer {
    pub data: *mut u8,
    pub len: usize,
}

fn buffer(value: Value) -> Buffer {
    let bytes = value.to_string().into_bytes().into_boxed_slice();
    let len = bytes.len();
    Buffer {
        data: Box::into_raw(bytes).cast::<u8>(),
        len,
    }
}

fn guarded(f: impl FnOnce() -> Result<Value, String>) -> Buffer {
    buffer(match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"status":"error", "error":error}),
        Err(_) => {
            json!({"status":"error", "error":"Rust panicked; reopen the index to reset the engine."})
        }
    })
}

unsafe fn text(pointer: *const c_char) -> Result<String, String> {
    if pointer.is_null() {
        return Err("Missing string argument".into());
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_owned)
        .map_err(|e| e.to_string())
}

/// # Safety
/// `path` must be a valid NUL-terminated UTF-8 string, and `out` writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_engine_open(path: *const c_char, out: *mut *mut Engine) -> Buffer {
    guarded(|| {
        if out.is_null() {
            return Err("Missing engine output".into());
        }
        unsafe {
            *out = ptr::null_mut();
        }
        let path = unsafe { text(path)? };
        let started = Instant::now();
        let (storage, legacy) =
            read_cache_with_format(Path::new(&path)).map_err(|e| format!("{e:#}"))?;
        let root = storage.path.clone();
        let ignores = storage.ignore_paths.clone();
        let includes = storage.include_paths.clone();
        let patterns = storage.exclusion_patterns.clone();
        let cache = SearchCache::from_persistent_storage(storage, &STOP);
        let total = cache.get_total_files();
        let mut state = State::new(cache, root.clone());
        // Checkpointing an unchanged index would rewrite the same file; legacy
        // formats are still upgraded by the next checkpoint.
        state.dirty = legacy;
        state.loaded_from = Some(path.into());
        let engine = Box::new(Engine(Arc::new(Mutex::new(state))));
        unsafe {
            *out = Box::into_raw(engine);
        }
        Ok(
            json!({"status":"ok", "total":total, "root":root, "ignores":ignores, "includes":includes, "exclusion_patterns":patterns, "load_ms":started.elapsed().as_secs_f64()*1000.0}),
        )
    })
}

/// # Safety
/// Engine must be live and no calls may be in flight. Null is permitted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_engine_close(engine: *mut Engine) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if !engine.is_null() {
            unsafe {
                drop(Box::from_raw(engine));
            }
        }
    }));
}

/// Allocate before enqueueing a search; immediately cancels older requests.
#[unsafe(no_mangle)]
pub extern "C" fn cn_request_new() -> *mut Request {
    Box::into_raw(Box::new(Request(
        CancellationToken::new_search(),
        Arc::default(),
    )))
}

#[unsafe(no_mangle)]
pub extern "C" fn cn_cancel() {
    let _ = CancellationToken::new_search();
}

/// # Safety
/// Request must be live and unused by any in-flight call. Null is permitted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_request_free(request: *mut Request) {
    if !request.is_null() {
        unsafe {
            drop(Box::from_raw(request));
        }
    }
}

/// # Safety
/// Handles must be live; strings must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_search(
    engine: *mut Engine,
    request: *const Request,
    generation: u64,
    query: *const c_char,
    directory: *const c_char,
    case_sensitive: bool,
) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let token = unsafe { request.as_ref() }.ok_or("No request")?.0;
        let query = unsafe { text(query)? };
        let directory = unsafe { text(directory)? };
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        if token.is_cancelled().is_none() {
            return Ok(json!({"status":"cancelled"}));
        }
        let started = Instant::now();
        let outcome = state
            .cache
            .search_query_with_options(
                SearchQuery {
                    query: (!query.is_empty()).then_some(query),
                    directory_query: (!directory.is_empty()).then_some(directory),
                },
                SearchOptions {
                    case_insensitive: !case_sensitive,
                },
                token,
            )
            .map_err(|e| format!("{e:#}"))?;
        let search_ms = started.elapsed().as_secs_f64() * 1000.0;
        if token.is_cancelled().is_none() || outcome.nodes.is_none() {
            return Ok(json!({"status":"cancelled"}));
        }
        let mut results = outcome.nodes.unwrap();
        if let Some(sort) = state.sort
            && state
                .cache
                .sort_results(
                    &mut results,
                    sort.key.into(),
                    matches!(sort.direction, sort::SortDirectionPayload::Desc),
                    token,
                )
                .is_none()
        {
            return Ok(json!({"status":"cancelled"}));
        }
        if token.is_cancelled().is_none() {
            return Ok(json!({"status":"cancelled"}));
        }
        state.results = results;
        state.generation = generation;
        Ok(
            json!({"status":"ok", "generation":generation, "total":state.results.len(),
            "search_ms":search_ms, "highlights":outcome.highlights,
            "skipped_cloud_files":outcome.skipped_cloud_files.len()}),
        )
    })
}

/// # Safety
/// Engine must be live. Stale generations return status `stale`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_rows(
    engine: *mut Engine,
    generation: u64,
    start: usize,
    count: usize,
) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        if generation != state.generation {
            return Ok(json!({"status":"stale"}));
        }
        let end = start
            .saturating_add(count.min(MAX_PAGE))
            .min(state.results.len());
        let start = start.min(end);
        let ids = state.results[start..end].to_vec();
        let nodes = state.cache.expand_cached_file_nodes(&ids);
        let rows: Vec<_> = nodes
            .iter()
            .zip(ids)
            .enumerate()
            .map(|(offset, (node, id))| {
                let metadata = node.metadata.as_ref();
                json!({"index":start+offset, "id":id.get(), "path":node.path.to_string_lossy(),
                "size":metadata.as_ref().map(|m| m.size()),
                "allocated_size":metadata.as_ref().map(|m| m.allocated_size()),
                "modified":metadata.as_ref().and_then(|m| m.mtime()).map(|v| v.get()),
                "created":metadata.as_ref().and_then(|m| m.ctime()).map(|v| v.get()),
                "metadata_loaded":!node.metadata.is_none(),
                "is_directory":node.metadata.file_type_hint() as u8 == 1})
            })
            .collect();
        Ok(json!({"status":"ok", "generation":generation, "rows":rows}))
    })
}

/// # Safety
/// Buffer must have been returned by this library and not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_buffer_free(buffer: Buffer) {
    if !buffer.data.is_null() {
        unsafe {
            drop(Box::from_raw(ptr::slice_from_raw_parts_mut(
                buffer.data,
                buffer.len,
            )));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{ffi::CString, fs};
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn scan_count_is_readable_before_traversal_finishes() {
        use search_cache::WalkData;
        use std::sync::atomic::Ordering;
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        std::fs::write(temp.path().join("entry.txt"), b"file").unwrap();
        // A search token avoids invalidating other tests' active scan tokens.
        let request = Request(CancellationToken::new_search(), Arc::default());
        let observed = AtomicBool::new(false);
        let walk = WalkData::new(temp.path(), &[], &[], false, || {
            // Hold the actual walker at its first entry until progress is visible.
            let deadline = Instant::now() + std::time::Duration::from_secs(2);
            while unsafe { live::cn_scan_count(&request) } == 0 && Instant::now() < deadline {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            observed.store(
                unsafe { live::cn_scan_count(&request) } > 0,
                Ordering::Relaxed,
            );
            false
        });
        let cache = live::with_scan_progress(&walk, &request.1, || {
            SearchCache::walk_fs_with_walk_data(&walk, &STOP)
        });
        assert!(cache.is_some());
        assert!(
            observed.load(Ordering::Relaxed),
            "scan count stayed zero until completion"
        );
    }

    #[test]
    fn scrolling_rows_do_not_wait_for_uncached_filesystem_metadata() {
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("scroll-target.txt"), b"contents").unwrap();
        let cache = SearchCache::walk_fs(temp.path());
        let results = vec![
            cache
                .node_index_for_path(&temp.path().join("scroll-target.txt"))
                .unwrap(),
        ];
        let mut state = State::new(cache, temp.path().to_path_buf());
        state.results = results;
        let engine = Box::into_raw(Box::new(Engine(Arc::new(Mutex::new(state)))));
        unsafe {
            let page = reply(cn_rows(engine, 0, 0, 128));
            assert_eq!(page["rows"].as_array().unwrap().len(), 1);
            assert!(
                page["rows"][0]["path"]
                    .as_str()
                    .unwrap()
                    .ends_with("scroll-target.txt")
            );
            assert!(
                page["rows"][0]["size"].is_null(),
                "Paging must not fetch filesystem metadata before returning filenames"
            );
            assert_eq!(page["rows"][0]["metadata_loaded"], false);
            {
                let mut state = (*engine).0.lock().unwrap();
                let ids = state.results.clone();
                state.cache.expand_file_nodes(&ids);
            }
            let cached = reply(cn_rows(engine, 0, 0, 128));
            assert_eq!(cached["rows"][0]["size"], 8);
            assert_eq!(cached["rows"][0]["metadata_loaded"], true);
            cn_engine_close(engine);
        }
    }

    #[test]
    fn disk_size_rows_and_sort_use_allocation_while_size_queries_stay_logical() {
        use std::os::unix::fs::MetadataExt;
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let sparse = temp.path().join("sparse.raw");
        let regular = temp.path().join("regular.bin");
        fs::File::create(&sparse).unwrap().set_len(1 << 30).unwrap();
        fs::write(&regular, vec![1u8; 65536]).unwrap();
        let actual = fs::symlink_metadata(&sparse).unwrap().blocks() * 512;
        assert!(actual < fs::symlink_metadata(&regular).unwrap().blocks() * 512);
        let mut cache = SearchCache::walk_fs(temp.path());
        let sparse_id = cache.node_index_for_path(&sparse).unwrap();
        let regular_id = cache.node_index_for_path(&regular).unwrap();
        cache.expand_file_nodes(&[sparse_id, regular_id]);
        assert_eq!(
            cache
                .search_query_with_options(
                    SearchQuery {
                        query: Some("size:>100mb".into()),
                        directory_query: None
                    },
                    SearchOptions {
                        case_insensitive: true
                    },
                    CancellationToken::noop()
                )
                .unwrap()
                .nodes
                .unwrap(),
            vec![sparse_id]
        );
        let mut state = State::new(cache, temp.path().into());
        state.results = vec![regular_id, sparse_id];
        let mut engine = Engine(Arc::new(Mutex::new(state)));
        unsafe {
            let rows = reply(cn_rows(&mut engine, 0, 0, 10));
            assert_eq!(rows["rows"][1]["size"], 1 << 30);
            assert_eq!(rows["rows"][1]["allocated_size"], actual);
            assert_eq!(rows["rows"][1]["metadata_loaded"], true);
        }
        let mut state = engine.0.lock().unwrap();
        let mut ids = state.results.clone();
        state
            .cache
            .sort_results(
                &mut ids,
                sort::SortKeyPayload::Size.into(),
                false,
                CancellationToken::noop(),
            )
            .unwrap();
        assert_eq!(ids, vec![sparse_id, regular_id]);
        state
            .cache
            .sort_results(
                &mut ids,
                sort::SortKeyPayload::Size.into(),
                true,
                CancellationToken::noop(),
            )
            .unwrap();
        assert_eq!(ids, vec![regular_id, sparse_id]);
    }

    #[test]
    fn poll_includes_events_only_when_requested_and_changed() {
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let mut state = State::new(SearchCache::walk_fs(temp.path()), temp.path().into());
        state.events.push_front(json!({"id":1, "path":"/a", "flags":"Created", "time":0.0}));
        state.processed_events = 1;
        let mut engine = Engine(Arc::new(Mutex::new(state)));
        unsafe {
            let hidden = reply(live::cn_poll(&mut engine, 0, false));
            assert_eq!(hidden["processed_events"], 1);
            assert!(hidden.get("events").is_none());
            let changed = reply(live::cn_poll(&mut engine, 0, true));
            assert_eq!(changed["events"].as_array().unwrap().len(), 1);
            let unchanged = reply(live::cn_poll(&mut engine, 1, true));
            assert!(unchanged.get("events").is_none());
        }
    }

    unsafe fn reply(buffer: Buffer) -> Value {
        let value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
                .unwrap();
        unsafe {
            cn_buffer_free(buffer);
        }
        value
    }

    #[test]
    fn sorting_applies_to_every_result_above_the_former_limit() {
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        const COUNT: usize = 20_001;
        for i in 0..COUNT {
            fs::File::create(temp.path().join(format!("item-{i:05}.unlimited-sort"))).unwrap();
        }
        let root = temp.path().canonicalize().unwrap();
        let cache = SearchCache::walk_fs(&root);
        let engine = Box::into_raw(Box::new(Engine(Arc::new(Mutex::new(State::new(
            cache, root,
        ))))));
        let query = CString::new(".unlimited-sort").unwrap();
        let empty = CString::new("").unwrap();
        unsafe {
            for (i, descriptor) in [
                r#"{"key":"filename","direction":"desc"}"#,
                r#"{"key":"filename","direction":"asc"}"#,
                "null",
            ]
            .into_iter()
            .enumerate()
            {
                let sort = CString::new(descriptor).unwrap();
                assert_eq!(reply(live::cn_sort(engine, sort.as_ptr()))["status"], "ok");
                let request = cn_request_new();
                let generation = i as u64 + 1;
                let result = reply(cn_search(
                    engine,
                    request,
                    generation,
                    query.as_ptr(),
                    empty.as_ptr(),
                    false,
                ));
                cn_request_free(request);
                assert_eq!(result["total"], COUNT);
                for position in [0, COUNT - 1] {
                    let row = reply(cn_rows(engine, generation, position, 1));
                    let name = if i == 0 {
                        COUNT - 1 - position
                    } else {
                        position
                    };
                    assert!(
                        row["rows"][0]["path"]
                            .as_str()
                            .unwrap()
                            .ends_with(&format!("/item-{name:05}.unlimited-sort"))
                    );
                }
            }
            cn_engine_close(engine);
        }
    }

    #[test]
    fn checkpoint_rewrites_only_changed_or_relocated_indexes() {
        use std::os::unix::fs::MetadataExt;
        use std::time::Duration;
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        // An empty root has no pending file metadata, so nothing backfills.
        let root = temp.path().join("files");
        fs::create_dir(&root).unwrap();
        let index = temp.path().join("index.db");
        SearchCache::walk_fs(&root).flush_to_file(&index).unwrap();
        let relocated = temp.path().join("relocated.db");
        fs::copy(&index, &relocated).unwrap();
        let inode = |path: &Path| fs::metadata(path).unwrap().ino();
        let (index_inode, relocated_inode) = (inode(&index), inode(&relocated));
        let index_c = CString::new(index.to_str().unwrap()).unwrap();
        let relocated_c = CString::new(relocated.to_str().unwrap()).unwrap();
        unsafe {
            let mut engine = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(index_c.as_ptr(), &mut engine))["status"],
                "ok"
            );
            assert_eq!(
                reply(live::cn_watch(engine, false, index_c.as_ptr()))["status"],
                "ok"
            );
            let started = Instant::now();
            while reply(live::cn_poll(engine, 0, false))["metadata_indexing"] != false {
                assert!(started.elapsed() < Duration::from_secs(3));
                std::thread::sleep(Duration::from_millis(5));
            }
            assert_eq!(reply(live::cn_checkpoint(engine))["status"], "ok");
            assert_eq!(inode(&index), index_inode, "unchanged index was rewritten");
            // A different checkpoint must receive the loaded index.
            assert_eq!(
                reply(live::cn_watch(engine, false, relocated_c.as_ptr()))["status"],
                "ok"
            );
            assert_eq!(reply(live::cn_checkpoint(engine))["status"], "ok");
            assert_ne!(inode(&relocated), relocated_inode);
            assert_eq!(inode(&index), index_inode);
            cn_engine_close(engine);
        }
    }

    #[test]
    fn date_index_backfills_legacy_snapshots_persists_and_tracks_events() {
        use everything_mac_sdk::{EventFlag, FsEvent};
        use std::time::{Duration, UNIX_EPOCH};
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("files");
        fs::create_dir(&root).unwrap();
        let file = root.join("date-target.txt");
        fs::write(&file, "original").unwrap();
        fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_times(
                fs::FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(1_600_000_000)),
            )
            .unwrap();
        let created = fs::symlink_metadata(&file)
            .unwrap()
            .created()
            .unwrap()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let old = temp.path().join("legacy.db");
        SearchCache::walk_fs(&root).flush_to_file(&old).unwrap();
        let old_bytes = fs::read(&old).unwrap();
        let source = CString::new(old.to_str().unwrap()).unwrap();
        let destination = CString::new(temp.path().join("native.db").to_str().unwrap()).unwrap();
        let query = CString::new("date-target").unwrap();
        let empty = CString::new("").unwrap();
        unsafe {
            let mut engine = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(source.as_ptr(), &mut engine))["status"],
                "ok"
            );
            let search = |generation| {
                let request = cn_request_new();
                assert_eq!(
                    reply(cn_search(
                        engine,
                        request,
                        generation,
                        query.as_ptr(),
                        empty.as_ptr(),
                        false
                    ))["total"],
                    1
                );
                cn_request_free(request);
                reply(cn_rows(engine, generation, 0, 128))["rows"][0].clone()
            };
            // All five sorts must leave unindexed metadata alone, including dates.
            for (i, key) in ["filename", "fullPath", "size", "mtime", "ctime"]
                .iter()
                .enumerate()
            {
                let sort = CString::new(format!(r#"{{"key":"{key}","direction":"asc"}}"#)).unwrap();
                assert_eq!(reply(live::cn_sort(engine, sort.as_ptr()))["status"], "ok");
                assert_eq!(search(i as u64 + 1)["metadata_loaded"], false);
            }
            // Backfill also works with FSEvents paused; no watcher is needed for migration.
            assert_eq!(
                reply(live::cn_watch(engine, false, destination.as_ptr()))["status"],
                "ok"
            );
            let started = Instant::now();
            let mut metadata_changed = false;
            loop {
                let polled = reply(live::cn_poll(engine, 0, false));
                // Backfilled dates must not invalidate the displayed results.
                assert_eq!(polled["changed"], false);
                metadata_changed |= polled["metadata_changed"] == true;
                if polled["metadata_indexing"] == false {
                    break;
                }
                assert!(started.elapsed() < Duration::from_secs(3));
                std::thread::sleep(Duration::from_millis(5));
            }
            assert!(metadata_changed);
            let rows = reply(cn_rows(engine, 5, 0, 128));
            assert_eq!(rows["status"], "ok");
            assert_eq!(rows["rows"][0]["modified"], 1_600_000_000_u64);
            let row = search(10);
            assert_eq!(row["modified"], 1_600_000_000_u64);
            assert_eq!(row["created"], created);
            let (id, stale_metadata) = {
                let mut state = (*engine).0.lock().unwrap();
                let id = state.cache.node_index_for_path(&file).unwrap();
                (id, state.cache.expand_cached_file_nodes(&[id])[0].metadata)
            };
            fs::write(&file, "modified contents").unwrap();
            fs::File::options()
                .write(true)
                .open(&file)
                .unwrap()
                .set_times(
                    fs::FileTimes::new()
                        .set_modified(UNIX_EPOCH + Duration::from_secs(1_700_000_000)),
                )
                .unwrap();
            {
                let mut state = (*engine).0.lock().unwrap();
                let event_id = state.cache.last_event_id() + 1;
                state
                    .cache
                    .handle_fs_events(vec![FsEvent {
                        path: file.clone(),
                        id: event_id,
                        flag: EventFlag::ItemModified,
                    }])
                    .unwrap();
                assert!(
                    !state
                        .cache
                        .store_indexed_metadata(id, &file, stale_metadata),
                    "A late background read must not overwrite a newer event"
                );
                state.dirty = true;
            }
            let updated = search(11);
            assert_eq!(updated["modified"], 1_700_000_000_u64);
            assert_eq!(updated["created"], created);
            assert_eq!(reply(live::cn_checkpoint(engine))["status"], "ok");
            cn_engine_close(engine);
            assert_eq!(fs::read(&old).unwrap(), old_bytes);
            fs::remove_file(&file).unwrap();
            let mut reopened = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(destination.as_ptr(), &mut reopened))["status"],
                "ok"
            );
            let sort = CString::new(r#"{"key":"ctime","direction":"asc"}"#).unwrap();
            assert_eq!(
                reply(live::cn_sort(reopened, sort.as_ptr()))["status"],
                "ok"
            );
            let request = cn_request_new();
            assert_eq!(
                reply(cn_search(
                    reopened,
                    request,
                    1,
                    query.as_ptr(),
                    empty.as_ptr(),
                    false
                ))["total"],
                1
            );
            cn_request_free(request);
            let restored = reply(cn_rows(reopened, 1, 0, 128))["rows"][0].clone();
            assert_eq!(restored["created"], created);
            assert_eq!(restored["modified"], 1_700_000_000_u64);
            assert!(
                (*reopened)
                    .0
                    .lock()
                    .unwrap()
                    .cache
                    .pending_metadata_ids()
                    .is_empty()
            );
            cn_engine_close(reopened);
        }
    }

    #[test]
    fn scan_cancellation_returns_while_filesystem_work_is_blocked() {
        let _lock = TEST_LOCK.lock().unwrap();
        let token = CancellationToken::new_scan();
        let (started, ready) = std::sync::mpsc::channel();
        let (release, blocked) = std::sync::mpsc::channel();
        let (done, result) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let answer = live::cancellable_scan(token, move || {
                started.send(()).unwrap();
                blocked.recv().unwrap();
                42
            });
            done.send(answer).unwrap();
        });
        ready
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap();
        live::cn_cancel_scan();
        assert_eq!(
            result
                .recv_timeout(std::time::Duration::from_secs(2))
                .unwrap()
                .unwrap(),
            None
        );
        let current = CancellationToken::new_scan();
        assert!(live::cancellable_scan(current, || 0).is_err());
        release.send(()).unwrap();
        let start = Instant::now();
        loop {
            if let Ok(value) = live::cancellable_scan(current, || 7) {
                assert_eq!(value, Some(7));
                break;
            }
            assert!(start.elapsed() < std::time::Duration::from_secs(2));
            std::thread::yield_now();
        }
    }

    #[test]
    fn selection_remap_tracks_ids_but_rejects_reused_nodes() {
        let _lock = TEST_LOCK.lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a.txt");
        let b = tmp.path().join("b.txt");
        fs::write(&a, b"a").unwrap();
        fs::write(&b, b"b").unwrap();
        let cache = SearchCache::walk_fs(tmp.path());
        let a_id = cache.node_index_for_path(&a).unwrap();
        let b_id = cache.node_index_for_path(&b).unwrap();
        let mut state = State::new(cache, tmp.path().to_owned());
        state.results = vec![a_id, b_id];
        state.generation = 1;
        let mut engine = Engine(Arc::new(Mutex::new(state)));
        let ranges = CString::new("[[0,1]]").unwrap();
        let cached = CString::new("null").unwrap();
        unsafe {
            assert_eq!(
                reply(live::cn_select(
                    &mut engine,
                    1,
                    ranges.as_ptr(),
                    cached.as_ptr()
                ))["selection_count"],
                1
            );
            {
                let mut state = engine.0.lock().unwrap();
                state.results.reverse();
                state.generation = 2;
            }
            let restored = reply(live::cn_selected(&mut engine, 2, true));
            assert_eq!(restored["ranges"], json!([[1, 2]]));
            assert_eq!(restored["paths"], json!([a]));
            {
                let mut state = engine.0.lock().unwrap();
                // Simulate a retained slot now referring to an unselected file.
                state.selection_nodes = vec![b_id];
                state.generation = 3;
            }
            let restored = reply(live::cn_selected(&mut engine, 3, true));
            assert_eq!(restored["selection_count"], 0);
            assert_eq!(restored["ranges"], json!([]));
            assert_eq!(
                reply(live::cn_selection_paths(&mut engine))["paths"],
                json!([])
            );
        }
    }

    #[test]
    #[ignore = "set EVERYTHING_MAC_SELECTION_INDEX to a read-only snapshot for timing"]
    fn selection_refresh_probe() {
        let _lock = TEST_LOCK.lock().unwrap();
        let path = CString::new(std::env::var("EVERYTHING_MAC_SELECTION_INDEX").unwrap()).unwrap();
        let empty = CString::new("").unwrap();
        let ranges = CString::new("[[0,1]]").unwrap();
        let cached = CString::new("null").unwrap();
        unsafe {
            let mut engine = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(path.as_ptr(), &mut engine))["status"],
                "ok"
            );
            for generation in 1..=6 {
                let request = cn_request_new();
                let result = reply(cn_search(
                    engine,
                    request,
                    generation,
                    empty.as_ptr(),
                    empty.as_ptr(),
                    false,
                ));
                cn_request_free(request);
                assert_eq!(result["status"], "ok");
                if generation == 1 {
                    assert_eq!(
                        reply(live::cn_select(
                            engine,
                            generation,
                            ranges.as_ptr(),
                            cached.as_ptr()
                        ))["selection_count"],
                        1
                    );
                } else {
                    let start = Instant::now();
                    let selected = reply(live::cn_selected(engine, generation, false));
                    let elapsed = start.elapsed();
                    assert_eq!(selected["selection_count"], 1);
                    println!(
                        "results={}, selection_refresh_ms={:.3}",
                        result["total"],
                        elapsed.as_secs_f64() * 1000.0
                    );
                }
            }
            cn_engine_close(engine);
        }
    }

    #[test]
    fn bridge_owns_buffers_pages_results_and_rejects_stale_work() {
        let _lock = TEST_LOCK.lock().unwrap();
        let tmp = tempfile::tempdir().unwrap();
        for i in 0..300 {
            fs::write(tmp.path().join(format!("résumé-{i}.txt")), b"x").unwrap();
        }
        let path = tmp.path().join("snapshot");
        SearchCache::walk_fs(tmp.path())
            .flush_to_file(&path)
            .unwrap();
        let before = fs::read(&path).unwrap();
        let cpath = CString::new(path.to_str().unwrap()).unwrap();
        let query = CString::new("résumé").unwrap();
        let empty = CString::new("").unwrap();
        unsafe {
            let mut engine = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(cpath.as_ptr(), &mut engine))["status"],
                "ok"
            );
            let old = cn_request_new();
            let current = cn_request_new();
            assert_eq!(
                reply(cn_search(
                    engine,
                    old,
                    1,
                    query.as_ptr(),
                    empty.as_ptr(),
                    false
                ))["status"],
                "cancelled"
            );
            let result = reply(cn_search(
                engine,
                current,
                2,
                query.as_ptr(),
                empty.as_ptr(),
                false,
            ));
            assert_eq!(result["total"], 300);
            assert_eq!(reply(cn_rows(engine, 1, 0, 10))["status"], "stale");
            let page = reply(cn_rows(engine, 2, 0, usize::MAX));
            assert_eq!(page["rows"].as_array().unwrap().len(), 256);
            assert_eq!(
                reply(cn_rows(engine, 2, 290, 128))["rows"]
                    .as_array()
                    .unwrap()
                    .len(),
                10
            );
            assert!(
                reply(cn_rows(engine, 2, usize::MAX, 128))["rows"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );
            let ranges = CString::new("[[0,300]]").unwrap();
            let no_paths = CString::new("null").unwrap();
            let selected = reply(live::cn_select(
                engine,
                2,
                ranges.as_ptr(),
                no_paths.as_ptr(),
            ));
            assert_eq!(selected["selection_count"], 300);
            assert_eq!(selected["paths"].as_array().unwrap().len(), 128);
            let restored = reply(live::cn_selected(engine, 2, false));
            assert_eq!(restored["ranges"], json!([[0, 300]]));
            assert_eq!(restored["selection_count"], 300);
            assert_eq!(restored["paths"].as_array().unwrap().len(), 128);
            // A removed result is pruned during restoration, without a second
            // cn_select round trip or resurrecting it when it appears again.
            let removed = {
                let mut state = (*engine).0.lock().unwrap();
                state.generation = 3;
                state.results.remove(0)
            };
            assert_eq!(
                reply(live::cn_selected(engine, 3, false))["selection_count"],
                299
            );
            {
                let mut state = (*engine).0.lock().unwrap();
                state.generation = 4;
                state.results.insert(0, removed);
            }
            assert_eq!(
                reply(live::cn_selected(engine, 4, false))["selection_count"],
                299
            );
            // A queued filesystem poll may invalidate rows before a selection lookup.
            {
                let mut state = (*engine).0.lock().unwrap();
                state.generation = 0;
                state.results.clear();
            }
            let action = reply(live::cn_selection_paths(engine));
            assert_eq!(action["status"], "ok");
            assert_eq!(action["paths"].as_array().unwrap().len(), 299);
            // A stale/reused node slot must not turn an unselected path into
            // an action target, even though the action ignores result generations.
            let saved = {
                let mut state = (*engine).0.lock().unwrap();
                std::mem::replace(&mut state.selection_nodes[0], removed)
            };
            assert_eq!(reply(live::cn_selection_paths(engine))["status"], "error");
            (*engine).0.lock().unwrap().selection_nodes[0] = saved;
            let mut replacement = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(cpath.as_ptr(), &mut replacement))["status"],
                "ok"
            );
            assert_eq!(
                reply(live::cn_transfer_selection(engine, replacement))["status"],
                "ok"
            );
            assert_eq!(
                reply(live::cn_selection_paths(replacement))["paths"]
                    .as_array()
                    .unwrap()
                    .len(),
                299
            );
            assert!(
                reply(live::cn_selection_paths(engine))["paths"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );
            assert_eq!(
                reply(live::cn_transfer_selection(replacement, engine))["status"],
                "ok"
            );
            cn_engine_close(replacement);
            assert_eq!(
                reply(live::cn_select(
                    engine,
                    2,
                    ranges.as_ptr(),
                    no_paths.as_ptr()
                ))["status"],
                "stale"
            );
            assert!(
                reply(live::cn_selected(engine, 0, true))["paths"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );
            assert!(
                reply(live::cn_selection_paths(engine))["paths"]
                    .as_array()
                    .unwrap()
                    .is_empty()
            );
            cn_cancel();
            assert_eq!(
                reply(cn_search(
                    engine,
                    current,
                    3,
                    query.as_ptr(),
                    empty.as_ptr(),
                    false
                ))["status"],
                "cancelled"
            );
            cn_request_free(old);
            cn_request_free(current);
            cn_engine_close(engine);
            let mut invalid = ptr::null_mut();
            let missing = CString::new(tmp.path().join("missing").to_str().unwrap()).unwrap();
            assert_eq!(
                reply(cn_engine_open(missing.as_ptr(), &mut invalid))["status"],
                "error"
            );
            assert!(invalid.is_null());
        }
        assert_eq!(fs::read(&path).unwrap(), before);
        let panic = guarded(|| panic!("contained test panic"));
        unsafe {
            assert_eq!(reply(panic)["status"], "error");
        }
    }
    #[test]
    fn scan_sort_selection_and_checkpoint_preserve_source_and_reject_cancelled_scan() {
        use super::live::*;
        let _lock = TEST_LOCK.lock().unwrap();
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("files");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("alpha.txt"), b"short").unwrap();
        fs::write(root.join("beta.txt"), b"longer file").unwrap();
        let root = root.canonicalize().unwrap();
        let croot = CString::new(root.to_str().unwrap()).unwrap();
        let empty_array = CString::new("[]").unwrap();
        let source = temp.path().join("original.db");
        SearchCache::walk_fs(&root).flush_to_file(&source).unwrap();
        let before = fs::read(&source).unwrap();
        unsafe {
            let mut engine = ptr::null_mut();
            let old = cn_scan_request_new();
            cn_cancel_scan();
            assert_eq!(
                reply(cn_scan(
                    croot.as_ptr(),
                    empty_array.as_ptr(),
                    empty_array.as_ptr(),
                    empty_array.as_ptr(),
                    old,
                    &mut engine
                ))["status"],
                "cancelled"
            );
            assert!(engine.is_null());
            cn_request_free(old);
            let request = cn_scan_request_new();
            assert_eq!(
                reply(cn_scan(
                    croot.as_ptr(),
                    empty_array.as_ptr(),
                    empty_array.as_ptr(),
                    empty_array.as_ptr(),
                    request,
                    &mut engine
                ))["status"],
                "ok"
            );
            cn_request_free(request);
            let sort = CString::new(r#"{"key":"size","direction":"desc"}"#).unwrap();
            assert_eq!(reply(cn_sort(engine, sort.as_ptr()))["status"], "ok");
            let query = CString::new(".txt").unwrap();
            let empty = CString::new("").unwrap();
            let request = cn_request_new();
            assert_eq!(
                reply(cn_search(
                    engine,
                    request,
                    7,
                    query.as_ptr(),
                    empty.as_ptr(),
                    false
                ))["total"],
                2
            );
            cn_request_free(request);
            let page = reply(cn_rows(engine, 7, 0, 128));
            assert!(
                page["rows"][0]["path"]
                    .as_str()
                    .unwrap()
                    .ends_with("beta.txt")
            );
            let indices = CString::new("[0]").unwrap();
            let selected = reply(cn_paths(engine, 7, indices.as_ptr()));
            let selected = CString::new(selected["paths"].to_string()).unwrap();
            assert_eq!(
                reply(cn_locate(engine, 7, selected.as_ptr()))["indices"],
                json!([0])
            );
            assert_eq!(
                reply(cn_paths(engine, 6, indices.as_ptr()))["status"],
                "stale"
            );
            let checkpoint = temp.path().join("native/index.db");
            let destination = CString::new(checkpoint.to_str().unwrap()).unwrap();
            assert_eq!(
                reply(cn_watch(engine, false, destination.as_ptr()))["status"],
                "ok"
            );
            assert_eq!(reply(cn_checkpoint(engine))["status"], "ok");
            cn_engine_close(engine);
            assert_eq!(fs::read(&source).unwrap(), before);
            let mut reopened = ptr::null_mut();
            assert_eq!(
                reply(cn_engine_open(destination.as_ptr(), &mut reopened))["status"],
                "ok"
            );
            cn_engine_close(reopened);
        }
    }
}
