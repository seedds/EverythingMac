//! Folders that macOS shows as a single item: apps, installer packages, and
//! document packages such as `.pages` or `.rtfd`. Finder decides by the folder's
//! extension, through the types that Launch Services knows, so this asks it too.
// UTType's C functions are deprecated in favor of the Objective-C class, which
// this crate cannot call; they still answer from the same type database.
#![allow(deprecated)]

use objc2_core_foundation::CFString;
use objc2_core_services::{
    UTTypeConformsTo, UTTypeCreatePreferredIdentifierForTag, kUTTagClassFilenameExtension,
    kUTTypeDirectory, kUTTypePackage,
};
use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex, PoisonError},
};

/// Whether macOS shows a folder named `*.{extension}` as a single item, ignoring
/// ASCII case. Answers are kept until the process exits, so a package type that
/// an app installed later declares is seen after a relaunch.
pub(crate) fn is_package_extension(extension: &str) -> bool {
    static ANSWERS: LazyLock<Mutex<HashMap<Box<str>, bool>>> = LazyLock::new(Default::default);
    if extension.is_empty() {
        return false;
    }
    let extension = extension.to_ascii_lowercase();
    let mut answers = ANSWERS.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(&package) = answers.get(extension.as_str()) {
        return package;
    }
    let tag = CFString::from_str(&extension);
    let package = unsafe {
        UTTypeCreatePreferredIdentifierForTag(
            kUTTagClassFilenameExtension,
            &tag,
            Some(kUTTypeDirectory),
        )
        .is_some_and(|uti| UTTypeConformsTo(&uti, kUTTypePackage))
    };
    answers.insert(extension.into(), package);
    package
}

#[cfg(test)]
mod tests {
    use super::is_package_extension;

    #[test]
    fn apps_and_document_packages_are_packages() {
        for extension in [
            "app", "APP", "pkg", "pages", "rtfd", "key", "numbers", "bundle",
        ] {
            assert!(is_package_extension(extension), "{extension}");
        }
        for extension in ["", "js", "txt", "bin", "png", "framework", "lproj", "d"] {
            assert!(!is_package_extension(extension), "{extension}");
        }
    }
}
