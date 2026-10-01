//! Serialized engine operations; FSEvents callbacks only enqueue SDK events.
use super::*;
use crossbeam_channel::TryRecvError;
use everything_mac_sdk::{EventFlag, EventWatcher, FsEvent};
use search_cache::{EventScan, HandleFSEError, NodeIdentity, ScannedEvents, WalkData};
use std::{
    collections::HashSet,
    fs,
    os::fd::AsRawFd,
    path::PathBuf,
    sync::{LazyLock, atomic::Ordering, mpsc},
    time::Duration,
};

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
            let result = catch_unwind(AssertUnwindSafe(work))
                .map_err(|payload| format!("Index scan failed: {}", panic_message(&*payload)));
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

/// How long a poll holds the engine for live updates: it waits this long for the
/// walks it starts, so that small changes still appear in the same poll, and
/// applies what walks found until then. Larger changes continue in the next
/// polls, which the app sends soon after, so searches run in between.
const POLL_TIME: Duration = Duration::from_millis(10);

/// Walks of the folders an event batch changed, running without the engine lock.
/// Later batches wait for them and for what they found to be applied, since they
/// may depend on the result. Dropping it cancels the walks.
pub(super) struct PendingWalk {
    result: mpsc::Receiver<Option<ScannedEvents>>,
    cancel: Arc<AtomicBool>,
}

impl Drop for PendingWalk {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}

/// Threads for walking folders. A scan of `/` opens more folders than the kernel
/// keeps vnodes for, so each open recycles one under a shared lock: past about
/// six threads, walks spend more time waiting than they gain.
fn walk_threads() -> usize {
    std::thread::available_parallelism().map_or(4, |cores| cores.get().clamp(2, 6))
}

// Like full scans, walks must not occupy the search pool while a syscall blocks.
static WALK_POOL: LazyLock<rayon::ThreadPool> = LazyLock::new(|| {
    rayon::ThreadPoolBuilder::new()
        .num_threads(walk_threads())
        .thread_name(|i| format!("everything-mac-native-live-walk-{i}"))
        .build()
        .expect("create live walk pool")
});

pub(super) fn start_walk(scan: EventScan) -> PendingWalk {
    let cancel = Arc::new(AtomicBool::new(false));
    let stop = cancel.clone();
    let (sender, result) = mpsc::sync_channel(1);
    #[cfg(test)]
    let gate = super::tests::walk_gate(scan.paths());
    WALK_POOL.spawn(move || {
        let scanned = catch_unwind(AssertUnwindSafe(|| {
            scan.scan(|| stop.load(Ordering::Relaxed))
        }))
        .ok()
        .flatten();
        #[cfg(test)]
        if let Some(gate) = gate {
            gate();
        }
        let _ = sender.send(scanned);
    });
    PendingWalk { result, cancel }
}

/// Applies the pending walk until `deadline` if it finishes by `wait_until`.
/// Returns whether no walk is left pending or partly applied.
pub(super) fn finish_walk(
    state: &mut State,
    wait_until: Instant,
    deadline: Instant,
    changed: &mut bool,
) -> bool {
    if state.applying.is_none() {
        let Some(walk) = &state.walk else {
            return true;
        };
        let scanned = match walk
            .result
            .recv_timeout(wait_until.saturating_duration_since(Instant::now()))
        {
            Ok(scanned) => scanned,
            Err(mpsc::RecvTimeoutError::Timeout) => return false,
            Err(mpsc::RecvTimeoutError::Disconnected) => None,
        };
        state.walk = None;
        let Some(scanned) = scanned else {
            // Only a panic ends a walk early; what it covered needs a full rescan.
            state.watcher = None;
            state.needs_rescan = true;
            *changed = true;
            return true;
        };
        state.applying = Some(scanned.into_changes());
    }
    let changes = state.applying.as_mut().expect("set above");
    let old_checkpoint = state.cache.last_event_id();
    *changed |= state.cache.apply_changes(changes, Some(deadline));
    state.events_dirty |= state.cache.last_event_id() != old_checkpoint;
    if !changes.is_done() {
        return false;
    }
    state.applying = None;
    // The walk may have read items that the app removed while it ran.
    let removed = std::mem::take(&mut state.removed_during_walk);
    if !removed.is_empty() {
        *changed |= remove_paths(state, removed);
    }
    true
}

fn apply_scanned(state: &mut State, scanned: ScannedEvents, changed: &mut bool) {
    let old_checkpoint = state.cache.last_event_id();
    *changed |= state.cache.apply_fs_events(scanned);
    state.events_dirty |= state.cache.last_event_id() != old_checkpoint;
}

/// Removes paths the app itself removed. Returns whether the index changed.
fn remove_paths(state: &mut State, paths: Vec<PathBuf>) -> bool {
    // Keep the FSEvents position: these events are replayed confirmations.
    let id = state.cache.last_event_id();
    let events = paths
        .into_iter()
        .map(|path| FsEvent {
            path,
            id,
            flag: EventFlag::ItemRemoved,
        })
        .collect();
    match state.cache.handle_fs_events(events) {
        Ok(changed) => changed,
        Err(HandleFSEError::Rescan) => {
            state.watcher = None;
            state.needs_rescan = true;
            true
        }
    }
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

/// Whether no scan was started or cancelled since `request`'s.
/// # Safety
/// The request must remain alive throughout this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_scan_current(request: *const Request) -> bool {
    unsafe { request.as_ref() }.is_some_and(|r| r.0.is_cancelled().is_some())
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
            // Indexes saved before scans skipped other volumes still contain them.
            state.prune_volumes = true;
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
        let mut state = match engine.0.lock() {
            Ok(state) => state,
            Err(poisoned) => {
                // A panic while the engine was locked, such as in a search, may have
                // left the index inconsistent. Ask for a rescan, which builds a new
                // engine, instead of failing every call until the app is relaunched.
                engine.0.clear_poison();
                let mut state = poisoned.into_inner();
                stop_for_rescan(&mut state);
                state
            }
        };
        // Metadata backfill never frees or reuses slab IDs, so the current results
        // and row generation stay valid; only structural changes invalidate them.
        let mut metadata_changed = std::mem::take(&mut state.metadata.changed);
        let mut changed = false;
        let mut watcher_stopped = false;
        let walking = contain(&mut state, |state| {
            apply_events(state, &mut changed, &mut watcher_stopped)
        })
        .unwrap_or_else(|| {
            changed = true;
            false
        });
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
            "metadata_changed":metadata_changed, "watcher_stopped":watcher_stopped, "walking":walking,
            "applying":state.applying.is_some(),
            "total":state.cache.get_total_files(), "processed_events":state.processed_events,
            "metadata_indexing":state.metadata.active()});
        // The event list is only for the visible Events tab, and only when it changed.
        if include_events && state.processed_events != since_processed {
            reply["events"] = json!(state.events);
        }
        Ok(reply)
    })
}

/// Applies queued filesystem events to the index. Returns whether a folder walk is
/// still running.
fn apply_events(state: &mut State, changed: &mut bool, watcher_stopped: &mut bool) -> bool {
    if std::mem::take(&mut state.prune_volumes) {
        *changed |= state.cache.remove_other_volumes();
    }
    let started = Instant::now();
    let deadline = started + POLL_TIME;
    // Walks started by earlier polls are not waited for.
    let mut walking = !finish_walk(state, started, deadline, changed);
    for _ in 0..16 {
        if walking || state.needs_rescan {
            break;
        }
        let events = match state.watcher.as_ref().map(|w| w.try_recv()) {
            Some(Ok(events)) => events,
            Some(Err(TryRecvError::Disconnected)) => {
                // Earlier batches may already have changed the index; still
                // invalidate old row IDs below before reporting the failure.
                state.watcher = None;
                *watcher_stopped = true;
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
        match state.cache.plan_fs_events(events) {
            // Without paths to read, applying only records the event position.
            Ok(scan) if scan.is_empty() => {
                if let Some(scanned) = scan.scan(|| false) {
                    apply_scanned(state, scanned, changed);
                }
            }
            Ok(scan) => {
                state.walk = Some(start_walk(scan));
                walking = !finish_walk(state, deadline, deadline, changed);
            }
            Err(HandleFSEError::Rescan) => {
                state.watcher = None;
                state.needs_rescan = true;
                *changed = true;
            }
        }
    }
    walking
}

/// Runs a change to the index. A panic, such as a failure to grow the index's
/// memory, becomes a request for a full rescan instead of unwinding through the
/// engine lock, which would make every later call fail. Returns `None` after one.
pub(super) fn contain<T>(state: &mut State, change: impl FnOnce(&mut State) -> T) -> Option<T> {
    match catch_unwind(AssertUnwindSafe(|| change(&mut *state))) {
        Ok(value) => Some(value),
        Err(_) => {
            stop_for_rescan(state);
            None
        }
    }
}

/// Stops applying changes to an index that needs a full rescan.
fn stop_for_rescan(state: &mut State) {
    state.watcher = None;
    state.walk = None;
    state.applying = None;
    state.needs_rescan = true;
}

/// # Safety
/// Valid serialized handle and a JSON array of absolute paths. Applies removals the
/// app made itself, such as moving files to the Trash, without waiting for FSEvents,
/// which later report them as no-ops. Old row IDs are invalidated on change.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_remove_paths(engine: *mut Engine, paths: *const c_char) -> Buffer {
    guarded(|| {
        let paths: Vec<PathBuf> =
            serde_json::from_str(&unsafe { text(paths)? }).map_err(|e| e.to_string())?;
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let mut state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        // A folder walk that is still running or being applied may have read
        // these paths already.
        if state.walk.is_some() || state.applying.is_some() {
            state.removed_during_walk.extend(paths.iter().cloned());
        }
        let changed = contain(&mut state, |state| remove_paths(state, paths)).unwrap_or(true);
        if changed {
            state.results.clear();
            state.generation = 0;
            state.dirty = true;
        }
        Ok(json!({"status":"ok", "changed":changed, "needs_rescan":state.needs_rescan}))
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
                .num_threads(walk_threads())
                .thread_name(|i| format!("everything-mac-native-walk-{i}"))
                .build()
                .map_err(|e| e.to_string())?;
            let exclusions = fswalk::Exclusions::compile(&root, &patterns)?;
            // Other volumes are left out unless an include path selects them.
            let volumes = search_cache::other_volumes(&root, &includes);
            let cache = pool.install(|| {
                let walk = WalkData::new(&root, &ignores, &includes, false, move || {
                    token.is_cancelled().is_none()
                })
                .with_exclusions(exclusions)
                .with_volumes(&volumes);
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
/// Periodic saves pass `include_events = false`: progress through FSEvents alone
/// is replayed on the next launch, so it is written only when quitting or switching.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_checkpoint(engine: *mut Engine, include_events: bool) -> Buffer {
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
        let unsaved = state.dirty || (include_events && state.events_dirty);
        if !unsaved && path.exists() {
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
        state.events_dirty = false;
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

/// Small selections also keep their paths, so their files stay selected when a
/// folder re-scan replaces the nodes. Larger selections keep only identities.
const PATH_FALLBACK_LIMIT: usize = 4096;

/// The node a retained selection entry refers to now: the same node while it
/// exists unchanged, otherwise whatever node is at its remembered path.
fn resolve_selected(state: &State, entry: usize) -> Option<NodeIdentity> {
    let identity = state.selection[entry];
    if state.selection_instance == state.cache.instance() && state.cache.is_current(identity) {
        return Some(identity);
    }
    let path = state.selection_paths.get(entry)?;
    state
        .cache
        .node_identity(state.cache.node_index_for_path(path)?)
}

/// # Safety
/// Valid serialized handle and JSON half-open ranges, plus complete cached paths
/// or null. Selections stay in Rust as fixed-size node identities, without paths.
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
        state.selection_paths.clear();
        state.selection_positions.clear();
        state.selection_generation = None;
        state.selection_instance = state.cache.instance();
        let mut sample = Vec::new();
        if generation != state.generation {
            let Some(paths) = cached else {
                return Ok(json!({"status":"stale"}));
            };
            let mut seen = HashSet::new();
            for path in paths {
                if let Some(identity) = state
                    .cache
                    .node_index_for_path(&path)
                    .and_then(|id| state.cache.node_identity(id))
                    && seen.insert(identity)
                {
                    state.selection.push(identity);
                    if sample.len() < 128 {
                        sample.push(path.clone());
                    }
                    state.selection_paths.push(path);
                }
            }
            if state.selection.len() > PATH_FALLBACK_LIMIT {
                state.selection_paths.clear();
            }
        } else {
            if ranges
                .iter()
                .any(|[start, end]| start > end || *end > state.results.len())
            {
                return Err("Invalid selection range".into());
            }
            let mut positions: Vec<usize> = ranges
                .iter()
                .flat_map(|[start, end]| *start..*end)
                .collect();
            positions.sort_unstable();
            positions.dedup();
            let keep_paths = positions.len() <= PATH_FALLBACK_LIMIT;
            state.selection.reserve(positions.len());
            state.selection_positions.reserve(positions.len());
            for i in positions {
                let id = state.results[i];
                let Some(identity) = state.cache.node_identity(id) else {
                    continue;
                };
                if keep_paths || sample.len() < 128 {
                    let Some(path) = state.cache.node_path(id) else {
                        continue;
                    };
                    if sample.len() < 128 {
                        sample.push(path.clone());
                    }
                    if keep_paths {
                        state.selection_paths.push(path);
                    }
                }
                state.selection.push(identity);
                state.selection_positions.push(i);
            }
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
            // Mark surviving nodes in a bitset, then keep the result rows that hold
            // them. Identities need no paths; reused slots have new generations.
            let alive: Vec<SlabIndex> = (0..state.selection.len())
                .filter_map(|entry| {
                    resolve_selected(&state, entry).map(|identity| identity.index())
                })
                .collect();
            let words = alive.iter().map(|id| id.get() / 64 + 1).max().unwrap_or(0);
            let mut selected = vec![0u64; words];
            for id in &alive {
                selected[id.get() / 64] |= 1 << (id.get() % 64);
            }
            let is_selected = |id: &SlabIndex| {
                selected
                    .get(id.get() / 64)
                    .is_some_and(|word| word & (1 << (id.get() % 64)) != 0)
            };
            let mut selection = Vec::with_capacity(alive.len());
            let mut positions = Vec::with_capacity(alive.len());
            for (i, id) in state.results.iter().enumerate() {
                if is_selected(id)
                    && let Some(identity) = state.cache.node_identity(*id)
                {
                    selection.push(identity);
                    positions.push(i);
                }
            }
            let selection_paths = if positions.len() <= PATH_FALLBACK_LIMIT {
                positions
                    .iter()
                    .map(|&i| state.cache.node_path(state.results[i]))
                    .collect::<Option<Vec<_>>>()
                    .unwrap_or_default()
            } else {
                vec![]
            };
            state.selection = selection;
            state.selection_positions = positions;
            state.selection_paths = selection_paths;
            state.selection_instance = state.cache.instance();
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
/// `limit` bounds the paths returned (0 for all), such as for a Quick Look preview.
/// # Safety
/// Engine must be live and calls serialized. Reused slab slots must never target
/// a different path after filesystem events invalidate the displayed generation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cn_selection_paths(engine: *mut Engine, limit: usize) -> Buffer {
    guarded(|| {
        let engine = unsafe { engine.as_ref() }.ok_or("No index loaded")?;
        let state = engine
            .0
            .lock()
            .map_err(|_| "Engine faulted; reopen index")?;
        let count = match limit {
            0 => state.selection.len(),
            limit => limit.min(state.selection.len()),
        };
        let paths = (0..count)
            .map(|entry| {
                resolve_selected(&state, entry)
                    .and_then(|identity| state.cache.node_path(identity.index()))
            })
            .collect::<Option<Vec<_>>>()
            .ok_or("One or more selected files moved or disappeared. Select the remaining files again.")?;
        Ok(json!({"status":"ok", "paths":paths}))
    })
}

/// # Safety
/// Distinct valid serialized handles; move only stable paths across a rescan.
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
            let paths: Vec<PathBuf> = (0..old.selection.len())
                .filter_map(|entry| {
                    resolve_selected(&old, entry)
                        .and_then(|identity| old.cache.node_path(identity.index()))
                })
                .collect();
            new.selection.clear();
            new.selection_paths.clear();
            // Only files found in the new index stay selected.
            for path in paths {
                if let Some(identity) = new
                    .cache
                    .node_index_for_path(&path)
                    .and_then(|id| new.cache.node_identity(id))
                {
                    new.selection.push(identity);
                    new.selection_paths.push(path);
                }
            }
            if new.selection.len() > PATH_FALLBACK_LIMIT {
                new.selection_paths.clear();
            }
            new.selection_instance = new.cache.instance();
            new.selection_positions.clear();
            new.selection_generation = None;
            old.selection.clear();
            old.selection_paths.clear();
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
