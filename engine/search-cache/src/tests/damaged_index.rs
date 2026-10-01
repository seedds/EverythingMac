use super::prelude::*;
use crate::{
    PersistentStorage, SearchOptions, SlabIndex, read_cache_from_file, write_cache_to_file,
};
use everything_mac_sdk::{EventFlag, FsEvent};
use std::{io::Write, path::Path, sync::atomic::AtomicBool, time::Instant};

static NEVER_STOPPED: AtomicBool = AtomicBool::new(false);

type Damage = Box<dyn FnOnce(&mut PersistentStorage)>;

/// A saved index of a small tree, and the folder it describes.
fn saved_index(label: &str) -> (TempDir, PathBuf) {
    let tmp = TempDir::new(label).unwrap();
    let root = tmp.path().join("tree");
    for dir in ["alpha/beta", "gamma"] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    for file in [
        "alpha/one.txt",
        "alpha/beta/two.rs",
        "gamma/three.md",
        "four",
    ] {
        fs::write(root.join(file), b"x").unwrap();
    }
    let index = tmp.path().join("index.db");
    SearchCache::walk_fs(&root).flush_to_file(&index).unwrap();
    (tmp, index)
}

fn damage(index: &Path, change: impl FnOnce(&mut PersistentStorage)) -> String {
    let mut storage = read_cache_from_file(index).unwrap();
    change(&mut storage);
    let damaged = index.with_file_name("damaged.db");
    write_cache_to_file(&damaged, &storage).unwrap();
    match read_cache_from_file(&damaged) {
        Ok(_) => panic!("the damaged index loaded"),
        Err(error) => format!("{error:#}"),
    }
}

/// The item with a name that appears once in the fixture.
fn named(storage: &PersistentStorage, name: &str) -> SlabIndex {
    *storage.name_index[name].iter().next().unwrap()
}

#[test]
fn damaged_structure_is_rejected() {
    let (_tmp, index) = saved_index("damaged_structure");
    let storage = read_cache_from_file(&index).expect("an intact index loads");
    let (alpha, beta, gamma) = (
        named(&storage, "alpha"),
        named(&storage, "beta"),
        named(&storage, "gamma"),
    );
    let missing = SlabIndex::new(storage.slab.len() + 100);

    let cases: Vec<(&str, Damage)> = vec![
        (
            "the root is missing",
            Box::new(move |s| s.slab_root = missing),
        ),
        (
            "the root has a parent",
            Box::new(move |s| s.slab_root = beta),
        ),
        (
            "lists missing item",
            Box::new(move |s| s.slab[gamma].children.push(missing)),
        ),
        (
            "has another parent",
            Box::new(move |s| s.slab[gamma].children.push(beta)),
        ),
        (
            "is listed twice",
            Box::new(move |s| s.slab[alpha].children.push(beta)),
        ),
        (
            "are not under the root",
            Box::new(move |s| s.slab[alpha].children.retain(|&c| c != beta)),
        ),
        (
            "the name index lists missing item",
            Box::new(move |s| {
                s.name_index
                    .insert("ghost".into(), crate::SortedSlabIndices::new(missing));
            }),
        ),
        (
            "indexed under another name",
            Box::new(move |s| {
                s.name_index
                    .insert("ghost".into(), crate::SortedSlabIndices::new(beta));
            }),
        ),
        (
            "the name index lists",
            Box::new(move |s| {
                // The item still points at the name, so keep its text allocated.
                std::mem::forget(s.name_index.remove_entry("beta"));
            }),
        ),
    ];
    for (expected, change) in cases {
        let error = damage(&index, change);
        assert!(
            error.contains("damaged") && error.contains(expected),
            "{expected}: {error}"
        );
    }
}

#[test]
fn truncated_or_altered_files_are_rejected() {
    let (_tmp, index) = saved_index("damaged_bytes");
    let bytes = fs::read(&index).unwrap();
    let damaged = index.with_file_name("damaged.db");
    for cut in [1, 16, bytes.len() / 2] {
        fs::write(&damaged, &bytes[..bytes.len() - cut]).unwrap();
        assert!(read_cache_from_file(&damaged).is_err(), "cut {cut}");
    }
    let mut altered = bytes.clone();
    altered[bytes.len() / 2] ^= 0x40;
    fs::write(&damaged, &altered).unwrap();
    assert!(read_cache_from_file(&damaged).is_err());
}

/// Changes random bytes of the decoded index, then saves it with a valid checksum.
/// Each result must either fail to load or load into a cache that can be searched,
/// walked, and updated without panicking.
#[test]
fn randomly_damaged_indexes_fail_or_work() {
    let (tmp, index) = saved_index("damaged_random");
    let payload = zstd::decode_all(fs::File::open(&index).unwrap()).unwrap();
    let damaged = index.with_file_name("damaged.db");
    let mut seed = 0x2545_f491_4f6c_dd1d_u64;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let started = Instant::now();
    let mut loaded = 0;
    for _ in 0..300 {
        let mut bytes = payload.clone();
        for _ in 0..1 + next() % 3 {
            let at = next() as usize % bytes.len();
            bytes[at] = next() as u8;
        }
        let mut encoder = zstd::Encoder::new(fs::File::create(&damaged).unwrap(), 1).unwrap();
        encoder.include_checksum(true).unwrap();
        encoder.write_all(&bytes).unwrap();
        encoder.finish().unwrap();
        let Ok(storage) = read_cache_from_file(&damaged) else {
            continue;
        };
        loaded += 1;
        let mut cache = SearchCache::from_persistent_storage(storage, &NEVER_STOPPED);
        let all = cache.search_empty(CancellationToken::noop()).unwrap();
        for &node in &all {
            cache.node_path(node);
        }
        let root = cache.file_nodes.root();
        cache.all_subnodes(root, CancellationToken::noop()).unwrap();
        cache
            .search_with_options("e", SearchOptions::default(), CancellationToken::noop())
            .unwrap();
        let id = cache.last_event_id() + 1;
        let _ = cache.handle_fs_events(vec![FsEvent {
            path: tmp.path().join("tree/alpha"),
            id,
            flag: EventFlag::ItemRemoved,
        }]);
    }
    assert!(loaded > 0, "some changes, such as to names, still load");
    assert!(started.elapsed().as_secs() < 60);
}
