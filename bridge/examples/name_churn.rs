//! Measures the memory a live index keeps after files come and go, as build, cache
//! and temporary folders do. Each round moves a folder of FILES newly named files
//! into a watched index, waits until live updates add them, moves the folder out
//! (as moving it to the Trash does; deleting each file would report more changes
//! than FSEvents keeps, asking for a rescan) and waits until they are removed. The index then lists what it did before the
//! round, so heap memory that stays in use is memory the removals did not free.
//! Uses a temporary folder only.
//! Usage: name_churn [FILES] [ROUNDS]
// Links the bridge, whose C functions are declared below.
use everything_mac_native_prototype as _;
use search_cache::SearchCache;
use serde_json::{Value, json};
use std::{
    ffi::{CString, c_char},
    fs,
    path::Path,
    time::{Duration, Instant},
};

#[repr(C)]
struct Buffer {
    data: *mut u8,
    len: usize,
}
enum Engine {}
unsafe extern "C" {
    fn cn_engine_open(path: *const c_char, out: *mut *mut Engine) -> Buffer;
    fn cn_watch(engine: *mut Engine, enabled: bool, checkpoint: *const c_char) -> Buffer;
    fn cn_poll(engine: *mut Engine, since_processed: u64, include_events: bool) -> Buffer;
    fn cn_engine_close(engine: *mut Engine);
    fn cn_buffer_free(buffer: Buffer);
}

fn reply(buffer: Buffer) -> Value {
    let value =
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
            .unwrap();
    unsafe { cn_buffer_free(buffer) };
    value
}

/// Heap memory in use, in MiB.
fn heap_in_use() -> f64 {
    let mut stats: libc::malloc_statistics_t = unsafe { std::mem::zeroed() };
    unsafe { libc::malloc_zone_statistics(std::ptr::null_mut(), &mut stats) };
    stats.size_in_use as f64 / (1024.0 * 1024.0)
}

/// Creates `files` empty files in folders of 1,000, all named for `round`.
fn stage(folder: &Path, round: usize, files: usize) {
    for i in 0..files {
        let dir = folder.join(format!("build-{round}-{}", i / 1000));
        if i % 1000 == 0 {
            fs::create_dir_all(&dir).unwrap();
        }
        fs::File::create(dir.join(format!("object-{round}-{i}.o"))).unwrap();
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let files: usize = args.next().map_or(100_000, |n| n.parse().unwrap());
    let rounds: usize = args.next().map_or(5, |n| n.parse().unwrap());
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("root");
    fs::create_dir(&root).unwrap();
    // FSEvents reports the new root after a delay; indexed before that, the report
    // would ask for a rescan.
    std::thread::sleep(Duration::from_secs(2));
    let index = base.join("index.db");
    SearchCache::walk_fs(&root).flush_to_file(&index).unwrap();
    let index = CString::new(index.to_str().unwrap()).unwrap();
    // Events in the checkpoint's folder are ignored, so keep it apart from the root.
    fs::create_dir(base.join("state")).unwrap();
    let checkpoint = CString::new(base.join("state/checkpoint.db").to_str().unwrap()).unwrap();
    let mut engine = std::ptr::null_mut();
    unsafe {
        assert_eq!(
            reply(cn_engine_open(index.as_ptr(), &mut engine))["status"],
            "ok"
        );
        assert_eq!(
            reply(cn_watch(engine, true, checkpoint.as_ptr()))["status"],
            "ok"
        );
    }
    let poll = || unsafe { reply(cn_poll(engine, 0, false)) };
    let total = || poll()["total"].as_u64().unwrap();
    let wait_for = |expected: u64| {
        let started = Instant::now();
        loop {
            let polled = poll();
            if polled["total"] == expected {
                break;
            }
            assert!(
                started.elapsed() < Duration::from_secs(120),
                "expected {expected} entries: {polled}"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    };
    std::thread::sleep(Duration::from_millis(500));
    let initial = total();
    let staged = base.join("staged");
    let mut first = None;
    // Round 0 warms up the event log and the allocator.
    for round in 0..=rounds {
        stage(&staged, round, files);
        let moved = root.join(format!("round-{round}"));
        fs::rename(&staged, &moved).unwrap();
        wait_for(initial + 1 + files.div_ceil(1000) as u64 + files as u64);
        let trashed = base.join("trashed");
        fs::rename(&moved, &trashed).unwrap();
        wait_for(initial);
        fs::remove_dir_all(&trashed).unwrap();
        let heap = heap_in_use();
        let first = *first.get_or_insert(heap);
        println!(
            "{}",
            json!({"round": round, "files": files, "entries": initial,
                "heap_mib": heap, "kept_since_round_0_mib": heap - first})
        );
    }
    unsafe { cn_engine_close(engine) };
}
