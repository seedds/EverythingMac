//! Times the background pass that reads sizes and dates after a full scan, and how
//! long searches wait for the engine while it runs. A scan leaves sizes and dates
//! only on folders, so this copies INDEX with them removed from everything else,
//! then compares what the pass read with the values saved in INDEX. With `--idle`,
//! nothing searches during the pass, so its CPU time is the pass's alone.
//! Usage: metadata_backfill INDEX [--idle] [QUERY...]
// Links the bridge, whose C functions are declared below.
use everything_mac_native_prototype as _;
use fswalk::NodeFileType;
use search_cache::{SlabIndex, SlabNodeMetadataCompact, read_cache_from_file, write_cache_to_file};
use serde_json::{Value, json};
use std::{
    ffi::{CString, c_char},
    path::Path,
    time::{Duration, Instant},
};

#[repr(C)]
struct Buffer {
    data: *mut u8,
    len: usize,
}
enum Engine {}
enum Request {}
unsafe extern "C" {
    fn cn_engine_open(path: *const c_char, out: *mut *mut Engine) -> Buffer;
    fn cn_watch(engine: *mut Engine, enabled: bool, checkpoint: *const c_char) -> Buffer;
    fn cn_poll(engine: *mut Engine, since_processed: u64, include_events: bool) -> Buffer;
    fn cn_request_new() -> *mut Request;
    fn cn_request_free(request: *mut Request);
    fn cn_search(
        engine: *mut Engine,
        request: *const Request,
        generation: u64,
        query: *const c_char,
        directory: *const c_char,
        case_sensitive: bool,
    ) -> Buffer;
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

fn summary(mut ms: Vec<f64>) -> Value {
    if ms.is_empty() {
        return json!(null);
    }
    ms.sort_by(f64::total_cmp);
    let at = |q: f64| ms[((ms.len() - 1) as f64 * q).round() as usize];
    json!({"count": ms.len(), "median": at(0.5), "p95": at(0.95), "max": at(1.0)})
}

/// User and system CPU seconds used by this process so far.
fn cpu() -> (f64, f64) {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let seconds = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    (seconds(usage.ru_utime), seconds(usage.ru_stime))
}

fn main() {
    let mut args = std::env::args().skip(1).peekable();
    let source = args
        .next()
        .expect("Usage: metadata_backfill INDEX [--idle] [QUERY...]");
    let idle_pass = args.next_if_eq("--idle").is_some();
    // The app calls the engine from a user-initiated queue.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0);
    }
    let mut queries: Vec<String> = args.collect();
    if queries.is_empty() {
        queries = ["a", "doc", "report", "photo", "*.swift"]
            .map(String::from)
            .into();
    }
    let queries: Vec<CString> = queries
        .into_iter()
        .map(|q| CString::new(q).unwrap())
        .collect();

    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let index = base.join("index.db");
    let mut storage = read_cache_from_file(Path::new(&source)).expect("read INDEX");
    let saved: Vec<(SlabIndex, SlabNodeMetadataCompact)> = storage
        .slab
        .iter()
        .filter(|(_, node)| node.metadata.file_type_hint() != NodeFileType::Dir)
        .map(|(id, node)| (id, node.metadata))
        .collect();
    for &(id, _) in &saved {
        storage.slab[id].metadata = SlabNodeMetadataCompact::none();
    }
    write_cache_to_file(&index, &storage).unwrap();
    drop(storage);

    let index = CString::new(index.to_str().unwrap()).unwrap();
    let checkpoint = base.join("state/checkpoint.db");
    let checkpoint_c = CString::new(checkpoint.to_str().unwrap()).unwrap();
    let empty = CString::default();
    let mut engine = std::ptr::null_mut();
    unsafe {
        assert_eq!(
            reply(cn_engine_open(index.as_ptr(), &mut engine))["status"],
            "ok"
        );
    }
    let mut generation = 0;
    let mut search = |query: &CString| {
        generation += 1;
        let request = unsafe { cn_request_new() };
        let started = Instant::now();
        let replied = unsafe {
            reply(cn_search(
                engine,
                request,
                generation,
                query.as_ptr(),
                empty.as_ptr(),
                false,
            ))
        };
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        unsafe { cn_request_free(request) };
        assert_eq!(replied["status"], "ok", "{replied}");
        ms
    };
    let idle: Vec<f64> = (0..3)
        .flat_map(|_| queries.iter().map(&mut search).collect::<Vec<_>>())
        .collect();

    let started = Instant::now();
    let cpu_before = cpu();
    unsafe {
        assert_eq!(
            reply(cn_watch(engine, false, checkpoint_c.as_ptr()))["status"],
            "ok"
        );
    }
    let (mut during, mut polls) = (Vec::new(), Vec::new());
    let mut next_poll = Instant::now();
    'backfill: for query in queries.iter().cycle() {
        if !idle_pass {
            during.push(search(query));
        }
        if Instant::now() >= next_poll {
            let polled_at = Instant::now();
            let polled = unsafe { reply(cn_poll(engine, 0, false)) };
            polls.push(polled_at.elapsed().as_secs_f64() * 1000.0);
            if polled["metadata_indexing"] == false {
                break 'backfill;
            }
            next_poll = Instant::now() + Duration::from_millis(100);
        }
        assert!(started.elapsed() < Duration::from_secs(1800));
        std::thread::sleep(Duration::from_millis(20));
    }
    let backfill_s = started.elapsed().as_secs_f64();
    let cpu_after = cpu();

    unsafe {
        assert_eq!(reply(cn_checkpoint(engine, false))["status"], "ok");
        cn_engine_close(engine);
    }
    let read = read_cache_from_file(&checkpoint).expect("read the saved result");
    let (mut same, mut different, mut missing, mut unaccessible) = (0, 0, 0, 0);
    for &(id, before) in &saved {
        let after = read.slab[id].metadata;
        if after.is_none() {
            missing += 1;
        } else if after == before {
            same += 1;
        } else if after.is_unaccessible() {
            unaccessible += 1;
        } else {
            different += 1;
        }
    }
    println!(
        "{}",
        json!({
            "entries": read.slab.len(),
            "cleared": saved.len(),
            "backfill_s": backfill_s,
            "per_s": saved.len() as f64 / backfill_s,
            "cpu_user_s": cpu_after.0 - cpu_before.0,
            "cpu_sys_s": cpu_after.1 - cpu_before.1,
            "search_ms_idle": summary(idle),
            "search_ms_during": summary(during),
            "poll_ms": summary(polls),
            "same": same,
            "different": different,
            "unaccessible": unaccessible,
            "still_missing": missing,
        })
    );
}
