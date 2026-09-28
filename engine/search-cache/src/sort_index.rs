//! Reusable, in-memory orders over slab IDs. No metadata reads or result paths are
//! needed at query time. Mutations are tracked here, including recycled slab IDs.
use crate::{FileNodes, SearchCache, SlabIndex, SlabNode};
use fswalk::NodeFileType;
use hashbrown::HashSet;
use search_cancel::CancellationToken;
use std::cmp::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(usize)]
pub enum SortColumn {
    Filename,
    FullPath,
    Size,
    Mtime,
    Ctime,
}
const COLUMNS: [SortColumn; 5] = [
    SortColumn::Filename,
    SortColumn::FullPath,
    SortColumn::Size,
    SortColumn::Mtime,
    SortColumn::Ctime,
];

#[derive(Default)]
pub(crate) struct SortIndexes {
    orders: [Option<Order>; 5],
}
struct Order {
    ids: Vec<SlabIndex>,
    ranks: Vec<u32>,
    dirty: HashSet<SlabIndex>,
    rebuild: bool,
}
impl Order {
    fn new(ids: Vec<SlabIndex>) -> Self {
        let mut this = Self {
            ids,
            ranks: vec![],
            dirty: HashSet::new(),
            rebuild: false,
        };
        this.rank();
        this
    }
    fn rank(&mut self) {
        let size = self.ids.iter().map(|id| id.get() + 1).max().unwrap_or(0);
        self.ranks.resize(size, u32::MAX);
        self.ranks.fill(u32::MAX);
        for (rank, id) in self.ids.iter().enumerate() {
            self.ranks[id.get()] = rank as u32;
        }
    }
}
impl SortIndexes {
    pub(crate) fn changed(&mut self, id: SlabIndex, structural: bool) {
        for (column, order) in COLUMNS.into_iter().zip(&mut self.orders) {
            if !structural && column == SortColumn::FullPath {
                continue;
            }
            if let Some(order) = order
                && !order.rebuild
            {
                order.dirty.insert(id);
                // A rescan/backfill must not accumulate millions of hash entries.
                if order.dirty.len() > 8192 {
                    order.dirty.clear();
                    order.rebuild = true;
                }
            }
        }
    }
}

impl SearchCache {
    /// Prepare once while opening/scanning, before the engine becomes ready.
    /// Orders are derived data; the existing snapshot format remains compatible.
    pub fn prepare_sort_indexes(&mut self) {
        for column in COLUMNS {
            self.ensure_sort_index(column);
        }
    }

    /// Sort unique, live IDs returned by this cache's search. Small result sets use
    /// integer ranks; broad searches filter a preordered ID array with a bitset.
    /// Cancellation leaves the engine's published results untouched.
    pub fn sort_results(
        &mut self,
        results: &mut Vec<SlabIndex>,
        column: SortColumn,
        descending: bool,
        token: CancellationToken,
    ) -> Option<()> {
        token.is_cancelled()?;
        self.ensure_sort_index(column);
        token.is_cancelled()?;
        let order = self.sort_indexes.orders[column as usize].as_ref().unwrap();
        if results.len() == order.ids.len() {
            results.clone_from(&order.ids);
        } else if results.len().saturating_mul(32) < order.ids.len() {
            results.sort_unstable_by_key(|id| order.ranks[id.get()]);
        } else {
            let mut included = vec![0u64; order.ranks.len().div_ceil(64)];
            for (i, id) in results.iter().enumerate() {
                token.is_cancelled_sparse(i)?;
                included[id.get() / 64] |= 1 << (id.get() % 64);
            }
            results.clear();
            for (i, id) in order.ids.iter().enumerate() {
                token.is_cancelled_sparse(i)?;
                if included[id.get() / 64] & (1 << (id.get() % 64)) != 0 {
                    results.push(*id);
                }
            }
        }
        if descending {
            results.reverse();
        }
        token.is_cancelled()
    }

    fn ensure_sort_index(&mut self, column: SortColumn) {
        if let Some(mut order) = self.sort_indexes.orders[column as usize].take()
            && !order.rebuild
        {
            if !order.dirty.is_empty() {
                // Unchanged entries retain their relative order. Remove obsolete
                // versions (including deleted/reused IDs), then merge only changes.
                let mut removed: Vec<_> = order
                    .dirty
                    .iter()
                    .filter_map(|id| order.ranks.get(id.get()).copied())
                    .filter(|rank| *rank != u32::MAX)
                    .collect();
                removed.sort_unstable();
                let mut removed = removed.into_iter().peekable();
                let mut position = 0u32;
                order.ids.retain(|_| {
                    let keep = removed.peek() != Some(&position);
                    if !keep {
                        removed.next();
                    }
                    position += 1;
                    keep
                });
                let mut changed: Vec<_> = order
                    .dirty
                    .drain()
                    .filter(|id| self.file_nodes.get(*id).is_some())
                    .collect();
                changed.sort_unstable_by(|a, b| compare(&self.file_nodes, *a, *b, column));
                let mut merged = Vec::with_capacity(order.ids.len() + changed.len());
                let mut start = 0;
                // Locate changed entries with binary searches, then copy intact
                // spans. Comparing paths against every unchanged file would
                // turn a single filesystem event back into millions of allocations.
                for id in changed {
                    let end = start
                        + order.ids[start..].partition_point(|old| {
                            compare(&self.file_nodes, *old, id, column).is_lt()
                        });
                    merged.extend_from_slice(&order.ids[start..end]);
                    merged.push(id);
                    start = end;
                }
                merged.extend_from_slice(&order.ids[start..]);
                order.ids = merged;
                order.rank();
            }
            self.sort_indexes.orders[column as usize] = Some(order);
            return;
        }
        let ids = match column {
            SortColumn::FullPath => path_order(&self.file_nodes),
            SortColumn::Filename => {
                self.ensure_sort_index(SortColumn::FullPath);
                let paths = &self.sort_indexes.orders[SortColumn::FullPath as usize]
                    .as_ref()
                    .unwrap()
                    .ranks;
                let mut ids = Vec::with_capacity(self.file_nodes.len());
                for group in self.name_index.groups() {
                    let start = ids.len();
                    ids.extend(group.iter().copied());
                    ids[start..].sort_unstable_by_key(|id| {
                        (type_order(&self.file_nodes[*id]), paths[id.get()])
                    });
                }
                // The root's display name is '/', regardless of its internal name.
                if let Some(pos) = ids.iter().position(|id| *id == self.file_nodes.root()) {
                    let root = ids.remove(pos);
                    let pos = ids.partition_point(|id| self.file_nodes[*id].name() < "/");
                    ids.insert(pos, root);
                }
                ids
            }
            _ => {
                self.ensure_sort_index(SortColumn::Filename);
                let names = self.sort_indexes.orders[SortColumn::Filename as usize]
                    .as_ref()
                    .unwrap();
                let mut keys: Vec<_> = names
                    .ids
                    .iter()
                    .enumerate()
                    .map(|(rank, id)| (numeric(&self.file_nodes[*id], column), rank as u32, *id))
                    .collect();
                keys.sort_unstable_by_key(|&(value, rank, _)| (value, rank));
                keys.into_iter().map(|(_, _, id)| id).collect()
            }
        };
        self.sort_indexes.orders[column as usize] = Some(Order::new(ids));
    }
}

fn name(node: &SlabNode) -> &str {
    if node.parent().is_none() {
        "/"
    } else {
        node.name()
    }
}
fn type_order(node: &SlabNode) -> u8 {
    match node.metadata.as_ref().map(|m| m.r#type()) {
        Some(NodeFileType::Dir) => 0,
        None => 2,
        _ => 1,
    }
}
fn numeric(node: &SlabNode, column: SortColumn) -> i64 {
    if matches!(column, SortColumn::Filename | SortColumn::FullPath) {
        return 0;
    }
    let Some(meta) = node.metadata.as_ref() else {
        return i64::MIN;
    };
    match column {
        SortColumn::Size => meta.size(),
        SortColumn::Mtime => meta.mtime().map(|v| i64::from(v.get())).unwrap_or(i64::MIN),
        SortColumn::Ctime => meta.ctime().map(|v| i64::from(v.get())).unwrap_or(i64::MIN),
        _ => 0,
    }
}
fn compare(nodes: &FileNodes, a: SlabIndex, b: SlabIndex, column: SortColumn) -> Ordering {
    let path = || {
        nodes
            .node_path(a)
            .unwrap()
            .as_os_str()
            .as_encoded_bytes()
            .cmp(nodes.node_path(b).unwrap().as_os_str().as_encoded_bytes())
    };
    if column == SortColumn::FullPath {
        return path();
    }
    numeric(&nodes[a], column)
        .cmp(&numeric(&nodes[b], column))
        .then_with(|| name(&nodes[a]).cmp(name(&nodes[b])))
        .then_with(|| type_order(&nodes[a]).cmp(&type_order(&nodes[b])))
        .then_with(path)
}

/// Lexical traversal without allocating a full path per file. A directory's
/// endpoint and its children prefix are separate events: '/a.txt' precedes
/// '/a/x', even though '/a' itself precedes both. Ordinary tree DFS is incorrect.
fn path_order(nodes: &FileNodes) -> Vec<SlabIndex> {
    if nodes.is_empty() {
        return vec![];
    }
    let mut ids = Vec::with_capacity(nodes.len());
    ids.push(nodes.root());
    let mut stack = vec![(nodes.root(), true)];
    while let Some((id, descend)) = stack.pop() {
        if !descend {
            ids.push(id);
            continue;
        }
        let start = stack.len();
        for child in &nodes[id].children {
            stack.push((*child, false));
            if !nodes[*child].children.is_empty() {
                stack.push((*child, true));
            }
        }
        stack[start..].sort_unstable_by(|(a, ad), (b, bd)| {
            let bytes = |id: SlabIndex, descend: bool| {
                nodes[id].name().bytes().chain(descend.then_some(b'/'))
            };
            bytes(*b, *bd).cmp(bytes(*a, *ad))
        });
    }
    ids
}
