#[cfg(test)]
use fswalk::NodeFileType;
#[cfg(test)]
use search_cache::{SearchResultNode, SlabIndex, SlabNodeMetadataCompact};
use serde::Deserialize;
#[cfg(test)]
use std::{cmp::Ordering as StdOrdering, path::Path};

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SortStatePayload {
    pub key: SortKeyPayload,
    pub direction: SortDirectionPayload,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SortKeyPayload {
    Filename,
    FullPath,
    Size,
    Mtime,
    Ctime,
}

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SortDirectionPayload {
    Asc,
    Desc,
}

impl From<SortKeyPayload> for search_cache::SortColumn {
    fn from(key: SortKeyPayload) -> Self {
        match key {
            SortKeyPayload::Filename => Self::Filename,
            SortKeyPayload::FullPath => Self::FullPath,
            SortKeyPayload::Size => Self::AllocatedSize,
            SortKeyPayload::Mtime => Self::Mtime,
            SortKeyPayload::Ctime => Self::Ctime,
        }
    }
}

// Keep the original path-based comparator as an independent test oracle.
#[cfg(test)]
mod reference {
    use super::*;
    #[derive(Debug)]
    pub(crate) struct SortEntry {
        pub(crate) slab_index: SlabIndex,
        node: SearchResultNode,
        path_key: String,
        name_key: String,
    }

    impl SortEntry {
        pub(crate) fn new(slab_index: SlabIndex, node: SearchResultNode) -> Self {
            let path_key = normalize_path(&node.path);
            let name_key = extract_filename(&node);
            Self {
                slab_index,
                node,
                path_key,
                name_key,
            }
        }
    }

    pub(crate) fn sort_entries(entries: &mut [SortEntry], sort: &SortStatePayload) {
        entries.sort_by(|a, b| compare_entries(a, b, sort));
    }

    fn normalize_path(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    fn extract_filename(node: &SearchResultNode) -> String {
        node.path
            .file_name()
            .and_then(|name| name.to_str())
            .map(|x| x.to_string())
            .unwrap_or_else(|| node.path.to_string_lossy().into_owned())
    }

    fn metadata_numeric(meta: &SlabNodeMetadataCompact, key: SortKeyPayload) -> i64 {
        let Some(meta_ref) = meta.as_ref() else {
            return i64::MIN;
        };
        match key {
            SortKeyPayload::Size => meta_ref.allocated_size(),
            SortKeyPayload::Mtime => meta_ref
                .mtime()
                .map(|value| value.get() as i64)
                .unwrap_or(i64::MIN),
            SortKeyPayload::Ctime => meta_ref
                .ctime()
                .map(|value| value.get() as i64)
                .unwrap_or(i64::MIN),
            SortKeyPayload::FullPath | SortKeyPayload::Filename => 0,
        }
    }

    fn type_order(node: &SearchResultNode) -> u8 {
        match node.metadata.as_ref().map(|m| m.r#type()) {
            Some(NodeFileType::Dir) => 0,
            None => 2,
            _ => 1,
        }
    }

    fn compare_entries(a: &SortEntry, b: &SortEntry, sort: &SortStatePayload) -> StdOrdering {
        let ordering = match sort.key {
            SortKeyPayload::FullPath => a
                .path_key
                .cmp(&b.path_key)
                .then_with(|| a.name_key.cmp(&b.name_key))
                .then_with(|| type_order(&a.node).cmp(&type_order(&b.node))),
            SortKeyPayload::Filename => a
                .name_key
                .cmp(&b.name_key)
                .then_with(|| type_order(&a.node).cmp(&type_order(&b.node)))
                .then_with(|| a.path_key.cmp(&b.path_key)),
            SortKeyPayload::Size | SortKeyPayload::Mtime | SortKeyPayload::Ctime => {
                metadata_numeric(&a.node.metadata, sort.key)
                    .cmp(&metadata_numeric(&b.node.metadata, sort.key))
                    .then_with(|| a.name_key.cmp(&b.name_key))
                    .then_with(|| type_order(&a.node).cmp(&type_order(&b.node)))
                    .then_with(|| a.path_key.cmp(&b.path_key))
            }
        };

        match sort.direction {
            SortDirectionPayload::Asc => ordering,
            SortDirectionPayload::Desc => ordering.reverse(),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use fswalk::NodeMetadata;
        use std::path::PathBuf;

        fn entry_with_metadata(
            slab_index: usize,
            path: &str,
            metadata: SlabNodeMetadataCompact,
        ) -> SortEntry {
            let node = SearchResultNode {
                path: PathBuf::from(path),
                metadata,
            };

            SortEntry::new(SlabIndex::new(slab_index), node)
        }

        fn metadata_with_type(r#type: NodeFileType, size: u64) -> SlabNodeMetadataCompact {
            SlabNodeMetadataCompact::some(NodeMetadata {
                r#type,
                size,
                allocated_size: size,
                ctime: None,
                mtime: None,
            })
        }

        fn verify_orders(cache: &mut search_cache::SearchCache) {
            let all = cache
                .search_empty(search_cancel::CancellationToken::noop())
                .unwrap();
            for step in [1, 2, 17, 100] {
                let ids: Vec<_> = all.iter().step_by(step).copied().collect();
                for key in [
                    SortKeyPayload::Filename,
                    SortKeyPayload::FullPath,
                    SortKeyPayload::Size,
                    SortKeyPayload::Mtime,
                    SortKeyPayload::Ctime,
                ] {
                    for direction in [SortDirectionPayload::Asc, SortDirectionPayload::Desc] {
                        let nodes = cache.expand_cached_file_nodes(&ids);
                        let mut expected: Vec<_> = ids
                            .iter()
                            .copied()
                            .zip(nodes)
                            .map(|(id, node)| SortEntry::new(id, node))
                            .collect();
                        sort_entries(&mut expected, &SortStatePayload { key, direction });
                        let mut actual = ids.clone();
                        cache
                            .sort_results(
                                &mut actual,
                                key.into(),
                                matches!(direction, SortDirectionPayload::Desc),
                                search_cancel::CancellationToken::noop(),
                            )
                            .unwrap();
                        assert_eq!(
                            actual,
                            expected.iter().map(|e| e.slab_index).collect::<Vec<_>>(),
                            "{key:?} {direction:?}, stride {step}"
                        );
                    }
                }
            }
        }

        #[test]
        fn maintained_indexes_match_original_sort_after_metadata_and_filesystem_changes() {
            use cardinal_sdk::{EventFlag, FsEvent};
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().join("files");
            for folder in ["a", "a.txt", "a!", "a0", "é", "中", "z/deep", "z.deep"] {
                std::fs::create_dir_all(root.join(folder)).unwrap();
                for i in 0..1100 {
                    std::fs::write(root.join(folder).join(format!("item-{i:03}")), "x").unwrap();
                }
            }
            std::os::unix::fs::symlink("missing-target", root.join("broken-link")).unwrap();
            let mut cache = search_cache::SearchCache::walk_fs(&root);
            cache.prepare_sort_indexes();
            verify_orders(&mut cache); // Unknown dates/size and root paths.
            for (i, id) in cache.pending_metadata_ids().into_iter().enumerate() {
                let path = cache.pending_metadata_path(id).unwrap();
                let metadata = if i % 19 == 0 {
                    SlabNodeMetadataCompact::unaccessible()
                } else {
                    SlabNodeMetadataCompact::some(NodeMetadata {
                        r#type: if i % 23 == 0 {
                            NodeFileType::Dir
                        } else {
                            NodeFileType::File
                        },
                        size: (i % 11) as u64,
                        allocated_size: (i % 17) as u64 * 4096,
                        mtime: std::num::NonZeroU64::new((i % 13) as u64),
                        ctime: std::num::NonZeroU64::new((i % 7) as u64),
                    })
                };
                assert!(cache.store_indexed_metadata(id, &path, metadata));
                if i == 63 {
                    verify_orders(&mut cache);
                }
            }
            verify_orders(&mut cache); // Metadata changes affect type and numeric ties.
            std::fs::remove_dir_all(root.join("a")).unwrap();
            std::fs::rename(root.join("z"), root.join("b")).unwrap();
            std::fs::create_dir(root.join("a/new"))
                .unwrap_or_else(|_| std::fs::create_dir_all(root.join("a/new")).unwrap());
            std::fs::write(root.join("a/new/item-001"), "replacement").unwrap();
            cache
                .handle_fs_events(
                    ["a", "z", "b"]
                        .into_iter()
                        .map(|folder| FsEvent {
                            path: root.join(folder),
                            id: 100,
                            flag: EventFlag::ItemModified,
                        })
                        .collect(),
                )
                .unwrap();
            verify_orders(&mut cache); // Removed subtree, rename, insertion and ID reuse.
            let snapshot = temp.path().join("snapshot.db");
            cache.flush_snapshot_to_file(&snapshot).unwrap();
            static STOP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
            let mut reopened = search_cache::SearchCache::from_persistent_storage(
                search_cache::read_cache_from_file(&snapshot).unwrap(),
                &STOP,
            );
            reopened.prepare_sort_indexes();
            verify_orders(&mut reopened);
        }

        #[test]
        fn filename_sort_keeps_directories_before_files() {
            let sort_state = SortStatePayload {
                key: SortKeyPayload::Filename,
                direction: SortDirectionPayload::Asc,
            };
            let mut entries = vec![
                entry_with_metadata(
                    1,
                    "/tmp/b/foo.txt",
                    metadata_with_type(NodeFileType::File, 0),
                ),
                entry_with_metadata(2, "/tmp/c/foo.txt", SlabNodeMetadataCompact::none()),
                entry_with_metadata(
                    0,
                    "/tmp/a/foo.txt",
                    metadata_with_type(NodeFileType::Dir, 0),
                ),
            ];

            sort_entries(&mut entries, &sort_state);
            let order: Vec<usize> = entries.iter().map(|entry| entry.slab_index.get()).collect();

            assert_eq!(
                order,
                vec![0, 1, 2],
                "directories should be listed before files, and files before nodes without metadata"
            );
        }

        #[test]
        fn size_sort_prioritizes_directories_and_paths_for_ties() {
            let sort_state = SortStatePayload {
                key: SortKeyPayload::Size,
                direction: SortDirectionPayload::Asc,
            };
            let mut entries = vec![
                entry_with_metadata(1, "/tmp/z/foo", metadata_with_type(NodeFileType::File, 5)),
                entry_with_metadata(0, "/tmp/m/foo", metadata_with_type(NodeFileType::Dir, 5)),
                entry_with_metadata(2, "/tmp/a/foo", metadata_with_type(NodeFileType::File, 5)),
            ];

            sort_entries(&mut entries, &sort_state);
            let order: Vec<usize> = entries.iter().map(|entry| entry.slab_index.get()).collect();

            assert_eq!(
                order,
                vec![0, 2, 1],
                "directories stay ahead when size and names match, while files fall back to path order"
            );
        }

        #[test]
        fn indexed_dates_sort_by_timestamp_in_both_directions() {
            for key in [SortKeyPayload::Mtime, SortKeyPayload::Ctime] {
                for direction in [SortDirectionPayload::Asc, SortDirectionPayload::Desc] {
                    let make = |id, name, modified, created| {
                        entry_with_metadata(
                            id,
                            name,
                            SlabNodeMetadataCompact::some(NodeMetadata {
                                r#type: NodeFileType::File,
                                size: 1,
                                allocated_size: 4096,
                                mtime: std::num::NonZeroU64::new(modified),
                                ctime: std::num::NonZeroU64::new(created),
                            }),
                        )
                    };
                    let mut entries = vec![make(0, "/a", 200, 100), make(1, "/z", 100, 200)];
                    sort_entries(&mut entries, &SortStatePayload { key, direction });
                    let first = match (key, direction) {
                        (SortKeyPayload::Mtime, SortDirectionPayload::Asc)
                        | (SortKeyPayload::Ctime, SortDirectionPayload::Desc) => 1,
                        _ => 0,
                    };
                    assert_eq!(entries[0].slab_index.get(), first);
                }
            }
        }
    }
}
