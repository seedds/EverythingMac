use crate::SlabIndex;

/// A set of slab indices with one bit per slot. Queries combine sets of millions of
/// nodes, where hashing each index costs far more than setting a bit. Memory grows
/// with the largest index added: about 600 KiB for a 5-million-slot index.
#[derive(Default)]
pub(crate) struct NodeSet(Vec<u64>);

impl NodeSet {
    pub(crate) fn from_indices(indices: &[SlabIndex]) -> Self {
        let mut set = Self::default();
        if let Some(max) = indices.iter().map(SlabIndex::get).max() {
            set.0 = vec![0; max / 64 + 1];
        }
        for &index in indices {
            set.insert(index);
        }
        set
    }

    /// Returns whether the index was not present before.
    pub(crate) fn insert(&mut self, index: SlabIndex) -> bool {
        let (word, bit) = (index.get() / 64, 1 << (index.get() % 64));
        if word >= self.0.len() {
            self.0.resize(word + 1, 0);
        }
        let added = self.0[word] & bit == 0;
        self.0[word] |= bit;
        added
    }

    pub(crate) fn contains(&self, index: SlabIndex) -> bool {
        self.0
            .get(index.get() / 64)
            .is_some_and(|word| word & (1 << (index.get() % 64)) != 0)
    }
}

/// Removes repeated indices, keeping each one's first position.
pub(crate) fn dedup_in_place(indices: &mut Vec<SlabIndex>) {
    let mut seen = NodeSet::default();
    indices.retain(|&index| seen.insert(index));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_contains_and_dedup() {
        let mut set = NodeSet::default();
        assert!(!set.contains(SlabIndex::new(1_000_000)));
        assert!(set.insert(SlabIndex::new(130)));
        assert!(!set.insert(SlabIndex::new(130)));
        assert!(set.insert(SlabIndex::new(0)));
        assert!(set.contains(SlabIndex::new(130)));
        assert!(!set.contains(SlabIndex::new(129)));
        assert!(!set.contains(SlabIndex::new(131)));

        let from = NodeSet::from_indices(&[SlabIndex::new(63), SlabIndex::new(64)]);
        assert!(from.contains(SlabIndex::new(63)) && from.contains(SlabIndex::new(64)));
        assert!(!from.contains(SlabIndex::new(65)));
        assert!(!NodeSet::from_indices(&[]).contains(SlabIndex::new(0)));

        let mut indices: Vec<_> = [5, 3, 5, 200, 3, 0].map(SlabIndex::new).into();
        dedup_in_place(&mut indices);
        assert_eq!(indices, [5, 3, 200, 0].map(SlabIndex::new));
    }
}
