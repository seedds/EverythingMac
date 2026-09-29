use cardinal_sdk::{EventFlag, FsEvent};
use fswalk::{Exclusions, WalkData};
use search_cache::SearchCache;
use std::{fs, sync::atomic::AtomicBool};
static STOP: AtomicBool = AtomicBool::new(false);

#[test]
fn exclusions_survive_events_snapshots_and_rescans() {
    let temp = tempdir::TempDir::new("pattern-lifecycle").unwrap();
    let root = temp.path();
    fs::create_dir_all(root.join("node_modules")).unwrap();
    fs::write(root.join("keep.txt"), "x").unwrap();
    let rules = Exclusions::compile(root, &["node_modules/".into(), "*.log".into()]).unwrap();
    let walk = WalkData::new(root, &[], &[], false, || false).with_exclusions(rules);
    let mut cache = SearchCache::walk_fs_with_walk_data(&walk, &STOP).unwrap();
    let db = root.join("index.db");
    cache.flush_snapshot_to_file(&db).unwrap();
    let bytes = fs::read(&db).unwrap();
    let storage = search_cache::read_cache_from_file(&db).unwrap();
    let mut cache = SearchCache::from_persistent_storage(storage, &STOP);
    assert_eq!(bytes, fs::read(&db).unwrap());
    assert_eq!(cache.exclusion_patterns(), ["node_modules/", "*.log"]);
    for (name, flag) in [
        ("node_modules/new.txt", EventFlag::ItemCreated),
        ("new.log", EventFlag::ItemCreated),
        ("visible.txt", EventFlag::ItemRenamed),
    ] {
        fs::write(root.join(name), "x").unwrap();
        let id = cache.last_event_id() + 1;
        cache
            .handle_fs_events(vec![FsEvent {
                path: root.join(name),
                id,
                flag: flag | EventFlag::ItemIsFile,
            }])
            .unwrap();
    }
    assert!(
        cache
            .search_with_options(
                "new",
                Default::default(),
                search_cancel::CancellationToken::noop()
            )
            .unwrap()
            .nodes
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        cache
            .search_with_options(
                "visible.txt",
                Default::default(),
                search_cancel::CancellationToken::noop()
            )
            .unwrap()
            .nodes
            .unwrap()
            .len(),
        1
    );
    fs::remove_file(root.join("visible.txt")).unwrap();
    let id = cache.last_event_id() + 1;
    cache
        .handle_fs_events(vec![FsEvent {
            path: root.join("visible.txt"),
            id,
            flag: EventFlag::ItemRemoved | EventFlag::ItemIsFile,
        }])
        .unwrap();
    assert!(
        cache
            .search_with_options(
                "visible.txt",
                Default::default(),
                search_cancel::CancellationToken::noop()
            )
            .unwrap()
            .nodes
            .unwrap()
            .is_empty()
    );
    cache.rescan();
    assert!(
        cache
            .search_with_options(
                "node_modules | new.log",
                Default::default(),
                search_cancel::CancellationToken::noop()
            )
            .unwrap()
            .nodes
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        cache
            .search_with_options(
                "keep.txt",
                Default::default(),
                search_cancel::CancellationToken::noop()
            )
            .unwrap()
            .nodes
            .unwrap()
            .len(),
        1
    );
}
