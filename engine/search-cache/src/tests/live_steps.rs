//! Live changes applied in steps, merged with what is indexed, and kept in name
//! order.
use super::prelude::*;
use crate::{SlabNodeMetadataCompact, read_cache_from_file};
use everything_mac_sdk::{EventFlag, FsEvent};
use std::{path::Path, sync::atomic::AtomicBool, time::Instant};

static NEVER_STOPPED: AtomicBool = AtomicBool::new(false);

fn write_files(folder: &Path, folders: usize, files: usize) {
    for d in 0..folders {
        let dir = folder.join(format!("d{d}"));
        fs::create_dir_all(&dir).unwrap();
        for f in 0..files {
            fs::write(dir.join(format!("f{f}.txt")), b"x").unwrap();
        }
    }
}

fn events(cache: &mut SearchCache, changes: &[(&Path, EventFlag)]) -> Vec<FsEvent> {
    let id = cache.last_event_id();
    changes
        .iter()
        .enumerate()
        .map(|(i, &(path, flag))| FsEvent {
            path: path.to_path_buf(),
            id: id + 1 + i as u64,
            flag,
        })
        .collect()
}

/// Every indexed path under `root`, sorted.
fn indexed_paths(cache: &SearchCache, root: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = cache
        .search_empty(CancellationToken::noop())
        .unwrap()
        .into_iter()
        .filter_map(|index| cache.node_path(index))
        .filter(|path| path.starts_with(root) && path != root)
        .collect();
    paths.sort();
    paths
}

/// Every path under `root` on disk, sorted.
fn disk_paths(root: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path.clone());
            }
            paths.push(path);
        }
    }
    paths.sort();
    paths
}

/// A folder moved out and a larger one moved in are applied one step at a time,
/// while the app removes items between steps: the index is whole after every
/// step, items the app removed are skipped, and the result matches the disk.
#[test]
fn large_changes_apply_in_steps_that_keep_the_index_whole() {
    let tmp = TempDir::new("live_steps").unwrap();
    let base = tmp.path().canonicalize().unwrap();
    let root = base.join("root");
    write_files(&root.join("old"), 3, 200);
    write_files(&root.join("kept"), 2, 50);
    write_files(&base.join("staged"), 4, 3000);
    let mut cache = SearchCache::walk_fs(&root);
    fs::rename(root.join("old"), base.join("old")).unwrap();
    fs::rename(base.join("staged"), root.join("new")).unwrap();
    let renamed = EventFlag::ItemRenamed | EventFlag::ItemIsDir;
    let events = events(
        &mut cache,
        &[(&root.join("old"), renamed), (&root.join("new"), renamed)],
    );
    let last_id = events.last().unwrap().id;
    let scanned = cache
        .plan_fs_events(events)
        .unwrap()
        .scan(|| false)
        .unwrap();
    let mut changes = scanned.into_changes();
    let mut steps = 0;
    let mut changed = false;
    // The app trashes a folder being added and a file, each once it is indexed.
    let trashed_folder = root.join("new/d0");
    let trashed_file = root.join("new/d3/f7.txt");
    while !changes.is_done() {
        changed |= cache.apply_changes(&mut changes, Some(Instant::now()));
        steps += 1;
        cache.assert_whole();
        if !changes.is_done() {
            assert_ne!(
                cache.last_event_id(),
                last_id,
                "recorded once all is applied"
            );
        }
        for trashed in [&trashed_folder, &trashed_file] {
            if trashed.exists() && cache.node_index_for_path(trashed).is_some() {
                if trashed.is_dir() {
                    fs::remove_dir_all(trashed).unwrap();
                } else {
                    fs::remove_file(trashed).unwrap();
                }
                let removal = vec![FsEvent {
                    path: trashed.clone(),
                    id: cache.last_event_id(),
                    flag: EventFlag::ItemRemoved,
                }];
                assert!(cache.handle_fs_events(removal).unwrap());
                cache.assert_whole();
            }
        }
    }
    assert!(changed);
    assert!(steps > 4, "applied in {steps} steps");
    assert_eq!(cache.last_event_id(), last_id);
    assert!(!trashed_folder.exists() && !trashed_file.exists());
    assert_eq!(indexed_paths(&cache, &root), disk_paths(&root));
}

/// A folder rescanned without changes keeps every item and reports no change;
/// with changes, only the changed items are added, removed or updated.
#[test]
fn rescanned_folders_change_only_what_differs() {
    let tmp = TempDir::new("live_merge").unwrap();
    let root = tmp.path().canonicalize().unwrap();
    write_files(&root.join("folder"), 3, 20);
    let mut cache = SearchCache::walk_fs(&root);
    let folder = root.join("folder");
    let rescan = |cache: &mut SearchCache| {
        let events = events(cache, &[(&folder, EventFlag::MustScanSubDirs)]);
        cache.handle_fs_events(events).unwrap()
    };
    let identities: Vec<_> = disk_paths(&folder)
        .iter()
        .map(|path| {
            let index = cache.node_index_for_path(path).unwrap();
            (path.clone(), cache.node_identity(index).unwrap())
        })
        .collect();
    assert!(!rescan(&mut cache), "nothing was added or removed");
    // The walk read sizes and dates the scan left for later.
    assert!(cache.take_metadata_changed());
    assert!(!rescan(&mut cache));
    assert!(!cache.take_metadata_changed(), "metadata is unchanged");
    assert!(
        identities
            .iter()
            .all(|(_, identity)| cache.is_current(*identity))
    );

    let rewritten = folder.join("d1/f3.txt");
    fs::write(&rewritten, b"longer").unwrap();
    assert!(!rescan(&mut cache));
    assert!(cache.take_metadata_changed());
    let index = cache.node_index_for_path(&rewritten).unwrap();
    assert_eq!(cache.file_nodes[index].metadata.as_ref().unwrap().size(), 6);

    fs::remove_dir_all(folder.join("d2")).unwrap();
    fs::remove_file(folder.join("d0/f0.txt")).unwrap();
    fs::write(folder.join("d0/added.txt"), b"x").unwrap();
    // A file replaced by a folder of the same name changes type.
    fs::remove_file(folder.join("d1/f4.txt")).unwrap();
    write_files(&folder.join("d1/f4.txt"), 1, 2);
    assert!(rescan(&mut cache));
    cache.assert_whole();
    assert_eq!(indexed_paths(&cache, &root), disk_paths(&root));
    for (path, identity) in &identities {
        assert_eq!(
            cache.is_current(*identity),
            path.exists(),
            "{path:?} keeps its node exactly while it exists"
        );
    }
}

/// Indexes saved before 0.1.75 list items added by live updates after the
/// others; loading puts them in name order. Names listed twice in a folder, which
/// older versions could leave, are merged by the next rescan of the folder.
#[test]
fn older_indexes_get_children_in_name_order() {
    let tmp = TempDir::new("older_order").unwrap();
    let base = tmp.path().canonicalize().unwrap();
    let root = base.join("root");
    write_files(&root, 2, 30);
    let snapshot = base.join("index.zstd");
    SearchCache::walk_fs(&root)
        .flush_snapshot_to_file(&snapshot)
        .unwrap();
    let mut storage = read_cache_from_file(&snapshot).unwrap();
    let folder = root.join("d1");
    let mut index = storage.slab_root;
    for name in folder.strip_prefix("/").unwrap() {
        index = *storage.slab[index]
            .children
            .iter()
            .find(|&&child| storage.slab[child].name() == name)
            .unwrap();
    }
    storage.slab[index].children.reverse();
    let mut cache = SearchCache::from_persistent_storage(storage, &NEVER_STOPPED);
    cache.assert_whole();
    for path in disk_paths(&root) {
        assert!(cache.node_index_for_path(&path).is_some(), "{path:?}");
    }

    let twin = cache.push_node(Some(index), "f5.txt", SlabNodeMetadataCompact::none());
    cache.insert_child(index, twin);
    assert_eq!(cache.name_index.get("f5.txt").unwrap().len(), 3);
    cache.assert_whole();
    let events = events(&mut cache, &[(&folder, EventFlag::MustScanSubDirs)]);
    assert!(cache.handle_fs_events(events).unwrap());
    cache.assert_whole();
    assert_eq!(
        cache.name_index.get("f5.txt").unwrap().len(),
        2,
        "one per folder"
    );
    assert_eq!(indexed_paths(&cache, &root), disk_paths(&root));
}

/// Below a folder that an older index lists twice, an item can be added at the
/// same path as one below the other copy. It is still found by name, and removed.
#[test]
fn items_at_the_path_of_another_are_indexed() {
    let tmp = TempDir::new("twin_paths").unwrap();
    let root = tmp.path().canonicalize().unwrap();
    write_files(&root, 1, 2);
    let mut cache = SearchCache::walk_fs(&root);
    let folder = root.join("d0");
    let first = cache.node_index_for_path(&folder).unwrap();
    let parent = cache.node_index_for_path(&root).unwrap();
    // The copy is listed after the first, so changes in the folder go to the first.
    let twin = cache.push_node(Some(parent), "d0", SlabNodeMetadataCompact::none());
    cache.insert_child(parent, twin);
    let late = cache.push_node(Some(twin), "late.txt", SlabNodeMetadataCompact::none());
    cache.insert_child(twin, late);
    cache.assert_whole();

    let added = folder.join("late.txt");
    fs::write(&added, b"x").unwrap();
    let created = events(&mut cache, &[(&added, EventFlag::ItemCreated)]);
    assert!(cache.handle_fs_events(created).unwrap());
    cache.assert_whole();
    let found: Vec<_> = cache
        .search("late.txt")
        .unwrap()
        .into_iter()
        .map(|index| cache.node_parent(index))
        .collect();
    assert_eq!(found.len(), 2);
    assert!(found.contains(&Some(first)) && found.contains(&Some(twin)));

    fs::remove_file(&added).unwrap();
    let removed = events(&mut cache, &[(&added, EventFlag::ItemRemoved)]);
    assert!(cache.handle_fs_events(removed).unwrap());
    cache.assert_whole();
}
