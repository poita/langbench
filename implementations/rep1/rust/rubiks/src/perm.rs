//! Small combinatorial helpers: permutation ranking and subset ranking.

/// Lehmer-code rank of a permutation of `0..p.len()` in `0..p.len()!`
/// (the identity has rank 0).
pub fn rank(p: &[u8]) -> usize {
    let n = p.len();
    let mut r = 0;
    for i in 0..n {
        let smaller = p[i + 1..].iter().filter(|&&x| x < p[i]).count();
        r = r * (n - i) + smaller;
    }
    r
}

/// Inverse of [`rank`]: the permutation of `0..n` with the given rank.
pub fn unrank(n: usize, mut r: usize) -> Vec<u8> {
    let mut digits = vec![0usize; n];
    for i in (0..n).rev() {
        let base = n - i;
        digits[i] = r % base;
        r /= base;
    }
    let mut pool: Vec<u8> = (0..n as u8).collect();
    digits.iter().map(|&d| pool.remove(d)).collect()
}

/// Number of inversions modulo 2 (0 for even permutations).
pub fn parity(p: &[u8]) -> u8 {
    let mut inv = 0;
    for i in 0..p.len() {
        inv += p[i + 1..].iter().filter(|&&x| x < p[i]).count();
    }
    (inv % 2) as u8
}

/// Ranking of the `k`-element subsets of `n` positions, represented as
/// bit masks, in increasing numeric order of the mask.
#[derive(Clone, Debug)]
pub struct Subsets {
    rank_of_mask: Vec<u16>,
    mask_of_rank: Vec<u16>,
}

impl Subsets {
    /// Builds the ranking for `k`-subsets of `n` positions (`n <= 16`).
    pub fn new(n: u32, k: u32) -> Subsets {
        let mut rank_of_mask = vec![u16::MAX; 1 << n];
        let mut mask_of_rank = Vec::new();
        for mask in 0..(1u32 << n) {
            if mask.count_ones() == k {
                rank_of_mask[mask as usize] = mask_of_rank.len() as u16;
                mask_of_rank.push(mask as u16);
            }
        }
        Subsets { rank_of_mask, mask_of_rank }
    }

    /// Number of subsets, `C(n, k)`.
    pub fn len(&self) -> usize {
        self.mask_of_rank.len()
    }

    /// Whether there are no subsets.
    pub fn is_empty(&self) -> bool {
        self.mask_of_rank.is_empty()
    }

    /// Rank of a mask with exactly `k` bits set.
    pub fn rank(&self, mask: u32) -> usize {
        let r = self.rank_of_mask[mask as usize];
        debug_assert!(r != u16::MAX);
        r as usize
    }

    /// The mask with the given rank.
    pub fn mask(&self, rank: usize) -> u32 {
        self.mask_of_rank[rank] as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rank_unrank_round_trip() {
        for n in 1..=5 {
            let total: usize = (1..=n).product();
            for r in 0..total {
                let p = unrank(n, r);
                assert_eq!(rank(&p), r);
            }
        }
        assert_eq!(rank(&[0, 1, 2, 3]), 0);
        assert_eq!(rank(&[3, 2, 1, 0]), 23);
    }

    #[test]
    fn parity_of_swap() {
        assert_eq!(parity(&[0, 1, 2]), 0);
        assert_eq!(parity(&[1, 0, 2]), 1);
        assert_eq!(parity(&[1, 2, 0]), 0);
    }

    #[test]
    fn subsets() {
        let s = Subsets::new(12, 4);
        assert_eq!(s.len(), 495);
        for r in 0..s.len() {
            assert_eq!(s.rank(s.mask(r)), r);
        }
        assert_eq!(Subsets::new(8, 4).len(), 70);
    }
}
