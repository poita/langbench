//! The 64-bit xorshift* generator of SPEC.md section 25.

const MULT: u64 = 0x2545_F491_4F6C_DD1D;

/// Deterministic pseudo-random number generator.
#[derive(Debug, Clone)]
pub struct Rng {
    state: u64,
}

impl Rng {
    /// Seed the generator. A zero seed is replaced by the multiplier constant.
    pub fn new(seed: u64) -> Rng {
        Rng {
            state: if seed == 0 { MULT } else { seed },
        }
    }

    /// The next raw 64-bit value.
    pub fn next_u64(&mut self) -> u64 {
        let mut s = self.state;
        s ^= s >> 12;
        s ^= s << 25;
        s ^= s >> 27;
        self.state = s;
        s.wrapping_mul(MULT)
    }

    /// A value in `0..n` (`n >= 1`).
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64() % n
    }

    /// Fisher–Yates shuffle as specified: lists of length 0 or 1 consume nothing.
    pub fn shuffle<T>(&mut self, items: &mut [T]) {
        let k = items.len();
        for i in (1..k).rev() {
            let j = self.below(i as u64 + 1) as usize;
            items.swap(i, j);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_reference_stream() {
        let mut r = Rng::new(7);
        let got: Vec<u64> = (0..5).map(|_| r.next_u64()).collect();
        assert_eq!(
            got,
            vec![
                15130880334998875822,
                17123930943180875438,
                1648209070578717474,
                1985375592982671918,
                6908966637734145041
            ]
        );
    }

    #[test]
    fn zero_seed_and_short_shuffles() {
        let mut a = Rng::new(0);
        let mut b = Rng::new(MULT);
        assert_eq!(a.next_u64(), b.next_u64());
        let mut r = Rng::new(1);
        let before = r.clone().next_u64();
        let mut one = [1];
        r.shuffle(&mut one);
        let mut none: [i32; 0] = [];
        r.shuffle(&mut none);
        assert_eq!(r.next_u64(), before);
    }
}
