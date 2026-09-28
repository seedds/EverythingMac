//! Inspect snapshot metadata coverage without reading any indexed files.
use search_cache::{SearchCache, SearchOptions, SearchQuery, read_cache_from_file};
use search_cancel::CancellationToken;
use serde_json::json;
use std::{path::Path, sync::atomic::AtomicBool};

static STOP: AtomicBool = AtomicBool::new(false);

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("Usage: metadata_inventory INDEX");
    let storage = read_cache_from_file(Path::new(&path)).expect("read snapshot");
    let mut cache = SearchCache::from_persistent_storage(storage, &STOP);
    let mut inventory = Vec::new();
    for query in ["cardinal", ".swift", ".js", ".py", "a", ""] {
        let ids = cache
            .search_query_with_options(
                SearchQuery {
                    query: (!query.is_empty()).then(|| query.into()),
                    directory_query: None,
                },
                SearchOptions {
                    case_insensitive: true,
                },
                CancellationToken::noop(),
            )
            .expect("query")
            .nodes
            .expect("completed");
        let (mut missing, mut unavailable, mut modified, mut created) = (0, 0, 0, 0);
        for batch in ids.chunks(256) {
            for node in cache.expand_cached_file_nodes(batch) {
                missing += usize::from(node.metadata.is_none());
                unavailable += usize::from(node.metadata.is_unaccessible());
                modified += usize::from(node.metadata.as_ref().and_then(|m| m.mtime()).is_some());
                created += usize::from(node.metadata.as_ref().and_then(|m| m.ctime()).is_some());
            }
        }
        inventory.push(json!({"query":query, "matches":ids.len(), "missing_metadata":missing,
            "unavailable_metadata":unavailable, "modified_known":modified, "created_known":created}));
    }
    println!("{}", serde_json::to_string_pretty(&inventory).unwrap());
}
