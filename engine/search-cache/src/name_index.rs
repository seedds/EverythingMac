use crate::{FileNodes, NAME_POOL, SlabIndex};
use hashbrown::HashSet;
use itertools::Itertools;
use search_cancel::CancellationToken;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, time::Instant};
use thin_vec::ThinVec;
use tracing::info;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[repr(transparent)]
#[serde(transparent)]
pub struct SortedSlabIndices {
    indices: ThinVec<SlabIndex>,
}

impl SortedSlabIndices {
    pub fn new(index: SlabIndex) -> Self {
        Self {
            indices: ThinVec::from_iter([index]),
        }
    }

    pub fn len(&self) -> usize {
        self.indices.len()
    }

    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &SlabIndex> {
        self.indices.iter()
    }

    pub fn insert(&mut self, index: SlabIndex, slab: &FileNodes) {
        let mut target = Vec::new();
        if slab.path_chain(index, &mut target).is_none() {
            return;
        }
        if let Err(pos) = self.position(&target, slab) {
            self.indices.insert(pos, index);
        }
    }

    /// Binary-searches by path, comparing ancestor chains instead of building a
    /// path for every probe.
    fn position(&self, target: &[SlabIndex], slab: &FileNodes) -> Result<usize, usize> {
        let mut chain = Vec::with_capacity(target.len());
        self.indices.binary_search_by(|existing| {
            slab.path_chain(*existing, &mut chain)
                .expect("node in name index must resolve to a path");
            slab.cmp_chains(&chain, target)
        })
    }

    /// Removes one ID found by path; the node must still be in the slab.
    fn remove_by_path(&mut self, index: SlabIndex, slab: &FileNodes) -> bool {
        let mut target = Vec::new();
        if slab.path_chain(index, &mut target).is_some()
            && let Ok(pos) = self.position(&target, slab)
            && self.indices[pos] == index
        {
            self.indices.remove(pos);
            return true;
        }
        // Duplicate paths from older indexes can hide the ID from the search.
        self.remove(index)
    }

    /// Removes several IDs in one pass; returns how many were present.
    fn remove_many(&mut self, ids: &[SlabIndex]) -> usize {
        let ids: HashSet<SlabIndex> = ids.iter().copied().collect();
        let before = self.indices.len();
        self.indices.retain(|id| !ids.contains(id));
        before - self.indices.len()
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    pub unsafe fn insert_ordered(&mut self, index: SlabIndex) {
        self.indices.push(index);
    }

    pub fn remove(&mut self, index: SlabIndex) -> bool {
        if let Some(pos) = self.indices.iter().position(|&existing| existing == index) {
            self.indices.remove(pos);
            true
        } else {
            false
        }
    }
}

#[derive(Clone, Default)]
pub struct NameIndex {
    map: BTreeMap<&'static str, SortedSlabIndices>,
}

impl NameIndex {
    pub(crate) fn groups(&self) -> impl Iterator<Item = &SortedSlabIndices> {
        self.map.values()
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn all_indices(&self, cancellation_token: CancellationToken) -> Option<Vec<SlabIndex>> {
        self.map
            .values()
            .flat_map(|indices| indices.iter().copied())
            .enumerate()
            .map(|(i, index)| {
                cancellation_token
                    .is_cancelled_sparse(i)
                    .map(|()| index)
                    .ok_or(())
            })
            .try_collect()
            .ok()
    }

    pub fn get(&self, name: &str) -> Option<&SortedSlabIndices> {
        self.map.get(name)
    }

    pub fn get_mut(&mut self, name: &str) -> Option<&mut SortedSlabIndices> {
        self.map.get_mut(name)
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    pub unsafe fn add_index_ordered(&mut self, name: &str, index: SlabIndex) {
        if let Some(existing) = self.map.get_mut(name) {
            unsafe {
                existing.insert_ordered(index);
            }
        } else {
            let interned = NAME_POOL.push(name);
            self.map.insert(interned, SortedSlabIndices::new(index));
        }
    }

    pub fn add_index(&mut self, name: &str, index: SlabIndex, slab: &FileNodes) {
        if let Some(existing) = self.map.get_mut(name) {
            existing.insert(index, slab);
        } else {
            let interned = NAME_POOL.push(name);
            self.map.insert(interned, SortedSlabIndices::new(index));
        }
    }

    pub fn remove_index(&mut self, name: &str, index: SlabIndex) -> bool {
        let Some(indices) = self.map.get_mut(name) else {
            return false;
        };
        let removed = indices.remove(index);
        if indices.is_empty() {
            self.map.remove(name);
        }
        removed
    }

    /// Removes IDs sharing `name` while their nodes are still in the slab; returns
    /// how many were present. Deleting a subtree updates each name's postings once
    /// instead of scanning them for every removed file.
    pub fn remove_indices(&mut self, name: &str, ids: &[SlabIndex], slab: &FileNodes) -> usize {
        let Some(indices) = self.map.get_mut(name) else {
            return 0;
        };
        let removed = match ids {
            [index] => usize::from(indices.remove_by_path(*index, slab)),
            _ => indices.remove_many(ids),
        };
        if indices.is_empty() {
            self.map.remove(name);
        }
        removed
    }

    pub fn remove(&mut self, name: &str) -> Option<SortedSlabIndices> {
        self.map.remove(name)
    }

    pub(crate) fn as_persistent(&self) -> BTreeMap<Box<str>, SortedSlabIndices> {
        self.map
            .iter()
            .map(|(name, indices)| ((*name).to_string().into_boxed_str(), indices.clone()))
            .collect()
    }

    pub fn into_persistent(self) -> BTreeMap<Box<str>, SortedSlabIndices> {
        self.map
            .into_iter()
            .map(|(name, indices)| (name.to_string().into_boxed_str(), indices))
            .collect()
    }

    pub fn construct_name_pool(data: BTreeMap<Box<str>, SortedSlabIndices>) -> Self {
        let name_pool_time = Instant::now();
        let mut map = BTreeMap::new();
        for (name, indices) in data {
            let interned = NAME_POOL.push(&name);
            map.insert(interned, indices);
        }
        info!(
            "Name pool construction time: {:?}, count: {}",
            name_pool_time.elapsed(),
            NAME_POOL.len(),
        );
        Self { map }
    }
}
