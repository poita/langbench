//! An insertion-ordered string-keyed map with expected O(1) lookup.

use crate::value::Value;
use std::cell::OnceCell;
use std::collections::HashMap;
use std::rc::Rc;

/// Objects with at most this many keys are searched linearly; larger ones get a hash index.
const INDEX_THRESHOLD: usize = 8;

/// A JSON object: keys keep the order in which they were first inserted.
///
/// Lookup is expected O(1). The key order used for comparison and `keys`
/// (sorted by code point) is computed at most once per object and cached.
#[derive(Debug, Clone, Default)]
pub struct Object {
    entries: Vec<(Rc<str>, Value)>,
    index: Option<HashMap<Rc<str>, usize>>,
    sorted: OnceCell<Vec<usize>>,
}

impl Object {
    /// Creates an empty object.
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates an empty object with room for `n` keys.
    pub fn with_capacity(n: usize) -> Self {
        Object { entries: Vec::with_capacity(n), index: None, sorted: OnceCell::new() }
    }

    /// Number of keys.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the object has no keys.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn find(&self, key: &str) -> Option<usize> {
        match &self.index {
            Some(m) => m.get(key).copied(),
            None => self.entries.iter().position(|(k, _)| &**k == key),
        }
    }

    /// Looks up a key.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.find(key).map(|i| &self.entries[i].1)
    }

    /// Whether the key is present.
    pub fn contains_key(&self, key: &str) -> bool {
        self.find(key).is_some()
    }

    /// Sets `key` to `value`. An existing key keeps its position; a new key is appended.
    pub fn insert(&mut self, key: Rc<str>, value: Value) {
        if let Some(i) = self.find(&key) {
            self.entries[i].1 = value;
            return;
        }
        self.sorted = OnceCell::new();
        let pos = self.entries.len();
        match self.index.as_mut() {
            Some(m) => {
                m.insert(key.clone(), pos);
            }
            None if pos >= INDEX_THRESHOLD => {
                let mut m: HashMap<Rc<str>, usize> =
                    self.entries.iter().enumerate().map(|(i, (k, _))| (k.clone(), i)).collect();
                m.insert(key.clone(), pos);
                self.index = Some(m);
            }
            None => {}
        }
        self.entries.push((key, value));
    }

    /// Iterates over `(key, value)` pairs in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = (&Rc<str>, &Value)> {
        self.entries.iter().map(|(k, v)| (k, v))
    }

    /// Iterates over keys in insertion order.
    pub fn keys(&self) -> impl Iterator<Item = &Rc<str>> {
        self.entries.iter().map(|(k, _)| k)
    }

    /// Iterates over values in insertion order.
    pub fn values(&self) -> impl Iterator<Item = &Value> {
        self.entries.iter().map(|(_, v)| v)
    }

    fn sorted_order(&self) -> &[usize] {
        self.sorted.get_or_init(|| {
            let mut order: Vec<usize> = (0..self.entries.len()).collect();
            order.sort_unstable_by(|&a, &b| self.entries[a].0.cmp(&self.entries[b].0));
            order
        })
    }

    /// Iterates over `(key, value)` pairs sorted by key (code point order).
    /// The sort happens at most once per object.
    pub fn sorted_iter(&self) -> impl Iterator<Item = (&Rc<str>, &Value)> {
        self.sorted_order().iter().map(move |&i| {
            let (k, v) = &self.entries[i];
            (k, v)
        })
    }

    /// `self + other`: `other`'s keys are set in order on a copy of `self`.
    pub fn merged(&self, other: &Object) -> Object {
        let mut r = self.clone();
        for (k, v) in other.iter() {
            r.insert(k.clone(), v.clone());
        }
        r
    }

    /// `self * other`: like [`merged`](Self::merged) but objects under the same key merge recursively.
    pub fn deep_merged(&self, other: &Object) -> Object {
        let mut r = self.clone();
        for (k, v) in other.iter() {
            let merged = match (r.get(k), v) {
                (Some(Value::Object(a)), Value::Object(b)) => Value::Object(Rc::new(a.deep_merged(b))),
                _ => v.clone(),
            };
            r.insert(k.clone(), merged);
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insertion_order_and_replacement() {
        let mut o = Object::new();
        for (i, k) in ["z", "a", "m"].iter().enumerate() {
            o.insert((*k).into(), Value::Number(i as f64));
        }
        o.insert("z".into(), Value::Number(9.0));
        assert_eq!(o.keys().map(|k| &**k).collect::<Vec<_>>(), ["z", "a", "m"]);
        assert_eq!(o.get("z"), Some(&Value::Number(9.0)));
        assert_eq!(o.sorted_iter().map(|(k, _)| &**k).collect::<Vec<_>>(), ["a", "m", "z"]);
    }

    #[test]
    fn large_objects_use_the_index() {
        let mut o = Object::new();
        for i in 0..100 {
            o.insert(i.to_string().into(), Value::Number(i as f64));
        }
        assert_eq!(o.len(), 100);
        assert_eq!(o.get("57"), Some(&Value::Number(57.0)));
        assert!(!o.contains_key("100"));
        o.insert("57".into(), Value::Null);
        assert_eq!(o.len(), 100);
    }

    #[test]
    fn merging() {
        let mut a = Object::new();
        a.insert("x".into(), Value::Number(1.0));
        let mut b = Object::new();
        b.insert("y".into(), Value::Number(2.0));
        b.insert("x".into(), Value::Number(3.0));
        let m = a.merged(&b);
        assert_eq!(m.keys().map(|k| &**k).collect::<Vec<_>>(), ["x", "y"]);
        assert_eq!(m.get("x"), Some(&Value::Number(3.0)));
        assert_eq!(a.get("x"), Some(&Value::Number(1.0)));
    }
}
