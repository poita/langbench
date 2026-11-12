//! Faces, the eighteen face-turn moves, and move-sequence text handling.

use std::fmt;
use std::str::FromStr;

/// One of the six faces of the cube, identified by its (fixed) centre.
///
/// The discriminant order `U R F D L B` is also the order of the faces in the
/// 54-character facelet string used by [`crate::FaceletCube`].
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum Face {
    U,
    R,
    F,
    D,
    L,
    B,
}

impl Face {
    /// All faces in `U R F D L B` order.
    pub const ALL: [Face; 6] = [Face::U, Face::R, Face::F, Face::D, Face::L, Face::B];

    /// Position of the face in [`Face::ALL`].
    pub fn index(self) -> usize {
        self as usize
    }

    /// The face at position `i` of [`Face::ALL`]. Panics if `i >= 6`.
    pub fn from_index(i: usize) -> Face {
        Face::ALL[i]
    }

    /// Parses an upper-case face letter.
    pub fn from_char(c: char) -> Option<Face> {
        match c {
            'U' => Some(Face::U),
            'R' => Some(Face::R),
            'F' => Some(Face::F),
            'D' => Some(Face::D),
            'L' => Some(Face::L),
            'B' => Some(Face::B),
            _ => None,
        }
    }

    /// The face letter.
    pub fn to_char(self) -> char {
        ['U', 'R', 'F', 'D', 'L', 'B'][self.index()]
    }
}

impl fmt::Display for Face {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_char())
    }
}

/// A face turn: a clockwise quarter turn (`X`), a half turn (`X2`) or a
/// counter-clockwise quarter turn (`X'`) of one face.
///
/// Internally the move is an index in `0..18`: `face * 3 + (quarter_turns - 1)`.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Move(u8);

impl Move {
    /// Number of distinct moves.
    pub const COUNT: usize = 18;

    /// All eighteen moves, ordered by face (`U R F D L B`) then `X`, `X2`, `X'`.
    pub const ALL: [Move; 18] = {
        let mut all = [Move(0); 18];
        let mut i = 0;
        while i < 18 {
            all[i] = Move(i as u8);
            i += 1;
        }
        all
    };

    /// Builds a move turning `face` clockwise by `quarter_turns` quarter
    /// turns, where `quarter_turns` is 1 (`X`), 2 (`X2`) or 3 (`X'`).
    ///
    /// Panics if `quarter_turns` is not in `1..=3`.
    pub fn new(face: Face, quarter_turns: u8) -> Move {
        assert!((1..=3).contains(&quarter_turns), "quarter_turns must be 1..=3");
        Move(face as u8 * 3 + quarter_turns - 1)
    }

    /// The move with the given index in `0..18` (see [`Move::index`]).
    pub fn from_index(i: usize) -> Move {
        assert!(i < Move::COUNT);
        Move(i as u8)
    }

    /// Index in `0..18`, usable to index per-move tables.
    pub fn index(self) -> usize {
        self.0 as usize
    }

    /// The face being turned.
    pub fn face(self) -> Face {
        Face::from_index((self.0 / 3) as usize)
    }

    /// Clockwise quarter turns: 1 for `X`, 2 for `X2`, 3 for `X'`.
    pub fn quarter_turns(self) -> u8 {
        self.0 % 3 + 1
    }

    /// The move undoing this one.
    pub fn inverse(self) -> Move {
        Move::new(self.face(), 4 - self.quarter_turns())
    }

    /// Whether this is a half turn (`X2`).
    pub fn is_half_turn(self) -> bool {
        self.quarter_turns() == 2
    }

    /// Parses a token given as bytes (`b"R"`, `b"R'"`, `b"R2"`).
    pub fn from_bytes(tok: &[u8]) -> Result<Move, ParseMoveError> {
        let err = || ParseMoveError(String::from_utf8_lossy(tok).into_owned());
        let (&f, rest) = tok.split_first().ok_or_else(err)?;
        let face = Face::from_char(f as char).ok_or_else(err)?;
        let turns = match rest {
            [] => 1,
            [b'2'] => 2,
            [b'\''] => 3,
            _ => return Err(err()),
        };
        Ok(Move::new(face, turns))
    }
}

impl fmt::Display for Move {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.face())?;
        match self.quarter_turns() {
            1 => Ok(()),
            2 => write!(f, "2"),
            _ => write!(f, "'"),
        }
    }
}

/// Error returned when a move token is not one of the eighteen legal tokens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseMoveError(pub String);

impl fmt::Display for ParseMoveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid move token {:?}", self.0)
    }
}

impl std::error::Error for ParseMoveError {}

impl FromStr for Move {
    type Err = ParseMoveError;
    fn from_str(s: &str) -> Result<Move, ParseMoveError> {
        Move::from_bytes(s.as_bytes())
    }
}

/// Parses whitespace-separated move tokens, e.g. `"R U R' U'"`. An empty (or
/// all-blank) string is the empty sequence.
pub fn parse_moves(s: &str) -> Result<Vec<Move>, ParseMoveError> {
    s.split_whitespace().map(str::parse).collect()
}

/// Formats moves as space-separated tokens (no trailing space).
pub fn format_moves(moves: &[Move]) -> String {
    let mut out = String::with_capacity(moves.len() * 3);
    for (i, m) in moves.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        out.push_str(&m.to_string());
    }
    out
}

/// The inverse of a move sequence.
pub fn invert_moves(moves: &[Move]) -> Vec<Move> {
    moves.iter().rev().map(|m| m.inverse()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_display_round_trip() {
        for m in Move::ALL {
            assert_eq!(m.to_string().parse::<Move>().unwrap(), m);
        }
        assert_eq!("R'".parse::<Move>().unwrap(), Move::new(Face::R, 3));
        assert_eq!("U2".parse::<Move>().unwrap(), Move::new(Face::U, 2));
    }

    #[test]
    fn rejects_bad_tokens() {
        for bad in ["", "r", "R2'", "R'2", "X", "R3", "RR", "R "] {
            assert!(bad.parse::<Move>().is_err(), "{bad:?}");
        }
    }

    #[test]
    fn sequences() {
        let seq = parse_moves("R U2  F'").unwrap();
        assert_eq!(format_moves(&seq), "R U2 F'");
        assert_eq!(format_moves(&invert_moves(&seq)), "F U2 R'");
        assert!(parse_moves("").unwrap().is_empty());
    }

    #[test]
    fn inverse_is_involution() {
        for m in Move::ALL {
            assert_eq!(m.inverse().inverse(), m);
            assert_eq!(m.inverse().face(), m.face());
        }
    }
}
