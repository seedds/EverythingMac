use crate::{
    SlabIndex, SlabNode, ThinSlab, name_index::SortedSlabIndices, names, node_set::NodeSet,
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{self, BufReader, BufWriter, Write},
    path::{Path, PathBuf},
    thread::available_parallelism,
    time::Instant,
};
use tracing::info;
use typed_num::Num;

const LSF_VERSION: i64 = 9;

/// A decoded index. Its items point at their names' keys in `name_index`, so an
/// item must not outlive its name's key there.
#[derive(Serialize, Deserialize)]
pub struct PersistentStorage {
    pub version: Num<LSF_VERSION>,
    pub exclusion_patterns: Vec<String>,
    /// The last event id of the cache.
    pub last_event_id: u64,
    /// The FSEvents history `last_event_id` belongs to; see
    /// `everything_mac_sdk::event_history_id`. `None` in indexes saved before v9.
    pub event_history: Option<u128>,
    /// Root file path of the cache
    pub path: PathBuf,
    /// Ignore paths
    pub ignore_paths: Vec<PathBuf>,
    /// Paths to include even when they fall under an ignored directory.
    pub include_paths: Vec<PathBuf>,
    /// Root index of the slab
    pub slab_root: SlabIndex,
    pub slab: ThinSlab<SlabNode>,
    #[serde(deserialize_with = "names::decode_name_index")]
    pub name_index: BTreeMap<Box<str>, SortedSlabIndices>,
    /// The number of rescans emitted before this snapshot.
    pub rescan_count: u64,
}

/// A borrowed view of the cache with exactly the serialized layout of
/// `PersistentStorage` (postcard writes slices, paths, and `&str` keys like the
/// owned types), so saving needs no copy of the slab or the name index.
#[derive(Serialize)]
pub(crate) struct PersistentStorageRef<'a> {
    pub version: Num<LSF_VERSION>,
    pub exclusion_patterns: &'a [String],
    pub last_event_id: u64,
    pub event_history: Option<u128>,
    pub path: &'a Path,
    pub ignore_paths: &'a [PathBuf],
    pub include_paths: &'a [PathBuf],
    pub slab_root: SlabIndex,
    pub slab: &'a ThinSlab<SlabNode>,
    pub name_index: &'a BTreeMap<Box<str>, SortedSlabIndices>,
    pub rescan_count: u64,
}

// v8 had no event history.
#[derive(Serialize, Deserialize)]
struct StorageV8 {
    version: Num<8>,
    exclusion_patterns: Vec<String>,
    last_event_id: u64,
    path: PathBuf,
    ignore_paths: Vec<PathBuf>,
    include_paths: Vec<PathBuf>,
    slab_root: SlabIndex,
    slab: ThinSlab<SlabNode>,
    #[serde(deserialize_with = "names::decode_name_index")]
    name_index: BTreeMap<Box<str>, SortedSlabIndices>,
    rescan_count: u64,
}

impl From<StorageV8> for PersistentStorage {
    fn from(old: StorageV8) -> Self {
        Self {
            version: Num,
            exclusion_patterns: old.exclusion_patterns,
            last_event_id: old.last_event_id,
            event_history: None,
            path: old.path,
            ignore_paths: old.ignore_paths,
            include_paths: old.include_paths,
            slab_root: old.slab_root,
            slab: old.slab,
            name_index: old.name_index,
            rescan_count: old.rescan_count,
        }
    }
}

// v7 retains its original field order for postcard compatibility.
#[derive(Serialize, Deserialize)]
struct LegacyStorage {
    version: Num<7>,
    last_event_id: u64,
    path: PathBuf,
    ignore_paths: Vec<PathBuf>,
    include_paths: Vec<PathBuf>,
    slab_root: SlabIndex,
    slab: ThinSlab<SlabNode>,
    #[serde(deserialize_with = "names::decode_name_index")]
    name_index: BTreeMap<Box<str>, SortedSlabIndices>,
    rescan_count: u64,
}

fn decode_storage<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let mut bytes = vec![0u8; 4 * 1024];
    let input = File::open(path).context("Failed to open cache file")?;
    let input = zstd::Decoder::new(input).context("Failed to create cache decoder")?;
    let mut input = BufReader::new(input);
    let storage = names::decoding(|| postcard::from_io((&mut input, &mut bytes)))?.0;
    // zstd checks the frame's checksum only at its end, after the last value.
    io::copy(&mut input, &mut io::sink()).context("The index file is damaged or incomplete")?;
    Ok(storage)
}

pub fn read_cache_from_file(path: &Path) -> Result<PersistentStorage> {
    read_cache_with_format(path).map(|(storage, _)| storage)
}

/// Also reports whether the file uses an earlier layout (v7 or v8), which the
/// next checkpoint should rewrite even when the index is otherwise unchanged.
/// Each attempt with the wrong version fails at the first byte.
pub fn read_cache_with_format(path: &Path) -> Result<(PersistentStorage, bool)> {
    let (storage, legacy): (PersistentStorage, bool) = match decode_storage(path) {
        Ok(storage) => (storage, false),
        Err(current_error) => {
            let storage = decode_storage::<StorageV8>(path)
                .map(PersistentStorage::from)
                .or_else(|_| {
                    decode_storage::<LegacyStorage>(path).map(|old| PersistentStorage {
                        version: Num,
                        exclusion_patterns: vec![],
                        last_event_id: old.last_event_id,
                        event_history: None,
                        path: old.path,
                        ignore_paths: old.ignore_paths,
                        include_paths: old.include_paths,
                        slab_root: old.slab_root,
                        slab: old.slab,
                        name_index: old.name_index,
                        rescan_count: old.rescan_count,
                    })
                })
                .map_err(|_| current_error)
                .context("Failed to decode index (supported formats: v7, v8, and v9)")?;
            (storage, true)
        }
    };
    fswalk::Exclusions::compile(&storage.path, &storage.exclusion_patterns)
        .map_err(anyhow::Error::msg)?;
    storage
        .check_structure()
        .context("The index file is damaged")?;
    Ok((storage, legacy))
}

impl PersistentStorage {
    /// Checks that the items form one tree under the root and that the name index
    /// lists each item once under its own name. A damaged index is then rejected
    /// here, instead of panicking or looping when it is searched or updated.
    fn check_structure(&self) -> Result<()> {
        let slab = &self.slab;
        let root = slab.get(self.slab_root).context("the root is missing")?;
        ensure!(root.parent().is_none(), "the root has a parent");
        let mut listed = NodeSet::default();
        listed.insert(self.slab_root);
        let mut reached = 1;
        let mut stack = vec![self.slab_root];
        while let Some(index) = stack.pop() {
            let node = &slab[index];
            ensure!(
                node.metadata.is_valid(),
                "item {} has invalid metadata",
                index.get()
            );
            for &child in &node.children {
                let child_node = slab.get(child).with_context(|| {
                    format!("item {} lists missing item {}", index.get(), child.get())
                })?;
                ensure!(
                    child_node.parent() == Some(index),
                    "item {} is listed by item {} but has another parent",
                    child.get(),
                    index.get()
                );
                ensure!(listed.insert(child), "item {} is listed twice", child.get());
                reached += 1;
                stack.push(child);
            }
        }
        ensure!(
            reached == slab.len(),
            "{} of {} items are not under the root",
            slab.len() - reached,
            slab.len()
        );
        let mut indexed = NodeSet::default();
        let mut postings = 0;
        for (name, indices) in &self.name_index {
            for &index in indices.iter() {
                let node = slab.get(index).with_context(|| {
                    format!("the name index lists missing item {}", index.get())
                })?;
                // Each item points at its name's key; comparing addresses reads
                // no name an item might point at after a damaged decode.
                ensure!(
                    node.name().as_ptr() == name.as_ptr() && node.name().len() == name.len(),
                    "item {} is indexed under another name",
                    index.get()
                );
                ensure!(
                    indexed.insert(index),
                    "item {} is indexed twice",
                    index.get()
                );
                postings += 1;
            }
        }
        ensure!(
            postings == slab.len(),
            "the name index lists {postings} of {} items",
            slab.len()
        );
        Ok(())
    }
}

pub fn write_cache_to_file(path: &Path, storage: &impl Serialize) -> Result<()> {
    let cache_encode_time = Instant::now();
    let parent = path
        .parent()
        .context("Cache path has no parent directory")?;
    let _ = fs::create_dir_all(parent);
    let tmp_path = path.with_extension("sctmp");
    // Replace the previous snapshot only after every byte is encoded and durable.
    let written = File::create(&tmp_path)
        .context("Failed to create cache file")
        .and_then(|file| encode_storage(file, storage))
        .and_then(|file| file.sync_all().context("Failed to sync cache file"))
        .and_then(|()| fs::rename(&tmp_path, path).context("Failed to rename cache file"));
    if let Err(error) = written {
        let _ = fs::remove_file(&tmp_path);
        return Err(error);
    }
    // Best effort: persist the directory entry created by the rename.
    if let Ok(directory) = File::open(parent) {
        let _ = directory.sync_all();
    }
    info!("Cache encode time: {:?}", cache_encode_time.elapsed());
    info!(
        "Cache size: {} MB",
        fs::symlink_metadata(path)
            .context("Failed to get cache file metadata")?
            .len() as f32
            / 1024.
            / 1024.
    );
    Ok(())
}

/// Encodes a complete zstd frame, returning buffered flush and frame-finish errors
/// that dropping the writers would silently discard.
fn encode_storage<W: Write>(output: W, storage: &impl Serialize) -> Result<W> {
    let mut encoder = zstd::Encoder::new(output, 6).context("Failed to create zstd encoder")?;
    encoder
        .multithread(available_parallelism().map(|x| x.get() as u32).unwrap_or(4))
        .context("Failed to create parallel zstd encoder")?;
    encoder
        .include_checksum(true)
        .context("Failed to enable cache checksum")?;
    let mut output = BufWriter::new(encoder);
    postcard::to_io(storage, &mut output).context("Failed to encode cache")?;
    let encoder = output
        .into_inner()
        .map_err(|error| error.into_error())
        .context("Failed to flush cache")?;
    encoder
        .finish()
        .context("Failed to finish cache compression")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SearchCache;
    use std::os::unix::fs::MetadataExt;

    #[test]
    fn reads_v7_without_rewriting_and_upgrades_on_checkpoint() {
        let temp = tempdir::TempDir::new("v7-migration").unwrap();
        fs::write(temp.path().join("kept.txt"), "data").unwrap();
        let path = temp.path().join("legacy.db");
        SearchCache::walk_fs(temp.path())
            .flush_to_file(&path)
            .unwrap();
        let current = read_cache_from_file(&path).unwrap();
        let old = LegacyStorage {
            version: Num,
            path: current.path,
            last_event_id: current.last_event_id,
            ignore_paths: current.ignore_paths,
            include_paths: current.include_paths,
            slab_root: current.slab_root,
            slab: current.slab,
            name_index: current.name_index,
            rescan_count: current.rescan_count,
        };
        let encoded = postcard::to_stdvec(&old).unwrap();
        fs::write(&path, zstd::encode_all(encoded.as_slice(), 1).unwrap()).unwrap();
        let before = fs::read(&path).unwrap();
        let (current, legacy) = read_cache_with_format(&path).unwrap();
        assert!(legacy);
        assert!(current.exclusion_patterns.is_empty());
        assert_eq!(before, fs::read(&path).unwrap());
        write_cache_to_file(&path, &current).unwrap();
        assert!(decode_storage::<PersistentStorage>(&path).is_ok());
        assert!(!read_cache_with_format(&path).unwrap().1);
    }

    #[test]
    fn reads_v8_without_an_event_history_and_upgrades_on_checkpoint() {
        let temp = tempdir::TempDir::new("v8-migration").unwrap();
        fs::write(temp.path().join("kept.txt"), "data").unwrap();
        let path = temp.path().join("v8.db");
        SearchCache::walk_fs(temp.path())
            .flush_to_file(&path)
            .unwrap();
        let current = read_cache_from_file(&path).unwrap();
        assert!(current.event_history.is_some());
        let last_event_id = current.last_event_id;
        let old = StorageV8 {
            version: Num,
            exclusion_patterns: vec!["*.log".into()],
            last_event_id,
            path: current.path,
            ignore_paths: current.ignore_paths,
            include_paths: current.include_paths,
            slab_root: current.slab_root,
            slab: current.slab,
            name_index: current.name_index,
            rescan_count: current.rescan_count,
        };
        let encoded = postcard::to_stdvec(&old).unwrap();
        fs::write(&path, zstd::encode_all(encoded.as_slice(), 1).unwrap()).unwrap();
        let (current, legacy) = read_cache_with_format(&path).unwrap();
        assert!(legacy);
        assert_eq!(current.event_history, None);
        assert_eq!(current.exclusion_patterns, ["*.log"]);
        assert_eq!(current.last_event_id, last_event_id);
        assert_eq!(current.slab.len(), old.slab.len());
        write_cache_to_file(&path, &current).unwrap();
        assert!(!read_cache_with_format(&path).unwrap().1);
    }

    /// Accepts `remaining` bytes, then fails like a full disk.
    struct FullDisk {
        remaining: usize,
    }

    impl Write for FullDisk {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            if self.remaining == 0 {
                return Err(std::io::ErrorKind::StorageFull.into());
            }
            let written = buf.len().min(self.remaining);
            self.remaining -= written;
            Ok(written)
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn snapshot_storage(temp: &Path) -> PersistentStorage {
        fs::write(temp.join("kept.txt"), "data").unwrap();
        let path = temp.join("source.db");
        SearchCache::walk_fs(temp).flush_to_file(&path).unwrap();
        read_cache_from_file(&path).unwrap()
    }

    #[test]
    fn encoding_reports_errors_from_the_final_flush() {
        let temp = tempdir::TempDir::new("full-disk").unwrap();
        let storage = snapshot_storage(temp.path());
        // A tiny snapshot fits in the buffers, so the failure surfaces only while
        // flushing and finishing the zstd frame.
        for remaining in [0, 8, 64] {
            assert!(encode_storage(FullDisk { remaining }, &storage).is_err());
        }
        assert!(
            encode_storage(
                FullDisk {
                    remaining: usize::MAX
                },
                &storage
            )
            .is_ok()
        );
    }

    #[test]
    fn failed_write_keeps_previous_snapshot_and_removes_temp_file() {
        let temp = tempdir::TempDir::new("failed-write").unwrap();
        let storage = snapshot_storage(temp.path());
        let path = temp.path().join("index.db");
        write_cache_to_file(&path, &storage).unwrap();
        assert!(!path.with_extension("sctmp").exists());
        let before = fs::read(&path).unwrap();

        // The temp file cannot be created: the previous snapshot is untouched.
        fs::create_dir(path.with_extension("sctmp")).unwrap();
        assert!(write_cache_to_file(&path, &storage).is_err());
        assert_eq!(before, fs::read(&path).unwrap());
        assert!(read_cache_from_file(&path).is_ok());

        // The final rename fails: the encoded temp file is removed.
        let blocked = temp.path().join("blocked");
        fs::create_dir_all(blocked.join("occupied")).unwrap();
        assert!(write_cache_to_file(&blocked, &storage).is_err());
        assert!(!blocked.with_extension("sctmp").exists());
    }

    #[test]
    fn borrowed_snapshot_matches_the_owned_encoding() {
        let temp = tempdir::TempDir::new("borrowed-snapshot").unwrap();
        fs::create_dir(temp.path().join("dir")).unwrap();
        for name in ["a.txt", "dir/b.txt", "dir/a.txt"] {
            fs::write(temp.path().join(name), name).unwrap();
        }
        let borrowed = temp.path().join("borrowed.db");
        let owned = temp.path().join("owned.db");
        let cache = SearchCache::walk_fs(temp.path());
        cache.flush_snapshot_to_file(&borrowed).unwrap();
        cache.flush_to_file(&owned).unwrap();
        let decode = |path: &Path| zstd::decode_all(File::open(path).unwrap()).unwrap();
        assert_eq!(decode(&borrowed), decode(&owned));
        assert!(read_cache_from_file(&borrowed).is_ok());
    }

    #[test]
    fn allocated_and_logical_sizes_round_trip_in_fresh_snapshot() {
        let temp = tempdir::TempDir::new("allocated-size").unwrap();
        let sparse = temp.path().join("sparse.raw");
        File::create(&sparse).unwrap().set_len(1 << 30).unwrap();
        let actual = fs::symlink_metadata(&sparse).unwrap().blocks() * 512;
        assert!(actual < 1 << 30);
        let mut cache = SearchCache::walk_fs(temp.path());
        let id = cache.node_index_for_path(&sparse).unwrap();
        cache.expand_file_nodes(&[id]);
        let path = temp.path().join("snapshot.db");
        cache.flush_snapshot_to_file(&path).unwrap();
        let storage = read_cache_from_file(&path).unwrap();
        let metadata = storage.slab[id].metadata.as_ref().unwrap();
        assert_eq!(metadata.size(), 1 << 30);
        assert_eq!(metadata.allocated_size(), actual as i64);
    }
}
