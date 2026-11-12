//! The cubie model: permutation and orientation of corners and edges.
//!
//! Corner positions/cubies are numbered `URF UFL ULB UBR DFR DLF DBL DRB`
//! (0..8) and edge positions/cubies `UR UF UL UB DR DF DL DB FR FL BL BR`
//! (0..12), matching the order of the cubies in the specification.
//!
//! `cp[i]` is the cubie sitting at corner position `i` and `co[i]` its twist
//! (the index, within the position's clockwise facelet triple, of the facelet
//! carrying the cubie's U/D colour). `ep`/`eo` are the same for edges, with
//! flip 0/1. The quarter turns of `R L F B` change corner twists, and only
//! `F B` quarter turns change edge flips.

use crate::facelet::{layout, FaceletCube};
use crate::moves::Move;
use crate::perm;
use std::fmt;
use std::sync::OnceLock;

/// Why a cube description is invalid or unsolvable.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CubeError {
    /// The stickers do not form eight corner and twelve edge cubies.
    BadFacelets,
    /// `cp` or `ep` is not a permutation, or a twist/flip is out of range.
    BadCubies,
    /// The corner twists do not sum to a multiple of 3.
    TwistedCorner,
    /// The edge flips do not sum to an even number.
    FlippedEdge,
    /// Corner and edge permutations have different parity.
    ParityMismatch,
}

impl fmt::Display for CubeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            CubeError::BadFacelets => "facelets do not describe a physical cube",
            CubeError::BadCubies => "invalid cubie permutation or orientation",
            CubeError::TwistedCorner => "corner twists do not sum to 0 mod 3",
            CubeError::FlippedEdge => "edge flips do not sum to 0 mod 2",
            CubeError::ParityMismatch => "corner and edge permutation parities differ",
        })
    }
}

impl std::error::Error for CubeError {}

/// A cube state at cubie level.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct CubieCube {
    /// Cubie at each corner position.
    pub cp: [u8; 8],
    /// Twist (0..3) of the cubie at each corner position.
    pub co: [u8; 8],
    /// Cubie at each edge position.
    pub ep: [u8; 12],
    /// Flip (0..2) of the cubie at each edge position.
    pub eo: [u8; 12],
}

impl CubieCube {
    /// The solved cube.
    pub const SOLVED: CubieCube = CubieCube {
        cp: [0, 1, 2, 3, 4, 5, 6, 7],
        co: [0; 8],
        ep: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
        eo: [0; 12],
    };

    /// The state of a solved cube after the single move `m`.
    pub fn from_move(m: Move) -> &'static CubieCube {
        &move_cubes()[m.index()]
    }

    /// The state after performing `other`'s permutation on top of `self`
    /// (`self` first, then `other`).
    pub fn then(&self, other: &CubieCube) -> CubieCube {
        let mut r = *self;
        for i in 0..8 {
            let j = other.cp[i] as usize;
            r.cp[i] = self.cp[j];
            r.co[i] = (self.co[j] + other.co[i]) % 3;
        }
        for i in 0..12 {
            let j = other.ep[i] as usize;
            r.ep[i] = self.ep[j];
            r.eo[i] = self.eo[j] ^ other.eo[i];
        }
        r
    }

    /// Applies one move.
    pub fn apply(&self, m: Move) -> CubieCube {
        self.then(CubieCube::from_move(m))
    }

    /// Applies a sequence of moves left to right.
    pub fn apply_all(&self, moves: &[Move]) -> CubieCube {
        moves.iter().fold(*self, |c, &m| c.apply(m))
    }

    /// Whether every cubie is in place and correctly oriented.
    pub fn is_solved(&self) -> bool {
        *self == CubieCube::SOLVED
    }

    /// Checks that this is a reachable (solvable) cube state.
    pub fn verify(&self) -> Result<(), CubeError> {
        let mut seen = [false; 12];
        for &c in &self.cp {
            if c >= 8 || std::mem::replace(&mut seen[c as usize], true) {
                return Err(CubeError::BadCubies);
            }
        }
        seen = [false; 12];
        for &e in &self.ep {
            if e >= 12 || std::mem::replace(&mut seen[e as usize], true) {
                return Err(CubeError::BadCubies);
            }
        }
        if self.co.iter().any(|&o| o >= 3) || self.eo.iter().any(|&o| o >= 2) {
            return Err(CubeError::BadCubies);
        }
        if self.co.iter().map(|&o| o as u32).sum::<u32>() % 3 != 0 {
            return Err(CubeError::TwistedCorner);
        }
        if self.eo.iter().map(|&o| o as u32).sum::<u32>() % 2 != 0 {
            return Err(CubeError::FlippedEdge);
        }
        if perm::parity(&self.cp) != perm::parity(&self.ep) {
            return Err(CubeError::ParityMismatch);
        }
        Ok(())
    }

    /// The same cube as a [`FaceletCube`].
    pub fn to_facelets(&self) -> FaceletCube {
        FaceletCube::from_cubie(self)
    }
}

impl Default for CubieCube {
    fn default() -> Self {
        CubieCube::SOLVED
    }
}

/// The cubie state of each of the 18 moves, derived from the facelet model.
fn move_cubes() -> &'static [CubieCube; 18] {
    static CUBES: OnceLock<[CubieCube; 18]> = OnceLock::new();
    CUBES.get_or_init(|| {
        let _ = layout();
        std::array::from_fn(|i| {
            FaceletCube::solved()
                .apply(Move::from_index(i))
                .to_cubie()
                .expect("a move of a solved cube is a valid cube")
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::moves::parse_moves;

    #[test]
    fn quarter_turn_orders() {
        for m in Move::ALL {
            let mut c = CubieCube::SOLVED;
            for _ in 0..4 {
                c = c.apply(m);
            }
            assert!(c.is_solved(), "{m}");
            assert_eq!(CubieCube::from_move(m).verify(), Ok(()));
        }
    }

    #[test]
    fn cubie_matches_facelets() {
        let seq = parse_moves("R U2 F' D L B' R2 U' F2 D' L2 B").unwrap();
        let mut c = CubieCube::SOLVED;
        let mut f = FaceletCube::solved();
        for m in seq {
            c = c.apply(m);
            f = f.apply(m);
            assert_eq!(c.to_facelets(), f);
            assert_eq!(f.to_cubie().unwrap(), c);
        }
    }

    #[test]
    fn invalid_cubes() {
        let mut c = CubieCube::SOLVED;
        c.co[0] = 1;
        assert_eq!(c.verify(), Err(CubeError::TwistedCorner));
        let mut c = CubieCube::SOLVED;
        c.eo[0] = 1;
        assert_eq!(c.verify(), Err(CubeError::FlippedEdge));
        let mut c = CubieCube::SOLVED;
        c.ep.swap(0, 1);
        assert_eq!(c.verify(), Err(CubeError::ParityMismatch));
    }
}
