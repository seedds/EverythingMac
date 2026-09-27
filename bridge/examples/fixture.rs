//! Disposable fixture for the native window's --self-check mode.
use search_cache::SearchCache;
use std::{fs, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = PathBuf::from(std::env::args().nth(1).expect("fixture output directory"));
    fs::create_dir_all(&root)?;
    if fs::read_dir(&root)?.next().is_some() {
        return Err("fixture directory must be empty".into());
    }
    fs::create_dir(root.join("docs"))?;
    fs::write(root.join("docs/Alpha.txt"), b"A")?;
    fs::write(root.join("docs/alpha.md"), b"B")?;
    fs::write(root.join("docs/résumé.txt"), b"unicode")?;
    fs::write(root.join("missing.txt"), b"removed after snapshot")?;
    SearchCache::walk_fs(&root).flush_to_file(&root.join("snapshot.db"))?;
    fs::remove_file(root.join("missing.txt"))?;
    println!("{}", root.join("snapshot.db").display());
    Ok(())
}
