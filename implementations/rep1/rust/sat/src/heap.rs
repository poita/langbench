//! Indexed binary max-heap of variables ordered by activity.

use crate::lit::Var;

const ABSENT: u32 = u32::MAX;

/// A priority queue of variables keyed by an external activity array.
///
/// Supports O(log n) insertion, removal of the maximum and key increase,
/// and O(1) membership tests.
#[derive(Default, Debug)]
pub struct VarHeap {
    heap: Vec<Var>,
    /// Position of each variable in `heap`, or `ABSENT`.
    pos: Vec<u32>,
}

impl VarHeap {
    /// Creates an empty heap.
    pub fn new() -> VarHeap {
        VarHeap::default()
    }

    /// Makes room for variable `v` (must be called for every variable
    /// before it is inserted).
    pub fn grow_to(&mut self, v: Var) {
        if self.pos.len() <= v.index() {
            self.pos.resize(v.index() + 1, ABSENT);
        }
    }

    /// True if `v` is currently queued.
    pub fn contains(&self, v: Var) -> bool {
        self.pos[v.index()] != ABSENT
    }

    /// Queues `v` if it is not already queued.
    pub fn insert(&mut self, v: Var, act: &[f64]) {
        if self.contains(v) {
            return;
        }
        let i = self.heap.len();
        self.pos[v.index()] = i as u32;
        self.heap.push(v);
        self.sift_up(i, act);
    }

    /// Restores heap order after `v`'s activity increased.
    pub fn increased(&mut self, v: Var, act: &[f64]) {
        if self.contains(v) {
            self.sift_up(self.pos[v.index()] as usize, act);
        }
    }

    /// Removes and returns the variable with the highest activity.
    pub fn pop_max(&mut self, act: &[f64]) -> Option<Var> {
        let top = *self.heap.first()?;
        let last = self.heap.pop().unwrap();
        self.pos[top.index()] = ABSENT;
        if !self.heap.is_empty() {
            self.heap[0] = last;
            self.pos[last.index()] = 0;
            self.sift_down(0, act);
        }
        Some(top)
    }

    fn sift_up(&mut self, mut i: usize, act: &[f64]) {
        let v = self.heap[i];
        while i > 0 {
            let parent = (i - 1) / 2;
            let p = self.heap[parent];
            if act[v.index()] <= act[p.index()] {
                break;
            }
            self.heap[i] = p;
            self.pos[p.index()] = i as u32;
            i = parent;
        }
        self.heap[i] = v;
        self.pos[v.index()] = i as u32;
    }

    fn sift_down(&mut self, mut i: usize, act: &[f64]) {
        let v = self.heap[i];
        let n = self.heap.len();
        loop {
            let mut child = 2 * i + 1;
            if child >= n {
                break;
            }
            if child + 1 < n && act[self.heap[child + 1].index()] > act[self.heap[child].index()] {
                child += 1;
            }
            let c = self.heap[child];
            if act[c.index()] <= act[v.index()] {
                break;
            }
            self.heap[i] = c;
            self.pos[c.index()] = i as u32;
            i = child;
        }
        self.heap[i] = v;
        self.pos[v.index()] = i as u32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pops_in_descending_activity_order() {
        let act = [0.5, 3.0, 1.0, 2.0, 4.0];
        let mut h = VarHeap::new();
        for i in 0..act.len() as u32 {
            h.grow_to(Var(i));
            h.insert(Var(i), &act);
        }
        let mut out = vec![];
        while let Some(v) = h.pop_max(&act) {
            out.push(v.0);
        }
        assert_eq!(out, vec![4, 1, 3, 2, 0]);
        assert_eq!(h.pop_max(&act), None);
    }

    #[test]
    fn increase_key_and_reinsert() {
        let mut act = vec![1.0, 2.0, 3.0];
        let mut h = VarHeap::new();
        for i in 0..3 {
            h.grow_to(Var(i));
            h.insert(Var(i), &act);
        }
        act[0] = 10.0;
        h.increased(Var(0), &act);
        assert_eq!(h.pop_max(&act), Some(Var(0)));
        assert!(!h.contains(Var(0)));
        h.insert(Var(0), &act);
        h.insert(Var(0), &act); // idempotent
        assert_eq!(h.pop_max(&act), Some(Var(0)));
        assert_eq!(h.pop_max(&act), Some(Var(2)));
    }
}
