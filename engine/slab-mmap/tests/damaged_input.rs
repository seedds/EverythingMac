//! A damaged saved slab must fail to load quickly, without mapping or filling a
//! file sized by the damaged numbers.
use slab_mmap::Slab;
use std::time::{Duration, Instant};

fn varint(mut value: u64, out: &mut Vec<u8>) {
    while value >= 0x80 {
        out.push(value as u8 | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

/// A postcard map of the given stated length holding `(key, 7u32)` entries.
fn map(len: u64, keys: &[u64]) -> Vec<u8> {
    let mut bytes = Vec::new();
    varint(len, &mut bytes);
    for &key in keys {
        varint(key, &mut bytes);
        varint(7, &mut bytes);
    }
    bytes
}

fn load(bytes: &[u8]) -> Result<Slab<u32>, postcard::Error> {
    postcard::from_bytes(bytes)
}

#[test]
fn damaged_lengths_and_keys_fail_quickly() {
    let started = Instant::now();
    // A stated length far beyond the entries present.
    assert!(load(&map(1 << 40, &[])).is_err());
    assert!(load(&map(u64::MAX, &[0, 1])).is_err());
    // Keys beyond what `u32` handles can hold, or far past the entries read.
    assert!(load(&map(1, &[u32::MAX as u64])).is_err());
    assert!(load(&map(1, &[1 << 40])).is_err());
    assert!(load(&map(1, &[1 << 25])).is_err());
    assert!(load(&map(3, &[0, 1, 1 << 26])).is_err());
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn sparse_keys_within_bounds_still_load() {
    let slab = load(&map(3, &[0, 5000, 1 << 20])).unwrap();
    assert_eq!(slab.len(), 3);
    assert_eq!(slab.get(1 << 20), Some(&7));
    assert_eq!(slab.get(4999), None);
}
