//! Relations: append-only sets of tuples with incrementally maintained hash
//! indexes.
//!
//! Tuples are sequences of interned constants (`u32` ranks, see
//! [`crate::eval`]). A tuple's id is its insertion position, so the tuples
//! added during one evaluation round form a contiguous id range; that is how
//! the semi-naive evaluator names its deltas.

use crate::hash::{hash_tuple, FxHashMap};

/// Maximum number of arguments of a predicate.
pub const MAX_ARITY: usize = 6;

/// Sentinel for "no tuple".
pub(crate) const NONE: u32 = u32::MAX;

/// Fixed-size key buffer for index lookups.
pub(crate) type Key = [u32; MAX_ARITY];

/// A hash index over a subset of the argument positions. Every key maps to a
/// chain of tuple ids in ascending order, threaded through `next`.
struct Index {
    positions: Vec<usize>,
    /// key -> (first id, last id)
    map: FxHashMap<Key, (u32, u32)>,
    /// `next[id]` is the following tuple id with the same key, or [`NONE`].
    next: Vec<u32>,
}

impl Index {
    fn key_of(&self, t: &[u32]) -> Key {
        let mut k = [0; MAX_ARITY];
        for (i, &p) in self.positions.iter().enumerate() {
            k[i] = t[p];
        }
        k
    }

    fn add(&mut self, id: u32, t: &[u32]) {
        let key = self.key_of(t);
        self.next.push(NONE);
        match self.map.entry(key) {
            std::collections::hash_map::Entry::Occupied(mut e) => {
                let tail = &mut e.get_mut().1;
                self.next[*tail as usize] = id;
                *tail = id;
            }
            std::collections::hash_map::Entry::Vacant(e) => {
                e.insert((id, id));
            }
        }
    }
}

/// A set of tuples of one fixed arity.
pub struct Relation {
    arity: usize,
    /// Flat storage, `arity` words per tuple.
    data: Vec<u32>,
    /// Open-addressing set of tuple ids (linear probing); empty = [`NONE`].
    table: Vec<u32>,
    indexes: Vec<Index>,
}

impl Relation {
    /// An empty relation of the given arity (1..=[`MAX_ARITY`]).
    pub fn new(arity: usize) -> Self {
        assert!((1..=MAX_ARITY).contains(&arity), "unsupported arity {arity}");
        Relation { arity, data: Vec::new(), table: vec![NONE; 16], indexes: Vec::new() }
    }

    /// Number of arguments per tuple.
    pub fn arity(&self) -> usize {
        self.arity
    }

    /// Number of tuples.
    pub fn len(&self) -> usize {
        self.data.len() / self.arity
    }

    /// Whether the relation has no tuples.
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// The tuple with the given id.
    #[inline]
    pub fn tuple(&self, id: u32) -> &[u32] {
        let s = id as usize * self.arity;
        &self.data[s..s + self.arity]
    }

    /// Iterate over all tuples in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = &[u32]> {
        self.data.chunks_exact(self.arity)
    }

    /// Id of `t` if present.
    #[inline]
    pub fn find(&self, t: &[u32]) -> Option<u32> {
        debug_assert_eq!(t.len(), self.arity);
        let mask = self.table.len() - 1;
        let mut i = hash_tuple(t) as usize & mask;
        loop {
            let id = self.table[i];
            if id == NONE {
                return None;
            }
            if self.tuple(id) == t {
                return Some(id);
            }
            i = (i + 1) & mask;
        }
    }

    /// Membership test.
    #[inline]
    pub fn contains(&self, t: &[u32]) -> bool {
        self.find(t).is_some()
    }

    /// Insert `t`; returns `false` if it was already present. Every index is
    /// updated in O(1).
    pub fn insert(&mut self, t: &[u32]) -> bool {
        if self.contains(t) {
            return false;
        }
        if (self.len() + 1) * 2 > self.table.len() {
            self.grow();
        }
        let id = self.len() as u32;
        assert!(id != NONE, "relation too large");
        self.data.extend_from_slice(t);
        self.place(id);
        for ix in &mut self.indexes {
            ix.add(id, t);
        }
        true
    }

    fn place(&mut self, id: u32) {
        let mask = self.table.len() - 1;
        let mut i = hash_tuple(self.tuple(id)) as usize & mask;
        while self.table[i] != NONE {
            i = (i + 1) & mask;
        }
        self.table[i] = id;
    }

    fn grow(&mut self) {
        let n = self.table.len() * 2;
        self.table = vec![NONE; n];
        for id in 0..self.len() as u32 {
            self.place(id);
        }
    }

    /// Return the id of the index over `positions` (ascending), building it
    /// from the current contents if it does not exist yet. After that the
    /// index is maintained by [`Relation::insert`], never rebuilt.
    pub(crate) fn ensure_index(&mut self, positions: &[usize]) -> usize {
        if let Some(i) = self.indexes.iter().position(|ix| ix.positions == positions) {
            return i;
        }
        let mut ix = Index { positions: positions.to_vec(), map: FxHashMap::default(), next: Vec::new() };
        for id in 0..self.len() as u32 {
            ix.add(id, self.tuple(id));
        }
        self.indexes.push(ix);
        self.indexes.len() - 1
    }

    /// First tuple id with the given key in index `ix`, or [`NONE`].
    #[inline]
    pub(crate) fn index_head(&self, ix: usize, key: &Key) -> u32 {
        self.indexes[ix].map.get(key).map_or(NONE, |e| e.0)
    }

    /// Next tuple id in the chain after `id`, or [`NONE`].
    #[inline]
    pub(crate) fn index_next(&self, ix: usize, id: u32) -> u32 {
        self.indexes[ix].next[id as usize]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_dedups() {
        let mut r = Relation::new(2);
        assert!(r.insert(&[1, 2]));
        assert!(!r.insert(&[1, 2]));
        assert!(r.insert(&[2, 1]));
        assert_eq!(r.len(), 2);
        assert!(r.contains(&[2, 1]));
        assert!(!r.contains(&[3, 3]));
    }

    #[test]
    fn grows_past_initial_table() {
        let mut r = Relation::new(2);
        for i in 0..1000 {
            assert!(r.insert(&[i, i + 1]));
        }
        for i in 0..1000 {
            assert_eq!(r.find(&[i, i + 1]), Some(i));
        }
        assert_eq!(r.len(), 1000);
    }

    #[test]
    fn index_chains_are_ascending_and_incremental() {
        let mut r = Relation::new(2);
        r.insert(&[1, 10]);
        r.insert(&[2, 20]);
        let ix = r.ensure_index(&[0]); // built over existing tuples
        r.insert(&[1, 11]); // maintained afterwards
        let mut key = [0; MAX_ARITY];
        key[0] = 1;
        let mut ids = Vec::new();
        let mut id = r.index_head(ix, &key);
        while id != NONE {
            ids.push(id);
            id = r.index_next(ix, id);
        }
        assert_eq!(ids, vec![0, 2]);
        assert_eq!(r.ensure_index(&[0]), ix);
    }
}
