use crate::{SlabIndex, SlabNode, ThinSlab, name_index::SortedSlabIndices};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File},
    io::{BufReader, BufWriter},
    path::{Path, PathBuf},
    thread::available_parallelism,
    time::Instant,
};
use tracing::info;
use typed_num::Num;

const LSF_VERSION: i64 = 8;

#[derive(Serialize, Deserialize)]
pub struct PersistentStorage {
    pub version: Num<LSF_VERSION>,
    pub exclusion_patterns: Vec<String>,
    /// The last event id of the cache.
    pub last_event_id: u64,
    /// Root file path of the cache
    pub path: PathBuf,
    /// Ignore paths
    pub ignore_paths: Vec<PathBuf>,
    /// Paths to include even when they fall under an ignored directory.
    pub include_paths: Vec<PathBuf>,
    /// Root index of the slab
    pub slab_root: SlabIndex,
    pub slab: ThinSlab<SlabNode>,
    pub name_index: BTreeMap<Box<str>, SortedSlabIndices>,
    /// The number of rescans emitted before this snapshot.
    pub rescan_count: u64,
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
    name_index: BTreeMap<Box<str>, SortedSlabIndices>,
    rescan_count: u64,
}

fn decode_storage<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let mut bytes = vec![0u8; 4 * 1024];
    let input = File::open(path).context("Failed to open cache file")?;
    let input = zstd::Decoder::new(input).context("Failed to create cache decoder")?;
    let mut input = BufReader::new(input);
    Ok(postcard::from_io((&mut input, &mut bytes))?.0)
}

pub fn read_cache_from_file(path: &Path) -> Result<PersistentStorage> {
    let storage: PersistentStorage = match decode_storage(path) {
        Ok(storage) => storage,
        Err(current_error) => {
            let old: LegacyStorage = decode_storage(path)
                .map_err(|_| current_error)
                .context("Failed to decode index (supported formats: v7 and v8)")?;
            PersistentStorage {
                version: Num,
                exclusion_patterns: vec![],
                last_event_id: old.last_event_id,
                path: old.path,
                ignore_paths: old.ignore_paths,
                include_paths: old.include_paths,
                slab_root: old.slab_root,
                slab: old.slab,
                name_index: old.name_index,
                rescan_count: old.rescan_count,
            }
        }
    };
    fswalk::Exclusions::compile(&storage.path, &storage.exclusion_patterns)
        .map_err(anyhow::Error::msg)?;
    Ok(storage)
}

pub fn write_cache_to_file(path: &Path, storage: &PersistentStorage) -> Result<()> {
    let cache_encode_time = Instant::now();
    let _ = fs::create_dir_all(path.parent().unwrap());
    let tmp_path = &path.with_extension(".sctmp");
    {
        let output = File::create(tmp_path).context("Failed to create cache file")?;
        let mut output = zstd::Encoder::new(output, 6).context("Failed to create zstd encoder")?;
        output
            .multithread(available_parallelism().map(|x| x.get() as u32).unwrap_or(4))
            .context("Failed to create parallel zstd encoder")?;
        let output = output.auto_finish();
        let mut output = BufWriter::new(output);
        postcard::to_io(storage, &mut output).context("Failed to encode cache")?;
    }
    fs::rename(tmp_path, path).context("Failed to rename cache file")?;
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
        let current = read_cache_from_file(&path).unwrap();
        assert!(current.exclusion_patterns.is_empty());
        assert_eq!(before, fs::read(&path).unwrap());
        write_cache_to_file(&path, &current).unwrap();
        assert!(decode_storage::<PersistentStorage>(&path).is_ok());
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
