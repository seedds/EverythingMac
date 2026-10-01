//! Times how long applying folder changes to an index takes, the part of a live
//! update that holds the engine lock. Builds a temporary tree, indexes it, then
//! changes it and applies events for each change:
//! - `move_in`: a folder of FILES files in folders of 1,000 is moved in;
//! - `rescan_same`: FSEvents asks to rescan that folder, which is unchanged;
//! - `add_to_wide`: ADDED files appear in a folder that already holds WIDE files,
//!   each reported by its own event;
//! - `move_out`: the folder is moved out again.
//!
//! Usage: apply_timing [FILES] [WIDE] [ADDED] [REPEATS]
use everything_mac_sdk::{EventFlag, FsEvent};
use search_cache::SearchCache;
use std::{fs, path::Path, time::Instant};

fn stage(dir: &Path, files: usize) {
    for i in 0..files {
        let folder = dir.join(format!("d{}", i / 1000));
        if i % 1000 == 0 {
            fs::create_dir_all(&folder).unwrap();
        }
        fs::File::create(folder.join(format!("f{i}.txt"))).unwrap();
    }
}

fn apply(cache: &mut SearchCache, events: Vec<FsEvent>) -> (f64, f64, bool) {
    let scan = cache.plan_fs_events(events).unwrap();
    let started = Instant::now();
    let scanned = scan.scan(|| false).unwrap();
    let walk_ms = started.elapsed().as_secs_f64() * 1000.0;
    let started = Instant::now();
    let changed = cache.apply_fs_events(scanned);
    (walk_ms, started.elapsed().as_secs_f64() * 1000.0, changed)
}

fn main() {
    let arg = |i: usize, default: usize| {
        std::env::args()
            .nth(i)
            .map_or(default, |n| n.parse().unwrap())
    };
    let (files, wide, added, repeats) =
        (arg(1, 200_000), arg(2, 100_000), arg(3, 10_000), arg(4, 3));
    let temp = tempfile::tempdir().unwrap();
    let base = temp.path().canonicalize().unwrap();
    let root = base.join("root");
    let wide_dir = root.join("wide");
    fs::create_dir_all(&wide_dir).unwrap();
    for i in 0..wide {
        fs::File::create(wide_dir.join(format!("w{i}.txt"))).unwrap();
    }
    let staged = base.join("staged");
    stage(&staged, files);
    let mut cache = SearchCache::walk_fs(&root);
    let moved = root.join("moved");
    let mut id = 1u64;
    let mut event = |path: &Path, flag: EventFlag| {
        id += 1;
        FsEvent {
            path: path.to_path_buf(),
            id,
            flag,
        }
    };
    let report =
        |name: &str, (walk_ms, apply_ms, changed): (f64, f64, bool), cache: &SearchCache| {
            println!(
                "{}",
                serde_json::json!({"case": name, "walk_ms": walk_ms, "apply_ms": apply_ms,
                "changed": changed, "total": cache.get_total_files()})
            );
        };
    for round in 0..repeats {
        fs::rename(&staged, &moved).unwrap();
        let events = vec![event(&moved, EventFlag::ItemRenamed | EventFlag::ItemIsDir)];
        report("move_in", apply(&mut cache, events), &cache);

        let events = vec![event(
            &moved,
            EventFlag::MustScanSubDirs | EventFlag::ItemIsDir,
        )];
        report("rescan_same", apply(&mut cache, events), &cache);

        let names: Vec<_> = (0..added)
            .map(|i| wide_dir.join(format!("new-{round}-{i}.txt")))
            .collect();
        for name in &names {
            fs::File::create(name).unwrap();
        }
        let events = names
            .iter()
            .map(|name| event(name, EventFlag::ItemCreated | EventFlag::ItemIsFile))
            .collect();
        report("add_to_wide", apply(&mut cache, events), &cache);

        fs::rename(&moved, &staged).unwrap();
        let events = vec![event(&moved, EventFlag::ItemRenamed | EventFlag::ItemIsDir)];
        report("move_out", apply(&mut cache, events), &cache);
    }
}
