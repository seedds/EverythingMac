//! Changes FILES files at once in a watched index, faster than macOS delivers their
//! events to the app, which then drops some (`UserDropped`) and replays them from
//! its event history. Polls like the app and prints whether a full rescan was
//! needed, the events processed (a replay delivers a few twice), and how many
//! changed files the index then shows with their new size. Uses a temporary folder
//! only. Treating `HandleFSEError::Dropped` as a rescan shows whether this Mac drops
//! events at that rate.
//!
//! Usage: drop_replay [FILES]
// Links the bridge, whose C functions are declared below.
use everything_mac_native_prototype as _;
use search_cache::SearchCache;
use serde_json::Value;
use std::{
    ffi::{CString, c_char},
    fs,
    io::Write,
    sync::atomic::AtomicBool,
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
    fn cn_checkpoint(engine: *mut Engine, include_events: bool) -> Buffer;
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

static NEVER: AtomicBool = AtomicBool::new(false);

fn main() {
    let files: usize = std::env::args()
        .nth(1)
        .map_or(10_000, |n| n.parse().unwrap());
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("root");
    let mut paths = Vec::with_capacity(files);
    for i in 0..files {
        let dir = root.join(format!("d{}", i / 1000));
        if i % 1000 == 0 {
            fs::create_dir_all(&dir).unwrap();
        }
        let path = dir.join(format!("f{i}.txt"));
        fs::write(&path, b"x").unwrap();
        paths.push(path);
    }
    // Let FSEvents report the files created above before the index's starting point.
    std::thread::sleep(Duration::from_secs(5));
    let index = base.join("index.db");
    SearchCache::walk_fs(&root).flush_to_file(&index).unwrap();
    let index = CString::new(index.to_str().unwrap()).unwrap();
    // Events in the checkpoint's folder are ignored, so keep it apart from the root.
    fs::create_dir(base.join("state")).unwrap();
    let checkpoint = base.join("state/checkpoint.db");
    let checkpoint_c = CString::new(checkpoint.to_str().unwrap()).unwrap();
    let mut engine = std::ptr::null_mut();
    unsafe {
        assert_eq!(
            reply(cn_engine_open(index.as_ptr(), &mut engine))["status"],
            "ok"
        );
        assert_eq!(
            reply(cn_watch(engine, true, checkpoint_c.as_ptr()))["status"],
            "ok"
        );
    }
    let poll = || {
        let started = Instant::now();
        let polled = unsafe { reply(cn_poll(engine, 0, false)) };
        (polled, started.elapsed().as_secs_f64() * 1000.0)
    };
    for _ in 0..5 {
        std::thread::sleep(Duration::from_millis(100));
        poll();
    }
    let changed = Instant::now();
    for path in &paths {
        fs::OpenOptions::new()
            .append(true)
            .open(path)
            .unwrap()
            .write_all(b"y")
            .unwrap();
    }
    let change_ms = changed.elapsed().as_secs_f64() * 1000.0;
    let (mut longest, mut busy, mut polls, mut rescan) = (0.0_f64, 0.0, 0, false);
    let (mut processed, mut quiet_since) = (0, Instant::now());
    // Until no event arrived for two seconds and nothing is left to apply.
    loop {
        assert!(changed.elapsed() < Duration::from_secs(120), "timed out");
        let (polled, ms) = poll();
        polls += 1;
        longest = longest.max(ms);
        busy += ms;
        if polled["needs_rescan"] == true {
            rescan = true;
            break;
        }
        let now = polled["processed_events"].as_u64().unwrap_or(0);
        if now != processed {
            processed = now;
            quiet_since = Instant::now();
        }
        let walking = polled["walking"] == true;
        if !walking && quiet_since.elapsed() > Duration::from_secs(2) {
            break;
        }
        std::thread::sleep(Duration::from_millis(
            match (walking, polled["applying"] == true) {
                (_, true) => 5,
                (true, false) => 50,
                _ => 100,
            },
        ));
    }
    let settled_ms = changed.elapsed().as_secs_f64() * 1000.0;
    let mut updated = 0;
    if !rescan {
        unsafe {
            assert_eq!(reply(cn_checkpoint(engine, true))["status"], "ok");
        }
        let mut saved =
            SearchCache::try_read_persistent_cache(&root, &checkpoint, &vec![], &vec![], &NEVER)
                .unwrap();
        let ids: Vec<_> = paths
            .iter()
            .filter_map(|path| saved.node_index_for_path(path))
            .collect();
        updated = saved
            .expand_cached_file_nodes(&ids)
            .iter()
            .filter(|node| node.metadata.as_ref().is_some_and(|m| m.size() == 2))
            .count();
    }
    unsafe { cn_engine_close(engine) };
    println!(
        "{}",
        serde_json::json!({"files": files, "change_ms": change_ms, "processed_events": processed,
            "rescan": rescan, "updated": updated, "settled_ms": settled_ms,
            "longest_poll_ms": longest, "busy_ms": busy, "polls": polls})
    );
}
