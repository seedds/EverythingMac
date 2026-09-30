//! The mount table, read without waiting on unresponsive file systems.
use fswalk::OtherVolumes;
use std::{
    ffi::{CStr, OsStr},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};

/// Volumes mounted below `root` other than the startup disk; see `OtherVolumes`.
pub fn other_volumes(root: &Path, include_paths: &[PathBuf]) -> OtherVolumes {
    OtherVolumes::new(root, include_paths, other_mounts())
}

/// Mount points of every volume except the startup disk's system and data volumes.
fn other_mounts() -> Vec<PathBuf> {
    // Firmlinks such as /Users lead into the data volume, whose device "/" reports.
    let data = std::fs::metadata("/").map(|m| m.dev() as i32).ok();
    let count = unsafe { libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT) };
    let Ok(count) = usize::try_from(count) else {
        return Vec::new();
    };
    // Leave room for volumes mounted between the two calls.
    let mut table: Vec<libc::statfs> = Vec::with_capacity(count + 8);
    let bytes = table.capacity() * size_of::<libc::statfs>();
    let count = unsafe {
        libc::getfsstat(
            table.as_mut_ptr(),
            bytes.try_into().unwrap_or(libc::c_int::MAX),
            libc::MNT_NOWAIT,
        )
    };
    let Ok(count) = usize::try_from(count) else {
        return Vec::new();
    };
    unsafe { table.set_len(count.min(table.capacity())) };
    let mut mounts = Vec::new();
    for volume in &table {
        let [device, _]: [i32; 2] = unsafe { std::mem::transmute(volume.f_fsid) };
        if volume.f_flags & libc::MNT_ROOTFS as u32 != 0 || Some(device) == data {
            continue;
        }
        let name = unsafe { CStr::from_ptr(volume.f_mntonname.as_ptr()) };
        let path = PathBuf::from(OsStr::from_bytes(name.to_bytes()));
        // A mount inside the data volume can also be reached through a firmlink.
        if let Ok(rest) = path.strip_prefix("/System/Volumes/Data")
            && !rest.as_os_str().is_empty()
        {
            mounts.push(Path::new("/").join(rest));
        }
        mounts.push(path);
    }
    mounts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_disk_is_not_another_volume() {
        let mounts = other_mounts();
        assert!(!mounts.iter().any(|m| m == Path::new("/")));
        assert!(
            !mounts
                .iter()
                .any(|m| m == Path::new("/System/Volumes/Data"))
        );
        // `/dev` is its own file system on every Mac.
        assert!(mounts.iter().any(|m| m == Path::new("/dev")));
        assert!(
            other_volumes(Path::new("/"), &[])
                .skipped()
                .any(|m| m == Path::new("/dev"))
        );
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap();
        assert!(
            !other_volumes(Path::new("/"), &[])
                .skipped()
                .any(|m| home.starts_with(m))
        );
    }
}
