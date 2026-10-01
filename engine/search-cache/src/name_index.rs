use crate::{FileNodes, SlabIndex, SlabNode, ThinSlab, names::Names};
use hashbrown::HashSet;
use rayon::prelude::*;
use search_cancel::CancellationToken;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    ops::Bound::{Excluded, Included, Unbounded},
};
use thin_vec::ThinVec;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
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
        // Most names belong to one item.
        if let [only] = self.indices[..] {
            if only != index {
                return false;
            }
            self.indices.clear();
            return true;
        }
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

/// Every item under its name, in path order. The keys own the names: each item
/// points at its name's key, so a key is removed only once no item has its name
/// (see `remove_unused`).
#[derive(Default)]
pub struct NameIndex {
    map: BTreeMap<Box<str>, SortedSlabIndices>,
    /// Boundaries splitting `map` into ranges that `matching_nodes` scans in
    /// parallel. They are copies, so they outlive names that are removed. Stale
    /// boundaries still cover every name; they only unbalance the ranges.
    splits: Vec<Box<str>>,
    /// `map.len()` when `splits` were chosen.
    splits_len: usize,
}

impl NameIndex {
    /// Chooses evenly spaced range boundaries for `matching_nodes`.
    pub(crate) fn refresh_splits(&mut self) {
        let parts = rayon::current_num_threads().max(1) * 4;
        let step = self.map.len().div_ceil(parts).max(1);
        self.splits = self.map.keys().skip(step).step_by(step).cloned().collect();
        self.splits_len = self.map.len();
    }

    /// Rebalances the scan ranges once live changes have added or removed many names.
    fn names_changed(&mut self) {
        if self.map.len().abs_diff(self.splits_len) > self.splits_len / 4 + 1024 {
            self.refresh_splits();
        }
    }

    /// Postings of every name the matcher accepts, in name order. Ranges of names
    /// are scanned in parallel, each with its own matcher from `matcher`.
    pub(crate) fn matching_nodes<M: FnMut(&str) -> bool>(
        &self,
        matcher: impl Fn() -> M + Sync,
        token: CancellationToken,
    ) -> Option<Vec<SlabIndex>> {
        let parts: Vec<Option<Vec<SlabIndex>>> = (0..=self.splits.len())
            .into_par_iter()
            .map(|part| {
                let lower = part
                    .checked_sub(1)
                    .map_or(Unbounded, |i| Included(&*self.splits[i]));
                let upper = self
                    .splits
                    .get(part)
                    .map_or(Unbounded, |name| Excluded(&**name));
                let mut matches = matcher();
                let mut nodes = Vec::new();
                for (i, (name, indices)) in self.map.range::<str, _>((lower, upper)).enumerate() {
                    token.is_cancelled_sparse(i)?;
                    if matches(name) {
                        nodes.extend(indices.iter().copied());
                    }
                }
                Some(nodes)
            })
            .collect();
        let mut nodes = Vec::with_capacity(parts.iter().flatten().map(Vec::len).sum());
        for part in parts {
            nodes.extend(part?);
        }
        Some(nodes)
    }

    /// Reference for tests: postings of accepted names from one serial pass.
    #[cfg(test)]
    pub(crate) fn serial_nodes(&self, matches: impl Fn(&str) -> bool) -> Vec<SlabIndex> {
        self.map
            .iter()
            .filter(|(name, _)| matches(name))
            .flat_map(|(_, indices)| indices.iter().copied())
            .collect()
    }

    /// Postings of every name starting with `prefix`, in name order.
    pub(crate) fn prefix_nodes(
        &self,
        prefix: &str,
        token: CancellationToken,
    ) -> Option<Vec<SlabIndex>> {
        let mut nodes = Vec::new();
        let names = self
            .map
            .range::<str, _>((Included(prefix), Unbounded))
            .take_while(|(name, _)| name.starts_with(prefix));
        for (i, (_, indices)) in names.enumerate() {
            token.is_cancelled_sparse(i)?;
            nodes.extend(indices.iter().copied());
        }
        Some(nodes)
    }

    pub(crate) fn groups(&self) -> impl Iterator<Item = &SortedSlabIndices> {
        self.map.values()
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    /// Every indexed node in name order, collected from ranges of names in parallel.
    pub fn all_indices(&self, cancellation_token: CancellationToken) -> Option<Vec<SlabIndex>> {
        self.matching_nodes(|| |_: &str| true, cancellation_token)
    }

    pub fn get(&self, name: &str) -> Option<&SortedSlabIndices> {
        self.map.get(name)
    }

    pub fn get_mut(&mut self, name: &str) -> Option<&mut SortedSlabIndices> {
        self.map.get_mut(name)
    }

    /// Builds the index from the address of every node's name, interned in
    /// `names`, with the nodes in path order and numbered in that order, as a new
    /// slab numbers them. Sorting and loading the map in bulk avoids a map lookup
    /// for each node. The keys are the interned names, so the nodes point at them.
    pub(crate) fn from_path_order(
        mut postings: Vec<(usize, SlabIndex)>,
        slab: &ThinSlab<SlabNode>,
        names: Names,
    ) -> Self {
        debug_assert!(postings.is_sorted_by_key(|&(_, index)| index));
        // Interned names are equal exactly when they share an address; only the empty
        // name has no allocation, and it is interned once too. Sorting each name's
        // nodes by number keeps them in path order, and sorting in place needs no
        // second buffer of every node.
        postings.par_sort_unstable();
        let mut keys: Vec<Box<str>> = names.into_inner().into_iter().collect();
        keys.par_sort_unstable_by_key(|name| name.as_ptr() as usize);
        let groups = postings.chunk_by(|a, b| a.0 == b.0);
        // Every interned name belongs to a node, so both are in address order.
        assert_eq!(groups.clone().count(), keys.len());
        let mut names = Vec::with_capacity(keys.len());
        names.extend(groups.zip(keys).map(|(group, name)| {
            assert_eq!(group[0].0, name.as_ptr() as usize);
            let indices = group.iter().map(|&(_, index)| index).collect();
            (name, SortedSlabIndices { indices })
        }));
        drop(postings);
        debug_assert!(names.iter().all(|(name, indices)| {
            indices
                .iter()
                .all(|&index| slab[index].name().as_ptr() == name.as_ptr())
        }));
        names.par_sort_unstable_by(|a, b| a.0.cmp(&b.0));
        Self {
            map: names.into_iter().collect(),
            ..Self::default()
        }
    }

    /// The key of an indexed name, for a new item to point at, and its postings.
    /// The key's text stays at its address until `remove_unused` removes it.
    pub(crate) fn postings_of(
        &mut self,
        name: &str,
    ) -> Option<(&'static str, &mut SortedSlabIndices)> {
        let (key, postings) = self
            .map
            .range_mut::<str, _>((Included(name), Included(name)))
            .next()?;
        let key = unsafe { std::str::from_raw_parts(key.as_ptr(), key.len()) };
        Some((key, postings))
    }

    /// Adds a name that is not indexed yet with its first item, which points at
    /// `name`'s text.
    pub(crate) fn add_name(&mut self, name: Box<str>, index: SlabIndex) {
        let previous = self.map.insert(name, SortedSlabIndices::new(index));
        debug_assert!(previous.is_none());
        self.names_changed();
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    #[cfg(test)]
    pub(crate) unsafe fn add_index_ordered(&mut self, name: &str, index: SlabIndex) {
        if let Some(existing) = self.map.get_mut(name) {
            unsafe {
                existing.insert_ordered(index);
            }
        } else {
            self.map
                .insert(Box::from(name), SortedSlabIndices::new(index));
        }
    }

    /// Adds `index` under `name` in path order, as `SearchCache::push_node` does,
    /// but without pointing the node at the key.
    #[cfg(test)]
    pub(crate) fn add_index(&mut self, name: &str, index: SlabIndex, slab: &FileNodes) {
        match self.postings_of(name) {
            Some((_, postings)) => postings.insert(index, slab),
            None => self.add_name(Box::from(name), index),
        }
    }

    /// Removes IDs sharing `name` while their nodes are still in the slab; returns
    /// how many were present, and whether no item has the name any more. Deleting
    /// a subtree updates each name's postings once instead of scanning them for
    /// every removed file. The name stays until `remove_unused`.
    pub fn remove_indices(
        &mut self,
        name: &str,
        ids: &[SlabIndex],
        slab: &FileNodes,
    ) -> (usize, bool) {
        let Some(indices) = self.map.get_mut(name) else {
            return (0, false);
        };
        let count = match ids {
            [index] => usize::from(indices.remove_by_path(*index, slab)),
            _ => indices.remove_many(ids),
        };
        (count, indices.is_empty())
    }

    /// Frees `name`, which `remove_indices` left without items. Called once the
    /// removed items are out of the slab: until then, finding postings by path
    /// reads their names.
    pub(crate) fn remove_unused(&mut self, name: &str) {
        // `name` may be the key's own text; it is not read once found.
        let removed = self.map.remove(name);
        debug_assert!(removed.is_some_and(|indices| indices.is_empty()));
        self.names_changed();
    }

    pub(crate) fn map(&self) -> &BTreeMap<Box<str>, SortedSlabIndices> {
        &self.map
    }

    pub fn into_persistent(self) -> BTreeMap<Box<str>, SortedSlabIndices> {
        self.map
    }

    /// The name index of a decoded index, whose items point at its keys.
    pub(crate) fn from_persistent(map: BTreeMap<Box<str>, SortedSlabIndices>) -> Self {
        Self {
            map,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn index_with(names: &[String]) -> NameIndex {
        let mut index = NameIndex::default();
        for (i, name) in names.iter().enumerate() {
            unsafe { index.add_index_ordered(name, SlabIndex::new(i)) };
        }
        index
    }

    fn serial(index: &NameIndex, matches: impl Fn(&str) -> bool) -> Vec<SlabIndex> {
        index
            .map
            .iter()
            .filter(|(name, _)| matches(name))
            .flat_map(|(_, indices)| indices.iter().copied())
            .collect()
    }

    fn check_matches(index: &NameIndex) {
        for needle in ["a", "beta-1", "É", "中", "zzz", ""] {
            let expected = serial(index, |name| name.contains(needle));
            let actual = index
                .matching_nodes(
                    || |name: &str| name.contains(needle),
                    CancellationToken::noop(),
                )
                .unwrap();
            assert_eq!(actual, expected, "{needle:?}");
        }
        let prefix = index
            .prefix_nodes("gamma-1", CancellationToken::noop())
            .unwrap();
        assert_eq!(prefix, serial(index, |name| name.starts_with("gamma-1")));
    }

    #[test]
    fn parallel_matching_equals_a_serial_scan_with_any_boundaries() {
        let names: Vec<String> = (0..6_000)
            .map(|i| format!("{}-{i}", ["alpha", "beta", "gamma", "ÉTÉ", "中文"][i % 5]))
            .collect();
        let mut index = index_with(&names);
        check_matches(&index); // No boundaries: a single range.
        index.refresh_splits();
        assert!(!index.splits.is_empty());
        check_matches(&index);
        // Removing names (including boundaries) and adding others leaves them stale.
        for name in names.iter().step_by(3) {
            index.map.remove(name.as_str());
        }
        let added: Vec<String> = (0..2_000).map(|i| format!("added-{i}")).collect();
        for (i, name) in added.iter().enumerate() {
            unsafe { index.add_index_ordered(name, SlabIndex::new(10_000 + i)) };
        }
        check_matches(&index);
    }

    #[test]
    fn cancelled_matching_returns_none() {
        let names: Vec<String> = (0..100).map(|i| format!("name-{i}")).collect();
        let mut index = index_with(&names);
        index.refresh_splits();
        let token = CancellationToken::new_search();
        let _ = CancellationToken::new_search();
        assert!(index.matching_nodes(|| |_: &str| true, token).is_none());
        assert!(index.prefix_nodes("name", token).is_none());
    }
}
