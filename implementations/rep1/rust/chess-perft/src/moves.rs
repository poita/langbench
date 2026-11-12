//! Moves, move lists and the sink abstraction used by the generator.

use crate::bitboard::Bitboard;
use crate::types::{PieceKind, Square};
use std::fmt;

/// Special properties of a move that affect how it is played.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MoveKind {
    /// An ordinary move or capture.
    Normal,
    /// A pawn advancing two squares (creates an en passant square).
    DoublePush,
    /// An en passant capture.
    EnPassant,
    /// Castling, written as the king's two-square move.
    Castle,
    /// A pawn promotion (with or without capture) to the given piece.
    Promotion(PieceKind),
}

/// A move: origin, destination and kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Move {
    /// Origin square.
    pub from: Square,
    /// Destination square.
    pub to: Square,
    /// Special-move information.
    pub kind: MoveKind,
}

impl Move {
    /// Creates a move.
    #[inline]
    pub const fn new(from: Square, to: Square, kind: MoveKind) -> Move {
        Move { from, to, kind }
    }

    /// The promotion piece, if this is a promotion.
    pub const fn promotion(&self) -> Option<PieceKind> {
        match self.kind {
            MoveKind::Promotion(k) => Some(k),
            _ => None,
        }
    }
}

impl fmt::Display for Move {
    /// UCI long algebraic notation, e.g. `e2e4`, `e1g1`, `a7a8q`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}", self.from, self.to)?;
        if let Some(k) = self.promotion() {
            write!(f, "{}", k.to_char())?;
        }
        Ok(())
    }
}

/// Maximum number of legal moves in any chess position is 218; 256 is ample.
const CAPACITY: usize = 256;

/// A fixed-capacity, stack-allocated list of moves.
#[derive(Clone)]
pub struct MoveList {
    moves: [Move; CAPACITY],
    len: usize,
}

impl MoveList {
    /// An empty list.
    pub fn new() -> MoveList {
        let dummy = Move::new(Square::from_index(0), Square::from_index(0), MoveKind::Normal);
        MoveList { moves: [dummy; CAPACITY], len: 0 }
    }

    /// Number of moves.
    pub fn len(&self) -> usize {
        self.len
    }

    /// True if there are no moves.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// The moves as a slice.
    pub fn as_slice(&self) -> &[Move] {
        &self.moves[..self.len]
    }

    /// Iterates over the moves.
    pub fn iter(&self) -> std::slice::Iter<'_, Move> {
        self.as_slice().iter()
    }
}

impl Default for MoveList {
    fn default() -> Self {
        MoveList::new()
    }
}

impl<'a> IntoIterator for &'a MoveList {
    type Item = &'a Move;
    type IntoIter = std::slice::Iter<'a, Move>;
    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

impl std::ops::Deref for MoveList {
    type Target = [Move];
    fn deref(&self) -> &[Move] {
        self.as_slice()
    }
}

/// Receiver of generated moves.
///
/// The generator is generic over its sink so that the same code can either
/// materialise moves ([`MoveList`]) or merely count them ([`MoveCounter`]),
/// which is what bulk counting at the last ply needs.
pub trait MoveSink {
    /// Receives one move.
    fn push(&mut self, mv: Move);

    /// Receives a `Normal` move from `from` to every square in `targets`.
    #[inline]
    fn push_targets(&mut self, from: Square, targets: Bitboard) {
        for to in targets {
            self.push(Move::new(from, to, MoveKind::Normal));
        }
    }
}

impl MoveSink for MoveList {
    #[inline]
    fn push(&mut self, mv: Move) {
        self.moves[self.len] = mv;
        self.len += 1;
    }
}

/// A [`MoveSink`] that only counts moves.
#[derive(Default, Debug, Clone, Copy)]
pub struct MoveCounter {
    /// Number of moves received so far.
    pub count: u64,
}

impl MoveSink for MoveCounter {
    #[inline]
    fn push(&mut self, _mv: Move) {
        self.count += 1;
    }

    #[inline]
    fn push_targets(&mut self, _from: Square, targets: Bitboard) {
        self.count += targets.count() as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_uci() {
        let e2 = Square::parse("e2").unwrap();
        let e4 = Square::parse("e4").unwrap();
        assert_eq!(Move::new(e2, e4, MoveKind::DoublePush).to_string(), "e2e4");
        let a7 = Square::parse("a7").unwrap();
        let a8 = Square::parse("a8").unwrap();
        assert_eq!(Move::new(a7, a8, MoveKind::Promotion(PieceKind::Knight)).to_string(), "a7a8n");
    }

    #[test]
    fn list_and_counter() {
        let a1 = Square::from_index(0);
        let mut list = MoveList::new();
        let mut counter = MoveCounter::default();
        let targets = Bitboard(0b1110);
        list.push_targets(a1, targets);
        counter.push_targets(a1, targets);
        assert_eq!(list.len(), 3);
        assert_eq!(counter.count, 3);
        assert_eq!(list[0].to.index(), 1);
    }
}
