//! Applies what walks of changed folders read from disk. A walked item that is
//! already indexed is merged with it, so only what differs changes and unchanged
//! items keep their IDs. Large changes are applied in steps, each leaving the
//! index whole: every item is under the root and in the name index, and each
//! folder's children are in name order. Searches can then run between steps.
use crate::{
    NodeIdentity, SearchCache, SlabIndex, SlabNode, SlabNodeMetadataCompact, ThinSlab,
    cache::{ScanOutcome, ScannedEvents, on_disk_name, same_name_ignoring_case},
};
use fswalk::{Node, NodeMetadata};
use hashbrown::{HashMap, HashSet};
use rayon::prelude::*;
use std::{cmp::Ordering, ffi::OsStr, path::PathBuf, time::Instant};
use thin_vec::ThinVec;

/// Items one step adds to a new folder or removes from a removed one at most, so
/// that a step stays short even for a large folder moved in or out. Other steps
/// each update the children of one folder.
const STEP_ITEMS: usize = 4096;

/// Changes read from disk, applied by `SearchCache::apply_changes`.
pub struct PendingChanges {
    /// Run last first.
    steps: Vec<Step>,
    /// Recorded once every step has run.
    max_event_id: Option<u64>,
}

impl PendingChanges {
    /// Whether every change is applied.
    pub fn is_done(&self) -> bool {
        self.steps.is_empty() && self.max_event_id.is_none()
    }
}

enum Step {
    /// Changes to some of the items in a folder, found by its path.
    Folder { path: PathBuf, changes: Vec<Change> },
    /// Brings the children of an indexed item in line with a walk of it.
    Merge {
        item: NodeIdentity,
        children: Vec<Node>,
    },
    /// Adds the walked children of an item that has none of them yet.
    Fill {
        item: NodeIdentity,
        children: std::vec::IntoIter<Node>,
    },
    /// Removes an item and everything under it, deepest first.
    Remove { item: NodeIdentity },
}

/// What a walk found under one name in a folder.
enum Update {
    /// The item is gone, or now ignored.
    Gone(Box<str>),
    Walked(Node),
}

impl Update {
    fn name(&self) -> &str {
        match self {
            Update::Gone(name) => name,
            Update::Walked(node) => &node.name,
        }
    }
}

struct Change {
    update: Update,
    /// The walk found the item under another spelling of the requested name.
    respelled: bool,
}

impl ScannedEvents {
    /// Groups what was read by folder, for `SearchCache::apply_changes`.
    pub fn into_changes(self) -> PendingChanges {
        let mut folders: Vec<(PathBuf, Vec<Change>)> = Vec::new();
        let mut positions: HashMap<PathBuf, usize> = HashMap::new();
        for scanned in self.paths {
            let (path, update, respelled) = match scanned.outcome {
                ScanOutcome::Missing => (scanned.requested, None, false),
                ScanOutcome::Ignored(path) => (path, None, false),
                ScanOutcome::Walked {
                    path,
                    respelled,
                    node,
                } => (path, Some(node), respelled),
            };
            // A change to the root itself always needs a full rescan instead.
            let (Some(folder), Some(name)) = (path.parent(), path.file_name()) else {
                continue;
            };
            let update = update.map_or_else(
                || Update::Gone(name.to_string_lossy().into()),
                Update::Walked,
            );
            let position = *positions.entry(folder.to_path_buf()).or_insert_with(|| {
                folders.push((folder.to_path_buf(), Vec::new()));
                folders.len() - 1
            });
            folders[position].1.push(Change { update, respelled });
        }
        PendingChanges {
            steps: folders
                .into_iter()
                .rev()
                .map(|(path, changes)| Step::Folder { path, changes })
                .collect(),
            max_event_id: self.max_event_id,
        }
    }
}

fn walked_metadata(metadata: Option<NodeMetadata>) -> SlabNodeMetadataCompact {
    // Walks of changed paths read metadata; an item it could not be read for is
    // indexed as unaccessible.
    metadata.map_or_else(
        SlabNodeMetadataCompact::unaccessible,
        SlabNodeMetadataCompact::some,
    )
}

/// Puts walked items in name order. Walks list them that way already.
fn by_name(mut nodes: Vec<Node>) -> Vec<Node> {
    if !nodes.is_sorted_by(|a, b| a.name <= b.name) {
        nodes.sort_by(|a, b| a.name.cmp(&b.name));
    }
    nodes
}

/// Puts each folder's children in name order where an index saved before 0.1.75
/// left items added by live updates at the end.
pub(crate) fn sort_children(slab: &mut ThinSlab<SlabNode>) {
    let ids: Vec<SlabIndex> = slab.iter().map(|(index, _)| index).collect();
    let unsorted: Vec<SlabIndex> = ids
        .into_par_iter()
        .filter(|&index| {
            !slab[index]
                .children
                .is_sorted_by_key(|&child| slab[child].name())
        })
        .collect();
    for index in unsorted {
        let mut children = std::mem::take(&mut slab[index].children);
        children.sort_by_key(|&child| slab[child].name());
        slab[index].children = children;
    }
}

impl SearchCache {
    /// Applies pending changes until `deadline`, running at least one step, or all
    /// of them without a deadline. Returns whether items were added or removed.
    pub fn apply_changes(
        &mut self,
        changes: &mut PendingChanges,
        deadline: Option<Instant>,
    ) -> bool {
        let mut changed = false;
        while let Some(step) = changes.steps.pop() {
            changed |= match step {
                Step::Folder {
                    path,
                    changes: list,
                } => self.apply_folder(path, list, &mut changes.steps),
                Step::Merge { item, children } => self.current(item).is_some_and(|index| {
                    let children = by_name(children).into_iter().map(Update::Walked);
                    self.update_children(index, children, true, &HashSet::new(), &mut changes.steps)
                }),
                Step::Fill { item, children } => self.fill(item, children, &mut changes.steps),
                Step::Remove { item } => self.remove_some(item, &mut changes.steps),
            };
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                break;
            }
        }
        if changes.steps.is_empty()
            && let Some(event_id) = changes.max_event_id.take()
        {
            self.update_last_event_id(event_id);
        }
        changed
    }

    /// The node `item` was taken from, if it still exists: the app may have removed
    /// it between steps.
    fn current(&self, item: NodeIdentity) -> Option<SlabIndex> {
        self.is_current(item).then_some(item.index())
    }

    fn identity(&self, index: SlabIndex) -> NodeIdentity {
        self.node_identity(index).expect("node exists")
    }

    fn apply_folder(
        &mut self,
        path: PathBuf,
        mut changes: Vec<Change>,
        steps: &mut Vec<Step>,
    ) -> bool {
        let folder = if changes
            .iter()
            .any(|change| matches!(change.update, Update::Walked(_)))
        {
            self.create_node_chain(&path)
        } else {
            // Nothing to remove from a folder that is not indexed.
            let Some(folder) = self.find_exact_path(&path) else {
                return false;
            };
            folder
        };
        // The last change to a name wins. `mv Foo foo` reports both names, which
        // both resolve to `foo`; only the old one's walk knows it was respelled.
        changes.sort_by(|a, b| a.update.name().cmp(b.update.name()));
        changes.dedup_by(|later, earlier| {
            let same = later.update.name() == earlier.update.name();
            if same {
                let respelled = later.respelled || earlier.respelled;
                std::mem::swap(later, earlier);
                earlier.respelled = respelled;
            }
            same
        });
        // On case-insensitive volumes, `mv Foo foo` reports both names, and both
        // resolve to the new spelling: drop indexed spellings that no longer exist.
        let mut stale = HashSet::new();
        for change in changes.iter().filter(|change| change.respelled) {
            let name = change.update.name();
            for &child in &self.file_nodes[folder].children {
                let child_name = self.file_nodes[child].name();
                if child_name != name
                    && same_name_ignoring_case(OsStr::new(child_name), OsStr::new(name))
                    && on_disk_name(&path.join(child_name)).as_deref()
                        != Some(OsStr::new(child_name))
                {
                    stale.insert(child);
                }
            }
        }
        let updates = changes.into_iter().map(|change| change.update);
        self.update_children(folder, updates, false, &stale, steps)
    }

    /// Merges `updates`, in name order with one per name, into `folder`'s children.
    /// With `complete`, they list every child, and children they omit are removed;
    /// otherwise those are kept, except `stale` ones. Returns whether items were
    /// added or removed; changes below the children are left to further steps.
    fn update_children(
        &mut self,
        folder: SlabIndex,
        updates: impl Iterator<Item = Update>,
        complete: bool,
        stale: &HashSet<SlabIndex>,
        steps: &mut Vec<Step>,
    ) -> bool {
        let children = std::mem::take(&mut self.file_nodes[folder].children);
        let mut kept = ThinVec::with_capacity(children.len());
        // Removed children without children of their own, removed together.
        let mut leaves = Vec::new();
        let mut changed = false;
        let mut children = children.into_iter().peekable();
        let mut updates = updates.peekable();
        loop {
            let child = children
                .peek()
                .map(|&child| (child, self.file_nodes[child].name()));
            let order = match (child, updates.peek()) {
                (None, None) => break,
                (Some(_), None) => Ordering::Less,
                (None, Some(_)) => Ordering::Greater,
                (Some((_, name)), Some(update)) => name.cmp(update.name()),
            };
            match (order, child) {
                (Ordering::Less, Some((child, _))) => {
                    children.next();
                    if complete || stale.contains(&child) {
                        self.drop_child(child, &mut kept, &mut leaves, steps);
                        changed = true;
                    } else {
                        kept.push(child);
                    }
                }
                (Ordering::Equal, Some((child, name))) => {
                    children.next();
                    match updates.next() {
                        Some(Update::Walked(node)) => {
                            kept.push(child);
                            changed |= self.merge_walked(child, node, steps);
                        }
                        _ => {
                            self.drop_child(child, &mut kept, &mut leaves, steps);
                            changed = true;
                        }
                    }
                    // Indexes from older versions can list a name twice.
                    while let Some(&twin) = children.peek()
                        && self.file_nodes[twin].name() == name
                    {
                        children.next();
                        self.drop_child(twin, &mut kept, &mut leaves, steps);
                        changed = true;
                    }
                }
                _ => {
                    // No indexed child has the updated name.
                    if let Some(Update::Walked(node)) = updates.next() {
                        kept.push(self.add_walked(folder, node, steps));
                        changed = true;
                    }
                }
            }
        }
        self.file_nodes[folder].children = kept;
        self.remove_nodes(leaves);
        changed
    }

    /// Removes a child: a leaf at once with the others, and a folder by later steps,
    /// which keep it listed until everything under it is removed.
    fn drop_child(
        &mut self,
        child: SlabIndex,
        kept: &mut ThinVec<SlabIndex>,
        leaves: &mut Vec<SlabIndex>,
        steps: &mut Vec<Step>,
    ) {
        if self.file_nodes[child].children.is_empty() {
            leaves.push(child);
        } else {
            kept.push(child);
            steps.push(Step::Remove {
                item: self.identity(child),
            });
        }
    }

    /// Adds a walked item under `parent`, leaving its children to a later step.
    /// The caller lists it among `parent`'s children.
    fn add_walked(&mut self, parent: SlabIndex, node: Node, steps: &mut Vec<Step>) -> SlabIndex {
        let Node {
            children,
            name,
            metadata,
        } = node;
        let index = self.push_node(Some(parent), name, walked_metadata(metadata));
        if !children.is_empty() {
            steps.push(Step::Fill {
                item: self.identity(index),
                children: by_name(children).into_iter(),
            });
        }
        index
    }

    /// Stores a walked item's metadata in its indexed node, leaving its children to
    /// a later step. Returns whether the item changed type, as when a file is
    /// replaced by a folder of the same name, which file and folder filters see.
    fn merge_walked(&mut self, index: SlabIndex, node: Node, steps: &mut Vec<Step>) -> bool {
        let Node {
            children, metadata, ..
        } = node;
        let metadata = walked_metadata(metadata);
        let indexed = &mut self.file_nodes[index];
        let type_changed = indexed.file_type_hint() != metadata.file_type_hint();
        // Items indexed without metadata have no known type to change.
        let replaced = type_changed && indexed.metadata.is_some() && metadata.is_some();
        if indexed.metadata != metadata {
            indexed.metadata = metadata;
            self.sort_indexes.metadata_changed(index, type_changed);
            self.metadata_changed = true;
        }
        if !children.is_empty() || !indexed.children.is_empty() {
            steps.push(Step::Merge {
                item: self.identity(index),
                children,
            });
        }
        replaced
    }

    fn fill(
        &mut self,
        item: NodeIdentity,
        mut children: std::vec::IntoIter<Node>,
        steps: &mut Vec<Step>,
    ) -> bool {
        let Some(index) = self.current(item) else {
            return false;
        };
        for node in children.by_ref().take(STEP_ITEMS) {
            let child = self.add_walked(index, node, steps);
            self.insert_child(index, child);
        }
        if children.len() > 0 {
            steps.push(Step::Fill { item, children });
        }
        true
    }

    /// Removes up to `STEP_ITEMS` items under `item`, deepest first, and `item`
    /// itself once nothing is left under it.
    fn remove_some(&mut self, item: NodeIdentity, steps: &mut Vec<Step>) -> bool {
        let Some(top) = self.current(item) else {
            return false;
        };
        let mut removed = Vec::new();
        let mut node = top;
        while removed.len() < STEP_ITEMS {
            while let Some(&last) = self.file_nodes[node].children.last() {
                node = last;
            }
            if node == top {
                break;
            }
            let parent = self.file_nodes[node]
                .parent()
                .expect("a child has a parent");
            self.file_nodes[parent].children.pop();
            removed.push(node);
            node = parent;
        }
        if self.file_nodes[top].children.is_empty() {
            if let Some(parent) = self.file_nodes[top].parent() {
                self.detach_child(parent, top);
            }
            removed.push(top);
        } else {
            steps.push(Step::Remove { item });
        }
        self.remove_nodes(removed);
        true
    }

    /// The child of `folder` with exactly `name`.
    pub(crate) fn child_named(&self, folder: SlabIndex, name: &str) -> Option<SlabIndex> {
        let children = &self.file_nodes[folder].children;
        let position = children.partition_point(|&child| self.file_nodes[child].name() < name);
        children
            .get(position)
            .copied()
            .filter(|&child| self.file_nodes[child].name() == name)
    }

    /// Lists `child` among `folder`'s children, in name order.
    pub(crate) fn insert_child(&mut self, folder: SlabIndex, child: SlabIndex) {
        let name = self.file_nodes[child].name();
        let children = &self.file_nodes[folder].children;
        let position = if children
            .last()
            .is_none_or(|&last| self.file_nodes[last].name() <= name)
        {
            children.len()
        } else {
            children.partition_point(|&other| self.file_nodes[other].name() <= name)
        };
        self.file_nodes[folder].children.insert(position, child);
    }

    /// Stops listing `child` among `folder`'s children.
    pub(crate) fn detach_child(&mut self, folder: SlabIndex, child: SlabIndex) {
        let name = self.file_nodes[child].name();
        let children = &self.file_nodes[folder].children;
        let start = children.partition_point(|&other| self.file_nodes[other].name() < name);
        let position = children[start..]
            .iter()
            .take_while(|&&other| self.file_nodes[other].name() == name)
            .position(|&other| other == child)
            .map(|offset| start + offset);
        if let Some(position) = position {
            self.file_nodes[folder].children.remove(position);
        }
    }

    /// Removes nodes that no folder lists any more, though each still has its
    /// parent, from the slab and the name index.
    pub(crate) fn remove_nodes(&mut self, removed: Vec<SlabIndex>) {
        if removed.is_empty() {
            return;
        }
        // Postings are located by path, so update them while the nodes still exist,
        // once per name rather than once per removed file.
        let mut by_name: HashMap<&'static str, Vec<SlabIndex>> = HashMap::new();
        for &id in &removed {
            by_name
                .entry(self.file_nodes[id].name())
                .or_default()
                .push(id);
        }
        // In name order, each lookup walks near the previous one.
        let mut by_name: Vec<_> = by_name.into_iter().collect();
        by_name.sort_unstable_by_key(|&(name, _)| name);
        let mut unused = Vec::new();
        for (name, ids) in &by_name {
            let (count, emptied) = self.name_index.remove_indices(name, ids, &self.file_nodes);
            assert_eq!(count, ids.len(), "inconsistent name index and node");
            if emptied {
                unused.push(*name);
            }
        }
        for id in removed {
            self.file_nodes.try_remove(id);
            self.sort_indexes.changed(id);
            // A later node in this slot must not match identities of this one.
            let slot = id.get();
            if slot >= self.slot_generations.len() {
                self.slot_generations.resize(slot + 1, 0);
            }
            self.slot_generations[slot] = self.slot_generations[slot].wrapping_add(1);
        }
        // Free the names no node has any more only now that the removed nodes are
        // gone: finding their postings by path read the names of their folders.
        for name in unused {
            self.name_index.remove_unused(name);
        }
    }
}
