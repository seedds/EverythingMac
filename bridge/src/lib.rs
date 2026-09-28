//! Throwaway C bridge for the native UI experiment. See include/cardinal_native.h.
mod live;
mod sort;

use search_cache::{SearchCache, SearchOptions, SearchQuery, SlabIndex, read_cache_from_file};
use search_cancel::CancellationToken;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr,
    sync::{Mutex, atomic::AtomicBool},
    time::Instant,
};

static STOP: AtomicBool = AtomicBool::new(false);
const MAX_PAGE: usize = 256;

pub struct Engine(Mutex<State>);
struct State {
    cache: SearchCache,
    results: Vec<SlabIndex>,
    generation: u64,
    root: std::path::PathBuf,
    watcher: Option<cardinal_sdk::EventWatcher>,
    event_root: std::path::PathBuf,
    needs_rescan: bool,
    checkpoint: Option<std::path::PathBuf>,
    dirty: bool,
    events: std::collections::VecDeque<Value>,
    processed_events: u64,
    sort: Option<sort::SortStatePayload>,
    sort_limit: usize,
    selection: std::collections::HashSet<[u64; 2]>,
    selection_positions: Vec<usize>,
    selection_generation: Option<u64>,
}
impl State {
    fn new(cache: SearchCache, root: std::path::PathBuf) -> Self {
        Self {
            cache,
            root: root.clone(),
            event_root: root,
            results: vec![],
            generation: 0,
            watcher: None,
            needs_rescan: false,
            checkpoint: None,
            dirty: true,
            events: Default::default(),
            processed_events: 0,
            sort: None,
            sort_limit: 20000,
            selection: Default::default(),
            selection_positions: vec![],
            selection_generation: None,
        }
    }
}
pub struct Request(CancellationToken);

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
        let storage = read_cache_from_file(Path::new(&path)).map_err(|e| format!("{e:#}"))?;
        let root = storage.path.clone();
        let ignores = storage.ignore_paths.clone();
        let includes = storage.include_paths.clone();
        let cache = SearchCache::from_persistent_storage(storage, &STOP);
        let total = cache.get_total_files();
        let engine = Box::new(Engine(Mutex::new(State::new(cache, root.clone()))));
        unsafe {
            *out = Box::into_raw(engine);
        }
        Ok(
            json!({"status":"ok", "total":total, "root":root, "ignores":ignores, "includes":includes, "load_ms":started.elapsed().as_secs_f64()*1000.0}),
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
    Box::into_raw(Box::new(Request(CancellationToken::new_search())))
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
        if let Some(sort) = state.sort.filter(|_| results.len() <= state.sort_limit) {
            let nodes = state.cache.expand_file_nodes(&results);
            let mut entries: Vec<_> = results
                .into_iter()
                .zip(nodes)
                .map(|(id, node)| sort::SortEntry::new(id, node))
                .collect();
            sort::sort_entries(&mut entries, &sort);
            results = entries.into_iter().map(|e| e.slab_index).collect();
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
        let engine = Box::into_raw(Box::new(Engine(Mutex::new(state))));
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
                    request,
                    &mut engine
                ))["status"],
                "ok"
            );
            cn_request_free(request);
            let sort = CString::new(r#"{"key":"size","direction":"desc"}"#).unwrap();
            assert_eq!(reply(cn_sort(engine, sort.as_ptr(), 20000))["status"], "ok");
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
