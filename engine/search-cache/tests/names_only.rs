//! EverythingMac searches names only: text that looks like an Everything filter
//! it does not implement, such as `content:` or `tag:`, is matched against names.

use search_cache::{SearchCache, SearchOptions};
use search_cancel::CancellationToken;
use std::fs;
use tempdir::TempDir;

fn names(cache: &mut SearchCache, query: &str) -> Vec<String> {
    let indices = cache
        .search_with_options(query, SearchOptions::default(), CancellationToken::noop())
        .expect("search should succeed")
        .nodes
        .expect("noop token should not cancel");
    cache
        .expand_file_nodes(&indices)
        .into_iter()
        .map(|node| {
            node.path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned()
        })
        .collect()
}

#[test]
fn unsupported_filters_match_names_not_contents() {
    let temp_dir = TempDir::new("names_only").unwrap();
    let dir = temp_dir.path();
    fs::write(dir.join("body.txt"), b"needle work").unwrap();
    // A colon is valid in a POSIX file name (Finder shows it as a slash).
    fs::write(dir.join("content:needle.txt"), b"").unwrap();
    fs::write(dir.join("tag:work.txt"), b"").unwrap();

    let mut cache = SearchCache::walk_fs(dir);
    assert_eq!(names(&mut cache, "content:needle"), ["content:needle.txt"]);
    assert_eq!(names(&mut cache, "tag:work"), ["tag:work.txt"]);
    assert!(names(&mut cache, "artist:someone").is_empty());
    assert!(names(&mut cache, "content:missing ext:txt").is_empty());
}
