//! Helpers shared by the integration tests.
#![allow(dead_code)]

use rubiks::{perm, CubieCube, Move, Solver};
use std::sync::OnceLock;

/// One solver (and its tables) shared by every test in a test binary.
pub fn solver() -> &'static Solver {
    static SOLVER: OnceLock<Solver> = OnceLock::new();
    SOLVER.get_or_init(Solver::new)
}

/// Small deterministic xorshift generator, so tests need no dependencies.
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    pub fn below(&mut self, n: usize) -> usize {
        (self.next() >> 11) as usize % n
    }
    pub fn moves(&mut self, n: usize) -> Vec<Move> {
        (0..n).map(|_| Move::from_index(self.below(18))).collect()
    }
    /// A uniformly random solvable cube state.
    pub fn cube(&mut self) -> CubieCube {
        let mut c = CubieCube::SOLVED;
        c.cp = perm::unrank(8, self.below(40320)).try_into().unwrap();
        c.ep = perm::unrank(12, self.below(479_001_600)).try_into().unwrap();
        if perm::parity(&c.cp) != perm::parity(&c.ep) {
            c.ep.swap(0, 1);
        }
        for i in 0..7 {
            c.co[i] = self.below(3) as u8;
        }
        c.co[7] = (3 - c.co[..7].iter().map(|&x| x as usize).sum::<usize>() % 3) as u8 % 3;
        for i in 0..11 {
            c.eo[i] = self.below(2) as u8;
        }
        c.eo[11] = c.eo[..11].iter().sum::<u8>() % 2;
        c.verify().unwrap();
        c
    }
}
