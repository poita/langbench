//! Error types for FEN and query parsing.

use std::error::Error;
use std::fmt;

/// An error produced while parsing a FEN record or a query line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    /// The FEN (or query) has the wrong number of space-separated fields.
    FieldCount(usize),
    /// The piece placement field is malformed; the payload says why.
    Placement(String),
    /// The side-to-move field is not `w` or `b`.
    Side(String),
    /// The castling field is malformed.
    Castling(String),
    /// The en passant field is not `-` or a valid square.
    EnPassant(String),
    /// A numeric field could not be parsed.
    Number(String),
    /// The position does not have exactly one king per side.
    Kings,
    /// A square name such as `e4` could not be parsed.
    Square(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::FieldCount(n) => write!(f, "unexpected number of fields: {n}"),
            ParseError::Placement(s) => write!(f, "bad piece placement: {s}"),
            ParseError::Side(s) => write!(f, "bad side to move: {s:?}"),
            ParseError::Castling(s) => write!(f, "bad castling field: {s:?}"),
            ParseError::EnPassant(s) => write!(f, "bad en passant field: {s:?}"),
            ParseError::Number(s) => write!(f, "bad number: {s:?}"),
            ParseError::Kings => write!(f, "each side must have exactly one king"),
            ParseError::Square(s) => write!(f, "bad square: {s:?}"),
        }
    }
}

impl Error for ParseError {}
