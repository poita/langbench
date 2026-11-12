//! Myers' O(ND) difference algorithm, linear-space variant.
//!
//! This is the "middle snake" divide-and-conquer form from section 4b of
//! Myers, *An O(ND) Difference Algorithm and Its Variations* (1986). A
//! forward search from the start and a backward search from the end run
//! simultaneously, one round at a time, until they overlap. The overlap is a
//! point on some shortest edit path; the problem is split there and both
//! halves are solved recursively. Common prefixes and suffixes are trimmed
//! before each search.
//!
//! No frontier is saved per round, so the working space is two arrays of
//! N+M+3 entries and the recursion depth is O(log D). The result is exact:
//! there is no cost limit and no heuristic.

use crate::edit::Edit;

/// Computes a shortest edit script between two integer sequences.
pub fn diff_ids(a: &[u32], b: &[u32]) -> Vec<Edit> {
    let size = a.len() + b.len() + 3;
    let mut s = Search {
        a,
        b,
        fd: vec![0; size],
        bd: vec![0; size],
        off: b.len() as isize + 1,
        out: Vec::with_capacity(a.len().max(b.len())),
    };
    s.solve(0, a.len(), 0, b.len());
    s.out
}

struct Search<'a> {
    a: &'a [u32],
    b: &'a [u32],
    /// Forward frontier: furthest x reached on each diagonal `x - y`.
    fd: Vec<isize>,
    /// Backward frontier: smallest x reached on each diagonal.
    bd: Vec<isize>,
    /// Added to a diagonal number to get an array index.
    off: isize,
    out: Vec<Edit>,
}

impl Search<'_> {
    /// Emits the edits for `a[alo..ahi]` against `b[blo..bhi]`, in order.
    fn solve(&mut self, mut alo: usize, mut ahi: usize, mut blo: usize, mut bhi: usize) {
        // Common prefix: emitted now.
        while alo < ahi && blo < bhi && self.a[alo] == self.b[blo] {
            self.out.push(Edit::Keep { a: alo, b: blo });
            alo += 1;
            blo += 1;
        }
        // Common suffix: emitted after the middle.
        let mut suffix = 0;
        while alo < ahi && blo < bhi && self.a[ahi - 1] == self.b[bhi - 1] {
            ahi -= 1;
            bhi -= 1;
            suffix += 1;
        }

        if alo == ahi {
            for j in blo..bhi {
                self.out.push(Edit::Insert { b: j });
            }
        } else if blo == bhi {
            for i in alo..ahi {
                self.out.push(Edit::Delete { a: i });
            }
        } else {
            let (x, y) = self.middle_snake(alo, ahi, blo, bhi);
            self.solve(alo, x, blo, y);
            self.solve(x, ahi, y, bhi);
        }

        for k in 0..suffix {
            self.out.push(Edit::Keep {
                a: ahi + k,
                b: bhi + k,
            });
        }
    }

    /// Finds a point `(x, y)` on a shortest path through the (non-trivial,
    /// trimmed) box `a[xoff..xlim] × b[yoff..ylim]`, where the forward and
    /// backward searches meet.
    fn middle_snake(&mut self, xoff: usize, xlim: usize, yoff: usize, ylim: usize) -> (usize, usize) {
        let (xoff, xlim, yoff, ylim) = (xoff as isize, xlim as isize, yoff as isize, ylim as isize);
        let off = self.off;
        let (a, b) = (self.a, self.b);

        let dmin = xoff - ylim;
        let dmax = xlim - yoff;
        let fmid = xoff - yoff;
        let bmid = xlim - ylim;
        let odd = (fmid - bmid) & 1 != 0;
        let (mut fmin, mut fmax) = (fmid, fmid);
        let (mut bmin, mut bmax) = (bmid, bmid);

        let ix = |d: isize| (d + off) as usize;
        self.fd[ix(fmid)] = xoff;
        self.bd[ix(bmid)] = xlim;

        loop {
            // Forward round: extend the frontier by one edit.
            if fmin > dmin {
                fmin -= 1;
                self.fd[ix(fmin - 1)] = -1;
            } else {
                fmin += 1;
            }
            if fmax < dmax {
                fmax += 1;
                self.fd[ix(fmax + 1)] = -1;
            } else {
                fmax -= 1;
            }
            let mut d = fmax;
            while d >= fmin {
                let tlo = self.fd[ix(d - 1)];
                let thi = self.fd[ix(d + 1)];
                let mut x = if tlo >= thi { tlo + 1 } else { thi };
                let mut y = x - d;
                while x < xlim && y < ylim && a[x as usize] == b[y as usize] {
                    x += 1;
                    y += 1;
                }
                self.fd[ix(d)] = x;
                if odd && bmin <= d && d <= bmax && self.bd[ix(d)] <= x {
                    return (x as usize, y as usize);
                }
                d -= 2;
            }

            // Backward round.
            if bmin > dmin {
                bmin -= 1;
                self.bd[ix(bmin - 1)] = isize::MAX;
            } else {
                bmin += 1;
            }
            if bmax < dmax {
                bmax += 1;
                self.bd[ix(bmax + 1)] = isize::MAX;
            } else {
                bmax -= 1;
            }
            let mut d = bmax;
            while d >= bmin {
                let tlo = self.bd[ix(d - 1)];
                let thi = self.bd[ix(d + 1)];
                let mut x = if tlo < thi { tlo } else { thi - 1 };
                let mut y = x - d;
                while x > xoff && y > yoff && a[(x - 1) as usize] == b[(y - 1) as usize] {
                    x -= 1;
                    y -= 1;
                }
                self.bd[ix(d)] = x;
                if !odd && fmin <= d && d <= fmax && x <= self.fd[ix(d)] {
                    return (x as usize, y as usize);
                }
                d -= 2;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::cost;

    /// Reference LCS length by dynamic programming (tests only).
    fn lcs(a: &[u32], b: &[u32]) -> usize {
        let mut prev = vec![0usize; b.len() + 1];
        for &x in a {
            let mut cur = vec![0usize; b.len() + 1];
            for (j, &y) in b.iter().enumerate() {
                cur[j + 1] = if x == y {
                    prev[j] + 1
                } else {
                    prev[j + 1].max(cur[j])
                };
            }
            prev = cur;
        }
        prev[b.len()]
    }

    fn check(a: &[u32], b: &[u32]) {
        let e = diff_ids(a, b);
        let (mut ra, mut rb) = (Vec::new(), Vec::new());
        for op in &e {
            match *op {
                Edit::Keep { a: i, b: j } => {
                    assert_eq!(a[i], b[j]);
                    assert_eq!(ra.len(), i);
                    assert_eq!(rb.len(), j);
                    ra.push(a[i]);
                    rb.push(b[j]);
                }
                Edit::Delete { a: i } => {
                    assert_eq!(ra.len(), i);
                    ra.push(a[i]);
                }
                Edit::Insert { b: j } => {
                    assert_eq!(rb.len(), j);
                    rb.push(b[j]);
                }
            }
        }
        assert_eq!(ra, a);
        assert_eq!(rb, b);
        assert_eq!(cost(&e), a.len() + b.len() - 2 * lcs(a, b), "{a:?} {b:?}");
    }

    #[test]
    fn empty_cases() {
        check(&[], &[]);
        check(&[1, 2], &[]);
        check(&[], &[1, 2]);
    }

    #[test]
    fn small_exhaustive() {
        // Every pair of sequences over {0,1,2} up to length 5.
        let mut all: Vec<Vec<u32>> = vec![vec![]];
        let mut frontier = vec![vec![]];
        for _ in 0..5 {
            let mut next = Vec::new();
            for s in &frontier {
                for c in 0..3 {
                    let mut t: Vec<u32> = s.clone();
                    t.push(c);
                    next.push(t);
                }
            }
            all.extend(next.iter().cloned());
            frontier = next;
        }
        for a in all.iter().step_by(3) {
            for b in &all {
                check(a, b);
            }
        }
    }
}
