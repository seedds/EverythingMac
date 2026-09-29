use globset::{GlobBuilder, GlobMatcher};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Clone, Debug, Default)]
pub struct Exclusions {
    root: PathBuf,
    raw: Arc<[String]>,
    rules: Arc<[Rule]>,
}

#[derive(Debug)]
struct Rule {
    matcher: GlobMatcher,
    basename: bool,
    directory: bool,
}

impl Exclusions {
    pub fn compile(root: &Path, patterns: &[String]) -> Result<Self, String> {
        let mut rules = Vec::new();
        for (line, raw) in patterns.iter().enumerate() {
            let pattern = raw.trim();
            if pattern.is_empty() {
                continue;
            }
            if pattern.starts_with('/')
                || pattern.starts_with('~')
                || pattern.split('/').any(|p| p == "..")
            {
                return Err(format!(
                    "Exclude patterns line {}: use a name or a pattern relative to the monitor root",
                    line + 1
                ));
            }
            let directory = pattern.ends_with('/');
            let pattern = pattern.trim_end_matches('/');
            let basename = !pattern.contains('/');
            let mut add = |pattern: &str, directory| -> Result<(), String> {
                let glob = GlobBuilder::new(pattern)
                    .literal_separator(true)
                    .case_insensitive(false)
                    .build()
                    .map_err(|e| format!("Exclude patterns line {}: {e}", line + 1))?;
                rules.push(Rule {
                    matcher: glob.compile_matcher(),
                    basename,
                    directory,
                });
                Ok(())
            };
            add(pattern, directory)?;
            // Prune the directory itself, not just entries subsequently found inside it.
            if let Some(parent) = pattern.strip_suffix("/**") {
                add(parent, true)?;
            }
        }
        Ok(Self {
            root: root.into(),
            raw: patterns.into(),
            rules: rules.into(),
        })
    }

    pub fn patterns(&self) -> &[String] {
        &self.raw
    }

    pub fn is_excluded(&self, path: &Path, is_directory: bool) -> bool {
        if self.rules.is_empty() {
            return false;
        }
        let Ok(relative) = path.strip_prefix(&self.root) else {
            return false;
        };
        // Every parent component is a directory, including for a deleted child event.
        for (i, candidate) in relative.ancestors().enumerate() {
            if candidate.as_os_str().is_empty() {
                break;
            }
            if self.rules.iter().any(|r| {
                (!r.directory || i > 0 || is_directory)
                    && r.matcher.is_match(if r.basename {
                        Path::new(candidate.file_name().unwrap())
                    } else {
                        candidate
                    })
            }) {
                return true;
            }
        }
        false
    }
}
