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

fn walked_paths(node: &fswalk::Node, path: &Path, into: &mut Vec<std::path::PathBuf>) {
    for child in &node.children {
        let child_path = path.join(&*child.name);
        into.push(child_path.clone());
        walked_paths(child, &child_path, into);
    }
}

fn listed_paths(path: &Path, rules: &Exclusions, into: &mut Vec<std::path::PathBuf>) {
    for entry in fs::read_dir(path).unwrap() {
        let entry = entry.unwrap();
        let is_dir = entry.file_type().unwrap().is_dir();
        let path = entry.path();
        // The full check of every parent, as for events.
        if rules.is_excluded(&path, is_dir) {
            continue;
        }
        into.push(path.clone());
        if is_dir {
            listed_paths(&path, rules, into);
        }
    }
}

#[test]
fn walks_check_each_entry_like_the_full_parent_check() {
    let temp = tempdir::TempDir::new("exclusions_entries").unwrap();
    let root = temp.path().canonicalize().unwrap();
    for dir in [
        "proj/src/deep/build/out",
        "proj/cache/inner",
        "proj/node_modules/pkg/lib",
        "proj/a/b/deep",
        "top/nested/src",
        "other/src/cache",
        "other/build",
    ] {
        fs::create_dir_all(root.join(dir)).unwrap();
    }
    for file in [
        "proj/src/main.rs",
        "proj/src/a.tmp",
        "proj/src/deep/b.tmp",
        "proj/src/deep/build/out/x.o",
        "proj/cache/inner/c.txt",
        "proj/cache.txt",
        "proj/node_modules/pkg/lib/index.js",
        "proj/a/b/deep/d.txt",
        "proj/error.log",
        "top/nested/src/e.tmp",
        "other/src/cache/f.txt",
        "other/cache",
        "other/build/g.txt",
    ] {
        fs::write(root.join(file), "x").unwrap();
    }
    let rules = Exclusions::compile(
        &root,
        &[
            "*.log".into(),
            "cache/".into(),
            "src/*.tmp".into(),
            "**/build/**".into(),
            "a/**/deep".into(),
            "node_modules".into(),
            "top/**".into(),
        ],
    )
    .unwrap();
    for start in [root.clone(), root.join("proj"), root.join("other/src")] {
        assert!(!rules.is_excluded(&start, true));
        let walk = WalkData::new(&start, &[], &[], false, || false).with_exclusions(rules.clone());
        let tree = fswalk::walk_it_without_root_chain(&walk).unwrap();
        let mut walked = Vec::new();
        walked_paths(&tree, &start, &mut walked);
        let mut listed = Vec::new();
        listed_paths(&start, &rules, &mut listed);
        walked.sort();
        listed.sort();
        assert_eq!(walked, listed, "walk from {start:?}");
    }
}
