use libc::dev_t;
use objc2_core_services::{
    FSEventsCopyUUIDForDevice, FSEventsGetCurrentEventId, FSEventsGetLastEventIdForDeviceBeforeTime,
};
use std::{collections::HashMap, os::unix::fs::MetadataExt, path::Path, time::SystemTime};

pub fn current_timestamp() -> i64 {
    SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}

pub fn current_event_id() -> u64 {
    unsafe { FSEventsGetCurrentEventId() }
}

/// Identifies the FSEvents history of the volume holding `path`: the UUID of the
/// volume's event database. macOS starts a new history, with a new UUID, when it
/// discards the old one (after a disk repair, for example); event IDs recorded
/// in the old history then no longer find their events. `None` when the volume
/// keeps no history or `path` cannot be read.
pub fn event_history_id(path: &Path) -> Option<u128> {
    let device = std::fs::metadata(path).ok()?.dev();
    let uuid = unsafe { FSEventsCopyUUIDForDevice(device as dev_t) }?;
    let b = uuid.uuid_bytes();
    Some(u128::from_be_bytes([
        b.byte0, b.byte1, b.byte2, b.byte3, b.byte4, b.byte5, b.byte6, b.byte7, b.byte8, b.byte9,
        b.byte10, b.byte11, b.byte12, b.byte13, b.byte14, b.byte15,
    ]))
}

pub fn last_event_id_before_time(dev: dev_t, timestamp: i64) -> u64 {
    unsafe { FSEventsGetLastEventIdForDeviceBeforeTime(dev, timestamp as f64) }
}

/// Given a device id, an event id, and a cache mapping timestamps to last event ids before them,
/// perform a binary search to find the timestamp corresponding to the event id.
pub fn event_id_to_timestamp(dev: dev_t, event_id: u64, cache: &mut HashMap<i64, u64>) -> i64 {
    let mut begin = 0i64;
    let mut end = current_timestamp();
    loop {
        let mid = (begin + end) / 2;
        if mid == begin || mid == end {
            return mid;
        }
        let mid_event_id = *cache
            .entry(mid)
            .or_insert_with(|| last_event_id_before_time(dev, mid));
        if mid_event_id < event_id {
            begin = mid
        } else if mid_event_id > event_id {
            end = mid
        } else {
            return mid;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::event_history_id;
    use std::path::Path;

    #[test]
    fn folders_on_one_volume_share_its_event_history() {
        let root = event_history_id(Path::new("/")).expect("the startup disk keeps a history");
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(event_history_id(temp.path()), Some(root));
        assert_eq!(event_history_id(&temp.path().join("missing")), None);
    }
}
