//! The [`OrderedMap`] data structure: an AVL tree with subtree sizes.
//!
//! Nodes live in an arena (`Vec`) and refer to each other by `u32` index,
//! which keeps the tree compact and avoids per-node allocation. Slots freed by
//! removal are recycled through an intrusive free list.

use crate::iter::{Iter, Keys, Range};
use std::ops::RangeInclusive;

/// Index of a node in the arena; [`NIL`] means "no node".
pub(crate) type Idx = u32;
pub(crate) const NIL: Idx = u32::MAX;

pub(crate) struct Node<V> {
    pub(crate) key: i64,
    pub(crate) value: V,
    pub(crate) left: Idx,
    pub(crate) right: Idx,
    /// Height of the subtree rooted here (a leaf has height 1).
    height: u8,
    /// Number of nodes in the subtree rooted here.
    size: u32,
}

enum Slot<V> {
    Used(Node<V>),
    /// A free slot, holding the next free slot's index.
    Free(Idx),
}

/// An ordered map from `i64` keys to values of type `V`.
///
/// Backed by an AVL tree whose nodes track subtree sizes, so that all
/// point operations and order-statistic queries take `O(log n)` time.
pub struct OrderedMap<V> {
    slots: Vec<Slot<V>>,
    root: Idx,
    free_head: Idx,
}

impl<V> Default for OrderedMap<V> {
    fn default() -> Self {
        Self::new()
    }
}

impl<V: Clone> Clone for Node<V> {
    fn clone(&self) -> Self {
        Node {
            key: self.key,
            value: self.value.clone(),
            left: self.left,
            right: self.right,
            height: self.height,
            size: self.size,
        }
    }
}

impl<V: Clone> Clone for Slot<V> {
    fn clone(&self) -> Self {
        match self {
            Slot::Used(n) => Slot::Used(n.clone()),
            Slot::Free(i) => Slot::Free(*i),
        }
    }
}

impl<V: Clone> Clone for OrderedMap<V> {
    fn clone(&self) -> Self {
        OrderedMap {
            slots: self.slots.clone(),
            root: self.root,
            free_head: self.free_head,
        }
    }
}

impl<V: std::fmt::Debug> std::fmt::Debug for OrderedMap<V> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_map().entries(self.iter()).finish()
    }
}

impl<V> OrderedMap<V> {
    /// Creates an empty map.
    pub const fn new() -> Self {
        OrderedMap {
            slots: Vec::new(),
            root: NIL,
            free_head: NIL,
        }
    }

    /// Creates an empty map with room for `capacity` entries.
    pub fn with_capacity(capacity: usize) -> Self {
        OrderedMap {
            slots: Vec::with_capacity(capacity),
            root: NIL,
            free_head: NIL,
        }
    }

    /// Number of entries in the map.
    pub fn len(&self) -> usize {
        self.size(self.root) as usize
    }

    /// Whether the map has no entries.
    pub fn is_empty(&self) -> bool {
        self.root == NIL
    }

    /// Removes every entry.
    pub fn clear(&mut self) {
        self.slots.clear();
        self.root = NIL;
        self.free_head = NIL;
    }

    // ----- node access helpers -------------------------------------------

    #[inline]
    pub(crate) fn node(&self, i: Idx) -> &Node<V> {
        match &self.slots[i as usize] {
            Slot::Used(n) => n,
            Slot::Free(_) => unreachable!("dangling node index"),
        }
    }

    #[inline]
    fn node_mut(&mut self, i: Idx) -> &mut Node<V> {
        match &mut self.slots[i as usize] {
            Slot::Used(n) => n,
            Slot::Free(_) => unreachable!("dangling node index"),
        }
    }

    pub(crate) fn root_idx(&self) -> Idx {
        self.root
    }

    #[inline]
    fn size(&self, i: Idx) -> u32 {
        if i == NIL {
            0
        } else {
            self.node(i).size
        }
    }

    #[inline]
    fn height(&self, i: Idx) -> u8 {
        if i == NIL {
            0
        } else {
            self.node(i).height
        }
    }

    fn alloc(&mut self, key: i64, value: V) -> Idx {
        let node = Node {
            key,
            value,
            left: NIL,
            right: NIL,
            height: 1,
            size: 1,
        };
        if self.free_head != NIL {
            let i = self.free_head;
            let Slot::Free(next) = self.slots[i as usize] else {
                unreachable!("free list points at a used slot")
            };
            self.free_head = next;
            self.slots[i as usize] = Slot::Used(node);
            i
        } else {
            let i = self.slots.len();
            assert!(i < NIL as usize, "ordered map capacity exceeded");
            self.slots.push(Slot::Used(node));
            i as Idx
        }
    }

    /// Releases slot `i`, returning the node that occupied it.
    fn release(&mut self, i: Idx) -> Node<V> {
        let old = std::mem::replace(&mut self.slots[i as usize], Slot::Free(self.free_head));
        self.free_head = i;
        match old {
            Slot::Used(n) => n,
            Slot::Free(_) => unreachable!("double free"),
        }
    }

    // ----- AVL maintenance -------------------------------------------------

    /// Recomputes height and size of `t` from its children.
    fn update(&mut self, t: Idx) {
        let (l, r) = {
            let n = self.node(t);
            (n.left, n.right)
        };
        let height = 1 + self.height(l).max(self.height(r));
        let size = 1 + self.size(l) + self.size(r);
        let n = self.node_mut(t);
        n.height = height;
        n.size = size;
    }

    fn balance_factor(&self, t: Idx) -> i32 {
        let n = self.node(t);
        self.height(n.left) as i32 - self.height(n.right) as i32
    }

    fn rotate_right(&mut self, t: Idx) -> Idx {
        let l = self.node(t).left;
        let lr = self.node(l).right;
        self.node_mut(t).left = lr;
        self.node_mut(l).right = t;
        self.update(t);
        self.update(l);
        l
    }

    fn rotate_left(&mut self, t: Idx) -> Idx {
        let r = self.node(t).right;
        let rl = self.node(r).left;
        self.node_mut(t).right = rl;
        self.node_mut(r).left = t;
        self.update(t);
        self.update(r);
        r
    }

    /// Restores the AVL invariant at `t` (whose children are valid AVL
    /// trees whose heights differ by at most 2) and returns the new subtree
    /// root.
    fn rebalance(&mut self, t: Idx) -> Idx {
        self.update(t);
        let bf = self.balance_factor(t);
        if bf > 1 {
            let l = self.node(t).left;
            if self.balance_factor(l) < 0 {
                let nl = self.rotate_left(l);
                self.node_mut(t).left = nl;
            }
            self.rotate_right(t)
        } else if bf < -1 {
            let r = self.node(t).right;
            if self.balance_factor(r) > 0 {
                let nr = self.rotate_right(r);
                self.node_mut(t).right = nr;
            }
            self.rotate_left(t)
        } else {
            t
        }
    }

    // ----- updates ---------------------------------------------------------

    /// Inserts `key` with `value`. Returns the previous value if the key was
    /// already present (the key itself is kept).
    pub fn insert(&mut self, key: i64, value: V) -> Option<V> {
        let (root, old) = self.insert_at(self.root, key, value);
        self.root = root;
        old
    }

    fn insert_at(&mut self, t: Idx, key: i64, value: V) -> (Idx, Option<V>) {
        if t == NIL {
            return (self.alloc(key, value), None);
        }
        let n = self.node(t);
        if key < n.key {
            let (nl, old) = self.insert_at(n.left, key, value);
            self.node_mut(t).left = nl;
            if old.is_some() {
                return (t, old);
            }
            (self.rebalance(t), None)
        } else if key > n.key {
            let (nr, old) = self.insert_at(n.right, key, value);
            self.node_mut(t).right = nr;
            if old.is_some() {
                return (t, old);
            }
            (self.rebalance(t), None)
        } else {
            let old = std::mem::replace(&mut self.node_mut(t).value, value);
            (t, Some(old))
        }
    }

    /// Removes `key`, returning its value if it was present.
    pub fn remove(&mut self, key: i64) -> Option<V> {
        let (root, old) = self.remove_at(self.root, key);
        self.root = root;
        old
    }

    fn remove_at(&mut self, t: Idx, key: i64) -> (Idx, Option<V>) {
        if t == NIL {
            return (NIL, None);
        }
        let n = self.node(t);
        if key < n.key {
            let (nl, old) = self.remove_at(n.left, key);
            self.node_mut(t).left = nl;
            if old.is_none() {
                return (t, None);
            }
            (self.rebalance(t), old)
        } else if key > n.key {
            let (nr, old) = self.remove_at(n.right, key);
            self.node_mut(t).right = nr;
            if old.is_none() {
                return (t, None);
            }
            (self.rebalance(t), old)
        } else {
            let (l, r) = (n.left, n.right);
            let removed = self.release(t);
            if l == NIL {
                return (r, Some(removed.value));
            }
            if r == NIL {
                return (l, Some(removed.value));
            }
            // Two children: the in-order successor takes this node's place.
            let (nr, m) = self.remove_min(r);
            let mn = self.node_mut(m);
            mn.left = l;
            mn.right = nr;
            (self.rebalance(m), Some(removed.value))
        }
    }

    /// Detaches the minimum node of the non-empty subtree `t`. Returns the
    /// new subtree root and the detached node (not freed; links stale).
    fn remove_min(&mut self, t: Idx) -> (Idx, Idx) {
        let l = self.node(t).left;
        if l == NIL {
            return (self.node(t).right, t);
        }
        let (nl, m) = self.remove_min(l);
        self.node_mut(t).left = nl;
        (self.rebalance(t), m)
    }

    // ----- point queries ---------------------------------------------------

    fn find(&self, key: i64) -> Option<&Node<V>> {
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if key < n.key {
                t = n.left;
            } else if key > n.key {
                t = n.right;
            } else {
                return Some(n);
            }
        }
        None
    }

    /// Returns the value stored under `key`.
    pub fn get(&self, key: i64) -> Option<&V> {
        self.find(key).map(|n| &n.value)
    }

    /// Returns a mutable reference to the value stored under `key`.
    pub fn get_mut(&mut self, key: i64) -> Option<&mut V> {
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if key < n.key {
                t = n.left;
            } else if key > n.key {
                t = n.right;
            } else {
                return Some(&mut self.node_mut(t).value);
            }
        }
        None
    }

    /// Whether `key` is present.
    pub fn contains_key(&self, key: i64) -> bool {
        self.find(key).is_some()
    }

    /// The smallest key.
    pub fn min(&self) -> Option<i64> {
        self.first_key_value().map(|(k, _)| k)
    }

    /// The largest key.
    pub fn max(&self) -> Option<i64> {
        self.last_key_value().map(|(k, _)| k)
    }

    /// The entry with the smallest key.
    pub fn first_key_value(&self) -> Option<(i64, &V)> {
        let mut t = self.root;
        if t == NIL {
            return None;
        }
        while self.node(t).left != NIL {
            t = self.node(t).left;
        }
        let n = self.node(t);
        Some((n.key, &n.value))
    }

    /// The entry with the largest key.
    pub fn last_key_value(&self) -> Option<(i64, &V)> {
        let mut t = self.root;
        if t == NIL {
            return None;
        }
        while self.node(t).right != NIL {
            t = self.node(t).right;
        }
        let n = self.node(t);
        Some((n.key, &n.value))
    }

    /// The largest key `<= key`.
    pub fn floor(&self, key: i64) -> Option<i64> {
        let mut best = None;
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if n.key == key {
                return Some(key);
            } else if n.key < key {
                best = Some(n.key);
                t = n.right;
            } else {
                t = n.left;
            }
        }
        best
    }

    /// The smallest key `>= key`.
    pub fn ceil(&self, key: i64) -> Option<i64> {
        let mut best = None;
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if n.key == key {
                return Some(key);
            } else if n.key > key {
                best = Some(n.key);
                t = n.left;
            } else {
                t = n.right;
            }
        }
        best
    }

    /// The smallest key strictly greater than `key`. Never overflows, even
    /// for `i64::MAX`.
    pub fn successor(&self, key: i64) -> Option<i64> {
        let mut best = None;
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if n.key > key {
                best = Some(n.key);
                t = n.left;
            } else {
                t = n.right;
            }
        }
        best
    }

    /// The largest key strictly less than `key`. Never overflows, even for
    /// `i64::MIN`.
    pub fn predecessor(&self, key: i64) -> Option<i64> {
        let mut best = None;
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if n.key < key {
                best = Some(n.key);
                t = n.right;
            } else {
                t = n.left;
            }
        }
        best
    }

    /// The number of keys strictly less than `key` (which need not be
    /// present).
    pub fn rank(&self, key: i64) -> usize {
        let mut count = 0usize;
        let mut t = self.root;
        while t != NIL {
            let n = self.node(t);
            if key <= n.key {
                t = n.left;
            } else {
                count += self.size(n.left) as usize + 1;
                t = n.right;
            }
        }
        count
    }

    /// The `k`-th smallest key (0-based), or `None` if `k >= len()`.
    pub fn select(&self, k: usize) -> Option<i64> {
        if k >= self.len() {
            return None;
        }
        let mut k = k;
        let mut t = self.root;
        loop {
            let n = self.node(t);
            let ls = self.size(n.left) as usize;
            if k < ls {
                t = n.left;
            } else if k == ls {
                return Some(n.key);
            } else {
                k -= ls + 1;
                t = n.right;
            }
        }
    }

    // ----- iteration -------------------------------------------------------

    /// Iterates over all entries in ascending key order.
    pub fn iter(&self) -> Iter<'_, V> {
        self.range(i64::MIN..=i64::MAX)
    }

    /// Iterates over all keys in ascending order.
    pub fn keys(&self) -> Keys<'_, V> {
        Keys::new(self.iter())
    }

    /// Iterates, in ascending order, over the entries whose keys lie in the
    /// inclusive `bounds`. An inverted range (`lo > hi`) is empty. Costs
    /// `O(log n)` to start plus `O(1)` amortised per entry.
    pub fn range(&self, bounds: RangeInclusive<i64>) -> Range<'_, V> {
        Range::new(self, *bounds.start(), *bounds.end())
    }

    /// Checks the BST ordering, AVL balance and the cached heights and sizes.
    /// Intended for tests; panics on a violation.
    #[doc(hidden)]
    pub fn validate(&self) {
        fn go<V>(m: &OrderedMap<V>, t: Idx, lo: Option<i64>, hi: Option<i64>) -> (u8, u32) {
            if t == NIL {
                return (0, 0);
            }
            let n = m.node(t);
            assert!(lo.is_none_or(|lo| n.key > lo), "BST order violated");
            assert!(hi.is_none_or(|hi| n.key < hi), "BST order violated");
            let (hl, sl) = go(m, n.left, lo, Some(n.key));
            let (hr, sr) = go(m, n.right, Some(n.key), hi);
            assert!((hl as i32 - hr as i32).abs() <= 1, "AVL balance violated");
            assert_eq!(n.height, 1 + hl.max(hr), "stale height");
            assert_eq!(n.size, 1 + sl + sr, "stale size");
            (n.height, n.size)
        }
        go(self, self.root, None, None);
    }
}

impl<V> FromIterator<(i64, V)> for OrderedMap<V> {
    fn from_iter<I: IntoIterator<Item = (i64, V)>>(iter: I) -> Self {
        let mut m = OrderedMap::new();
        m.extend(iter);
        m
    }
}

impl<V> Extend<(i64, V)> for OrderedMap<V> {
    fn extend<I: IntoIterator<Item = (i64, V)>>(&mut self, iter: I) {
        for (k, v) in iter {
            self.insert(k, v);
        }
    }
}

impl<'a, V> IntoIterator for &'a OrderedMap<V> {
    type Item = (i64, &'a V);
    type IntoIter = Iter<'a, V>;
    fn into_iter(self) -> Iter<'a, V> {
        self.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// Small deterministic xorshift generator so tests need no dependencies.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
    }

    #[test]
    fn empty_map() {
        let m: OrderedMap<u8> = OrderedMap::new();
        assert!(m.is_empty());
        assert_eq!(m.len(), 0);
        assert_eq!(m.min(), None);
        assert_eq!(m.max(), None);
        assert_eq!(m.rank(5), 0);
        assert_eq!(m.select(0), None);
        assert_eq!(m.floor(0), None);
        assert_eq!(m.range(0..=10).count(), 0);
    }

    #[test]
    fn insert_replace_remove() {
        let mut m = OrderedMap::new();
        assert_eq!(m.insert(5, "five"), None);
        assert_eq!(m.insert(5, "FIVE"), Some("five"));
        assert_eq!(m.get(5), Some(&"FIVE"));
        assert_eq!(m.len(), 1);
        assert_eq!(m.remove(5), Some("FIVE"));
        assert_eq!(m.remove(5), None);
        assert!(m.is_empty());
    }

    #[test]
    fn extreme_keys_do_not_overflow() {
        let m: OrderedMap<()> = [i64::MIN, 0, i64::MAX].into_iter().map(|k| (k, ())).collect();
        assert_eq!(m.successor(i64::MAX), None);
        assert_eq!(m.predecessor(i64::MIN), None);
        assert_eq!(m.successor(i64::MIN), Some(0));
        assert_eq!(m.predecessor(i64::MAX), Some(0));
        assert_eq!(m.rank(i64::MIN), 0);
        assert_eq!(m.rank(i64::MAX), 2);
        assert_eq!(m.iter().count(), 3);
    }

    #[test]
    fn sorted_insert_and_descending_delete_stay_balanced() {
        let mut m = OrderedMap::new();
        for k in 0..5000 {
            m.insert(k, k);
        }
        m.validate();
        // Height of an AVL tree with n nodes is at most 1.45 log2(n + 2).
        assert!(m.height(m.root) <= 19);
        for k in (0..5000).rev() {
            assert_eq!(m.remove(k), Some(k));
            if k % 97 == 0 {
                m.validate();
            }
        }
        assert!(m.is_empty());
    }

    #[test]
    fn slots_are_recycled() {
        let mut m = OrderedMap::new();
        for round in 0..10 {
            for k in 0..100 {
                m.insert(k, round);
            }
            for k in 0..100 {
                m.remove(k);
            }
        }
        assert_eq!(m.slots.len(), 100);
    }

    #[test]
    fn randomized_against_btreemap() {
        let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
        let mut m = OrderedMap::new();
        let mut model = BTreeMap::new();
        for step in 0..20_000u32 {
            let key = (rng.next() % 300) as i64 - 150;
            match rng.next() % 4 {
                0 | 1 => assert_eq!(m.insert(key, step), model.insert(key, step)),
                2 => assert_eq!(m.remove(key), model.remove(&key)),
                _ => {}
            }
            assert_eq!(m.len(), model.len());
            let probe = (rng.next() % 320) as i64 - 160;
            assert_eq!(m.get(probe), model.get(&probe));
            assert_eq!(m.floor(probe), model.range(..=probe).next_back().map(|(k, _)| *k));
            assert_eq!(m.ceil(probe), model.range(probe..).next().map(|(k, _)| *k));
            assert_eq!(m.successor(probe), model.range(probe + 1..).next().map(|(k, _)| *k));
            assert_eq!(m.predecessor(probe), model.range(..probe).next_back().map(|(k, _)| *k));
            assert_eq!(m.rank(probe), model.range(..probe).count());
            let k = (rng.next() % 200) as usize;
            assert_eq!(m.select(k), model.keys().nth(k).copied());
            if step % 500 == 0 {
                m.validate();
                let hi = probe + (rng.next() % 100) as i64;
                let got: Vec<_> = m.range(probe..=hi).map(|(k, v)| (k, *v)).collect();
                let want: Vec<_> = model.range(probe..=hi).map(|(k, v)| (*k, *v)).collect();
                assert_eq!(got, want);
            }
        }
        m.validate();
    }
}
