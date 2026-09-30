//! Times `cn_poll` while real FSEvents report a folder of many files moved into a
//! watched index, as when a large folder is copied or moved into place. Each poll
//! runs on the app's serial engine queue, so the longest one is the longest time a
//! search or row load waits. Uses a temporary folder only.
//! Usage: live_walk [FILES]
// Links the bridge, whose C functions are declared below.
use everything_mac_native_prototype as _;
use search_cache::SearchCache;
use serde_json::Value;
use std::{
    ffi::{CString, c_char},
    fs,
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

fn main() {
    let files: usize = std::env::args()
        .nth(1)
        .map_or(200_000, |n| n.parse().unwrap());
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("root");
    fs::create_dir(&root).unwrap();
    let staged = base.join("staged");
    let dirs = files.div_ceil(1000);
    for i in 0..files {
        let dir = staged.join(format!("d{}", i / 1000));
        if i % 1000 == 0 {
            fs::create_dir_all(&dir).unwrap();
        }
        fs::File::create(dir.join(format!("f{i}.txt"))).unwrap();
    }
    let index = base.join("index.db");
    SearchCache::walk_fs(&root).flush_to_file(&index).unwrap();
    let index = CString::new(index.to_str().unwrap()).unwrap();
    // Events in the checkpoint's folder are ignored, so keep it apart from the root.
    fs::create_dir(base.join("state")).unwrap();
    let checkpoint = base.join("state/checkpoint.db");
    let checkpoint = CString::new(checkpoint.to_str().unwrap()).unwrap();
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
    let poll = || {
        let started = Instant::now();
        let polled = unsafe { reply(cn_poll(engine, 0, false)) };
        (polled, started.elapsed().as_secs_f64() * 1000.0)
    };
    std::thread::sleep(Duration::from_millis(500));
    let initial = poll().0["total"].as_u64().unwrap() as usize;
    let expected = initial + 1 + dirs + files;
    let moved = Instant::now();
    fs::rename(&staged, root.join("moved")).unwrap();
    let (mut polls, mut longest, mut total) = (0, 0.0_f64, 0);
    while total < expected || moved.elapsed() < Duration::from_millis(300) {
        assert!(
            moved.elapsed() < Duration::from_secs(120),
            "timed out at {total}"
        );
        std::thread::sleep(Duration::from_millis(100));
        let (polled, ms) = poll();
        polls += 1;
        longest = longest.max(ms);
        total = polled["total"].as_u64().unwrap() as usize;
    }
    println!(
        "{}",
        serde_json::json!({"files": files, "indexed_after_ms": moved.elapsed().as_secs_f64() * 1000.0,
            "longest_poll_ms": longest, "polls": polls, "total": total})
    );
    unsafe { cn_engine_close(engine) };
}
