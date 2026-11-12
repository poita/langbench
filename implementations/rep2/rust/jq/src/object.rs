//! An insertion-ordered string-keyed map with expected O(1) lookup.

use std::cell::OnceCell;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::rc::Rc;

use crate::value::Value;

/// Objects with at most this many keys are searched linearly; larger ones
/// carry a hash index.
const INDEX_THRESHOLD: usize = 8;

/// A small, fast, non-cryptographic hasher (the "Fx" multiply-rotate scheme).
#[derive(Default, Clone, Copy)]
pub(crate) struct FxHasher {
    hash: u64,
}

const SEED: u64 = 0x517c_c1b7_2722_0a95;

impl FxHasher {
    #[inline]
    fn add(&mut self, word: u64) {
        self.hash = (self.hash.rotate_left(5) ^ word).wrapping_mul(SEED);
    }
}

impl Hasher for FxHasher {
    fn write(&mut self, bytes: &[u8]) {
        let mut chunks = bytes.chunks_exact(8);
        for c in &mut chunks {
            self.add(u64::from_le_bytes(c.try_into().unwrap()));
        }
        let rest = chunks.remainder();
        if !rest.is_empty() {
            let mut buf = [0u8; 8];
            buf[..rest.len()].copy_from_slice(rest);
            self.add(u64::from_le_bytes(buf) ^ ((rest.len() as u64) << 56));
        }
    }

    #[inline]
    fn finish(&self) -> u64 {
        self.hash.rotate_left(26)
    }
}

type Index = HashMap<Rc<str>, usize, BuildHasherDefault<FxHasher>>;

/// An insertion-ordered map from strings to [`Value`]s.
///
/// Keys keep the position at which they were first inserted; re-inserting an
/// existing key replaces its value in place. The key-sorted order (used for
/// `keys`, comparison and so on) is computed at most once per object and then
/// cached.
#[derive(Default)]
pub struct Object {
    entries: Vec<(Rc<str>, Value)>,
    index: Option<Index>,
    sorted: OnceCell<Box<[u32]>>,
}

impl Clone for Object {
    fn clone(&self) -> Object {
        Object {
            entries: self.entries.clone(),
            index: self.index.clone(),
            sorted: OnceCell::new(),
        }
    }
}

impl std::fmt::Debug for Object {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_map().entries(self.iter()).finish()
    }
}

impl Object {
    /// Creates an empty object.
    pub fn new() -> Object {
        Object::default()
    }

    /// Creates an empty object with room for `n` keys.
    pub fn with_capacity(n: usize) -> Object {
        Object {
            entries: Vec::with_capacity(n),
            index: None,
            sorted: OnceCell::new(),
        }
    }

    /// Number of keys.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the object has no keys.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn position(&self, key: &str) -> Option<usize> {
        match &self.index {
            Some(m) => m.get(key).copied(),
            None => self.entries.iter().position(|(k, _)| &**k == key),
        }
    }

    /// Looks up the value stored under `key`.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.position(key).map(|i| &self.entries[i].1)
    }

    /// Whether `key` is present.
    pub fn contains_key(&self, key: &str) -> bool {
        self.position(key).is_some()
    }

    /// Sets `key` to `value`. An existing key keeps its position.
    pub fn insert(&mut self, key: Rc<str>, value: Value) {
        if let Some(i) = self.position(&key) {
            self.entries[i].1 = value;
            return;
        }
        self.sorted.take();
        let n = self.entries.len();
        if let Some(m) = &mut self.index {
            m.insert(key.clone(), n);
        } else if n >= INDEX_THRESHOLD {
            let mut m: Index = HashMap::with_capacity_and_hasher(n * 2, Default::default());
            for (i, (k, _)) in self.entries.iter().enumerate() {
                m.insert(k.clone(), i);
            }
            m.insert(key.clone(), n);
            self.index = Some(m);
        }
        self.entries.push((key, value));
    }

    /// Iterates over `(key, value)` pairs in insertion order.
    pub fn iter(&self) -> impl ExactSizeIterator<Item = (&Rc<str>, &Value)> + Clone {
        self.entries.iter().map(|(k, v)| (k, v))
    }

    /// Iterates over the keys in insertion order.
    pub fn keys(&self) -> impl ExactSizeIterator<Item = &Rc<str>> + Clone {
        self.entries.iter().map(|(k, _)| k)
    }

    /// Iterates over the values in insertion order.
    pub fn values(&self) -> impl ExactSizeIterator<Item = &Value> + Clone {
        self.entries.iter().map(|(_, v)| v)
    }

    /// Entry positions ordered by key (code point order); computed once.
    fn sorted_order(&self) -> &[u32] {
        self.sorted.get_or_init(|| {
            let mut idx: Vec<u32> = (0..self.entries.len() as u32).collect();
            idx.sort_unstable_by(|&a, &b| self.entries[a as usize].0.cmp(&self.entries[b as usize].0));
            idx.into_boxed_slice()
        })
    }

    /// Iterates over the keys in sorted (code point) order.
    pub fn sorted_keys(&self) -> impl ExactSizeIterator<Item = &Rc<str>> + Clone {
        self.sorted_order().iter().map(|&i| &self.entries[i as usize].0)
    }

    /// Iterates over `(key, value)` pairs in sorted key order.
    pub fn sorted_iter(&self) -> impl ExactSizeIterator<Item = (&Rc<str>, &Value)> + Clone {
        self.sorted_order().iter().map(|&i| {
            let e = &self.entries[i as usize];
            (&e.0, &e.1)
        })
    }
}

impl FromIterator<(Rc<str>, Value)> for Object {
    fn from_iter<T: IntoIterator<Item = (Rc<str>, Value)>>(iter: T) -> Object {
        let iter = iter.into_iter();
        let mut o = Object::with_capacity(iter.size_hint().0);
        for (k, v) in iter {
            o.insert(k, v);
        }
        o
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insertion_order_and_replacement() {
        let mut o = Object::new();
        for (i, k) in ["z", "a", "m"].iter().enumerate() {
            o.insert(Rc::from(*k), Value::from(i as i64));
        }
        o.insert(Rc::from("z"), Value::from(9i64));
        let keys: Vec<&str> = o.keys().map(|k| &**k).collect();
        assert_eq!(keys, ["z", "a", "m"]);
        assert_eq!(o.get("z"), Some(&Value::from(9i64)));
        let sorted: Vec<&str> = o.sorted_keys().map(|k| &**k).collect();
        assert_eq!(sorted, ["a", "m", "z"]);
    }

    #[test]
    fn large_objects_use_the_index() {
        let mut o = Object::new();
        for i in 0..100 {
            o.insert(Rc::from(i.to_string()), Value::from(i as i64));
        }
        assert_eq!(o.len(), 100);
        assert_eq!(o.get("57"), Some(&Value::from(57i64)));
        assert!(o.get("100").is_none());
        o.insert(Rc::from("57"), Value::Null);
        assert_eq!(o.len(), 100);
        assert_eq!(o.get("57"), Some(&Value::Null));
    }
}
