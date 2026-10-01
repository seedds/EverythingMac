//! Names of indexed items. Each distinct name is stored once, as a key of the
//! name index, and every item with that name points at the key's text; the name
//! is freed when its last item is removed (see `NameIndex`). While a walk or a
//! saved index is turned into an index, `Names` holds each name for the items that
//! share it until the name index takes it over, keeping its address.
use crate::SortedSlabIndices;
use hashbrown::HashSet;
use serde::{
    Deserializer,
    de::{self, DeserializeSeed, MapAccess, Visitor},
};
use std::{cell::RefCell, collections::BTreeMap, fmt};

#[derive(Default)]
pub(crate) struct Names(HashSet<Box<str>>);

impl Names {
    /// The stored copy of `name`, added if new. It stays at its address until it
    /// is dropped, including after `take` moves it.
    pub(crate) fn intern(&mut self, name: &str) -> &'static str {
        let stored = self.0.get_or_insert_with(name, |name| Box::from(name));
        unsafe { std::str::from_raw_parts(stored.as_ptr(), stored.len()) }
    }

    /// Like `intern`, but keeps `name` itself as the stored copy when it is new, and
    /// drops it otherwise.
    pub(crate) fn intern_owned(&mut self, name: Box<str>) -> &'static str {
        let stored = self.0.get_or_insert(name);
        unsafe { std::str::from_raw_parts(stored.as_ptr(), stored.len()) }
    }

    /// Moves out the stored copy of `name`, whose text keeps its address.
    pub(crate) fn take(&mut self, name: &str) -> Option<Box<str>> {
        self.0.take(name)
    }

    pub(crate) fn into_inner(self) -> HashSet<Box<str>> {
        self.0
    }
}

thread_local! {
    /// Names of the index being decoded on this thread; see `decoding`.
    static DECODING: RefCell<Option<Names>> = const { RefCell::new(None) };
}

/// Runs `decode` with names that decoded items share and that the decoded name
/// index then takes over. Names left over belong to no key of the name index, so
/// the structure check rejects any item still pointing at one; they are dropped
/// here.
pub(crate) fn decoding<T>(decode: impl FnOnce() -> T) -> T {
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            DECODING.set(None);
        }
    }
    DECODING.set(Some(Names::default()));
    let _reset = Reset;
    decode()
}

/// Decodes an item's name into the names being decoded.
pub(crate) struct DecodeName;

impl<'de> DeserializeSeed<'de> for DecodeName {
    type Value = &'static str;

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<Self::Value, D::Error> {
        // Unlike `deserialize_str`, postcard's reader lends a reused buffer here.
        deserializer.deserialize_string(self)
    }
}

impl Visitor<'_> for DecodeName {
    type Value = &'static str;

    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("a name")
    }

    fn visit_str<E: de::Error>(self, name: &str) -> Result<Self::Value, E> {
        DECODING
            .with_borrow_mut(|names| names.as_mut().map(|names| names.intern(name)))
            .ok_or_else(|| E::custom("item names are decoded only with their index"))
    }
}

/// Decodes a name index, taking each key from the names its items were decoded
/// into, so that the items point at the keys.
pub(crate) fn decode_name_index<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<BTreeMap<Box<str>, SortedSlabIndices>, D::Error> {
    struct Key;

    impl<'de> DeserializeSeed<'de> for Key {
        type Value = Box<str>;

        fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<Box<str>, D::Error> {
            deserializer.deserialize_string(self)
        }
    }

    impl Visitor<'_> for Key {
        type Value = Box<str>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("a name")
        }

        fn visit_str<E: de::Error>(self, name: &str) -> Result<Box<str>, E> {
            let taken =
                DECODING.with_borrow_mut(|names| names.as_mut().and_then(|names| names.take(name)));
            Ok(taken.unwrap_or_else(|| Box::from(name)))
        }
    }

    struct Index;

    impl<'de> Visitor<'de> for Index {
        type Value = BTreeMap<Box<str>, SortedSlabIndices>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("a name index")
        }

        fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
            // A damaged length must not reserve memory for it.
            let mut entries = Vec::with_capacity(map.size_hint().unwrap_or(0).min(1 << 20));
            while let Some(name) = map.next_key_seed(Key)? {
                // Saved from a map, so in order; a repeated key would drop the copy
                // that items point at.
                if entries.last().is_some_and(|(last, _)| *last >= name) {
                    return Err(de::Error::custom("the name index is out of order"));
                }
                entries.push((name, map.next_value()?));
            }
            Ok(entries.into_iter().collect())
        }
    }

    deserializer.deserialize_map(Index)
}
