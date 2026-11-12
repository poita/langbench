//! Interning of lines to dense integer ids.

use std::collections::HashMap;
use std::hash::Hash;

/// Assigns each distinct value a small integer id, so equality of two values
/// becomes an O(1) integer comparison.
#[derive(Debug)]
pub struct Interner<'a, T> {
    ids: HashMap<&'a T, u32>,
}

impl<'a, T: Eq + Hash> Interner<'a, T> {
    /// Creates an empty interner.
    pub fn new() -> Self {
        Interner {
            ids: HashMap::new(),
        }
    }

    /// Returns the id of `item`, allocating a new one if it is unseen.
    pub fn intern(&mut self, item: &'a T) -> u32 {
        let next = self.ids.len() as u32;
        *self.ids.entry(item).or_insert(next)
    }

    /// Interns every element of `items` and returns the ids in order.
    pub fn intern_all(&mut self, items: &'a [T]) -> Vec<u32> {
        items.iter().map(|x| self.intern(x)).collect()
    }

    /// Number of distinct values seen so far.
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    /// True if nothing has been interned yet.
    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

impl<'a, T: Eq + Hash> Default for Interner<'a, T> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_items_share_ids() {
        let items = ["x", "y", "x", "z", "y"];
        let mut i = Interner::new();
        assert_eq!(i.intern_all(&items), vec![0, 1, 0, 2, 1]);
        assert_eq!(i.len(), 3);
    }
}
