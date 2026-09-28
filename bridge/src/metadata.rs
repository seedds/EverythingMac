//! Backfill dates in existing and newly scanned indexes without blocking searches.
//! Workers hold only a weak engine reference while performing filesystem I/O.
use super::State;
use search_cache::{SlabIndex, SlabNodeMetadataCompact};
use std::{
    collections::VecDeque,
    path::Path,
    sync::{Arc, LazyLock, Mutex, Weak},
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

// Globally bounded, even if an engine is closed while a volume is unresponsive.
// This pool is independent of the search and directory-walking pools.
static POOL: LazyLock<rayon::ThreadPool> = LazyLock::new(|| {
    rayon::ThreadPoolBuilder::new()
        .num_threads(2)
        .thread_name(|i| format!("cardinal-date-index-{i}"))
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
    state.metadata.workers = 2;
    drop(state);
    for _ in 0..2 {
        let worker = Worker(Arc::downgrade(engine));
        POOL.spawn(move || {
            worker.run(|path| {
                std::fs::symlink_metadata(path)
                    .map(|m| SlabNodeMetadataCompact::some(m.into()))
                    .unwrap_or_else(|_| SlabNodeMetadataCompact::unaccessible())
            })
        });
    }
}

struct Worker(Weak<Mutex<State>>);

impl Worker {
    fn run(self, read: impl Fn(&Path) -> SlabNodeMetadataCompact) {
        loop {
            let jobs = {
                let Some(engine) = self.0.upgrade() else {
                    return;
                };
                let Ok(mut state) = engine.lock() else {
                    return;
                };
                if state.metadata.pending.is_empty() {
                    return;
                }
                let mut jobs = Vec::new();
                for _ in 0..64 {
                    let Some(id) = state.metadata.pending.pop_front() else {
                        break;
                    };
                    if let Some(path) = state.cache.pending_metadata_path(id) {
                        jobs.push((id, path));
                    }
                }
                jobs
            };
            for (id, path) in jobs {
                if self.0.strong_count() == 0 {
                    return;
                }
                // No engine ownership or mutex is retained across this syscall.
                let metadata = read(&path);
                let Some(engine) = self.0.upgrade() else {
                    return;
                };
                let Ok(mut state) = engine.lock() else {
                    return;
                };
                if state.cache.store_indexed_metadata(id, &path, metadata) {
                    state.dirty = true;
                    state.metadata.changed = true;
                }
            }
            std::thread::yield_now();
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let Some(engine) = self.0.upgrade()
            && let Ok(mut state) = engine.lock()
        {
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
}
