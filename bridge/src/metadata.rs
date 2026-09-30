//! Backfill dates in existing and newly scanned indexes without blocking searches.
//! Workers hold only a weak engine reference while performing filesystem I/O.
use super::State;
use search_cache::{SlabIndex, SlabNodeMetadataCompact};
use std::{
    collections::VecDeque,
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    sync::{Arc, LazyLock, Mutex, PoisonError, Weak},
};

#[derive(Default)]
pub(super) struct Indexing {
    started: bool,
    pending: VecDeque<SlabIndex>,
    workers: usize,
    pub changed: bool,
}

impl Indexing {
    pub fn active(&self) -> bool {
        self.workers != 0
    }
}

/// Files read per batch. Each batch locks the engine twice: once to take the
/// paths and once to store what was read.
const BATCH: usize = 256;

/// Reads scale with threads up to about four, after which the kernel spends more
/// time per file; half the cores leaves the rest for searches.
static WORKERS: LazyLock<usize> = LazyLock::new(|| {
    std::thread::available_parallelism().map_or(2, |cores| (cores.get() / 2).clamp(2, 4))
});

// Globally bounded, even if an engine is closed while a volume is unresponsive.
// This pool is independent of the search and directory-walking pools.
static POOL: LazyLock<rayon::ThreadPool> = LazyLock::new(|| {
    rayon::ThreadPoolBuilder::new()
        .num_threads(*WORKERS)
        .thread_name(|i| format!("everything-mac-date-index-{i}"))
        .build()
        .expect("create metadata indexing pool")
});

pub(super) fn start(engine: &Arc<Mutex<State>>) {
    let mut state = engine.lock().unwrap_or_else(|e| e.into_inner());
    if state.metadata.started {
        return;
    }
    state.metadata.started = true;
    state.metadata.pending = state.cache.pending_metadata_ids().into();
    if state.metadata.pending.is_empty() {
        return;
    }
    state.metadata.workers = *WORKERS;
    drop(state);
    for _ in 0..*WORKERS {
        spawn_worker(engine, |path| {
            std::fs::symlink_metadata(path)
                .map(|m| SlabNodeMetadataCompact::some(m.into()))
                .unwrap_or_else(|_| SlabNodeMetadataCompact::unaccessible())
        });
    }
}

/// Runs a worker on the indexing pool. A panic stops only that worker: the pool
/// would otherwise abort the app.
fn spawn_worker(
    engine: &Arc<Mutex<State>>,
    read: impl Fn(&Path) -> SlabNodeMetadataCompact + Send + 'static,
) {
    let worker = Worker(Arc::downgrade(engine));
    POOL.spawn(move || {
        let _ = catch_unwind(AssertUnwindSafe(|| worker.run(read)));
    });
}

struct Worker(Weak<Mutex<State>>);

impl Worker {
    fn run(self, read: impl Fn(&Path) -> SlabNodeMetadataCompact) {
        loop {
            let Some(Some(jobs)) = self.locked(|state| {
                let pending = &mut state.metadata.pending;
                if pending.is_empty() {
                    return None;
                }
                let ids: Vec<_> = pending.drain(..pending.len().min(BATCH)).collect();
                Some(state.cache.pending_metadata_jobs(&ids))
            }) else {
                return;
            };
            let mut read_back = Vec::with_capacity(jobs.len());
            for (identity, path) in jobs {
                if self.0.strong_count() == 0 {
                    return;
                }
                // No engine ownership or mutex is retained across this syscall.
                read_back.push((identity, read(&path)));
            }
            let stored = self.locked(|state| {
                if state.cache.store_indexed_metadata(&read_back) {
                    state.dirty = true;
                    state.metadata.changed = true;
                }
            });
            if stored.is_none() {
                return;
            }
        }
    }

    /// Runs `f` with the engine locked, or returns `None` once the engine is closed
    /// or faulted. A panic in `f` ends indexing without poisoning the engine.
    fn locked<T>(&self, f: impl FnOnce(&mut State) -> T) -> Option<T> {
        let engine = self.0.upgrade()?;
        let mut state = engine.lock().ok()?;
        match catch_unwind(AssertUnwindSafe(|| f(&mut state))) {
            Ok(value) => Some(value),
            Err(_) => {
                state.metadata.pending.clear();
                None
            }
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        // Count the worker as finished even if a panic left the engine poisoned,
        // so the app does not report indexing forever.
        if let Some(engine) = self.0.upgrade() {
            let mut state = engine.lock().unwrap_or_else(PoisonError::into_inner);
            state.metadata.workers -= 1;
            if state.metadata.workers == 0 {
                state.metadata.pending = VecDeque::new();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use search_cache::SearchCache;
    use std::{fs, sync::mpsc, time::Duration};

    #[test]
    fn blocked_metadata_read_does_not_lock_or_retain_the_engine() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("file.txt"), "contents").unwrap();
        let cache = SearchCache::walk_fs(temp.path());
        let mut state = State::new(cache, temp.path().into());
        state.metadata.pending = state.cache.pending_metadata_ids().into();
        state.metadata.workers = 1;
        let engine = Arc::new(Mutex::new(state));
        let weak = Arc::downgrade(&engine);
        let worker = Worker(weak.clone());
        let (started, waiting) = mpsc::channel();
        let (release, blocked) = mpsc::channel();
        let task = std::thread::spawn(move || {
            worker.run(|_| {
                started.send(()).unwrap();
                blocked.recv().unwrap();
                SlabNodeMetadataCompact::unaccessible()
            })
        });
        waiting.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(
            engine.try_lock().is_ok(),
            "Searches must not wait for metadata I/O"
        );
        assert_eq!(Arc::strong_count(&engine), 1);
        drop(engine);
        assert!(
            weak.upgrade().is_none(),
            "Closing must release the index immediately"
        );
        release.send(()).unwrap();
        task.join().unwrap();
    }

    fn pending_engine() -> (tempfile::TempDir, Arc<Mutex<State>>) {
        let temp = tempfile::tempdir().unwrap();
        fs::write(temp.path().join("file.txt"), "contents").unwrap();
        let cache = SearchCache::walk_fs(temp.path());
        let mut state = State::new(cache, temp.path().into());
        state.metadata.pending = state.cache.pending_metadata_ids().into();
        state.metadata.workers = 1;
        (temp, Arc::new(Mutex::new(state)))
    }

    #[test]
    fn worker_reads_every_pending_file_once_across_batches() {
        let temp = tempfile::tempdir().unwrap();
        for folder in ["a", "b", "c"] {
            fs::create_dir(temp.path().join(folder)).unwrap();
            for i in 0..BATCH / 2 + 1 {
                fs::write(temp.path().join(folder).join(format!("{i}")), "x").unwrap();
            }
        }
        let cache = SearchCache::walk_fs(temp.path());
        let mut state = State::new(cache, temp.path().into());
        state.metadata.pending = state.cache.pending_metadata_ids().into();
        let pending = state.metadata.pending.len();
        assert!(pending > BATCH);
        state.metadata.workers = 1;
        let engine = Arc::new(Mutex::new(state));
        let reads = std::sync::atomic::AtomicUsize::new(0);
        Worker(Arc::downgrade(&engine)).run(|path| {
            reads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            SlabNodeMetadataCompact::some(fs::symlink_metadata(path).unwrap().into())
        });
        assert_eq!(reads.into_inner(), pending);
        let mut state = engine.lock().unwrap();
        assert!(state.cache.pending_metadata_ids().is_empty());
        assert!(!state.metadata.active());
        assert!(state.dirty && state.metadata.changed);
        let file = temp.path().join("b/1");
        let id = state.cache.node_index_for_path(&file).unwrap();
        let stored = state.cache.expand_cached_file_nodes(&[id])[0].metadata;
        let read = SlabNodeMetadataCompact::some(fs::symlink_metadata(&file).unwrap().into());
        assert_eq!(stored, read);
    }

    #[test]
    fn panicking_worker_stops_indexing_without_aborting_or_poisoning() {
        let (_temp, engine) = pending_engine();
        spawn_worker(&engine, |_| panic!("metadata read failed"));
        let started = std::time::Instant::now();
        while engine.lock().unwrap().metadata.active() {
            assert!(started.elapsed() < Duration::from_secs(2));
            std::thread::sleep(Duration::from_millis(10));
        }

        let mut state = engine.lock().unwrap();
        state.metadata.pending = state.cache.pending_metadata_ids().into();
        assert!(!state.metadata.pending.is_empty());
        state.metadata.workers = 1;
        drop(state);
        let worker = Worker(Arc::downgrade(&engine));
        assert!(
            worker
                .locked(|_| -> () { panic!("storing metadata failed") })
                .is_none()
        );
        assert!(!engine.is_poisoned());
        assert!(engine.lock().unwrap().metadata.pending.is_empty());
        drop(worker);
        assert!(!engine.lock().unwrap().metadata.active());
    }

    #[test]
    fn worker_is_counted_as_finished_after_the_engine_faulted() {
        let (_temp, engine) = pending_engine();
        let worker = Worker(Arc::downgrade(&engine));
        let shared = engine.clone();
        let _ = std::thread::spawn(move || {
            let _state = shared.lock().unwrap();
            panic!("fault the engine");
        })
        .join();
        assert!(engine.is_poisoned());
        drop(worker);
        let state = engine.lock().unwrap_or_else(PoisonError::into_inner);
        assert!(!state.metadata.active());
    }
}
