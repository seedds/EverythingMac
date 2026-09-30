use crate::{SlabIndex, SlabNode, ThinSlab};
use std::{
    cmp::Ordering,
    ffi::OsStr,
    ops::{Deref, DerefMut},
    path::{Path, PathBuf},
};

#[derive(Debug)]
pub struct FileNodes {
    pub(crate) exclusions: fswalk::Exclusions,
    path: PathBuf,
    ignore_paths: Vec<PathBuf>,
    include_paths: Vec<PathBuf>,
    slab: ThinSlab<SlabNode>,
    root: SlabIndex,
}

impl FileNodes {
    pub(crate) fn new(
        path: PathBuf,
        ignore_paths: Vec<PathBuf>,
        include_paths: Vec<PathBuf>,
        slab: ThinSlab<SlabNode>,
        root: SlabIndex,
    ) -> Self {
        Self {
            exclusions: Default::default(),
            path,
            ignore_paths,
            include_paths,
            slab,
            root,
        }
    }

    pub(crate) fn root(&self) -> SlabIndex {
        self.root
    }

    pub fn node_path(&self, index: SlabIndex) -> Option<PathBuf> {
        let mut current = index;
        let mut segments = vec![];
        while let Some(parent) = self.slab.get(current)?.parent() {
            segments.push(self.slab.get(current)?.name());
            current = parent;
        }
        Some(
            std::iter::once("/")
                .chain(segments.into_iter().rev())
                .map(OsStr::new)
                .collect(),
        )
    }

    /// Writes the nodes from the top-level entry down to `index` itself, omitting
    /// the root that every path shares. `None` if a node is missing.
    pub(crate) fn path_chain(
        &self,
        mut index: SlabIndex,
        chain: &mut Vec<SlabIndex>,
    ) -> Option<()> {
        chain.clear();
        while let Some(parent) = self.slab.get(index)?.parent() {
            chain.push(index);
            index = parent;
        }
        chain.reverse();
        Some(())
    }

    /// Orders two `path_chain`s component by component, which is the order of
    /// `PathBuf`'s `Ord` kept by the name index, without building either path.
    pub(crate) fn cmp_chains(&self, a: &[SlabIndex], b: &[SlabIndex]) -> Ordering {
        for (x, y) in a.iter().zip(b) {
            if x != y {
                let order = self.slab[*x].name().cmp(self.slab[*y].name());
                if order.is_ne() {
                    return order;
                }
            }
        }
        a.len().cmp(&b.len())
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn ignore_paths(&self) -> &Vec<PathBuf> {
        &self.ignore_paths
    }

    pub(crate) fn include_paths(&self) -> &Vec<PathBuf> {
        &self.include_paths
    }

    pub(crate) fn slab(&self) -> &ThinSlab<SlabNode> {
        &self.slab
    }

    pub(crate) fn into_parts(
        self,
    ) -> (
        PathBuf,
        Vec<PathBuf>,
        Vec<PathBuf>,
        SlabIndex,
        ThinSlab<SlabNode>,
    ) {
        let Self {
            path,
            ignore_paths,
            include_paths,
            slab,
            root,
            ..
        } = self;
        (path, ignore_paths, include_paths, root, slab)
    }
}

impl Deref for FileNodes {
    type Target = ThinSlab<SlabNode>;

    fn deref(&self) -> &Self::Target {
        &self.slab
    }
}

impl DerefMut for FileNodes {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.slab
    }
}
