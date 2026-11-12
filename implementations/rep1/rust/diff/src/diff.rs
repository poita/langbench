//! High-level diff entry point.

use std::hash::Hash;

use crate::edit::Edit;
use crate::intern::Interner;
use crate::myers;

/// Computes a shortest edit script turning `a` into `b`.
///
/// The elements are interned first, so they only need `Eq + Hash`. The
/// returned edits are in order: reading the `Keep` and `Delete` entries top
/// to bottom visits every index of `a` once, and the `Keep` and `Insert`
/// entries do the same for `b`.
///
/// Runs in O((N+M)·D) time and O(N+M) extra space.
pub fn diff<T: Eq + Hash>(a: &[T], b: &[T]) -> Vec<Edit> {
    let mut interner = Interner::new();
    let ia = interner.intern_all(a);
    let ib = interner.intern_all(b);
    myers::diff_ids(&ia, &ib)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::cost;

    #[test]
    fn paper_example() {
        let a: Vec<char> = "abcabba".chars().collect();
        let b: Vec<char> = "cbabac".chars().collect();
        assert_eq!(cost(&diff(&a, &b)), 5);
    }

    #[test]
    fn identical_is_all_keeps() {
        let a = ["p", "q"];
        let e = diff(&a, &a);
        assert_eq!(
            e,
            vec![Edit::Keep { a: 0, b: 0 }, Edit::Keep { a: 1, b: 1 }]
        );
    }
}
