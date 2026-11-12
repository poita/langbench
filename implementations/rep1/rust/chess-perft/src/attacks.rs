//! Precomputed attack, ray and line tables, evaluated at compile time.
//!
//! Sliding attacks use the classical "ray + first blocker" technique: for each
//! of the eight directions a table of rays is indexed by square; the nearest
//! blocker is found with a bit scan and the ray beyond it is cut off.

use crate::bitboard::Bitboard;
use crate::types::{Color, Square};

/// Direction steps as (file delta, rank delta): N, NE, E, SE, S, SW, W, NW.
const STEPS: [(i32, i32); 8] =
    [(0, 1), (1, 1), (1, 0), (1, -1), (0, -1), (-1, -1), (-1, 0), (-1, 1)];

/// True for directions in which the square index increases along the ray.
const POSITIVE: [bool; 8] = [true, true, true, false, false, false, false, true];

const fn build_rays() -> [[u64; 64]; 8] {
    let mut rays = [[0u64; 64]; 8];
    let mut d = 0;
    while d < 8 {
        let mut sq = 0;
        while sq < 64 {
            let mut f = (sq % 8) as i32 + STEPS[d].0;
            let mut r = (sq / 8) as i32 + STEPS[d].1;
            while f >= 0 && f < 8 && r >= 0 && r < 8 {
                rays[d][sq] |= 1u64 << (r * 8 + f);
                f += STEPS[d].0;
                r += STEPS[d].1;
            }
            sq += 1;
        }
        d += 1;
    }
    rays
}

const fn build_leaper(deltas: [(i32, i32); 8]) -> [u64; 64] {
    let mut t = [0u64; 64];
    let mut sq = 0;
    while sq < 64 {
        let mut i = 0;
        while i < 8 {
            let f = (sq % 8) as i32 + deltas[i].0;
            let r = (sq / 8) as i32 + deltas[i].1;
            if f >= 0 && f < 8 && r >= 0 && r < 8 {
                t[sq] |= 1u64 << (r * 8 + f);
            }
            i += 1;
        }
        sq += 1;
    }
    t
}

const fn build_pawn() -> [[u64; 64]; 2] {
    let mut t = [[0u64; 64]; 2];
    let mut sq = 0;
    while sq < 64 {
        let (f, r) = ((sq % 8) as i32, (sq / 8) as i32);
        let mut c = 0;
        while c < 2 {
            let nr = if c == 0 { r + 1 } else { r - 1 };
            if nr >= 0 && nr < 8 {
                if f > 0 {
                    t[c][sq] |= 1u64 << (nr * 8 + f - 1);
                }
                if f < 7 {
                    t[c][sq] |= 1u64 << (nr * 8 + f + 1);
                }
            }
            c += 1;
        }
        sq += 1;
    }
    t
}

/// Builds the (BETWEEN, LINE) tables from the rays.
const fn build_between_line() -> ([[u64; 64]; 64], [[u64; 64]; 64]) {
    let mut between = [[0u64; 64]; 64];
    let mut line = [[0u64; 64]; 64];
    let mut a = 0;
    while a < 64 {
        let mut d = 0;
        while d < 8 {
            let ray = RAYS[d][a];
            let mut b = 0;
            while b < 64 {
                if ray >> b & 1 != 0 {
                    between[a][b] = ray & !RAYS[d][b] & !(1u64 << b);
                    line[a][b] = ray | RAYS[(d + 4) % 8][a] | (1u64 << a);
                }
                b += 1;
            }
            d += 1;
        }
        a += 1;
    }
    (between, line)
}

static RAYS: [[u64; 64]; 8] = build_rays();
static KNIGHT: [u64; 64] = build_leaper([
    (1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2),
]);
static KING: [u64; 64] = build_leaper(STEPS);
static PAWN: [[u64; 64]; 2] = build_pawn();
static BETWEEN: [[u64; 64]; 64] = build_between_line().0;
static LINE: [[u64; 64]; 64] = build_between_line().1;

#[inline]
fn ray_attacks(dir: usize, sq: usize, occ: u64) -> u64 {
    let ray = RAYS[dir][sq];
    let blockers = ray & occ;
    if blockers == 0 {
        return ray;
    }
    let first = if POSITIVE[dir] {
        blockers.trailing_zeros()
    } else {
        63 - blockers.leading_zeros()
    };
    ray ^ RAYS[dir][first as usize]
}

/// Squares a knight on `sq` attacks.
#[inline]
pub fn knight_attacks(sq: Square) -> Bitboard {
    Bitboard(KNIGHT[sq.index()])
}

/// Squares a king on `sq` attacks.
#[inline]
pub fn king_attacks(sq: Square) -> Bitboard {
    Bitboard(KING[sq.index()])
}

/// Squares a pawn of `color` on `sq` attacks (its two diagonal captures).
#[inline]
pub fn pawn_attacks(color: Color, sq: Square) -> Bitboard {
    Bitboard(PAWN[color.index()][sq.index()])
}

/// Squares a bishop on `sq` attacks given the occupancy `occ`.
///
/// Blockers are included in the result; the caller masks out own pieces.
#[inline]
pub fn bishop_attacks(sq: Square, occ: Bitboard) -> Bitboard {
    let (s, o) = (sq.index(), occ.0);
    Bitboard(ray_attacks(1, s, o) | ray_attacks(3, s, o) | ray_attacks(5, s, o) | ray_attacks(7, s, o))
}

/// Squares a rook on `sq` attacks given the occupancy `occ`.
#[inline]
pub fn rook_attacks(sq: Square, occ: Bitboard) -> Bitboard {
    let (s, o) = (sq.index(), occ.0);
    Bitboard(ray_attacks(0, s, o) | ray_attacks(2, s, o) | ray_attacks(4, s, o) | ray_attacks(6, s, o))
}

/// Squares a queen on `sq` attacks given the occupancy `occ`.
#[inline]
pub fn queen_attacks(sq: Square, occ: Bitboard) -> Bitboard {
    bishop_attacks(sq, occ) | rook_attacks(sq, occ)
}

/// Squares strictly between `a` and `b` if they share a rank, file or
/// diagonal; empty otherwise.
#[inline]
pub fn between(a: Square, b: Square) -> Bitboard {
    Bitboard(BETWEEN[a.index()][b.index()])
}

/// The whole rank, file or diagonal through `a` and `b` (including both) if
/// they are aligned; empty otherwise.
#[inline]
pub fn line(a: Square, b: Square) -> Bitboard {
    Bitboard(LINE[a.index()][b.index()])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sq(s: &str) -> Square {
        Square::parse(s).unwrap()
    }

    #[test]
    fn leaper_counts() {
        assert_eq!(knight_attacks(sq("a1")).count(), 2);
        assert_eq!(knight_attacks(sq("d4")).count(), 8);
        assert_eq!(king_attacks(sq("a1")).count(), 3);
        assert_eq!(king_attacks(sq("e4")).count(), 8);
        assert_eq!(pawn_attacks(Color::White, sq("a2")).count(), 1);
        assert_eq!(pawn_attacks(Color::Black, sq("e7")).count(), 2);
        assert_eq!(pawn_attacks(Color::White, sq("e8")).count(), 0);
    }

    #[test]
    fn slider_counts_on_empty_board() {
        assert_eq!(rook_attacks(sq("d4"), Bitboard::EMPTY).count(), 14);
        assert_eq!(bishop_attacks(sq("d4"), Bitboard::EMPTY).count(), 13);
        assert_eq!(queen_attacks(sq("a1"), Bitboard::EMPTY).count(), 21);
    }

    #[test]
    fn sliders_stop_at_blockers() {
        let occ = Bitboard::from(sq("d6")) | Bitboard::from(sq("b4")) | Bitboard::from(sq("d2"));
        let att = rook_attacks(sq("d4"), occ);
        assert!(att.contains(sq("d6")) && !att.contains(sq("d7")));
        assert!(att.contains(sq("b4")) && !att.contains(sq("a4")));
        assert!(att.contains(sq("d2")) && !att.contains(sq("d1")));
        assert!(att.contains(sq("h4")));
    }

    #[test]
    fn between_and_line() {
        assert_eq!(between(sq("a1"), sq("a4")).count(), 2);
        assert!(between(sq("a1"), sq("a4")).contains(sq("a3")));
        assert_eq!(between(sq("a1"), sq("h8")).count(), 6);
        assert!(between(sq("a1"), sq("b3")).is_empty());
        assert!(between(sq("a1"), sq("a2")).is_empty());
        assert_eq!(line(sq("c3"), sq("e5")).count(), 8);
        assert!(line(sq("c3"), sq("d5")).is_empty());
        assert!(line(sq("a1"), sq("a8")).contains(sq("a5")));
    }
}
