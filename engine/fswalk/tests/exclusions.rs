use fswalk::{Exclusions, WalkData, walk_it};
use std::{fs, path::Path};

#[test]
fn patterns_prune_nested_trees_even_inside_included_paths() {
    let temp = tempdir::TempDir::new("exclusions").unwrap();
    let root = temp.path();
    for name in [
        "project/node_modules/deep",
        "project/build/deep",
        "project/keep",
        "project/cache.log",
    ] {
        fs::create_dir_all(root.join(name)).unwrap();
        fs::write(root.join(name).join("file.txt"), "x").unwrap();
    }
    fs::write(root.join("project/error.log"), "x").unwrap();
    fs::write(root.join("project/KEEP.LOG"), "x").unwrap();
    let rules = Exclusions::compile(
        root,
        &["node_modules".into(), "*.log".into(), "**/build/**".into()],
    )
    .unwrap();
    let ignored = vec![root.to_path_buf()];
    let included = vec![root.join("project")];
    let walk =
        WalkData::new(root, &ignored, &included, false, || false).with_exclusions(rules.clone());
    let tree = walk_it(&walk).unwrap();
    let text = format!("{tree:?}");
    assert!(!text.contains("node_modules"));
    assert!(!text.contains("error.log"));
    assert!(!text.contains("build"));
    assert!(text.contains("KEEP.LOG"));
    assert!(text.contains("keep"));
    assert!(rules.is_excluded(&root.join("project/node_modules/deep/new.txt"), false));
    assert!(!rules.is_excluded(&root.join("project/node_modules-other"), true));
}

#[test]
fn rules_are_root_relative_and_directory_rules_respect_file_kind() {
    let anchored = Exclusions::compile(Path::new("/root"), &["build/**".into()]).unwrap();
    assert!(anchored.is_excluded(Path::new("/root/build"), true));
    assert!(!anchored.is_excluded(Path::new("/root/project/build"), true));
    let rules =
        Exclusions::compile(Path::new("/root"), &["cache/".into(), "src/*.tmp".into()]).unwrap();
    assert!(rules.is_excluded(Path::new("/root/a/cache/file"), false));
    assert!(!rules.is_excluded(Path::new("/root/cache"), false));
    assert!(rules.is_excluded(Path::new("/root/src/a.tmp"), false));
    assert!(!rules.is_excluded(Path::new("/root/other/src/a.tmp"), false));
    assert!(!rules.is_excluded(Path::new("/elsewhere/cache"), true));
    assert!(
        Exclusions::compile(Path::new("/root"), &["ok".into(), "[".into()])
            .unwrap_err()
            .contains("line 2")
    );
}
