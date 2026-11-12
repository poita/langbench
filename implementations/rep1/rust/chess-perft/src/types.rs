//! Basic chess vocabulary: colours, piece kinds and squares.

use crate::error::ParseError;
use std::fmt;

/// A side: white or black.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Color {
    White,
    Black,
}

impl Color {
    /// The other side.
    #[inline]
    pub const fn opposite(self) -> Color {
        match self {
            Color::White => Color::Black,
            Color::Black => Color::White,
        }
    }

    /// Index usable for per-colour arrays (`White` = 0, `Black` = 1).
    #[inline]
    pub const fn index(self) -> usize {
        self as usize
    }
}

/// The kind of a piece, independent of colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PieceKind {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
}

impl PieceKind {
    /// All piece kinds, in index order.
    pub const ALL: [PieceKind; 6] = [
        PieceKind::Pawn,
        PieceKind::Knight,
        PieceKind::Bishop,
        PieceKind::Rook,
        PieceKind::Queen,
        PieceKind::King,
    ];

    /// Index usable for per-kind arrays (`Pawn` = 0 … `King` = 5).
    #[inline]
    pub const fn index(self) -> usize {
        self as usize
    }

    /// Lower-case letter used in FEN (black) and UCI promotion suffixes.
    pub const fn to_char(self) -> char {
        match self {
            PieceKind::Pawn => 'p',
            PieceKind::Knight => 'n',
            PieceKind::Bishop => 'b',
            PieceKind::Rook => 'r',
            PieceKind::Queen => 'q',
            PieceKind::King => 'k',
        }
    }

    /// Parses a FEN piece letter (either case) into a colour and kind.
    pub fn from_fen_char(c: char) -> Option<(Color, PieceKind)> {
        let kind = match c.to_ascii_lowercase() {
            'p' => PieceKind::Pawn,
            'n' => PieceKind::Knight,
            'b' => PieceKind::Bishop,
            'r' => PieceKind::Rook,
            'q' => PieceKind::Queen,
            'k' => PieceKind::King,
            _ => return None,
        };
        let color = if c.is_ascii_uppercase() { Color::White } else { Color::Black };
        Some((color, kind))
    }
}

/// A board square, numbered `a1` = 0, `b1` = 1, … `h8` = 63.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Square(u8);

impl Square {
    /// Builds a square from a 0–63 index. Panics in debug builds if out of range.
    #[inline]
    pub const fn from_index(index: usize) -> Square {
        debug_assert!(index < 64);
        Square(index as u8)
    }

    /// Builds a square from a file (0 = a) and a rank (0 = rank 1), both 0–7.
    #[inline]
    pub const fn new(file: usize, rank: usize) -> Square {
        Square::from_index(rank * 8 + file)
    }

    /// The 0–63 index of the square.
    #[inline]
    pub const fn index(self) -> usize {
        self.0 as usize
    }

    /// File, 0 (a) to 7 (h).
    #[inline]
    pub const fn file(self) -> usize {
        (self.0 & 7) as usize
    }

    /// Rank, 0 (rank 1) to 7 (rank 8).
    #[inline]
    pub const fn rank(self) -> usize {
        (self.0 >> 3) as usize
    }

    /// Parses algebraic notation such as `e4`.
    pub fn parse(s: &str) -> Result<Square, ParseError> {
        match s.as_bytes() {
            [f @ b'a'..=b'h', r @ b'1'..=b'8'] => {
                Ok(Square::new((f - b'a') as usize, (r - b'1') as usize))
            }
            _ => Err(ParseError::Square(s.to_string())),
        }
    }
}

impl fmt::Display for Square {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}{}", (b'a' + self.file() as u8) as char, self.rank() + 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn square_roundtrip() {
        for i in 0..64 {
            let sq = Square::from_index(i);
            assert_eq!(Square::parse(&sq.to_string()).unwrap(), sq);
        }
        assert_eq!(Square::parse("a1").unwrap().index(), 0);
        assert_eq!(Square::parse("h8").unwrap().index(), 63);
        assert_eq!(Square::parse("e4").unwrap(), Square::new(4, 3));
    }

    #[test]
    fn square_parse_rejects_garbage() {
        for s in ["", "e", "e9", "i1", "e44", "E4"] {
            assert!(Square::parse(s).is_err(), "{s}");
        }
    }

    #[test]
    fn fen_chars() {
        assert_eq!(PieceKind::from_fen_char('N'), Some((Color::White, PieceKind::Knight)));
        assert_eq!(PieceKind::from_fen_char('q'), Some((Color::Black, PieceKind::Queen)));
        assert_eq!(PieceKind::from_fen_char('x'), None);
    }
}
