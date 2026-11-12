//! Iterators over an [`OrderedMap`].

use crate::map::{Idx, OrderedMap, NIL};

/// Iterator over the entries with keys in an inclusive range, in ascending
/// order. Created by [`OrderedMap::range`].
///
/// It keeps an explicit stack of pending ancestors (at most the tree height),
/// so the traversal is pruned: subtrees entirely below `lo` are never
/// entered and iteration stops at the first key above `hi`.
pub struct Range<'a, V> {
    map: &'a OrderedMap<V>,
    stack: Vec<Idx>,
    hi: i64,
}

/// Iterator over all entries in ascending key order. Created by
/// [`OrderedMap::iter`].
pub type Iter<'a, V> = Range<'a, V>;

impl<'a, V> Range<'a, V> {
    pub(crate) fn new(map: &'a OrderedMap<V>, lo: i64, hi: i64) -> Self {
        let mut stack = Vec::with_capacity(48);
        if lo <= hi {
            let mut t = map.root_idx();
            while t != NIL {
                let n = map.node(t);
                if n.key >= lo {
                    stack.push(t);
                    t = n.left;
                } else {
                    t = n.right;
                }
            }
        }
        Range { map, stack, hi }
    }
}

impl<'a, V> Iterator for Range<'a, V> {
    type Item = (i64, &'a V);

    fn next(&mut self) -> Option<Self::Item> {
        let t = self.stack.pop()?;
        let n = self.map.node(t);
        if n.key > self.hi {
            self.stack.clear();
            return None;
        }
        // Everything in the right subtree is >= lo already.
        let mut c = n.right;
        while c != NIL {
            self.stack.push(c);
            c = self.map.node(c).left;
        }
        Some((n.key, &n.value))
    }
}

/// Iterator over keys in ascending order. Created by [`OrderedMap::keys`].
pub struct Keys<'a, V>(Iter<'a, V>);

impl<'a, V> Keys<'a, V> {
    pub(crate) fn new(inner: Iter<'a, V>) -> Self {
        Keys(inner)
    }
}

impl<V> Iterator for Keys<'_, V> {
    type Item = i64;
    fn next(&mut self) -> Option<i64> {
        self.0.next().map(|(k, _)| k)
    }
}
