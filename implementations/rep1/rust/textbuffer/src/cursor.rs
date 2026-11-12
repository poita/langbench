//! Cursors, selections and the normalization that merges colliding cursors.

use crate::position::Position;
use std::cmp::Reverse;

/// A caret with an optional selection.
///
/// The anchor, when present, is never equal to the head: a cursor whose
/// anchor would coincide with its head has no selection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cursor {
    /// Where the caret is.
    pub head: Position,
    /// The other end of the selection, if any.
    pub anchor: Option<Position>,
    /// Exactly one cursor of a buffer is primary.
    pub primary: bool,
    /// Column that `move up` / `move down` aim for.
    pub goal: usize,
}

impl Cursor {
    /// A cursor without a selection at `head`, with the goal column of `head`.
    pub fn at(head: Position, primary: bool) -> Self {
        Cursor {
            head,
            anchor: None,
            primary,
            goal: head.col,
        }
    }

    /// Whether the cursor has a (non-empty) selection.
    #[inline]
    pub fn has_selection(&self) -> bool {
        self.anchor.is_some()
    }

    /// The start of the range: the smaller of head and anchor.
    #[inline]
    pub fn start(&self) -> Position {
        match self.anchor {
            Some(a) => a.min(self.head),
            None => self.head,
        }
    }

    /// The end of the range: the larger of head and anchor.
    #[inline]
    pub fn end(&self) -> Position {
        match self.anchor {
            Some(a) => a.max(self.head),
            None => self.head,
        }
    }

    /// Whether the selection is backward (head before anchor).
    #[inline]
    pub fn is_backward(&self) -> bool {
        matches!(self.anchor, Some(a) if self.head < a)
    }

    /// Sets the selection from a range and a direction. An empty range gives
    /// a cursor without selection.
    fn with_range(mut self, start: Position, end: Position, backward: bool) -> Self {
        if start == end {
            self.head = start;
            self.anchor = None;
        } else if backward {
            self.head = start;
            self.anchor = Some(end);
        } else {
            self.head = end;
            self.anchor = Some(start);
        }
        self
    }
}

/// Whether `next` (the cursor after `cur` in sorted order) merges into the
/// group whose merged cursor is `cur`.
#[inline]
fn joins(cur: &Cursor, next: &Cursor) -> bool {
    if cur.has_selection() && next.has_selection() {
        next.start() < cur.end()
    } else {
        next.start() <= cur.end()
    }
}

/// Sorts cursors into cursor order and merges colliding ones.
///
/// Cursors are sorted by range start ascending, then range end descending,
/// keeping the existing order of cursors with identical ranges (the sort is
/// stable). A sweep then merges every cursor that overlaps the current
/// group: a point cursor merges when it lies within (or on the edge of)
/// another range; two selections merge only when they overlap, not when they
/// merely touch. A merged cursor spans the union of the ranges, keeps the
/// direction and goal column of the first cursor of the group and is primary
/// if any member was.
///
/// The common case, cursors already ordered and separate, costs one linear
/// check; otherwise the cost is `O(C log C)`.
pub fn normalize(cursors: &mut Vec<Cursor>) {
    if cursors
        .windows(2)
        .all(|w| !joins(&w[0], &w[1]) && w[0].start() < w[1].start())
    {
        return;
    }
    cursors.sort_by_key(|c| (c.start(), Reverse(c.end())));
    let mut out: Vec<Cursor> = Vec::with_capacity(cursors.len());
    for &c in cursors.iter() {
        match out.last_mut() {
            Some(cur) if joins(cur, &c) => {
                let start = cur.start();
                let end = cur.end().max(c.end());
                let primary = cur.primary || c.primary;
                let backward = cur.is_backward();
                *cur = cur.with_range(start, end, backward);
                cur.primary = primary;
            }
            _ => out.push(c),
        }
    }
    *cursors = out;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(l: usize, c: usize) -> Position {
        Position::new(l, c)
    }

    fn point(l: usize, c: usize, primary: bool) -> Cursor {
        Cursor::at(p(l, c), primary)
    }

    fn sel(anchor: Position, head: Position) -> Cursor {
        Cursor {
            head,
            anchor: Some(anchor),
            primary: false,
            goal: head.col,
        }
    }

    #[test]
    fn range_of_forward_and_backward_selection() {
        let f = sel(p(0, 1), p(0, 4));
        assert_eq!(
            (f.start(), f.end(), f.is_backward()),
            (p(0, 1), p(0, 4), false)
        );
        let b = sel(p(0, 4), p(0, 1));
        assert_eq!(
            (b.start(), b.end(), b.is_backward()),
            (p(0, 1), p(0, 4), true)
        );
        let c = point(1, 1, true);
        assert_eq!(
            (c.start(), c.end(), c.has_selection()),
            (p(1, 1), p(1, 1), false)
        );
    }

    #[test]
    fn sorts_by_start() {
        let mut v = vec![point(2, 0, false), point(0, 5, true), point(1, 1, false)];
        normalize(&mut v);
        let heads: Vec<_> = v.iter().map(|c| c.head).collect();
        assert_eq!(heads, vec![p(0, 5), p(1, 1), p(2, 0)]);
    }

    #[test]
    fn equal_points_merge_and_keep_primary() {
        let mut v = vec![point(0, 1, false), point(0, 1, true)];
        v[0].goal = 7;
        normalize(&mut v);
        assert_eq!(v.len(), 1);
        assert!(v[0].primary);
        assert_eq!(v[0].goal, 7, "first cursor's goal wins");
    }

    #[test]
    fn point_inside_or_on_edge_of_selection_merges() {
        for col in [1, 2, 4] {
            let mut v = vec![sel(p(0, 1), p(0, 4)), point(0, col, false)];
            normalize(&mut v);
            assert_eq!(v.len(), 1, "col {col}");
            assert_eq!((v[0].start(), v[0].end()), (p(0, 1), p(0, 4)));
        }
        let mut v = vec![sel(p(0, 1), p(0, 4)), point(0, 5, false)];
        normalize(&mut v);
        assert_eq!(v.len(), 2);
    }

    #[test]
    fn touching_selections_do_not_merge_but_overlapping_do() {
        let mut v = vec![sel(p(0, 1), p(0, 3)), sel(p(0, 3), p(0, 5))];
        normalize(&mut v);
        assert_eq!(v.len(), 2);
        let mut v = vec![sel(p(0, 1), p(0, 4)), sel(p(0, 3), p(0, 5))];
        normalize(&mut v);
        assert_eq!(v.len(), 1);
        assert_eq!((v[0].start(), v[0].end()), (p(0, 1), p(0, 5)));
        assert_eq!(v[0].head, p(0, 5), "forward direction kept");
    }

    #[test]
    fn merged_selection_keeps_direction_of_first_in_sorted_order() {
        let mut v = vec![sel(p(0, 4), p(0, 1)), sel(p(0, 3), p(0, 6))];
        normalize(&mut v);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].head, p(0, 1));
        assert_eq!(v[0].anchor, Some(p(0, 6)));
    }

    #[test]
    fn equal_start_longer_range_sorts_first() {
        let mut v = vec![point(0, 1, true), sel(p(0, 1), p(0, 4))];
        normalize(&mut v);
        assert_eq!(v.len(), 1);
        assert!(v[0].has_selection());
        assert!(v[0].primary);
    }

    #[test]
    fn identical_ranges_keep_prior_order() {
        let mut a = point(0, 2, false);
        a.goal = 1;
        let mut b = point(0, 2, false);
        b.goal = 2;
        let mut v = vec![b, a];
        normalize(&mut v);
        assert_eq!(v[0].goal, 2);
    }
}
