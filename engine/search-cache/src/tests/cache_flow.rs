use super::prelude::*;
use crate::SlabNodeMetadataCompact;
use everything_mac_sdk::{EventFlag, FsEvent};
use std::sync::atomic::AtomicBool;

static NEVER_STOPPED: AtomicBool = AtomicBool::new(false);

#[test]
fn test_search_empty_returns_all_nodes() {
    let tmp = TempDir::new("search_empty").unwrap();
    fs::File::create(tmp.path().join("a.txt")).unwrap();
    fs::File::create(tmp.path().join("b.txt")).unwrap();
    let cache = SearchCache::walk_fs(tmp.path());
    let all = cache
        .search_empty(CancellationToken::noop())
        .expect("noop cancellation token should not cancel");
    assert_eq!(all.len(), cache.get_total_files());
}

#[test]
fn test_node_path_root_and_child() {
    let tmp = TempDir::new("node_path").unwrap();
    fs::create_dir(tmp.path().join("dir1")).unwrap();
    fs::File::create(tmp.path().join("dir1/file_x")).unwrap();
    let mut cache = SearchCache::walk_fs(tmp.path());
    let idxs = cache.search("file_x").unwrap();
    assert_eq!(idxs.len(), 1);
    let full = cache.node_path(idxs.into_iter().next().unwrap()).unwrap();
    assert!(full.ends_with(PathBuf::from("dir1/file_x")));
}

#[test]
fn test_remove_node_path_nonexistent_returns_none() {
    let tmp = TempDir::new("remove_node_none").unwrap();
    let mut cache = SearchCache::walk_fs(tmp.path());
    // remove_node_path is private via crate; exercise via scan removal scenario
    // create then delete file and ensure second scan removal returns None
    let file = tmp.path().join("temp_remove.txt");
    fs::write(&file, b"x").unwrap();
    let id = cache.last_event_id() + 1;
    cache
        .handle_fs_events(vec![FsEvent {
            path: file.clone(),
            id,
            flag: EventFlag::ItemCreated,
        }])
        .unwrap();
    // delete file and send removal event => handle_fs_events will trigger internal removal
    fs::remove_file(&file).unwrap();
    let id2 = id + 1;
    cache
        .handle_fs_events(vec![FsEvent {
            path: file.clone(),
            id: id2,
            flag: EventFlag::ItemRemoved,
        }])
        .unwrap();
    assert!(cache.search("temp_remove.txt").unwrap().is_empty());
}

#[test]
fn test_expand_file_nodes_fetch_metadata() {
    let tmp = TempDir::new("expand_meta").unwrap();
    fs::write(tmp.path().join("meta.txt"), b"hello world").unwrap();
    let mut cache = SearchCache::walk_fs(tmp.path());
    let idxs = cache.search("meta.txt").unwrap();
    assert_eq!(idxs.len(), 1);
    // First query_files returns metadata None
    let q1 = cache
        .query_files("meta.txt", CancellationToken::noop())
        .expect("query should succeed")
        .expect("noop cancellation token should not cancel");
    assert_eq!(q1.len(), 1);
    assert!(q1[0].metadata.is_none());
    // expand_file_nodes should fetch metadata
    let nodes = cache.expand_file_nodes(&idxs);
    assert_eq!(nodes.len(), 1);
    assert!(
        nodes[0].metadata.is_some(),
        "metadata should be fetched on demand"
    );
    // A second expand should still have metadata (cached)
    let nodes2 = cache.expand_file_nodes(&idxs);
    assert!(nodes2[0].metadata.is_some());
}

#[test]
fn background_metadata_jobs_build_paths_and_skip_replaced_nodes() {
    let tmp = TempDir::new("metadata_jobs").unwrap();
    for dir in ["a/b", "c"] {
        fs::create_dir_all(tmp.path().join(dir)).unwrap();
    }
    for file in ["a/one", "a/two", "a/b/three", "c/four", "five"] {
        fs::write(tmp.path().join(file), b"x").unwrap();
    }
    let mut cache = SearchCache::walk_fs(tmp.path());
    let pending = cache.pending_metadata_ids();
    let jobs = cache.pending_metadata_jobs(&pending);
    assert_eq!(jobs.len(), pending.len());
    for (identity, path) in &jobs {
        assert_eq!(cache.node_path(identity.index()).as_ref(), Some(path));
    }
    let mut names: Vec<_> = jobs
        .iter()
        .filter_map(|(_, path)| path.strip_prefix(tmp.path()).ok())
        .map(|path| path.to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, ["a/b/three", "a/one", "a/two", "c/four", "five"]);

    // A file removed after its path was taken frees its slot for a new file.
    let removed = tmp.path().join("a/one");
    let (old, _) = jobs.iter().find(|(_, path)| *path == removed).unwrap();
    fs::remove_file(&removed).unwrap();
    fs::write(tmp.path().join("c/new"), b"new contents").unwrap();
    let id = cache.last_event_id() + 1;
    cache
        .handle_fs_events(vec![
            FsEvent {
                path: removed.clone(),
                id,
                flag: EventFlag::ItemRemoved,
            },
            FsEvent {
                path: tmp.path().join("c/new"),
                id: id + 1,
                flag: EventFlag::ItemCreated,
            },
        ])
        .unwrap();
    let new = cache
        .node_index_for_path(&tmp.path().join("c/new"))
        .unwrap();
    assert_eq!(new, old.index(), "the new file reuses the slot");
    let new_metadata = cache.file_nodes[new].metadata;

    let read: Vec<_> = jobs
        .iter()
        .map(|(identity, _)| (*identity, SlabNodeMetadataCompact::unaccessible()))
        .collect();
    assert!(cache.store_indexed_metadata(&read));
    assert_eq!(
        cache.file_nodes[new].metadata, new_metadata,
        "a late read for the removed file must not reach the new one"
    );
    assert!(cache.pending_metadata_ids().is_empty());
    assert!(
        !cache.store_indexed_metadata(&read),
        "stored metadata is not replaced"
    );
}

#[test]
fn test_persistent_roundtrip() {
    let tmp = TempDir::new("persist_round").unwrap();
    fs::write(tmp.path().join("a.bin"), b"data").unwrap();
    let cache_path = tmp.path().join("cache.zstd");
    let cache = SearchCache::walk_fs(tmp.path());
    let original_total = cache.get_total_files();
    cache.flush_to_file(&cache_path).unwrap();
    let loaded = SearchCache::try_read_persistent_cache(
        tmp.path(),
        &cache_path,
        &Vec::new(),
        &Vec::new(),
        &NEVER_STOPPED,
    )
    .unwrap();
    assert_eq!(loaded.get_total_files(), original_total);
}

#[test]
fn decoded_snapshot_constructor_matches_validated_loader() {
    let tmp = TempDir::new("decoded_snapshot").unwrap();
    fs::write(tmp.path().join("résumé.txt"), b"fixture").unwrap();
    let snapshot = tmp.path().join("index.zstd");
    SearchCache::walk_fs(tmp.path())
        .flush_to_file(&snapshot)
        .unwrap();
    let before = fs::read(&snapshot).unwrap();
    let mut decoded = SearchCache::from_persistent_storage(
        crate::read_cache_from_file(&snapshot).unwrap(),
        &NEVER_STOPPED,
    );
    let mut validated = SearchCache::try_read_persistent_cache(
        tmp.path(),
        &snapshot,
        &vec![],
        &vec![],
        &NEVER_STOPPED,
    )
    .unwrap();
    assert_eq!(decoded.get_total_files(), validated.get_total_files());
    assert_eq!(decoded.ignore_paths(), validated.ignore_paths());
    assert_eq!(decoded.include_paths(), validated.include_paths());
    for query in ["", "résumé", "*.txt", "missing"] {
        assert_eq!(
            decoded.search(query).unwrap(),
            validated.search(query).unwrap()
        );
    }
    assert_eq!(fs::read(&snapshot).unwrap(), before);
    for (root, ignores, includes) in [
        (tmp.path().join("wrong"), vec![], vec![]),
        (
            tmp.path().to_path_buf(),
            vec![tmp.path().join("ignored")],
            vec![],
        ),
        (
            tmp.path().to_path_buf(),
            vec![],
            vec![tmp.path().join("included")],
        ),
    ] {
        assert!(
            SearchCache::try_read_persistent_cache(
                &root,
                &snapshot,
                &ignores,
                &includes,
                &NEVER_STOPPED
            )
            .is_err()
        );
    }
    fs::write(&snapshot, b"not a compressed snapshot").unwrap();
    assert!(crate::read_cache_from_file(&snapshot).is_err());
    assert!(
        SearchCache::try_read_persistent_cache(
            tmp.path(),
            &snapshot,
            &vec![],
            &vec![],
            &NEVER_STOPPED,
        )
        .is_err()
    );
}
