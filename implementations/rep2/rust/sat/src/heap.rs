//! Indexed binary max-heap of variables ordered by activity.
//!
//! This is the priority queue behind VSIDS branching. The heap does not own
//! the activity scores; callers pass the score slice to every operation that
//! needs to compare, which keeps the scores freely accessible elsewhere.

use crate::lit::Var;

const ABSENT: u32 = u32::MAX;

/// Max-heap of variables keyed by an external activity array.
#[derive(Default, Debug, Clone)]
pub struct VarHeap {
    heap: Vec<Var>,
    /// Position of each variable in `heap`, or `ABSENT`.
    pos: Vec<u32>,
}

impl VarHeap {
    /// Creates an empty heap.
    pub fn new() -> Self {
        Self::default()
    }

    /// Makes room for variable `v` (it is not inserted).
    pub fn grow_to(&mut self, v: Var) {
        if self.pos.len() <= v.index() {
            self.pos.resize(v.index() + 1, ABSENT);
        }
    }

    /// Returns `true` if the heap holds no variables.
    pub fn is_empty(&self) -> bool {
        self.heap.is_empty()
    }

    /// Returns `true` if `v` is currently in the heap.
    pub fn contains(&self, v: Var) -> bool {
        self.pos.get(v.index()).is_some_and(|&p| p != ABSENT)
    }

    /// Inserts `v` if it is not already present.
    pub fn insert(&mut self, v: Var, act: &[f64]) {
        self.grow_to(v);
        if self.contains(v) {
            return;
        }
        self.pos[v.index()] = self.heap.len() as u32;
        self.heap.push(v);
        self.sift_up(self.heap.len() - 1, act);
    }

    /// Restores heap order after the activity of `v` increased.
    pub fn increased(&mut self, v: Var, act: &[f64]) {
        if self.contains(v) {
            self.sift_up(self.pos[v.index()] as usize, act);
        }
    }

    /// Removes and returns the variable with the highest activity.
    pub fn pop_max(&mut self, act: &[f64]) -> Option<Var> {
        let top = *self.heap.first()?;
        let last = self.heap.pop().expect("non-empty");
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
            let l = 2 * i + 1;
            if l >= n {
                break;
            }
            let r = l + 1;
            let child = if r < n && act[self.heap[r].index()] > act[self.heap[l].index()] {
                r
            } else {
                l
            };
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
    fn pops_in_activity_order() {
        let act = vec![0.5, 3.0, 1.0, 2.0, 0.1];
        let mut h = VarHeap::new();
        for i in 0..act.len() {
            h.insert(Var(i as u32), &act);
        }
        let order: Vec<u32> = std::iter::from_fn(|| h.pop_max(&act)).map(|v| v.0).collect();
        assert_eq!(order, vec![1, 3, 2, 0, 4]);
        assert!(h.is_empty());
    }

    #[test]
    fn increase_reorders_and_insert_is_idempotent() {
        let mut act = vec![1.0, 2.0, 3.0];
        let mut h = VarHeap::new();
        for i in 0..3 {
            h.insert(Var(i), &act);
            h.insert(Var(i), &act);
        }
        act[0] = 10.0;
        h.increased(Var(0), &act);
        assert_eq!(h.pop_max(&act), Some(Var(0)));
        assert!(!h.contains(Var(0)));
        assert_eq!(h.pop_max(&act), Some(Var(2)));
        assert_eq!(h.pop_max(&act), Some(Var(1)));
        assert_eq!(h.pop_max(&act), None);
    }
}
