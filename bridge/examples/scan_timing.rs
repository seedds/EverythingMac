//! Times full scans through `cn_scan`, as the app runs them. The scope defaults to
//! the app's default, `/` with nothing ignored; PATTERNS are exclusion patterns,
//! one per argument. The first scan warms the filesystem caches. `index_heap_mib`
//! is the heap memory the scanned index held, freed when it was closed.
//! Usage: scan_timing [ROOT] [REPEATS] [PATTERN...]
// Links the bridge, whose C functions are declared below.
use everything_mac_native_prototype as _;
use serde_json::{Value, json};
use std::{
    ffi::{CString, c_char},
    time::Instant,
};

#[repr(C)]
struct Buffer {
    data: *mut u8,
    len: usize,
}
enum Engine {}
enum Request {}
unsafe extern "C" {
    fn cn_scan_request_new() -> *mut Request;
    fn cn_request_free(request: *mut Request);
    fn cn_scan(
        root: *const c_char,
        ignores: *const c_char,
        includes: *const c_char,
        patterns: *const c_char,
        request: *const Request,
        out: *mut *mut Engine,
    ) -> Buffer;
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

/// User and system CPU seconds, and the peak physical footprint in MiB, so far.
/// The footprint is what Activity Monitor shows as memory; unlike the resident
/// size, it leaves out freed pages the system can reclaim.
fn usage() -> (f64, f64, f64) {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) };
    let seconds = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 / 1e6;
    let mut info: libc::rusage_info_v4 = unsafe { std::mem::zeroed() };
    unsafe { libc::proc_pid_rusage(libc::getpid(), libc::RUSAGE_INFO_V4, (&raw mut info).cast()) };
    (
        seconds(usage.ru_utime),
        seconds(usage.ru_stime),
        info.ri_lifetime_max_phys_footprint as f64 / (1024.0 * 1024.0),
    )
}

/// Heap memory in use, in MiB. The index's items are in a separate mapped file.
fn heap_in_use() -> f64 {
    let mut stats: libc::malloc_statistics_t = unsafe { std::mem::zeroed() };
    unsafe { libc::malloc_zone_statistics(std::ptr::null_mut(), &mut stats) };
    stats.size_in_use as f64 / (1024.0 * 1024.0)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let root = args.next().unwrap_or_else(|| "/".into());
    let repeats: usize = args.next().map_or(3, |n| n.parse().unwrap());
    let patterns: Vec<String> = args.collect();
    let root = CString::new(root).unwrap();
    let none = CString::new("[]").unwrap();
    let patterns = CString::new(json!(patterns).to_string()).unwrap();
    // The app scans from a user-initiated queue.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0);
    }
    for run in 0..=repeats {
        let request = unsafe { cn_scan_request_new() };
        let mut engine = std::ptr::null_mut();
        let before = usage();
        let started = Instant::now();
        let scanned = unsafe {
            reply(cn_scan(
                root.as_ptr(),
                none.as_ptr(),
                none.as_ptr(),
                patterns.as_ptr(),
                request,
                &mut engine,
            ))
        };
        let seconds = started.elapsed().as_secs_f64();
        let after = usage();
        assert_eq!(scanned["status"], "ok", "{scanned}");
        let held = heap_in_use();
        unsafe {
            cn_engine_close(engine);
            cn_request_free(request);
        }
        let released = held - heap_in_use();
        println!(
            "{}",
            json!({
                "run": if run == 0 { "warm-up".to_string() } else { run.to_string() },
                "scan_s": seconds,
                "entries": scanned["total"],
                "cpu_user_s": after.0 - before.0,
                "cpu_sys_s": after.1 - before.1,
                "peak_footprint_mib": after.2,
                "index_heap_mib": released,
            })
        );
    }
}
