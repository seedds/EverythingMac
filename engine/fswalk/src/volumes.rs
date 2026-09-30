//! Mount points of volumes other than the startup disk, which walks skip unless an
//! include path selects them.
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
};

/// Volumes mounted below a walk's root other than the startup disk: external and
/// network drives, disk images, Simulator runtimes, and system volumes such as
/// Preboot. Including a volume's mount point, or a folder above it, indexes the
/// whole volume; including a folder on it indexes only that folder.
#[derive(Clone, Debug, Default)]
pub struct OtherVolumes {
    /// Mount points skipped together with everything below them.
    skipped: HashSet<PathBuf>,
    /// Mount points above an include path, ignored except for that path.
    partial: Vec<PathBuf>,
}

impl OtherVolumes {
    /// Sorts the mount points of other volumes for a walk of `root`.
    pub fn new(
        root: &Path,
        include_paths: &[PathBuf],
        mounts: impl IntoIterator<Item = PathBuf>,
    ) -> Self {
        let mut volumes = Self::default();
        for mount in mounts {
            if mount == root
                || !mount.starts_with(root)
                || include_paths
                    .iter()
                    .any(|include| mount.starts_with(include))
            {
                continue;
            }
            if include_paths
                .iter()
                .any(|include| include.starts_with(&mount))
            {
                volumes.partial.push(mount);
            } else {
                volumes.skipped.insert(mount);
            }
        }
        volumes
    }

    pub fn is_empty(&self) -> bool {
        self.skipped.is_empty() && self.partial.is_empty()
    }

    /// Mount points skipped together with everything below them.
    pub fn skipped(&self) -> impl Iterator<Item = &Path> {
        self.skipped.iter().map(PathBuf::as_path)
    }

    /// Whether a walk skips the directory `path` and everything below it.
    pub(crate) fn skips(&self, path: &Path) -> bool {
        !self.skipped.is_empty() && self.skipped.contains(path)
    }

    /// Whether `path` is on a skipped volume.
    pub(crate) fn covers(&self, path: &Path) -> bool {
        self.skipped.iter().any(|mount| path.starts_with(mount))
    }

    pub(crate) fn partial(&self) -> &[PathBuf] {
        &self.partial
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(paths: &[&str]) -> Vec<PathBuf> {
        paths.iter().map(PathBuf::from).collect()
    }

    #[test]
    fn mounts_are_skipped_unless_an_include_path_selects_them() {
        let volumes = OtherVolumes::new(
            Path::new("/"),
            &paths(&["/Volumes/Photos", "/Volumes/Backup/Documents", "/mnt"]),
            paths(&[
                "/Volumes/USB",
                "/Volumes/Photos",
                "/Volumes/Backup",
                "/mnt/share",
                "/",
            ]),
        );
        assert!(volumes.skips(Path::new("/Volumes/USB")));
        assert!(volumes.covers(Path::new("/Volumes/USB/a/b.txt")));
        // Included volumes, and volumes inside included folders, are walked.
        assert!(!volumes.covers(Path::new("/Volumes/Photos/a.jpg")));
        assert!(!volumes.covers(Path::new("/mnt/share/a.txt")));
        // A folder on a volume keeps its volume's other contents out.
        assert_eq!(volumes.partial(), paths(&["/Volumes/Backup"]));
        assert!(!volumes.skips(Path::new("/Volumes/Backup")));
        assert!(!volumes.covers(Path::new("/")));
    }

    #[test]
    fn only_mounts_below_the_root_matter() {
        let volumes = OtherVolumes::new(
            Path::new("/Volumes/USB"),
            &[],
            paths(&["/Volumes/USB", "/Volumes/Other", "/Volumes/USB/Nested"]),
        );
        assert_eq!(
            volumes.skipped().collect::<Vec<_>>(),
            [Path::new("/Volumes/USB/Nested")]
        );
        assert!(!volumes.is_empty());
        assert!(OtherVolumes::new(Path::new("/Users"), &[], paths(&["/Volumes/USB"])).is_empty());
    }
}
