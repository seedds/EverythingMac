//! Serialized engine operations; FSEvents callbacks only enqueue SDK events.
use super::*;
use crossbeam_channel::TryRecvError;
use everything_mac_sdk::EventWatcher;
use search_cache::{HandleFSEError, WalkData};
use std::{collections::HashSet, fs, os::fd::AsRawFd, path::PathBuf};

// A filesystem syscall can wait on a disconnected volume or an OS permission
// prompt. Keep at most one scan worker alive, and let cancellation release the
// serialized engine queue without waiting for that syscall to return.
static SCAN_ACTIVE: AtomicBool = AtomicBool::new(false);
struct ScanSlot;
impl Drop for ScanSlot {
    fn drop(&mut self) {
        SCAN_ACTIVE.store(false, std::sync::atomic::Ordering::Release);
    }
}
pub(super) fn cancellable_scan<T: Send + 'static>(
    token: CancellationToken,
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<Option<T>, String> {
    use std::sync::{atomic::Ordering, mpsc};
    if token.is_cancelled().is_none() {
        return Ok(None);
    }
    SCAN_ACTIVE.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| "Previous scan is still waiting on macOS filesystem access. Retry once access resumes.")?;
    let slot = ScanSlot;
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name("everything-mac-native-scan".into())
        .spawn(move || {
            let result =
                catch_unwind(AssertUnwindSafe(work)).map_err(|_| "Index scan panicked".to_string());
            drop(slot);
            let _ = sender.send(result);
        })
        .map_err(|e| e.to_string())?;
    loop {
        if token.is_cancelled().is_none() {
            return Ok(None);
        }
        match receiver.recv_timeout(std::time::Duration::from_millis(25)) {
            Ok(result) => {
                return if token.is_cancelled().is_some() {
                    result.map(Some)
                } else {
                    Ok(None)
                };
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("Index scan worker stopped".into());
            }
        }
    }
}

fn canonical_scope(path: PathBuf) -> PathBuf {
    let mut ancestor = path.as_path();
    let mut suffix = Vec::new();
    loop {
        if let Ok(mut resolved) = ancestor.canonicalize() {
            for component in suffix.into_iter().rev() {
                resolved.push(component);
            }
            return resolved;
        }
        let Some(name) = ancestor.file_name() else {
            return path;
        };
        suffix.push(name.to_os_string());
        let Some(parent) = ancestor.parent() else {
            return path;
        };
        ancestor = parent;
    }
}

fn watch(state: &mut State) {
    state.event_root = state
        .root
        .canonicalize()
        .unwrap_or_else(|_| state.root.clone());
    state.watcher = Some(
        EventWatcher::spawn(
            state.root.to_string_lossy().into_owned(),
            state.cache.last_event_id(),
            0.1,
            state.cache.ignore_paths(),
            state.cache.include_paths(),
        )
        .1,
    );
}

#[unsafe(no_mangle)]
pub extern "C" fn cn_scan_request_new() -> *mut Request {
    Box::into_raw(Box::new(Request(
        CancellationToken::new_scan(),
        Arc::default(),
    )))
}
/// Read progress without waiting for the serialized engine queue.
/// # Safety
/// The request must remain alive throughout this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_scan_count(request: *const Request) -> usize {
    unsafe { request.as_ref() }.map_or(0, |r| r.1.load(std::sync::atomic::Ordering::Relaxed))
}

// Sample existing walker counters, avoiding another atomic operation per file.
// Disconnecting the channel also stops the sampler if traversal panics.
pub(super) fn with_scan_progress<F: Fn() -> bool + Sync, T>(
    walk: &WalkData<'_, F>,
    progress: &AtomicUsize,
    work: impl FnOnce() -> T,
) -> T {
    use std::sync::{atomic::Ordering, mpsc};
    std::thread::scope(|scope| {
        let (done, receiver) = mpsc::channel::<()>();
        scope.spawn(move || {
            loop {
                progress.store(
                    walk.num_files.load(Ordering::Relaxed) + walk.num_dirs.load(Ordering::Relaxed),
                    Ordering::Relaxed,
                );
                if !matches!(
                    receiver.recv_timeout(std::time::Duration::from_millis(100)),
                    Err(mpsc::RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
        });
        let result = work();
        drop(done);
        result
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn cn_cancel_scan() {
    let _ = CancellationToken::new_scan();
}

/// # Safety
/// Valid serialized handle. The checkpoint filename must belong to the native app.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_watch(
    engine: *mut Engine,
    enabled: bool,
    checkpoint: *const c_char,
) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let path = PathBuf::from(unsafe { text(checkpoint)? });
        if !path.is_absolute() {
            return Err("Native checkpoint must be absolute".into());
        }
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        // A checkpoint elsewhere (such as a migrated filename) must be written
        // even though the loaded index itself is unchanged.
        if state.loaded_from.as_deref() != Some(path.as_path()) {
            state.dirty = true;
        }
        state.checkpoint = Some(path);
        state.watcher = None;
        if enabled {
            watch(&mut state);
        }
        drop(state);
        // Registering a live/native index also migrates snapshots whose dates
        // have not yet been collected. Snapshot-only tools never call cn_watch.
        metadata::start(&engine.0);
        Ok(json!({"status":"ok"}))
    })
}

/// # Safety
/// Valid serialized handle. Old row IDs are invalidated before returning changes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_poll(
    engine: *mut Engine,
    since_processed: u64,
    include_events: bool,
) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        // Metadata backfill never frees or reuses slab IDs, so the current results
        // and row generation stay valid; only structural changes invalidate them.
        let mut metadata_changed = std::mem::take(&mut state.metadata.changed);
        let mut changed = false;
        let mut watcher_stopped = false;
        for _ in 0..16 {
            let events = match state.watcher.as_ref().map(|w| w.try_recv()) {
                Some(Ok(events)) => events,
                Some(Err(TryRecvError::Disconnected)) => {
                    // Earlier batches may already have changed the index; still
                    // invalidate old row IDs below before reporting the failure.
                    state.watcher = None;
                    watcher_stopped = true;
                    break;
                }
                _ => break,
            };
            let events: Vec<_> = events.into_iter().filter_map(|mut event| {
                if let Some(parent) = state.checkpoint.as_ref().and_then(|p| p.parent())
                    && event.path.starts_with(parent) { return None; }
                if state.event_root != state.root
                    && let Ok(suffix) = event.path.strip_prefix(&state.event_root) {
                    event.path = state.root.join(suffix);
                }
                state.processed_events += 1;
                // FSEvents paths are raw bytes; serializing a non-UTF-8 Path would panic.
                state.events.push_front(json!({"id":event.id, "path":event.path.to_string_lossy(),
                    "flags":format!("{:?}",event.flag),
                    "time":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs_f64()}));
                state.events.truncate(500);
                Some(event)
            }).collect();
            let old_checkpoint = state.cache.last_event_id();
            match state.cache.handle_fs_events(events) {
                Ok(touched) => changed |= touched,
                Err(HandleFSEError::Rescan) => {
                    state.watcher = None;
                    state.needs_rescan = true;
                    changed = true;
                }
            }
            state.dirty |= state.cache.last_event_id() != old_checkpoint;
            if state.needs_rescan {
                break;
            }
        }
        // Attribute-only events update sizes and dates in place, keeping row IDs.
        if state.cache.take_metadata_changed() {
            metadata_changed = true;
            state.dirty = true;
        }
        if changed {
            state.results.clear();
            state.generation = 0;
            state.dirty = true;
        }
        let mut reply = json!({"status":"ok", "changed":changed, "needs_rescan":state.needs_rescan,
            "metadata_changed":metadata_changed, "watcher_stopped":watcher_stopped,
            "total":state.cache.get_total_files(), "processed_events":state.processed_events,
            "metadata_indexing":state.metadata.active()});
        // The event list is only for the visible Events tab, and only when it changed.
        if include_events && state.processed_events != since_processed {
            reply["events"] = json!(state.events);
        }
        Ok(reply)
    })
}

/// # Safety
/// Valid UTF-8 root, JSON configuration arrays, request and writable output.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_scan(
    root: *const c_char,
    ignores: *const c_char,
    includes: *const c_char,
    patterns: *const c_char,
    request: *const Request,
    out: *mut *mut Engine,
) -> Buffer {
    guarded(|| {
        if out.is_null() {
            return Err("Missing engine output".into());
        }
        unsafe {
            *out = ptr::null_mut();
        }
        let root = PathBuf::from(unsafe { text(root)? });
        if !root.is_absolute() {
            return Err("Choose an absolute folder".into());
        }
        let ignores: Vec<PathBuf> =
            serde_json::from_str(&unsafe { text(ignores)? }).map_err(|e| e.to_string())?;
        let includes: Vec<PathBuf> =
            serde_json::from_str(&unsafe { text(includes)? }).map_err(|e| e.to_string())?;
        if ignores.iter().chain(&includes).any(|p| !p.is_absolute()) {
            return Err("Include and ignore paths must be absolute".into());
        }
        let patterns: Vec<String> =
            serde_json::from_str(&unsafe { text(patterns)? }).map_err(|e| e.to_string())?;
        fswalk::Exclusions::compile(&root, &patterns)?;
        let request = unsafe { request.as_ref() }.ok_or("Missing scan request")?;
        let token = request.0;
        let progress = request.1.clone();
        let start = Instant::now();
        let Some(scanned) = cancellable_scan(token, move || -> Result<_, String> {
            // Preflight may block too; every filesystem access belongs to this worker.
            if !root.is_dir() {
                return Err("Choose an existing folder".into());
            }
            let root = root.canonicalize().map_err(|e| e.to_string())?;
            let mut ignores: Vec<_> = ignores.into_iter().map(canonical_scope).collect();
            let includes: Vec<_> = includes.into_iter().map(canonical_scope).collect();
            if !ignores
                .iter()
                .any(|p| p == Path::new("/System/Volumes/Data"))
            {
                ignores.push("/System/Volumes/Data".into());
            }
            // Do not let blocked traversal occupy the search engine's Rayon pool.
            let pool = rayon::ThreadPoolBuilder::new()
                .num_threads(4)
                .thread_name(|i| format!("everything-mac-native-walk-{i}"))
                .build()
                .map_err(|e| e.to_string())?;
            let exclusions = fswalk::Exclusions::compile(&root, &patterns)?;
            let cache = pool.install(|| {
                let walk = WalkData::new(&root, &ignores, &includes, false, move || {
                    token.is_cancelled().is_none()
                })
                .with_exclusions(exclusions);
                with_scan_progress(&walk, &progress, || {
                    SearchCache::walk_fs_with_walk_data(&walk, &STOP)
                })
            });
            Ok(cache.map(|cache| (cache, root, ignores, includes)))
        })?
        else {
            return Ok(json!({"status":"cancelled"}));
        };
        let Some((cache, root, ignores, includes)) = scanned? else {
            return Ok(json!({"status":"cancelled"}));
        };
        let total = cache.get_total_files();
        let patterns = cache.exclusion_patterns().to_vec();
        unsafe {
            *out = Box::into_raw(Box::new(Engine(Arc::new(Mutex::new(State::new(
                cache,
                root.clone(),
            ))))));
        }
        Ok(
            json!({"status":"ok", "root":root, "total":total, "ignores":ignores, "includes":includes, "exclusion_patterns":patterns,
            "load_ms":start.elapsed().as_secs_f64()*1000.0}),
        )
    })
}

/// # Safety
/// Valid serialized engine; only its previously configured native checkpoint is written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_checkpoint(engine: *mut Engine) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        let path = state
            .checkpoint
            .clone()
            .ok_or("No native checkpoint configured")?;
        if state.needs_rescan {
            return Err("Rescan required before saving index".into());
        }
        if !state.dirty && path.exists() {
            return Ok(json!({"status":"ok"}));
        }
        fs::create_dir_all(path.parent().ok_or("No checkpoint parent")?)
            .map_err(|e| e.to_string())?;
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path.with_extension("lock"))
            .map_err(|e| e.to_string())?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Another instance is saving the native index".into());
        }
        state
            .cache
            .flush_snapshot_to_file(&path)
            .map_err(|e| format!("{e:#}"))?;
        state.dirty = false;
        Ok(json!({"status":"ok"}))
    })
}

/// # Safety
/// Valid handle and UTF-8 JSON sort descriptor (or null).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_sort(engine: *mut Engine, sort: *const c_char) -> Buffer {
    guarded(|| {
        let sort: Option<sort::SortStatePayload> =
            serde_json::from_str(&unsafe { text(sort)? }).map_err(|e| e.to_string())?;
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        state.sort = sort;
        Ok(json!({"status":"ok"}))
    })
}

/// # Safety
/// Valid handle and JSON positions. Used only for explicit selection/file actions.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_paths(
    engine: *mut Engine,
    generation: u64,
    indices: *const c_char,
) -> Buffer {
    guarded(|| {
        let indices: Vec<usize> =
            serde_json::from_str(&unsafe { text(indices)? }).map_err(|e| e.to_string())?;
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        if state.generation != generation {
            return Ok(json!({"status":"stale"}));
        }
        let paths: Vec<_> = indices
            .into_iter()
            .filter_map(|i| state.results.get(i))
            .filter_map(|id| state.cache.node_path(*id))
            .collect();
        Ok(json!({"status":"ok", "paths":paths}))
    })
}

/// # Safety
/// Valid handle and JSON paths; resolves current identities rather than stale slab IDs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_locate(
    engine: *mut Engine,
    generation: u64,
    paths: *const c_char,
) -> Buffer {
    guarded(|| {
        let paths: Vec<PathBuf> =
            serde_json::from_str(&unsafe { text(paths)? }).map_err(|e| e.to_string())?;
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        if state.generation != generation {
            return Ok(json!({"status":"stale"}));
        }
        let ids: HashSet<_> = paths
            .iter()
            .filter_map(|p| state.cache.node_index_for_path(p))
            .collect();
        let indices: Vec<_> = state
            .results
            .iter()
            .enumerate()
            .filter_map(|(i, id)| ids.contains(id).then_some(i))
            .collect();
        Ok(json!({"status":"ok", "indices":indices}))
    })
}

fn path_identity(path: &Path) -> [u64; 2] {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut hasher);
    let first = hasher.finish();
    let mut second = std::collections::hash_map::DefaultHasher::new();
    0x43415244494e414c_u64.hash(&mut second);
    path.hash(&mut second);
    [first, second.finish()]
}

/// # Safety
/// Valid serialized handle and JSON half-open ranges, plus complete cached paths
/// or null. Large passive selections stay in Rust as fixed-size identities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_select(
    engine: *mut Engine,
    generation: u64,
    ranges: *const c_char,
    cached: *const c_char,
) -> Buffer {
    guarded(|| {
        let ranges: Vec<[usize; 2]> =
            serde_json::from_str(&unsafe { text(ranges)? }).map_err(|e| e.to_string())?;
        let cached: Option<Vec<PathBuf>> =
            serde_json::from_str(&unsafe { text(cached)? }).map_err(|e| e.to_string())?;
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        // An unsuccessful replacement must never leave the previous file actionable.
        state.selection.clear();
        state.selection_nodes.clear();
        state.selection_positions.clear();
        state.selection_generation = None;
        let mut sample = Vec::new();
        if generation != state.generation {
            let Some(paths) = cached else {
                return Ok(json!({"status":"stale"}));
            };
            for path in paths {
                if let Some(id) = state.cache.node_index_for_path(&path)
                    && state.selection.insert(path_identity(&path))
                {
                    state.selection_nodes.push(id);
                    if sample.len() < 128 {
                        sample.push(path);
                    }
                }
            }
        } else {
            if ranges
                .iter()
                .any(|[start, end]| start > end || *end > state.results.len())
            {
                return Err("Invalid selection range".into());
            }
            for [start, end] in ranges {
                for i in start..end {
                    if let Some(path) = state.cache.node_path(state.results[i]) {
                        if state.selection.insert(path_identity(&path)) {
                            let id = state.results[i];
                            state.selection_nodes.push(id);
                        }
                        state.selection_positions.push(i);
                        if sample.len() < 128 {
                            sample.push(path);
                        }
                    }
                }
            }
        }
        if generation == state.generation {
            state.selection_positions.sort_unstable();
            state.selection_positions.dedup();
            state.selection_generation = Some(generation);
        }
        Ok(json!({"status":"ok","paths":sample,"selection_count":state.selection.len()}))
    })
}

/// # Safety
/// Valid serialized handle. Returns compact ranges, or paths for an explicit action.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_selected(engine: *mut Engine, generation: u64, paths: bool) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        if generation != state.generation {
            return Ok(json!({"status":"stale"}));
        }
        // Remap only after a new search or filesystem update. Repeated actions on
        // unchanged rows read only the selected positions, even in a broad query.
        if state.selection_generation != Some(generation) {
            // Validate only retained selections. Rebuilding and hashing the path
            // of every result made one selected row stall broad live searches.
            // IDs alone are insufficient: deleted slots can be reused.
            let selected: std::collections::HashMap<_, _> = state
                .selection_nodes
                .iter()
                .filter_map(|id| {
                    let identity = path_identity(&state.cache.node_path(*id)?);
                    state
                        .selection
                        .contains(&identity)
                        .then_some((*id, identity))
                })
                .collect();
            let mut surviving = std::collections::HashSet::new();
            state.selection_positions = if selected.is_empty() {
                vec![]
            } else {
                state
                    .results
                    .iter()
                    .enumerate()
                    .filter_map(|(i, id)| {
                        let identity = selected.get(id)?;
                        surviving.insert(*identity);
                        Some(i)
                    })
                    .collect()
            };
            state.selection = surviving;
            state.selection_nodes = state
                .selection_positions
                .iter()
                .map(|&i| state.results[i])
                .collect();
            state.selection_generation = Some(generation);
        }
        let mut ranges: Vec<[usize; 2]> = Vec::new();
        let mut selected_paths = Vec::new();
        for &i in &state.selection_positions {
            if (paths || selected_paths.len() < 128)
                && let Some(path) = state.cache.node_path(state.results[i])
            {
                selected_paths.push(path);
            }
            if let Some(last) = ranges.last_mut()
                && last[1] == i
            {
                last[1] = i + 1;
            } else {
                ranges.push([i, i + 1]);
            }
        }
        Ok(json!({"status":"ok","ranges":ranges,"paths":selected_paths,
            "selection_count":state.selection_positions.len()}))
    })
}

/// Resolve an explicit action from retained selection identities, not result rows.
/// # Safety
/// Engine must be live and calls serialized. Reused slab slots must never target
/// a different path after filesystem events invalidate the displayed generation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_selection_paths(engine: *mut Engine) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        let paths: Vec<_> = state
            .selection_nodes
            .iter()
            .filter_map(|&id| {
                state
                    .cache
                    .node_path(id)
                    .filter(|path| state.selection.contains(&path_identity(path)))
            })
            .collect();
        if paths.len() != state.selection.len() {
            return Err("One or more selected files moved or disappeared. Select the remaining files again.".into());
        }
        Ok(json!({"status":"ok", "paths":paths}))
    })
}

/// # Safety
/// Distinct valid serialized handles; move only stable path identities across a rescan.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_transfer_selection(from: *mut Engine, to: *mut Engine) -> Buffer {
    guarded(|| {
        if from == to {
            return Err("Selection transfer requires different engines".into());
        }
        if let Some(old) = unsafe { from.as_ref() } {
            let new = unsafe { to.as_ref() }.ok_or("No destination engine")?;
            let mut old = old.0.lock().map_err(|_| "Old engine faulted")?;
            let mut new = new.0.lock().map_err(|_| "New engine faulted")?;
            new.selection_nodes = old
                .selection_nodes
                .iter()
                .filter_map(|&id| {
                    old.cache
                        .node_path(id)
                        .filter(|path| old.selection.contains(&path_identity(path)))
                        .and_then(|path| new.cache.node_index_for_path(&path))
                })
                .collect();
            new.selection = std::mem::take(&mut old.selection);
            new.selection_positions.clear();
            new.selection_generation = None;
            old.selection_nodes.clear();
            old.selection_positions.clear();
            old.selection_generation = None;
        }
        Ok(json!({"status":"ok"}))
    })
}

/// Validate patterns without starting a scan or touching the filesystem.
/// # Safety
/// Patterns must be a NUL-terminated UTF-8 JSON string array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_validate_exclusions(patterns: *const c_char) -> Buffer {
    guarded(|| {
        let patterns: Vec<String> =
            serde_json::from_str(&unsafe { text(patterns)? }).map_err(|e| e.to_string())?;
        fswalk::Exclusions::compile(Path::new("/"), &patterns)?;
        Ok(json!({"status":"ok"}))
    })
}
