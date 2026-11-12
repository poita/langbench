//! Storage for the tuples of one predicate.
//!
//! A [`Relation`] is an append-only set of fixed-arity rows of `u32` values.
//! Rows are stored flat, in insertion order, and are identified by their row
//! number. Insertion order is what makes semi-naive evaluation cheap: "the
//! tuples derived in round *k*" is simply a contiguous range of row numbers.
//!
//! Membership is answered by an open-addressing hash table over row numbers.
//! Any number of hash [`Index`]es, each on a set of columns, can be attached;
//! every index is updated incrementally on insertion, so the total cost of
//! maintaining an index over a whole run is linear in the relation's size.

/// Sentinel for "no row".
pub(crate) const NONE: u32 = u32::MAX;

#[inline]
fn mix(h: u64, v: u32) -> u64 {
    (h.rotate_left(5) ^ u64::from(v)).wrapping_mul(0x517c_c1b7_2722_0a95)
}

#[inline]
fn finish(h: u64) -> usize {
    ((h ^ (h >> 29)).wrapping_mul(0xbf58_476d_1ce4_e5b9) >> 20) as usize
}

#[inline]
fn hash_slice(vals: &[u32]) -> usize {
    finish(vals.iter().fold(0x9e37_79b9, |h, &v| mix(h, v)))
}

#[inline]
fn hash_cols(row: &[u32], cols: &[usize]) -> usize {
    finish(cols.iter().fold(0x9e37_79b9, |h, &c| mix(h, row[c])))
}

/// An append-only set of tuples with optional hash indexes.
#[derive(Debug, Clone)]
pub struct Relation {
    arity: usize,
    data: Vec<u32>,
    /// Open-addressing table of row numbers (`NONE` = empty), load ≤ 1/2.
    table: Vec<u32>,
    indexes: Vec<Index>,
}

impl Relation {
    /// An empty relation of the given arity (at least 1).
    pub fn new(arity: usize) -> Self {
        assert!(arity > 0, "relations have at least one column");
        Relation { arity, data: Vec::new(), table: vec![NONE; 16], indexes: Vec::new() }
    }

    /// Number of columns.
    pub fn arity(&self) -> usize {
        self.arity
    }

    /// Number of tuples.
    pub fn len(&self) -> usize {
        self.data.len() / self.arity
    }

    /// `true` if there are no tuples.
    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// The tuple stored in row `row`.
    #[inline]
    pub fn row(&self, row: u32) -> &[u32] {
        let s = row as usize * self.arity;
        &self.data[s..s + self.arity]
    }

    /// Iterate over all tuples in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = &[u32]> {
        self.data.chunks_exact(self.arity)
    }

    /// Row number of `tuple`, if present.
    #[inline]
    pub fn find(&self, tuple: &[u32]) -> Option<u32> {
        debug_assert_eq!(tuple.len(), self.arity);
        let mask = self.table.len() - 1;
        let mut i = hash_slice(tuple) & mask;
        loop {
            let r = self.table[i];
            if r == NONE {
                return None;
            }
            if self.row(r) == tuple {
                return Some(r);
            }
            i = (i + 1) & mask;
        }
    }

    /// Whether `tuple` is present.
    #[inline]
    pub fn contains(&self, tuple: &[u32]) -> bool {
        self.find(tuple).is_some()
    }

    /// Insert `tuple`; returns `true` if it was not already present.
    pub fn insert(&mut self, tuple: &[u32]) -> bool {
        debug_assert_eq!(tuple.len(), self.arity);
        if (self.len() + 1) * 2 > self.table.len() {
            self.grow();
        }
        let mask = self.table.len() - 1;
        let mut i = hash_slice(tuple) & mask;
        loop {
            let r = self.table[i];
            if r == NONE {
                break;
            }
            if self.row(r) == tuple {
                return false;
            }
            i = (i + 1) & mask;
        }
        let row = u32::try_from(self.len()).expect("relation too large");
        assert!(row != NONE);
        self.table[i] = row;
        self.data.extend_from_slice(tuple);
        for idx in &mut self.indexes {
            idx.add(&self.data, self.arity, row);
        }
        true
    }

    fn grow(&mut self) {
        let cap = self.table.len() * 2;
        let mask = cap - 1;
        let mut table = vec![NONE; cap];
        for (r, row) in self.data.chunks_exact(self.arity).enumerate() {
            let mut i = hash_slice(row) & mask;
            while table[i] != NONE {
                i = (i + 1) & mask;
            }
            table[i] = r as u32;
        }
        self.table = table;
    }

    /// Get (creating and back-filling it if necessary) the index on `cols`,
    /// returning its id for use with [`Relation::index`].
    pub fn ensure_index(&mut self, cols: &[usize]) -> usize {
        if let Some(i) = self.indexes.iter().position(|ix| ix.cols == cols) {
            return i;
        }
        assert!(cols.iter().all(|&c| c < self.arity));
        let mut ix = Index::new(cols.to_vec());
        for r in 0..self.len() {
            ix.add(&self.data, self.arity, r as u32);
        }
        self.indexes.push(ix);
        self.indexes.len() - 1
    }

    #[inline]
    pub(crate) fn index(&self, id: usize) -> &Index {
        &self.indexes[id]
    }

    /// First row (lowest row number) whose indexed columns equal `key`, or
    /// [`NONE`]. Subsequent rows come from [`Index::next`].
    #[inline]
    pub(crate) fn probe(&self, id: usize, key: &[u32]) -> u32 {
        self.indexes[id].first(&self.data, self.arity, key)
    }
}

#[derive(Debug, Clone, Copy)]
struct Slot {
    head: u32,
    tail: u32,
}

const EMPTY: Slot = Slot { head: NONE, tail: NONE };

/// A hash index over some columns of a [`Relation`].
///
/// Each distinct key owns a singly linked chain of rows in ascending row
/// order, so a scan of a key's rows can stop at the first row beyond any
/// "visible" prefix of the relation.
#[derive(Debug, Clone)]
pub(crate) struct Index {
    cols: Vec<usize>,
    slots: Vec<Slot>,
    used: usize,
    next: Vec<u32>,
}

impl Index {
    fn new(cols: Vec<usize>) -> Self {
        Index { cols, slots: vec![EMPTY; 16], used: 0, next: Vec::new() }
    }

    /// The indexed columns.
    #[cfg(test)]
    pub(crate) fn cols(&self) -> &[usize] {
        &self.cols
    }

    /// Next row with the same key as `row`, or [`NONE`].
    #[inline]
    pub(crate) fn next(&self, row: u32) -> u32 {
        self.next[row as usize]
    }

    #[inline]
    fn key_of<'a>(&self, data: &'a [u32], arity: usize, row: u32) -> &'a [u32] {
        let s = row as usize * arity;
        &data[s..s + arity]
    }

    fn same_key(&self, a: &[u32], b: &[u32]) -> bool {
        self.cols.iter().all(|&c| a[c] == b[c])
    }

    /// Register the freshly appended `row` (which must be the highest row).
    fn add(&mut self, data: &[u32], arity: usize, row: u32) {
        debug_assert_eq!(self.next.len(), row as usize);
        self.next.push(NONE);
        if (self.used + 1) * 2 > self.slots.len() {
            self.grow(data, arity);
        }
        let mask = self.slots.len() - 1;
        let new_row = self.key_of(data, arity, row);
        let mut i = hash_cols(new_row, &self.cols) & mask;
        loop {
            let s = self.slots[i];
            if s.head == NONE {
                self.slots[i] = Slot { head: row, tail: row };
                self.used += 1;
                return;
            }
            if self.same_key(self.key_of(data, arity, s.head), new_row) {
                self.next[s.tail as usize] = row;
                self.slots[i].tail = row;
                return;
            }
            i = (i + 1) & mask;
        }
    }

    fn grow(&mut self, data: &[u32], arity: usize) {
        let cap = self.slots.len() * 2;
        let mask = cap - 1;
        let mut slots = vec![EMPTY; cap];
        for s in self.slots.iter().filter(|s| s.head != NONE) {
            let mut i = hash_cols(self.key_of(data, arity, s.head), &self.cols) & mask;
            while slots[i].head != NONE {
                i = (i + 1) & mask;
            }
            slots[i] = *s;
        }
        self.slots = slots;
    }

    /// First row for `key` (values of the indexed columns, in column order).
    #[inline]
    fn first(&self, data: &[u32], arity: usize, key: &[u32]) -> u32 {
        debug_assert_eq!(key.len(), self.cols.len());
        let mask = self.slots.len() - 1;
        let mut i = hash_slice(key) & mask;
        loop {
            let s = self.slots[i];
            if s.head == NONE {
                return NONE;
            }
            let row = self.key_of(data, arity, s.head);
            if self.cols.iter().zip(key).all(|(&c, &k)| row[c] == k) {
                return s.head;
            }
            i = (i + 1) & mask;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_membership() {
        let mut r = Relation::new(2);
        assert!(r.insert(&[1, 2]));
        assert!(!r.insert(&[1, 2]));
        assert!(r.insert(&[2, 1]));
        assert_eq!(r.len(), 2);
        assert_eq!(r.find(&[2, 1]), Some(1));
        assert!(!r.contains(&[3, 3]));
        for i in 0..1000 {
            r.insert(&[i, i + 1]);
        }
        assert!(r.contains(&[999, 1000]));
        assert_eq!(r.iter().count(), r.len());
    }

    fn chain(r: &Relation, id: usize, key: &[u32]) -> Vec<u32> {
        let mut out = Vec::new();
        let mut row = r.probe(id, key);
        while row != NONE {
            out.push(row);
            row = r.index(id).next(row);
        }
        out
    }

    #[test]
    fn index_chains_are_ascending_and_incremental() {
        let mut r = Relation::new(2);
        for i in 0..50u32 {
            r.insert(&[i % 5, i]);
        }
        let by0 = r.ensure_index(&[0]); // back-filled
        for i in 50..100u32 {
            r.insert(&[i % 5, i]); // incremental
        }
        assert_eq!(r.ensure_index(&[0]), by0);
        let c = chain(&r, by0, &[3]);
        assert_eq!(c.len(), 20);
        assert!(c.windows(2).all(|w| w[0] < w[1]));
        assert!(c.iter().all(|&row| r.row(row)[0] == 3));
        assert!(chain(&r, by0, &[7]).is_empty());
        let both = r.ensure_index(&[1, 0]);
        assert_eq!(chain(&r, both, &[42, 2]).len(), 1);
        assert_eq!(r.index(both).cols(), &[1, 0]);
    }
}
