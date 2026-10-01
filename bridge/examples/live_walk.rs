//! Times `cn_poll` while real FSEvents report large changes to a watched index.
//! Each poll runs on the app's serial engine queue, so the longest one is the
//! longest time a search or row load waits. Polls follow the app after one that
//! reports a walk: 5 ms later while it is applied, and 50 ms later while it is
//! read; otherwise they come every 100 ms, more often than the app's 500 ms. Uses
//! a temporary folder only. Prints one line per change, with the time spent in
//! polls (`busy_ms`) and the process's CPU time from the change's end (`cpu_ms`):
//! - `move_in`: a folder of FILES files, in folders of 1,000, is moved in;
//! - `add_wide`: ADDED files are created in an indexed folder of WIDE files;
//! - `move_out`: the first folder is moved out again.
//!
//! Usage: live_walk [FILES] [WIDE] [ADDED]
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

/// User and system CPU time of this process so far.
fn cpu_ms() -> f64 {
    let mut usage = unsafe { std::mem::zeroed::<libc::rusage>() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let ms = |time: libc::timeval| time.tv_sec as f64 * 1000.0 + time.tv_usec as f64 / 1000.0;
    ms(usage.ru_utime) + ms(usage.ru_stime)
}

fn main() {
    let arg = |i: usize, default: usize| {
        std::env::args()
            .nth(i)
            .map_or(default, |n| n.parse().unwrap())
    };
    let (files, wide, added) = (arg(1, 200_000), arg(2, 100_000), arg(3, 10_000));
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("root");
    let wide_dir = root.join("wide");
    fs::create_dir_all(&wide_dir).unwrap();
    for i in 0..wide {
        fs::File::create(wide_dir.join(format!("w{i}.txt"))).unwrap();
    }
    let staged = base.join("staged");
    let dirs = files.div_ceil(1000);
    for i in 0..files {
        let dir = staged.join(format!("d{}", i / 1000));
        if i % 1000 == 0 {
            fs::create_dir_all(&dir).unwrap();
        }
        fs::File::create(dir.join(format!("f{i}.txt"))).unwrap();
    }
    // FSEvents reports the files created above after the index's starting point
    // unless they are older than it. A busy Mac reports them late, and replaying
    // that many can make it drop events, which needs a full rescan.
    std::thread::sleep(Duration::from_secs(5));
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
    // Polls until the index holds `expected` items, after `change` ran.
    let measure = |name: &str, expected: usize, change: &dyn Fn()| {
        let changed = Instant::now();
        change();
        let cpu = cpu_ms();
        let (mut polls, mut longest, mut busy, mut total) = (0, 0.0_f64, 0.0, 0);
        let mut next = Duration::from_millis(100);
        let mut walking = false;
        while total != expected || walking || changed.elapsed() < Duration::from_millis(300) {
            assert!(
                changed.elapsed() < Duration::from_secs(120),
                "{name} timed out at {total} of {expected}"
            );
            std::thread::sleep(next);
            let (polled, ms) = poll();
            if polled["needs_rescan"] == true {
                // FSEvents asks for one when it drops events or reports the root.
                let events = unsafe { reply(cn_poll(engine, u64::MAX, true)) };
                let causes: Vec<_> = events["events"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|event| {
                        let flags = event["flags"].as_str().unwrap_or_default();
                        flags.contains("Dropped")
                            || flags.contains("RootChanged")
                            || event["path"] == root.to_str().unwrap()
                    })
                    .collect();
                panic!("{name} needs a rescan; events: {causes:?}");
            }
            polls += 1;
            longest = longest.max(ms);
            busy += ms;
            total = polled["total"].as_u64().unwrap() as usize;
            walking = polled["walking"] == true;
            next = Duration::from_millis(match (walking, polled["applying"] == true) {
                (_, true) => 5,
                (true, false) => 50,
                _ => 100,
            });
        }
        println!(
            "{}",
            serde_json::json!({"change": name, "indexed_after_ms": changed.elapsed().as_secs_f64() * 1000.0,
                "longest_poll_ms": longest, "busy_ms": busy, "cpu_ms": cpu_ms() - cpu, "polls": polls,
                "total": total})
        );
    };
    let moved = root.join("moved");
    let with_folder = initial + 1 + dirs + files;
    measure("move_in", with_folder, &|| {
        fs::rename(&staged, &moved).unwrap()
    });
    measure("add_wide", with_folder + added, &|| {
        for i in 0..added {
            fs::File::create(wide_dir.join(format!("new{i}.txt"))).unwrap();
        }
    });
    measure("move_out", initial + added, &|| {
        fs::rename(&moved, base.join("out")).unwrap()
    });
    unsafe { cn_engine_close(engine) };
}
