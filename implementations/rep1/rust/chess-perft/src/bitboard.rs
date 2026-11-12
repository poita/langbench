//! A 64-bit set of squares.

use crate::types::Square;
use std::fmt;
use std::ops::{BitAnd, BitAndAssign, BitOr, BitOrAssign, BitXor, BitXorAssign, Not};

/// A set of squares stored as a 64-bit mask (bit `i` is square index `i`).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Bitboard(pub u64);

impl Bitboard {
    /// The empty set.
    pub const EMPTY: Bitboard = Bitboard(0);
    /// The set of all 64 squares.
    pub const FULL: Bitboard = Bitboard(!0);

    /// The set containing only `sq`.
    #[inline]
    pub const fn from_square(sq: Square) -> Bitboard {
        Bitboard(1u64 << sq.index())
    }

    /// True if the set is empty.
    #[inline]
    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// True if the set has at least one square.
    #[inline]
    pub const fn any(self) -> bool {
        self.0 != 0
    }

    /// Number of squares in the set.
    #[inline]
    pub const fn count(self) -> u32 {
        self.0.count_ones()
    }

    /// True if `sq` is in the set.
    #[inline]
    pub const fn contains(self, sq: Square) -> bool {
        self.0 >> sq.index() & 1 != 0
    }

    /// The lowest-numbered square in the set, if any.
    #[inline]
    pub const fn lsb(self) -> Option<Square> {
        if self.0 == 0 { None } else { Some(Square::from_index(self.0.trailing_zeros() as usize)) }
    }
}

impl From<Square> for Bitboard {
    #[inline]
    fn from(sq: Square) -> Bitboard {
        Bitboard::from_square(sq)
    }
}

/// Iterator over the squares of a [`Bitboard`], lowest index first.
#[derive(Clone, Copy)]
pub struct Squares(u64);

impl Iterator for Squares {
    type Item = Square;

    #[inline]
    fn next(&mut self) -> Option<Square> {
        if self.0 == 0 {
            return None;
        }
        let i = self.0.trailing_zeros() as usize;
        self.0 &= self.0 - 1;
        Some(Square::from_index(i))
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let n = self.0.count_ones() as usize;
        (n, Some(n))
    }
}

impl IntoIterator for Bitboard {
    type Item = Square;
    type IntoIter = Squares;

    #[inline]
    fn into_iter(self) -> Squares {
        Squares(self.0)
    }
}

macro_rules! bit_op {
    ($tr:ident, $f:ident, $atr:ident, $af:ident, $op:tt) => {
        impl $tr for Bitboard {
            type Output = Bitboard;
            #[inline]
            fn $f(self, rhs: Bitboard) -> Bitboard {
                Bitboard(self.0 $op rhs.0)
            }
        }
        impl $atr for Bitboard {
            #[inline]
            fn $af(&mut self, rhs: Bitboard) {
                self.0 = self.0 $op rhs.0;
            }
        }
    };
}
bit_op!(BitAnd, bitand, BitAndAssign, bitand_assign, &);
bit_op!(BitOr, bitor, BitOrAssign, bitor_assign, |);
bit_op!(BitXor, bitxor, BitXorAssign, bitxor_assign, ^);

impl Not for Bitboard {
    type Output = Bitboard;
    #[inline]
    fn not(self) -> Bitboard {
        Bitboard(!self.0)
    }
}

impl fmt::Debug for Bitboard {
    /// Prints an 8x8 diagram, rank 8 on top.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f)?;
        for rank in (0..8).rev() {
            for file in 0..8 {
                let c = if self.contains(Square::new(file, rank)) { 'X' } else { '.' };
                write!(f, "{c}")?;
            }
            writeln!(f)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_ops() {
        let a = Bitboard::from_square(Square::new(0, 0));
        let b = Bitboard::from_square(Square::new(7, 7));
        let both = a | b;
        assert_eq!(both.count(), 2);
        assert!(both.contains(Square::new(7, 7)));
        assert_eq!((both & a), a);
        assert_eq!((both ^ a), b);
        assert!((!both).count() == 62);
        assert!(Bitboard::EMPTY.is_empty());
        assert_eq!(both.lsb(), Some(Square::new(0, 0)));
    }

    #[test]
    fn iterates_in_index_order() {
        let bb = Bitboard(0b1010_0001);
        let v: Vec<usize> = bb.into_iter().map(|s| s.index()).collect();
        assert_eq!(v, vec![0, 5, 7]);
    }
}
